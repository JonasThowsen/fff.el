{
  description = "fff.el - simple Emacs frontend for fff.nvim with Nix packaging";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    fff-nvim = {
      url = "github:dmtrKovalenko/fff.nvim";
      flake = false;
    };
    emacs-ffi-src = {
      url = "github:tromey/emacs-ffi";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      fff-nvim,
      emacs-ffi-src,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        lib = pkgs.lib;
        emacsPackages = pkgs.emacsPackagesFor pkgs.emacs;
        version = "0.2.0";
        libExt = if pkgs.stdenv.hostPlatform.isDarwin then "dylib" else "so";

        fffNativeLib = pkgs.rustPlatform.buildRustPackage {
          pname = "libfff-c";
          inherit version;
          src = fff-nvim;
          cargoLock = {
            lockFile = "${fff-nvim}/Cargo.lock";
            allowBuiltinFetchGit = true;
          };
          cargoBuildFlags = [ "-p" "fff-c" ];
          doCheck = false;

          installPhase = ''
            runHook preInstall
            mkdir -p $out
            cp "$(find target -type f -name 'libfff_c.${libExt}' | head -n 1)" "$out/libfff_c.${libExt}"
            runHook postInstall
          '';
        };

        emacsFfiModule = pkgs.stdenv.mkDerivation {
          pname = "emacs-ffi-module";
          inherit version;
          src = emacs-ffi-src;
          nativeBuildInputs = [ pkgs.pkg-config ];
          buildInputs = [ pkgs.emacs pkgs.libffi pkgs.libtool pkgs.libtool.lib ];
          dontConfigure = true;

          buildPhase = ''
            runHook preBuild
            $CC -shared -fPIC \
              -I${pkgs.emacs}/include \
              -I${pkgs.libtool}/include \
              -I${pkgs.libffi.dev}/include \
              -L${pkgs.libtool.lib}/lib \
              -L${pkgs.libffi.out}/lib \
              -o ffi-module.${libExt} \
              ffi-module.c \
              -lltdl -lffi
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p $out
            cp ffi-module.${libExt} $out/ffi-module.${libExt}
            runHook postInstall
          '';
        };

        fffEmacsSrc = pkgs.runCommand "fff-emacs-src" { } ''
          mkdir -p $out
          cp ${./emacs/fff.el} $out/fff.el
          cp ${./emacs/ffi.el} $out/ffi.el
          cp ${emacsFfiModule}/ffi-module.${libExt} $out/ffi-module.${libExt}
          cp ${fffNativeLib}/libfff_c.${libExt} $out/libfff_c.${libExt}
        '';

        fffEmacs = pkgs.stdenvNoCC.mkDerivation {
          pname = "fff-emacs";
          inherit version;
          src = fffEmacsSrc;
          dontBuild = true;
          propagatedUserEnvPkgs = [ emacsPackages.consult ];

          installPhase = ''
            runHook preInstall
            LISPDIR=$out/share/emacs/site-lisp
            install -d $LISPDIR
            install *.el ffi-module.${libExt} libfff_c.${libExt} $LISPDIR
            runHook postInstall
          '';

          meta = {
            description = "Emacs frontend for fff.nvim with bundled ffi runtime";
            license = with lib.licenses; [ mit gpl3Plus ];
            platforms = lib.platforms.unix;
          };
        };
      in
      {
        packages = {
          default = fffEmacs;
          fff-emacs = fffEmacs;
          libfff-c = fffNativeLib;
          emacs-ffi-module = emacsFfiModule;
        };

        checks.default = fffEmacs;

        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.pkg-config
            pkgs.emacs
            pkgs.libffi
            pkgs.libtool
          ];
        };
      }
    );
}
