# How the bench load generators work

This doc explains the internals of the two load drivers that ship in
`scripts/`: the in-tree closed-loop one (`bench.escript`) and the
external open-loop one (`wrk2_bench.sh`). Read it if you need to
know what the numbers in [`bench_results.md`](bench_results.md) and
[`wrk2_results.md`](wrk2_results.md) actually measure, or if you're
trying to decide which driver to trust for a given question.

## TL;DR

| | `bench.escript` | `wrk2_bench.sh` |
|---|---|---|
| Loop | closed | open |
| Throughput | total requests / elapsed wall | issued at fixed target rate |
| Latency truth | per-request send→recv timing, but Coordinated-Omission-deflated under load | HdrHistogram corrected for delayed starts |
| Stack | pure Erlang, in-tree (`roadrunner_bench_client` for h2) | wrk2 in Docker (`cylab/wrk2`) |
| Question it answers | "what's the peak RPS each server reaches?" | "what tail latency does every issued request see at rate R?" |

Both have a place. Use `bench.escript` to find the peak (so you
know what to plug into `wrk2_bench.sh`'s rate sweep) and use
`wrk2_bench.sh` to characterise the tail honestly at rates below /
near the peak.

## `bench.escript` — closed-loop, in-tree

### Connection model

Each scenario starts the chosen server in a peer BEAM (one peer per
server: roadrunner, cowboy, elli — kept isolated) via
`peer:start_link/1`. The driver's main BEAM then spawns **one
worker process per `--clients` slot** (default 50). Each worker
opens **one keep-alive TCP connection** and reuses it for every
request the worker issues during the measurement window.

```
peer BEAM (roadrunner_listener)
    ↑   ↑   ↑   ...   ↑          (50 TCP connections)
    │   │   │         │
worker  worker  worker      (50 Erlang processes)
    └──── one driver BEAM ────┘
```

Workers don't share state. They're spawned with `spawn_link`, run
their loop until the `Deadline` (a `monotonic_time(millisecond)`
target), and `!` their accumulator back to the driver.

### Request scheduling — the closed loop

The hot path inside one worker:

```erlang
keep_alive_loop(Sock, Req, BodyLen, Deadline, Acc) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true -> Acc;
        false ->
            T0 = erlang:monotonic_time(nanosecond),
            ok = gen_tcp:send(Sock, Req),
            {ok, _Bytes} = recv_response(Sock, <<>>, BodyLen, 5000),
            T1 = erlang:monotonic_time(nanosecond),
            keep_alive_loop(Sock, Req, BodyLen, Deadline,
                            bump_ok(Acc, T1 - T0, Bytes))
    end.
```

Send → recv → loop. **The worker can't issue request N+1 until
request N's response has been fully read.** That's the closed loop:
the load offered to the server is paced by the server itself.

This is the source of Coordinated Omission. When the server stalls
for any reason (GC, scheduling, a slow connection on the same
listener), the worker waits — and the requests that "would have"
been sent during the stall are never sent, so their latency never
enters the histogram. The p99 you see is what the stall *let
through*, not what every issued request would have seen.

### Throughput

After all workers finish, the driver computes:

```
RPS = total successful requests / wall-clock elapsed (µs)
```

`elapsed_us` is bracketed by `monotonic_time(microsecond)` calls
**around the worker spawn** — startup overhead is amortised but the
spawn itself is included.

`total` excludes errors. The CSV / report shows error count
separately when non-zero.

### Latency aggregation

Each worker keeps an in-memory list of nanosecond per-request
durations: `latencies_ns => [Ns | _]`. After the worker exits, it
`!`s the whole list back to the driver:

```erlang
init_acc() ->
    #{ok => 0, err => 0, bytes_in => 0, latencies_ns => []}.
```

The driver concatenates all 50 worker lists, sorts the result, and
indexes:

```erlang
pct(Sorted, N, Q) ->
    Idx = max(1, min(N, round(Q * N))),
    lists:nth(Idx, Sorted).
```

So `p99` is `Sorted[round(0.99 * N)]`, etc. For a 5-second h1 hello
run at 50 workers, the sample count is well over 1 M (roughly the
per-second peak in `bench_results.md` × 5), so the index hits the
right percentile to within 1 sample.

### Can the loader be the bottleneck?

It can, and you should think about it on the high-throughput cells.
At ~300 k req/s on roadrunner `hello` h1, 50 worker processes each
run ~6000 `gen_tcp:send/recv` pairs per second, so each cycle is
~167 µs end-to-end. Of that, ~30 µs is Erlang-side CPU work (send
NIF + recv loop reading until `\r\n\r\n` then counting
Content-Length bytes + nanosecond timestamp + cons + recursion);
the remaining ~137 µs is the worker blocked on the response
(kernel + server time). The Erlang CPU portion is what competes
with the server for cores: 50 workers × 30 µs × 6 k cycles per
second is ~9 cores of total loadgen CPU. On the 24-thread machine
in `bench_results.md`'s header, that fits comfortably below
saturation; on smaller boxes the loadgen and the server can
genuinely contend.

Symptoms of loader saturation:

- Adding `--clients` doesn't increase throughput.
- The peer-BEAM CPU is much lower than the driver-BEAM CPU.
- Latency p50 stays flat at higher rates instead of climbing — a
  closed-loop driver in saturation just stops issuing more
  requests, which hides the real picture.

If you suspect this, drop to fewer clients (`--clients 25`) and
compare against the default. If RPS doesn't drop proportionally,
you were CPU-bound on the loadgen.

For the canonical comparison numbers in `bench_results.md` we run
50 clients on a 24-thread machine which leaves the loadgen
comfortably below saturation for everything except the very top
throughput cells (`hello`, `pipelined_h1`).

## `wrk2_bench.sh` — open-loop, via Docker wrk2

The script wraps [wrk2](https://github.com/giltene/wrk2) (Gil Tene's
constant-throughput variant of `wrk`). wrk2 uses the same C-level
event loop wrk does, but **schedules requests at a fixed target
rate (`-R`) regardless of server response time** and corrects the
HdrHistogram for [Coordinated
Omission](https://www.scylladb.com/2021/04/22/on-coordinated-omission/).

### Architecture

```
host                                 docker container
─────                                ────────────────
peer BEAM (one server)               cylab/wrk2:latest
    ↑      ↑      ↑   ...            wrk2 process
    │      │      │                       │
    │      │      │            ┌──────────┴──────────┐
    │      │      │            │  8 threads × 50    │
    │      │      │            │  connections       │
    └──────┴──────┴── TCP ─────┴────────────────────┘
                  (loopback, --network=host)
```

The driver script (`scripts/wrk2_bench.sh`):

1. Starts ONE server in a peer BEAM via `bench.escript --standalone`,
   which writes the bound port + URL path + HTTP method to a port
   file and blocks until SIGTERM.
2. Spawns `cylab/wrk2:latest` with `--network=host` so the
   container hits the BEAM listener on loopback. wrk2 runs its
   own event loop inside the container.
3. wrk2 issues requests at the target rate. With `-c 50`, it
   maintains 50 keep-alive connections and issues requests
   serially on each (one in flight per connection at a time).
   wrk2 supports HTTP pipelining via a Lua hook (`wrk.pipelining`)
   but our scripts don't enable it.
4. After `-d` seconds, wrk2 prints the HdrHistogram. The script
   parses both blocks: "Recorded Latency" (CO-corrected) and
   "Uncorrected Latency" (what a closed-loop tool would have
   reported, for direct comparison).
5. The script kills the standalone listener, repeats for each
   (server, scenario, rate) combination, and writes the matrix
   to `docs/wrk2_results.md`.

### Rate selection

For each (scenario, server) pair, the script sweeps four rates:
50 %, 75 %, 90 %, 95 % of the peak measured by `bench.escript`
(read from `bench_results.md`). The 90 % point usually sits
around the elbow; 95 % usually saturates. The achieved-rate
column in the report flags rows where actual / target < 0.99.

### Latency aggregation — HdrHistogram with CO correction

wrk2 records every individual request's latency into an
HdrHistogram (a sparse-bucketed lock-free histogram designed by
Gil Tene). With CO correction enabled, when wrk2 schedules a
request at time `T` and the server doesn't respond until
`T + Δ`, wrk2 backfills synthetic samples for all the requests
that *would have been issued* during the gap, with their
latencies extrapolated to `T_end - T_scheduled` (not
`T_end - T_actually_sent`).

The result is what the customer would have observed if they were
hammering the server at that rate from outside, instead of being
politely throttled by the loadgen waiting on the previous
response.

### Can wrk2 be the bottleneck?

In principle, yes — wrk2 is C event-loop code at ~50 connections
per thread, and at very high target rates (millions of req/s) on
small responses you can run out of CPU on the wrk2 side too. In
practice, for our matrix (peak < 300 k req/s, `-t 8 -c 50`) it
isn't close. wrk2 was designed for this kind of measurement; the
Docker overhead is ~1 % at our throughput levels.

If you're benchmarking a server that pushes >1 M req/s, scale
`-t` and `-c` up and watch for `Requests/sec` in wrk2's output
falling below `-R` even at low rates — that's the loader
saturating.

## Why both?

Closed-loop and open-loop measure different things. The closed-loop
bench answers **"what's the peak RPS each server reaches?"** —
useful for capacity planning, comparing servers at saturation, and
finding regressions. The open-loop bench answers **"what tail
latency does every issued request see at rate R?"** — useful for
SLA sizing and exposing tail-hiding effects.

`bench_results.md` and `wrk2_results.md` are complementary, not
substitutes. The peak in `bench_results.md` feeds the rate sweep in
`wrk2_results.md`; the tail in `wrk2_results.md` tells you how
close to that peak you can actually run in production.

## HttpArena-shape workloads

For profile-driven optimization against the
[HttpArena](https://github.com/MDA2AV/HttpArena) leaderboard, the
bench includes scenarios that mirror HttpArena profiles directly,
so improvements can be measured reproducibly inside this repo
rather than only via the external harness:

- `httparena_baseline`: `GET /baseline11?a=I&b=I` returns plaintext
  `A + B`. Mirrors HttpArena's `baseline` profile.
- `httparena_json`: `GET /httparena_json/50?m=1` returns a 50-item
  JSON list with `total = price * quantity * m`. The dataset is
  cached in `persistent_term` at module load. Mirrors HttpArena's
  `json` profile.
- `httparena_upload_20mb_auto` and `httparena_upload_20mb_manual`:
  `POST /upload` with a 20 MB body, under `body_buffering => auto`
  vs `body_buffering => manual` respectively. The handler returns
  the plaintext byte count. Mirrors HttpArena's `upload` profile;
  the pair is the in-tree reproduction of HttpArena's auto-mode
  memory peak on the 20 MB validator.

All four are roadrunner-only fixtures (no cowboy / elli parity
handler); the bench filters the other servers out at preflight.

Run with `--with-resources` to capture peak RSS / BEAM memory
alongside throughput:

```bash
./scripts/bench.escript --scenarios httparena_upload_20mb_auto \
    --with-resources --clients 8 --duration 5
./scripts/bench.escript --scenarios httparena_upload_20mb_manual \
    --with-resources --clients 8 --duration 5
```

For hot-path analysis, add `--profile --profile-tool eprof` (or
`fprof`).
