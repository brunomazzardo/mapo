# Mapo shell integration, stage 1 (ARCHITECTURE §3.4). The daemon points ZDOTDIR here; restore the
# user's ZDOTDIR, run their .zshenv, then load the integration in interactive shells. zsh reads
# .zprofile, .zshrc and .zlogin from the restored ZDOTDIR on its own.
builtin typeset -g _mapo_integration_dir=${${(%):-%x}:A:h}
if [[ -n ${MAPO_ZSH_ZDOTDIR+set} ]]; then
    builtin export ZDOTDIR=$MAPO_ZSH_ZDOTDIR
    builtin unset MAPO_ZSH_ZDOTDIR
else
    builtin unset ZDOTDIR
fi
if [[ -r ${ZDOTDIR:-$HOME}/.zshenv ]]; then
    builtin source ${ZDOTDIR:-$HOME}/.zshenv
fi
if [[ -o interactive && -r $_mapo_integration_dir/mapo-integration.zsh ]]; then
    builtin source $_mapo_integration_dir/mapo-integration.zsh
fi
