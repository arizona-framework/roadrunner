# Roadmap

The TODO backlog on the road to v1.0: open work only. Each item carries a
short rationale and a rough effort estimate (small, medium, large). Items
drop off as they ship.

## HTTP/2 response-shape coverage

A WebSocket upgrade (`{websocket, ...}` returned, or
`roadrunner_send:websocket/4`) still answers `501 Not Implemented` over
HTTP/2 and HTTP/3; every other response shape works on all protocols.

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

## HTTP/3 follow-ups

h3 is served with `protocols => [http3]` (QPACK decodes the client's
dynamic table, responses use the static table). Remaining work:

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
- `connection_age` on h3 (small to medium): HTTP/2 connections can close
  at an age (`{http2, #{connection_age => ...}}`), HTTP/3 ones live as
  long as they are used. The h3 drain (GOAWAY on the control stream)
  already does the close; what is left is the per-connection timer with
  its jitter, the grace that resets the requests still open, an
  `{http3, #{connection_age => ...}}` opt and its tests. The rest of the
  HTTP/2 keepalive policy needs nothing on h3: the QUIC idle timeout
  (`keep_alive_timeout`) closes idle connections and a QUIC PING costs
  the server only an ACK it sends anyway, so there is no PING policy to
  enforce
- `send_stall_timeout` on h3 (medium): an HTTP/2 stream whose response
  waits for the client's flow-control window is reset after
  `send_stall_timeout`, while an HTTP/3 response waits for the client's
  stream and connection credit (MAX_STREAM_DATA, MAX_DATA) with no such
  limit, the QUIC idle timeout not firing while the client acknowledges
  packets. It crosses the QUIC connection's send buffers and flow credit
  (`roadrunner_quic_connection`) and the h3 loop: a stall clock per
  stream for its own credit and one for the connection's (so the streams
  queued behind one the client reads are not reset), a reset with
  `H3_REQUEST_CANCELLED`, an `{http3, #{send_stall_timeout => ...}}` opt
  and its tests

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
- One RTT estimate per path (RFC 9002 §5): each packet number space keeps
  its own, so the application space starts from the 333 ms initial RTT
  rather than the handshake's samples, and its first probe timeouts run
  long — small

### QUIC frames that serve no request — medium

**What:** HTTP/2's `control_frame_policy` bounds the frames that make the
server work without serving anything. HTTP/3 has no such frames of its
own worth a budget: SETTINGS may come once, there is no PING,
WINDOW_UPDATE, PRIORITY or RST_STREAM at its layer, and unknown or empty
frames are dropped with no answer, each paid for with stream data the
client sends in an encrypted packet. The QUIC layer below has some (RFC
9000 §21.9): each PATH_CHALLENGE is answered with a PATH_RESPONSE, and
PING, empty STREAM frames and repeated MAX_DATA or MAX_STREAM_DATA frames
cost a little work each. A budget per connection, counted the same way
and closing the connection past it, would match HTTP/2.

**Why deferred:** a QUIC flood costs the client one encrypted packet per
1200 bytes or so of frames, every answer is as large as what it answers,
and acknowledgments are already sent per packet, not per frame, so the
work stays in proportion to the bytes received.

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

### HTTP/3 — see above

Unlocks `baseline-h3` and `static-h3`.

### gRPC: the rest — medium

**What:** `roadrunner_grpc` serves the four call kinds over HTTP/2 and
HTTP/3 with pluggable codecs, and cancels a call at its `grpc-timeout`.
Still to come: the Hex release of the Protocol Buffers adapter,
[`roadrunner_grpc_protobuf`](https://github.com/arizona-framework/roadrunner_grpc_protobuf),
after the roadrunner release that ships gRPC; and benchmarks.

**HttpArena impact:** `unary-grpc` and `unary-grpc-tls`, the gRPC
profiles the leaderboard scores.

**Scope:** medium, in several PRs.

### gRPC interceptors — medium

**What:** an `interceptors` option for `roadrunner_grpc:routes/1` that
wraps each call with what a middleware does not know as the call
starts: the service, the method and the call kind, around the method
itself, and around each message read and sent for streams (grpc-go's
stream interceptors).

**Why deferred:** `middlewares` already covers checks ahead of a call
(auth, rate limits, values for the method) and `reject/3` answers them
with a gRPC status; a middleware reads the method from the path. A
complete interceptor wraps the stream's reads and writes too, which is
its own design.

**Scope:** medium.

## Other

### Inbound frame-rate limit per WebSocket connection — small to medium

**What:** a limit on how many frames a WebSocket client may send per
second, closing a connection that floods frames (pings, say) as HTTP/2's
`ping_policy` and `control_frame_policy` do. A session already queues
at most 17 pongs per write, and `send_timeout` closes a client that
reads none of them, but a flood still costs the server the CPU to read it and the
kernel receive buffer that holds what it has not read yet.

### Production gRPC client — large

**What:** `roadrunner_grpc_client` is a small client for tests, tooling
and simple calls. A client for production traffic needs more, each a
piece of its own:

- reconnect with backoff after the connection closes (medium)
- keepalive pings, to notice a dead connection before a call does (small)
- a name resolver and load balancing over several addresses (large)
- retries and hedging, honoring server pushback, and gRPC's service
  config (large)
- connection pooling, moving new calls to a new connection after a
  GOAWAY (medium)
- HTTP/3, over roadrunner's own QUIC (large)
- client-side interceptors (small)
- client telemetry events, like the server's call events (small)
- an interop run against a non-roadrunner server, such as grpc-go's
  interop server (medium)

**Why deferred:** the client was built for roadrunner's own tests and
tools; these matter only once it carries production traffic.

### CI performance regression check — medium

**What:** a CI job that catches a performance regression before merge.
Timing on shared CI runners is too noisy to gate on, so the check counts
work instead: for each bench scenario, the reductions, words allocated,
garbage collections and messages or socket sends per request, measured
on one connection with a fixed number of requests after a warm-up, on
`+S 1`, with `main` and the pull request built and run in the same job.
The first step is a stability check (`main` against itself, many times,
on CI and on a loaded machine); only if the counts stay within about
0.5% does the job fail a pull request past a small threshold.

**Why deferred:** counts miss native time (BIFs, NIFs, zlib, crypto, the
kernel) and scheduling effects such as accept latency, so a local
two-sided A/B stays the check before a performance-sensitive change
merges. The CI job is a safety net on top of it.

**Scope:** medium.

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

### Count a crashed connection's running handlers — medium

**What:** when a connection process crashes or is killed, the listener
takes back its request slots on the next `slot_reconciliation` tick.
The handlers it leaves running stop counting toward
`max_concurrent_requests` at that point, so until they end the server
can run that many more than the limit. With `graceful_drain => false`
there is no connection registry, so a crashed connection's slots are
not taken back at all. Counting each handler until it ends whatever
happens to its connection needs the handler registered with the slot
keeper as it starts.

**Why deferred:** registering every handler costs a message per
request, and a connection process only dies this way through a bug, a
`max_heap_size` kill or an operator; a clean close already keeps its
handlers counted until they end.

**Scope:** medium.

### Load-sensitive HTTP/2 connection-loop tests — small

**What:** many cases in `roadrunner_conn_loop_http2_tests` wait 500 ms
for the connection to send or close on a fake socket, and a few must
answer a liveness PING within a 100 ms idle timeout. On a machine with
its CPUs fully busy they fail (no send in time); they pass in normal
runs and in CI. Longer waits for sends and closes, and a larger idle
timeout where a test only needs the ordering, would make them hold
under load.

**Why deferred:** seen only under deliberate CPU starvation, never in a
gate or CI run.

**Scope:** small.

### Opt-in mailbox-proof HTTP/2 writes — small

**What:** every HTTP/2 write from a stream worker waits for the
connection's acknowledgement with a receive that scans the worker's
whole mailbox, about 4.5 ns per queued message per write. A loop handler
or gRPC method that falls behind on its own messages pays that on every
write: about 44 µs per write with 10,000 queued, and the slower it gets
the further behind it falls. Tagging the wait with a monitor of the
connection, made for that write, lets the runtime skip straight to the
reply, so a write costs about 1 µs at any queue depth. A handler or route
option would turn that on for workers that expect a backlog.

**Why deferred:** every automatic choice costs something on the common
write with an empty mailbox: checking the queue length on each write
adds 30 to 45 ns, checking it every 16th write 9 to 30 ns, and always
using the monitor tag about 250 ns. Only an explicit option is free for
handlers that never fall behind, and it is new API.

**Scope:** small.

### Cheaper parked requests in queue mode — medium

**What:** in queue mode (`overload_mode => {queue, _}`) under sustained
overload, every request goes through the listener's queue process: its
park and its grant are messages, and its connection wakes once more for
the grant. Against a queue that let new requests take freed slots first,
that measured 7.4% fewer requests a second and 7.4% more CPU per request
(128 slots, 2048 open HTTP/2 streams). A direct hand-off, where the
connection that frees a slot takes the oldest parked request off a
shared ordered table and grants it itself, would take the queue process
out of the path of each request.

**Why deferred:** it changes how slots move between connections. The
queue process now orders every grant, expiry, cancel and close one at a
time, which is what keeps each slot released exactly once; a hand-off
without it needs the same guarantee from atomic table operations.

**Scope:** medium.

### Other queue orders for sustained overload — medium

**What:** a `queue` option or a new mode that serves the newest request
first, or drops ones past a target wait (CoDel-style, where `timeout` is a
fixed deadline): most requests stay fast when clients time out early, but
the oldest can wait out their whole `timeout`. Only for a measured need;
first in, first out stays the default.

**Scope:** medium.

### Answer parked HTTP/2 requests when a listener stops — small

**What:** `roadrunner_listener:stop/1` takes the listener's queue process
down with it, while HTTP/2 connections, which are not linked to the
listener, live on (HTTP/3 ones go down with their QUIC connections). On a
surviving connection, a request that was parked never hears back, nor
does the first one over the ceiling after the stop. Once the count of
parked requests is up (from a request parked before the stop, or the
first one over the ceiling after it), it stays up, so every later request
on every surviving connection parks and hangs too, under the ceiling as
well, until its client gives up. Connections could watch the queue
process from their first park (a watch set after it is gone fires at
once) and, once it is gone, refuse what they have parked and refuse
instead of parking. `drain/2` is not affected while `graceful_drain` is
on (the default): the queue process outlives the connections it waits
for, and the deadline kills the rest first. With
`graceful_drain => false` the deadline kills nobody, so a drain that runs
out ends like `stop/1`.

**Why deferred:** found in review of the queue's first in, first out
fix, which made it reach requests under the ceiling too (before, only
requests over it parked), and it needs the HTTP/2 loop to tell the queue
process's `DOWN` from its workers'.

**Scope:** small.

### Cheaper accepts under load — medium

**What:** acceptors run at high priority by default (`accept_priority`)
and, on a plain-TCP listener on Linux or FreeBSD, each has a listen
socket of its own (`num_listen_sockets`), so a busy server takes new
connections in promptly and in parallel. Each accept still costs the acceptor a few
round trips: `gen_tcp:accept` reads 11 options off the listen socket and
writes them to the new one, and `controlling_process` hands the socket
over; on a TLS listener it also waits on the `ssl` application's own
processes, which run at normal priority. The acceptor could become the
connection and spawn its replacement instead (no handoff).

**Why deferred:** the listen sockets already remove the shared-socket
wait; the remaining cost is per connection, and removing it changes the
acceptor pool's design.

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

### Per-route `body_buffering` — large

**What:** Let a route pick `auto` or `manual` body buffering, in place of
the listener's. A gRPC service wants `manual` so streams really stream,
while the other routes on a listener that serves both HTTP/1.1 and HTTP/2
on one port usually want `auto`.

**Why deferred:** on HTTP/2 and HTTP/3 the connection decides from the
listener's mode when to start a stream's worker (at the end of the headers
or of the body), and the worker is what resolves the route, so the choice
has to move to after routing. Today a gRPC listener of its own is the
workaround.
A route's `max_content_length => infinity`, which holds only for bodies
read as they arrive, would then follow the route's mode in place of the
listener's (`roadrunner_router:compile/3`).

**Scope:** large.

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
