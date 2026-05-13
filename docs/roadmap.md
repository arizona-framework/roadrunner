# Roadmap

Items deferred past v0.1. Each carries a short rationale and a
rough effort estimate so you know what's on deck and what's
"someday".

## HTTP/2 response-shape coverage

Today, one of the five handler return shapes still returns `501 Not
Implemented` when served over HTTP/2 (`src/roadrunner_conn_loop_http2.erl`
moduledoc has the matrix). It's tracked here.

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

`--protocols h3` in `scripts/bench.escript` is currently a stub;
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
remaining 10 profiles need roadrunner-side features; listed in
roughly the order a follow-up PR would tackle them. (`baseline-h2c`
and `json-h2c` are reachable once the HttpArena SHA pin bumps and
the bench app subscribes; the underlying h2c prior-knowledge
support shipped in `roadrunner_listener`'s `protocols => [http2]`
opt on plaintext listeners.)

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

### `gateway-64`, `gateway-h3`, `production-stack` — out of scope

Reverse-proxy multi-container setups (nginx, caddy, or envoy in
front of the framework). Bench-app docker-compose work, not a
roadrunner gap.

## Other

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

### Sendfile chunk size tracks the peer's negotiated MAX_FRAME_SIZE

**What:** Today `?SENDFILE_CHUNK_SIZE` in
`src/roadrunner_http2_stream_worker.erl` is pinned at 16384, the
RFC 9113 §6.5.2 default for `SETTINGS_MAX_FRAME_SIZE`. Peers can
advertise up to `16777215` in their SETTINGS frame; gun, h2o, and
other clients routinely raise it. Reading the peer's actual
negotiated value (already tracked at
`roadrunner_http2_settings:settings.max_frame_size`,
`src/roadrunner_http2_settings.erl:47`) and using it as the cap in
`sendfile_loop/3` would let large sendfile responses ship fewer,
larger DATA frames.

**Why deferred:** Per-DATA-frame overhead is 9 bytes of header vs
payloads typically thousands of bytes long, so the bandwidth win is
sub-1%. Plumbing the peer's settings into the stream worker also
isn't trivial: the worker is handed `(ConnPid, StreamId, ...)` at
spawn time, not the conn's per-stream peer-settings view, so the
handoff path needs a new field. No measured case yet where the
framing overhead matters.

**Scope:** small once measured. Add the peer `max_frame_size` to
the stream worker's spawn args (or a fetch-on-demand call into the
conn); replace `min(Remaining, ?SENDFILE_CHUNK_SIZE)` with
`min(Remaining, PeerMaxFrameSize)` in `sendfile_loop/3`. One new
test in `roadrunner_conn_loop_http2_tests` that advertises a higher
`MAX_FRAME_SIZE` in the client SETTINGS and asserts the resulting
DATA frames scale up accordingly.

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

### CI bench-vs-baseline comparison

**What:** The `Bench` workflow (`.github/workflows/bench.yml`) writes
its result to the workflow step summary only. A follow-up would upload
the bench output as an artifact and add a comparison step (or
dashboard) that diffs a PR run against a baseline (e.g. `main` HEAD)
and surfaces the delta.

**Why deferred:** GH free runners are too noisy for automated
regression gating (deltas under ~15 % are inside variance per
`scripts/bench.escript`'s own NOTE). A useful comparison needs a
baseline-collection strategy that filters noise (multi-sample on
both sides, distribution stats, alerting only on shifts well outside
variance). Eyeball-from-summary covers the v1 use case.

**Scope:** medium. The artifact upload is a few lines; the parser,
distribution stats, baseline storage, and presentation are the bulk.

### Proper OTP citizenship in loop responses

**What:** Both `roadrunner_loop_response:info_loop/4` (h1) and
`roadrunner_http2_loop_response:info_loop/5` (h2) silently drop
`{system, _, _}`, `{'$gen_call', _, _}`, and `{'$gen_cast', _}`
messages. A more polite implementation would call
`sys:handle_system_msg/6` on the system message, reply to gen-calls
with `gen:reply(From, {error, not_supported})`, and so on.

**Why deferred:** the conn (h1) and worker (h2) are plain
`proc_lib`-spawned loops, not `gen_*` behaviours, so the only path
for these shapes to reach them is misuse (`gen_server:call(ConnPid, _)`
or `sys:get_state(ConnPid)`). The current contract is "those calls
appear to hang; the caller should expect to time out", documented
in the `roadrunner_loop_response` moduledoc. Proper handling would
make these calls observable (e.g. `sys:get_state/1` would return the
loop state), which has debugging value but no functional fix.

**Scope:** small. New helper `roadrunner_loop_sys` exporting a
single `handle/3` (sys message, From, ProcessState) used from both
h1 and h2 info_loops. Tests covering sys/get_state, sys/replace_state,
gen_call rejection, gen_cast no-op.

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
