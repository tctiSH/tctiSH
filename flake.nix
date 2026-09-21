{
  inputs = {
    # One nixpkgs.
    #
    # This used to be two, three years apart: the build pinned itself to a 2023
    # revision for glib 2.69, which needed a meson old enough to accept a 2021
    # meson.build, and a second `nixpkgs-tools` input supplied everything the
    # pin was too old for. Following UTM to glib 2.83 is what retired the pin --
    # it wants meson >= 1.4.0, so the old revision could not have built it
    # anyway, and the two constraints pointed the same way for the first time.
    #
    # `nixpkgs-unstable` rather than the bare `github:NixOS/nixpkgs`, which
    # resolves to master. The branch only advances once Hydra has built it, so
    # an update lands on revisions the binary cache already has; master can put
    # the whole toolchain -- clang, python, rust -- in front of you as a source
    # build.
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # Rust, with the cross targets the repo needs; see rustToolchain below.
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs =
    {
      self,
      nixpkgs,
      rust-overlay,
    }:
    let
      # We can only build on Apple Silicon at the moment
      system = "aarch64-darwin";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ rust-overlay.overlays.default ];
      };

      # Stable Rust: everything except the formatter.
      #
      # Built from `minimal` rather than `default` so the component list is
      # explicit, and so the stable rustfmt is absent -- see nightlyRustfmt
      # below, which would otherwise collide with it over bin/rustfmt.
      #
      # `rustc` brings its own rust-lld along, which is what links the musl
      # target; llvm-tools is here for the rest of the LLVM binutils.
      #
      # Two targets, for the two things besides tctictl itself that want Rust:
      #
      #   - utils/tctictl/build_and_copy.sh                 (musl)
      #   - the pairing flow's `idevice` FFI, when it lands (iOS)
      #
      # Without these, build_and_copy.sh depends on a separately-provisioned
      # global cargo with `rustup target add` already run, which is exactly the
      # kind of unwritten setup step the flake exists to remove. See also the
      # musl linker below, without which the target is present but unusable.
      rustToolchain = pkgs.rust-bin.stable.latest.minimal.override {
        extensions = [
          "clippy"
          "llvm-tools"
          "rust-analyzer"
          "rust-src"
        ];
        targets = [
          "x86_64-unknown-linux-musl"
          "aarch64-apple-ios"
        ];
      };

      # The toolchain above propagates nixpkgs' clang wrapper, so that cargo has a linker driver.
      # In a devShell that wrapper lands at the *front* of $PATH, ahead of Xcode's clang -- which
      # is the exact situation mkShellNoCC exists to prevent, arriving by a different route. It
      # broke the QEMU build: meson resolved the bare `objc = ['clang']` in QEMU's cross file to
      # the nix wrapper, which links against nix's macOS SDK and so fails the ObjC probe for an
      # iOS target.
      #
      # Exposing just the binaries keeps `cc` coming from Xcode. Nothing here needs the propagated
      # one: tctictl is built for musl and linked with rustc's own lld, set below.
      rustBinaries = pkgs.runCommand "tctish-rust-binaries" { } ''
        mkdir -p $out/bin
        for tool in ${rustToolchain}/bin/*; do
          ln -s "$tool" "$out/bin/$(basename "$tool")"
        done
      '';

      # Host tools the dependency build may reach for, pinned so that it cannot
      # matter what the developer happens to have installed.
      #
      # msgfmt is the one that does real work: glib compiles its translation
      # catalogues with it.
      #
      # The glib code generators are here for a different reason -- none of them
      # is invoked by the current build, and glib 2.83 overrides find_program for
      # its own mkenums anyway. They are here to *shadow* Homebrew's, which is a
      # complete glib toolset sitting on $PATH ahead of nothing in particular.
      # That has bitten this repo before: a Homebrew gdbus-codegen generated
      # sources against its own glib and emitted a symbol our build did not have.
      # `--disable-dbus-display` is the fix for that specific case; this is what
      # stops the next one being decided by `brew upgrade`.
      #
      # Note this buys determinism, not version agreement: nixpkgs' glib is
      # newer than the one we cross-compile, so anything that actually generated
      # code here would still be generating it with the wrong glib. The answer
      # then is to stop generating, as dbus-display did.
      #
      # Only binaries are exposed, and that is deliberate. Pulling glib and
      # gettext into the shell whole would put their headers and .pc files in
      # front of a build whose entire job is to cross-compile its own copies, and
      # the failure from getting that wrong would arrive deep into a dependency
      # build.
      hostBuildTools = pkgs.runCommand "tctish-host-build-tools" { } ''
        mkdir -p $out/bin
        ln -s ${pkgs.gettext}/bin/msgfmt $out/bin/msgfmt
        for tool in gdbus-codegen gio-querymodules glib-compile-resources                     glib-compile-schemas glib-genmarshal glib-mkenums; do
          ln -s ${pkgs.glib.dev}/bin/"$tool" $out/bin/"$tool"
        done
      '';

      # And the following system-level packages in addition to having `xcrun`
      # accessible
      buildDependencies =
        with pkgs;
        [
          # gettext's configure probes for bison; the others are meson's and
          # QEMU's. QEMU builds its own meson into a pyvenv, so the one here is
          # for the glib build.
          bison
          python3
          meson
          ninja

          # meson resolves [wrap-git] subprojects by shelling out to git --
          # QEMU's libucontext and slirp, at configure time. Before this was
          # listed, it came from the nix-darwin system profile, which the
          # shellHook below now removes from $PATH.
          git
        ]
        ++ [
          hostBuildTools

          # Generates StikJIT's Xcode project; see build_stikjit.sh.
          pkgs.xcodegen

          # Both targets are synchronized root groups, so CocoaPods has to be
          # new enough to know the PBXFileSystemSynchronizedRootGroup ISA.
          # CocoaPods 1.13.0 on Xcodeproj 1.23.0 -- what the old 2023 pin shipped
          # -- has no such ISA and aborts `pod install` with "attempted to
          # initialize an object with unknown ISA
          # `PBXFileSystemSynchronizedRootGroup`". It fails loudly rather than
          # corrupting anything, but it does fail. 1.16.2 on Xcodeproj 1.27.0 was
          # verified to round-trip both targets intact.
          pkgs.cocoapods

          rustBinaries
          nightlyRustfmt
        ];

      # The formatter, and only the formatter, from nightly.
      #
      # rustfmt.toml asks for brace_style, comment normalisation, macro body
      # formatting and friends, every one of which is nightly-gated. A stable
      # rustfmt does not error on them -- it warns and carries on formatting to
      # its own defaults, so the config would look applied and not be.
      nightlyRustfmt = pkgs.rust-bin.nightly.latest.rustfmt;

      # Everything `make format` drives, minus swift-format and clang-format,
      # which come from the active Xcode toolchain via `xcrun` so that they match
      # what the IDE applies on save. See tmp/plans/autoformatting.md.
      formatters = with pkgs; [
        dprint # Markdown, JSON, TOML, YAML
        nixfmt # Nix (RFC 166 style)
        ruff # Python
        rufo # Ruby -- one file, the Podfile
        shfmt
      ];
    in
    {
      # mkShellNoCC because mkShell pulls in stdenv's cc-wrapper, which puts an
      # old nix clang ahead of Xcode's on $PATH. QEMU's configure emits a bare
      # `objc = ['clang']` into its meson cross file, so that wrapper gets picked
      # up and injects -mmacos-version-min, conflicts with -miphoneos-version-min
      # and breaks the ObjC probe. This build must use only the Xcode toolchain.
      devShells.${system}.default = pkgs.mkShellNoCC {
        packages = buildDependencies ++ formatters;

        # Apple's `ld` does not understand GNU linker options, so linking the
        # musl target with it fails on `--as-needed`. rustc ships an lld that
        # does; it just isn't on $PATH. Pointing cargo straight at it is what
        # makes utils/tctictl/build_and_copy.sh work from a Mac at all.
        #
        # The directory is rustc's own triple, `aarch64-apple-darwin`, which is
        # spelled differently to nix's `aarch64-darwin`.
        CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER = "${rustToolchain}/lib/rustlib/aarch64-apple-darwin/bin/rust-lld";

        # Everything the build resolves by bare name comes from this flake or
        # from Apple. The inherited $PATH is filtered rather than replaced, so
        # Xcode and the base system keep working -- xcrun, otool,
        # install_name_tool, xcodebuild, codesign, plutil, sysctl -- while
        # Homebrew, /usr/local, the nix-darwin system profile and per-user bin
        # directories cannot decide what a build picks up.
        #
        # This is not hypothetical. Homebrew ships a complete glib toolset, and a
        # Homebrew gdbus-codegen once generated QEMU sources against its own glib
        # and emitted a symbol our build did not have. pkg-config was the same
        # story quieter: build_dependencies.sh builds its own into
        # $PREFIX/host/bin exactly to keep host .pc files out, and Homebrew's sat
        # in front of it on $PATH regardless.
        #
        # Two consequences worth knowing. `git` and `curl` now resolve to
        # different binaries than before -- nixpkgs' git, Apple's curl -- so a
        # per-process firewall like Little Snitch will ask about them afresh.
        # And `nix` itself is dropped, which is fine because the Makefile only
        # reaches for it when IN_NIX_SHELL is unset.
        shellHook = ''
          _tctish_path=""
          _tctish_oldifs="$IFS"
          IFS=":"
          for _tctish_dir in $PATH; do
            case "$_tctish_dir" in
              /nix/store/* | /usr/bin | /bin | /usr/sbin | /sbin                 | /Library/Apple/usr/bin | /System/Cryptexes/*                 | /var/run/com.apple.security.cryptexd/*)
                _tctish_path="$_tctish_path:$_tctish_dir"
                ;;
            esac
          done
          IFS="$_tctish_oldifs"
          export PATH="''${_tctish_path#:}"
          unset _tctish_path _tctish_oldifs _tctish_dir
        '';
      };
    };
}
