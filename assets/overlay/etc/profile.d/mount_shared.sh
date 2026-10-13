# Mounts the 9p tag `shared` at /ios_host, once.
#
# Every login reads this, and the logins on hvc0 and ttyS0 start together at boot. The tag takes
# only one mount at a time, and a second gets "Resource busy", so the logins take turns and only the
# first mounts. Nor is it mounted again later: the mount carries across a saved session. A mount
# that has stopped working stays mounted, then, until unmounted by hand; another login can't tell
# a dead mount from a slow one without risking hanging on it.
#
# Mounting needs root. A login waits at most 10 seconds for its turn, so that a mount that hangs
# holds up only the login making it, and not the rest, such as the one on ttyS0.
#
# cache=readahead: reads go through the page cache with read-ahead, so a file read in small pieces
# costs a few large 9p requests rather than one round trip per piece, each of which puts the reader
# to sleep and wakes it again in emulated code. Several times faster to read, under either backend.
#
# It stays coherent with changes made on the iOS side: a file's cached pages are kept from open to
# close, and dropped at the next open if its version (QEMU's: mtime in seconds, and size) changed.
# Writes still go straight to the host.
if [ "$(id -u)" = 0 ]; then
	(
		# busybox's flock can't time out, so timeout runs it. The lock belongs to the open file,
		# so it stays held after flock exits.
		if ! timeout 10 flock 9 2>/dev/null; then
			echo "tctiSH: another login is still mounting /ios_host, so this one didn't wait."
			exit
		fi
		grep -qs '^shared /ios_host 9p ' /proc/mounts ||
			mount -t 9p -o trans=virtio,cache=readahead shared /ios_host -oversion=9p2000.L
	) 9>>/run/lock/tctish-share
fi
