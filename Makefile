.PHONY: build install fmt lint test test-rust test-daemon test-vim clean vim-core defcompile check-classes preview

build:
	cargo build --release --locked

install:
	./install.sh

fmt:
	cargo fmt --check

lint:
	cargo clippy --all-targets -- -D warnings

test: fmt lint test-rust test-daemon check-classes defcompile vim-core test-vim

test-rust:
	cargo test --all-targets

test-daemon: build
	./target/release/simplemarkdown-daemon --self-test
	./target/release/simplemarkdown-daemon --help >/dev/null
	./target/release/simplemarkdown-daemon --version >/dev/null
	./target/release/simplemarkdown-daemon --classes >/dev/null
	printf '%s\n' '{"type":"ping","id":1}' \
		| ./target/release/simplemarkdown-daemon \
		| grep -qF '"type":"pong"'

# The Vim side registers one text-property type per class the daemon may emit.
# A class present in Rust but missing in Vim is a hard prop_add() error inside
# a channel callback — the worst place to find out — so the two lists are
# compared here rather than discovered at render time.
check-classes: build
	@./target/release/simplemarkdown-daemon --classes > /tmp/simplemarkdown-rust-classes
	@vim -Nu NONE -n -i NONE -es -S tests/classes.vim > /tmp/simplemarkdown-vim-classes
	@diff -u /tmp/simplemarkdown-rust-classes /tmp/simplemarkdown-vim-classes \
		&& echo "classes: Rust and Vim agree"

test-vim:
	vim -Nu NONE -n -i NONE -es -S tests/vim_smoke.vim

# Render the fixture to the terminal.  Handy when changing the layout code:
# the diff of two runs is the whole review.
preview: build
	@./target/release/simplemarkdown-daemon --preview tests/fixtures/kitchen-sink.md $${WIDTH:-80}

clean:
	rm -rf target lib/simplemarkdown-daemon lib/simplemarkdown-daemon.exe tests/*-errors.log

# ---------------------------------------------------------------------------
# simplecore: the vendored daemon supervisor shared by the simple* suite.
# Regenerate with ../.simplecore/vendor.sh; never edit autoload/simplemarkdown/core.vim.
# ---------------------------------------------------------------------------

# Supervisor regression suite: liveness, generation guards, backoff restarts,
# the crash-loop breaker, request timeouts and the protocol handshake.
vim-core:
	vim -Nu NONE -n -i NONE -es -S tests/vim_core.vim

# Vim9 compiles def bodies lazily, so a type error in a cold branch stays
# hidden until a user reaches it.  :defcompile surfaces it here instead.
defcompile:
	vim -Nu NONE -n -i NONE -es -S tests/defcompile.vim
