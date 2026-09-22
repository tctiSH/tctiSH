# tctiSH

This is an experimental iSH-alike that runs under the TCTI pseudo-JIT. It does not yet, y'know,
work.

Unless we got this working already and just didn't update the README.md. In that case, it works.

## Building

Everything that isn't Xcode or the guest image comes from the Nix flake, so start there:

```sh
nix develop
```

That provides `xcodegen`, `cocoapods`, Rust, the formatters and the toolchain the QEMU build wants.
Xcode itself is expected to be installed separately.

Everything below has a `make` target, and every target that needs the devshell enters it for you, so
`make build` works from a bare shell. `make` on its own lists them.

The steps are wired together: `make build` depends on the QEMU sysroot, the StikJIT framework,
libssh2 and the Pods, and each of those is a rule on the file it produces rather than a phony target
so they run once and then stay quiet. Running the numbered steps by hand is only for doing one in
isolation.

`deps` watches the files that decide what it builds (`build_dependencies.sh`, the source URLs in
`third-party/dependencies/sources`, and the patches beside them) so editing any of those is enough
to trigger a rebuild. `stikjit` cannot do the same, because it tracks a submodule and no file
reliably changes when a gitlink moves; after bumping StikJIT, force it with
`make clean-stikjit stikjit`.

StikJIT is the only submodule a `make` target builds from; `third-party/SwiftTerm` is the other one,
consumed by Xcode directly. Clone with submodules, or fix one you already have:

```sh
git submodule update --init --recursive
```

### 1. Dependencies

```sh
make deps
```

Builds QEMU and its libraries into `sysroot-iOS-arm64/`. About six minutes from scratch once the
tarballs are cached, and only needed when something under `third-party/dependencies/` changes.

It fetches from the network while it runs: five source tarballs up front, then two git clones part
way through, for QEMU's `libucontext` and `slirp` meson subprojects. Behind a per-process firewall
those clones are the part that will stall.

### 2. StikJIT

```sh
make stikjit
```

Produces `build-StikJIT/StikJIT.xcframework`, which provides the debugger side of JIT enablement on
iOS 26+.

This builds from a _copy_ of the submodule in `build-StikJIT/source`, with the fixes in `patches/`
applied to the copy. The submodule itself is only ever read, so it stays clean in `git status`.

### 3. libssh2

```sh
make libssh2
```

Builds libssh2 and OpenSSL for iOS into `build-libssh2/out`, from release tarballs pinned by version
and hash in `build_libssh2.sh`. About a minute.

The app reaches the guest's shell over SSH through SwiftSH, which is vendored in
`third-party/SwiftSH` rather than fetched, so that it links this build instead of the libssh2 1.8.0
upstream bundles. That one dates from 2016 and shares no key exchange or host key algorithm with the
guest's current dropbear: every connection ends before authentication, and libssh2 reports it to the
app as `authenticationFailed` -- a password problem that isn't.

### 4. Pods

```sh
make pods
```

Needed after a fresh clone and whenever the `Podfile` or `third-party/SwiftSH/SwiftSH.podspec`
changes.

> **Build the workspace, never the bare project.** `tctiSH.xcodeproj` on its own cannot build the
> Pods targets, and fails with `Unable to resolve module dependency: 'Socket'` -- which looks like a
> project-format problem and isn't.

### 5. The app

```sh
make build
```

Or just open `tctiSH.xcworkspace` in Xcode.

`make clean` removes the app and `tctictl` output. `make distclean` also throws away the StikJIT
framework, libssh2 and the QEMU sysroot, which are minutes apiece to rebuild, hence the split. There
is no `clean-pods`, because `Pods/` is checked in and removing it would read as a page of deleted
files rather than a clean slate.

Minimum deployment target is **iOS 18.0**, kept in step across the app, the helper extension, the
pods and the StikJIT build. `build_stikjit.sh` reads it out of the project rather than keeping a
second copy, because a framework built newer than the app embedding it doesn't fail the build, it
fails the launch.

## The Guest Image

Building the guest image depends on three artifacts, all of which can be reproducibly built but are
still checked in due to the expanded tool list needed for their builds.

| Artifact            | Description                                                                                      |
| ------------------- | ------------------------------------------------------------------------------------------------ |
| `assets/bzImage`    | The guest kernel.                                                                                |
| `assets/initrd.img` | The root filesystem the VM boots.                                                                |
| `assets/empty.qcow` | The blank persistent store that the app copies out of its bundle whenever starting from scratch. |

They can be built, assuming the [prerequisites](#Prerequisites) are available, as follows:

```sh
make guest
```

`make build` depends on the rootfs and the disk, as rules on the files rather than phony targets, so
they rebuild when the overlay or the lock moves.

**It does not depend on the kernel**, which is the one asymmetry worth knowing about. The other two
take about a second each, so depending on them is free; a kernel build is tens of minutes, and a
fresh clone has no meaningful mtimes to reason from as git stamps every file with the checkout time,
so the dependency would risk a twenty-minute surprise on someone's first build. The consequence is
that after editing `tctish.config` you have to run `make kernel` yourself; `make build` will not
notice.

They remain checked in on purpose. The packages `rootfs.lock` pins get deleted from Alpine's CDN
within weeks of being superseded, so a tree that could only build them would eventually be a tree
that could not. Keeping the blobs means a fresh clone always has a working guest, and the build is
there for when you want to change one.

### Prerequisites

This is the one part of the build the Nix flake can't provide, because it needs a Linux kernel:

```sh
brew install container
container system start
```

macOS cannot run Linux binaries at all, so all three builds re-exec themselves inside
`container run --rm` when invoked from macOS. You run them the same way on either platform.

Each part needs the container for a different reason, and it shows in how they are invoked. The
rootfs build runs x86_64 Alpine tooling (`apk`, and the install scripts it fires) so it needs
somewhere those can _execute_. The kernel build runs nothing x86_64 at all; it cross-compiles, and
wants a Linux only because kbuild is thousands of invocations of tools macOS does not have.

So the two flags below apply to `build_rootfs.sh` only. `build_kernel.sh` needs neither, and is not
given them.

| Flag                      | Reason                                                                    |
| ------------------------- | ------------------------------------------------------------------------- |
| `--rosetta`               | Registers an x86_64 `binfmt_misc` handler, so the guest's own `apk` runs. |
| `--cap-add CAP_SYS_ADMIN` | To `mount -t proc` inside the target.                                     |

That `/proc` mount is non-optional for a non-obvious reason: `apk` chroots into the target to run
install scripts, and Rosetta reads `/proc/self/exe` to identify what it is translating. Without it,
every install script fails with `rosetta error: Unable to open /proc/self/exe`.

Rosetta is an accelerator here, not a dependency. The mechanism is `binfmt_misc`, and `qemu-user` is
an equally valid handler: slower, but not reliant on Apple keeping Rosetta around.

### Pinned Things

`assets/rootfs.lock` names everything the build fetches, with a SHA-256 for each. A plain build
fetches exactly those and verifies every one. To move to current packages:

```sh
make rootfs-lock    # re-resolve against live edge, rewrite the lock
make guest          # build from it
```

The branch is `edge`, deliberately. The shipped image remains a pinned snapshot, but
`/etc/apk/repositories` in the guest points at live edge. We get a reproducible build but the user's
`apk add` still reaches current packages.

It should be noted that Alpine archives `releases/` indefinitely, but keeps only the latest build of
each package in `main/`: the base is pinned durably and the sixteen packages are not. When edge
supersedes one of them the old file goes away, `--lock` is how you catch up.

### Overlay Filesystem

Everything tctiSH adds on top of stock Alpine lives in `assets/overlay/`:

| File                                 | Description                                                                       |
| ------------------------------------ | --------------------------------------------------------------------------------- |
| `init`                               | Unpacks into RAM, builds the overlayfs root, hands off to busybox init.           |
| `etc/inittab`                        | Respawns the getty, syslogd and dropbear.                                         |
| `etc/profile.d/shell_integration.sh` | The PS1 that reports the guest's cwd to the host, and prints `tcti_motd`.         |
| `etc/profile.d/mount_shared.sh`      | Mounts the 9p tag `qemu_launcher.c` passes as `shared`.                           |
| `etc/motd`                           | **Deliberately empty**, so Alpine's own greeting does not print over `tcti_motd`. |

`assets/scripts/` is installed alongside it into `/usr/bin`. `tctictl` is an _input_ rather than
something copied in afterwards, so `make guest` ensures that it is built first.

`init` mounts five pseudo-filesystems into the final root beyond the usual proc/sysfs/devtmpfs,
because the kernel's newer capabilities are only reachable through them:

| mount            | what needs it                                                            |
| ---------------- | ------------------------------------------------------------------------ |
| `tracefs`        | ftrace, kprobes, uprobes — the tracepoints eBPF attaches to              |
| `bpffs`          | pinning BPF maps and programs; libbpf and bpftool expect this exact path |
| `cgroup2`        | any cgroup-scoped BPF program, and what makes `CONFIG_MEMCG` reachable   |
| `securityfs`     | the LSM interface, BPF LSM included                                      |
| `debugfs` (0700) | older tooling that reaches tracing through it rather than tracefs        |

None of them costs anything at runtime. They are virtual — no threads, no timers, no I/O — and
mounting only makes an interface visible. The work behind tracing is paid for by having it compiled
in, and `cgroup2` enables no controllers until something writes to `cgroup.subtree_control`.

`etc/inittab` respawns `tctish-powerbtn`, which is what makes `system_powerdown` work. QEMU asserts
the ACPI power button, the kernel turns that into an input event — it could not before
`CONFIG_ACPI_BUTTON` — and this reads the event and calls `poweroff`. Without it the request is
received and ignored, and the VM has to be killed, which is a plug-pull the ext4 journal then has to
recover from.

It is not `acpid`, though busybox ships one: acpid's default event source is `/proc/acpi/event`, an
interface the kernel removed years ago. The event is four `input_event` structs on a character
device, and reading one is less machinery than configuring a daemon to read it. It finds the device
by name rather than assuming `event0`, for the same reason the disk is `/dev/vda` rather than a
hardcoded major.

`etc/resolv.conf` points at `192.168.100.3`, QEMU's built-in DNS forwarder, which resolves through
the phone and so follows its VPN and private DNS.

`init` also sets `vm.overcommit_memory` to 1. The kernel's default refuses any single mapping larger
than RAM plus swap, and the guest has no swap and often only a gibibyte, so programs that reserve
far more than they use -- Lean's 1 GiB thread stacks, for one -- failed with "Resource temporarily
unavailable". It costs the phone nothing: QEMU caps guest RAM at `-m`, and iOS only charges for
guest pages actually touched.

`init` mounts the persistent disk as `/dev/vda`, straight from devtmpfs. It used to hand-roll
`mknod /dev/ios0 b 254 0`, which worked only because virtio-blk happened to land on major 254 — the
major is allocated dynamically at registration, so nothing guaranteed it. devtmpfs was already
mounted twenty lines earlier, so the node had been redundant as well as brittle.

The root password is set from a literal hash in `build_rootfs.sh` rather than by calling `passwd`,
because crypt(3) salts randomly and a fresh hash each build would defeat the lock. It has to be set
at all because Alpine's minirootfs ships `root:*`, which disables password login. The app connects
as root/toor, so without it dropbear refuses and the user never sees the terminal.

### Blank Disk

`assets/build_disk.sh` makes `empty.qcow`: a 200 GiB qcow2 carrying a made, never-mounted ext4
filesystem. It is 19 MB on disk due to `qcow2`'s sparseness and it containing essentially nothing.

Despite the name it is **not** an empty disk, and should not become one. `init` _can_ format the
disk itself but that would charge every user a `mkfs` of a 200 GiB filesystem under emulation on
their very first launch: too expensive for a good user experience.

Two things are pinned: the filesystem UUID and directory hash seed, which mke2fs would otherwise
generate randomly, and the feature set. The feature list is prefixed `none,` deliberately. This
matters beyond reproducibility: a feature the guest kernel does not implement shows up as a mount
failure on device rather than as a build error.

### The Kernel

`assets/build_kernel.sh` builds `bzImage` from a pinned kernel.org tarball, verified by hash. The
line is **6.18**, the newest longterm; picking a non-LTS line is how the guest spent four years on a
6.0 release candidate, so this should move along 6.18.x and change lines only deliberately.

```sh
make kernel          # build it
make kernel-config   # resolve the config and report the delta, without building
```

Two things are pinned, against two different kinds of drift:

|                   | pinned by                                                            |
| ----------------- | -------------------------------------------------------------------- |
| the kernel source | a tarball and its SHA-256, in `build_kernel.sh`                      |
| the toolchain     | `assets/kernel/flake.lock`, which fixes nixpkgs to an exact revision |

The second matters more than it looks. A kernel's bytes depend on its compiler in detail, and a
container image pins nothing — `alpine:latest` moves and the clang inside it moves with it. Nix
gives an exactly-pinned clang, lld and pahole with no daemon: the container is still `--rm`.

Nothing x86_64 runs during this build. Unlike the rootfs it needs neither `--rosetta` nor
`CAP_SYS_ADMIN` — the kernel is _cross-compiled_ via `LLVM=1`, which is tier-1 upstream for x86_64
and needs no separate cross-targeted toolchain, clang being a cross compiler by construction.

> The kernel is built with the **unwrapped** clang, while host tools use the wrapped one on `PATH`.
> nixpkgs' cc-wrapper targets a single triple and says so when asked to cross-compile; it fails
> concretely at `scripts/mod/empty.o`. Unwrapped is right rather than merely quieter — the kernel
> compiles `-nostdinc` and supplies every header itself — but `objtool` and `resolve_btfids` are
> ordinary native programs that want a libc, so only `CC` is overridden.

Two container-managed volumes hold what cannot live on a macOS bind mount, and in both cases that is
forced rather than chosen:

| Volume          | Why it Can't Be a Directory                                                                                                                                                                                                                                                                             |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `tctish-nix`    | **macOS is case-insensitive and the Nix store is not** — one perl package ships `pod` and `Pod` in the same directory, so copying a store onto APFS fails partway with `File exists` and leaves it silently incomplete.                                                                                 |
| `tctish-kernel` | **the bind mount does not reproduce symlinks.** A kernel tree has 85 of them; unpacked onto the bind mount, `tools/testing/selftests/bpf/json_writer.h` becomes a zero-length file with mode `000` that the container then cannot unlink, so `--clean` and rebuild fails and the tree is quietly wrong. |

Everything that needs to be _seen_ from macOS stays on the bind mount, because it is all plain
files: the source tarball (so `--clean` costs no re-download), the config reports, and `bzImage`
itself. `--clean` drops the kernel volume, `--clean-all` drops both.

#### The Configuration

`assets/kernel/tctish.config` is the whole configuration, in `savedefconfig` form: a minimal list of
what differs from the kernel's own defaults, which is why ~270 lines describe a kernel with
thousands of options. Symbols absent from it take the kernel default.

**Every line in it is asserted after configuration**, and a symbol that did not take fails the
build. This is not ceremony — Kconfig's failure mode is silence. A symbol whose dependencies are
unmet is dropped without a word, `make` succeeds, the kernel boots, and the feature is absent. It
has caught five real faults so far:

| What                                     | Why                                                                                                                                   |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `CONFIG_SQUASHFS` silently dropped       | needs `MISC_FILESYSTEMS`, which was off                                                                                               |
| every CPU mitigation silently re-enabled | `SPECULATION_MITIGATIONS` was renamed `CPU_MITIGATIONS` in 6.10, so `olddefconfig` had no old value to carry and took the new default |
| `CONFIG_I2C_I801` unsatisfiable          | `I2C` was being selected by `DRM`; disabling DRM removed it                                                                           |
| `CONFIG_MICROCODE` not disableable       | it is `def_bool y` in 6.18 — there is no prompt                                                                                       |
| `CPU_IDLE_GOV_HALTPOLL` not disableable  | `select`-only; `HALTPOLL_CPUIDLE` is what to turn off                                                                                 |

The file also restates symbols it does _not_ change — the overlay root, 9p, virtio, the initramfs —
purely so the assertion pass becomes a tripwire. The mitigations entry is the evidence that earns
that space: a default which holds today is not one that holds across the next four-year jump.

Each build writes `build-kernel/config-delta.txt`, diffed against the previous build of the tree. A
reconfigure that changes nothing leaves the last meaningful report standing.

### Booting the Guest Locally

```sh
make boot-guest              # serial console, guest logs in as root
make boot-guest ARGS=--ssh   # connect over SSH instead
```

`assets/boot_guest.sh` boots the shipped `bzImage`, `initrd.img` and a writable copy of `empty.qcow`
on this Mac. `--help` lists the rest: `--fresh` to discard the working disk, `--share` to offer a
different host directory over 9p (it appears at `/ios_host`), `--snapshot` to resume one, and
`--memory`/`--cpus`.

QEMU comes from the devshell, which is why this has a `make` target rather than being run directly.

**It tests the guest image, not TCTI.** The emulator here is an ordinary host QEMU running plain
TCG; the QEMU the app ships is cross-compiled for iOS, links the TCTI backend, and is built as a
dylib the app `dlopen`s, so it cannot run on macOS at all. Anything about execution under
translation still needs a device.

It does pin the machine _type_ to `pc-i440fx-10.0`, the default of the QEMU we ship, so that a newer
host QEMU does not quietly test a different machine. That axis is not hypothetical: `pc-i440fx-6.2`
changed what a bare `-smp 4` meant and cost the guest three of its four CPUs.

This replaces `start_qemu.sh`, which was the 2022 developer loop and had been unrunnable for years —
it built QEMU from a submodule that no longer exists, passed `-soundhw hda` (removed from QEMU in
6.0), and packed the ramdisk with a `cpio` flag pair GNU cpio rejects.

### Hand-Editing Instead

`dev_ramdisk.sh` unpacks `initrd.img` into `assets/ramdisk/` and `make_ramdisk.sh` packs it back,
for quick experiments inside the guest. That path is not reproducible and `build_rootfs.sh` will
overwrite whatever it produces. It's for trying something, not for shipping it.

## Formatting

```sh
make format         # rewrite everything
make format-check   # report, change nothing
```

One formatter per language, all of them pinned by the flake except `swift-format` and
`clang-format`, which come from the active Xcode toolchain so that they apply exactly what the IDE
applies on save. An Xcode upgrade can therefore move the Swift and C formatting on its own.

|                            | tool                                                   | config                          |
| -------------------------- | ------------------------------------------------------ | ------------------------------- |
| Swift                      | `swift-format` (Xcode)                                 | `.swift-format`                 |
| C, Objective-C             | `clang-format` (Xcode)                                 | `.clang-format`                 |
| Rust                       | `rustfmt`, from nightly -- the config is nightly-gated | `rustfmt.toml`                  |
| Shell                      | `shfmt`                                                | `SHFMT_FLAGS` in the `Makefile` |
| Python                     | `ruff format`                                          | `ruff.toml`                     |
| Nix                        | `nixfmt`                                               | --                              |
| Ruby                       | `rufo`                                                 | --                              |
| Markdown, JSON, TOML, YAML | `dprint`                                               | `dprint.json`                   |

100 columns throughout. Submodules, `Pods/`, `assets/` and `patches/` are excluded and stay that
way: the first two are not ours, the guest-side scripts are their own world, and reformatting a
patch breaks it silently, because its context lines are literal.

The QEMU command line in `qemu_launcher.c` sits inside a `// clang-format off` fence. It is laid out
one option pair per line on purpose, and bin-packing it loses the structure -- along with, in one
case, splitting a string literal through the middle of `192.168.100.0/24`.

## Running

### JIT

JIT needs a debugger, because on iOS 26+ TXM stops a process making its own mappings executable.
There are two ways to provide one.

**With StikJIT, standalone.** What ships. Needs:

- [LocalDevVPN](https://github.com/jkcoxson/LocalDevVPN), or some other loopback VPN, running on the
  device, and
- an RPPairing file, generated by [`idevice_pair`](https://github.com/jkcoxson/idevice_pair).

Launch the app and it offers to import one if it is missing. Everything after that is automatic: it
checks the tunnel, has the helper extension attach a debugger, and boots the VM with JIT. A device's
first launch fetches a developer disk image first, and runs without JIT while it does.

**With Xcode.** For development. Install the LLDB script once, into `~/.lldbinit-Xcode`:

```
command script import /path/to/tctiSH/utils/jit-bless/jit_bless.py
```

The app notices a debugger is already attached and leaves the JIT region to it, so StikJIT is not
involved at all. Blessing takes ~15s under LLDB against ~1.2s via StikJIT, because the SB API cannot
batch its writes; the app is frozen throughout, which is expected rather than a hang. Watch
`/tmp/jit-bless.log` to see it working.

The script scopes itself to the QEMU JIT framework, so it stays inert in every other project you
debug. See [`utils/README.md`](utils/README.md).

### Logs

Console.app, filtered on subsystem `<bundle-id>.tctish` for everything, or one of:

| subsystem               | what is in it                                       |
| ----------------------- | --------------------------------------------------- |
| `io.ara.tctish.jit`     | enablement decisions, and the helper extension      |
| `io.ara.tctish.qemu`    | which QEMU build and boot image the VM started with |
| `io.ara.tctish.network` | tunnel, developer disk image, SSH                   |
| `io.ara.tctish.fs`      | files and where they live                           |
| `io.ara.tctish.ui`      | app lifecycle                                       |

All processes log there.

### When the VM Fails to Boot

The status pill in the top right turns red and offers a recovery boot after 30 seconds without a
shell. That resets the machine and boots Linux from scratch, losing the resumed session. Same effect
as choosing Recovery Boot in Settings, without having to go and find it.
