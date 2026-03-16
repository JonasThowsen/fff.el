{
  description = "fff.el";

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

        rustToolchain = pkgs.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml;
        craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;
        emacsCargoToml = builtins.fromTOML (builtins.readFile ./crates/fff-emacs/Cargo.toml);

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
          buildInputs = [ pkgs.openssl ];
          LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
        };

        cargoArgs = commonArgs // {
          pname = emacsCargoToml.package.name;
          version = emacsCargoToml.package.version;
          cargoExtraArgs = "-p fff-emacs --features zlob";
        };

        fffEmacsHelper = craneLib.buildPackage (
          cargoArgs
          // {
            cargoArtifacts = craneLib.buildDepsOnly cargoArgs;
            doCheck = false;
          }
        );

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
      in
      {
        checks = {
          inherit fffEmacsHelper;
        };

        packages = {
          default = fffEmacs;
          fff-emacs = fffEmacs;
          fff-emacs-helper = fffEmacsHelper;
          fff-emacs-elisp = fffEmacsElisp;
        };

        apps.default = flake-utils.lib.mkApp { drv = fffEmacsHelper; };
        apps.fff-emacs = flake-utils.lib.mkApp { drv = fffEmacsHelper; };

        devShells.default = craneLib.devShell {
          checks = self.checks.${system};
        };
      }
    );
}
