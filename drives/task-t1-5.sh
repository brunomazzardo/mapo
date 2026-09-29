#!/usr/bin/env zsh
# task-t1-5: the Files inspector follows the focused tab's folder without taking focus, shows git
# letters, updates from the file system and git, and has its states (PLAN T1.5, UX §5.2).
set -euo pipefail
source "${0:A:h}/lib.sh"

drive_begin task-t1-5

# files_rows: the Files rows of the current tree as [{id, value}], sorted by id.
files_rows() {
    mapo ui tree --depth 24 |
        jq -c '[.. | objects | select((.id // "") | startswith("inspector.files.row:")) | {id, value}] | sort_by(.id)'
}

# wait_json SECONDS FILTER CMD…: polls CMD's JSON until `jq -e FILTER` holds (for values `ui wait` can't see).
wait_json() {
    local seconds=$1 filter=$2
    shift 2
    local deadline=$(( EPOCHREALTIME + seconds ))
    while (( EPOCHREALTIME < deadline )); do
        "$@" | jq -e "$filter" >/dev/null 2>&1 && return 0
        sleep 0.05
    done
    return 1
}

files_state() { mapo ui tree --depth 24 | jq -c '[.. | objects | select(.id? == "inspector.files.state") | .value]' }

step "A workspace with a focused shell, and the inspector open with ⌥⌘0"
mapo ui key cmd+shift+n >/dev/null
mapo ui wait 'pane.terminal:terminal-1' --state focused --timeout-ms 3000 >/dev/null
mapo tab wait terminal-1 --until idle --timeout-ms 5000 >/dev/null
mapo ui key cmd+alt+0 >/dev/null
mapo ui wait inspector.segment:files --timeout-ms 2000 >/dev/null
ui_snapshot inspector-open; ui_shot inspector-open
expect_json '.focus.id' '"pane.terminal:terminal-1"' < "$SNAP"

step "cd into a repository: the tree follows within a second, focus stays in the terminal"
# The shell reports its cwd normalized (no `//`), and the tree is rooted there.
D="${DRIVE_TMP:a}/repo"
mkdir -p "$D"
(
    cd "$D"
    git init -q
    echo a > a.txt
    echo x > ignored.log
    echo '*.log' > .gitignore
    git add -A
    git -c user.name=drive -c user.email=drive@example.invalid commit -qm init
    echo b >> a.txt
    touch new.txt
    mkdir src
    echo 'fn main() {}' > src/lib.rs
)
follow_cd() {
    mapo tab send terminal-1 "cd $D" >/dev/null
    mapo ui wait inspector.files.row:a.txt --timeout-ms 1000 >/dev/null
}
timing files-follow-cd follow_cd
ui_snapshot followed; ui_shot followed
expect_json '.focus.id' '"pane.terminal:terminal-1"' < "$SNAP"
jq -c '[.tree | .. | objects | select((.id // "") | startswith("inspector.files.row:")) | {id, value}]' "$SNAP" |
    expect_json . '[{"id":"inspector.files.row:src","value":"?"},{"id":"inspector.files.row:.gitignore","value":null},{"id":"inspector.files.row:a.txt","value":"M"},{"id":"inspector.files.row:new.txt","value":"?"}]'
jq -c '[.tree | .. | objects | select(.id? == "inspector.files.header") | .value]' "$SNAP" | expect_json '.[0]' "$(_drive_json_str "$D")"

step "Clicking a folder expands it lazily"
mapo ui click inspector.files.row:src >/dev/null
mapo ui wait inspector.files.row:src/lib.rs --timeout-ms 1000 >/dev/null
ui_snapshot expanded; ui_shot expanded
jq -c '[.tree | .. | objects | select(.id? == "inspector.files.row:src/lib.rs") | .value]' "$SNAP" | expect_json . '["?"]'

step "A new file appears through fs.watch, debounced"
fs_change() {
    mapo tab run terminal-1 'touch later.txt' >/dev/null
    mapo ui wait inspector.files.row:later.txt --timeout-ms 800 >/dev/null
}
timing files-fs-changed fs_change
fs_change_sub() {
    mapo tab run terminal-1 'touch src/mod.rs' >/dev/null
    mapo ui wait inspector.files.row:src/mod.rs --timeout-ms 800 >/dev/null
}
timing files-fs-changed-sub fs_change_sub

step "Staging a file updates its letter through git.changed"
mapo tab run terminal-1 'git add new.txt' >/dev/null
git_letter() {
    wait_json 2 'map(select(.id == "inspector.files.row:new.txt")) | .[0].value == "A"' files_rows
}
timing files-git-changed git_letter
files_rows | expect_json 'map(select(.id == "inspector.files.row:new.txt")) | .[0].value' '"A"'

step "Keyboard: a click selects a folder, → and ← expand and collapse, Return toggles"
row_gone() { wait_json 2 "map(select(.id == \"$1\")) | length == 0" files_rows; }
mapo ui click inspector.files.row:src >/dev/null
row_gone inspector.files.row:src/lib.rs
mapo ui key right >/dev/null
mapo ui wait inspector.files.row:src/lib.rs --timeout-ms 1000 >/dev/null
mapo ui key left >/dev/null
row_gone inspector.files.row:src/lib.rs
mapo ui key return >/dev/null
mapo ui wait inspector.files.row:src/lib.rs --timeout-ms 1000 >/dev/null
ui_snapshot keyboard; ui_shot keyboard
jq -c '[.tree | .. | objects | select(.id? == "inspector.files.row:src/lib.rs")] | length' "$SNAP" | expect_json . 1
mapo ui focus pane.terminal:terminal-1 >/dev/null
mapo ui wait pane.terminal:terminal-1 --state focused --timeout-ms 2000 >/dev/null

step "mapo explorer collapse and refresh"
mapo explorer collapse | expect_json '.path' "$(_drive_json_str "$D")"
wait_json 2 'map(select(.id == "inspector.files.row:src/lib.rs")) | length == 0' files_rows
files_rows | expect_json 'map(select(.id == "inspector.files.row:src/lib.rs")) | length' 0
mapo explorer refresh | expect_json '.state' '"ready"'

step "The folder is deleted: missing with Retry, then it recovers by itself"
mapo tab run terminal-1 "rm -rf $D" >/dev/null
mapo ui wait inspector.files.retry --timeout-ms 2000 >/dev/null
ui_snapshot missing; ui_shot missing
jq -c '[.tree | .. | objects | select(.id? == "inspector.files.state") | .value]' "$SNAP" | expect_json . '["missing"]'
expect_json '.focus.id' '"pane.terminal:terminal-1"' < "$SNAP"
mkdir -p "$D"
wait_json 4 '. == ["empty"]' files_state
files_state | expect_json . '["empty"]'

step "Exclude rules: a folder holding only excluded items says so, without taking focus"
mkdir -p "${DRIVE_TMP:a}/excluded"
: > "${DRIVE_TMP:a}/excluded/.DS_Store"
mapo tab send terminal-1 "cd ${DRIVE_TMP:a}/excluded" >/dev/null
# The previous step also ends "empty", so wait for the header to follow the new folder first.
files_header() { mapo ui tree --depth 24 | jq -c '[.. | objects | select(.id? == "inspector.files.header") | .value]' }
wait_json 3 '.[0] | endswith("/excluded")' files_header
wait_json 2 '. == ["empty"]' files_state
ui_snapshot excluded
expect_json '.focus.id' '"pane.terminal:terminal-1"' < "$SNAP"
jq -r '[.tree | .. | objects | select(.id? == "inspector.files.state") | .label] | .[0]' "$SNAP" | jq -Rc . |
    expect_json 'startswith("Nothing to show")' true

step "Identifiers: every interactive element has one"
mapo ui tree --depth 24 | jq '[.. | objects | select(.role? as $r | ["button","checkBox","radioButton","popUpButton","menuButton","textField","textArea","row","link","slider","splitter"] | index($r)) | select(.id == null)] | length' |
    expect_json . 0
ui_snapshot end-state; ui_shot end-state

drive_end
