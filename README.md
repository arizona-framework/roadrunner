# Roadrunner

[![Erlang CI](https://github.com/arizona-framework/roadrunner/actions/workflows/erlang.yml/badge.svg?branch=main)](https://github.com/arizona-framework/roadrunner/actions/workflows/erlang.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/roadrunner.svg)](https://hex.pm/packages/roadrunner)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/roadrunner/)
[![License](https://img.shields.io/hexpm/l/roadrunner.svg)](https://github.com/arizona-framework/roadrunner/blob/main/LICENSE.md)

![roadrunner logo](https://raw.githubusercontent.com/arizona-framework/roadrunner/main/assets/logo.jpg)

Pure-Erlang HTTP/1.1 + HTTP/2 + WebSocket server for OTP 29+. **Beep beep.**

Built ground-up via TDD as the HTTP backbone for the
[arizona-framework](https://github.com/arizona-framework/arizona). The
user-facing API is a handler behaviour, request/response accessors,
listener controls, and a handful of opt-in helpers (cookies, qs,
multipart, SSE, WebSocket). RFC-correct parsing, modern OTP idioms
throughout, and predictable per-connection lifecycle observability.

## ⚠️ Requirements

Roadrunner requires **OTP 29**. Older OTPs won't compile, and the
throughput numbers in the [performance section](#performance-at-a-glance)
assume 29.

## 🚧 Status

Roadrunner is in `0.x`. The core is functional and covered by tests,
but the API may change between minor versions. Pin an exact commit
ref in your deps (e.g. `{ref, "<sha>"}`) if you need stability
across upgrades.

Eunit + Common Test (incl. PropEr) suites with **100 % line coverage**,
dialyzer-clean, h2spec strict 100 %, Autobahn fuzzingclient strict
100 % across the full WebSocket matrix (no exclusions).

Standards conformance:

- **HTTP/1.1**: RFC 9110 (semantics) + RFC 9112 (syntax).
- **HTTP/2**: RFC 9113 (frames + multiplexing) + RFC 7541 (HPACK).
  Opt-in per listener by listing `~"h2"` in the TLS
  `alpn_preferred_protocols` option. Conformance harness:
  [`scripts/h2spec.sh`](scripts/h2spec.sh) (drives
  [h2spec](https://github.com/summerwind/h2spec)).
- **Content-Encoding** (RFC 9110 §8.4.1): gzip + deflate with
  qvalue-aware `Accept-Encoding` negotiation (RFC 9110 §12.5.3),
  works unchanged over HTTP/2.
- **WebSocket**: RFC 6455. Conformance harness:
  [`scripts/autobahn.escript`](scripts/autobahn.escript) (drives the
  [Autobahn|Testsuite](https://github.com/crossbario/autobahn-testsuite)
  fuzzingclient).
- **WebSocket compression**: RFC 7692 `permessage-deflate`,
  including `*_max_window_bits` and `*_no_context_takeover`.

## Performance at a glance

Median req/s on a 12th-gen i9-12900HX, 50 clients, 5 s warmup + 5 s
measure, loopback. Full per-protocol grid + p50/p99 + memory shape
in [`docs/comparison.md`](docs/comparison.md).

| scenario                  | roadrunner    | cowboy        | elli          |
|---------------------------|--------------:|--------------:|--------------:|
| `hello`                   |   **298 k**   |       179 k   |       278 k   |
| `headers_heavy`           |   **235 k**   |       118 k   |       211 k   |
| `cookies_heavy`           |   **247 k**   |       154 k   |          —    |
| `pipelined_h1`            |   **501 k**   |       329 k   |       4.9 k   |
| `gzip_response`           |   **127 k**   |       100 k   |          —    |
| `websocket_msg_throughput`|   **199 k**   |       155 k   |          —    |

Bold = row winner. `—` means the elli fixture doesn't support that
workload shape (no router, no gzip middleware, no native cookie
parser, no WebSocket). On simple GETs (`hello`, `json`, `echo`)
Roadrunner's lead over elli is within the bench's ~15 % variance
band — the comparison doc has the full honest framing.

The numbers above are throughput from `scripts/bench.escript`
(closed-loop). For Coordinated-Omission-corrected tail latency at
sustained rates (open-loop, via wrk2), see
[`docs/wrk2_results.md`](docs/wrk2_results.md) and the
methodology section in [`docs/comparison.md`](docs/comparison.md).

## Quickstart

Add to `rebar.config`:

```erlang
{deps, [
    {roadrunner, {git, "https://github.com/arizona-framework/roadrunner.git", {branch, "main"}}}
]}.
```

Write a handler — the third route element is per-route opts, threaded
to the handler via `roadrunner_req:route_opts/1`:

```erlang
-module(hello_handler).
-behaviour(roadrunner_handler).
-export([handle/1]).

handle(Req) ->
    #{greeting := Greeting} = roadrunner_req:route_opts(Req),
    {roadrunner_resp:text(200, <<Greeting/binary, ", roadrunner!">>), Req}.
```

Boot a listener:

```erlang
1> application:ensure_all_started(roadrunner).
2> roadrunner:start_listener(my_listener, #{
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

For HTTP/2 over TLS, add a cert and put `~"h2"` in the listener's
`alpn_preferred_protocols`:

```erlang
3> roadrunner:start_listener(my_tls_listener, #{
       port => 8443,
       tls => [
           {certfile, "cert.pem"},
           {keyfile, "key.pem"},
           {alpn_preferred_protocols, [~"h2", ~"http/1.1"]}
       ],
       routes => [{~"/", hello_handler, #{greeting => ~"hello"}}]
   }).
```

ALPN routes `h2` clients to the HTTP/2 path and `http/1.1` clients (or
no-ALPN) to the HTTP/1.1 path on the same listener. Omit `~"h2"` from
the list to disable HTTP/2.

For listeners that don't need routing, `routes => Mod` skips the router
entirely and dispatches every request to `Mod:handle/1`:

```erlang
roadrunner:start_listener(my_listener, #{port => 8080, routes => hello_handler}).
```

## Features

### Handlers

- **Buffered responses:** `{Status, Headers, Body}` — `roadrunner_resp:text/2`,
  `:html/2`, `:json/2`, `:redirect/2`, plus empty-status shortcuts.
- **Streaming:** `{stream, Status, Headers, Fun}` — chunked transfer with a
  `Send/2` callback; supports trailer headers per RFC 7230 §4.1.2.
- **Loop / SSE:** `{loop, Status, Headers, State}` + optional
  `handle_info/3` callback for message-driven push.
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

- Strict RFC 9110 / RFC 9112 parsing — request smuggling defenses
  (CL+TE conflict, multiple-CL), header CRLF/NUL injection rejection,
  chunk-size leading-whitespace rejection, RFC 6265 cookie OWS handling,
  RFC 6455 §5.5 control-frame limits, SSE event-line CRLF rejection,
  trailer header CRLF injection rejection, sendfile path traversal +
  symlink escape defenses.
- TLS hardened defaults — TLS 1.2/1.3 only, `honor_cipher_order`,
  `client_renegotiation` off, AEAD-only ECDHE-or-1.3 ciphers filtered
  through `ssl:filter_cipher_suites/2`, OTP default `supported_groups`
  (PQ-hybrid `x25519mlkem768` first when the OpenSSL build supports it),
  `early_data` disabled.
- DoS bounds — `max_clients`, `max_content_length`,
  `minimum_bytes_per_second`, `request_timeout`, `keep_alive_timeout`,
  `max_keep_alive_requests`.

### Observability

- `telemetry` events: request `start | stop | exception | rejected`,
  `response, send_failed`, listener `accept | conn_close |
  slots_reconciled`, ws `upgrade | frame_in | frame_out`, `drain,
  acknowledged` (opt-in via `roadrunner:acknowledge_drain/1`).
- Per-request `request_id` attached to `logger:set_process_metadata/1`
  so any `?LOG_*` from middleware/handlers is auto-correlated.
- `roadrunner_listener:info/1` for pull-side `active_clients` /
  `requests_served` metrics.
- `proc_lib:set_label/1` per-listener / per-acceptor / per-conn for
  legible `observer` process trees.

### Lifecycle

- `roadrunner_listener:drain/2` — graceful shutdown with timeout. Closes
  the listen socket, broadcasts `{roadrunner_drain, Deadline}` to in-flight
  conns via `pg`, polls until idle or deadline, then `exit(Pid, shutdown)`
  for stragglers.
- `roadrunner_listener:status/1` — `accepting | draining`.
- Optional `slot_reconciliation => #{interval => N}` listener opt — a
  periodic reaper that compares `client_counter` against the conn `pg`
  group and releases slots orphaned by `kill`-style exits. Off by default;
  enable in production where you can't trust every exit path to run
  `terminate/3` (`kill` signals, OOM kills, supervisor brutal-kill).

### Test surface

- **PropEr properties** via `ct_property_test`: `roadrunner_uri`
  percent round-trip + encode shape, `roadrunner_qs` round-trip,
  `roadrunner_cookie` adversarial robustness, `roadrunner_http1`
  parsers never-crash + incremental-feed equivalence, plus
  `roadrunner_conn_loop` robustness over random recv/drain/stray
  inputs (clean exit + slot release) and `request_id` consistency
  between `request_start` / `request_stop` telemetry.
- **Malformed-input corpus**: `roadrunner_http1_corpus_tests`
  exercises HTTP/1.1 patterns lifted from the
  [llhttp](https://github.com/nodejs/llhttp) test corpus and the
  canonical request-smuggling vectors documented by Portswigger.
- **Conformance harnesses**: `scripts/h2spec.sh` (HTTP/2),
  `scripts/autobahn.escript` (WebSocket),
  `scripts/redbot.escript` (HTTP/1.1 response hygiene).

## Documentation

- [`docs/comparison.md`](docs/comparison.md) — full side-by-side
  benchmarks vs cowboy and elli (throughput, latency, architectural
  trade-offs, reproduction commands).
- [`docs/bench_results.md`](docs/bench_results.md) — full per-protocol
  matrix with p50 / p99 across every scenario.
- [`docs/resource_results.md`](docs/resource_results.md) — memory + CPU
  shape per scenario.
- [`docs/conn_lifecycle_investigation.md`](https://github.com/arizona-framework/roadrunner/blob/main/docs/conn_lifecycle_investigation.md)
  — the connection-process model trade-offs and the one h2 case
  cowboy still wins.
- [`docs/roadmap.md`](docs/roadmap.md) — deferred items, with rough
  effort estimates for each.

## Design philosophy

- **RFC-correct, hostile-input-safe.** Parsers are pure incremental
  binary matchers; only programmer errors raise, wire input always
  becomes `{error, _}`. Malformed bytes are bounded by length and
  rejected before reaching application code.
- **Modern OTP idioms.** Sigils for binary literals, body recursion (cons
  on the way out), binary keys for wire-derived data, `-doc` /
  `-moduledoc` markdown, dialyzer-clean specs. No `binary_to_atom` on
  parsed names.
- **Continuation-style middleware** over Plug.Conn-style transformation
  — strictly more expressive than cowboy's deprecated `(Req, Env)`
  shape and dramatically simpler than cowboy's stream handlers.
- **Telemetry over custom callbacks.** `telemetry` is the de facto
  standard (Phoenix, Ecto, gleam_otp); zero-overhead when no subscribers,
  integrates with prometheus / opentelemetry / datadog out of the box.
- **No external deps unless stdlib genuinely can't.** Only runtime dep
  is `telemetry` (tiny, no transitive deps); only dev-time dep is the
  `erlfmt` plugin.

## Sponsors

If you like Roadrunner, please consider [sponsoring me](https://github.com/sponsors/williamthome).
I'm thankful for your never-ending support ❤️

I also accept coffees ☕

[!["Buy Me A Coffee"](https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png)](https://www.buymeacoffee.com/williamthome)

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for development setup,
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

See [LICENSE.md](LICENSE.md) for more information.
