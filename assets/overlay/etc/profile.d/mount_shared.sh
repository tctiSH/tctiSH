umount /ios_host

# cache=readahead: reads go through the page cache with read-ahead, so a file read in small pieces
# costs a few large 9p requests rather than one round trip per piece, each of which puts the reader
# to sleep and wakes it again in emulated code. Several times faster to read, under either backend.
#
# It stays coherent with changes made on the iOS side: a file's cached pages are kept from open to
# close, and dropped at the next open if its version (QEMU's: mtime in seconds, and size) changed.
# Writes still go straight to the host.
mount -t 9p -o trans=virtio,cache=readahead shared /ios_host -oversion=9p2000.L
