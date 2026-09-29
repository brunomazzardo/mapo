# Mapo native: engineering

Status: approved direction (2026-09-28). This is the handbook for building, running, driving and measuring Mapo native from the first commit. [REQUIREMENTS.md](REQUIREMENTS.md) §5 states R-ENG-1 to R-ENG-5; this file makes them concrete. [ARCHITECTURE.md](ARCHITECTURE.md) and [PROTOCOL.md](PROTOCOL.md) define the processes and the wire format. [PLAN.md](PLAN.md) orders the work and [HANDOFF.md](HANDOFF.md) has the hard rules for agents.

## 1. Principles

The user's requirement, verbatim (DECISIONS D-22):

> mapo should be auto testable, auto drivable, lightweight, easy to run on worktrees and develop in parallel, build and optimize in parallel, focus on auto drivable tests not automated tests, tests that can feel the ux/ui and use the app.

Each principle below is a rule with a check. A task that fails a check is not done.

| # | Principle | Rule | Check |
|---|---|---|---|
| P1 | Drivable first | A feature ships with its daemon command (a `mapo` verb), an identifier on every interactive element (§4.2), and a drive step that uses it through the UI (§5). | The task's drive calls `mapo ui` on the new identifiers. The identifier check in §4.2 returns 0. |
| P2 | Isolation | Every process belongs to one instance (§2). Dev work never uses `main`, never touches the frozen app or its data, and nothing listens on TCP. | `lsof -nP -a -iTCP -sTCP:LISTEN -p <daemon pid>,<app pid>` prints nothing. `just kill` in one worktree leaves every other instance running. |
| P3 | Lightweight | No Electron, Node or web views at runtime. Every dependency has a line in ARCHITECTURE §3.1. Work is event-driven; any timer backs off. | The R-NF-1 budgets hold (§6). A no-op `just build` takes under 10 s. |
| P4 | Parallel | Any number of worktrees build, run and drive at once and share only read-mostly caches (§7). A fresh worktree needs no manual step beyond `just setup`. | T0.10: two worktrees run instances side by side while both build. `just setup && just build && just drive m0-skeleton` passes in a new worktree. |
| P5 | Evidence over assertions | A task is done when a drive has used the real app and an agent has reviewed the evidence (§5.5). "It compiles" and "tests pass" never mean done. | The PROGRESS.md entry names the evidence folder and the review verdict. |

## 2. Instances and worktrees

An instance is one isolated Mapo world: its own daemon, socket, lock, tokens, database, config, logs and window title. Instances share nothing.

### 2.1 Name resolution

Every Mapo process (CLI, daemon, app, attach, hook, mcp) resolves its instance in this order and stops at the first hit:

1. `--instance NAME`
2. `MAPO_INSTANCE`
3. The worktree default. Walk up from the real path of the process's own executable to the first directory that contains `.git` (a file in a linked worktree, a folder in a main checkout). The name is `dev-<basename of that directory>`.
4. `main`

Names match `[a-z0-9][a-z0-9-]{0,31}`. The worktree default is not normalized. A folder like `Mapo_Native`, or one longer than 28 characters, fails with a message to rename the folder or pass `--instance`.

| Executable | Instance |
|---|---|
| `~/code/mapo-native/target/debug/mapo` | `dev-mapo-native` |
| `~/code/mapo-native-rail/.build/xcode/Build/Products/Debug/Mapo.app/Contents/Helpers/mapo` | `dev-mapo-native-rail` |
| `/Applications/Mapo.app/Contents/Helpers/mapo` (installed app, M5) | `main` |

Drives pass `--instance drive-<name>-<HHMMSS>`. The resolution code lives once, in `crates/mapo-instance`. The app doesn't re-implement it. At launch it runs its bundled `mapo instance show --json` (with its own `--instance` if it got one) and uses the returned name and paths.

### 2.2 Paths

| What | Path | Mode |
|---|---|---|
| Instance data | `~/Library/Application Support/dev.mapo.app/instances/<instance>/` with `state.db` (+ `-wal`, `-shm`), `config.toml`, `app.token`, `logs/`, `recovery/` | dir 0700, `app.token` 0600 |
| Runtime dir | `$(getconf DARWIN_USER_TEMP_DIR)mapo/` | 0700 |
| Socket | `<runtime>/<instance>.sock`; at most 91 bytes on this machine (`/var/folders/w4/…/T/mapo/`), under the 104-byte limit | 0600 |
| Daemon lock | `<runtime>/<instance>.lock` | 0600 |
| Daemon pid file | `<runtime>/<instance>.pid`: line 1 the pid, line 2 the executable path | 0600 |
| App pid file | `<runtime>/<instance>.app.pid`, same format, written by the app at launch and removed at exit | 0600 |
| Logs | `<data>/logs/mapod.YYYY-MM-DD.log`, `app.…`, `attach.…`, `hook.…`; daily files, 7 kept | |
| Shared cache | `~/Library/Caches/mapo/`: `ghostty/<version>/`, `drive.lock/` | |
| Build outputs | `<worktree>/target/`, `<worktree>/.build/` | |
| Evidence | `<worktree>/evidence/<drive-or-task>/<YYYYMMDD-HHMMSS>/` (gitignored) | |

### 2.3 Locks, sockets and tokens

Daemon start, in order:

1. Resolve the instance. Create the data dir and the runtime dir with mode 0700. Refuse to start if the runtime dir belongs to another user.
2. Open `<instance>.lock` and take `flock(LOCK_EX | LOCK_NB)`. If that fails, exit 1 with `instance <name> is already served by pid <pid> (<exe>)`, read from the pid file. The kernel drops the lock when the process dies, so a stale lock can't exist.
3. Write the pid file. Open `state.db` and run migrations.
4. Write a fresh `app.token` to a temp file with mode 0600 and rename it into place.
5. Remove any leftover `<instance>.sock` (holding the lock proves no daemon owns it), bind with umask 0177, and listen.
6. Restore tabs from their definitions, log `ready`, and accept connections.

On `daemon.shutdown`, SIGTERM or SIGINT, the daemon emits `daemon.stopping`, stops accepting, hangs up its tabs, flushes SQLite, removes the socket and the pid file, and exits 0. Every 60 s it checks that its socket file still exists and rebinds if a temp-dir cleanup removed it.

Credentials follow PROTOCOL §3, plus these instance rules:

- `app.token` changes on every daemon boot. The app, the CLI and `mapo attach` (on every reconnect) read it from the data dir and never reuse one across a new `bootId`.
- The CLI sends `MAPO_TOKEN` only when `MAPO_INSTANCE` equals the instance it resolved. Otherwise it uses that instance's `app.token`. `just mapo` and drives unset `MAPO_TOKEN` and `MAPO_HOOK_TOKEN`, so they act as the operator.
- Before setting the R-TAB-4 variables, the daemon removes every inherited `MAPO_*` variable from a tab's environment. A `mapo` in a tab always reaches its own instance, and variables from the frozen app's terminals (`MAPO_TAB_ID`, `MAPO_AGENT_TOKEN`, `MAPO_CLI_SOCKET_FILE`) or from `just dev` (`MAPO_DEV_INSTANCE`) never leak into tabs.

### 2.4 How the processes agree on the instance

| Process | Instance comes from |
|---|---|
| `just` recipes | the `instance` variable (§3.1), passed as `--instance` to every command |
| `mapo` CLI | §2.1 |
| Mapo.app | `--instance` in argv, else §2.1 through its bundled `mapo` |
| Daemon spawned by the app | `mapo daemon --instance <the app's instance>` |
| `mapo attach` | `--instance` and `MAPO_INSTANCE`, set by the app on each surface |
| Shells, Claude, `mapo hook`, `mapo mcp` | `MAPO_INSTANCE`, set by the daemon for each tab |

Every client compares `instance` in the `hello` result with the name it resolved, and fails with both names on a mismatch. `mapo instance show` prints the name with its source (`flag`, `env`, `worktree` or `default`).

The `mapo instance` subcommands (T0.2):

| Command | Does |
|---|---|
| `mapo instance [show] [--json]` | name, source, worktree, every path above, `daemon: {running, pid, exe, bootId, protocol}`, `app: {running, pid}` |
| `mapo instance list [--json]` | every instance under the data root or the runtime dir, with running state and disk use |
| `mapo instance wait [--timeout-ms N]` | waits until the daemon answers `ping`; exit 124 on timeout |
| `mapo instance stop` | `daemon.shutdown`, then after 5 s SIGTERM, then after 3 s SIGKILL, each sent only if the pid's executable and argv still match the pid file |
| `mapo instance clean` | deletes a stopped instance's data dir and runtime files |

A binary whose executable lies inside a git worktree refuses `daemon`, `instance stop` and `instance clean` for `main`.

### 2.5 Running several instances

```sh
cd ~/code/mapo-native      && just app    # dev-mapo-native
cd ~/code/mapo-native-rail && just app    # dev-mapo-native-rail
just instance=dev-scratch app             # a scratch instance on the same build
just mapo instance list                   # every instance and its state
just instance=dev-scratch kill && just clean-instance dev-scratch
```

Each instance costs one daemon and one app process. The Dock and ⌘-Tab show one "Mapo Dev" per instance; the window title tells them apart.

### 2.6 Bundle ids, names and window titles

| | Dev builds (all dev instances) | Installed app (M5) | Frozen VS Code build |
|---|---|---|---|
| Bundle id | `dev.mapo.app.dev` | `dev.mapo.app` | `dev.mapo.Mapo` |
| Display name | Mapo Dev | Mapo | Mapo |
| Instances | `dev-<worktree>`, `drive-…`, any name but `main` | `main` | none |
| Window title (UX §2) | `<workspace> (<instance>)` | `<workspace>` | |
| Data | `…/dev.mapo.app/instances/<instance>/` | `…/dev.mapo.app/instances/main/` | `~/.mapo`, `~/Library/Application Support/Mapo` |

- `app/project.yml` sets `PRODUCT_BUNDLE_IDENTIFIER = dev.mapo.app.dev` and the display name "Mapo Dev" for every configuration, Release included. Only `just install` (T5.2) builds `dev.mapo.app`.
- The title bar is hidden (R-NF-6), but `NSWindow.title` still names the instance for Mission Control, the Window menu, `mapo ui window` and screenshots. Outside `main`, the `toolbar.title` subtitle also starts with the instance name (UX §2.1).
- Dev instances share everything macOS keys by bundle id: UserDefaults, notification permission, saved window state. Keep per-instance state in the daemon or `config.toml`, put the instance in autosave names (the frame autosaves as `main-<instance>`), and turn off window restoration; sessions come from the daemon.

### 2.7 Extra worktrees for parallel work

```sh
git -C ~/code/mapo-native worktree add ../mapo-native-<topic> -b native-<topic> native
cd ~/code/mapo-native-<topic>
just setup && just build     # the first build compiles every dependency
just app                     # instance dev-mapo-native-<topic>
```

- `<topic>` is `[a-z0-9-]`, 16 characters at most, so the instance name fits in 32.
- Stay current with `git rebase native`. To land, run `git merge --ff-only native-<topic>` in `~/code/mapo-native`, then `just build` and the relevant drive there.
- To remove it, run `just kill && just clean-instance` in the topic worktree, then `git -C ~/code/mapo-native worktree remove ../mapo-native-<topic>` and `git -C ~/code/mapo-native branch -d native-<topic>`. Never push (HANDOFF §6).

### 2.8 Never touch `main` or the frozen app

- Never run `killall Mapo`, `pkill Mapo`, `pkill -x Mapo`, `open -a Mapo` or AppleScript `tell application "Mapo"`. The frozen app's executable and name are also `Mapo`, so these hit it along with every dev instance. Launch dev apps by path (`just app`, drives). Stop processes through pid files (`just kill`, `mapo instance stop`) or the pids a drive recorded.
- Don't read or write `/Applications/Mapo.app`, `~/.mapo` or `~/Library/Application Support/Mapo`. The native root `~/Library/Application Support/dev.mapo.app/` has a similar name; check paths twice.
- Don't use instance `main`. `just` refuses it and worktree binaries refuse to serve, stop or clean it.
- `~/code/mapo` is the frozen checkout on branch `mapo`. Read it; never commit, check out, reset or clean there.
- A `mapo` on `PATH` may be another build. In a worktree use `just mapo` or `target/<profile>/mapo`.

## 3. Dev loop

### 3.1 Justfile variables

| Variable | Default | Override |
|---|---|---|
| `instance` | `$MAPO_DEV_INSTANCE`, else `dev-<worktree folder>` | `just instance=dev-scratch app` |
| `profile` | `$MAPO_DEV_PROFILE`, else `debug` | `just profile=release build` |
| `jobs` | `$MAPO_JOBS`, else `num_cpus()` | `MAPO_JOBS=4 just build` |
| `task` | `snap` | `just task=T0.7 snap rail` |

- Every recipe refuses `instance=main`. `just dev` exports `MAPO_DEV_INSTANCE` and `MAPO_DEV_PROFILE` so its mprocs panes use the same values. Never export them from a shell profile.
- The justfile does not read `MAPO_INSTANCE`. A tab sets it, so honoring it would let `just dev` in a Mapo tab target the tab's instance.
- Recipes that take arguments use `[positional-arguments]` and `"$@"`, so quoting survives: `just mapo tab send terminal-1 'echo a b'`.
- Recipes that start a long-running process `exec` it. `just` 1.46 forwards SIGTERM to its child, so mprocs can stop it cleanly.

### 3.2 Recipes

| Recipe | Does | Writes | Re-running |
|---|---|---|---|
| `just setup` | Checks Xcode 27, Rust 1.96 (`rust-toolchain.toml`), xcodegen ≥ 2.46, just ≥ 1.46, mprocs ≥ 0.9, jq; reports zig and sccache as optional; installs the pinned `typeshare-cli` with `cargo install --locked` if missing; runs `just ghostty` and `just gen`; creates `evidence/`. | cache, `.build/ghostty/`, generated files | Safe, under 5 s when warm. Exit 1 lists each missing tool with its install command. |
| `just ghostty` | Reads `third_party/ghostty.lock` (`VERSION`, `URL`, `SHA256` lines). If the cache lacks a verified copy, downloads to `<cache>/<VERSION>.tmp.<pid>/`, checks `shasum -a 256`, unzips and renames it into place. Links the worktree to it. | `~/Library/Caches/mapo/ghostty/<VERSION>/`, `.build/ghostty/GhosttyKit.xcframework` (symlink; an APFS clone `cp -cR` if the toolchain rejects symlinks) | No network once verified. Concurrent runs are safe: a rename loser discards its copy. |
| `just gen` | Generates Swift protocol types from `crates/mapo-protocol` with typeshare, then `xcodegen generate --spec app/project.yml --use-cache --cache-path .build/xcodegen.cache`. | `app/Packages/MapoKit/Sources/MapoProtocol/Generated/`, `app/Mapo.xcodeproj` (both gitignored) | Rewrites a file only when its content changed, so mtimes stay and nothing recompiles. |
| `just build` | `cargo build -p mapo -j {{jobs}}` (plus `--release` for `profile=release`), `just gen`, then `xcodebuild -project app/Mapo.xcodeproj -scheme Mapo -configuration <Debug\|Release> -derivedDataPath .build/xcode -destination 'platform=macOS,arch=arm64' -jobs {{jobs}} MAPO_PROFILE={{profile}} build`. Prints errors, warnings and the app path. | `target/<profile>/mapo`, `.build/xcode/Build/Products/<Config>/Mapo.app`, full log in `.build/logs/xcodebuild.log` | Incremental; a no-op build takes under 10 s. |
| `just daemon` | Builds `mapo` for `profile`, then `exec target/<profile>/mapo daemon --instance {{instance}} --foreground`. | daemon log on stderr and in `logs/` | Exit 1 with the owner's pid and exe if the instance already has a daemon. |
| `just app *ARGS` | `just build`; stops the app named in this instance's app pid file if that pid still runs `…/Mapo.app/Contents/MacOS/Mapo` (SIGTERM, 5 s, then SIGKILL); then `exec`s `Mapo.app/Contents/MacOS/Mapo --instance {{instance}} ARGS`. The app spawns a detached daemon if none runs, unless ARGS has `--no-spawn-daemon`. | | Leaves exactly one app for this instance, on the fresh build. |
| `just dev` | `just build`, then `exec mprocs --config mprocs.yaml` with `MAPO_DEV_INSTANCE` and `MAPO_DEV_PROFILE` set. | | A second `just dev` for the same instance shows "already served" in its daemon pane. |
| `just mapo *ARGS` | `target/<profile>/mapo --instance {{instance}} ARGS`, with `MAPO_TOKEN` and `MAPO_HOOK_TOKEN` unset. | CLI output | Does not build. A missing binary prints "run just build". |
| `just drive NAME *ARGS` | `just build`, then `zsh drives/NAME.sh ARGS` with `MAPO_ROOT` and `MAPO_PROFILE` set. | `evidence/NAME/<ts>/` | Each run uses a new instance and folder. Exit status is the drive's result. |
| `just snap [STEP]` | Writes `snapshot-STEP.json` (`mapo ui snapshot`) and `shot-STEP.png` (`screencapture -x -o -l <windowNumber>`) of this instance's window. STEP defaults to `manual`. | `evidence/{{task}}/<ts>/` | Needs the app running. Without pixels it prints `pixels: unavailable` and still writes the snapshot. |
| `just kill` | Stops this instance's app (app pid file, same check as `just app`) and daemon (`mapo instance stop`). | | Exit 0 when nothing runs. Never touches another instance. |
| `just clean-instance [NAME]` | NAME defaults to this instance. Stops it, then `mapo instance clean`. A glob such as `'drive-*'` cleans only stopped instances and lists the running ones it skipped. | | Refuses `main`. Safe to repeat. |
| `just fmt` | `cargo fmt --all`; `xcrun swift-format format --in-place` on every Swift file outside `Generated/`. | sources | Idempotent. |
| `just lint` | `cargo fmt --all --check`; `cargo clippy --workspace --all-targets -- -D warnings`; `xcrun swift-format lint --strict` on the same Swift files; `zsh -n drives/*.sh`. | | Read-only. Exit 1 on any finding. |
| `just test` | `cargo test --workspace`; `swift test --package-path app/Packages/MapoKit --scratch-path .build/swiftpm`. | | Under 60 s. No network, no app, no instance (§8). |

App flags: `--instance NAME`, and `--no-spawn-daemon`, which makes the app wait and reconnect instead of spawning. While it can't reach its daemon the app shows the `app.banner` states from UX §4.3 ("Reconnecting to mapod…"), never a blank window (R-NF-3).

`mapo daemon` without `--foreground` forks a detached daemon (setsid), waits up to 10 s until it answers `ping`, prints `{"pid":…,"socket":"…"}` and exits 0. If the daemon fails to start it exits 1 with the reason. The app's auto-spawn and the drives use this mode.

### 3.3 What runs where

| Piece | Binary | Resources (shell integration, terminfo, Claude plugin) |
|---|---|---|
| `just daemon` | `target/<profile>/mapo` | the worktree's `resources/` and `plugin/` |
| `just app`, drives | `.build/xcode/Build/Products/<Config>/Mapo.app` | the bundle |
| Daemon spawned by the app | `Mapo.app/Contents/Helpers/mapo` | the bundle's `Contents/Resources/` |
| `mapo attach` | `Mapo.app/Contents/Helpers/mapo` | |
| `just mapo`, a drive's `mapo` | `target/<profile>/mapo` | |
| `mapo` inside tabs | first on `PATH`: `Contents/Resources/bin/` for a bundled daemon, else the daemon's own directory | |

- The daemon finds resources relative to its executable: `../Resources/` inside a bundle, otherwise the worktree root found by walking up. Edits to shell integration or the plugin reach new tabs after a daemon restart, with no app build.
- The Xcode target installs `target/<profile>/mapo` with a run-script phase: copy to a temp file next to the destination, `codesign` it with the app's identity and `--options runtime`, then `mv -f` it into place. The rename gives a new inode, so a daemon or attach process running the old binary keeps running. Set `ENABLE_USER_SCRIPT_SANDBOXING = NO` on that target and declare the phase's input and output files.
- The Rust binary lives at `Contents/Helpers/mapo`, with `Contents/Resources/bin/mapo -> ../../Helpers/mapo` (ARCHITECTURE §2). It must never go in `Contents/MacOS/`: the default APFS volume is case-insensitive, so `MacOS/mapo` would be the app executable `MacOS/Mapo`. This was checked on this machine on 2026-09-28.

### 3.4 mprocs.yaml

```yaml
# Started by `just dev`, which exports MAPO_DEV_INSTANCE and MAPO_DEV_PROFILE.
# No `server:` key: it makes mprocs listen on TCP (R-ENG-3). Nothing here serves HTTP, so no portless.
procs:
  daemon:
    shell: "just daemon"
    stop: SIGTERM
  app:
    shell: "just app --no-spawn-daemon"
    stop: SIGTERM
  events:
    shell: "just mapo events --follow"
    autostart: false
```

`just dev` is for a person at a terminal. In mprocs, select a pane and press `r` to restart it, `x` to stop it or `s` to start it; `q` quits everything, and the keymap window at the bottom lists the bindings. mprocs ignores unknown config keys silently, so check spelling against its schema.

### 3.5 Daemon lifetime and restarts

- The daemon doesn't depend on the app. Quitting, crashing or rebuilding the app leaves every tab running; the daemon emits `app.disconnected`. A new app registers, takes `state.snapshot`, recreates the visible surfaces, and each `mapo attach` replays (ARCHITECTURE §3.4).
- The daemon exits only on `daemon.shutdown` (`mapo instance stop`, `just kill`), on SIGTERM or SIGINT (mprocs stop, Ctrl-C in `just daemon`), or on a crash. It has no idle exit; `mapo instance list` finds forgotten ones.
- Restarting the daemon ends every tab's processes. Tabs come back from their definitions (R-PER-3): shells restart in their last cwd, running commands are gone, agent tabs resume (R-AG-7).
- A daemon runs the binary it started from until it restarts. Additive protocol changes keep working. A `protocol` bump makes clients fail with `unavailable` until the daemon restarts.

| Goal | Under `just dev` | Without mprocs (agents) |
|---|---|---|
| Rebuild and restart only the app | select `app`, press `r` | `just app` |
| Restart only the daemon, same build | select `daemon`, press `r` | `just mapo instance stop`; the running app spawns a new one from its bundle |
| Run new Rust code in the daemon | select `daemon`, press `r` (it rebuilds) | `just build && just mapo instance stop` |
| Stop this instance | `q` | `just kill` |

### 3.6 Logs

| Source | File in `<data>/logs/` | Live view |
|---|---|---|
| Daemon | `mapod.YYYY-MM-DD.log`, plus stderr under `just daemon` | the `daemon` pane, or `tail -F "$(just mapo instance show --json \| jq -r .logDir)/mapod.$(date +%F).log"` |
| App | `app.YYYY-MM-DD.log`, plus stderr and unified logging (subsystem `dev.mapo.app`) | the `app` pane, or `log stream --level debug --predicate 'subsystem == "dev.mapo.app"'` |
| `mapo attach` | `attach.YYYY-MM-DD.log` only: its stderr is the terminal screen | `tail -F` |
| `mapo hook` | `hook.YYYY-MM-DD.log` only: hooks must print nothing | `tail -F` |
| CLI | stderr only | `MAPO_LOG=debug just mapo …` |

`MAPO_LOG` takes tracing's EnvFilter syntax (default `info`, for example `MAPO_LOG=info,mapo_term=trace`); the app reads the same variable for its level. Logs never contain tokens, prompts or terminal contents (R-NF-4).

## 4. Drivability contract

### 4.1 Every command is reachable through `mapo`

- Every user action that changes state is a daemon command, and the app calls the same command the CLI calls (R-CTL-1). A drive can perform any action as a person (`mapo ui key`, `mapo ui click`) or as an agent (`mapo <verb>`), and both leave the same state.
- View-only actions (Toggle Rail, Toggle Inspector, font size, opening the palette) change no daemon state; reach them with `mapo ui key <chord>` or `mapo ui click <id>`.
- The menu bar, the palette and the shortcuts come from one command table in MapoUI. Each entry names its daemon method, or `view`.

| Action | Key | Method | CLI |
|---|---|---|---|
| New Workspace | ⇧⌘N | `workspace.create` | `mapo workspace new` |
| New Shell Tab | ⌘T | `tab.create` | `mapo tab new` |
| Split Right | ⌘D | `pane.split` | `mapo pane split right` |
| Stop Command | ⌘. | `tab.stop` | `mapo tab stop NAME` |
| Toggle Inspector | ⌥⌘0 | view | `mapo ui key cmd+alt+0` |

### 4.2 Accessibility identifiers

Every interactive element has one of these identifiers (R-NF-5), or one that [UX.md](UX.md) §2.4 adds under the same rules. `mapo ui` targets them.

| Area | Identifiers |
|---|---|
| Window, toolbar | `window.main`, `window.divider:rail`, `window.divider:inspector`, `toolbar.title`, `toolbar.splitRight`, `toolbar.splitDown`, `toolbar.palette`, `toolbar.inspector` |
| Rail | `rail`, `rail.toggle`, `rail.newWorkspace`, `rail.workspace:<workspaceName>`, `rail.workspace.badge:<workspaceName>`, `rail.tab:<workspaceName>/<tabName>` |
| Panes | `pane:<paneId>`, `pane.empty.newShell`, `pane.header:<tabName>`, `pane.terminal:<tabName>`, `pane.file:<absPath>`, `pane.diff:<absPath>`, `pane.stop:<tabName>`, `pane.close:<paneId>` |
| Inspector | `inspector`, `inspector.segment:files`, `inspector.segment:changes`, `inspector.files.header`, `inspector.files.row:<relPath>`, `inspector.changes.summary`, `inspector.changes.row:<relPath>` |
| Palette | `palette`, `palette.field`, `palette.row:<index>` (zero-based, display order) |
| Editor, dialogs | `editor:<absPath>`, `dialog`, `dialog.confirm`, `dialog.cancel` |
| Notifications | `notification:<tabId>`: not an AX element, a line in the app log (below) |

Rules:

1. Only the `AXID` helper in MapoUI builds identifier strings; views never spell them out.
2. Names are the stable names (R-TAB-3), not titles. In `rail.tab:<workspaceName>/<tabName>`, a `/` inside a name is written `%2F` and `%` is written `%25`. `<relPath>` is relative to the inspector's root (the Files folder, or the repository root for Changes).
3. `pane.*` identifiers are unique within the visible layout; rail identifiers are unique within the window. A rename changes the identifier.
4. Each identified element also has a VoiceOver label that speaks its state, for example `be-claude, needs you` (the exact label patterns are in UX.md). A new kind of element extends this table in the same commit.
5. When the app posts or suppresses a notification it logs `notification:<tabId> state=<state> shown=<true|false> reason=<posted|visible|coalesced|unauthorized>` to `app.YYYY-MM-DD.log`.

Roles in `ui.tree` drop the `AX` prefix and lowercase the first letter (`AXButton` becomes `button`). The identifier check, run by `m0-skeleton` and every later drive:

```sh
mapo ui tree | jq '[.. | objects | select(.role? as $r | ["button","checkBox","radioButton",
  "popUpButton","menuButton","textField","textArea","row","link","slider","splitter"] | index($r))
  | select(.id == null)] | length'          # must print 0
```

### 4.3 `mapo ui`

`ui.*` needs no Accessibility permission: the app synthesizes events in its own process (ARCHITECTURE §4.6). A target is a positional identifier, or `--label TEXT`, `--role ROLE --label TEXT`, or `--point X,Y`. Coordinates are window points with a top-left origin; multiply by `scale` to land on `shot-*.png` pixels.

```sh
just mapo ui window                    # {"windowNumber":8123,"frame":{...},"scale":2,"title":"Workspace 1 (dev-mapo-native)"}
just mapo ui snapshot | jq .focus      # the element that has keyboard focus
just mapo ui click rail.newWorkspace
just mapo ui click 'rail.tab:Workspace 1/terminal-1' --right      # context menu
just mapo ui click --role button --label 'New Workspace'
just mapo ui key cmd+shift+n           # through the menu bar, like a person
just mapo ui type 'ls -la' && just mapo ui key return
just mapo ui wait 'pane.terminal:terminal-2' --state focused --timeout-ms 3000
just mapo ui metrics --reset
just mapo ui metrics | jq '.navigation[] | select(.name == "workspace.switch")'
```

- Chords join modifiers `cmd`, `shift`, `alt` (or `opt`), `ctrl` with `+` and end in a key. Keys are single characters (`t`, `[`, `.`, `,`, `=`, `0`) or `return`, `escape`, `tab`, `space`, `delete`, `left`, `right`, `up`, `down`, `home`, `end`, `pageup`, `pagedown`, `f1` to `f12`. Keys name US-layout keys: ⌘+ is `cmd+=`.
- `ui type` sends key events to the first responder. Typing into a focused terminal goes through libghostty, `mapo attach` and the daemon, the same path as a person's keystrokes. `mapo tab send` skips the UI; drives use it only for setup.
- `ui wait` exits 124 on timeout; a missing app is `unavailable` (exit 1).
- `ui metrics` (basic in M0, full in M5) has `launch.processStartToFirstFrameMs`, `navigation: [{name, ms}]`, `frames: {p50Ms, p95Ms, dropped}` and `attach.lastMs`. Navigation names: `app.reattach`, `workspace.switch`, `tab.focus`, `tab.create`, `pane.split`, `palette.open`, `file.open`. Each runs from the input event's timestamp to the first frame presented with the new state.
- `ui window` also reports `occluded`: true when macOS says no part of the window is visible (display asleep or locked, minimized, another Space).

### 4.4 Semantic snapshots

`mapo ui snapshot` returns what a person could see, as data:

| Field | Contents |
|---|---|
| `window` | `ui window`'s result |
| `focus` | the first responder: `{id, role, label}` |
| `tree` | the element tree (PROTOCOL §7): id, role, label, value (the raw state such as `needs-you`, or field text; UX §2.4), frame, focused, enabled, children |
| `model.workspaceId`, `model.layout` | the active workspace and the Layout the app renders |
| `model.rail` | rows in display order, shaped as UX §3.8 specifies: `{kind:"workspace", name, state, accessory, …}` and `{kind:"tab", name, display, icon, state, accessory, selected, …}` |
| `terminals` | one entry per visible terminal pane: `{tabId, paneId, text}`, where `text` follows `tab read` rules (visible rows, populated rows below the cursor, no trailing blanks) |

A snapshot has no colors, fonts, materials or pixels. Frames still show geometry: rail rows are 24 pt (tabs) and 26 pt (workspaces), panes tile without gaps or overlaps, and nothing lies outside the window.

### 4.5 Pixels

Screenshots come from outside the app: `screencapture -x -o -l <windowNumber> shot.png`, with `windowNumber` from `mapo ui window`. They need Screen Recording permission for the app that hosts the agent's shell. Its bundle id is `$__CFBundleIdentifier` in that shell (`com.cmuxterm.app` for cmux). The user does the pre-flight (HANDOFF §4):

1. System Settings › Privacy & Security › Screen & System Audio Recording: enable the host app, then quit and reopen it.
2. Keep the display awake and unlocked (`caffeinate -dimsu`). A locked display gives blank shots.
3. `just app`, then `just snap preflight`, and open the PNG. It must show Mapo's window content, not the desktop.

### 4.6 When pixels are unavailable

Pixels are unavailable when `screencapture` fails, the PNG is empty, or `ui window` reports `occluded`. The agent then:

1. Keeps driving. Drives record `pixels: unavailable` in `summary.md` and skip `ui_shot`.
2. Checks everything the snapshot can prove: identifiers, labels, state words, focus, frames and geometry, terminal text, timings.
3. Lists every visual claim it could not check (colors, Liquid Glass, focus ring, alignment by eye) under "Not verified" in the review, and never says the UI looks right.
4. Adds the pre-flight to PROGRESS.md under "Needs the user".

In-app capture is not a substitute. Metal terminal layers and glass materials don't render through `cacheDisplay`, so it would show the wrong picture.

## 5. Drives

A drive is a scripted person. It uses the app through the keyboard and mouse paths (`mapo ui`), uses the CLI for setup and verification, and records what a person would see at each step. Its hard checks are few and decide pass or fail. Its evidence is for an agent to judge the UX, which is the part automated tests can't do.

### 5.1 Format

`drives/<name>.sh` is a zsh script that starts with `set -euo pipefail` and `source "${0:A:h}/lib.sh"`. Names are the planned `m0-skeleton` … `m5-switch` (see [drives/README.md](../drives/README.md)) or new ones of at most 19 characters, so `drive-<name>-<HHMMSS>` fits in 32. In zsh, never keep a command in a variable and run `$CMD args` (no word splitting); `mapo` is a function.

### 5.2 Helpers in `drives/lib.sh`

| Helper | Behavior |
|---|---|
| `drive_begin NAME` | Takes the machine-wide lock `~/Library/Caches/mapo/drive.lock/` (a directory holding the owner's pid; a dead owner's lock is removed; waits up to 10 min). Sets `DRIVE_INSTANCE=drive-NAME-HHMMSS`, `EVIDENCE`, `DRIVE_TMP` (a fresh dir under `$TMPDIR`). Tees all output to `$EVIDENCE/log.txt`. Copies `$DRIVE_CONFIG` to the instance's `config.toml` if set. Starts the daemon (`mapo daemon`, detached) and the app (`Mapo --instance … --no-spawn-daemon`), records both pids, waits for `window.main`, focuses it, records `daemon-ready` and `app-ready` timings, the load average and the commit, then takes `ui_snapshot launch` and `ui_shot launch`, which decides `PIXELS`. Installs `trap drive_end EXIT INT TERM`. Refuses to reuse an existing instance. |
| `step "text"` | Increments `DRIVE_STEP` (`01`, `02`, …) and logs `== [NN] text` with the elapsed time. |
| `mapo ARGS…` | Runs `target/<profile>/mapo --instance $DRIVE_INSTANCE --json ARGS` with `MAPO_TOKEN`, `MAPO_HOOK_TOKEN` and `MAPO_ATTACH_TOKEN` unset. Logs the call, exit code and ms to `log.txt`. Shadows any `mapo` on `PATH`. |
| `ui_snapshot STEP` | Writes `snapshot-NN-STEP.json` from `mapo ui snapshot` and sets `SNAP` to its path. STEP is `[a-z0-9-]+`. |
| `ui_shot STEP` | With `PIXELS=available` and the window not occluded, writes `shot-NN-STEP.png` with `screencapture -x -o -l` and sets `SHOT`. Otherwise logs `pixels: unavailable` and returns 0. Never fails a drive. |
| `expect_json FILTER EXPECTED` | Reads JSON on stdin, runs `jq -c FILTER`, and compares it with EXPECTED parsed as JSON (`1`, `true`, `'"idle"'`, `'["shell"]'`). Pass logs `PASS`. Fail logs `FAIL` with the filter, expected and actual values (truncated to 2 KB), counts the failure, takes `ui_snapshot fail` and `ui_shot fail`, and returns 1. |
| `timing NAME CMD…` | Runs CMD (a command or a function), appends `{step, name, ms, budgetMs}` to the timings, and returns CMD's exit status. `budgetMs` comes from `BUDGET_MS[NAME]` in lib.sh. |
| `drive_end` | Idempotent. Takes `ui_snapshot end` and `ui_shot end` and saves `mapo ui metrics` and `mapo debug stats`. Stops the app pid it started (SIGTERM, 5 s, SIGKILL), then the daemon (`mapo instance stop`), and verifies no process with `--instance $DRIVE_INSTANCE` is left. Appends the last 200 lines of the daemon and app logs to `log.txt`, writes `timings.json` and `summary.md`, deletes the instance data and `DRIVE_TMP` on pass (keeps them on failure or with `DRIVE_KEEP=1`), keeps the 20 newest runs of this drive, releases the lock, prints the evidence path as its last line, and exits 0 only if every check passed and no command failed. |

Knobs: `DRIVE_CONFIG=drives/fixtures/<file>.toml` (start with that config), `DRIVE_NO_APP=1` (start only the daemon and skip the window wait and launch snapshot; for drives written before the app is drivable, T0.2 to T0.9), `DRIVE_KEEP=1` (leave the instance running; stop it later with `just instance=<instance> kill`), `DRIVE_ENFORCE_BUDGETS=1` (over-budget fails the drive; used on Release builds), `DRIVE_NOLOCK=1` (skip the machine lock for a snapshot-only run; the summary marks focus visuals and timings unreliable). `lib.sh` also works when a drive runs as `zsh drives/<name>.sh`: it derives `MAPO_ROOT` from its own path and defaults to `debug`.

Drives serialize on the lock because they activate their window: key-window state, the focus ring and timings are only trustworthy with one drive on screen. Builds still run in parallel. A drive steals focus, so run drives when nobody is typing on the machine.

### 5.3 Lifecycle

1. **Begin.** `drive_begin` creates the throwaway instance and starts its daemon and app from this worktree's build.
2. **Steps.** Each `step` acts through the UI, waits for the outcome (`mapo ui wait`, `mapo tab wait`, never `sleep`), checks it with `expect_json`, and leaves at least a snapshot. Visual steps also take a shot.
3. **Evidence.** Snapshots, shots, timings and the transcript accumulate in `$EVIDENCE`.
4. **Teardown.** `drive_end` stops only the two pids it started and verifies the instance is gone. It never uses `pkill` or `killall`, and it never touches the worktree's own instance, other drives or the frozen app.

### 5.4 Evidence

```
evidence/m1-daily/20260929-021530/
  summary.md                 result, header, steps, failures, budgets, review
  timings.json               {drive, instance, profile, commit, pixels, loadavg1, timings:[…], metrics:{…}, stats:{…}}
  snapshot-01-launch.json    one per ui_snapshot, numbered by step
  shot-01-launch.png         one per ui_shot, only when pixels are available
  snapshot-07-fail.json      taken automatically by a failing expect_json
  log.txt                    transcript: steps, every mapo call with exit code and ms, PASS/FAIL, log tails
```

`drive_end` writes `summary.md` from this template. The agent fills in the Review section.

```markdown
# m1-daily: PASS

- Checks: 41 passed, 0 failed
- Started: 2026-09-29 02:15:30 -03, took 96.4 s
- Commit: 1a2b3c4 (clean), build: debug, instance: drive-m1-daily-021530
- Pixels: available. Load average (1 min): 2.10

## Steps
| # | Step | Checks | Evidence | ms |
|---|---|---|---|---|
| 01 | Launch | 2/2 | snapshot-01-launch.json, shot-01-launch.png | 312 |

## Failures
None.

## Timings and budgets
| Name | Source | ms | Budget | Verdict |
|---|---|---|---|---|
| launch | ui.metrics | 288 | 400 | ok (debug build) |

## Review
- Looked at: shot-01 … shot-14, in order
- Feels right:
- Feels wrong: (file, what, fix or task)
- Not verified:
- Verdict: accept | fix first
```

Copy the few screenshots that tell the story into `docs/progress/<task>-<step>.png` and link them from PROGRESS.md. `evidence/` itself is never committed.

### 5.5 Reviewing evidence: feeling the UX

A drive passes on its checks. A task passes only after this review.

1. **Read `summary.md`.** On FAIL, start from the failure's snapshot and shot.
2. **Look at the shots in order.** Open each PNG and say what a person sees and what changed since the previous one. Look for blank or half-drawn panes, the focus ring on the wrong pane, clipped or overlapping text, rows that jumped, state words other than Needs you and Failed in the rail, colors off the Mapo Glass palette, glass where a pane should be opaque.
3. **Compare timings with budgets.** Over budget is a defect. Above 80 % of budget is a warning. Compare with the previous run of the same drive (`ls evidence/<drive>/`); more than 20 % or 10 ms slower is a finding. Under 50 ms feels instant, around 100 ms is noticeable, over 250 ms feels slow.
4. **Check focus.** Every snapshot has `.focus`. After each action, focus sits where a person expects: the new terminal after ⌘T, the editor after opening a file, the field in the palette. Background events never move focus or scroll: snapshot before and after one (for example a hidden tab going `failed`) and compare `.focus` and the rail rows' frames.
5. **Check for flicker.** `frames.dropped` must not grow during a navigation. Snapshots taken right after an action must never show an empty pane, a missing rail row or a "Disconnected" overlay. Sub-frame flicker is invisible to drives; it goes on the user checklist (T5.3).
6. **Check copy.** List every visible string with `jq -r '.. | objects | (.label?, .value?) | strings' "$SNAP" | sort -u`. State words come from R-ST-1. Commands and buttons use title case, and prompts end in "…" ("New Tab in Folder…"). No ids, UUIDs, `nil`, `null` or `Optional(`. Every error names the problem and the next step (R-NF-3).
7. **Write the review** in `summary.md`. Fix each "feels wrong" now if it is in scope; otherwise record it in PROGRESS.md.

### 5.6 Worked example

```zsh
#!/usr/bin/env zsh
# Create a workspace and a shell tab with the keyboard, type a command like a person,
# then check the result with the CLI and a snapshot.
set -euo pipefail
source "${0:A:h}/lib.sh"

drive_begin example-new-tab

step "New workspace with ⇧⌘N"
ws="Workspace $(( $(mapo workspace list | jq length) + 1 ))"
new_workspace() { mapo ui key cmd+shift+n >/dev/null; mapo ui wait "rail.workspace:$ws" --timeout-ms 2000 >/dev/null; }
timing new-workspace new_workspace
mapo workspace list | jq --arg ws "$ws" '[.[] | select(.name == $ws)] | length' | expect_json . 1
ui_snapshot new-workspace; ui_shot new-workspace

step "New shell tab with ⌘T takes focus"
tab="terminal-$(( $(mapo tab list --workspace "$ws" | jq length) + 1 ))"
new_tab() { mapo ui key cmd+t >/dev/null; mapo ui wait "pane.terminal:$tab" --state focused --timeout-ms 3000 >/dev/null; }
timing new-tab new_tab
mapo tab list --workspace "$ws" | jq -c --arg t "$tab" '[.[] | select(.name == $t) | .kind]' | expect_json . '["shell"]'

step "Type a command like a person"
mapo tab wait "$tab" --workspace "$ws" --until drive-42 --timeout-ms 5000 >/dev/null &
waiter=$!                                   # pattern waits see only output after they start
mapo ui type 'echo drive-$((6*7))'          # the tab's shell prints drive-42; the echoed line doesn't match
mapo ui key return
wait $waiter

step "The snapshot agrees with the CLI"
ui_snapshot typed; ui_shot typed
expect_json '.focus.id' "\"pane.terminal:$tab\"" < "$SNAP"
jq --arg t "$tab" '[.model.rail[] | select(.name == $t)] | length' "$SNAP" | expect_json . 1
expect_json '[.terminals[].text | test("(?m)^drive-42$")] | any' true < "$SNAP"

drive_end
```

## 6. Performance budgets (R-NF-1)

| Budget | Measured by | Fixture and method |
|---|---|---|
| Cold launch to first interactive frame, daemon running: ≤ 400 ms | `ui metrics` `launch.processStartToFirstFrameMs` | Daemon up, a workspace with 4 visible tabs. Relaunch with `just app` 5 times; take the median. |
| Reattach and paint a workspace with 10 tabs: ≤ 150 ms | navigation `app.reattach` | 10 tabs visible in a 5×2 grid, each after `seq 1 2000`. From the `hello` reply to the first frame where all 10 surfaces show their replay. |
| Switch workspace: ≤ 50 ms | navigation `workspace.switch`, p95 of 20 | Two workspaces with 5 visible panes each; alternate `mapo ui key ctrl+cmd+down` and `up`. |
| Keystroke to glyph: ≤ +2 ms over Ghostty | `mapo debug latency --tab NAME`; Typometer A/B | Proxy: 200 single bytes through an attach connection to a tab running `cat`, against the same probe on a raw PTY; the p95 difference is the number. End to end: Typometer against Ghostty.app with the same font and theme, with the user present (T5.3). |
| Idle CPU, 20 tabs: app ≈ 0 % (under 0.3 %), daemon < 0.5 % | `mapo debug stats --interval-ms 60000`; cross-check `top -l 2 -s 60 -stats pid,cpu -pid <pid>` | 20 shells at their prompts, 10 visible, 30 s settle; once with the app in front and once hidden. |
| Memory, 20 tabs, 10 visible: daemon ≤ 150 MB, app ≤ 250 MB | `mapo debug stats` (physical footprint); `footprint --pid <pid>`; `vmmap --summary <pid>` for the breakdown | The same fixture, each tab having printed 10,000 lines. The daemon emulator keeps 2,000 lines; libghostty keeps the rest. |

- `mapo debug` verbs are client-side diagnostics that need no new daemon method. `stats` reads the daemon and app pids from the pid files, calls `proc_pid_rusage` for CPU time and physical footprint, and takes tab counts from `state.snapshot`; `--interval-ms N` samples twice and reports CPU %. `latency` opens its own attach connection as a second client.
- `/usr/bin/time -l` covers one-shot commands: `/usr/bin/time -l target/release/mapo --instance <i> tab list >/dev/null` gives wall time, maximum RSS and peak footprint. Tracked without a budget: a release `mapo` call takes under 20 ms, and `mapo hook` always exits within 2 s.
- **When.** Every drive records launch and each navigation it performs; on Debug builds these are trends only. The full pass (T5.1, `m5-switch`) runs on a Release build (`just profile=release …`) on AC power with the machine quiet. Drives record the 1-minute load average and mark verdicts `noisy` above 6. Re-measure after changes to attach or replay, terminal surfaces, the rail, the split container, event fan-out or SQLite writes. To compare an optimization, run the same drive 3 times in the baseline worktree and 3 times in the candidate and compare medians.
- **On a regression.** Re-run 3 times and compare medians with the last good evidence. Find the commit with `git bisect run` over `DRIVE_ENFORCE_BUDGETS=1 just profile=release drive <name>`. Profile with `sample <pid> 5 -file .build/traces/<name>.txt` (a text call tree an agent can read) or `xcrun xctrace record --template 'Time Profiler' --attach <pid> --time-limit 15s --output .build/traces/<name>.trace`, and with `footprint` and `vmmap` for memory. Fix it, or record why it can't be met under "Needs the user" in PROGRESS.md. Never loosen a budget quietly.

## 7. Parallel builds and caches

| Output | Where | Shared |
|---|---|---|
| Cargo target | `<worktree>/target/` | no |
| Xcode derived data, with `SourcePackages/` and `ModuleCache.noindex/` | `<worktree>/.build/xcode/` | no |
| SwiftPM test builds | `<worktree>/.build/swiftpm/` | no |
| Generated Swift and Xcode project | `app/Packages/MapoKit/Sources/MapoProtocol/Generated/`, `app/Mapo.xcodeproj` | no |
| GhosttyKit | `~/Library/Caches/mapo/ghostty/<version>/`, linked as `.build/ghostty/GhosttyKit.xcframework` | yes, read-only once verified |
| Cargo registry, SwiftPM downloads | `~/.cargo/registry`, `~/Library/Caches/org.swift.swiftpm/` | yes; the tools lock them |

- Never set `CARGO_TARGET_DIR` or give two worktrees one derived data path. Cargo locks its target dir, so a shared one builds one worktree at a time, and two xcodebuilds on one derived data path fail with "database is locked". Per-worktree outputs also give drives a fixed app path.
- Xcode.app may open `app/Mapo.xcodeproj` for reading and debugging. Its own builds go to `~/Library/Developer/Xcode/DerivedData`; `just` and drives never use them.
- `.cargo/config.toml` pins `MACOSX_DEPLOYMENT_TARGET = { value = "26.0", force = true }` under `[env]`. Without it, terminal and Xcode builds invalidate each other ([research/interop-build.md](research/interop-build.md) §3.1). Xcode never runs cargo; `just build` does, and Xcode copies the result.
- `just gen` is idempotent (§3.2), and several worktrees can run it at once because all its outputs live in the worktree.
- sccache is optional. It caches dependency crates across worktrees, not the incremental workspace crates, which shortens a fresh worktree's first build. To use it, `brew install sccache` and `export RUSTC_WRAPPER=sccache` in the shell that builds. Never set it in `.cargo/config.toml`.

Job counts for this machine (12 cores: 8 performance and 4 efficiency; 32 GB). `jobs` feeds `cargo -j` and `xcodebuild -jobs`; each Swift compile job can take about 1 GB.

| Builds running at once | `MAPO_JOBS` |
|---|---|
| 1 or 2 | default (12) |
| 3 or 4 | 4 |
| 5 or 6 (HANDOFF allows five workers plus the coordinator) | 3 |

Merge hotspots are `crates/mapo-protocol/`, `Cargo.lock`, `app/project.yml`, the `justfile` and `docs/PROGRESS.md` (owned by the coordinator, HANDOFF §7). Land protocol changes on `native` first as small additive commits, then rebase the topic branches. For a `Cargo.lock` conflict, take `native`'s version and run `cargo build`.

## 8. Testing policy

Drives are the acceptance (§5). Unit tests exist only for pure logic: input in, output out, with no window, PTY, socket, clock or network.

| Pure logic | Where | Test shape |
|---|---|---|
| Status function: raw facts to `state` and `stateLabel` (R-ST-1, R-AG-3) | `mapo-core::status` | one table of cases |
| Protocol codec: JSON-RPC messages, error kinds, attach frames | `mapo-protocol` | round trips, frames split across reads |
| OSC pre-parser: OSC 7, 133, 0, 2, 9, 777 in chunks cut at any byte | `mapo-term` | byte streams to facts |
| Ring buffer cut | `mapo-term` | never splits an escape sequence or a UTF-8 character |
| Process identity hashing (pid, start time, executable) | `mapo-proc` | stable, and changes when any input changes |
| Selectors, "first free Workspace N", instance names and paths | `mapo-core`, `mapo-instance` | tables |
| `tab read` row trimming, `tab wait` matching after the last send | `mapo-term` on an emulator fed bytes | byte fixtures |
| Chord parsing, palette fuzzy matching, split-tree geometry | MapoKit | tables |

- No UI unit tests: no XCUITest, no image snapshots, no test that opens a window. A drive step checks UI behavior.
- Protocol fixtures: `crates/mapo-protocol/fixtures/*.json` holds one canonical example per wire type and event. A Rust test compares serialized sample values with the files (`UPDATE_FIXTURES=1 cargo test -p mapo-protocol` rewrites them). A Swift test in `MapoProtocolTests` decodes each file and encodes it back. The fixture diff is the review artifact for a protocol change.
- One table-driven test per function. Prefer one structural equality over many field assertions.
- `just test` stays under 60 s, uses temp dirs, and never touches real instances or the runtime dir.
- A fixed bug gets a drive step that reproduces it, or a unit test when the bug was in pure logic.

## 9. Code conventions

Rust:

- Edition 2024 for every crate; `rust-toolchain.toml` pins 1.96 with rustfmt and clippy. `just lint` runs clippy with `-D warnings`.
- Library crates define errors as `thiserror` enums. Each maps to a PROTOCOL §4 kind, with a message that names the problem and a `hint` with the next step. Only the `mapo` binary uses `anyhow` with `.context()`.
- No `unwrap`, `expect` or `panic!` on daemon paths: set `clippy::unwrap_used`, `expect_used` and `panic` to `deny` in `[workspace.lints]`, with `allow-unwrap-in-tests` and `allow-expect-in-tests` in `clippy.toml`. A panic in a tab task marks that tab `failed`; it never takes down the daemon.
- `unsafe_code = "deny"` at the workspace, allowed per module only for libc and libproc calls, each with a `// SAFETY:` comment.
- Log with `tracing`, one span per request (`id`, `method`, `caller`), structured fields, and the EnvFilter from `MAPO_LOG`. Never log tokens, prompts or terminal contents.
- Nothing blocks the tokio runtime: SQLite has its own thread and other blocking work goes through `spawn_blocking`. No lock is held across `.await`, and the core actor owns state with no `Arc<Mutex<…>>`.
- A new dependency needs a justification line in ARCHITECTURE §3.1. rmcp is pinned to an exact version.

Swift:

- Swift 6 language mode with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` for the app and MapoKit modules. Generated MapoProtocol stays in Swift 5 mode. MapoClient does socket I/O off the main actor and hands decoded messages to the MainActor store; the main thread never waits on the socket.
- AppKit first: windows, splits, outline views, the editor, menus and focus. SwiftUI only in the palette, settings, popovers and hover cards, hosted in AppKit. Views are built in code; no storyboards or nibs.
- `xcrun swift-format` with the repo's `.swift-format` (4-space indent, 120 columns) and the rules `NeverForceUnwrap`, `NeverUseForceTry` and `NeverUseImplicitlyUnwrappedOptionals` on. No `!`, `try!` or `as!` in UI paths; a failure shows a visible state instead.
- Every interactive view sets an identifier through `AXID` and a spoken label (§4.2).

Commits and docs:

- `type(scope): summary`, imperative, at most 72 characters. Types: `feat`, `fix`, `perf`, `refactor`, `test`, `docs`, `build`, `chore`. Scopes: `protocol`, `instance`, `core`, `term`, `agent`, `proc`, `git`, `mcp`, `cli`, `app`, `ui`, `terminal`, `editor`, `automation`, `drives`, `build`, `docs`. The body says why, then `Task: T0.5` and `Drive: m0-skeleton PASS evidence/m0-skeleton/<ts>`.
- Small verified slices: every commit builds, passes `just lint` and `just test`, and its drive passed. Never push.
- A change to a documented contract (protocol, identifiers, recipes, paths, keyboard map) updates the doc in the same commit.
- No license or copyright headers. The frozen repository's conventions (tabs, Microsoft headers, `nls`) don't apply here.

## 10. Signing and permissions

- **Dev signing.** Ad-hoc "Sign to Run Locally": `CODE_SIGN_IDENTITY = "-"`, no team. `just build` uses `$MAPO_SIGN_IDENTITY` when set, else a keychain identity named `Mapo Dev Local` when `security find-identity -v -p codesigning` lists it, else ad-hoc.
- **Optional stable identity (the user's step).** TCC ties grants for ad-hoc apps to the code hash, which changes on every build, so camera or microphone grants for programs in tabs reset after each rebuild. A stable local certificate keeps them. In Keychain Access › Certificate Assistant › Create a Certificate…, name it `Mapo Dev Local`, choose Self Signed Root and Code Signing, then set its Code Signing trust to Always Trust. Agents never create certificates or edit keychains.
- **Hardened runtime** is on in every configuration, so dev behaves like the installed app. MapoKit and GhosttyKit link statically; there are no embedded dylibs for library validation to reject. Debug builds get `get-task-allow` from Xcode for the debugger.
- **Entitlements** (`app/Mapo/Mapo.entitlements`, R-NF-4): `com.apple.security.device.camera`, `com.apple.security.device.audio-input`, `com.apple.security.personal-information.addressbook`, `…calendars`, `…location`, `…photos-library`, `com.apple.security.automation.apple-events`. No `app-sandbox`, `cs.allow-jit`, `cs.allow-unsigned-executable-memory` or `cs.disable-library-validation`. Info.plist has a usage string for each: `NSCameraUsageDescription`, `NSMicrophoneUsageDescription`, `NSContactsUsageDescription`, `NSCalendarsFullAccessUsageDescription`, `NSLocationUsageDescription`, `NSPhotoLibraryUsageDescription`, `NSAppleEventsUsageDescription`, each worded "A program running in Mapo wants to use …".
- **Who gets the prompt.** macOS attributes a tab program's permission request to the process responsible for the daemon. For a daemon spawned by the app that is Mapo Dev. For `just daemon` it is the terminal running it, so grants given there don't carry over.
- **Mapo Dev itself needs no TCC grant to be driven.** `ui.*` works in-process, and pixels come from the host terminal's `screencapture`. An Accessibility or Input Monitoring prompt during a drive is a bug.
- **Notifications in dev.** Authorization belongs to the bundle id `dev.mapo.app.dev`, shared by every dev instance. The app requests it lazily on the first attention event; the system prompt is for the user. Drives never depend on a banner appearing. They check the `notification:<tabId>` log line (§4.2), which is written whether the banner was shown, suppressed or unauthorized. Focus modes hide banners but not the log line.
- **No login items in dev.** Code that calls SMAppService runs only when the bundle id is `dev.mapo.app`, the instance is `main` and the executable is outside a git worktree (T5.2). Dev work never writes `~/Library/LaunchAgents` and never runs `launchctl`.

## 11. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `no daemon for instance <i>` while `<i>.sock` exists | Stale socket after a crash | Delete nothing. The next daemon removes it after taking the lock: `just daemon`, or `just app`. |
| `instance <i> is already served by pid N` | The app spawned a daemon earlier, or another worktree's folder name maps to the same instance | `just kill`, then retry. If `mapo instance show` names an exe in another worktree, rename a folder or use `instance=`. |
| `unavailable` with `daemonProtocol`, or the banner "mapod is from another build" | The daemon runs an older or newer build | `just build && just kill && just app`. `just mapo instance show` names the daemon's exe. |
| `just ghostty` fails: 404, timeout or checksum mismatch | Network, a moved release, or a bad download | Retry. Check the URL with `curl -fsSIL`. On a mismatch delete `~/Library/Caches/mapo/ghostty/<version>/` and retry once. Never edit `SHA256` to match a download. Otherwise pin another release (record it in DECISIONS.md), build from source with Zig 0.16, or after the 2 h timebox use the SwiftTerm fallback (PLAN T0.8). |
| A terminal shows `reconnecting…` or the "Disconnected" scrim (UX §4.3) | The daemon is down, restarted with a new token, or belongs to another instance | `just mapo instance show`, then `attach.<date>.log`. The tab is fine if `just mapo tab list` shows it. `mapo attach` must re-read `app.token` after a new `bootId`. Click Reconnect (`pane.reconnect:<tabName>`) or run `just app`. |
| `pixels: unavailable` | No Screen Recording for the host terminal, a locked or sleeping display, or an occluded window | §4.5 pre-flight, `caffeinate -dimsu`, then `just snap preflight`. |
| `app.banner` stays on "Reconnecting to mapod…" or "Can't reach mapod" | Started with `--no-spawn-daemon` and no daemon; instance mismatch; missing `Contents/Helpers/mapo`; daemon failed at start | Compare the window title with `just mapo instance show`. Check the bundle. Read the start error in `mapod.<date>.log`. |
| `mapo ui …` returns `unavailable` | No app registered for that instance | `just mapo instance show` (app pid), then `just app`. |
| Something reports a port collision | Not Mapo: nothing in Mapo listens on TCP | Find the owner with `lsof -nP -iTCP -sTCP:LISTEN`. A TCP listener owned by a Mapo pid is a bug (P2). |
| `mapo` behaves like another version | A different `mapo` is first on `PATH` | Use `just mapo` or `target/<profile>/mapo`. `type -a mapo` lists candidates. |
| xcodebuild says "database is locked"; or Rust rebuilds every time with "built for newer macOS" warnings | Two builds share one derived data path; or deployment target drift | Never share `.build/xcode`; wait for the other build. Check `.cargo/config.toml` `[env]` (§7). |
| Swift decoding fails (`keyNotFound`) after a protocol change | Stale generated types or a stale bundled `mapo` | `just gen && just build`, then restart the daemon. |
| A window position or preference moves between instances; clicking a notification opens another instance | Dev instances share one bundle id | Expected in dev (§2.6, §10). Keep state out of UserDefaults; drives read notification log lines. |
| `drive_begin` waits on `drive.lock` | Another drive is running | Wait. A dead owner's lock is removed automatically. `DRIVE_NOLOCK=1` for snapshot-only runs. |
