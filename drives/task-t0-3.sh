#!/usr/bin/env zsh
# task-t0-3: one daemon per instance that speaks the handshake and starts, answers and stops safely.
set -euo pipefail
source "${0:A:h}/lib.sh"
DRIVE_NO_APP=1

drive_begin task-t0-3
RUN=$("$MAPO_BIN" --instance "$DRIVE_INSTANCE" instance show --json | jq -r .runtimeDir)
DATA=$("$MAPO_BIN" --instance "$DRIVE_INSTANCE" instance show --json | jq -r .dataDir)

step "The daemon answers ping and instance.info"
mapo instance wait --timeout-ms 5000
mapo rpc ping | expect_json '(.bootId | length > 0) and .uptimeMs >= 0' true
mapo rpc instance.info | expect_json '[.instance, .daemonPid, .protocol]' "[\"$DRIVE_INSTANCE\",$DRIVE_DAEMON_PID,1]"
mapo instance show | expect_json '[.daemon.running, .daemon.protocol]' '[true,1]'

step "A second daemon refuses; detached start returns the running one"
rc=0; "$MAPO_BIN" --instance "$DRIVE_INSTANCE" daemon --foreground 2> "$DRIVE_TMP/second.err" || rc=$?
print -r -- "{\"rc\":$rc}" | expect_json .rc 1
jq -c '.error | test("already served by pid [0-9]+")' "$DRIVE_TMP/second.err" | expect_json . true
mapo daemon | expect_json .pid "$DRIVE_DAEMON_PID"

step "The socket is private and requests are validated"
stat -f '{"mode":"%Lp"}' "$RUN/$DRIVE_INSTANCE.sock" | expect_json .mode '"600"'
rc=0; mapo rpc ping '{"bogus":1}' 2> "$DRIVE_TMP/bogus.err" || rc=$?
print -r -- "{\"rc\":$rc}" | expect_json .rc 2
jq -c .kind "$DRIVE_TMP/bogus.err" | expect_json . '"invalid_argument"'
printf '{"jsonrpc":"2.0","id":1,"method":"ping","params":{}}\n' | nc -U "$RUN/$DRIVE_INSTANCE.sock" |
    expect_json '.error.message | startswith("hello required")' true

step "Stats report the daemon's footprint and near-zero idle CPU"
mapo debug stats --interval-ms 2000 > "$DRIVE_TMP/stats.json"
expect_json '.daemon.footprintBytes > 0' true < "$DRIVE_TMP/stats.json"
expect_json '.daemon.cpuPercent < 0.5' true < "$DRIVE_TMP/stats.json"
_drive_record_timing daemon-footprint-kb $(( $(jq .daemon.footprintBytes "$DRIVE_TMP/stats.json") / 1024 ))

step "Stop removes the socket and pid file, and no token reaches the logs"
T=$(cat "$DATA/app.token")
timing instance-stop mapo instance stop
DRIVE_DAEMON_PID=0
print -r -- "{\"sock\":$([[ -e $RUN/$DRIVE_INSTANCE.sock ]] && print true || print false),\"pid\":$([[ -e $RUN/$DRIVE_INSTANCE.pid ]] && print true || print false)}" |
    expect_json '[.sock, .pid]' '[false,false]'
leaked=$( { grep -rlFf <(printf "%s\n" "$T") "$DATA/logs" || true; } | wc -l | tr -d " ")
print -r -- "{\"n\":$leaked}" | expect_json .n 0

drive_end
