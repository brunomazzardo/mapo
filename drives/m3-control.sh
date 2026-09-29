#!/usr/bin/env zsh
# m3-control: the M3 gate (PLAN T3.7). A shell tab acts as an agent with its own MAPO_TOKEN: it
# creates tab B, runs a command, waits on output, reads the screen, hits a guard, retries with
# --force, and reads the activity log; then it lists tabs over MCP. No real Claude runs here.
set -euo pipefail
source "${0:A:h}/lib.sh"
DRIVE_NO_APP=1

drive_begin m3-control
# as_agent CMD: runs CMD inside tab A, so the CLI uses A's own credential, and prints its output.
as_agent() { mapo tab run A "$1" | jq -r .output }

step "An agent tab with its own credential"
mapo workspace new >/dev/null
mapo tab new --name A >/dev/null
mapo tab wait A --until idle --timeout-ms 8000 >/dev/null
as_agent 'mapo tab list --json | jq -c "[.[].name]"' | expect_json . '["A"]'

step "It creates tab B, runs a command, waits on output and reads the screen"
as_agent 'mapo tab new --name B --json >/dev/null && mapo tab wait B --until idle --timeout-ms 8000 --json >/dev/null && echo ready' | jq -R . | expect_json . '"ready"'
as_agent 'mapo tab run B "echo from-b-\$((6*7))" --json | jq -c "[.exitCode, .output]"' | expect_json . '[0,"from-b-42"]'
as_agent 'mapo tab send B "sleep 1; echo LATE-\$((1+1))" --json >/dev/null && mapo tab wait B --until LATE-2 --timeout-ms 5000 --json >/dev/null && echo waited' | jq -R . | expect_json . '"waited"'
as_agent 'mapo tab read B --json | jq -r ".text | contains(\"LATE-2\")"' | expect_json . true

step "A guard rejects closing another tab until --force"
as_agent 'mapo tab close B --json 2>&1 >/dev/null | jq -r .kind; true' | jq -R . | expect_json . '"forbidden"'
as_agent 'mapo tab close B --force --json | jq -r .closed' | expect_json . true

step "The activity log shows both, from tab A"
mapo activity | expect_json '[.[] | select(.command=="tab.close") | [.outcome, .caller.kind]]' '[["ok","tab"],["rejected","tab"]]'

step "MCP inside the tab lists the tabs"
as_agent 'printf "%s\n" "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"drive\",\"version\":\"1\"}}}" "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}" "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"mapo_tab_list\",\"arguments\":{}}}" | mapo mcp | tail -n 1 | jq -c "[.result.structuredContent.result[].name]"' |
    expect_json . '["A"]'
print "   SKIPPED: tab ask between two real Claude tabs, and Claude using the MCP tools (usage limit; see PROGRESS)"

drive_end
