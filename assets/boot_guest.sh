#!/bin/bash
#
# Boots the shipped guest image on this Mac and gives you a shell in it.
#
# Replaces start_qemu.sh, which was the 2022 developer loop and had been
# unrunnable for years: it built QEMU from a `qemu-tcti` submodule that no longer
# exists, passed `-soundhw hda` (removed from QEMU in 6.0), and packed the
# ramdisk with `cpio -o -c -H newc`, a flag pair GNU cpio rejects outright.
#
# What this tests, and what it does not:
#
#   it does     the guest image -- the kernel, the initramfs, init, the overlay
#               root, the disk, 9p, dropbear, and anything you do at the shell
#   it does not TCTI. The emulator here is an ordinary host QEMU running plain
#               TCG. The QEMU the app ships is cross-compiled for iOS, links the
#               TCTI backend, and is built as a dylib the app dlopens -- it
#               cannot run on macOS at all. Testing that needs a device.
#
# The machine is spelled to match qemu_launcher.c as closely as a host boot can,
# including the machine *type*, which matters more than it looks: the app passes
# no -M and so gets whatever its own QEMU defaults to. Pinning it here means this
# script keeps testing the machine we ship even as the host QEMU moves, and it is
# exactly the axis that bit this project before -- pc-i440fx-6.2 silently changed
# what a bare `-smp 4` meant, and cost the guest three of its four CPUs.
#
set -euo pipefail

ASSETS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$ASSETS/.." && pwd)"

# The machine type the app's QEMU defaults to. Bump alongside the QEMU upgrade,
# not before it: the point is to match what ships, not to be current.
MACHINE="pc-i440fx-10.0"

# Matches qemu_launcher.c. The guest's /etc/network config expects this subnet.
GUEST_IP="192.168.100.100"
SSH_PORT="10022"
MONITOR_PORT="10045"

MEMORY="1G"
CPUS="4"
SHARE="/tmp"
DISK="$ASSETS/boot_guest.qcow"
KEY="$ASSETS/placeholder_keys/placeholder_key"

FRESH=0
USE_SSH=0
SNAPSHOT=""

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

usage() {
    cat <<'USAGE'
usage: boot_guest.sh [options]

  --ssh             Connect over SSH rather than using the serial console.
  --fresh           Recreate the working disk from assets/empty.qcow first.
  --snapshot NAME   Resume from a saved snapshot instead of booting cold.
  --share DIR       Host directory offered over 9p as "shared" (default: /tmp).
  --memory SIZE     Guest RAM, as QEMU spells it (default: 1G).
  --cpus N          Guest CPUs (default: 4).
  -h, --help        This.

Boots assets/bzImage + assets/initrd.img against a writable copy of
assets/empty.qcow. The copy lives at assets/boot_guest.qcow and persists between
runs, so the guest keeps its state; --fresh throws it away.

The 9p share appears at /ios_host in the guest, mounted for you by
etc/profile.d/mount_shared.sh at login -- so mounting it by hand gets you
"Resource busy" rather than a second copy.
USAGE
}

# Prefer an explicitly named QEMU, so that a host build of *our* QEMU can be
# dropped in without editing this script. Otherwise take the devshell's.
resolve_qemu() {
    if [ -n "${TCTISH_QEMU:-}" ]; then
        [ -x "$TCTISH_QEMU" ] || die "TCTISH_QEMU is set but not executable: $TCTISH_QEMU"
        QEMU="$TCTISH_QEMU"
        return 0
    fi

    command -v qemu-system-x86_64 >/dev/null 2>&1 ||
        die "no qemu-system-x86_64 on PATH. It comes from the devshell:
  nix develop --command ./assets/boot_guest.sh
or run this through its make target, which enters the shell for you:
  make boot-guest"

    QEMU="$(command -v qemu-system-x86_64)"
}

prepare_disk() {
    if [ "$FRESH" -eq 1 ]; then
        rm -f "$DISK"
    fi

    if [ ! -f "$DISK" ]; then
        [ -f "$ASSETS/empty.qcow" ] || die "missing $ASSETS/empty.qcow; run: make guest"
        note "creating a working disk from empty.qcow"
        cp "$ASSETS/empty.qcow" "$DISK"
    fi
}

# dropbear rejects a key the filesystem lets anyone read, and git stores no mode
# beyond the executable bit -- so the checked-in key is whatever the umask made
# it. Copy rather than chmod in place, which would dirty the tree.
prepare_key() {
    KEY_COPY="$(mktemp)"
    cat "$KEY" >"$KEY_COPY"
    chmod 600 "$KEY_COPY"
    trap 'rm -f "$KEY_COPY"' EXIT
}

# Ask the guest to power down, through the monitor.
#
# Not something the app does -- on iOS a session ends with the process being
# killed, and the saved snapshot is what survives -- so this path is exercised
# here and nowhere else.
#
# `system_powerdown` asserts the ACPI power button. Two things have to be true
# for that to mean anything, and both now are: the kernel has CONFIG_ACPI_BUTTON
# so it turns the assertion into an input event, and /usr/bin/tctish-powerbtn is
# listening for that event and calls poweroff.
#
# A clean shutdown takes about six seconds under TCG, so the wait below is
# generous rather than tight -- falling back to `quit` is a plug-pull, and doing
# it one second early would make the journal recovery we are avoiding.
shut_down() {
    note "powering the guest down"

    # -w matters: macOS nc does not close when stdin ends, it waits on the socket
    # for a reply that a monitor command does not always produce -- so without a
    # timeout this blocks for ever rather than sending and returning.
    if ! printf 'system_powerdown\n' | nc -w 2 127.0.0.1 "$MONITOR_PORT" >/dev/null 2>&1; then
        warn "could not reach the monitor; stopping QEMU outright"
    fi

    local attempt=0
    while kill -0 "$QEMU_PID" 2>/dev/null; do
        attempt=$((attempt + 1))
        if [ "$attempt" -ge 20 ]; then
            warn "the guest did not power down; stopping the emulator"
            kill "$QEMU_PID" 2>/dev/null || true
            break
        fi
        sleep 1
    done

    wait "$QEMU_PID" 2>/dev/null || true
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --ssh) USE_SSH=1 ;;
            --fresh) FRESH=1 ;;
            --snapshot)
                SNAPSHOT="${2:-}"
                [ -n "$SNAPSHOT" ] || die "--snapshot needs a name"
                shift
                ;;
            --share)
                SHARE="${2:-}"
                [ -d "$SHARE" ] || die "--share needs a directory that exists"
                shift
                ;;
            --memory)
                MEMORY="${2:-}"
                shift
                ;;
            --cpus)
                CPUS="${2:-}"
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *) die "unknown option: $1 (try --help)" ;;
        esac
        shift
    done

    resolve_qemu
    prepare_disk

    for image in bzImage initrd.img; do
        [ -f "$ASSETS/$image" ] || die "missing $ASSETS/$image; run: make guest"
    done

    # The machine, spelled as qemu_launcher.c spells it.
    local argv=(
        "$QEMU"
        -M "$MACHINE"
        -m "$MEMORY"
        -smp "$CPUS"
        -kernel "$ASSETS/bzImage"
        -initrd "$ASSETS/initrd.img"
        -device virtio-net-pci,id=net1,netdev=net0
        -netdev "user,id=net0,net=192.168.100.0/24,dhcpstart=$GUEST_IP,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22"
        -device virtio-rng-pci
        -device virtio-blk-pci,id=disk1,drive=drive1
        -drive "file=$DISK,id=drive1,if=none,format=qcow2"
        -fsdev "local,path=$SHARE,security_model=none,id=fsdev0"
        -device virtio-9p-pci,fsdev=fsdev0,mount_tag=shared
        -monitor "tcp:localhost:$MONITOR_PORT,server=on,wait=off"
        -no-reboot
    )

    # console=ttyS0 is the one deliberate difference from the app, which reaches
    # the guest over SSH and leaves the kernel talking to nothing. Here the
    # console is the point.
    local cmdline="tcti_disk=file"
    if [ "$USE_SSH" -eq 0 ]; then
        cmdline="$cmdline console=ttyS0"
        argv+=(-nographic)
    else
        argv+=(-display none -serial null)
    fi
    argv+=(-append "$cmdline")

    [ -n "$SNAPSHOT" ] && argv+=(-loadvm "$SNAPSHOT")

    note "$(basename "$QEMU"), machine $MACHINE, $CPUS cpus, $MEMORY"
    note "9p share: $SHARE (tag 'shared')"
    note "monitor: telnet localhost $MONITOR_PORT"

    if [ "$USE_SSH" -eq 0 ]; then
        note "console follows; the guest logs in as root automatically"
        echo
        exec "${argv[@]}"
    fi

    prepare_key

    # Backgrounded here rather than with QEMU's own -daemonize, so that the
    # script keeps a pid it can wait on and signal. A daemonized QEMU is an
    # orphan: the only handle on it is a pattern match against its command line,
    # which is both fragile and unnecessary.
    "${argv[@]}" &
    QEMU_PID=$!

    note "waiting for the guest to answer on port $SSH_PORT"
    local attempt=0
    until nc -z 127.0.0.1 "$SSH_PORT" 2>/dev/null; do
        attempt=$((attempt + 1))
        [ "$attempt" -lt 60 ] || die "the guest never opened port $SSH_PORT"
        sleep 1
    done

    # The host key changes with every fresh disk, so checking it would only ever
    # produce a scary warning about a machine that is meant to be disposable.
    ssh -i "$KEY_COPY" -p "$SSH_PORT" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        root@127.0.0.1 || true

    shut_down
}

main "$@"
