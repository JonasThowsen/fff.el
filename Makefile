.PHONY: build check test develop

build:
	nix build .#fff-emacs

check:
	nix flake check

test:
	emacs -Q --batch -L test -L emacs -l test/fff-test.el -f ert-run-tests-batch-and-exit

develop:
	nix develop
