//! State model, command dispatch, event ring and persistence (ARCHITECTURE §3.3).
//!
//! One actor task owns all state. Callers send it messages with a oneshot reply; it never
//! awaits I/O. Every mutation sends a write batch to the SQLite thread and appends events.

pub mod actor;
pub mod events;
pub mod layout;
pub mod model;
pub mod names;
pub mod status;
pub mod store;

pub use actor::{CoreHandle, spawn};
