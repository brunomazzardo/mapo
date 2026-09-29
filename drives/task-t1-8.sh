#!/usr/bin/env zsh
# task-t1-8: the menu bar and the full keyboard map come from one command table. The drive reads the
# table from `ui.snapshot` (`model.commands`, the same entries MainMenu and the palette are built from)
# and walks it: each Mapo row sends its chord with `mapo ui key`, or runs through ⌘K when it has none,
# and checks the effect through CLI JSON or the snapshot. Rows of a later milestone are marked with it
# (and their chord changes nothing); AppKit's standard items and the file pane's responder items
# (T1.6 drives them) are marked too. Any other row without a check fails the drive.
set -euo pipefail
source "${0:A:h}/lib.sh"

drive_begin task-t1-8

snap() { mapo ui snapshot; }
panes() { mapo rpc layout.get; }
# Every workspace's tabs.
tabs() { mapo rpc state.snapshot | jq .tabs; }
workspaces() { mapo workspace list; }
tab_id() { tabs | jq -r --arg n "$1" '.[] | select(.name==$n) | .id'; }
ws_id() { mapo workspace list | jq -r --arg n "$1" '.[] | select(.name==$n) | .id'; }
activate() { mapo rpc workspace.activate "{\"workspace\":\"$(ws_id "$1")\"}" >/dev/null; }
# A CLI tab.focus never moves keyboard focus off the rail (background changes don't steal
# focus), so do what a person does: click the tab's rail row in the active workspace.
focus_tab() {
    local ws
    ws=$(mapo rpc state.snapshot | jq -r '.activeWorkspaceId as $a | .workspaces[] | select(.id == $a) | .name')
    mapo ui click "rail.tab:$ws/$1" >/dev/null
    mapo ui wait "pane.terminal:$1" --state focused --timeout-ms 3000 >/dev/null
}
# poll FILTER EXPECTED CMD...: re-runs CMD until jq FILTER gives EXPECTED (3 s), then checks it.
poll() {
    local filter=$1 expected=$2 want out i
    shift 2
    want=$(print -r -- "$expected" | jq -c .)
    for i in {1..60}; do
        out=$("$@" 2>/dev/null | jq -c "$filter" 2>/dev/null) || out=""
        [[ $out == "$want" ]] && break
        sleep 0.05
    done
    "$@" | expect_json "$filter" "$expected"
}
# palette_run TITLE: runs a command through ⌘K, the way a row without a shortcut is reached.
palette_run() {
    mapo ui key cmd+k >/dev/null
    mapo ui wait palette.field --state focused --timeout-ms 2000 >/dev/null
    mapo ui type ">$1" >/dev/null
    local i
    for i in {1..40}; do
        mapo ui tree --depth 24 | jq -e --arg t "$1, Commands" \
            '[.. | objects | select(.id? == "palette.row:0") | .label | startswith($t)] | any' >/dev/null && break
        sleep 0.05
    done
    mapo ui tree --depth 24 | jq -r '[.. | objects | select(.id? == "palette.row:0") | .label][0] // ""' |
        jq -Rc . | expect_json "startswith(\"$1, Commands\")" true
    mapo ui key return >/dev/null
    mapo ui wait palette --state gone --timeout-ms 2000 >/dev/null
}
cols() { mapo tab run "$1" 'tput cols' | jq -r '.output | tonumber'; }

# MARK: Rows. Each takes the row's chord and alternate chord from the table.

'row:app.settings'() {
    mapo ui key $1 >/dev/null
    poll '[.. | objects | select(.kind? == "pane") | .content.file? // empty | endswith("/config.toml")] | any' \
        true panes
    local cfg="$(mapo instance show | jq -r .dataDir)/config.toml"
    grep -c '^\[terminal\]' "$cfg" | expect_json . 1
    ui_snapshot settings; ui_shot settings
    local pane=$(panes | jq -r '[.. | objects | select(.kind? == "pane" and (.content.file? // "" | endswith("/config.toml"))) | .id][0]')
    mapo rpc pane.close "{\"pane\":\"$pane\"}" >/dev/null
    poll '[.. | objects | select(.kind? == "pane")] | length' 1 panes
}

'row:file.newWorkspace'() {
    local before=$(workspaces | jq length)
    mapo ui key $1 >/dev/null
    poll length $((before + 1)) workspaces
    # Tab names count per workspace, so the new workspace's shell is terminal-1 again.
    mapo ui wait "rail.tab:Workspace $((before + 1))/terminal-1" --timeout-ms 3000 >/dev/null
    mapo ui wait 'pane.terminal:terminal-1' --state focused --timeout-ms 3000 >/dev/null
}

'row:file.newShellTab'() {
    local before=$(tabs | jq length)
    mapo ui key $1 >/dev/null
    poll length $((before + 1)) tabs
    mapo ui wait 'pane.terminal:terminal-2' --state focused --timeout-ms 3000 >/dev/null
}

# ⇧⌘T types the workspace's agent command; a harmless one, so no real Claude starts (PLAN §5 rules).
'row:file.newAgentTab'() {
    local ws before agent
    ws=$(mapo rpc state.snapshot | jq -r '.activeWorkspaceId as $a | .workspaces[] | select(.id == $a) | .name')
    mapo workspace configure "$ws" --agent-command 'echo fakeagent' >/dev/null
    before=$(tabs | jq length)
    mapo ui key $1 >/dev/null
    poll length $((before + 1)) tabs
    agent=$(tabs | jq -r '[.[] | select(.kind=="agent")] | last | .name')
    mapo ui wait "pane.terminal:$agent" --state focused --timeout-ms 3000 >/dev/null
    mapo tab wait "$agent" --until fakeagent --timeout-ms 8000 >/dev/null
    mapo rpc tab.close "{\"tab\":\"$(tab_id $agent)\",\"force\":true}" >/dev/null
    poll length $before tabs
}

'row:file.newTabInFolder'() {
    local folder="${DRIVE_TMP:A}/folder" before=$(tabs | jq length)
    mkdir -p "$folder"
    mapo ui key $1 >/dev/null
    mapo ui wait dialog --timeout-ms 2000 >/dev/null
    mapo ui wait dialog.field --state focused --timeout-ms 2000 >/dev/null
    ui_snapshot folder-sheet; ui_shot folder-sheet
    # The field starts fully selected, so typing replaces it; a path that isn't a folder disables New Tab.
    mapo ui type "$folder-missing" >/dev/null
    poll '[.tree | .. | objects | select(.id? == "dialog.confirm") | .enabled]' '[false]' snap
    mapo ui key cmd+a >/dev/null
    mapo ui type "$folder" >/dev/null
    poll '[.tree | .. | objects | select(.id? == "dialog.confirm") | .enabled]' '[true]' snap
    mapo ui press dialog.confirm >/dev/null
    mapo ui wait dialog --state gone --timeout-ms 2000 >/dev/null
    poll length $((before + 1)) tabs
    tabs | expect_json "[.[] | select(.cwd == \"$folder\")] | length" 1
    # Cancel changes nothing.
    mapo ui key $1 >/dev/null
    mapo ui wait dialog --timeout-ms 2000 >/dev/null
    mapo ui press dialog.cancel >/dev/null
    mapo ui wait dialog --state gone --timeout-ms 2000 >/dev/null
    tabs | expect_json length $((before + 1))
}

# toggle_view FIELD CHORD: the chord flips model.view.FIELD, and again flips it back.
toggle_view() {
    local was=$(snap | jq ".model.view.$1")
    mapo ui key $2 >/dev/null
    poll ".model.view.$1" "$([[ $was == true ]] && print false || print true)" snap
    mapo ui key $2 >/dev/null
    poll ".model.view.$1" "$was" snap
}
'row:view.toggleSidebar'() { toggle_view sidebar $1; }
'row:view.toggleInspector'() { toggle_view inspector $1; }

'row:view.showFiles'() {
    palette_run 'Show Files'
    poll '.model.view | [.inspector, .inspectorSegment]' '[true,"files"]' snap
    mapo ui key cmd+alt+0 >/dev/null
    poll '.model.view.inspector' false snap
}

'row:view.showChanges'() {
    palette_run 'Show Changes'
    poll '.model.view | [.inspector, .inspectorSegment]' '[true,"changes"]' snap
    palette_run 'Show Files'
    mapo ui key cmd+alt+0 >/dev/null
    poll '.model.view | [.inspector, .inspectorSegment]' '[false,"files"]' snap
}

'row:view.palette'() {
    mapo ui key $1 >/dev/null
    mapo ui wait palette.field --state focused --timeout-ms 2000 >/dev/null
    snap | expect_json '.model.view.palette' true
    mapo ui key $1 >/dev/null
    mapo ui wait palette --state gone --timeout-ms 2000 >/dev/null
}

FONT_BASE=0
FONT_TAB=""
FONT_COLS=0
'row:view.bigger'() {
    FONT_BASE=$(snap | jq .model.view.fontSize)
    FONT_TAB=$(snap | jq -r '.focus.id | sub("^pane.terminal:"; "")')
    FONT_COLS=$(cols $FONT_TAB)
    mapo ui key $1 >/dev/null
    poll .model.view.fontSize $((FONT_BASE + 1)) snap
    mapo ui key $2 >/dev/null   # ⌘= does the same
    poll .model.view.fontSize $((FONT_BASE + 2)) snap
    # The grid follows: fewer columns at a bigger size.
    local i now=$FONT_COLS
    for i in {1..40}; do now=$(cols $FONT_TAB); (( now < FONT_COLS )) && break; sleep 0.05; done
    print -r -- $(( now < FONT_COLS )) | expect_json . 1
}

'row:view.smaller'() {
    mapo ui key $1 >/dev/null
    poll .model.view.fontSize $((FONT_BASE + 1)) snap
}

'row:view.actualSize'() {
    mapo ui key $1 >/dev/null
    poll .model.view.fontSize $FONT_BASE snap
    local i now=0
    # Back to the base size; the grid can differ by a column or two from font metric rounding.
    for i in {1..40}; do now=$(cols $FONT_TAB); (( now >= FONT_COLS - 3 && now <= FONT_COLS + 3 )) && break; sleep 0.05; done
    print -r -- "{\"now\":$now,\"base\":$FONT_COLS}" | expect_json '(.now - .base) | fabs <= 3' true
}

'row:workspace.previous'() {
    activate 'Workspace 2'
    mapo ui key $1 >/dev/null
    poll .model.workspaceId "\"$(ws_id 'Workspace 1')\"" snap
}

'row:workspace.next'() {
    mapo ui key $1 >/dev/null
    poll .model.workspaceId "\"$(ws_id 'Workspace 2')\"" snap
}

'row:workspace.rename'() {
    activate 'Workspace 2'
    palette_run 'Rename Workspace'
    mapo ui wait rail.rename --state focused --timeout-ms 2000 >/dev/null
    mapo ui type 'Second' >/dev/null
    mapo ui key return >/dev/null
    poll '[.[].name]' '["Workspace 1","Second"]' workspaces
}

'row:workspace.moveUp'() {
    activate Second
    palette_run 'Move Workspace Up'
    poll '[.[].name]' '["Second","Workspace 1"]' workspaces
}

'row:workspace.moveDown'() {
    palette_run 'Move Workspace Down'
    poll '[.[].name]' '["Workspace 1","Second"]' workspaces
}

'row:workspace.delete'() {
    mapo workspace new Doomed >/dev/null
    activate Doomed
    poll .model.workspaceId "\"$(ws_id Doomed)\"" snap
    palette_run 'Delete Workspace'
    poll '[.[].name]' '["Workspace 1","Second"]' workspaces
}

# hook TAB FIXTURE [WORKSPACE]: feeds a hook fixture through `mapo hook` inside the tab (the synthetic
# agent path). The leading space absorbs an Esc left by an interrupt in this plain shell.
hook() {
    mapo tab run ${3:+--workspace=$3} "$1" " mapo hook < $MAPO_ROOT/crates/mapo-agent/fixtures/$2.json" >/dev/null
}

# ⌘J is disabled with nothing to attend to, then focuses a tab that needs you in another workspace.
'row:tab.nextNeedingYou'() {
    later $1
    mapo workspace new Attn >/dev/null
    mapo tab new --workspace Attn --name nx >/dev/null
    mapo tab wait --workspace Attn nx --until idle --timeout-ms 8000 >/dev/null
    hook nx 02-UserPromptSubmit Attn
    hook nx 03-PermissionRequest Attn
    poll '.[] | select(.name=="nx") | .state' '"needs-you"' tabs
    mapo ui key $1 >/dev/null
    mapo ui wait 'pane.terminal:nx' --state focused --timeout-ms 3000 >/dev/null
    mapo rpc workspace.delete "{\"workspace\":\"$(ws_id Attn)\",\"force\":true}" >/dev/null
    poll '[.[].name]' '["Workspace 1","Second"]' workspaces
}

# A workspace of three tabs for the Tab rows.
tabs_setup() {
    mapo workspace new Tabs >/dev/null
    local name
    for name in a b c; do mapo tab new --workspace Tabs --name $name >/dev/null; done
    activate Tabs
    focus_tab a
}

'row:tab.previous'() {
    tabs_setup
    mapo ui key $1 >/dev/null   # wraps from the first to the last
    mapo ui wait 'pane.terminal:c' --state focused --timeout-ms 3000 >/dev/null
}

'row:tab.next'() {
    mapo ui key $1 >/dev/null   # wraps from the last to the first
    mapo ui wait 'pane.terminal:a' --state focused --timeout-ms 3000 >/dev/null
    mapo ui key $1 >/dev/null
    mapo ui wait 'pane.terminal:b' --state focused --timeout-ms 3000 >/dev/null
}

goto_tab() {
    local names=(a b c)
    mapo ui key $1 >/dev/null
    if (( $2 <= 3 )); then
        mapo ui wait "pane.terminal:${names[$2]}" --state focused --timeout-ms 3000 >/dev/null
        snap | expect_json .focus.id "\"pane.terminal:${names[$2]}\""
    else
        # No tab N: the item is disabled and focus stays.
        local before=$(snap | jq -c .focus.id)
        sleep 0.2
        snap | expect_json .focus.id "$before"
    fi
}
for n in {1..9}; do
    functions[row:tab.goTo.$n]="goto_tab \$1 $n"
done

'row:tab.rename'() {
    focus_tab c
    mapo ui key $1 >/dev/null
    mapo ui wait rail.rename --state focused --timeout-ms 2000 >/dev/null
    mapo ui type 'cee' >/dev/null
    mapo ui key return >/dev/null
    poll '[.[] | select(.workspaceId == "'"$(ws_id Tabs)"'") | .name] | sort' '["a","b","cee"]' tabs
}

# ⇧⌘X sends Esc to the focused working agent, which the daemon records as an interrupt.
# Tab b, because clicking the still-selected cee would start a rename; tab.close closes b next.
'row:tab.interrupt'() {
    focus_tab b
    hook b 02-UserPromptSubmit
    poll '.[] | select(.name=="b") | .state' '"running"' tabs
    mapo ui key $1 >/dev/null
    poll '.[] | select(.name=="b") | [.state, .agent.interrupted]' '["idle",true]' tabs
}

'row:tab.stop'() {
    focus_tab a
    mapo tab wait a --until idle --timeout-ms 5000 >/dev/null
    mapo tab send a 'sleep 600' >/dev/null
    poll '.[] | select(.name=="a") | .state' '"running"' tabs
    mapo ui key $1 >/dev/null
    poll '.[] | select(.name=="a") | .state' '"idle"' tabs
}

'row:tab.close'() {
    focus_tab b
    mapo ui key $1 >/dev/null
    poll '[.[] | select(.name=="b")] | length' 0 tabs
}

# A workspace with one pane for the Pane rows: [A | [B / C]] after the two splits.
'row:pane.splitRight'() {
    mapo workspace new Panes >/dev/null
    mapo tab new --workspace Panes --name p1 >/dev/null
    activate Panes
    focus_tab p1
    mapo ui key $1 >/dev/null
    poll '[.. | objects | select(.kind? == "pane")] | length' 2 panes
    poll '.root.axis' '"row"' panes
}

'row:pane.splitDown'() {
    mapo ui key $1 >/dev/null
    poll '[.. | objects | select(.kind? == "pane")] | length' 3 panes
    poll '.root.children[1].axis' '"column"' panes
}

pane_a() { panes | jq -r '.root.children[0].id'; }
pane_b() { panes | jq -r '.root.children[1].children[0].id'; }
pane_c() { panes | jq -r '.root.children[1].children[1].id'; }
focus_pane() { mapo rpc pane.focus "{\"pane\":\"$1\"}" >/dev/null; }
'row:pane.focusLeft'() {
    focus_pane $(pane_c)
    mapo ui key $1 >/dev/null
    poll .focusedPaneId "\"$(pane_a)\"" panes
}
'row:pane.focusRight'() {
    local a=$(pane_a)
    focus_pane $a
    mapo ui key $1 >/dev/null
    poll ".focusedPaneId != \"$a\"" true panes
}
'row:pane.focusUp'() {
    focus_pane $(pane_c)
    mapo ui key $1 >/dev/null
    poll .focusedPaneId "\"$(pane_b)\"" panes
}
'row:pane.focusDown'() {
    focus_pane $(pane_b)
    mapo ui key $1 >/dev/null
    poll .focusedPaneId "\"$(pane_c)\"" panes
}

'row:pane.equalize'() {
    mapo rpc pane.resize "{\"split\":\"$(panes | jq -r .root.id)\",\"ratios\":[0.3,0.7]}" >/dev/null
    palette_run 'Equalize Panes'
    poll '.root.ratios' '[0.5,0.5]' panes
}

'row:pane.close'() {
    focus_pane $(pane_c)
    mapo ui key $1 >/dev/null
    poll '[.. | objects | select(.kind? == "pane")] | length' 2 panes
}

# later CHORD: the item is disabled, so its chord changes no tab or workspace.
later() {
    [[ -z $1 ]] && return 0
    local before="$(tabs | jq -c '[.[].id] | sort')$(workspaces | jq -c '[.[].id] | sort')"
    mapo ui key $1 >/dev/null
    sleep 0.2
    print -r -- "$(tabs | jq -c '[.[].id] | sort')$(workspaces | jq -c '[.[].id] | sort')" | jq -Rc . |
        expect_json . "$(print -r -- $before | jq -Rc .)"
}

# MARK: Walk

step "Setup: Workspace 1; read the command table from the snapshot"
mapo ui key cmd+shift+n >/dev/null
mapo ui wait 'pane.terminal:terminal-1' --state focused --timeout-ms 3000 >/dev/null
mapo tab wait terminal-1 --until idle --timeout-ms 5000 >/dev/null
ui_snapshot table
jq '.model.commands | length' "$SNAP" | expect_json '. > 60' true
# Every UX §8 shortcut is in the table.
jq -c '[.model.commands[].chord // empty] | sort' "$SNAP" | expect_json '
    ["cmd+,","cmd+shift+n","cmd+t","cmd+shift+t","cmd+alt+t","cmd+s","cmd+f","cmd+alt+f","cmd+l",
     "cmd+ctrl+s","cmd+alt+0","cmd+k","cmd+shift+=","cmd+-","cmd+0","cmd+ctrl+up","cmd+ctrl+down","cmd+j",
     "cmd+shift+[","cmd+shift+]","cmd+1","cmd+9","cmd+alt+r","cmd+shift+x","cmd+.","cmd+shift+w","cmd+d",
     "cmd+shift+d","cmd+alt+left","cmd+alt+right","cmd+alt+up","cmd+alt+down","cmd+w","cmd+m","cmd+q"]
    - . | length' 0

typeset -a table unchecked
table=("${(@f)$(jq -c '.model.commands[]' "$SNAP")}")
typeset -i driven=0 marked_later=0 marked_system=0 marked_editor=0
: > "$EVIDENCE/checklist.txt"
for row in $table; do
    id=$(jq -r .id <<< $row)
    chord=$(jq -r '.chord // ""' <<< $row)
    alternate=$(jq -r '.alternateChord // ""' <<< $row)
    milestone=$(jq -r '.milestone // ""' <<< $row)
    method=$(jq -r .method <<< $row)
    if [[ -n $milestone ]]; then
        step "$id ${chord:-(no shortcut)}: later ($milestone)"
        later "$chord"
        result="later $milestone"
        marked_later+=1
    elif (( ${+functions[row:$id]} )); then
        step "$id ${chord:-(palette)}: $method"
        "row:$id" "$chord" "$alternate"
        result="driven"
        driven+=1
    elif [[ $method == system ]]; then
        result="system (AppKit standard item)"
        marked_system+=1
    elif [[ $method == editor ]]; then
        result="editor (file pane responder, T1.6)"
        marked_editor+=1
    else
        result="UNCHECKED"
        unchecked+=$id
    fi
    print -r -- "$id	${chord:--}	$method	$result" >> "$EVIDENCE/checklist.txt"
done

step "Every row is driven or marked"
print -r -- "driven=$driven later=$marked_later system=$marked_system editor=$marked_editor"
print -r -- "${(j:,:)unchecked}" | jq -Rc . | expect_json . '""'
ui_snapshot end-of-table; ui_shot end-of-table
mapo ui tree --depth 24 | jq '[.. | objects | select(.role? as $r | ["button","checkBox","radioButton",
    "popUpButton","menuButton","textField","textArea","row","link","slider","splitter"] | index($r))
    | select(.id == null)] | length' | expect_json . 0

drive_end
