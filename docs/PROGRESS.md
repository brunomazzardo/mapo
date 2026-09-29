# Progress

Newest entries first. Every session adds an entry. Every overnight run ends with a **morning report**; its template is in [PLAN.md](PLAN.md). Keep the entries short, link evidence, and move anything that needs the user into "Needs the user".

## Needs the user

- **Merging helper branches into `native` is blocked (decide how integration should work).** At 00:05 on 2026-09-29, the coordinator's auto-mode classifier refused to cherry-pick mapo-30's T0.3 commits (`native-daemon`: e8381971bde, 217a57820d7) onto `native` and run their drive, as "Untrusted Code Integration". Nobody retried it or worked around it, and no other session was asked to merge. Earlier, 29d43a8 (mapo-2b's SwiftTerm surface, from `native-surface` 7f190378bee) had already been cherry-picked, built and unit-tested on `native` before the refusal. It is kept; revert it with `git revert 29d43a8` if you prefer. The helpers keep committing on their own branches (`native-daemon`, `native-termcore`, `native-app`, `native-surface`) without cross-merging. To continue, review and merge them yourself (`git merge --ff-only` or `git cherry-pick` in ~/code/mapo-native), or allow the coordinator to integrate helper commits.
- **Allow acquiring GhosttyKit** (the prebuilt libghostty-spm pin from PLAN T0.8, or a Zig 0.16 source build) so T0.8 can move from SwiftTerm to Ghostty (D-13; goal: terminal quality). On 2026-09-28 at 23:40 the coordinator's auto-mode permission classifier refused the prebuilt download as "Untrusted Code Integration". Tonight's run uses the SwiftTerm fallback behind `TerminalSurface`, and nobody retried the download or worked around the refusal.
- **Install the Metal Toolchain?** (`xcodebuild -downloadComponent MetalToolchain`, an Apple component outside Homebrew and cargo, so HANDOFF §6.4 leaves it to you). SwiftTerm 1.12 and later compile a Metal shader and fail without it, so the fallback is pinned to SwiftTerm 1.11.2 (CoreGraphics renderer). Moving to 1.20.0 is a one-line change once it's installed.
- Session `mapo-native` never processed its kickoff: the cross-session message stayed queued and the session stayed "waiting", probably blocked on something in its UI. The overnight run was moved to `mapo-bf` as coordinator (HANDOFF §7). Check what `mapo-native` was waiting on.

- **Screen Recording pre-flight (HANDOFF §4).** On 2026-09-28 at 23:49, `screencapture -x` from the agent's host app (cmux, `com.cmuxterm.app`) exited 0 but produced an all-black image: either Screen Recording isn't granted to cmux, or the display was asleep or locked. Tonight's drives run on semantic snapshots and record `pixels: unavailable`; visual claims are listed under "Not verified". To fix it: System Settings › Privacy & Security › Screen & System Audio Recording › enable cmux, reopen it, and keep the display awake (`caffeinate -dimsu`).

## Deviations

| Task | Spec | Said | Did | Why |
|---|---|---|---|---|
| T0.8 | PLAN T0.8 fallback | SwiftTerm "from 1.20.0" | SwiftTerm exactly 1.11.2 | 1.12+ needs the Metal Toolchain, which isn't installed (see Needs the user) |
| T0.8 | D-13, PLAN T0.8a | GhosttyKit prebuilt | SwiftTerm fallback, `engine = "swiftterm"` default | GhosttyKit acquisition refused by the permission classifier (see Needs the user) |

## 2026-09-28/29 overnight run (coordinator mapo-bf)

- **T0.2 done.** `crates/mapo-instance` (names, resolution from the executable's worktree, paths, 0700 dirs, pid files, `Secret` tokens, process identity through `proc_pidpath` and `KERN_PROCARGS2`); `mapo instance show|list|wait|stop|clean`; `just mapo`, `just kill` and `just clean-instance`; `drives/lib.sh` stage 1 with the `DRIVE_NO_APP=1` knob (added to ENGINEERING §5.2). Evidence by hand, as PLAN allows for T0.2: every acceptance line holds. The worktree default is `dev-mapo-native`, `MAPO_INSTANCE` gives `source: env`, `Bad_Name` exits 2 and quotes the regex, the executable decides the name even from `/tmp`, `--instance main instance clean` exits 1, the runtime dir is mode 700, the socket path is 74 bytes (limit 91), `just instance=main kill` exits 1, and 8 unit tests pass. `instance wait` checks for a connectable socket until T0.3 adds `ping`, and `instance stop` uses SIGTERM, then SIGKILL, until T0.3 adds `daemon.shutdown`.
- **T0.1 done.** Cargo workspace, crate stubs, MapoKit (6 modules plus tests), XcodeGen app, justfile, mprocs.yaml, embed script. `just setup` exits 0 and reports zig and sccache as optional; `just build` exits 0; `Contents/Helpers/mapo --version` prints `mapo 0.1.0`; codesign shows `Identifier=dev.mapo.app.dev` with `flags=0x10002(adhoc,runtime)`; a no-op `just build` takes 1.5 s; `git status` is clean of generated files. Xcode drops the hardened-runtime flag for ad-hoc signing, so `project.yml` passes `OTHER_CODE_SIGN_FLAGS = --options runtime`.
- **Parallel tracks** (HANDOFF §7): mapo-30 has the daemon (T0.3 to T0.6, `native-daemon`); mapo-02 has termcore, the pure T0.5/T0.6 pieces and the zsh integration (`native-termcore`); mapo-07 has the app (T0.7, T0.9, `native-app`); mapo-2b has the terminal surface on SwiftTerm (T0.8, `native-surface`). The coordinator does T0.1, T0.2, the merges, T0.10 and T0.11.

## 2026-09-28: specs written, no code yet

- The interview produced [DECISIONS.md](DECISIONS.md). The design exploration is on the Claude Design canvas <https://claude.ai/artifact/DXzWX7bnxWX3i2zJCy1A8J>; the chosen boards are "A · Source list" and "S2 · Slimmer".
- Research is saved in [research/](research/).
- The orphan branch `native` was created as worktree `~/code/mapo-native`. The docs set was written and committed.
- Next: [PLAN.md](PLAN.md) T0.1.
