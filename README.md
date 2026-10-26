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
accessors, listener controls, and opt-in helpers.

## Why Roadrunner?

A small, fast HTTP core you can trust on the hot path.

- **Fast where it counts**: Tuned for low p50 and p99 under sustained load. See
  [Performance](#performance).
- **Correct and hostile-input-safe**: Strict RFC 9110 / 9112 / 9113 parsing,
  100% h2spec, 100% h3spec and 100% Autobahn (no exclusions), tested against
  request-smuggling cases, and listed on Http11Probe. See
  [Conformance](#conformance).
- **Every HTTP version, one server**: HTTP/1.1, HTTP/2, HTTP/3 (experimental),
  and WebSocket served from one listener; browsers upgrade to h3 over the same
  port via `Alt-Svc`.
- **Pure Erlang, no dependencies**: No runtime deps,
  no C NIFs, and Roadrunner owns its own h1/h2/h3 codecs and its own QUIC
  transport: easy to read and audit.
- **Pleasant to build on**: Plain-Erlang request and response values, composable
  middleware, and opt-in helpers for cookies, query strings, multipart, SSE,
  NDJSON, and WebSocket.
- **Production lifecycle in the box**: Graceful drain with a deadline, request
  and connection events, per-request `request_id` log correlation, and configurable DoS bounds.

## Requirements

Requires **OTP 27+**.

## 🚧 Status

Roadrunner is in `0.x`. The core is functional and covered by tests,
but the API may change between minor versions. Pin an exact version
in your deps if you need stability across upgrades.

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
$ curl localhost:8080
hello, roadrunner!
```

## Documentation

| Topic | Description |
|---|---|
| [API reference](https://hexdocs.pm/roadrunner/) | Every public module, type, and function |
| [Listener options](https://hexdocs.pm/roadrunner/roadrunner_listener.html#t:opts/0) | Every listener option |
| [Handlers](https://hexdocs.pm/roadrunner/roadrunner_handler.html) | Response shapes: buffered, stream, loop, sendfile, WebSocket |
| [Middleware](https://hexdocs.pm/roadrunner/roadrunner_middleware.html) | Writing and ordering middleware |
| [Resource limits](https://github.com/arizona-framework/roadrunner/blob/main/docs/resource_limits.md) | Per-connection and per-peer limits, defaults, and over-limit behavior |
| [Roadmap](https://github.com/arizona-framework/roadrunner/blob/main/docs/roadmap.md) | Planned work |
| [Changelog](https://github.com/arizona-framework/roadrunner/blob/main/CHANGELOG.md) | Release notes |

## Features

### Routing

Routes are tried top to bottom and the first match wins. `:param` binds one
segment and `*wildcard` binds the rest of the path as a list:

```erlang
routes => [
    {~"/", hello_handler, #{greeting => ~"hello"}},
    {~"/users/:id", user_handler},
    {~"/files/*path", files_handler}
]
```

```erlang
#{~"id" := Id} = roadrunner_req:bindings(Req).
```

A route that can never match, because the routes above it already answer its
path and methods, stops the listener from starting and names both routes. A
mis-ordered table shows up at boot instead of as a 404 in production.

The map form adds per-route options: allowed `methods` (others get `405` with an
`Allow` header), a body cap, a request rate, and route middleware:

```erlang
routes => [
    #{path => ~"/users", handler => users_index, methods => [~"GET"]},
    #{path => ~"/users", handler => users_create, methods => [~"POST"]},
    #{path => ~"/upload", handler => upload_handler, max_content_length => 104_857_600},
    #{path => ~"/login", handler => login_handler, rate_limit => #{rate => 5, period => 60}}
]
```

Method matching is literal, so a `[~"GET"]` route does not answer `HEAD`. Swap
the table on a running listener with `roadrunner_listener:reload_routes/2`. For
a listener with a single handler, pass `routes => Mod` (or `{Mod, State}`) to
skip the router.

### Requests

`roadrunner_req` reads everything from the request value. Functions that
consume the body return a new `Req`:

```erlang
handle(Req) ->
    Method = roadrunner_req:method(Req),
    Agent = roadrunner_req:header(~"user-agent", Req),
    Query = roadrunner_req:parse_qs(Req),
    Cookies = roadrunner_req:parse_cookies(Req),
    {ok, Body, Req2} = roadrunner_req:read_body(Req),
    ...
```

`read_form/1` decodes both urlencoded and `multipart/form-data` bodies. With
`body_buffering => manual`, `read_body/2` reads the body in chunks.

### Responses

`roadrunner_resp` builds buffered responses, and you can also return a plain
`{Status, Headers, Body}` tuple:

```erlang
%% Each line is a possible return from handle/1
{roadrunner_resp:json(200, #{id => 42}), Req}
{roadrunner_resp:redirect(302, ~"/login"), Req}
{roadrunner_resp:not_found(), Req}
{{200, [{~"content-type", ~"text/plain"}], ~"hi"}, Req}
```

A plain tuple without `content-length` gets one from its body.

Set a cookie on any buffered response:

```erlang
Resp = roadrunner_resp:text(200, ~"welcome"),
{roadrunner_resp:set_cookie(Resp, ~"session", Token, #{http_only => true, secure => true}), Req}
```

### Streaming

Return `{stream, Status, Headers, Fun}` and call `Send` as data is ready.
On HTTP/1.1 the body goes out chunked, and `{fin, Trailers}` sends trailer
headers:

```erlang
handle(Req) ->
    Fun = fun(Send) ->
        ok = Send(~"first part\n", nofin),
        ok = Send(~"last part\n", fin)
    end,
    {{stream, 200, [{~"content-type", ~"text/plain"}], Fun}, Req}.
```

### Server-Sent Events

A `{loop, ...}` response keeps the connection open and calls `handle_info/3`
for each message the process receives. `roadrunner_sse` frames the events:

```erlang
handle(Req) ->
    ok = my_pubsub:subscribe(self(), notifications),
    Headers = [{~"content-type", ~"text/event-stream"}, {~"cache-control", ~"no-cache"}],
    {{loop, 200, Headers, undefined}, Req}.

handle_info({notification, Body}, Push, State) ->
    _ = Push(roadrunner_sse:event(~"notify", Body)),
    {ok, State};
handle_info(_Other, _Push, State) ->
    {ok, State}.
```

Keep a catch-all clause: Roadrunner also sends the handler
`{roadrunner_disconnect, Reason}` when the client goes away and
`{roadrunner_drain, Deadline}` when the listener drains.

### NDJSON

```erlang
{roadrunner_resp:ndjson(200, Rows), Req}
```

To stream rows instead, send `roadrunner_ndjson:item(Row)` from a `{stream, ...}`
response.

### WebSocket

Upgrade from any handler over HTTP/1.1, then handle frames in a
`roadrunner_ws_handler`:

```erlang
handle(Req) ->
    {{websocket, echo_ws, #{}}, Req}.
```

```erlang
-module(echo_ws).
-behaviour(roadrunner_ws_handler).
-export([handle_frame/2]).

handle_frame(#{opcode := text, payload := Msg}, State) ->
    {reply, [{text, Msg}], State};
handle_frame(_Frame, State) ->
    {ok, State}.
```

Fragmented messages arrive reassembled, and ping, pong, and close are handled
for you. `permessage-deflate` is negotiated automatically when the client asks
for it. Optional `init/1`, `handle_info/2`, and `handle_drain/2` callbacks
cover setup, process messages, and drain.

### Static files

```erlang
{~"/static/*path", roadrunner_static, #{
    dir => ~"/var/www",
    cache_control => ~"public, max-age=31536000, immutable"
}}
```

Supports `ETag`, `Last-Modified`, `Range`, and precompressed `.br` / `.gz`
files, and by default refuses a symlinked file that points outside `dir`.
`Content-Type` comes from the file extension, with the common web types
(fonts, `.wasm`, `.webp`, `.mjs`, and more) built in and a `mime_types`
option to add your own.

A route can also serve one file, and either path can sit in an
application's `priv` directory:

```erlang
{~"/assets/*path", roadrunner_static, #{dir => {priv, my_app, ~"static"}}},
{~"/favicon.ico", roadrunner_static, #{file => {priv, my_app, ~"favicon.ico"}}}
```

The options are checked when the listener starts, so a typo stops it
from booting instead of failing a request.
Handlers can also send a file directly with
`{sendfile, Status, Headers, {Filename, Offset, Length}}` (zero-copy for
HTTP/1.1 over plain TCP).

### Middleware

A middleware wraps the handler. It gets the request and a `Next` function,
and the first entry in the list runs outermost:

```erlang
auth(Req, Next, _State) ->
    case roadrunner_req:header(~"authorization", Req) of
        undefined -> {roadrunner_resp:unauthorized(), Req};
        _ -> Next(Req)
    end.
```

Built-in middleware:

```erlang
middlewares => [
    roadrunner_compress,
    roadrunner_etag,
    roadrunner_security_headers,
    {roadrunner_cors, #{origins => [~"https://app.example.com"], credentials => true}},
    {fun ?MODULE:auth/3, undefined}
]
```

- **`roadrunner_compress`**: gzip / deflate negotiated on `Accept-Encoding`
- **`roadrunner_etag`**: weak `ETag` on buffered `200` responses to `GET` /
  `HEAD`, and `304 Not Modified` on a match
- **`roadrunner_security_headers`**: safe default headers, with opt-in HSTS
  (`hsts => true`) and CSP
- **`roadrunner_cors`**: CORS with preflight handling and deny-by-default origins

### HTTP/2 and HTTP/3

Add a certificate and list the protocols. ALPN is set up from `protocols`:

```erlang
roadrunner:start_listener(my_tls_listener, #{
    port => 8443,
    protocols => [http1, http2, http3],
    tls => [{certfile, "cert.pem"}, {keyfile, "key.pem"}],
    routes => [{~"/", hello_handler, #{greeting => ~"hello"}}]
}).
```

HTTP/1.1 and HTTP/2 share the TCP port. HTTP/3 (experimental) serves over UDP
on the same port number. When the listener also serves HTTP/1.1 or HTTP/2 on a
fixed port (not `port => 0`), their responses advertise HTTP/3 in `Alt-Svc` so
browsers upgrade. For HTTP/2 over plain TCP (prior knowledge), use
`protocols => [http2]` without `tls`. Without `tls`, a listener serves either
HTTP/1.1 or HTTP/2, not both.

For the fastest new connections, use an ECDSA P-256 certificate. Each new TLS
or QUIC connection signs with the certificate's key, and an ECDSA P-256
signature takes far less CPU than an RSA one, so the server can accept many
more new connections per second. All current browsers support it. To make a
self-signed one for testing:

```sh
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -nodes -days 365 -keyout key.pem -out cert.pem -subj /CN=localhost
```

For a real domain, ask your certificate authority for an ECDSA key (most ACME
clients, such as certbot, can request one).

A listener with `tls` starts the `ssl` application itself, so plain HTTP nodes
never load it. If you build a release that serves TLS, add `ssl` to your
application's `applications` list so the release includes it.

### Behind a proxy

```erlang
%% L4 balancer that prepends a PROXY protocol header
proxy_protocol => true,

%% HTTP proxies that set X-Forwarded-For
real_ip => #{trusted_proxies => [~"10.0.0.0/8"]}
```

`roadrunner_req:client_ip/1` returns the real client, and rate limits and
events use it too.

### Limits and hardening

```erlang
max_clients => 10_000,
max_content_length => 1_048_576,
request_timeout => 30_000,
rate_limit => #{rate => 100, period => 1}
```

- Strict RFC 9110 / 9112 parsing that rejects request smuggling shapes
  (CL + TE, conflicting `Content-Length`) and CR / LF injection in headers
- TLS 1.2 / 1.3 only with AEAD ciphers, and post-quantum hybrid key exchange
  first on HTTP/1.1 and HTTP/2 when your OTP and OpenSSL support it
- Bounds on connections, concurrent HTTP/2 and HTTP/3 requests, body size,
  slow clients, and header size, all listed in [Configuration](#configuration)

### Observability

Roadrunner hands events for requests, connections, and WebSocket frames to
one event handler: a module with a `handle_event/2` callback. By default
they are dropped, and no telemetry library is needed. To send them to
`telemetry`, Prometheus, OpenTelemetry, or your logs, set a handler:

```erlang
%% sys.config
[{roadrunner, [{event_handler, log_requests}]}].
```

```erlang
-module(log_requests).
-behaviour(roadrunner_event_handler).
-export([handle_event/2]).

handle_event(request_start, Req) ->
    {erlang:monotonic_time(), roadrunner_req:method(Req), roadrunner_req:path(Req)};
handle_event(request_stop, {{Start, Method, Path}, Status, _Kind}) ->
    Us = erlang:convert_time_unit(erlang:monotonic_time() - Start, native, microsecond),
    logger:info("~s ~s -> ~p (~p us)", [Method, Path, Status, Us]);
handle_event(_Event, _Args) ->
    ok.
```

Each event passes the raw values it has, so a handler builds only what it
uses. See `roadrunner_event_handler` for the full list of events.

Each request also sets a `request_id` in the `logger` process metadata, so
logs from your handlers line up with it. `roadrunner_listener:info/1` returns
live counters such as `active_clients` and `requests_served`.

### Graceful drain

```erlang
case roadrunner_listener:drain(my_listener, 30_000) of
    {ok, drained} -> ok;
    {timeout, Killed} -> logger:warning("closed ~p connections at the deadline", [Killed])
end.
```

Drain stops accepting new connections, tells open connections and long-lived
handlers (loop and WebSocket) to finish, waits up to the deadline, closes what
is left, and then stops the listener.

## Configuration

All listener options live in the
[`roadrunner_listener:opts/0`](https://hexdocs.pm/roadrunner/roadrunner_listener.html#t:opts/0)
type. Beyond `port`,
`protocols`, `tls`, and `routes`, the type covers:

- **Limits and timeouts**: `max_clients`, `max_concurrent_requests`,
  `overload_mode` (refuse, queue, or answer `503` to requests over the
  limit),
  `max_content_length`, `max_keep_alive_requests`, `request_timeout`,
  `keep_alive_timeout`, `tls_handshake_timeout`, `min_bytes_per_second`,
  `rate_check_interval`, `rate_limit`
- **Real client IP**: `proxy_protocol`, `real_ip` (see
  [Behind a proxy](#behind-a-proxy))
- **Sockets**: `ip` (bind address, all interfaces by default),
  `num_acceptors`, `socket_backlog`, `recv_buffer`
- **Middleware**: `middlewares`
- **Body buffering**: `body_buffering`
- **Graceful drain**: `graceful_drain`, `slot_reconciliation`
- **Per-conn hibernation**: `hibernate_after`
- **Handler spawn opts**: `handler_spawn`
- **WebSocket**: `ws`: `max_frame_size`, `max_message_size`, `recv_buffer`,
  `hibernate_after`
- **HTTP/1 tunables**: Under the `{http1, Opts}` entry in `protocols`:
  `max_request_line`, `max_header_line`, `max_header_block`,
  `max_header_count`, `linger_timeout`
- **HTTP/2 tunables**: Under the `{http2, Opts}` entry in `protocols`:
  `conn_window`, `stream_window`, `window_refill_threshold`,
  `max_concurrent_streams`, `max_header_block`, `max_header_list_size`
- **HTTP/3 tunables**: Under the `{http3, Opts}` entry in `protocols`:
  `listeners` (reuseport pool size), `max_header_block`, `max_streams_bidi`,
  `max_field_section_size`, `secret` (the key behind QUIC stateless resets
  and address validation tokens, kept across restarts)

## Modules

| Module | Purpose |
|---|---|
| `roadrunner` | Start, stop, and list listeners |
| `roadrunner_listener` | Listener options, drain, info, and route reload |
| `roadrunner_handler` | Handler behaviour and response shapes |
| `roadrunner_req` | Request accessors and body reading |
| `roadrunner_resp` | Response builders |
| `roadrunner_router` | Route syntax and matching |
| `roadrunner_middleware` | Middleware behaviour |
| `roadrunner_ws_handler` | WebSocket handler behaviour |
| `roadrunner_event_handler` | Event handler behaviour for observability |
| `roadrunner_event_noop` | Default event handler, drops every event |
| `roadrunner_static` | Static file handler |
| `roadrunner_sse` | Server-Sent Events framing |
| `roadrunner_ndjson` | NDJSON framing |
| `roadrunner_multipart` | `multipart/form-data` parser |
| `roadrunner_cookie` | Cookie parsing and serialization |
| `roadrunner_qs` | Query string codec |
| `roadrunner_uri` | Percent-encoding helpers |
| `roadrunner_http` | Shared HTTP types and date formatting |
| `roadrunner_cors` | CORS middleware |
| `roadrunner_security_headers` | Security headers middleware |

## Conformance

Strict 100% h2spec (HTTP/2), 100% h3spec (QUIC and HTTP/3 error handling)
and Autobahn fuzzingclient across the full WebSocket matrix (no exclusions). The HTTP/1.1 parser is tested against
malformed-request cases taken from the [llhttp](https://github.com/nodejs/llhttp)
test corpus and [PortSwigger](https://portswigger.net/web-security/request-smuggling)
request-smuggling patterns.

Roadrunner is also listed on [Http11Probe](https://www.http-probe.com/servers/roadrunner.html),
an open suite that sends the same malformed and ambiguous HTTP/1.1 requests
to many servers and checks each answer against RFC 9110 and RFC 9112. See its
results page for the current score.

Standards conformance:

- **HTTP/1.1**: RFC 9110 (semantics) + RFC 9112 (syntax).
- **HTTP/2**: RFC 9113 (frames + multiplexing) + RFC 7541 (HPACK).
  Conformance harness: [`scripts/h2spec.sh`](https://github.com/arizona-framework/roadrunner/blob/main/scripts/h2spec.sh) (drives
  [h2spec](https://github.com/summerwind/h2spec)).
- **HTTP/3 (experimental)**: RFC 9114 over QUIC with QPACK (RFC 9204)
  header compression, the client's dynamic table included, over
  Roadrunner's own pure-Erlang QUIC transport (TLS 1.3 required).
  Conformance harness:
  [`scripts/h3spec.sh`](https://github.com/arizona-framework/roadrunner/blob/main/scripts/h3spec.sh) (drives
  [h3spec](https://github.com/kazu-yamamoto/h3spec)). Interop harness:
  [`scripts/h3interop.sh`](https://github.com/arizona-framework/roadrunner/blob/main/scripts/h3interop.sh)
  (downloads, uploads and multiplexed requests from the
  [quiche](https://github.com/cloudflare/quiche) and
  [ngtcp2](https://github.com/ngtcp2/ngtcp2) clients and headless
  Chrome, plus a key update in the middle of an ngtcp2 download, with
  and without packet loss).
- **Content-Encoding (RFC 9110 §8.4.1)**: gzip + deflate with
  qvalue-aware `Accept-Encoding` negotiation (RFC 9110 §12.5.3),
  works unchanged over HTTP/2.
- **WebSocket**: RFC 6455. Conformance harness:
  [`scripts/autobahn.escript`](https://github.com/arizona-framework/roadrunner/blob/main/scripts/autobahn.escript) (drives the
  [Autobahn|Testsuite](https://github.com/crossbario/autobahn-testsuite)
  fuzzingclient).
- **WebSocket compression**: RFC 7692 `permessage-deflate`,
  including `*_max_window_bits` and `*_no_context_takeover`.

## Performance

Roadrunner runs on [HttpArena](https://http-arena.com/), an open
benchmark that tests HTTP servers and frameworks on the same hardware
under the same rules. See the leaderboard for current numbers.

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
