//! The handshake (PROTOCOL §2, §3) and the M0 meta results.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Role {
    App,
    Cli,
    Mcp,
    Hook,
    Attach,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CredentialKind {
    App,
    Tab,
    Hook,
}

/// The token travels only here; never log a `Credential`.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Credential {
    pub kind: CredentialKind,
    pub token: String,
}

impl std::fmt::Debug for Credential {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Credential {{ kind: {:?}, token: *** }}", self.kind)
    }
}

/// Attach parameters inside `hello` (PROTOCOL §8).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct AttachHello {
    pub tab: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace: Option<String>,
    pub cols: u16,
    pub rows: u16,
    #[serde(default)]
    pub width_px: u16,
    #[serde(default)]
    pub height_px: u16,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct HelloParams {
    pub protocol: u32,
    pub role: Role,
    #[serde(default)]
    pub client: String,
    pub credential: Credential,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub attach: Option<AttachHello>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Caller {
    pub kind: CredentialKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tab_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HelloResult {
    pub protocol: u32,
    pub daemon: String,
    pub boot_id: String,
    pub instance: String,
    pub features: Vec<String>,
    pub caller: Caller,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub attach: Option<AttachResult>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AttachResult {
    pub tab_id: String,
    pub replay_bytes: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PingResult {
    pub boot_id: String,
    pub uptime_ms: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InstanceInfo {
    pub instance: String,
    pub data_dir: String,
    pub runtime_dir: String,
    pub socket: String,
    pub daemon_pid: u32,
    pub version: String,
    pub protocol: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub config_error: Option<String>,
}

/// Params of methods that take none: `{}` only, anything else is `invalid_argument`.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Empty {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hello_round_trip() {
        let line = r#"{"protocol":1,"role":"cli","client":"mapo/0.1.0","credential":{"kind":"app","token":"t"}}"#;
        let p: HelloParams = serde_json::from_str(line).unwrap();
        assert_eq!(serde_json::to_string(&p).unwrap(), line);
        assert!(!format!("{p:?}").contains("\"t\""));
        assert!(
            serde_json::from_str::<HelloParams>(
                r#"{"protocol":1,"role":"cli","credential":{"kind":"app","token":"t"},"x":1}"#
            )
            .is_err()
        );
    }
}
