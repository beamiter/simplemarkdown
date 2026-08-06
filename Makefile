.PHONY: check build install fmt lint clippy test test-rust test-daemon test-vim test-external clean vim-core defcompile check-classes preview bench core-verify

build:
	cargo build --release --locked

install:
	./install.sh

fmt:
	cargo fmt --all -- --check

clippy:
	cargo clippy --all-targets --locked -- -D warnings

# Kept: `lint` predates the suite-wide name.
lint: clippy

# `check` is the full gate in every simple* plugin; `test` is cargo test alone.
check: core-verify fmt clippy test test-daemon check-classes defcompile vim-core test-vim test-external

# Kept: `test-rust` predates the suite-wide name.
test-rust: test

test:
	cargo test --locked --all-targets

test-daemon: build
	./target/release/simplemarkdown-daemon --self-test
	./target/release/simplemarkdown-daemon --help >/dev/null
	./target/release/simplemarkdown-daemon --version >/dev/null
	./target/release/simplemarkdown-daemon --classes >/dev/null
	printf '%s\n' '{"type":"ping","id":1}' \
		| ./target/release/simplemarkdown-daemon \
		| grep -qF '"type":"pong"'
	@# A piped client closes stdin as soon as it has written, and every queued
	@# reply must still reach stdout.  Losing them was a race between stdin EOF
	@# and the writer task, so one run proves nothing: repeat it.
	@for run in 1 2 3 4 5 6 7 8; do \
		got="$$(printf '%s\n' \
			'{"type":"ping","id":1}' \
			'{"type":"render","id":2,"lines":["# heading"],"width":40}' \
			'{"type":"render","id":3,"lines":["- item"],"width":40}' \
			| ./target/release/simplemarkdown-daemon | wc -l)"; \
		test "$$got" -eq 3 \
			|| { echo "run $$run: $$got replies, want 3 (a reply was lost at exit)"; exit 1; }; \
	done
	@echo "daemon: replies survive stdin EOF"

# The Vim side registers one text-property type per class the daemon may emit.
# A class present in Rust but missing in Vim is a hard prop_add() error inside
# a channel callback — the worst place to find out — so the two lists are
# compared here rather than discovered at render time.
check-classes: build
	@./target/release/simplemarkdown-daemon --classes > /tmp/simplemarkdown-rust-classes
	@vim -Nu NONE -n -i NONE -es -S tests/classes.vim > /tmp/simplemarkdown-vim-classes
	@diff -u /tmp/simplemarkdown-rust-classes /tmp/simplemarkdown-vim-classes \
		&& echo "classes: Rust and Vim agree"

test-vim: build
	vim -Nu NONE -n -i NONE -es -S tests/vim_smoke.vim

# The external (browser) preview, against a stand-in for omd: port allocation,
# one server per buffer, and teardown.  Needs no omd installed.
test-external:
	vim -Nu NONE -n -i NONE -es -S tests/vim_external.vim

# Render the fixture to the terminal.  Handy when changing the layout code:
# the diff of two runs is the whole review.
preview: build
	@./target/release/simplemarkdown-daemon --preview tests/fixtures/kitchen-sink.md $${WIDTH:-80}

clean:
	rm -rf target lib/simplemarkdown-daemon lib/simplemarkdown-daemon.exe tests/*-errors.log

# ---------------------------------------------------------------------------
# simplecore: the vendored daemon supervisor shared by the simple* suite.
#   https://github.com/beamiter/simplecore
# Regenerate with ../.simplecore/vendor.sh; never edit autoload/simplemarkdown/core.vim.
# ---------------------------------------------------------------------------

# The bundle is copied into each plugin rather than shared by reference, so
# that every plugin stays independently installable.  Copies drift silently
# unless something checks them, and one such copy went unnoticed long enough
# for the whole .simplecore directory to go missing before it had a repository
# of its own: .simplecore.manifest pins the sha256 of every vendored file, and
# this target fails the build when a copy no longer matches.
#
#   git clone https://github.com/beamiter/simplecore ../.simplecore
#   ../.simplecore/vendor.sh --check    # suite-wide drift
#   ../.simplecore/vendor.sh            # re-vendor
core-verify:
	@grep -E '^[0-9a-f]{64}  ' .simplecore.manifest | sha256sum -c --quiet
	@echo "simplecore: bundle v$$(awk '$$1 == "version" { print $$2 }' .simplecore.manifest) verified"

# Supervisor regression suite: liveness, generation guards, backoff restarts,
# the crash-loop breaker, request timeouts and the protocol handshake.
vim-core:
	vim -Nu NONE -n -i NONE -es -S tests/vim_core.vim

# Vim9 compiles def bodies lazily, so a type error in a cold branch stays
# hidden until a user reaches it.  :defcompile surfaces it here instead.
defcompile:
	vim -Nu NONE -n -i NONE -es -S tests/defcompile.vim
