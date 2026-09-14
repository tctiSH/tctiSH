#!/bin/bash
#
# Builds the utility, and copies the result into our ramdisk.
#
# `tctictl` is the guest-side configuration tool: it ships inside initrd.img at
# ./bin/tctictl and talks to the app, so that things only the host can do -- a
# file picker, mounting an iOS folder -- can be asked for from inside the VM.
#
set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS="$BASEDIR/../../assets"
RAMDISK_BIN="$ASSETS/ramdisk/bin"

TARGET="x86_64-unknown-linux-musl"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# The devshell provides Rust with the musl target, and points cargo at rustc's
# bundled lld for it -- Apple's `ld` cannot link the target. Run this through
# `nix develop --command`, or as `make tctictl`, rather than expecting a global
# cargo to have had `rustup target add` run against it.
command -v cargo >/dev/null 2>&1 || {
    echo -e "${RED}'cargo' not found.${NC}" >&2
    exit 1
}

# The unpacked ramdisk isn't in the repo -- it's gitignored, and built by
# whatever produced initrd.img. Say so plainly rather than letting `cp` fail
# with something less helpful.
[ -d "$RAMDISK_BIN" ] || {
    echo -e "${RED}No unpacked ramdisk at $RAMDISK_BIN.${NC}" >&2
    echo "It isn't in the repo; unpack initrd.img there first." >&2
    exit 1
}

echo -e "${GREEN}Building tctictl for $TARGET...${NC}"
(cd "$BASEDIR" && cargo build --release --target="$TARGET")

echo -e "${GREEN}Copying into the ramdisk...${NC}"
cp "$BASEDIR/target/$TARGET/release/tctictl" "$RAMDISK_BIN"

echo -e "${GREEN}Repacking initrd.img...${NC}"
(cd "$ASSETS" && ./make_ramdisk.sh)

echo -e "${GREEN}Done: $ASSETS/initrd.img${NC}"
