//! The OSC pre-parser: turns a tab's output bytes into shell-integration facts
//! (cwd, prompt marks, title, notifications, bell) and feeds the text stream.

use alacritty_terminal::vte::{Parser, Perform};

use crate::text::TextStream;

/// An OSC 133 prompt mark.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mark {
    /// Prompt start.
    A,
    /// Prompt end; command input starts.
    B,
    /// Command output starts.
    C,
    /// Command finished, with its exit code when the shell sent one.
    D { exit_code: Option<i32> },
}

/// Which OSC a notification came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NotifyKind {
    /// OSC 9 (iTerm2 style).
    Nine,
    /// OSC 777 (rxvt style, `notify;title;body`).
    SevenSevenSeven,
}

/// Something the shell or a program told the terminal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Fact {
    /// OSC 7: the percent-decoded path of a `file://host/path` URL.
    Cwd(String),
    /// OSC 133 prompt mark.
    Mark(Mark),
    /// OSC 0 or 2 window title.
    Title(String),
    /// OSC 9 or 777. `body` is every parameter after the OSC number, joined with `;`.
    Notify { kind: NotifyKind, body: String },
    /// BEL outside an escape sequence.
    Bell,
}

/// A fact and its position in the text stream: `text_offset` is
/// [`TextStream::end`] when the fact arrived, so the text printed after it is
/// `text().since(text_offset)`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FactAt {
    pub text_offset: u64,
    pub fact: Fact,
}

/// Long-lived parser for one tab. Keep it for the tab's lifetime so sequences
/// and UTF-8 characters split across reads still parse.
pub struct Preparser {
    parser: Parser,
    sink: Sink,
}

impl Default for Preparser {
    fn default() -> Self {
        Self::new()
    }
}

impl Preparser {
    /// A pre-parser whose text stream has the default capacity.
    pub fn new() -> Self {
        Self::with_text(TextStream::new())
    }

    /// A pre-parser that appends to the given text stream.
    pub fn with_text(text: TextStream) -> Self {
        Self {
            parser: Parser::new(),
            sink: Sink {
                text,
                facts: Vec::new(),
            },
        }
    }

    /// Parses one chunk of PTY output, appends its text to the stream, and
    /// returns the facts it completed, in order.
    pub fn advance(&mut self, chunk: &[u8]) -> Vec<FactAt> {
        self.parser.advance(&mut self.sink, chunk);
        std::mem::take(&mut self.sink.facts)
    }

    /// The text stream fed by [`advance`](Self::advance).
    pub fn text(&self) -> &TextStream {
        &self.sink.text
    }
}

struct Sink {
    text: TextStream,
    facts: Vec<FactAt>,
}

impl Sink {
    fn push_fact(&mut self, fact: Fact) {
        self.facts.push(FactAt {
            text_offset: self.text.end(),
            fact,
        });
    }
}

impl Perform for Sink {
    fn print(&mut self, c: char) {
        self.text.push(c);
    }

    fn execute(&mut self, byte: u8) {
        // vte never calls `execute` for the BEL that terminates an OSC.
        match byte {
            0x07 => self.push_fact(Fact::Bell),
            b'\n' | b'\r' | b'\t' => self.text.push(char::from(byte)),
            _ => {}
        }
    }

    fn osc_dispatch(&mut self, params: &[&[u8]], _bell_terminated: bool) {
        if let Some(fact) = osc_fact(params) {
            self.push_fact(fact);
        }
    }
}

fn osc_fact(params: &[&[u8]]) -> Option<Fact> {
    let (number, rest) = params.split_first()?;
    match *number {
        b"7" => cwd(&join(rest)).map(Fact::Cwd),
        b"133" => mark(rest).map(Fact::Mark),
        b"0" | b"2" => Some(Fact::Title(lossy(&join(rest)))),
        b"9" => Some(Fact::Notify {
            kind: NotifyKind::Nine,
            body: lossy(&join(rest)),
        }),
        b"777" => Some(Fact::Notify {
            kind: NotifyKind::SevenSevenSeven,
            body: lossy(&join(rest)),
        }),
        _ => None,
    }
}

/// Re-joins the parameters vte split at `;`.
fn join(params: &[&[u8]]) -> Vec<u8> {
    params.join(&b';')
}

fn lossy(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

/// The path of a `file://host/path` URL, percent-decoded.
fn cwd(url: &[u8]) -> Option<String> {
    let rest = url.strip_prefix(b"file://")?;
    let slash = rest.iter().position(|&b| b == b'/')?;
    let path = percent_decode(&rest[slash..]);
    Some(lossy(&path))
}

fn percent_decode(bytes: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let decoded = match bytes[i..] {
            [b'%', hi, lo, ..] => hex(hi).zip(hex(lo)).map(|(h, l)| h << 4 | l),
            _ => None,
        };
        match decoded {
            Some(byte) => {
                out.push(byte);
                i += 3;
            }
            None => {
                out.push(bytes[i]);
                i += 1;
            }
        }
    }
    out
}

fn hex(b: u8) -> Option<u8> {
    char::from(b)
        .to_digit(16)
        .and_then(|d| u8::try_from(d).ok())
}

fn mark(params: &[&[u8]]) -> Option<Mark> {
    match *params.first()? {
        b"A" => Some(Mark::A),
        b"B" => Some(Mark::B),
        b"C" => Some(Mark::C),
        b"D" => Some(Mark::D {
            exit_code: params
                .get(1)
                .and_then(|code| std::str::from_utf8(code).ok())
                .and_then(|code| code.parse().ok()),
        }),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(text_offset: u64, fact: Fact) -> FactAt {
        FactAt { text_offset, fact }
    }

    fn run(chunks: &[&[u8]]) -> (Vec<FactAt>, String) {
        let mut pre = Preparser::new();
        let facts = chunks.iter().flat_map(|c| pre.advance(c)).collect();
        (facts, pre.text().since(0).to_owned())
    }

    #[test]
    fn facts_from_sequences() {
        let cases: Vec<(&[u8], Vec<FactAt>)> = vec![
            (
                b"\x1b]7;file://mac.local/Users/me/My%20Dir\x07",
                vec![at(0, Fact::Cwd("/Users/me/My Dir".into()))],
            ),
            (
                b"\x1b]7;file:///tmp/a;b%3Bc%e2%9c%93%zz\x1b\\",
                vec![at(0, Fact::Cwd("/tmp/a;b;c\u{2713}%zz".into()))],
            ),
            (b"\x1b]7;http://x/y\x07\x1b]7;file://host\x07", vec![]),
            (
                b"\x1b]133;A\x07$ \x1b]133;B\x07ls\r\n\x1b]133;C\x1b\\out\r\n\x1b]133;D;2\x07",
                vec![
                    at(0, Fact::Mark(Mark::A)),
                    at(2, Fact::Mark(Mark::B)),
                    at(5, Fact::Mark(Mark::C)),
                    at(9, Fact::Mark(Mark::D { exit_code: Some(2) })),
                ],
            ),
            (
                b"\x1b]133;D\x07\x1b]133;D;x\x07\x1b]133;A;cl=m\x07\x1b]133;Z\x07",
                vec![
                    at(0, Fact::Mark(Mark::D { exit_code: None })),
                    at(0, Fact::Mark(Mark::D { exit_code: None })),
                    at(0, Fact::Mark(Mark::A)),
                ],
            ),
            (
                b"\x1b]0;a;b\x07\x1b]2;\xe2\x9c\x93 vim\x1b\\\x1b]1;icon\x07",
                vec![
                    at(0, Fact::Title("a;b".into())),
                    at(0, Fact::Title("\u{2713} vim".into())),
                ],
            ),
            (
                b"\x1b]9;done\x07\x1b]777;notify;Claude;needs input\x1b\\",
                vec![
                    at(
                        0,
                        Fact::Notify {
                            kind: NotifyKind::Nine,
                            body: "done".into(),
                        },
                    ),
                    at(
                        0,
                        Fact::Notify {
                            kind: NotifyKind::SevenSevenSeven,
                            body: "notify;Claude;needs input".into(),
                        },
                    ),
                ],
            ),
            // BEL rings in ground and inside CSI, never when it ends an OSC or sits in a DCS.
            (
                b"a\x07b\x1b]0;t\x07\x1bP1$r\x07\x1b\\\x1b[\x071m",
                vec![
                    at(1, Fact::Bell),
                    at(2, Fact::Title("t".into())),
                    at(2, Fact::Bell),
                ],
            ),
        ];
        let got: Vec<_> = cases.iter().map(|(input, _)| run(&[input]).0).collect();
        let want: Vec<_> = cases.into_iter().map(|(_, want)| want).collect();
        assert_eq!(got, want);
    }

    #[test]
    fn text_stream_gets_printed_text() {
        let cases: &[(&[u8], &str)] = &[
            (b"hi\r\nthere\n", "hi\nthere\n"),
            (b"\x1b[1;31mred\x1b[0m\ta\x08b", "red\tab"),
            (b"\x1b]0;title\x07x\x1bP+q544e\x1b\\y", "xy"),
            (b"caf\xc3\xa9 \xf0\x9f\x8e\x89", "caf\u{e9} \u{1f389}"),
        ];
        let got: Vec<_> = cases.iter().map(|(input, _)| run(&[input]).1).collect();
        let want: Vec<_> = cases.iter().map(|(_, want)| (*want).to_owned()).collect();
        assert_eq!(got, want);
    }

    #[test]
    fn split_at_every_byte_parses_the_same() {
        let fixture: &[u8] = b"\x1b]7;file://h/Users/me/caf%C3%A9\x1b\\\
            \x1b]2;~/caf\xc3\xa9\x07\x1b]133;A\x07\xe2\x9d\xaf \x1b]133;B\x07make\r\n\
            \x1b]133;C\x07\x1b]2;make\x07\x1b[32mok \xf0\x9f\x8e\x89\x1b[0m\r\n\x07\
            \x1b]9;built\x1b\\\x1b]777;notify;t;b\x07\x1b]133;D;0\x07";
        let whole = run(&[fixture]);
        let mut cuts: Vec<_> = (0..=fixture.len())
            .map(|i| run(&[&fixture[..i], &fixture[i..]]))
            .collect();
        cuts.push(run(&fixture.chunks(1).collect::<Vec<_>>()));
        let want = vec![whole.clone(); fixture.len() + 2];
        assert_eq!(cuts, want);
        // Guard against a vacuous fixture.
        assert_eq!(whole.0.len(), 10);
    }
}
