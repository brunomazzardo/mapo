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
    /// The last command failed and no new command started since (R-ST-5).
    pub last_command_failed: Option<i32>,
}

pub fn status(f: &Facts) -> (State, String) {
    if f.launch_error {
        return (State::Failed, "Couldn't start".into());
    }
    if let Some(code) = f.stopped_exit {
        return (State::Stopped, format!("Stopped (exit {code})"));
    }
    if f.stopping {
        return (State::Stopping, "Stopping".into());
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
    if let Some(code) = f.last_command_failed {
        return (State::Failed, format!("Failed (exit {code})"));
    }
    (State::Idle, String::new())
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
                (State::Stopped, "Stopped (exit 3)"),
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
                    last_command_failed: Some(1),
                    ..Default::default()
                },
                (State::Failed, "Failed (exit 1)"),
            ),
            (
                Facts {
                    last_command_failed: Some(1),
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
