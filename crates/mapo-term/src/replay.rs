//! Replay helpers: removing terminal queries from recorded output before it is
//! replayed to a client.

/// Returns `bytes` without the terminal queries that would make a client answer
/// again when replayed (the answer would arrive as input, like a stray
/// `^[[24;1R` at the prompt). Everything else is kept byte for byte, including
/// incomplete sequences at the end.
///
/// Stripped: DSR and CPR (`CSI 5 n`, `CSI 6 n`, `CSI ? 6 n`); DA1, DA2, DA3
/// (`CSI c`, `CSI 0 c`, `CSI > c`, `CSI > 0 c`, `CSI = c`, `CSI = 0 c`); the
/// kitty keyboard query `CSI ? u`; XTVERSION `CSI > q` and `CSI > 0 q`; DECRQM
/// (`CSI ? Pn $ p`, `CSI Pn $ p`); window size reports `CSI 14 t`, `16 t`,
/// `18 t`; color queries `OSC 4 ; n ; ?` and `OSC 10..19 ; ?`; clipboard reads
/// `OSC 52 ; sel ; ?`; DECRQSS `DCS $ q … ST` and XTGETTCAP `DCS + q … ST`.
/// Only the live output reaches the emulator unstripped; use this for replays.
pub fn strip_queries(bytes: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == 0x1b
            && let Some(len) = query_len(&bytes[i..])
        {
            i += len;
            continue;
        }
        out.push(bytes[i]);
        i += 1;
    }
    out
}

/// The length of the query that starts `seq` (which starts with ESC), if it is one.
fn query_len(seq: &[u8]) -> Option<usize> {
    match seq.get(1)? {
        b'[' => {
            let body_len = seq[2..].iter().position(|b| !(0x20..=0x3f).contains(b))?;
            let final_at = 2 + body_len;
            let final_byte = *seq.get(final_at)?;
            is_csi_query(&seq[2..final_at], final_byte).then_some(final_at + 1)
        }
        b']' => {
            let body_len = seq[2..]
                .iter()
                .position(|&b| matches!(b, 0x07 | 0x18 | 0x1a | 0x1b))?;
            let end_at = 2 + body_len;
            let len = match seq.get(end_at..end_at + 2)? {
                [0x07, _] => end_at + 1,
                [0x1b, b'\\'] => end_at + 2,
                _ => return None,
            };
            is_osc_query(&seq[2..end_at]).then_some(len)
        }
        b'P' => {
            let body_len = seq[2..]
                .iter()
                .position(|&b| matches!(b, 0x18 | 0x1a | 0x1b))?;
            let st = 2 + body_len;
            if seq.get(st..st + 2)? != b"\x1b\\" {
                return None;
            }
            let body = &seq[2..st];
            (body.starts_with(b"$q") || body.starts_with(b"+q")).then_some(st + 2)
        }
        _ => None,
    }
}

fn is_csi_query(body: &[u8], final_byte: u8) -> bool {
    match final_byte {
        b'n' => matches!(body, b"5" | b"6" | b"?6"),
        b'c' => matches!(body, b"" | b"0" | b">" | b">0" | b"=" | b"=0"),
        b'u' => body == b"?",
        b'q' => matches!(body, b">" | b">0"),
        b't' => matches!(body, b"14" | b"16" | b"18"),
        b'p' => body
            .strip_suffix(b"$")
            .map(|mode| mode.strip_prefix(b"?").unwrap_or(mode))
            .is_some_and(|mode| !mode.is_empty() && mode.iter().all(u8::is_ascii_digit)),
        _ => false,
    }
}

fn is_osc_query(body: &[u8]) -> bool {
    let mut params = body.split(|&b| b == b';');
    let Some(number) = params.next() else {
        return false;
    };
    let rest: Vec<&[u8]> = params.collect();
    match number {
        // OSC 4 ; index ; spec [; index ; spec …]: every spec is `?`.
        b"4" => {
            !rest.is_empty()
                && rest.len().is_multiple_of(2)
                && rest.chunks(2).all(|pair| pair[1] == b"?")
        }
        // OSC 52 ; selection ; ?
        b"52" => rest.len() == 2 && rest[1] == b"?",
        // Dynamic colors OSC 10..19: every parameter is `?`.
        [b'1', b'0'..=b'9'] => !rest.is_empty() && rest.iter().all(|p| *p == b"?"),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_queries_only() {
        let cases: &[(&[u8], &[u8])] = &[
            (b"a\x1b[6nb\x1b[5nc\x1b[?6n", b"abc"),
            (b"\x1b[c\x1b[0c\x1b[>c\x1b[>0c\x1b[=c\x1b[=0cx", b"x"),
            (b"\x1b[?u\x1b[>q\x1b[>0qx", b"x"),
            (b"\x1b[?2026$p\x1b[4$p\x1b[14t\x1b[18tx", b"x"),
            (
                b"\x1b]10;?\x07\x1b]11;?\x1b\\\x1b]12;?\x07\x1b]10;?;?\x07x",
                b"x",
            ),
            (b"\x1b]4;1;?\x07\x1b]4;1;?;2;?\x1b\\\x1b]52;c;?\x07x", b"x"),
            (b"\x1bP$qm\x1b\\\x1bP+q544e;636f6c73\x1b\\x", b"x"),
            // Kept: SGR, cursor moves, modes, marks, titles, color sets, DCS data.
            (
                b"\x1b[1;31mred\x1b[0m\x1b[12;40H\x1b[?1049h\x1b[?2004h\x1b[2 q\x1b[>4;1m",
                b"\x1b[1;31mred\x1b[0m\x1b[12;40H\x1b[?1049h\x1b[?2004h\x1b[2 q\x1b[>4;1m",
            ),
            (
                b"\x1b]133;A\x07\x1b]0;?\x07\x1b]11;rgb:0/0/0\x07\x1b]4;1;?;2;#fff\x07",
                b"\x1b]133;A\x07\x1b]0;?\x07\x1b]11;rgb:0/0/0\x07\x1b]4;1;?;2;#fff\x07",
            ),
            (
                b"\x1b[6;1n\x1b[1c\x1b[8;24;80t\x1b[$p\x1bP1$r0m\x1b\\\x1b]52;c;aGk=\x07",
                b"\x1b[6;1n\x1b[1c\x1b[8;24;80t\x1b[$p\x1bP1$r0m\x1b\\\x1b]52;c;aGk=\x07",
            ),
            // UTF-8 and incomplete sequences at the end stay.
            ("é\x1b[6n日".as_bytes(), "é日".as_bytes()),
            (b"x\x1b[6", b"x\x1b[6"),
            (b"x\x1b]11;?", b"x\x1b]11;?"),
            (b"x\x1bP$qm", b"x\x1bP$qm"),
            // An OSC cut short by ESC is not a query; the next sequence still is.
            (b"\x1b]11;?\x1b[6n", b"\x1b]11;?"),
            (b"\x1bP$qm\x1b[6n\x1b\\", b"\x1bP$qm\x1b\\"),
        ];
        let got: Vec<_> = cases
            .iter()
            .map(|(input, _)| strip_queries(input))
            .collect();
        let want: Vec<_> = cases.iter().map(|(_, want)| want.to_vec()).collect();
        assert_eq!(got, want);
    }
}
