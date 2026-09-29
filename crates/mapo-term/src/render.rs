//! Replay payloads for `mapo attach` (PLAN T0.6 steps 6–7): raw replay from the byte ring, grid
//! replay rendered from the emulator, and the mode trailer both end with.

use std::fmt::Write as _;

use alacritty_terminal::event::EventListener;
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::index::{Column, Line};
use alacritty_terminal::term::cell::{Cell, Flags};
use alacritty_terminal::term::{Term, TermMode};
use alacritty_terminal::vte::ansi::{Color, NamedColor};

/// How a reattaching client gets its screen back.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReplayStrategy {
    /// Replay the raw byte ring, queries stripped.
    Raw,
    /// Render the emulator's grid as escape sequences.
    Grid,
}

impl ReplayStrategy {
    /// `MAPO_REPLAY=grid|raw`, default raw.
    pub fn from_env() -> Self {
        match std::env::var("MAPO_REPLAY").as_deref() {
            Ok("grid") => Self::Grid,
            _ => Self::Raw,
        }
    }
}

/// Reset the client and clear its scrollback.
pub const RESET: &[u8] = b"\x1bc\x1b[3J";

/// Restores the modes a program set, and the cursor. Never re-enters the alternate screen.
pub fn trailer<T: EventListener>(term: &Term<T>) -> Vec<u8> {
    let mode = term.mode();
    let mut s = String::new();
    let set = |s: &mut String, on: bool, n: &str| {
        let _ = write!(s, "\x1b[?{n}{}", if on { 'h' } else { 'l' });
    };
    set(&mut s, mode.contains(TermMode::APP_CURSOR), "1");
    set(&mut s, mode.contains(TermMode::BRACKETED_PASTE), "2004");
    set(&mut s, mode.contains(TermMode::FOCUS_IN_OUT), "1004");
    set(&mut s, mode.contains(TermMode::MOUSE_REPORT_CLICK), "1000");
    set(&mut s, mode.contains(TermMode::MOUSE_DRAG), "1002");
    set(&mut s, mode.contains(TermMode::MOUSE_MOTION), "1003");
    set(&mut s, mode.contains(TermMode::SGR_MOUSE), "1006");
    s.push_str(if mode.contains(TermMode::APP_KEYPAD) {
        "\x1b="
    } else {
        "\x1b>"
    });
    let cursor = term.grid().cursor.point;
    let _ = write!(
        s,
        "\x1b[{};{}H",
        cursor.line.0.max(0) + 1,
        cursor.column.0 + 1
    );
    set(&mut s, mode.contains(TermMode::SHOW_CURSOR), "25");
    s.into_bytes()
}

fn color(out: &mut String, c: Color, fg: bool) {
    let base = if fg { 30 } else { 40 };
    match c {
        Color::Named(n) => {
            let i = n as usize;
            if i < 8 {
                let _ = write!(out, ";{}", base + i);
            } else if i < 16 {
                let _ = write!(out, ";{}", base + 60 + i - 8);
            } else if matches!(n, NamedColor::Foreground | NamedColor::Background) {
            } else if let Some(i) = dim_index(n) {
                let _ = write!(out, ";{}", base + i);
            }
        }
        Color::Indexed(i) => {
            let _ = write!(out, ";{};5;{i}", base + 8);
        }
        Color::Spec(rgb) => {
            let _ = write!(out, ";{};2;{};{};{}", base + 8, rgb.r, rgb.g, rgb.b);
        }
    }
}

fn dim_index(n: NamedColor) -> Option<usize> {
    Some(match n {
        NamedColor::DimBlack => 0,
        NamedColor::DimRed => 1,
        NamedColor::DimGreen => 2,
        NamedColor::DimYellow => 3,
        NamedColor::DimBlue => 4,
        NamedColor::DimMagenta => 5,
        NamedColor::DimCyan => 6,
        NamedColor::DimWhite => 7,
        _ => return None,
    })
}

fn sgr(cell: &Cell) -> String {
    let mut s = String::from("\x1b[0");
    let f = cell.flags;
    for (flag, code) in [
        (Flags::BOLD, "1"),
        (Flags::DIM, "2"),
        (Flags::ITALIC, "3"),
        (Flags::UNDERLINE, "4"),
        (Flags::INVERSE, "7"),
        (Flags::HIDDEN, "8"),
        (Flags::STRIKEOUT, "9"),
    ] {
        if f.contains(flag) {
            s.push(';');
            s.push_str(code);
        }
    }
    color(&mut s, cell.fg, true);
    color(&mut s, cell.bg, false);
    s.push('m');
    s
}

/// Renders the last `history` scrollback rows and the screen, row by row.
pub fn grid<T: EventListener>(term: &Term<T>, history: usize) -> Vec<u8> {
    let g = term.grid();
    let mut s = String::new();
    let alt = term.mode().contains(TermMode::ALT_SCREEN);
    if alt {
        s.push_str("\x1b[?1049h\x1b[H\x1b[2J");
    }
    let top = if alt {
        0
    } else {
        -(g.history_size().min(history) as i32)
    };
    let bottom = g.screen_lines() as i32 - 1;
    let cols = g.columns();
    let mut last_sgr = String::new();
    for l in top..=bottom {
        if l > top {
            s.push_str("\r\n");
        }
        let row = &g[Line(l)];
        let mut end = cols;
        while end > 0
            && row[Column(end - 1)].c == ' '
            && row[Column(end - 1)].bg == Color::Named(NamedColor::Background)
        {
            end -= 1;
        }
        for c in 0..end {
            let cell = &row[Column(c)];
            if cell
                .flags
                .intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER)
            {
                continue;
            }
            let attrs = sgr(cell);
            if attrs != last_sgr {
                s.push_str(&attrs);
                last_sgr = attrs;
            }
            s.push(cell.c);
            if let Some(zw) = cell.zerowidth() {
                s.extend(zw);
            }
        }
        if last_sgr != "\x1b[0m" {
            s.push_str("\x1b[0m");
            last_sgr = "\x1b[0m".into();
        }
    }
    let mut out = RESET.to_vec();
    out.extend_from_slice(s.as_bytes());
    out
}

#[cfg(test)]
mod tests {
    use alacritty_terminal::event::VoidListener;
    use alacritty_terminal::term::Config;
    use alacritty_terminal::term::test::TermSize;
    use alacritty_terminal::vte::ansi::Processor;

    use super::*;

    fn term(bytes: &[u8]) -> Term<VoidListener> {
        let mut t = Term::new(Config::default(), &TermSize::new(20, 4), VoidListener);
        let mut p: Processor = Processor::new();
        p.advance(&mut t, bytes);
        t
    }

    /// Replaying the grid into a fresh terminal gives back the same visible text.
    #[test]
    fn grid_round_trips() {
        let cases: [&[u8]; 3] = [
            b"plain\r\n\x1b[1;31mred bold\x1b[0m end\r\n",
            b"\x1b[?1049h\x1b[2;3Hin alt\x1b[4;1H\x1b[7mbar\x1b[0m",
            b"a\r\nb\r\nc\r\nd\r\ne\r\nf",
        ];
        for bytes in cases {
            let original = term(bytes);
            let mut replay = grid(&original, 1000);
            replay.extend(trailer(&original));
            let copy = term(&replay);
            assert_eq!(
                crate::read::rows(&copy, 100),
                crate::read::rows(&original, 100)
            );
            assert_eq!(copy.grid().cursor.point, original.grid().cursor.point);
        }
    }

    #[test]
    fn trailer_restores_modes() {
        let t = term(b"\x1b[?2004h\x1b[?1h\x1b[?25l\x1b[?1006h\x1b[3;5H");
        assert_eq!(
            String::from_utf8(trailer(&t)).unwrap(),
            "\x1b[?1h\x1b[?2004h\x1b[?1004l\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006h\x1b>\x1b[3;5H\x1b[?25l"
        );
    }
}
