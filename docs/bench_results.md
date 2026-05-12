# Benchmark results

> ⚠️ **Out of date.** The full matrix below is from 2026-05-05
> (SHA `020b440`) and has NOT been re-run after the
> `feat/http-arena` branch's perf rounds (concat fix, iodata body,
> h2 lowercase contract). Several scenarios moved by 5-20 % on
> roadrunner since this matrix was captured.
>
> For up-to-date side-by-side numbers on the representative
> scenarios, see [`comparison.md`](comparison.md). Re-run the full
> matrix locally with `./scripts/bench_matrix.sh` (~25-40 min) to
> refresh this file end-to-end.

Captured by `scripts/bench_matrix.sh` on 2026-05-05 at `020b440`.

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
| `hello` | 254 k | 181 k | 272 k | 135 µs / 1.8 ms |
| `json` | 255 k | 178 k | 270 k | 135 µs / 1.6 ms |
| `echo` | 225 k | 146 k | 269 k | 157 µs / 1.8 ms |
| `headers_heavy` | 210 k | 125 k | 240 k | 180 µs / 1.6 ms |
| `large_response` | 103 k | 90 k | 114 k | 373 µs / 3.1 ms |
| `url_with_qs` | 247 k | 167 k | — | 148 µs / 1.4 ms |
| `varied_paths_router` | 239 k | 168 k | — | 151 µs / 1.5 ms |
| `path_with_unicode` | 235 k | 167 k | — | 159 µs / 1.3 ms |
| `router_404_storm` | 51 k | 43 k | 50 k | 890 µs / 2.5 ms |
| `cors_preflight` | 242 k | 162 k | — | 153 µs / 1.3 ms |
| `redirect_response` | 258 k | 176 k | — | 133 µs / 1.7 ms |
| `head_method` | 251 k | 176 k | — | 139 µs / 1.7 ms |
| `post_4kb_form` | 122 k | 92 k | — | 344 µs / 2.2 ms |
| `chunked_request_body` | 210 k | 129 k | — | 177 µs / 1.5 ms |
| `compressed_request_body` | 233 k | 149 k | 278 k | 154 µs / 1.6 ms |
| `multi_request_body` | 225 k | 111 k | 245 k | 160 µs / 1.6 ms |
| `expect_100_continue` | 130 k | 94 k | — | 294 µs / 2.8 ms |
| `large_post_streaming` | 15 k | 6.6 k | — | 3.4 ms / 7.2 ms |
| `cookies_heavy` | 234 k | 160 k | — | 153 µs / 1.6 ms |
| `etag_304` | 234 k | 169 k | — | 149 µs / 1.8 ms |
| `mixed_workload` | 169 k | 133 k | 177 k | 223 µs / 2.1 ms |
| `pipelined_h1` | 426 k | 331 k | 4.9 k | 97 µs / 730 µs |
| `large_keepalive_session` | 227 k | 175 k | 279 k | 152 µs / 2.0 ms |
| `connection_storm` | 46 k | 46 k | 55 k | 956 µs / 3.2 ms |
| `slow_client` | 6.2 k | 6.2 k | 6.2 k | 8.0 ms / 8.3 ms |
| `accept_storm_burst` | 28 k | 31 k | 35 k | 1.3 ms / 1.6 ms |
| `partial_body_drop` | 17 k | 16 k | — | 1.9 ms / 11.9 ms |
| `server_sent_events` | 11 k | 10.0 k | — | 4.2 ms / 9.5 ms |
| `gzip_response` | 105 k | 96 k | — | 387 µs / 2.5 ms |
| `backpressure_sustained` | 249 k | 182 k | — | 139 µs / 1.8 ms |
| `websocket_msg_throughput` | 214 k | 168 k | — | 167 µs / 2.0 ms |

## HTTP/2

| scenario | roadrunner | cowboy | elli | rr p50 / p99 |
|---|---:|---:|---:|---:|
| `hello` | 158 k | 154 k | — | 233 µs / 2.6 ms |
| `json` | 155 k | 138 k | — | 247 µs / 2.5 ms |
| `echo` | 151 k | 101 k | — | 257 µs / 2.3 ms |
| `headers_heavy` | 146 k | 82 k | — | 260 µs / 2.6 ms |
| `multi_request_body` | 129 k | 29 k | — | 305 µs / 2.5 ms |
| `cookies_heavy` | 153 k | 136 k | — | 253 µs / 2.3 ms |
| `streaming_response` | 57 k | 56 k | — | 694 µs / 4.1 ms |
| `multi_stream_h2` | 330 k | 314 k | — | 133 µs / 397 µs |
| `small_chunked_response` | 4.7 k | 4.9 k | — | 10.0 ms / 20.4 ms |
| `tls_handshake_throughput` | 2.5 k | 3.0 k | — | 20.2 ms / 24.9 ms |

## Notes / known gaps

- `large_response` / `head_method` are listed h1-only here.
  Their h2 cells errored on 64 KB single-stream responses
  against both servers — a flow-control interaction in the
  test client, not a server-side bug.
- `pipelined_h1` elli: elli's keep-alive path doesn't
  pipeline; the 4.9 k req/s reflects per-request RTT,
  not pipelining.
- `tls_handshake_throughput` h2: cowboy edges roadrunner
  here. See
  [`docs/conn_lifecycle_investigation.md`](https://github.com/arizona-framework/roadrunner/blob/main/docs/conn_lifecycle_investigation.md)
  Round 3 for the prior null-result investigation.

## Reading the numbers honestly

- Throughput deltas under ~15 % are inside run-to-run
  variance on a loaded dev box. The bench's banner reminds
  on every run.
- p50 / p99 are usually steadier than throughput run-to-run.
- Loopback hides NIC + kernel TCP cost. For a public
  comparison run against a remote host with `--clients`
  tuned to your CPU count.
