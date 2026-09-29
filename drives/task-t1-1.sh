#!/usr/bin/env zsh
# task-t1-1: the S2 rail (PLAN T1.1). Row heights, states and words, the inline branch, hold-⌘ hints,
# reorder that survives a daemon restart, inline rename, and background updates that leave focus alone.
set -euo pipefail
source "${0:A:h}/lib.sh"

drive_begin task-t1-1

# rail_poll FILTER [TIMEOUT_MS]: snapshots until FILTER holds, since the app applies the daemon's event a
# moment after the CLI returns. It never fails; the expect_json after it decides.
rail_poll() {
    local deadline=$(( EPOCHREALTIME + ${2:-3000} / 1000.0 ))
    while (( EPOCHREALTIME < deadline )); do
        mapo ui snapshot 2>/dev/null | jq -e "$1" >/dev/null 2>&1 && return 0
        sleep 0.1
    done
    return 0
}

rail_names() { print -r -- "[.model.rail[] | select(.kind==\"$1\") | .name]" }

step "Two workspaces: only the active one expands, rows are 26 and 24 pt"
mapo workspace new Mapo >/dev/null
mapo workspace new Obsess >/dev/null
mapo tab new --workspace Obsess --name o1 --cwd "$DRIVE_TMP" >/dev/null
mapo tab new --workspace Mapo --name t1 --cwd "$DRIVE_TMP" >/dev/null
mapo tab new --workspace Mapo --name t2 --cwd "$DRIVE_TMP" >/dev/null
mapo workspace activate Mapo >/dev/null
mapo ui wait 'rail.tab:Mapo/t2' --timeout-ms 3000 >/dev/null
mapo tab wait t1 --workspace Mapo --until idle --timeout-ms 5000 >/dev/null
mapo tab wait t2 --workspace Mapo --until idle --timeout-ms 5000 >/dev/null
rail_poll '[.model.rail[] | select(.kind=="tab") | .state] | all(. == "idle")'
ui_snapshot rows; ui_shot rows
expect_json '[.tree | .. | objects | select((.id // "") | startswith("rail.tab:")) | .frame.h] | all(. == 24)' true < "$SNAP"
expect_json '[.tree | .. | objects | select((.id // "") | test("^rail\\.workspace:")) | .frame.h] | all(. == 26)' true < "$SNAP"
expect_json '[.model.rail[] | select(.kind=="workspace") | [.name, .expanded]]' '[["Mapo",true],["Obsess",false]]' < "$SNAP"
expect_json "$(rail_names tab)" '["t1","t2"]' < "$SNAP"
expect_json '[.model.rail[] | select(.kind=="tab" and .state=="idle") | .accessory] | all(. == null)' true < "$SNAP"

step "A tab that can't start shows its word, and its AX value is the raw state"
mapo tab new --workspace Mapo --name bad --cwd /nonexistent/x >/dev/null 2>&1 || true
rail_poll '.model.rail[] | select(.kind=="tab" and .name=="bad") | .state == "failed"'
ui_snapshot failed; ui_shot failed
expect_json '.model.rail[] | select(.kind=="tab" and .name=="bad") | [.state, (.accessory | startswith("word:"))]' '["failed",true]' < "$SNAP"
expect_json '.tree | .. | objects | select(.id? == "rail.tab:Mapo/bad") | .value' '"failed"' < "$SNAP"
expect_json '.tree | .. | objects | select(.id? == "rail.tab:Mapo/bad") | .label | test("couldn.t start|failed")' true < "$SNAP"
expect_json '[.model.rail[] | select(.kind=="tab" and .state=="idle") | .accessory] | all(. == null)' true < "$SNAP"

step "The workspace row shows the branch of the shown tab's folder"
repo="$DRIVE_TMP/repo"
git init -q -b rail-branch "$repo"
mapo tab focus t1 --workspace Mapo >/dev/null
mapo tab send t1 --workspace Mapo "cd $repo" >/dev/null
mapo tab wait t1 --workspace Mapo --until idle --timeout-ms 5000 >/dev/null
rail_poll '.model.rail[] | select(.kind=="workspace" and .name=="Mapo") | .branch == "rail-branch"' 5000
ui_snapshot branch; ui_shot branch
expect_json '.model.rail[] | select(.kind=="workspace" and .name=="Mapo") | .branch' '"rail-branch"' < "$SNAP"
expect_json '.tree | .. | objects | select(.id? == "rail.workspace:Mapo") | .label | contains("branch rail-branch")' true < "$SNAP"

step "Holding ⌘ shows ⌘1 to ⌘9 on the active workspace's tabs; releasing hides them"
mapo ui key cmd --phase down >/dev/null
sleep 0.6
ui_snapshot hints; ui_shot hints
expect_json '[.model.rail[] | select(.kind=="tab") | .hint]' '["⌘1","⌘2","⌘3"]' < "$SNAP"
expect_json '[.tree | .. | objects | select((.id // "") | startswith("rail.tab:")) | .frame.h] | all(. == 24)' true < "$SNAP"
mapo ui key cmd --phase up >/dev/null
rail_poll '[.model.rail[] | select(.kind=="tab") | .hint] | all(. == null)'
ui_snapshot hints-up
expect_json '[.model.rail[] | select(.kind=="tab") | .hint] | all(. == null)' true < "$SNAP"

step "Reorder from the CLI shows in the rail and survives a daemon restart"
mapo workspace move Obsess --index 0 >/dev/null
mapo tab move t2 --workspace Mapo --index 0 >/dev/null
rail_poll "$(rail_names workspace) == [\"Obsess\",\"Mapo\"] and $(rail_names tab) == [\"t2\",\"t1\",\"bad\"]"
ui_snapshot reordered; ui_shot reordered
expect_json "$(rail_names workspace)" '["Obsess","Mapo"]' < "$SNAP"
expect_json "$(rail_names tab)" '["t2","t1","bad"]' < "$SNAP"
mapo instance stop >/dev/null
DRIVE_DAEMON_PID=$(mapo daemon | jq -r .pid)
timing daemon-reconnect wait_app 10000
mapo workspace list | expect_json '[.[].name]' '["Obsess","Mapo"]'
mapo ui wait 'rail.tab:Mapo/t2' --timeout-ms 5000 >/dev/null
rail_poll "$(rail_names tab) == [\"t2\",\"t1\",\"bad\"]" 5000
ui_snapshot restarted
expect_json "$(rail_names workspace)" '["Obsess","Mapo"]' < "$SNAP"
expect_json "$(rail_names tab)" '["t2","t1","bad"]' < "$SNAP"

step "Background changes repaint rows in place and leave focus alone"
mapo tab focus t1 --workspace Mapo >/dev/null
sleep 0.3
ui_snapshot before-bg
before=$(jq -c '.focus' "$SNAP")
mapo tab rename t2 --workspace Mapo t2b >/dev/null
mapo tab send bad --workspace Mapo 'true' >/dev/null 2>&1 || true
rail_poll "$(rail_names tab) | index(\"t2b\") != null"
ui_snapshot after-bg
expect_json '.focus' "$before" < "$SNAP"
expect_json "$(rail_names tab)" '["t2b","t1","bad"]' < "$SNAP"

step "Double-click a tab, type a name, Return: the tab is renamed and labeled"
mapo ui click 'rail.tab:Mapo/t1' --count 2 >/dev/null
mapo ui wait rail.rename --state focused --timeout-ms 2000 >/dev/null
ui_snapshot rename-open; ui_shot rename-open
expect_json '.focus.id' '"rail.rename"' < "$SNAP"
mapo ui type 'renamed' >/dev/null
mapo ui key return >/dev/null
mapo ui wait 'rail.tab:Mapo/renamed' --timeout-ms 3000 >/dev/null
mapo ui wait rail.rename --state gone --timeout-ms 2000 >/dev/null
mapo tab list --workspace Mapo | expect_json '.[] | select(.name=="renamed") | .labeled' true

step "A duplicate name keeps the field open; Escape cancels"
mapo ui click 'rail.tab:Mapo/renamed' --count 2 >/dev/null
mapo ui wait rail.rename --state focused --timeout-ms 2000 >/dev/null
mapo ui type 't2b' >/dev/null
mapo ui key return >/dev/null
sleep 0.2
ui_snapshot rename-dup
expect_json '[.tree | .. | objects | select(.id? == "rail.rename")] | length' 1 < "$SNAP"
mapo ui key escape >/dev/null
mapo ui wait rail.rename --state gone --timeout-ms 2000 >/dev/null
mapo tab list --workspace Mapo | expect_json '[.[].name] | sort' '["bad","renamed","t2b"]'

step "Deleting a workspace removes only its row"
mapo workspace delete Obsess --force >/dev/null 2>&1 || mapo workspace delete Obsess >/dev/null
rail_poll "$(rail_names workspace) == [\"Mapo\"]"
ui_snapshot deleted; ui_shot deleted
expect_json "$(rail_names workspace)" '["Mapo"]' < "$SNAP"
expect_json "$(rail_names tab)" '["t2b","renamed","bad"]' < "$SNAP"

step "Every interactive element keeps its identifier"
mapo ui tree | jq '[.. | objects | select(.role? as $r | ["button","checkBox","radioButton",
    "popUpButton","menuButton","textField","textArea","row","link","slider","splitter"] | index($r))
    | select(.id == null)] | length' | expect_json . 0

drive_end
