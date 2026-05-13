# Roadrunner vs cowboy + elli

This file consolidates the side-by-side benchmarks and architectural
trade-off discussion that used to live in the README. The README
points here for readers comparing roadrunner against the alternatives.

## Loadgen + hardware

`scripts/bench.escript` runs the same loadgen against each server in
its own peer BEAM. `scripts/bench_matrix.sh` drives 30+ scenarios
across both protocols and writes the consolidated tables that ship
in [`bench_results.md`](bench_results.md). Numbers below are the
median of 3 runs at 50 concurrent clients, loopback only (no NIC).
Re-run locally to see what your hardware shows; absolute numbers
shift, relative ordering tends to hold.

| | |
|---|---|
| CPU | 12th Gen Intel Core i9-12900HX (24 threads) |
| Kernel | Linux 6.19.6 (Arch) |
| OTP | 29 (erts 17.0, JIT) |
| Loadgen | 50 clients, 5s warmup + 5s measure, loopback |
| Bench client | in-tree `roadrunner_bench_client` (h1 + h2) |

## TL;DR

Roadrunner beats cowboy on most common scenarios by +30–80 % req/s
with proportionally lower p50 / p99. The exceptions are
connection-storm-shape scenarios (open-conn / close-conn dominates)
and the h2 `tls_handshake_throughput` case — those tie or slightly
lose. Vs elli, roadrunner ties or wins on simple GETs (`hello`,
`echo`, `json`) within a few percent, with elli still slightly
ahead on bandwidth-bound `large_response`. Roadrunner beats elli
outright wherever the workload needs a feature elli doesn't ship —
pipelining, gzip, body streaming, h2, WebSocket, router, native
qs/cookie parsing, etag.

## Throughput — req/s, HTTP/1.1 (higher = better)

A representative cross-section. The full per-protocol tables
(including per-server p50 / p99) live in
[`bench_results.md`](bench_results.md). Memory + CPU shape per
scenario lives in [`resource_results.md`](resource_results.md).

Bolded cells indicate the row's winner *and* a margin wider than
~15 % over the next-best (the bench's own variance band — see
"Reading the numbers honestly" below). Cells without bold are
inside variance and shouldn't be read as a win.

| scenario                  | roadrunner    | elli          | cowboy        |
|---------------------------|--------------:|--------------:|--------------:|
| `hello`                   |       285 k   |       289 k   |       196 k   |
| `json`                    |       292 k   |       301 k   |       182 k   |
| `echo`                    |       270 k   |       281 k   |       148 k   |
| `large_response`          |       124 k   |       125 k   |        94 k   |
| `headers_heavy`           |       267 k   |       241 k   |       134 k   |
| `cookies_heavy`           |   **287 k**   |          —    |       163 k   |
| `pipelined_h1`            |   **526 k**   |       4.9 k   |       357 k   |
| `varied_paths_router`     |   **294 k**   |          —    |       170 k   |
| `gzip_response`           |   **136 k**   |          —    |       108 k   |
| `websocket_msg_throughput`|   **230 k**   |          —    |       167 k   |

`—` means the elli test fixture doesn't support that scenario shape
(no h2, no WebSocket, no gzip middleware, no router, no native qs
parser, etc.). That's a real comparison point: if your workload
needs any of these, elli isn't on the table.

## Throughput — req/s, HTTP/2 (higher = better)

| scenario                   | roadrunner    | cowboy        |
|----------------------------|--------------:|--------------:|
| `hello`                    |       178 k   |       169 k   |
| `json`                     |       170 k   |       151 k   |
| `echo`                     |   **163 k**   |       118 k   |
| `headers_heavy`            |   **162 k**   |        89 k   |
| `multi_stream_h2`          |       351 k   |       331 k   |
| `tls_handshake_throughput` |       2.7 k   |     **3.2 k** |

Multi-stream and basic-req h2 line up with the h1 picture — large
wins on bigger headers/bodies, smaller wins on the simple paths.
`tls_handshake_throughput` is the one cowboy-wins case; documented
honestly in
[`conn_lifecycle_investigation.md`](https://github.com/arizona-framework/roadrunner/blob/main/docs/conn_lifecycle_investigation.md).

## Latency — p50 / p99 (lower = better)

p50 / p99 numbers per scenario × server are in the full results
file. Spot-checks from the same run:

| scenario               |     rr p50 / p99 |        elli p50 / p99 | cowboy p50 / p99 |
|------------------------|-----------------:|----------------------:|-----------------:|
| `hello`                | 119 µs / 1.65 ms |      117 µs / 1.53 ms | 196 µs / 1.87 ms |
| `echo`                 | 126 µs / 1.77 ms |      119 µs / 1.70 ms | 261 µs / 2.75 ms |
| `cookies_heavy`        | 120 µs / 1.56 ms |           —           | 235 µs / 2.62 ms |
| `pipelined_h1`         |  74 µs / 0.71 ms |   10.35 ms / 10.67 ms | 117 µs / 0.82 ms |

## Open-loop tail latency (wrk2)

The numbers above come from `bench.escript`, a closed-loop loadgen.
Closed loop deflates tail latency under load
([Coordinated Omission](https://www.scylladb.com/2021/04/22/on-coordinated-omission/));
[`bench_internals.md`](bench_internals.md) explains how and when it
matters.

[wrk2](https://github.com/giltene/wrk2) is the open-loop counterpart.
For the same `hello` scenario at the same rate, the corrected p99 is
roughly 13× the uncorrected:

|                          | corrected p99 | uncorrected p99 |
|--------------------------|--------------:|----------------:|
| roadrunner @ 127 k req/s |        2.0 ms |          165 µs |
| roadrunner @ 191 k req/s |        2.2 ms |           89 µs |

Full per-scenario tables and the rate-vs-tail curve are in
[`wrk2_results.md`](wrk2_results.md).

Run it locally:

```
./scripts/wrk2_bench.sh                       # full matrix
./scripts/wrk2_bench.sh --quick                # --runs 1, dev iteration
./scripts/wrk2_bench.sh --scenarios hello,echo  # subset
```

Requires Docker and a compiled test profile. See
[`CONTRIBUTING.md`](../CONTRIBUTING.md) for setup.

## Reading the numbers honestly

- **vs cowboy: roadrunner wins on most scenarios** by 25–60 % on
  req/s with proportionally lower p50 / p99. The exception is
  `tls_handshake_throughput` (h2), where cowboy edges roadrunner
  on fresh-TLS-conn-per-request workloads (documented in
  [`conn_lifecycle_investigation.md`](https://github.com/arizona-framework/roadrunner/blob/main/docs/conn_lifecycle_investigation.md)).
  Connection-storm-shape scenarios (in the full results) tie
  within variance.
- **vs elli: tied or just ahead on simple hot-path GETs.**
  Roadrunner now matches or slightly leads elli on `hello` /
  `echo` (within ~7 %), and trails by ~2–7 % on `json` /
  `large_response`. The gap (either way) is inside the bench's
  variance band — elli's minimal surface still wins the cleanest
  hot path some runs. Add a router / cookie parse / gzip /
  pipeline / h2 / WebSocket and elli either falls behind or
  drops out (no support). Elli also still wins the
  connection-storm-shape scenarios where the per-conn process
  model dominates.
- **p99 vs cowboy is typically 1.4–1.8× lower; vs elli within
  10 %** on the simple hot-path scenarios.
- **Cowboy trails on most axes here** because its dual-process
  pipeline (acceptor → connection → stream handlers) adds dispatch
  overhead the simpler servers don't pay. It optimizes for HTTP/2
  feature richness and supervisor-tree visibility — the
  trade-off shows on the bench.
- **Numbers shift on real hardware.** Loopback hides NIC + kernel
  TCP cost. For a public comparison run against a remote host with
  `--clients` tuned to your CPU count.

## Architectural trade-offs

|                                | roadrunner                       | elli                       | cowboy                        |
|--------------------------------|----------------------------------|----------------------------|-------------------------------|
| Per-conn process model         | tail-recursive `proc_lib` loop   | tail-recursive loop        | gen_server + stream handlers  |
| Request lifecycle observable   | yes (`proc_lib:get_label/1`)     | no                         | partial                       |
| Drain / graceful shutdown      | built-in (`pg`-broadcast)        | DIY                        | partial                       |
| Telemetry                      | `telemetry` library, 10+ events  | none (handler callbacks)   | `cowboy_metrics_h` opt-in     |
| Middleware shape               | continuation-passing             | `pre_request`/`post_request` callback | deprecated `(Req, Env)`/stream handlers |
| Hibernation between requests   | `hibernate_after` works          | no                         | depends on stream handler     |
| Default recv mode              | passive (`gen_tcp:recv`)         | passive (`gen_tcp:recv`)   | active (`{active, once}`)     |
| HTTP RFCs                      | RFC 9110 + RFC 9112 + RFC 9113   | RFC 7230 era               | RFC 9110 + RFC 9112 + HTTP/2  |
| HTTP/2 (RFC 9113 + 7541)       | yes — h2spec 100 % strict        | no                         | yes                           |
| Content-Encoding               | gzip + deflate, qvalue-aware     | DIY                        | hooks for stream handlers     |
| WebSocket conformance          | Autobahn 100 % strict            | n/a                        | Autobahn-tested               |
| permessage-deflate (RFC 7692)  | yes                              | n/a                        | yes                           |
| Public API surface             | small                            | small                      | large (HTTP/2, gun, etc.)     |
| Runtime deps                   | `telemetry` only                 | none                       | `cowlib`, `ranch`             |

## How to reproduce

Single scenario:

```
mise exec -- ./scripts/bench.escript --servers roadrunner,elli,cowboy \
  --scenarios hello --clients 50 --duration 5 --warmup 2
```

Run several times and take the median — the bench script's banner
warns that single runs sit inside a ±15 % variance band on a
loaded dev box. `scripts/bench.escript` also accepts `--profile`
to dump an eprof or fprof hotspot table.

Full matrix (regenerates `bench_results.md`):

```
./scripts/bench_matrix.sh
```

Override defaults via env: `RUNS=5 DURATION=10 ./scripts/bench_matrix.sh`.

`scripts/bench.escript --protocol h2` drives the same scenarios
over HTTP/2. The h2 loadgen is the in-tree pure-Erlang
`roadrunner_bench_client` (lives in `test/` because it's only used
by dev tools); no external h2 client / loadgen needs to be
installed. h2 vs h1 numbers are workload-shape-sensitive: small
responses at high concurrency typically favor h2 (single-connection
multiplexing — note that this bench uses one connection per worker
so it measures protocol framing overhead, not multiplexing benefit);
single-request latency may favor h1 (no frame demux). Run both
directions on the same hardware before claiming a win.

## Picking a server

- **Pick elli** if you need only the simplest GET hot path with
  zero modern features and care about the last 6–15 % of throughput
  more than RFC coverage / drain / telemetry / pipelining / gzip /
  h2 / WebSocket.
- **Pick cowboy** if you need sub-protocols beyond what roadrunner
  ships, or you're already in an ecosystem where it's the lingua
  franca. Roadrunner beats it on every common scenario in this
  bench.
- **Pick roadrunner** if you want a small surface, queryable
  per-request state, drain + telemetry built in, RFC-9110/9112/9113
  coverage, h2spec-compliant HTTP/2, Autobahn-strict WebSocket, and
  the throughput / p99 numbers above.
