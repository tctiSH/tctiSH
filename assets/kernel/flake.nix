{
  description = "Pinned toolchain for building the tctiSH guest kernel.";

  # The whole point of this file. nixpkgs is pinned exactly by flake.lock, so the
  # compiler, linker, assembler and pahole are the same bytes on every machine
  # and at every point in the future -- which is what the container image alone
  # could not give us, since `alpine:latest` and the clang inside it both move.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

  outputs =
    { nixpkgs, ... }:
    let
      forEach =
        f:
        nixpkgs.lib.genAttrs [ "aarch64-linux" "x86_64-linux" ] (
          system: f nixpkgs.legacyPackages.${system}
        );
    in
    {
      devShells = forEach (pkgs: {
        default = pkgs.mkShellNoCC {
          # The compiler used for *target* code, as opposed to the wrapped clang
          # on PATH which builds the host tools.
          #
          # nixpkgs' cc-wrapper injects include paths and hardening flags for a
          # single target triple, and says so itself when asked to cross-compile:
          # "supplying the --target x86_64-linux-gnu != aarch64-unknown-linux-gnu
          # argument to a nix-wrapped compiler may not work correctly ... you may
          # want to use an un-wrapped compiler instead". It fails concretely, at
          # scripts/mod/empty.o, on `-nostdlibinc` being unused.
          #
          # Unwrapped is correct here rather than merely quieter: the kernel
          # compiles with -nostdinc and supplies every header itself, so there is
          # nothing for a wrapper to contribute. The host tools are a different
          # matter -- objtool and resolve_btfids are ordinary native programs that
          # want a libc -- which is why only CC is overridden and HOSTCC is left
          # pointing at the wrapped compiler.
          TCTISH_TARGET_CC = "${pkgs.llvmPackages.clang-unwrapped}/bin/clang";

          packages = with pkgs; [
            # The cross toolchain. clang needs no separate cross-targeted
            # package -- one compiler targets everything -- which is most of why
            # the build uses LLVM=1 rather than a GNU cross toolchain.
            clang
            lld
            llvm

            # DWARF to BTF. CONFIG_DEBUG_INFO_BTF fails the build without it.
            pahole

            # kbuild's hard dependencies.
            bison
            flex
            bc
            perl
            python3
            gnumake

            # libelf for objtool and resolve_btfids; zlib and openssl for the
            # host-side tools kbuild builds along the way.
            elfutils
            zlib
            openssl

            # resolve_btfids vendors libbpf and compiles it against system
            # headers, so it wants these even though the kernel brings its own.
            linuxHeaders
            glibc.dev

            # Used by the script itself rather than by kbuild.
            bash
            coreutils
            findutils
            diffutils
            gnused
            gnugrep
            curl
            xz
            cpio
          ];
        };
      });
    };
}
