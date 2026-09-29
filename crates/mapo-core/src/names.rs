//! Default names (PLAN T0.4 step 2).

/// The first free `Workspace N`, from 1.
pub fn first_free_workspace<'a>(taken: impl IntoIterator<Item = &'a str>) -> String {
    first_free("Workspace ", taken)
}

/// The first free `<prefix>N`, from 1: `terminal-` or `agent-`.
pub fn first_free<'a>(prefix: &str, taken: impl IntoIterator<Item = &'a str>) -> String {
    let taken: std::collections::HashSet<&str> = taken.into_iter().collect();
    (1..)
        .map(|n| format!("{prefix}{n}"))
        .find(|name| !taken.contains(name.as_str()))
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn free_names() {
        assert_eq!(
            [
                first_free_workspace([]),
                first_free_workspace(["Workspace 1", "Obsess"]),
                first_free_workspace(["Workspace 2"]),
                first_free("terminal-", ["terminal-1", "terminal-2"]),
            ],
            ["Workspace 1", "Workspace 2", "Workspace 1", "terminal-3"]
        );
    }
}
