#!/usr/bin/env zsh
# task-t1-3: workspace switching. Two workspaces with 5 visible panes each; ⌃⌘↑ and ⌃⌘↓ swap cached
# containers fast; terminals hidden for 30 s free their `mapo attach`, and showing them again repaints
# from the replay.
set -euo pipefail
source "${0:A:h}/lib.sh"

drive_begin task-t1-3

attaches() { pgrep -f "attach --tab .* --instance $DRIVE_INSTANCE( |\$)" | wc -l | tr -d ' '; }

# Five panes: ⌘D, ⇧⌘D, ⌘D, ⇧⌘D from one shell, each waiting for the new terminal to take focus.
five_panes() {
    local n=$1 k
    for k in cmd+d cmd+shift+d cmd+d cmd+shift+d; do
        n=$(( n + 1 ))
        mapo ui key $k >/dev/null
        mapo ui wait "pane.terminal:terminal-$n" --state focused --timeout-ms 3000 >/dev/null
    done
}

step "Two workspaces with 5 visible panes each, every shell after seq 1 2000"
for ws in "Workspace 1" "Workspace 2"; do
    mapo ui key cmd+shift+n >/dev/null
    mapo ui wait "rail.workspace:$ws" --timeout-ms 2000 >/dev/null
    mapo ui wait 'pane.terminal:terminal-1' --state focused --timeout-ms 3000 >/dev/null
    five_panes 1
    mapo rpc layout.get | jq '[.. | objects | select(.kind=="pane")] | length' | expect_json . 5
    for t in $(mapo tab list --workspace "$ws" | jq -r '.[].name'); do
        mapo tab wait $t --workspace "$ws" --until idle --timeout-ms 5000 >/dev/null
        mapo tab send $t --workspace "$ws" 'seq 1 2000' >/dev/null
    done
done
sleep 1
attaches | expect_json . 10
ui_snapshot fixture; ui_shot fixture

step "20 alternations of ⌃⌘↑ and ⌃⌘↓"
mapo ui metrics --reset >/dev/null
for _ in {1..20}; do
    mapo ui key ctrl+cmd+up >/dev/null
    sleep 0.15
    mapo ui key ctrl+cmd+down >/dev/null
    sleep 0.15
done
sleep 0.3
mapo ui metrics > "$DRIVE_TMP/switch.json"
jq '[.navigation[] | select(.name=="workspace.switch")] | length' "$DRIVE_TMP/switch.json" | expect_json . 40
_drive_record_timing workspace-switch \
    "$(jq '[.navigation[] | select(.name=="workspace.switch") | .ms] | sort | .[(length*0.95|floor)] | floor' "$DRIVE_TMP/switch.json")"
_drive_record_timing workspace-switch-p50 \
    "$(jq '[.navigation[] | select(.name=="workspace.switch") | .ms] | sort | .[(length*0.5|floor)] | floor' "$DRIVE_TMP/switch.json")"
mapo rpc state.snapshot | jq -r '.workspaces[] | select(.id == $ARGS.named.a) | .name' --arg a "$(mapo rpc state.snapshot | jq -r .activeWorkspaceId)" |
    jq -R . | expect_json . '"Workspace 2"'
# Surfaces were reused, not rebuilt: still one attach per tab.
attaches | expect_json . 10

step "After 31 s hidden, only the visible surfaces keep an attach"
# The detach fires 30 s after the last switch hid them; allow a few seconds for the processes to exit.
sleep 30
for _ in {1..40}; do (( $(attaches) <= 5 )) && break; sleep 0.1; done
attaches | expect_json . 5

step "⌃⌘↑ shows Workspace 1 again and the replay repaints it"
mapo ui metrics --reset >/dev/null
mapo ui key ctrl+cmd+up >/dev/null
mapo ui wait 'pane.terminal:terminal-5' --timeout-ms 3000 >/dev/null
sleep 1
ui_snapshot back; ui_shot back
jq '(.terminals | length) == 5 and (.terminals | all(.text | length > 0))' "$SNAP" | expect_json . true
jq '[.terminals[].text | test("(?m)^2000$")] | all' "$SNAP" | expect_json . true
attaches | expect_json . 10
_drive_record_timing workspace-switch-cold \
    "$(mapo ui metrics | jq '[.navigation[] | select(.name=="workspace.switch") | .ms] | last | floor')"

step "Restart the daemon: the app reattaches every visible surface"
mapo instance stop >/dev/null
DRIVE_DAEMON_PID=$(mapo daemon | jq -r .pid)
timing daemon-reconnect wait_app 10000
mapo ui wait 'pane.terminal:terminal-5' --timeout-ms 5000 >/dev/null
sleep 1
_drive_record_timing app.reattach "$(mapo ui metrics | jq '[.navigation[]? | select(.name == "app.reattach") | .ms] | last // 0 | floor')"
mapo ui tree | jq '[.. | objects | select(.role? as $r | ["button","checkBox","radioButton","popUpButton","menuButton","textField","textArea","row","link","slider","splitter"] | index($r)) | select(.id == null)] | length' |
    expect_json . 0

drive_end
