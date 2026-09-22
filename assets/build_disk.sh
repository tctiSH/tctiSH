#!/bin/bash
#
# Builds assets/empty.qcow, the blank persistent store the app copies out of its
# bundle the first time it runs (QEMU.swift, getPersistentStore).
#
# It is not actually empty: it carries a made ext4 filesystem. That is deliberate
# and worth keeping. init can format the disk itself -- it notices a failed mount
# and runs mkfs.ext4 -- but doing that on first boot costs the user a mkfs of a
# 200 GiB filesystem under emulation, on the very first launch, which is the
# worst possible moment for it. Shipping it made means first boot just mounts.
#
# Like build_rootfs.sh this re-execs into a Linux container, and for the same
# reason: it needs mke2fs. It does not need Rosetta -- ext4 is little-endian on
# disk by definition, so an aarch64 mke2fs writes the same bytes an x86_64 one
# would.
#
set -euo pipefail

ASSETS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$ASSETS/.." && pwd)"

OUT="$ASSETS/empty.qcow"

# Matches what has shipped since 2022. The guest sees a 200 GiB disk regardless
# of how much space iOS actually has; qcow2 keeps it sparse, so the file on disk
# is the filesystem metadata and nothing else.
DISK_SIZE="200G"

# Fixed, because mke2fs would otherwise generate them randomly and no two builds
# would agree. The UUID is the one the shipped image already has, so nothing
# observable in the guest changes.
FS_UUID="967deadd-54f8-4333-a683-6acc843cbb76"
HASH_SEED="9f2b1c74-3e5a-4d81-b6c0-2a7e8d4f1b93"

# Spelled out rather than left to mke2fs defaults, which move between e2fsprogs
# releases. Two reasons: a newer mke2fs would otherwise silently change the image,
# and it could enable an on-disk feature the guest kernel does not implement --
# which shows up as a mount failure on device, not as a build error.
#
# The leading `none` matters. A bare -O list *adds to* the defaults rather than
# replacing them, so without it e2fsprogs 1.47 quietly contributes orphan_file
# and metadata_csum_seed and the list below is not the list you get.
#
# Relative to the 2022 image this adds exactly those two, deliberately: both are
# wanted, and both are old enough for the guest (orphan_file needs 5.15, which
# 6.0 and the 6.12/6.18 bump all satisfy). needs_recovery is absent because it is
# a state flag rather than a feature -- that the shipped image has it set means
# it was mounted once before being committed, so every first boot since has
# replayed a journal it did not need to.
FS_FEATURES="none,has_journal,ext_attr,resize_inode,dir_index,filetype,extent"
FS_FEATURES="$FS_FEATURES,64bit,flex_bg,sparse_super,large_file,huge_file"
FS_FEATURES="$FS_FEATURES,dir_nlink,extra_isize,metadata_csum,metadata_csum_seed"
FS_FEATURES="$FS_FEATURES,orphan_file"

export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

die() {
    echo "${RED}error:${NC} $*" >&2
    exit 1
}

note() {
    echo "${GREEN}==>${NC} $*"
}

# See the matching note in build_rootfs.sh: the devshell's $PATH filter drops
# Homebrew, and `container` lives there.
CONTAINER=""
resolve_container() {
    local candidate
    for candidate in container /opt/homebrew/bin/container /usr/local/bin/container; do
        if command -v "$candidate" >/dev/null 2>&1; then
            CONTAINER="$candidate"
            return 0
        fi
    done
    die "no 'container' runtime found. Install it with: brew install container"
}

maybe_reexec() {
    [ "$(uname -s)" = "Linux" ] && return 0

    resolve_container

    "$CONTAINER" system status >/dev/null 2>&1 ||
        die "the container runtime is not running. Start it with: container system start"

    note "re-executing inside a Linux container"
    exec "$CONTAINER" run --rm \
        -c 4 -m 4g \
        -v "$REPO:$REPO" -w "$REPO" \
        alpine:latest \
        sh -c "apk add --no-cache bash e2fsprogs qemu-img >/dev/null 2>&1 && exec bash '${BASH_SOURCE[0]}' $*"
}

main() {
    maybe_reexec "$@"

    local work raw
    work="$(mktemp -d)"
    raw="$work/disk.raw"
    # shellcheck disable=SC2064
    trap "rm -rf '$work'" EXIT

    note "mke2fs $(mke2fs -V 2>&1 | head -1 | sed 's/^mke2fs //')"

    # Sparse, so this costs nothing until mke2fs writes metadata into it.
    truncate -s "$DISK_SIZE" "$raw"

    # -F because the target is a file rather than a block device, and mke2fs
    # would otherwise ask.
    note "making ext4 ($DISK_SIZE)"
    mkfs.ext4 -q -F \
        -U "$FS_UUID" \
        -E "hash_seed=$HASH_SEED" \
        -O "$FS_FEATURES" \
        "$raw"

    # Never mount it. The shipped image was, which is why it carries a dirty
    # journal; leaving it untouched is what keeps first boot from recovering.
    note "converting to qcow2"
    qemu-img convert -f raw -O qcow2 "$raw" "$OUT.tmp"
    mv "$OUT.tmp" "$OUT"

    echo
    note "built ${OUT#"$REPO"/}"
    echo "    virtual:   $DISK_SIZE"
    echo "    on disk:   $(du -h "$OUT" | cut -f1)"
    echo "    sha256:    $(sha256sum "$OUT" | cut -d' ' -f1)"
}

main "$@"
