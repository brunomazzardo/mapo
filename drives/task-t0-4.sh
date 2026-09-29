#!/usr/bin/env zsh
# task-t0-4: workspaces and tabs are daemon state that persists in SQLite and streams as events.
set -euo pipefail
source "${0:A:h}/lib.sh"
DRIVE_NO_APP=1

drive_begin task-t0-4

step "Create workspaces with default and given names"
mapo workspace new | expect_json .name '"Workspace 1"'
mapo workspace new Obsess | expect_json .name '"Obsess"'

step "Tabs: a labeled tab, a duplicate, and a missing one"
mapo tab new --workspace Obsess --name be --cwd /usr/bin | expect_json '[.labeled, .title, .cwd]' '[true,"be","/usr/bin"]'
mapo tab new --workspace Obsess | expect_json '[.name, .labeled]' '["terminal-1",false]'
rc=0; mapo tab new --workspace Obsess --name be 2> "$DRIVE_TMP/dup.err" || rc=$?
print -r -- "{\"rc\":$rc}" | expect_json .rc 1
jq -c .kind "$DRIVE_TMP/dup.err" | expect_json . '"conflict"'
rc=0; mapo tab focus nope --workspace Obsess 2> "$DRIVE_TMP/nope.err" || rc=$?
print -r -- "{\"rc\":$rc}" | expect_json .rc 1
jq -c '[.kind, (.error | contains("nope"))]' "$DRIVE_TMP/nope.err" | expect_json . '["not_found",true]'

step "Events are numbered in order and replayable"
mapo events --after 0 > "$DRIVE_TMP/events.ndjson"
jq -s -c 'map(.seq) == (map(.seq) | sort) and length >= 6' "$DRIVE_TMP/events.ndjson" | expect_json . true
jq -s -c 'map(.type) | index("tab.created") != null' "$DRIVE_TMP/events.ndjson" | expect_json . true

step "Focusing a tab activates its workspace and shows it"
mapo tab focus be --workspace Obsess | expect_json '[.visible, .name]' '[true,"be"]'
mapo rpc state.snapshot | expect_json '.activeWorkspaceId == (.workspaces[] | select(.name=="Obsess") | .id)' true

step "State survives a daemon restart"
mapo instance stop
DRIVE_DAEMON_PID=$(mapo daemon | jq -r .pid)
mapo workspace list | expect_json 'map(.name)' '["Workspace 1","Obsess"]'
mapo tab list --workspace Obsess | expect_json 'map(.name)' '["be","terminal-1"]'
mapo rpc state.snapshot | expect_json '.activeWorkspaceId == (.workspaces[] | select(.name=="Obsess") | .id)' true

step "Delete with --force"
mapo workspace delete Obsess --force | expect_json .deleted true
mapo workspace list | expect_json 'map(.name)' '["Workspace 1"]'

drive_end
