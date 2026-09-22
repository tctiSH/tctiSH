.DEFAULT_GOAL := help

# This is set if inside the devshell, so any command that MUST run in the devshell should have
# $(SHELL_WRAPPER) prefixed.
ifeq ($(IN_NIX_SHELL),)
    SHELL_WRAPPER := nix develop --command
else
    SHELL_WRAPPER :=
endif

.PHONY: help
help:
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

# -- Artifacts ------------------------------------------------------------------------------------

# What each build step actually produces. `build` depends on these files rather than on the phony
# targets below, because a phony prerequisite would rebuild QEMU on every single `make build`.
QEMU_SYSROOT      := sysroot-iOS-arm64
QEMU_FRAMEWORK    := $(QEMU_SYSROOT)/Frameworks/qemu-x86_64-softmmu_jit.framework
QEMU_LIBRARY      := $(QEMU_FRAMEWORK)/qemu-x86_64-softmmu_jit
STIKJIT_BUILD     := build-StikJIT
STIKJIT_FRAMEWORK := $(STIKJIT_BUILD)/StikJIT.xcframework/Info.plist
IDEVICE_BUILD     := build-idevice
IDEVICE_LIBRARY   := $(IDEVICE_BUILD)/out/libidevice_ffi.a
LIBSSH2_BUILD     := build-libssh2
LIBSSH2_LIBRARY   := $(LIBSSH2_BUILD)/out/libssh2.a
PODS_MANIFEST     := Pods/Manifest.lock
TCTICTL_TARGET    := x86_64-unknown-linux-musl
TCTICTL_BINARY    := utils/tctictl/target/$(TCTICTL_TARGET)/release/tctictl
GUEST_INITRD      := assets/initrd.img
GUEST_DISK        := assets/empty.qcow
GUEST_KERNEL      := assets/bzImage

# -- Building -------------------------------------------------------------------------------------

# QEMU is a release tarball plus a patch file, both named in
# third-party/dependencies/, so the prerequisites are the things that decide what gets built:
# the script, the source URL, and our changes to it. StikJIT is still a submodule and still
# tracks nothing -- after bumping it, force the rebuild with `make clean-stikjit stikjit`.
$(QEMU_LIBRARY): build_dependencies.sh third-party/dependencies/sources \
                 $(wildcard third-party/dependencies/*.patch)
	$(SHELL_WRAPPER) ./build_dependencies.sh

# Pinned by version inside build_idevice.sh, so that is the only prerequisite: a
# bump there is what should trigger a rebuild.
$(IDEVICE_LIBRARY): build_idevice.sh
	$(SHELL_WRAPPER) ./build_idevice.sh

$(STIKJIT_FRAMEWORK): build_stikjit.sh $(wildcard patches/*.patch) $(IDEVICE_LIBRARY)
	$(SHELL_WRAPPER) ./build_stikjit.sh

# Pinned by version and hash inside build_libssh2.sh, so again the script is the only prerequisite.
# No $(SHELL_WRAPPER): it needs Xcode's iOS SDK and nothing the devshell adds.
$(LIBSSH2_LIBRARY): build_libssh2.sh
	./build_libssh2.sh

# The vendored SwiftSH podspec is an input too: it is where the pod learns to look in
# build-libssh2/out, and a change to it means nothing until `pod install` regenerates the project.
#
# The touch is because pod install leaves Manifest.lock alone when its content would not change, and
# for a podspec that is any edit the parsed spec cannot see a comment, for example. Without it the
# manifest stays older than its input and every `make build` runs pod install again.
$(PODS_MANIFEST): Podfile third-party/SwiftSH/SwiftSH.podspec
	$(SHELL_WRAPPER) pod install
	touch $@

# -- The guest ------------------------------------------------------------------------------------

# initrd.img and empty.qcow stay checked in, because they are what the app bundles and because the
# packages rootfs.lock pins are deleted from Alpine's CDN within weeks of being superseded -- so a
# tree that could only build them would eventually be a tree that could not.
#
# They are still rules on the files they produce, so a change to the overlay or the lock rebuilds
# them and a clean tree stays quiet. Note the consequence: these two are the only targets that need
# the container runtime, and only when something they depend on has actually moved.
#
# No $(SHELL_WRAPPER) on either. Both re-exec themselves into a container, and the devshell's $PATH
# filter would take Homebrew's `container` away from them -- the scripts look in Homebrew's prefix
# themselves so that running under `nix develop` works anyway, but there is nothing here they want
# from the devshell.
$(TCTICTL_BINARY): $(wildcard utils/tctictl/src/*.rs) utils/tctictl/Cargo.toml
	$(SHELL_WRAPPER) cargo build --release --manifest-path utils/tctictl/Cargo.toml \
		--target $(TCTICTL_TARGET)

# tctictl is an input to the image rather than something copied in afterwards, so it is a
# prerequisite and not a separate step.
$(GUEST_INITRD): assets/build_rootfs.sh assets/rootfs.lock $(TCTICTL_BINARY) \
                 $(shell find assets/overlay assets/scripts -type f 2>/dev/null)
	./assets/build_rootfs.sh

# Nothing but the script decides what this contains.
$(GUEST_DISK): assets/build_disk.sh
	./assets/build_disk.sh

# The kernel is deliberately *not* a prerequisite of `build`, which is where it parts company with
# the two rules above. Those take about a second, so depending on them is free insurance against
# shipping a stale image; this one is tens of minutes, and a fresh clone has no reliable mtimes to
# reason from.
#
# The consequence is real and worth knowing: after editing tctish.config you must run `make guest`
# (or this target) yourself. `make build` will not notice.
$(GUEST_KERNEL): assets/build_kernel.sh assets/kernel/tctish.config assets/kernel/flake.lock assets/kernel/flake.nix
	./assets/build_kernel.sh

.PHONY: deps
deps: $(QEMU_LIBRARY) ## Build QEMU and its libraries into sysroot-iOS-arm64/ (slow)

.PHONY: idevice
idevice: $(IDEVICE_LIBRARY) ## Build idevice's FFI library for iOS from source

.PHONY: libssh2
libssh2: $(LIBSSH2_LIBRARY) ## Build libssh2 and OpenSSL for iOS, for the vendored SwiftSH pod

.PHONY: stikjit
stikjit: $(STIKJIT_FRAMEWORK) ## Build build-StikJIT/StikJIT.xcframework from the patched submodule copy

.PHONY: pods
pods: $(PODS_MANIFEST) ## Install the CocoaPods dependencies

# Always the workspace, never the bare project: tctiSH.xcodeproj on its own cannot build the Pods
# targets, and fails with "Unable to resolve module dependency: 'Socket'" -- which looks like a
# project-format problem and isn't.
.PHONY: guest
guest: $(GUEST_INITRD) $(GUEST_DISK) $(GUEST_KERNEL) ## Build the whole guest image: kernel, rootfs and blank disk (needs `container`)

.PHONY: kernel
kernel: $(GUEST_KERNEL) ## Build just the guest kernel into assets/bzImage (slow)

.PHONY: kernel-config
kernel-config: ## Resolve the guest kernel config and report the delta, without building
	./assets/build_kernel.sh --config-only

# Runs on the host rather than in a container, so it goes through the devshell like everything else
# that needs a pinned tool: QEMU, in this case.
.PHONY: boot-guest
boot-guest: ## Boot the guest image locally and drop into a shell (see --help for options)
	$(SHELL_WRAPPER) ./assets/boot_guest.sh $(ARGS)

.PHONY: rootfs-lock
rootfs-lock: ## Re-resolve the guest's Alpine packages and rewrite assets/rootfs.lock
	./assets/build_rootfs.sh --lock

.PHONY: build
build: $(QEMU_LIBRARY) $(STIKJIT_FRAMEWORK) $(LIBSSH2_LIBRARY) $(PODS_MANIFEST) $(GUEST_INITRD) $(GUEST_DISK) ## Build the app for a generic iOS device
	xcodebuild -workspace tctiSH.xcworkspace -scheme tctiSH -destination 'generic/platform=iOS' build

.PHONY: tctictl
tctictl: $(TCTICTL_BINARY) ## Build the guest-side tctictl, which `make guest` consumes

# -- Formatting -----------------------------------------------------------------------------------

# swift-format and clang-format come from the active Xcode toolchain rather than from nixpkgs, so
# that they apply exactly what the IDE applies on save. Resolved once here, and checked before use
# so a toolchain without them fails loudly instead of silently skipping two languages.
SWIFT_FORMAT := $(shell xcrun --find swift-format 2>/dev/null)
CLANG_FORMAT := $(shell xcrun --find clang-format 2>/dev/null)

define require_xcode_tool
@test -n "$(1)" || { \
	echo "error: $(2) is not in the active Xcode toolchain." >&2; \
	echo "       'xcode-select -p' says: $$(xcode-select -p)" >&2; \
	exit 1; \
}
endef

# Not ours to reformat, and excluded everywhere. See tmp/plans/autoformatting.md.
#
#   third-party             submodules and vendored sources, including the QEMU patch
#   Pods                    vendored by CocoaPods, rewritten by `pod install`
#   assets                  guest-side build scripts, their own world
#   patches                 context lines are literal, so reformatting silently breaks them
#
# Everything is found through `git ls-files`, which also keeps build output out by construction.
NOT_OURS := ^(third-party|Pods|assets|patches)/

SWIFT_SOURCES  := $(shell git ls-files '*.swift' | grep -Ev '$(NOT_OURS)')
C_SOURCES      := $(shell git ls-files '*.c' '*.h' '*.m' '*.mm' | grep -Ev '$(NOT_OURS)')
SHELL_SOURCES  := $(shell git ls-files '*.sh' | grep -Ev '$(NOT_OURS)')
PYTHON_SOURCES := $(shell git ls-files '*.py' | grep -Ev '$(NOT_OURS)')
# Nix gets a narrower exclusion than the rest. The `assets/` entry in NOT_OURS is about guest-side
# shell scripts having their own conventions; a Nix flake is ours wherever it happens to sit, and
# assets/kernel/flake.nix pins the kernel toolchain. The wildcard is there as well as `git ls-files`
# so that a flake is formatted before its first commit rather than after it -- $(sort) dedupes the
# two sources once it is tracked.
NOT_OURS_NIX   := ^(third-party|Pods|patches)/
NIX_SOURCES    := $(sort $(shell git ls-files '*.nix' | grep -Ev '$(NOT_OURS_NIX)') \
                         $(wildcard assets/kernel/*.nix))
RUBY_SOURCES   := $(shell git ls-files 'Podfile' '*.rb' | grep -Ev '$(NOT_OURS)')
RUST_SOURCES   := $(shell git ls-files '*.rs' | grep -Ev '$(NOT_OURS)')

# tctictl only ever runs inside the guest, so it is linted for the guest's target. Without this,
# cargo builds it for the macOS host, where the Linux-only sys-mount crate does not compile at all
# -- twenty errors in a dependency, before any of our own code is looked at. The devshell provides
# the target; see utils/tctictl/build_and_copy.sh, which builds with the same one.
CARGO_TARGET := x86_64-unknown-linux-musl

# Four spaces, matching Xcode's editor and the existing scripts. The dialect comes
# from each script's shebang, so a genuinely POSIX script would still be treated
# as one.
SHFMT_FLAGS := --indent 4 --case-indent

# Comments are the one thing swift-format will not touch: it neither breaks a line that runs past
# the limit nor joins short ones back up, so a paragraph wrapped at 60 columns and one wrapped at 99
# both pass, for ever. SwiftFormat's `wrap` rule does the first but not the second, and cannot be
# scoped to comments without also taking authority over code layout -- measured at 43 code lines
# changed against 2 comment lines on this tree. Hence our own pass, which is the exact complement of
# swift-format: it rewrites comments and never code, and runs first so neither can undo the other.
# Doc comments get a narrower measure than the code they sit above: they are read as prose, in a
# popover or on a docs page, and 100 columns of it is a wall.
COMMENT_REFLOW := utils/reflow-comments/reflow_comments.py
COMMENT_WIDTH := 100
DOC_COMMENT_WIDTH := 80
REFLOW_FLAGS := --width $(COMMENT_WIDTH) --doc-width $(DOC_COMMENT_WIDTH)

.PHONY: format-swift
format-swift: ## Format the Swift sources
	$(call require_xcode_tool,$(SWIFT_FORMAT),swift-format)
	@$(SHELL_WRAPPER) python3 $(COMMENT_REFLOW) $(REFLOW_FLAGS) $(SWIFT_SOURCES)
	@$(SWIFT_FORMAT) format --parallel --in-place $(SWIFT_SOURCES)

.PHONY: format-c
format-c: ## Format the C and Objective-C sources
	$(call require_xcode_tool,$(CLANG_FORMAT),clang-format)
	@$(CLANG_FORMAT) -i $(C_SOURCES)

.PHONY: format-rust
format-rust: ## Format the Rust sources
	@$(SHELL_WRAPPER) python3 $(COMMENT_REFLOW) $(REFLOW_FLAGS) $(RUST_SOURCES)
	$(SHELL_WRAPPER) cargo fmt --manifest-path utils/tctictl/Cargo.toml --all

.PHONY: format-shell
format-shell: ## Format the shell scripts
	$(SHELL_WRAPPER) shfmt $(SHFMT_FLAGS) --write $(SHELL_SOURCES)

.PHONY: format-python
format-python: ## Format the Python sources
	$(SHELL_WRAPPER) ruff format $(PYTHON_SOURCES)

.PHONY: format-nix
format-nix: ## Format the Nix sources
	$(SHELL_WRAPPER) nixfmt $(NIX_SOURCES)

.PHONY: format-ruby
format-ruby: ## Format the Podfile
	$(SHELL_WRAPPER) rufo --simple-exit $(RUBY_SOURCES)

.PHONY: format-docs
format-docs: ## Format the docs and configs (Markdown, JSON, TOML, YAML)
	$(SHELL_WRAPPER) dprint fmt

.PHONY: format
format: format-swift format-c format-rust format-shell format-python format-nix format-ruby format-docs ## Format everything

# -- Checking -------------------------------------------------------------------------------------

# swift-format has no --check, so diff its output against the file. `diff -u` exits non-zero on a
# difference, and the loop keeps going so one run reports every offending file rather than the first.
.PHONY: format-check-swift
format-check-swift: ## Check Swift formatting without changing files
	$(call require_xcode_tool,$(SWIFT_FORMAT),swift-format)
	@$(SHELL_WRAPPER) python3 $(COMMENT_REFLOW) $(REFLOW_FLAGS) --check $(SWIFT_SOURCES)
	@failed=0; for f in $(SWIFT_SOURCES); do \
		$(SWIFT_FORMAT) format "$$f" | diff -u --label "$$f" --label "$$f (formatted)" "$$f" - || failed=1; \
	done; exit $$failed

.PHONY: format-check-c
format-check-c: ## Check C and Objective-C formatting without changing files
	$(call require_xcode_tool,$(CLANG_FORMAT),clang-format)
	@$(CLANG_FORMAT) --dry-run --Werror $(C_SOURCES)

.PHONY: format-check-rust
format-check-rust: ## Check Rust formatting without changing files
	@$(SHELL_WRAPPER) python3 $(COMMENT_REFLOW) $(REFLOW_FLAGS) --check $(RUST_SOURCES)
	$(SHELL_WRAPPER) cargo fmt --manifest-path utils/tctictl/Cargo.toml --all --check

.PHONY: format-check-shell
format-check-shell: ## Check shell formatting without changing files
	$(SHELL_WRAPPER) shfmt $(SHFMT_FLAGS) --diff $(SHELL_SOURCES)

.PHONY: format-check-python
format-check-python: ## Check Python formatting without changing files
	$(SHELL_WRAPPER) ruff format --check $(PYTHON_SOURCES)

.PHONY: format-check-nix
format-check-nix: ## Check Nix formatting without changing files
	$(SHELL_WRAPPER) nixfmt --check $(NIX_SOURCES)

.PHONY: format-check-ruby
format-check-ruby: ## Check the Podfile's formatting without changing it
	$(SHELL_WRAPPER) rufo --check --simple-exit $(RUBY_SOURCES)

.PHONY: format-check-docs
format-check-docs: ## Check docs and config formatting without changing files
	$(SHELL_WRAPPER) dprint check

.PHONY: format-check
format-check: format-check-swift format-check-c format-check-rust format-check-shell format-check-python format-check-nix format-check-ruby format-check-docs ## Check all formatting without changing files

.PHONY: clippy
clippy: ## Lint the Rust sources with clippy
	$(SHELL_WRAPPER) cargo clippy --manifest-path utils/tctictl/Cargo.toml --all-targets \
		--target $(CARGO_TARGET)

.PHONY: lint
lint: format-check clippy ## Run all the linting tasks

# -- Cleaning -------------------------------------------------------------------------------------

# There is deliberately no clean-pods: Pods/ is checked in, so removing it would show up as a page of
# deleted tracked files rather than as a clean slate. `make pods` regenerates it in place.

.PHONY: clean-app
clean-app: ## Remove the app's build output
	xcodebuild -workspace tctiSH.xcworkspace -scheme tctiSH clean

.PHONY: clean-rust
clean-rust: ## Remove tctictl's build output
	$(SHELL_WRAPPER) cargo clean --manifest-path utils/tctictl/Cargo.toml

.PHONY: clean-stikjit
clean-stikjit: ## Remove the StikJIT framework, its archive and the patched source copy
	rm -rf $(STIKJIT_BUILD)

# Takes the cargo target directory with it, which is most of the size and all of
# the rebuild time. Removing this forces a StikJIT rebuild too, since the
# framework depends on the library.
.PHONY: clean-idevice
clean-idevice: ## Remove the idevice source checkout and its build output
	rm -rf $(IDEVICE_BUILD)

# Keeps nothing, tarballs included; they are re-fetched and re-checked against their pinned hashes.
.PHONY: clean-libssh2
clean-libssh2: ## Remove the libssh2 and OpenSSL build tree and its downloads
	rm -rf $(LIBSSH2_BUILD)

# Both QEMU build trees now live at build-iOS-arm64/<tarball>/qemu_{tcti,jit}, so a single
# `rm -rf build-iOS-arm64` reaches them. It used to configure inside the qemu-tcti submodule, which
# outlived that and left stale objects and a stale config-host.mak behind -- the one thing a clean
# exists to rule out. Removing the tarballs with it also costs a re-download, which is most of why
# this is not something to reach for casually.
#
# By far the largest build tree here: an unpacked kernel source, an object tree with full debug
# info, and the tarball. The toolchain volume is another ~3.6 GB, and lives in the container
# runtime's storage rather than in this directory so `--clean-all` is what reaches it.
.PHONY: clean-kernel
clean-kernel: ## Remove the kernel build tree and the pinned toolchain volume
	./assets/build_kernel.sh --clean-all

.PHONY: clean-deps
clean-deps: ## Remove the QEMU sysroot and its build tree (~6 minutes to rebuild, plus downloads)
	rm -rf $(QEMU_SYSROOT) build-iOS-arm64

# The two cheap ones. StikJIT and the QEMU sysroot are both minutes, but neither is something you
# want thrown away by a reflexive `make clean`; that is what distclean is for.
.PHONY: clean
clean: clean-app clean-rust ## Remove the app and tctictl build output

.PHONY: distclean
distclean: clean clean-stikjit clean-idevice clean-libssh2 clean-deps clean-kernel ## Remove everything, including the slow QEMU, StikJIT and kernel builds

# -- Utility --------------------------------------------------------------------------------------

.PHONY: shell
shell: ## Launch the user's `$SHELL` inside the devshell
	nix develop --command $(shell echo $$SHELL)

.PHONY: editor
editor: ## Launch the user's `$EDITOR` inside the devshell
	nix develop --command $(EDITOR)
