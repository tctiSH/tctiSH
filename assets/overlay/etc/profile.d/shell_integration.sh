#
# Set up the prompt that makes TCTI stuff work.
#
_normal=$'\e[0m'
_color=$'\e[1;35m'

# Emit the CWD after any command, so the host can use it.
PS1="\[$_color"'\033]7;$(pwd)\033\\ \]_\w\$ '"\[$_normal\]"
unset _normal _color

# Switch to a CWD if we're supposed to have one.
CWDFILE="/ios_host/last_cwd.dat"
if [ -f $CWDFILE ]; then
	cd $(cat $CWDFILE)
	rm -f $CWDFILE
else
	cat /etc/tcti_motd
fi
