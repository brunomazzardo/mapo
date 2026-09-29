#!/usr/bin/env zsh
# task-t4-1: tabs that listen on TCP are servers, detected from events (PLAN T4.1), and ports map
# to tabs with a guarded stop (T4.2). Daemon only.
set -euo pipefail
source "${0:A:h}/lib.sh"
DRIVE_NO_APP=1

drive_begin task-t4-1
srv() { mapo tab list | jq -c '.[] | select(.name=="srv")' }
poll() { local f=$1 want=$2 i; for i in {1..40}; do [[ $(srv | jq -c "$f") == "$want" ]] && break; sleep 0.1; done; srv | expect_json "$f" "$want" }

step "A listening command labels its tab as a server within 2 s"
mapo tab new --name srv >/dev/null
mapo tab wait srv --until idle --timeout-ms 8000 >/dev/null
mapo tab send srv 'nc -l 4173' >/dev/null
timing server-detect poll '.server.ports' '[4173]'

step "Ports map listeners to tabs; stop re-checks identity and refuses Mapo"
mapo ports --port 4173 | expect_json '.[0] | [.port, .name, (.tabId != null)]' '[4173,"nc",true]'
PID=$(mapo ports --port 4173 | jq -r '.[0].pid'); ID=$(mapo ports --port 4173 | jq -r '.[0].identity')
rc=0; mapo process stop $PID --identity 0000000000000000 2>/dev/null >/dev/null || rc=$?
print -r -- "{\"rc\":$rc}" | expect_json .rc 1
rc=0; mapo process stop $(mapo instance show | jq .daemon.pid) --identity x 2> "$DRIVE_TMP/self.err" >/dev/null || rc=$?
jq -c .kind "$DRIVE_TMP/self.err" | expect_json . '"forbidden"'
mapo process stop $PID --identity $ID | expect_json .signalSent '"SIGTERM"'
poll '.server' 'null'
poll '.state' '"idle"'

step "Stop (Ctrl-C) ends a server without marking it failed"
mapo tab send srv 'nc -l 4175' >/dev/null
poll '.server.ports' '[4175]'
mapo tab stop srv >/dev/null
poll '[.server, .state]' '[null,"idle"]'

step "A server that exits non-zero is failed with its code"
mapo tab send srv 'sh -c "nc -l 4174 & sleep 2; kill %1 2>/dev/null; exit 3"' >/dev/null
poll '.server.ports' '[4174]'
poll '[.state, .stateDetail]' '["failed","exit 3"]'

drive_end
