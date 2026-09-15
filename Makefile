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
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

# -- Artifacts ------------------------------------------------------------------------------------

# What each build step actually produces. `build` depends on these files rather than on the phony
# targets below, because a phony prerequisite would rebuild QEMU on every single `make build`.
QEMU_SYSROOT      := sysroot-iOS-arm64
QEMU_FRAMEWORK    := $(QEMU_SYSROOT)/Frameworks/qemu-x86_64-softmmu_jit.framework
QEMU_LIBRARY      := $(QEMU_FRAMEWORK)/qemu-x86_64-softmmu_jit
STIKJIT_BUILD     := build-StikJIT
STIKJIT_FRAMEWORK := $(STIKJIT_BUILD)/StikJIT.xcframework/Info.plist
PODS_MANIFEST     := Pods/Manifest.lock

# -- Building -------------------------------------------------------------------------------------

# Neither of these tracks its submodule: there is no file that reliably changes when a gitlink
# moves, and guessing wrong costs an hour of QEMU. After bumping qemu-tcti or StikJIT, force the
# rebuild with `make clean-deps deps` or `make clean-stikjit stikjit`.
$(QEMU_LIBRARY): build_dependencies.sh
	$(SHELL_WRAPPER) ./build_dependencies.sh

$(STIKJIT_FRAMEWORK): build_stikjit.sh $(wildcard patches/*.patch)
	$(SHELL_WRAPPER) ./build_stikjit.sh

$(PODS_MANIFEST): Podfile
	$(SHELL_WRAPPER) pod install

.PHONY: deps
deps: $(QEMU_LIBRARY) ## Build QEMU and its libraries into sysroot-iOS-arm64/ (slow)

.PHONY: stikjit
stikjit: $(STIKJIT_FRAMEWORK) ## Build build-StikJIT/StikJIT.xcframework from the patched submodule copy

.PHONY: pods
pods: $(PODS_MANIFEST) ## Install the CocoaPods dependencies

# Always the workspace, never the bare project: tctiSH.xcodeproj on its own cannot build the Pods
# targets, and fails with "Unable to resolve module dependency: 'Socket'" -- which looks like a
# project-format problem and isn't.
.PHONY: build
build: $(QEMU_LIBRARY) $(STIKJIT_FRAMEWORK) $(PODS_MANIFEST) ## Build the app for a generic iOS device
	xcodebuild -workspace tctiSH.xcworkspace -scheme tctiSH -destination 'generic/platform=iOS' build

.PHONY: tctictl
tctictl: ## Build the guest-side tctictl and repack it into initrd.img
	$(SHELL_WRAPPER) ./utils/tctictl/build_and_copy.sh

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
#   qemu-tcti, third-party  submodules; we rebase onto upstream and do not want the conflicts
#   Pods                    vendored by CocoaPods, rewritten by `pod install`
#   assets                  guest-side build scripts, their own world
#   patches                 context lines are literal, so reformatting silently breaks them
#
# Everything is found through `git ls-files`, which also keeps build output out by construction.
NOT_OURS := ^(qemu-tcti|third-party|Pods|assets|patches)/

SWIFT_SOURCES  := $(shell git ls-files '*.swift' | grep -Ev '$(NOT_OURS)')
C_SOURCES      := $(shell git ls-files '*.c' '*.h' '*.m' '*.mm' | grep -Ev '$(NOT_OURS)')
SHELL_SOURCES  := $(shell git ls-files '*.sh' | grep -Ev '$(NOT_OURS)')
PYTHON_SOURCES := $(shell git ls-files '*.py' | grep -Ev '$(NOT_OURS)')
NIX_SOURCES    := $(shell git ls-files '*.nix' | grep -Ev '$(NOT_OURS)')
RUBY_SOURCES   := $(shell git ls-files 'Podfile' '*.rb' | grep -Ev '$(NOT_OURS)')

# Four spaces, matching Xcode's editor and the existing scripts. The dialect comes
# from each script's shebang, so a genuinely POSIX script would still be treated
# as one.
SHFMT_FLAGS := --indent 4 --case-indent

.PHONY: format-swift
format-swift: ## Format the Swift sources
	$(call require_xcode_tool,$(SWIFT_FORMAT),swift-format)
	@$(SWIFT_FORMAT) format --parallel --in-place $(SWIFT_SOURCES)

.PHONY: format-c
format-c: ## Format the C and Objective-C sources
	$(call require_xcode_tool,$(CLANG_FORMAT),clang-format)
	@$(CLANG_FORMAT) -i $(C_SOURCES)

.PHONY: format-rust
format-rust: ## Format the Rust sources
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
	@failed=0; for f in $(SWIFT_SOURCES); do \
		$(SWIFT_FORMAT) format "$$f" | diff -u --label "$$f" --label "$$f (formatted)" "$$f" - || failed=1; \
	done; exit $$failed

.PHONY: format-check-c
format-check-c: ## Check C and Objective-C formatting without changing files
	$(call require_xcode_tool,$(CLANG_FORMAT),clang-format)
	@$(CLANG_FORMAT) --dry-run --Werror $(C_SOURCES)

.PHONY: format-check-rust
format-check-rust: ## Check Rust formatting without changing files
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
	$(SHELL_WRAPPER) cargo clippy --manifest-path utils/tctictl/Cargo.toml --all-targets

.PHONY: lint
lint: format-check clippy ## Run all the linting tasks

# -- Cleaning -------------------------------------------------------------------------------------

# There is deliberately no clean-pods: Pods/ is checked in, so removing it would show up as 67
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

# build_dependencies.sh configures QEMU inside the submodule itself, so those two trees outlive a
# `rm -rf build-iOS-arm64`. Leaving them means the next build reuses stale objects and a stale
# config-host.mak, which is the one thing a clean exists to rule out.
.PHONY: clean-deps
clean-deps: ## Remove the QEMU sysroot and its build tree (an hour to rebuild)
	rm -rf $(QEMU_SYSROOT) build-iOS-arm64 qemu-tcti/qemu_tcti qemu-tcti/qemu_jit

# The two cheap ones. StikJIT and the QEMU sysroot are minutes and an hour respectively, and neither
# is something you want thrown away by a reflexive `make clean`; that is what distclean is for.
.PHONY: clean
clean: clean-app clean-rust ## Remove the app and tctictl build output

.PHONY: distclean
distclean: clean clean-stikjit clean-deps ## Remove everything, including the slow QEMU and StikJIT builds

# -- Utility --------------------------------------------------------------------------------------

.PHONY: shell
shell: ## Launch the user's `$SHELL` inside the devshell
	nix develop --command $(shell echo $$SHELL)

.PHONY: editor
editor: ## Launch the user's `$EDITOR` inside the devshell
	nix develop --command $(EDITOR)
