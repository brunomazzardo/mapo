# Mapo feature research

Compiled 2026-09-25 from the last 60 days of the user's own work, with their permission:

| Source | Volume |
|---|---|
| Personal Claude Code transcripts | 10 projects, about 100 MB |
| Work Claude Code transcripts, Mesh/Obsess | 165 sessions, about 415 MB, about 2,100 user turns |
| Work Claude Code transcripts, other projects | 12 sessions across 6 projects |
| Shell history (zsh, atuin) and Claude prompt history | 1,544 shell commands, 4,064 prompts |

Raw reports were kept out of the repo because they describe employer work. Everything below is paraphrased and generic.

## What the evidence says about how the user works

- **Several Claude sessions run at once, all day.** In 304 separate minutes, two or more sessions were taking prompts at the same time. There were 396 distinct sessions in 60 days.
- **One task spans a backend and a frontend repo.** Sessions `cd` between them hundreds of times. About 600 hand-typed path variables (`R=`, `B=`, `W=`) exist only to jump between repos and worktrees.
- **Two Claude identities.** `claude` (personal) and `claude-work` (separate config dir). `claude-work` gets about three times the use.
- **Dev servers are managed by hand or by home-made tools.** A custom `dev:ctl` / `dev:status` / `dev:logs` layer over mprocs was called 147 times. Health endpoints get polled in loops. Expo and iOS simulator commands fail the most.
- **Git ritual around environments.** Checking out `qa`, `stg`, `prod` or `main` and then pulling is the most repeated command pair (93 and 140 uses). Releases create paired backend and frontend worktrees per environment, then remove them.
- **PRs and reviews dominate prompts.** `gh pr view` ran 241 times and `gh pr create` 88 times. Reviews often fan out to several reviewer agents and get consolidated by hand.
- **Parallel agents talk to each other.** 291 messages passed between backend and frontend sessions over a home-made socket channel, mostly to agree API contracts.
- **Visual QA against designs is constant.** About 640 browser automation actions and about 250 Figma lookups, mostly "still not centered" or "wrong size" follow-ups.
- **Almost no separate editor use.** `code` and similar ran 4 times. Work happens in Claude Code and the terminal. CotEditor is used for quick file opens.
- **Mapo's layout is what the user was already hunting for.** A personal session compared Zed, VS Code, cmux, Superset and Sublime, looking for projects on the left, a terminal in the middle and a tree on the right that follows the terminal. That session also reported, twice, that clicking a file left focus in the terminal.

## Ranked features

Ranked by how often the need shows up and how well it fits Mapo.

### Tier 1: build next

1. **Project workspaces with saved setups.** A workspace such as Obsess holds tabs in several repos: Claude in backend, Claude in frontend, dev servers for each. Save each tab's folder, kind and startup command so the whole project comes up in one click. Evidence: the user's own description, backend/frontend lockstep, about 600 path shortcuts.
2. **Correct agent status and "needs you" attention.** Show running, waiting for input, and done per tab and roll it up to the workspace row, with a badge and optional notification. Evidence: constant concurrency, background agents, users stepping away and resuming. Current Mapo shows the wrong status for idle Claude tabs.
3. **Choose the Claude identity per workspace.** Launch `claude` or `claude-work` (or any command) for Claude tabs, set per workspace. Evidence: two aliases, work used three times as much. Mapo currently always runs `claude`.
4. **Server tabs.** Mark a tab as a server. Show running, crashed or last-failure state and its local URL (portless name) on the workspace row, with restart and log actions. Detect `mprocs.yaml` and offer its processes. Evidence: `dev:ctl` usage, health polling loops, Expo failures, portless and mprocs in daily use.
5. **Clicking a file moves focus to the editor.** Evidence: reported twice verbatim. Core interaction.

### Tier 2: next wave

6. **Branch and worktree awareness.** Show each tab's branch. One-click "switch to qa, stg or prod and pull". "New worktree for this workspace", and a paired backend and frontend worktree action for releases. Evidence: 93 and 140 uses of the checkout and pull pair, frequent worktree use, "another agent is on a branch instead of the worktree".
7. **Changes summary per workspace.** Files changed and lines added per repo, visible before it becomes a 22,000-line PR. Evidence: "why is the PR 22k lines", "is it really 110 files on this branch".
8. **PR panel and multi-agent review.** List the branch's PR, its checks and comments. Add a "review with N agents and consolidate" action. Evidence: PR and review are the top prompt themes, recurring five-reviewer fan-outs.
9. **Tabs that can message each other.** Name tabs and let a Claude tab send a note to another tab, shown inline. Evidence: 291 cross-session messages over a home-made socket protocol, plus one mis-routed message.
10. **Handoff to a fresh tab.** One action that asks the agent to write a handoff note, then opens a fresh Claude tab in the same folder and branch. Evidence: explicit "context too high, restart" and "leave a note so I can restart" requests.

### Tier 3: later

11. **Browser pane per workspace.** VS Code already ships an integrated browser (`contrib/browserView`). Wire it to the workspace's server URL and let agents screenshot it. Do not expose auth tokens to agents: one session copied a production token out of browser storage.
12. **Mapo as default file opener and a `mapo` CLI.** Replaces CotEditor. Files open in the workspace that covers their repo, otherwise in a Quick workspace.
13. **Background agent panel.** One list of what each background agent did, instead of reconciling notifications by hand. Evidence: an 11-agent fan-out that had to be pieced together.

### Out of scope for Mapo

- Ticket creation (ClickUp): better as a Claude Code skill.
- Phone and VPN debugging loops: little a desktop app can fix beyond Tier 1 item 4.

## Things the user built that Mapo can absorb

| Home-made tool | Mapo equivalent |
|---|---|
| `y()` yazi wrapper that cds the shell on quit | Explorer that follows the terminal (done) |
| `gcof()` fuzzy branch switcher | Branch picker per tab (item 6) |
| `fkill()` fuzzy process killer | Server tabs with stop and restart (item 4) |
| `procs-init()` mprocs scaffolder, `dev:ctl` | Server tabs reading `mprocs.yaml` (item 4) |
| Socket-based cross-session messaging | Tab messaging (item 9) |

## Every suggestion, consolidated

All ideas from the four research reports plus the user's own, deduplicated and grouped. Source tags: **U** the user's own idea, **P** personal transcripts, **W** Mesh/Obsess work transcripts, **O** other work transcripts, **S** shell and prompt history. Numbers in brackets point to the ranked list above.

### Workspaces and layout

| # | Suggestion | Sources | Evidence |
|---|---|---|---|
| A1 | Workspace = project spanning several repos (backend, frontend, admin, mobile), with a combined status and diff across them | U, O, P, W | Hundreds of `cd`s between paired repos, about 600 path shortcuts, "VS Code doesn't allow multiple projects" [1] |
| A2 | Saved workspace setups: each tab's folder, kind and startup command, reopened in one click | U, S | The user's own description, the long clone-install-sync chain for a new checkout [1] |
| A3 | "New workspace from repo": clone, install root and subpackages, sync env vars | S | One long chained bootstrap command found verbatim |
| A4 | Quick add and remove of unrelated repos, not only worktrees of one repo | P | Multi-project sidebar was the reason VS Code got rejected |
| A5 | Reorderable, pinnable left rail that can mix workspaces, tabs and agent threads in the user's order | P | "ideally I can change order between files and agents" |
| A6 | Clicking a file moves focus to the editor; the explorer follows the terminal without stealing focus | P, S | Reported twice verbatim [5] |
| A7 | Discoverable keyboard shortcuts for new tab, new terminal from a thread, terminal and agent toggle | P | A shortcut that didn't register, and "is there a shortcut for this" |
| A8 | Pinned one-key actions for the most common commands | S | Frequent typos like `claer`, `claude-wrok` in fast terminal use |

### Agents and Claude tabs

| # | Suggestion | Sources | Evidence |
|---|---|---|---|
| B1 | Correct per-tab status (running, waiting for you, done) rolled up to the workspace row, with a badge | P, S, W | 304 minutes with concurrent sessions, hundreds of background task notifications [2] |
| B2 | Choose `claude`, `claude-work` or another command per workspace or tab | S | Two aliases, work used about three times as much [3] |
| B3 | Background agent dashboard: in-flight and finished tasks, output, jump to result | O, P | An 11-agent fan-out reconciled by hand [13] |
| B4 | Resume where you left off after a usage limit or restart, with a "done so far" marker | O, P | "Continue from where you left off, don't repeat work" |
| B5 | Fast interrupt and redirect: visible stop, keep context, follow up immediately | O | Frequent mid-task interrupts |
| B6 | Handoff to a fresh tab: agent writes a handoff note, a new Claude tab opens in the same folder and branch | W | "context too high, restart", "leave a note so I can restart" [10] |
| B7 | Named tabs that can message each other, shown inline | W, P | 291 messages over a home-made socket channel, one mis-routed [9] |
| B8 | Per-repo conventions panel: which skills and CI rules apply, one click to run them | O | The same repo skills invoked on almost every ship |

### Dev servers and processes

| # | Suggestion | Sources | Evidence |
|---|---|---|---|
| C1 | Server tabs: running, crashed or last failure, local URL, restart, logs | U, W, O, S | 147 `dev:ctl`/`dev:status`/`dev:logs` calls, health-check polling loops [4] |
| C2 | Read an existing `mprocs.yaml`, or generate one, and show its processes | S, W | The user's `procs-init()` helper and `dev:ctl` over mprocs [4] |
| C3 | Restart and share over Tailscale or portless in one action | S | `dev:stop` then `PORTLESS_TAILSCALE=1 dev`, verbatim 4 times |
| C4 | Port and PID process killer | S | The user's `fkill()` helper |
| C5 | Simulator actions: prebuild and run iOS, reboot or terminate a simulator, show the last failure | P, S | Expo and iOS is the most failure-prone command family |
| C6 | "Restart backend and tail logs" reachable from any workspace tab | W | Phone and VPN debugging needed manual API restarts |

### Git, worktrees and PRs

| # | Suggestion | Sources | Evidence |
|---|---|---|---|
| D1 | One-click "switch to qa, stg, prod or main and pull" | S | 93 and 140 uses of that pair [6] |
| D2 | Branch shown on every tab, fuzzy branch picker with log preview | S, W | The user's `gcof()`, "another agent is on a branch instead of the worktree" [6] |
| D3 | New worktree for a workspace | P, W | Worktrees used constantly [6] |
| D4 | Promote to environment: create, verify and clean up a paired backend and frontend worktree | O | The qa, stg, prod release routine [6] |
| D5 | Changes summary per workspace and repo, with a size warning | P, W | "is it really 110 files", "why is the PR 22k lines" [7] |
| D6 | PR panel: the branch's PR, checks and comments | S, W, P | `gh pr view` 241 times [8] |
| D7 | Review with N agents and consolidate, output written outside the repo by default | W, P | Recurring five-reviewer fan-outs, reviews kept out of the reviewed repo [8] |
| D8 | PR helpers: write or update the description from the diff, request a bot re-review, target an env branch | S | PR and review are the top prompt themes |

### Browser, visuals and files

| # | Suggestion | Sources | Evidence |
|---|---|---|---|
| E1 | Browser pane per workspace, pointed at its server URL, usable by agents without exposing auth tokens | O, W | About 640 browser automation actions; a production token was copied out of storage [11] |
| E2 | Screenshot the current dev page and compare against a Figma link | W | About 250 Figma lookups, "still not centered" loops |
| E3 | Mapo as default file opener and a `mapo` CLI, replacing CotEditor, landing in the matching workspace or a Quick workspace | U | The user's own idea [12] |

### Outside Mapo's scope

| # | Suggestion | Sources | Why not |
|---|---|---|---|
| F1 | File a ticket (ClickUp) from a conversation | W | Better as a Claude Code skill |
| F2 | Cross-device mobile debugging | W | Little a desktop app can fix beyond C6 |
