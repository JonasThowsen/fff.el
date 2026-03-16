{
  description = "fff.nvim";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    crane.url = "github:ipetkov/crane";

    flake-utils.url = "github:numtide/flake-utils";

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      crane,
      flake-utils,
      rust-overlay,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ (import rust-overlay) ];
        };

        lib = pkgs.lib;

        rustToolchain = pkgs.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml;

        craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;

        nvimCargoToml = builtins.fromTOML (builtins.readFile ./crates/fff-nvim/Cargo.toml);
        emacsCargoToml = builtins.fromTOML (builtins.readFile ./crates/fff-emacs/Cargo.toml);

        # Common arguments can be set here to avoid repeating them later
        # Note: changes here will rebuild all dependency crates
        commonArgs = {
          src = craneLib.cleanCargoSource ./.;
          strictDeps = true;

          nativeBuildInputs = [
            pkgs.pkg-config
            pkgs.perl
            pkgs.zig
            pkgs.clang
            pkgs.llvmPackages.libclang
          ];
          buildInputs = with pkgs; [
            openssl
          ];
          LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
        };

        mkRustPackage =
          cargoToml: cargoExtraArgs:
          let
            args = commonArgs // {
              pname = cargoToml.package.name;
              version = cargoToml.package.version;
              inherit cargoExtraArgs;
            };
          in
          craneLib.buildPackage (
            args
            // {
              cargoArtifacts = craneLib.buildDepsOnly args;
              doCheck = false;
            }
          );

        fffNvimRust = mkRustPackage nvimCargoToml "-p fff-nvim --features zlob";
        fffEmacsHelper = mkRustPackage emacsCargoToml "-p fff-emacs --features zlob";

        emacsPackages = pkgs.emacsPackagesFor pkgs.emacs;

        fffEmacsElisp = emacsPackages.trivialBuild {
          pname = "fff-emacs-elisp";
          version = emacsCargoToml.package.version;
          src = pkgs.runCommand "fff-emacs-elisp-src" { } ''
            mkdir -p "$out"
            cp "${./emacs/fff.el}" "$out/fff.el"
          '';
        };

        fffEmacs = pkgs.symlinkJoin {
          name = "fff-emacs";
          paths = [
            fffEmacsHelper
            fffEmacsElisp
          ];
          meta = {
            description = "Emacs frontend and helper for fff";
            mainProgram = "fff-emacs";
          };
        };

        # Copies the dynamic library into the target/release folder
        copy-dynamic-library = /* bash */ ''
          set -eo pipefail
          mkdir -p target/release
          if [ "$(uname)" = "Darwin" ]; then
            cp -vf ${fffNvimRust}/lib/libfff_nvim.dylib target/release/libfff_nvim.dylib
          else
            cp -vf ${fffNvimRust}/lib/libfff_nvim.so target/release/libfff_nvim.so
          fi
          echo "Library copied to target/release/"
        '';
      in
      {
        checks = {
          inherit fffNvimRust fffEmacsHelper;
        };

        packages = {
          default = fffEmacs;
          fff-emacs = fffEmacs;
          fff-emacs-helper = fffEmacsHelper;
          fff-emacs-elisp = fffEmacsElisp;
          fff-nvim-rust = fffNvimRust;

          # Neovim plugin
          fff-nvim = pkgs.vimUtils.buildVimPlugin {
            pname = "fff.nvim";
            version = "main";
            src = pkgs.lib.cleanSource ./.;
            postPatch = copy-dynamic-library;
            doCheck = false; # Skip require check since we have a Rust FFI component
          };
        };

        apps.default = flake-utils.lib.mkApp { drv = fffEmacsHelper; };
        apps.fff-emacs = flake-utils.lib.mkApp { drv = fffEmacsHelper; };

        # Add the release command
        apps.release = flake-utils.lib.mkApp {
          drv = pkgs.writeShellScriptBin "release" copy-dynamic-library;
        };

        devShells.default = craneLib.devShell {
          # Inherit inputs from checks.
          checks = self.checks.${system};
          # Extra inputs can be added here; cargo and rustc are provided by default.
          packages = [
            # pkgs.ripgrep
          ];
        };
      }
    );
}
