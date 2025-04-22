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
    devShells.${system}.default = pkgs.mkShell {
      packages = buildDependencies;
    };
  };
}
