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

**Practical impact today:** zero in browsers — they default to h1
for `WebSocket()` even on h2-capable origins. Only matters if the
client explicitly speaks h2 WS.

**Scope:** large — adds a whole protocol-layer feature plus full
Autobahn re-run.

**Source:** Arizona handoff R-h2-1.

## HTTP/3 follow-ups

h3 shipped experimentally (`protocols => [http3]`, QPACK static-table
only). Remaining work:

- h3 manual-mode body reading (parity with the deferred h2 item) —
  needs the same conn-loop→worker inbound routing WebSocket would, so
  do it alongside that work, not standalone
- WebSocket over h3 (`websocket` shape, still `501`) — RFC 9220
  Extended CONNECT; do WebSocket over h2 (RFC 8441) first, since it's
  the more common transport and h2 has no WebSocket either
- QPACK dynamic table (non-zero capacity) — the `quic` dep has the full
  RFC 9204 machinery; the work is wiring encoder/decoder streams +
  section acks + blocked-stream buffering into the owned conn loop
- HttpArena `baseline-h3` / `static-h3` profiles (the local
  `scripts/bench.escript` h3 path is wired and measured; these live in
  the separate `MDA2AV/HttpArena` repo)
- WebTransport / Extended CONNECT (RFC 9220) and HTTP datagrams
  (RFC 9297), both already provided by the dep
- A scheduler-scaled default for the reuseport pool size
  (`{http3, #{listeners => N}}`, validated `1..1024`, default 8,
  `1` = no pooling); currently unmeasured
- Full RFC 9000 connection-ID rotation: issuing spare server CIDs and
  registering them so packets using them route. A currently-unwired
  dep feature, a deliberate upstream effort if wanted

## Native QUIC transport follow-ups

The HTTP/3 path now runs on the native `roadrunner_quic_*` stack (the `quic`
dep is a test-profile differential oracle + CT client only). The RFC MUSTs a
browser depends on are implemented; the items below are conformance hardening
and transport completeness that a real browser GET / POST does not need.

### SHOULD/MAY conformance — harden against non-conformant peers

A conformant browser / quiche / ngtcp2 never trips these; they tighten the
advisory or malformed cases the server currently tolerates or omits.

- Report a real ACK Delay (always 0 today) and advertise `ack_delay_exponent`
  / `max_ack_delay` (RFC 9000 §13.2.5) — small-medium
- Intersect the client's offered cipher / TLS version (`supported_versions`) /
  group (`supported_groups`) against the hardcoded `TLS_AES_128_GCM_SHA256` /
  TLS 1.3 / x25519, aborting on no overlap (RFC 8446 §4.1.1) — medium
- Emit a reserved "GREASE" setting in the h3 SETTINGS frame (RFC 9114
  §7.2.4.1) — small
- Honor the peer's `SETTINGS_MAX_FIELD_SECTION_SIZE` when sizing response
  headers (RFC 9114 §4.2.2) — small-medium
- Reject non-zero packet reserved bits as PROTOCOL_VIOLATION after
  header-protection removal (RFC 9000 §17.2 / §17.3.1) — small

### Transport completeness — bites large transfers / advanced cases

- Send-side flow control: seed send windows from the peer's advertised
  transport params, process inbound `MAX_DATA` / `MAX_STREAM_DATA`, grant
  outbound `MAX_DATA` / `MAX_STREAM_DATA`, and emit `DATA_BLOCKED` /
  `STREAM_DATA_BLOCKED` (RFC 9000 §4). Each window is seeded from our own
  advertised value and never raised, so a transfer past the initial grant
  stalls; the suite max is 100 KB, well under it — medium
- Respond to a peer-initiated key update (RFC 9001 §6). Security-sensitive:
  trial-decrypt the next-phase keys and commit ONLY on success (not the dep's
  commit-then-decrypt, which a single forged flipped-bit datagram desyncs),
  keep the header-protection key fixed, enforce the AEAD integrity limit —
  large
- Draining state: linger ~3×PTO to absorb the peer's reordered packets before
  close, and reject `send_data` on a draining connection (RFC 9000 §10.2) —
  medium
- Seed the idle timeout from the negotiated `max_idle_timeout` (a fixed 30s
  today) (RFC 9000 §10.1) — small-medium
- NewReno congestion control (RFC 9002 §7); needs the loss layer to surface
  acked bytes + sent times. Sending is bounded only by the §8.1
  anti-amplification limit and flow control today — large
- A no-flatten / by-reference stream send buffer, so a large response body is
  not flattened into one binary before sending — medium

### Retire the dep

- Build a native QUIC test client so the `quic` dep can leave the test profile
  too; the h3 SUITE + bench drive the native server with the dep's client, its
  last remaining use — large
- Then move `quic` out of production `deps` into `profiles.test.deps` and drop
  it from the dialyzer `plt_extra_apps`, so production deps become
  `[telemetry]` — small

### Known dep deviation (informational)

The `quic` dep's QPACK static table has a `:age` typo at index 2 (RFC 9204
Appendix A is `age`, no colon). The native stack is RFC-correct, so this entry
is the one place the dep oracle cannot validate the native encode/decode; not a
roadrunner bug, recorded so a future dep cross-check does not "correct" the
native value back to the dep's.

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

### Connection-process memory tuning follow-ups

**What:** The `handler_spawn` listener opt already exposes the full
`proc_lib:start/5` spawn config (`opts` + `start_timeout`) for every
handler-running process, defaulting to `[{fullsweep_after, 0}]`.
Remaining polish:
- a named convenience opt (e.g. a top-level `max_heap_size`) if the
  raw `opts` passthrough proves clumsy in practice
- characterize the `+MHacul 0 +MBacul 0` allocator-carrier-release
  tradeoff before recommending it anywhere: it lowers resident memory
  but raises allocator↔OS traffic and can hurt throughput at high core
  counts, so it is workload-dependent, not a blanket win (the
  `handler_spawn` doc now says as much)
- revisit whether `fullsweep_after, 0` should stay the default: it is
  free on allocation-heavy handlers but costs ~3-4% on trivial
  passthrough, so an adaptive policy (or a different default) may be
  better once measured on more workloads
- verify the per-process memory win extends to the HTTP/2 and HTTP/3
  stream-worker processes under load (validated so far on the h1
  connection process)

**Why deferred:** the passthrough plus default already capture a
substantial, workload-dependent process-memory reduction on
allocation-heavy handlers; these are refinements that each want their
own measurement before shipping.

**Scope:** small.

### h2 receive-window defaults

**What:** Bump the listener's default receive-window peaks above the
RFC 9113 §6.9.2 baseline of 65535. Override knobs already exist as
nested `http2` sub-opts (`conn_window`, `stream_window`,
`window_refill_threshold` under `protocols => [{http2, #{...}}]`);
the question is what values to ship as the default.

**Why deferred:** `window / RTT` caps per-stream throughput, and at
65535 with a 100 ms RTT the ceiling is ~0.6 MB/s. Reference points
for the bumped defaults: gun 8 MB / 8 MB, Mint (post-PR) 16 MB /
4 MB, Go net/http2 1 GB / 4 MB, h2o 16 MB+. The trade-off for a
**server**: a larger conn-level peak means each peer can hold up
to that many in-flight bytes before back-pressure, multiplied by
`max_clients`. Worst-case memory pressure at `max_clients = 100k`
× `16 MB conn peak` is ~1.6 TB — small VPS deployments would
notice. Mint's bench was a CLIENT (one app's connection pool),
where the multiplier is smaller.

For now the listener opts let users opt in per-deployment. A
default change wants its own benchmarking against roadrunner-shape
workloads (server-side, large-POST upload patterns) before shipping.

**Scope:** small (one-line default change + ~50 test sites that
have to drain the new SETTINGS entry + early WINDOW_UPDATE in
their handshake fixture).

### Advertise SETTINGS_MAX_HEADER_LIST_SIZE

**What:** Advertise `SETTINGS_MAX_HEADER_LIST_SIZE` (RFC 9113 §6.5.2,
id 0x06) in the server's SETTINGS frame. The cumulative HEADERS +
CONTINUATION block is now capped (16384-byte default, GOAWAY(ENHANCE_YOUR_CALM)
on overflow, the same way h1 and h3 bound it), which closes the
CONTINUATION-flood memory gap. Advertising the decoded-size limit lets
conformant clients avoid sending an oversized block in the first place
rather than learning via the connection close.

**Why deferred:** The setting bounds the *decoded* header-list size, a
different unit from the encoded-block cap that does the real memory
bounding, so it is an advisory courtesy rather than the load-bearing
fix. The h3 sibling (`SETTINGS_MAX_FIELD_SECTION_SIZE`, under the
HTTP/3 follow-ups above) wants the same treatment.

**Scope:** small-to-medium. `server_settings_frame/1` in
`roadrunner_conn_loop_http2.erl` adds `{6, Limit}`; the setting already
exists defaulted to `infinity` in `roadrunner_http2_settings.erl` and the
encoder skips `infinity`, so advertising it meaningfully needs a concrete
value to ship and (to be truthful) decode-side enforcement, since today we
only parse the peer's value and bound inbound via the encoded
`max_header_block` cap. The ~50 handshake fixtures that drain the server
SETTINGS need to tolerate the extra entry.

### Refresh resource_results.md against the current headline scenarios

**What:** `docs/resource_results.md` still carries its own scenario
pick (captured 2026-05-06) predating the curated `?MAIN_SCENARIOS` in
`scripts/bench.escript`: it is missing `multi_request_body`,
`post_4kb_form`, `large_post_streaming`, `streaming_response` and still
lists the dropped `cookies_heavy` / `tls_handshake_throughput`.
`comparison.md` was resynced to `?MAIN_SCENARIOS`; the README quick-look
table and the bench-script-driven docs (`bench_results.md`,
`wrk2_results.md`) were already current.

**Why deferred:** the resource doc's memory / CPU numbers are a
single-run snapshot that can only be refreshed by re-running
`scripts/bench.escript --with-resources` against the current 14
scenarios, not edited by hand. Fold it into the next matrix run rather
than re-running the bench just for this.

**Scope:** small (one `--with-resources` matrix pass + re-render the
three tables and trim the dropped-scenario notes).

### Automate `docs/resource_results.md` regeneration

**What:** Extend `scripts/bench_matrix.sh` so it can pass
`--with-resources` to every cell and emit a refreshed
`docs/resource_results.md` alongside `bench_results.md`. Today the
resource doc is hand-curated from a one-off survey.

**Why deferred:** doable but ~80–120 LOC of awk/bash for the
parser + emitter; the doc is checked-in snapshot-style and rarely
needs full regeneration. Automating earns its keep once we're
chasing a regression that needs frequent refresh.

**Scope:** small.

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

### h2 manual-mode body reading

**What:** Parity with the h1 manual-mode body reader for h2 streams
(streaming an arbitrarily large body without buffering it in memory
on the worker process before the handler sees it).

**Why deferred:** the h2 stream-worker today buffers the full body
before dispatching the handler (h2 framing already chunks the wire
bytes; we just don't expose that to the handler yet). Auto-mode is
the only mode on h2.

**Scope:** small-medium when needed. No present caller is blocked.

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

### Cancel a handler on client disconnect — medium

**What:** Signal a running handler when the client goes away. For
`{loop, ...}` (SSE / long-poll) and streaming handlers that block in
`receive` or keep producing chunks after the request, deliver a
`{roadrunner_disconnect, _}` message (or expose a monitor) the moment
the connection closes, so the handler can drop pubsub subscriptions and
stop expensive work instead of discovering the dead socket only on its
next write.

**Why deferred:** ordinary request/response handlers finish before the
client can leave, so they never need it; it only matters for the
long-lived streaming shapes, and none has a caller blocked on it today.

**Scope:** medium. The conn loop already owns the socket so it can watch
for close; the work is routing that into the loop/stream lifecycle
across h1, h2, and h3 without racing the normal finish path.

### NDJSON streaming response builder — small

**What:** A first-class newline-delimited-JSON response, the JSON
sibling of `roadrunner_sse`: a builder that frames each item as one
`<json>\n` chunk over the existing chunked-streaming path, for streaming
list endpoints and token-by-token responses.

**Why deferred:** the chunked-streaming primitive already lets a handler
emit NDJSON by hand; a named builder is ergonomics, worth adding once a
handler wants the framing (and the `application/x-ndjson` content type)
for free.

**Scope:** small. A thin wrapper over the streaming response shape plus
the content-type default.

### PROXY protocol for the real client address — medium

**What:** Parse the PROXY protocol header (v1 text and v2 binary) that a
TCP load balancer (haproxy, AWS NLB, and friends) prepends before the
first request byte, and populate `roadrunner_req:peer/1` with the real
client address instead of the balancer's. Opt-in per listener, since
trusting that header from an untrusted peer would let a client spoof its
own address.

**Why deferred:** direct-to-internet and TLS-terminating-proxy
deployments do not need it (the socket peer is already the client, or the
proxy speaks HTTP and can set `Forwarded`). It matters specifically
behind an L4 balancer, where today the peer address is the balancer's.
Real-IP-aware logging, the per-peer rate guard, and any geo or authz
keyed on client IP all depend on it.

**Scope:** medium. A pre-request parse stage on accept (gated by a
listener opt), plus threading the parsed address into the request's peer
field across h1, h2, and h3.

## Per-route framework knobs the map shape unlocks

The map-shape route entry (`#{path => ..., handler => ..., state =>
..., middlewares => [...]}`) is intentionally extensible — new
top-level keys add new per-route capabilities without breaking
existing routes. None of the below is wired up yet; the map shape
is ready when one of these has a real caller behind it.

### Per-route `name => atom()` for telemetry / reverse routing — small

**What:** Let a route declare a stable name (e.g. `name =>
users_show`) and surface it in telemetry metadata (`[roadrunner,
request, start | stop | exception]`) plus expose a
`roadrunner_router:url_for/2,3` for reverse-resolving the name back
to a path.

**Why deferred:** no telemetry consumer asking for it today.
`(listener_name, method, path)` is already enough to identify a
route in dashboards; named lookup is a niceness, not a need.

### Per-route `methods => [binary()]` allowlist with automatic 405 — small

**What:** `methods => [~"GET", ~"PUT"]` on a route map means the
framework returns `405 Method Not Allowed` (with the right `Allow`
header) for any other method on that path. Eliminates the
boilerplate every handler currently writes to gate on
`roadrunner_req:method/1`.

**Why deferred:** simple to bolt on once a couple of real handlers
demonstrate the pattern they want. The single-route equality check
is the wrong model for catch-all routes (`/api/*path`) that
multiplex methods downstream.

### Nested route groups with shared prefix + middlewares — medium

**What:** Phoenix-style scope / pipeline:

```erlang
[#{prefix => ~"/api", middlewares => [auth_mw], routes => [
    #{path => ~"/users/:id", handler => users_show},
    #{path => ~"/posts/:id", handler => posts_show}
 ]}]
```

The framework flattens these at compile time into the existing
linear route list, concatenating the prefix and prepending the
group's middlewares to each leaf route.

**Why deferred:** the flat list is fine until the route table has
shared per-section middlewares (auth, rate limit, body-limit
overrides) duplicated across many entries. Add when a real codebase
shows that duplication.

## Built-in edge middleware

The continuation-middleware model (`call(Req, Next, State)`, configured
per entry via `{Module, State}`) makes browser-facing and abuse-control
concerns composable at the listener or per-route level. Each is
boilerplate every public service rewrites today; shipping configurable,
default-safe versions removes it. None is wired yet.

### CORS middleware — small-medium

**What:** A configurable `roadrunner_cors` middleware: origin allowlist
or predicate, allowed methods and headers, credentials, exposed headers,
max-age, an `OPTIONS` preflight short-circuit with the right
`Access-Control-*` headers, and a cache-correct `Vary: Origin`.

**Why deferred:** every browser-facing service needs it, but the exact
policy is app-specific, so it stays unwired until a real caller drives
the shape rather than a guess. The middleware slot is ready.

**Scope:** small-medium. The preflight branch plus header echoing is the
bulk; `Vary` correctness mirrors `roadrunner_compress`.

### Security-headers middleware — small

**What:** A `roadrunner_security_headers` middleware that applies a
default-safe set on every response: `X-Content-Type-Options: nosniff`,
frame options, referrer policy, `Strict-Transport-Security` on TLS
listeners, and opt-in CSP. Every value overridable; a header the handler
already set wins.

**Why deferred:** trivial to hand-roll, but it is the same dozen lines in
every service; a curated default earns its keep once one service asks.

**Scope:** small.

### Conditional requests for dynamic responses — small

**What:** A `roadrunner_etag` middleware that derives a (strong or weak)
`ETag` from the handler's response body, or honors one the handler
already set, and turns a matching `If-None-Match` into a bodyless `304
Not Modified`. The same ETag / `If-None-Match` logic the static handler
already runs, lifted to apply to dynamic handler responses.

**Why deferred:** static assets already get conditional requests via
`roadrunner_static`; extending it to dynamic responses saves bandwidth on
read-heavy JSON endpoints, but wants a real caller to confirm the hashing
cost is worth it at their response sizes.

**Scope:** small. Reuses the static handler's ETag and `If-None-Match`
comparison; the new part is hashing the dynamic body and the 304 path.

### Per-peer request-rate guard — medium

**What:** A token-bucket abuse guard keyed by peer (the real client IP,
accurate behind a proxy once PROXY-protocol support lands), answering
`429 Too Many Requests` with `Retry-After` when one peer exceeds a
configured request rate. It belongs to the same DoS-protection family as
the slowloris `min_bytes_per_second` guard and `max_clients`: it stops a
single source monopolizing the server rather than enforcing application
quotas.

**Why deferred:** the existing caps already bound total load; per-peer
fairness matters once a deployment sees one source flooding it. The
per-peer bucket state (an `atomics` / ETS store) wants a clean ownership
and sweep story before it ships. Richer per-user or per-route quota
policy is application logic, expressed above the server.

**Scope:** medium. The bucket math is small; the per-peer store and its
sweep are the bulk.

### Graceful load-shedding — small-medium

**What:** Turn the hard `max_clients` / `max_concurrent_requests` caps
into a graceful shed: over a soft threshold, answer `503 Service
Unavailable` with `Retry-After` instead of refusing the connection, so
clients back off cleanly rather than hammering a closed port.

**Why deferred:** the hard caps already protect the server from overload;
graceful shedding is a client-experience refinement, useful once a
deployment reports clients retry-storming a refused port.

**Scope:** small-medium. Reuses the existing slot counters; the work is
the soft-threshold check and the 503 path on the conn loop.

## Deferred to the application layer

Capabilities that are real, but sit above the HTTP server core: in
whatever application, framework, or library runs on top of roadrunner.
That could be a framework (Arizona is one), a third-party library, or the
service's own code. Roadrunner deliberately stops at the HTTP layer and
hands these up. It supplies the mechanism, an ordered middleware slot,
immutable request and response values, and `telemetry` events; the layer
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
- **Observability backends.** Roadrunner emits `telemetry` events with
  zero overhead when nothing is subscribed; exporting them as traces and
  metrics to a chosen backend (OpenTelemetry, Prometheus, and the like)
  is an integration the layer above wires up.
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
