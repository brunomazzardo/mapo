# drives/lib.sh: helpers every drive sources (ENGINEERING §5.2).
#
# A drive is a scripted person. It acts through `mapo ui`, checks with the CLI, and leaves
# evidence in evidence/<drive>/<ts>/. It never touches the worktree's own instance, `main`,
# other drives or the frozen app, and it stops only the pids it started.
#
# Stages: T0.2 lock, naming, evidence, step, expect_json, timing, mapo; T0.3 daemon start and
# stop; T0.9 app, ui_snapshot, ui_shot. Until T0.9, DRIVE_NO_APP=1 starts only the daemon.

zmodload zsh/datetime zsh/mathfunc
setopt extended_glob

MAPO_ROOT=${MAPO_ROOT:-${${(%):-%x}:A:h:h}}
MAPO_PROFILE=${MAPO_PROFILE:-debug}
MAPO_BIN="$MAPO_ROOT/target/$MAPO_PROFILE/mapo"
case $MAPO_PROFILE in release) MAPO_CONFIG_NAME=Release ;; *) MAPO_CONFIG_NAME=Debug ;; esac
MAPO_APP="$MAPO_ROOT/.build/xcode/Build/Products/$MAPO_CONFIG_NAME/Mapo.app"
DRIVE_LOCK="$HOME/Library/Caches/mapo/drive.lock"

typeset -gA BUDGET_MS
BUDGET_MS=(
    daemon-ready 1000
    app-ready 2000
    launch 400
    new-workspace 150
    new-tab 150
    workspace-switch 50
    tab-focus 50
    app-reattach 500
)

typeset -g DRIVE_NAME="" DRIVE_INSTANCE="" EVIDENCE="" DRIVE_TMP="" SNAP="" SHOT=""
typeset -g DRIVE_STEP=00 DRIVE_STEP_TEXT="" PIXELS=unavailable
typeset -gi DRIVE_FAILS=0 DRIVE_PASSES=0 DRIVE_ENDED=0 DRIVE_DAEMON_PID=0 DRIVE_APP_PID=0 DRIVE_HAVE_LOCK=0
typeset -gF DRIVE_T0=0
typeset -ga DRIVE_TIMINGS DRIVE_STEPS

# zsh runs an EXIT trap set inside a function when that function returns, so set it here.
trap drive_end EXIT
trap 'DRIVE_FAILS+=1; exit 130' INT TERM

_drive_ms() { print -- $(( int((EPOCHREALTIME - $1) * 1000) )) }

_drive_log() { print -r -- "$*" >> "$EVIDENCE/log.txt" }

# The CLI bound to the drive's instance, as the operator, always JSON. Logs call, exit and ms.
mapo() {
    local t=$EPOCHREALTIME rc=0
    env -u MAPO_TOKEN -u MAPO_HOOK_TOKEN -u MAPO_ATTACH_TOKEN \
        "$MAPO_BIN" --instance "$DRIVE_INSTANCE" --json "$@" || rc=$?
    [[ -n $EVIDENCE ]] && _drive_log "   mapo ${(j: :)${(q-)@}} -> exit $rc, $(_drive_ms $t) ms"
    return $rc
}

_drive_lock() {
    [[ ${DRIVE_NOLOCK:-0} == 1 ]] && return 0
    mkdir -p "${DRIVE_LOCK:h}"
    local waited=0 owner
    while ! mkdir "$DRIVE_LOCK" 2>/dev/null; do
        owner=$(cat "$DRIVE_LOCK/pid" 2>/dev/null || true)
        if [[ -n $owner ]] && ! kill -0 "$owner" 2>/dev/null; then
            rm -rf "$DRIVE_LOCK"
            continue
        fi
        (( waited == 0 )) && print -u2 "drive: waiting for drive.lock (owner pid ${owner:-?})"
        (( waited += 1 ))
        if (( waited > 600 )); then print -u2 "drive: drive.lock still held after 10 min"; return 1; fi
        sleep 1
    done
    print -- $$ > "$DRIVE_LOCK/pid"
    DRIVE_HAVE_LOCK=1
}

_drive_unlock() {
    if (( DRIVE_HAVE_LOCK )) && [[ $(cat "$DRIVE_LOCK/pid" 2>/dev/null) == $$ ]]; then
        rm -rf "$DRIVE_LOCK"
    fi
    DRIVE_HAVE_LOCK=0
}

_drive_json_str() { jq -Rn --arg s "$1" '$s' }

# Starts the drive's daemon, detached, and records its pid. Available from T0.3.
_drive_start_daemon() {
    local t=$EPOCHREALTIME out
    if ! "$MAPO_BIN" daemon --help >/dev/null 2>&1; then
        _drive_log "   daemon: not yet (PLAN T0.3)"
        return 0
    fi
    out=$(mapo daemon) || { print -u2 "drive: daemon failed to start"; return 1; }
    DRIVE_DAEMON_PID=$(print -r -- "$out" | jq -r .pid)
    _drive_record_timing daemon-ready $(_drive_ms $t)
}

_drive_stop_daemon() {
    (( DRIVE_DAEMON_PID )) || return 0
    mapo instance stop >/dev/null 2>&1 || true
    if kill -0 $DRIVE_DAEMON_PID 2>/dev/null; then
        _drive_log "   daemon pid $DRIVE_DAEMON_PID survived instance stop"
        DRIVE_FAILS+=1
    fi
}

# Starts the app for the drive's instance. Available from T0.9.
_drive_start_app() {
    [[ ${DRIVE_NO_APP:-0} == 1 ]] && return 0
    if [[ ! -x "$MAPO_APP/Contents/MacOS/Mapo" ]] || ! typeset -f ui_snapshot >/dev/null; then
        _drive_log "   app: not yet (PLAN T0.9); set DRIVE_NO_APP=1"
        return 0
    fi
    _drive_start_app_impl
}

_drive_stop_app() {
    (( DRIVE_APP_PID )) || return 0
    kill -TERM $DRIVE_APP_PID 2>/dev/null || return 0
    local i
    for i in {1..50}; do kill -0 $DRIVE_APP_PID 2>/dev/null || return 0; sleep 0.1; done
    kill -KILL $DRIVE_APP_PID 2>/dev/null || true
}

_drive_record_timing() { # name ms
    local budget=${BUDGET_MS[$1]:-null}
    DRIVE_TIMINGS+=("{\"step\":\"$DRIVE_STEP\",\"name\":\"$1\",\"ms\":$2,\"budgetMs\":$budget}")
    _drive_log "   timing $1: $2 ms (budget $budget)"
}

# drive_begin NAME: lock, instance, evidence folder, daemon (and app from T0.9).
drive_begin() {
    DRIVE_NAME=$1
    if [[ ! $DRIVE_NAME =~ '^[a-z0-9-]{1,19}$' ]]; then print -u2 "drive: bad name $DRIVE_NAME"; exit 2; fi
    if [[ ! -x $MAPO_BIN ]]; then print -u2 "drive: $MAPO_BIN is missing; run just build"; exit 1; fi
    _drive_lock || exit 1
    DRIVE_T0=$EPOCHREALTIME
    DRIVE_INSTANCE="drive-$DRIVE_NAME-$(strftime %H%M%S $EPOCHSECONDS)"
    local data
    data=$("$MAPO_BIN" --instance "$DRIVE_INSTANCE" instance show --json | jq -r .dataDir)
    if [[ -e $data ]]; then print -u2 "drive: instance $DRIVE_INSTANCE already exists"; _drive_unlock; exit 1; fi
    EVIDENCE="$MAPO_ROOT/evidence/$DRIVE_NAME/$(strftime %Y%m%d-%H%M%S $EPOCHSECONDS)"
    mkdir -p "$EVIDENCE"
    DRIVE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/mapo-$DRIVE_NAME.XXXXXX")
    exec > >(tee -a "$EVIDENCE/log.txt") 2>&1
    print "== drive $DRIVE_NAME, instance $DRIVE_INSTANCE"
    print "   commit $(git -C "$MAPO_ROOT" rev-parse --short HEAD)$([[ -n $(git -C "$MAPO_ROOT" status --porcelain) ]] && print ' (dirty)'), build $MAPO_PROFILE"
    print "   load $(sysctl -n vm.loadavg)"
    if [[ -n ${DRIVE_CONFIG:-} ]]; then
        mkdir -p "$data"; chmod 700 "$data"; cp "$DRIVE_CONFIG" "$data/config.toml"
    fi
    _drive_start_daemon || exit 1
    _drive_start_app || exit 1
}

# step "text": numbers and logs a step.
step() {
    DRIVE_STEP=${(l:2::0:)$(( 10#$DRIVE_STEP + 1 ))}
    DRIVE_STEP_TEXT=$1
    DRIVE_STEPS+=("$DRIVE_STEP|$1|$DRIVE_PASSES|$DRIVE_FAILS")
    print "== [$DRIVE_STEP] $1 (+$(_drive_ms $DRIVE_T0) ms)"
}

# expect_json FILTER EXPECTED: stdin JSON through jq -c FILTER must equal EXPECTED.
expect_json() {
    local filter=$1 expected=$2 input actual want
    input=$(cat)
    actual=$(print -r -- "$input" | jq -c "$filter" 2>&1) || true
    want=$(print -r -- "$expected" | jq -c . 2>/dev/null) || want=$expected
    if [[ $actual == "$want" ]]; then
        DRIVE_PASSES+=1
        print "   PASS $filter == $want"
        return 0
    fi
    DRIVE_FAILS+=1
    print "   FAIL $filter: expected $want, got ${actual[1,2048]}"
    typeset -f ui_snapshot >/dev/null && { ui_snapshot fail || true; }
    typeset -f ui_shot >/dev/null && { ui_shot fail || true; }
    return 1
}

# timing NAME CMD...: runs CMD and records its duration against BUDGET_MS[NAME].
timing() {
    local name=$1; shift
    local t=$EPOCHREALTIME rc=0
    "$@" || rc=$?
    _drive_record_timing "$name" $(_drive_ms $t)
    return $rc
}

_drive_summary() {
    local result=$1 took=$2
    local commit; commit=$(git -C "$MAPO_ROOT" rev-parse --short HEAD)
    {
        print -r -- "# $DRIVE_NAME: $result"
        print
        print -r -- "- Checks: $DRIVE_PASSES passed, $DRIVE_FAILS failed"
        print -r -- "- Started: $(strftime '%Y-%m-%d %H:%M:%S %z' ${DRIVE_T0%.*}), took $(printf %.1f $(( took / 1000.0 ))) s"
        print -r -- "- Commit: $commit, build: $MAPO_PROFILE, instance: $DRIVE_INSTANCE"
        print -r -- "- Pixels: $PIXELS. Load average: $(sysctl -n vm.loadavg)"
        print
        print -r -- "## Steps"
        print -r -- "| # | Step | Checks |"
        print -r -- "|---|---|---|"
        local s n text p f i next_p next_f
        for (( i = 1; i <= ${#DRIVE_STEPS}; i++ )); do
            IFS='|' read -r n text p f <<< "${DRIVE_STEPS[$i]}"
            if (( i < ${#DRIVE_STEPS} )); then
                IFS='|' read -r _ _ next_p next_f <<< "${DRIVE_STEPS[$((i + 1))]}"
            else
                next_p=$DRIVE_PASSES; next_f=$DRIVE_FAILS
            fi
            print -r -- "| $n | $text | $(( next_p - p ))/$(( next_p - p + next_f - f )) |"
        done
        print
        print -r -- "## Failures"
        if (( DRIVE_FAILS )); then grep -E '^   FAIL' "$EVIDENCE/log.txt" || print -r -- "(see log.txt)"; else print -r -- "None."; fi
        print
        print -r -- "## Timings and budgets"
        print -r -- "| Name | ms | Budget | Verdict |"
        print -r -- "|---|---|---|---|"
        local t
        for t in "${DRIVE_TIMINGS[@]}"; do
            print -r -- "$t" | jq -r '"| \(.name) | \(.ms) | \(.budgetMs // "-") | \(if .budgetMs == null then "-" elif .ms > .budgetMs then "over" elif .ms > .budgetMs * 0.8 then "warn" else "ok" end) |"'
        done
        print
        print -r -- "## Review"
        print -r -- "- Looked at:"
        print -r -- "- Feels right:"
        print -r -- "- Feels wrong:"
        print -r -- "- Not verified:"
        print -r -- "- Verdict:"
    } > "$EVIDENCE/summary.md"
    print -r -- "[${(j:,:)DRIVE_TIMINGS}]" | jq \
        --arg drive "$DRIVE_NAME" --arg instance "$DRIVE_INSTANCE" --arg profile "$MAPO_PROFILE" \
        --arg commit "$commit" --arg pixels "$PIXELS" --arg load "$(sysctl -n vm.loadavg)" \
        '{drive: $drive, instance: $instance, profile: $profile, commit: $commit, pixels: $pixels, loadavg: $load, timings: .}' \
        > "$EVIDENCE/timings.json"
}

# drive_end: idempotent teardown; exits 0 only if every check passed.
drive_end() {
    local rc=$?
    [[ -z $DRIVE_NAME ]] && return
    (( DRIVE_ENDED )) && return
    DRIVE_ENDED=1
    trap - EXIT INT TERM
    (( rc != 0 )) && { DRIVE_FAILS+=1; print "   FAIL the drive exited with status $rc at step $DRIVE_STEP"; }
    if typeset -f ui_snapshot >/dev/null && (( DRIVE_APP_PID )); then
        ui_snapshot end || true
        ui_shot end || true
        mapo ui metrics > "$EVIDENCE/metrics.json" 2>/dev/null || true
    fi
    mapo debug stats > "$EVIDENCE/stats.json" 2>/dev/null || true
    _drive_stop_app
    _drive_stop_daemon
    local left
    left=$(pgrep -f -- "--instance $DRIVE_INSTANCE( |\$)" || true)
    if [[ -n $left ]]; then
        DRIVE_FAILS+=1
        print "   FAIL processes left for $DRIVE_INSTANCE: ${(f)left}"
    fi
    local logdir
    logdir=$("$MAPO_BIN" --instance "$DRIVE_INSTANCE" instance show --json 2>/dev/null | jq -r .logDir)
    for f in "$logdir"/mapod.*.log(N) "$logdir"/app.*.log(N); do
        print "--- tail $f:t" >> "$EVIDENCE/log.txt"
        tail -n 200 "$f" >> "$EVIDENCE/log.txt"
    done
    local result=PASS
    (( DRIVE_FAILS )) && result=FAIL
    _drive_summary $result $(_drive_ms $DRIVE_T0)
    if [[ $result == PASS && ${DRIVE_KEEP:-0} != 1 ]]; then
        "$MAPO_BIN" --instance "$DRIVE_INSTANCE" instance clean >/dev/null 2>&1 || true
        rm -rf "$DRIVE_TMP"
    fi
    local old
    old=("$MAPO_ROOT/evidence/$DRIVE_NAME"/*(N/On[21,-1]))
    (( ${#old} )) && rm -rf "${old[@]}"
    _drive_unlock
    print "== $DRIVE_NAME: $result ($DRIVE_PASSES passed, $DRIVE_FAILS failed)"
    print -r -- "$EVIDENCE"
    [[ $result == PASS ]] && exit 0 || exit 1
}
