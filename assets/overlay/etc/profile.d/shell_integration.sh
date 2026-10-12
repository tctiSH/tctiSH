#
# Set up the prompt that makes TCTI stuff work.
#
_normal=$'\e[0m'
_color=$'\e[1;35m'

# Emit the CWD after any command, so the host can use it.
PS1="\[$_color"'\033]7;$(pwd)\033\\ \]_\w\$ '"\[$_normal\]"
unset _normal _color

# The app's terminal draws 24-bit color, but TERM=xterm-256color doesn't say
# so, and most programs only use it when COLORTERM does.
export COLORTERM=truecolor

cat /etc/tcti_motd
