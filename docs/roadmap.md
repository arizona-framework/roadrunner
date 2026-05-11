# Roadmap

Items deferred past v0.1. Each carries a short rationale and a
rough effort estimate so you know what's on deck and what's
"someday".

## HTTP/2 response-shape coverage

Today, three of the five handler return shapes return `501 Not
Implemented` when served over HTTP/2 (`src/roadrunner_conn_loop_http2.erl`
moduledoc has the matrix). All three are tracked here.

### `{sendfile, _}` over h2 — small effort

**What:** Allow a handler to return `{sendfile, Status, Headers,
{File, Offset, Length}}` and have it work over h2.

**Why deferred:** h2 has no kernel sendfile path — every byte must
go through HPACK (for headers) and DATA framing. The implementation
is a chunked-read-and-frame loop honoring per-stream and conn-level
flow control. Doable; just lower priority than other items because
the perf upside vs. a buffered response is smaller on h2 than on h1.

**Scope:** small. Tests cover happy path, large file (>64 KB so
multiple DATA frames), small initial window (flow-control split),
file-open errors.

### `{loop, _}` over h2 — medium effort

**What:** Allow a handler to return `{loop, Status, Headers,
State}` and run a long-lived handler with `handle_info/3` callbacks
(SSE-style push) over h2.

**Why deferred:** the h2 stream worker today does request → response
→ exit. Implementing `{loop, _}` means teaching the worker to enter
a selective-receive loop, dispatch process messages to
`Handler:handle_info/3`, and emit DATA frames per push (with the
conn process mediating socket writes for ordering + flow control).
It also has to cooperate with peer `RST_STREAM` cancellation and h2
flow-control windows. Not protocol-hard — just code we haven't
written.

**Workaround today:** `{stream, _}` works on both h1 and h2 and is
a better cross-protocol primitive for most push workloads.

**Scope:** medium. Tests cover happy path, server-initiated close,
peer-initiated `RST_STREAM`, mid-loop flow-control bursts,
`handle_info/3` returning `{ok, NewState}` / `{stop, _}` /
`{reply, NewState}`.

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

## HTTP/3 — placeholder

**What:** RFC 9114 (HTTP semantics over QUIC) listener path.

**Why deferred:** OTP doesn't ship a QUIC stack, and the
production options are imperfect:

- [`quicer`](https://github.com/emqx/quicer) — NIF over Microsoft's
  `msquic`. Mature, fast. Trade-off: a C dep + NIF means it breaks
  the "pure-Erlang" property roadrunner currently markets.
- [`erlang_quic`](https://github.com/benoitc/erlang_quic) — Benoît
  Chesneau's **pure-Erlang** RFC 9000/9001 + RFC 9114 implementation,
  Apache-2.0 (declared in the project README). Already has a full h3
  server with QPACK (RFC 9204), HTTP datagrams (RFC 9297), Extended
  CONNECT (RFC 9220 / WebTransport), server push, RFC 9218
  priorities. Min OTP 26. Zero runtime deps. Tagged through v1.3.0.
  Looks like the right architectural fit. Worth filing an upstream
  PR adding a `LICENSE` file at repo root so dep tooling and
  GitHub's license API pick it up automatically; the README
  declaration is unambiguous but unconventional.

`--protocol h3` in `scripts/bench.escript` is currently a stub;
ALPN advertisement does not include `h3`.

**Scope:** medium-large. Wiring is mostly: ALPN advertise `h3`,
route h3 traffic to a new `roadrunner_conn_loop_http3` that adapts
`erlang_quic`'s stream events to our handler / middleware /
telemetry surface. Most of the protocol-heavy work is already done
by the dep.

## HttpArena coverage gaps

The HttpArena Erlang submission (`frameworks/roadrunner/` in
`MDA2AV/HttpArena`) covers 16 of HttpArena's 28 profiles: baseline,
pipelined, limited-conn, json, json-comp, json-tls, upload,
async-db, api-4, api-16, static, fortunes, crud, baseline-h2,
echo-ws, echo-ws-pipeline. Validator passes 57/57 on those. The
remaining 12 profiles need roadrunner-side features; listed in
roughly the order a follow-up PR would tackle them.

### `static` gzip-sibling serving — small (roadrunner-side)

**What:** When `Accept-Encoding: gzip` is present and `<file>.gz`
exists, serve the pre-compressed sibling with
`Content-Encoding: gzip`. nginx's `gzip_static on`.

**Why:** The HttpArena `static` fixture ships `.gz` siblings.
Without sibling-serving, every static response either passes the
raw bytes (uncompressed wire) or runs through the on-the-fly
compress middleware (CPU per request). Sibling-serving sends the
pre-encoded bytes verbatim. The validator marks this as SKIP today
(compression is optional for correctness); the benchmark numbers
would improve with it.

**Scope:** small. One file existence check on the request path,
swap the file plus add headers.

### `static-h2` — covered by `{sendfile, _}` over h2 above

### h2c (HTTP/2 cleartext) — small/medium (roadrunner-side)

**What:** Accept HTTP/2 on a plaintext listener, either via
prior-knowledge (client opens with the h2 connection preface
directly on a dedicated port) or RFC 7540 §3.2 `Upgrade: h2c`.

**Why deferred:** The current h2 path is gated by TLS ALPN
negotiation in `roadrunner_listener`. h2c needs either a listener
opt that forces every accepted connection through the h2 state
machine without TLS, or first-byte sniffing for the HTTP/2 preface
(`PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n`) on a shared port.

**HttpArena impact:** `baseline-h2c` and `json-h2c`.

**Scope:** small for prior-knowledge on a dedicated listener,
medium with preface sniffing.

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

### `gateway-64`, `gateway-h3`, `production-stack` — out of scope

Reverse-proxy multi-container setups (nginx, caddy, or envoy in
front of the framework). Bench-app docker-compose work, not a
roadrunner gap.

## Other

### h2 receive-window defaults

**What:** Bump the listener's default receive-window peaks above the
RFC 9113 §6.9.2 baseline of 65535. Override knobs already exist
(`h2_initial_conn_window`, `h2_initial_stream_window`,
`h2_window_refill_threshold` on `roadrunner_listener:opts()`); the
question is what values to ship as the default.

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

### Investigate small-body POST RSS gap

**What:** A `--with-resources` survey (see `docs/resource_results.md`)
shows roadrunner using **+51 % RSS** vs cowboy on `post_4kb_form` and
**+17 %** on `echo` (256-byte body). The hot-path GETs and large-body
streaming scenarios don't show this gap — only small-body POST.

**Why deferred:** the likely cause is the per-request `body_state`
machinery + manual-mode reader being allocated even for auto-mode
small-body workloads. Investigation needs fprof under load to
confirm the allocation site, then a targeted fix (e.g. lazy
allocation of the body-state map / reader closures only when the
handler opts into manual mode). Single most actionable resource
finding from the survey.

**Scope:** medium — fprof + targeted refactor + A/B precommit
verification.

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

### h2 manual-mode body reading

**What:** Parity with the h1 manual-mode body reader for h2 streams
(streaming an arbitrarily large body without buffering it in memory
on the worker process before the handler sees it).

**Why deferred:** the h2 stream-worker today buffers the full body
before dispatching the handler (h2 framing already chunks the wire
bytes; we just don't expose that to the handler yet). Auto-mode is
the only mode on h2.

**Scope:** small-medium when needed. No present caller is blocked.

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

## Tracking

Updates to this file accompany the related code change. When an
item lands, move it from here to a "Done" section in the relevant
investigation doc (e.g. `docs/conn_lifecycle_investigation.md`
already serves that purpose for perf wins).
