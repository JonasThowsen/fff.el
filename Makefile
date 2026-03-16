.PHONY: build test format lint

build:
	cargo build --release -p fff-emacs --features zlob

test:
	cargo test --workspace --features zlob

format:
	cargo fmt --all

lint:
	cargo clippy --workspace --features zlob -- -D warnings
