# Mapo shell integration for zsh 5.1+ (ARCHITECTURE §3.4, PLAN T0.5 step 3).
# Reports the cwd (OSC 7), prompt and command boundaries with exit codes (OSC 133 A/B/C/D) and a
# title (OSC 2). Written for Mapo; prints nothing but escape sequences.
autoload -Uz is-at-least 2>/dev/null
is-at-least 5.1 || builtin return 0
[[ -n $_mapo_integrated ]] && builtin return 0
builtin typeset -g _mapo_integrated=1 _mapo_running= _mapo_fd= _mapo_ps1_marked=

# Marks go to a close-on-exec fd on the tty, so a redirected stdout can't swallow them.
builtin zmodload zsh/system 2>/dev/null
if [[ -n $TTY ]] && builtin sysopen -w -o cloexec -u _mapo_fd -- $TTY 2>/dev/null; then :; else _mapo_fd=1; fi

_mapo_emit() { builtin print -rnu $_mapo_fd -- "$1" 2>/dev/null }

_mapo_urlencode() {
    builtin emulate -L zsh
    builtin setopt no_multibyte
    local s=$1 out= c i
    for (( i = 1; i <= ${#s}; i++ )); do
        c=${s[i]}
        if [[ $c == [A-Za-z0-9/._~-] ]]; then out+=$c; else out+=$(builtin printf '%%%02X' "'$c"); fi
    done
    builtin print -rn -- $out
}

_mapo_report_cwd() {
    _mapo_emit $'\e]7;file://'"${HOST}$(_mapo_urlencode "$PWD")"$'\e\\'
}

# 133;A and B wrap the prompt; B ends in ST because some plugins strip BEL-terminated marks.
_mapo_mark_ps1() {
    [[ $PS1 == *$'\e]133;A'* ]] && builtin return
    PS1=$'%{\e]133;A\e\\%}'"$PS1"$'%{\e]133;B\e\\%}'
    _mapo_ps1_marked=1
}

_mapo_unmark_ps1() {
    PS1=${PS1//$'%{\e]133;A\e\\%}'/}
    PS1=${PS1//$'%{\e]133;B\e\\%}'/}
}

_mapo_precmd() {
    local ret=$?
    # zle can run precmd again (reset-prompt); only a real command end reports D.
    if [[ -n $_mapo_running ]]; then
        _mapo_emit $'\e]133;D;'"$ret"$'\e\\'
        _mapo_running=
    fi
    _mapo_report_cwd
    _mapo_emit $'\e]2;'"${(%):-%~}"$'\a'
    _mapo_mark_ps1
}

_mapo_preexec() {
    _mapo_unmark_ps1
    _mapo_running=1
    _mapo_emit $'\e]133;C\e\\'
    local title=${1//[[:cntrl:]]/}
    _mapo_emit $'\e]2;'"${title[1,80]}"$'\a'
}

_mapo_chpwd() { _mapo_report_cwd }

# Runs once, at the first prompt, after every rc file: install the real hooks last so they see
# the final PS1, and put Mapo's bin dir back in front of PATH (path_helper and rc files reorder it).
_mapo_first_precmd() {
    local ret=$?
    precmd_functions=(${precmd_functions:#_mapo_first_precmd})
    precmd_functions+=(_mapo_precmd)
    preexec_functions+=(_mapo_preexec)
    chpwd_functions+=(_mapo_chpwd)
    if [[ -n $MAPO_BIN_DIR ]]; then
        path=($MAPO_BIN_DIR ${path:#$MAPO_BIN_DIR})
    fi
    _mapo_report_cwd
    _mapo_emit $'\e]2;'"${(%):-%~}"$'\a'
    _mapo_mark_ps1
    return $ret
}

builtin typeset -ga precmd_functions preexec_functions chpwd_functions
precmd_functions+=(_mapo_first_precmd)
