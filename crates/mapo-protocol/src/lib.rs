//! The Mapo wire contract (docs/PROTOCOL.md): JSON-RPC 2.0 over NDJSON, error kinds,
//! the hello handshake, method names, shared types and the attach frame codec.

pub mod error;
pub mod hello;
pub mod methods;
pub mod rpc;

pub use error::{ErrorData, ErrorKind, RpcError};
pub use rpc::{Incoming, Notification, Request, Response, parse_params};

/// The protocol version this build speaks (PROTOCOL §2).
pub const PROTOCOL_VERSION: u32 = 1;
