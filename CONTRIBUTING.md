# Contributing to Roadrunner

1. [Setup](#setup)
1. [Workflow](#workflow)
1. [License](#license)
1. [Reporting a bug](#reporting-a-bug)
1. [Requesting or implementing a feature](#requesting-or-implementing-a-feature)
1. [Submitting your changes](#submitting-your-changes)
   1. [Code Style](#code-style)
   1. [Committing your changes](#committing-your-changes)
   1. [Pull requests and branching](#pull-requests-and-branching)
   1. [Credits](#credits)

## Setup

See `.tool-versions` for the required Erlang/OTP and rebar3 versions
(install via [mise](https://mise.jdx.dev/) or
[asdf](https://asdf-vm.com/)).

```bash
git clone https://github.com/arizona-framework/roadrunner.git
cd roadrunner
rebar3 compile
```

## Workflow

One command covers day-to-day development:

- **`rebar3 precommit`** -- run before every commit and before pushing.
  Formats Erlang via `erlfmt`, compiles, runs xref + dialyzer, runs
  the eunit + Common Test (incl. PropEr) suites with cover, and
  fails if line coverage drops below 100 %. CI runs the same command.

For everything else (single-suite runs, coverage reports, individual
check stages) invoke `rebar3 <task>` directly: `rebar3 eunit`,
`rebar3 ct`, `rebar3 dialyzer`, `rebar3 cover`, `rebar3 fmt`, etc.
See `rebar.config` for the full alias list.

Diagnostic / conformance scripts under `scripts/` (`bench.escript`,
`h2spec.sh`, `autobahn.escript`, `redbot.escript`, `wrk2_bench.sh`)
are run directly; each script's header documents its requirements.

### Benchmarking notes

Two complementary load drivers ship in this repo:

- **`scripts/bench.escript`** — closed-loop. Each worker sends a
  request, waits for the response, sends the next. Reports
  throughput + p50/p99 from per-request timing. Easy to set up,
  no external dependency, but tail latency under load is
  deflated by Coordinated Omission. Used for the per-scenario
  matrix in [`docs/bench_results.md`](docs/bench_results.md).
- **`scripts/wrk2_bench.sh`** — open-loop, via
  [wrk2](https://github.com/giltene/wrk2) running in Docker
  (`cylab/wrk2:latest`). Issues requests at a fixed rate
  regardless of server response and reports
  Coordinated-Omission-corrected HdrHistogram percentiles.
  Output: [`docs/wrk2_results.md`](docs/wrk2_results.md). Needs
  `docker` on PATH and `rebar3 as test compile` already done;
  the script pulls the image automatically.

Run a quick wrk2 sanity check:

```bash
./scripts/wrk2_bench.sh --quick --scenario hello
```

The full matrix takes ~2 hours at `--runs 1 --duration 30s` and
~10 hours at the canonical `--runs 3 --duration 60s`. Run on a
quiet machine — system noise inflates tail percentiles.

Both drivers' internals (worker model, latency aggregation,
loader-as-bottleneck conditions) are documented in
[`docs/bench_internals.md`](docs/bench_internals.md).

## License

Roadrunner is licensed under the [Apache License Version 2.0](LICENSE.md), for all code.

## Reporting a bug

Roadrunner is not perfect software and will be buggy.

Bugs can be reported via
[GitHub issues: bug report](https://github.com/arizona-framework/roadrunner/issues/new?template=bug_report.md).

Some contributors and maintainers may be unpaid developers working on Roadrunner, in their own time,
with limited resources. We ask for respect and understanding, and will provide the same back.

If your contribution is an actual bug fix, we ask you to include tests that, not only show the issue
is solved, but help prevent future regressions related to it.

## Requesting or implementing a feature

Before requesting or implementing a new feature, do the following:

- search, in existing [issues](https://github.com/arizona-framework/roadrunner/issues) (open or closed),
whether the feature might already be in the works, or has already been rejected,
- make sure you're using the latest software release (or even the latest code, if you're going for
_bleeding edge_).

If this is done, open up a
[GitHub issues: feature request](https://github.com/arizona-framework/roadrunner/issues/new?template=feature_request.md).

We may discuss details with you regarding the implementation, and its inclusion within the project.

We try to have as many of Roadrunner's features tested as possible. Everything that a user can do,
and is repeatable in any way, should be tested, to guarantee backwards compatible.

## Submitting your changes

### Code Style

- run `rebar3 fmt` (also part of the `precommit` gate) — `erlfmt`
  enforces no trailing whitespace, 4-space indentation, and a
  100-character soft line limit
- write small functions whenever possible, and use descriptive names for functions and variables
- comment tricky or non-obvious decisions made to explain their rationale
- prefer modern OTP idioms — sigils for binary literals (`~"..."`),
  triple-quoted multi-line strings (`"""..."""`), `maybe` expressions
  for nested case chains, body recursion (cons on the way out) over
  `lists:reverse(Acc)`, binary keys for wire-derived data (no
  `binary_to_atom` on parsed names)

### Committing your changes

Merging to the `main` branch will usually be preceded by a squash.

Commit messages use a plain imperative subject line — no
`feat:`/`fix:`/`chore:` semantic prefixes. Subject only, no body
unless the change genuinely needs explanation (a one-line subject
beats a paragraph of preamble).

While it's OK (and expected) for your commit messages to relate the
*why* of a given change, be aware that the final commit (the merge
one) will be the PR title — so make it specific. This also helps
automated changelog generation.

### Pull requests and branching

All fixes to Roadrunner end up requiring a +1 from one or more of the project's maintainers.

During the review process, you may be asked to correct or edit a few things before a final rebase
to merge things. Do send edits as individual commits to allow for gradual and partial reviews to be
done by reviewers.

### Credits

Roadrunner has been improved by
[many contributors](https://github.com/arizona-framework/roadrunner/graphs/contributors)!
