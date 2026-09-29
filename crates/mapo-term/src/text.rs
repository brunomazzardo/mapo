//! The text stream: a bounded, append-only log of the plain text a tab printed,
//! addressed by absolute byte offsets, plus the literal matcher behind
//! `tab wait --until PATTERN`.

/// Default bound of a [`TextStream`]: 1 MiB of UTF-8 text.
pub const DEFAULT_TEXT_CAPACITY: usize = 1 << 20;

/// Append-only text log with absolute byte offsets.
///
/// It holds printed characters, `\n` and `\t`. A `\r` becomes a line break,
/// and any `\r` or `\n` that directly follows a `\r` is dropped, so `\r\n`
/// folds to one `\n` and a lone `\r` (a progress-bar redraw) still separates
/// lines. Offsets count UTF-8 bytes from the first character ever pushed and
/// never go backwards. When the log grows past its capacity, the oldest text is
/// trimmed at a character boundary.
#[derive(Debug, Clone)]
pub struct TextStream {
    buf: String,
    start: u64,
    capacity: usize,
    after_cr: bool,
}

impl Default for TextStream {
    fn default() -> Self {
        Self::new()
    }
}

impl TextStream {
    /// An empty stream bounded to [`DEFAULT_TEXT_CAPACITY`].
    pub fn new() -> Self {
        Self::with_capacity(DEFAULT_TEXT_CAPACITY)
    }

    /// An empty stream that keeps about `capacity` bytes (at least 16).
    pub fn with_capacity(capacity: usize) -> Self {
        Self {
            buf: String::new(),
            start: 0,
            capacity: capacity.max(16),
            after_cr: false,
        }
    }

    /// Appends one character, applying the `\r` folding described on the type.
    pub fn push(&mut self, c: char) {
        match c {
            '\r' => {
                if !self.after_cr {
                    self.buf.push('\n');
                }
                self.after_cr = true;
            }
            '\n' => {
                if !self.after_cr {
                    self.buf.push('\n');
                }
                self.after_cr = false;
            }
            c => {
                self.buf.push(c);
                self.after_cr = false;
            }
        }
        if self.buf.len() > self.capacity {
            self.trim();
        }
    }

    /// Absolute offset of the oldest byte still held.
    pub fn start(&self) -> u64 {
        self.start
    }

    /// Absolute offset just past the newest byte; the offset the next character gets.
    pub fn end(&self) -> u64 {
        self.start + self.buf.len() as u64
    }

    /// The text from `offset` to the end. An offset before [`start`](Self::start)
    /// is clamped to it, and one inside a character moves to the next character.
    pub fn since(&self, offset: u64) -> &str {
        self.between(offset, self.end())
    }

    /// The text between two absolute offsets, clamped like [`since`](Self::since).
    pub fn between(&self, from: u64, to: u64) -> &str {
        let from = self.relative(from);
        let to = self.relative(to).max(from);
        self.buf.get(from..to).unwrap_or_default()
    }

    /// Relative index of an absolute offset, clamped and moved to a char boundary.
    fn relative(&self, offset: u64) -> usize {
        let rel = usize::try_from(offset.saturating_sub(self.start)).unwrap_or(usize::MAX);
        self.buf.ceil_char_boundary(rel.min(self.buf.len()))
    }

    /// Drops the oldest text, leaving an eighth of the capacity free so trimming
    /// is not repeated on every push.
    fn trim(&mut self) {
        let excess = self.buf.len() - self.capacity + self.capacity / 8;
        let cut = self.buf.ceil_char_boundary(excess.min(self.buf.len()));
        self.buf.drain(..cut);
        self.start += cut as u64;
    }
}

/// Where a [`Matcher`] starts looking.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Start {
    /// Match anywhere after the start offset.
    AtOffset,
    /// Skip past the first occurrence of this sent text (its echo) after the
    /// start offset, then match. Line endings in it are folded like the stream.
    AfterEcho(String),
}

/// Incremental literal substring match on a [`TextStream`], for `tab wait --until`.
///
/// Call [`poll`](Self::poll) after each chunk. It rescans only the tail that could
/// still hold a match, so polling is cheap on long output.
#[derive(Debug, Clone)]
pub struct Matcher {
    pattern: String,
    scan_from: u64,
    echo: Option<String>,
}

impl Matcher {
    /// A matcher for `pattern` in the text after the absolute offset `from`.
    pub fn new(pattern: impl Into<String>, from: u64, start: Start) -> Self {
        let echo = match start {
            Start::AtOffset => None,
            Start::AfterEcho(sent) => Some(fold_line_endings(&sent)).filter(|e| !e.is_empty()),
        };
        Self {
            pattern: pattern.into(),
            scan_from: from,
            echo,
        }
    }

    /// The absolute offset where the pattern starts, once it has printed.
    pub fn poll(&mut self, text: &TextStream) -> Option<u64> {
        if let Some(echo) = &self.echo {
            match find(text, self.scan_from, echo) {
                Ok(at) => {
                    self.scan_from = at + echo.len() as u64;
                    self.echo = None;
                }
                Err(next) => {
                    self.scan_from = next;
                    return None;
                }
            }
        }
        match find(text, self.scan_from, &self.pattern) {
            Ok(at) => Some(at),
            Err(next) => {
                self.scan_from = next;
                None
            }
        }
    }
}

/// Finds `needle` after `from`: `Ok(match offset)`, or `Err(offset to resume from)`.
fn find(text: &TextStream, from: u64, needle: &str) -> Result<u64, u64> {
    let hay = text.since(from);
    let hay_start = text.end() - hay.len() as u64;
    match hay.find(needle) {
        Some(i) => Ok(hay_start + i as u64),
        None => {
            let keep = needle.len().saturating_sub(1);
            let resume = hay.floor_char_boundary(hay.len().saturating_sub(keep));
            Err(hay_start + resume as u64)
        }
    }
}

/// Folds the sent text like the stream does, and drops the trailing Enter.
fn fold_line_endings(sent: &str) -> String {
    let mut stream = TextStream::with_capacity(usize::MAX);
    sent.chars().for_each(|c| stream.push(c));
    stream.since(0).trim_end_matches('\n').to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stream(chunks: &[&str], capacity: usize) -> TextStream {
        let mut text = TextStream::with_capacity(capacity);
        chunks
            .iter()
            .flat_map(|c| c.chars())
            .for_each(|c| text.push(c));
        text
    }

    #[test]
    fn push_folds_carriage_returns_and_trims() {
        // (input, capacity, expected (start, end, held text))
        let cases: &[(&str, usize, (u64, u64, &str))] = &[
            ("a\r\nb\n", 64, (0, 4, "a\nb\n")),
            ("50%\r60%\r\n", 64, (0, 8, "50%\n60%\n")),
            ("x\r\r\ny\n\n", 64, (0, 5, "x\ny\n\n")),
            ("tab\there", 64, (0, 8, "tab\there")),
            // 20 bytes into capacity 16: trims 20 - 16 + 2 = 6 bytes.
            ("0123456789abcdefghij", 16, (6, 20, "6789abcdefghij")),
            // 18 bytes into capacity 17: the 3-byte cut moves to 4.
            ("éééééééééé", 17, (4, 20, "éééééééé")),
        ];
        let got: Vec<_> = cases
            .iter()
            .map(|(input, capacity, _)| {
                let text = stream(&[input], *capacity);
                (text.start(), text.end(), text.since(0).to_owned())
            })
            .collect();
        let want: Vec<_> = cases
            .iter()
            .map(|(_, _, (s, e, t))| (*s, *e, (*t).to_owned()))
            .collect();
        assert_eq!(got, want);
    }

    #[test]
    fn since_and_between_clamp() {
        let text = stream(&["héllo\nworld"], 64);
        // (from, to, expected)
        let cases: &[(u64, u64, &str)] = &[
            (0, 100, "héllo\nworld"),
            (2, 100, "llo\nworld"), // 2 is inside "é", moves to 3
            (7, 9, "wo"),
            (9, 7, ""),
            (50, 60, ""),
        ];
        let got: Vec<_> = cases.iter().map(|(f, t, _)| text.between(*f, *t)).collect();
        let want: Vec<_> = cases.iter().map(|(_, _, w)| *w).collect();
        assert_eq!(got, want);
    }

    #[test]
    fn matcher_skips_the_echo() {
        // (chunks printed one poll at a time, pattern, from, start, poll results)
        type Case<'a> = (&'a [&'a str], &'a str, u64, Start, Vec<Option<u64>>);
        let cases: Vec<Case> = vec![
            // The pattern appears only in the echo: never matches.
            (
                &["$ sleep 3 # ONLY", "ECHO\r\n", "\r\n"],
                "ONLYECHO",
                0,
                Start::AfterEcho("sleep 3 # ONLYECHO\r".into()),
                vec![None, None, None],
            ),
            // Real output after the echo matches.
            (
                &["$ echo MARK-$((40+2))\r\n", "MARK-4", "2\r\n"],
                "MARK-42",
                0,
                Start::AfterEcho("echo MARK-$((40+2))".into()),
                vec![None, None, Some(22)],
            ),
            // The echo itself contains the pattern, and the output repeats it.
            (
                &["$ echo ONLYECHO\r\n", "ONLYECHO\r\n"],
                "ONLYECHO",
                0,
                Start::AfterEcho("echo ONLYECHO\r".into()),
                vec![None, Some(16)],
            ),
            // Without echo skipping, the echo satisfies the wait.
            (
                &["$ echo hi", "\r\nhi\r\n"],
                "hi",
                0,
                Start::AtOffset,
                vec![Some(7), Some(7)],
            ),
            // Text before the start offset is ignored; a match split across polls.
            (
                &["old ab", "c a", "bc\n"],
                "abc",
                7,
                Start::AtOffset,
                vec![None, None, Some(8)],
            ),
        ];
        let got: Vec<_> = cases
            .iter()
            .map(|(chunks, pattern, from, start, _)| {
                let mut text = TextStream::new();
                let mut matcher = Matcher::new(*pattern, *from, start.clone());
                chunks
                    .iter()
                    .map(|chunk| {
                        chunk.chars().for_each(|c| text.push(c));
                        matcher.poll(&text)
                    })
                    .collect::<Vec<_>>()
            })
            .collect();
        let want: Vec<_> = cases.into_iter().map(|(_, _, _, _, w)| w).collect();
        assert_eq!(got, want);
    }
}
