//! A small blocking client for CLI verbs: connect, hello, call (PROTOCOL §2, §3).

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::time::Duration;

use mapo_instance::{Instance, Paths};
use mapo_protocol::hello::{Credential, CredentialKind, HelloParams, HelloResult, Role};
use mapo_protocol::rpc::{Id, Incoming, Request};
use mapo_protocol::{PROTOCOL_VERSION, RpcError};
use serde_json::Value;

pub struct Client {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    next_id: i64,
    pub hello: HelloResult,
}

/// Picks the credential: `MAPO_TOKEN` when `MAPO_INSTANCE` names this instance, else its app token.
fn credential(instance: &Instance, paths: &Paths) -> Result<Credential, RpcError> {
    let env_instance = std::env::var("MAPO_INSTANCE").ok();
    if let (Ok(token), Some(env)) = (std::env::var("MAPO_TOKEN"), env_instance)
        && env == instance.name
        && !token.is_empty()
    {
        return Ok(Credential {
            kind: CredentialKind::Tab,
            token,
        });
    }
    let token = mapo_instance::read_token(&paths.token).map_err(|_| {
        RpcError::unavailable(format!("no daemon for instance {}", instance.name))
            .with_hint(format!("mapo --instance {} daemon", instance.name))
    })?;
    Ok(Credential {
        kind: CredentialKind::App,
        token: token.expose().to_owned(),
    })
}

impl Client {
    pub fn connect(
        instance: &Instance,
        role: Role,
        timeout: Option<Duration>,
    ) -> Result<Self, RpcError> {
        let paths = instance
            .paths()
            .map_err(|e| RpcError::internal(e.to_string()))?;
        let stream = UnixStream::connect(&paths.socket).map_err(|_| {
            RpcError::unavailable(format!("no daemon for instance {}", instance.name))
                .with_hint(format!("mapo --instance {} daemon", instance.name))
        })?;
        stream.set_read_timeout(timeout).ok();
        let writer = stream
            .try_clone()
            .map_err(|e| RpcError::internal(e.to_string()))?;
        let mut client = Self {
            reader: BufReader::new(stream),
            writer,
            next_id: 1,
            hello: HelloResult {
                protocol: 0,
                daemon: String::new(),
                boot_id: String::new(),
                instance: String::new(),
                features: vec![],
                caller: mapo_protocol::hello::Caller {
                    kind: CredentialKind::App,
                    tab_id: None,
                    workspace_id: None,
                },
            },
        };
        let params = HelloParams {
            protocol: PROTOCOL_VERSION,
            role,
            client: format!("mapo/{}", env!("CARGO_PKG_VERSION")),
            credential: credential(instance, &paths)?,
            attach: None,
        };
        let value = serde_json::to_value(&params).map_err(|e| RpcError::internal(e.to_string()))?;
        let hello: HelloResult = serde_json::from_value(client.call("hello", value)?)
            .map_err(|e| RpcError::internal(format!("bad hello result: {e}")))?;
        if hello.instance != instance.name {
            return Err(RpcError::unavailable(format!(
                "connected to instance {} but resolved {}",
                hello.instance, instance.name
            )));
        }
        client.hello = hello;
        Ok(client)
    }

    pub fn send(&mut self, method: &str, params: Value) -> Result<Id, RpcError> {
        let id = Id::Num(self.next_id);
        self.next_id += 1;
        let mut line = serde_json::to_string(&Request::new(id.clone(), method, params))
            .map_err(|e| RpcError::internal(e.to_string()))?;
        line.push('\n');
        self.writer
            .write_all(line.as_bytes())
            .map_err(|e| RpcError::unavailable(format!("daemon connection lost: {e}")))?;
        Ok(id)
    }

    /// Reads the next line: a response or a notification.
    pub fn read(&mut self) -> Result<Incoming, RpcError> {
        let mut line = String::new();
        match self.reader.read_line(&mut line) {
            Ok(0) => Err(RpcError::unavailable("the daemon closed the connection")),
            Ok(_) => Incoming::parse(line.trim_end()).map_err(|(_, e)| e),
            Err(e)
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                Err(RpcError::new(
                    mapo_protocol::ErrorKind::Timeout,
                    "timed out waiting for the daemon",
                ))
            }
            Err(e) => Err(RpcError::unavailable(format!(
                "daemon connection lost: {e}"
            ))),
        }
    }

    pub fn call(&mut self, method: &str, params: Value) -> Result<Value, RpcError> {
        let id = self.send(method, params)?;
        loop {
            if let Incoming::Response(resp) = self.read()?
                && resp.id.as_ref() == Some(&id)
            {
                return resp.into_result();
            }
        }
    }
}
