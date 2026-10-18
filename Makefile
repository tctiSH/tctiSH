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
QEMU_FRAMEWORK    := $(QEMU_SYSROOT)/Frameworks/qemu-x86_64-softmmu.framework
QEMU_LIBRARY      := $(QEMU_FRAMEWORK)/qemu-x86_64-softmmu
STIKJIT_BUILD     := build-StikJIT
STIKJIT_FRAMEWORK := $(STIKJIT_BUILD)/StikJIT.xcframework/Info.plist
IDEVICE_BUILD     := build-idevice
IDEVICE_LIBRARY   := $(IDEVICE_BUILD)/out/libidevice_ffi.a
TCTICTL_TARGET    := x86_64-unknown-linux-musl
TCTICTL_BINARY    := utils/tctictl/target/$(TCTICTL_TARGET)/release/tctictl
GUEST_INITRD      := assets/initrd.img
GUEST_DISK        := assets/empty.qcow
GUEST_KERNEL      := assets/bzImage

# Whether `build` rebuilds the checked-in guest images when their definitions change. GUEST=build
# (the default) does, and needs `container` to. GUEST=prebuilt takes them as checked in, and builds
# them only if they are missing, which is what CI wants as a fresh clone always looks stale.
GUEST             ?= build

# Our QEMU, built for this Mac, which is what `boot-guest` runs. One build per backend:
# build-macOS-arm64/qemu_{jit,tcti}. BACKEND picks which one a target means. The GC root keeps the
# nix libraries those builds link against; see build_host_qemu.sh.
BACKEND           ?= jit
HOST_QEMU_BUILD   := build-macOS-arm64
HOST_QEMU          = $(HOST_QEMU_BUILD)/qemu_$(1)/qemu-system-x86_64
HOST_QEMU_ROOT    := $(HOST_QEMU_BUILD)/nix-gc-root

# Checked only for the targets that use it, so that a BACKEND some other tool left in the
# environment cannot stop every other target from running.
ifneq ($(filter host-qemu boot-guest bench,$(MAKECMDGOALS)),)
    ifeq ($(filter $(BACKEND),jit tcti),)
        $(error BACKEND must be jit or tcti, not '$(BACKEND)')
    endif
endif

ifneq ($(filter build,$(MAKECMDGOALS)),)
    ifeq ($(filter $(GUEST),build prebuilt),)
        $(error GUEST must be build or prebuilt, not '$(GUEST)')
    endif
endif

# The Makefile passes --backend from BACKEND, and builds for BACKEND; one in ARGS as well would boot
# a backend other than the one just built.
ifneq ($(filter boot-guest,$(MAKECMDGOALS)),)
    ifneq ($(filter --backend,$(ARGS)),)
        $(error Choose the backend with BACKEND=jit|tcti, not ARGS=--backend)
    endif
endif

# -- Building -------------------------------------------------------------------------------------

# QEMU is the third-party/qemu submodule, which points at tctiSH's fork. What decides what gets
# built is that checkout -- its commit, and any edits not yet committed, in files git tracks or not
# -- so both are summarised into a stamp, and the library depends on the stamp. 
#
# The stamp's recipe runs every time, but rewrites the file only when the summary changes, so an
# untouched tree stays quiet and an edit in it is noticed. StikJIT is also a submodule and still
# tracks nothing -- after bumping it, force the rebuild with `make clean-stikjit stikjit`.
#
# The submodule is checked out here, not left to build_dependencies.sh: in an empty directory,
# `git -C` finds tctiSH's repository instead, and a stamp of that would change as soon as the
# build checked QEMU out, costing a second full build.
QEMU_STAMP := build-iOS-arm64/qemu-source.stamp

.PHONY: qemu-source-changed
$(QEMU_STAMP): qemu-source-changed
	@mkdir -p $(dir $@)
	@[ -e third-party/qemu/.git ] || git submodule update --init third-party/qemu
	@{ git -C third-party/qemu rev-parse HEAD; git -C third-party/qemu status --porcelain; \
	   git -C third-party/qemu diff HEAD; \
	   cd third-party/qemu && git ls-files -z --others --exclude-standard | xargs -0 -r shasum; \
	 } 2>/dev/null | shasum > $@.new
	@if cmp -s $@.new $@; then rm $@.new; else mv $@.new $@; fi

$(QEMU_LIBRARY): build_dependencies.sh qemu_source.sh third-party/dependencies/sources $(QEMU_STAMP)
	$(SHELL_WRAPPER) ./build_dependencies.sh

# The same checkout and the same stamp, built for this Mac instead. ninja decides what actually
# needs recompiling, so a stamp change it finds nothing in costs seconds; the touch is for that
# case, where nothing is relinked and the binary would otherwise stay older than the stamp.
#
# The flake is an input because the build links against its libraries; the script configures again
# when the host-qemu shell it describes has changed.
#
# No $(SHELL_WRAPPER): the script enters the flake's host-qemu shell itself, which is not the
# default one. See build_host_qemu.sh.
$(HOST_QEMU_BUILD)/qemu_%/qemu-system-x86_64: build_host_qemu.sh qemu_source.sh flake.nix flake.lock \
                                              $(QEMU_STAMP) $(HOST_QEMU_ROOT)
	./build_host_qemu.sh $*
	touch $@

# Made by the script, never here. The empty recipe is what makes a missing root -- after
# `make unroot-host-qemu` -- count as new, so the binaries depending on it run the script again and
# it comes back, along with any libraries a garbage collection took. A root that exists never counts
# as new: it is a symlink, make reads the mtime of what it points at, and the store dates everything
# to the epoch.
$(HOST_QEMU_ROOT): ;

# Pinned by version inside build_idevice.sh, so that is the only prerequisite: a
# bump there is what should trigger a rebuild.
$(IDEVICE_LIBRARY): build_idevice.sh
	$(SHELL_WRAPPER) ./build_idevice.sh

$(STIKJIT_FRAMEWORK): build_stikjit.sh $(wildcard patches/*.patch) $(IDEVICE_LIBRARY)
	$(SHELL_WRAPPER) ./build_stikjit.sh

# -- The guest ------------------------------------------------------------------------------------

# initrd.img and empty.qcow stay checked in, because they are what the app bundles and because the
# packages rootfs.lock pins are deleted from Alpine's CDN within weeks of being superseded -- so a
# tree that could only build them would eventually be a tree that could not.
#
# They are still rules on the files they produce, so a change to the overlay or the lock rebuilds
# them and a tree that has built them once stays quiet. Note the consequence: these two are the only
# targets that need the container runtime, and only when something they depend on has actually
# moved -- which, in a fresh clone, it always seems to have. GUEST=prebuilt is for that.
#
# No $(SHELL_WRAPPER) on either. Both re-exec themselves into a container, and the devshell's $PATH
# filter would take Homebrew's `container` away from them -- the scripts look in Homebrew's prefix
# themselves so that running under `nix develop` works anyway, but there is nothing here they want
# from the devshell.
# What each checked-in image is built from, which the rules below and `check-images` both use. Each
# rule stamps its image into assets/images.sha256 with a digest of these, which is how CI knows an
# image is still what its inputs build; see assets/image_stamps.sh. tctictl's include its Cargo.lock
# and the flake's lock, which pins the Rust it is built with. The overlay and the scripts are what
# git has; the initrd rule refuses to build with anything else in them, which would go into the
# image without being in its digest.
TCTICTL_SOURCES     := $(wildcard utils/tctictl/src/*.rs) utils/tctictl/Cargo.toml \
                       utils/tctictl/Cargo.lock flake.lock
GUEST_INITRD_INPUTS := assets/build_rootfs.sh assets/rootfs.lock $(TCTICTL_SOURCES) \
                       $(shell git ls-files assets/overlay assets/scripts)
GUEST_DISK_INPUTS   := assets/build_disk.sh
GUEST_KERNEL_INPUTS := assets/build_kernel.sh assets/kernel/tctish.config assets/kernel/flake.lock \
                       assets/kernel/flake.nix

$(TCTICTL_BINARY): $(TCTICTL_SOURCES)
	$(SHELL_WRAPPER) cargo build --release --locked --manifest-path utils/tctictl/Cargo.toml \
		--target $(TCTICTL_TARGET)

# tctictl is an input to the image rather than something copied in afterwards, so it is a
# prerequisite and not a separate step.
$(GUEST_INITRD): $(filter-out $(TCTICTL_SOURCES),$(GUEST_INITRD_INPUTS)) $(TCTICTL_BINARY)
	@stray="$$(git ls-files --others assets/overlay assets/scripts)"; \
	if [ -n "$$stray" ]; then \
		echo "error: these would go into the image without being in git:" >&2; \
		echo "$$stray" >&2; \
		exit 1; \
	fi
	./assets/build_rootfs.sh
	./assets/image_stamps.sh stamp $@ $(GUEST_INITRD_INPUTS)

# Nothing but the script decides what this contains.
$(GUEST_DISK): $(GUEST_DISK_INPUTS)
	./assets/build_disk.sh
	./assets/image_stamps.sh stamp $@ $(GUEST_DISK_INPUTS)

# The kernel is deliberately *not* a prerequisite of `build`, which is where it parts company with
# the two rules above. Those take about a second, so depending on them is free insurance against
# shipping a stale image; this one is tens of minutes, and a fresh clone has no reliable mtimes to
# reason from.
#
# The consequence is real and worth knowing: after editing tctish.config you must run `make guest`
# (or this target) yourself. `make build` will not notice.
$(GUEST_KERNEL): $(GUEST_KERNEL_INPUTS)
	./assets/build_kernel.sh
	./assets/image_stamps.sh stamp $@ $(GUEST_KERNEL_INPUTS)

.PHONY: deps
deps: $(QEMU_LIBRARY) ## Build QEMU and its libraries into sysroot-iOS-arm64/ (slow)

.PHONY: host-qemu
host-qemu: $(call HOST_QEMU,$(BACKEND)) ## Build our QEMU for this Mac into build-macOS-arm64/ (BACKEND=jit|tcti)

.PHONY: idevice
idevice: $(IDEVICE_LIBRARY) ## Build idevice's FFI library for iOS from source

.PHONY: stikjit
stikjit: $(STIKJIT_FRAMEWORK) ## Build build-StikJIT/StikJIT.xcframework from the patched submodule copy

.PHONY: guest
guest: $(GUEST_INITRD) $(GUEST_DISK) $(GUEST_KERNEL) ## Build the whole guest image: kernel, rootfs and blank disk (needs `container`)

.PHONY: kernel
kernel: $(GUEST_KERNEL) ## Build just the guest kernel into assets/bzImage (slow)

.PHONY: kernel-config
kernel-config: ## Resolve the guest kernel config and report the delta, without building
	./assets/build_kernel.sh --config-only

# Boots on our QEMU, built for this Mac, so the kernel is tested against the emulator the app ships.
# BACKEND=tcti for TCTI. Setting TCTISH_QEMU to some other qemu-system-x86_64 runs that instead, and
# skips the build, as does asking for --help.
#
# No $(SHELL_WRAPPER): nothing it runs comes from the devshell any more.
.PHONY: boot-guest
boot-guest: $(if $(or $(TCTISH_QEMU),$(filter --help -h,$(ARGS))),,$(call HOST_QEMU,$(BACKEND))) ## Boot the guest image locally on our QEMU (BACKEND=jit|tcti; ARGS=--help for options)
	./assets/boot_guest.sh --backend $(BACKEND) $(ARGS)

# -- Benchmarking ---------------------------------------------------------------------------------

# The suite in utils/bench: real programs, timed in the guest on our QEMU, built for this Mac. See
# utils/bench/README.md for the workloads and how to read the results. It runs the hybrid build, the
# one QEMU with both backends that the app ships, started on BACKEND; BENCH_QEMU runs another build
# instead, such as a baseline, and skips building the hybrid.
#
# Everything it makes is in build-bench/: the disk, the results and each round's logs.
BENCH_DISK  := build-bench/bench.qcow
BENCH_QEMU  ?=
HYBRID_QEMU := $(call HOST_QEMU,hybrid)

# Installs the workloads' programs onto a copy of the app's empty disk, on the JIT, over the
# network. Not rebuilt when the guest image changes: results are only comparable on one disk, so
# making a new one is a decision, made with `make clean-bench bench-disk`.
$(BENCH_DISK): | $(if $(BENCH_QEMU),,$(HYBRID_QEMU))
	python3 utils/bench/bench.py prepare $(if $(BENCH_QEMU),--qemu $(BENCH_QEMU))

.PHONY: bench-disk
bench-disk: $(BENCH_DISK) ## Build build-bench/bench.qcow, the disk the benchmarks run on (needs the network)

# Timing wants a quiet Mac: each round's times are as noisy as whatever else is running.
.PHONY: bench
bench: $(BENCH_DISK) $(if $(BENCH_QEMU),,$(HYBRID_QEMU)) ## Run the benchmarks (BACKEND=jit|tcti; WORKLOADS="a b"; ROUNDS=n; LABEL=name; ARGS=more options)
	python3 utils/bench/bench.py run --backend $(BACKEND) \
		$(if $(BENCH_QEMU),--qemu $(BENCH_QEMU)) $(if $(WORKLOADS),--workloads "$(WORKLOADS)") \
		$(if $(ROUNDS),--rounds $(ROUNDS)) $(if $(LABEL),--label $(LABEL)) $(ARGS)

# A build of the hybrid from another fork commit, beside the default build, for `make bench
# BENCH_QEMU=...` to time against: build-macOS-arm64/qemu_hybrid-<NAME>, NAME defaulting to the
# commit. A full QEMU build, as long as `host-qemu`'s.
.PHONY: bench-baseline
bench-baseline: ## Build the hybrid QEMU from a fork commit to compare against (COMMIT=sha; NAME=suffix)
	@test -n "$(COMMIT)" || { echo "error: name the fork commit: COMMIT=<sha>" >&2; exit 1; }
	python3 utils/bench/bench.py baseline $(COMMIT) $(if $(NAME),--name $(NAME))

.PHONY: bench-compare
bench-compare: ## Tabulate benchmark results against the first label (LABELS="a b ...")
	@test -n "$(LABELS)" || { echo "error: name the results to compare: LABELS=\"a b\"" >&2; \
		ls build-bench/results 2>/dev/null | sed 's/\.jsonl$$//; s/^/  /' >&2; exit 1; }
	@python3 utils/bench/bench.py compare $(LABELS)

.PHONY: bench-list
bench-list: ## Name the benchmark workloads
	@python3 utils/bench/bench.py list

.PHONY: rootfs-lock
rootfs-lock: ## Re-resolve the guest's Alpine packages and rewrite assets/rootfs.lock
	./assets/build_rootfs.sh --lock

# GUEST=prebuilt depends only on the guest images that are missing, so ones that exist are used as
# they are. Not order-only prerequisites: make still brings those up to date, container and all.
ifeq ($(GUEST),prebuilt)
    GUEST_IMAGES := $(filter-out $(wildcard $(GUEST_INITRD) $(GUEST_DISK)),$(GUEST_INITRD) $(GUEST_DISK))
else
    GUEST_IMAGES := $(GUEST_INITRD) $(GUEST_DISK)
endif

# SwiftTerm generates its version information with a build-tool plugin, which Xcode will only run
# once someone has trusted it in the IDE. A command-line build has nobody to ask, so skips the check
# instead.
XCODEBUILD_ACTION := build
XCODEBUILD_ARCHIVE_ARGS :=
XCODEBUILD_CODESIGN_ARGS :=
ifeq ($(XCARCHIVE_BUILD),1)
    XCODEBUILD_ACTION := archive
    XCODEBUILD_ARCHIVE_ARGS := -archivePath "$(HOME)/tctiSH.xcarchive"
endif
ifeq ($(SKIP_CODESIGNING),1)
    XCODEBUILD_CODESIGN_ARGS := CODE_SIGNING_ALLOWED=NO
endif

.PHONY: build
build: $(QEMU_LIBRARY) $(STIKJIT_FRAMEWORK) $(GUEST_IMAGES) ## Build the app for a generic iOS device (XCARCHIVE_BUILD=1 to create ~/tctiSH.xcarchive)
	xcodebuild -project tctiSH.xcodeproj -scheme tctiSH -destination 'generic/platform=iOS' \
		-skipPackagePluginValidation $(XCODEBUILD_ARCHIVE_ARGS) $(XCODEBUILD_CODESIGN_ARGS) $(XCODEBUILD_ACTION)

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

# Not ours to reformat, and excluded everywhere.
#
#   third-party             submodules and vendored sources, including QEMU
#   assets                  the guest's files, but for its shell scripts; see SHELL_SOURCES
#   patches                 context lines are literal, so reformatting silently breaks them
#   utils/bench/guest/aok   aok-vm's benchmarks, kept as they were written; see its NOTICE
#
# Everything is found through `git ls-files`, which also keeps build output out by construction.
NOT_OURS := ^(third-party|assets|patches|utils/bench/guest/aok)/

SWIFT_SOURCES  := $(shell git ls-files '*.swift' | grep -Ev '$(NOT_OURS)')
C_SOURCES      := $(shell git ls-files '*.c' '*.h' '*.m' '*.mm' | grep -Ev '$(NOT_OURS)')
# The guest's shell scripts are formatted as the Mac's are: those in assets/ as well, with the ones
# that have no .sh named.
NOT_OURS_SHELL := ^(third-party|patches)/
SHELL_SOURCES  := $(sort $(shell git ls-files '*.sh' | grep -Ev '$(NOT_OURS_SHELL)') \
                         $(shell git ls-files assets/scripts assets/overlay/init))
PYTHON_SOURCES := $(shell git ls-files '*.py' | grep -Ev '$(NOT_OURS)')
# Nix gets a narrower exclusion than the rest too: a Nix flake is ours wherever it happens to sit,
# and assets/kernel/flake.nix pins the kernel toolchain. The wildcard is there as well as `git ls-files`
# so that a flake is formatted before its first commit rather than after it -- $(sort) dedupes the
# two sources once it is tracked.
NOT_OURS_NIX   := ^(third-party|patches)/
NIX_SOURCES    := $(sort $(shell git ls-files '*.nix' | grep -Ev '$(NOT_OURS_NIX)') \
                         $(wildcard assets/kernel/*.nix))
RUST_SOURCES   := $(shell git ls-files '*.rs' | grep -Ev '$(NOT_OURS)')

# tctictl only ever runs inside the guest, so it is linted for the guest's target. Without this,
# cargo builds it for the macOS host, where the Linux-only sys-mount crate does not compile at all
# -- twenty errors in a dependency, before any of our code is looked at. The devshell provides
# the target; see utils/tctictl/build_and_copy.sh, which builds with the same one.
CARGO_TARGET := x86_64-unknown-linux-musl

# Two spaces. The dialect comes from each script's shebang, so a genuinely POSIX script is treated as
# one. The profile.d scripts have none, and are read as bash, which formats POSIX the same.
SHFMT_FLAGS := --indent 2 --case-indent

# Comments are the one thing swift-format will not touch: it neither breaks a line that runs past
# the limit nor joins short ones back up, so a paragraph wrapped at 60 columns and one wrapped at 99
# both pass, for ever. SwiftFormat's `wrap` rule does the first but not the second, and cannot be
# scoped to comments without also taking authority over code layout -- measured at 43 code lines
# changed against 2 comment lines on this tree. Hence reflow_comments.py, the exact complement of
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

.PHONY: format-docs
format-docs: ## Format the docs and configs (Markdown, JSON, TOML, YAML)
	$(SHELL_WRAPPER) dprint fmt

.PHONY: format
format: format-swift format-c format-rust format-shell format-python format-nix format-docs ## Format everything

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

.PHONY: format-check-docs
format-check-docs: ## Check docs and config formatting without changing files
	$(SHELL_WRAPPER) dprint check

.PHONY: format-check
format-check: format-check-swift format-check-c format-check-rust format-check-shell format-check-python format-check-nix format-check-docs ## Check all formatting without changing files

.PHONY: clippy
clippy: ## Lint the Rust sources with clippy
	$(SHELL_WRAPPER) cargo clippy --manifest-path utils/tctictl/Cargo.toml --all-targets \
		--target $(CARGO_TARGET) -- -D warnings

.PHONY: check-images
check-images: ## Check the checked-in guest images are what their inputs build, as stamped
	@status=0; \
	./assets/image_stamps.sh check $(GUEST_INITRD) $(GUEST_INITRD_INPUTS) || status=1; \
	./assets/image_stamps.sh check $(GUEST_DISK) $(GUEST_DISK_INPUTS) || status=1; \
	./assets/image_stamps.sh check $(GUEST_KERNEL) $(GUEST_KERNEL_INPUTS) || status=1; \
	exit $$status

.PHONY: lint
lint: format-check clippy ## Run all the linting tasks

# -- Cleaning -------------------------------------------------------------------------------------

.PHONY: clean-app
clean-app: ## Remove the app's build output
	xcodebuild -project tctiSH.xcodeproj -scheme tctiSH clean

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

# Both QEMU build trees live at build-iOS-arm64/qemu_{tcti,jit}, outside the submodule checkout,
# so a single `rm -rf build-iOS-arm64` reaches them and leaves the checkout alone. Removing the
# dependency tarballs with it costs a re-download, which is most of why this is not something to
# reach for casually.
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

# Results are only comparable on the disk they ran on, so this removes them along with it.
.PHONY: clean-bench
clean-bench: ## Remove the benchmark disk, results and logs in build-bench/
	rm -rf build-bench

# Both backends at once, and the GC root with them. Also what a change to build_host_qemu.sh's
# configure flags needs, since a configured build tree is kept and only rebuilt.
.PHONY: clean-host-qemu
clean-host-qemu: ## Remove the Mac builds of QEMU and their GC root (~5 minutes each to rebuild)
	rm -rf $(HOST_QEMU_BUILD)

# Keeps the builds and lets the libraries go: the next garbage collection takes them, and the next
# `make boot-guest` or `make host-qemu` fetches them again and puts the root back, without
# recompiling. The -N-link entries are the profile's generations, and each is a root.
.PHONY: unroot-host-qemu
unroot-host-qemu: ## Let nix garbage-collect the Mac QEMU builds' libraries (the next boot restores them)
	rm -f $(HOST_QEMU_ROOT) $(HOST_QEMU_ROOT)-*-link

# The two cheap ones. StikJIT and the QEMU sysroot are both minutes, but neither is something you
# want thrown away by a reflexive `make clean`; that is what distclean is for.
.PHONY: clean
clean: clean-app clean-rust ## Remove the app and tctictl build output

.PHONY: distclean
distclean: clean clean-stikjit clean-idevice clean-deps clean-host-qemu clean-kernel ## Remove everything, including the slow QEMU, StikJIT and kernel builds

# -- Utility --------------------------------------------------------------------------------------

.PHONY: shell
shell: ## Launch the user's `$SHELL` inside the devshell
	nix develop --command $(shell echo $$SHELL)

.PHONY: editor
editor: ## Launch the user's `$EDITOR` inside the devshell
	nix develop --command $(EDITOR)
