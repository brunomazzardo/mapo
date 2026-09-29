---
name: mapo
description: Drive Mapo from inside a Mapo tab with the mapo CLI (workspaces, tabs, send, wait, read, run). Use when you need to coordinate with other tabs or agents in Mapo.
---

# Mapo

You are running inside a Mapo tab. The `mapo` CLI on your PATH talks to this Mapo instance as your tab.

- `mapo tab list`, `mapo tab new --name N [--cwd DIR]`: see and create tabs in your workspace.
- `mapo tab send NAME 'text'`, then `mapo tab wait NAME --until idle|TEXT`: type into a tab and wait instead of polling.
- `mapo tab read NAME` and `mapo tab run NAME 'cmd'`: read a screen, or run a command and get its output and exit code.
- Destructive actions on other tabs or workspaces need `--force`; only use it when the user asked.

The full skill arrives in PLAN T3.6.
