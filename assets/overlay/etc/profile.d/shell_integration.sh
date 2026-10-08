#
# Set up the prompt that makes TCTI stuff work.
#
_normal=$'\e[0m'
_color=$'\e[1;35m'

# Emit the CWD after any command, so the host can use it.
PS1="\[$_color"'\033]7;$(pwd)\033\\ \]_\w\$ '"\[$_normal\]"
unset _normal _color

# The app's terminal draws 24-bit color, but TERM=xterm-256color doesn't say
# so, and most programs only use it when COLORTERM does. Set here rather than
# sent over SSH, so it doesn't depend on what the SSH server will accept.
export COLORTERM=truecolor

# Switch to a CWD if we're supposed to have one.
CWDFILE="/ios_host/last_cwd.dat"
if [ -f $CWDFILE ]; then
	cd $(cat $CWDFILE)
	rm -f $CWDFILE
else
	cat /etc/tcti_motd
fi
