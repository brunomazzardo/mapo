# Handoff: build Mapo native

Written 2026-09-28 at the end of the interview and design session. It is for the next agent, typically an overnight `/goal` run. Read it fully, then [PLAN.md](PLAN.md).

## 1. Mission

Execute the whole plan, in order, as far as the night allows:

1. **M0**, the walking skeleton that agents can drive from day one.
2. **M1**, the daily core.
3. **M2**, Claude integration.
4. **M3**, the agent control plane.
5. **M4**, servers, ports and Changes.
6. **M5 T5.1**, the performance pass.

The rest of M5 needs the user. M0 must be solid before M1 starts. Every task must end with the real app and daemon being driven and leaving evidence, followed by one small commit. By morning the user should find:

- a `native` branch that builds with `just build`
- an app they can launch with `just app` that shows the rail and a working Ghostty terminal served by the daemon
- terminals that survive quitting and reopening the app
- everything drivable through `mapo` and `mapo ui`
- a morning report at the top of [PROGRESS.md](PROGRESS.md).

## 2. Context in one minute

- Mapo began as a VS Code fork: a cmux-style hub with workspaces, Claude tabs with hook-driven status, a cwd-following explorer, a `mapo` CLI with 40+ verbs, an MCP server and server tabs. It works, but fighting VS Code's editor and terminal lifecycle cost too much. It is frozen at `~/code/mapo` (branch `mapo`) and installed as `/Applications/Mapo.app`.
- The native rewrite keeps the product and drops the platform:
  - a Rust daemon owns PTYs and state
  - a Swift/AppKit app renders, with libghostty terminals running `mapo attach`
  - a native TextKit 2 editor
  - Claude Code integration through a plugin injected with `CLAUDE_CODE_PLUGIN_DIRS`
  - one socket protocol for the app, the CLI, MCP, hooks and automation.
- Every decision is recorded in [DECISIONS.md](DECISIONS.md), with who made it. The user was interviewed in depth, so treat the specs as settled.

## 3. Where everything is

| What | Where |
|---|---|
| This repo (branch `native`, orphan) | `~/code/mapo-native`, a worktree of the repository at `~/code/mapo` |
| Frozen VS Code build | `~/code/mapo` (branch `mapo`); read the old code with `git show mapo:<path>` or under `~/code/mapo/src/vs/workbench/contrib/mapo/` |
| Installed frozen app (**do not touch**) | `/Applications/Mapo.app`, bundle id `dev.mapo.Mapo`, data in `~/.mapo` and `~/Library/Application Support/Mapo` |
| Specs | [REQUIREMENTS](REQUIREMENTS.md), [UX](UX.md), [ARCHITECTURE](ARCHITECTURE.md), [PROTOCOL](PROTOCOL.md), [ENGINEERING](ENGINEERING.md) |
| Plan, roadmap, log | [PLAN](PLAN.md), [ROADMAP](ROADMAP.md), [PROGRESS](PROGRESS.md) |
| Feature map and port notes | [FEATURE-MAP](FEATURE-MAP.md), [reference/vscode-build/](reference/vscode-build/) |
| Research, with versions and links | [research/](research/) |
| Design boards | Canvas <https://claude.ai/artifact/DXzWX7bnxWX3i2zJCy1A8J> (private); copies in [design/](design/) |
| App icon source | `resources/icon/mapo.svg` |

## 4. Pre-flight (the user, before starting the run)

1. **Screen Recording.** Grant it to the terminal app that will run the agent: System Settings › Privacy & Security › Screen & System Audio Recording, then restart that app. Pixel screenshots (`screencapture -l`) depend on it. Without it, drives still run on semantic snapshots and report `pixels: unavailable`.
2. **Keep the Mac awake and the display unlocked** if you want pixel evidence, for example with `caffeinate -dimsu` in a spare terminal. Screenshots of a locked display come out blank. Semantic snapshots work either way.
3. **Start Claude Code in `~/code/mapo-native`** so AGENTS.md (CLAUDE.md) loads. Use a permission mode that allows the following without prompting:
   - build and toolchain: `cargo`, `rustup`, `xcodebuild`, `xcodegen`, `swift`, `just`, `mprocs`
   - installs: `brew install jq zig`, `cargo install typeshare-cli`
   - repository: `git` (add and commit only)
   - downloads: `curl`, `gh release download`
   - running and inspecting: `open`, `screencapture`, `kill` for its own PIDs, `sqlite3`
   - network access to crates.io, github.com and objects.githubusercontent.com, with ziglang.org as a fallback.
4. **Optional:**
   - `brew install zig` is only needed if the prebuilt GhosttyKit fails; Zig 0.16 is required.
   - Leaving the frozen Mapo running is fine: the native app uses different bundle ids, sockets and data.

Machine, verified 2026-09-28:

- macOS 27.0 on arm64, Xcode 27.0, Swift 6.4, Rust 1.96
- present: xcodegen, just 1.46, mprocs 0.9.6, gh, brew, Claude Code 2.1.284
- missing: zig, sccache (both optional)
- check `jq` with `command -v jq`, and install it with brew if it's absent.

## 5. How to run the night

- **Scope.** All PLAN tasks in order: T0.1 to T0.11 (M0), then M1, M2, M3, M4 and T5.1. Parallel workers are allowed where PLAN marks tasks as independent (§7 below).
- **Loop per task** (PLAN §1):
  1. read the task and its requirement IDs
  2. implement
  3. `just build`
  4. drive it (`mapo …`, `mapo ui …`, `just drive …`)
  5. read the evidence as a user would: does it look right, feel fast, keep focus?
  6. fix and repeat until the acceptance holds
  7. commit (`type(scope): summary`)
  8. add a PROGRESS.md entry with the evidence path.
- **Definition of done:** the task's acceptance holds in the running app and has evidence. Nothing counts as done because it compiles.
- **Unit tests** only for pure logic (ENGINEERING §8).
- **When stuck:**
  - Respect the timeboxes: GhosttyKit 2 h, then the SwiftTerm fallback (PLAN T0.8); any other single blocker 90 min.
  - Then record the blocker in PROGRESS.md under "Needs the user" or "Blockers", and move on to the next task that isn't blocked.
  - Never stall the night on one problem.
- **When the docs are ambiguous:**
  1. Precedence is DECISIONS > REQUIREMENTS > UX, PROTOCOL, ARCHITECTURE > ENGINEERING > PLAN.
  2. If it's still unclear, pick the simplest option that keeps the app drivable and isolated, and record it under "Deviations" in PROGRESS.md.
  3. Fix the spec in the same commit when the spec was wrong.

## 6. Hard rules

1. **Isolation.** Use your instance (`dev-mapo-native`, or `drive-*` for drives). Never use instance `main`. Never touch `~/code/mapo`, `/Applications/Mapo.app`, `~/.mapo` or `~/Library/Application Support/Mapo`.
2. **Processes.** Stop only processes you started. Use the PID files and `just kill`, never broad `pkill -f`. Other Claude sessions, the frozen Mapo and the user's servers must keep running.
3. **Git.** Commit on `native`, or on `native-<topic>` branches in extra worktrees that you merge back fast-forward or with a clean rebase. Never push, force-push, rewrite `mapo`, or delete branches you didn't create.
4. **System.** Don't change system settings or default apps. Don't register login items, launch agents or global hotkeys. Don't install anything outside Homebrew or cargo.
5. **Claude inside drives.** Use disposable folders under `$TMPDIR` and harmless prompts, and accept Claude's folder trust only for those folders. If Claude's own permission reviewer refuses something, record it and continue. Never weaken permissions or route around a refusal.
6. **Decisions.** Don't reopen [DECISIONS.md](DECISIONS.md). If reality forces a change to a "User" decision, stop that line of work, write it under "Needs the user", and continue elsewhere.
7. **Models.** Work on Opus. Use a Fable subagent only for a critical review at the M0 boundary, or for a genuinely hard question. Superpowers skills are opt-in; don't invoke them.

## 7. Parallel work, helper sessions and escalation

- **Roles.** The session that runs the `/goal` is the **coordinator**. It owns the plan order, merges, drives and PROGRESS.md.
- **Workers.** For the first overnight run (2026-09-28) the user created five extra Claude sessions for the coordinator to use: `mapo-bf`, `mapo-2b`, `mapo-02`, `mapo-07`, `mapo-30`.
- **Run of 2026-09-28/29.** The session `mapo-native` never processed its kickoff: the message sat in its queue and the session stayed "waiting". At 23:40, `mapo-32` made **`mapo-bf` the coordinator**. The workers are `mapo-2b`, `mapo-02`, `mapo-07` and `mapo-30`, plus Opus subagents. If `mapo-native` wakes up later, it must not start a second run; it asks `mapo-bf` for a task instead.
  - Find them with `ListAgents`, and hand them tasks with `SendMessage`.
  - Opus subagents (the Agent tool) are also allowed.
  - Keep at most five workers active at once, so builds don't starve each other. Don't use other sessions the user didn't list (for example `mapo-22` and `mapo-fe`); they belong to other work.
- **Each worker** gets its own worktree, branch and instance, and its own `target/` and `.build/`:

  ```
  git -C ~/code/mapo-native worktree add ../mapo-native-<topic> -b native-<topic> native
  ```

  Its instance is `dev-mapo-native-<topic>`. Tell each worker to read `~/code/mapo-native/AGENTS.md`, this file and its PLAN task(s) first. Its message should name the exact task IDs, the acceptance, the worktree path, and "commit on your branch, never push, report back with SendMessage when done or blocked".
- **Good parallel splits:**
  - the Rust daemon track (T0.3 to T0.6)
  - the Swift app track (T0.7, then T0.8 once `mapo attach` exists)
  - GhosttyKit acquisition (the first half of T0.8)
  - later, the independent M1 tasks marked in PLAN (Files inspector, editor, palette, appearance).
- **The coordinator** merges worker branches back into `native`, fast-forward or by clean rebase. After every merge it runs `just build` and the relevant drive, and it keeps PROGRESS.md current.
- **Escalation.** Report urgent issues to the session `mapo-32` with `SendMessage`. `mapo-32` ran the interview and holds its full context. Urgent means:
  - a hard rule would have to be broken
  - a "User" decision looks impossible or wrong
  - every remaining task is blocked
  - something risks the user's data, machine or daily app
  - a security concern.

  Send one message with the facts and the options, and continue with unblocked work while you wait. Anything only the user can decide goes under "Needs the user" in PROGRESS.md.

## 8. Stopping and the morning report

- Stop starting new tasks at **08:00 America/Sao_Paulo**. Finish the in-flight task or revert it to a clean state.
- Stop every instance you started. Leave the tree committed and clean.
- Write the morning report at the top of [PROGRESS.md](PROGRESS.md) using the template in [PLAN.md](PLAN.md):
  - what works, with evidence paths and 2–5 screenshots copied into `docs/progress/`
  - metrics against the budgets
  - deviations
  - blockers and what needs the user
  - the exact next task
- A Fable critical review of M0 is welcome before the report, if time allows. Put its findings in the report; fix only clear bugs.

## 9. The `/goal` prompt

Paste this into Claude Code started in `~/code/mapo-native`:

```
/goal Build Mapo native from docs/PLAN.md in ~/code/mapo-native (branch `native`), in order: M0 end to end, then M1, M2, M3, M4 and T5.1, as far as the night allows.

Read AGENTS.md, docs/HANDOFF.md and docs/PLAN.md first; treat docs/DECISIONS.md, REQUIREMENTS.md, UX.md, ARCHITECTURE.md, PROTOCOL.md and ENGINEERING.md as the spec. For every task: implement, `just build`, then validate by driving the real daemon and app (mapo CLI, `mapo ui …`, `just drive …`), read the evidence like a user would (looks right, feels fast, keeps focus), fix until the task's acceptance holds, commit one small verified slice (never push), and log it in docs/PROGRESS.md with the evidence path. M0 must pass `just drive m0-skeleton` before M1 starts.

You are the coordinator. You may parallelize independent PLAN tasks with Opus subagents and with the five helper sessions the user created (mapo-bf, mapo-2b, mapo-02, mapo-07, mapo-30; find them with ListAgents, brief them with SendMessage per HANDOFF §7): at most five workers, each in its own worktree/branch/instance, you merge and re-drive after every merge, and you own PROGRESS.md. Escalate urgent issues (HANDOFF §7 defines urgent) to the session mapo-32 with SendMessage and keep working on unblocked tasks meanwhile.

Hard rules: use your own MAPO_INSTANCE (dev-mapo-native, dev-mapo-native-<topic>, drive-*); never touch ~/code/mapo, /Applications/Mapo.app, instance `main`, ~/.mapo or ~/Library/Application Support/Mapo; don't use sessions other than the five helpers and mapo-32; stop only processes you started; don't reopen docs/DECISIONS.md — record conflicts under "Needs the user" and move on; respect PLAN timeboxes (GhosttyKit 2 h → SwiftTerm fallback; any other blocker 90 min → record it and continue with the next unblocked task); don't change system settings or register login items; in drives that run real Claude use disposable folders and harmless prompts and never work around a permission refusal. Work on Opus; use a Fable subagent only for a critical review at milestone boundaries.

Stop starting new tasks at 08:00 America/Sao_Paulo, finish or cleanly revert in-flight work (yours and the workers'), stop every instance you or they started, and write the morning report at the top of docs/PROGRESS.md using the template in docs/PLAN.md.
```

## 10. After the run (for the user)

- Read the morning report in [PROGRESS.md](PROGRESS.md) and look at `docs/progress/` screenshots.
- `cd ~/code/mapo-native && just app` to try it. It launches the dev instance and never touches the frozen Mapo.
- Resolve anything under "Needs the user", then start the next run with the same prompt; it continues from PROGRESS.md.
