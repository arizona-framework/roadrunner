# Roadrunner

[![Erlang CI](https://github.com/arizona-framework/roadrunner/actions/workflows/erlang.yml/badge.svg?branch=main)](https://github.com/arizona-framework/roadrunner/actions/workflows/erlang.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/roadrunner.svg)](https://hex.pm/packages/roadrunner)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/roadrunner/)
[![License](https://img.shields.io/hexpm/l/roadrunner.svg)](https://github.com/arizona-framework/roadrunner/blob/main/LICENSE.md)

![roadrunner logo](https://raw.githubusercontent.com/arizona-framework/roadrunner/main/assets/logo.jpg)

Pure-Erlang HTTP/1.1 + HTTP/2 + HTTP/3 + WebSocket server for Erlang/OTP.
**Built for low tail latency at sustained load.** Beep beep.

Roadrunner is the HTTP backbone of the
[arizona-framework](https://github.com/arizona-framework/arizona), and works
standalone too. The API is small: a handler behaviour, request and response
accessors, listener controls, and opt-in helpers (cookies, query strings,
multipart, SSE, WebSocket).

## Why Roadrunner?

A small, fast HTTP core you can trust on the hot path.

- **Fast where it counts**: Tuned for low p50 and p99 under sustained load. See
  [Performance at a glance](#performance-at-a-glance).
- **Correct and hostile-input-safe**: Strict RFC 9110 / 9112 / 9113 parsing,
  100% h2spec and 100% Autobahn (no exclusions), and stress-tested against
  request-smuggling corpora. See [Conformance](#conformance).
- **Every HTTP version, one server**: HTTP/1.1, HTTP/2, HTTP/3 (experimental),
  and WebSocket served from one listener; browsers upgrade to h3 over the same
  port via `Alt-Svc`.
- **Pure Erlang, almost no dependencies**: Two runtime deps (`telemetry` and
  `quic`, the HTTP/3 transport), no C NIFs, and Roadrunner owns its own
  h1/h2/h3 codecs: easy to read and audit. `quic` only starts for HTTP/3, so
  h1/h2 deployments never load it.
- **Pleasant to build on**: Plain-Erlang request and response values, composable
  middleware, and opt-in helpers for cookies, query strings, multipart, SSE, and
  WebSocket.
- **Production lifecycle in the box**: Graceful drain with a deadline, telemetry
  events, per-request `request_id` log correlation, and configurable DoS bounds.

## Requirements

Requires **OTP 27+**.

## 🚧 Status

Roadrunner is in `0.x`. The core is functional and covered by tests,
but the API may change between minor versions. Pin an exact version
in your deps if you need stability across upgrades.

## Conformance

Strict 100% h2spec (HTTP/2) and Autobahn fuzzingclient across the full
WebSocket matrix (no exclusions). HTTP/1.1 parsers stress-tested against
the [llhttp](https://github.com/nodejs/llhttp) test corpus and the
canonical [PortSwigger](https://portswigger.net/web-security/request-smuggling)
request-smuggling vectors.

Standards conformance:

- **HTTP/1.1**: RFC 9110 (semantics) + RFC 9112 (syntax).
- **HTTP/2**: RFC 9113 (frames + multiplexing) + RFC 7541 (HPACK).
  Opt-in per listener via `protocols => [http1, http2]` (or
  `[http2]` for h2c prior-knowledge on plain TCP). Conformance
  harness: [`scripts/h2spec.sh`](https://github.com/arizona-framework/roadrunner/blob/main/scripts/h2spec.sh) (drives
  [h2spec](https://github.com/summerwind/h2spec)).
- **HTTP/3 (experimental)**: RFC 9114 over QUIC with QPACK (RFC 9204)
  static-table compression. Enable per listener via
  `protocols => [http3]` (requires `tls`; QUIC mandates TLS 1.3); it
  co-serves with h1/h2 on the same port number (TCP for h1/h2, UDP for
  h3) and advertises `Alt-Svc` so browsers upgrade. Built on the
  pure-Erlang [`quic`](https://github.com/benoitc/erlang_quic) transport
  (still 1.x), so treat HTTP/3 as experimental.
- **Content-Encoding (RFC 9110 §8.4.1)**: gzip + deflate with
  qvalue-aware `Accept-Encoding` negotiation (RFC 9110 §12.5.3),
  works unchanged over HTTP/2.
- **WebSocket**: RFC 6455. Conformance harness:
  [`scripts/autobahn.escript`](https://github.com/arizona-framework/roadrunner/blob/main/scripts/autobahn.escript) (drives the
  [Autobahn|Testsuite](https://github.com/crossbario/autobahn-testsuite)
  fuzzingclient).
- **WebSocket compression**: RFC 7692 `permessage-deflate`,
  including `*_max_window_bits` and `*_no_context_takeover`.

## Performance at a glance

Median req/s over HTTP/1.1 on a 12th-gen i9-12900HX, 50 clients,
2 s warmup + 5 s measure, loopback. HTTP/2 numbers, p50 / p99
percentiles, and memory shape sit in
[`docs/bench_results.md`](https://github.com/arizona-framework/roadrunner/blob/main/docs/bench_results.md)
and [`docs/comparison.md`](https://github.com/arizona-framework/roadrunner/blob/main/docs/comparison.md).

| scenario                  | roadrunner    | cowboy        | elli          |
|---------------------------|--------------:|--------------:|--------------:|
| `hello`                   |   **307 k**   |       201 k   |       299 k   |
| `json`                    |       299 k   |       189 k   |   **304 k**   |
| `echo`                    |   **304 k**   |       162 k   |       282 k   |
| `headers_heavy`           |   **257 k**   |       141 k   |       253 k   |
| `large_response`          |   **124 k**   |        98 k   |       123 k   |
| `multi_request_body`      |       262 k   |       125 k   |   **274 k**   |
| `varied_paths_router`     |   **290 k**   |       175 k   |          —    |
| `post_4kb_form`           |   **193 k**   |        98 k   |          —    |
| `large_post_streaming`    |    **20 k**   |       6.9 k   |          —    |
| `pipelined_h1`            |   **580 k**   |       371 k   |       4.8 k   |
| `websocket_msg_throughput`|   **232 k**   |       179 k   |          —    |
| `gzip_response`           |   **138 k**   |       111 k   |          —    |

Bold = fastest in row. `—` means that workload has no elli fixture. On
simple GETs and small POSTs Roadrunner and elli sit within the bench's
~15% variance band on those rows; the comparison doc has the full
methodology.

### Tail latency at sustained load

Open-loop, Coordinated-Omission-corrected (wrk2, `hello`, 8 threads,
50 connections, 3-run median): Roadrunner sustains **291 k req/s**
at p50 1.07 ms, p99 2.31 ms, p99.99 4.70 ms. Full per-scenario
matrix with all four rate-points per server in
[`docs/wrk2_results.md`](https://github.com/arizona-framework/roadrunner/blob/main/docs/wrk2_results.md).

The throughput numbers above are from `scripts/bench.escript`
(closed-loop); the comparison doc has the full methodology
breakdown.

## Comparison

If your workload needs a feature, the server has to ship it. `—`
means achievable in user code but no helper / option built in; `✗`
means out of scope for that server.

| feature                                   | roadrunner | cowboy | elli |
|-------------------------------------------|:----------:|:------:|:----:|
| HTTP/1.1                                  |     ✓      |   ✓    |  ✓   |
| HTTP/2 + HPACK                            |     ✓      |   ✓    |  ✗   |
| HTTP/3 (QUIC, experimental)               |     ✓      |   ✗    |  ✗   |
| WebSocket (RFC 6455)                      |     ✓      |   ✓    |  —   |
| permessage-deflate (RFC 7692)             |     ✓      |   ✓    |  ✗   |
| Native router                             |     ✓      |   ✓    |  ✗   |
| gzip / deflate response negotiation       |     ✓      |   ✓    |  —   |
| Streaming request bodies                  |     ✓      |   ✓    |  —   |
| Native qs / cookie / multipart            |     ✓      |   ✓    |  —   |
| Server-Sent Events helper                 |     ✓      |   —    |  —   |
| Sendfile                                  |     ✓      |   ✓    |  ✓   |
| Static handler (ETag / Range / IMS)       |     ✓      |   ✓    |  —   |
| Graceful drain with deadline + broadcast  |     ✓      |   —    |  ✗   |
| Per-request `request_id` in logger meta   |     ✓      |   —    |  ✗   |

## Quickstart

Add to `rebar.config` (latest version on
[Hex](https://hex.pm/packages/roadrunner)):

```erlang
{deps, [
    roadrunner
]}.
```

Write a handler. The third route element is per-route state, threaded
to the handler via `roadrunner_req:state/1`:

```erlang
-module(hello_handler).
-behaviour(roadrunner_handler).
-export([handle/1]).

handle(Req) ->
    #{greeting := Greeting} = roadrunner_req:state(Req),
    {roadrunner_resp:text(200, <<Greeting/binary, ", roadrunner!">>), Req}.
```

Boot a listener:

```erlang
application:ensure_all_started(roadrunner).
roadrunner:start_listener(my_listener, #{
    port => 8080,
    routes => [{~"/", hello_handler, #{greeting => ~"hello"}}]
}).
```

```
$ curl -i localhost:8080
HTTP/1.1 200 OK
content-type: text/plain; charset=utf-8
content-length: 18

hello, roadrunner!
```

A handler is a module with `handle/1`. To read path parameters from a `:param`
route (`roadrunner_req:bindings/1`), read the body (`read_body/1` returns
`iodata` and threads `Req2` back), and reply with JSON
(`roadrunner_resp:json/2` encodes the term):

```erlang
-module(users_handler).
-behaviour(roadrunner_handler).
-export([handle/1]).

handle(Req) ->
    #{~"id" := Id} = roadrunner_req:bindings(Req),
    {ok, Body, Req2} = roadrunner_req:read_body(Req),
    Reply = #{id => Id, received => byte_size(iolist_to_binary(Body))},
    {roadrunner_resp:json(200, Reply), Req2}.
```

Mix literal and `:param` routes:

```erlang
routes => [
    {~"/", hello_handler, #{greeting => ~"hello"}},
    {~"/users/:id", users_handler, undefined}
]
```

The request accessors (`method/1`, `path/1`, `header/2`, `parse_qs/1`,
`bindings/1`, `peer/1`, `read_body/1`) all live in `roadrunner_req`.

To wrap every response, register a middleware. An entry is a `Callable` or a
`{Callable, State}` pair, and the first in the list runs outermost:

```erlang
-module(server_header_mw).
-behaviour(roadrunner_middleware).
-export([call/3]).

call(Req, Next, _State) ->
    {{Status, Headers, Body}, Req2} = Next(Req),
    {{Status, [{~"server", ~"roadrunner"} | Headers], Body}, Req2}.
```

```erlang
roadrunner:start_listener(api, #{
    port => 8080,
    middlewares => [server_header_mw],
    routes => [{~"/", hello_handler, #{greeting => ~"hello"}}]
}).
```

For HTTP/2 over TLS, add a cert and list both protocols. ALPN is
derived from `protocols` automatically:

```erlang
roadrunner:start_listener(my_tls_listener, #{
    port => 8443,
    protocols => [http1, http2],
    tls => [
        {certfile, "cert.pem"},
        {keyfile, "key.pem"}
    ],
    routes => [{~"/", hello_handler, #{greeting => ~"hello"}}]
}).
```

ALPN routes `h2` clients to the HTTP/2 path and `http/1.1` clients (or
no-ALPN) to the HTTP/1.1 path on the same listener. Drop `http2` from
the list to disable HTTP/2. For HTTP/2 on plain TCP (h2c
prior-knowledge per RFC 7540 §3.4), use `protocols => [http2]` without
the `tls` opt.

For HTTP/3 (experimental), add `http3` to a TLS listener's `protocols`
(e.g. `protocols => [http1, http2, http3]`). It serves h3 over UDP on the
same port number and advertises `Alt-Svc` so browsers upgrade from TCP;
the `quic` transport starts on demand, so h1/h2-only listeners never load
it.

For listeners that don't need routing, `routes => Mod` (or
`{Mod, State}` to seed handler state) skips the router entirely and
dispatches every request to `Mod:handle/1`:

```erlang
roadrunner:start_listener(my_listener, #{
    port => 8080,
    routes => {hello_handler, #{greeting => ~"hello"}}
}).
```

## Configuration

All listener options live in the
[`roadrunner_listener:opts/0`](https://hexdocs.pm/roadrunner/roadrunner_listener.html#t:opts/0)
type, with per-key defaults and tuning rationale. Beyond `port`,
`protocols`, `tls`, and `routes` from the Quickstart, the type covers:

- **DoS bounds**: `max_clients`, `max_concurrent_requests`,
  `socket_backlog`, `max_content_length`, `request_timeout`,
  `keep_alive_timeout`, `min_bytes_per_second`, `max_keep_alive_requests`
- **Middleware**: `middlewares`
- **Body buffering**: `body_buffering`
- **Graceful drain**: `graceful_drain`, `slot_reconciliation`
- **Per-conn hibernation**: `hibernate_after`
- **Handler spawn opts**: `handler_spawn`
- **HTTP/1 tunables**: Under the `{http1, Opts}` entry in `protocols`:
  `max_request_line`, `max_header_line`, `max_header_block`,
  `max_header_count`
- **HTTP/2 tunables**: Under the `{http2, Opts}` entry in `protocols`:
  `conn_window`, `stream_window`, `window_refill_threshold`,
  `max_concurrent_streams`, `max_header_block`
- **HTTP/3 tunables**: Under the `{http3, Opts}` entry in `protocols`:
  `listeners` (reuseport pool size), `max_header_block`

## Features

### Handlers

- **Buffered responses**: `{Status, Headers, Body}` via `roadrunner_resp:text/2`,
  `:html/2`, `:json/2`, `:redirect/2`, plus empty-status shortcuts.
- **Streaming**: `{stream, Status, Headers, Fun}`, chunked transfer with a
  `Send/2` callback; supports trailer headers per RFC 9112 §7.1.2.
- **Loop / SSE**: `{loop, Status, Headers, State}` plus an optional
  `handle_info/3` callback for message-driven push.
- **WebSocket**: `{websocket, Module, State}` upgrade with a
  `roadrunner_ws_handler` callback.
- **Sendfile**: `{sendfile, Status, Headers, {Filename, Offset, Length}}`,
  zero-copy file body via `file:sendfile/5` (TCP) or chunked `ssl:send`
  fallback (TLS).

### Routing

- **Router**: `roadrunner_router` with literal / `:param` / `*wildcard` segments.
- **Hot reload**: Routes published to `persistent_term` for O(1) lookup;
  `roadrunner_listener:reload_routes/2` swaps the table without restart.

### Middleware

- **Continuation-style**: Each entry is a `Callable` or a
  `{Callable, State}` pair, where `Callable` is a module (`call/3`) or a
  `fun((Req, Next, State) -> {Response, Req2})`. Listener-level + per-route,
  first-in-list = outermost.

### Built-in handlers

- **`roadrunner_static`**: File serving with ETag, `If-None-Match`, `Range`,
  `Last-Modified`, `If-Modified-Since`, and configurable symlink policy
  (`refuse_escapes` default).

### Hardening

- **Strict parsing**: RFC 9110 / 9112, with defenses grouped by subsystem:
    - **Request smuggling / framing**: CL+TE conflict, multiple-CL,
      chunk-size leading-whitespace rejection.
    - **Header / control-frame injection**: Header CRLF / NUL rejection,
      SSE event-line CRLF rejection, trailer-header CRLF rejection,
      RFC 6455 §5.5 control-frame limits, RFC 6265 cookie OWS handling.
    - **Sendfile path safety**: Path traversal + symlink escape defenses.
- **TLS defaults**: TLS 1.2 / 1.3 only, AEAD-only cipher filter,
  client renegotiation off, post-quantum hybrid `x25519mlkem768` first
  when the OpenSSL build supports it. Full settings list in the
  `roadrunner_listener` module docs.
- **DoS bounds**: `max_clients`, `max_concurrent_requests`,
  `socket_backlog`, `max_content_length`, `min_bytes_per_second`,
  `request_timeout`, `keep_alive_timeout`, `max_keep_alive_requests`.

### Observability

- **Telemetry**: `telemetry` events covering request, response, listener
  accept / close, slot reconciliation, ws upgrade and frames, and
  drain ack (opt-in via `roadrunner:acknowledge_drain/1`). Full event
  list with measurements / metadata in the `roadrunner_telemetry`
  module docs.
- **Log correlation**: Per-request `request_id` attached to
  `logger:set_process_metadata/1` so any `?LOG_*` from
  middleware/handlers is auto-correlated.
- **Pull metrics**: `roadrunner_listener:info/1` for `active_clients` /
  `requests_served`.
- **Process labels**: `proc_lib:set_label/1` per-listener / per-acceptor /
  per-conn for legible `observer` process trees.

### Lifecycle

- **Drain**: `roadrunner_listener:drain/2` does graceful shutdown with a
  timeout: closes the listen socket, broadcasts `{roadrunner_drain, Deadline}`
  to in-flight conns via `pg`, polls until idle or deadline, then
  `exit(Pid, shutdown)` for stragglers.
- **Status**: `roadrunner_listener:status/1` returns `accepting | draining`.
- **Slot reconciliation**: Optional `slot_reconciliation => #{interval => N}`
  listener opt: a periodic reaper that compares `client_counter` against the
  conn `pg` group and releases slots orphaned by `kill`-style exits. Off by
  default; enable in production where you can't trust every exit path to run
  `terminate/3` (`kill` signals, OOM kills, supervisor brutal-kill).

## Documentation

- [`docs/comparison.md`](https://github.com/arizona-framework/roadrunner/blob/main/docs/comparison.md): full side-by-side
  benchmarks vs cowboy and elli (throughput, latency, architectural
  trade-offs, reproduction commands).
- [`docs/bench_results.md`](https://github.com/arizona-framework/roadrunner/blob/main/docs/bench_results.md): full per-protocol
  matrix with p50 / p99 across every scenario.
- [`docs/bench_internals.md`](https://github.com/arizona-framework/roadrunner/blob/main/docs/bench_internals.md): loadgen worker
  model, latency aggregation, when the loader becomes the bottleneck.
- [`docs/wrk2_results.md`](https://github.com/arizona-framework/roadrunner/blob/main/docs/wrk2_results.md): open-loop,
  Coordinated-Omission-corrected tail-latency tables (full per-scenario,
  all rate-points per server).
- [`docs/resource_results.md`](https://github.com/arizona-framework/roadrunner/blob/main/docs/resource_results.md): memory + CPU
  shape per scenario.
- [`docs/conn_lifecycle_investigation.md`](https://github.com/arizona-framework/roadrunner/blob/main/docs/conn_lifecycle_investigation.md):
  the connection-process model trade-offs and the one h2 case
  cowboy still wins.
- [`docs/roadmap.md`](https://github.com/arizona-framework/roadrunner/blob/main/docs/roadmap.md): deferred items, with rough
  effort estimates for each.

## Sponsors

Roadrunner is open source and maintained on personal time. If you or your company find it useful,
consider [sponsoring](https://github.com/sponsors/williamthome).

I also accept coffees ☕

[!["Buy Me A Coffee"](https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png)](https://www.buymeacoffee.com/williamthome)

<a href="https://github.com/sponsors/williamthome">
  <img
    src="https://raw.githubusercontent.com/williamthome/williamthome/sponsorkit/sponsors.svg"
    alt="Sponsors"
  />
</a>

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](https://github.com/arizona-framework/roadrunner/blob/main/CONTRIBUTING.md) for development setup,
testing guidelines, and contribution workflow.

### Contributors

<a href="https://github.com/arizona-framework/roadrunner/graphs/contributors">
  <img
    src="https://contrib.rocks/image?repo=arizona-framework/roadrunner&max=100&columns=10"
    width="15%"
    alt="Contributors"
  />
</a>

## Star History

<a href="https://star-history.com/#arizona-framework/roadrunner">
  <picture>
    <source
      media="(prefers-color-scheme: dark)"
      srcset="https://api.star-history.com/svg?repos=arizona-framework/roadrunner&type=Date&theme=dark"
    />
    <source
      media="(prefers-color-scheme: light)"
      srcset="https://api.star-history.com/svg?repos=arizona-framework/roadrunner&type=Date"
    />
    <img
      src="https://api.star-history.com/svg?repos=arizona-framework/roadrunner&type=Date"
      alt="Star History Chart"
      width="100%"
    />
  </picture>
</a>

## License

Copyright (c) 2026 [William Fank Thomé](https://github.com/williamthome)

Roadrunner is open-source under the Apache 2.0 License on
[GitHub](https://github.com/arizona-framework/roadrunner).

See [LICENSE.md](https://github.com/arizona-framework/roadrunner/blob/main/LICENSE.md) for more information.
