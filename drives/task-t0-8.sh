#!/usr/bin/env zsh
# task-t0-8: every visible tab renders in a terminal surface whose process is `mapo attach`, with
# keyboard, resizing and ⌘ chords reaching the menu. SwiftTerm engine tonight (see PROGRESS).
set -euo pipefail
source "${0:A:h}/lib.sh"

drive_begin task-t0-8

step "A tab gets a focused surface running mapo attach"
mapo workspace new >/dev/null
mapo tab new --name g1 --cwd /usr/bin --focus >/dev/null
mapo ui wait pane.terminal:g1 --state focused --timeout-ms 5000 >/dev/null
mapo tab wait g1 --until idle --timeout-ms 5000 >/dev/null
pgrep -f "Helpers/mapo attach --tab .* --instance $DRIVE_INSTANCE\$" | wc -l | tr -d ' ' | jq -R '{n: tonumber}' | expect_json .n 1

step "Typing into the surface reaches the shell"
mapo tab wait g1 --until surface-42 --timeout-ms 5000 >/dev/null &
waiter=$!
mapo ui type 'echo surface-$((6*7))' >/dev/null
mapo ui key return >/dev/null
wait $waiter
mapo tab send g1 'printf "\e[1;31mred\e[0m\n"' >/dev/null
mapo tab wait g1 --until idle --timeout-ms 5000 >/dev/null
ui_snapshot color; ui_shot color
expect_json '[.terminals[].text | contains("surface-42")] | any' true < "$SNAP"

step "Resizing the pane reaches the PTY"
if [[ $(mapo ui window | jq -r .occluded) == true ]]; then
    # AppKit doesn't finish the inspector animation for an occluded window (display asleep).
    print "   NOT VERIFIED: the window is occluded, so the inspector toggle can't resize the pane"
else
    A=$(mapo tab run g1 'stty size' | jq -r .output)
    mapo ui key cmd+alt+0 >/dev/null
    sleep 0.5
    B=$(mapo tab run g1 'stty size' | jq -r .output)
    mapo ui key cmd+alt+0 >/dev/null
    print -r -- "{\"a\":\"$A\",\"b\":\"$B\"}" | expect_json '.a != .b' true
fi

step "⌘T goes to the menu, not the terminal"
n=$(mapo tab list | jq length)
mapo ui key cmd+t >/dev/null
mapo ui wait pane.terminal:terminal-1 --state focused --timeout-ms 3000 >/dev/null
mapo tab list | expect_json length $(( n + 1 ))

step "vim survives quitting and relaunching the app"
mapo tab focus g1 >/dev/null
mapo ui wait pane.terminal:g1 --state focused --timeout-ms 3000 >/dev/null
mapo tab send g1 "vim -u NONE -N $DRIVE_TMP/notes.txt" >/dev/null
mapo tab wait g1 --until notes.txt --timeout-ms 5000 >/dev/null
mapo ui type 'ihello vim' >/dev/null
mapo ui key escape >/dev/null
app=$DRIVE_APP_PID
mapo ui key cmd+q >/dev/null || true
for _ in {1..100}; do kill -0 $app 2>/dev/null || break; sleep 0.05; done
DRIVE_APP_PID=0
_drive_start_app_impl
mapo ui wait pane.terminal:g1 --timeout-ms 5000 >/dev/null
sleep 0.5
ui_snapshot vim-relaunch; ui_shot vim-relaunch
mapo tab read g1 | expect_json '[.altScreen, (.text | contains("hello vim"))]' '[true,true]'
expect_json '[.terminals[].text | contains("hello vim")] | any' true < "$SNAP"

step "Leaving vim gives a clean prompt with no stray query replies"
mapo ui focus pane.terminal:g1 >/dev/null
mapo ui type ':q!' >/dev/null
mapo ui key return >/dev/null
mapo tab wait g1 --until idle --timeout-ms 5000 >/dev/null
mapo tab read g1 | jq -r '.text' > "$DRIVE_TMP/after-vim.txt"
grep -cE '\^\[\[|[0-9]+;[0-9]+R' "$DRIVE_TMP/after-vim.txt" | jq -R '{n: tonumber}' | expect_json .n 0 || true

drive_end
