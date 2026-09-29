//! The event ring: 10,000 numbered events with the boot id, replayable with `after`
//! (PROTOCOL §7, REQUIREMENTS R-CTL-5).

use std::collections::VecDeque;

use mapo_protocol::RpcError;
use mapo_protocol::types::Event;
use serde_json::{Value, json};
use tokio::sync::mpsc;

pub const RING_CAPACITY: usize = 10_000;
/// A subscriber further behind than this is cut off with `cursor_expired`.
pub const SUBSCRIBER_QUEUE: usize = 1_000;

pub type SubItem = Result<Event, RpcError>;

struct Subscriber {
    tx: mpsc::Sender<SubItem>,
    types: Option<Vec<String>>,
}

pub struct Ring {
    boot_id: String,
    seq: u64,
    events: VecDeque<Event>,
    subscribers: Vec<Subscriber>,
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn wanted(types: &Option<Vec<String>>, kind: &str) -> bool {
    types.as_ref().is_none_or(|t| t.iter().any(|x| x == kind))
}

pub fn cursor_expired(oldest: u64) -> RpcError {
    RpcError::conflict("the event cursor is older than the ring; take a fresh state.snapshot")
        .with_details(json!({ "reason": "cursor_expired", "oldestSeq": oldest }))
}

impl Ring {
    pub fn new(boot_id: String) -> Self {
        Self {
            boot_id,
            seq: 0,
            events: VecDeque::with_capacity(1024),
            subscribers: Vec::new(),
        }
    }

    pub fn boot_id(&self) -> &str {
        &self.boot_id
    }

    pub fn seq(&self) -> u64 {
        self.seq
    }

    pub fn push(&mut self, kind: &str, data: Value) {
        self.seq += 1;
        let event = Event {
            seq: self.seq,
            boot_id: self.boot_id.clone(),
            at: now_ms(),
            kind: kind.to_owned(),
            data,
        };
        if self.events.len() == RING_CAPACITY {
            self.events.pop_front();
        }
        self.subscribers.retain(|s| {
            if !wanted(&s.types, kind) {
                return !s.tx.is_closed();
            }
            if s.tx.capacity() <= 1 {
                let oldest = event.seq;
                let _ = s.tx.try_send(Err(cursor_expired(oldest)));
                return false;
            }
            s.tx.try_send(Ok(event.clone())).is_ok()
        });
        self.events.push_back(event);
    }

    pub fn oldest(&self) -> u64 {
        self.events.front().map_or(self.seq + 1, |e| e.seq)
    }

    /// Events after `after`, or `cursor_expired` if the ring no longer holds `after + 1`.
    pub fn since(&self, after: u64, types: &Option<Vec<String>>) -> Result<Vec<Event>, RpcError> {
        if after + 1 < self.oldest() && after < self.seq {
            return Err(cursor_expired(self.oldest()));
        }
        Ok(self
            .events
            .iter()
            .filter(|e| e.seq > after && wanted(types, &e.kind))
            .cloned()
            .collect())
    }

    /// Replays from `after` (default: now) and registers a live subscriber.
    pub fn subscribe(
        &mut self,
        after: Option<u64>,
        types: Option<Vec<String>>,
    ) -> Result<(u64, Vec<Event>, mpsc::Receiver<SubItem>), RpcError> {
        let replay = match after {
            Some(a) => self.since(a, &types)?,
            None => Vec::new(),
        };
        let (tx, rx) = mpsc::channel(SUBSCRIBER_QUEUE + 1);
        self.subscribers.push(Subscriber { tx, types });
        Ok((self.seq, replay, rx))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ring_replay_and_expiry() {
        let mut ring = Ring::new("b".into());
        for _ in 0..(RING_CAPACITY + 5) {
            ring.push("x", json!({}));
        }
        let got = (
            ring.oldest(),
            ring.since(RING_CAPACITY as u64 + 3, &None)
                .map(|v| v.len())
                .ok(),
            ring.since(1, &None)
                .err()
                .map(|e| e.data.details["reason"].clone()),
            ring.since(5, &None).map(|v| v.len()).ok(),
        );
        assert_eq!(
            got,
            (
                6,
                Some(2),
                Some(json!("cursor_expired")),
                Some(RING_CAPACITY)
            )
        );
    }

    #[tokio::test(flavor = "current_thread")]
    async fn slow_subscriber_is_cut_off() {
        let mut ring = Ring::new("b".into());
        let (_, _, mut rx) = ring.subscribe(None, None).unwrap();
        for _ in 0..(SUBSCRIBER_QUEUE + 10) {
            ring.push("x", json!({}));
        }
        let mut n = 0;
        let mut last = None;
        while let Ok(item) = rx.try_recv() {
            n += 1;
            last = Some(item.is_err());
        }
        assert_eq!((n, last), (SUBSCRIBER_QUEUE + 1, Some(true)));
    }
}
