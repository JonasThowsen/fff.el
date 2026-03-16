.PHONY: build check develop

build:
	nix build .#fff-emacs

check:
	nix flake check

develop:
	nix develop
