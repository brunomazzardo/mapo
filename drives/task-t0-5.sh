#!/usr/bin/env zsh
# task-t0-5: every tab is a login shell owned by the daemon, with shell integration, a headless
# emulator, replayable history, and tab send/read/wait/run.
set -euo pipefail
source "${0:A:h}/lib.sh"
DRIVE_NO_APP=1

drive_begin task-t0-5
rp() { print -r -- "${1:A}" }

step "A tab reaches its prompt and runs commands"
mapo tab new --name t1 --cwd /usr/bin >/dev/null
timing tab-ready mapo tab wait t1 --until idle --timeout-ms 5000 >/dev/null
mapo tab run t1 'echo hi' | expect_json '[.exitCode, .output]' '[0,"hi"]'
rc=0; mapo tab run t1 'sh -c "exit 3"' >/dev/null || rc=$?
print -r -- "{\"rc\":$rc}" | expect_json .rc 3

step "The environment is Mapo's, with no leaked session markers"
mapo tab run t1 env | jq -r .output > "$DRIVE_TMP/env.txt"
grep -cE '^(MAPO_INSTANCE|MAPO_TAB_ID|MAPO_TOKEN|TERM_PROGRAM)=' "$DRIVE_TMP/env.txt" | jq -R '{n: tonumber}' | expect_json .n 4
grep -c '^CLAUDE' "$DRIVE_TMP/env.txt" | jq -R '{n: tonumber}' | expect_json .n 0 || true
grep -E '^MAPO_INSTANCE=' "$DRIVE_TMP/env.txt" | cut -d= -f2 | jq -R . | expect_json . "\"$DRIVE_INSTANCE\""
mapo tab run t1 'echo $PATH' | jq -r '.output | split(":")[0]' | jq -R . | expect_json 'endswith("target/debug") or endswith("Resources/bin")' true

step "cd reports the cwd through OSC 7"
mapo tab send t1 'cd /private/etc' >/dev/null
mapo tab wait t1 --until idle --timeout-ms 5000 >/dev/null
mapo tab list | expect_json '.[] | select(.name=="t1") | .cwd' '"/private/etc"'

step "Pattern waits see output, never the echo"
mapo tab send t1 'sleep 1; echo MARK-$((40+2))' >/dev/null
mapo tab wait t1 --until MARK-42 --timeout-ms 5000 >/dev/null
mapo tab send t1 'sleep 3 # ONLYECHO' >/dev/null
rc=0; mapo tab wait t1 --until ONLYECHO --timeout-ms 1500 2>/dev/null || rc=$?
print -r -- "{\"rc\":$rc}" | expect_json .rc 124
mapo tab wait t1 --until idle --timeout-ms 5000 >/dev/null
mapo tab read t1 | expect_json '.text | contains("MARK-42")' true

step "A missing folder fails the launch; focusing retries it"
mkdir -p "$DRIVE_TMP/t05"
mapo tab new --name bad --cwd "$DRIVE_TMP/t05/missing" >/dev/null
sleep 0.3
mapo tab list | expect_json '.[] | select(.name=="bad") | [.state, .launchError.kind]' '["failed","cwd_missing"]'
mkdir -p "$DRIVE_TMP/t05/missing"
mapo tab focus bad >/dev/null
mapo tab wait bad --until idle --timeout-ms 5000 >/dev/null
mapo tab list | expect_json '.[] | select(.name=="bad") | .state' '"idle"'

step "exit 0 closes the tab; exit 3 leaves it stopped"
mapo tab new --name x0 >/dev/null; mapo tab wait x0 --until idle --timeout-ms 5000 >/dev/null
mapo tab send x0 exit >/dev/null
mapo tab new --name x3 >/dev/null; mapo tab wait x3 --until idle --timeout-ms 5000 >/dev/null
mapo tab send x3 'exit 3' >/dev/null
for _ in {1..40}; do mapo tab list | jq -e '(map(.name) | index("x0") | not) and (.[] | select(.name=="x3") | .state == "stopped")' >/dev/null && break; sleep 0.1; done
mapo tab list | expect_json '[(map(.name) | index("x0")), (.[] | select(.name=="x3") | [.state, .lastExit.code])]' '[null,["stopped",3]]'

step "Closing a busy tab needs --force, and the shell goes away"
mapo tab send t1 'sleep 30' >/dev/null
for _ in {1..40}; do mapo tab list | jq -e '.[] | select(.name=="t1") | .state == "running"' >/dev/null && break; sleep 0.05; done
rc=0; mapo tab close t1 2>/dev/null || rc=$?
print -r -- "{\"rc\":$rc}" | expect_json .rc 1
mapo tab close t1 --force | expect_json .closed true

step "A daemon restart brings tabs back in their folders, nothing replayed"
mapo tab new --name keep --cwd "$DRIVE_TMP" >/dev/null
mapo tab wait keep --until idle --timeout-ms 5000 >/dev/null
mapo instance stop
DRIVE_DAEMON_PID=$(mapo daemon | jq -r .pid)
mapo tab wait keep --until idle --timeout-ms 8000 >/dev/null
mapo tab run keep pwd | jq -c .output | expect_json . "\"$(rp $DRIVE_TMP)\""
mapo tab list | expect_json 'map(.name) | sort' '["bad","keep","x3"]'

step "A flood of output keeps the daemon bounded and responsive"
mapo tab send keep 'head -c 3000000 /dev/urandom | base64; echo FLOOD-DONE' >/dev/null
mapo tab wait keep --until FLOOD-DONE --timeout-ms 30000 >/dev/null
mapo tab wait keep --until idle --timeout-ms 10000 >/dev/null
timing tab-read mapo tab read keep >/dev/null
mapo debug stats > "$DRIVE_TMP/stats.json"
_drive_record_timing daemon-footprint-kb $(( $(jq .daemon.footprintBytes "$DRIVE_TMP/stats.json") / 1024 ))
jq '.daemon.footprintBytes < 150000000' "$DRIVE_TMP/stats.json" | expect_json . true

drive_end
