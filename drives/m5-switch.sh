#!/usr/bin/env zsh
# m5-switch: the performance pass (PLAN T5.1, ENGINEERING §6), meant for a Release build:
#   just profile=release drive m5-switch
# Records every R-NF-1 metric against its budget; budgets are reported, not enforced here.
set -euo pipefail
source "${0:A:h}/lib.sh"

drive_begin m5-switch
median() { jq -s 'sort | .[(length/2|floor)]' }
metric() { mapo ui metrics | jq "$1" }

step "Fixture: workspace One with 5 visible panes, Two with 5, and 10 hidden tabs in Three (20 tabs)"
mapo ui key cmd+shift+n >/dev/null
mapo ui wait 'pane.terminal:terminal-1' --state focused --timeout-ms 5000 >/dev/null
mapo workspace rename 'Workspace 1' One >/dev/null
for i in {2..5}; do mapo pane split right --workspace One >/dev/null; done
mapo workspace new Two >/dev/null
mapo tab new --workspace Two --name t1 >/dev/null
for i in {2..5}; do mapo pane split right --workspace Two >/dev/null; done
mapo workspace new Three >/dev/null
for i in {1..10}; do mapo tab new --workspace Three --name h$i >/dev/null; done
for ws in One Two Three; do
    for t in $(mapo tab list --workspace $ws | jq -r '.[].name'); do mapo tab wait $t --workspace $ws --until idle --timeout-ms 15000 >/dev/null; done
done
mapo rpc state.snapshot | expect_json '.tabs | length' 20
for ws in One Two; do
    for t in $(mapo tab list --workspace $ws | jq -r '.[].name'); do mapo tab send $t --workspace $ws 'seq 1 2000' >/dev/null; done
done
mapo tab wait terminal-1 --workspace One --until 2000 --timeout-ms 10000 >/dev/null || true

step "Workspace switch: p95 of 20 (budget 50 ms)"
mapo rpc workspace.activate "{\"workspace\":\"$(mapo workspace list | jq -r '.[] | select(.name=="One") | .id')\"}" >/dev/null
sleep 0.5
mapo ui metrics --reset >/dev/null
for _ in {1..10}; do mapo ui key ctrl+cmd+down >/dev/null; sleep 0.15; mapo ui key ctrl+cmd+up >/dev/null; sleep 0.15; done
p95=$(metric '[.navigation[] | select(.name == "workspace.switch") | .ms] | sort | .[((length * 0.95) | floor) - 1] | floor')
_drive_record_timing workspace.switch.p95 "$p95"

step "Cold launch with the daemon running: median of 5 (budget 400 ms)"
launches=()
for _ in {1..5}; do
    app=$DRIVE_APP_PID
    kill -TERM $app 2>/dev/null || true
    for _ in {1..100}; do kill -0 $app 2>/dev/null || break; sleep 0.05; done
    DRIVE_APP_PID=0
    _drive_start_app_impl
    mapo ui wait 'pane.terminal:terminal-1' --timeout-ms 5000 >/dev/null || true
    launches+=$(metric '.launch.processStartToFirstFrameMs | floor')
done
_drive_record_timing launch.median "$(print -l $launches | median)"

step "Reattach after a daemon restart (budget 150 ms for 10 tabs)"
mapo instance stop >/dev/null
DRIVE_DAEMON_PID=$(mapo daemon | jq -r .pid)
wait_app 10000
sleep 1
_drive_record_timing app.reattach "$(metric '[.navigation[]? | select(.name == "app.reattach") | .ms] | last // -1 | floor')"
_drive_record_timing attach.last "$(metric '.attach.lastMs // -1')"

step "Idle CPU over 30 s and memory, 20 tabs with 10 visible"
for ws in One Two Three; do
    for t in $(mapo tab list --workspace $ws | jq -r '.[].name'); do mapo tab wait $t --workspace $ws --until idle --timeout-ms 15000 >/dev/null; done
done
sleep 5
mapo debug stats --interval-ms 30000 > "$DRIVE_TMP/idle.json"
cp "$DRIVE_TMP/idle.json" "$EVIDENCE/idle-stats.json"
_drive_record_timing idle.cpu.daemon.permille "$(jq '(.daemon.cpuPercent * 10) | floor' "$DRIVE_TMP/idle.json")"
_drive_record_timing idle.cpu.app.permille "$(jq '(.app.cpuPercent * 10) | floor' "$DRIVE_TMP/idle.json")"
_drive_record_timing footprint.daemon.mb "$(jq '(.daemon.footprintBytes / 1048576) | floor' "$DRIVE_TMP/idle.json")"
_drive_record_timing footprint.app.mb "$(jq '(.app.footprintBytes / 1048576) | floor' "$DRIVE_TMP/idle.json")"
jq '.daemon.footprintBytes < 150*1048576 and .app.footprintBytes < 250*1048576' "$DRIVE_TMP/idle.json" | expect_json . true

drive_end
