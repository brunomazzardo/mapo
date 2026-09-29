//! Hook ingest: Claude's hook JSON to the fields `hook.report` accepts (PROTOCOL §6.7). Everything
//! else, prompts and tool outputs included, is dropped before it leaves `mapo hook`.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Longest tool summary kept (a Bash command or a file path).
pub const TOOL_SUMMARY_MAX: usize = 80;

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct HookReport {
    pub event: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub transcript_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notification_type: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prompt_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_summary: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_assistant_message: Option<String>,
}

fn string(v: &Value, key: &str) -> Option<String> {
    v.get(key)
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
}

fn truncate(s: &str, max: usize) -> String {
    let one_line: String = s.split_whitespace().collect::<Vec<_>>().join(" ");
    if one_line.chars().count() <= max {
        return one_line;
    }
    let mut out: String = one_line.chars().take(max - 1).collect();
    out.push('…');
    out
}

/// Parses a hook payload leniently: hook schemas change often, so unknown fields are ignored and a
/// missing event name is the only failure.
pub fn report_from_hook_json(json: &str) -> Option<HookReport> {
    let v: Value = serde_json::from_str(json).ok()?;
    let event = string(&v, "hook_event_name")?;
    let tool_summary = v.get("tool_input").and_then(|input| {
        ["command", "file_path", "path", "url", "pattern"]
            .iter()
            .find_map(|k| input.get(k).and_then(Value::as_str))
            .map(|s| truncate(s, TOOL_SUMMARY_MAX))
    });
    Some(HookReport {
        session_id: string(&v, "session_id"),
        source: string(&v, "source"),
        cwd: string(&v, "cwd"),
        transcript_path: string(&v, "transcript_path"),
        agent_id: string(&v, "agent_id"),
        notification_type: string(&v, "notification_type"),
        prompt_id: string(&v, "prompt_id"),
        tool_name: string(&v, "tool_name"),
        tool_summary,
        last_assistant_message: if event == "Stop" {
            string(&v, "last_assistant_message")
        } else {
            None
        },
        event,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fixtures_parse() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("fixtures");
        let mut names: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .flatten()
            .map(|e| e.path())
            .collect();
        names.sort();
        let got: Vec<(String, Option<String>)> = names
            .iter()
            .map(|p| {
                let r = report_from_hook_json(&std::fs::read_to_string(p).unwrap()).unwrap();
                assert!(crate::Event::parse(&r.event).is_some(), "{p:?}");
                (r.event, r.tool_summary)
            })
            .collect();
        assert!(got.len() >= 10, "{got:?}");
        let pr = got.iter().find(|(e, _)| e == "PermissionRequest").unwrap();
        assert_eq!(pr.1.as_deref(), Some("pnpm db:migrate"));
    }

    #[test]
    fn keeps_only_known_fields() {
        let r = report_from_hook_json(
            r#"{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"secret prompt","prompt_id":"p1"}"#,
        )
        .unwrap();
        let json = serde_json::to_string(&r).unwrap();
        assert!(!json.contains("secret"));
        assert_eq!(r.prompt_id.as_deref(), Some("p1"));
        let long = report_from_hook_json(&format!(
            r#"{{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{{"command":"{}"}}}}"#,
            "x".repeat(200)
        ))
        .unwrap();
        assert_eq!(long.tool_summary.map(|s| s.chars().count()), Some(80));
    }
}
