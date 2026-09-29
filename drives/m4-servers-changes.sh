#!/usr/bin/env zsh
# m4-servers-changes: the M4 gate (PLAN T4.4): the Changes inspector, diff and gutter (task-t4-3's steps), then
# server detection, ports and a guarded stop (task-t4-1's steps), in one run with the app.
# task-t4-3: the Changes inspector lists files changed against HEAD with letters and counts, warns on a
# large change, opens a colored diff pane, empties after a commit, and the editor's gutter shows an
# unsaved edit (PLAN T4.3, UX §5.3, §6.1, §6.3).
set -euo pipefail
source "${0:A:h}/lib.sh"

drive_begin m4-servers-changes
BUDGET_MS[changes-commit]=1000
BUDGET_MS[gutter-edit]=1000

# ax_value ID: the accessibility value of the element ID ("null" when absent).
ax_value() { mapo ui tree --depth 30 | jq -c --arg id "$1" '[.. | objects | select(.id? == $id) | .value][0]' }

# wait_value SECONDS ID JQ-FILTER: polls ID's value until the filter holds on it.
wait_value() {
    local seconds=$1 id=$2 filter=$3
    local deadline=$(( EPOCHREALTIME + seconds ))
    while (( EPOCHREALTIME < deadline )); do
        ax_value "$id" | jq -e "$filter" >/dev/null 2>&1 && return 0
        sleep 0.05
    done
    return 1
}

changes_rows() {
    mapo ui tree --depth 30 |
        jq -c '[.. | objects | select((.id // "") | startswith("inspector.changes.row:")) | {id, value}] | sort_by(.id)'
}

step "A workspace with a focused shell, the inspector on Changes"
mapo ui key cmd+shift+n >/dev/null
mapo ui wait 'pane.terminal:terminal-1' --state focused --timeout-ms 3000 >/dev/null
mapo tab wait terminal-1 --until idle --timeout-ms 5000 >/dev/null
mapo ui key cmd+alt+0 >/dev/null
mapo ui wait inspector.segment:changes --timeout-ms 2000 >/dev/null
mapo ui click inspector.segment:changes >/dev/null
mapo ui wait inspector.changes.state --timeout-ms 2000 >/dev/null
# The new shell starts in the home folder, outside any repository.
wait_value 2 inspector.changes.state '. == "not-a-repository"' || true
ax_value inspector.changes.state | expect_json . '"not-a-repository"'

step "A repository with a modified, an added and an untracked file"
D="${DRIVE_TMP:a}/repo"
mkdir -p "$D"
(
    cd "$D"
    git init -q -b main
    printf 'one\ntwo\nthree\n' > a.txt
    printf 'alpha\nbeta\n' > b.txt
    git add -A
    git -c user.name=drive -c user.email=drive@example.invalid commit -qm init
    printf 'one\n2\nthree\nfour\n' > a.txt
    printf 'x\ny\n' > added.txt
    git add added.txt
    printf 'u\n' > u.txt
)
mapo tab send terminal-1 "cd $D" >/dev/null
follow_cd() { mapo ui wait inspector.changes.row:a.txt --timeout-ms 2000 >/dev/null }
timing changes-follow-cd follow_cd
ui_snapshot changes; ui_shot changes
changes_rows | expect_json . '[{"id":"inspector.changes.row:a.txt","value":"M +2 -1"},{"id":"inspector.changes.row:added.txt","value":"A +2 -0"},{"id":"inspector.changes.row:u.txt","value":"? +1 -0"}]'
ax_value inspector.changes.summary | expect_json . '"main, 3 files, +5 -1"'
mapo git changes "$D" --json | expect_json '[.branch, .totals.files, .totals.added, .totals.deleted, [.files[].status]]' '["main",3,5,1,["M","A","?"]]'
ax_value inspector.segment:changes >/dev/null

step "Selecting a row opens its diff in the file pane, with Open File"
open_diff() {
    mapo ui click inspector.changes.row:a.txt >/dev/null
    mapo ui wait "pane.diff:$D/a.txt" --timeout-ms 2000 >/dev/null
    wait_value 2 "pane.diff:$D/a.txt" '. != "loading"'
}
timing changes-open-diff open_diff
ui_snapshot diff; ui_shot diff
ax_value "pane.diff:$D/a.txt" | expect_json . '"1 hunk, +2 -1"'
mapo rpc layout.get | jq -c '[.. | objects | select(.kind? == "pane") | .content.diff // empty | [.root, .path]]' |
    expect_json . "[[$(_drive_json_str "$D"),$(_drive_json_str "$D/a.txt")]]"
mapo ui tree --depth 30 | jq -c --arg id "pane.openFile:$D/a.txt" '[.. | objects | select(.id? == $id)] | length' | expect_json . 1
# The untracked file's diff is all additions.
mapo ui click inspector.changes.row:u.txt >/dev/null
mapo ui wait "pane.diff:$D/u.txt" --timeout-ms 2000 >/dev/null
wait_value 2 "pane.diff:$D/u.txt" '. == "1 hunk, +1 -0"'
ax_value "pane.diff:$D/u.txt" | expect_json . '"1 hunk, +1 -0"'

step "Open File opens the editor; its gutter shows the saved changes against HEAD"
mapo ui click inspector.changes.row:a.txt >/dev/null
mapo ui wait "pane.openFile:$D/a.txt" --timeout-ms 2000 >/dev/null
mapo ui click "pane.openFile:$D/a.txt" >/dev/null
mapo ui wait "editor:$D/a.txt" --state focused --timeout-ms 2000 >/dev/null
wait_value 2 "editor.gutter:$D/a.txt" '. == "2 changed hunks"' || true
ax_value "editor.gutter:$D/a.txt" | expect_json . '"2 changed hunks"'

step "An unsaved edit shows a gutter hunk before saving"
mapo file open "$D/b.txt" >/dev/null
mapo ui wait "editor:$D/b.txt" --state focused --timeout-ms 2000 >/dev/null
wait_value 2 "editor.gutter:$D/b.txt" '. == "no changes"' || true
ax_value "editor.gutter:$D/b.txt" | expect_json . '"no changes"'
gutter_edit() {
    mapo ui type 'gamma ' >/dev/null
    wait_value 2 "editor.gutter:$D/b.txt" '. == "1 changed hunk"'
}
timing gutter-edit gutter_edit
ui_snapshot gutter; ui_shot gutter
ax_value "editor.gutter:$D/b.txt" | expect_json . '"1 changed hunk"'
git -C "$D" diff --quiet -- b.txt && print "   b.txt is unchanged on disk (unsaved)"
# Delete the typed word again: the buffer matches HEAD and the hunk goes away.
mapo ui key shift+cmd+left >/dev/null
mapo ui key delete >/dev/null
wait_value 2 "editor.gutter:$D/b.txt" '. == "no changes"' || true
ax_value "editor.gutter:$D/b.txt" | expect_json . '"no changes"'

step "A 60-file change shows the size warning"
mkdir "$DRIVE_TMP/many"
for i in {1..60}; do print "line $i" > "$DRIVE_TMP/many/f$i.txt"; done
mv "$DRIVE_TMP/many" "$D/many"
wait_value 3 inspector.changes.warning '. != null' || true
ui_snapshot warning; ui_shot warning
ax_value inspector.changes.warning | expect_json . '"Large change: 66 lines in 63 files. Consider splitting it."'
rm -rf "$D/many"
wait_value 2 inspector.changes.warning '. == null'
ax_value inspector.changes.warning | expect_json . null

step "git commit -am in the tab empties the list within a second"
commit() {
    mapo tab send terminal-1 'git add u.txt && git -c user.name=drive -c user.email=drive@example.invalid commit -qam wip' >/dev/null
    wait_value 1.5 inspector.changes.state '. == "clean"'
}
timing changes-commit commit
ui_snapshot committed; ui_shot committed
ax_value inspector.changes.state | expect_json . '"clean"'
changes_rows | expect_json 'length' 0

srv() { mapo tab list | jq -c '.[] | select(.name=="srv")' }
poll() { local f=$1 want=$2 i; for i in {1..40}; do [[ $(srv | jq -c "$f") == "$want" ]] && break; sleep 0.1; done; srv | expect_json "$f" "$want" }

step "A listening command labels its tab as a server within 2 s"
mapo tab new --name srv --workspace "$(mapo rpc state.snapshot | jq -r '.activeWorkspaceId')" >/dev/null
mapo tab wait srv --until idle --timeout-ms 8000 >/dev/null
mapo tab send srv 'nc -l 4173' >/dev/null
timing server-detect poll '.server.ports' '[4173]'

step "Ports map listeners to tabs; stop re-checks identity and refuses Mapo"
mapo ports --port 4173 | expect_json '.[0] | [.port, .name, (.tabId != null)]' '[4173,"nc",true]'
PID=$(mapo ports --port 4173 | jq -r '.[0].pid'); ID=$(mapo ports --port 4173 | jq -r '.[0].identity')
rc=0; mapo process stop $PID --identity 0000000000000000 2>/dev/null >/dev/null || rc=$?
print -r -- "{\"rc\":$rc}" | expect_json .rc 1
rc=0; mapo process stop $(mapo instance show | jq .daemon.pid) --identity x 2> "$DRIVE_TMP/self.err" >/dev/null || rc=$?
jq -c .kind "$DRIVE_TMP/self.err" | expect_json . '"forbidden"'
mapo process stop $PID --identity $ID | expect_json .signalSent '"SIGTERM"'
poll '.server' 'null'
poll '.state' '"idle"'

step "Stop (Ctrl-C) ends a server without marking it failed"
mapo tab send srv 'nc -l 4175' >/dev/null
poll '.server.ports' '[4175]'
mapo tab stop srv >/dev/null
poll '[.server, .state]' '[null,"idle"]'

step "A server that exits non-zero is failed with its code"
mapo tab send srv 'sh -c "nc -l 4174 & sleep 2; kill %1 2>/dev/null; exit 3"' >/dev/null
poll '.server.ports' '[4174]'
poll '[.state, .stateDetail]' '["failed","exit 3"]'

drive_end
