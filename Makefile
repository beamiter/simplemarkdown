.PHONY: check build install fmt lint clippy test test-rust test-daemon test-vim test-links test-format test-authoring test-lint test-outline test-protocol test-external test-config clean vim-core defcompile check-classes check-codes check-protocol check-settings preview bench core-verify

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
check: core-verify fmt clippy test test-daemon check-protocol check-classes check-codes check-settings defcompile vim-core test-vim test-links test-format test-authoring test-lint test-outline test-protocol test-external test-config

# Kept: `test-rust` predates the suite-wide name.
test-rust: test

test:
	cargo test --locked --all-targets

test-daemon: build
	./target/release/simplemarkdown-daemon --self-test
	./target/release/simplemarkdown-daemon --help >/dev/null
	./target/release/simplemarkdown-daemon --version >/dev/null
	./target/release/simplemarkdown-daemon --classes >/dev/null
	@# `make bench` is a measurement, not an assertion, so it is not in the
	@# gate — but that it still runs is.
	./target/release/simplemarkdown-daemon --bench tests/fixtures/kitchen-sink.md 40 2 >/dev/null
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
	@# The browser preview's page is the one thing this daemon emits that no
	@# other target looks at, and a stylesheet that failed to inline is a page
	@# that renders as unstyled HTML rather than as an error anybody notices.
	@page="$$(./target/release/simplemarkdown-daemon --html tests/fixtures/kitchen-sink.md)"; \
	for want in '<!DOCTYPE html>' '<style>' 'data-line=' 'id="sm-doc"' 'window.SM'; do \
		case "$$page" in \
			*"$$want"*) ;; \
			*) echo "--html produced a page with no $$want"; exit 1;; \
		esac; \
	done; \
	echo "daemon: --html produces a self-contained page"
	@# The outline, the link table and the block index describe the whole
	@# document however little of it moved, and on a small patch they are the
	@# entire reply.  A fresh session must be sent all three; a render that
	@# changes none of them must carry none.
	@out="$$(printf '%s\n' \
		'{"type":"render","id":1,"session":"s","lines":["# heading","","word one"],"width":40}' \
		| ./target/release/simplemarkdown-daemon)"; \
	case "$$out" in \
		*'"toc"'*'"links"'*'"blocks"'*) ;; \
		*) echo "a fresh session must be sent every index: $$out"; exit 1;; \
	esac
	@# Serialised with a sleep: piped in together the two renders run
	@# concurrently, and the second would find no session to compare against.
	@out="$$({ printf '%s\n' \
		'{"type":"render","id":1,"session":"s","lines":["# heading","","word one"],"width":40}'; \
		sleep 1; \
		printf '%s\n' \
		'{"type":"render","id":2,"session":"s","incremental":true,"lines":["# heading","","word two"],"width":40}'; \
		sleep 1; } \
		| ./target/release/simplemarkdown-daemon | tail -1)"; \
	case "$$out" in \
		*'"toc"'*) echo "an unchanged outline was re-sent: $$out"; exit 1;; \
		*'"links"'*) echo "an unchanged link table was re-sent: $$out"; exit 1;; \
		*'"blocks"'*) echo "an unchanged block index was re-sent: $$out"; exit 1;; \
	esac; \
	echo "daemon: an unchanged index is not re-sent"
	@# An outline the client has withdrawn must not be parsed or answered.  The
	@# plugin debounces its background outline refreshes and withdraws the one
	@# still in flight when a newer one supersedes it — the same treatment a
	@# superseded render gets, because an outline costs the same full parse of
	@# the same full document.  A daemon that ignored the withdrawal would go on
	@# spending a core on a heading tree nobody will read.
	@#
	@# The cancel is sent first on purpose: this is not a race to win but an
	@# assertion that the id is consulted at all, and out-of-order cancels are
	@# exactly what the client produces (see note_cancelled).
	@out="$$(printf '%s\n' \
		'{"type":"cancel","id":7}' \
		'{"type":"outline","id":7,"lines":["# heading","","body"]}' \
		'{"type":"ping","id":8}' \
		| ./target/release/simplemarkdown-daemon)"; \
	case "$$out" in \
		*'"outline_result"'*) echo "a withdrawn outline was answered anyway: $$out"; exit 1;; \
	esac; \
	printf '%s' "$$out" | grep -qF '"type":"pong"' \
		|| { echo "the daemon stopped answering after a withdrawn outline: $$out"; exit 1; }; \
	echo "daemon: a withdrawn outline is not parsed"
	@# And one nobody withdrew still comes back, or the check above would pass
	@# on a daemon that had simply stopped answering outlines altogether.
	@out="$$(printf '%s\n' \
		'{"type":"outline","id":9,"lines":["# heading","","body"]}' \
		| ./target/release/simplemarkdown-daemon)"; \
	case "$$out" in \
		*'"outline_result"'*) ;; \
		*) echo "an outline nobody withdrew went unanswered: $$out"; exit 1;; \
	esac; \
	echo "daemon: an outline that still stands is answered"

# The protocol version is stated three times: in Rust, in Vim, and by the
# running daemon's handshake.  The plugin refuses to talk to a daemon whose
# version it does not know, so a bump applied to one and not the other is a
# preview that never draws — and CI used to assert a *literal* version here,
# which is how it stayed red for the whole life of v2 while asserting v1.
# Nothing is hardcoded below: every number is read from the source that owns it.
check-protocol: build
	@rust="$$(sed -n 's/^pub const PROTOCOL_VERSION: u32 = \([0-9]\+\);.*/\1/p' \
		src/simplemarkdown/protocol.rs)"; \
	vim_="$$(sed -n 's/^const PROTOCOL_VERSION = \([0-9]\+\).*/\1/p' \
		autoload/simplemarkdown.vim)"; \
	test -n "$$rust" || { echo "no PROTOCOL_VERSION in src/simplemarkdown/protocol.rs"; exit 1; }; \
	test -n "$$vim_" || { echo "no PROTOCOL_VERSION in autoload/simplemarkdown.vim"; exit 1; }; \
	test "$$rust" = "$$vim_" \
		|| { echo "protocol: Rust says v$$rust, Vim expects v$$vim_"; exit 1; }; \
	reply="$$(printf '%s\n' '{"type":"ping","id":1}' \
		| ./target/release/simplemarkdown-daemon)"; \
	printf '%s' "$$reply" | grep -qF "\"protocol_version\":$$rust" \
		|| { echo "protocol: the handshake does not declare v$$rust: $$reply"; exit 1; }; \
	printf '%s' "$$reply" | grep -qF '"render":true' \
		|| { echo "protocol: the handshake does not advertise the render capability"; exit 1; }; \
	echo "protocol: Rust, Vim and the handshake all say v$$rust"

# The Vim side registers one text-property type per class the daemon may emit.
# A class present in Rust but missing in Vim is a hard prop_add() error inside
# a channel callback — the worst place to find out — so the two lists are
# compared here rather than discovered at render time.
check-classes: build
	@./target/release/simplemarkdown-daemon --classes > /tmp/simplemarkdown-rust-classes
	@vim -Nu NONE -n -i NONE -es -S tests/classes.vim > /tmp/simplemarkdown-vim-classes
	@diff -u /tmp/simplemarkdown-rust-classes /tmp/simplemarkdown-vim-classes \
		&& echo "classes: Rust and Vim agree"

# The diagnostic codes are a closed set for the same reason the property
# classes are: a code that appears in the location list and nowhere in the help
# is one a reader cannot act on.  `--codes` is what the daemon can emit; the
# help is where a user looks it up; this is what keeps them the same set.
check-codes: build
	@./target/release/simplemarkdown-daemon --codes | cut -f1 > /tmp/simplemarkdown-codes
	@while read -r code; do \
		grep -q "^    $$code " doc/simplemarkdown.txt \
			|| { echo "diagnostic $$code is not documented in doc/simplemarkdown.txt"; exit 1; }; \
	done < /tmp/simplemarkdown-codes
	@echo "codes: every diagnostic the daemon can emit is documented"

# Every `g:` option is read through simplemarkdown#Setting(), which answers a
# name the settings table does not declare with an exception — the right answer
# for a typo in this repository, and a wrong one to discover from a cold branch
# inside a channel callback.  :defcompile cannot catch it: the name is a string.
# So the two lists are compared here, both read from the source that owns them.
# (That the table and the *help* are the same set is asserted from Vim, in
# tests/vim_config.vim, where the table can be asked rather than parsed.)
check-settings:
	@sed -n "s/^  {name: '\([a-z_]*\)'.*/\1/p" autoload/simplemarkdown.vim \
		| sort -u > /tmp/simplemarkdown-settings-declared
	@grep -ho "Setting('[a-z_]*')" \
		autoload/simplemarkdown.vim autoload/simplemarkdown/external.vim plugin/simplemarkdown.vim \
		| sed "s/^Setting('//; s/')$$//" | sort -u > /tmp/simplemarkdown-settings-used
	@test -s /tmp/simplemarkdown-settings-declared \
		|| { echo "no settings table found in autoload/simplemarkdown.vim"; exit 1; }
	@test -s /tmp/simplemarkdown-settings-used \
		|| { echo "nothing reads a setting; the grep above has gone stale"; exit 1; }
	@unknown="$$(comm -13 /tmp/simplemarkdown-settings-declared /tmp/simplemarkdown-settings-used)"; \
	test -z "$$unknown" \
		|| { echo "Setting() asks for names the table does not declare: $$unknown"; exit 1; }
	@echo "settings: every name Setting() is asked for is in the table"

test-vim: build
	vim -Nu NONE -n -i NONE -es -S tests/vim_smoke.vim

# Link following: bare `#anchor`, `other.md#section`, relative and reference
# links, followed from the preview window and from the source buffer.  Its own
# file because it needs a docs tree on disk, not the smoke test's one buffer.
test-links: build
	vim -Nu NONE -n -i NONE -es -S tests/vim_links.vim

# Table formatting: the one command that writes to the document rather than
# reading it.  Its own file because it needs a buffer with a CJK cell, a ragged
# row and a fenced block full of pipes, and because a formatter that gets its
# range wrong corrupts a file rather than drawing something odd.
test-format: build
	vim -Nu NONE -n -i NONE -es -S tests/vim_format.vim

# The structural edits: heading levels and list numbers.  Its own file rather
# than more of test-format because what they have to get right is different — a
# table is one span, a demoted section is several splices that must undo as one,
# and both a `#` in a fenced block and a `1.` in a code sample are bait for the
# pattern matching this deliberately does not do.
test-authoring: build
	vim -Nu NONE -n -i NONE -es -S tests/vim_authoring.vim

# Diagnostics: the codes, lines and severities that reach the location list,
# and the two behaviours that decide whether a linter is usable — that it
# clears itself when the document is clean, and that the on-write pass is
# silent.
test-lint: build
	vim -Nu NONE -n -i NONE -es -S tests/vim_lint.vim

# The outline: the heading tree asked for on its own, and the three things
# that need it where no preview exists — the contents popup, `]]`/`[[` in the
# source, and folding.  A folding bug is invisible in a unit test: an
# incoherent set of foldexpr answers silently produces no folds at all, so the
# test closes them and asks the window what it did.
test-outline: build
	vim -Nu NONE -n -i NONE -es -S tests/vim_outline.vim

# Version skew: a plugin updated without its daemon rebuilt.  `check-protocol`
# above proves the three declarations agree; this proves what happens when they
# do not — the preview must explain itself and must not render.
test-protocol:
	vim -Nu NONE -n -i NONE -es -S tests/vim_protocol.vim

# The external (browser) preview.  It talks HTTP to the port the plugin was
# handed rather than believing the plugin's own table: the table is what the
# plugin thinks it did, the socket is what it did, and every bug this preview
# has had lived in the gap.  Needs the daemon, which is now the server.
test-external: build
	vim -Nu NONE -n -i NONE -es -S tests/vim_external.vim

# Configuration: a `g:` option that does not hold what it says it holds.  Its
# own file because every assertion in it needs options set wrong *before* the
# plugin loads — the case that used to be silent, since normalising rewrites
# `g:` and the mistake is gone by the time anyone looks — which no other test
# can arrange without breaking its own fixture.
test-config: build
	vim -Nu NONE -n -i NONE -es -S tests/vim_config.vim

# The first render, the steady-state renders after it (the gap between the two
# is the highlight cache), and the patch one edit produces.  The CHANGELOG
# publishes all three; this is how they are taken.  WIDTH= and RUNS= to change.
bench: build
	@./target/release/simplemarkdown-daemon --bench \
		tests/fixtures/kitchen-sink.md $${WIDTH:-80} $${RUNS:-20}

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
