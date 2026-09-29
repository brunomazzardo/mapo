//! `tab read` rows (PLAN T0.5 step 9, contract 5): scrollback plus screen, trimmed the way a
//! person reads them.

use alacritty_terminal::event::EventListener;
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::index::{Column, Line};
use alacritty_terminal::term::Term;
use alacritty_terminal::term::cell::Flags;

/// The last `lines` rows. Wide-character spacers are skipped and trailing spaces trimmed. Rows
/// below the cursor stay when they hold text (TUIs draw menus there); trailing blank rows go.
pub fn rows<T: EventListener>(term: &Term<T>, lines: usize) -> Vec<String> {
    let grid = term.grid();
    let top = -(grid.history_size() as i32);
    let bottom = grid.screen_lines() as i32 - 1;
    let cols = grid.columns();
    let mut out: Vec<String> = Vec::with_capacity((bottom - top + 1) as usize);
    for l in top..=bottom {
        let row = &grid[Line(l)];
        let mut s = String::with_capacity(cols);
        for c in 0..cols {
            let cell = &row[Column(c)];
            if cell
                .flags
                .intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER)
            {
                continue;
            }
            s.push(cell.c);
            if let Some(zw) = cell.zerowidth() {
                s.extend(zw);
            }
        }
        out.push(s.trim_end().to_owned());
    }
    while out.last().is_some_and(String::is_empty) {
        out.pop();
    }
    let skip = out.len().saturating_sub(lines);
    out.split_off(skip)
}

#[cfg(test)]
mod tests {
    use alacritty_terminal::event::VoidListener;
    use alacritty_terminal::term::Config;
    use alacritty_terminal::term::test::TermSize;
    use alacritty_terminal::vte::ansi::Processor;

    use super::*;

    fn feed(bytes: &[u8]) -> Term<VoidListener> {
        let mut term = Term::new(Config::default(), &TermSize::new(20, 5), VoidListener);
        let mut p: Processor = Processor::new();
        p.advance(&mut term, bytes);
        term
    }

    #[test]
    fn trims_and_keeps_rows_below_cursor() {
        let cases: [(&[u8], usize, Vec<&str>); 4] = [
            (b"a  \r\nb\r\n\r\n", 10, vec!["a", "b"]),
            (b"1\r\n2\r\n3\r\n4\r\n5\r\n6\r\n7", 3, vec!["5", "6", "7"]),
            // A menu drawn below the cursor, then the cursor moved back up.
            (
                b"prompt\r\n\r\n  > option\x1b[1;7H",
                10,
                vec!["prompt", "", "  > option"],
            ),
            ("日本\r\n".as_bytes(), 10, vec!["日本"]),
        ];
        let got: Vec<Vec<String>> = cases.iter().map(|(b, n, _)| rows(&feed(b), *n)).collect();
        let want: Vec<Vec<String>> = cases
            .iter()
            .map(|(_, _, w)| w.iter().map(|s| (*s).to_owned()).collect())
            .collect();
        assert_eq!(got, want);
    }
}
