# Drives

A drive is a scripted walkthrough that uses the real Mapo app the way a person does and leaves evidence: semantic snapshots, screenshots, timings and a summary. Drives are Mapo's acceptance checks; unit tests cover only pure logic. [ENGINEERING.md](../docs/ENGINEERING.md) §5 is the full contract. This page is the short version.

## Running a drive

```sh
just setup                             # once per worktree
just drive m0-skeleton                 # build, run, print the evidence folder
just profile=release drive m5-switch   # Release build, for the budgets
DRIVE_KEEP=1 just drive m1-daily       # leave the instance running for inspection
```

A run builds this worktree, starts a throwaway instance `drive-<name>-<HHMMSS>` with its own daemon and app, runs the steps, writes `evidence/<name>/<YYYYMMDD-HHMMSS>/`, stops only the processes it started, and prints the evidence path as its last line. Exit 0 means every check passed. `zsh drives/<name>.sh` also works but skips the build.

- Pixels need Screen Recording for the terminal app that runs the drive ([HANDOFF.md](../docs/HANDOFF.md) §4). Without it the drive continues on snapshots and records `pixels: unavailable`.
- One drive runs at a time on the machine (lock `~/Library/Caches/mapo/drive.lock/`) because drives activate their window. Builds in other worktrees keep going. A drive takes keyboard focus, so don't type in other apps while one runs.
- A drive never touches your worktree's instance (`dev-…`), other drives, instance `main` or the frozen app.

## Writing a drive

```zsh
#!/usr/bin/env zsh
# drives/palette-focus.sh: ⌘K opens the palette with its field focused.
set -euo pipefail
source "${0:A:h}/lib.sh"

drive_begin palette-focus

step "Open the palette with ⌘K"
timing palette-open mapo ui key cmd+k
mapo ui wait palette.field --state focused --timeout-ms 1000 >/dev/null
ui_snapshot palette; ui_shot palette
expect_json '.focus.id' '"palette.field"' < "$SNAP"

drive_end
```

The name is `[a-z0-9-]`, at most 19 characters, and matches the file name. ENGINEERING §5.6 has a complete example with the CLI and pattern waits.

## Helpers in `lib.sh`

| Helper | Use | Does |
|---|---|---|
| `drive_begin` | `drive_begin NAME` | Takes the lock; creates the instance, `$EVIDENCE` and `$DRIVE_TMP`; tees output to `log.txt`; starts the daemon and the app; takes the launch snapshot and shot, which set `PIXELS`; installs the EXIT trap. |
| `step` | `step "text"` | Starts step `NN` and logs it with the elapsed time. |
| `mapo` | `mapo ARGS…` | This worktree's `mapo`, bound to the drive instance, JSON output, operator credential. Logs every call. |
| `ui_snapshot` | `ui_snapshot STEP` | Writes `snapshot-NN-STEP.json` and sets `$SNAP`. |
| `ui_shot` | `ui_shot STEP` | Writes `shot-NN-STEP.png` when pixels are available and sets `$SHOT`. Never fails the drive. |
| `expect_json` | `… \| expect_json FILTER EXPECTED` | Passes when `jq -c FILTER` on stdin equals EXPECTED, read as JSON (`1`, `true`, `'"idle"'`). A failure logs actual and expected, takes a `fail` snapshot and shot, and returns 1. |
| `timing` | `timing NAME CMD…` | Runs CMD (a command or a function), records its ms and `BUDGET_MS[NAME]` in `timings.json`, returns its status. |
| `drive_end` | `drive_end` | Final snapshot, shot, `ui metrics` and `debug stats`; stops the app and daemon it started; writes `summary.md` and `timings.json`; cleans up on pass; exits 0 or 1. |

Variables: `MAPO_ROOT`, `MAPO_PROFILE`, `DRIVE_INSTANCE`, `EVIDENCE`, `DRIVE_TMP` (for test repos and files), `DRIVE_STEP`, `SNAP`, `SHOT`, `PIXELS`.

Knobs: `DRIVE_CONFIG=drives/fixtures/<file>.toml` starts the instance with that config. `DRIVE_KEEP=1` leaves it running (stop it with `just instance=<instance> kill`). `DRIVE_ENFORCE_BUDGETS=1` fails the drive when a budget is exceeded. `DRIVE_NOLOCK=1` skips the lock for a snapshot-only run.

## Rules

1. Act through the UI (`mapo ui key`, `click`, `type`). Use the CLI to set up and to verify.
2. Every step leaves a snapshot. Steps a person would look at also take a shot.
3. Wait, never sleep: `mapo ui wait`, `mapo tab wait`, `mapo instance wait`. A pattern wait (`tab wait --until TEXT`) sees only output that arrives after it starts, so start it in the background before the action and `wait` for it after.
4. Check what a person or an agent would see: rail rows, focus, state words, terminal text, CLI results. Not internals.
5. Stay self-contained. Files and repositories go in `$DRIVE_TMP`, settings in a `DRIVE_CONFIG` fixture. Don't depend on your own instances, config or the network. `m2-agents` and `m3-control` run the real `claude` with harmless prompts in disposable folders.
6. Finish in under 3 minutes; `m5-switch` is the exception.
7. Never `pkill` or `killall`. The helpers stop exactly the pids they started.
8. In zsh, never run a command kept in a variable (`$CMD args` doesn't word-split). Use a function.

## Reviewing the evidence

Passing checks are necessary, not sufficient. Read the evidence like a user would (ENGINEERING §5.5):

1. `summary.md` first. On a failure, the `fail` snapshot and shot.
2. The shots in order: what changed, and anything that looks wrong (blank panes, focus ring, clipped text, colors, glass).
3. Timings against the budgets and against the previous run of the same drive.
4. Focus after every action. Background events never move it.
5. Copy: state words, title case, "…" on commands that prompt, no ids or `null`.
6. Write the Review section of `summary.md`. Copy the screenshots that tell the story into `docs/progress/`.

## Planned drives

| Drive | Task | Purpose |
|---|---|---|
| `m0-skeleton` | T0.11 | Launch, ⇧⌘N, ⌘T, type into a Ghostty terminal, relaunch the app and see the same screen reattach; M0 CLI verbs, identifiers, no TCP, timings. |
| `m1-daily` | T1.10 | The daily core: S2 rail, splits and focus moves, workspace switch within 50 ms, Files following `cd`, file pane editing, ⌘K palette, keyboard map. |
| `m2-agents` | T2.6 | A real Claude agent tab: hook status Working, Needs you, Done; ⇧⌘X interrupt; rail word, dock badge, notification log, ⌘J; resume after a daemon restart. |
| `m3-control` | T3.7 | The control plane: CLI parity, JSON output and exit codes, `--force` guards, activity log, `tab run/ask/wait/read/send`, event cursors, `mapo mcp` tools. |
| `m4-servers-changes` | T4.4 | A dev server in an ordinary tab gets the server icon and `:PORT`; a failed exit; ports list and safe stop; Changes inspector, diff and gutter. |
| `m5-switch` | T5.1, T5.3 | A Release build at daily scale (20 tabs, 10 visible) against every R-NF-1 budget, plus daemon restart and resume, for the switch-over checklist. |
