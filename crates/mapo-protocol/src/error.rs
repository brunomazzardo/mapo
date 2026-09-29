//! Error kinds with their JSON-RPC codes and CLI exit codes (PROTOCOL §4).

use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorKind {
    InvalidArgument,
    NotFound,
    Conflict,
    Forbidden,
    Unavailable,
    Busy,
    Timeout,
    Cancelled,
    NeedsYou,
    Internal,
}

impl ErrorKind {
    pub fn code(self) -> i64 {
        match self {
            Self::InvalidArgument => -32602,
            Self::NotFound => -32001,
            Self::Conflict => -32002,
            Self::Forbidden => -32003,
            Self::Unavailable => -32004,
            Self::Busy => -32005,
            Self::Timeout => -32006,
            Self::Cancelled => -32007,
            Self::NeedsYou => -32008,
            Self::Internal => -32603,
        }
    }

    pub fn exit_code(self) -> i32 {
        match self {
            Self::InvalidArgument => 2,
            Self::Timeout => 124,
            Self::NeedsYou => 5,
            _ => 1,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::InvalidArgument => "invalid_argument",
            Self::NotFound => "not_found",
            Self::Conflict => "conflict",
            Self::Forbidden => "forbidden",
            Self::Unavailable => "unavailable",
            Self::Busy => "busy",
            Self::Timeout => "timeout",
            Self::Cancelled => "cancelled",
            Self::NeedsYou => "needs_you",
            Self::Internal => "internal",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ErrorData {
    pub kind: ErrorKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hint: Option<String>,
    #[serde(default)]
    pub details: Value,
    /// Extra top-level members such as `daemonProtocol`.
    #[serde(flatten)]
    pub extra: serde_json::Map<String, Value>,
}

/// A JSON-RPC error object: `{code, message, data: {kind, hint, details}}`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, thiserror::Error)]
#[error("{message}")]
pub struct RpcError {
    pub code: i64,
    pub message: String,
    pub data: Box<ErrorData>,
}

impl RpcError {
    pub fn new(kind: ErrorKind, message: impl Into<String>) -> Self {
        Self {
            code: kind.code(),
            message: message.into(),
            data: Box::new(ErrorData {
                kind,
                hint: None,
                details: Value::Object(Default::default()),
                extra: Default::default(),
            }),
        }
    }

    pub fn kind(&self) -> ErrorKind {
        self.data.kind
    }

    pub fn with_hint(mut self, hint: impl Into<String>) -> Self {
        self.data.hint = Some(hint.into());
        self
    }

    pub fn with_details(mut self, details: Value) -> Self {
        self.data.details = details;
        self
    }

    pub fn with_extra(mut self, key: &str, value: Value) -> Self {
        self.data.extra.insert(key.to_owned(), value);
        self
    }

    pub fn invalid(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::InvalidArgument, message)
    }

    pub fn not_found(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::NotFound, message)
    }

    pub fn conflict(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::Conflict, message)
    }

    pub fn forbidden(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::Forbidden, message)
    }

    pub fn unavailable(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::Unavailable, message)
    }

    pub fn internal(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::Internal, message)
    }

    /// The CLI's one-line JSON form: `{"error","kind","hint"}` (PROTOCOL §4).
    pub fn cli_line(&self) -> String {
        let mut obj = serde_json::json!({ "error": self.message, "kind": self.kind().as_str() });
        if let Some(hint) = &self.data.hint {
            obj["hint"] = Value::String(hint.clone());
        }
        obj.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wire_shape() {
        let err = RpcError::not_found("Tab \"x\" not found")
            .with_hint("mapo tab list")
            .with_details(serde_json::json!({"names": ["a"]}));
        assert_eq!(
            serde_json::to_value(&err).unwrap(),
            serde_json::json!({"code": -32001, "message": "Tab \"x\" not found",
                "data": {"kind": "not_found", "hint": "mapo tab list", "details": {"names": ["a"]}}})
        );
        let back: RpcError = serde_json::from_value(serde_json::to_value(&err).unwrap()).unwrap();
        assert_eq!(back, err);
        let codes: Vec<(i64, i32)> = [
            ErrorKind::InvalidArgument,
            ErrorKind::Timeout,
            ErrorKind::NeedsYou,
            ErrorKind::Busy,
        ]
        .iter()
        .map(|k| (k.code(), k.exit_code()))
        .collect();
        assert_eq!(
            codes,
            vec![(-32602, 2), (-32006, 124), (-32008, 5), (-32005, 1)]
        );
    }
}
