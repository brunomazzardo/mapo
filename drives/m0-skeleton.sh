#!/usr/bin/env zsh
# m0-skeleton: the M0 gate (PLAN T0.11). A person opens Mapo, makes a workspace and tabs with
# the keyboard, types into a terminal, runs vim, quits and relaunches the app, and restarts the
# daemon. Terminals must survive all of it.
set -euo pipefail
source "${0:A:h}/lib.sh"

drive_begin m0-skeleton

ws="Workspace 1"

step "New workspace with ⇧⌘N opens a focused shell"
new_workspace() {
    mapo ui key cmd+shift+n >/dev/null
    mapo ui wait "rail.workspace:$ws" --timeout-ms 2000 >/dev/null
    mapo ui wait 'pane.terminal:terminal-1' --state focused --timeout-ms 3000 >/dev/null
}
timing new-workspace new_workspace
mapo workspace list | jq -c '[.[].name]' | expect_json . "[\"$ws\"]"
mapo tab list --workspace "$ws" | jq -c '[.[].name]' | expect_json . '["terminal-1"]'
ui_snapshot new-workspace; ui_shot new-workspace
expect_json '.focus.id' '"pane.terminal:terminal-1"' < "$SNAP"

step "⌘T opens a second tab that takes focus and reaches a prompt"
new_tab() {
    mapo ui key cmd+t >/dev/null
    mapo ui wait 'pane.terminal:terminal-2' --state focused --timeout-ms 3000 >/dev/null
    mapo tab wait terminal-2 --workspace "$ws" --until idle --timeout-ms 5000 >/dev/null
}
timing new-tab new_tab
mapo tab list --workspace "$ws" | jq -c '[.[].name]' | expect_json . '["terminal-1","terminal-2"]'

step "Type a command like a person"
mapo tab wait terminal-2 --workspace "$ws" --until drive-42 --timeout-ms 5000 >/dev/null &
waiter=$!
mapo ui type 'echo drive-$((6*7))' >/dev/null
mapo ui key return >/dev/null
wait $waiter
ui_snapshot typed; ui_shot typed
expect_json '[.terminals[].text | test("(?m)^drive-42$")] | any' true < "$SNAP"
expect_json '.focus.id' '"pane.terminal:terminal-2"' < "$SNAP"

step "A tab made from the CLI appears in the rail and runs in its folder"
mapo tab new --workspace "$ws" --name cli --cwd "$DRIVE_TMP" >/dev/null
mapo ui wait "rail.tab:$ws/cli" --timeout-ms 1000 >/dev/null
mapo tab wait cli --workspace "$ws" --until idle --timeout-ms 5000 >/dev/null
mapo tab run cli pwd --workspace "$ws" | jq -c .output | expect_json . "\"${DRIVE_TMP:A}\""

step "Clicking a rail row shows that tab and moves focus to it"
mapo ui click "rail.tab:$ws/terminal-1" >/dev/null
mapo ui wait 'pane.terminal:terminal-1' --state focused --timeout-ms 2000 >/dev/null
ui_snapshot clicked
expect_json '.focus.id' '"pane.terminal:terminal-1"' < "$SNAP"
mapo ui tree | jq '[.. | objects | select(.role? as $r | ["button","checkBox","radioButton",
    "popUpButton","menuButton","textField","textArea","row","link","slider","splitter"] | index($r))
    | select(.id == null)] | length' | expect_json . 0

step "vim runs full screen and takes typing"
mapo tab send terminal-1 --workspace "$ws" "vim -u NONE -N $DRIVE_TMP/notes.txt" >/dev/null
mapo tab wait terminal-1 --workspace "$ws" --until 'notes.txt' --timeout-ms 5000 >/dev/null
mapo ui type 'ihello vim' >/dev/null
mapo ui key escape >/dev/null
mapo tab read terminal-1 --workspace "$ws" | jq -c '[.altScreen, (.text | contains("hello vim"))]' | expect_json . '[true,true]'
ui_snapshot vim; ui_shot vim

step "Quitting the app leaves every terminal running"
P=$(mapo tab run cli 'echo $$' --workspace "$ws" | jq -r .output)
app_pid=$DRIVE_APP_PID
mapo ui key cmd+q >/dev/null || true
for _ in {1..100}; do kill -0 $app_pid 2>/dev/null || break; sleep 0.05; done
kill -0 $app_pid 2>/dev/null && { print "   FAIL app pid $app_pid still running after ⌘Q"; DRIVE_FAILS+=1; }
DRIVE_APP_PID=0
mapo tab list --workspace "$ws" | jq -c '[.[].name] | sort' | expect_json . '["cli","terminal-1","terminal-2"]'
mapo tab run cli 'echo $$' --workspace "$ws" | jq -r .output | jq -R . | expect_json . "\"$P\""

step "Relaunching the app reattaches and repaints vim"
_drive_start_app_impl
mapo ui wait 'pane.terminal:terminal-1' --timeout-ms 3000 >/dev/null
# A relaunch is a cold launch that reattaches every visible surface.
_drive_record_timing relaunch "$(mapo ui metrics | jq '.launch.processStartToFirstFrameMs | floor')"
ui_snapshot relaunch; ui_shot vim-relaunch
mapo tab read terminal-1 --workspace "$ws" | jq -c '[.altScreen, (.text | contains("hello vim"))]' | expect_json . '[true,true]'

step "Restarting the daemon shows the banner, then the tabs come back"
mapo ui focus 'pane.terminal:terminal-1' >/dev/null
mapo ui type ':q!' >/dev/null
mapo ui key return >/dev/null
mapo tab wait terminal-1 --workspace "$ws" --until idle --timeout-ms 5000 >/dev/null
mapo tab read terminal-1 --workspace "$ws" | jq -r '.text | split("\n") | last' | jq -R 'test("R$") | not' | expect_json . true
LOGDIR=$("$MAPO_BIN" --instance "$DRIVE_INSTANCE" instance show --json | jq -r .logDir)
mapo instance stop >/dev/null
# ui.* goes through the daemon, so while it's down the banner is read from the app log.
for _ in {1..60}; do grep -q 'banner reconnecting: Reconnecting to mapod' "$LOGDIR"/app.*.log && break; sleep 0.05; done
grep -c 'banner reconnecting: Reconnecting to mapod' "$LOGDIR"/app.*.log | jq -R '{n: tonumber}' | expect_json '.n >= 1' true
DRIVE_DAEMON_PID=$(mapo daemon | jq -r .pid)
timing daemon-reconnect wait_app 10000
mapo ui wait 'pane.terminal:terminal-1' --timeout-ms 5000 >/dev/null
mapo tab wait cli --workspace "$ws" --until idle --timeout-ms 5000 >/dev/null
mapo tab run cli pwd --workspace "$ws" | jq -c .output | expect_json . "\"${DRIVE_TMP:A}\""
ui_snapshot daemon-restart; ui_shot daemon-restart
_drive_record_timing app.reattach "$(mapo ui metrics | jq '[.navigation[]? | select(.name == "app.reattach") | .ms] | last | floor')"
_drive_record_timing attach-last "$(mapo ui metrics | jq '.attach.lastMs // 0')"
jq '[.. | objects | select(.id? == "app.banner" and .value? != "hidden")] | length' "$SNAP" | expect_json . 0

drive_end
