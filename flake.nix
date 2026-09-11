{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
  };
  outputs = {
    self,
    nixpkgs
  }: let
    # We can only build on Apple Silicon at the moment
    system = "aarch64-darwin";
    pkgs = import nixpkgs { inherit system; };

    # We require the following python packages
    pythonPackages = pkgs: with pkgs; [
      pyparsing
      six
    ];

    # And the following system-level packages in addition to having `xcrun`
    # accessible
    buildDependencies = with pkgs; [
      bison
      cocoapods
      libgpg-error
      (python3.withPackages pythonPackages)
      meson
      ninja
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
