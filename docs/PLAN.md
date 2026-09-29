# Mapo native: implementation plan

Status: ready for the first overnight run, written 2026-09-28. The implementing agent executes this plan one task at a time. It builds what [REQUIREMENTS.md](REQUIREMENTS.md) asks for, to the look in [UX.md](UX.md), in the way [ARCHITECTURE.md](ARCHITECTURE.md) describes, speaking [PROTOCOL.md](PROTOCOL.md), with the dev loop, drives and budgets from [ENGINEERING.md](ENGINEERING.md). [HANDOFF.md](HANDOFF.md) has the rules for a night, and [ROADMAP.md](ROADMAP.md) is the one-page view. When documents disagree, precedence is DECISIONS > REQUIREMENTS > UX, PROTOCOL, ARCHITECTURE > ENGINEERING > PLAN (HANDOFF §5).

| Symbol | Meaning in every task |
|---|---|
| `$ROOT` | The worktree root: `~/code/mapo-native` or a parallel worktree. Run commands from here. |
| `$I` | Your instance: `dev-<worktree folder>` (ENGINEERING §2.1), so `dev-mapo-native` here |
| `$DATA` | `~/Library/Application Support/dev.mapo.app/instances/$I` |
| `$RUN` | `$(getconf DARWIN_USER_TEMP_DIR)mapo` |
| `$APP` | `$ROOT/.build/xcode/Build/Products/Debug/Mapo.app` |
| `$EVIDENCE` | The current evidence folder, `evidence/<drive-or-task>/<YYYYMMDD-HHMMSS>` |
| `mapo` | `just mapo …`: `target/debug/mapo --instance $I` with tab tokens unset. Inside a drive it is the `drives/lib.sh` function bound to the drive's instance. |
| `# →` | The observable result that must hold |

## 1. How to use this plan

### 1.1 The loop per task

1. **Read** the task, every requirement ID it lists, and the spec sections it cites. Check docs/PROGRESS.md for "Needs the user", "Blockers" and "Deviations" entries that touch it.
2. **Implement** in small steps that keep `just build` green.
3. **Build** with `just build`. Run `just lint` before each commit.
4. **Drive.** Run the task's acceptance against a fresh instance the way a user would: CLI JSON, `mapo ui snapshot`, `just snap`. From T0.3 on, save the acceptance as a drive, `drives/task-<id>.sh` (for example `task-t0-5`), so later tasks rerun it with `just drive task-t0-5`. T0.2 records its evidence by hand.
5. **Review the evidence** as ENGINEERING §5.5 describes: look at every shot in order, compare timings with budgets, check focus and copy, and fill in the Review section of `summary.md`. Does it match UX.md? Is focus where a person expects it? Is it fast?
6. **Commit** one verified slice (§1.3).
7. **Log** an entry in PROGRESS.md: task ID, done, partial or blocked, the evidence path, the numbers measured, the review verdict, and any deviation.

### 1.2 Definition of done

- The acceptance passes on a fresh instance: a drive instance, or your dev instance after `just kill && just clean-instance`.
- `summary.md` lists every check with pass or fail and the observed value, and its Review section is filled in (ENGINEERING §5.4, §5.5).
- `just build`, `just lint` and `just test` are clean. Unit tests exist only for pure logic (ENGINEERING §8).
- Every new interactive control has its identifier (ENGINEERING §4.2, UX §2.4) and a VoiceOver label that speaks its state. Once the app exists, the identifier check in ENGINEERING §4.2 prints 0.
- No token appears in logs, events or activity: `grep -rFf "$DATA/app.token" "$DATA/logs"` prints nothing (`-f` keeps the token out of grep's argv). The run's logs have no panics and no unexplained errors.
- Nothing listens on TCP: `lsof -nP -a -iTCP -sTCP:LISTEN -p <daemon pid>,<app pid>` prints nothing.
- The behavior matches the specs, or the deviation is recorded (§1.4) with the spec fixed in the same commit.
- The slice is committed and PROGRESS.md is updated. "It compiles" and "tests pass" are not done.

### 1.3 Commits

Follow ENGINEERING §9: `type(scope): summary`, imperative, at most 72 characters, with types `feat`, `fix`, `perf`, `refactor`, `test`, `docs`, `build` and `chore` and the scopes listed there. The body says why, then names the task and the drive run:

```
feat(term): run tab shells in daemon-owned PTYs

Tabs must outlive the app (R-TAB-6), so the daemon owns the PTY and the emulator.

Task: T0.5
Drive: task-t0-5 PASS evidence/task-t0-5/20260929-021502
```

A task may take several commits, and each one builds. Add the attribution trailer your session instructions require. Never push or force-push, and never touch the branches `main` or `mapo`.

### 1.4 Recording deviations

The code sometimes has to differ from a spec: a doc is wrong, an API doesn't exist, or a clearly simpler local choice exists. Then:

1. Apply the precedence above. Never override a **User** decision in DECISIONS.md. Write it under "Needs the user" in PROGRESS.md, stop that line of work and continue elsewhere.
2. Pick the simplest option that keeps Mapo drivable and isolated.
3. Fix the spec in the same commit.
4. Add a row to "Deviations" in PROGRESS.md with the task, the spec and section, what it said, what you did and why.

The specs were corrected on 2026-09-28 after this plan was drafted: the binary lives at `Contents/Helpers/mapo`, terminfo at `78/`, zsh integration is written in-house, and `cursor_expired` goes in `details.reason`. No prescribed deviations remain. Record any new ones as described above.

### 1.5 When blocked

- Every task has a budget. At one and a half times the budget without convergence, take its fallback. The hard timeboxes are 2 h for GhosttyKit in T0.8 (then SwiftTerm), 90 min for raw replay fidelity in T0.6 (then grid replay), and 90 min for any other single blocker.
- Leave the tree clean. Commit what works behind a config flag, or `git stash` the rest. Never commit a broken build.
- Write a "Blockers" entry in PROGRESS.md with the symptom, the exact error, what you tried and the next idea. Then move to the next task whose dependencies are met (§3.1).
- Anything that needs a human goes under "Needs the user": a system permission dialog, System Settings, a login, a User decision. Keep working elsewhere. Never weaken a guardrail to get unblocked.

### 1.6 Evidence

ENGINEERING §5.4 defines the folder: `summary.md` (result, steps, failures, budgets, review), `timings.json`, `snapshot-NN-STEP.json`, `shot-NN-STEP.png` (only with pixels) and `log.txt`. `evidence/` is gitignored. Copy the two to five screenshots that tell a milestone's story into `docs/progress/<task>-<step>.png` for the morning report. Without Screen Recording permission, follow ENGINEERING §4.6: keep driving on snapshots, list visual claims under "Not verified", and never say the UI looks right.

## 2. Guardrails

HANDOFF §6 and ENGINEERING §2.8 have the full lists. In short:

- **Instances.** Use your own: `dev-mapo-native`, `dev-mapo-native-<topic>` in a parallel worktree, `drive-<name>-<HHMMSS>` in a drive. Never `main`. The justfile never reads `MAPO_INSTANCE`, every recipe refuses `instance=main`, and worktree binaries refuse to serve, stop or clean `main`.
- **Never touch** `~/code/mapo`, the branches `main` and `mapo`, `/Applications/Mapo.app` (the frozen VS Code build, bundle id `dev.mapo.Mapo`), `~/.mapo` or `~/Library/Application Support/Mapo`.
- **Processes.** Stop only processes you started, through pid files (`just kill`, `mapo instance stop`) or the pids a drive recorded. Never `pkill`, `killall`, `open -a Mapo` or AppleScript by name: the frozen app is also called `Mapo`.
- **Git.** Commit on `native`, or on `native-<topic>` in a parallel worktree that you rebase and fast-forward into `native`. No push.
- **System.** Change no system settings, default apps, login items, launch agents or global hotkeys. Install tools only with Homebrew or cargo (HANDOFF §4).
- **Claude in drives.** Disposable folders under `$TMPDIR`, harmless prompts, folder trust accepted only for those folders. Never weaken permissions or route around a refusal. §5 has the full rules.
- **Stop time.** Run `TZ=America/Sao_Paulo date +%H:%M` before starting each task. At 08:00 or later, start nothing new. Finish or cleanly revert the task in flight, stop every instance you started, and write the morning report (§6).

## 3. M0: walking skeleton, drivable from day one

Exit criteria: `just drive m0-skeleton` passes (T0.11). A Ghostty terminal served by the daemon through `mapo attach` survives quitting and relaunching the app and restarting the daemon. The drive creates the workspace and tab through `mapo ui` and records timings.

### 3.1 Dependency graph and parallel tracks

```
T0.1 ─► T0.2 ─► T0.3 ─► T0.4 ─► T0.5 ─► T0.6 ───────────────────┐
  │                        │                                    ▼
  │                        └─► T0.7 ─► T0.9 ──────────────► T0.8b ─► T0.10 ─► T0.11
  └─► T0.8a  fetch, verify and link GhosttyKit ───────────► T0.8b
```

On a single tree, work in ID order with two exceptions: T0.9 may come before T0.8b, whose acceptance uses `mapo ui`, and T0.8a may run any time after T0.1. HANDOFF §7 allows up to five parallel workers, Opus subagents or the user's helper sessions, each in its own worktree (ENGINEERING §2.7 has the commands):

| Track | Worktree, branch, instance | Tasks | Starts after | Owns |
|---|---|---|---|---|
| Daemon | `../mapo-native-daemon`, `native-daemon`, `dev-mapo-native-daemon` | T0.3 to T0.6 | T0.2 is on `native` | `crates/`, `resources/shell-integration/` |
| App | `../mapo-native-app`, `native-app`, `dev-mapo-native-app` | T0.7, T0.9 | T0.4 is on `native` | `app/` except `MapoTerminal` |
| Ghostty | `../mapo-native-ghostty`, `native-ghostty`, `dev-mapo-native-ghostty` | T0.8a | T0.1 is on `native` | `third_party/`, `scripts/ghostty.sh`, `resources/terminfo/`, `MapoTerminal` |
| Coordinator | `~/code/mapo-native`, `native`, `dev-mapo-native` | merges, T0.8b, T0.10, T0.11 | | PROGRESS.md |

Land protocol changes on `native` first as small additive commits, and rebase before merging; the hotspots are in ENGINEERING §7. With three builds running, set `MAPO_JOBS=4`.

### T0.1 Repo scaffolding

**Goal.** Both halves exist, build with one command and pin their toolchains. Every contract recipe exists. **Requirements.** R-ENG-4, R-ENG-5, R-NF-2, R-NF-4 (usage strings, hardened runtime).

**Deliverables.**
- `Cargo.toml` as a workspace with `resolver = "3"`, `[workspace.package] edition = "2024"`, and `[workspace.lints]` from ENGINEERING §9 (`clippy::unwrap_used`, `expect_used` and `panic` denied, `unsafe_code = "deny"`) plus `clippy.toml` allowing both in tests. `[workspace.dependencies]`: tokio 1 (`rt-multi-thread`, `macros`, `net`, `io-util`, `sync`, `time`, `signal`, `process`, `fs`), serde, serde_json, thiserror, anyhow, tracing, tracing-subscriber, tracing-appender, clap 4 (`derive`, `env`), uuid 1 (`v7`, `serde`), rusqlite (`bundled`), base64, getrandom, libc, rustix (`fs`, `process`, `termios`), `pty-process = { version = "=0.5.3", features = ["async"] }`, `alacritty_terminal = "=0.26.0"`, typeshare 1. Check each version with `cargo info <crate>` before pinning (ARCHITECTURE §3.1).
- `rust-toolchain.toml` (`channel = "1.96.0"`, `rustfmt`, `clippy`) and `.cargo/config.toml` with `[env] MACOSX_DEPLOYMENT_TARGET = { value = "26.0", force = true }`.
- Library stubs for `crates/mapo-protocol`, `mapo-instance`, `mapo-core` and `mapo-term`, and the binary crate `mapo` with `mapo --version`. Create `mapo-git` in T1.1, `mapo-agent` in T2.2, `mapo-mcp` in T3.5 and `mapo-proc` in T4.1.
- `app/project.yml`; `app/Mapo/` with `main.swift`, `AppDelegate.swift`, `Info.plist` and `Mapo.entitlements`; `app/Packages/MapoKit/Package.swift` (tools 6.2, `.macOS("26.0")`) with `MapoProtocol` in Swift 5 mode, `MapoClient`, `MapoTerminal`, `MapoEditor`, `MapoUI` and `MapoAutomation` in Swift 6 with `.defaultIsolation(MainActor.self)`, and pure-logic test targets such as `MapoProtocolTests`. A `.swift-format` with 4-space indent, 120 columns and the rules in ENGINEERING §9.
- `scripts/embed.sh`, the Xcode run-script phase from ENGINEERING §3.3. It copies `target/$MAPO_PROFILE/mapo` to a temp file next to `Mapo.app/Contents/Helpers/mapo`, signs it with the app's identity and `--options runtime`, and `mv -f`s it into place, so a running daemon keeps its old inode. It copies `resources/shell-integration/`, `resources/terminfo/` and (from T2.1) `plugin/` into `Contents/Resources/`, and creates `Contents/Resources/bin/mapo -> ../../Helpers/mapo`. The binary never goes in `Contents/MacOS/`: APFS is case-insensitive, so `MacOS/mapo` would be `MacOS/Mapo` (ARCHITECTURE §2).
- A `justfile` with every recipe and variable from ENGINEERING §3.1 and §3.2 (`instance`, `profile`, `jobs`, `task`; `[positional-arguments]` and `"$@"` so quoting survives). A recipe whose task hasn't landed prints `not yet: PLAN T0.x` and exits 1.
- `mprocs.yaml` exactly as in ENGINEERING §3.4, started by `just dev`.
- `.gitignore` already ignores `target/`, `.build/` (GhosttyKit is linked from `.build/ghostty/`), `app/Mapo.xcodeproj/`, `MapoProtocol/Generated/` and `evidence/`. Extend it if new generated paths appear.

The essentials of `app/project.yml` (ENGINEERING §2.6 and §10 have the rest: display name "Mapo Dev", entitlements and usage strings, signing identity):

```yaml
name: Mapo
options: { bundleIdPrefix: dev.mapo, deploymentTarget: { macOS: "26.0" } }
packages: { MapoKit: { path: Packages/MapoKit } }
targets:
  Mapo:
    type: application
    platform: macOS
    sources: [Mapo]
    dependencies: [{ package: MapoKit, products: [MapoProtocol, MapoClient, MapoTerminal, MapoUI, MapoAutomation] }]
    info: { path: Mapo/Info.plist, properties: { CFBundleDisplayName: Mapo Dev, LSMinimumSystemVersion: "26.0" } }
    entitlements: { path: Mapo/Mapo.entitlements, properties: { com.apple.security.device.camera: true, com.apple.security.device.audio-input: true } }
    settings:
      base: { PRODUCT_BUNDLE_IDENTIFIER: dev.mapo.app.dev, SWIFT_VERSION: "6.0", SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor,
              ENABLE_HARDENED_RUNTIME: YES, CODE_SIGN_IDENTITY: "-", ARCHS: arm64, ENABLE_USER_SCRIPT_SANDBOXING: NO }
    postBuildScripts:
      - { name: Embed mapo and resources, script: "\"$SRCROOT/../scripts/embed.sh\"",
          inputFiles: ["$(SRCROOT)/../target/$(MAPO_PROFILE)/mapo"], outputFiles: ["$(CONTENTS_FOLDER_PATH)/Helpers/mapo"] }
```

**Acceptance.**
```zsh
just setup      # → exit 0; tool versions listed; zig and sccache reported as optional
just build      # → exit 0, $APP exists, full log in .build/logs/xcodebuild.log
"$APP/Contents/Helpers/mapo" --version                                     # → mapo 0.1.0
codesign -dv "$APP" 2>&1 | grep -E 'Identifier=dev.mapo.app.dev|runtime'   # → both lines match
time just build # → a no-op build under 10 s (ENGINEERING P3)
git status --short                                                         # → no target/, .build/, Mapo.xcodeproj or Generated/
```

**Budget and fallback.** 45 min. If `xcrun swift-format` is missing, `just lint` skips Swift and says so. **Commits.** `build: scaffold cargo workspace, MapoKit and XcodeGen app`, then `build: add justfile, mprocs.yaml and embed script`.

### T0.2 Instance model

**Goal.** Every process resolves the same instance and paths, and nothing collides with another worktree, a drive or the installed app. **Requirements.** R-ENG-3, R-NF-4 (modes), R-PER-2 (paths); ENGINEERING §2.

**Deliverables.** `crates/mapo-instance`; `mapo instance show|list|wait|stop|clean` (client-side, PROTOCOL §9); `just mapo`, `just kill` and `just clean-instance`; the first part of `drives/lib.sh`.

**Steps.**
1. Resolution follows ENGINEERING §2.1 exactly: `--instance`, then `MAPO_INSTANCE`, then the worktree default, then `main`. The worktree default walks up from the real path of the process's own executable, not the cwd, to the first directory containing `.git`, and is `dev-<basename>`. It isn't normalized: a folder whose name doesn't give a valid instance name fails with a message to rename the folder or pass `--instance`. A binary inside a git worktree refuses `daemon`, `instance stop` and `instance clean` for `main`.
2. Paths and modes follow ENGINEERING §2.2: the data dir and runtime dir are created 0700, and a runtime dir owned by another user is refused. Pid files hold the pid on line 1 and the executable path on line 2. The app writes and removes `<I>.app.pid` itself (T0.7).
3. Tokens are 32 bytes from `getrandom`, base64url without padding, written to a temp file created 0600 and renamed into place. They live in a `Secret` type whose `Debug` and `Display` print `***`.
4. `mapo instance show [--json]` prints the name, its source (`flag`, `env`, `worktree` or `default`), the worktree, every path (including `socket` and `logDir`), `daemon: {running, pid, exe, bootId, protocol}` and `app: {running, pid}`. `list`, `wait`, `stop` and `clean` behave as the table in ENGINEERING §2.4 says. `stop` signals a pid only if its executable and argv still match the pid file.
5. The justfile: `instance := env_var_or_default("MAPO_DEV_INSTANCE", "dev-" + file_name(justfile_directory()))`, passed as `--instance {{instance}}` to every command. `just mapo` unsets `MAPO_TOKEN` and `MAPO_HOOK_TOKEN`. `just kill` stops the app through its pid file (same check as `just app`) and the daemon through `mapo instance stop`.
6. `drives/lib.sh` follows ENGINEERING §5.2. Build it in three stages: here the lock, instance naming, `EVIDENCE`, `step`, `expect_json`, `timing` and the `mapo` function; the daemon start and stop in T0.3; the app, `ui_snapshot` and `ui_shot` in T0.9. Until T0.9, `drive_begin` honors `DRIVE_NO_APP=1`, which starts only the daemon and skips the window wait and launch snapshot. The knob is additive: add it to ENGINEERING §5.2 in the same commit.

**Acceptance.**
```zsh
mapo instance show --json | jq -e '.name=="dev-mapo-native" and .source=="worktree"'
MAPO_INSTANCE=drive-x-000001 target/debug/mapo instance show --json | jq -e '.source=="env"'
target/debug/mapo --instance Bad_Name instance show; echo $?       # → 2, and the message quotes the regex
(cd /tmp && "$ROOT/target/debug/mapo" instance show --json | jq -r .name)   # → dev-mapo-native: the executable decides, not the cwd
target/debug/mapo --instance main instance clean; echo $?          # → 1, a worktree binary refuses main
stat -f '%Lp' "$(getconf DARWIN_USER_TEMP_DIR)mapo"                 # → 700
mapo instance show --json | jq -r .socket | awk '{print length($0)}' # → at most 91 on this machine
just instance=main kill; echo $?                                     # → 1, refused
just test                                                            # → name and path tests pass
```

**Budget and fallback.** 30 min. **Commits.** `feat(instance): resolve instances, paths and tokens; add mapo instance`.

### T0.3 Daemon skeleton

**Goal.** One daemon per instance that speaks the handshake and can be started, found and stopped safely. **Requirements.** R-PER-1, R-PER-4, R-NF-4, R-CTL-1, R-ENG-3; PROTOCOL §1 to §4, and `hello`, `ping`, `instance.info` and `daemon.shutdown` from §6.1.

**Deliverables.** `mapo daemon [--foreground]`. In `mapo-protocol`, the JSON-RPC envelope, error kinds with their codes and CLI exit codes (PROTOCOL §4), the hello types and method names. In the binary, `src/daemon/` with the listener, connections and dispatch. `mapo debug stats [--interval-ms N]`, client-side as ENGINEERING §6 describes: pids from the pid files, `proc_pid_rusage` for CPU time and physical footprint, tab counts from `state.snapshot`. A hidden dev verb `mapo rpc METHOD [PARAMS_JSON]` that prints the raw result and exits by error kind; list it in PROTOCOL §9 in the same commit. `just daemon`, and daemon start and stop in `lib.sh`.

**Steps.**
1. Start in the order of ENGINEERING §2.3. Resolve the instance and create the dirs. Take an exclusive, non-blocking `flock` on `<I>.lock`; if it fails, exit 1 with `instance <name> is already served by pid <pid> (<exe>)`. Write the pid file, open `state.db` (from T0.4), and write a fresh `app.token`. Remove a leftover socket, bind `tokio::net::UnixListener` under umask `0o177`, log `ready` and accept. Every 60 s, check that the socket file still exists, and rebind if a temp-dir cleanup removed it.
2. Without `--foreground`, `mapo daemon` detaches. If a daemon already answers `ping`, it prints `{"pid":…,"socket":"…"}` and exits 0. Otherwise it spawns `current_exe daemon --foreground --instance <I>` with `pre_exec(|| { libc::setsid(); Ok(()) })` and stdio on `/dev/null`, waits up to 10 s for `ping`, and prints the same JSON, or exits 1 with the reason. The app's auto-spawn and the drives use this mode.
3. On accept, `peer_cred()` must report your uid; drop anything else. Each connection gets a reader task (NDJSON, at most 8 MiB per line, else `invalid_argument` and close), a writer task that drains an mpsc carrying responses and events, and one task per request, so responses may arrive out of order.
4. `hello` must come first, or the daemon answers `invalid_argument` and closes. A `protocol` other than 1 gets `unavailable` with `data.daemonProtocol: 1`. M0 accepts the `app` credential, compared in constant time with this boot's token, and the `tab` credential from T0.5. Store the caller on the connection. Params use `#[serde(deny_unknown_fields, rename_all = "camelCase")]`, so an unknown field fails with `invalid_argument`.
5. `ping` returns `{bootId, uptimeMs}`, where the boot ID is a UUIDv7 like every other ID. `instance.info` returns the fields in PROTOCOL §6.1. `daemon.shutdown` needs the app credential, else `forbidden`. It emits `daemon.stopping`, stops accepting, hangs up the tabs (T0.5), flushes SQLite, removes the socket and pid file, and exits 0. SIGTERM and SIGINT do the same.
6. Logs go to `$DATA/logs/mapod.<date>.log` through `tracing-appender`, 7 files kept, one span per request (`id`, `method`, `caller`). `--foreground` also logs to stderr. `MAPO_LOG` takes an EnvFilter. Tokens only travel inside `Secret`.
7. The runtime is `new_multi_thread().worker_threads(2)`. Apart from the 60 s socket check, nothing ticks while idle: the idle CPU budget is under 0.5%.

**Acceptance.**
```zsh
just daemon                                            # in the background → "ready" in mapod.<date>.log
mapo instance wait --timeout-ms 5000; mapo rpc ping --json | jq -e '.bootId and .uptimeMs >= 0'
mapo rpc instance.info --json | jq -e '.socket and .daemonPid'
target/debug/mapo --instance $I daemon --foreground; echo $?     # → 1, "already served by pid N (<exe>)"
target/debug/mapo --instance $I daemon                 # → the same pid as JSON, exit 0
stat -f '%Lp' "$RUN/$I.sock"                           # → 600
mapo rpc ping '{"bogus":1}'; echo $?                   # → 2; stderr is {"error":…,"kind":"invalid_argument",…}
printf '{"jsonrpc":"2.0","id":1,"method":"ping","params":{}}\n' | nc -U "$RUN/$I.sock"   # → error: hello required
mapo debug stats --json | jq -e '.daemon.footprintBytes > 0'
T=$(cat "$DATA/app.token"); mapo instance stop         # → socket and pid file gone within 1 s
grep -rFf <(printf '%s\n' "$T") "$DATA/logs"           # → no output
```

**Budget and fallback.** 60 min. **Commits.** `feat(core): single-instance daemon with hello, ping, info and shutdown`.

### T0.4 Core state, SQLite, events, workspace and tab commands, CLI

**Goal.** Workspaces and tabs are daemon state that persists in SQLite, streams as events and works from the CLI. **Requirements.** R-WS-1, R-WS-3, R-TAB-3, R-TAB-8, R-PER-2, R-PER-3, R-CTL-1, R-CTL-3, R-CTL-5 (the M0 part), R-ST-1 (status skeleton).

**Deliverables.** The `mapo-core` actor; the pure `mapo-core::status` function with a table test; the persistence thread and `crates/mapo-core/migrations/0001_init.sql` (`meta`, `workspaces`, `tabs`, `layouts`); the event ring; `state.snapshot`, `events.subscribe`, `workspace.list|create|rename|activate|delete` and `tab.list|create|close|rename|focus` (tabs are definitions until T0.5 adds PTYs); the CLI verbs; `#[typeshare]` annotations, `just gen` and golden fixtures.

**Steps.**
1. The actor owns all state and receives `CoreMsg` values over an mpsc, each with a oneshot reply. It never awaits IO. After each mutation it sends a write batch to the SQLite thread, which applies it in one transaction; the actor never waits on disk.
2. IDs are UUIDv7 strings. The default workspace name is the first free `Workspace N`, from 1. Default tab names are `terminal-N` and `agent-N`, unique per workspace; a duplicate is a `conflict`. A given name sets `labeled` and is also the title; unlabeled tabs show the live title (T0.5).
3. Selectors follow PROTOCOL §5. A tab name resolves in the `workspace` param, else the caller's workspace, else the active one. With a `tab` credential, an omitted `tab` means the caller's own tab. `not_found` lists the workspace's tab names in `data.details.names`. An ambiguous workspace name is a `conflict` with the candidate IDs. `kind` accepts the aliases `terminal` and `claude`.
4. The M0 layout is one pane per workspace: `{workspaceId, focusedPaneId, root: {kind:"pane", id, content: {tab: <id>} | {empty: true}, recentFiles: []}}`. `tab.focus` activates the tab's workspace and shows the tab in the pane; from T0.5 it also retries a failed launch. With no workspace at all, `tab.create` first creates `Workspace 1` (PA-23).
5. Events live in a ring of 10,000 `Event {seq, bootId, at, type, data}`. `events.subscribe {after?, types?}` replays from `after + 1`, then streams. An `after` older than the ring fails with kind `conflict` and `details: {reason: "cursor_expired", oldestSeq}` (PROTOCOL §7). A subscriber whose outbound queue passes 1,000 events gets that error and is disconnected; the core never blocks on it.
6. `workspace.delete` fails with `forbidden` without `force` while a tab runs a foreground program (known from T0.5). Deleting the active workspace activates the next one.
7. `status(facts) -> (state, stateLabel)` is pure. In M0, a launch error gives `failed` with "Couldn't start", spawning gives `starting`, a stopped shell gives `stopped`, the span between OSC 133;C and D gives `running` with "Running", and a prompt gives `idle`. T1.4 and T2.2 complete it.
8. SQLite runs in WAL mode with `synchronous=NORMAL`. `PRAGMA user_version` selects numbered migrations embedded with `include_str!`. On start, load workspaces, tab definitions, layouts and the active workspace.
9. The CLI verbs, with clap: `workspace list|new [NAME]|rename NAME NEW|activate NAME|delete NAME [--force]`; `tab list|new [--name N] [--kind shell|agent] [--cwd DIR] [--cmd CMD]|close NAME [--force]|rename NAME NEW|focus NAME`; `status [NAME]`; `events [--follow] [--after SEQ] [--type T]`, which without `--follow` prints the ring after `SEQ` and exits. Global flags are `--instance`, `--workspace`, `--json` and `--timeout-ms`. The CLI prints tables on a TTY and compact JSON when piped or given `--json`, errors as PROTOCOL §4 says, and exit codes 1, 2, 5 and 124. It makes a relative `--cwd` absolute against its own cwd. It sends `MAPO_TOKEN` only when `MAPO_INSTANCE` equals the resolved instance, else the instance's `app.token` (PROTOCOL §3).
10. Swift types. Annotate protocol structs with `#[typeshare]` and serde renames (camelCase fields, kebab-case state values). `just gen` writes `app/Packages/MapoKit/Sources/MapoProtocol/Generated/`, rewriting a file only when its content changed, then runs XcodeGen with its cache (ENGINEERING §3.2). typeshare can't express internally tagged unions (`Node`, pane `content`, `Target`) or the per-type `Event.data`, so hand-write those in `MapoProtocol/Manual.swift`. A Rust test compares serialized samples with `crates/mapo-protocol/fixtures/*.json` (`UPDATE_FIXTURES=1` rewrites them), and `MapoProtocolTests` decodes and re-encodes every fixture. If typeshare costs more than 30 minutes, hand-write every Swift type against the fixtures; DECISIONS D-15 allows it.

**Acceptance.**
```zsh
mapo workspace new --json | jq -e '.name=="Workspace 1"'
mapo workspace new Obsess --json | jq -e '.name=="Obsess"'
mapo tab new --workspace Obsess --name be --cwd /usr/bin --json | jq -e '.labeled and .title=="be"'
mapo tab new --workspace Obsess --name be; echo $?                   # → 1, conflict
mapo tab focus nope --workspace Obsess; echo $?                      # → 1, not_found, and the error lists "be"
mapo events --after 0 --json | head -n 3 | jq -s -e 'map(.seq) == (map(.seq) | sort)'
mapo instance stop && target/debug/mapo --instance $I daemon && mapo workspace list --json | jq -e 'map(.name)==["Workspace 1","Obsess"]'
mapo workspace delete Obsess --force --json | jq -e .deleted
just test                                                            # → status and fixture tests pass on both sides
```

**Budget and fallback.** 90 min; the typeshare fallback is in step 10. **Commits.** `feat(core): workspaces and tabs with SQLite, events and CLI`, `build: generate Swift protocol types`.

### T0.5 PTY, shell integration, emulator, ring buffer, agent verbs

**Goal.** Every tab is a login shell owned by the daemon, with shell integration, a headless emulator, a replayable byte history, and `tab send`, `read`, `wait` and `run`. **Requirements.** R-TAB-1, R-TAB-2 (cwd default), R-TAB-4, R-TAB-5, R-TAB-6 (daemon side), R-TAB-7, R-TAB-9, R-TAB-12, R-PER-3, R-CTL-9, and behavior contracts 1, 5, 6 and 11 (REQUIREMENTS §8).

**Deliverables.** `crates/mapo-term` (spawn, environment, OSC pre-parser, emulator, ring buffer, text stream, tab task); `resources/shell-integration/zsh/.zshenv` and `mapo-integration.zsh`; `tab.send`, `tab.read`, `tab.wait`, `tab.run`, and the full `tab.create`, `tab.close` and `tab.focus`; CLI `tab send|read|wait|run`.

**Steps.**
1. **Spawn.** `let (pty, pts) = pty_process::open()?; pty.resize(pty_process::Size::new(24, 80))?;`, then `pty_process::Command::new(shell).args(["-l", "-i"]).current_dir(cwd).env_clear().envs(env).spawn(pts)?`. pty-process makes the child a session leader with the PTY as its controlling terminal (setsid and TIOCSCTTY); its builder methods take `self` by value. The shell is `[shell] program`, else `$SHELL`, else the passwd entry, else `/bin/zsh`. A missing or unreadable cwd spawns nothing and sets `launchError {kind: "cwd_missing" | "cwd_unreadable" | "spawn_failed", message, path}`; the definition stays (R-TAB-9). Launches are serialized per tab, so concurrent focus requests start exactly one process (contract 1).
2. **Environment.** Start from the daemon's environment and remove every inherited `MAPO_*` (the frozen app sets `MAPO_TAB_ID` and `MAPO_AGENT_TOKEN`; `just dev` sets `MAPO_DEV_INSTANCE`), `CLAUDECODE` and every `CLAUDE_CODE_*` (contract 11: the overnight agent runs inside Claude Code), plus `GHOSTTY_*`, `TERM_PROGRAM*`, `TERMINFO*`, `ITERM_*`, `KITTY_*`, `VSCODE_*`, `TMUX*`, `SHLVL`, `COLUMNS`, `LINES`, `PWD` and `OLDPWD`. Then set the R-TAB-4 variables: `MAPO_INSTANCE`, `MAPO_WORKSPACE_ID`, `MAPO_TAB_ID`, `MAPO_TAB_NAME`, `MAPO_TOKEN`, and `MAPO_HOOK_TOKEN` for M2. Also `MAPO_BIN_DIR` and `PATH=$MAPO_BIN_DIR:<inherited PATH>`, and `TERM=xterm-ghostty` with `TERMINFO=<resources>/terminfo`, falling back to `xterm-256color` when `terminfo/78/xterm-ghostty` is missing. Add `TERM_PROGRAM=ghostty`, `COLORTERM=truecolor`, `LANG=en_US.UTF-8` when unset, and `ZDOTDIR=<resources>/shell-integration/zsh`, saving any previous `ZDOTDIR` in `MAPO_ZSH_ZDOTDIR`. T2.1 adds `CLAUDE_CODE_PLUGIN_DIRS`. Resources and `MAPO_BIN_DIR` follow ENGINEERING §3.3: inside a bundle, `../Resources/` and `Contents/Resources/bin`; otherwise the worktree root and the daemon's own directory.
3. **zsh integration.** Write it yourself (ARCHITECTURE §3.4). Ghostty's zsh and bash files are GPL-3.0 (derived from Kitty; the file headers say so), so read them for ideas only.
   - `.zshenv` restores `ZDOTDIR` from `MAPO_ZSH_ZDOTDIR` (or unsets it), sources the user's `${ZDOTDIR:-$HOME}/.zshenv`, then, in interactive shells, sources `mapo-integration.zsh`. zsh reads the user's `.zprofile`, `.zshrc` and `.zlogin` from the restored `ZDOTDIR` on its own.
   - `mapo-integration.zsh` only registers a one-shot `precmd` hook. It runs at the first prompt, after every rc file. It installs the real hooks at the end of `precmd_functions` and puts `$MAPO_BIN_DIR` back at the front of `path`, because `/etc/zprofile` runs `path_helper` and rc files reorder PATH.
   - `precmd` saves `$?` in its first statement. If a command ran, it emits `OSC 133;D;<status>`. It emits `OSC 7` (`file://$HOST` plus the percent-encoded `$PWD`) and `OSC 2` (the cwd shortened with `~`), and wraps `OSC 133;A` at the start of `PS1` and `OSC 133;B` at its end in `%{…%}`. `preexec` strips the marks, then emits `OSC 133;C` and an `OSC 2` holding the first 80 characters of the command. `chpwd` emits `OSC 7`.
   - Pitfalls. Skip D when zle invokes `precmd` (the `zle` builtin returns true there). Write marks to a close-on-exec fd opened on `$TTY` with `zmodload zsh/system` and `sysopen`, so redirected stdout can't swallow them. Prefix builtins with `builtin`, require zsh 5.1, and print nothing else. Test against the user's real `~/.zshrc` without modifying it.
4. **The tab task** reads the PTY master through `AsyncRead` with a 64 KiB buffer. For each chunk:
   - The OSC pre-parser runs first. It is a `vte::Parser` from `alacritty_terminal::vte`, so both parsers share one vte version, with a `Perform` that implements `osc_dispatch`, `execute` and `print`. OSC 7 gives the cwd (percent-decode it and re-join the params after the first with `;`). OSC 133 gives A, B, C, and D with its exit code. OSC 0 and 2 give the title, and OSC 9 and 777 are recorded for M2. `execute` turns BEL into a bell fact and passes `\n`, `\r` and `\t` to the text stream, which `print` also feeds. The parser lives as long as the tab, so a sequence split across reads still parses.
   - The emulator is an `alacritty_terminal::Term<Listener>` with `scrolling_history` from config (default 10,000) and a small `Dimensions` impl, driven by `alacritty_terminal::vte::ansi::Processor::advance(&mut term, &chunk)`. The listener passes `Event::PtyWrite(reply)` back to the tab task, which writes it to the PTY only while no attach client is connected (T0.6).
   - The ring buffer holds 2 MiB of raw bytes with absolute offsets. A byte-level boundary tracker (ground, ESC, CSI, string until BEL or ST) records a safe offset at every `\n` seen in ground state, and trimming cuts at the oldest safe offset past the overflow. A cut then never lands inside an escape sequence or a UTF-8 character.
   - The chunk goes to attach sessions (T0.6), and facts go to the core: cwd, marks, exit codes, title and bell. Title-only `tab.updated` events are throttled to 4 per second per tab, because spinner titles would flood the stream.
5. **Foreground program**, on demand only (133;C and D, `tab.list`, close and delete checks): `rustix::termios::tcgetpgrp` on the master. If it differs from the shell's process group, read the leader's name with `libc::proc_name`. No polling.
6. **Launch commands.** A tab with a `command`, and every agent tab from M2, writes `command` plus `\r` after the first `133;A`, or after 3 s when no integration shows up.
7. **`tab.send {text, execute: true, paste: "auto"}`** wraps multi-line text, or any text with `paste: true`, in bracketed paste (`ESC[200~…ESC[201~`) when the emulator reports that mode. `execute` appends `\r`. Record a send mark: the text-stream offset, and whether the tab sat at a prompt.
8. **`tab.wait`.** `until: "idle"` resolves at a prompt: the last mark is A or B with no C after it. M2 adds agents that are idle or done. `until: {pattern}` is a literal substring match on the text stream after the last send mark, as in the VS Code build. If that send ran a command at a prompt with integration, matching starts after the command's `133;C`. Otherwise the first occurrence of the sent text, its echo, is dropped before matching. With no send, matching starts when the wait began (contract 6). Waiters live in the core and resolve on tab facts. Expiry fails with `timeout`, exit 124.
9. **`tab.read {lines: 200}`** returns the last `lines` rows of scrollback and screen. For each row, skip wide-character spacers and trim trailing spaces. Keep populated rows below the cursor, because Claude draws menus there, and drop trailing blank rows (contract 5). Also return `altScreen` and `cursor`.
10. **`tab.run {command, lines: 200, timeoutMs}`** needs shell integration (else `unavailable`) and an idle prompt (else `busy`). It writes the command and `\r`, collects the text stream between `133;C` and `133;D;<code>`, and returns `{exitCode, output, truncated, durationMs}`. The CLI prints the output raw on a TTY and exits with `exitCode`.
11. **`tab.close`** fails with `forbidden` without `force` while a foreground program other than the shell runs; the app asks the user instead (R-TAB-7). Closing drops the PTY master, so the kernel sends SIGHUP to the session. Also send SIGHUP to the foreground group and SIGKILL to the shell if it survives 3 s, then revoke the tab's tokens and emit `tab.closed`.
12. **Shell exit (R-TAB-12).** Exit 0 after the first prompt closes the tab. A non-zero exit or a signal leaves it `stopped` with `lastExit`; T1.4 adds `tab.restart` and the Restart bar. When the daemon starts, it relaunches every tab from its definition in the last cwd it persisted from OSC 7. It never replays commands, and agent resume comes in T2.5.

**Acceptance.** Compare paths with `realpath`: `/tmp` and `/var` are symlinks into `/private`.
```zsh
mapo tab new --name t1 --cwd /usr/bin; mapo tab wait t1 --until idle --timeout-ms 5000; echo $?   # → 0
mapo tab run t1 'echo hi' --json | jq -e '.exitCode==0 and .output=="hi"'
mapo tab run t1 'sh -c "exit 3"'; echo $?                             # → 3
mapo tab run t1 'env' --json | jq -r .output | grep -cE '^(MAPO_INSTANCE|MAPO_TAB_ID|MAPO_TOKEN|TERM_PROGRAM)='   # → 4
mapo tab run t1 'echo $TERM $(env | grep -c "^CLAUDE")'               # → xterm-ghostty 0
mapo tab run t1 'infocmp xterm-ghostty >/dev/null && echo ok'         # → ok
mapo tab send t1 'cd /private/etc'; mapo tab wait t1 --until idle
mapo tab list --json | jq -e '.[] | select(.name=="t1") | .cwd=="/private/etc"'
mapo tab send t1 'sleep 1; echo MARK-$((40+2))'; mapo tab wait t1 --until MARK-42 --timeout-ms 5000; echo $?   # → 0
mapo tab send t1 'sleep 3 # ONLYECHO'; mapo tab wait t1 --until ONLYECHO --timeout-ms 1500; echo $?     # → 124
mapo tab read t1 --json | jq -e '.text | contains("MARK-42")'
mapo tab new --name bad --cwd "$TMPDIR/mapo-t05/missing" --json | jq -e '.state=="failed" and .launchError.kind=="cwd_missing"'
mkdir -p "$TMPDIR/mapo-t05/missing"; mapo tab focus bad; mapo tab wait bad --until idle; echo $?   # → 0
mapo tab new --name x0; mapo tab wait x0 --until idle; mapo tab send x0 'exit'      # → x0 disappears from tab list
mapo tab new --name x3; mapo tab wait x3 --until idle; mapo tab send x3 'exit 3'    # → x3 is stopped, lastExit.code 3
mapo tab send t1 'sleep 30'; mapo tab close t1; echo $?               # → 1, forbidden
mapo tab close t1 --force --json | jq -e .closed                      # → and its shell pid is gone (ps -p)
mapo instance stop && target/debug/mapo --instance $I daemon && mapo tab list --json | jq -e 'map(.name) | index("bad")'   # → tabs back, cwds kept, nothing replayed
```
Also stream `head -c 3000000 /dev/urandom | base64` through a tab: the daemon footprint in `mapo debug stats` stays bounded, and `tab read` still answers.

**Budget and fallback.** 2.5 h. If deferred init fights the user's rc files, print the A mark from `precmd` instead of patching `PS1`, and record the deviation. **Commits.** `feat(term): PTY tabs with zsh integration, OSC pre-parser, emulator and ring buffer`, `feat(cli): tab send, read, wait and run`.

### T0.6 `mapo attach`

**Goal.** Any terminal can attach to a tab, see its screen and recent scrollback, type, resize, and ride out daemon restarts. Programs never hang while nobody is attached. **Requirements.** R-TAB-6, R-PER-1, PROTOCOL §3 and §8, ARCHITECTURE §3.4 (attach).

**Deliverables.** The attach frame codec in `mapo-protocol`; attach sessions in `mapo-term`; `mapo attach --tab ID|NAME [--instance I]` with two hidden flags for headless checks, `--replay-only` (print the replay, exit after REPLAY_END, no raw mode) and `--size COLSxROWS`; `ReplayStrategy { Raw, Grid }`, chosen by `[terminal] replay = "raw" | "grid"` or `MAPO_REPLAY`; answers to terminal queries while detached; a unit-tested query stripper.

**Steps.**
1. The client reads `app.token` from the instance's data dir on every connect attempt, because tokens rotate when the daemon boots (PROTOCOL §3). It logs only to `attach.<date>.log`, since its stderr is the terminal screen.
2. Client terminal: `tcgetattr` on stdin, raw mode with `rustix::termios` (`Termios::make_raw`), restored on every exit path including SIGTERM and SIGHUP. `TIOCGWINSZ` gives cols, rows and pixels for `hello {role: "attach", credential, attach: {tab, cols, rows, widthPx, heightPx}}`.
3. Frames follow PROTOCOL §8. stdin becomes IN frames of at most 64 KiB, and OUT goes to stdout. `SIGWINCH` (`tokio::signal::unix::SignalKind::window_change()`) becomes RESIZE. PING goes out every 15 s, and the client reconnects when no PONG arrives within 45 s. DETACH is sent on an orderly exit. EXIT(code) prints a dim `[shell exited with code N]` and keeps waiting, because the tab may restart. `not_found` on reconnect prints `Tab closed` and exits 0.
4. Reconnect: on EOF or error, print `\r\n\e[2m[mapo] reconnecting…\e[0m` and retry for 30 s, backing off from 100 ms and doubling to 2 s. The daemon's replay then clears and repaints. After 30 s, print `Disconnected from Mapo (instance I)` and exit 2. The surface then shows the "Disconnected" scrim (UX §4.3, T0.8).
5. The daemon session checks the credential, resolves the tab, and gets the replay payload and a broadcast receiver from the tab task in one message, so no byte is lost or doubled between replay and live output. It replies `{attach: {tabId, replayBytes}}` and sends REPLAY_BEGIN, the replay as OUT frames, REPLAY_END, then live OUT.
6. Raw replay is `ESC c` and `ESC[3J` (reset, clear the client's scrollback), then the ring with terminal queries stripped, then a mode trailer from the emulator. The trailer restores cursor visibility (`?25`), bracketed paste (`?2004`), mouse modes (`?1000`, `?1002`, `?1003`, `?1006`), focus reporting (`?1004`), application cursor keys (`?1`), keypad mode and the cursor position. It never sends `?1049h`, because entering the alternate screen again clears it.
   - **Pitfall: replayed queries.** The ring may hold old `CSI 6n`, `CSI c`, `CSI > c`, `CSI ? u`, `CSI > q`, `OSC 10;?`, `OSC 11;?`, DECRQM, and DCS `$q` or `+q`. Replaying them makes the client answer again, and those answers arrive as input: a stray `^[[24;1R` at the prompt. Strip queries from the replay, never from live output. libghostty-spm carries a patch for the same problem.
   - **Pitfall: trimmed alternate screen.** If the emulator is in the alternate screen but the ring no longer holds the switch into it, raw replay paints the full-screen program onto the main screen. Track the offset of the last alternate-screen entry, and use grid replay for that attach when it was trimmed.
7. Grid replay, which is also the fallback, renders the emulator as escape sequences. It resets, enters the alternate screen when that is active, and writes the last 1,000 scrollback rows and then the screen, row by row, with SGR for colors, bold, italic, underline, inverse, dim and strikeout. It ends with the mode trailer and cursor. Only scrollback older than 1,000 rows is lost.
8. Size: the hello size and each RESIZE call `pty.resize(pty_process::Size::new_with_pixel(rows, cols, w, h))` (TIOCSWINSZ, so the kernel signals the foreground job) and resize the emulator. The last resize wins. Resize before building a grid replay and after sending a raw one.
9. Lag: the broadcast holds 256 chunks. `RecvError::Lagged`, or falling more than 1 MiB behind, triggers a fresh REPLAY_BEGIN…REPLAY_END. Bytes are never dropped silently.
10. Detached queries: while no client is attached, the tab task writes the emulator's `PtyWrite` replies to the PTY. Those include DA1, DA2, DSR and CPR, and whatever else alacritty emits. It also answers `OSC 10` and `OSC 11` color queries with the theme colors. While a client is attached, it drops them, and the real terminal answers.

**Acceptance.**
```zsh
mapo attach --tab t1 --replay-only | grep -a -c MARK-42                        # → at least 1
(sleep 1; printf 'echo via-attach\r'; sleep 1) | script -q /dev/null target/debug/mapo --instance $I attach --tab t1 >/dev/null
mapo tab read t1 --json | jq -e '.text | contains("via-attach")'
mapo attach --tab t1 --replay-only --size 100x30 >/dev/null; mapo tab run t1 'stty size'   # → 30 100
# nothing attached; the tab runs zsh:
mapo tab run t1 'printf "\e[6n" > /dev/tty; IFS= read -rs -t 2 -d R r < /dev/tty; echo "CPR=${r#*\[}"'   # → CPR=<row>;<col>
(sleep 6; printf 'echo after-restart\r'; sleep 2) | script -q /dev/null target/debug/mapo --instance $I attach --tab t1 > "$EVIDENCE/attach.out" &
sleep 1; mapo instance stop; target/debug/mapo --instance $I daemon; wait
grep -c reconnecting "$EVIDENCE/attach.out"                                    # → at least 1
mapo tab read t1 --json | jq -e '.text | contains("after-restart")'
MAPO_REPLAY=grid mapo attach --tab t1 --replay-only | head -c 2 | xxd           # → starts with 1b63 (ESC c)
just test                                                                       # → codec, boundary tracker and query stripper tests pass
```
`script` doesn't answer terminal queries, so the stray-reply check and the vim reattach run with the app in T0.8 and T0.11.

**Budget and fallback.** 2 h in total, of which raw replay fidelity gets 90 min. If vim or Claude's TUI doesn't come back right in T0.8, make `Grid` the default and record it. **Commits.** `feat(term): mapo attach with replay, resize, reconnect and detached query answers`.

### T0.7 Swift app skeleton

**Goal.** A native window connects to its instance's daemon, starting it if needed. It mirrors workspaces and tabs in a basic S2 rail and creates them with ⇧⌘N and ⌘T. **Requirements.** R-WS-1, R-WS-3, R-WS-4 (basic), R-TAB-2, R-PER-1, R-PER-4, R-NF-3, R-NF-6, R-ENG-3; UX §2 and §4.3.

**Deliverables.** `main.swift`, `AppDelegate.swift`, `MapoWindow`, `MainWindowController.swift` and a programmatic main menu (Mapo, File, Edit, View, Window) in `app/Mapo/`. In MapoClient: `MapoConnection`, `MapoClient`, `AppStore` and `DaemonLauncher`. In MapoUI: the `AXID` helper that builds every identifier string (ENGINEERING §4.2), `RailViewController`, `PaneAreaViewController` (one pane in M0) and `InspectorViewController`, a collapsed placeholder. `just app` works as ENGINEERING §3.2 describes: it builds, stops this instance's previous app, and `exec`s the app in the foreground, so agents run it in the background.

**Steps.**
1. The instance comes from `--instance`, else from the bundled `Contents/Helpers/mapo instance show --json`, which also returns the paths (ENGINEERING §2.1). The app doesn't re-implement resolution. It writes `<I>.app.pid` (pid and executable) at launch and removes it at exit. `--no-spawn-daemon` makes it wait and reconnect instead of spawning.
2. The window follows UX §2. `MapoWindow` uses `.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView`, `titlebarAppearsTransparent = true`, `titleVisibility = .hidden` and `toolbarStyle = .unified`. Its `title` is the active workspace name plus ` (<instance>)`, hidden but used by Mission Control, the Window menu and `ui.window`. It opens centered at 1440×900 on first launch. Frame autosave is `main-<instance>` and split autosave `split-<instance>`, and window restoration is off. All dev instances share one bundle ID, so nothing per-instance goes into `UserDefaults`. The identifier is `window.main`, and the app calls `NSApp.activate()` at launch.
3. An `NSSplitViewController` holds three items: `NSSplitViewItem(sidebarWithViewController:)` for the rail, a content item for the panes, and `NSSplitViewItem(inspectorWithViewController:)`, collapsed. The sidebar item gives the rail macOS 26 Liquid Glass; add no `NSVisualEffectView`. The traffic lights sit over the rail. View › Hide/Show Inspector (⌥⌘0) exists from now on; T0.8 uses it to test resizing.
4. The connection is `NWConnection(to: .unix(path: socket), using: .tcp)`, doing I/O on a private serial queue and handing decoded messages to the main actor. It splits incoming bytes on `\n` and decodes each line with `JSONDecoder`. Requests get numeric IDs and a `CheckedContinuation` in a pending map. Notifications (`method == "event"`) feed an `AsyncStream`. Requests from the daemon carry string IDs such as `"d-17"` and go to a handler (T0.9). If `NWEndpoint.unix` misbehaves, put a POSIX `socket(AF_UNIX, SOCK_STREAM)` with `DispatchIO` behind the same `MapoConnection` API.
5. Startup: read `app.token`, connect, send `hello {role: "app", credential: {kind: "app", token}}`, and check that `instance` in the reply matches. On `ENOENT` or `ECONNREFUSED`, and unless `--no-spawn-daemon` is set, run `Contents/Helpers/mapo daemon --instance <I>`, which detaches with setsid and returns once the socket answers. Then re-read the token and connect. While the daemon is unreachable, `app.banner` shows the states in UX §4.3: "Reconnecting to mapod…", and after 10 s "Can't reach mapod. Mapo keeps retrying." with [Restart mapod]. A blank window is never acceptable (R-NF-3).
6. Sync: `state.snapshot` fills the `AppStore` (`@Observable @MainActor`), and `events.subscribe {after: seq}` applies events in order. On disconnect, show the banner and retry with backoff. A new `bootId` means a fresh snapshot.
7. The basic S2 rail has 26 pt workspace rows, plus 24 pt tab rows for the active workspace only. A tab row shows the title and a state dot: running `#6CA8FF`, done `#6FCF97`. Only Needs you (`#E8B557`) and Failed (`#F47067`) get words. Row views carry `rail.workspace:<name>` and `rail.tab:<workspace>/<tab>` through `AXID`, the raw state as their AX value, and a spoken label (UX §3.8). Clicking a workspace calls `workspace.activate`; clicking a tab calls `tab.focus`. Watch the store with `withObservationTracking`, re-arming after each change, and reload only the rows that changed.
8. Menus call daemon commands (UX §8). New Workspace (⇧⌘N) calls `workspace.create`, then opens one shell tab in the home folder and focuses it (PA-23); the CLI creates workspaces empty. New Shell Tab (⌘T) calls `tab.create {kind: "shell", placement: "focused", focus: true}`, and the daemon picks the focused tab's cwd, else `$HOME`. ⌘Q quits only the app, and the daemon keeps running.

**Acceptance.** T0.9 repeats the keyboard and click checks through `mapo ui`.
```zsh
just kill; just app                                   # in the background → app.<date>.log says "connected bootId=…"
mapo instance show --json | jq -e '.daemon.running and .app.running'   # → the app spawned the daemon
mapo events --after 0 --json | jq -c 'select(.type=="app.connected")' | head -n 1   # → one event
mapo workspace new Alpha; mapo tab new --workspace Alpha --name a1
screencapture -x "$EVIDENCE/full.png"                 # → with Screen Recording, the rail shows Alpha and a1
mapo instance stop                                    # → app.banner appears, the app respawns the daemon, the rail repopulates
```

**Budget and fallback.** 90 min; the POSIX socket fallback is in step 4. **Commits.** `feat(app): window, split view, MapoClient and basic S2 rail`.

### T0.8 Terminal surface

**Goal.** Every visible tab renders in a libghostty surface whose process is `mapo attach`, with native keyboard, IME, mouse and resizing, behind the `TerminalSurface` protocol. **Requirements.** R-TAB-10, R-TAB-6, D-13, ARCHITECTURE §4.3.

**Deliverables.** For T0.8a: `third_party/ghostty.lock`, `scripts/ghostty.sh` (`just ghostty`), the binary target in MapoKit, `third_party/ghostty-extra-api.txt` and `resources/terminfo/`. For T0.8b: `GhosttyRuntime`, `GhosttySurfaceView`, `TerminalSurface`, `SurfaceRegistry`, the generated `$DATA/ghostty.conf` and `third_party/licenses/ghostty-LICENSE`.

**T0.8a steps: acquire, verify, link.**
1. `third_party/ghostty.lock` holds the `VERSION`, `URL` and `SHA256` lines that `just ghostty` reads (ENGINEERING §3.2), plus the source and upstream commit for the record. The values come from libghostty-spm's `Package.swift` on `main`, read on 2026-09-28:
   ```sh
   VERSION=1.6.20260928
   URL=https://github.com/Lakr233/libghostty-spm/releases/download/upstream.3c47ca159368-2/GhosttyKit.xcframework.zip
   SHA256=804d4c92cad153eb8d85ed86f4c98ca587e90ff47ac0a62c846c985ece02a9c3
   SOURCE=Lakr233/libghostty-spm release upstream.3c47ca159368-2
   UPSTREAM_COMMIT=3c47ca159368eb4a860ffe5333abdf4a85b2767b
   ```
2. `just ghostty` behaves as ENGINEERING §3.2 says. It downloads the zip (about 77 MB, all Apple platforms) to `<cache>/<VERSION>.tmp.<pid>/` and checks `shasum -a 256` against `SHA256`. On a mismatch it deletes the download and fails; never edit the lock to match. It unzips, renames into `~/Library/Caches/mapo/ghostty/<VERSION>/`, and links `.build/ghostty/GhosttyKit.xcframework` to it (use a `cp -cR` clone if the toolchain rejects the symlink).
3. Inside is a static-library xcframework: `libghostty.a` per slice, with `Headers/libghostty/ghostty.h` and `Headers/libghostty/module.modulemap` declaring `module libghostty`. That module map is already nested, so it can't collide with another (swift-build #1746). Swift code writes `import libghostty`. Linking needs `-lc++` and the Carbon framework; add any framework an undefined-symbol error names.
4. Link through MapoKit: `.binaryTarget(name: "libghostty", path: "../../../.build/ghostty/GhosttyKit.xcframework")`. `MapoTerminal` depends on it with `linkerSettings: [.linkedLibrary("c++"), .linkedFramework("Carbon")]`. SwiftPM accepts a binary target outside the package root, even through a symlink (verified with `swift build` on 2026-09-28). The XcodeGen project gets it through the package. If Xcode rejects that, link it in `project.yml` (`- framework: ../.build/ghostty/GhosttyKit.xcframework` with `embed: false`), move `GhosttySurfaceView` into the app target under `app/Mapo/Terminal/`, and record the deviation from ARCHITECTURE §4.1.
5. Only upstream APIs. The prebuilt applies 17 patches, host-managed IO among them. Fetch upstream `include/ghostty.h` at `UPSTREAM_COMMIT` with `gh api -H 'Accept: application/vnd.github.raw' "repos/ghostty-org/ghostty/contents/include/ghostty.h?ref=$UPSTREAM_COMMIT"`, diff its `GHOSTTY_API` names against the shipped header, and write the extras to `third_party/ghostty-extra-api.txt`. `just lint` fails when Mapo code calls one of them.
6. Terminfo: copy `Sources/GhosttyTerminal/Resources/terminfo/78/xterm-ghostty` and the `67/ghostty` symlink from libghostty-spm at tag `$VERSION` (MIT) into `resources/terminfo/`, and commit them. macOS ncurses uses hex-named directories (`78` is `x`), so the path is `terminfo/78/xterm-ghostty` (ARCHITECTURE §2). Check with `infocmp -A resources/terminfo xterm-ghostty`.
7. Spike: call `ghostty_init` and `ghostty_info()` at app launch and log the version. `just build` must link.

**T0.8b steps: the surface.**
1. Port from Ghostty's macOS app at `UPSTREAM_COMMIT`. It's MIT: keep an attribution comment in the ported files and add `third_party/licenses/ghostty-LICENSE`. The runtime callbacks are in `macos/Sources/Ghostty/Ghostty.App.swift`, key and modifier translation in `Ghostty.Input.swift` and `NSEvent+Extension.swift`, and the view in `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`. Keep keyboard, IME, mouse, scroll, focus, sizing, clipboard, title, bell and child exit. Drop the inspector, search, Quick Look, secure input, progress bars, and drag and drop (T1.5 adds its own).
2. `GhosttyRuntime`, one per app on the main actor.
   - Call `ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)` once. Build the config with `ghostty_config_new()`, `ghostty_config_load_file(cfg, "$DATA/ghostty.conf")` and `ghostty_config_finalize(cfg)`, and log every `ghostty_config_get_diagnostic`. Never call `ghostty_config_load_default_files` or `ghostty_config_load_cli_args`: the user's own Ghostty config stays out, the default in REQUIREMENTS §9.
   - Generate `ghostty.conf` from `config.toml [terminal]`. Include `font-family`, `font-size` and the Mapo Glass colors from UX §9. Set `shell-integration = none`, `wait-after-command = false`, `confirm-close-surface = false` and `quit-after-last-window-closed = false`. Set `scrollback-limit = 4000000`, because the daemon keeps history and client scrollback costs app memory. Take `macos-option-as-alt` from config, and use `clipboard-read = deny` until a confirmation UI exists. Finally `keybind = clear`: Ghostty's defaults bind ⌘T, ⌘D, ⌘W, ⌘K and more, and with them cleared every ⌘ chord falls through the surface's `performKeyEquivalent` to Mapo's menus (UX §8). `copy:`, `paste:` and `selectAll:` on the surface call `ghostty_surface_binding_action(surface, "copy_to_clipboard" | "paste_from_clipboard" | "select_all", len)`.
   - `ghostty_runtime_config_s`: `wakeup_cb` schedules one coalesced `DispatchQueue.main.async { ghostty_app_tick(app) }`. `action_cb` handles `SET_TITLE` (`onTitle`), `RING_BELL` (`onBell`), `MOUSE_SHAPE`, `MOUSE_VISIBILITY`, `OPEN_URL`, `SHOW_CHILD_EXITED`, `CELL_SIZE`, `COLOR_CHANGE`, and `RENDER` if the pinned version expects the host to draw. It returns false for everything else, `PWD` included, because the daemon owns the cwd. The clipboard callbacks use `NSPasteboard.general`, and `close_surface_cb` calls the surface's exit handler.
   - Call `ghostty_app_new(&runtime, cfg)`. Call `ghostty_app_set_focus` when the app activates and resigns, `ghostty_app_keyboard_changed` on input-source changes, and `ghostty_app_set_color_scheme` on appearance changes.
3. `GhosttySurfaceView: NSView, NSTextInputClient, TerminalSurface`.
   - Create the surface when the view first joins a window. From `var c = ghostty_surface_config_new()`, set `platform_tag = GHOSTTY_PLATFORM_MACOS`, and set `platform.macos.nsview` and `userdata` to `Unmanaged.passUnretained(self).toOpaque()`. Set `scale_factor = window.backingScaleFactor` and `font_size = 0`, which uses the config. Set `command = "direct:<APP>/Contents/Helpers/mapo attach --tab <id> --instance <I>"`, and put only `MAPO_INSTANCE` in `env_vars`, because attach reads the token itself (ARCHITECTURE §4.3). Set `wait_after_command = false` and `context = GHOSTTY_SURFACE_CONTEXT_SPLIT`. Keep the C strings alive across `ghostty_surface_new`, with nested `withCString` or with `strdup` and `free`.
   - Since Ghostty 1.2, `direct:` skips `/bin/sh -c`. On macOS, Ghostty still runs the command through `/usr/bin/login -flp <user>`. That keeps the environment, but may print "Last login", which the replay's reset wipes. If the app path contains a space, drop `direct:` and single-quote the path.
   - `setFrameSize` and `layout` call `ghostty_surface_set_size` with backing pixels. `viewDidChangeBackingProperties` calls `ghostty_surface_set_content_scale` and updates the layer's `contentsScale`. The size reaches the daemon as libghostty's TIOCSWINSZ, then SIGWINCH in `mapo attach`, then a RESIZE frame.
   - Input. First-responder changes call `ghostty_surface_set_focus`. `keyDown` runs `interpretKeyEvents`, collecting `insertText`, then calls `ghostty_surface_key` with `ghostty_input_key_s {action, mods, consumed_mods, keycode: event.keyCode, text, unshifted_codepoint, composing}`, and `keyUp` and `flagsChanged` do the same. For IME, `setMarkedText` calls `ghostty_surface_preedit` and `firstRect(forCharacterRange:)` calls `ghostty_surface_ime_point`. Mouse and scroll events call `ghostty_surface_mouse_button`, `ghostty_surface_mouse_pos` and `ghostty_surface_mouse_scroll` through a tracking area. `setVisible(v)` calls `ghostty_surface_set_occlusion(surface, v)`.
   - When the child exits, or `close_surface_cb` fires while the tab still exists, show the "Disconnected" scrim from UX §4.3 with [Reconnect] (`pane.reconnect:<tabName>`). Reconnect builds a new surface, which replays. A surface never closes its pane by itself.
   - Tear down on the main thread: remove the view, then call `ghostty_surface_free`. Callbacks look up their surface in a registry keyed by the userdata pointer and ignore unknown pointers. Late callbacks after a free are a known libghostty hazard, and cmux documents several. The identifier is `pane.terminal:<tabName>`, with a label that speaks the title and state.
4. `TerminalSurface` lives in MapoTerminal (ARCHITECTURE §4.3). A `SurfaceRegistry` on the main actor, keyed by tab ID, keeps surfaces until their tab closes, and re-layout never recreates one. `config.toml [terminal] engine = "ghostty" | "swiftterm"` picks the implementation. The pane shows its tab's surface, and ⌘T focuses the new one.

**Fallback after the 2 h timebox: SwiftTerm.** Add `https://github.com/migueldeicaza/SwiftTerm` (MIT) to MapoKit, pinned to `1.11.2`: from 1.12.0 it ships a Metal shader that only builds with Xcode's Metal Toolchain component, which isn't installed. Move to `1.20.0` once it is. `SwiftTermSurfaceView` wraps `LocalProcessTerminalView` and calls `startProcess(executable: <APP>/Contents/Helpers/mapo, args: ["attach", "--tab", id, "--instance", I], environment: ["MAPO_INSTANCE=…", "TERM=xterm-256color"])` through SwiftTerm's `LocalProcess`. Make `engine = "swiftterm"` the default. Record a Blocker with the exact GhosttyKit failure: link errors, the crash log from `~/Library/Logs/DiagnosticReports/`, or a blank Metal layer. Building GhosttyKit from source is a follow-up for a later night, not a reason to stall M0: `brew install zig` for Zig 0.16, clone Ghostty at the pinned commit into `~/Library/Caches/mapo/ghostty-src/`, and follow that commit's HACKING.md for the xcframework target.

**Acceptance.** With the app running for your instance:
```zsh
just ghostty                                           # second run → no download
mapo tab new --name g1 --cwd /usr/bin; mapo ui wait pane.terminal:g1 --state focused
pgrep -fl "Helpers/mapo attach --tab .* --instance $I" # → one process per visible surface
mapo tab wait g1 --until ghostty-42 --timeout-ms 5000 &
mapo ui type 'echo ghostty-$((6*7))'; mapo ui key return; wait $!; echo $?   # → 0
mapo tab send g1 'printf "\e[1;31mred\e[0m\n"'; just task=T0.8 snap color   # → red text in the shot
A=$(mapo tab run g1 'stty size'); mapo ui key cmd+alt+0; B=$(mapo tab run g1 'stty size'); [ "$A" != "$B" ]   # → resize reached the PTY
mapo ui key cmd+t; mapo tab list --json | jq length    # → one more tab: the menu got ⌘T, not Ghostty
mapo tab send g1 'vim -u NONE -N /etc/hosts'; mapo ui key cmd+q
just app; mapo ui wait pane.terminal:g1; just task=T0.8 snap vim   # (app in the background) → vim repainted after relaunch
mapo ui key cmd+q; just app; mapo tab send g1 ':q!'; mapo tab wait g1 --until idle
mapo tab read g1 --json | jq -r .text | tail -n 1      # → a clean prompt, no "R" residue from replayed queries
```
If T0.9 hasn't landed, check with `mapo tab send` and `tab read` plus a full-screen `screencapture -x`, and rerun the `mapo ui` lines after T0.9.

**Budget and fallback.** A hard 2 h timebox runs from the start of T0.8a to a live Ghostty surface; then SwiftTerm gets at most 1 h. **Commits.** `build: fetch and pin GhosttyKit; link through MapoKit`, `feat(terminal): Ghostty surfaces running mapo attach`, and on the fallback path `feat(terminal): SwiftTerm fallback surface`.

### T0.9 Automation surface v0

**Goal.** An agent can see and drive the app as a user does, with no Accessibility permission: tree, snapshot, click, press, focus, type, key, wait, window, basic metrics and screenshots. **Requirements.** R-ENG-1, R-ENG-2, R-NF-5, D-21; PROTOCOL §6.8; ENGINEERING §4.

**Deliverables.** `app.register`. Daemon routing of `ui.*` to the most recently registered app: the daemon sends a request on the app's connection with a string ID `"d-<n>"` and waits for the request's `timeoutMs` plus 1 s, or 10 s by default; with no app it answers `unavailable`. MapoAutomation handlers for `ui.window`, `ui.tree`, `ui.snapshot`, `ui.click`, `ui.press`, `ui.focus`, `ui.type`, `ui.key`, `ui.wait` and `ui.metrics`. `mapo ui …` with the target syntax of ENGINEERING §4.3. Identifiers on every M0 control. `just snap [STEP]`, and the rest of `drives/lib.sh`: the app in `drive_begin`, plus `ui_snapshot` and `ui_shot`.

**Steps.**
1. CLI targets (ENGINEERING §4.3): a positional identifier, `--label TEXT`, `--role ROLE --label TEXT`, or `--point X,Y` in window points with a top-left origin. `--right` and `--count` modify clicks. Targets resolve by model identity, and virtualized rows are scrolled into view before a click (PROTOCOL §6.8).
2. The tree starts at `window.contentView` and walks `accessibilityChildren()` recursively to depth 12. For each element it reads `accessibilityIdentifier()`, `accessibilityRole()` (drop the `AX` prefix and lowercase the first letter), `accessibilityLabel()`, a string `accessibilityValue()` (the raw state on stateful elements), `accessibilityFrame()` converted to window coordinates, focus and `isAccessibilityEnabled()`. It walks through ignored elements to their children.
3. The snapshot follows ENGINEERING §4.4. The app returns `window`, `focus`, `tree` and `model` (`workspaceId`, `layout`, and `rail` rows shaped as UX §3.8 specifies). The daemon adds `terminals: [{tabId, paneId, text}]` from its emulators, following the `tab read` rules, so terminal text is the daemon's truth.
4. Input stays inside the process, so it needs no Accessibility permission:
   - `ui.click` takes the element's center and builds `NSEvent.mouseEvent(with: .leftMouseDown, …, windowNumber:)`. It posts the matching mouse-up first with `NSApp.postEvent(_:atStart: false)`, then calls `window.sendEvent(down)`. Controls that run a tracking loop take the mouse-up from the queue.
   - `ui.press` calls `accessibilityPerformPress()`. `ui.focus` makes the window key and calls `window.makeFirstResponder(view)`.
   - `ui.key {chord}` parses the chord grammar of ENGINEERING §4.3. It builds `NSEvent.keyEvent` with matching characters and the virtual key code from a US-layout table (libghostty encodes from key codes). It offers the event to `NSApp.mainMenu?.performKeyEquivalent(with:)` first, then sends keyDown and keyUp through `window.sendEvent`.
   - `ui.type {text}` sends keyDown and keyUp per character, with the US key code and shift. Characters outside the table go through `insertText` when the first responder is an `NSTextInputClient`.
5. `ui.wait {target, state, timeoutMs: 5000}` re-checks at most every 50 ms on the main run loop. On timeout it fails with `timeout` (exit 124) and summarizes the last tree in the error.
6. `ui.window` returns `{windowNumber, frame, scale, title, occluded}`. The basic `ui.metrics` has three parts. `launch.processStartToFirstFrameMs` runs from the process start time (`sysctl(KERN_PROC_PID)`) to the first frame presented after the first snapshot. `navigation` spans use the names in ENGINEERING §4.3 (`app.reattach`, `workspace.switch`, `tab.focus`, `tab.create`, …) and run from the input event's timestamp to the first frame showing the new state. `attach.lastMs` is added by the daemon, from the attach hello until REPLAY_END is flushed. `reset: true` clears them.
7. Put identifiers on every M0 control through `AXID`: `window.main`, `toolbar.title`, `rail`, `rail.toggle`, `rail.newWorkspace`, `rail.workspace:<name>`, `rail.tab:<workspace>/<tab>`, `pane:<paneId>`, `pane.terminal:<tabName>`, `app.banner`, `app.banner.action` and `pane.reconnect:<tabName>`. Each gets a label that speaks its state.
8. `just snap [STEP]` writes `snapshot-STEP.json` and `shot-STEP.png` into `evidence/{{task}}/<ts>/` (ENGINEERING §3.2). Pixels are unavailable when `screencapture` fails, the PNG is empty, or `ui window` reports `occluded` (ENGINEERING §4.6).

**Acceptance.**
```zsh
mapo ui window --json | jq -e --arg i "($I)" '(.title | endswith($i)) and .windowNumber > 0'
mapo ui key cmd+shift+n; mapo ui wait 'rail.workspace:Workspace 1' --timeout-ms 2000; echo $?   # → 0
mapo ui wait 'pane.terminal:terminal-1' --state focused                      # → ⇧⌘N opened and focused a shell tab (PA-23)
mapo ui key cmd+t; mapo ui wait 'pane.terminal:terminal-2' --state focused
mapo tab wait terminal-2 --until typed-42 --timeout-ms 5000 &          # start the waiter first (ENGINEERING §5.6)
mapo ui type 'echo typed-$((6*7))'; mapo ui key return; wait $!; echo $?   # → 0
mapo ui snapshot --json | jq -e '.terminals[] | select(.text | contains("typed-42"))'
mapo workspace new Alpha >/dev/null; mapo ui click rail.workspace:Alpha
mapo rpc state.snapshot --json | jq -e '.activeWorkspaceId == (.workspaces[] | select(.name=="Alpha") | .id)'
mapo ui metrics --json | jq -e '.launch.processStartToFirstFrameMs > 0'
mapo ui tree | jq '[.. | objects | select(.role? as $r | ["button","checkBox","radioButton","popUpButton","menuButton","textField","textArea","row","link","slider","splitter"] | index($r)) | select(.id == null)] | length'   # → 0
just task=T0.9 snap rail                               # → snapshot plus shot, or "pixels: unavailable"
kill "$(head -n 1 "$RUN/$I.app.pid")"; mapo ui window; echo $?   # → 1, unavailable
```

**Budget and fallback.** 2 h. If a control ignores synthesized clicks, target it with `ui.press`. **Commits.** `feat(automation): app.register and ui.* over the daemon`, `test(drives): complete lib.sh with app and UI helpers`.

### T0.10 Isolation and parallel proof

**Goal.** Prove that two worktrees and their instances build and run side by side without touching each other, and that the second worktree reuses the GhosttyKit cache. **Requirements.** R-ENG-3, R-ENG-4, R-ENG-5; ENGINEERING P2 and P4.

**Steps.**
1. `git -C ~/code/mapo-native worktree add ../mapo-native-iso -b native-iso native`. In the new worktree, run `just setup` (GhosttyKit must come from the cache), `just build` while the main worktree also builds (record both times), then `just app` in the background.
2. With both instances running (`dev-mapo-native` and `dev-mapo-native-iso`), create workspace `Only-Main` in one and `Only-Iso` in the other. Compare sockets, pids, data dirs, window titles and workspace lists. Each worktree has its own `target/` and `.build/`.
3. `just kill` in the iso worktree. The main instance keeps answering.
4. In the main worktree, show that rebuilding the app leaves terminals alone: note `mapo tab run t1 'echo $$'`, run `just app` (it rebuilds and restarts only the app), and compare.
5. Run `just setup && just build && just drive m0-skeleton` in the iso worktree once T0.11 exists (ENGINEERING P4). Then clean up with the commands in ENGINEERING §2.7.

**Acceptance.**
```zsh
(cd ../mapo-native-iso && just ghostty)                                # → no download
mapo ui window --json | jq -r .title                                   # → "… (dev-mapo-native)"
(cd ../mapo-native-iso && just mapo ui window --json | jq -r .title)   # → "… (dev-mapo-native-iso)"
mapo workspace list --json | jq -e 'map(.name) | index("Only-Iso") | not'
ls "$RUN"                                                              # → two sockets and two pid files per role
lsof -nP -a -iTCP -sTCP:LISTEN -p "$(head -n 1 "$RUN/$I.pid")"          # → nothing
(cd ../mapo-native-iso && just kill); mapo rpc ping --json | jq -e .bootId
P1=$(mapo tab run t1 'echo $$'); just app; P2=$(mapo tab run t1 'echo $$'); [ "$P1" = "$P2" ]
```

**Budget and fallback.** 45 min. **Commits.** Fixes as `fix(<scope>): …`. The proof itself is a PROGRESS.md entry, with the comparison table in `summary.md`.

### T0.11 Drive `m0-skeleton`

**Goal.** One scripted walkthrough uses all of M0 as a user would and leaves evidence and timings. It is the milestone gate. **Requirements.** R-ENG-1, R-ENG-2, R-TAB-6, R-PER-1, R-NF-1 (the M0 metrics).

**Deliverables.** `drives/m0-skeleton.sh`, its evidence with a filled Review, a PROGRESS.md entry, and two to five screenshots in `docs/progress/`.

**Steps.** Each is a `step` that acts through the UI, waits for the outcome, checks it with `expect_json`, and leaves a snapshot; visual steps also take a shot.
1. `drive_begin m0-skeleton` starts instance `drive-m0-skeleton-<HHMMSS>` with its daemon and the app (`--no-spawn-daemon`), and records `launch`.
2. ⇧⌘N: `rail.workspace:Workspace 1` and a focused `pane.terminal:terminal-1` appear. Time it as `new-workspace`.
3. ⌘T: `pane.terminal:terminal-2` is focused. Time it as `new-tab`, up to the first prompt in `tab read`.
4. Type a command with `ui type` and `ui key return` while a `tab wait --until` for its output runs in the background, as in ENGINEERING §5.6. Snapshot and shot `typed`.
5. `mapo tab new --name cli --cwd "$DRIVE_TMP"`: the rail row appears within 1 s, and `mapo tab run cli pwd` prints the temp dir (compare with `realpath`).
6. Click `rail.tab:Workspace 1/terminal-1`: the pane shows it and the focus follows. Run the identifier check from ENGINEERING §4.2.
7. `mapo tab send terminal-1 'vim -u NONE -N "$DRIVE_TMP/notes.txt"'`, then `ui type 'ihello vim'` and `ui key escape`. Shot `vim`.
8. Note `P=$(mapo tab run cli 'echo $$')`. Quit with `ui key cmd+q` and wait for the app pid to exit. `mapo tab list` still lists every tab, and `mapo tab run cli 'echo $$'` still prints `$P`.
9. Relaunch the app. Time `app.reattach` from `ui metrics`. Snapshot `relaunch`: terminal-1 has `altScreen: true` and the vim buffer. Shot `vim-relaunch` shows it painted correctly, with no stray reply characters.
10. Type `:q!` and return. Stop the drive's daemon with `mapo instance stop`: `app.banner` shows "Reconnecting to mapod…". Start it again with `mapo daemon`: the banner goes away and the tabs come back in their cwds. Snapshot `daemon-restart`.
11. `drive_end` saves `ui metrics` and `debug stats`, stops only what the drive started, and writes the summary.

**Acceptance.** `just drive m0-skeleton` exits 0 with every check passing. `timings.json` has `launch`, `new-workspace`, `new-tab`, `app.reattach`, `attach.lastMs` and the daemon and app footprints. Screenshots exist, or `pixels: unavailable` is recorded. The Review section is filled in. Afterwards nothing of the drive instance remains: `mapo instance list` and `pgrep -fl drive-m0-skeleton` show nothing.

**Budget and fallback.** 1 h, plus the fixes it turns up. If time allows, ask a Fable subagent for a critical review of M0 (HANDOFF §8) and fix only clear bugs. **Commits.** `test(drives): m0-skeleton drive`.

## 4. M1: daily core

Exit criteria: `just drive m1-daily` passes (T1.10) within the M1 budgets: workspace switch p95 at most 50 ms, reattach and paint at most 150 ms, and cold launch with the daemon running at most 400 ms. On Debug builds these are trends; the enforced pass is T5.1.

Work in ID order. These groups can run in parallel worktrees: rail and status (T1.1, T1.4), layout (T1.2, then T1.3), and inspector and editor (T1.5, then T1.6). T1.7 to T1.9 run on `native` after those, and T1.10 comes last.

### T1.1 Rail per S2

**Goal.** The rail from UX §3 and the S2 board: look, states and interactions. **Requirements.** R-WS-2, R-WS-4, R-WS-5, R-WS-7, R-ST-2, R-TAB-3, R-TAB-8, R-KEY-3, contracts 3 and 4.

**Deliverables.** `RailViewController` on `NSOutlineView` with custom row views. `crates/mapo-git` with repository discovery and the branch read from `.git/HEAD`, following `gitdir:` files in worktrees. `branch`, `attentionCount` and `state` on `WorkspaceSummary`. `workspace.move` and `tab.move` with their CLI verbs. Context menus, inline rename (`rail.rename`) and hold-⌘ hints. Implementation notes:

- UX §3 is the spec for rows, states, hints, interaction and menus, and `docs/design/S2-rail-slimmer.dc.html` has the source measurements.
- Workspace rows are 26 pt and tab rows 24 pt. Inactive workspaces are single collapsed rows. Only Needs you and Failed get words; working and running get a `#6CA8FF` dot and done a `#6FCF97` dot; idle shows nothing. `model.rail` carries `accessory` values exactly as UX §3.8 lists them.
- Holding ⌘ shows ⌘1 to ⌘9 on the active workspace's first nine tab rows, from a local `flagsChanged` monitor. Add an additive `phase: "down" | "up"` field to `ui.key` so drives can hold a modifier, and document it in PROTOCOL §6.8.
- Drag reorder uses a private pasteboard type and calls `workspace.move` or `tab.move`. Background updates reload single rows (`reloadData(forRowIndexes:columnIndexes:)`) and never scroll or move focus. Deleting a workspace keeps the scroll position and selects the next row.
- The daemon re-reads the branch when the focused tab's cwd changes, and emits `workspace.updated` when it differs.

**Acceptance.**
```zsh
mapo ui snapshot --json | jq -e '[.tree | .. | objects | select((.id // "") | startswith("rail.tab:")) | .frame.h] | all(. == 24)'
mapo workspace move Obsess --index 0; mapo instance stop; target/debug/mapo --instance $I daemon; mapo workspace list --json | jq -e '.[0].name=="Obsess"'
mapo tab new --name bad --cwd /nonexistent/x         # → its row shows the word and its AX value is "failed"; idle rows carry no word
mapo tab send t1 "cd $REPO"                          # → the rail.workspace:<name> label contains the branch
mapo ui key cmd --phase down                         # → hints on the first nine tab rows; --phase up hides them
# double-click a tab row, ui type a name, return    → tab list shows the new name with labeled true
```

**Budget and fallback.** 2.5 h. If drag and drop fights the outline view, ship Move Up and Move Down in the context menu, keep the CLI verbs, and list drag for the user. **Commits.** `feat(ui): S2 rail with states, badges, branch, hints, reorder and rename`.

### T1.2 Tiling split tree

**Goal.** Tiling panes per workspace, owned by the daemon's layout model and rendered by an AppKit container. **Requirements.** R-LAY-1, R-LAY-2, R-LAY-3, R-LAY-4, R-LAY-6 (header), R-LAY-7, R-TAB-7 (confirmation in the UI); UX §4.

**Deliverables.**
- The layout model from PROTOCOL §7 in `mapo-core::layout`, pure and unit-tested: split, close with sibling promotion, directional focus from normalized rectangles, and equalize.
- `layout.get`, `pane.split`, `pane.close`, `pane.focus`, `pane.resize` and `pane.equalize`, persisted in `layouts` and announced with `layout.updated`. The CLI verbs `mapo pane split right|down [--tab NAME|--file PATH]`, `pane focus left|right|up|down`, `pane close` and `pane equalize`.
- In the app, `SplitContainerView`, an NSView that lays out its children from ratios with 8 pt gutters (`pane.divider:<splitId>/<index>`). Dragging a gutter resizes live and sends `pane.resize` on mouse-up.
- Pane cards with the header from UX §4.1 (`pane.header:<tabName>`, `pane.close:<paneId>`), the focus ring, and the empty pane (`pane.empty.newShell:<paneId>`, `pane.empty.newAgent:<paneId>`).

**Notes.** ⌘D and ⇧⌘D split with a new shell in the focused tab's cwd. `tab.focus` shows the tab in its own pane if visible; otherwise it goes into the focused pane, or into the most recently focused terminal pane when the focused pane shows a file or diff. The replaced tab keeps running. ⌘W closes the pane and keeps the tab. ⇧⌘W closes the tab, confirming through `dialog`, `dialog.confirm` and `dialog.cancel` when a foreground program runs. ⌥⌘ plus an arrow moves focus. Status updates never move focus.

**Acceptance.**
```zsh
mapo ui key cmd+d; mapo ui key cmd+shift+d
mapo rpc layout.get --json | jq -e '[.. | objects | select(.kind=="pane")] | length == 3'
for t in $(mapo tab list --json | jq -r '.[].name'); do mapo tab run $t pwd; done   # → the same folder for all three
mapo ui key cmd+alt+left; mapo ui snapshot --json | jq -r .focus.id    # → a different pane.terminal:…
mapo pane close; mapo tab list --json | jq length                     # → tab count unchanged
mapo ui click 'rail.tab:Workspace 1/<background tab>'                 # → it replaces the focused pane's content
# quit and relaunch the app, restart the daemon                       → layout.get equals the saved copy, ratios included
mapo ui metrics --json | jq '.navigation[] | select(.name=="pane.split")'   # → at most 150 ms
```

**Budget and fallback.** 3 h. If the custom container stalls, nest one `NSSplitView` per split node, as Bonsplit does, behind the same `PaneLayoutView` API. **Commits.** `feat(core): layout tree and pane commands`, `feat(ui): tiling container, pane headers and focus ring`.

### T1.3 Workspace switching

**Goal.** A switch shows the other workspace's layout at once, and hidden terminals cost almost nothing. **Requirements.** R-WS-3, R-NF-1 (switch at most 50 ms, reattach at most 150 ms), ARCHITECTURE §4.3 (visibility), contract 2.

**Deliverables.** One cached pane container per workspace; a switch swaps containers without recreating surfaces. `SurfaceRegistry` frees a surface 30 s after it was hidden, so its `mapo attach` exits, and recreates it when it shows again; the replay repaints it. ⌃⌘↑ and ⌃⌘↓.

**Acceptance.** The fixture comes from ENGINEERING §6.
```zsh
# two workspaces with 5 visible panes each; 20 alternations of ctrl+cmd+down and ctrl+cmd+up
mapo ui metrics --json | jq '[.navigation[] | select(.name=="workspace.switch") | .ms] | sort | .[(length*0.95|floor)]'   # → at most 50
sleep 31; pgrep -f "attach --tab .* --instance $I" | wc -l            # → only the visible surfaces
mapo ui key ctrl+cmd+up; mapo ui snapshot --json | jq -e '.terminals | all(.text | length > 0)'   # → text back
mapo ui metrics --json | jq '.navigation[] | select(.name=="app.reattach")'   # → at most 150 ms
```

**Budget and fallback.** 2 h. If reattach misses 150 ms, cap raw replay at the last 256 KiB plus a grid snapshot of the screen, and record the measurement. **Commits.** `perf(ui): cached workspace containers and hidden-surface detach`.

### T1.4 Status vocabulary, shell states, `ui.visibility`, restart

**Goal.** One status vocabulary across the rail, pane headers, CLI and snapshot, long shell commands and exited shells included. **Requirements.** R-ST-1, R-ST-2, R-ST-5, R-TAB-11, R-TAB-12, R-WS-7, R-LAY-6 (Stop), R-NF-5, R-SRV-4; UX §7.

**Deliverables.**
- The shell part of `mapo-core::status`. A tab is `running` between C and D. A command that ran for at least `[attention] done-threshold-seconds` (30) and finished while nobody viewed the tab becomes `done` on exit 0, or `failed` with `stateDetail` "exit N". `failed` clears when the next command starts. `done` clears once the tab is visible in the key window and focused.
- `ui.visibility {keyWindow, visibleTabIds, focusedTabId}`, which the app sends when the key window, layout or focus changes.
- `tab.stop`, which writes `\x03`, with `mapo tab stop`, the Stop button `pane.stop:<tabName>` while a shell command runs, and ⌘. (Stop Command).
- `tab.restart` and the exit bar from UX §4.3 with [Restart] and [Close Tab] (R-TAB-12). Document the CLI verb `mapo tab restart NAME` in PROTOCOL §9.
- A workspace's state is its most urgent tab's state. `tab.state` events.

**Acceptance.**
```zsh
# h sits in another workspace:
mapo tab send h 'sleep 31; false'; sleep 33
mapo tab list --json | jq -e '.[] | select(.name=="h") | .state=="failed" and .stateDetail=="exit 1"'
mapo ui snapshot --json | jq -e '.model.rail[] | select(.name=="h") | .state=="failed"'
mapo tab focus h; mapo tab list --json | jq -e '.[] | select(.name=="h") | .state=="failed"'    # → still failed
mapo tab send h 'true'; mapo tab wait h --until idle; mapo tab list --json | jq -e '.[] | select(.name=="h") | .state=="idle"'
# a hidden 31 s success becomes done and clears on focus; a 5 s command never marks done
mapo tab send v 'sleep 100'; mapo ui click pane.stop:v; mapo tab list --json | jq '.[] | select(.name=="v") | .lastExit.code'   # → 130
mapo tab send s 'exit 3'; mapo tab restart s; mapo tab wait s --until idle; echo $?   # → 0, same pane, same cwd
just test                                            # → the status table covers every transition
```

**Budget and fallback.** 2 h. **Commits.** `feat(core): shell done and failed states, visibility, restart`, `feat(ui): state words, dots, Stop and the exit bar`.

### T1.5 Files inspector

**Goal.** The Files segment follows the focused tab's folder without taking focus, and works from keyboard and mouse. **Requirements.** R-FS-1, R-FS-2, R-FS-3, R-FS-4, R-FS-5, contract 9; UX §5.

**Deliverables.**
- In `mapo-git`: `fs.list` with the `ignore` crate (`WalkBuilder` with `max_depth(Some(1))`, gitignore on, plus `[files] exclude`), reporting `hiddenByExclude`. A status cache per repository root, filled by `git -c core.fsmonitor=false --no-optional-locks status --porcelain=v2 -z --branch --untracked-files=all`. `fs.watch` and `fs.unwatch` on notify with notify-debouncer-full at 150 ms, which emit `fs.changed` and mark the cache dirty; changes to `.git/HEAD`, `.git/index` or `.git/refs/` emit `git.changed`. `explorer.refresh` and `explorer.collapse`, which the daemon routes to the app.
- In the app: the segments `inspector.segment:files` and `inspector.segment:changes` (Changes stays empty until M4). The Files `NSOutlineView` with lazy children, the header `inspector.files.header`, and rows `inspector.files.row:<relPath>` with git letters. The states in `inspector.files.state`, with `inspector.files.retry`. Type-to-select, arrow keys, Enter to open (T1.6), and the context menu from UX §5.2. Dropping rows on a terminal types their quoted paths (UX §4.4) through `tab.send {execute: false}`.
- When refreshes overlap, the newer one supersedes the older, and the last focused tab wins. Folders sort first. Nothing here takes focus from the terminal.

**Acceptance.**
```zsh
D=$(mktemp -d); (cd $D && git init -q && echo a > a.txt && echo x > ignored.log && echo '*.log' > .gitignore && git add -A && git commit -qm init && echo b >> a.txt && touch new.txt)
mapo tab send t1 "cd $D"; mapo ui wait inspector.files.row:a.txt --timeout-ms 1000
mapo ui snapshot --json | jq -r .focus.id                            # → pane.terminal:t1
mapo ui snapshot --json | jq -c '[.tree | .. | objects | select((.id // "") | startswith("inspector.files.row:")) | {id, value}]'   # → a.txt M, new.txt ?, no ignored.log
mapo tab run t1 'touch later.txt'; mapo ui wait inspector.files.row:later.txt --timeout-ms 800
mapo tab run t1 "rm -rf $D"; mapo ui wait inspector.files.retry        # → state "missing" with Retry
mapo explorer refresh --json | jq -e '.state'
```

**Budget and fallback.** 3 h. **Commits.** `feat(git): fs.list, fs.watch and git decorations`, `feat(ui): Files inspector`.

### T1.6 File pane and TextKit 2 editor

**Goal.** Clicking a file opens it beside the terminal, in a light native editor that never loses text. **Requirements.** R-LAY-5, R-ED-1, R-ED-2, R-ED-4, R-ED-5, R-ED-6, R-FS-6, contracts 2, 3 and 10, D-5, D-14; UX §6.

**Deliverables.**
- `file.open` and `mapo file open PATH`. The daemon rejects folders, missing paths, broken links and unreadable files before any UI change. With no file pane, the file splits right of the focused terminal. The pane keeps `recentFiles` (`pane.recent:<paneId>`), is reused, and takes focus.
- MapoEditor: `NSTextView(usingTextLayoutManager: true)`; a gutter view that draws line numbers from the visible `NSTextLayoutFragment`s; the dirty dot; undo and redo; find and replace through `NSTextFinder` (`usesFindBar = true`); Go to Line (⌘L); toggles for soft wrap and line numbers.
- Tree-sitter highlighting with SwiftTreeSitter and Neon. Start with Swift, Rust, TypeScript, TSX, JavaScript, JSON and Markdown; the other R-ED-2 languages land before M5. Check each grammar's license.
- Image and PDF preview (`pane.preview:<absPath>`). Files over 8 MB, or with a NUL byte in the first 8 KiB, open read-only with Open With Default App.
- External changes, detected through a `DispatchSource` vnode watch: a clean buffer reloads silently, and a dirty one offers `editor.keepMine:` and `editor.reload:`.
- Recovery copies every 5 s while a buffer is dirty, in `$DATA/recovery/`, and `editor.restore:` when a newer copy exists. Quitting with dirty buffers asks first.
- The identifiers `pane.file:<absPath>` and `editor:<absPath>`, plus the rest of UX §2.4's `editor.*` list.
- STTextView is allowed if the gutter or performance becomes a sink; record that in DECISIONS.md (ARCHITECTURE §4.4). Editor state survives workspace switches because the pane container stays cached (T1.3).

**Acceptance.**
```zsh
mapo file open $D/a.swift --json | jq -e '.paneId'
mapo ui snapshot --json | jq -r .focus.id                             # → editor:<abs path of a.swift>
mapo ui type 'let answer = 42'; mapo ui key cmd+s; grep -c 'let answer = 42' $D/a.swift   # → 1
B=$(mapo rpc layout.get --json); mapo file open $D; echo $?; [ "$B" = "$(mapo rpc layout.get --json)" ]   # → 1, layout unchanged
ln -s $D/nope $D/broken; mapo file open $D/broken; echo $?           # → 1
mapo file open $D/logo.png                                           # → pane.preview:…; a 9 MB file opens read-only
echo x >> $D/a.swift                                                 # → a clean buffer reloads; a dirty one shows editor.keepMine and editor.reload
kill -9 "$(head -n 1 "$RUN/$I.app.pid")"                             # while dirty → a copy in $DATA/recovery/; relaunch, reopen → editor.restore
# switch workspaces and back                                         → unsaved text intact
mapo ui metrics --json | jq '.navigation[] | select(.name=="file.open")'   # → at most 100 ms for a 2,000-line file
```

**Budget and fallback.** 4 h. If the gutter stalls, ship line numbers only and move hunks to T4.3. **Commits.** `feat(core): file.open and file panes`, `feat(editor): TextKit 2 editor with highlighting, find and recovery`.

### T1.7 ⌘K palette

**Goal.** ⌘K reaches any workspace, tab, recent file or command by fuzzy search. **Requirements.** R-KEY-1.

**Deliverables.** A SwiftUI `PaletteView` in an `NSPanel` centered over the window. Its sources are workspaces, tabs with their state words, recent files, and every command from the Keymap table (T1.8). It scores subsequences, with bonuses for prefixes and word starts, and shows at most 50 rows. Enter runs a row. Esc closes the palette and restores the previous first responder. Identifiers `palette`, `palette.field` and `palette.row:<index>`.

**Acceptance.**
```zsh
mapo ui key cmd+k; mapo ui wait palette.field --state focused         # → palette.open at most 50 ms in ui.metrics
mapo ui type cli; mapo ui snapshot --json | jq -r '.. | objects | select(.id?=="palette.row:0") | .label'   # → contains cli
mapo ui key return; mapo ui snapshot --json | jq -r .focus.id          # → pane.terminal:cli, and the palette is gone
mapo ui key cmd+k; mapo ui key escape; mapo ui snapshot --json | jq -r .focus.id   # → focus restored
```

**Budget and fallback.** 2 h. **Commits.** `feat(ui): command palette`.

### T1.8 Menus and the full keyboard map

**Goal.** Every command is in the menu bar with its shortcut, and every shortcut in UX §8 works. **Requirements.** R-KEY-2, R-KEY-3; UX §8; ENGINEERING §4.1.

**Deliverables.** One command table in MapoUI builds the menu bar, the palette's commands and the drive's checklist, and each entry names its daemon method or `view`. Every shortcut in UX §8 works, or shows as a disabled item when its feature comes later: ⇧⌘T, ⇧⌘X and ⌘J before M2. ⌥⌘T opens the New Tab in Folder… sheet. ⌘, opens `config.toml` in the file pane (D-30). ⌘+, ⌘- and ⌘0 change the terminal and editor font size, regenerate `ghostty.conf` and call `ghostty_app_update_config`. ⌃⌘S and ⌥⌘0 map to the system `toggleSidebar:` and `toggleInspector:`. ⌥⌘R renames the tab.

**Notes.** Menu key equivalents win over the terminal because Ghostty's bindings are cleared (T0.8). ⌘C, ⌘V and ⌘A go to the first responder.

**Acceptance.** `drives/task-t1-8.sh` walks the command table, sends each chord with `mapo ui key`, and checks the effect through CLI JSON or the snapshot. Examples: ⌘1 focuses tab 1, ⇧⌘] the next tab and ⌃⌘↓ the next workspace. ⌘D adds a pane and ⌘W removes one. ⌥⌘0 toggles the inspector, and ⌘, opens config.toml. Every row passes, or is marked with its later milestone.

**Budget and fallback.** 2 h. **Commits.** `feat(ui): menu bar and keyboard map from one table`.

### T1.9 Appearance

**Goal.** The Mapo Glass look from the design boards, in dark and light, respecting accessibility settings. **Requirements.** R-NF-6, R-NF-5 (Reduce Motion, Reduce Transparency, Increase Contrast); UX §2.3 and §9.

**Deliverables.** `Theme.swift` with every UX §9 token, in dark and light. The rail and inspector get glass from their split view items, with no `NSVisualEffectView`. If a shot shows the inspector's material differing from the rail's, wrap the inspector in `NSGlassEffectView` (UX §2.3). Add the opaque pane cards and the window backdrop with its radial glows, and write the terminal colors into `ghostty.conf`. Reduce Transparency, Reduce Motion and Increase Contrast behave as UX §9.3 and §9.4 say. `config.toml [ui] appearance = "system" | "dark" | "light"` and `reduce-transparency = "system" | "on" | "off"` let drives capture every variant without touching system settings.

**Acceptance.** Take shots in dark, light and reduced transparency, and compare them with `docs/design/A-source-list.dc.html` and `S2-rail-slimmer.dc.html`. `summary.md` lists row heights, colors, the absent title bar, the traffic lights inside the rail and the matching glass, each marked as matching or differing.

**Budget and fallback.** 2 h. **Commits.** `feat(ui): Mapo Glass theme, dark and light`.

### T1.10 Drive `m1-daily`

**Goal.** The daily flow end to end within budgets. It is the M1 gate.

**Deliverables.** `drives/m1-daily.sh`, covering:
- two workspaces with three tabs each, and splits with ⌘D and ⇧⌘D;
- opening a file from Files with a click, then edit, save, find and go to line;
- 20 workspace switches with their p95, and a hidden 31 s command that fails and one that succeeds;
- palette navigation, a subset of the keymap, inline rename and reorder;
- quit and relaunch, keeping layout, order, names and editor text, and a daemon restart that keeps the layout and brings shells back in their cwds;
- the ENGINEERING §6 fixtures for reattach, switch and memory.

**Acceptance.** `just drive m1-daily` exits 0 with the Review filled in. `timings.json` shows launch at most 400 ms, switch p95 at most 50 ms and reattach at most 150 ms, or PROGRESS.md records each miss with its number. **Commits.** `test(drives): m1-daily drive`.

## 5. M2 to M5

These milestones are in less detail. Before starting one, re-read its requirements and expand its tasks here in the same form as M0 and M1.

**Rules for drives that run real Claude, from M2 on.**
- Work in `$DRIVE_TMP`, the disposable folder `drive_begin` creates, with harmless prompts that touch nothing outside it, such as "Reply with the single word OK."
- Claude shows a folder-trust dialog for a new folder, and Mapo never answers it (R-AG-3). The drive may accept it by sending Enter to that tab, only after `tab read` shows both the trust prompt and the disposable folder's path. Never for any other folder.
- Never pass `--dangerously-skip-permissions`, change permission modes or settings, or edit `~/.claude`. A login prompt means no real Claude for this run: record "Needs the user", mark those steps skipped and keep the synthetic ones.
- When your own session runs in auto mode, Claude Code's reviewer may refuse commands that start another agent. Record the refusal in PROGRESS.md and continue on the synthetic path, which feeds fixture JSON from `crates/mapo-agent/fixtures/` through `mapo hook` into the same status machine. Never retry a refused command in another shape.

### M2: Claude integration and attention

Exit criteria: `just drive m2-agents` passes. Hook-driven Working, Needs you and Done show in the rail, pane header, badge and dock badge. A notification is posted only when the tab can't be seen, and an agent resumes after a daemon restart.

#### T2.1 Plugin bundle and injection

**Goal.** Every Claude started in a Mapo tab loads Mapo's plugin, with no change to the user's settings. **Requirements.** R-AG-1, R-TAB-4, D-27. **Deliverables.** `plugin/.claude-plugin/plugin.json` (`name: "mapo"`); `plugin/hooks/hooks.json`, where every event in ARCHITECTURE §3.5 runs `[ -n "$MAPO_TAB_ID" ] && exec mapo hook || exit 0`; `plugin/.mcp.json` pointing at `mapo mcp` (it answers from T3.5); a stub `plugin/skills/mapo/SKILL.md` (T3.6). Embed it into `Contents/Resources/claude-plugin/`, and set `CLAUDE_CODE_PLUGIN_DIRS=<existing>:<plugin dir>` in every tab. Once per daemon start, run `claude --version` through the user's interactive shell with a 5 s timeout. Below 2.1.280, agent tab commands also get `--plugin-dir`; older CLIs ignore the variable, so the plugin never loads twice.

**Acceptance.** `mapo tab run t 'echo $CLAUDE_CODE_PLUGIN_DIRS'` ends with the plugin dir. In an agent tab in `$DRIVE_TMP`, once Claude has started, `mapo tab list --json` shows `agent.hooksConnected: true` and a `sessionId`. **Risks.** `CLAUDE_CODE_PLUGIN_DIRS` shipped on 2026-09-22, and its behavior next to a user's own `--plugin-dir` is unverified. Hook schemas change weekly, so parse them leniently.

#### T2.2 `mapo hook`, `hook.report` and the agent status machine

**Goal.** Agent status comes from hooks, with title and screen fallbacks. **Requirements.** R-AG-2, R-AG-3, R-CTL-4, contracts 12 and 13; FEATURE-MAP §5.1. **Deliverables.** `crates/mapo-agent` with an `AgentAdapter` trait and `ClaudeAdapter`. `mapo hook` reads at most 1 MiB of stdin, keeps only the fields `hook.report` accepts (PROTOCOL §6.7), logs only to `hook.<date>.log`, and always exits 0 within 2 s. `hook.report` keeps `toolSummary` only while the tab needs you. The status machine is ported from FEATURE-MAP §5.1 (the VS Code build's `mapoAgentSessions.ts`) and scoped by `agent_id`; Mapo records interrupts itself and ignores late events until the next UserPromptSubmit. Fallbacks: ✳ in the title means idle, spinner glyphs mean working, and a screen matcher for the trust and login dialogs (strings in `[agent] trust-dialog-patterns`) runs only while hooks aren't connected. Fixtures for every R-AG-3 event live in `crates/mapo-agent/fixtures/`, with table tests.

**Acceptance.** Inside tab `ag`, feed the fixtures in order with `mapo tab run ag "mapo hook < $ROOT/crates/mapo-agent/fixtures/<event>.json"`. UserPromptSubmit gives `running`, PermissionRequest `needs-you` and PostToolBatch `running`. After SubagentStart and a Stop the tab stays `running` until SubagentStop, and a final Stop gives `done`. From tab A, `MAPO_TAB_ID=<B> mapo hook < …` changes nothing about B, because the token is bound to tab A. With real Claude, a harmless prompt goes `running`, then `done`, and an untrusted folder shows `needs-you` from the screen matcher. **Risks.** Stop doesn't fire on Esc, so the interrupt bookkeeping must be right. Title glyphs and dialog wording change between Claude releases, which is why they live in config.

#### T2.3 Agent tabs

**Goal.** Agent tabs run the workspace's agent command through the interactive shell and can be interrupted safely. **Requirements.** R-AG-4, R-WS-6, R-TAB-1, R-TAB-2, contract 7. **Deliverables.** `workspace.configure {agentCommand}` and `mapo workspace configure NAME --agent-command CMD`. ⇧⌘T and `tab new --kind agent` type a command into the shell, so aliases like `claude-work` resolve: the tab's override, else the workspace's command, else `[agent] default-command` (`claude`). `tab.interrupt` sends Escape and records `interruptedAt`. It runs from `mapo tab interrupt`, ⇧⌘X and the pane's Stop (`pane.stop:<tabName>`), which shows only while the agent works. An interrupt goes to the pane whose Stop was clicked.

**Acceptance.** Real Claude in `$DRIVE_TMP`: `tab send ag "Write the numbers 1 to 300, one per line."` gives `running`. Clicking `pane.stop:ag` while another pane has focus makes `ag` `idle` and interrupted and leaves the other tab alone, and a follow-up prompt runs. Synthetic: `tab interrupt` after a UserPromptSubmit fixture gives `idle`, and a late Stop fixture doesn't mark it `done`. **Risks.** Escape behaves differently during a permission dialog than during a turn. Test both.

#### T2.4 Attention

**Goal.** Tabs that need the user are hard to miss and never steal focus. **Requirements.** R-ST-3, R-ST-4, R-ST-5, R-ST-6, D-8; UX §7.3. **Deliverables.** The rail badge, and the dock badge (`NSApp.dockTile.badgeLabel`) with the needs-you count across workspaces. `UNUserNotificationCenter` notifications for needs-you, failed and done when the tab can't be seen, authorized lazily; the identifier `<instance>/<tabId>` coalesces repeats, and a click runs `tab.focus`. Done clears on view, and ⌘J focuses the next tab that needs you. `attention.changed`, `dockBadge` in the snapshot model, and the ENGINEERING §4.2 log line for every posted or suppressed notification.

**Acceptance.** A PermissionRequest fixture for a tab in another workspace fires `attention.changed {count: 1}`, sets `rail.workspace.badge:<ws>` and `.model.dockBadge` to 1, and logs `notification:<tabId> … shown=true reason=posted`. A second fixture logs `reason=coalesced`. ⌘J focuses that tab. The same event for the focused, visible tab logs `reason=visible`. **Risks.** macOS asks for notification permission once, in a dialog the agent can't answer. Record "Needs the user" and rely on the log line (ENGINEERING §10). Dev instances share `dev.mapo.app.dev`, so ignore notification responses whose instance prefix isn't yours.

#### T2.5 Session IDs and resume

**Goal.** Agent tabs come back with their conversation after a daemon restart. **Requirements.** R-AG-6, R-AG-7, R-PER-3. **Deliverables.** Migration `0002` with `agent_sessions`. The `session_id` is saved from SessionStart. On daemon start, agent tabs launch `<agentCommand> --resume <session_id>`. A failed resume leaves the tab with its reason and a retry, as R-TAB-9 does for launches.

**Acceptance.** Real Claude: "Remember the word PAPAYA and reply OK." reaches `done`. Restart the drive's daemon. `pgrep -fl -- '--resume'` shows the session ID, and `tab send ag "Which word did I ask you to remember? Reply with the word only."` followed by `tab wait ag --until PAPAYA` exits 0. **Risks.** Resume behavior may change between Claude releases, so the drive records the Claude version.

#### T2.6 Drive `m2-agents`

**Goal.** The M2 gate. **Deliverables.** `drives/m2-agents.sh`. The synthetic path always runs: every R-AG-3 transition through `mapo hook`, attention while hidden, the badge and dock badge, the notification log, ⌘J, done on view, and interrupt. The real-Claude path follows under the rules above: start, trust in `$DRIVE_TMP`, a turn, Stop, resume. A step may be skipped only with a recorded reason. **Acceptance.** `just drive m2-agents` exits 0, with shots of Working, Needs you and Done in the rail and pane header.

### M3: agent control plane

Exit criteria: `just drive m3-control` passes. An agent inside Mapo drives Mapo through the CLI and MCP, guards reject and log, and `tab ask` returns replies.

#### T3.1 CLI verb parity, output formats, exit codes

**Goal.** Every v1 verb, keeping the VS Code build's names, flags and JSON shapes where the feature exists. **Requirements.** R-CTL-2, R-CTL-3, D-25; FEATURE-MAP §5.9. **Deliverables.** The verbs of R-CTL-2 and PROTOCOL §9, checked against `docs/reference/vscode-build/COMMANDS.md`, and `mapo --help` grouped by noun. Tables on a TTY, raw text for `tab read`, `tab run` and `git changes`, compact JSON when piped, errors as PROTOCOL §4 prints them, and exit codes 1, 2, 5 and 124. **Acceptance.** `drives/task-t3-1.sh` walks a table of commands, with expected exit codes and jq filters, that covers every verb, and it passes. `script -q /dev/null target/debug/mapo --instance $I tab list` prints a table with a header row. **Risks.** PROTOCOL names `tab.run`'s parameter `command` where the VS Code build used `text`. Keep PROTOCOL's name and note it in the parity table.

#### T3.2 Credentials, guards, activity

**Goal.** Credentials identify callers, destructive agent actions need `--force`, and every mutating request from an agent or the automation surface is logged. **Requirements.** R-CTL-4, R-CTL-6, R-NF-4; FEATURE-MAP §5.10. **Deliverables.** Scope checks for `tab` and `hook` credentials. `force` guards for deleting workspaces, closing another tab and stopping a process. Migration `0003` with `activity`, bounded to 5,000 rows. `activity.list`, `mapo activity` and `activity.recorded` events. **Acceptance.** From inside tab A, `mapo tab close B` exits 1 with `forbidden`, and `--force` closes it. `mapo activity --json` lists both, with caller tab A and the outcomes `rejected` and `ok`. A `mapo ui click` appears as an automation entry. `grep -rFf` over activity, events and logs finds no live token.

#### T3.3 Final semantics of `tab run`, `ask`, `wait`, `read` and `send`

**Goal.** Agent-to-agent calls return real answers without screen scraping. **Requirements.** R-AG-5, R-CTL-9, contracts 5, 6 and 13; FEATURE-MAP §5.3 to §5.5. **Deliverables.** `tab.ask` waits until the target is idle or done. It pastes the prompt with bracketed paste and submits it, confirms UserPromptSubmit within 10 s, waits for Stop, and returns `{reply: last_assistant_message, turnMs}`. It fails with `needs_you` (exit 5) when the target needs the user during the ask, and with `timeout` (exit 124). `last_assistant_message` is held only while an ask waits. `tab wait --until idle` accepts `idle` or `done` for agents.

**Acceptance.** Real Claude: `mapo tab ask ag "Reply with exactly: PONG"` prints PONG and exits 0. A prompt that makes Claude ask permission in the default mode, such as "Create an empty file named x.txt here", exits 5, and the tab shows Needs you. `--timeout-ms 1000` on a long prompt exits 124. `tab read` of Claude's screen includes its menu rows below the cursor. **Risks.** If Claude's permission flow changes, find another harmless trigger. Never loosen permissions to get one.

#### T3.4 Event cursors, replay, `events.wait`

**Requirements.** R-CTL-5. **Deliverables.** Replay with `--after`, the cursor-expired error from T0.4, a fresh snapshot after a boot ID change, and `events.wait {after, timeoutMs}` → `{events, cursor}` as a long poll. **Acceptance.** After 10,050 renames, `mapo events --after 1` exits 1 with the cursor expired. `mapo events --follow --after <recent seq>` replays with consecutive `seq` values. `mapo rpc events.wait '{"after":<latest>,"timeoutMs":500}'` returns `{events: []}` after about 500 ms.

#### T3.5 `mapo mcp`

**Goal.** Claude in a Mapo tab gets one typed MCP tool per public command. **Requirements.** R-CTL-7; PROTOCOL §10. **Deliverables.** `crates/mapo-mcp` on rmcp, over stdio, pinned with `=` to the current 3.x (check with `cargo info rmcp`; ARCHITECTURE lists 3.5.0). It requires `MAPO_TOKEN` and never falls back to the app token. Closing stdin cancels waits and exits 0. Tools `mapo_<group>_<verb>` cover PROTOCOL §6.1 to §6.7, plus `mapo_events_wait` and the resource `mapo://skill`. Schemas come from the protocol types (schemars, `additionalProperties: false`), and descriptions stay under 2,048 characters. Failures set `isError`; successes return `structuredContent.result`. There are no `ui.*`, `app.*`, `hook.*` or `daemon.*` tools.

**Acceptance.** Inside a tab, piping `initialize`, `tools/list` and `tools/call mapo_tab_list` into `mapo mcp` returns the tools and the tab list. Outside a tab, `mapo mcp` exits 1 with a clear message. With real Claude, "Use the mapo MCP tool that lists tabs and reply with the number of tabs only." makes `tab ask` return the right number; Claude names the tool `mcp__plugin_mapo_mapo__mapo_tab_list`. **Risks.** rmcp went through three major versions between March and July 2026, so keep it inside `mapo-mcp`.

#### T3.6 The skill for native

**Requirements.** R-CTL-8. **Deliverables.** `plugin/skills/mapo/SKILL.md`, ported from `docs/reference/vscode-build/SKILL.md`. It covers names versus titles, the verbs, waiting instead of polling (`tab wait`, `events.wait`), guards and `--force`, exit codes and conventions. `mapo skill` prints it, and `mapo://skill` serves the same text. **Acceptance.** `diff <(mapo skill) plugin/skills/mapo/SKILL.md` is empty, and the MCP resource returns the same bytes.

#### T3.7 Drive `m3-control`

**Deliverables.** `drives/m3-control.sh`. A shell tab acting as an agent, with its own `MAPO_TOKEN`, creates tab B, runs a command, waits on output, reads the screen, hits a guard, retries with `--force` and reads the activity log. With real Claude, one agent tab then asks another with `tab ask`, and a third uses the MCP tools. **Acceptance.** `just drive m3-control` exits 0, with the activity log and the replies saved as evidence.

### M4: servers in tabs, ports, Changes

Exit criteria: `just drive m4-servers-changes` passes.

#### T4.1 Server detection

**Goal.** Any tab that listens on a TCP port is labeled as a server, detected from events. **Requirements.** R-SRV-1, R-SRV-2, R-SRV-3, R-SRV-4, D-20. **Deliverables.** `crates/mapo-proc` finds the processes on the tab's TTY (`libproc` `pids_by_type(ProcFilter::ByTTY)`) and their LISTEN sockets (`proc_pidfdinfo`). Scans run on 133;C and D, then after 1 s, 2 s and 5 s, then every 10 s while the command runs. Idle tabs are never scanned. `tab.server {ports}` drives the rail's server icon and `:PORT` accessory (UX §3), and the pane header's `localhost:PORT` with Open in Browser (`pane.openURL:<tabName>`). A serving command that exits non-zero gives `failed` with "exit N". Stop sends Ctrl-C.

**Acceptance.** Run `mapo tab send srv 'nc -l 4173'`. Within 2 s, `.server.ports == [4173]` and the row's accessory is `port::4173`. Stop clears the ports. A command that listens and then exits 3 gives `failed` with "exit 3". With `MAPO_LOG=mapo_proc=debug`, the daemon log shows no scans while every tab sits idle for 60 s. **Risks.** Docker-published ports show Docker's proxy process. Processes that daemonize leave the TTY.

#### T4.2 Ports and processes

**Requirements.** R-SRV-5; FEATURE-MAP §5.6. **Deliverables.** `proc.ports` uses the `listeners` crate, filtered to the current user's LISTEN sockets and mapped to tabs by TTY or by ancestry up to a tab's shell. A process's identity is a hash of its pid, start time and executable path. `proc.stop` re-checks the identity and refuses Mapo, the daemon, their ancestors and other users' processes. It sends only SIGTERM and needs `force` from agents. A palette section, `mapo ports [--port N]` and `mapo process stop PID --identity ID [--force]`. **Acceptance.** With `nc -l 4175` in a tab, `mapo ports --port 4175 --json` shows its pid and `tabId`. `process stop` with that identity returns `signalSent`, and nc exits. A stale identity gives `conflict`, and the daemon's own pid gives `forbidden`.

#### T4.3 Changes inspector, diff view, gutter

**Requirements.** R-GIT-1, R-GIT-2, R-GIT-3, R-ED-3; UX §5.3 and §6.3. **Deliverables.** `git.status`, `git.diff` and `git.baseText` through the git CLI with `-c core.fsmonitor=false --no-optional-locks`. The Changes segment has a summary row (`inspector.changes.summary`) and rows with letters and +/- counts (`inspector.changes.row:<relPath>`). A warning (`inspector.changes.warning`) appears above `[changes] warn-lines` (1,500) or `warn-files` (50). A read-only unified `DiffView` (`pane.diff:<absPath>`) with Open File (`pane.openFile:<absPath>`). Everything updates live on file changes, commits and branch switches. The editor's git gutter is diffed in the app against `git.baseText` with `CollectionDifference`, debounced at 200 ms. **Acceptance.** In a temporary repository, modified, added and untracked files show letters and counts. Selecting a row opens `pane.diff:<path>` with colored lines. A 60-file change shows the warning. `git commit -am` in a tab empties the list within 1 s. An edit shows a gutter hunk before saving.

#### T4.4 Drive `m4-servers-changes`

**Deliverables.** `drives/m4-servers-changes.sh` covers T4.1 to T4.3, with shots of the server row, the header URL and the diff view. **Acceptance.** `just drive m4-servers-changes` exits 0.

### M5: switch-over

Exit criteria: `just profile=release drive m5-switch` meets R-NF-1 or records each miss with its numbers, and the user signs off the daily-driver checklist.

#### T5.1 Performance pass

**Requirements.** R-NF-1; ENGINEERING §6. **Deliverables.** The full `ui.metrics`, with frame pacing from `NSView.displayLink(target:selector:)`. `mapo debug latency --tab NAME`. `drives/m5-switch.sh`, which runs every ENGINEERING §6 fixture on a Release build with `DRIVE_ENFORCE_BUDGETS=1`. Tune replay size, emulator scrollback and event throttles until the budgets hold, profiling with `sample`, `xctrace`, `footprint` and `vmmap`. The Typometer comparison against Ghostty.app runs with the user in T5.3. **Acceptance.** PROGRESS.md lists every R-NF-1 metric with its budget and the median of three runs. **Risks.** Twenty tabs with a 2 MiB ring each already use 40 MB of the daemon's 150 MB budget, and each 2,000-line emulator costs several MB when full of wide lines. Lower the ring or the emulator scrollback if the budget fails.

#### T5.2 Install flow (with the user)

**Requirements.** R-PER-4, D-29; ENGINEERING §10. **Deliverables.** `just install` makes a Release build with bundle ID `dev.mapo.app` and instance `main`. It installs to `~/Applications/Mapo.app`, because the frozen build owns `/Applications/Mapo.app` until T5.4. A login agent runs through `SMAppService.agent(plistName:)`, with `Contents/Library/LaunchAgents/dev.mapo.mapod.plist` running `Contents/Helpers/mapo daemon --foreground --instance main`. That code runs only for bundle `dev.mapo.app`, instance `main` and an executable outside a git worktree, and it registers only after the user confirms. The agent prepares this and never runs it alone. **Acceptance.** With the user: the app launches at login, the daemon survives logging out and back in, and the tabs come back.

#### T5.3 Daily-driver checklist (with the user)

**Deliverables.** A checklist in PROGRESS.md built from the user's real flows: their workspaces, `claude-work`, dev servers, files, ⌘K and attention. The user works through it for at least three working days, and every problem becomes a task. The Typometer run and the sub-frame flicker checks from ENGINEERING §5.5 happen here.

#### T5.4 Retire the VS Code build (with the user)

**Deliverables.** After a clean week on native, the user quits and archives `/Applications/Mapo.app` and `~/.mapo`, and the native app moves to `/Applications/Mapo.app`. The branch `mapo` and `~/code/mapo` stay frozen. Nothing deletes them.

## 6. Morning report template

At the end of every overnight run, copy this block to the top of docs/PROGRESS.md and fill it in.

```markdown
## YYYY-MM-DD morning report

Run: started HH:MM, stopped HH:MM America/Sao_Paulo. Parallel worktrees: none, or list them.
Summary: one or two sentences on where M0 and M1 stand, and what the user should try first.

### What works
| Task | Status | Evidence | Review verdict | Notes |
|---|---|---|---|---|
| T0.1 Repo scaffolding | done | evidence/… | accept | |
| T0.8 Terminal surface | done with Ghostty, or fallback with SwiftTerm | evidence/task-t0-8/…/ | | |

Try it: `cd ~/code/mapo-native && just app`

Screenshots: ![Rail and terminal](progress/T0.11-relaunch.png)

### Drives
| Drive | Result | Evidence |
|---|---|---|
| m0-skeleton | PASS, 11 of 11 steps | evidence/m0-skeleton/…/ |

### Metrics against budgets (R-NF-1)
| Metric | Budget | Measured | Source |
|---|---|---|---|
| Cold launch to first interactive frame, daemon running | ≤ 400 ms | | ui.metrics launch |
| Reattach and paint a workspace (N tabs) | ≤ 150 ms | | navigation app.reattach |
| Switch workspace to visible | ≤ 50 ms | | navigation workspace.switch, from M1 |
| Keystroke to glyph, compared with Ghostty | ≤ +2 ms | not measured before M5 | mapo debug latency |
| Idle CPU, 20 tabs | app ≈ 0%, daemon < 0.5% | | mapo debug stats --interval-ms 60000 |
| Memory, 20 tabs and 10 visible | daemon ≤ 150 MB, app ≤ 250 MB | | mapo debug stats, footprint |
| No-op and cold `just build` | no-op under 10 s | | |

Debug-build numbers are trends only (ENGINEERING §6).

### Deviations from the docs
| Task | Spec and section | Said | Did | Why | Spec updated |
|---|---|---|---|---|---|

### Blockers
- Task: symptom, exact error, what was tried, next idea.

### Needs the user
- Item: why the agent couldn't do it, and what to click or decide.

### Next task
Tx.y name: the first concrete step.
```
