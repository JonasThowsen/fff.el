# fff.el

`fff.el` is an Emacs frontend for the `fff` Rust search engine.

It provides:

- fast file picking backed by the Rust index/search core
- live grep with switchable `plain`, `fuzzy`, and `regex` modes
- a bottom picker with a large live preview
- frecency and query tracking through a helper process

## Quick start

If you just want to try it, install the combined package and load `fff` in Emacs.

### Nix / flakes

Add the flake input:

```nix
inputs.fff-el.url = "github:JonasThowsen/fff.el";
```

Then install the combined package.

NixOS:

```nix
environment.systemPackages = [
  inputs.fff-el.packages.${pkgs.stdenv.hostPlatform.system}.fff-emacs
];
```

Home Manager:

```nix
home.packages = [
  inputs.fff-el.packages.${pkgs.stdenv.hostPlatform.system}.fff-emacs
];
```

### Cargo + local elisp

```bash
cargo install --git https://github.com/JonasThowsen/fff.el --features zlob fff-emacs
```

Then add the Lisp file from this repo to your `load-path`:

```elisp
(add-to-list 'load-path "/path/to/fff.el/emacs")
(require 'fff)
```

## Package layout

The flake exposes three packages:

- `fff-emacs-helper` - the Rust backend process that does indexing, file search, grep, and query tracking
- `fff-emacs-elisp` - the Emacs Lisp frontend that provides `fff-find-files`, `fff-live-grep`, and the picker UI
- `fff-emacs` - a convenience package that contains both of the above

In practice:

- the helper must be on your `PATH` or set explicitly with `fff-helper-command`
- the Lisp package must be available in Emacs' `load-path`

## Recommended Nix setup for custom Emacs

If you build Emacs with `emacsWithPackages`, the cleanest setup is to install the helper separately and add the Lisp package to your Emacs package set.

```nix
let
  system = pkgs.stdenv.hostPlatform.system;
in {
  environment.systemPackages = [
    inputs.fff-el.packages.${system}.fff-emacs-helper
  ];

  myEmacs = (pkgs.emacsPackagesFor pkgs.emacs-pgtk).emacsWithPackages (
    epkgs: [
      inputs.fff-el.packages.${system}.fff-emacs-elisp
    ]
  );
}
```

This is usually the best setup for a personal Nix Emacs config because:

- the helper binary is installed system-wide
- the Lisp package is part of your Emacs build
- `(require 'fff)` works without manual `load-path` hacks

## Emacs setup

If you installed `fff-emacs-elisp` through `emacsWithPackages`, `(require 'fff)` should just work.

If you installed `fff-emacs` as a generic system package, you may still need to make sure Emacs sees the Lisp path.

Example setup:

```elisp
(require 'fff)

;; Optional if `fff-emacs` is not on your exec-path.
(setq fff-helper-command '("/path/to/fff-emacs"))

;; The first mode is the default for `fff-live-grep`.
(setq fff-grep-mode-cycle '(fuzzy plain regex))

(global-set-key (kbd "C-c f f") #'fff-find-files)
(global-set-key (kbd "C-c f g") #'fff-live-grep)
(global-set-key (kbd "C-c f s") #'fff-status)
(global-set-key (kbd "C-c f R") #'fff-rescan)
```

## Usage

Main commands:

- `M-x fff-find-files`
- `M-x fff-live-grep`
- `M-x fff-status`
- `M-x fff-rescan`
- `M-x fff-refresh-git-status`

Picker keys:

- type to refine the query
- `C-n` / `C-p` or arrows to move
- `RET` to open
- `C-s` / `C-v` to open in splits
- `C-u` / `C-d` to page the preview
- `DEL` to delete a character
- `C-w` to delete the last word
- `C-k` to clear the query
- `S-TAB` to cycle grep modes
- `C-g` to quit

## Development

Build the helper:

```bash
cargo build --release -p fff-emacs --features zlob
```

Useful commands:

```bash
make build
make test
make format
make lint
```
