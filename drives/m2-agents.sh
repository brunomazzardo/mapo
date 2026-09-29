#!/usr/bin/env zsh
# m2-agents: the M2 gate (PLAN T2.6), synthetic path. It is task-t2-4's attention walk plus Working and
# Done in the rail and pane header. The real-Claude path is skipped tonight: see docs/PROGRESS.md.
# Originally task-t2-4: attention on the synthetic path (PLAN T2.4, with the app bits of T2.3). A PermissionRequest
# fixture goes through `mapo hook` inside a shell tab of a background workspace; the drive checks the rail
# badge, the dock badge, the notification log line (never a banner, ENGINEERING §10), coalescing, ⌘J, the
# visible case, the pane's Stop and ⇧⌘X, and ⇧⌘T. No real Claude runs here.
set -euo pipefail
source "${0:A:h}/lib.sh"

drive_begin m2-agents
F="$MAPO_ROOT/crates/mapo-agent/fixtures"
LOGDIR=$("$MAPO_BIN" --instance "$DRIVE_INSTANCE" instance show --json | jq -r .logDir)
# Tab ag lives in Back; the CLI resolves names in the active workspace unless told. The leading space
# absorbs the Esc an interrupt leaves in this plain shell, which would otherwise eat the next character.
hook() { mapo tab run --workspace Back "$1" " mapo hook < $F/$2.json" >/dev/null; }
tabs() { mapo rpc state.snapshot | jq .tabs; }
tab_id() { tabs | jq -r --arg n "$1" '.[] | select(.name==$n) | .id'; }
state() { tabs | jq -c --arg n "$1" '.[] | select(.name==$n) | .state'; }
badge() { mapo ui snapshot | jq -c --arg id "rail.workspace.badge:$1" '[.. | objects | select(.id? == $id) | .value]'; }
# reasons ID: the app's notification log lines for a tab, one reason per line.
reasons() { cat "$LOGDIR"/app.*.log | grep -o "notification:$1 .*" | sed -E 's/.*reason=([a-z]+).*/\1/' || true; }
# wait_reasons ID N: waits (3 s) until the tab has N notification lines, then prints them as JSON.
wait_reasons() {
    local i
    for i in {1..60}; do (( $(reasons $1 | wc -l) >= $2 )) && break; sleep 0.05; done
    reasons $1 | jq -Rsc 'split("\n") | map(select(. != ""))'
}
# poll FILTER EXPECTED CMD...: re-runs CMD until jq FILTER gives EXPECTED (3 s), then checks it.
poll() {
    local filter=$1 expected=$2 want out i
    shift 2
    want=$(print -r -- "$expected" | jq -c .)
    for i in {1..60}; do
        out=$("$@" 2>/dev/null | jq -c "$filter" 2>/dev/null) || out=""
        [[ $out == "$want" ]] && break
        sleep 0.05
    done
    "$@" | expect_json "$filter" "$expected"
}

step "Setup: workspace Back with shell tab ag, then Front with tab a, active"
mapo workspace new Back >/dev/null
mapo tab new --workspace Back --name ag >/dev/null
mapo workspace new Front >/dev/null
mapo rpc workspace.activate "{\"workspace\":\"$(mapo workspace list | jq -r '.[] | select(.name=="Front") | .id')\"}" >/dev/null
mapo tab new --workspace Front --name a --focus >/dev/null
mapo ui wait 'pane.terminal:a' --timeout-ms 5000 >/dev/null
mapo tab wait --workspace Back ag --until idle --timeout-ms 8000 >/dev/null
mapo tab wait a --until idle --timeout-ms 8000 >/dev/null
AG=$(tab_id ag)
snap_model() { mapo ui snapshot | jq -c .model.dockBadge; }
snap_model | expect_json . 0

step "A PermissionRequest in the background workspace: badge, dock badge, attention.changed, notification"
hook ag 02-UserPromptSubmit
hook ag 03-PermissionRequest
poll . '"needs-you"' state ag
mapo events --after 0 | jq -s -c '[.[] | select(.type=="attention.changed") | .data.count] | last' | expect_json . 1
poll . '["1"]' badge Back
mapo ui snapshot | expect_json .model.dockBadge 1
ui_snapshot needs-you-background; ui_shot needs-you-background
first=$(wait_reasons $AG 1 | jq -r '.[0]')
if [[ $first == unauthorized ]]; then
    # macOS asks for notification permission once, in a dialog only the user can answer (ENGINEERING §10).
    print "   note: notifications unauthorized for dev.mapo.app.dev; Needs the user to allow them"
    print -r -- '"unauthorized"' | expect_json . '"unauthorized"'
else
    print -r -- "\"$first\"" | expect_json . '"posted"'
fi
grep -h "notification:$AG " "$LOGDIR"/app.*.log | head -1 | jq -Rc 'test("state=needs-you shown=(true|false) reason=")' |
    expect_json . true

step "A second PermissionRequest coalesces"
hook ag 03-PermissionRequest
wait_reasons $AG 2 | expect_json '.[1]' '"coalesced"'
mapo ui snapshot | expect_json .model.dockBadge 1

step "⌘J focuses the tab that needs you, in its workspace"
mapo ui key cmd+j >/dev/null
mapo ui wait 'pane.terminal:ag' --state focused --timeout-ms 3000 >/dev/null
mapo rpc state.snapshot | jq -r '.activeWorkspaceId as $a | .workspaces[] | select(.id == $a) | .name' | jq -Rc . |
    expect_json . '"Back"'
state ag | expect_json . '"needs-you"'   # viewing never clears needs-you (R-ST-5)
ui_snapshot focused-needs-you; ui_shot focused-needs-you

step "The same event for the focused, visible tab logs reason=visible"
hook ag 04-PostToolBatch
poll . '"running"' state ag
hook ag 03-PermissionRequest
poll . '"needs-you"' state ag
# Only a window a person can see counts (UX §7.3): when other windows cover it, it notifies instead.
if [[ $(mapo ui window | jq .occluded) == false ]]; then
    wait_reasons $AG 3 | expect_json '.[2]' '"visible"'
else
    print "   note: the window is occluded on this screen, so the tab can't be seen"
    wait_reasons $AG 3 | expect_json '.[2] | IN("posted", "unauthorized")' true
fi

step "Stop on a working agent's pane interrupts it (pane.stop:ag)"
hook ag 04-PostToolBatch
poll . '"running"' state ag
mapo ui wait 'pane.stop:ag' --timeout-ms 3000 >/dev/null
ui_snapshot working; ui_shot working
mapo ui click 'pane.stop:ag' >/dev/null
poll . '"idle"' state ag
tabs | expect_json '.[] | select(.name=="ag") | .agent.interrupted' true
mapo ui wait 'pane.stop:ag' --state gone --timeout-ms 3000 >/dev/null

step "⇧⌘X interrupts the focused working agent"
hook ag 02-UserPromptSubmit
poll . '"running"' state ag
mapo ui key cmd+shift+x >/dev/null
poll . '"idle"' state ag
mapo ui snapshot | expect_json .model.dockBadge 0
poll '.' '[]' badge Back

step "⇧⌘T opens an agent tab running the workspace's agent command"
mapo workspace configure Back --agent-command 'echo fakeagent' | expect_json .agentCommand '"echo fakeagent"'
before=$(tabs | jq length)
mapo ui key cmd+shift+t >/dev/null
poll length $((before + 1)) tabs
new=$(tabs | jq -r '[.[] | select(.kind=="agent")] | last | .name')
mapo ui wait "pane.terminal:$new" --state focused --timeout-ms 3000 >/dev/null
mapo tab wait --workspace Back "$new" --until fakeagent --timeout-ms 8000 >/dev/null

step "Working and Done show in the rail row and the pane header of the active workspace"
mapo rpc workspace.activate "{\"workspace\":\"$(mapo workspace list | jq -r '.[] | select(.name=="Back") | .id')\"}" >/dev/null
mapo ui wait 'rail.tab:Back/ag' --timeout-ms 3000 >/dev/null
# ⇧⌘T's agent tab took the pane in the previous step; show ag the way a person would.
mapo ui click 'rail.tab:Back/ag' >/dev/null
mapo ui wait 'pane.terminal:ag' --timeout-ms 3000 >/dev/null
hook ag 02-UserPromptSubmit
poll . '"running"' state ag
rail_ag() { mapo ui snapshot | jq -c '[.model.rail[]? | select(.kind=="tab" and .name=="ag") | .state] | first'; }
poll . '"running"' rail_ag
# The header shows Stop (pane.stop:ag) only while the agent works (UX §4.1).
mapo ui wait 'pane.stop:ag' --timeout-ms 3000 >/dev/null
mapo ui snapshot | jq -c '[.. | objects | select(.id? == "pane.stop:ag")] | length' | expect_json . 1
ui_snapshot working; ui_shot working
hook ag 10-Stop
poll . '"done"' rail_ag
mapo ui wait 'pane.stop:ag' --state gone --timeout-ms 3000 >/dev/null
ui_snapshot done; ui_shot done
print "   SKIPPED: the real-Claude path (start, trust, a turn, Stop, resume); see docs/PROGRESS.md Needs the user"

drive_end
