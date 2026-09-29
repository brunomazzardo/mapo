//! The tiling layout tree (PROTOCOL §7 `Layout` and `Node`, UX §4.2): pure functions over a
//! workspace's layout. The actor calls them and persists and announces the result.
//!
//! A split's `axis` is `"row"` (children left to right, a split to the right) or `"column"`
//! (children top to bottom, a split down). Ratios are positive and sum to 1.

use mapo_protocol::types::{Layout, Node, PaneContent};

pub const ROW: &str = "row";
pub const COLUMN: &str = "column";

/// A direction for splitting (`Right`, `Down`) or moving focus (all four).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    Left,
    Right,
    Up,
    Down,
}

impl Direction {
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "left" => Some(Self::Left),
            "right" => Some(Self::Right),
            "up" => Some(Self::Up),
            "down" => Some(Self::Down),
            _ => None,
        }
    }

    /// The axis a split in this direction uses.
    fn axis(self) -> &'static str {
        match self {
            Self::Left | Self::Right => ROW,
            Self::Up | Self::Down => COLUMN,
        }
    }
}

/// A pane's rectangle in the unit square, origin at the top left.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl Rect {
    const UNIT: Rect = Rect {
        x: 0.0,
        y: 0.0,
        w: 1.0,
        h: 1.0,
    };
}

#[derive(Debug, Clone, PartialEq, thiserror::Error)]
pub enum LayoutError {
    #[error("pane {0} is not in this layout")]
    PaneNotFound(String),
    #[error("split {0} is not in this layout")]
    SplitNotFound(String),
    #[error("{0}")]
    BadRatios(String),
}

const EPS: f64 = 1e-9;

// ---- queries ----

/// Pane ids in tree order (left to right, top to bottom).
pub fn pane_ids(layout: &Layout) -> Vec<String> {
    fn walk(node: &Node, out: &mut Vec<String>) {
        match node {
            Node::Pane { id, .. } => out.push(id.clone()),
            Node::Split { children, .. } => children.iter().for_each(|c| walk(c, out)),
        }
    }
    let mut out = Vec::new();
    walk(&layout.root, &mut out);
    out
}

/// What pane `id` shows.
pub fn content<'a>(layout: &'a Layout, pane: &str) -> Option<&'a PaneContent> {
    fn find<'a>(node: &'a Node, pane: &str) -> Option<&'a PaneContent> {
        match node {
            Node::Pane { id, content, .. } => (id == pane).then_some(content),
            Node::Split { children, .. } => children.iter().find_map(|c| find(c, pane)),
        }
    }
    find(&layout.root, pane)
}

/// The pane that shows `tab`, if any.
pub fn pane_of_tab<'a>(layout: &'a Layout, tab: &str) -> Option<&'a str> {
    fn find<'a>(node: &'a Node, tab: &str) -> Option<&'a str> {
        match node {
            Node::Pane {
                id,
                content: PaneContent::Tab { tab: t },
                ..
            } if t == tab => Some(id),
            Node::Pane { .. } => None,
            Node::Split { children, .. } => children.iter().find_map(|c| find(c, tab)),
        }
    }
    find(&layout.root, tab)
}

/// The tab in pane `pane`, if it shows one.
pub fn tab_in<'a>(layout: &'a Layout, pane: &str) -> Option<&'a str> {
    match content(layout, pane) {
        Some(PaneContent::Tab { tab }) => Some(tab),
        _ => None,
    }
}

/// The workspace's file pane (UX §6: at most one), if any.
pub fn file_pane(layout: &Layout) -> Option<&str> {
    fn find(node: &Node) -> Option<&str> {
        match node {
            Node::Pane {
                id,
                content: PaneContent::File { .. },
                ..
            } => Some(id),
            Node::Pane { .. } => None,
            Node::Split { children, .. } => children.iter().find_map(find),
        }
    }
    find(&layout.root)
}

/// Every pane's rectangle in the unit square, in tree order.
pub fn rects(layout: &Layout) -> Vec<(String, Rect)> {
    fn walk(node: &Node, r: Rect, out: &mut Vec<(String, Rect)>) {
        match node {
            Node::Pane { id, .. } => out.push((id.clone(), r)),
            Node::Split {
                axis,
                ratios,
                children,
                ..
            } => {
                let mut offset = 0.0;
                for (child, ratio) in children.iter().zip(ratios) {
                    let cr = if axis == ROW {
                        Rect {
                            x: r.x + offset * r.w,
                            w: ratio * r.w,
                            ..r
                        }
                    } else {
                        Rect {
                            y: r.y + offset * r.h,
                            h: ratio * r.h,
                            ..r
                        }
                    };
                    walk(child, cr, out);
                    offset += ratio;
                }
            }
        }
    }
    let mut out = Vec::new();
    walk(&layout.root, Rect::UNIT, &mut out);
    out
}

/// The nearest pane in `dir` from `from`: it lies wholly on that side and overlaps `from` across
/// the axis. Ties go to the larger overlap, then to the closer center. None at an edge.
pub fn neighbor(layout: &Layout, from: &str, dir: Direction) -> Option<String> {
    let all = rects(layout);
    let (_, a) = all.iter().find(|(id, _)| id == from)?;
    let a = *a;
    let overlap = |lo1: f64, hi1: f64, lo2: f64, hi2: f64| hi1.min(hi2) - lo1.max(lo2);
    all.iter()
        .filter(|(id, _)| id != from)
        .filter_map(|(id, b)| {
            let (gap, over, center) = match dir {
                Direction::Left => (
                    a.x - (b.x + b.w),
                    overlap(a.y, a.y + a.h, b.y, b.y + b.h),
                    ((a.y + a.h / 2.0) - (b.y + b.h / 2.0)).abs(),
                ),
                Direction::Right => (
                    b.x - (a.x + a.w),
                    overlap(a.y, a.y + a.h, b.y, b.y + b.h),
                    ((a.y + a.h / 2.0) - (b.y + b.h / 2.0)).abs(),
                ),
                Direction::Up => (
                    a.y - (b.y + b.h),
                    overlap(a.x, a.x + a.w, b.x, b.x + b.w),
                    ((a.x + a.w / 2.0) - (b.x + b.w / 2.0)).abs(),
                ),
                Direction::Down => (
                    b.y - (a.y + a.h),
                    overlap(a.x, a.x + a.w, b.x, b.x + b.w),
                    ((a.x + a.w / 2.0) - (b.x + b.w / 2.0)).abs(),
                ),
            };
            (gap > -EPS && over > EPS).then_some((id, gap, over, center))
        })
        .min_by(|l, r| {
            l.1.total_cmp(&r.1)
                .then(r.2.total_cmp(&l.2))
                .then(l.3.total_cmp(&r.3))
        })
        .map(|(id, ..)| id.clone())
}

// ---- mutations ----

/// Sets what pane `pane` shows.
pub fn set_content(layout: &mut Layout, pane: &str, new: PaneContent) -> Result<(), LayoutError> {
    fn walk(node: &mut Node, pane: &str, new: &mut Option<PaneContent>) -> bool {
        match node {
            Node::Pane { id, content, .. } if id == pane => {
                if let Some(c) = new.take() {
                    *content = c;
                }
                true
            }
            Node::Pane { .. } => false,
            Node::Split { children, .. } => children.iter_mut().any(|c| walk(c, pane, new)),
        }
    }
    if walk(&mut layout.root, pane, &mut Some(new)) {
        Ok(())
    } else {
        Err(LayoutError::PaneNotFound(pane.to_owned()))
    }
}

/// How many recent files a file pane keeps (UX §6.1).
pub const RECENT_FILES: usize = 10;

/// Shows `path` in pane `pane` and puts it first in the pane's recent files, newest first, without
/// duplicates and at most `RECENT_FILES` long.
pub fn open_file(layout: &mut Layout, pane: &str, path: &str) -> Result<(), LayoutError> {
    let node = pane_mut(&mut layout.root, pane)
        .ok_or_else(|| LayoutError::PaneNotFound(pane.to_owned()))?;
    if let Node::Pane {
        content,
        recent_files,
        ..
    } = node
    {
        *content = PaneContent::File {
            file: path.to_owned(),
        };
        recent_files.retain(|p| p != path);
        recent_files.insert(0, path.to_owned());
        recent_files.truncate(RECENT_FILES);
    }
    Ok(())
}

/// Empties pane `pane`'s recent files, keeping the file it shows.
pub fn clear_recent(layout: &mut Layout, pane: &str) -> Result<(), LayoutError> {
    let node = pane_mut(&mut layout.root, pane)
        .ok_or_else(|| LayoutError::PaneNotFound(pane.to_owned()))?;
    if let Node::Pane {
        content,
        recent_files,
        ..
    } = node
    {
        recent_files.clear();
        if let PaneContent::File { file } = content {
            recent_files.push(file.clone());
        }
    }
    Ok(())
}

fn pane_mut<'a>(node: &'a mut Node, pane: &str) -> Option<&'a mut Node> {
    match node {
        Node::Pane { id, .. } if id == pane => Some(node),
        Node::Pane { .. } => None,
        Node::Split { children, .. } => children.iter_mut().find_map(|c| pane_mut(c, pane)),
    }
}

/// Focuses pane `pane`.
pub fn focus(layout: &mut Layout, pane: &str) -> Result<(), LayoutError> {
    if content(layout, pane).is_none() {
        return Err(LayoutError::PaneNotFound(pane.to_owned()));
    }
    layout.focused_pane_id = pane.to_owned();
    Ok(())
}

/// Splits `target` to the right or down. The new pane `new_pane` shows `content`, takes half of
/// the target's space and gets focus. A split along the parent's axis adds a sibling instead of
/// nesting; otherwise the target becomes a split named `new_split`.
pub fn split(
    layout: &mut Layout,
    target: &str,
    dir: Direction,
    content: PaneContent,
    new_pane: &str,
    new_split: &str,
) -> Result<(), LayoutError> {
    fn walk(
        node: &mut Node,
        target: &str,
        axis: &str,
        new: &mut Option<Node>,
        split_id: &str,
    ) -> bool {
        match node {
            Node::Pane { id, .. } if id == target => {
                let Some(fresh) = new.take() else {
                    return false;
                };
                let old = std::mem::replace(node, placeholder());
                *node = Node::Split {
                    id: split_id.to_owned(),
                    axis: axis.to_owned(),
                    ratios: vec![0.5, 0.5],
                    children: vec![old, fresh],
                };
                true
            }
            Node::Pane { .. } => false,
            Node::Split {
                axis: a,
                ratios,
                children,
                ..
            } => {
                if a == axis
                    && let Some(i) = children
                        .iter()
                        .position(|c| matches!(c, Node::Pane { id, .. } if id == target))
                    && let Some(fresh) = new.take()
                {
                    let half = ratios[i] / 2.0;
                    ratios[i] = half;
                    ratios.insert(i + 1, half);
                    children.insert(i + 1, fresh);
                    return true;
                }
                children
                    .iter_mut()
                    .any(|c| walk(c, target, axis, new, split_id))
            }
        }
    }
    let axis = dir.axis();
    let mut fresh = Some(Node::Pane {
        id: new_pane.to_owned(),
        content,
        recent_files: vec![],
    });
    if !walk(&mut layout.root, target, axis, &mut fresh, new_split) {
        return Err(LayoutError::PaneNotFound(target.to_owned()));
    }
    layout.focused_pane_id = new_pane.to_owned();
    Ok(())
}

/// Closes `target`. Its space goes to the next sibling, else the previous one, and focus follows
/// the space when the closed pane had it. A split left with one child is replaced by that child.
/// The last pane is not removed: it becomes empty.
pub fn close(layout: &mut Layout, target: &str) -> Result<(), LayoutError> {
    if let Node::Pane { id, content, .. } = &mut layout.root {
        if id != target {
            return Err(LayoutError::PaneNotFound(target.to_owned()));
        }
        *content = PaneContent::Empty { empty: true };
        return Ok(());
    }
    /// Removes the target from the subtree; returns the pane that takes its space.
    fn walk(node: &mut Node, target: &str) -> Option<String> {
        let Node::Split {
            ratios, children, ..
        } = node
        else {
            return None;
        };
        let Some(i) = children
            .iter()
            .position(|c| matches!(c, Node::Pane { id, .. } if id == target))
        else {
            return children.iter_mut().find_map(|c| walk(c, target));
        };
        let freed = ratios.remove(i);
        children.remove(i);
        let heir = if i < children.len() { i } else { i - 1 };
        ratios[heir] += freed;
        let taker = if heir == i {
            first_pane(&children[heir])
        } else {
            last_pane(&children[heir])
        };
        Some(taker)
    }
    let taker = walk(&mut layout.root, target)
        .ok_or_else(|| LayoutError::PaneNotFound(target.to_owned()))?;
    normalize(&mut layout.root);
    if layout.focused_pane_id == target {
        layout.focused_pane_id = taker;
    }
    Ok(())
}

/// Sets every split's ratios equal, or only `split`'s.
pub fn equalize(layout: &mut Layout, split: Option<&str>) -> Result<(), LayoutError> {
    fn walk(node: &mut Node, only: Option<&str>) -> bool {
        let Node::Split {
            id,
            ratios,
            children,
            ..
        } = node
        else {
            return false;
        };
        let mut hit = false;
        if only.is_none_or(|s| s == id) {
            let n = children.len().max(1) as f64;
            ratios.iter_mut().for_each(|r| *r = 1.0 / n);
            hit = true;
        }
        for c in children.iter_mut() {
            hit |= walk(c, only);
        }
        hit
    }
    let hit = walk(&mut layout.root, split);
    match split {
        Some(s) if !hit => Err(LayoutError::SplitNotFound(s.to_owned())),
        _ => Ok(()),
    }
}

/// Sets `split`'s ratios, normalized to sum to 1. There must be one positive ratio per child.
pub fn resize(layout: &mut Layout, split: &str, new: &[f64]) -> Result<(), LayoutError> {
    fn find<'a>(node: &'a mut Node, split: &str) -> Option<(&'a mut Vec<f64>, usize)> {
        match node {
            Node::Split {
                id,
                ratios,
                children,
                ..
            } => {
                if id == split {
                    let n = children.len();
                    return Some((ratios, n));
                }
                children.iter_mut().find_map(|c| find(c, split))
            }
            Node::Pane { .. } => None,
        }
    }
    let (ratios, n) = find(&mut layout.root, split)
        .ok_or_else(|| LayoutError::SplitNotFound(split.to_owned()))?;
    if new.len() != n {
        return Err(LayoutError::BadRatios(format!(
            "split {split} has {n} children, got {} ratios",
            new.len()
        )));
    }
    if new.iter().any(|r| !r.is_finite() || *r <= 0.0) {
        return Err(LayoutError::BadRatios(
            "ratios must be positive numbers".into(),
        ));
    }
    let sum: f64 = new.iter().sum();
    *ratios = new.iter().map(|r| r / sum).collect();
    Ok(())
}

// ---- helpers ----

fn placeholder() -> Node {
    Node::Pane {
        id: String::new(),
        content: PaneContent::Empty { empty: true },
        recent_files: vec![],
    }
}

fn first_pane(node: &Node) -> String {
    match node {
        Node::Pane { id, .. } => id.clone(),
        Node::Split { children, .. } => children.first().map(first_pane).unwrap_or_default(),
    }
}

fn last_pane(node: &Node) -> String {
    match node {
        Node::Pane { id, .. } => id.clone(),
        Node::Split { children, .. } => children.last().map(last_pane).unwrap_or_default(),
    }
}

/// Replaces one-child splits with their child and inlines a child split that runs along its
/// parent's axis, scaling its ratios.
fn normalize(node: &mut Node) {
    let Node::Split {
        axis,
        ratios,
        children,
        ..
    } = node
    else {
        return;
    };
    children.iter_mut().for_each(normalize);
    let mut new_ratios = Vec::with_capacity(ratios.len());
    let mut new_children = Vec::with_capacity(children.len());
    for (child, ratio) in std::mem::take(children).into_iter().zip(ratios.iter()) {
        match child {
            Node::Split {
                axis: ca,
                ratios: cr,
                children: cc,
                ..
            } if ca == *axis => {
                new_ratios.extend(cr.iter().map(|r| r * ratio));
                new_children.extend(cc);
            }
            other => {
                new_ratios.push(*ratio);
                new_children.push(other);
            }
        }
    }
    *ratios = new_ratios;
    *children = new_children;
    if children.len() == 1
        && let Some(only) = children.pop()
    {
        *node = only;
    }
}

#[cfg(test)]
#[allow(clippy::type_complexity)] // table-driven cases
mod tests {
    use super::*;

    fn tab(t: &str) -> PaneContent {
        PaneContent::Tab { tab: t.into() }
    }

    fn p(id: &str) -> Node {
        Node::Pane {
            id: id.into(),
            content: tab(&format!("t{id}")),
            recent_files: vec![],
        }
    }

    fn s(id: &str, axis: &str, ratios: &[f64], children: Vec<Node>) -> Node {
        Node::Split {
            id: id.into(),
            axis: axis.into(),
            ratios: ratios.to_vec(),
            children,
        }
    }

    fn lay(focused: &str, root: Node) -> Layout {
        Layout {
            workspace_id: "w".into(),
            focused_pane_id: focused.into(),
            root,
        }
    }

    /// A compact picture of a tree: `a`, `row(a .5, b .5)`.
    fn shape(node: &Node) -> String {
        match node {
            Node::Pane { id, .. } => id.clone(),
            Node::Split {
                axis,
                ratios,
                children,
                ..
            } => {
                let inner: Vec<String> = children
                    .iter()
                    .zip(ratios)
                    .map(|(c, r)| format!("{} {}", shape(c), (r * 1000.0).round() / 1000.0))
                    .collect();
                format!("{axis}({})", inner.join(", "))
            }
        }
    }

    /// The 2×2 fixture: row(column(a, c), column(b, d)).
    fn grid() -> Layout {
        lay(
            "a",
            s(
                "r",
                ROW,
                &[0.5, 0.5],
                vec![
                    s("c1", COLUMN, &[0.5, 0.5], vec![p("a"), p("c")]),
                    s("c2", COLUMN, &[0.5, 0.5], vec![p("b"), p("d")]),
                ],
            ),
        )
    }

    #[test]
    fn split_cases() {
        let cases: Vec<(&str, Layout, &str, Direction, Result<&str, LayoutError>)> = vec![
            (
                "one pane right",
                lay("a", p("a")),
                "a",
                Direction::Right,
                Ok("row(a 0.5, n 0.5)"),
            ),
            (
                "one pane down",
                lay("a", p("a")),
                "a",
                Direction::Down,
                Ok("column(a 0.5, n 0.5)"),
            ),
            (
                "same axis adds a sibling",
                lay("a", s("r", ROW, &[0.5, 0.5], vec![p("a"), p("b")])),
                "a",
                Direction::Right,
                Ok("row(a 0.25, n 0.25, b 0.5)"),
            ),
            (
                "cross axis nests",
                lay("b", s("r", ROW, &[0.5, 0.5], vec![p("a"), p("b")])),
                "b",
                Direction::Down,
                Ok("row(a 0.5, column(b 0.5, n 0.5) 0.5)"),
            ),
            (
                "missing pane",
                lay("a", p("a")),
                "zz",
                Direction::Right,
                Err(LayoutError::PaneNotFound("zz".into())),
            ),
        ];
        for (name, mut layout, target, dir, want) in cases {
            let got = split(&mut layout, target, dir, tab("new"), "n", "sn")
                .map(|()| shape(&layout.root));
            assert_eq!(got.as_deref().map_err(Clone::clone), want.clone(), "{name}");
            if want.is_ok() {
                assert_eq!(
                    layout.focused_pane_id, "n",
                    "{name}: the new pane is focused"
                );
            }
        }
    }

    #[test]
    fn close_cases() {
        let pair = || lay("a", s("r", ROW, &[0.3, 0.7], vec![p("a"), p("b")]));
        let three = || {
            lay(
                "c",
                s("r", ROW, &[0.2, 0.3, 0.5], vec![p("a"), p("b"), p("c")]),
            )
        };
        // (name, layout, target, shape after, focus after)
        let cases: Vec<(&str, Layout, &str, Result<(&str, &str), LayoutError>)> = vec![
            (
                "last pane turns empty",
                lay("a", p("a")),
                "a",
                Ok(("a", "a")),
            ),
            ("next sibling takes the space", pair(), "a", Ok(("b", "b"))),
            (
                "previous sibling when last",
                three(),
                "c",
                Ok(("row(a 0.2, b 0.8)", "b")),
            ),
            (
                "middle goes to the next",
                three(),
                "b",
                Ok(("row(a 0.2, c 0.8)", "c")),
            ),
            ("unfocused close keeps focus", pair(), "b", Ok(("a", "a"))),
            (
                "promotion flattens same-axis splits",
                lay(
                    "x",
                    s(
                        "r",
                        ROW,
                        &[0.5, 0.5],
                        vec![
                            p("a"),
                            s(
                                "c",
                                COLUMN,
                                &[0.5, 0.5],
                                vec![p("x"), s("r2", ROW, &[0.5, 0.5], vec![p("b"), p("d")])],
                            ),
                        ],
                    ),
                ),
                "x",
                Ok(("row(a 0.5, b 0.25, d 0.25)", "b")),
            ),
            (
                "missing pane",
                pair(),
                "zz",
                Err(LayoutError::PaneNotFound("zz".into())),
            ),
        ];
        for (name, mut layout, target, want) in cases {
            let got = close(&mut layout, target)
                .map(|()| (shape(&layout.root), layout.focused_pane_id.clone()));
            let want = want.map(|(s, f)| (s.to_owned(), f.to_owned()));
            assert_eq!(got, want, "{name}");
        }
        let mut last = lay("a", p("a"));
        close(&mut last, "a").unwrap();
        assert_eq!(
            content(&last, "a"),
            Some(&PaneContent::Empty { empty: true })
        );
    }

    #[test]
    fn neighbor_cases() {
        let uneven = lay(
            "a",
            s(
                "r",
                ROW,
                &[0.5, 0.5],
                vec![p("a"), s("c", COLUMN, &[0.3, 0.7], vec![p("b"), p("d")])],
            ),
        );
        let cases: Vec<(&str, Layout, &str, Direction, Option<&str>)> = vec![
            ("grid right", grid(), "a", Direction::Right, Some("b")),
            ("grid down", grid(), "a", Direction::Down, Some("c")),
            ("grid left edge", grid(), "a", Direction::Left, None),
            ("grid up edge", grid(), "a", Direction::Up, None),
            ("grid from d left", grid(), "d", Direction::Left, Some("c")),
            ("grid from d up", grid(), "d", Direction::Up, Some("b")),
            (
                "larger overlap wins",
                uneven.clone(),
                "a",
                Direction::Right,
                Some("d"),
            ),
            ("back left from b", uneven, "b", Direction::Left, Some("a")),
            ("single pane", lay("a", p("a")), "a", Direction::Right, None),
            ("unknown pane", grid(), "zz", Direction::Right, None),
        ];
        for (name, layout, from, dir, want) in cases {
            assert_eq!(neighbor(&layout, from, dir).as_deref(), want, "{name}");
        }
    }

    #[test]
    fn rects_cases() {
        let r = |x, y, w, h| Rect { x, y, w, h };
        let cases: Vec<(&str, Layout, Vec<(&str, Rect)>)> = vec![
            ("one pane", lay("a", p("a")), vec![("a", Rect::UNIT)]),
            (
                "grid",
                grid(),
                vec![
                    ("a", r(0.0, 0.0, 0.5, 0.5)),
                    ("c", r(0.0, 0.5, 0.5, 0.5)),
                    ("b", r(0.5, 0.0, 0.5, 0.5)),
                    ("d", r(0.5, 0.5, 0.5, 0.5)),
                ],
            ),
            (
                "ratios",
                lay("a", s("r", ROW, &[0.25, 0.75], vec![p("a"), p("b")])),
                vec![
                    ("a", r(0.0, 0.0, 0.25, 1.0)),
                    ("b", r(0.25, 0.0, 0.75, 1.0)),
                ],
            ),
        ];
        for (name, layout, want) in cases {
            let want: Vec<(String, Rect)> =
                want.into_iter().map(|(i, r)| (i.to_owned(), r)).collect();
            assert_eq!(rects(&layout), want, "{name}");
        }
    }

    #[test]
    fn equalize_cases() {
        let skewed = || {
            lay(
                "a",
                s(
                    "r",
                    ROW,
                    &[0.2, 0.8],
                    vec![p("a"), s("c", COLUMN, &[0.9, 0.1], vec![p("b"), p("d")])],
                ),
            )
        };
        let cases: Vec<(&str, Layout, Option<&str>, Result<&str, LayoutError>)> = vec![
            (
                "all",
                skewed(),
                None,
                Ok("row(a 0.5, column(b 0.5, d 0.5) 0.5)"),
            ),
            (
                "one split",
                skewed(),
                Some("c"),
                Ok("row(a 0.2, column(b 0.5, d 0.5) 0.8)"),
            ),
            ("single pane", lay("a", p("a")), None, Ok("a")),
            (
                "missing split",
                skewed(),
                Some("zz"),
                Err(LayoutError::SplitNotFound("zz".into())),
            ),
        ];
        for (name, mut layout, only, want) in cases {
            let got = equalize(&mut layout, only).map(|()| shape(&layout.root));
            assert_eq!(got, want.map(str::to_owned), "{name}");
        }
    }

    #[test]
    fn resize_cases() {
        let pair = || lay("a", s("r", ROW, &[0.5, 0.5], vec![p("a"), p("b")]));
        let cases: Vec<(&str, &str, Vec<f64>, Result<&str, &str>)> = vec![
            ("sets ratios", "r", vec![0.3, 0.7], Ok("row(a 0.3, b 0.7)")),
            ("normalizes", "r", vec![1.0, 3.0], Ok("row(a 0.25, b 0.75)")),
            ("wrong count", "r", vec![1.0], Err("bad")),
            ("zero ratio", "r", vec![0.0, 1.0], Err("bad")),
            ("missing split", "zz", vec![0.5, 0.5], Err("missing")),
        ];
        for (name, split_id, ratios, want) in cases {
            let mut layout = pair();
            let got = resize(&mut layout, split_id, &ratios).map(|()| shape(&layout.root));
            match (got, want) {
                (Ok(g), Ok(w)) => assert_eq!(g, w, "{name}"),
                (Err(LayoutError::BadRatios(_)), Err("bad")) => {}
                (Err(LayoutError::SplitNotFound(_)), Err("missing")) => {}
                (g, w) => panic!("{name}: got {g:?}, want {w:?}"),
            }
        }
    }

    /// The recent files of pane `id`.
    fn recent(layout: &Layout, pane: &str) -> Vec<String> {
        fn find(node: &Node, pane: &str) -> Option<Vec<String>> {
            match node {
                Node::Pane {
                    id, recent_files, ..
                } => (id == pane).then(|| recent_files.clone()),
                Node::Split { children, .. } => children.iter().find_map(|c| find(c, pane)),
            }
        }
        find(&layout.root, pane).unwrap_or_default()
    }

    #[test]
    fn open_file_cases() {
        let mut layout = grid();
        assert_eq!(file_pane(&layout), None);
        let mut opened = |path: &str| {
            open_file(&mut layout, "b", path).unwrap();
            (
                file_pane(&layout).map(str::to_owned),
                recent(&layout, "b").join(","),
            )
        };
        let steps: Vec<(&str, &str)> = vec![
            ("/x/a", "/x/a"),
            ("/x/b", "/x/b,/x/a"),
            ("/x/a", "/x/a,/x/b"),
        ];
        for (path, want) in steps {
            assert_eq!(
                opened(path),
                (Some("b".to_owned()), want.to_owned()),
                "{path}"
            );
        }
        for i in 0..20 {
            open_file(&mut layout, "b", &format!("/y/{i}")).unwrap();
        }
        let r = recent(&layout, "b");
        assert_eq!((r.len(), r[0].as_str()), (RECENT_FILES, "/y/19"));
        clear_recent(&mut layout, "b").unwrap();
        assert_eq!(recent(&layout, "b"), vec!["/y/19".to_owned()]);
        assert_eq!(
            open_file(&mut layout, "zz", "/a"),
            Err(LayoutError::PaneNotFound("zz".into()))
        );
    }

    #[test]
    fn query_cases() {
        let mut layout = grid();
        set_content(&mut layout, "d", PaneContent::Empty { empty: true }).unwrap();
        let cases: Vec<(&str, Option<String>, Option<&str>)> = vec![
            (
                "pane_of_tab",
                pane_of_tab(&layout, "tb").map(str::to_owned),
                Some("b"),
            ),
            (
                "pane_of_tab missing",
                pane_of_tab(&layout, "td").map(str::to_owned),
                None,
            ),
            (
                "tab_in",
                tab_in(&layout, "c").map(str::to_owned),
                Some("tc"),
            ),
            (
                "tab_in empty",
                tab_in(&layout, "d").map(str::to_owned),
                None,
            ),
            (
                "pane_ids",
                Some(pane_ids(&layout).join(",")),
                Some("a,c,b,d"),
            ),
        ];
        for (name, got, want) in cases {
            assert_eq!(got.as_deref(), want, "{name}");
        }
        assert_eq!(
            set_content(&mut layout, "zz", PaneContent::Empty { empty: true }),
            Err(LayoutError::PaneNotFound("zz".into()))
        );
        assert_eq!(
            focus(&mut layout, "zz"),
            Err(LayoutError::PaneNotFound("zz".into()))
        );
        focus(&mut layout, "d").unwrap();
        assert_eq!(layout.focused_pane_id, "d");
    }
}
