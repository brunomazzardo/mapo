//! Files and git for the inspector (ARCHITECTURE §3.7): one-level folder listings with ignore rules,
//! a git status cache per repository root, and debounced file watching.

pub mod branch;
pub mod changes;
pub mod fs;
pub mod status;
pub mod watch;

pub use fs::{ListOptions, Listing, list};
pub use status::{Repo, RepoStatus, StatusCache};
pub use watch::{Change, Watcher};
