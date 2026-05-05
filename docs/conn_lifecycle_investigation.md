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

*(Pending: instrument `roadrunner_conn_loop` and `roadrunner_acceptor`
with `-ifdef(MEASURE_LIFECYCLE)` `timer:tc/0` boundaries. Phase totals
should reconcile within 10% of the P1 p50.)*

## P4 — Targeted fixes

*(Pending: 10×5s A/B per change on `connection_storm`. Accept only outside
variance band.)*

### Candidate 1 — drop `{inet_backend, socket}` for plain TCP

If validated by P3, removing the explicit `inet_backend, socket` opt should
remove 100+ `prim_socket:is_supported_option` calls per conn. Estimated
upper bound: roadrunner p50 → ~120 µs (sequential), throughput → 50K+ req/s
(concurrent).

Risk: `prim_socket` was the project's deliberate choice (per
`src/roadrunner_listener.erl:6` doc) for the "production-ready NIF-based
async I/O path." We're a POC with zero users, so the trade is acceptable
if it pays off in throughput. Document the reversal in commit message and
README.

## P5 — Outcome

*(Written incrementally as P3/P4 produce data.)*
