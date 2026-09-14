# tctiSH

This is an experimental iSH-alike that runs under the TCTI pseudo-JIT. It does not yet, y'know,
work.

Unless we got this working already and just didn't update the README.md. In that case, it works.

## Building

Everything that isn't Xcode comes from the Nix flake, so start there:

```sh
nix develop
```

That provides `xcodegen`, `cocoapods`, Rust, the formatters and the toolchain the QEMU build wants.
Xcode itself is expected to be installed separately.

Everything below has a `make` target, and every target that needs the devshell enters it for you, so
`make build` works from a bare shell. `make` on its own lists them.

The steps are wired together: `make build` depends on the QEMU sysroot, the StikJIT framework and
the Pods, and each of those is a rule on the file it produces rather than a phony target -- so they
run once and then stay quiet. Running the numbered steps by hand is only for doing one in isolation.

Neither `deps` nor `stikjit` watches its submodule. There is no file that reliably changes when a
gitlink moves, and a wrong guess costs an hour of QEMU, so after bumping `qemu-tcti` or `StikJIT`
force it: `make clean-deps deps`, or `make clean-stikjit stikjit`.

Clone with submodules, or fix one you already have:

```sh
git submodule update --init --recursive
```

### 1. Dependencies

```sh
make deps
```

Builds QEMU and its libraries into `sysroot-iOS-arm64/`. Slow, and only needed when the QEMU
submodule moves.

### 2. StikJIT

```sh
make stikjit
```

Produces `build-StikJIT/StikJIT.xcframework`, which provides the debugger side of JIT enablement on
iOS 26+.

This builds from a _copy_ of the submodule in `build-StikJIT/source`, with the fixes in `patches/`
applied to the copy. The submodule itself is only ever read, so it stays clean in `git status`.

### 3. Pods

```sh
make pods
```

Needed after a fresh clone and whenever the `Podfile` changes.

> **Build the workspace, never the bare project.** `tctiSH.xcodeproj` on its own cannot build the
> Pods targets, and fails with `Unable to resolve module dependency: 'Socket'` -- which looks like a
> project-format problem and isn't.

### 4. The app

```sh
make build
```

Or just open `tctiSH.xcworkspace` in Xcode.

`make clean` removes the app and `tctictl` output. `make distclean` also throws away the StikJIT
framework and the QEMU sysroot, which is minutes and an hour to rebuild respectively -- hence the
split. There is no `clean-pods`, because `Pods/` is checked in and removing it would read as 67
deleted files rather than a clean slate.

Minimum deployment target is **iOS 18.0**, kept in step across the app, the helper extension, the
pods and the StikJIT build. `build_stikjit.sh` reads it out of the project rather than keeping a
second copy, because a framework built newer than the app embedding it doesn't fail the build, it
fails the launch.

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
