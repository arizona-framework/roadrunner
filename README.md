# roadrunner

Pure-Erlang HTTP/1.1 + HTTP/2 + WebSocket server for OTP 28+. **Beep beep.**

Built ground-up via TDD as the HTTP backbone for the
[arizona-framework](https://github.com/arizona-framework/arizona). The
user-facing API is a handler behaviour, request/response accessors,
listener controls, and a handful of opt-in helpers (cookies, qs,
multipart, SSE, WebSocket). RFC-correct parsing, modern OTP idioms
throughout, and predictable per-connection lifecycle observability.

## Status

Eunit + Common Test (incl. PropEr) suites with **100 % line coverage**,
dialyzer-clean, h2spec strict 100 %, Autobahn fuzzingclient strict
100 % across the full WebSocket matrix (no exclusions). Continuous
performance work is tracked in [`docs/roadmap.md`](docs/roadmap.md).

Standards conformance:

- **HTTP/1.1**: RFC 9110 (semantics) + RFC 9112 (syntax).
- **HTTP/2**: RFC 9113 (frames + multiplexing) + RFC 7541 (HPACK).
  Opt-in per listener by listing `~"h2"` in the TLS
  `alpn_preferred_protocols` option.
  [h2spec](https://github.com/summerwind/h2spec) passes at 100 % in
  strict (`-S`) mode (`scripts/h2spec.sh`).
- **Content-Encoding** (RFC 9110 §8.4.1): gzip + deflate with
  qvalue-aware `Accept-Encoding` negotiation (RFC 9110 §12.5.3),
  works unchanged over HTTP/2.
- **WebSocket**: RFC 6455 — passes the
  [Autobahn|Testsuite](https://github.com/crossbario/autobahn-testsuite)
  fuzzingclient at strict 100 % (`scripts/autobahn.escript`).
- **WebSocket compression**: RFC 7692 `permessage-deflate`,
  including `*_max_window_bits` and `*_no_context_takeover`.

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

For listeners that don't need routing, `handler => Mod` skips the router
entirely and dispatches every request to `Mod:handle/1`:

```erlang
roadrunner:start_listener(my_listener, #{port => 8080, handler => hello_handler}).
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
  `max_keep_alive_request`.

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
- Optional `slot_reconciliation => #{interval_ms => N}` listener opt — a
  periodic reaper that compares `client_counter` against the conn `pg`
  group and releases slots orphaned by `kill`-style exits. Off by default;
  enable for chaos-tested deployments.

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

- [`docs/comparison.md`](docs/comparison.md) — side-by-side benchmarks
  vs cowboy and elli (throughput, latency, architectural trade-offs,
  reproduction commands).
- [`docs/bench_results.md`](docs/bench_results.md) — full per-protocol
  matrix with p50 / p99 across every scenario.
- [`docs/resource_results.md`](docs/resource_results.md) — memory + CPU
  shape per scenario.
- [`docs/conn_lifecycle_investigation.md`](docs/conn_lifecycle_investigation.md)
  — the connection-process model trade-offs and the one h2 case
  cowboy still wins.
- [`docs/roadmap.md`](docs/roadmap.md) — deferred items past v0.1
  (notably `{loop, _}`, `{sendfile, _}`, `{websocket, _, _}` over
  HTTP/2 — currently 501 — and HTTP/3).

## Design philosophy

- **Small surface, RFC-correct.** Parsers are pure incremental binary
  matchers; only programmer errors raise, wire input becomes
  `{error, _}`. Hostile input is bounded before reaching application
  code.
- **Modern OTP idioms.** Sigils for binary literals, body recursion (cons
  on the way out), binary keys for wire-derived data, `-doc` /
  `-moduledoc` markdown, dialyzer-clean specs. No `binary_to_atom` on
  parsed names.
- **Continuation-style middleware** over Plug.Conn-style transformation
  — strictly more expressive than cowboy 2.13's deprecated `(Req, Env)`
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
