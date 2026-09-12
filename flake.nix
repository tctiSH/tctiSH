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
  };
  outputs = {
    self,
    nixpkgs,
    nixpkgs-tools
  }: let
    # We can only build on Apple Silicon at the moment
    system = "aarch64-darwin";
    pkgs = import nixpkgs { inherit system; };
    toolsPkgs = import nixpkgs-tools { inherit system; };

    # We require the following python packages
    pythonPackages = pkgs: with pkgs; [
      pyparsing
      six
    ];

    # And the following system-level packages in addition to having `xcrun`
    # accessible
    buildDependencies = with pkgs; [
      bison
      libgpg-error
      (python3.withPackages pythonPackages)
      meson
      ninja
    ] ++ [
      # Generates StikJIT's Xcode project; see build_stikjit.sh.
      toolsPkgs.xcodegen

      # Both targets are synchronized root groups. The pinned nixpkgs ships
      # CocoaPods 1.13.0 on Xcodeproj 1.23.0, which has no such ISA and aborts
      # `pod install` with "attempted to initialize an object with unknown ISA
      # `PBXFileSystemSynchronizedRootGroup`". It fails loudly rather than
      # corrupting anything, but it does fail. This one is CocoaPods 1.16.2 on
      # Xcodeproj 1.27.0, verified to round-trip both targets intact.
      toolsPkgs.cocoapods
    ];
  in {
    # mkShellNoCC because mkShell pulls in stdenv's cc-wrapper, which puts an
    # old nix clang ahead of Xcode's on $PATH. QEMU's configure emits a bare
    # `objc = ['clang']` into its meson cross file, so that wrapper gets picked
    # up and injects -mmacos-version-min, conflicts with -miphoneos-version-min 
    # and breaks the ObjC probe. This build must use only the Xcode toolchain.
    devShells.${system}.default = pkgs.mkShellNoCC {
      packages = buildDependencies;
    };
  };
}
