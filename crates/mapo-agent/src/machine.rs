//! The hook-event status machine (FEATURE-MAP §5.1, REQUIREMENTS R-AG-3).

use std::collections::BTreeSet;
use std::time::{Duration, Instant};

/// The main agent's own status.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AgentStatus {
    Idle,
    Running,
    Done,
}

/// What the rail shows for the agent.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Derived {
    NeedsYou,
    Running,
    Done,
    Idle,
}

/// Hook events Mapo handles.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Event {
    SessionStart,
    UserPromptSubmit,
    Notification,
    PermissionRequest,
    PostToolBatch,
    SubagentStart,
    SubagentStop,
    Stop,
    StopFailure,
    SessionEnd,
}

impl Event {
    pub fn parse(name: &str) -> Option<Self> {
        Some(match name {
            "SessionStart" => Self::SessionStart,
            "UserPromptSubmit" => Self::UserPromptSubmit,
            "Notification" => Self::Notification,
            "PermissionRequest" => Self::PermissionRequest,
            "PostToolBatch" => Self::PostToolBatch,
            "SubagentStart" => Self::SubagentStart,
            "SubagentStop" => Self::SubagentStop,
            "Stop" => Self::Stop,
            "StopFailure" => Self::StopFailure,
            "SessionEnd" => Self::SessionEnd,
            _ => return None,
        })
    }
}

/// Notification types that mean the agent waits on the user; idle reminders and auth
/// notifications never create attention.
pub const ATTENTION_NOTIFICATIONS: &[&str] = &[
    "permission_prompt",
    "elicitation_dialog",
    "elicitation_url_dialog",
    "agent_needs_input",
];

/// How long an optimistic Working (after a send) waits for UserPromptSubmit.
pub const OPTIMISTIC_REVERT: Duration = Duration::from_secs(6);

#[derive(Debug, Clone, PartialEq, Eq)]
struct Optimistic {
    prior: AgentStatus,
    sent_at: Instant,
}

/// Per-tab agent state. `scope` is the hook's `agent_id`, or "" for the main agent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentState {
    pub status: AgentStatus,
    pub attention: BTreeSet<String>,
    pub subagents: BTreeSet<String>,
    pub interrupted: bool,
    pub hooks_connected: bool,
    pub turn_started_at: Option<Instant>,
    optimistic: Option<Optimistic>,
}

impl Default for AgentState {
    fn default() -> Self {
        Self {
            status: AgentStatus::Idle,
            attention: BTreeSet::new(),
            subagents: BTreeSet::new(),
            interrupted: false,
            hooks_connected: false,
            turn_started_at: None,
            optimistic: None,
        }
    }
}

impl AgentState {
    /// Applies one hook event. Returns false when a Notification of another type was ignored.
    pub fn receive(
        &mut self,
        event: Event,
        scope: &str,
        notification_type: Option<&str>,
        now: Instant,
    ) -> bool {
        if matches!(event, Event::UserPromptSubmit | Event::SessionStart) {
            self.interrupted = false;
        }
        if event == Event::Notification
            && !notification_type.is_some_and(|t| ATTENTION_NOTIFICATIONS.contains(&t))
        {
            self.hooks_connected = true;
            return false;
        }
        let suppressed = matches!(
            event,
            Event::PostToolBatch
                | Event::Stop
                | Event::Notification
                | Event::PermissionRequest
                | Event::SubagentStart
        );
        if self.interrupted && suppressed {
            self.hooks_connected = true;
            return true;
        }
        match event {
            Event::UserPromptSubmit => {
                self.attention.clear();
                self.status = AgentStatus::Running;
                self.turn_started_at = Some(now);
                self.optimistic = None;
            }
            Event::PostToolBatch => {
                self.attention.remove(scope);
                if scope.is_empty() {
                    self.status = AgentStatus::Running;
                }
            }
            Event::SubagentStart => {
                if !scope.is_empty() {
                    self.subagents.insert(scope.to_owned());
                }
            }
            Event::SubagentStop => {
                self.subagents.remove(scope);
                self.attention.remove(scope);
            }
            Event::Notification | Event::PermissionRequest | Event::StopFailure => {
                self.attention.insert(scope.to_owned());
            }
            Event::Stop => {
                self.attention.remove(scope);
                self.status = AgentStatus::Done;
                self.optimistic = None;
            }
            Event::SessionStart | Event::SessionEnd => {
                self.attention.clear();
                self.subagents.clear();
                self.status = AgentStatus::Idle;
            }
        }
        self.hooks_connected = true;
        true
    }

    /// Mapo wrote ESC: late events are ignored until the next prompt (Stop doesn't fire on Esc).
    pub fn interrupt(&mut self) {
        self.interrupted = true;
        self.attention.clear();
        self.subagents.clear();
        self.status = AgentStatus::Idle;
        self.optimistic = None;
    }

    /// A prompt was sent: show Working at once, reverting after 6 s without UserPromptSubmit.
    pub fn submit(&mut self, now: Instant) {
        self.interrupted = false;
        self.attention.clear();
        self.optimistic = Some(Optimistic {
            prior: self.status,
            sent_at: now,
        });
        self.status = AgentStatus::Running;
    }

    /// Reverts an optimistic Working that no UserPromptSubmit confirmed. Returns true on change.
    pub fn expire_optimistic(&mut self, now: Instant) -> bool {
        match &self.optimistic {
            Some(o) if now.duration_since(o.sent_at) >= OPTIMISTIC_REVERT => {
                if self.status == AgentStatus::Running {
                    self.status = o.prior;
                }
                self.optimistic = None;
                true
            }
            _ => false,
        }
    }

    /// When the next optimistic revert is due, if any.
    pub fn optimistic_deadline(&self) -> Option<Instant> {
        self.optimistic
            .as_ref()
            .map(|o| o.sent_at + OPTIMISTIC_REVERT)
    }

    pub fn derived(&self) -> Derived {
        if !self.attention.is_empty() {
            return Derived::NeedsYou;
        }
        if !self.subagents.is_empty() {
            return Derived::Running;
        }
        match self.status {
            AgentStatus::Running => Derived::Running,
            AgentStatus::Done => Derived::Done,
            AgentStatus::Idle => Derived::Idle,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    type Step<'a> = (&'a str, &'a str, Option<&'a str>);

    fn run(steps: &[Step<'_>]) -> Vec<Derived> {
        let mut s = AgentState::default();
        let now = Instant::now();
        steps
            .iter()
            .map(|(e, scope, n)| {
                match *e {
                    "interrupt" => s.interrupt(),
                    name => {
                        s.receive(Event::parse(name).unwrap(), scope, *n, now);
                    }
                }
                s.derived()
            })
            .collect()
    }

    #[test]
    fn transitions() {
        use Derived::*;
        let cases: Vec<(Vec<Step<'_>>, Vec<Derived>)> = vec![
            // A turn with a permission request.
            (
                vec![
                    ("SessionStart", "", None),
                    ("UserPromptSubmit", "", None),
                    ("PermissionRequest", "", None),
                    ("PostToolBatch", "", None),
                    ("Stop", "", None),
                ],
                vec![Idle, Running, NeedsYou, Running, Done],
            ),
            // Stop while a subagent runs stays running until SubagentStop.
            (
                vec![
                    ("UserPromptSubmit", "", None),
                    ("SubagentStart", "a1", None),
                    ("Stop", "", None),
                    ("SubagentStop", "a1", None),
                ],
                vec![Running, Running, Running, Done],
            ),
            // Attention is scoped: a subagent's request, cleared by its SubagentStop.
            (
                vec![
                    ("UserPromptSubmit", "", None),
                    ("SubagentStart", "a1", None),
                    ("PermissionRequest", "a1", None),
                    ("SubagentStop", "a1", None),
                ],
                vec![Running, Running, NeedsYou, Running],
            ),
            // Only attention notification types count.
            (
                vec![
                    ("UserPromptSubmit", "", None),
                    ("Notification", "", Some("idle_prompt")),
                    ("Notification", "", Some("permission_prompt")),
                ],
                vec![Running, Running, NeedsYou],
            ),
            // An interrupt ignores late events until the next prompt.
            (
                vec![
                    ("UserPromptSubmit", "", None),
                    ("interrupt", "", None),
                    ("PostToolBatch", "", None),
                    ("Stop", "", None),
                    ("UserPromptSubmit", "", None),
                ],
                vec![Running, Idle, Idle, Idle, Running],
            ),
            // StopFailure needs you even while interrupted.
            (
                vec![
                    ("UserPromptSubmit", "", None),
                    ("interrupt", "", None),
                    ("StopFailure", "", None),
                ],
                vec![Running, Idle, NeedsYou],
            ),
            // /clear: SessionEnd then SessionStart keeps working afterwards.
            (
                vec![
                    ("UserPromptSubmit", "", None),
                    ("SessionEnd", "", None),
                    ("SessionStart", "", None),
                    ("UserPromptSubmit", "", None),
                ],
                vec![Running, Idle, Idle, Running],
            ),
        ];
        for (steps, want) in cases {
            assert_eq!(run(&steps), want, "{steps:?}");
        }
    }

    #[test]
    fn optimistic_submit_reverts() {
        let t0 = Instant::now();
        let mut s = AgentState::default();
        s.submit(t0);
        let a = (
            s.derived(),
            s.expire_optimistic(t0 + Duration::from_secs(1)),
        );
        let b = (
            s.expire_optimistic(t0 + Duration::from_secs(7)),
            s.derived(),
        );
        let mut c = AgentState::default();
        c.submit(t0);
        c.receive(Event::UserPromptSubmit, "", None, t0);
        let d = (
            c.expire_optimistic(t0 + Duration::from_secs(7)),
            c.derived(),
        );
        assert_eq!(
            (a, b, d),
            (
                (Derived::Running, false),
                (true, Derived::Idle),
                (false, Derived::Running)
            )
        );
    }
}
