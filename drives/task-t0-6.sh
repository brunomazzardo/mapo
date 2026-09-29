#!/usr/bin/env zsh
# task-t0-6: any terminal can attach to a tab, see its screen and scrollback, type, resize, and
# ride out daemon restarts; programs never hang while nobody is attached.
set -euo pipefail
source "${0:A:h}/lib.sh"
DRIVE_NO_APP=1

drive_begin task-t0-6
attach() { env -u MAPO_TOKEN "$MAPO_BIN" --instance "$DRIVE_INSTANCE" attach "$@" }

step "Replay carries the tab's history"
mapo tab new --name t1 >/dev/null
mapo tab wait t1 --until idle --timeout-ms 5000 >/dev/null
mapo tab run t1 'echo MARK-$((40+2))' >/dev/null
timing attach-replay attach --tab t1 --replay-only > "$DRIVE_TMP/replay.bin"
grep -a -c MARK-42 "$DRIVE_TMP/replay.bin" | jq -R '{n: tonumber}' | expect_json '.n >= 1' true
head -c 2 "$DRIVE_TMP/replay.bin" | xxd -p | jq -R . | expect_json . '"1b63"'

step "Typing through an attached terminal reaches the shell"
(sleep 1; printf 'echo via-$((1+1))-attach\r'; sleep 1) | script -q /dev/null "$MAPO_BIN" --instance "$DRIVE_INSTANCE" attach --tab t1 >/dev/null 2>&1 &
sp=$!
mapo tab wait t1 --until via-2-attach --timeout-ms 5000 >/dev/null || true
kill $sp 2>/dev/null || true; wait $sp 2>/dev/null || true
mapo tab wait t1 --until idle --timeout-ms 5000 >/dev/null
mapo tab read t1 | expect_json '.text | contains("via-2-attach")' true

step "The attach size reaches the PTY"
attach --tab t1 --replay-only --size 100x30 >/dev/null
mapo tab run t1 'stty size' | expect_json .output '"30 100"'

step "With nothing attached, the daemon answers terminal queries"
mapo tab run t1 'printf "\e[6n" > /dev/tty; IFS= read -rs -t 2 -d R r < /dev/tty; echo "CPR=${r#*\[}"' |
    expect_json '.output | test("CPR=[0-9]+;[0-9]+")' true

step "An attached client reconnects across a daemon restart"
(sleep 6; printf 'echo after-$((1+1))-restart\r'; sleep 2) | script -q /dev/null "$MAPO_BIN" --instance "$DRIVE_INSTANCE" attach --tab t1 > "$EVIDENCE/attach.out" 2>&1 &
sp=$!
sleep 1
mapo instance stop
DRIVE_DAEMON_PID=$(mapo daemon | jq -r .pid)
mapo tab wait t1 --until after-2-restart --timeout-ms 12000 >/dev/null || true
kill $sp 2>/dev/null || true; wait $sp 2>/dev/null || true
mapo tab wait t1 --until idle --timeout-ms 5000 >/dev/null
grep -ac reconnecting "$EVIDENCE/attach.out" | jq -R '{n: tonumber}' | expect_json '.n >= 1' true
mapo tab read t1 | expect_json '.text | contains("after-2-restart")' true

step "Grid replay starts with a reset"
MAPO_REPLAY=grid attach --tab t1 --replay-only | head -c 2 | xxd -p | jq -R . | expect_json . '"1b63"'

step "Full-screen programs come back through replay"
mapo tab send t1 "vim -u NONE -N $DRIVE_TMP/notes.txt" >/dev/null
mapo tab wait t1 --until notes.txt --timeout-ms 5000 >/dev/null
mapo tab send t1 --no-execute 'ihello vim' >/dev/null
sleep 0.3
attach --tab t1 --replay-only --size 80x24 > "$DRIVE_TMP/vim.bin"
grep -ac 'hello vim' "$DRIVE_TMP/vim.bin" | jq -R '{n: tonumber}' | expect_json '.n >= 1' true
mapo tab read t1 | expect_json '[.altScreen, (.text | contains("hello vim"))]' '[true,true]'
mapo tab send t1 --no-execute $'\e:q!\r' >/dev/null
mapo tab wait t1 --until idle --timeout-ms 5000 >/dev/null
ps -ax -o command | grep -c "attach --tab t1 --instance $DRIVE_INSTANCE\|$DRIVE_INSTANCE attach" | jq -R '{n: tonumber}' | expect_json '.n <= 1' true

drive_end
