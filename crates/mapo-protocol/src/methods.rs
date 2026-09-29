//! Method names (PROTOCOL §6).

pub const HELLO: &str = "hello";
pub const PING: &str = "ping";
pub const INSTANCE_INFO: &str = "instance.info";
pub const DAEMON_SHUTDOWN: &str = "daemon.shutdown";
pub const STATE_SNAPSHOT: &str = "state.snapshot";
pub const EVENTS_SUBSCRIBE: &str = "events.subscribe";
/// The notification that carries an event.
pub const EVENT: &str = "event";
pub const WORKSPACE_LIST: &str = "workspace.list";
pub const WORKSPACE_CREATE: &str = "workspace.create";
pub const WORKSPACE_RENAME: &str = "workspace.rename";
pub const WORKSPACE_ACTIVATE: &str = "workspace.activate";
pub const WORKSPACE_DELETE: &str = "workspace.delete";
pub const TAB_LIST: &str = "tab.list";
pub const TAB_CREATE: &str = "tab.create";
pub const TAB_CLOSE: &str = "tab.close";
pub const TAB_RENAME: &str = "tab.rename";
pub const TAB_FOCUS: &str = "tab.focus";
pub const TAB_SEND: &str = "tab.send";
pub const TAB_READ: &str = "tab.read";
pub const TAB_WAIT: &str = "tab.wait";
pub const TAB_RUN: &str = "tab.run";
