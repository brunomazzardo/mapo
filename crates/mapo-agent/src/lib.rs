//! The Claude adapter (ARCHITECTURE §3.5): turns hook events into agent status. The status machine
//! is a port of the VS Code build's `mapoAgentSessions.ts` (FEATURE-MAP §5.1), scoped by agent id.

pub mod hook;
pub mod machine;

pub use hook::{HookReport, report_from_hook_json};
pub use machine::{AgentState, AgentStatus, Derived, Event};
