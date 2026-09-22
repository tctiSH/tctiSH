#!/bin/bash
#
# Builds the tctiSH guest root filesystem and packs it into initrd.img.
#
# The guest is Alpine, assembled from a pinned minirootfs tarball plus a pinned
# set of .apk files, with the tctiSH-specific overlay laid on top. Everything it
# fetches is named and hashed in rootfs.lock, so two runs of this script produce
# the same bytes. Regenerate the lock with --lock when you want to move.
#
# Why a container: the build runs x86_64 Alpine tooling -- apk and the install
# scripts it fires -- so it needs a Linux kernel with an x86_64 binfmt handler.
# On macOS this script re-execs itself inside `container` with --rosetta, which
# supplies both. On Linux it just runs. See tmp/plans/kernel-upgrade.md.
#
# CAP_SYS_ADMIN is required, and only for one thing: apk chroots into the target
# to run install scripts, and Rosetta needs /proc/self/exe to identify what it
# is translating, so /proc has to be mounted inside the target first.
#
set -euo pipefail

ASSETS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$ASSETS/.." && pwd)"

# The guest branch. `edge` is deliberate: the shipped image is a pinned snapshot,
# while /etc/apk/repositories points at live edge so that a user's `apk add` and
# `apk upgrade` get current packages. The pin is for the build, not the runtime.
ALPINE_BRANCH="edge"
ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"
ARCH="x86_64"

# The base. Alpine deletes superseded package builds from main/ within weeks, but
# releases/ is archived -- snapshots back to 2019 are still fetchable -- so the
# base is pinned durably even though the packages on top are not.
MINIROOTFS_VERSION="20260805"
MINIROOTFS_SHA256="5acac12c425a0817c1b6a79bdd5df4c73756fc8dc268eab32f8ba830872b835d"

# What we add on top of the minirootfs. Dependencies are resolved into the lock;
# this is the world list, not the install list.
#
#   bash            the login shell; /etc/inittab and the guest scripts want it
#   dropbear        the SSH server the app connects to
#   netcat-openbsd  tctish-mount pipes QMP commands through it
#   e2fsprogs       init formats the disk on first boot
#
# e2fsprogs used to be `apk add`ed by init at first boot, against a repository
# that has since gone EOL. It is baked in now, which takes a network round trip
# off the critical boot path.
WORLD=(bash dropbear netcat-openbsd e2fsprogs)

LOCK="$ASSETS/rootfs.lock"
OUT="$ASSETS/initrd.img"

# The guest's root password, as a crypt(3) hash, and the shadow lastchg field.
#
# The app logs in as root/toor -- see TerminalView.swift, .byPassword(username:
# "root", password: "toor") -- but Alpine's minirootfs ships `root:*`, which
# disables password login entirely. Without this line dropbear refuses the app's
# authentication and the terminal never opens.
#
# Carried forward verbatim from the 2022 image rather than generated, because
# crypt(3) picks a random salt: running `passwd` here would produce a different
# hash on every build and defeat the whole point of the lock. Not a secret -- it
# is a fixed placeholder credential for a local VM, and the plaintext is in the
# app source.
ROOT_PASSWORD_HASH='$6$ayoNqDz/j3BYEDmV$nFPZdaROuZixFLSh0pG6jdYXxwooeRQ7.jJKuBOu35UQYZ6rGpXjfALby0/QHgAys0c7K1.JDS5yY4YeWLbIl/'
ROOT_PASSWORD_LASTCHG="19236"

# Timestamps for anything we create. cpio records mtimes and gzip records one of
# its own, so both have to be pinned or the image differs run to run.
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"

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

# A `touch` that understands `-d @epoch` and `-h`, which busybox's does not.
#
# Probed rather than assumed, because the failure it guards against is silent:
# busybox touch rejects the argument, `find -exec` swallows the status, and the
# build produces an image with live timestamps that looks entirely fine until you
# compare two of them.
TOUCH=""
resolve_touch() {
    local candidate probe
    probe="$(mktemp)"

    for candidate in /usr/bin/touch gtouch touch; do
        if command -v "$candidate" >/dev/null 2>&1 &&
            "$candidate" -h -d "@0" "$probe" 2>/dev/null; then
            TOUCH="$candidate"
            rm -f "$probe"
            return 0
        fi
    done

    rm -f "$probe"
    die "no touch understands '-d @epoch'; install coreutils"
}

# ---------------------------------------------------------------------------------------------
# Container re-exec
# ---------------------------------------------------------------------------------------------

# Hand off to a Linux container when we are not already in one. --rm so nothing
# is left running afterwards: the whole point of using `container` rather than a
# persistent builder VM is that there is no daemon holding memory between builds.
# The devshell filters $PATH down to nix and Apple directories -- see the
# shellHook in flake.nix, which exists to stop Homebrew deciding what a build
# picks up. Homebrew's `container` is collateral: correct for the QEMU build,
# wrong here. So look in the usual install locations rather than requiring that
# this be run from outside `nix develop`.
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
    exec "$CONTAINER" run --rm --rosetta --cap-add CAP_SYS_ADMIN \
        -c 8 -m 8g \
        -v "$REPO:$REPO" -w "$REPO" \
        alpine:latest \
        sh -c "apk add --no-cache bash coreutils cpio curl >/dev/null 2>&1 && exec bash '${BASH_SOURCE[0]}' $*"
}

# ---------------------------------------------------------------------------------------------
# Fetching
# ---------------------------------------------------------------------------------------------

sha256_of() {
    sha256sum "$1" | cut -d' ' -f1
}

# Fetch and verify, or fail loudly. A hash mismatch here means upstream moved
# under a pin, which is a decision to make rather than something to paper over.
fetch_verify() {
    local url="$1" dest="$2" want="$3" got

    curl -fsSL "$url" -o "$dest" || die "could not fetch $url"

    got="$(sha256_of "$dest")"
    [ "$got" = "$want" ] || die "hash mismatch for $url
  expected $want
  actual   $got"
}

minirootfs_url() {
    echo "$ALPINE_MIRROR/$ALPINE_BRANCH/releases/$ARCH/alpine-minirootfs-$MINIROOTFS_VERSION-$ARCH.tar.gz"
}

apk_url() {
    local repo="$1" name="$2" version="$3"
    echo "$ALPINE_MIRROR/$ALPINE_BRANCH/$repo/$ARCH/$name-$version.apk"
}

# ---------------------------------------------------------------------------------------------
# Building the base
# ---------------------------------------------------------------------------------------------

# Unpack the pinned minirootfs and point it at our mirror. The stock file already
# lists main and community, but spells the host `cdn.alpinelinux.org`; we use the
# same mirror we built against so the runtime and the build agree.
unpack_base() {
    local root="$1" work="$2"

    fetch_verify "$(minirootfs_url)" "$work/minirootfs.tar.gz" "$MINIROOTFS_SHA256"
    mkdir -p "$root"
    tar xzf "$work/minirootfs.tar.gz" -C "$root"

    # The stock file already lists main and community, but spells the host
    # `cdn.alpinelinux.org`. Drop it: write_repositories puts ours back, and
    # leaving it here makes the offline install warn about indexes it has been
    # told not to fetch.
    rm -f "$root/etc/apk/repositories"
}

# Written after the offline install rather than before it, so that apk does not
# spend the build warning about index files it has been told not to fetch.
write_repositories() {
    local root="$1"

    cat >"$root/etc/apk/repositories" <<EOF
$ALPINE_MIRROR/$ALPINE_BRANCH/main
$ALPINE_MIRROR/$ALPINE_BRANCH/community
EOF
}

# apk chroots to run install scripts, and Rosetta reads /proc/self/exe, so /proc
# must exist inside the target. resolv.conf is only needed when apk is allowed to
# reach the network, which is the --lock path.
with_proc() {
    local root="$1"
    mkdir -p "$root/proc"
    mount -t proc proc "$root/proc"
}

without_proc() {
    local root="$1"
    umount "$root/proc" 2>/dev/null || true
}

# ---------------------------------------------------------------------------------------------
# --lock
# ---------------------------------------------------------------------------------------------

# Resolve WORLD against the live branch, then record every resulting package with
# the hash of the exact .apk we resolved to. Deliberately a separate mode: a plain
# build never touches the network beyond the hashes written here.
do_lock() {
    local work root
    work="$(mktemp -d)"
    root="$work/root"
    # shellcheck disable=SC2064
    trap "without_proc '$root'; rm -rf '$work'" EXIT

    note "resolving $ALPINE_BRANCH packages: ${WORLD[*]}"
    unpack_base "$root" "$work"
    write_repositories "$root"
    with_proc "$root"
    cp /etc/resolv.conf "$root/etc/resolv.conf"

    # --simulate prints the resolution without touching the root. The lines look
    # like "(  3/16) Installing readline (8.3.3-r1)".
    local resolved
    resolved="$(chroot "$root" /sbin/apk add --simulate --no-cache "${WORLD[@]}" 2>&1 |
        sed -n 's/^([ 0-9]*\/[ 0-9]*) Installing \([^ ]*\) (\([^)]*\))$/\1 \2/p')"

    [ -n "$resolved" ] || die "apk resolved nothing -- has the branch or a package name moved?"

    {
        echo "# tctiSH guest root filesystem lock."
        echo "#"
        echo "# Generated by assets/build_rootfs.sh --lock. Do not edit by hand."
        echo "# Every line is fetched and hash-checked by a plain build."
        echo "#"
        echo "# Alpine $ALPINE_BRANCH, $ARCH."
        echo
        echo "minirootfs $MINIROOTFS_VERSION $MINIROOTFS_SHA256"
        echo
    } >"$LOCK.tmp"

    # Packages do not say which repository they came from, so try main and fall
    # back to community. Recording the repo keeps the build's fetch unambiguous.
    local name version repo url dest found total=0
    while read -r name version; do
        [ -n "$name" ] || continue
        found=""
        for repo in main community; do
            url="$(apk_url "$repo" "$name" "$version")"
            dest="$work/$name-$version.apk"
            if curl -fsSL "$url" -o "$dest" 2>/dev/null; then
                found="$repo"
                break
            fi
        done
        [ -n "$found" ] || die "could not find $name-$version in main or community"

        echo "package $found $name $version $(sha256_of "$dest")" >>"$LOCK.tmp"
        total=$((total + 1))
    done <<<"$resolved"

    mv "$LOCK.tmp" "$LOCK"
    note "locked $total packages into ${LOCK#"$REPO"/}"
}

# ---------------------------------------------------------------------------------------------
# Overlay
# ---------------------------------------------------------------------------------------------

# Everything tctiSH adds on top of stock Alpine. Kept as real files in the repo
# rather than as edits to an unpacked image, so a guest change is a reviewable
# diff rather than an opaque one inside a binary.
apply_overlay() {
    local root="$1"

    note "applying overlay"

    # The runtime's view of Alpine: live edge, so that a user's `apk add` and
    # `apk upgrade` inside the guest reach current packages. The build's pin
    # governs what ships, not what the user can install afterwards.
    write_repositories "$root"

    # init, /etc/inittab, /etc/tcti_motd, /etc/config/dropbear, and the two
    # profile.d scripts -- shell_integration.sh sets the PS1 that reports the
    # guest's cwd back to the host, and prints tcti_motd; mount_shared.sh mounts
    # the 9p tag qemu_launcher.c passes as `shared`.
    #
    # overlay/etc/motd is empty on purpose: Alpine ships its own "Welcome to
    # Alpine!" text, and blanking it is what stops that printing over ours.
    cp -a "$ASSETS/overlay/." "$root/"
    chmod 0755 "$root/init"

    # The guest-side helpers. The old image carried mount.ios twice, in /sbin and
    # /usr/bin, differing by one stray space; one file and a symlink instead.
    install -d -m 0755 "$root/usr/bin"
    install -m 0755 "$ASSETS"/scripts/* "$root/usr/bin/"
    ln -sf ../usr/bin/mount.ios "$root/sbin/mount.ios"

    # Let root log in. See ROOT_PASSWORD_HASH above for why this is a literal
    # rather than a call to passwd.
    sed -i "s|^root:[^:]*:[^:]*:|root:$ROOT_PASSWORD_HASH:$ROOT_PASSWORD_LASTCHG:|" \
        "$root/etc/shadow"
    grep -q '^root:\$6\$' "$root/etc/shadow" ||
        die "failed to set the root password hash; dropbear would refuse the app's login"

    # init copies this into the user's authorized_keys on first boot.
    install -d -m 0755 "$root/etc/dropbear"
    install -m 0644 "$ASSETS/placeholder_keys/placeholder_key.pub" "$root/etc/dropbear/"

    # Mountpoint for host folders, and the private directory the app expects.
    install -d -m 0755 "$root/ios_host" "$root/private"

    # tctictl is built separately, by utils/tctictl/build_and_copy.sh, because it
    # needs the Rust musl toolchain from the devshell rather than anything here.
    # Its absence is normal on a first build and must not be fatal.
    local tctictl="$REPO/utils/tctictl/target/x86_64-unknown-linux-musl/release/tctictl"
    if [ -f "$tctictl" ]; then
        install -m 0755 "$tctictl" "$root/bin/tctictl"
        note "included tctictl"
    else
        warn "tctictl not built; the image will not contain it. Run 'make tctictl' first if you want it."
    fi
}

# Anything that records when the build ran, rather than what it produced. Left in,
# these defeat the whole point of pinning: the image would differ run to run even
# with an unchanged lock.
normalise() {
    local root="$1"

    note "normalising for reproducibility"
    resolve_touch

    rm -rf "$root/pkgs"
    rm -rf "$root/var/cache/apk"
    install -d -m 0755 "$root/var/cache/apk"

    # apk records every install with a wall-clock timestamp. It is a log of this
    # build, not a property of the image, and it is the only file whose *contents*
    # differ between two runs of the same lock.
    rm -f "$root/var/log/apk.log"

    # And every directory keeps the mtime of whenever it happened to be written.
    #
    # GNU touch, explicitly: busybox's does not understand `-d @epoch` and fails
    # silently inside `find -exec`, which looks exactly like success.
    find "$root" -depth -exec "$TOUCH" -h -d "@$SOURCE_DATE_EPOCH" {} +
}

# ---------------------------------------------------------------------------------------------
# Packing
# ---------------------------------------------------------------------------------------------

# newc is what the kernel's initramfs loader reads. Note -H newc alone, without a
# redundant -c: GNU cpio rejects the pair as "Archive format multiply defined",
# where BSD cpio accepts it. The old make_ramdisk.sh had both, so it only ever
# worked on macOS.
#
# The sort makes the archive order independent of readdir order, and gzip -n
# leaves the timestamp out of the header.
pack() {
    local root="$1" out="$2"

    note "packing $(basename "$out")"
    (cd "$root" && find . | LC_ALL=C sort | cpio -o -H newc --quiet) |
        gzip -9 -n >"$out"
}

# ---------------------------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------------------------

do_build() {
    local work root pkgs
    work="$(mktemp -d)"
    root="$work/root"
    pkgs="$root/pkgs"
    # shellcheck disable=SC2064
    trap "without_proc '$root'; rm -rf '$work'" EXIT

    [ -f "$LOCK" ] || die "no lock at ${LOCK#"$REPO"/}. Generate one with: $0 --lock"

    # The lock's minirootfs line is the authority, not the constant above, so a
    # lock generated against a different snapshot still builds what it says.
    local lock_version lock_sha
    read -r _ lock_version lock_sha < <(grep '^minirootfs ' "$LOCK")
    [ "$lock_version" = "$MINIROOTFS_VERSION" ] ||
        warn "lock pins minirootfs $lock_version, script default is $MINIROOTFS_VERSION; using the lock"
    MINIROOTFS_VERSION="$lock_version"
    MINIROOTFS_SHA256="$lock_sha"

    note "unpacking alpine-minirootfs-$MINIROOTFS_VERSION-$ARCH"
    unpack_base "$root" "$work"

    note "fetching locked packages"
    mkdir -p "$pkgs"
    local args=() repo name version sha
    while read -r _ repo name version sha; do
        fetch_verify "$(apk_url "$repo" "$name" "$version")" "$pkgs/$name-$version.apk" "$sha"
        args+=("/pkgs/$name-$version.apk")
    done < <(grep '^package ' "$LOCK")

    [ ${#args[@]} -gt 0 ] || die "the lock contains no packages"

    note "installing ${#args[@]} packages offline"
    with_proc "$root"
    chroot "$root" /sbin/apk add --no-network --allow-untrusted "${args[@]}" >/dev/null
    without_proc "$root"

    # Before the overlay, not in normalise() after it: the overlay ships the
    # guest's own resolv.conf, and removing "whatever resolv.conf is there" once
    # the overlay has landed deleted it. That is how the image went out with no
    # resolv.conf at all, and every lookup in the guest timed out against
    # 127.0.0.1. What this removes is only a stray from the build environment.
    rm -f "$root/etc/resolv.conf"

    apply_overlay "$root"
    normalise "$root"
    pack "$root" "$OUT"

    echo
    note "built ${OUT#"$REPO"/}"
    echo "    packages:  $(grep -c '^P:' "$root/lib/apk/db/installed")"
    echo "    files:     $(find "$root" | wc -l | tr -d ' ')"
    echo "    unpacked:  $(du -sh "$root" | cut -f1)"
    echo "    initrd.img: $(du -h "$OUT" | cut -f1)"
    echo "    sha256:    $(sha256_of "$OUT")"
}

# ---------------------------------------------------------------------------------------------

main() {
    local mode="build"

    # Before anything else, and with the arguments still intact: on macOS this
    # does not return.
    maybe_reexec "$@"

    while [ $# -gt 0 ]; do
        case "$1" in
            --lock) mode="lock" ;;
            -h | --help)
                sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
                exit 0
                ;;
            *) die "unknown argument: $1" ;;
        esac
        shift
    done

    case "$mode" in
        lock) do_lock ;;
        build) do_build ;;
    esac
}

main "$@"
