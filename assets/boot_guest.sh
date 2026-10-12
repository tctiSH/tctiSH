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
#               root, the disk, 9p, the console and its resizing, the agent, and
#               anything you do at the shell --
#               on our QEMU: the third-party/qemu fork, built for this Mac by
#               build_host_qemu.sh, with either backend. TCTI runs natively on
#               Apple Silicon, so --backend tcti is the app's interpreter, gadgets
#               and all.
#   it does not anything behind TARGET_OS_IPHONE in that fork: handing the code
#               buffer to a debugger, the purgeable code cache. Nor the app's
#               side -- the launcher, the dylib it dlopens, snapshots on
#               backgrounding. Testing those needs a device.
#
# The machine is spelled to match qemu_launcher.c as closely as a host boot can,
# including the machine *type*, which matters more than it looks: the app passes
# no -M and so gets whatever its QEMU defaults to. Our build defaults to the
# same, but pinning it here means a QEMU bump that moves the default shows up as
# an edit to this file rather than silently -- and it is exactly the axis that
# bit this project before: pc-i440fx-6.2 silently changed what a bare `-smp 4`
# meant, and cost the guest three of its four CPUs.
#
set -euo pipefail

ASSETS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$ASSETS/.." && pwd)"

# The machine type the app's QEMU defaults to. Bump alongside the QEMU upgrade,
# not before it: the point is to match what ships, not to be current.
MACHINE="pc-i440fx-11.1"

# Matches qemu_launcher.c. The guest's /etc/network config expects this subnet.
GUEST_IP="192.168.100.100"
MONITOR_PORT="10045"

BACKEND="jit"
MEMORY="1G"
CPUS="4"

# One slot per core, as qemu_launcher.c makes them, capped at the guest's
# NR_CPUS. The rest of the slots are there to hot-plug into from the monitor.
MAX_CPUS="$(sysctl -n hw.logicalcpu_max 2>/dev/null || nproc 2>/dev/null || echo 4)"
[ "$MAX_CPUS" -gt 16 ] && MAX_CPUS=16
SHARE="/tmp"
DISK="$ASSETS/boot_guest.qcow"
LOG="$ASSETS/boot_guest.log"

FRESH=0
USE_SERIAL=0
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

  --backend NAME    jit (the default) or tcti: which build of our QEMU to run.
  --serial          Use the serial console, with the kernel's log, rather than
                    hvc0, the console the app shows.
  --fresh           Recreate the working disk from assets/empty.qcow first.
  --snapshot NAME   Resume from a saved snapshot instead of booting cold.
  --share DIR       Host directory offered over 9p as "shared" (default: /tmp).
  --memory SIZE     Guest RAM, as QEMU spells it (default: 1G).
  --cpus N          Guest CPUs plugged in at boot (default: 4).
  --max-cpus N      Slots to hot-plug into (default: this host's cores, up to 16).
  -h, --help        This.

Boots assets/bzImage + assets/initrd.img against a writable copy of
assets/empty.qcow. The copy lives at assets/boot_guest.qcow and persists between
runs, so the guest keeps its state; --fresh throws it away.

The emulator is build-macOS-arm64/qemu_<backend>/qemu-system-x86_64, which
`make host-qemu BACKEND=<backend>` builds and `make boot-guest` builds first if
it has to. Setting TCTISH_QEMU runs some other qemu-system-x86_64 instead.

By default this terminal is hvc0, the virtio console the app shows, and its
size follows this window's, through the monitor's console_resize, as the app's
does. The kernel's log goes to assets/boot_guest.log. With --serial, this
terminal is the serial console instead, kernel log and all, as it was before
the app moved off SSH; hvc0 is then left unconnected.

The guest agent's port is a socket in a temporary directory, named on startup.
Ask it whether Linux is up with:  printf 'ping 1\n' | nc -U <socket>

The 9p share appears at /ios_host in the guest, mounted for you by
etc/profile.d/mount_shared.sh at login -- so mounting it by hand gets you
"Resource busy" rather than a second copy.
USAGE
}

# Our QEMU for the chosen backend, unless TCTISH_QEMU names another -- a
# harness build, say. Never whatever qemu-system-x86_64 is on $PATH: an upstream
# QEMU boots the same image happily, and would quietly test the wrong emulator.
resolve_qemu() {
    if [ -n "${TCTISH_QEMU:-}" ]; then
        [ -x "$TCTISH_QEMU" ] || die "TCTISH_QEMU is set but not executable: $TCTISH_QEMU"
        QEMU="$TCTISH_QEMU"
        return 0
    fi

    case "$BACKEND" in
        jit | tcti) ;;
        *) die "--backend is jit or tcti, not '$BACKEND'" ;;
    esac

    QEMU="$REPO/build-macOS-arm64/qemu_$BACKEND/qemu-system-x86_64"
    [ -x "$QEMU" ] || die "no $BACKEND build of our QEMU yet; run: make host-qemu BACKEND=$BACKEND
or boot through make, which builds it first: make boot-guest BACKEND=$BACKEND"
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

# Tells hvc0 this terminal's size, as the app tells it its view's.
send_console_size() {
    local size
    size="$(stty size </dev/tty 2>/dev/null)" || return 0
    printf 'console_resize hvc0 %s %s\n' "${size#* }" "${size% *}" |
        nc -w 1 127.0.0.1 "$MONITOR_PORT" >/dev/null 2>&1 || true
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
            --backend)
                BACKEND="${2:-}"
                shift
                ;;
            --serial) USE_SERIAL=1 ;;
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
            --max-cpus)
                MAX_CPUS="${2:-}"
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
        -smp "cpus=$CPUS,maxcpus=$MAX_CPUS,sockets=1,cores=$MAX_CPUS,threads=1"
        -cpu Haswell-v4,-pcid,-tsc-deadline,-invpcid,-spec-ctrl
        -kernel "$ASSETS/bzImage"
        -initrd "$ASSETS/initrd.img"
        -device virtio-net-pci,id=net1,netdev=net0
        -netdev "user,id=net0,net=192.168.100.0/24,dhcpstart=$GUEST_IP"
        -device virtio-serial-pci,id=vser0,console-size=on
        -device virtconsole,id=hvc0,chardev=hvc0-socket,bus=vser0.0
        -device virtserialport,id=agent,chardev=agent-socket,bus=vser0.0,name=io.ara.tctish.agent
        -device virtio-rng-pci
        -device virtio-balloon-pci,free-page-reporting=on
        -device "virtio-blk-pci,id=disk1,drive=drive1,num-queues=$MAX_CPUS"
        -drive "file=$DISK,id=drive1,if=none,format=qcow2,discard=unmap,detect-zeroes=unmap"
        -fsdev "local,path=$SHARE,security_model=none,id=fsdev0"
        -device virtio-9p-pci,fsdev=fsdev0,mount_tag=shared
        -monitor "tcp:localhost:$MONITOR_PORT,server=on,wait=off"
        -no-reboot
    )

    # The agent's socket. A short path, because a Unix socket's must fit in 104
    # bytes.
    AGENT_DIR="$(mktemp -d /tmp/tctish-agent.XXXXXX)"
    AGENT_SOCKET="$AGENT_DIR/agent.sock"
    trap 'rm -rf "$AGENT_DIR"' EXIT
    argv+=(-chardev "socket,id=agent-socket,path=$AGENT_SOCKET,server=on,wait=off")

    # console=ttyS0 is the one deliberate difference from the app, which leaves
    # the kernel talking to nothing: here the log is worth keeping.
    local cmdline="tcti_disk=file page_reporting.page_reporting_order=2 rcupdate.rcu_cpu_stall_suppress=1"
    cmdline="$cmdline console=ttyS0"
    if [ "$USE_SERIAL" -eq 1 ]; then
        argv+=(-nographic -chardev null,id=hvc0-socket)
    else
        # signal=off hands Ctrl-C to the guest rather than to QEMU, as in the app.
        argv+=(-display none -serial "file:$LOG" -chardev stdio,id=hvc0-socket,signal=off)
    fi
    argv+=(-append "$cmdline")

    [ -n "$SNAPSHOT" ] && argv+=(-loadvm "$SNAPSHOT")

    [ "$CPUS" -le "$MAX_CPUS" ] || die "--cpus $CPUS is more than --max-cpus $MAX_CPUS"

    note "$QEMU, machine $MACHINE, $CPUS of $MAX_CPUS cpus, $MEMORY"
    note "9p share: $SHARE (tag 'shared')"
    note "monitor: telnet localhost $MONITOR_PORT"
    note "agent: $AGENT_SOCKET"

    if [ "$USE_SERIAL" -eq 1 ]; then
        note "serial console follows; the guest logs in as root automatically"
        echo
        "${argv[@]}"
        return
    fi

    note "kernel log: ${LOG#"$REPO"/}"
    note "hvc0 follows; the guest logs in as root automatically. 'poweroff' to leave"
    echo

    # In the background rather than exec'd, so that this script can pass on
    # the window's size as it changes: bash runs a trap only between commands,
    # and `wait` is one it can be interrupted in. QEMU still has the terminal,
    # as a script without job control keeps everything in one process group,
    # but its stdin has to be handed over by name: without job control, bash
    # gives a background command /dev/null otherwise.
    exec 3<&0
    "${argv[@]}" <&3 3<&- &
    QEMU_PID=$!

    # A TERM sent to this script powers the guest down, rather than pulling
    # its plug. Closing the window can't: the hangup reaches QEMU as well, as
    # it shares this process group, and QEMU quits at once on one.
    trap 'shut_down; exit 0' HUP TERM

    # The size now, once the monitor is listening, and again each time it
    # changes. QEMU keeps it until the guest's driver is up to be told.
    until nc -z 127.0.0.1 "$MONITOR_PORT" 2>/dev/null; do
        kill -0 "$QEMU_PID" 2>/dev/null || break
        sleep 0.2
    done
    send_console_size
    trap send_console_size WINCH

    while kill -0 "$QEMU_PID" 2>/dev/null; do
        wait "$QEMU_PID" || true
    done
}

main "$@"
