<p align=center>
  <img src="https://avatars.githubusercontent.com/u/112928231?s=200"/>
</p>

# tctiSH

tctiSH is a full Linux shell for iOS and iPadOS built atop QEMU in order to support any x86_64
program you can imagine. It is built atop the [QEMU](https://github.com/tctiSH/qemu) machine
emulation and virtualization framework, augmented with the TCTI pseudo-JIT, support features for the
app, and many performance improvements for this use-case.

- **Full System Emulation:** Because it is built atop QEMU, tctiSH emulates _an entire machine and
  operating system_, rather than being just an emulator for a linux userland using syscall
  translation akin to [iSH](https://github.com/ish-app/ish). In doing so it is doing more work (as
  there is a whole Linux kernel running), but this also means that there is no software compiled for
  x86_64 linux that it cannot run.
- **Good Performance via TCTI:** iOS and iPadOS do not generally allow apps to execute code using a
  Just-In-Time (JIT) compiler, which is used by most system emulators to get good performance. TCTI,
  the Tiny Code Threaded Interpreter, is a backend for QEMU's TCG that compiles the tiny code to
  chains of gadgets, reducing overhead _significantly_ when compared to direct interpretation of the
  same. TCTI provides performance that is almost always within one order of magnitude of TCG's
  standard JIT, but the gap is usually even smaller than that.
- **Optional JIT:** The app also supports running with JIT for near-native performance in many
  scenarios. With a loopback VPN such as [LocalDevVPN](https://github.com/jkcoxson/LocalDevVPN)
  running on device, the app can use [StikJIT](https://github.com/StikDebug/StikJIT) to enable JIT
  without needing an additional program. It does need an RRPairing file to do this, but on iOS 27 it
  can generate that file on-device, without the support of a computer.

The roadmap for tctiSH is big, containing a mixture of performance improvements, UX improvements,
and new features. Fundamentally, the goal is to make it the best place to run linux programs of all
kinds on your iOS devices.

## Getting Started

This section provides a quick overview of both how you can [build](#building) the app, and also how
to [use](#basic-usage) it on your phone.

### Building

It is not a goal of this project to provide prebuild binaries that can be re-signed, at least for
the moment. Instead, we provide a fairly simple method to build the app yourself. You will need to
have the following dependencies:

- `nix`, the declarative package manager, installed and available on your `$PATH`.
- [Xcode](https://apps.apple.com/nl/app/xcode/id497799835) installed, with `xcrun` available on your
  `$PATH`.
- [`container`](https://github.com/apple/container) installed and on your path with the container
  runtime service started. `make build` uses it to rebuild the guest image when it looks out of
  date, which in a fresh clone it always does. If you **only want to build the app**, you can skip
  it with `make build GUEST=prebuilt`, which uses the checked-in image as it is.

The build is handled through the [`Makefile`](./Makefile), which provides a number of utility
commands and also abstracts away the usage of `nix` for you. In other words, you can run bare
`make <...>` commands, and it will drop into the nix shell as needed.

To build the app onto your device, you can follow these steps:

1. Clone the repository, making sure you get the submodules.

   ```sh
   git clone --recursive https://github.com/tctiSH/tctiSH
   ```

2. Build the dependencies by running `make build`. This will take some time the first time you do
   it, as it has to fetch all the devshell dependencies and build our QEMU fork.
3. Open `tctiSH.xcworkspace` in Xcode. Open the tctiSH project settings and select the tctiSH target
   before changing the team to your team and setting a bundle identifier you can build with. Then
   select the JITHelper target and do the same.
4. In Xcode's build menu select tctiSH as the scheme and your device as the build target (we do not
   currently support simulator devices). Then run the build. This should launch the app on your
   device, though do note that the first launch under Xcode will hang forever, so feel free to kill
   it and relaunch by hand. You can fix this by installing
   [`jit-bless.py`](./utils/jit-bless/jit_bless.py) as an LLDB script as described in that file.

### Basic Usage

When the app launches you will be met with a terminal and a keyboard, as well as a little pill
telling you that it is starting with TCTI, the interpreter that needs no JIT. What you have is a
bare [Alpine Linux](https://www.alpinelinux.org) environment with little beyond busybox and some
basic tools installed. How you use this is beyond the scope of this document.

- The keyboard provides a bar above it to augment the basic iOS keyboard, including escape, modifier
  keys, and utilities such as arrow keys.
- At its right is a blue cog, which enters the app's settings screen. Here you can configure the
  behavior of the app, including how much memory it uses, what it does in the background, and other
  properties of its runtime.
- Your app state is saved whenever the app goes into the background, but running programs are lost
  due to the terminal's SSH connection starting anew after each resume. If you want stuff to not get
  lost for now you need to unparent it from your shell.
- The `/ios_host` folder is the default form of host access, and corresponds to
  `On My iP(hone|ad)/tctiSH/SharedFolder.d`.
- You can mount additional host folders by calling `mount -t ios <mount-name> <mount-point>`. This
  will pop up a folder picker that lets you pick from any files app location. Once you submit, the
  folder you picked will be mounted at the specified mount point with the given name, but the mount
  point must exist first.
- You can long-press on the app icon to get options to run with or without JIT, or to trigger a
  recovery boot if you are having problems. With the app already running, the JIT options switch the
  running session's mode rather than restarting it.

### Setting Up JIT

To set up JIT mode for tctiSH you first need to download a loopback VPN. We recommend using
[LocalDevVPN](https://github.com/jkcoxson/LocalDevVPN) as it is what the app is developed alongside.
You can get JIT working as follows:

1. Install and activate your loopback VPN.
2. Launch tctiSH.
3. It will detect the tunnel and ask you to provide a pairing:

   - **iOS 27:** Here you can pair on-device. Simply tap the corresponding button and follow the
     instructions.
   - **iOS 26 and Earlier:** You need to generate a pairing file using another device (usually a
     computer), and an RRPairing-capable application like
     [`idevice_pair`](https://github.com/jkcoxson/idevice_pair).

4. Once tctiSH has your pairing file, it switches to JIT by itself (or offers if configured to), and
   the session you have carries on, just faster.

How tctiSH moves between JIT and TCTI is up to you, and you can configure it in Settings > JIT >
Execution Mode:

- **Dynamic (Auto)**, the default, starts with JIT if it is available (the loopback VPN is up and
  tctiSH has your pairing file), and otherwise launches TCTI straight away, switching to JIT by
  itself as soon as it can. If the JIT code cache needs to grow while the loopback VPN is
  unavailable, it switches to TCTI to prevent thrashing and conserve energy.
- **Dynamic (Ask)** does the same, but offers each switch rather than performing it automatically.
- **Always JIT** waits for JIT when the app opens, and switches to it by itself if it arrives later.
- **Never JIT** always runs with TCTI.

You can also switch by hand at any time with **Running with JIT** in the settings. Switching keeps
the session: Linux carries on where it was without knowing that anything has changed.

Note that for JIT to work you will always need your loopback VPN active, and to either be in
airplane mode or connected to WiFi. Once the JIT helper has done its work you can fall back to
mobile data, at least until the helper is needed again. By default, the helper is needed every time
the code cache size is changed (e.g. when it grows in dynamic mode, or when resuming from a
background session that evicted the code cache). If you don't want this behavior, make sure to use a
fixed-size code cache and do not set the app to evict the code cache in the background.

Switching to JIT needs the helper to prepare the JIT's memory, and also to grow that memory.
Switching back to TCTI keeps that memory prepared unless **Flush JIT Buffers** is on. That gives the
memory back while running with TCTI, at the cost of needing the helper again to return. With
**Release Memory** on, it is also given back whenever the session is put away in the background
while running with TCTI.

## Development

If you are interested in developing tctiSH, we work on a PR-based workflow. We recommend that you
fork the repo to make your changes before PRing back. Some additional things to know for developing
the app:

- The minimum deployment target is intentionally iOS and iPadOS 18 as we rely on some newer kernel
  features for performance. This must be kept in sync across the app.
- If you want to work on the JIT in conjunction with Xcode, or simply have JITted launches under
  Xcode not hang, you will need to install the [`jit-bless.py`](./utils/jit-bless/jit_bless.py) LLDB
  script. This performs the other part of the debugger's JIT page blessing dance, as when Xcode's
  debugger is connected the StikJIT debugger connection cannot.
- While `make build` is the umbrella build step, it depends on much more fine-grained build steps.
  Run `make` on its own to see the available build steps.
- `etc/resolv.conf` in the default image points at `192.168.100.3`, QEMU's built-in DNS forwarder,
  which resolves through the phone and so follows its VPN and private DNS settings.
- The root password is set from a literal hash in `build_rootfs.sh` rather than by calling `passwd`,
  because crypt(3) salts randomly and a fresh hash each build would defeat the lock. It has to be
  set at all because Alpine's minirootfs ships `root:*`, which disables password login. The app
  connects as root/toor.
- `assets/build_disk.sh` makes `empty.qcow`: a 200 GiB (maximum size) `.qcow2` carrying a
  newly-created but never-mounted ext4 filesystem. Despite the name it is **not** an empty disk, and
  should not become one as we do not want `init` to force format the disk for the user on every
  first launch as this would be too expensive for good UX.

### The Guest Image

The guest image is checked in by default as its dependencies require a more expansive set of tools
to update. The following three artifacts are required, but you should only need to care about them
if you change the definitions of the kernel or root filesystem builds.

| Artifact            | Description                                                                                      |
| ------------------- | ------------------------------------------------------------------------------------------------ |
| `assets/bzImage`    | The guest kernel.                                                                                |
| `assets/initrd.img` | The root filesystem the VM boots.                                                                |
| `assets/empty.qcow` | The blank persistent store that the app copies out of its bundle whenever starting from scratch. |

They can be built as follows:

```sh
make guest
```

Note that while `make build` will force rebuilds of the root filesystem and disk if their
definitions change, it explicitly does not depend on the kernel as this is an extremely
time-consuming build.

A fresh clone always looks changed to `make` as git gives every file its checkout time, and the root
filesystem depends on `tctictl`, which is built rather than checked into the repo. The first
`make build` in a new clone therefore rebuilds the root filesystem and disk by default, but this can
be skipped using `make build GUEST=prebuilt`.

`assets/rootfs.lock` names all the packages the build fetches, with a hash for each. A plain build
fetches exactly those and verifies every one. You can move the current package set by:

```sh
make rootfs-lock    # re-resolve against live edge, rewrite the lock
make guest          # build from it
```

The branch is `edge` because that is what we have found to be more useful. Even though the shipped
image is a pinned snapshot, the repositories it contains point at `edge` and hence users get the
latest packages whenever they add them.

It should be noted that Alpine archives `releases/` indefinitely, but keeps only the latest build of
each package in `main/`: the base is pinned durably and the sixteen packages are not. When edge
supersedes one of them the old file goes away, `--lock` is how you catch up when building a new
image.

### Overlay Filesystem

Everything tctiSH adds _on top_ of the stock Alpine root filesystem lives in `assets/overlay/`:

| File                                 | Description                                                                       |
| ------------------------------------ | --------------------------------------------------------------------------------- |
| `init`                               | Unpacks into RAM, builds the overlayfs root, hands off to busybox init.           |
| `etc/inittab`                        | Respawns the getty, syslogd and dropbear.                                         |
| `etc/profile.d/shell_integration.sh` | The PS1 that reports the guest's cwd to the host, and prints `tcti_motd`.         |
| `etc/profile.d/mount_shared.sh`      | Mounts the 9p tag `qemu_launcher.c` passes as `shared`.                           |
| `etc/motd`                           | **Deliberately empty**, so Alpine's own greeting does not print over `tcti_motd`. |

`assets/scripts/` is installed alongside it into `/usr/bin`. `tctictl` is an _input_ rather than
something copied in afterwards, so `make guest` ensures that it is built first.

`init` mounts the following five pseudo-filesystems into the final root beyond the usual
proc/sysfs/devtmpfs, because the kernel's capabilities require them:

| mount            | what needs it                                                            |
| ---------------- | ------------------------------------------------------------------------ |
| `tracefs`        | ftrace, kprobes, uprobes — the tracepoints eBPF attaches to              |
| `bpffs`          | pinning BPF maps and programs; libbpf and bpftool expect this exact path |
| `cgroup2`        | any cgroup-scoped BPF program, and what makes `CONFIG_MEMCG` reachable   |
| `securityfs`     | the LSM interface, BPF LSM included                                      |
| `debugfs` (0700) | older tooling that reaches tracing through it rather than tracefs        |

### The Kernel

`assets/build_kernel.sh` builds `bzImage` from a pinned kernel.org tarball, verified by hash. The
line is currently pinned to **6.18**, the latest-available LTS. It should be rare that a contributor
needs to rebuild the kernel, but it can be done as follows:

```sh
make kernel          # build it
make kernel-config   # resolve the config and report the delta, without building
```

Our build pins the kernel source using a tarball and its SHA-256 hash (in `build_kernel.sh`), and
the kernel build toolchain (pinned by `assets/kernel/flake.lock`). This ensures byte-for-byte
reproducible kernel builds, which are done via cross-compilation rather than needing to run x86_64
code like the root filesystem build.

> The kernel is built with the **unwrapped** clang, while host tools use the wrapped one on `PATH`.
> nixpkgs' cc-wrapper targets a single triple and says so when asked to cross-compile; it fails
> concretely at `scripts/mod/empty.o`.

The kernel configuration is specified in `savedefconfig` form in `assets/kernel/tctish.config` as a
minimal list of what differs from the kernel's defaults. We assert every configuration parameter
that differs after the `configure` step, as `kconfig` likes to fail silently.

### Booting the Guest Locally

When working directly on the kernel for paravirtualisation or feature-enablement reasons it can be
very useful to boot the guest kernel locally. This can be done as follows:

```sh
make boot-guest                   # JIT, serial console, guest logs in as root
make boot-guest BACKEND=tcti      # the same, under TCTI
make boot-guest ARGS=--ssh        # connect over SSH instead
make boot-guest ARGS=--help       # the other options
```

`assets/boot_guest.sh` boots the shipped `bzImage`, `initrd.img` and a writable copy of `empty.qcow`
on the developer's mac, using **our QEMU fork** built for macOS. `BACKEND` picks the JIT (the
default) or TCTI, which runs natively on Apple Silicon. The first boot with each backend builds it
into `build-macOS-arm64/` if needed, and later boots rebuild only when the `third-party/qemu`
checkout or the flake changes. `make host-qemu BACKEND=...` builds one without booting it.

The build has its own devshell, `nix develop .#host-qemu`, as building for the mac needs host
libraries that the default devshell deliberately keeps away from the iOS build. The build script
enters it by itself, and keeps those libraries from nix's garbage collector with a GC root in
`build-macOS-arm64/`. `make unroot-host-qemu` removes the root if you want the space back, and the
next boot fetches whatever was collected without recompiling.

Running the guest on our QEMU cannot exercise the iOS-specific code paths, including the debugger
blessing of the code buffer, the purgeable code cache, and TXM enforcement, as well as the app's own
launcher. Testing those still needs to be done on a real device.

### Formatting

We have comprehensive code and documentation formatting set up in the repository, which must be run
before any commit.

```sh
make format         # rewrite everything
make format-check   # report, change nothing
```

### Logs

Console.app, filtered on subsystem `<bundle-id>` (e.g. `io.ara.tctish`) for everything, or one of:

| Subsystem             | What it Logs                                        |
| --------------------- | --------------------------------------------------- |
| `<bundle-id>.jit`     | Enablement decisions, and the helper extension      |
| `<bundle-id>.qemu`    | Which QEMU build and boot image the VM started with |
| `<bundle-id>.network` | Tunnel, developer disk image, SSH                   |
| `<bundle-id>.fs`      | Files and where they live                           |
| `<bundle-id>.ui`      | App lifecycle                                       |
