# Mapo native: agent instructions

Mapo is a native macOS home for parallel terminal and Claude Code work. A Rust daemon (`mapod`) owns processes and state. A Swift app renders with AppKit and libghostty. The `mapo` CLI and MCP server let agents drive it.

This branch, `native`, is a from-scratch rewrite. The old app is the VS Code fork on branch `mapo`, in the worktree `~/code/mapo` (same repository). It is **frozen** and stays the user's daily driver until native v1 ships.

## Read first

1. [docs/HANDOFF.md](docs/HANDOFF.md): the current state, the rules for autonomous runs, and where to start.
2. [docs/PLAN.md](docs/PLAN.md): the task-by-task plan with acceptance checks. [docs/PROGRESS.md](docs/PROGRESS.md) records where the last session stopped.
3. Specs:
   - [REQUIREMENTS](docs/REQUIREMENTS.md): what
   - [UX](docs/UX.md): how it looks and behaves
   - [ARCHITECTURE](docs/ARCHITECTURE.md): how it is built
   - [PROTOCOL](docs/PROTOCOL.md): the wire contract
   - [ENGINEERING](docs/ENGINEERING.md): dev loop, drives, budgets
4. [docs/DECISIONS.md](docs/DECISIONS.md): decisions the user already made. Don't reopen them without the user.
5. [docs/FEATURE-MAP.md](docs/FEATURE-MAP.md): how the VS Code build maps onto this design, with port notes.

## Non-negotiables

1. **Commands are the feature boundary.** Every user-visible action is a daemon command first. The UI, CLI, MCP, hooks and automation call the same command.
2. **The daemon owns state and processes.** The app is a client. Terminal bytes flow only through `mapo attach`.
3. **Drivable from day one.** Every interactive element has an accessibility identifier from [ENGINEERING.md](docs/ENGINEERING.md), and every flow can be driven with `mapo` and `mapo ui`. A feature is done only when a drive exercises it and leaves evidence.
4. **Isolation.** Always run your own instance: `MAPO_INSTANCE`, which defaults to `dev-<worktree>`. Never touch:
   - instance `main`
   - `/Applications/Mapo.app` (the frozen VS Code build, bundle id `dev.mapo.Mapo`) or its data in `~/.mapo` and `~/Library/Application Support/Mapo`
   - the `~/code/mapo` worktree.

   Stop only processes you started.
5. **Light.** No Electron, no Node at runtime, no web views in v1. Stay within the budgets in REQUIREMENTS R-NF-1.

## How to validate

Build, launch your instance, then drive it like a user with `mapo …`, `mapo ui …` and `just drive <name>`. Read the snapshots, screenshots and timings the drive leaves in `evidence/`, fix what feels wrong, and repeat. Unit tests are only for pure logic: the status function, codecs, parsers and the ring buffer. "It compiles" and "tests pass" are not done.

## Conventions

- **Rust:** edition 2024, the stable toolchain pinned in `rust-toolchain.toml`. `cargo fmt` and `cargo clippy --all-targets -- -D warnings` must be clean. Use `thiserror` in libraries and `anyhow` in the binary. No `unwrap()` on daemon paths. Use `tracing` for logs.
- **Swift:** Swift 6 language mode with MainActor default isolation. Generated protocol types may use Swift 5 mode. AppKit first; SwiftUI only where UX.md says. No force unwraps in UI code. Every interactive view gets its identifier.
- **Files:** no license headers. This is not VS Code code, so the Microsoft header rule from `~/code/mapo` does not apply here.
- **Commits:** small, one verified slice each, formatted `type(scope): summary` (feat, fix, docs, build, refactor, test, chore). Never push. Never modify the `mapo` branch.
- **Docs:** when behavior has to differ from a spec, update the spec in the same commit and note it in docs/PROGRESS.md.
- **Parity:** `CLAUDE.md` is a symlink to this file. Keep it that way. Skills go in `.agents/skills/`, with `.claude/skills` as a symlink to it.

## Working agreements with the user

- Implement on Opus. Use a Fable subagent only for a critical review at a milestone boundary, or for a genuinely hard design or debug question.
- Superpowers process skills are opt-in: don't invoke them unless the user asks.
- Multi-process dev uses mprocs (`mprocs.yaml`). portless is only for HTTP servers; Mapo has none.
- Before handing back, validate in the running app. The user cares about the product working more than about unit tests.

## Commands

`just --list` is the source of truth once M0 lands. The planned recipes are in [ENGINEERING.md](docs/ENGINEERING.md) §3.
