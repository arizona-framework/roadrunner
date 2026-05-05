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

## Other

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
