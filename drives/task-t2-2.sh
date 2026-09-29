#!/usr/bin/env zsh
# task-t2-2: the synthetic Claude path (PLAN T2.1, T2.2, T2.3, T2.5). Hook fixtures go through
# `mapo hook` inside a tab into the agent status machine; no real Claude runs here.
set -euo pipefail
source "${0:A:h}/lib.sh"
DRIVE_NO_APP=1

drive_begin task-t2-2
F="$MAPO_ROOT/crates/mapo-agent/fixtures"
st() { mapo tab list | jq -c --arg n "$1" '[.[] | select(.name==$n) | .state, .stateLabel, .stateDetail]' }
hook() { mapo tab run "$1" "mapo hook < $F/$2.json" >/dev/null }

step "Every tab loads Mapo's plugin"
mapo workspace new >/dev/null
mapo tab new --name ag >/dev/null
mapo tab new --name other >/dev/null
mapo tab wait ag --until idle --timeout-ms 8000 >/dev/null
mapo tab wait other --until idle --timeout-ms 8000 >/dev/null
mapo tab run ag 'echo $CLAUDE_CODE_PLUGIN_DIRS' | expect_json '.output | endswith("/plugin")' true
jq -e '.hooks | keys | length == 10' "$MAPO_ROOT/plugin/hooks/hooks.json" | expect_json . true

step "Hook events drive the agent status (R-AG-3)"
hook ag 01-SessionStart;       st ag | expect_json . '["idle","",null]'
hook ag 02-UserPromptSubmit;   st ag | expect_json . '["running","Working",null]'
hook ag 03-PermissionRequest;  st ag | expect_json . '["needs-you","Needs you","Approve: pnpm db:migrate"]'
mapo events --after 0 | jq -s -c '[.[] | select(.type=="attention.changed") | .data.count] | last' | expect_json . 1
hook ag 04-PostToolBatch;      st ag | expect_json . '["running","Working",null]'
hook ag 05-SubagentStart
hook ag 06-Stop-with-subagent; st ag | expect_json . '["running","Working",null]'
hook ag 07-SubagentStop;       st ag | expect_json . '["done","Done",null]'
hook ag 09-Notification-idle;  st ag | expect_json '.[0]' '"done"'
mapo tab list | expect_json '.[] | select(.name=="ag") | [.statusSource, .agent.hooksConnected, .agent.sessionId]' '["hooks",true,"0199aaaa-0000-7000-8000-000000000001"]'

step "A hook token is bound to its own tab"
B=$(mapo tab list | jq -r '.[] | select(.name=="other") | .id')
mapo tab run ag "MAPO_TAB_ID=$B mapo hook < $F/03-PermissionRequest.json" >/dev/null
st other | expect_json '.[0]' '"idle"'

step "Interrupt ignores late events until the next prompt"
hook ag 02-UserPromptSubmit
mapo tab interrupt ag | expect_json '[.state, .agent.interrupted]' '["idle",true]'
# No real agent reads the Escape here, so zsh's line editor got it: Ctrl-C gives a clean prompt.
mapo tab send ag --no-execute $'\x03' >/dev/null
sleep 0.3
hook ag 10-Stop;               st ag | expect_json '.[0]' '"idle"'
hook ag 02-UserPromptSubmit;   st ag | expect_json '.[0]' '"running"'

step "Agent tabs run the workspace's agent command and resume after a daemon restart"
mapo workspace configure 'Workspace 1' --agent-command 'echo fakeagent' | expect_json .agentCommand '"echo fakeagent"'
mapo tab new --name bot --kind agent >/dev/null
mapo tab wait bot --until idle --timeout-ms 8000 >/dev/null
mapo tab read bot | expect_json '.text | contains("fakeagent")' true
hook bot 01-SessionStart
mapo instance stop
DRIVE_DAEMON_PID=$(mapo daemon | jq -r .pid)
mapo tab wait bot --until idle --timeout-ms 8000 >/dev/null
mapo tab read bot | expect_json '.text | contains("fakeagent --resume 0199aaaa-0000-7000-8000-000000000001")' true

drive_end
