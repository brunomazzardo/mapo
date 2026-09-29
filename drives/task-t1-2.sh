#!/usr/bin/env zsh
# task-t1-2: tiling panes. ⌘D and ⇧⌘D split with a shell in the same folder, ⌥⌘ arrows move focus,
# ⌘W closes a pane and keeps its tab, a rail click shows a background tab in the focused pane, ⇧⌘W
# asks before closing a busy tab, and the layout survives an app relaunch and a daemon restart.
set -euo pipefail
source "${0:A:h}/lib.sh"

drive_begin task-t1-2

ws="Workspace 1"
panes() { mapo rpc layout.get | jq '[.. | objects | select(.kind=="pane")] | length'; }

step "⇧⌘N, then cd somewhere; ⌘D and ⇧⌘D split with a shell in that folder"
mapo ui key cmd+shift+n >/dev/null
mapo ui wait 'pane.terminal:terminal-1' --state focused --timeout-ms 3000 >/dev/null
mapo tab wait terminal-1 --until idle --timeout-ms 5000 >/dev/null
mapo tab send terminal-1 "cd ${DRIVE_TMP:A}" >/dev/null
mapo tab wait terminal-1 --until idle --timeout-ms 5000 >/dev/null
mapo ui metrics --reset >/dev/null
split_right() {
    mapo ui key cmd+d >/dev/null
    mapo ui wait 'pane.terminal:terminal-2' --state focused --timeout-ms 3000 >/dev/null
}
timing split-right split_right
mapo ui key cmd+shift+d >/dev/null
mapo ui wait 'pane.terminal:terminal-3' --state focused --timeout-ms 3000 >/dev/null
panes | expect_json . 3
for t in terminal-1 terminal-2 terminal-3; do
    mapo tab wait $t --until idle --timeout-ms 5000 >/dev/null
    mapo tab run $t pwd | jq -c .output | expect_json . "\"${DRIVE_TMP:A}\""
done
ui_snapshot split; ui_shot split
# Panes tile: headers, bodies and gutters carry their identifiers, and cards don't overlap.
jq '[.tree | .. | objects | select((.id // "") | startswith("pane.header:"))] | length' "$SNAP" | expect_json . 3
jq '[.tree | .. | objects | select((.id // "") | startswith("pane.divider:"))] | length' "$SNAP" | expect_json . 2
jq '[.tree | .. | objects | select((.id // "") | startswith("pane:")) | .frame] as $f
    | [range(0; $f|length) as $i | range($i+1; $f|length) as $j | $f[$i] as $a | $f[$j] as $b
       | select($a.x < $b.x + $b.w and $b.x < $a.x + $a.w and $a.y < $b.y + $b.h and $b.y < $a.y + $a.h)]
    | length' "$SNAP" | expect_json . 0
_drive_record_timing pane.split "$(mapo ui metrics | jq '[.navigation[] | select(.name=="pane.split") | .ms] | max | floor')"

step "⌥⌘← moves focus to the pane on the left; a click on a pane focuses it"
mapo ui key cmd+alt+left >/dev/null
mapo ui wait 'pane.terminal:terminal-1' --state focused --timeout-ms 2000 >/dev/null
ui_snapshot focus-left
expect_json '.focus.id' '"pane.terminal:terminal-1"' < "$SNAP"
mapo ui key cmd+alt+left >/dev/null   # at the edge: nothing happens
sleep 0.3
mapo ui snapshot | expect_json '.focus.id' '"pane.terminal:terminal-1"'
mapo ui click 'pane.header:terminal-3' >/dev/null
mapo ui wait 'pane.terminal:terminal-3' --state focused --timeout-ms 2000 >/dev/null
t3_pane=$(mapo tab list | jq -r '.[] | select(.name=="terminal-3") | .paneId')
mapo rpc layout.get | jq -c .focusedPaneId | expect_json . "\"$t3_pane\""

step "⌘W closes the pane and the tab keeps running in the background"
mapo ui key cmd+w >/dev/null
sleep 0.4
panes | expect_json . 2
mapo tab list | jq length | expect_json . 3
mapo tab list | jq -c '[.[] | select(.name=="terminal-3") | .visible]' | expect_json . '[false]'

step "A rail click on the background tab shows it in the focused pane"
mapo ui click "rail.tab:$ws/terminal-3" >/dev/null
mapo ui wait 'pane.terminal:terminal-3' --state focused --timeout-ms 2000 >/dev/null
panes | expect_json . 2
mapo tab list | jq -c '[.[] | select(.name=="terminal-3") | .visible]' | expect_json . '[true]'
ui_snapshot rail-click

step "⇧⌘W asks before closing a tab that runs a command; Cancel keeps it, Close Tab closes it"
mapo tab send terminal-3 'sleep 600' >/dev/null
for _ in {1..40}; do [[ $(mapo tab list | jq -r '.[] | select(.name=="terminal-3") | .state') == running ]] && break; sleep 0.1; done
mapo ui wait 'pane.stop:terminal-3' --timeout-ms 2000 >/dev/null
mapo ui key cmd+shift+w >/dev/null
mapo ui wait dialog --timeout-ms 2000 >/dev/null
ui_snapshot dialog; ui_shot dialog
mapo ui press dialog.cancel >/dev/null
mapo ui wait dialog --state gone --timeout-ms 2000 >/dev/null
mapo tab list | jq length | expect_json . 3
mapo ui key cmd+shift+w >/dev/null
mapo ui wait dialog --timeout-ms 2000 >/dev/null
mapo ui press dialog.confirm >/dev/null
mapo ui wait 'pane.terminal:terminal-3' --state gone --timeout-ms 3000 >/dev/null
mapo tab list | jq -c '[.[].name] | sort' | expect_json . '["terminal-1","terminal-2"]'
panes | expect_json . 1

step "Closing the last pane leaves an empty pane; Return opens a shell in it"
mapo ui key cmd+d >/dev/null
mapo ui wait 'pane.terminal:terminal-3' --state focused --timeout-ms 3000 >/dev/null
mapo pane close >/dev/null
mapo pane close >/dev/null
# The CLI returns before the app renders the new layout; wait for the empty pane.
for _ in {1..40}; do
    mapo ui tree --depth 24 | jq -e '[.. | objects | select((.id // "") | startswith("pane.empty.newShell:"))] | length == 1' >/dev/null && break
    sleep 0.05
done
ui_snapshot empty
jq '[.tree | .. | objects | select((.id // "") | startswith("pane.empty.newShell:"))] | length' "$SNAP" | expect_json . 1
jq '[.tree | .. | objects | select((.id // "") | startswith("pane.empty.newAgent:"))] | length' "$SNAP" | expect_json . 1
mapo ui key return >/dev/null
mapo ui wait 'pane.terminal:terminal-4' --state focused --timeout-ms 3000 >/dev/null

step "Resize and equalize from the CLI; a double-click on a gutter equalizes its split"
mapo pane split right >/dev/null
mapo pane split down --tab terminal-1 >/dev/null
split=$(mapo rpc layout.get | jq -r .root.id)
mapo rpc pane.resize "{\"split\":\"$split\",\"ratios\":[1,3]}" | jq -c .root.ratios | expect_json . '[0.25,0.75]'
mapo ui click "pane.divider:$split/0" --count 2 >/dev/null
sleep 0.3
mapo rpc layout.get | jq -c .root.ratios | expect_json . '[0.5,0.5]'
mapo rpc pane.resize "{\"split\":\"$split\",\"ratios\":[0.35,0.65]}" >/dev/null
mapo pane focus left >/dev/null
mapo rpc layout.get > "$DRIVE_TMP/saved.json"

step "Quit and relaunch the app, restart the daemon: the layout comes back, ratios included"
app_pid=$DRIVE_APP_PID
mapo ui key cmd+q >/dev/null || true
for _ in {1..100}; do kill -0 $app_pid 2>/dev/null || break; sleep 0.05; done
DRIVE_APP_PID=0
mapo instance stop >/dev/null
DRIVE_DAEMON_PID=$(mapo daemon | jq -r .pid)
_drive_start_app_impl
mapo ui wait 'pane.terminal:terminal-4' --timeout-ms 5000 >/dev/null
mapo rpc layout.get | jq -S . > "$DRIVE_TMP/restored.json"
jq -S . "$DRIVE_TMP/saved.json" | diff - "$DRIVE_TMP/restored.json" >/dev/null && same=true || same=false
print -r -- "$same" | expect_json . true
ui_snapshot relaunch; ui_shot relaunch
jq '[.tree | .. | objects | select((.id // "") | startswith("pane:"))] | length' "$SNAP" | expect_json . 3
mapo ui tree | jq '[.. | objects | select(.role? as $r | ["button","checkBox","radioButton","popUpButton","menuButton","textField","textArea","row","link","slider","splitter"] | index($r)) | select(.id == null)] | length' |
    expect_json . 0

drive_end
