//! Method names (PROTOCOL §6).

pub const HELLO: &str = "hello";
pub const PING: &str = "ping";
pub const INSTANCE_INFO: &str = "instance.info";
pub const DAEMON_SHUTDOWN: &str = "daemon.shutdown";
pub const STATE_SNAPSHOT: &str = "state.snapshot";
pub const EVENTS_SUBSCRIBE: &str = "events.subscribe";
/// The notification that carries an event.
pub const EVENT: &str = "event";
