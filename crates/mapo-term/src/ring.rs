//! The ring buffer: a tab's recent raw output with absolute offsets, trimmed
//! only where a replay can safely start.

use std::collections::VecDeque;

/// Default capacity of a [`Ring`]: 2 MiB of raw bytes.
pub const DEFAULT_RING_CAPACITY: usize = 2 << 20;

/// Raw byte history of a tab, addressed by absolute offsets.
///
/// A boundary tracker follows the escape-sequence state of every byte pushed.
/// Each `\n` seen in ground state is a safe offset (skipping ones closer than
/// `capacity / 16`, at most 256 bytes, to the previous safe offset, which bounds
/// the bookkeeping). Output with no newline for `capacity / 4` bytes (at most
/// 64 KiB) records a ground-state character boundary instead. When the ring
/// grows past its capacity it cuts at the oldest safe offset past the overflow,
/// so the held bytes never start inside an escape sequence or a UTF-8
/// character. Only a single sequence longer than the capacity forces a raw cut.
#[derive(Debug, Clone)]
pub struct Ring {
    buf: VecDeque<u8>,
    start: u64,
    capacity: usize,
    tracker: Tracker,
    safe: VecDeque<u64>,
    last_safe: u64,
    last_alt_screen_enter: Option<u64>,
}

impl Default for Ring {
    fn default() -> Self {
        Self::new()
    }
}

impl Ring {
    /// An empty ring of [`DEFAULT_RING_CAPACITY`].
    pub fn new() -> Self {
        Self::with_capacity(DEFAULT_RING_CAPACITY)
    }

    /// An empty ring that holds at most `capacity` bytes (at least 64).
    pub fn with_capacity(capacity: usize) -> Self {
        Self {
            buf: VecDeque::new(),
            start: 0,
            capacity: capacity.max(64),
            tracker: Tracker::default(),
            safe: VecDeque::new(),
            last_safe: 0,
            last_alt_screen_enter: None,
        }
    }

    /// Appends raw output, then trims the oldest bytes past the capacity.
    pub fn push(&mut self, bytes: &[u8]) {
        let newline_gap = (self.capacity / 16).min(256) as u64;
        let fallback_gap = (self.capacity / 4).min(64 << 10) as u64;
        let mut offset = self.end();
        for &byte in bytes {
            if let Some(enter) = self.tracker.step(byte, offset) {
                self.last_alt_screen_enter = Some(enter);
            }
            offset += 1;
            if self.tracker.is_safe() {
                let gap = offset - self.last_safe;
                if (byte == b'\n' && gap >= newline_gap) || gap >= fallback_gap {
                    self.safe.push_back(offset);
                    self.last_safe = offset;
                }
            }
        }
        self.buf.extend(bytes);
        self.trim();
    }

    /// Absolute offset of the oldest byte held.
    pub fn start(&self) -> u64 {
        self.start
    }

    /// Absolute offset just past the newest byte.
    pub fn end(&self) -> u64 {
        self.start + self.buf.len() as u64
    }

    /// Offset of the escape that last entered the alternate screen
    /// (`CSI ? 1049 h`, `? 1047 h` or `? 47 h`). When it is before
    /// [`start`](Self::start), the switch was trimmed and a raw replay would
    /// paint the full-screen program onto the main screen.
    pub fn last_alt_screen_enter(&self) -> Option<u64> {
        self.last_alt_screen_enter
    }

    /// The held bytes from `offset` (clamped to the held range) to the end, as
    /// at most two slices in order.
    pub fn bytes_since(&self, offset: u64) -> (&[u8], &[u8]) {
        let skip = usize::try_from(offset.saturating_sub(self.start))
            .unwrap_or(usize::MAX)
            .min(self.buf.len());
        let (a, b) = self.buf.as_slices();
        if skip <= a.len() {
            (&a[skip..], b)
        } else {
            (&b[skip - a.len()..], &[])
        }
    }

    /// Everything held, as at most two slices in order.
    pub fn contents(&self) -> (&[u8], &[u8]) {
        self.bytes_since(self.start)
    }

    fn trim(&mut self) {
        if self.buf.len() <= self.capacity {
            return;
        }
        let need = self.end() - self.capacity as u64;
        while self.safe.front().is_some_and(|&s| s < need) {
            self.safe.pop_front();
        }
        let cut = self.safe.front().copied().unwrap_or(need);
        let drop = usize::try_from(cut - self.start).unwrap_or(self.buf.len());
        self.buf.drain(..drop.min(self.buf.len()));
        self.start = cut;
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
enum State {
    #[default]
    Ground,
    Escape,
    EscapeIntermediate,
    Csi,
    /// OSC string: ends at BEL or ST.
    Osc,
    /// DCS, SOS, PM or APC string: ends at ST.
    String,
}

/// Byte-level escape-sequence and UTF-8 state, just enough to find safe cuts.
#[derive(Debug, Clone, Default)]
struct Tracker {
    state: State,
    utf8_left: u8,
    seq_start: u64,
    csi: [u8; 24],
    csi_len: usize,
}

impl Tracker {
    fn is_safe(&self) -> bool {
        self.state == State::Ground && self.utf8_left == 0
    }

    /// Advances over `byte` at absolute `offset`. Returns the start offset of
    /// an alternate-screen entry that this byte completed.
    fn step(&mut self, byte: u8, offset: u64) -> Option<u64> {
        // ESC, CAN and SUB act in every state.
        match byte {
            0x1b => {
                self.state = State::Escape;
                self.seq_start = offset;
                self.utf8_left = 0;
                return None;
            }
            0x18 | 0x1a => {
                self.state = State::Ground;
                self.utf8_left = 0;
                return None;
            }
            _ => {}
        }
        match self.state {
            State::Ground => {
                self.utf8_left = match byte {
                    0x80..=0xbf => self.utf8_left.saturating_sub(1),
                    0xc0..=0xdf => 1,
                    0xe0..=0xef => 2,
                    0xf0..=0xf7 => 3,
                    _ => 0,
                };
            }
            State::Escape => match byte {
                b'[' => {
                    self.state = State::Csi;
                    self.csi_len = 0;
                }
                b']' => self.state = State::Osc,
                b'P' | b'X' | b'^' | b'_' => self.state = State::String,
                0x20..=0x2f => self.state = State::EscapeIntermediate,
                0x30..=0x7e | 0x80..=0xff => self.state = State::Ground,
                _ => {}
            },
            State::EscapeIntermediate => {
                if matches!(byte, 0x30..=0x7e | 0x80..=0xff) {
                    self.state = State::Ground;
                }
            }
            State::Csi => match byte {
                0x20..=0x3f => {
                    if let Some(slot) = self.csi.get_mut(self.csi_len) {
                        *slot = byte;
                    }
                    self.csi_len = self.csi_len.saturating_add(1);
                }
                0x40..=0x7e => {
                    self.state = State::Ground;
                    if byte == b'h' && self.enters_alt_screen() {
                        return Some(self.seq_start);
                    }
                }
                0x80..=0xff => self.state = State::Ground,
                _ => {}
            },
            State::Osc => {
                if byte == 0x07 {
                    self.state = State::Ground;
                }
            }
            State::String => {}
        }
        None
    }

    /// Whether the collected CSI parameters are `? … 47 | 1047 | 1049 …`.
    fn enters_alt_screen(&self) -> bool {
        let Some(params) = self.csi.get(..self.csi_len) else {
            return false;
        };
        params.strip_prefix(b"?").is_some_and(|params| {
            params
                .split(|&b| b == b';')
                .any(|p| matches!(p, b"47" | b"1047" | b"1049"))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn held(ring: &Ring) -> Vec<u8> {
        let (a, b) = ring.contents();
        [a, b].concat()
    }

    #[test]
    fn trims_at_safe_offsets() {
        let line = |c: u8| {
            let mut l = vec![c; 63];
            l.push(b'\n');
            l
        };
        let lines: Vec<u8> = (b'a'..=b'j').flat_map(line).collect();
        let long_osc = [b"\x1b]0;".as_slice(), &[b'x'; 90], b"\n\x07"].concat();
        // (capacity, chunks, expected (start, end, held length))
        type Case = (usize, Vec<Vec<u8>>, (u64, u64, usize));
        let cases: Vec<Case> = vec![
            // Fits: nothing trimmed.
            (256, vec![b"hello\r\n".to_vec()], (0, 7, 7)),
            // Ten 64-byte lines into 256: newline gap is 16, so every line
            // end is safe, and the cut lands on a line start.
            (256, vec![lines.clone()], (384, 640, 256)),
            // The same, pushed a byte at a time.
            (
                256,
                lines.chunks(1).map(<[u8]>::to_vec).collect(),
                (384, 640, 256),
            ),
            // A `\n` inside an OSC is not safe; the cut waits for ground state.
            (
                100,
                vec![b"ab\n".to_vec(), long_osc.clone(), b"cd\nef\n".to_vec()],
                (99, 105, 6),
            ),
            // No newline at all: the fallback records ground boundaries every
            // capacity / 4 bytes, never inside the 3-byte "€".
            (64, vec!["€".repeat(40).into_bytes()], (72, 120, 48)),
        ];
        let got: Vec<_> = cases
            .iter()
            .map(|(capacity, chunks, _)| {
                let mut ring = Ring::with_capacity(*capacity);
                chunks.iter().for_each(|c| ring.push(c));
                (ring.start(), ring.end(), held(&ring).len())
            })
            .collect();
        let want: Vec<_> = cases.iter().map(|(_, _, w)| *w).collect();
        assert_eq!(got, want);
    }

    #[test]
    fn tracks_alt_screen_entry() {
        let filler = "x\n".repeat(100);
        // (chunks, capacity, expected (last entry, entry still held))
        type Case<'a> = (Vec<&'a str>, usize, (Option<u64>, bool));
        let cases: Vec<Case> = vec![
            (vec!["ab\x1b[?1049h"], 256, (Some(2), true)),
            (
                vec!["\x1b[?47h", "\x1b[?1049l", "\x1b[?1;1047h"],
                256,
                (Some(14), true),
            ),
            (vec!["\x1b[?1049", "h"], 256, (Some(0), true)),
            (
                vec!["\x1b[1049h\x1b[?25h\x1b]0;?1049h\x07"],
                256,
                (None, false),
            ),
            (vec!["\x1b[?1049h", &filler], 64, (Some(0), false)),
        ];
        let got: Vec<_> = cases
            .iter()
            .map(|(chunks, capacity, _)| {
                let mut ring = Ring::with_capacity(*capacity);
                chunks.iter().for_each(|c| ring.push(c.as_bytes()));
                let enter = ring.last_alt_screen_enter();
                (enter, enter.is_some_and(|e| e >= ring.start()))
            })
            .collect();
        let want: Vec<_> = cases.iter().map(|(_, _, w)| *w).collect();
        assert_eq!(got, want);
    }

    #[test]
    fn bytes_since_spans_both_halves() {
        let mut ring = Ring::with_capacity(64);
        for i in 0..20u8 {
            ring.push(&[b'a' + i % 26, b'\n']);
        }
        let joined = |(a, b): (&[u8], &[u8])| [a, b].concat();
        let (start, end) = (ring.start(), ring.end());
        let got = vec![
            joined(ring.bytes_since(0)),
            joined(ring.bytes_since(start + 3)),
            joined(ring.bytes_since(end)),
            joined(ring.bytes_since(end + 10)),
        ];
        let all = held(&ring);
        let want = vec![all.clone(), all[3..].to_vec(), vec![], vec![]];
        assert_eq!(got, want);
    }

    /// Deterministic pseudo-random fixture: output units that must never be
    /// split, pushed in random-size chunks into small rings. After every push,
    /// the ring must hold exactly the tail of the stream, start on a unit
    /// boundary, and stay within its capacity.
    #[test]
    fn cut_never_splits_a_unit() {
        let units: &[&[u8]] = &[
            b"a",
            b"Z",
            b" ",
            b"\n",
            b"\r",
            b"\n",
            "é".as_bytes(),
            "日".as_bytes(),
            "🎉".as_bytes(),
            b"\x1b[1;31m",
            b"\x1b[0m",
            b"\x1b[12;40H",
            b"\x1b[?1049h",
            b"\x1b[?1049l",
            b"\x1b]0;title with\nnewline\x07",
            b"\x1b]133;A\x1b\\",
            b"\x1b]7;file://h/tmp/x\x07",
            b"\x1bP+q544e\n\x07\x1b\\",
            b"\x1b_apc\npayload\x1b\\",
            b"\x1b(B",
            b"\x07",
        ];
        let mut seed: u64 = 0x9e37_79b9_7f4a_7c15;
        let mut next = move |n: usize| {
            seed = seed
                .wrapping_mul(6_364_136_223_846_793_005)
                .wrapping_add(1_442_695_040_888_963_407);
            (seed >> 33) as usize % n
        };
        let mut failures = Vec::new();
        for capacity in [64usize, 100, 257, 1000] {
            let mut stream = Vec::new();
            let mut boundaries = std::collections::BTreeSet::from([0u64]);
            for _ in 0..3000 {
                stream.extend_from_slice(units[next(units.len())]);
                boundaries.insert(stream.len() as u64);
            }
            let mut ring = Ring::with_capacity(capacity);
            let mut pushed = 0;
            while pushed < stream.len() {
                let len = (1 + next(40)).min(stream.len() - pushed);
                ring.push(&stream[pushed..pushed + len]);
                pushed += len;
                let start = ring.start();
                let ok = ring.end() == pushed as u64
                    && boundaries.contains(&start)
                    && held(&ring) == stream[start as usize..pushed]
                    && ring.end() - start <= capacity as u64;
                if !ok {
                    failures.push((capacity, pushed, start));
                }
            }
        }
        assert_eq!(failures, vec![]);
    }
}
