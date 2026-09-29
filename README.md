# Mapo (native)

Mapo is a native macOS home for parallel terminal and Claude Code work. The rail holds workspaces and their tabs (shells and Claude agents; servers are ordinary tabs). The center holds tiling panes. The inspector shows the Files and Changes of whatever folder the focused terminal is in. A light native editor sits beside the terminal. Agents drive all of it through the `mapo` CLI and MCP.

- Rust daemon (`mapod`): owns processes, state and commands.
- Swift app: AppKit plus libghostty.
- Socket protocol between them.

**Status:** docs only, dated 2026-09-28. Implementation starts with milestone M0 in [docs/PLAN.md](docs/PLAN.md).

The previous app is a VS Code fork on branch `mapo` (worktree `~/code/mapo`, installed as `/Applications/Mapo.app`). It stays frozen as the daily driver until this app reaches v1.

## Documents

| Doc | Purpose |
|---|---|
| [AGENTS.md](AGENTS.md) (also `CLAUDE.md`) | Rules for any agent working here |
| [docs/HANDOFF.md](docs/HANDOFF.md) | Start here: state, pre-flight, the overnight `/goal` prompt |
| [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md) | What Mapo must do (requirement IDs) |
| [docs/UX.md](docs/UX.md) | Window, rail, panes, inspector, states, keyboard, tokens |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Processes, crates, terminal pipeline, app modules, risks |
| [docs/PROTOCOL.md](docs/PROTOCOL.md) | The socket protocol: methods, events, attach frames, CLI and MCP mapping |
| [docs/ENGINEERING.md](docs/ENGINEERING.md) | Instances and worktrees, dev loop, drives, evidence, budgets, conventions |
| [docs/PLAN.md](docs/PLAN.md) | Task-by-task implementation plan with acceptance |
| [docs/ROADMAP.md](docs/ROADMAP.md) | Milestones, switch-over, later items |
| [docs/DECISIONS.md](docs/DECISIONS.md) | What the user decided and why |
| [docs/FEATURE-MAP.md](docs/FEATURE-MAP.md) | The VS Code build mapped onto this design, with port notes |
| [docs/PROGRESS.md](docs/PROGRESS.md) | Running log and morning reports |
| [docs/research/](docs/research/) | Research on interop, reference apps and crates |
| [docs/reference/vscode-build/](docs/reference/vscode-build/) | Frozen references from the VS Code build |
| [drives/README.md](drives/README.md) | How drives (scripted, evidence-producing walkthroughs) work |

Design canvas (Claude Design): <https://claude.ai/artifact/DXzWX7bnxWX3i2zJCy1A8J>
