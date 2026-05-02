# roadrunner

A modern, pure-Erlang HTTP/1.1 + WebSocket server for OTP 28+.

Built ground-up via TDD as a Cowboy alternative for the
[arizona-framework](https://github.com/arizona-framework/arizona). Targets a
small public surface, RFC-correct parsing, and modern OTP idioms throughout.

## Status

POC — not yet deployed in production. 738 eunit + 15 CT property
tests, 100% line coverage across 28 source modules, dialyzer-clean.
The per-connection request lifecycle is a `gen_statem` with named
states (`awaiting_shoot | reading_request | reading_body |
dispatching | finishing`) so it shows up in `sys:get_state/1`,
`sys:trace/2`, and observer's process inspector. See
[`/.claude/plans/sorted-discovering-thimble.md`](./.claude/plans/sorted-discovering-thimble.md)
for the rolling roadmap.

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

### Property tests

15 PropEr properties via OTP `ct_property_test`: `roadrunner_uri`
percent round-trip + encode shape, `roadrunner_qs` round-trip,
`roadrunner_cookie` adversarial robustness, `roadrunner_http1` 5 parsers
never-crash + 3 incremental-feed equivalence, plus
`roadrunner_conn_statem` robustness over random recv/drain/stray inputs
(clean exit + slot release) and request_id consistency between
`request_start` / `request_stop` telemetry.

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
