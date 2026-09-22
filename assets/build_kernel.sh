#!/bin/bash
#
# Builds the tctiSH guest kernel and writes it to assets/bzImage.
#
# The source is a pinned kernel.org release tarball, verified by hash. The whole
# configuration is assets/kernel/tctish.config, in savedefconfig form, and every
# symbol in it is asserted against the resolved .config afterwards.
#
# Two layers of pinning, for two different kinds of drift:
#
#   the kernel      a tarball and its SHA-256, below
#   the toolchain   assets/kernel/flake.lock, which pins nixpkgs to an exact
#                   revision -- so clang, lld, binutils and pahole are the same
#                   bytes on every machine and in a year's time
#
# Why a container: kbuild is thousands of invocations of tools macOS does not
# have, so it needs a Linux kernel to run on. Why Nix inside the container: the
# container image alone pins nothing -- `alpine:latest` moves, and the compiler
# inside it moves with it -- and a kernel build's output depends on its compiler
# in detail. Nix gives an exactly-pinned toolchain without a daemon: the
# container is still `--rm`, and the only thing that persists between builds is a
# named volume holding the Nix store, which is a cache in the same sense the
# object tree is. `--clean-all` removes it.
#
# Unlike build_rootfs.sh this needs neither --rosetta nor CAP_SYS_ADMIN. Nothing
# x86_64 is executed here: the kernel is cross-compiled via LLVM=1, which is
# tier-1 upstream for x86_64 and needs no separate cross-targeted toolchain,
# clang being a cross compiler by construction.
#
# (The first attempt used Alpine's x86_64-elf GNU toolchain -- the one the 2022
# kernel was built with, per the old config's banner. It no longer assembles
# 6.18: binutils 2.45 refuses the cross-section symbol arithmetic the kernel's
# ALTERNATIVE macros generate, and arch/x86/entry/entry.S dies on it.)
#
# See tmp/plans/kernel-upgrade.md.
#
set -euo pipefail

ASSETS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$ASSETS/.." && pwd)"

# The kernel. 6.18 is the newest longterm line; picking a non-LTS line is how the
# guest spent four years on a 6.0 release candidate, so this should move along
# 6.18.x and change lines only deliberately.
#
# The hash is from https://cdn.kernel.org/pub/linux/kernel/v6.x/sha256sums.asc.
KERNEL_VERSION="6.18.53"
KERNEL_SHA256="4d6fba95c2244b08a7b4144a4d38b9be4fb31abb5e7682ae40bb5cb11374cfe0"
KERNEL_MIRROR="https://cdn.kernel.org/pub/linux/kernel/v6.x"

# The image the build runs in, pinned by digest -- the same one `nixos/nix:latest`
# resolved to when this kernel was first built.
#
# Pinned for a reason that has nothing to do with the kernel's bytes, which the
# flake decides: the image's own `sh` lives in /nix/store, and the toolchain
# volume is mounted over /nix. A volume seeded from one image lacks the store
# paths another image's `sh` points into, and the container then cannot start
# at all ("failed to find target executable sh"). The digest is part of the
# seed stamp, so moving it re-seeds rather than failing.
BUILDER_IMAGE="nixos/nix@sha256:7a007c766426c1877758ddc5cb87a965ac131fc78c582ce0083d922d51ae945c"

CONFIG="$ASSETS/kernel/tctish.config"
FLAKE="$ASSETS/kernel"
OUT="$ASSETS/bzImage"

# Out of tree, and gitignored. Kernel builds are worth caching: a config change
# followed by a rebuild is minutes rather than the better part of an hour.
BUILD="$REPO/build-kernel"

# Where the source and object trees actually live.
#
# Not on the bind mount, and this is not a preference. Apple's container runtime
# does not reproduce symlinks through a macOS bind mount: the kernel tarball's
# `tools/testing/selftests/bpf/json_writer.h` is a symlink, and unpacking it onto
# the bind mount produces a zero-length regular file with mode 000 which the
# container then cannot unlink. A kernel tree is full of symlinks, so a tree
# unpacked there is quietly wrong, and `--clean` followed by a rebuild fails.
#
# A managed volume is a real Linux filesystem, which is also why the Nix store
# had to move there. Everything that needs to be *seen* from macOS -- the
# tarball, the reports, bzImage itself -- stays on the bind mount, because those
# are all plain files.
WORK="${TCTISH_WORK:-$BUILD}"
SRC="$WORK/linux-$KERNEL_VERSION"

# Scoped by version, because the volume is machine-global and shared by every
# checkout on this machine. Two trees on different kernel versions would
# otherwise hand kbuild the same object directory with a different source tree
# under it, which is a confusing failure at best and a mixed build at worst.
OBJ="$WORK/obj-$KERNEL_VERSION"
DELTA="$BUILD/config-delta.txt"
PREVIOUS="$BUILD/config-previous"

# The Nix store lives in a container-managed volume rather than a directory under
# build-kernel/, and that is not a stylistic choice.
#
# macOS is case-insensitive by default, and the Nix store is not: a single
# perl package ships `pod` and `Pod` in one directory, as does ncurses' terminfo
# tree. Copying a store onto an APFS bind mount fails partway through with a
# scatter of "File exists", leaving a store that is silently incomplete. A
# managed volume lives inside the runtime's own case-sensitive storage.
#
# It is persistent state, unlike everything else here, so it gets a name and
# `--clean-all` removes it. It is a cache, in the same sense the object tree is;
# nothing runs between builds.
NIX_VOLUME="tctish-nix"

# Written into the volume itself, last, when seeding finishes. See
# seed_nix_store for why it is not kept on the host.
NIX_STAMP_NAME=".tctish-seed"

# The source and object trees; see WORK above for why this is a volume.
WORK_VOLUME="tctish-kernel"

# Set once we are inside the pinned toolchain, so the re-exec does not loop.
: "${TCTISH_TOOLCHAIN:=}"

# Pin everything kbuild stamps into the image. Without these the version banner
# carries a build date, a username and a hostname -- which is why the old kernel
# announces itself as having been built by `deck@catra` in September 2022, and
# why two builds of identical source would not match.
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"
export KBUILD_BUILD_USER="tctish"
export KBUILD_BUILD_HOST="tctish-builder"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
NC=$'\033[0m'

die() {
    echo "${RED}error:${NC} $*" >&2
    exit 1
}

note() {
    echo "${GREEN}==>${NC} $*"
}

warn() {
    echo "${YELLOW}warning:${NC} $*" >&2
}

# ---------------------------------------------------------------------------------------------
# Container and toolchain
# ---------------------------------------------------------------------------------------------

# The devshell filters $PATH down to nix and Apple directories -- see the
# shellHook in flake.nix -- which drops Homebrew, and `container` with it. Look in
# the usual install locations rather than requiring this be run outside the shell.
CONTAINER=""
find_container() {
    local candidate
    for candidate in container /opt/homebrew/bin/container /usr/local/bin/container; do
        if command -v "$candidate" >/dev/null 2>&1; then
            CONTAINER="$candidate"
            return 0
        fi
    done
    return 1
}

resolve_container() {
    find_container ||
        die "no 'container' runtime found. Install it with: brew install container"
}

# Cleaning runs on the host, before any re-exec, and only in the outermost
# invocation. Inside the container there is no `container` binary to delete a
# volume with -- which is how --clean-all used to fail.
do_clean() {
    local all="$1"

    [ -n "$TCTISH_TOOLCHAIN" ] && return 0

    if [ "$all" -eq 1 ]; then
        note "removing $BUILD and both volumes"
        rm -rf "$BUILD"
        if find_container; then
            "$CONTAINER" volume delete "$WORK_VOLUME" >/dev/null 2>&1 || true
            "$CONTAINER" volume delete "$NIX_VOLUME" >/dev/null 2>&1 || true
        fi
    else
        # The toolchain volume carries its own seed stamp, so the whole build
        # tree can go without the next build re-seeding 3.6 GB.
        note "removing the build tree (keeping the toolchain volume)"
        rm -rf "$BUILD"
        if find_container; then
            "$CONTAINER" volume delete "$WORK_VOLUME" >/dev/null 2>&1 || true
        fi
    fi
}

NIX_FLAGS="experimental-features = nix-command flakes"

# The store is ~3.6 GB and would otherwise be refetched from cache.nixos.org on
# every build.
#
# It has to be *seeded* rather than simply mounted, and the reason is worth
# writing down because the failure is baffling otherwise: the image's own
# userland lives in /nix/store, `sh` included. Mounting an empty volume over
# /nix leaves a container with no executables at all, and the runtime reports
# only "failed to find target executable sh".
#
# Keyed on the builder image and the flake, so changing any of them rebuilds the
# volume from scratch rather than layering a second toolchain on top of the
# first.
#
# The stamp lives *in the volume*, and is read back from it. It used to be a file
# on the host beside a check that the volume existed, and the two came apart:
# the volumes were replaced by empty ones -- `container run -v name:...` creates
# any named volume that does not exist, silently -- while the host stamp still
# said "seeded". The build then mounted an empty /nix and died without a word of
# explanation. A stamp stored with the data cannot claim data that is not there.
seed_nix_store() {
    local want have
    # All three: the image supplies the `sh` the store must contain, flake.lock
    # pins *which* nixpkgs, flake.nix decides *what* is taken from it. Changing
    # any of them leaves the volume missing store paths.
    want="$({
        printf '%s\n' "$BUILDER_IMAGE"
        cat "$FLAKE/flake.lock" "$FLAKE/flake.nix"
    } | sha256_stdin)"

    # Mounted beside /nix rather than over it, so that an empty or half-seeded
    # volume cannot take the image's own `cat` away. Only stdout is kept; the
    # runtime reports progress on stderr.
    have="$("$CONTAINER" run --rm -v "$NIX_VOLUME:/seed" "$BUILDER_IMAGE" \
        cat "/seed/$NIX_STAMP_NAME" 2>/dev/null || true)"

    if [ "$want" = "$have" ]; then
        return 0
    fi

    if [ -n "$have" ]; then
        note "the builder image or the flake moved; rebuilding the toolchain volume"
    else
        note "seeding the toolchain volume -- it is empty or incomplete, and this fetches ~3.6 GB"
    fi

    "$CONTAINER" volume delete "$NIX_VOLUME" >/dev/null 2>&1 || true
    "$CONTAINER" volume create "$NIX_VOLUME" >/dev/null ||
        die "could not create the $NIX_VOLUME volume"

    "$CONTAINER" run --rm -c 8 -m 8g \
        -v "$REPO:$REPO" -v "$NIX_VOLUME:/seed" -w "$REPO" \
        "$BUILDER_IMAGE" \
        sh -c "set -e
               export NIX_CONFIG='$NIX_FLAGS'
               nix develop 'path:$FLAKE' -c true
               cp -a /nix/. /seed/
               printf '%s\n' '$want' >'/seed/$NIX_STAMP_NAME'" ||
        die "could not seed the toolchain volume"
}

maybe_reexec() {
    # Innermost: already inside the pinned toolchain, so get on with it.
    [ -n "$TCTISH_TOOLCHAIN" ] && return 0

    # Middle: inside the container but not yet inside the toolchain.
    if [ "$(uname -s)" = "Linux" ]; then
        note "entering the pinned toolchain"
        export NIX_CONFIG="$NIX_FLAGS"
        export TCTISH_TOOLCHAIN=1
        exec nix develop "path:$FLAKE" -c bash "${BASH_SOURCE[0]}" "$@"
    fi

    # Outermost: on macOS, so hand off to Linux first.
    resolve_container

    "$CONTAINER" system status >/dev/null 2>&1 ||
        die "the container runtime is not running. Start it with: container system start"

    seed_nix_store

    note "re-executing inside a Linux container"

    # More memory than the rootfs build gets, and for one reason: linking vmlinux
    # with full DWARF5 debug info is the peak, and BTF generation reads all of it
    # back. This is the step that makes the kernel build memory-hungry rather than
    # merely slow.
    "$CONTAINER" volume create "$WORK_VOLUME" >/dev/null 2>&1 || true

    exec "$CONTAINER" run --rm \
        -c 8 -m 12g \
        -v "$REPO:$REPO" -v "$NIX_VOLUME:/nix" -v "$WORK_VOLUME:/build" -w "$REPO" \
        -e TCTISH_WORK=/build \
        "$BUILDER_IMAGE" \
        sh -c "exec bash '${BASH_SOURCE[0]}' $*"
}

# The object tree is cached between runs, which is the point -- a config tweak
# should not cost a full rebuild. But a cache keyed on nothing is a trap: swap the
# toolchain and kbuild will happily link objects from two different compilers,
# and the failure lands at the very end of a long build, if it lands at all.
check_toolchain() {
    local stamp="$BUILD/.toolchain" current

    current="$("${TCTISH_TARGET_CC:-clang}" --version | head -1) via ${TCTISH_TARGET_CC:-clang}"

    if [ -f "$stamp" ] && [ "$(cat "$stamp")" != "$current" ]; then
        warn "toolchain changed, discarding the cached object tree"
        warn "  was: $(cat "$stamp")"
        warn "  now: $current"
        rm -rf "$OBJ"
    fi

    mkdir -p "$BUILD"
    printf '%s\n' "$current" >"$stamp"
}

# ---------------------------------------------------------------------------------------------
# Fetching
# ---------------------------------------------------------------------------------------------

sha256_stdin() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -d' ' -f1
    else
        shasum -a 256 | cut -d' ' -f1
    fi
}

sha256_of() {
    # Portable because this is called from both sides of the container
    # boundary: macOS ships shasum, the builder ships sha256sum.
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# Fetch and verify, or fail loudly. A hash mismatch means upstream moved under a
# pin, which is a decision to make rather than something to paper over.
fetch_verify() {
    local url="$1" dest="$2" want="$3" got

    curl -fsSL "$url" -o "$dest" || die "could not fetch $url"

    got="$(sha256_of "$dest")"
    [ "$got" = "$want" ] || die "hash mismatch for $url
  expected $want
  actual   $got"
}

# Unpack the pinned tarball, reusing what is already there. The marker file is
# written last, so an interrupted extraction is not mistaken for a complete one.
unpack_source() {
    # Deliberately on the bind mount rather than in the work volume: it is one
    # plain file, and keeping it host-side means `--clean` does not cost a
    # re-download.
    local tarball="$BUILD/linux-$KERNEL_VERSION.tar.xz"

    if [ -f "$SRC/.tctish-unpacked" ]; then
        note "source tree already unpacked"
        return 0
    fi

    mkdir -p "$BUILD" "$WORK"

    if [ -f "$tarball" ] && [ "$(sha256_of "$tarball")" = "$KERNEL_SHA256" ]; then
        note "using cached tarball"
    else
        note "fetching linux-$KERNEL_VERSION"
        fetch_verify "$KERNEL_MIRROR/linux-$KERNEL_VERSION.tar.xz" "$tarball" "$KERNEL_SHA256"
    fi

    note "unpacking"

    # Cleared first, so a partial tree can never be mistaken for a whole one.
    #
    # This can fail, and the reason is not guessable: the container does not
    # always manage to unlink through the bind mount what macOS can delete
    # perfectly well. Saying so beats failing into tar, which then reports only
    # "Exiting with failure status due to previous errors" over a half-removed
    # tree.
    rm -rf "$SRC" || die "could not clear the source tree through the bind mount.
  Remove it from macOS and retry:  rm -rf ${SRC#"$REPO"/}"

    tar xJf "$tarball" -C "$WORK"
    touch "$SRC/.tctish-unpacked"
}

# ---------------------------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------------------------

kmake() {
    # CC is the unwrapped clang; HOSTCC stays the wrapped one on PATH. See the
    # TCTISH_TARGET_CC comment in assets/kernel/flake.nix for why they differ.
    make -C "$SRC" O="$OBJ" ARCH=x86_64 LLVM=1 \
        CC="${TCTISH_TARGET_CC:-clang}" "$@"
}

configure() {
    mkdir -p "$OBJ"

    # Stash the outgoing config so the delta can be computed against it. It is
    # only *promoted* to $PREVIOUS if it turns out to differ from what we
    # generate, so that a no-op reconfigure -- `make kernel-config` followed by
    # `make kernel`, say -- leaves the last meaningful report standing instead of
    # overwriting it with an empty one.
    local outgoing=""
    if [ -f "$OBJ/.config" ]; then
        outgoing="$(mktemp)"
        cp "$OBJ/.config" "$outgoing"
    fi

    note "configuring from $(basename "$CONFIG")"

    # defconfig semantics: symbols named here are set, everything else takes the
    # kernel's own default. That is what makes a 270-line file sufficient.
    cp "$CONFIG" "$SRC/arch/x86/configs/tctish_defconfig"
    kmake tctish_defconfig >/dev/null

    assert_config

    if [ -n "$outgoing" ]; then
        if diff -q "$outgoing" "$OBJ/.config" >/dev/null 2>&1; then
            note "configuration unchanged since the last build"
        else
            cp "$outgoing" "$PREVIOUS"
            write_delta
        fi
        rm -f "$outgoing"
    fi
}

# Check that every symbol the config asks for actually made it into the resolved
# .config.
#
# This exists because Kconfig's failure mode is silence. A symbol whose
# dependencies are unmet is dropped without a word, `make` succeeds, the kernel
# boots, and the feature is simply absent. It has already caught two real faults:
# CONFIG_SQUASHFS silently dropped for want of MISC_FILESYSTEMS, and the
# SPECULATION_MITIGATIONS rename quietly re-enabling every mitigation.
assert_config() {
    local line symbol value bad=0

    note "verifying the configuration took"

    while IFS= read -r line; do
        case "$line" in
            '#'*' is not set')
                symbol="${line#\# }"
                symbol="${symbol% is not set}"
                if grep -q "^${symbol}=" "$OBJ/.config"; then
                    value="$(grep "^${symbol}=" "$OBJ/.config")"
                    warn "$symbol should be unset, but is: $value"
                    bad=$((bad + 1))
                fi
                ;;
            CONFIG_*=*)
                symbol="${line%%=*}"
                if ! grep -qxF "$line" "$OBJ/.config"; then
                    if grep -q "^${symbol}=" "$OBJ/.config"; then
                        warn "$line -- resolved instead to $(grep "^${symbol}=" "$OBJ/.config")"
                    else
                        warn "$line -- not set at all (unmet dependency?)"
                    fi
                    bad=$((bad + 1))
                fi
                ;;
        esac
    done < <(grep -E '^(CONFIG_[A-Za-z0-9_]+=|# CONFIG_[A-Za-z0-9_]+ is not set)' "$CONFIG")

    [ "$bad" -eq 0 ] ||
        die "$bad symbol(s) from $(basename "$CONFIG") did not take; see above"
}

# Normalise a .config into `SYMBOL=value` lines, with unset symbols as `=n`, so
# two configs can be compared without the comment noise.
normalise_config() {
    sed -nE \
        -e 's/^CONFIG_([A-Za-z0-9_]+)=(.*)$/\1=\2/p' \
        -e 's/^# CONFIG_([A-Za-z0-9_]+) is not set$/\1=n/p' \
        "$1" | LC_ALL=C sort
}

# Symbols Kconfig derives rather than the user choosing: toolchain capability
# probes, architecture facts, and `select`-only helpers. They dominate a diff by
# volume and carry none of its meaning.
DERIVED_RE='^[<>] (ARCH_|AS_|CC_|CLANG_|GCC_|RUSTC_|LD_|TOOLS_|OBJTOOL|HAVE_|GENERIC_|AS64|X86_FEATURE)|_SUPPORT=|_SUPPORTS_|_HAS_|_WANT_'

# What changed since the last build. Self-maintaining: each build leaves its
# resolved config behind for the next one to diff against, so bumping the kernel
# version or editing tctish.config produces a readable report of the consequences
# rather than requiring anyone to remember to look.
write_delta() {
    local old new

    if [ ! -f "$PREVIOUS" ]; then
        note "no previous config to compare against; skipping the delta"
        return 0
    fi

    old="$(mktemp)"
    new="$(mktemp)"
    normalise_config "$PREVIOUS" >"$old"
    normalise_config "$OBJ/.config" >"$new"

    {
        echo "# Config delta against the previous build of this tree."
        echo "#"
        echo "# Symbols the user never selects -- ARCH_*, CC_HAS_*, HAVE_* and the like,"
        echo "# which Kconfig derives from the tree and the toolchain -- are split into"
        echo "# section 2. They are most of the volume and none of the decisions."
        echo
        echo "## 1. Decisions"
        echo
        diff "$old" "$new" | grep -E '^[<>]' | grep -Ev "$DERIVED_RE" || echo "(none)"
        echo
        echo "## 2. Derived (informational)"
        echo
        diff "$old" "$new" | grep -E '^[<>]' | grep -E "$DERIVED_RE" || echo "(none)"
    } >"$DELTA"

    note "config delta written to ${DELTA#"$REPO"/}"

    rm -f "$old" "$new"
}

# Regenerate the minimal form of the current configuration. Written beside the
# build rather than over tctish.config, because the prose in that file does not
# survive a round trip and losing it silently would be worse than the manual fold.
savedefconfig() {
    kmake savedefconfig >/dev/null
    cp "$OBJ/defconfig" "$BUILD/savedefconfig.out"
    note "minimal config written to build-kernel/savedefconfig.out"
    note "fold it into $(basename "$CONFIG") by hand; the comments are not regenerated"
}

# ---------------------------------------------------------------------------------------------
# Building
# ---------------------------------------------------------------------------------------------

build() {
    local jobs
    jobs="$(nproc)"

    # Kbuild wants a date string rather than an epoch.
    export KBUILD_BUILD_TIMESTAMP
    KBUILD_BUILD_TIMESTAMP="$(date -u -d "@$SOURCE_DATE_EPOCH" 2>/dev/null ||
        date -u -r "$SOURCE_DATE_EPOCH")"

    note "building with $jobs jobs (this is the slow part)"
    kmake -j"$jobs" bzImage

    [ -f "$OBJ/arch/x86/boot/bzImage" ] || die "the build produced no bzImage"

    cp "$OBJ/arch/x86/boot/bzImage" "$OUT"
    note "wrote ${OUT#"$REPO"/} ($(du -h "$OUT" | cut -f1))"

    # The banner the guest will report. Worth printing because CONFIG_LOCALVERSION
    # is load-bearing and this is where you would notice it having gone missing.
    if [ -f "$OBJ/include/config/kernel.release" ]; then
        note "kernel release: $(cat "$OBJ/include/config/kernel.release")"
    fi
}

# ---------------------------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------------------------

usage() {
    cat <<'USAGE'
usage: build_kernel.sh [options]

  --config-only     Configure and write the delta report, but do not build.
  --savedefconfig   Regenerate the minimal config into build-kernel/, and stop.
  --clean           Remove the build tree first, then build. Keeps the pinned
                    toolchain; use --clean-all to drop that too.
  --clean-all       Remove the build tree and both volumes, then stop.
  -h, --help        This.

Builds the guest kernel into assets/bzImage. On macOS this re-execs itself
inside `container`, and then inside a Nix shell pinned by
assets/kernel/flake.lock. See the header of this script.
USAGE
}

main() {
    # Before the re-exec, deliberately. Cleaning has to happen host-side (see
    # do_clean), and there is no reason to start a container to print usage.
    local arg
    for arg in "$@"; do
        case "$arg" in
            -h | --help)
                usage
                exit 0
                ;;
            # --clean removes the tree and carries on to rebuild, which is what
            # "forcing a full rebuild" means. --clean-all is the nuke, and stops:
            # `make clean-kernel` must not delete both volumes and then spend
            # half an hour putting them back.
            --clean) do_clean 0 ;;
            --clean-all)
                do_clean 1
                exit 0
                ;;
        esac
    done

    maybe_reexec "$@"

    local config_only=0 save_only=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --config-only) config_only=1 ;;
            --savedefconfig) save_only=1 ;;
            --clean | --clean-all) ;; # already handled, before the re-exec
            -h | --help)
                usage
                exit 0
                ;;
            *) die "unknown option: $1 (try --help)" ;;
        esac
        shift
    done

    [ -f "$CONFIG" ] || die "missing config: $CONFIG"
    [ -f "$FLAKE/flake.lock" ] || die "missing $FLAKE/flake.lock; the toolchain is unpinned"

    command -v clang >/dev/null 2>&1 || die "no clang on PATH; the toolchain shell is wrong"
    command -v ld.lld >/dev/null 2>&1 || die "no ld.lld on PATH; the toolchain shell is wrong"
    command -v pahole >/dev/null 2>&1 ||
        die "no pahole on PATH; CONFIG_DEBUG_INFO_BTF cannot be satisfied"

    unpack_source
    check_toolchain
    configure

    if [ "$save_only" -eq 1 ]; then
        savedefconfig
        exit 0
    fi

    if [ "$config_only" -eq 1 ]; then
        note "stopping after configuration, as asked"
        exit 0
    fi

    build
}

main "$@"
