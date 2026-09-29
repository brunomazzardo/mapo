#!/usr/bin/env zsh
# task-t1-7: the ⌘K palette. ⌘K opens it with the field focused (palette.open in ui.metrics), typing
# fuzzy-filters tabs of every workspace, workspaces and commands, Return runs the row and focuses its tab,
# Esc closes it and gives focus back, and a query with no match says so.
set -euo pipefail
source "${0:A:h}/lib.sh"

drive_begin task-t1-7

rows() { jq -c '[.tree | .. | objects | select((.id // "") | startswith("palette.row:")) | .label]' "$SNAP"; }
open_palette() {
    mapo ui key cmd+k >/dev/null
    mapo ui wait palette.field --state focused --timeout-ms 2000 >/dev/null
}
# wait_row0 TEXT: until palette.row:0's label starts with TEXT.
wait_row0() {
    local i
    for i in {1..40}; do
        mapo ui tree --depth 24 | jq -e --arg t "$1" \
            '[.. | objects | select(.id? == "palette.row:0") | .label | startswith($t)] | any' >/dev/null && return 0
        sleep 0.05
    done
    return 0
}

step "Setup: Workspace 1 with terminal-1 and cli, and a workspace Other with api-server"
mapo ui key cmd+shift+n >/dev/null
mapo ui wait 'pane.terminal:terminal-1' --state focused --timeout-ms 3000 >/dev/null
mapo tab new --name cli >/dev/null
mapo workspace new Other >/dev/null
mapo tab new --workspace Other --name api-server >/dev/null
mapo rpc state.snapshot | jq -c '[.tabs[].name] | sort' | expect_json . '["api-server","cli","terminal-1"]'

step "⌘K opens the palette with its field focused, within budget"
mapo ui metrics --reset >/dev/null
timing palette-key-wait open_palette
ui_snapshot open; ui_shot open
expect_json '.focus.id' '"palette.field"' < "$SNAP"
jq -c '[.tree | .. | objects | select(.id? == "palette") | .role]' "$SNAP" | expect_json . '["window"]'
# An empty query lists the active workspace's tabs, then workspaces.
rows | expect_json '[.[] | split(", ")[1]]' '["Tabs","Tabs","Workspaces","Workspaces"]'
rows | expect_json '[.[2], .[3]]' '["Workspace 1, Workspaces","Other, Workspaces"]'
jq '.model.view.palette' "$SNAP" | expect_json . true
ms=$(mapo ui metrics | jq '[.navigation[] | select(.name=="palette.open") | .ms] | max // empty | floor')
print -r -- "${ms:-null}" | expect_json '. != null' true
_drive_record_timing palette.open "${ms:-0}"
mapo ui tree --depth 24 | jq '[.. | objects | select(.role? as $r | ["button","checkBox","radioButton",
    "popUpButton","menuButton","textField","textArea","row","link","slider","splitter"] | index($r))
    | select(.id == null)] | length' | expect_json . 0

step "Typing cli puts the cli tab first; Return focuses it and closes the palette"
mapo ui type cli >/dev/null
wait_row0 cli
ui_snapshot typed; ui_shot typed
jq -r '.tree | .. | objects | select(.id? == "palette.row:0") | .label' "$SNAP" | jq -Rc . | expect_json 'contains("cli")' true
expect_json '.focus.id' '"palette.field"' < "$SNAP"
mapo ui key return >/dev/null
mapo ui wait palette --state gone --timeout-ms 2000 >/dev/null
mapo ui wait 'pane.terminal:cli' --state focused --timeout-ms 3000 >/dev/null
ui_snapshot ran
expect_json '.focus.id' '"pane.terminal:cli"' < "$SNAP"
jq '.model.view.palette' "$SNAP" | expect_json . false

step "⌘K then Esc closes the palette and gives focus back"
open_palette
mapo ui key escape >/dev/null
mapo ui wait palette --state gone --timeout-ms 2000 >/dev/null
ui_snapshot escape
expect_json '.focus.id' '"pane.terminal:cli"' < "$SNAP"
# A second ⌘K closes it too.
open_palette
mapo ui key cmd+k >/dev/null
mapo ui wait palette --state gone --timeout-ms 2000 >/dev/null
mapo ui snapshot | expect_json '.focus.id' '"pane.terminal:cli"'

step "A tab in another workspace: Return activates Other and focuses api-server"
open_palette
mapo ui type api >/dev/null
wait_row0 api-server
ui_snapshot other
jq -r '.tree | .. | objects | select(.id? == "palette.row:0") | .label' "$SNAP" | jq -Rc . |
    expect_json . '"api-server, Tabs"'
# Arrows move the selection and wrap; down then up is back on the first row.
mapo ui key down >/dev/null
mapo ui key up >/dev/null
mapo ui key return >/dev/null
mapo ui wait 'pane.terminal:api-server' --state focused --timeout-ms 3000 >/dev/null
other=$(mapo workspace list | jq -r '.[] | select(.name=="Other") | .id')
mapo ui snapshot | expect_json '.model.workspaceId' "\"$other\""

step "Commands: >split right runs Split Right"
open_palette
mapo ui type '>split right' >/dev/null
wait_row0 'Split Right'
ui_snapshot command
jq -r '.tree | .. | objects | select(.id? == "palette.row:0") | .label' "$SNAP" | jq -Rc . |
    expect_json . '"Split Right, Commands, ⌘D"'
mapo ui key return >/dev/null
mapo ui wait palette --state gone --timeout-ms 2000 >/dev/null
for _ in {1..40}; do
    [[ $(mapo rpc layout.get | jq '[.. | objects | select(.kind=="pane")] | length') == 2 ]] && break
    sleep 0.05
done
mapo rpc layout.get | jq '[.. | objects | select(.kind=="pane")] | length' | expect_json . 2

step "A workspace row activates it; a query with no match says so"
open_palette
mapo ui type 'workspace 1' >/dev/null
wait_row0 'Workspace 1'
mapo ui key return >/dev/null
mapo ui wait palette --state gone --timeout-ms 2000 >/dev/null
ws1=$(mapo workspace list | jq -r '.[] | select(.name=="Workspace 1") | .id')
for _ in {1..40}; do [[ $(mapo ui snapshot | jq -r .model.workspaceId) == "$ws1" ]] && break; sleep 0.05; done
mapo ui snapshot | expect_json '.model.workspaceId' "\"$ws1\""
open_palette
mapo ui type zzqxw >/dev/null
sleep 0.2
ui_snapshot nomatch; ui_shot nomatch
rows | expect_json . '[]'
jq '[.tree | .. | objects | select((.label // .value // "") | startswith("No matches for"))] | length > 0' "$SNAP" |
    expect_json . true
mapo ui key escape >/dev/null
mapo ui wait palette --state gone --timeout-ms 2000 >/dev/null

drive_end
