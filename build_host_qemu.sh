#!/usr/bin/env bash
#
# Builds tctiSH's QEMU fork for this Mac, so that a guest booted here runs on
# the emulator the app ships rather than on an upstream one.
#
#   build_host_qemu.sh tcti|jit|hybrid-tcti|hybrid-jit|hybrid
#
# The output is build-macOS-arm64/qemu_<backend>/qemu-system-x86_64, which is
# what assets/boot_guest.sh runs. TCTI runs natively on Apple Silicon, so both
# backends can be built and booted here. The hybrid flavors build both backends
# into one QEMU (--enable-tcg-hybrid), using the one named, or for plain
# `hybrid` the one chosen at startup (-accel tcg,tcti=on for TCTI).
#
# For comparing builds, two variables let trees coexist:
#
#   HOST_QEMU_SRC   a QEMU checkout other than third-party/qemu, such as a
#                   worktree of the fork at a baseline commit
#   HOST_QEMU_TREE  a suffix for the build directory, which becomes
#                   qemu_<backend>-<suffix>; make never builds or boots these
#
# What this build shares with the app's is the source: the third-party/qemu
# checkout, with its TCG, TCTI, 9p and device work. What it does not have is
# anything behind TARGET_OS_IPHONE -- handing the code buffer to a debugger,
# the purgeable code cache, TXM -- and it is an ordinary executable rather than
# the dylib the app dlopens. Those still need a device.
#
# It builds in the flake's `host-qemu` shell, not the default one. That shell
# exists because the default one is careful to expose no libraries, as the iOS
# build cross-compiles its own and must not find the host's; a build *for* the
# host needs exactly the libraries that one keeps out. The script enters the
# shell itself, so it runs the same from a bare shell, the default devshell or
# make.
set -euo pipefail

GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
NC=$'\033[0m'

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QEMU_DIR="${HOST_QEMU_SRC:-$BASEDIR/third-party/qemu}"

die() {
    echo "${RED}error:${NC} $*" >&2
    exit 1
}

BACKEND="${1:-}"
case "$BACKEND" in
    tcti) BACKEND_FLAGS="--enable-tcg-threaded-interpreter" ;;
    jit) BACKEND_FLAGS="" ;;
    hybrid-tcti) BACKEND_FLAGS="--enable-tcg-hybrid=tcti" ;;
    hybrid-jit) BACKEND_FLAGS="--enable-tcg-hybrid=jit" ;;
    hybrid) BACKEND_FLAGS="--enable-tcg-hybrid=runtime" ;;
    *) die "usage: $(basename "$0") tcti|jit|hybrid-tcti|hybrid-jit|hybrid" ;;
esac

BUILD_ROOT="$BASEDIR/build-macOS-arm64"
BUILD_DIR="$BUILD_ROOT/qemu_$BACKEND${HOST_QEMU_TREE:+-$HOST_QEMU_TREE}"

# The binaries link against the shell's libraries in /nix/store -- glib, pixman,
# slirp -- and nothing else keeps those from a garbage collection, after which
# a binary that make considers up to date would no longer start. Entering the
# shell through a profile here makes it a GC root, and with it everything it
# references.
#
# `make unroot-host-qemu` removes just this, for whoever wants the space back.
# The Makefile treats a missing root as reason to run this script again, and
# entering the shell fetches whatever was collected, so the next boot puts it
# all back without recompiling anything.
GC_ROOT="$BUILD_ROOT/nix-gc-root"

# Re-enter through the host-qemu shell unless already in it.
#
# `nix` is looked for beyond $PATH because the default devshell filters it out
# of $PATH, and this has to work when run from inside that shell too.
if [ "${TCTISH_DEVSHELL:-}" != "host-qemu" ]; then
    NIX="$(command -v nix || true)"
    for candidate in /run/current-system/sw/bin/nix /nix/var/nix/profiles/default/bin/nix; do
        [ -n "$NIX" ] && break
        [ -x "$candidate" ] && NIX="$candidate"
    done
    [ -n "$NIX" ] || die "cannot find nix, which this build needs for its host libraries"

    mkdir -p "$BUILD_ROOT"
    exec "$NIX" develop --profile "$GC_ROOT" "$BASEDIR#host-qemu" --command "$0" "$@"
fi

# The flags follow QEMU_PLATFORM_BUILD_FLAGS in build_dependencies.sh, so that
# what is compiled in matches the app's: configure enables whatever it finds,
# and the host-qemu shell has QEMU's full nixpkgs set of libraries on offer.
# That means slirp built from its subproject and linked statically, as the app
# has it, rather than nixpkgs' libslirp, and libucontext coroutines.
#
# Where this deliberately differs:
#
#   - Debug info stays on, as this build is the one a debugger gets pointed at.
#   - Capstone is in, so that -d in_asm and out_asm disassemble the guest's
#     code and the JIT's. It only runs when something is logged.
#   - It is an executable, not --enable-shared-lib.
#   - It also turns off what an iOS SDK simply lacks and a Mac has: spice,
#     opengl, vde, curses, smartcards, the guest agent, the tools.
#
# --disable-download because prepare_qemu_source has already fetched every
# subproject configure needs.
CONFIGURE_FLAGS=(
    --target-list=x86_64-softmmu
    --disable-hvf --disable-cocoa --disable-coreaudio --disable-sdl --disable-gtk
    --disable-vnc --disable-spice --disable-opengl --disable-dbus-display
    --disable-virglrenderer --enable-capstone --disable-fdt --disable-rust
    --disable-gnutls --disable-gcrypt --disable-nettle --disable-libssh
    --disable-curl --disable-libusb --disable-usb-redir --disable-libiscsi
    --disable-lzo --disable-snappy --disable-zstd --disable-png
    --disable-vde --disable-curses --disable-smartcard
    --disable-docs --disable-werror --disable-tools --disable-guest-agent
    --enable-slirp --disable-slirp-smbd -Dforce_fallback_for=slirp
    -Dslirp:default_library=static
    --with-coroutine=libucontext --enable-ucontext
    --enable-virtfs --disable-download
)
[ -z "$BACKEND_FLAGS" ] || CONFIGURE_FLAGS+=("$BACKEND_FLAGS")

# A build tree goes on with what it was configured with: meson records the
# libraries' paths at configure time, and ninja reconfigures by itself only
# when a meson.build changes. So each tree remembers its environment and flags,
# and one where either has changed -- a nixpkgs bump, an edit to the host-qemu
# shell or to the flags above -- is configured afresh. The environment is
# unknown when this is run by hand from inside the shell, with no profile.
ENVIRONMENT="$(readlink -f "$GC_ROOT" 2>/dev/null || true)"
CONFIGURED="$ENVIRONMENT ${CONFIGURE_FLAGS[*]}"
if [ -n "$ENVIRONMENT" ] && [ -f "$BUILD_DIR/build.ninja" ] &&
    [ "$(cat "$BUILD_DIR/environment" 2>/dev/null)" != "$CONFIGURED" ]; then
    echo "${GREEN}The host-qemu shell or the configure flags have changed; configuring QEMU ($BACKEND) again...${NC}"
    rm -rf "$BUILD_DIR"
fi

# shellcheck source=qemu_source.sh
source "$BASEDIR/qemu_source.sh"
prepare_qemu_source

if [ ! -f "$BUILD_DIR/build.ninja" ]; then
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    echo "${GREEN}Configuring QEMU ($BACKEND) for this Mac...${NC}"
    if ! (cd "$BUILD_DIR" && "$QEMU_DIR/configure" "${CONFIGURE_FLAGS[@]}"); then
        # Removed so the next run configures afresh rather than building a
        # half-configured tree.
        rm -rf "$BUILD_DIR"
        die "configure failed"
    fi
    [ -z "$ENVIRONMENT" ] || echo "$CONFIGURED" >"$BUILD_DIR/environment"
fi

echo "${GREEN}Building QEMU ($BACKEND) for this Mac...${NC}"
ninja -C "$BUILD_DIR" qemu-system-x86_64
