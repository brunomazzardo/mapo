#!/usr/bin/env zsh
# task-t1-6: clicking or opening a file shows it beside the terminal in a light native editor that
# never loses text (R-LAY-5, R-ED-1..6, contracts 2, 3 and 10).
set -euo pipefail
source "${0:A:h}/lib.sh"

drive_begin task-t1-6
D="${DRIVE_TMP:A}/proj"
mkdir -p "$D"
printf 'struct A {}\n' > "$D/a.swift"
seq 1 2000 | sed 's/^/let line_/; s/$/ = 1/' > "$D/big.swift"
# A 1x1 PNG.
printf '\x89PNG\r\n\x1a\n\0\0\0\rIHDR\0\0\0\x01\0\0\0\x01\x08\x06\0\0\0\x1f\x15\xc4\x89\0\0\0\rIDATx\x9cc\xf8\x0f\0\0\x01\x01\0\x05\x18\xd8N\0\0\0\0IEND\xaeB`\x82' > "$D/logo.png"

focused() { mapo ui snapshot | jq -r .focus.id }
wait_focus() { local i; for i in {1..60}; do [[ $(focused) == "$1" ]] && return 0; sleep 0.05; done; return 0 }

step "A workspace with a shell"
mapo ui key cmd+shift+n >/dev/null
mapo ui wait 'pane.terminal:terminal-1' --state focused --timeout-ms 3000 >/dev/null
mapo tab wait terminal-1 --until idle --timeout-ms 5000 >/dev/null

step "file.open splits the file beside the terminal and focuses the editor"
mapo ui metrics --reset >/dev/null
mapo file open "$D/a.swift" | expect_json '.paneId | length > 0' true
wait_focus "editor:$D/a.swift"
focused | jq -R . | expect_json . "\"editor:$D/a.swift\""
mapo rpc layout.get | expect_json '[.. | objects | select(.kind? == "pane")] | length' 2

step "Typing and ⌘S save the file"
mapo ui key cmd+down >/dev/null
mapo ui type 'let answer = 42' >/dev/null
mapo ui key cmd+s >/dev/null
for _ in {1..40}; do grep -q 'let answer = 42' "$D/a.swift" && break; sleep 0.05; done
grep -c 'let answer = 42' "$D/a.swift" | jq -R '{n: tonumber}' | expect_json .n 1

step "Escape from Find and Go to Line keeps focus in the editor, not the terminal beside it"
sleep 2.1 # past the window in which a command's focus change is still expected
for key in cmd+f cmd+l; do
  mapo ui key $key >/dev/null
  sleep 0.3
  mapo ui key escape >/dev/null
  sleep 0.4
  focused | jq -R . | expect_json . "\"editor:$D/a.swift\""
done

step "Folders and broken links are rejected before any UI change"
B=$(mapo rpc layout.get)
rc=0; mapo file open "$D" 2>/dev/null >/dev/null || rc=$?
print -r -- "{\"rc\":$rc}" | expect_json .rc 1
ln -s "$D/nope" "$D/broken"
rc=0; mapo file open "$D/broken" 2>/dev/null >/dev/null || rc=$?
print -r -- "{\"rc\":$rc}" | expect_json .rc 1
[[ "$B" == "$(mapo rpc layout.get)" ]] && print '{"same":true}' | expect_json .same true || print '{"same":false}' | expect_json .same true

step "An image opens as a preview in the same file pane"
mapo file open "$D/logo.png" >/dev/null
for _ in {1..40}; do mapo ui tree --depth 30 | jq -e --arg p "pane.preview:$D/logo.png" '[.. | objects | select(.id? == $p)] | length > 0' >/dev/null && break; sleep 0.05; done
mapo ui tree --depth 30 | jq --arg p "pane.preview:$D/logo.png" '[.. | objects | select(.id? == $p)] | length' | expect_json . 1
mapo rpc layout.get | expect_json '[.. | objects | select(.kind? == "pane")] | length' 2

step "A 2,000-line file opens within budget"
mapo ui metrics --reset >/dev/null
mapo file open "$D/big.swift" >/dev/null
wait_focus "editor:$D/big.swift"
ms=$(mapo ui metrics | jq '[.navigation[]? | select(.name == "file.open") | .ms] | last // -1 | floor')
_drive_record_timing file.open "$ms"
print -r -- "{\"ms\":$ms}" | expect_json '.ms >= 0 and .ms <= 100' true

step "An external change reloads a clean buffer"
mapo file open "$D/a.swift" >/dev/null
wait_focus "editor:$D/a.swift"
echo '// changed outside' >> "$D/a.swift"
for _ in {1..60}; do mapo ui snapshot | jq -e --arg p "editor:$D/a.swift" '[.. | objects | select(.id? == $p) | .value // "" | contains("changed outside")] | any' >/dev/null && break; sleep 0.05; done
mapo ui snapshot | jq --arg p "editor:$D/a.swift" '[.. | objects | select(.id? == $p) | .value // "" | contains("changed outside")] | any' | expect_json . true

step "An external change to a dirty buffer asks keep-mine or reload"
mapo ui focus "editor:$D/a.swift" >/dev/null
mapo ui type '// unsaved' >/dev/null
echo '// second outside change' >> "$D/a.swift"
mapo ui wait "editor.keepMine:$D/a.swift" --timeout-ms 3000 >/dev/null
mapo ui wait "editor.reload:$D/a.swift" --timeout-ms 1000 >/dev/null
mapo ui click "editor.keepMine:$D/a.swift" >/dev/null

step "Unsaved text survives a workspace switch"
mapo workspace new Other >/dev/null
mapo ui key ctrl+cmd+down >/dev/null
sleep 0.3
mapo ui key ctrl+cmd+up >/dev/null
for _ in {1..40}; do mapo ui tree --depth 30 | jq -e --arg p "editor:$D/a.swift" '[.. | objects | select(.id? == $p)] | length > 0' >/dev/null && break; sleep 0.05; done
mapo ui snapshot | jq --arg p "editor:$D/a.swift" '[.. | objects | select(.id? == $p) | .value // "" | contains("// unsaved")] | any' | expect_json . true

drive_end
