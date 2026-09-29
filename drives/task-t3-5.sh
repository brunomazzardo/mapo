#!/usr/bin/env zsh
# task-t3-5: `mapo mcp` (PLAN T3.5, PROTOCOL §10). JSON-RPC lines are piped into `mapo mcp` inside
# a tab, so it runs with that tab's MAPO_TOKEN; outside a tab it must refuse. No real Claude runs.
set -euo pipefail
source "${0:A:h}/lib.sh"
DRIVE_NO_APP=1

drive_begin task-t3-5
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"drive","version":"0"}}}'
# mcp NAME LINE...: pipes the lines into `mapo mcp` in tab t; responses land in $DRIVE_TMP/NAME.jsonl.
mcp() {
    local name=$1; shift
    local quoted=() l
    for l in "$@"; do quoted+=("'$l'"); done
    mapo tab run t "printf '%s\\n' ${(j: :)quoted} | mapo mcp > $DRIVE_TMP/$name.jsonl"
}
resp() { jq -s -c --argjson id $2 ".[] | select(.id == \$id) | $3" "$DRIVE_TMP/$1.jsonl" }

step "initialize, tools/list and tools/call mapo_tab_list inside a tab"
mapo workspace new >/dev/null
mapo tab new --name t >/dev/null
mapo tab wait t --until idle --timeout-ms 8000 >/dev/null
mcp list "$INIT" \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"mapo_tab_list","arguments":{}}}' \
    | expect_json .exitCode 0
resp list 1 '.result.serverInfo.name' | expect_json . '"mapo"'
resp list 2 '.result.tools | length' | expect_json . 32
resp list 2 '[.result.tools[] | select(.inputSchema.additionalProperties != false or (.description | length) >= 2048 or (.name | test("^mapo_(ui|app|hook|daemon)_") ))] | length' | expect_json . 0
resp list 2 '[.result.tools[].name] | index("mapo_events_wait") != null and index("mapo_tab_ask") != null' | expect_json . true
resp list 3 '[.result.isError, [.result.structuredContent.result[].name]]' | expect_json . '[false,["t"]]'
resp list 3 '.result.content[0].text | fromjson | .[0].name' | expect_json . '"t"'

step "mapo://skill serves the skill, and failures set isError"
mcp misc "$INIT" \
    '{"jsonrpc":"2.0","id":2,"method":"resources/list"}' \
    '{"jsonrpc":"2.0","id":3,"method":"resources/read","params":{"uri":"mapo://skill"}}' \
    '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"mapo_tab_focus","arguments":{"tab":"nope"}}}' \
    '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"mapo_tab_list","arguments":{"bogus":1}}}' \
    '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"mapo_status","arguments":{"tab":"t"}}}' \
    | expect_json .exitCode 0
resp misc 2 '[.result.resources[].uri]' | expect_json . '["mapo://skill"]'
resp misc 3 '.result.contents[0].text' | jq -j . > "$DRIVE_TMP/skill.md"
same=false; cmp -s "$MAPO_ROOT/plugin/skills/mapo/SKILL.md" "$DRIVE_TMP/skill.md" && same=true
print $same | expect_json . true
resp misc 4 '[.result.isError, (.result.content[0].text | fromjson | .kind)]' | expect_json . '[true,"not_found"]'
resp misc 5 '[.result.isError, (.result.content[0].text | fromjson | .kind)]' | expect_json . '[true,"invalid_argument"]'
resp misc 6 '.result.structuredContent.result.name' | expect_json . '"t"'

step "Closing stdin cancels an outstanding wait and exits 0"
mcp wait "$INIT" \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"mapo_tab_wait","arguments":{"tab":"t","until":{"pattern":"NEVER_PRINTED_42"}}}}' \
    | expect_json '[.exitCode, .durationMs < 3000]' '[0,true]'
resp wait 2 '[.result.isError, (.result.content[0].text | fromjson | .kind)]' | expect_json . '[true,"cancelled"]'

step "Outside a tab, mapo mcp exits 1 and never uses the app token"
rc=0; env -u MAPO_TOKEN -u MAPO_INSTANCE "$MAPO_BIN" --instance "$DRIVE_INSTANCE" mcp </dev/null 2>"$DRIVE_TMP/err.txt" || rc=$?
print $rc | expect_json . 1
jq -c '[.kind, (.error | contains("MAPO_TOKEN"))]' "$DRIVE_TMP/err.txt" | expect_json . '["forbidden",true]'

step "MCP calls land in the activity log as the tab"
mcp act "$INIT" \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"mapo_tab_rename","arguments":{"tab":"t","name":"t2"}}}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"mapo_tab_rename","arguments":{"tab":"t2","name":"t"}}}' \
    >/dev/null
mapo activity --limit 5 | expect_json '[.[] | select(.command == "tab.rename") | .caller.kind] | unique' '["tab"]'

drive_end
