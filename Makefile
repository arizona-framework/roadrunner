# Roadrunner Makefile
#
# The whole reason this Makefile exists: rebar3 on OTP 29 RC3 fails
# the TLS handshake to hex.pm on `/packages/<name>` paths because
# Fastly's edge rejects OTP 29's TLS 1.3 client fingerprint there.
# Without a workaround, every `rebar3 compile` / `rebar3 precommit`
# /  `rebar3 ex_doc` that needs to refresh the hex registry fails to
# load `rebar3_hank`, `rebar3_hex`, and `rebar3_ex_doc` plugins.
#
# The fix is an `ssl.config` (under `config/rebar3_ssl.config`) that
# pins TLS 1.2 + disables `middlebox_comp_mode`, loaded into the
# rebar3 BEAM via `ERL_FLAGS`. Setting it as a Makefile variable
# means contributors don't have to remember it on every invocation.
#
# **Drop this file (or at least the ERL_FLAGS bit) once OTP 29 RC4
# lands** — the Fastly-side fix is in that release.

SHELL := /bin/bash

# Loaded into the rebar3 BEAM only — the project's own ssl listeners
# pass their opts verbatim and aren't affected.
ERL_FLAGS := -config $(CURDIR)/config/rebar3_ssl
export ERL_FLAGS

.PHONY: all help compile test precommit doc fmt fmt-check \
	xref hank dialyzer eunit ct cover \
	bench bench-quick wrk2 wrk2-quick h2spec autobahn redbot \
	clean clean-doc clean-build distclean

all: precommit

help:
	@echo "Roadrunner — common make targets"
	@echo ""
	@echo "  compile       rebar3 compile"
	@echo "  test          rebar3 precommit (fmt-check, xref, hank, dialyzer, eunit, ct, 100% cover)"
	@echo "  precommit     alias for 'test'"
	@echo "  doc           rebar3 ex_doc (writes ./doc/)"
	@echo "  fmt           rebar3 fmt (writes)"
	@echo "  fmt-check     rebar3 fmt --check (CI / pre-push)"
	@echo "  xref / hank / dialyzer / eunit / ct / cover  individual rebar3 stages"
	@echo ""
	@echo "  bench         scripts/bench.escript (full closed-loop matrix)"
	@echo "  bench-quick   scripts/bench.escript --scenario hello --duration 5 (smoke)"
	@echo "  wrk2          scripts/wrk2_bench.sh (open-loop matrix, ~2-10h)"
	@echo "  wrk2-quick    scripts/wrk2_bench.sh --quick --scenario hello"
	@echo "  h2spec        scripts/h2spec.sh"
	@echo "  autobahn      scripts/autobahn.escript"
	@echo "  redbot        scripts/redbot.escript"
	@echo ""
	@echo "  clean         rebar3 clean"
	@echo "  clean-doc     rm -rf ./doc"
	@echo "  clean-build   rm -rf ./_build"
	@echo "  distclean     clean-build + clean-doc + remove erl_crash.dump etc"

compile:
	rebar3 compile

test precommit:
	rebar3 precommit

doc:
	rebar3 ex_doc

fmt:
	rebar3 fmt

fmt-check:
	rebar3 fmt --check

xref:
	rebar3 xref

hank:
	rebar3 hank

dialyzer:
	rebar3 dialyzer

eunit:
	rebar3 eunit --cover

ct:
	rebar3 ct --cover

cover:
	rebar3 cover --verbose --min_coverage=100

bench:
	./scripts/bench_matrix.sh

bench-quick:
	./scripts/bench.escript --scenario hello --duration 5 --warmup 1

wrk2:
	./scripts/wrk2_bench.sh

wrk2-quick:
	./scripts/wrk2_bench.sh --quick --scenario hello

h2spec:
	./scripts/h2spec.sh

autobahn:
	./scripts/autobahn.escript

redbot:
	./scripts/redbot.escript

clean:
	rebar3 clean

clean-doc:
	rm -rf ./doc

clean-build:
	rm -rf ./_build

distclean: clean-build clean-doc
	rm -f erl_crash.dump rebar3.crashdump
