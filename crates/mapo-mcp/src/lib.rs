//! `mapo mcp`: a stdio MCP server on rmcp with one tool per public protocol method (PROTOCOL §10).
//!
//! The crate knows nothing about sockets or credentials. The `mapo` binary hands it a [`Caller`]
//! that opens a tab-credential connection per call, so rmcp's API churn stays inside this crate.

mod tools;

use std::io;
use std::path::Path;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};

use mapo_protocol::RpcError;
use rmcp::model::{
    CallToolRequestParams, CallToolResponse, CallToolResult, ContentBlock, ErrorData,
    Implementation, InitializeResult, ListResourcesResult, ListToolsResult, PaginatedRequestParams,
    ReadResourceRequestParams, ReadResourceResponse, ReadResourceResult, Resource,
    ResourceContents, ServerCapabilities, Tool,
};
use rmcp::service::{RequestContext, RoleServer};
use rmcp::{ServerHandler, ServiceExt};
use serde_json::{Map, Value, json};
use tokio::io::{AsyncRead, ReadBuf};
use tokio::sync::watch;

pub use tools::ToolSpec;

const SKILL_URI: &str = "mapo://skill";
const SKILL: &str = include_str!("../../../plugin/skills/mapo/SKILL.md");

/// Makes one protocol call. Blocking; the server runs it on its own thread.
pub trait Caller: Send + Sync + 'static {
    fn call(&self, method: &str, params: Value) -> Result<Value, RpcError>;
}

/// Serves MCP on stdin and stdout until stdin closes. Outstanding waits are cancelled then.
pub fn serve(caller: Arc<dyn Caller>) -> io::Result<()> {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()?;
    runtime.block_on(async move {
        let (closed_tx, closed_rx) = watch::channel(false);
        let server = Server {
            caller,
            tools: Arc::new(tools::all()),
            stdin_closed: closed_rx,
        };
        let stdin = EofSignal {
            inner: tokio::io::stdin(),
            closed: closed_tx,
        };
        let running = server
            .serve((stdin, tokio::io::stdout()))
            .await
            .map_err(|e| io::Error::other(e.to_string()))?;
        running
            .waiting()
            .await
            .map_err(|e| io::Error::other(e.to_string()))?;
        Ok::<(), io::Error>(())
    })?;
    // Blocking calls may still hold daemon connections; exiting closes them, which cancels them
    // in the daemon. Don't wait for the runtime to join those threads.
    runtime.shutdown_background();
    Ok(())
}

/// Stdin that tells the handlers when it reaches end of file.
struct EofSignal {
    inner: tokio::io::Stdin,
    closed: watch::Sender<bool>,
}

impl AsyncRead for EofSignal {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let before = buf.filled().len();
        let poll = Pin::new(&mut self.inner).poll_read(cx, buf);
        if let Poll::Ready(result) = &poll
            && (result.is_err() || (buf.filled().len() == before && buf.remaining() > 0))
        {
            self.closed.send_replace(true);
        }
        poll
    }
}

#[derive(Clone)]
struct Server {
    caller: Arc<dyn Caller>,
    tools: Arc<Vec<ToolSpec>>,
    stdin_closed: watch::Receiver<bool>,
}

impl Server {
    async fn run(&self, spec_index: usize, params: Value) -> CallToolResult {
        let caller = self.caller.clone();
        let tools = self.tools.clone();
        let (tx, rx) = tokio::sync::oneshot::channel();
        std::thread::spawn(move || {
            let spec = &tools[spec_index];
            let result = match spec.method {
                Some(method) => caller.call(method, params),
                None => status(caller.as_ref(), params),
            };
            let _ = tx.send(result);
        });
        let waits = self.tools[spec_index].waits;
        let mut closed = self.stdin_closed.clone();
        let outcome = tokio::select! {
            result = rx => result.unwrap_or_else(|_| Err(RpcError::internal("the call thread ended without a result"))),
            _ = closed.wait_for(|c| *c), if waits => Err(RpcError::new(
                mapo_protocol::ErrorKind::Cancelled,
                "cancelled: the MCP client closed stdin",
            )),
        };
        match outcome {
            Ok(value) => success(value),
            Err(err) => failure(&err),
        }
    }
}

fn success(value: Value) -> CallToolResult {
    let text = serde_json::to_string(&value).unwrap_or_default();
    let mut result = CallToolResult::success(vec![ContentBlock::text(text)]);
    result.structured_content = Some(json!({ "result": value }));
    result
}

fn failure(err: &RpcError) -> CallToolResult {
    let mut body = Map::new();
    body.insert("error".into(), json!(err.message));
    body.insert("kind".into(), json!(err.kind().as_str()));
    if let Some(hint) = &err.data.hint {
        body.insert("hint".into(), json!(hint));
    }
    if err.data.details.as_object().is_some_and(|d| !d.is_empty()) {
        body.insert("details".into(), err.data.details.clone());
    }
    CallToolResult::error(vec![ContentBlock::text(Value::Object(body).to_string())])
}

/// `mapo_status`: `tab.list`, optionally narrowed to one tab by name or id (like `mapo status`).
fn status(caller: &dyn Caller, params: Value) -> Result<Value, RpcError> {
    let mut params = match params {
        Value::Object(map) => map,
        _ => return Err(RpcError::invalid("params must be an object")),
    };
    let name = params.remove("tab");
    if let Some(key) = params.keys().find(|k| k.as_str() != "workspace") {
        return Err(RpcError::invalid(format!("unknown field `{key}`")));
    }
    let tabs = caller.call("tab.list", Value::Object(params))?;
    let Some(name) = name else {
        return Ok(tabs);
    };
    tabs.as_array()
        .and_then(|all| {
            all.iter()
                .find(|t| t["name"] == name || t["id"] == name)
                .cloned()
        })
        .ok_or_else(|| {
            RpcError::not_found(format!("Tab {name} not found")).with_hint("mapo_tab_list")
        })
}

/// Paths are absolute on the wire; resolve relative ones against this server's cwd.
fn absolutize(params: &mut Value) {
    let Ok(cwd) = std::env::current_dir() else {
        return;
    };
    let fix = |v: &mut Value| {
        if let Some(p) = v.as_str()
            && !Path::new(p).is_absolute()
        {
            *v = json!(cwd.join(p).to_string_lossy());
        }
    };
    for key in ["path", "cwd"] {
        if let Some(v) = params.get_mut(key) {
            fix(v);
        }
    }
    if let Some(v) = params.get_mut("content").and_then(|c| c.get_mut("file")) {
        fix(v);
    }
}

impl ServerHandler for Server {
    fn get_info(&self) -> InitializeResult {
        InitializeResult::new(
            ServerCapabilities::builder()
                .enable_tools()
                .enable_resources()
                .build(),
        )
        .with_server_info(Implementation::new("mapo", env!("CARGO_PKG_VERSION")))
        .with_instructions(
            "Mapo tools act on the Mapo workspaces and tabs this agent runs in. Names resolve in your own workspace. Read the resource mapo://skill for conventions: name your tabs, wait instead of polling, and pass force only when you mean it.",
        )
    }

    async fn list_tools(
        &self,
        _request: Option<PaginatedRequestParams>,
        _context: RequestContext<RoleServer>,
    ) -> Result<ListToolsResult, ErrorData> {
        let tools = self
            .tools
            .iter()
            .map(|spec| {
                let schema = match &spec.schema {
                    Value::Object(map) => map.clone(),
                    _ => Map::new(),
                };
                Tool::new(spec.name, spec.description, Arc::new(schema))
            })
            .collect();
        Ok(ListToolsResult::with_all_items(tools))
    }

    async fn call_tool(
        &self,
        request: CallToolRequestParams,
        _context: RequestContext<RoleServer>,
    ) -> Result<CallToolResponse, ErrorData> {
        let Some(index) = self.tools.iter().position(|t| t.name == request.name) else {
            return Err(ErrorData::invalid_params(
                format!("unknown tool {}", request.name),
                None,
            ));
        };
        let mut params = Value::Object(request.arguments.unwrap_or_default());
        absolutize(&mut params);
        Ok(CallToolResponse::Complete(self.run(index, params).await))
    }

    async fn list_resources(
        &self,
        _request: Option<PaginatedRequestParams>,
        _context: RequestContext<RoleServer>,
    ) -> Result<ListResourcesResult, ErrorData> {
        let mut skill = Resource::new(SKILL_URI, "mapo skill")
            .with_description("How to drive Mapo from an agent: names, verbs, waiting, guards.");
        skill.mime_type = Some("text/markdown".into());
        Ok(ListResourcesResult::with_all_items(vec![skill]))
    }

    async fn read_resource(
        &self,
        request: ReadResourceRequestParams,
        _context: RequestContext<RoleServer>,
    ) -> Result<ReadResourceResponse, ErrorData> {
        if request.uri != SKILL_URI {
            return Err(ErrorData::resource_not_found(
                format!("no resource {}", request.uri),
                None,
            ));
        }
        let contents = ResourceContents::TextResourceContents {
            uri: SKILL_URI.into(),
            mime_type: Some("text/markdown".into()),
            text: SKILL.into(),
            meta: None,
        };
        Ok(ReadResourceResponse::Complete(ReadResourceResult::new(
            vec![contents],
        )))
    }
}
