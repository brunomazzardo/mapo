//! JSON-RPC 2.0 envelopes, one per NDJSON line (PROTOCOL §1, §4).

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::error::RpcError;

/// Requests from clients carry numeric ids; requests from the daemon carry string ids ("d-17").
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Id {
    Num(i64),
    Str(String),
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Request {
    pub jsonrpc: String,
    pub id: Id,
    pub method: String,
    #[serde(default = "empty_object")]
    pub params: Value,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Notification {
    pub jsonrpc: String,
    pub method: String,
    #[serde(default = "empty_object")]
    pub params: Value,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Response {
    pub jsonrpc: String,
    pub id: Option<Id>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<RpcError>,
}

fn empty_object() -> Value {
    Value::Object(Default::default())
}

impl Request {
    pub fn new(id: Id, method: &str, params: Value) -> Self {
        Self {
            jsonrpc: "2.0".into(),
            id,
            method: method.into(),
            params,
        }
    }
}

impl Notification {
    pub fn new(method: &str, params: Value) -> Self {
        Self {
            jsonrpc: "2.0".into(),
            method: method.into(),
            params,
        }
    }
}

impl Response {
    pub fn ok(id: Id, result: Value) -> Self {
        Self {
            jsonrpc: "2.0".into(),
            id: Some(id),
            result: Some(result),
            error: None,
        }
    }

    pub fn err(id: Option<Id>, error: RpcError) -> Self {
        Self {
            jsonrpc: "2.0".into(),
            id,
            result: None,
            error: Some(error),
        }
    }

    pub fn into_result(self) -> Result<Value, RpcError> {
        match (self.error, self.result) {
            (Some(e), _) => Err(e),
            (None, Some(v)) => Ok(v),
            (None, None) => Ok(Value::Null),
        }
    }
}

/// One decoded line.
#[derive(Debug, Clone, PartialEq)]
pub enum Incoming {
    Request(Request),
    Notification(Notification),
    Response(Response),
}

impl Incoming {
    /// Parses a line. On failure, returns the error to send back with whatever id could be recovered.
    pub fn parse(line: &str) -> Result<Self, (Option<Id>, RpcError)> {
        let value: Value = serde_json::from_str(line)
            .map_err(|e| (None, RpcError::invalid(format!("malformed JSON: {e}"))))?;
        let id = value
            .get("id")
            .and_then(|v| serde_json::from_value::<Id>(v.clone()).ok());
        let obj = value.as_object().ok_or_else(|| {
            (
                id.clone(),
                RpcError::invalid("a message must be a JSON object"),
            )
        })?;
        if obj.get("jsonrpc").and_then(Value::as_str) != Some("2.0") {
            return Err((id, RpcError::invalid("jsonrpc must be \"2.0\"")));
        }
        if let Some(params) = obj.get("params")
            && !params.is_object()
        {
            return Err((id, RpcError::invalid("params must be an object")));
        }
        let decoded = if obj.contains_key("method") {
            if obj.contains_key("id") {
                serde_json::from_value(value).map(Self::Request)
            } else {
                serde_json::from_value(value).map(Self::Notification)
            }
        } else {
            serde_json::from_value(value).map(Self::Response)
        };
        decoded.map_err(|e| (id, RpcError::invalid(format!("malformed message: {e}"))))
    }
}

/// Decodes params into `T`, turning serde errors (unknown fields included) into `invalid_argument`.
pub fn parse_params<T: DeserializeOwned>(params: &Value) -> Result<T, RpcError> {
    serde_json::from_value(params.clone())
        .map_err(|e| RpcError::invalid(format!("invalid params: {e}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Debug, Deserialize, PartialEq)]
    #[serde(deny_unknown_fields, rename_all = "camelCase")]
    struct P {
        timeout_ms: Option<u64>,
    }

    #[test]
    fn parse_lines() {
        let got: Vec<String> = [
            r#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#,
            r#"{"jsonrpc":"2.0","method":"event","params":{"seq":1}}"#,
            r#"{"jsonrpc":"2.0","id":"d-3","result":{}}"#,
            r#"{"jsonrpc":"2.0","id":2,"method":"ping","params":[1]}"#,
            r#"{"jsonrpc":"1.0","id":3,"method":"ping"}"#,
            r#"not json"#,
        ]
        .iter()
        .map(|l| match Incoming::parse(l) {
            Ok(Incoming::Request(r)) => format!("req {:?} {} {}", r.id, r.method, r.params),
            Ok(Incoming::Notification(n)) => format!("note {}", n.method),
            Ok(Incoming::Response(r)) => format!("resp {:?}", r.id),
            Err((id, e)) => format!("err {:?} {}", id, e.kind().as_str()),
        })
        .collect();
        assert_eq!(
            got,
            vec![
                "req Num(1) ping {}",
                "note event",
                "resp Some(Str(\"d-3\"))",
                "err Some(Num(2)) invalid_argument",
                "err Some(Num(3)) invalid_argument",
                "err None invalid_argument",
            ]
        );
        assert_eq!(
            parse_params::<P>(&serde_json::json!({"timeoutMs": 5})).unwrap(),
            P {
                timeout_ms: Some(5)
            }
        );
        assert!(
            parse_params::<P>(&serde_json::json!({"bogus": 1}))
                .unwrap_err()
                .message
                .contains("bogus")
        );
    }
}
