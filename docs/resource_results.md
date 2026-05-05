# Resource consumption results

Captured by `scripts/bench.escript --with-resources` on 2026-05-05
at `9bd80f5`.

**Hardware / runtime**

- CPU: 12th Gen Intel Core i9-12900HX (24 threads)
- Kernel: Linux 6.19.6 (Arch)
- OTP: 29 (erts 17.0, JIT)
- Loadgen: 50 clients, 2 s warmup + 3 s measure, loopback only
- Sampling: every 100 ms during the measure window; reports the
  PEAK observed RSS / BEAM `memory(total)` and the AVG CPU% over
  the window

`cpu%` is normalized to wall-clock — `1100 %` means the equivalent
of 11 cores fully busy on average. On this 24-thread machine the
ceiling is ~2400 %.

This is a **single-run snapshot** to compare resource shape across
servers; numbers will shift run-to-run by ~5–10 % on a loaded host.
Re-run the relevant scenarios when chasing a specific regression.

## HTTP/1.1

| scenario | server | req/s | rss | beam | cpu% |
|---|---|---:|---:|---:|---:|
| `hello` | elli | 267 k | 110 MB | 50 MB | 1066 % |
| `hello` | roadrunner | 265 k | 121 MB | 55 MB | 1116 % |
| `hello` | cowboy | 183 k | 107 MB | 53 MB | 1276 % |
| `echo` | elli | 236 k | 120 MB | 51 MB | 1102 % |
| `echo` | roadrunner | 212 k | **137 MB** | 57 MB | 1263 % |
| `echo` | cowboy | 131 k | 117 MB | 56 MB | 1341 % |
| `large_response` | elli | 101 k | 99 MB | 47 MB | 817 % |
| `large_response` | roadrunner | 96 k | 105 MB | 51 MB | 885 % |
| `large_response` | cowboy | 81 k | 94 MB | 49 MB | 1005 % |
| `pipelined_h1` | roadrunner | 405 k | 106 MB | 56 MB | 1269 % |
| `pipelined_h1` | cowboy | 319 k | 130 MB | 64 MB | 1428 % |
| `pipelined_h1` | elli | 4.9 k | 82 MB | 47 MB | 164 % (broken)|
| `post_4kb_form` | roadrunner | 108 k | **240 MB** | 70 MB | 1550 % |
| `post_4kb_form` | cowboy | 85 k | 159 MB | 72 MB | 1632 % |
| `large_post_streaming` | roadrunner | 14 k | **199 MB** | 83 MB | 1453 % |
| `large_post_streaming` | cowboy | 6.4 k | 783 MB | 579 MB | 965 % |
| `websocket_msg_throughput` | roadrunner | 189 k | 119 MB | 53 MB | 914 % |
| `websocket_msg_throughput` | cowboy | 154 k | 107 MB | 52 MB | 1057 % |
| `large_keepalive_session` | elli | 256 k | 109 MB | 49 MB | 1036 % |
| `large_keepalive_session` | roadrunner | 224 k | 108 MB | 51 MB | 1167 % |
| `large_keepalive_session` | cowboy | 172 k | 104 MB | 51 MB | 1223 % |
| `connection_storm` | elli | 53 k | 81 MB | 46 MB | 535 % |
| `connection_storm` | cowboy | 45 k | 93 MB | 49 MB | 931 % |
| `connection_storm` | roadrunner | 39 k | 92 MB | 48 MB | 681 % |
| `router_404_storm` | elli | 52 k | 80 MB | 47 MB | 519 % |
| `router_404_storm` | roadrunner | 50 k | 96 MB | 48 MB | 719 % |
| `router_404_storm` | cowboy | 45 k | 88 MB | 48 MB | 863 % |

## HTTP/2

| scenario | server | req/s | rss | beam | cpu% |
|---|---|---:|---:|---:|---:|
| `streaming_response` | roadrunner | 55 k | 216 MB | 103 MB | 1199 % |
| `streaming_response` | cowboy | 53 k | 248 MB | 100 MB | 1227 % |
| `multi_stream_h2` | roadrunner | 322 k | 240 MB | 139 MB | 1399 % |
| `multi_stream_h2` | cowboy | 312 k | 266 MB | 118 MB | 1467 % |

## Patterns observed

### Where roadrunner consumes more

- **Small-body POST scenarios are the standout**:
  `post_4kb_form` shows roadrunner at 240 MB RSS vs cowboy's
  159 MB — a **+51 % gap**. `echo` (256-byte body) shows
  +17 %. The likely cause is the per-request `body_state`
  machinery + manual-mode reader being allocated even for
  auto-mode small-body workloads. **This is the most actionable
  finding** — see `docs/roadmap.md` for tracking.
- **Hot-path GETs** (`hello`, `large_response`, `large_keepalive_session`):
  roadrunner sits 5–15 % above elli on RSS — the cost of the
  feature surface (telemetry, drain group, slot atomics, label
  observability). Trade-off, not a regression target.
- **Connection-storm shapes** (`connection_storm`, `router_404_storm`):
  ~20 % more RSS + ~30 % more CPU than elli. Already documented
  in `docs/conn_lifecycle_investigation.md` as the
  per-conn-process cost vs elli's accept-and-handle-in-one-process
  model.

### Where roadrunner WINS on resources

- **`large_post_streaming` (h1)**: roadrunner uses 199 MB while
  cowboy uses **783 MB** (4× advantage) AND ships 2.2× more
  req/s. The iolist-based body reader (`fill_n` / `fill_iolist`)
  flat-out beats cowboy's buffered allocator path on big uploads.
- **`pipelined_h1`**: roadrunner uses 18 % less RSS and 11 %
  less CPU than cowboy while beating it 1.27× on throughput.
- **`streaming_response` (h2) / `multi_stream_h2` (h2)**:
  roadrunner uses 10–13 % less RSS than cowboy on the hot h2
  paths.
- **`websocket_msg_throughput`**: 11 % more RSS than cowboy but
  **14 % less CPU**, with 23 % more throughput.

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
mise exec -- ./scripts/bench.escript --scenario post_4kb_form \
  --duration 5 --warmup 2 --with-resources
```

To regenerate this whole doc with fresh numbers, run each row's
scenario above with `--with-resources` and update the table.
Automating it via `scripts/bench_matrix.sh --with-resources` is on
the roadmap (`docs/roadmap.md`) but not yet implemented.

## Cross-references

- Throughput-only comparison with full p50 / p99 across all
  scenarios: [`docs/bench_results.md`](bench_results.md).
- Connection-process model trade-offs (the connection-storm gap
  noted above): [`docs/conn_lifecycle_investigation.md`](conn_lifecycle_investigation.md).
- Tracked deferred work (including the `body_state`/`echo`/
  `post_4kb_form` resource investigation):
  [`docs/roadmap.md`](roadmap.md).
