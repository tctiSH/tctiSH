#
# Ask before poweroff or halt in an interactive shell.
#
# In tctiSH neither ends with a machine to switch back on. QEMU runs inside the
# app, so once Linux stops, every terminal goes dead until tctiSH is opened
# again, and Linux then starts afresh. reboot is left alone: the app follows a
# reboot by itself.
#
# Only for interactive shells: a script, or `sh -lc`, that reads /etc/profile
# has nobody to ask. Nor is `command poweroff` asked, or a full path. A no
# fails, so that `poweroff && ...` doesn't carry on as if it had worked.
#
case $- in
*i*)
	_tctish_confirm_stop() {
		echo "$1 stops Linux, and every terminal with it, until tctiSH is opened again."
		printf 'Linux then starts afresh. Continue? [y/N] '
		_tctish_answer=
		read -r _tctish_answer
		case "$_tctish_answer" in
		[yY]*)
			unset _tctish_answer
			command "$@"
			;;
		*)
			unset _tctish_answer
			echo "Not done."
			return 1
			;;
		esac
	}

	poweroff() { _tctish_confirm_stop poweroff "$@"; }
	halt() { _tctish_confirm_stop halt "$@"; }
	;;
esac
