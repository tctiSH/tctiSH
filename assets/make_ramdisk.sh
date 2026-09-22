#!/bin/bash
#
# Repacks the unpacked ramdisk/ directory into initrd.img.
#
# This is the hand-edit path: dev_ramdisk.sh unpacks initrd.img into ramdisk/,
# you change files there, and this packs them back. It is for quick experiments
# inside the guest.
#
# It is *not* how the shipped image is produced. build_rootfs.sh builds that from
# a pinned Alpine minirootfs plus rootfs.lock, and running this afterwards will
# overwrite the result with whatever happens to be in ramdisk/.
#
set -euo pipefail

ASSETS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -d "$ASSETS/ramdisk" ] || {
    echo "error: no unpacked ramdisk at $ASSETS/ramdisk. Run dev_ramdisk.sh first." >&2
    exit 1
}

# -H newc is the format the kernel's initramfs loader reads.
#
# Note there is no -c. GNU cpio rejects `-c -H newc` outright, as "Archive format
# multiply defined", where BSD cpio accepts the pair and ignores the redundancy --
# so the old spelling worked on macOS and failed on Linux. Since the real build
# now runs in a Linux container, keep the portable form here too.
#
# The sort and gzip -n are for the same reason build_rootfs.sh uses them: without
# them the archive depends on readdir order and carries a build timestamp, so two
# packs of identical trees produce different bytes.
(
    cd "$ASSETS/ramdisk"
    find . | LC_ALL=C sort | cpio -o -H newc --quiet
) | gzip -9 -n >"$ASSETS/initrd.img"

echo "packed $(du -h "$ASSETS/initrd.img" | cut -f1) into ${ASSETS##*/}/initrd.img"
