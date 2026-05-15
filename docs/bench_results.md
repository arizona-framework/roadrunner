# Benchmark results

Captured by `scripts/bench_matrix.sh` on 2026-05-15 at `90fba12`.

**Hardware / runtime**

- CPU: 12th Gen Intel(R) Core(TM) i9-12900HX (24 threads)
- Kernel: Linux 6.19.6-arch1-1 x86_64
- OTP: 29
- Loadgen: 3 runs/cell × 5s measure (2s warmup), 50 clients, loopback
- Bench client: in-tree `roadrunner_bench_client` (h1 + h2)

Numbers are the **median** req/s across 3 runs. `p50 / p99`
shown is **roadrunner's** for that cell. Per-server p50 / p99
for cowboy and elli land in `/tmp/bench_results.csv` after a
matrix run if you need to diff alternative servers.

Re-run locally with:

```
./scripts/bench_matrix.sh
```

Override defaults via env: `RUNS=5 DURATION=10 ./scripts/bench_matrix.sh`.
Set `SKIP_BENCH=1` to regenerate the CSV / MD from the existing
`/tmp/bench_matrix.log` without re-running the bench.

## HTTP/1.1

| scenario | roadrunner | cowboy | elli | rr p50 / p99 |
|---|---:|---:|---:|---:|
| `hello` | 287 k | 189 k | 281 k | 115 µs / 1.7 ms |
| `json` | 290 k | 194 k | 316 k | 115 µs / 1.7 ms |
| `echo` | 284 k | 153 k | 294 k | 123 µs / 1.5 ms |
| `headers_heavy` | 254 k | 143 k | 249 k | 135 µs / 1.8 ms |
| `large_response` | 121 k | 95 k | 129 k | 315 µs / 3.0 ms |
| `multi_request_body` | 271 k | 120 k | 275 k | 129 µs / 1.5 ms |
| `varied_paths_router` | 292 k | 168 k | — | 119 µs / 1.4 ms |
| `post_4kb_form` | 174 k | 95 k | — | 220 µs / 1.8 ms |
| `large_post_streaming` | 19 k | 7.0 k | — | 2.5 ms / 5.9 ms |
| `pipelined_h1` | 572 k | 362 k | 4.8 k | 69 µs / 609 µs |
| `websocket_msg_throughput` | 231 k | 171 k | — | 153 µs / 1.9 ms |
| `gzip_response` | 137 k | 108 k | — | 287 µs / 2.2 ms |

## HTTP/2

| scenario | roadrunner | cowboy | elli | rr p50 / p99 |
|---|---:|---:|---:|---:|
| `hello` | 172 k | 166 k | — | 215 µs / 2.5 ms |
| `json` | 167 k | 151 k | — | 224 µs / 2.4 ms |
| `echo` | 163 k | 118 k | — | 237 µs / 2.1 ms |
| `headers_heavy` | 163 k | 89 k | — | 240 µs / 2.1 ms |
| `multi_request_body` | 138 k | 33 k | — | 285 µs / 2.5 ms |
| `multi_stream_h2` | 350 k | 339 k | — | 126 µs / 379 µs |
| `streaming_response` | 61 k | 60 k | — | 644 µs / 4.1 ms |

## Notes / known gaps

- `large_response` is listed h1-only here. The h2 cell
  errored on 64 KB single-stream responses against both
  servers, which is a flow-control interaction in the test
  client and not a server-side bug.
- `pipelined_h1` elli: elli's keep-alive path doesn't
  pipeline; the elli column reflects per-request RTT,
  not pipelining.
- `websocket_msg_throughput` is roadrunner + cowboy only;
  the elli fixture has no WebSocket support.
- The wider set of scenarios (connection-shape storms,
  TLS handshake throughput, the HttpArena fixtures, etc.)
  is runnable ad-hoc via `./scripts/bench.escript
  --scenarios <name>`. The headline matrix here mirrors
  `?MAIN_SCENARIOS` in scripts/bench.escript.

## Reading the numbers honestly

- Throughput deltas under ~15 % are inside run-to-run
  variance on a loaded dev box. The bench's banner reminds
  on every run.
- p50 / p99 are usually steadier than throughput run-to-run.
- Loopback hides NIC + kernel TCP cost. For a public
  comparison run against a remote host with `--clients`
  tuned to your CPU count.
