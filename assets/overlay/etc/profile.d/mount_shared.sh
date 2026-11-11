# Mounts the 9p tag `shared` at /ios_host, once, and then the folders `mount -t ios` mounted.
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
#
# With tctiSH's Write-Back Caching on, cache=mmap instead: the same, but writes are held and reach
# the host in larger pieces by ordinary writeback. That's safe because the app has Linux write out
# dirty data before each background save. tctictl asks the app which mode to use; without the app,
# or with no answer within a few seconds, it's readahead, which writes straight through.
#
# Once /ios_host is mounted, `tctictl lowlevel restore-mounts` mounts again each folder that
# `mount -t ios` mounted, where it was mounted: the app remembers both for this disk, and shares
# the folders again at each launch. It never brings up the picker: a folder that can't be reached
# stays unmounted. It runs in the background, so that no login waits for the app or a slow share,
# and without /run/lock/tctish-share, which the other logins would otherwise wait on. From before
# /ios_host is mounted until the restore is done, /run/lock/tctish-restore is held, and
# `mount -t ios` and `tctictl forget` wait for it, so that they never race the restore. What it
# says goes to the kernel log, which the app shows as Kernel Log. A resume doesn't run it: the
# mounts carry across a saved session, as /ios_host does.
if [ "$(id -u)" = 0 ]; then
  (
    # busybox's flock can't time out, so timeout runs it. The lock belongs to the open file,
    # so it stays held after flock exits.
    if ! timeout 10 flock 9 2>/dev/null; then
      echo "tctiSH: another login is still mounting /ios_host, so this one didn't wait."
      exit
    fi
    grep -qs '^shared /ios_host 9p ' /proc/mounts && exit

    cache="$(timeout 3 tctictl lowlevel share-cache 2>/dev/null)"
    [ "$cache" = mmap ] || cache=readahead

    # The restore lock. The restore below inherits fd 8, and holds the lock after this subshell has
    # exited, until it gives it back: tctictl when done, or the shell if tctictl fails or is out
    # of time. Not left to the process ending, which a folder that never answers can hold up. If
    # /ios_host doesn't mount, the lock goes with the subshell. Nothing else holds it for long.
    exec 8>>/run/lock/tctish-restore
    flock 8

    # In a new session, so that a hangup on this console doesn't kill it partway, with its output
    # sent to the kernel log a line at a time, since each write there is one record. It can wait
    # for the app behind another tctictl, such as a `mount -t ios` showing the picker, so a line
    # says so if it fails or runs out of time. (tctictl's RESTORE_WAIT is sized past the 60 s.)
    if mount -t 9p -o "trans=virtio,cache=$cache" shared /ios_host -oversion=9p2000.L; then
      setsid sh -c '{ timeout 60 tctictl lowlevel restore-mounts --release-lock-fd 8 2>&1 ||
        {
          status=$?
          flock -u 8
          echo "tctiSH: restoring mounts did not finish (status $status)"
        }; } |
        while IFS= read -r line; do echo "$line" >/dev/kmsg; done' </dev/null >/dev/null 2>&1 9>&- &
    fi
  ) 9>>/run/lock/tctish-share
fi
