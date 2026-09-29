# Decisions

Made in the interview on 2026-09-28, with the design exploration on the Claude Design canvas <https://claude.ai/artifact/DXzWX7bnxWX3i2zJCy1A8J>.

- **User** means the user chose it. **Default** means Claude proposed it and the user did not object; it can be revisited by asking the user.
- Agents: do not reopen a **User** decision on your own. If reality forces a change, stop that line of work, record it in [PROGRESS.md](PROGRESS.md) under "Needs the user", and continue with other tasks.

## Product and scope

| ID | Question | Decision | Why / notes | By |
|---|---|---|---|---|
| D-1 | What should going native buy? | All four: native feel and speed, terminal quality, reliability, a small codebase the user owns. In that order when they conflict. | Sets the tie-breaks for every later choice | User |
| D-2 | What must v1 include beyond the daily core? | The agent control plane (CLI, MCP, skill, `tab send/read/wait/run/ask`, events, activity) and dev servers plus ports. Servers were then redefined by D-20. | The user's agent-to-agent flows depend on the control plane | User |
| D-3 | What waits for later? | Saved setups, repo membership, `.mapo/actions` with pins, the mprocs adapter | Not needed for daily use | User |
| D-4 | Should sessions survive quitting, crashing or updating? | Yes. A daemon (mapod) owns the PTYs; the app attaches as a client. | Updates and UI crashes stop killing agents; developing Mapo inside Mapo becomes safe | User |
| D-5 | How much editor? | A light native editor: highlighting, find/replace, save, git gutter, diff, image and Markdown preview (CotEditor-class) | History shows almost no editor use; CotEditor for quick opens | User |
| D-9 | Which agent CLIs get first-class support? | Claude Code only (`claude`, `claude-work` through the workspace agent command). Keep an adapter seam. | | User |
| D-12 | Who is it for? | Just the user: local builds, no updater, a config file before settings UI | | User |
| D-17 | Which later features should the architecture make room for now? | Worktrees and branch operations; PR and review panel; browser pane. Not the default file opener. | | User |
| D-18 | What happens to the VS Code build? | Frozen. It stays the daily driver until native v1 parity; only blockers get fixed. | | User |
| D-19 | Import existing workspaces? | No. Start fresh. | | User |
| D-20 | Server tabs? | No separate server section and no managed server tabs in v1. Servers are ordinary tabs; Mapo detects listening ports and shows a server icon and a port label (`:4000`). Managed servers are LATER. | User: "not sold on those extra bottom server tabs, lets move that as a future thing, normal tabs run server we identify maybe label and icon" | User |

## UX

| ID | Question | Decision | Why / notes | By |
|---|---|---|---|---|
| D-6 | Tabs and splits? | Tabs live only in the rail, with tiling splits per workspace. Any pane shows a terminal or a file; clicking a file splits beside the focused terminal. | Removes the duplicated tab strips of the VS Code build | User |
| D-7 | Right sidebar panels in v1? | Files (follows the focused tab's cwd) and Changes (git changes plus diff). Not search, the fuzzy finder or the activity view. | | User |
| D-8 | How loud is attention? | Rail status, dock badge, and a macOS notification only when you can't see that tab; clicking it jumps to the tab. | | User |
| D-10 | Window direction? | "A · Source list": rail, panes, inspector, glass sidebars, no title bar. | Chosen over "B · Workspace strip" and "C · Floating glass" | User |
| D-16 | Rail design? | "S2 · Slimmer". It combines A1 (quiet: words only for Needs you and Failed, dots otherwise) with A5 (compact rows, shortcut hints shown while holding ⌘), and takes A3's direction but more minimal: branch inline, no chips, no cards, no inline actions. | User: "mix of a1 and a5", "more a3 but minimal and more slim" | User |
| D-23 | How are UI directions explored? | With the `/design` skill (a Claude Design canvas) and several variants per question, iterated with the user | User asked for `/design` explicitly | User |

## Architecture

| ID | Question | Decision | Why / notes | By |
|---|---|---|---|---|
| D-13 | Terminal engine and PTY ownership? | Upstream libghostty renders. Each surface runs `mapo attach <tab>`, which connects to the daemon that owns the PTY (the tmux/zmx pattern). No fork; the terminal view sits behind `TerminalSurface`. | GhosttyKit comes prebuilt from `Lakr233/libghostty-spm` (pinned); the fallback builds it with Zig 0.16; SwiftTerm is a last resort | User |
| D-14 | Editor implementation? | Native TextKit 2 (NSTextView; STTextView allowed, since GPL is acceptable for personal use), tree-sitter highlighting, a git gutter, a unified diff view | The research recommended Monaco in a WKWebView; the user chose native | User |
| D-15 | How does Swift talk to Rust? | The socket protocol only: JSON-RPC over NDJSON plus binary attach frames. No UniFFI. Swift types are generated from Rust. | The CLI, MCP and hooks use the same protocol | User |
| D-21 | How do agents validate the native UI? | Built-in automation: `mapo ui` for the AX tree, semantic snapshots, synthetic input, waits and metrics. Pixels come from `screencapture -l`. | Replaces Playwright over CDP | User |
| D-22 | Engineering from day one? | Auto-testable, auto-drivable, lightweight, runnable in parallel worktrees, built and optimized in parallel. Validation is by drives that use the app and "feel the UX/UI", not by automated unit-test suites. | User's words, verbatim, are in [ENGINEERING.md](ENGINEERING.md) §1 | User |
| D-24 | Platform? | macOS 26+ on Apple silicon only | The machine runs macOS 27; this gives native Liquid Glass | Default |
| D-25 | CLI compatibility? | Keep the VS Code build's verb names, flags and JSON shapes where the feature still exists | Existing skill knowledge and habits carry over | Default |
| D-26 | Binaries? | One Rust binary `mapo` with subcommands (daemon, attach, hook, mcp, ui, CLI verbs) plus the Swift app | Small, fast to start; attach and hooks need millisecond startup | Default |
| D-27 | How does Mapo hook into Claude? | A Claude Code plugin loaded with `CLAUDE_CODE_PLUGIN_DIRS`, falling back to `--plugin-dir` for CLIs older than 2.1.280. No settings edits, no wrapper. | From research: replaces the VS Code build's `--settings`/`--mcp-config`/`--add-dir` flags | Default |
| D-28 | UI toolkit? | AppKit for lifecycle, windows, splits, lists, the editor and focus. SwiftUI for the palette, settings and popovers. | cmux and Ghostty both moved hot paths out of SwiftUI | Default |
| D-29 | Identity and paths? | Bundle ids `dev.mapo.app` (installed, M5) and `dev.mapo.app.dev` (every dev build). Per-instance data in `~/Library/Application Support/dev.mapo.app/instances/<instance>/`. | Can't collide with the frozen app (`dev.mapo.Mapo`) | Default |
| D-30 | Settings? | `config.toml` per instance, hot-reloaded; ⌘, opens it in the file pane | "Just me": no settings UI in v1 | Default |

## Repository

| ID | Question | Decision | Why / notes | By |
|---|---|---|---|---|
| D-11 | Where does the rewrite live? | The orphan branch `native` in the same repository, checked out at `~/code/mapo-native` with `git worktree add --orphan` | Clean tree; the old code stays readable with `git show mapo:<path>` | User |
