#!/usr/bin/env zsh
# task-t1-4: one status vocabulary for long shell commands, stops and exited shells (R-ST-1,
# R-TAB-11, R-TAB-12). Long commands run in parallel so the drive takes about 40 s.
set -euo pipefail
source "${0:A:h}/lib.sh"

drive_begin task-t1-4

step "Tabs in a background workspace"
mapo workspace new Bg >/dev/null
for t in h g q v s; do mapo tab new --workspace Bg --name $t >/dev/null; done
for t in h g q v s; do mapo tab wait $t --workspace Bg --until idle --timeout-ms 8000 >/dev/null; done
mapo workspace new Front >/dev/null
mapo tab new --workspace Front --name f --focus >/dev/null
mapo ui wait pane.terminal:f --state focused --timeout-ms 5000 >/dev/null || true

step "Long unviewed commands become failed or done; short ones don't"
mapo tab send h --workspace Bg 'sleep 31; false' >/dev/null
mapo tab send g --workspace Bg 'sleep 31; true' >/dev/null
mapo tab send q --workspace Bg 'sleep 2; false' >/dev/null
mapo tab wait h --workspace Bg --until idle --timeout-ms 40000 >/dev/null
mapo tab wait g --workspace Bg --until idle --timeout-ms 10000 >/dev/null
mapo tab list --workspace Bg | expect_json '[.[] | select(.name=="h" or .name=="g" or .name=="q") | [.name, .state, .stateDetail]]' '[["h","failed","exit 1"],["g","done",null],["q","idle",null]]'
ui_snapshot states
# Inactive workspaces are one collapsed row whose state is its most urgent tab's.
expect_json '[.model.rail[]? | select(.kind=="workspace" and .name=="Bg") | .state] | first' '"failed"' < "$SNAP"
mapo workspace list | expect_json '.[] | select(.name=="Bg") | .state' '"failed"'

step "Focusing keeps failed; the next command clears it"
mapo tab focus h --workspace Bg >/dev/null
mapo tab list --workspace Bg | expect_json '.[] | select(.name=="h") | .state' '"failed"'
mapo tab send h --workspace Bg true >/dev/null
mapo tab wait h --workspace Bg --until idle --timeout-ms 5000 >/dev/null
mapo tab list --workspace Bg | expect_json '.[] | select(.name=="h") | .state' '"idle"'

step "Stop sends Ctrl-C"
mapo tab send v --workspace Bg 'sleep 100' >/dev/null
for _ in {1..40}; do mapo tab list --workspace Bg | jq -e '.[] | select(.name=="v") | .state == "running"' >/dev/null && break; sleep 0.05; done
mapo tab stop v --workspace Bg >/dev/null
mapo tab wait v --workspace Bg --until idle --timeout-ms 5000 >/dev/null
mapo tab list --workspace Bg | expect_json '.[] | select(.name=="v") | .lastExit.code' 130

step "An exited shell stops, then restarts in its folder"
mapo tab send s --workspace Bg 'cd /usr/bin; exit 3' >/dev/null
for _ in {1..40}; do mapo tab list --workspace Bg | jq -e '.[] | select(.name=="s") | .state == "stopped"' >/dev/null && break; sleep 0.05; done
mapo tab list --workspace Bg | expect_json '.[] | select(.name=="s") | [.state, .stateDetail]' '["stopped","exit 3"]'
mapo tab restart s --workspace Bg >/dev/null
mapo tab wait s --workspace Bg --until idle --timeout-ms 5000 >/dev/null
mapo tab run s --workspace Bg pwd | expect_json .output '"/usr/bin"'

drive_end
