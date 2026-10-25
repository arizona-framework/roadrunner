# Roadmap

The TODO backlog on the road to v1.0: open work only. Each item carries a
short rationale and a rough effort estimate (small, medium, large). Items
drop off as they ship.

## HTTP/2 response-shape coverage

One of the five handler return shapes still returns `501 Not Implemented`
when served over HTTP/2 (`src/roadrunner_conn_loop_http2.erl` moduledoc
has the matrix).

### `{websocket, _, _}` over h2 — RFC 8441 Extended CONNECT — large effort

**What:** Allow a handler to return `{websocket, Module, State}`
and have the upgrade work when the listener served the request over
h2.

**Why deferred:** plain h1 WebSocket uses `Upgrade: websocket` +
`Connection: Upgrade` headers — h2 has no equivalent. RFC 8441
added a way to do it: a `CONNECT` method with a
`:protocol = websocket` pseudo-header that creates a tunnel for WS
frames over h2 DATA frames. Implementation needs:
- `SETTINGS_ENABLE_CONNECT_PROTOCOL=1` advertised in our SETTINGS frame
- Parsing `:protocol` pseudo-header in HEADERS
- Routing CONNECT-method requests with `:protocol=websocket` to
  the WS handler
- WS frame I/O carried in h2 DATA frames (each direction)
- Handling close, ping, pong, fragmentation, control-frame size
  limits, all the existing WS hardening rules, plus the full
  `permessage-deflate` matrix (RFC 7692)
- Re-running the Autobahn fuzzingclient under h2

**Practical impact today:** small. Chrome and Firefox open a WebSocket
inside an existing h2 connection when the server advertises
`SETTINGS_ENABLE_CONNECT_PROTOCOL`; without it they open a separate h1
connection, which works everywhere. What h2 WebSocket saves is that
connection's TCP and TLS handshake (one or two round trips on mount or
reconnect) and one socket per user on the server. Behind a reverse proxy
or CDN the browser's h2 connection ends at the proxy, which usually
speaks h1 to the backend for WebSockets, so roadrunner sees no change
there. Per message it is likely slower than the dedicated h1 socket:
frames share one TCP connection with the page's other traffic (head of
line blocking behind a large download) and go through h2 framing, flow
control and the connection process. Worth doing when Arizona apps
commonly face browsers directly with many connected users.

**Validation:** no RFC 8441 conformance suite exists. Run the Autobahn
fuzzingclient through an h1-to-h2 bridge (Envoy can upgrade an h1
WebSocket to Extended CONNECT upstream), add headless Chrome to check a
real browser negotiates and uses it, and cover the RFC 8441 rules
(SETTINGS, `:protocol` without the setting, pseudo-headers, 200 not 101,
RST_STREAM and END_STREAM mapped to close) in CT.

**Scope:** large. The biggest part is giving `roadrunner_ws_session` a
second I/O backend: it owns a raw socket today (controlling-process
handoff, active-once reads, direct sends), while over h2 it reads stream
DATA from the connection process and sends within the stream and
connection flow-control windows. The frame codec (`roadrunner_ws`) and
the handler API carry over unchanged. The h1 WebSocket path must stay as
fast as it is, checked by an A/B on the WS bench.

**Source:** Arizona handoff R-h2-1.

## Pre-SETTINGS stream leniency — small effort

**What:** Do not refuse streams a client opened before it could have
seen our advertised `max_concurrent_streams`. With prior-knowledge h2c a
client sends its preface and a burst of HEADERS in the same flight;
RFC 9113 §6.5.2 makes `SETTINGS_MAX_CONCURRENT_STREAMS` *initially
unlimited*, so the burst is compliant and refusing it sheds real
requests at every connection setup.

**Most of it is already handled.** Admitting the burst outright is how
the multi-GiB blowup that took `json-h2c` to zero happened, so leniency
needed somewhere to put the excess. `overload_mode` queueing is that
somewhere and has shipped: with a listener-wide ceiling in queue mode an
opening burst waits instead of being refused. What remains is only
whether to keep admitting past the advertised per-connection limit until
the client's SETTINGS ack arrives, which is a smaller question than it
was.

**HTTP/3 does not need this.** h3 has no
`SETTINGS_MAX_CONCURRENT_STREAMS`; stream concurrency is QUIC's, via the
`initial_max_streams_bidi` transport parameter and `MAX_STREAMS` frames.
The client learns the limit during the handshake, before it can open a
stream, so there is no burst to be lenient about.

## HTTP/3 follow-ups

h3 shipped experimentally (`protocols => [http3]`; QPACK decodes the
client's dynamic table, responses use the static table). Remaining work:

- WebSocket over h3 (`websocket` shape, still `501`) — RFC 9220
  Extended CONNECT; it reuses the stream I/O backend WebSocket over h2
  (RFC 8441) needs, so it follows that item, and shares its trade-offs
- QPACK encoder dynamic table: compress response headers with a dynamic
  table of our own (encoder stream, tracking the client's Section
  Acknowledgments and Insert Count Increments before evicting), when the
  client advertises a non-zero `SETTINGS_QPACK_MAX_TABLE_CAPACITY`
- HttpArena `baseline-h3` / `static-h3` profiles (the local
  `scripts/bench.escript` h3 path is wired and measured; these live in
  the separate `MDA2AV/HttpArena` repo)
- WebTransport / Extended CONNECT (RFC 9220) and HTTP datagrams
  (RFC 9297)

## Native QUIC transport follow-ups

The HTTP/3 path runs on the native `roadrunner_quic_*` stack end to end, with no
`quic` dependency in production or test (roadrunner has no production deps,
and the test profile drives the server with a native QUIC client); the `quic`
dep is kept in the bench profile only, as an HTTP/3 comparison server. The RFC
MUSTs a browser depends on are implemented; the items below are conformance
hardening and transport completeness that a real browser GET / POST does not
need.

### Transport completeness — bites large transfers / advanced cases

- Send-side flow control edge: signal `DATA_BLOCKED` / `STREAM_DATA_BLOCKED` when
  the send window is zero *before any data is sent* (a peer that advertised
  `initial_max_data` / `initial_max_stream_data` of 0). The common case — a
  transfer that fills a non-zero window — already emits the frame on the
  flow's blocked transition; this remainder is the never-sent-a-byte case a
  conformant peer never produces — small

### Throughput levers identified by profiling

All-scope eprof on current `main` over a steady-state download (`scripts/bench.escript
--servers roadrunner --protocols h3 --scenarios large_response --profile
--profile-tool eprof --profile-scope all`). Harness note: the native loadgen now
replenishes its receive window with MAX_DATA, so a connection sustains a download
(~330 MB/s aggregate on a 24-core box) instead of stalling at the advertised
`initial_max_data`; the per-connection bench numbers stay loadgen-bound (one
Erlang process per connection, serial per-datagram decrypt), so validate server
changes by profile-share, not headline req/s.

- Per-packet AEAD + header protection (~10%) and packet assembly
  (`build_packet/4` + `stream_data_budget/5`, ~13% together): mostly inherent
  per-packet work. `stream_data_budget/5` re-encodes the pending ACK frames each
  packet just to size them; caching that size across a burst is a possible
  micro-lever — small
- TLS session tickets / 0-RTT (RFC 8446 §2.2, RFC 9001 §4.6) for returning
  clients: a connection-setup lever only, not steady-state. Resumption skips
  the certificate and its signature, so a returning client's handshake gets
  cheaper still than the full ECDSA P-256 one the bench now does — large

### External interop check

`scripts/h3interop.sh` already gates every PR on the quiche and ngtcp2 clients
and headless Chrome (downloads, uploads, multiplexing, an ngtcp2 key update,
with and without packet loss). Remaining:

- Run the QUIC Interop Runner (quic-interop-runner) on a schedule: a server
  image following its endpoint contract, so every client stack runs its test
  cases (handshake, transfer, retry, resumption, zerortt, chacha20, keyupdate,
  ecn, v2, connection migration) and the unsupported ones show as named gaps
  — medium

## HttpArena profile gaps

Remaining HttpArena profiles need roadrunner-side features.

### h2c Upgrade-mode on a shared port — medium (roadrunner-side)

**What:** RFC 7540 §3.2 `Upgrade: h2c` negotiation: an HTTP/1.1
request with `Upgrade: h2c, HTTP2-Settings: <base64>` headers,
answered with `101 Switching Protocols`, after which the
connection upstreams h2 frames. The same listener accepts h1 and
h2c on the same port, unlocking `protocols => [http1, http2]` on
plain TCP (today that combo is rejected at `init/1` with
`{listener_opt_conflict, protocols, _, no_h2c_upgrade}`).

**Why deferred:** The prior-knowledge variant (`protocols => [http2]`
on a dedicated plaintext listener) ships and covers the common case
(benchmarks, internal clients with prior knowledge). Upgrade-mode
adds preface sniffing or h1-parse-then-switch logic to the conn
loop — a real expansion of the connection state machine that
isn't on the critical path.

**HttpArena impact:** none (its `baseline-h2c` / `json-h2c` profiles
use prior-knowledge).

**Scope:** medium. Decide on shared-port sniff vs h1-parse-Upgrade;
implement the chosen path; tests for both successful upgrade and
`Upgrade: h2c` rejection on TLS sockets (the spec forbids it).

### HTTP/3 — see above

Unlocks `baseline-h3` and `static-h3`.

### gRPC — large (roadrunner-side)

**What:** A gRPC layer on top of the h2 stack: `application/grpc`
content-type dispatch, length-prefixed framing inside h2 DATA,
`grpc-status` trailers, server-streaming generators, plus a
codegen story (rebar3 plugin or grpcbox-style runtime descriptors).

**HttpArena impact:** `unary-grpc`, `stream-grpc`, and their TLS
variants.

**Scope:** large. None of the bits are exotic, but there are a
lot of them.

## Other

### CI bench-vs-baseline comparison

**What:** The `Bench` workflow (`.github/workflows/bench.yml`) writes its
result to the step summary and already uploads `bench.log` as a
downloadable artifact. The remaining follow-up is a comparison step (or
dashboard) that diffs a PR run against a baseline (e.g. `main` HEAD) and
surfaces the delta.

**Why deferred:** GH free runners are too noisy for automated
regression gating (deltas under ~15 % are inside variance per
`scripts/bench.escript`'s own NOTE). A useful comparison needs a
baseline-collection strategy that filters noise (multi-sample on
both sides, distribution stats, alerting only on shifts well outside
variance). Eyeball-from-summary covers the v1 use case.

**Scope:** medium. The parser, distribution stats, baseline storage, and
presentation are the bulk; the artifact upload already ships.

### Extend the erlang_quic h3 comparison past the small-response scenarios

**What:** `bench_erlang_quic_server` serves the GET-side h3 scenarios (hello,
json, large_response, headers_heavy, head_method, cookies_heavy) as the
`erlang_quic` comparison target, but two gaps remain. `large_response` does not
yield a usable number: the dep server stalls mid-download (CPU ~300%, err=50 at
the deadline) because the native loadgen (`roadrunner_quic_test_conn`) sustains
downloads from roadrunner's own server but not from the dep, so it needs to grant
per-stream `MAX_STREAM_DATA`, not just connection-level `MAX_DATA`. `echo` and
`multi_request_body` are filtered out (a preflight drops `erlang_quic` for them):
the dep's 5-arg handler exposes no POST body, so echoing one needs the dep's
`set_stream_handler` body-receive path.

**Why deferred:** the five small-response scenarios compare cleanly, and the dep
is bench-only tooling on its way out; the bulk-transfer and upload comparisons
are the remaining gaps.

**Scope:** small for `large_response` (loadgen per-stream credit grant),
small-medium for the POST scenarios (dep body-receive wiring).

### Strict grammars for Set-Cookie attributes

**What:** `roadrunner_cookie:serialize/3` validates the cookie
`Name` and `Value` against RFC 6265 §4.1.1 (and rejects header-injection
bytes in `Domain`, `Path`, `Expires`), but it does not enforce the full
attribute grammars — e.g. `Domain` is not checked against RFC 1035 §3.5
hostname rules, `Expires` is not parsed as IMF-fixdate, `Path` accepts
any non-CTL non-`;` byte (RFC 6265 §4.1.1 allows that, but stricter
checks could catch caller bugs earlier).

**Why deferred:** the present check covers the header-injection /
attribute-smuggling surface (the cowlib CVE-2026-43969 class). Strict
grammar enforcement is callers-write-bugs ergonomics, not security.

**Scope:** small per attribute. Add when a real caller hits the gap.

### Anchor the manual-mode body rate window at the first body byte — small

**What:** `make_recv/3` (`roadrunner_conn.erl`) captures its rate-window start at
closure creation (`read_body_phase/3`), so in manual body-buffering mode a handler
that delays before calling `roadrunner_req:read_body/1,2` has its think-time counted
toward the body's minimum-byte-rate average. Auto mode has no gap (it reads the
body synchronously right after the closure is built), the request-read phase
already anchors at the first byte, and a manual-mode request expecting
`100-continue` anchors at the 100, which its first read sends.

**Why deferred:** bounded today by the request_timeout `Deadline` threaded into the
same closure (it fires first), and the residual is a narrow self-inflicted case
(manual mode + a slow handler + a configured `min_bytes_per_second` + a small body).
Anchoring at the first body recv would also slightly weaken Slowloris protection for
a client that stalls between headers-done and body-start, so it is defensible as-is.
Revisit only if a real workload reports false `slow_client` drops.

**Scope:** small.

### Check `roadrunner_static` options when the routes compile — medium

**What:** `roadrunner_static` reads its route state (`dir`, `cache_control`,
`symlink_policy`, `cache_ttl_ms`, `mime_types`) on each request and never
checks it up front. A typo such as `symlink_policy => folow` quietly falls
back to the default, a missing `dir` or a `mime_types` that is not a map only
fails when a request arrives, and an uppercase `mime_types` key never
matches. A compile-time hook for handler state (like a middleware's `init/1`,
under a name that cannot clash with `roadrunner_ws_handler:init/1`) would let
the handler reject a bad option when the listener starts, lowercase the
`mime_types` keys, and merge them into the built-in table once.

**Why deferred:** handlers have no compile-time hook today, and adding one
touches the router, `validate/1` and `reload_routes/2` for every handler, not
just the static one.

**Scope:** medium.

## Per-route framework knobs the map shape unlocks

The map-shape route entry (`#{path => ..., handler => ..., state =>
..., middlewares => [...]}`) is intentionally extensible — new
top-level keys add new per-route capabilities without breaking
existing routes. None of the below is wired up yet; the map shape
is ready when one of these has a real caller behind it.

### Per-route `name => atom()` for events / reverse routing — small

**What:** Let a route declare a stable name (e.g. `name =>
users_show`) and surface it to the event handler on `request_start`
plus expose a
`roadrunner_router:url_for/2,3` for reverse-resolving the name back
to a path.

**Why deferred:** no event handler asking for it today.
`(listener_name, method, path)` is already enough to identify a
route in dashboards; named lookup is a niceness, not a need.

### Nested route groups with shared prefix + middlewares — medium

**What:** Phoenix-style scope / pipeline:

```erlang
[#{prefix => ~"/api", middlewares => [auth_mw], routes => [
    #{path => ~"/users/:id", handler => users_show},
    #{path => ~"/posts/:id", handler => posts_show}
 ]}]
```

The framework flattens these at compile time into the plain route
list `compile/2` takes, concatenating the prefix and prepending the
group's middlewares to each leaf route.

**Why deferred:** the flat list is fine until the route table has
shared per-section middlewares (auth, rate limit, body-limit
overrides) duplicated across many entries. Add when a real codebase
shows that duplication.

## Deferred to the application layer

Capabilities that are real, but sit above the HTTP server core: in
whatever application, framework, or library runs on top of roadrunner.
That could be a framework (Arizona is one), a third-party library, or the
service's own code. Roadrunner deliberately stops at the HTTP layer and
hands these up. It supplies the mechanism, an ordered middleware slot,
immutable request and response values, and events through a
`roadrunner_event_handler`; the layer
above supplies the policy and the ergonomics. Listed so the boundary is
explicit.

- **Identity, authorization, and sessions.** Token validation, session
  cookies, and single sign-on (OIDC and the like) are application trust
  policy. Roadrunner exposes the request (headers, cookies) and the
  connection; a middleware above decides who a caller is and what they
  may do.
- **API description and input validation.** Generated schemas and docs
  (OpenAPI and friends) and parse-and-validate-into-typed-values are
  bound to the application's own routes and data shapes, which roadrunner
  never sees; it dispatches opaque handlers.
- **Application protocols layered on HTTP.** RPC, GraphQL, and agent/tool
  surfaces (MCP and similar) are an application concern; the layer above
  mounts them on ordinary roadrunner routes, no extra listener.
- **Outbound requests.** A client (pooling, retries, circuit breaking,
  load balancing) is not a server concern; it belongs with the
  application's integrations.
- **Observability backends.** Roadrunner hands its events to one
  configured `roadrunner_event_handler` and drops them by default;
  turning them into `telemetry` events, traces, or metrics for a chosen
  backend (OpenTelemetry, Prometheus, and the like) is a handler the
  layer above provides.
- **Per-identity quotas and policy.** The application half of rate
  limiting: who gets how much, keyed by authenticated identity.
  Roadrunner keeps the connection-level abuse guard; the layer above owns
  user-level quotas.
- **Service lifecycle endpoints.** Readiness and health checks
  (dependencies reachable, warm-up complete) are application-defined, a
  single route handler above the server.

## Out of scope

These are deliberately out of scope, not "deferred":

- **HTTP/2 server push** (RFC 9113 §8.4). Chrome 106 removed support;
  the feature is effectively dead. We have no plans to ship it.
- **HTTP/2 priority** (RFC 9218 / deprecated RFC 7540 priority
  scheme). Roadrunner serves streams round-robin. Real users tune
  via application logic, not h2 priorities.
- **Hard-restart of in-flight conns**. `roadrunner_listener:drain/2`
  is the supported lifecycle primitive; there's no plan for a
  forced-cancel. Slot tracking handles cleanup.
- **Reverse-proxy / gateway stacks** (HttpArena `gateway-64`,
  `gateway-h3`, `production-stack`). nginx / caddy / envoy in front of
  the framework is bench-app docker-compose work, not a roadrunner gap.
