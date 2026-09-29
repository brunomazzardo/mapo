//! The pure status function: raw tab facts to `state` and `stateLabel` (REQUIREMENTS R-ST-1).

use mapo_protocol::types::{State, TabKind};

/// Everything the status function looks at. Later milestones add agent facts.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Facts {
    pub kind: Option<TabKind>,
    pub launch_error: bool,
    pub spawning: bool,
    pub stopping: bool,
    /// The shell exited with a non-zero code or a signal (R-TAB-12).
    pub stopped_exit: Option<i32>,
    /// Between OSC 133;C and 133;D.
    pub in_command: bool,
    /// A long command finished with this non-zero code while nobody viewed the tab; clears when
    /// the next command starts (R-TAB-11, R-ST-5).
    pub failed_exit: Option<i32>,
    /// A long command finished with 0 while nobody viewed the tab; clears once viewed (UX §7.4).
    pub done: bool,
    /// Hook-driven agent status while an agent runs in the tab (R-AG-3); it wins over the shell's.
    pub agent: Option<mapo_agent::Derived>,
}

pub fn status(f: &Facts) -> (State, String) {
    if f.launch_error {
        return (State::Failed, "Couldn't start".into());
    }
    if f.stopped_exit.is_some() {
        return (State::Stopped, "Stopped".into());
    }
    if f.stopping {
        return (State::Stopping, "Stopping".into());
    }
    if let Some(agent) = f.agent {
        use mapo_agent::Derived;
        return match agent {
            Derived::NeedsYou => (State::NeedsYou, "Needs you".into()),
            Derived::Running => (State::Running, "Working".into()),
            Derived::Done => (State::Done, "Done".into()),
            Derived::Idle => (State::Idle, String::new()),
        };
    }
    if f.spawning {
        return (State::Starting, "Starting".into());
    }
    if f.in_command {
        let word = if f.kind == Some(TabKind::Agent) {
            "Working"
        } else {
            "Running"
        };
        return (State::Running, word.into());
    }
    if f.failed_exit.is_some() {
        return (State::Failed, "Failed".into());
    }
    if f.done {
        return (State::Done, "Done".into());
    }
    (State::Idle, String::new())
}

/// The short detail shown next to a state word ("exit 1"), when there is one.
pub fn detail(f: &Facts) -> Option<String> {
    if f.launch_error {
        return None;
    }
    f.failed_exit
        .or(f.stopped_exit)
        .map(|code| format!("exit {code}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn table() {
        let cases = [
            (Facts::default(), (State::Idle, "")),
            (
                Facts {
                    spawning: true,
                    ..Default::default()
                },
                (State::Starting, "Starting"),
            ),
            (
                Facts {
                    launch_error: true,
                    spawning: true,
                    ..Default::default()
                },
                (State::Failed, "Couldn't start"),
            ),
            (
                Facts {
                    stopped_exit: Some(3),
                    ..Default::default()
                },
                (State::Stopped, "Stopped"),
            ),
            (
                Facts {
                    in_command: true,
                    ..Default::default()
                },
                (State::Running, "Running"),
            ),
            (
                Facts {
                    in_command: true,
                    kind: Some(TabKind::Agent),
                    ..Default::default()
                },
                (State::Running, "Working"),
            ),
            (
                Facts {
                    failed_exit: Some(1),
                    ..Default::default()
                },
                (State::Failed, "Failed"),
            ),
            (
                Facts {
                    done: true,
                    ..Default::default()
                },
                (State::Done, "Done"),
            ),
            (
                Facts {
                    in_command: true,
                    agent: Some(mapo_agent::Derived::NeedsYou),
                    ..Default::default()
                },
                (State::NeedsYou, "Needs you"),
            ),
            (
                Facts {
                    in_command: true,
                    agent: Some(mapo_agent::Derived::Running),
                    ..Default::default()
                },
                (State::Running, "Working"),
            ),
            (
                Facts {
                    agent: Some(mapo_agent::Derived::Done),
                    ..Default::default()
                },
                (State::Done, "Done"),
            ),
            (
                Facts {
                    failed_exit: Some(1),
                    in_command: true,
                    ..Default::default()
                },
                (State::Running, "Running"),
            ),
            (
                Facts {
                    stopping: true,
                    in_command: true,
                    ..Default::default()
                },
                (State::Stopping, "Stopping"),
            ),
        ];
        let got: Vec<(State, String)> = cases.iter().map(|(f, _)| status(f)).collect();
        let want: Vec<(State, String)> = cases
            .iter()
            .map(|(_, (s, l))| (*s, (*l).to_owned()))
            .collect();
        assert_eq!(got, want);
    }
}
