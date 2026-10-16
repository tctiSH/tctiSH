# Starts the command set in tctiSH's Settings > Terminals, such as xonsh or tmux, in place of the
# shell's prompt.
#
# Last in profile.d, hence the name, so that the motd and the prompt's setup come first. Runs only
# in the login shell that tctish-login starts on an hvc console. login leads that session and runs
# the shell as its child, so the shell's parent leads the session. A shell started by hand (sh -l,
# su -) has a parent that doesn't, and the recovery login on ttyS0 isn't on an hvc console, so both
# keep the shell.
#
# Every login reads this, so the checks start no processes: they read /proc/$$/stat. tctish-agent
# writes the command to a file as Linux comes up and when the setting changes. A login before that,
# early in a boot, asks the app through tctictl instead, for at most 3 seconds, since another
# tctictl may hold the port. With no answer, the shell stays and says nothing.
#
# The command runs in a subshell that reads ~/.profile first, as the shell would before its prompt,
# so that a PATH set there (to ~/.local/bin, say) finds it. When it ends, the session ends, as
# exiting the shell does, and the next one starts the command again.
#
# The shell stays instead, and says why, when the command can't have been used: it ends within 3
# seconds, as one that isn't found does, or fails within 10, as one that can't start does under
# emulation. Otherwise a command that fails at once would start again for as long as the terminal
# is open. The shell also stays when Ctrl-Z stops the command, so fg can bring it back.
#
# local isn't POSIX, but ash and bash, the shells that read profile.d here, both have it.
# shellcheck disable=SC3043
_tctish_default_command() {
	case "$-" in
	*i*) ;;
	*) return ;;
	esac

	# After the command's name, which is in parentheses: state, ppid, pgrp, session, then the
	# terminal's device number.
	local _tctish_stat
	read -r _tctish_stat <"/proc/$$/stat" || return
	# shellcheck disable=SC2086
	set -- ${_tctish_stat##*') '}
	# Its parent, login, leads the session: busybox login, as tctish-login runs it, whose name is
	# busybox's. A shell typed at the prompt has a parent that's a shell. A busybox built without
	# LOGIN_SESSION_AS_CHILD runs the shell in login's place, so that it leads the session itself.
	local _tctish_parent=
	[ "${4:-}" = "${2:-}" ] && read -r _tctish_parent <"/proc/$2/comm"
	case "$_tctish_parent" in
	login | busybox) ;;
	*) [ "${4:-}" = "$$" ] || return ;;
	esac
	# The hvc consoles' major number is 229, in bits 8 to 19.
	[ $(((${5:-0} >> 8) & 4095)) -eq 229 ] || return
	# So that the command's "$@" is empty, as at a prompt.
	set --

	# Prefixed, since ~/.profile and the command run with these set.
	local _tctish_file=/run/tctish/default-command _tctish_command=
	if [ -e "$_tctish_file" ]; then
		# Empty for none, which read fails on.
		read -r _tctish_command <"$_tctish_file"
	else
		_tctish_command="$(timeout 3 tctictl lowlevel default-command 2>/dev/null)" || return
	fi
	[ -n "$_tctish_command" ] || return

	local _tctish_started _tctish_ended _tctish_status
	read -r _tctish_started _ </proc/uptime
	# Ctrl-C ends the command. Untrapped, ash would pass it on and stop reading /etc/profile here,
	# leaving the shell rather than ending the session. The command gets the usual Ctrl-C.
	trap : INT
	# A function, so that a job stopped with Ctrl-Z is listed by its name rather than as the whole
	# subshell.
	(tctish_default_command)
	_tctish_status=$?
	trap - INT
	read -r _tctish_ended _ </proc/uptime
	# In hundredths of a second, as the uptime has two decimals, and without leading zeros, which
	# would read as octal: an uptime under a second, as in a fresh container, has some.
	_tctish_started=${_tctish_started%.*}${_tctish_started#*.}
	_tctish_started=${_tctish_started#"${_tctish_started%%[!0]*}"}
	_tctish_ended=${_tctish_ended%.*}${_tctish_ended#*.}
	_tctish_ended=${_tctish_ended#"${_tctish_ended%%[!0]*}"}
	local _tctish_ran=$((${_tctish_ended:-0} - ${_tctish_started:-0}))

	# Stopped by SIGSTOP, SIGTSTP, SIGTTIN or SIGTTOU.
	[ "$_tctish_status" -ge 147 ] && [ "$_tctish_status" -le 150 ] && return

	# Done with, or ended by a signal (Ctrl-C, a hangup), after it ran.
	if [ "$_tctish_status" -eq 0 ] || [ "$_tctish_status" -gt 128 ]; then
		[ "$_tctish_ran" -ge 300 ] && exit "$_tctish_status"
	elif [ "$_tctish_ran" -ge 1000 ]; then
		exit "$_tctish_status"
	fi

	local _tctish_what
	if [ "$_tctish_status" -eq 127 ]; then
		_tctish_what="not found"
	elif [ "$_tctish_status" -eq 0 ] || [ "$_tctish_status" -gt 128 ]; then
		_tctish_what="ended immediately"
	else
		_tctish_what="failed (status $_tctish_status)"
	fi
	# The command and sh in bold, in the theme's ANSI green. The command goes in as an argument, so
	# that a % or \ in it prints as it is.
	printf 'tctiSH: \033[1;32m%s\033[0m %s, remaining in \033[1;32msh\033[0m\n' \
		"$_tctish_command" "$_tctish_what"
	echo "Change it in Settings > Terminals > Command"
}

# The default command, run in place of the prompt: ~/.profile, as the shell would read it first, and
# then the command.
tctish_default_command() {
	# shellcheck disable=SC1091
	[ -r "$HOME/.profile" ] && . "$HOME/.profile"

	# A program that isn't found isn't run, so that the shell doesn't say so too. Only a plain
	# name is looked up: one with quotes, ~ or an assignment in it, say, is left to the shell.
	local _tctish_program
	set -f
	# shellcheck disable=SC2086
	set -- $_tctish_command
	set +f
	_tctish_program="${1:-}"
	set --
	case "$_tctish_program" in
	*[!A-Za-z0-9_./+-]*) ;;
	*) command -v "$_tctish_program" >/dev/null || return 127 ;;
	esac

	eval "$_tctish_command"
}

_tctish_default_command
unset -f _tctish_default_command tctish_default_command
