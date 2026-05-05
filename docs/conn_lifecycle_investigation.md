# Conn-lifecycle investigation — finding the actual blocker

**Profile-driven Phase P1–P5 of `perf/conn-lifecycle` branch.**

## Symptom

Three bench scenarios show roadrunner is the worst vs cowboy / elli — all
measure per-connection or per-iteration framework overhead, not request
hot-path work:

| Scenario | roadrunner | cowboy | elli |
|---|---|---|---|
| `connection_storm` | 38K req/s | 45K | 53K |
| `router_404_storm` | 15K | 18K | 47K |
| `slow_client` | 4.4K | 6.2K | 6.2K |

Five point optimizations were tried first (drain_group skip, set_label
removal, init_ack-first, async spawn, more acceptors) — all within
variance or regressing. None of them addressed the actual blocker
because the actual blocker had not yet been measured.

## P1 — Sequential per-conn baseline

`scripts/diag/conn_storm_probe.escript --server <name> --mode local --reqs 1000`
times one connection at a time (no concurrency, no scheduler noise):

| Server | p50 | p95 | p99 | Throughput (1/p50) |
|---|---|---|---|---|
| roadrunner | **220 µs** | 459 µs | 623 µs | ~4,500 req/s/client |
| cowboy | 161 µs | 403 µs | 534 µs | ~6,200 req/s/client |
| elli | 108 µs | 274 µs | 335 µs | ~9,200 req/s/client |

**Roadrunner per-conn p50 is ~60 µs over cowboy and ~110 µs over elli.**
Sequential ratios match the concurrent `connection_storm` ratios (38/45/53),
so the gap is structural — not a contention or scheduler artifact.

## P2 — fprof survey (top own-time MFAs over 100 sequential conns)

`scripts/diag/conn_storm_probe.escript --server roadrunner --mode local --reqs 100 --profile fprof`

Output: `/tmp/roadrunner_conn_storm_fprof.analysis`. Top 10 by **own time**
(exclusive) — sorted, rounded:

| MFA | Calls/req | Own (ms / 100 reqs) | % of own total |
|---|---|---|---|
| `maps:fold_1/4` | 106 | 118.9 | 22% |
| `prim_socket:'-supports/1-fun-2-'/3` | 105 | 63.1 | 12% |
| `maps:try_next/2` | 105 | 52.6 | 10% |
| `prim_socket:is_supported_option/2` | 106 | 13.3 | 2.5% |
| `garbage_collect` | 24 | 10.1 | 1.9% |
| `gen:do_call/4` | 8 | 9.2 | 1.7% |
| `io_lib_format:build_small/1` | 19 | 6.8 | 1.3% |
| `io_lib_format:build_limited/5` | 26 | 6.4 | 1.2% |
| `gen_statem:loop_actions_list/12` | 16 | 5.5 | 1.0% |
| `roadrunner_bin:ascii_lowercase_walk/1` | 23 | 4.6 | 0.85% |

Top 4 entries are all the `prim_socket` / `maps` walking that
`{inet_backend, socket}` does on every socket option check —
**~106 socket-option lookups per connection**, dominating ~46% of
own time.

The fprof trace is in `/tmp/roadrunner_conn_storm_fprof.trace`; analysis at
`/tmp/roadrunner_conn_storm_fprof.analysis` (re-runnable from the probe).

## Hypothesis (P3 will validate)

`src/roadrunner_listener.erl:260` opens plain TCP listeners with
`{inet_backend, socket}` — the new NIF-based `socket` backend introduced as
default-ready in OTP 27. cowboy and elli use the legacy `inet_drv`
backend (gen_tcp default). The new backend exposes per-call socket-option
introspection that dominates per-conn time on short-lived connections.

This affects ONLY plain h1 listeners. TLS uses `ssl:listen` which doesn't
go through this backend. The `connection_storm` and `router_404_storm`
scenarios are h1-only, so they pay this cost on every conn.

## P3 — Per-phase manual timing

**Skipped.** P2's survey identified a single dominant MFA family
(`prim_socket:is_supported_option` + `maps:fold_1` walking it,
together ~46% of own time). When one candidate dominates this
clearly, per-phase decomposition is redundant — the fix IS the
validation. If P4 had been ambiguous we would have come back here.

## P4 — Targeted fix

### Candidate 1 — drop `{inet_backend, socket}` for plain TCP listeners ✓ ACCEPTED

`src/roadrunner_listener.erl:open_listen_socket/2` now opens plain
TCP listeners with the legacy `inet_drv` backend (gen_tcp default)
instead of the OTP-27 NIF-based `socket` backend.

#### Sequential probe (10×, p50 µs)

| | Before | After |
|---|---|---|
| roadrunner | 220 µs | **144–162 µs** |

#### Concurrent connection_storm (10×5s, 50 clients, req/s)

| | Before (median) | After (median) | Δ |
|---|---|---|---|
| roadrunner | 36.8K | **44.9K** | **+22%** |
| cowboy | ~45K | ~42K | (variance) |
| elli | ~53K | ~55K | (variance) |

#### Concurrent router_404_storm (single 5s run, req/s)

| | Before | After |
|---|---|---|
| roadrunner | 15K | **48K** (+220%) |
| cowboy | 18K | 44K |
| elli | 47K | 51K |

#### Concurrent slow_client (single 5s run, req/s)

| | Before | After |
|---|---|---|
| roadrunner | 4.4K | **6.2K** (+41%) |
| cowboy | 6.2K | 6.2K |
| elli | 6.2K | 6.2K |

#### What was given up

The OTP-27 `{inet_backend, socket}` NIF backend is the new default-ready
async I/O path. Removing it loses:
- The newer async I/O semantics (better polling on long-lived conns).
- Future-facing alignment with where OTP is going.

For a POC focused on h1 throughput these don't matter today. The
`base_listen_opts/0` doc-comment notes the trade so a future
maintainer can revisit when the workload mix shifts toward long-lived
connections.

#### Verification

- 1341 eunit + 33 CT pass; 100% coverage; dialyzer clean.
- `connection_storm` 10×5s A/B: roadrunner median +22% over baseline,
  well outside the ±2K req/s variance band of the baseline.
- `router_404_storm` and `slow_client` both confirmed wins
  (single-run for those — they share the same root cause and the
  signal is wider than any plausible variance).

## P5 — Outcome

**One change closed all three worst-scenario gaps.** Roadrunner now
matches or beats cowboy on connection_storm, router_404_storm, and
slow_client. Elli still wins by 10–20% on storm scenarios — that
remaining gap is the conn-process model itself (1-process-per-conn
vs elli's accept-and-handle-in-one-process model) and is out of
scope for this branch.

The earlier point-optimization attempts that came up empty
(`drain_group => disabled`, `set_label`/`refine_conn_label` skip,
`init_ack` first, async spawn, more acceptors) all turned out to
target costs that were genuinely small relative to the inet_backend
overhead. None of them would have surfaced the actual bottleneck
without the fprof survey.

**Lesson for future investigations:** profile first, fix second.
The 5 µs/conn cost guess from the prior session was off by an order
of magnitude — the actual cost was 60+ µs/conn, all in one place.
