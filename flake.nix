{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";

    # Pinned separately as the main nixpkgs is deliberately held back for the
    # QEMU dependency build (glib 2.69 and its patch set), and predates
    # xcodegen, so host-side tooling that needs something newer comes from here
    # instead.
    #
    # TODO: fold this back into the main input once the pin can move with the
    # QEMU update.
    nixpkgs-tools.url = "github:NixOS/nixpkgs";

    # Rust, with the cross targets the repo needs; see rustToolchain below.
    # Following nixpkgs-tools rather than nixpkgs, because the held-back pin is
    # from 2023 and nothing modern evaluates against it.
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs-tools";
    };
  };
  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-tools,
      rust-overlay,
    }:
    let
      # We can only build on Apple Silicon at the moment
      system = "aarch64-darwin";
      pkgs = import nixpkgs { inherit system; };
      toolsPkgs = import nixpkgs-tools {
        inherit system;
        overlays = [ rust-overlay.overlays.default ];
      };

      # We require the following python packages
      #
      # tomli is QEMU's; its configure reads pyproject.toml through it on any
      # Python older than 3.11, where tomllib became part of the standard
      # library. It can go when the held-back pin below moves past 3.10.
      pythonPackages =
        pkgs: with pkgs; [
          pyparsing
          six
          tomli
        ];

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
      rustToolchain = toolsPkgs.rust-bin.stable.latest.minimal.override {
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

      # Two host tools that build_dependencies.sh checks for by name, and which
      # were previously coming from wherever the developer happened to have
      # them -- Homebrew, on the machine this was written on.
      #
      # Only the binaries are exposed. Pulling glib and gettext into the shell
      # whole would also put their headers and .pc files in front of a build
      # whose entire job is to cross-compile its own copies of both, and the
      # failure from getting that wrong would arrive an hour in.
      hostBuildTools = pkgs.runCommand "tctish-host-build-tools" { } ''
        mkdir -p $out/bin
        ln -s ${pkgs.gettext}/bin/msgfmt $out/bin/msgfmt
        ln -s ${pkgs.glib.dev}/bin/glib-mkenums $out/bin/glib-mkenums
      '';

      # And the following system-level packages in addition to having `xcrun`
      # accessible
      buildDependencies =
        with pkgs;
        [
          bison
          libgpg-error
          (python3.withPackages pythonPackages)
          meson
          ninja
        ]
        ++ [
          hostBuildTools

          # Generates StikJIT's Xcode project; see build_stikjit.sh.
          toolsPkgs.xcodegen

          # Both targets are synchronized root groups. The pinned nixpkgs ships
          # CocoaPods 1.13.0 on Xcodeproj 1.23.0, which has no such ISA and aborts
          # `pod install` with "attempted to initialize an object with unknown ISA
          # `PBXFileSystemSynchronizedRootGroup`". It fails loudly rather than
          # corrupting anything, but it does fail. This one is CocoaPods 1.16.2 on
          # Xcodeproj 1.27.0, verified to round-trip both targets intact.
          toolsPkgs.cocoapods

          rustBinaries
          nightlyRustfmt
        ];

      # The formatter, and only the formatter, from nightly.
      #
      # rustfmt.toml asks for brace_style, comment normalisation, macro body
      # formatting and friends, every one of which is nightly-gated. A stable
      # rustfmt does not error on them -- it warns and carries on formatting to
      # its own defaults, so the config would look applied and not be.
      nightlyRustfmt = toolsPkgs.rust-bin.nightly.latest.rustfmt;

      # Everything `make format` drives, minus swift-format and clang-format,
      # which come from the active Xcode toolchain via `xcrun` so that they match
      # what the IDE applies on save. See tmp/plans/autoformatting.md.
      formatters = with toolsPkgs; [
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
      };
    };
}
