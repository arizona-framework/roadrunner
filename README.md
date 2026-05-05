# roadrunner

A modern, pure-Erlang HTTP/1.1 + HTTP/2 + WebSocket server for OTP 28+.

Built ground-up via TDD as a Cowboy alternative for the
[arizona-framework](https://github.com/arizona-framework/arizona). Targets a
small public surface, RFC-correct parsing, and modern OTP idioms throughout.

## Status

POC — not yet deployed in production. Eunit + CT (incl. PropEr)
tests with 100% line coverage, dialyzer-clean.

Standards conformance:

- **HTTP/1.1**: RFC 9110 (semantics) + RFC 9112 (syntax).
- **HTTP/2**: RFC 9113 (frames + multiplexing) + RFC 7541 (HPACK)
  — opt-in per listener via `http2_enabled => true` in TLS opts;
  passes [h2spec](https://github.com/summerwind/h2spec) at 100 %
  in both default (146/146) and strict (`-S`, 147/147) modes
  (`scripts/h2spec.sh`).
- **Content-Encoding** (RFC 9110 §8.4.1): gzip + deflate, with
  qvalue-aware `Accept-Encoding` negotiation (RFC 9110 §12.5.3).
  Works unchanged over HTTP/2.
- **WebSocket**: RFC 6455 — passes the
  [Autobahn|Testsuite](https://github.com/crossbario/autobahn-testsuite)
  fuzzingclient at strict 100 % (`scripts/autobahn.escript`).
- **WebSocket compression**: RFC 7692 `permessage-deflate`,
  including `*_max_window_bits` and `*_no_context_takeover`.

The per-connection request lifecycle is a tail-recursive `proc_lib`
loop (`roadrunner_conn_loop`) with named phases (`awaiting_shoot |
reading_request | reading_body | dispatching | finishing`)
reflected in `proc_lib:get_label/1` so the lifecycle shows up in
observer's process inspector and `recon:proc_count/2`.

The HTTP/2 path takes over after the TLS ALPN handshake settles
on `h2`; it shares the same handler / middleware / router / drain
/ telemetry surface as the HTTP/1.1 path. Each request stream
runs in its own `spawn_monitor`-spawned worker so a handler crash
resets only the affected stream (`RST_STREAM(INTERNAL_ERROR)`)
and leaves the other streams on the connection running.
`SETTINGS_MAX_CONCURRENT_STREAMS = 100` is advertised; flow
control honors `WINDOW_UPDATE` and `SETTINGS_INITIAL_WINDOW_SIZE`
shifts. See `src/roadrunner_conn_loop_http2.erl` for the conn
state machine and `src/roadrunner_http2_stream_worker.erl` for
the worker dispatch contract.

## Quickstart

```erlang
%% rebar.config
{deps, [
    {roadrunner, {git, "https://github.com/arizona-framework/roadrunner.git", {branch, "main"}}}
]}.
```

```erlang
%% A handler
-module(hello_handler).
-behaviour(roadrunner_handler).
-export([handle/1]).

handle(Req) ->
    {roadrunner_resp:text(200, ~"hello, roadrunner!"), Req}.
```

```erlang
%% Boot a listener
1> application:ensure_all_started(roadrunner).
2> roadrunner:start_listener(http, #{
       port => 8080,
       routes => [{~"/", hello_handler, undefined}]
   }).
```

```
$ curl -i localhost:8080
HTTP/1.1 200 OK
content-type: text/plain; charset=utf-8
content-length: 14

hello, roadrunner!
```

To enable HTTP/2 over TLS:

```erlang
3> roadrunner:start_listener(https, #{
       port => 8443,
       tls => [{certfile, "cert.pem"}, {keyfile, "key.pem"}],
       http2_enabled => true,
       routes => [{~"/", hello_handler, undefined}]
   }).
```

```
$ curl -i --http2 https://localhost:8443/
HTTP/2 200
content-type: text/plain; charset=utf-8
content-length: 14

hello, roadrunner!
```

ALPN negotiation routes `h2` clients to the HTTP/2 path and
`http/1.1` clients (or no-ALPN) to the HTTP/1.1 path on the same
listener.

## Features

### Handlers

- **Buffered responses:** `{Status, Headers, Body}` — `roadrunner_resp:text/2`,
  `:html/2`, `:json/2`, `:redirect/2`, plus empty-status shortcuts.
- **Streaming:** `{stream, Status, Headers, Fun}` — chunked transfer with a
  `Send/2` callback; supports trailer headers per RFC 7230 §4.1.2.
- **Loop / SSE:** `{loop, Status, Headers, State}` + optional
  `handle_info/3` callback for message-driven push (cowboy_loop equivalent).
- **WebSocket:** `{websocket, Module, State}` upgrade with
  `roadrunner_ws_handler` callback.
- **Sendfile:** `{sendfile, Status, Headers, {Filename, Offset, Length}}` —
  zero-copy file body via `file:sendfile/5` (TCP) or chunked `ssl:send`
  fallback (TLS).

### Routing

- `roadrunner_router` with literal / `:param` / `*wildcard` segments.
- 3-tuple route shape `{Path, Handler, Opts}` — opts thread to the handler.
- Routes published to `persistent_term` for O(1) lookup;
  `roadrunner_listener:reload_routes/2` swaps the table without restart.

### Middleware

- Continuation-style `(Req, Next) -> {Response, Req2}` — listener-level +
  per-route, first-in-list = outermost.

### Built-in handlers

- `roadrunner_static` for file serving with ETag, `If-None-Match`, `Range`,
  `Last-Modified`, `If-Modified-Since`, and configurable symlink policy
  (`refuse_escapes` default).

### Hardening

- RFC 7230 / RFC 9112 strict parsing — request smuggling defenses
  (CL+TE conflict, multiple-CL), header CRLF/NUL injection rejection,
  chunk-size leading-whitespace rejection, RFC 6265 cookie OWS handling,
  RFC 6455 §5.5 control-frame limits, SSE event-line CRLF rejection,
  trailer header CRLF injection rejection, sendfile path traversal +
  symlink escape defenses.
- TLS hardened defaults — TLS 1.2/1.3 only, `honor_cipher_order`,
  `client_renegotiation` off, AEAD-only ECDHE-or-1.3 ciphers filtered
  through `ssl:filter_cipher_suites/2`, `x25519mlkem768` PQ hybrid first,
  `early_data` disabled.
- DoS bounds — `max_clients`, `max_content_length`,
  `minimum_bytes_per_second`, `request_timeout`, `keep_alive_timeout`,
  `max_keep_alive_request`.

### Observability

- `telemetry` events: `[roadrunner, request, start | stop | exception |
  rejected]`, `[roadrunner, response, send_failed]`, `[roadrunner, listener,
  accept | conn_close | slots_reconciled]`, `[roadrunner, ws, upgrade |
  frame_in | frame_out]`, `[roadrunner, drain, acknowledged]` (opt-in via
  `roadrunner:acknowledge_drain/1` from a `{loop, ...}` / WebSocket
  handler that pattern-matches `{roadrunner_drain, _}`).
- Per-request `request_id` attached to `logger:set_process_metadata/1`
  so any `?LOG_*` call from middleware/handlers is auto-correlated.
- `roadrunner_listener:info/1` for pull-side `active_clients` /
  `requests_served` metrics.
- `proc_lib:set_label/1` per-listener / per-acceptor / per-conn for
  legible `observer` process trees.

### Lifecycle

- `roadrunner_listener:drain/2` — graceful shutdown with timeout. Closes the
  listen socket immediately, broadcasts `{roadrunner_drain, Deadline}` to
  in-flight conns via `pg`, polls `active_clients` until zero or
  deadline, then `exit(Pid, shutdown)` for stragglers.
- `roadrunner_listener:status/1` — `accepting | draining`.
- Optional `slot_reconciliation => #{interval_ms => N}` listener
  opt — periodic reaper compares `client_counter` vs the conn pg
  group and releases slots orphaned by `kill`-style exits (which
  bypass `terminate/3`). Off by default; enable for chaos-tested
  deployments.

### Property + conformance tests

PropEr properties via OTP `ct_property_test`: `roadrunner_uri`
percent round-trip + encode shape, `roadrunner_qs` round-trip,
`roadrunner_cookie` adversarial robustness, `roadrunner_http1`
parsers never-crash + incremental-feed equivalence, plus
`roadrunner_conn_loop` robustness over random recv/drain/stray
inputs (clean exit + slot release) and `request_id` consistency
between `request_start` / `request_stop` telemetry.

`roadrunner_http1_corpus_tests` runs HTTP/1.1 malformed-input
patterns lifted from the [llhttp](https://github.com/nodejs/llhttp)
test corpus (the parser used by Node.js / undici) and the
canonical request-smuggling vectors documented by Portswigger —
the same coverage that goes into protecting other production
HTTP/1.x servers in the wild.

WebSocket conformance lives in `test/autobahn/`. Run
`./scripts/autobahn.escript` (requires Docker) to drive the full
[Autobahn|Testsuite](https://github.com/crossbario/autobahn-testsuite)
fuzzingclient against a roadrunner echo listener; the harness
prints a pass/fail summary and the HTML report path. Roadrunner
passes 100 % strict on the **full suite** with zero exclusions —
every category from basic framing through fragmentation, UTF-8,
close handling, oversize control frames, large-payload performance
(9.x), and the full `permessage-deflate` matrix (12.x + 13.x).
Three cases (7.1.6, 7.13.1, 7.13.2) are reported as `INFORMATIONAL`
rather than `OK` — Autobahn's category for cases the spec leaves
genuinely implementation-defined (close-during-write under
async-only models; out-of-range close codes 5000 / 65535). Their
own descriptions read *"Actual events are undefined by the spec."*

HTTP/1.1 response hygiene is audited via
[REDbot](https://redbot.org). Run `./scripts/redbot.escript`
(requires Docker) to probe a representative set of routes
(plain, JSON, cached, ETag, Last-Modified, conditional-GET,
gzip-eligible) and capture per-route reports under
`test/redbot/reports/`. See `test/redbot/README.md` for what's
covered and what kinds of findings count as framework gaps vs
handler-level choices.

HTTP/2 conformance lives in `scripts/h2spec.sh`. The script
boots a roadrunner h2 listener with a throwaway TLS cert and
drives [h2spec](https://github.com/summerwind/h2spec) (Docker
image `summerwind/h2spec`) against it. Roadrunner passes
**146/146 in default mode and 147/147 in strict (`-S`) mode**
across the generic HTTP/2 conformance, RFC 9113 frame
definitions, and HPACK (RFC 7541) test categories — including
stream-state transitions, flow control, settings validation,
content-length consistency, request trailers, padding rules,
and the full HPACK decoding-error matrix.

## Comparison with cowboy and elli

`scripts/bench.escript` runs the same loadgen against each server in
its own peer BEAM. `scripts/bench_matrix.sh` drives all 35 scenarios
across both protocols and writes the consolidated tables that ship
in [`docs/bench_results.md`](docs/bench_results.md) (raw CSV at
[`docs/bench_results.csv`](docs/bench_results.csv)). Numbers below
are the median of 3 runs at 50 concurrent clients on a single Linux
dev box, loopback. Re-run locally to see what your hardware shows;
absolute numbers shift, relative ordering tends to hold.

> **TL;DR.** Roadrunner beats cowboy on most common scenarios by
> +30–50 % req/s with proportionally lower p50 / p99. The
> exceptions are connection-storm-shape scenarios (open-conn /
> close-conn dominates) and two h2-specific cases — those tie or
> slightly lose. Vs elli, roadrunner is within ~15 % on simple
> GETs (elli's minimal surface still wins the cleanest hot path)
> and beats elli outright wherever the workload needs a feature
> elli doesn't ship — pipelining, gzip, body streaming, h2,
> WebSocket, router, native qs/cookie parsing, etag.

### Throughput — req/s, HTTP/1.1 (higher = better)

A representative cross-section. Full 35-scenario table including
HTTP/2 and per-server p50/p99 lives in
[`docs/bench_results.md`](docs/bench_results.md).

Bolded cells indicate the row's winner *and* a margin wider than
~15 % over the next-best (the bench's own variance band — see
"Reading the numbers honestly" below). Cells without bold are
inside variance and shouldn't be read as a win.

| scenario                  | roadrunner    | elli          | cowboy        |
|---------------------------|--------------:|--------------:|--------------:|
| `hello`                   |       254 k   |       272 k   |       181 k   |
| `json`                    |       255 k   |       270 k   |       178 k   |
| `echo`                    |       225 k   |    **269 k**  |       146 k   |
| `headers_heavy`           |       210 k   |       240 k   |       125 k   |
| `large_response`          |       103 k   |       114 k   |        90 k   |
| `url_with_qs`             |   **247 k**   |          —    |       167 k   |
| `varied_paths_router`     |   **239 k**   |          —    |       168 k   |
| `cors_preflight`          |   **242 k**   |          —    |       162 k   |
| `redirect_response`       |   **258 k**   |          —    |       176 k   |
| `chunked_request_body`    |   **210 k**   |          —    |       129 k   |
| `multi_request_body`      |       225 k   |       245 k   |       111 k   |
| `expect_100_continue`     |   **130 k**   |          —    |        94 k   |
| `large_post_streaming`    |  **14.6 k**   |          —    |       6.6 k   |
| `cookies_heavy`           |   **234 k**   |          —    |       160 k   |
| `etag_304`                |   **234 k**   |          —    |       169 k   |
| `gzip_response`           |       105 k   |          —    |        96 k   |
| `pipelined_h1`            |   **426 k**   |       4.9 k   |       331 k   |
| `large_keepalive_session` |       227 k   |    **279 k**  |       175 k   |
| `connection_storm`        |        46 k   |     **55 k**  |        46 k   |
| `accept_storm_burst`      |        28 k   |     **35 k**  |        31 k   |
| `websocket_msg_throughput`|   **214 k**   |          —    |       168 k   |
| `backpressure_sustained`  |   **249 k**   |          —    |       182 k   |

`—` means the elli test fixture doesn't support that scenario shape
(no h2, no WebSocket, no gzip middleware, no router, no native qs
parser, etc.). That's a real comparison point: if your workload
needs any of these, elli isn't on the table.

### Throughput — req/s, HTTP/2 (higher = better)

| scenario                   | roadrunner    | cowboy        |
|----------------------------|--------------:|--------------:|
| `hello`                    |       158 k   |       154 k   |
| `json`                     |       155 k   |       138 k   |
| `echo`                     |   **151 k**   |       101 k   |
| `headers_heavy`            |   **146 k**   |        82 k   |
| `multi_request_body`       |   **129 k**   |        29 k   |
| `streaming_response`       |        57 k   |        56 k   |
| `multi_stream_h2`          |       330 k   |       314 k   |
| `small_chunked_response`   |       4.7 k   |       4.9 k   |
| `tls_handshake_throughput` |       2.5 k   |     **3.0 k** |

Multi-stream and basic-req h2 line up with the h1 picture — large
wins on bigger headers/bodies, smaller wins on the simple paths. The
two cowboy wins (`small_chunked_response`, `tls_handshake_throughput`)
are documented honestly in
[`docs/conn_lifecycle_investigation.md`](docs/conn_lifecycle_investigation.md).

### Latency — p50 / p99 (lower = better)

p50 / p99 numbers per scenario × server are in the full results
file. Spot-checks from the same run:

| scenario               | rr p50 / p99    | elli p50 / p99   | cowboy p50 / p99 |
|------------------------|----------------:|-----------------:|-----------------:|
| `hello`                | 135 µs / 1.75 ms| 122 µs / 1.82 ms | 208 µs / 2.44 ms |
| `echo`                 | 157 µs / 1.77 ms| 129 µs / 1.57 ms | 269 µs / 2.44 ms |
| `cookies_heavy`        | 153 µs / 1.57 ms|         —        | 244 µs / 2.43 ms |
| `pipelined_h1`         |  97 µs / 0.73 ms| 10.3 ms / 10.6 ms| 127 µs / 0.82 ms |
| `large_post_streaming` | 3.4 ms / 7.18 ms|         —        | 6.0 ms / 30.0 ms |

### Reading the numbers honestly

- **vs cowboy: roadrunner wins on most scenarios** by 25–60 % on
  req/s with proportionally lower p50 / p99. The exceptions:
  `connection_storm` and `accept_storm_burst` are ties (within
  variance), and the h2 `small_chunked_response` /
  `tls_handshake_throughput` cells are roadrunner-loses
  (documented in
  [`docs/conn_lifecycle_investigation.md`](docs/conn_lifecycle_investigation.md)).
- **vs elli: a wash on simple hot-path GETs.** Elli's lack of
  telemetry, drain, hibernation, and slot tracking shows up as up
  to ~20 % more throughput on `hello` / `json` / `echo` /
  `headers_heavy` / `large_response` / `large_keepalive_session`.
  Add a router / cookie parse / gzip / pipeline / body stream /
  h2 / WebSocket and elli either falls behind or drops out (no
  support). Elli also still wins the connection-storm-shape
  scenarios where the per-conn process model dominates.
- **p99 is competitive but not dramatic.** Earlier README copy
  claimed "2.5–3.5× lower p99" — that was measured on a 3 s
  warmup + 3 s window where multi-millisecond outliers
  under-counted. With the 2 s + 5 s settings used here,
  roadrunner's p99 vs cowboy is typically 1.4–1.8× lower; vs elli
  it's within 10 %.
- **Cowboy trails on most axes here** because its dual-process
  pipeline (acceptor → connection → stream handlers) adds dispatch
  overhead the simpler servers don't pay. It optimizes for HTTP/2
  feature richness and supervisor-tree visibility — the
  trade-off shows on the bench.
- **Numbers shift on real hardware.** Loopback hides NIC + kernel
  TCP cost. For a public comparison run against a remote host with
  `--clients` tuned to your CPU count.

### Architectural trade-offs

|                                | roadrunner                       | elli                       | cowboy                        |
|--------------------------------|----------------------------------|----------------------------|-------------------------------|
| Per-conn process model         | tail-recursive `proc_lib` loop   | tail-recursive loop        | gen_server + stream handlers  |
| Request lifecycle observable   | yes (`proc_lib:get_label/1`)     | no                         | partial                       |
| Drain / graceful shutdown      | built-in (`pg`-broadcast)        | DIY                        | partial                       |
| Telemetry                      | `telemetry` library, 8 events    | none (handler callbacks)   | `cowboy_metrics_h` opt-in     |
| Middleware shape               | continuation-passing             | `pre_request`/`post_request` callback | deprecated `(Req, Env)`/stream handlers |
| Hibernation between requests   | `hibernate_after` works          | no                         | depends on stream handler     |
| Default recv mode              | passive (`gen_tcp:recv`)         | passive (`gen_tcp:recv`)   | active (`{active, once}`)     |
| HTTP RFCs                      | RFC 9110 + RFC 9112 + RFC 9113   | RFC 7230 era               | RFC 9110 + RFC 9112 + HTTP/2  |
| HTTP/2 (RFC 9113 + 7541)       | yes — h2spec 100 % strict        | no                         | yes                           |
| Content-Encoding               | gzip + deflate, qvalue-aware     | DIY                        | hooks for stream handlers     |
| WebSocket conformance          | Autobahn 100 % strict            | n/a                        | Autobahn-tested               |
| permessage-deflate (RFC 7692)  | yes                              | n/a                        | yes                           |
| Production maturity            | POC                              | 10+ years, stable          | 10+ years, stable             |
| Public API surface             | small                            | small                      | large (HTTP/2, gun, etc.)     |
| Runtime deps                   | `telemetry` only                 | none                       | `cowlib`, `ranch`             |

### How to reproduce

Single scenario:

```
mise exec -- ./scripts/bench.escript --servers roadrunner,elli,cowboy \
  --scenario hello --clients 50 --duration 5 --warmup 2
```

Run several times and take the median — the bench script's banner
warns that single runs sit inside a ±15 % variance band on a
loaded dev box. `scripts/bench.escript` also accepts `--profile`
to dump an eprof or fprof hotspot table.

Full matrix (all 35 scenarios × {h1, h2}, medians of 3 runs,
regenerates `docs/bench_results.{md,csv}`):

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

### Picking a server

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
  the throughput / p99 numbers above (and the POC status — see
  "Status" above).

## Design philosophy

- **Small surface, RFC-correct.** Parsers are pure incremental binary
  matchers; only programmer errors raise, wire input becomes
  `{error, _}`. Hostile input is bounded before reaching application code.
- **Modern OTP idioms.** Sigils for binary literals, body recursion (cons
  on the way out), binary keys for wire-derived data, `-doc`/`-moduledoc`
  markdown, dialyzer-clean specs. No `binary_to_atom` on parsed names.
- **Continuation-style middleware** over Plug.Conn-style transformation
  — strictly more expressive than cowboy 2.13's deprecated `(Req, Env)`
  shape and dramatically simpler than cowboy's stream handlers.
- **Telemetry over custom callbacks.** `telemetry` is the de facto
  standard (Phoenix, Ecto, gleam_otp), zero-overhead when no
  subscribers, integrates with prometheus/opentelemetry/datadog out of
  the box.
- **No external deps unless stdlib genuinely can't.** Only runtime dep
  is `telemetry` (tiny, no transitive deps); only dev-time dep is the
  `erlfmt` plugin.

## Build

```
mise exec -- rebar3 precommit
```

Runs fmt-check, compile, xref, dialyzer, eunit + ct with cover, and
fails if line coverage drops below 100%.

## License

Apache-2.0.
