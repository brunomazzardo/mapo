# Progress

Newest entries first. Every session adds an entry. Every overnight run ends with a **morning report**; its template is in [PLAN.md](PLAN.md). Keep the entries short, link evidence, and move anything that needs the user into "Needs the user".

## Needs the user

- Session `mapo-native` never processed its kickoff: the cross-session message stayed queued and the session stayed "waiting", probably blocked on something in its UI. The overnight run was moved to `mapo-bf` as coordinator (HANDOFF §7). Check what `mapo-native` was waiting on.

- Before the first overnight run, do the HANDOFF §4 pre-flight: Screen Recording for the terminal app that runs the agent, and permissions for the agent session.

## 2026-09-28: specs written, no code yet

- The interview produced [DECISIONS.md](DECISIONS.md). The design exploration is on the Claude Design canvas <https://claude.ai/artifact/DXzWX7bnxWX3i2zJCy1A8J>; the chosen boards are "A · Source list" and "S2 · Slimmer".
- Research is saved in [research/](research/).
- The orphan branch `native` was created as worktree `~/code/mapo-native`. The docs set was written and committed.
- Next: [PLAN.md](PLAN.md) T0.1.
