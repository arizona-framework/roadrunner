# Resource consumption results

Captured by `scripts/bench.escript --with-resources` on 2026-05-06
at `f43fe1b`.

**Hardware / runtime**

- CPU: 12th Gen Intel Core i9-12900HX (24 threads)
- Kernel: Linux 6.19.6 (Arch)
- OTP: 29 (erts 17.0, JIT)
- Loadgen: 50 clients, 2 s warmup + 5 s measure, loopback only
- Sampling: every 100 ms during the measure window; reports the
  PEAK observed RSS / BEAM `memory(total)` and the AVG CPU% over
  the window

`cpu%` is normalized to wall-clock — `1100 %` means the equivalent
of 11 cores fully busy on average. On this 24-thread machine the
ceiling is ~2400 %.

This is a **single-run snapshot** to compare resource shape across
servers; numbers will shift run-to-run by ~5–10 % on a loaded host.
Re-run the relevant scenarios when chasing a specific regression.
The scenario set mirrors the README's trimmed comparison tables;
for the full per-scenario throughput grid see
[`docs/bench_results.md`](bench_results.md).

## HTTP/1.1

| scenario | server | req/s | rss | beam | cpu% |
|---|---|---:|---:|---:|---:|
| `hello` | roadrunner | 296 k | 104 MB | 67 MB | 1069 % |
| `hello` | elli | 288 k | 110 MB | 51 MB | 1072 % |
| `hello` | cowboy | 188 k | 116 MB | 58 MB | 1263 % |
| `json` | elli | 280 k | 109 MB | 53 MB | 1099 % |
| `json` | roadrunner | 274 k | 115 MB | 64 MB | 1115 % |
| `json` | cowboy | 170 k | 107 MB | 55 MB | 1276 % |
| `echo` | elli | 241 k | 118 MB | 52 MB | 1085 % |
| `echo` | roadrunner | 231 k | 134 MB | 66 MB | 1154 % |
| `echo` | cowboy | 130 k | 118 MB | 54 MB | 1320 % |
| `large_response` | elli | 105 k | 96 MB | 50 MB | 850 % |
| `large_response` | roadrunner | 104 k | 98 MB | 62 MB | 842 % |
| `large_response` | cowboy | 81 k | 91 MB | 50 MB | 986 % |
| `headers_heavy` | roadrunner | 221 k | 148 MB | 77 MB | 1187 % |
| `headers_heavy` | elli | 221 k | 145 MB | 52 MB | 1184 % |
| `headers_heavy` | cowboy | 118 k | 131 MB | 61 MB | 1458 % |
| `cookies_heavy` | roadrunner | 245 k | 129 MB | 68 MB | 1140 % |
| `cookies_heavy` | cowboy | 149 k | 112 MB | 56 MB | 1360 % |
| `cookies_heavy` | elli | — | — | — | — (no native cookie parser) |
| `pipelined_h1` | roadrunner | 482 k | 118 MB | 78 MB | 1121 % |
| `pipelined_h1` | cowboy | 322 k | 126 MB | 63 MB | 1363 % |
| `pipelined_h1` | elli | 4.9 k | 79 MB | 46 MB | 154 % (broken) |
| `varied_paths_router` | roadrunner | 242 k | 110 MB | 69 MB | 1132 % |
| `varied_paths_router` | cowboy | 150 k | 153 MB | 68 MB | 1306 % |
| `gzip_response` | roadrunner | 117 k | 213 MB | 90 MB | 1588 % |
| `gzip_response` | cowboy | 93 k | 188 MB | 63 MB | 1601 % |
| `websocket_msg_throughput` | roadrunner | 198 k | 153 MB | 71 MB | 919 % |
| `websocket_msg_throughput` | cowboy | 156 k | 103 MB | 52 MB | 1090 % |

## HTTP/2

| scenario | server | req/s | rss | beam | cpu% |
|---|---|---:|---:|---:|---:|
| `hello` | roadrunner | 159 k | 170 MB | 86 MB | 1248 % |
| `hello` | cowboy | 149 k | 183 MB | 89 MB | 1270 % |
| `json` | roadrunner | 152 k | 163 MB | 82 MB | 1250 % |
| `json` | cowboy | 137 k | 191 MB | 84 MB | 1362 % |
| `echo` | roadrunner | 146 k | 180 MB | 98 MB | 1262 % |
| `echo` | cowboy | 99 k | 167 MB | 70 MB | 1349 % |
| `headers_heavy` | roadrunner | 142 k | 183 MB | 95 MB | 1288 % |
| `headers_heavy` | cowboy | 81 k | 163 MB | 80 MB | 1647 % |
| `multi_stream_h2` | roadrunner | 325 k | 251 MB | 131 MB | 1382 % |
| `multi_stream_h2` | cowboy | 297 k | 270 MB | 113 MB | 1439 % |
| `tls_handshake_throughput` | cowboy | 2.9 k | 198 MB | 84 MB | 1214 % |
| `tls_handshake_throughput` | roadrunner | 2.4 k | 145 MB | 63 MB | 927 % |

## Patterns observed

### Where roadrunner WINS on resources

- **`pipelined_h1`**: roadrunner uses 6 % less RSS and 18 % less
  CPU than cowboy while beating it 1.5× on throughput.
- **`varied_paths_router`**: 28 % less RSS, 13 % less CPU than
  cowboy, with 1.6× more throughput.
- **`websocket_msg_throughput`**: 16 % less CPU than cowboy with
  1.27× more throughput (does pay 49 % more RSS for it — the
  per-frame buffer-and-validate machinery — but the CPU win is
  the headline).
- **`multi_stream_h2`** (h2): 7 % less RSS than cowboy with 9 %
  more throughput. The h2 hot path is more efficient end-to-end.
- **`tls_handshake_throughput`** (h2): roadrunner uses 27 % less
  RSS and 24 % less CPU than cowboy on this scenario, **but**
  cowboy still wins 22 % on throughput — the per-handshake
  serialization is the bottleneck, not resources.

### Where roadrunner pays a tax

- **BEAM heap is 15–60 % higher than elli** across most h1
  scenarios — the cost of the feature surface (telemetry ETS
  tables, drain group, request-id batching, persistent_term'd
  compiled patterns, slot atomics). The biggest gap is
  `headers_heavy` at +48 % BEAM (77 MB vs 52 MB) where the
  per-request decision cache + telemetry metadata accumulate
  more state per conn. Consistent across runs; not a
  regression target.
- **`gzip_response` RSS**: roadrunner at 213 MB vs cowboy 188 MB
  (+13 %) for the +27 % throughput it delivers. zlib z-streams
  per conn aren't free; this is the price of native gzip
  middleware vs cowboy's "you wire your own" approach.
- **`echo` and h2 `echo`**: ~14 % more RSS than elli/cowboy. The
  body-state machinery for read-body is allocated even when the
  handler reads in one shot — known sub-optimal for
  small-body POSTs (tracked in `docs/roadmap.md`).

### Resource ties

- **`hello`, `large_response`, `headers_heavy`** vs elli: all
  three sit within 5 % on RSS and CPU. The per-scenario CPU
  efficiency (req/s ÷ cpu%) is essentially identical to elli.

## Reading the numbers honestly

- Single-run snapshot. Run-to-run variance on RSS / CPU is in
  the 5–10 % range on a loaded host; treat anything inside that
  band as noise.
- Loopback only — real-network deployments push more time into
  the kernel TCP path, which doesn't show up here.
- Max-throughput shape: every server is pegged to its own CPU
  ceiling. The CPU% comparison answers "how much CPU does each
  server burn to do its best?" — not "how much does each need to
  serve N req/s?". For a fixed-rate comparison the bench would
  need an open-loop driver (out of scope today).
- BEAM `memory(total)` excludes some allocator carrier waste; the
  OS-level RSS captures it. `rss > beam` is normal.
- The doc is checked into the repo as a point-in-time snapshot;
  re-run when investigating a specific regression rather than
  treating these numbers as the ongoing baseline.

## Reproducing

Single scenario:

```
mise exec -- ./scripts/bench.escript --servers roadrunner,elli,cowboy \
  --scenarios hello --clients 50 --duration 5 --warmup 2 --with-resources
```

To regenerate this whole doc with fresh numbers, loop the kept
scenarios above with `--with-resources` and update the table.
Automating it via `scripts/bench_matrix.sh --with-resources` is on
the roadmap (`docs/roadmap.md`) but not yet implemented.

## Cross-references

- Throughput-only comparison with full p50 / p99 across all
  scenarios: [`docs/bench_results.md`](bench_results.md).
- Connection-process model trade-offs:
  [`docs/conn_lifecycle_investigation.md`](https://github.com/arizona-framework/roadrunner/blob/main/docs/conn_lifecycle_investigation.md).
- Tracked deferred work (including the small-body-POST
  resource investigation): [`docs/roadmap.md`](roadmap.md).
