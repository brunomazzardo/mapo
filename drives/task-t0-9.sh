#!/usr/bin/env zsh
# task-t0-9: an agent can see and drive the app as a person does, with no Accessibility permission.
set -euo pipefail
source "${0:A:h}/lib.sh"

drive_begin task-t0-9

step "The window names its instance"
mapo ui window | expect_json "(.title | endswith(\"($DRIVE_INSTANCE)\")) and .windowNumber > 0" true

step "⇧⌘N opens a workspace with a focused shell"
new_ws() {
    mapo ui key cmd+shift+n >/dev/null
    mapo ui wait 'rail.workspace:Workspace 1' --timeout-ms 2000 >/dev/null
    mapo ui wait 'pane.terminal:terminal-1' --state focused --timeout-ms 3000 >/dev/null
}
timing new-workspace new_ws
ui_snapshot new-workspace; ui_shot new-workspace
expect_json '.focus.id' '"pane.terminal:terminal-1"' < "$SNAP"

step "⌘T opens a second tab that takes focus"
new_tab() {
    mapo ui key cmd+t >/dev/null
    mapo ui wait 'pane.terminal:terminal-2' --state focused --timeout-ms 3000 >/dev/null
}
timing new-tab new_tab
mapo tab wait terminal-2 --until idle --timeout-ms 5000 >/dev/null

step "Typing like a person reaches the shell"
mapo tab wait terminal-2 --until typed-42 --timeout-ms 5000 >/dev/null &
waiter=$!
mapo ui type 'echo typed-$((6*7))' >/dev/null
mapo ui key return >/dev/null
wait $waiter
ui_snapshot typed; ui_shot typed
expect_json '[.terminals[].text | contains("typed-42")] | any' true < "$SNAP"

step "Clicking a rail row activates that workspace"
mapo workspace new Alpha >/dev/null
mapo ui wait rail.workspace:Alpha --timeout-ms 2000 >/dev/null
mapo ui click rail.workspace:Alpha >/dev/null
sleep 0.2
mapo rpc state.snapshot | expect_json '.activeWorkspaceId == (.workspaces[] | select(.name=="Alpha") | .id)' true

step "Metrics, identifiers and a snapshot"
mapo ui metrics > "$DRIVE_TMP/metrics.json"
expect_json '.launch.processStartToFirstFrameMs > 0' true < "$DRIVE_TMP/metrics.json"
mapo ui tree | jq '[.. | objects | select(.role? as $r | ["button","checkBox","radioButton","popUpButton","menuButton","textField","textArea","row","link","slider","splitter"] | index($r)) | select(.id == null)] | length' |
    expect_json . 0
ui_snapshot rail; ui_shot rail

step "Without an app, ui calls are unavailable"
kill $DRIVE_APP_PID
for _ in {1..100}; do kill -0 $DRIVE_APP_PID 2>/dev/null || break; sleep 0.05; done
DRIVE_APP_PID=0
rc=0; mapo ui window 2> "$DRIVE_TMP/noapp.err" >/dev/null || rc=$?
print -r -- "{\"rc\":$rc}" | expect_json .rc 1
jq -c .kind "$DRIVE_TMP/noapp.err" | expect_json . '"unavailable"'

drive_end
