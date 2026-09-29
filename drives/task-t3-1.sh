#!/usr/bin/env zsh
# task-t3-1: CLI verb parity, output formats and exit codes (PLAN T3.1, R-CTL-2, R-CTL-3, PROTOCOL
# §4 and §9). A table of rows walks every verb `mapo --help` and each noun's `--help` list, plus the
# hidden `hook` and `rpc`. Each row is a command, its expected exit code and a jq check. Piped rows
# check compact JSON on stdout, or one PROTOCOL §4 line on stderr; TTY rows run under `script`.
# Only echo, sleep, seq and sh run in tabs; agent tabs run `echo fakeagent` and needs-you comes from
# the synthetic hook fixtures, so no real Claude runs. The drive checks at the end that every verb
# from the help had a row. Every row lands in rows.tsv in the evidence folder.
#
# Known deviations (recorded, not fixed here):
# - PROTOCOL §9 lists `mapo ui hover|scroll` and `mapo debug latency`; neither the CLI nor the app
#   implements ui.hover, ui.scroll or a latency probe yet, so they have no rows.
# - `tab interrupt` on a plain shell tab succeeds: it sends Escape and marks the shell
#   `agent.interrupted`. PROTOCOL §6 describes it only for agents; whether a shell should get
#   `conflict` is a spec question.
# - `ui focus window.main` is `conflict` (the window isn't a focusable element), though lib.sh calls it.
set -euo pipefail
source "${0:A:h}/lib.sh"

drive_begin task-t3-1
F="$MAPO_ROOT/crates/mapo-agent/fixtures"
ROWS="$EVIDENCE/rows.tsv"
print -r -- $'verb\texit\tgot\tms\tcommand' > "$ROWS"
typeset -gA COVERED
typeset -g RAW_INSTANCE=$DRIVE_INSTANCE
NOUNS_WITH_VERBS=(workspace tab pane file git explorer ui process instance debug)

# raw ARGS: the CLI without --json, so stdout piped to a file must give JSON on its own.
raw() {
    env -u MAPO_TOKEN -u MAPO_HOOK_TOKEN -u MAPO_ATTACH_TOKEN \
        "$MAPO_BIN" --instance "$RAW_INSTANCE" "$@"
}

_verb() {
    if (( ${NOUNS_WITH_VERBS[(Ie)$1]} )) && [[ -n ${2:-} && $2 != -* ]]; then print -r -- "$1 $2"; else print -r -- "$1"; fi
}

# row EXIT FILTER WANT -- ARGS: `mapo ARGS` piped must exit EXIT. jq FILTER runs over stdout when it
# printed something, else over stderr, and must give WANT. JSON must be one compact line.
row() {
    local want_rc=$1 filter=$2 want=$3; shift 3; [[ $1 == -- ]] && shift
    local out=$DRIVE_TMP/row.out err=$DRIVE_TMP/row.err rc=0 t=$EPOCHREALTIME stream compact actual
    raw "$@" > $out 2> $err < /dev/null || rc=$?
    local ms=$(_drive_ms $t) verb=$(_verb "$@")
    COVERED[$verb]=1
    stream=$out; [[ -s $out ]] || stream=$err
    compact=false
    [[ $(wc -l < $stream | tr -d ' ') == 1 && $(jq -c . < $stream 2>/dev/null) == "$(< $stream)" ]] && compact=true
    actual=$(jq -c "$filter" < $stream 2>/dev/null) || actual=$(jq -Rs -c . < $stream)
    print -r -- "$verb"$'\t'"$want_rc"$'\t'"$rc"$'\t'"$ms"$'\t'"mapo ${(j: :)${(q-)@}}" >> "$ROWS"
    print -r -- "   mapo ${(j: :)${(q-)@}}"
    print -r -- "[$rc,$compact,${actual:-null}]" | expect_json . "[$want_rc,true,$want]" && return 0
    print -r -- "     stdout: $(head -c 300 $out)"; print -r -- "     stderr: $(head -c 300 $err)"
}

# ok FILTER WANT -- ARGS: exit 0 with compact JSON.
ok() { row 0 "$@" }

# err EXIT KIND HINT -- ARGS: one PROTOCOL §4 line on stderr, nothing on stdout. HINT is true when
# the error must carry a hint, false when it must not, and any when either is fine.
err() {
    local rc=$1 kind=$2 hint=$3; shift 3
    local f='[.kind, (.error | type), has("hint")]' w="[\"$kind\",\"string\",$hint]"
    [[ $hint == any ]] && { f='[.kind, (.error | type)]'; w="[\"$kind\",\"string\"]"; }
    row $rc "$f" "$w" "$@"
}

# text EXIT FILTER WANT -- ARGS: like row, but stdout is raw text, run through jq -Rs FILTER.
text() {
    local want_rc=$1 filter=$2 want=$3; shift 3; [[ $1 == -- ]] && shift
    local out=$DRIVE_TMP/row.out rc=0 t=$EPOCHREALTIME
    raw "$@" > $out 2> $DRIVE_TMP/row.err < /dev/null || rc=$?
    local verb=$(_verb "$@")
    COVERED[$verb]=1
    print -r -- "$verb"$'\t'"$want_rc"$'\t'"$rc"$'\t'"$(_drive_ms $t)"$'\t'"mapo ${(j: :)${(q-)@}}" >> "$ROWS"
    print -r -- "   mapo ${(j: :)${(q-)@}}"
    print -r -- "[$rc,$(jq -Rs -c "$filter" < $out)]" | expect_json . "[$want_rc,$want]" || true
}

# tty FILTER WANT -- ARGS: `mapo ARGS` on a pseudo-terminal (script); jq -Rs FILTER over its output.
tty() {
    local filter=$1 want=$2; shift 2; [[ $1 == -- ]] && shift
    script -q /dev/null env -u MAPO_TOKEN -u MAPO_HOOK_TOKEN -u MAPO_ATTACH_TOKEN \
        "$MAPO_BIN" --instance "$DRIVE_INSTANCE" "$@" < /dev/null > $DRIVE_TMP/tty.raw 2>&1 || true
    perl -pe 's/\^D\x08\x08//g; s/\r//g; s/\e\[[0-9;]*m//g' $DRIVE_TMP/tty.raw > $DRIVE_TMP/tty.txt
    print -r -- "   (tty) mapo ${(j: :)${(q-)@}}"
    sed 's/^/     | /' $DRIVE_TMP/tty.txt | head -n 8
    jq -Rs -c "$filter" < $DRIVE_TMP/tty.txt | expect_json . "$want" || true
}

# state TAB: the tab's state, from a piped tab list.
state() { raw tab list | jq -r --arg n "$1" '.[] | select(.name == $n) | .state' }
# poll_state TAB STATE: waits up to 5 s for it.
poll_state() {
    local i; for i in {1..50}; do [[ $(state $1) == $2 ]] && return 0; sleep 0.1; done
    print "   (tab $1 is $(state $1), not $2)"
}

step "Workspaces: list, new, rename, activate, configure, move, delete"
ok '.name' '"Parity"' -- workspace new Parity
ok '.name' '"Spare"' -- workspace new Spare
ok '[.[].name] | index("Parity") != null' true -- workspace list
ok '.name' '"Spare2"' -- workspace rename Spare Spare2
ok '.name' '"Parity"' -- workspace activate Parity
ok '.agentCommand' '"echo fakeagent"' -- workspace configure Parity --agent-command 'echo fakeagent'
ok '[.name, .order]' '["Spare2",0]' -- workspace move Spare2 --index 0
err 2 invalid_argument true -- workspace move Spare2 --index minus-one
err 2 invalid_argument any -- workspace move Spare2 --index 99
ok '.deleted' true -- workspace delete Spare2 --force
err 1 not_found any -- workspace delete Nope --force
raw workspace new Dup > /dev/null; raw workspace new Dup > /dev/null
err 1 conflict any -- workspace activate Dup
for id in $(raw workspace list | jq -r '.[] | select(.name == "Dup") | .id'); do
    ok '.deleted' true -- workspace delete $id --force
done
raw workspace activate Parity > /dev/null
err 2 invalid_argument true -- workspace bogus

step "A repository to work in"
REPO=$DRIVE_TMP/repo
mkdir -p $REPO
(
    cd $REPO
    git init -q -b main
    print one > a.txt
    git add -A
    git -c user.name=drive -c user.email=drive@example.invalid commit -qm init
    print two >> a.txt
)
print "   $REPO: a.txt modified"

step "Tabs: new with kinds and aliases, list, send, wait, read, run"
ok '[.name, .kind]' '["a","shell"]' -- tab new --name a --cwd $REPO
ok '.name' '"a"' -- tab wait a --until idle --timeout-ms 8000
ok '[.name, .kind]' '["b","shell"]' -- tab new --name b --kind terminal
ok '[.name, .kind]' '["c","agent"]' -- tab new --name c --kind claude
err 2 invalid_argument any -- tab new --name d --kind robot
err 1 conflict any -- tab new --name a
ok '[.[].name]' '["a","b","c"]' -- tab list
ok '.sent > 0' true -- tab send a 'echo hi-$((6*7))'
ok '.name' '"a"' -- tab wait a --until hi-42 --timeout-ms 5000
ok '.text | contains("hi-42")' true -- tab read a --lines 20
ok '[.exitCode, .output]' '[0,"run-ok"]' -- tab run a 'echo run-ok'
ok '[.exitCode, .output]' '[0,"1 2 3"]' -- tab run a 'seq 3 | paste -sd" " -'
row 3 '[.exitCode, .output]' '[3,""]' -- tab run a 'sh -c "exit 3"'
err 1 not_found true -- tab read nope
err 2 invalid_argument true -- tab send a
err 2 invalid_argument true -- tab wait a

step "Tabs: rename, move, focus, interrupt, close"
ok '.name' '"bee"' -- tab rename b bee
ok '[.name, .order]' '["bee",0]' -- tab move bee --index 0
ok '.name' '"a"' -- tab focus a
# Interrupt sends Escape, which would eat the next send's first key at a shell prompt, so use c.
ok '.name' '"c"' -- tab interrupt c
ok '.closed' true -- tab close bee
err 1 not_found true -- tab close bee
err 1 not_found true -- tab rename nope x

step "--tab-id ID selects a tab by ID (R-CTL-2)"
ID=$(raw tab list | jq -r '.[] | select(.name == "a") | .id')
ok '.sent > 0' true -- tab send --tab-id $ID 'echo via-id'
ok '.name' '"a"' -- tab wait --tab-id $ID --until via-id --timeout-ms 5000
ok '.text | contains("via-id")' true -- tab read --tab-id=$ID
ok '.output' '"id-run"' -- tab run --tab-id $ID 'echo id-run'
err 1 not_found true -- tab focus --tab-id 01a0ffff-0000-7000-8000-000000000000
err 2 invalid_argument true -- status --tab-id $ID

step "Timeout (124), stop, restart and conflict"
raw tab send a 'sleep 5' > /dev/null
poll_state a running
err 124 timeout any -- tab wait a --until idle --timeout-ms 200
err 1 conflict any -- tab restart a
ok '.name' '"a"' -- tab stop a
ok '.state' '"idle"' -- tab wait a --until idle --timeout-ms 5000
raw tab new --name d > /dev/null
raw tab wait d --until idle --timeout-ms 8000 > /dev/null
raw tab send d 'exit 3' > /dev/null
poll_state d stopped
ok '.name' '"d"' -- tab restart d
ok '.name' '"d"' -- tab wait d --until idle --timeout-ms 8000

step "Needs you (5): tab ask on an agent whose hooks reported a permission request"
raw tab new --name ag > /dev/null
raw tab wait ag --until idle --timeout-ms 8000 > /dev/null
raw tab run ag "mapo hook < $F/01-SessionStart.json" > /dev/null
raw tab run ag "mapo hook < $F/03-PermissionRequest.json" > /dev/null
poll_state ag needs-you
err 5 needs_you true -- tab ask ag 'Reply with exactly: PONG'
err 1 not_found true -- tab ask nope hello

step "Panes: split, focus, equalize, close"
ok '.root.kind' '"split"' -- pane split right
ok '.focusedPaneId | type' '"string"' -- pane focus left
ok '.root.ratios' '[0.5,0.5]' -- pane equalize
ok '.root.kind' '"pane"' -- pane close
err 2 invalid_argument true -- pane split up
err 1 not_found any -- pane focus --pane nope

step "Status, events, activity"
ok 'type' '"array"' -- status
ok '.name' '"a"' -- status a
err 1 not_found true -- status nope
text 0 'split("\n") | map(select(length > 0) | fromjson | .seq) | (length > 0 and . == sort)' true -- events --after 0
ok 'length <= 3' true -- activity --limit 3
err 2 invalid_argument true -- activity --limit lots

step "Files, git, explorer"
ok '[.branch, .totals.files, [.files[].path]]' '["main",1,["a.txt"]]' -- git changes $REPO
ok '.paneId | type' '"string"' -- file open $REPO/a.txt
err 1 not_found any -- file open $REPO/missing.txt
ok 'has("path")' true -- explorer refresh
ok 'has("path")' true -- explorer collapse

step "ui: window, tree, snapshot, wait, focus, click, press, type, key, metrics"
ok '.windowNumber > 0' true -- ui window
ok 'type' '"object"' -- ui tree --depth 1
ok 'type' '"object"' -- ui snapshot
ok '.element.id' '"window.main"' -- ui wait window.main --timeout-ms 2000
ok '.ok' true -- ui click 'rail.tab:Parity/a'
ok '.ok' true -- ui focus 'pane.terminal:a'
ok '.element.id' '"pane.terminal:a"' -- ui wait 'pane.terminal:a' --state focused --timeout-ms 3000
err 1 conflict any -- ui focus window.main
err 1 not_found any -- ui press no.such.element
ok '.ok' true -- ui type 'echo typed-$((3*3))'
ok '.ok' true -- ui key return
ok '.name' '"a"' -- tab wait a --until typed-9 --timeout-ms 5000
ok 'type' '"object"' -- ui metrics
err 2 invalid_argument any -- ui click
err 124 timeout any -- ui wait no.such.element --timeout-ms 200

step "Ports and process stop"
ok 'type' '"array"' -- ports
ok '.' '[]' -- ports --port 1
DPID=$(raw instance show | jq .daemon.pid)
err 1 forbidden any -- process stop $DPID --identity x
err 2 invalid_argument true -- process stop not-a-pid --identity x

step "Instance, debug, daemon, skill, mcp, attach, hook, rpc"
ok '.name' "\"$DRIVE_INSTANCE\"" -- instance show
ok "[.[].name] | index(\"$DRIVE_INSTANCE\") != null" true -- instance list
text 0 'length' 0 -- instance wait
err 1 conflict true -- instance clean
GHOST="drive-t31ghost-$$"
RAW_INSTANCE=$GHOST text 0 'length' 0 -- instance stop
ok '.daemon.pid' "$DPID" -- debug stats
ok '.pid' "$DPID" -- daemon
text 0 "startswith(\"---\\nname: mapo\\n\")" true -- skill
print $(raw skill | cmp -s - "$MAPO_ROOT/plugin/skills/mapo/SKILL.md" && print true || print false) | expect_json . true
err 1 forbidden any -- mcp
err 1 not_found true -- attach --tab nope
text 0 'length' 0 -- hook
ok '[.[].name] | index("a") != null' true -- rpc tab.list
err 2 invalid_argument any -- rpc tab.list '{"bogus":1}'
err 2 invalid_argument any -- rpc tab.list 'not json'

step "Usage errors exit 2 with a PROTOCOL §4 line when piped"
err 2 invalid_argument true -- tab
err 2 invalid_argument true -- tab bogus
err 2 invalid_argument true -- bogus
err 2 invalid_argument true -- tab list --bogus

step "On a terminal: tables, raw text, and errors as text"
tty 'split("\n")[0] | test("^NAME +KIND +STATE +CWD +TITLE$")' true -- tab list
tty 'split("\n") | map(select(test("^a +shell +idle "))) | length' 1 -- tab list
tty '[contains("1 2 3"), startswith("{")]' '[true,false]' -- tab read a --lines 40
tty '.' '"tty-run\n"' -- tab run a 'echo tty-run'
tty 'split("\n")[0:2]' '["main  1 files  +1 −0","M  a.txt  +1 −0"]' -- git changes $REPO
tty 'split("\n")[0:2]' '["mapo: Tab \"nope\" not found in workspace \"Parity\"","mapo tab list --workspace '"'"'Parity'"'"'"]' -- tab close nope
tty '[(split("\n")[0] | fromjson | type), (split("\n") | length)]' '["array",2]' -- tab list --json
tty 'startswith("error: unrecognized subcommand '"'"'bogus'"'"'")' true -- tab bogus

step "Every verb from the help had a row"
verbs=()
for n in ${(f)"$(raw --help | sed -n '/^Commands:/,/^$/p' | awk 'NR > 1 && NF { print $1 }')"}; do
    [[ $n == help ]] && continue
    subs=(${(f)"$(raw $n --help | sed -n '/^Commands:/,/^$/p' | awk 'NR > 1 && NF && $1 != "help" { print $1 }')"})
    if (( ${#subs} )); then for s in $subs; do verbs+=("$n $s"); done; else verbs+=("$n"); fi
done
verbs+=(hook rpc)
missing=()
for v in $verbs; do (( ${+COVERED[$v]} )) || missing+=("$v"); done
print "   ${#verbs} verbs in the help (with hidden hook and rpc), $(( ${#verbs} - ${#missing} )) covered, $(( $(wc -l < $ROWS) - 1 )) rows"
print -r -- "${(j:, :)verbs}" > "$EVIDENCE/verbs.txt"
print -r -- "[${(j:,:)${(@)missing/(#m)*/\"$MATCH\"}}]" | expect_json . '[]'

drive_end
