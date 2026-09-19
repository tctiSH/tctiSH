#!/usr/bin/env bash
#
# Builds idevice's FFI library for iOS, from source.
#
# StikJIT vendors a prebuilt `libidevice_ffi.a` in its submodule. We build our
# own and stage it over that copy as it is the last binary artifact in the
# build, and StikJIT's is old enough to be missing the pairing API the on-device
# pairing flow needs (`pairable_host_*`, added upstream in v0.1.64 and given an
# FFI wrapper in v0.1.68).
#
# Produces the two files StikJIT's idevice/ directory wants. The third,
# module.modulemap, does not change and is left alone.
#
# Requires the devshell's Rust toolchain, which already carries the
# aarch64-apple-ios target:
#
#     nix develop --command ./build_idevice.sh
#
set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The version we build. Bumping this is the whole of a version bump: nothing
# else in the tree names it.
IDEVICE_VERSION="${IDEVICE_VERSION:-v0.1.68}"
IDEVICE_REPO="${IDEVICE_REPO:-https://github.com/jkcoxson/idevice.git}"

TARGET="aarch64-apple-ios"

BUILD_DIR="$BASEDIR/build-idevice"
SOURCE_DIR="$BUILD_DIR/source"
OUTPUT_DIR="$BUILD_DIR/out"

# `rustcrypto` rather than the default `aws-lc`, deliberately. aws-lc-sys needs
# cmake and bindgen, and bindgen needs libclang. rustcrypto is pure Rust and
# needs none of it. `ring` is the fallback if it ever misbehaves.
#
# `full` is upstream's everything-feature; we use remote_pairing (which is where
# PairableHost lives), core_device_proxy, debug_proxy, mobile_image_mounter, rsd
# and tunnel_tcp_stack out of it. `obfuscate` matches what upstream ships.
FEATURES="${IDEVICE_FEATURES:-full,rustcrypto,obfuscate}"

# idevice's release profile sets `lto = true`, which makes rustc put LLVM
# bitcode in the archive instead of native objects. Xcode's linker then has to
# read bitcode its own LLVM does not understand.
export CARGO_PROFILE_RELEASE_LTO="${CARGO_PROFILE_RELEASE_LTO:-false}"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

check_env() {
    command -v cargo >/dev/null 2>&1 || {
        echo -e "${RED}'cargo' not found. Run inside 'nix develop'.${NC}" >&2
        exit 1
    }

    # The target has to be installed, not merely named. A missing one fails deep
    # inside the build with "can't find crate for `core`", which reads as a
    # source problem rather than a toolchain one.
    if ! rustc --print target-list | grep -qx "$TARGET"; then
        echo -e "${RED}rustc does not know the $TARGET target.${NC}" >&2
        exit 1
    fi

    # rustc works out the iOS SDK by shelling out to xcrun, so it has to be
    # reachable even though nothing here calls it directly.
    command -v xcrun >/dev/null 2>&1 || {
        echo -e "${RED}'xcrun' not found; the iOS SDK cannot be located.${NC}" >&2
        exit 1
    }
}

# Fetches the pinned tag, or updates an existing checkout to it.
#
# Shallow, single-tag: this is a build input, not something anyone reads history
# from, and the full history is a good deal larger than the one commit we want.
fetch_source() {
    if [ -d "$SOURCE_DIR/.git" ]; then
        local current
        current="$(git -C "$SOURCE_DIR" describe --tags --exact-match 2>/dev/null || echo "")"
        if [ "$current" = "$IDEVICE_VERSION" ]; then
            echo "  already at $IDEVICE_VERSION"
            return 0
        fi
        echo "  updating to $IDEVICE_VERSION"
        git -C "$SOURCE_DIR" fetch --depth 1 origin "refs/tags/$IDEVICE_VERSION:refs/tags/$IDEVICE_VERSION" --force
        git -C "$SOURCE_DIR" checkout --force "$IDEVICE_VERSION"
        return 0
    fi

    rm -rf "$SOURCE_DIR"
    mkdir -p "$(dirname "$SOURCE_DIR")"
    git clone --depth 1 --branch "$IDEVICE_VERSION" "$IDEVICE_REPO" "$SOURCE_DIR"
}

check_env

echo -e "${GREEN}Building idevice $IDEVICE_VERSION for $TARGET...${NC}"
fetch_source
echo "  $(git -C "$SOURCE_DIR" log -1 --format='%h %s')"

# Built from ffi/, because build.rs writes idevice.h relative to its own
# manifest directory and appends ffi/plist.h to it.
echo -e "${GREEN}Compiling (this takes a few minutes the first time)...${NC}"
(
    cd "$SOURCE_DIR/ffi"
    cargo build \
        --release \
        --target "$TARGET" \
        --no-default-features \
        --features "$FEATURES"
)

LIBRARY="$SOURCE_DIR/target/$TARGET/release/libidevice_ffi.a"
HEADER="$SOURCE_DIR/ffi/idevice.h"

for artifact in "$LIBRARY" "$HEADER"; do
    if [ ! -f "$artifact" ]; then
        echo -e "${RED}The build produced no $(basename "$artifact").${NC}" >&2
        exit 1
    fi
done

# Checked against the *library*. cbindgen generates declarations by reading
# source, so a feature that compiled nothing still produces a full
# header.
#
# Xcode's nm rather than the toolchain's own, deliberately: its linker is what
# has to consume this, so its opinion is the one that matters.
#
# Two `set -o pipefail` traps here, both of which turned a successful search into
# a reported failure while this was being written:
#
#   1. nm exits non-zero over the unreadable members described below, so piping
#      it straight into grep reports failure whatever grep found. Hence capturing
#      the output first.
#   2. `grep -q` exits on the first match, `printf` then dies of SIGPIPE, and
#      pipefail propagates *that*, so a pipeline into `grep -q` fails precisely
#      when it matches. Hence the herestrings below rather than pipes.
symbols="$(nm -g "$LIBRARY" 2>/dev/null || true)"
nm_errors="$(nm -g "$LIBRARY" 2>&1 >/dev/null || true)"

for symbol in _pairable_host_prepare _pairable_host_accept_fd _pairable_host_free; do
    if ! grep -q " T $symbol\$" <<<"$symbols"; then
        echo -e "${RED}The library does not export $symbol.${NC}" >&2
        echo "Either the feature set is wrong or $IDEVICE_VERSION predates it." >&2
        exit 1
    fi
done

# Rust ships std, core and compiler_builtins as bitcode, so Xcode's nm cannot
# read those members and says so. That is normal and the linker copes. Anything
# *we* compiled being unreadable is not normal as it would mean LTO put bitcode
# in our objects, which the linker would have to translate with an LLVM that has
# already been measured not to understand this one.
#
# `|| true` because grep exits non-zero when it filters everything out, which is
# the *good* case here and would otherwise take the script down silently under
# `set -e`. That is the third pipefail trap in this one check.
ours_unreadable="$(grep "error:" <<<"$nm_errors" |
    grep -Evc "(std|core|alloc|compiler_builtins|gimli|object|memchr|miniz_oxide|rustc_demangle|panic_[a-z]+|addr2line|hashbrown|unwind|libc)-[0-9a-f]+\." || true)"

if [ "$ours_unreadable" -gt 0 ]; then
    echo -e "${RED}Xcode's nm could not read $ours_unreadable non-std members.${NC}" >&2
    echo "LTO has probably put bitcode in them; see CARGO_PROFILE_RELEASE_LTO above." >&2
    grep "error:" <<<"$nm_errors" | head -5 >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
cp "$LIBRARY" "$OUTPUT_DIR/libidevice_ffi.a"
cp "$HEADER" "$OUTPUT_DIR/idevice.h"

# Recorded so build_stikjit.sh can say which version it staged, and so a stale
# output directory is identifiable without re-reading the library.
git -C "$SOURCE_DIR" rev-parse HEAD >"$OUTPUT_DIR/VERSION"
echo "$IDEVICE_VERSION" >>"$OUTPUT_DIR/VERSION"

echo -e "${GREEN}Built $OUTPUT_DIR/libidevice_ffi.a${NC}"
echo "  $(du -h "$OUTPUT_DIR/libidevice_ffi.a" | cut -f1) library, $(du -h "$OUTPUT_DIR/idevice.h" | cut -f1) header"
