//! Attach frames (PROTOCOL §8): `kind:u8 | length:u32 BE | payload`, payload at most 64 KiB.

pub const MAX_PAYLOAD: usize = 65_536;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Frame {
    Out(Vec<u8>),
    In(Vec<u8>),
    Resize {
        cols: u16,
        rows: u16,
        width_px: u16,
        height_px: u16,
    },
    ReplayBegin,
    ReplayEnd,
    Exit(i32),
    Ping,
    Pong,
    Detach,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum FrameError {
    #[error("unknown attach frame kind {0:#04x}")]
    UnknownKind(u8),
    #[error("attach frame payload of {0} bytes exceeds 64 KiB")]
    TooLarge(usize),
    #[error("malformed {0} frame")]
    Malformed(&'static str),
}

impl Frame {
    fn kind(&self) -> u8 {
        match self {
            Self::Out(_) => 0x01,
            Self::In(_) => 0x02,
            Self::Resize { .. } => 0x03,
            Self::ReplayBegin => 0x04,
            Self::ReplayEnd => 0x05,
            Self::Exit(_) => 0x06,
            Self::Ping => 0x07,
            Self::Pong => 0x08,
            Self::Detach => 0x09,
        }
    }

    /// Appends the encoded frame to `out`. Data larger than 64 KiB must go through [`encode_data`].
    pub fn encode_into(&self, out: &mut Vec<u8>) {
        let payload: Vec<u8> = match self {
            Self::Out(b) | Self::In(b) => b.clone(),
            Self::Resize {
                cols,
                rows,
                width_px,
                height_px,
            } => [*cols, *rows, *width_px, *height_px]
                .iter()
                .flat_map(|v| v.to_be_bytes())
                .collect(),
            Self::Exit(code) => code.to_be_bytes().to_vec(),
            _ => Vec::new(),
        };
        out.push(self.kind());
        out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        out.extend_from_slice(&payload);
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        self.encode_into(&mut out);
        out
    }
}

/// Encodes terminal bytes as OUT (or IN) frames of at most 64 KiB each.
pub fn encode_data(input: bool, data: &[u8], out: &mut Vec<u8>) {
    for chunk in data.chunks(MAX_PAYLOAD) {
        let f = if input {
            Frame::In(chunk.to_vec())
        } else {
            Frame::Out(chunk.to_vec())
        };
        f.encode_into(out);
    }
}

/// An incremental decoder: feed bytes as they arrive, take whole frames out.
#[derive(Debug, Default)]
pub struct FrameDecoder {
    buf: Vec<u8>,
}

impl FrameDecoder {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn push(&mut self, bytes: &[u8]) {
        self.buf.extend_from_slice(bytes);
    }

    /// The next complete frame, `Ok(None)` when more bytes are needed.
    pub fn next_frame(&mut self) -> Result<Option<Frame>, FrameError> {
        if self.buf.len() < 5 {
            return Ok(None);
        }
        let kind = self.buf[0];
        let len = u32::from_be_bytes([self.buf[1], self.buf[2], self.buf[3], self.buf[4]]) as usize;
        if len > MAX_PAYLOAD {
            return Err(FrameError::TooLarge(len));
        }
        if self.buf.len() < 5 + len {
            return Ok(None);
        }
        let payload: Vec<u8> = self.buf[5..5 + len].to_vec();
        self.buf.drain(..5 + len);
        let u16_at = |i: usize| u16::from_be_bytes([payload[i], payload[i + 1]]);
        let frame = match kind {
            0x01 => Frame::Out(payload),
            0x02 => Frame::In(payload),
            0x03 if payload.len() == 8 => Frame::Resize {
                cols: u16_at(0),
                rows: u16_at(2),
                width_px: u16_at(4),
                height_px: u16_at(6),
            },
            0x03 => return Err(FrameError::Malformed("RESIZE")),
            0x04 => Frame::ReplayBegin,
            0x05 => Frame::ReplayEnd,
            0x06 if payload.len() == 4 => Frame::Exit(i32::from_be_bytes([
                payload[0], payload[1], payload[2], payload[3],
            ])),
            0x06 => return Err(FrameError::Malformed("EXIT")),
            0x07 => Frame::Ping,
            0x08 => Frame::Pong,
            0x09 => Frame::Detach,
            other => return Err(FrameError::UnknownKind(other)),
        };
        Ok(Some(frame))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn all() -> Vec<Frame> {
        vec![
            Frame::Out(b"hello\x1b[31m".to_vec()),
            Frame::In(vec![3]),
            Frame::Resize {
                cols: 120,
                rows: 40,
                width_px: 1680,
                height_px: 1120,
            },
            Frame::ReplayBegin,
            Frame::Out(vec![]),
            Frame::ReplayEnd,
            Frame::Exit(-1),
            Frame::Ping,
            Frame::Pong,
            Frame::Detach,
        ]
    }

    #[test]
    fn round_trip_split_at_every_size() {
        let mut wire = Vec::new();
        for f in all() {
            f.encode_into(&mut wire);
        }
        for step in 1..=wire.len() {
            let mut d = FrameDecoder::new();
            let mut got = Vec::new();
            for chunk in wire.chunks(step) {
                d.push(chunk);
                while let Some(f) = d.next_frame().unwrap() {
                    got.push(f);
                }
            }
            assert_eq!(got, all(), "chunk size {step}");
        }
    }

    #[test]
    fn large_data_and_bad_input() {
        let mut wire = Vec::new();
        encode_data(false, &vec![7u8; MAX_PAYLOAD * 2 + 5], &mut wire);
        let mut d = FrameDecoder::new();
        d.push(&wire);
        let mut sizes = Vec::new();
        while let Some(Frame::Out(b)) = d.next_frame().unwrap() {
            sizes.push(b.len());
        }
        assert_eq!(sizes, vec![MAX_PAYLOAD, MAX_PAYLOAD, 5]);
        let errs: Vec<FrameError> = [
            vec![0x10, 0, 0, 0, 0],
            vec![0x01, 0, 2, 0, 1],
            vec![0x03, 0, 0, 0, 1, 0],
        ]
        .into_iter()
        .map(|b| {
            let mut d = FrameDecoder::new();
            d.push(&b);
            d.next_frame().unwrap_err()
        })
        .collect();
        assert_eq!(
            errs,
            vec![
                FrameError::UnknownKind(0x10),
                FrameError::TooLarge(131_073),
                FrameError::Malformed("RESIZE")
            ]
        );
    }
}
