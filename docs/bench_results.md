# Benchmark results

Captured by `scripts/bench_matrix.sh` on 2026-05-20 at `1e8be80`.

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
| `hello` | 307 k | 201 k | 299 k | 112 µs / 1.4 ms |
| `json` | 299 k | 189 k | 304 k | 112 µs / 1.5 ms |
| `echo` | 304 k | 162 k | 282 k | 116 µs / 1.2 ms |
| `headers_heavy` | 257 k | 141 k | 253 k | 134 µs / 1.8 ms |
| `large_response` | 124 k | 98 k | 123 k | 310 µs / 2.7 ms |
| `multi_request_body` | 262 k | 125 k | 274 k | 134 µs / 1.5 ms |
| `varied_paths_router` | 290 k | 175 k | — | 118 µs / 1.5 ms |
| `post_4kb_form` | 193 k | 98 k | — | 199 µs / 1.5 ms |
| `large_post_streaming` | 20 k | 6.9 k | — | 2.5 ms / 5.7 ms |
| `pipelined_h1` | 580 k | 371 k | 4.8 k | 68 µs / 615 µs |
| `websocket_msg_throughput` | 232 k | 179 k | — | 149 µs / 2.0 ms |
| `gzip_response` | 138 k | 111 k | — | 286 µs / 2.2 ms |

## HTTP/2

| scenario | roadrunner | cowboy | elli | rr p50 / p99 |
|---|---:|---:|---:|---:|
| `hello` | 167 k | 163 k | — | 219 µs / 2.5 ms |
| `json` | 168 k | 153 k | — | 226 µs / 2.3 ms |
| `echo` | 164 k | 112 k | — | 235 µs / 2.2 ms |
| `headers_heavy` | 161 k | 90 k | — | 236 µs / 2.5 ms |
| `multi_request_body` | 140 k | 28 k | — | 279 µs / 2.4 ms |
| `multi_stream_h2` | 351 k | 335 k | — | 125 µs / 374 µs |
| `streaming_response` | 62 k | 61 k | — | 640 µs / 4.1 ms |

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
