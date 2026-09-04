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

Five point optimizations were tried first (graceful_drain skip, set_label
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
(`graceful_drain => false`, `set_label`/`refine_conn_label` skip,
`init_ack` first, async spawn, more acceptors) all turned out to
target costs that were genuinely small relative to the inet_backend
overhead. None of them would have surfaced the actual bottleneck
without the fprof survey.

**Lesson for future investigations:** profile first, fix second.
The 5 µs/conn cost guess from the prior session was off by an order
of magnitude — the actual cost was 60+ µs/conn, all in one place.

## Round 3 — `tls_handshake_throughput` (h2): null result

`tls_handshake_throughput` (open fresh TLS conn per request, GET /,
close — full handshake every time) showed roadrunner ~2.4K vs
cowboy ~2.9K, a consistent **20% loss** across 3 runs (well outside
variance). fprof'd the path looking for a fixable hotspot.

**Top own-time MFAs (5 clients × 2 s, fprof):**

| MFA | % own | Calls/conn |
|---|---|---|
| `gen:do_call/4` (gen_statem dispatch inside ssl) | 6.2% | ~4 |
| `prim_inet:enc_opts/2` | 3.9% | ~3.4 |
| `prim_inet:enc_opt_val/4` | 3.0% | ~3.1 |
| `roadrunner_bin:ascii_lowercase_walk/1` | 2.8% | ~8 |
| `prim_inet:dec_opt_val/1` | 2.1% | ~4 |
| `prim_inet:type_opt/2` | 2.0% | ~10 |
| `prim_inet:dec_opt_val/3` | 1.9% | ~3.4 |
| `prim_inet:type_opt_1/1` | 1.8% | ~10 |

**Caller analysis:** the `prim_inet:*` cluster (~15% combined own
time) is reached via `prim_inet:accept0/3 → accept_opts/3 → getopts
+ setopts`. This is OTP's standard `gen_tcp:accept` machinery — when
the inet driver hands a new socket up, it inherits the listener's
options via this getopts/setopts dance. Same path cowboy hits.

**No fixable hotspot.** The gap is spread across many small
contributors:
- `prim_inet` accept-opts inheritance is OTP-internal and identical
  for any `inet_drv`-backed listener (which both servers are).
- `gen_statem:call` overhead is from the `ssl` app's internal state
  machine — also identical.
- `ascii_lowercase_walk` at 2.8% is plausibly fprof overhead on a
  short-string walk that JIT-compiles to ~50 ns per call (fprof's
  per-call instrumentation cost is ~1 µs).

**What WOULD close the gap (out of scope for this branch):**
- Switching to the OTP-27 `socket` NIF backend for the TLS listener
  *might* reduce the inheritance cost, but we deliberately reverted
  to `inet_drv` for h1 (40% gain at recv time). Different trade per
  scenario; no single-default that wins both.
- Multi-acceptor SSL or handshake-pre-staging — architectural.
- Reducing per-conn `setopts({active, once})` calls by switching
  to `{active, N}` — structural change to the recv loop.

This is documented as a known gap. Pursuing more without an
architectural lever returns null results inside variance.

## Round 4 — `streaming_response` / `large_post_streaming` / `small_chunked_response` near-tie

All three were within variance vs cowboy (51K/53K, 6.1K/6.4K, 5.0K/5.1K).
fprof'd each looking for shared MFA hotspots.

### Win: `roadrunner_conn:fill_n/3` — O(N²) → O(N)

`large_post_streaming` fprof showed `fill_n/3` at 15.6 % of own time.
The implementation accumulated recv chunks via `<<Buf/binary,
More/binary>>` per recursion — each step reallocates the running
buffer (cumulative O(N²) copy bytes for many small chunks).

Rewrote with body recursion that conses each recv chunk onto an
iolist on the way OUT, flattening once via `iolist_to_binary` at the
end (O(N) total). No `lists:reverse` per `feedback_body_recursion`.

A/B (3×5 s):

| | Before (median) | After (median) | Δ |
|---|---|---|---|
| roadrunner | 11.7K req/s | **13.5K** | **+15 %** |
| cowboy | ~6.1K | ~6.1K | unchanged |
| Δ vs cowboy | +96 % | **+130 %** | — |

Variance band on baseline was <1 % (11.67–11.77K), so the +15 % is
unambiguously real.

Same fix shape later applied to `roadrunner_conn:read_body_until/3`
(auto-mode body read), same `<<Acc/binary, Data/binary>>` pattern.
At 4 KB body sizes (~3 recv chunks per request) the O(N²) was
invisible. The `httparena_upload_20mb_auto` scenario (20 MB body,
~320 recv chunks per request) surfaced it unambiguously: eprof
showed `read_body_until/3` at 49 % of CPU. Shipped the body-
recursive iolist fix in `b507415` "Avoid quadratic binary concat
in conn body buffer"; pre→post on that scenario: 381 → 430 r/s,
peak RSS 3.4 GB → 1.95 GB, p99 44 → 31 ms.

### Null results (reverted)

- **`roadrunner_conn_loop_http2:try_send_data`/`send_data_chunks`**:
  redundant `window_budget/2` call between the two functions.
  Threading the value through saved one call per chunk; A/B on
  `small_chunked_response` (100 chunks per response) was within
  variance. Function is too cheap to register.
- **`roadrunner_uri:percent_decode/1` slow-path run-based decoder**:
  `binary:match` to the next `%`, slice the unchanged run as a
  sub-binary, only individually process `%HH` triples. Structurally
  better worst-case (O(L) vs O(L²) on long runs). A/B on
  `path_with_unicode` was within variance because the URLs have
  only 4-5 percent-encoded values — the slow path is too small a
  slice of total request cost. Kept the fast-path (skip when no
  `%`) but reverted the slow-path rewrite.

### Outcome

`streaming_response` h2: roadrunner now leads cowboy 54.9K vs
52.8K (was tied). `large_post_streaming` h1: roadrunner doubles
cowboy. `small_chunked_response` h2: still tied (no fixable
hotspot found beyond the inevitable per-chunk message round-trip
between stream worker and conn process — a structural property
of the design).

## Round 2 — WebSocket throughput

`websocket_msg_throughput` (1 KB masked text frames, 50 conns) was
added in this round. Initial result: roadrunner 110K msgs/s vs
cowboy 153K — a clear gap.

### Findings (fprof, `--profile-tool fprof` on bench.escript)

Two byte-at-a-time unmask paths in roadrunner, each ~30% of own
time on the WS hot path:

1. `roadrunner_ws:unmask/2` — unmasks the full frame payload in
   `parse_payload`, server-side. Original implementation built an
   iolist via cons-on-the-way-out then `iolist_to_binary`. Each
   byte: `binary:at(MaskKey, I rem 4)` + `bxor` + cons + recursion
   bookkeeping.
2. `roadrunner_ws_session:unmask_slice/3` — unmasks an incremental
   slice for early UTF-8 validation, called from
   `early_validate_text/3` per frame fragment. Same byte-at-a-time
   pattern.

cowlib's `cow_ws:mask/3` processes 16 bytes per recursion (4 ×
32-bit words) with a single `bxor` against a precomputed rotated
32-bit mask. ~10× faster on 1 KB payloads.

### Fix

Both functions rewritten to mirror cowlib's pattern — 16 bytes per
recursion, 32-bit XOR, bit-rotated mask key for non-zero offsets.
Two commits:

- `Unmask WS frames in 32-bit chunks instead of byte-at-a-time`
  (`roadrunner_ws:unmask/2`)
- `Unmask WS frame slices in 32-bit chunks instead of
  byte-at-a-time` (`roadrunner_ws_session:unmask_slice/3` — adds a
  test export + chunk-path unit tests for honest coverage).

### Measured impact

10×5s `websocket_msg_throughput` A/B at 50 clients:

| Stage | Median (msgs/s) | Δ |
|---|---|---|
| Baseline | 110K | — |
| After `roadrunner_ws:unmask` fix | 149K | +35% |
| After `unmask_slice` fix (final) | **193K** | **+75%** total |

Now beats cowboy (153K) by ~26% on the same scenario.

### What's left

Re-profile after the fixes shows ~40% of own time still in the two
chunked unmask paths combined. The remaining cost is partly
fundamental (1024 bytes XOR'd at 16 bytes/recursion is 64
iterations + 64 binary appends) and partly the fact that
**we unmask twice** for text frames: once for incremental UTF-8
validation in `early_validate_text/3`, then again for the final
payload in `roadrunner_ws:parse_payload/6`. Caching the
already-unmasked bytes from the early-validation path so
`parse_payload` doesn't re-unmask is a real optimization but
crosses the `roadrunner_ws_session` ↔ `roadrunner_ws` module
boundary — needs its own design pass. Deferred.

Roadrunner currently leads cowboy on this scenario; pursuing more
WS optimization without a fresh signal is gilding the lily.

## Round 5 — connect burst: null result

The roadmap carried a "medium effort" item claiming a 1024-connection
burst was "about twice as slow as it needs to be", from a measurement of
~61 ms to a first response against ~31 ms for another BEAM server. Three
things turned out to be wrong with that premise.

### The recorded numbers were taken cold

Repeating the burst against one roadrunner over plain TCP, timing
connect to first response byte, varying only warmth:

| load generator | server | p50 | p90 |
| --- | --- | --- | --- |
| cold | cold | 44.9 / 48.6 ms | 46.1 / 58.6 ms |
| cold | warm | 23.6 / 34.3 ms | 30.1 / 39.7 ms |
| warm | warm | 7.5 / 9.7 ms | 11.7 / 13.9 ms |

A cold run reproduces the recorded ~61 ms; warm, the same burst is 8 to
14 ms, and roughly half the cold cost belongs to the load generator
rather than the server. So the figure characterises warm-up, not the
accept path. Cold start itself is lazy code loading serialized by the
code server, which a release boot script avoids entirely; see
`resource_limits.md`.

### Measured against the floor there is no 2x

A minimal accept-and-reply server with the same listen options and
acceptor count, doing no HTTP parsing, routing, telemetry or accounting,
under the same client. Medians of 9 warm rounds each:

| server | p50 | p90 |
| --- | --- | --- |
| bare accept-and-reply | 5.3 ms | 7.5 ms |
| roadrunner | 8.9 ms | 14.5 ms |

roadrunner sits about 3.5 us per connection above a server that does no
HTTP work at all. That is the entire budget available, not 2x.

### The socket ownership transfer costs nothing

eprof over a warm burst put `erts_internal:port_control/3` at 16.9% with
9 calls per connection, and the `prim_inet` option-marshalling family at
another ~16%. Six of those nine round trips come from
`inet:tcp_controlling_process/2` (setopts, getopts, transfer, setopts),
which pointed at removing the handoff. It does not help. Four handoff
shapes of the same bare server, differing only in how the socket reaches
the process that serves it, medians of 9 warm rounds:

| handoff | p50 | p90 |
| --- | --- | --- |
| spawn, no transfer | 5.3 ms | 7.5 ms |
| spawn + `controlling_process` | 4.6 ms | 5.9 ms |
| acceptor becomes the conn process, no transfer at all | 5.8 ms | 7.3 ms |

Adding the transfer measured nominally *faster* than omitting it, and
eliminating it architecturally was no better than keeping it. Its cost
sits below the noise floor of this measurement.

**Treat `prim_inet` entries in a profile with suspicion.** Round 3 above
hit the same top-of-profile signature and it was equally misleading
there. Tracing overhead falls heavily on cheap port operations, so their
share is inflated; only a controlled A/B settles whether removing them
buys anything.

### Outcome

There is no single dominant cost in connection setup. The ~3.5 us per
connection over the floor is spread across work an HTTP server has to
do: parsing, routing, telemetry, counters, the drain-group join, the
request id, the date header. Nothing here justifies restructuring the
accept path, so the roadmap item is closed.

Two costs are real but only bite on connection churn, recorded in case
they matter later. The `Date` header cache in
`roadrunner_http:http_date_now/0` is a process-dictionary cache keyed on
the current second, so a workload serving one request per connection
recomputes it every time, ~2% of a churn profile; a shared clock would
need an owner process and an ETS table, and `persistent_term` is the
wrong tool because a per-second update triggers a global scan.
`crypto:strong_rand_bytes/1` for the request id is ~1.7%. Both amortise
to nothing under keep-alive.

### Carried over from the roadmap entry

**Already ruled out by measurement** (3-round interleaved A/B each, so
these are not worth re-testing):

- the `pg:join` into the drain group, both by moving it after
  `proc_lib:init_ack` (off the acceptor's critical path) and by
  disabling `graceful_drain` entirely — both tied
- acceptor pool size — 16 and 100 acceptors behave the same
- garbage collection — `erlang:system_monitor` fires no `long_gc`
- the synchronous `proc_lib:start` handshake per accepted connection.
  Instrumenting the accept path shows it *is* where the acceptor's time
  goes — 870 us of a 875 us total per connection, against 2 us for
  `controlling_process` and 0.2 us for the `shoot` send — because the
  acceptor waits for the new process to be scheduled and ack. But
  spawning asynchronously instead (no init-ack round trip) cuts that to
  2 us per connection and leaves time-to-first-response unchanged. With
  a pool of acceptors the blocking is parallel, so it is not the serial
  constraint; starting and scheduling the conn processes themselves
  costs the same either way.
- the read path. On this workload the conn loop makes zero passive
  `recv` calls: the whole 10 KB request arrives in one `{active, once}`
  delivery, and `recv` engages only once a request outgrows the 64 KB
  listener buffer (measured 0, 1 and 4 calls per request for 10 KB,
  64 KB and 256 KB bodies). Where it does engage, active-mode reads
  measured ~2.5 % worse at p50 and unchanged at p99, and `{active, 64}`
  batching saved ~8 us per request (~3 % of p50) with no p99 movement.
  The gen_statem cost on TLS is real but sits in `ssl:setopts` and
  `ssl:send`, about 30 us per request, far too small to explain a
  p99-to-average ratio of 17.
- the keep-alive request cap, CPU throttling in the container, VM flag
  asymmetry, Nagle, and hibernation, each checked and none of them
  moving the tail.

**Also inconclusive:** spreading accepts over a pool of `SO_REUSEPORT`
listen sockets (8 vs 1, same total acceptors, isolated from roadrunner
in a minimal accept-and-reply server) measured tied — one round of three
suggested the median halved, but finer sampling reversed it. Run-to-run
variance on a 24-core laptop is larger than the effect being chased
(p50 ranged 4.6-14.6 ms for an identical configuration), so this needs a
quiet, larger machine before it means anything either way. Note the h3
stack already pools listeners this way, so the machinery has precedent
if it does turn out to help.

**Stalls seen during the burst:** `erlang:system_monitor` attributed
them to the `tcp_inet` port being scheduled for up to 20 ms at a stretch,
and to conn processes blocked that long inside `erlang:port_control/3`
(the `{active, once}` re-arm). In steady state they nearly vanish (max
~5 ms, a handful per 14 s). That reading pointed at the accept path and
at `port_control`, and both suspects are now settled above: the
`proc_lib:start` handshake and the ownership transfer that drives most
of those `port_control` calls were each measured directly and cost
nothing. What remained untested was the single listen socket's port,
which the `SO_REUSEPORT` experiment above could not resolve on this
machine. With the whole gap to the floor now measured at ~3.5 us per
connection, there is not enough left for it to be worth chasing.
