# fff.el

A tiny Emacs frontend for [fff.nvim](https://github.com/dmtrKovalenko/fff.nvim), packaged for Nix.

This repo is intentionally minimal:

- direct FFI calls to upstream `libfff_c`
- Consult-based UI
- no custom picker UI
- no helper process
- no compatibility layer for old commands

## Commands

- `M-x fff-find-file`
- `M-x fff-grep`
- `M-x fff-grep-fuzzy`

That is the whole public surface.

## Nix usage

Add the flake input:

```nix
inputs.fff-el.url = "github:JonasThowsen/fff.el";
```

### emacsWithPackages

```nix
let
  system = pkgs.stdenv.hostPlatform.system;
  myFff = inputs.fff-el.packages.${system}.fff-emacs;
in {
  programs.emacs.package = (pkgs.emacsPackagesFor pkgs.emacs-pgtk).emacsWithPackages (
    epkgs: [
      epkgs.consult
      myFff
    ]
  );
}
```

## Emacs setup

```elisp
(require 'fff)

(global-set-key (kbd "C-c f f") #'fff-find-file)
(global-set-key (kbd "C-c f g") #'fff-grep)
(global-set-key (kbd "C-c f G") #'fff-grep-fuzzy)
```

Optional configuration:

```elisp
(setq fff-max-results 150)
(setq fff-smart-case t)
(setq fff-frecency-db-path "~/.cache/fff_nvim")
(setq fff-history-db-path "~/.local/share/fff_queries")
```

## Development

```bash
nix build .#fff-emacs
nix flake check
```
