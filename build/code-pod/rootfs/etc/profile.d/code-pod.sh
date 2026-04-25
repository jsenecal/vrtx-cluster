# shellcheck shell=sh
export EDITOR=vim
export PAGER=less
export LESS='-R'
export NPM_CONFIG_PREFIX=/usr/local
case ":$PATH:" in
    *":/usr/local/bin:"*) ;;
    *) export PATH="/usr/local/bin:/usr/local/sbin:$PATH" ;;
esac
