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

## HTTP/3

**Phase 1 shipped:** a roadrunner-owned HTTP/3 listener over QUIC
(RFC 9114). Enable it with `protocols => [http3]` (requires `tls`,
since QUIC mandates TLS 1.3); it co-listens with `http1` / `http2` on
the same port number (TCP for h1/h2, UDP for h3). roadrunner owns the
listener and the connection loop (`roadrunner_conn_loop_http3`),
applying its own rules (slot tracking, drain group, telemetry,
dispatch, response shapes, per-stream crash isolation). It leans on
the pure-Erlang [`quic`](https://github.com/benoitc/erlang_quic)
dependency only as a transport + codec helper layer (`quic` /
`quic_listener` for the QUIC transport, `quic_h3_frame` / `quic_qpack`
for h3 framing and QPACK), not its turnkey `quic_h3` server, mirroring
how roadrunner owns its own HTTP/1.1 and HTTP/2 stacks. `quic` is
started on demand, so HTTP/1.1/HTTP/2-only deployments never boot it.

Every non-WebSocket response shape works — buffered, `stream`,
`sendfile`, and `loop` — with `HEAD` requests returning headers and no
body; QPACK runs static-table only
(`qpack_max_table_capacity = 0`). A conformance pass followed,
bringing the owned connection loop in line with RFC 9114 / 9204:
request-stream frame ordering, peer control / QPACK stream validation,
GOAWAY on graceful drain, the matching connection error codes, an
explicit per-connection request-stream cap, `certs_keys` / cert-chain
TLS config, a shared `Date` header across h1/h2/h3, and `Alt-Svc`
advertising on the co-served h1/h2 responses so browsers upgrade from
TCP to QUIC. `quic` is a young (1.x) dependency, so treat HTTP/3 as
experimental for now.

**Performance (per-request cost):** h3's per-request cost is dominated by
the `quic` dependency's transport, not roadrunner. A whole-node profile
(`--profile-scope all`, eprof and fprof cross-checked) puts roadrunner's
own h3 code (conn loop + stream workers) at ~1.5-2.5% of server CPU,
while ~90% is the dep's pure-Erlang packet/frame processing, AEAD framing
plus `crypto` NIFs (~17%), and QPACK (~5%). So optimizing roadrunner's h3
hot path can't move per-request throughput (a QPACK-huffman encoder
rewrite and a buffered-send async-cast swap were both evaluated and
dropped on this basis), and reimplementing QUIC in roadrunner isn't
justified. The lever there is a faster transport (upstream `quic` work or
a NIF / kernel-assisted stack), out of scope for now.

**Scalability (fixed):** a single QUIC listener received and demuxed
every inbound datagram, so h3 throughput FELL under load (closed-loop
hello: 31.7k req/s at 50 clients down to 21.5k at 400, CPU stuck at
~10/24 cores) - inbound serialization, not per-request cost. Serving h3
over the dep's existing reuseport listener pool (`quic_listener_sup` with
`pool_size`; the kernel spreads datagrams across N listeners that share
one connection registry) recovers multi-core scaling: 36.2k at 50
clients, 33.4k at 400 (+14% / +55%), and the under-load drop shrinks from
32% to 8%. No dep change - the pinned hex `quic` already ships the pool.

Open h3 perf follow-ups:
- The pool size is configurable via `{http3, #{listeners => N}}`
  (validated `1..1024`, default 8, `1` = no pooling); a scheduler-scaled
  default is a possible future tweak but is currently unmeasured
- Reuseport routes by the kernel's 4-tuple hash, so a client that
  MIGRATES to a server-issued CID could land on a shard that doesn't know
  it: the dep registers only the initial CIDs in the shared table
  (stable-address benches are unaffected). Dep-side fix: register
  `NEW_CONNECTION_ID`s in the shared table, or `quic_lb`-encode a shard
  index into them

**Follow-ups:**

- Wake an h2 worker blocked in its send-`sync` when the conn dies. The
  idle `{loop, _}` leak (worker parked in `info_loop`) is fixed on both
  h2 and h3 (the worker monitors the conn and stops on its `DOWN`), but
  an h2 worker stalled in `sync/1` waiting for a frame ack still blocks
  until the connection's QUIC/TCP teardown reaps it; a uniform fix
  (e.g. the conn loop killing in-flight workers, or `sync` honoring the
  monitor) would close the narrow remaining window for `stream` + `loop`
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

### Small-body POST RSS gap — investigated, it's the keep-alive GC trade-off

**What:** A `--with-resources` survey (see `docs/resource_results.md`)
shows roadrunner using **+51 % RSS** vs cowboy on `post_4kb_form` and
**+17 %** on `echo` (256-byte body). The hot-path GETs and large-body
streaming scenarios don't show this gap — only small-body POST.

**Investigated on `perf/httparena-followups`.** The earlier
hypothesis (per-request `body_state` / manual-reader allocated even
in auto mode) was wrong: auto mode never builds the body_reader (see
`roadrunner_conn_loop:read_body_phase`'s `auto` branch). The actual
cause is the **keep-alive process model**: roadrunner reuses one conn
process across keep-alive requests, so each request's garbage (body
iolist, refc-binary body in the binary bucket, request-map copies,
parser scratch) lingers until the BEAM fires a heap-growth-triggered
GC — and small per-request allocations don't grow the heap fast
enough to collect promptly. Cowboy spawns a fresh process per
request that dies and reclaims immediately, so its steady-state
footprint is lower.

**Important framing:** in the same measurement roadrunner ran ~2×
cowboy's throughput (183 K vs 95 K rps on `post_4kb_form @ 64c`).
Per-rps, roadrunner is *leaner* (0.53 vs 0.73 KB-beam/rps). The
absolute-RSS gap is a consequence of pushing more requests through
fewer, longer-lived processes.

**Measured GC-frequency trade-off (`post_4kb_form @ 64c`):**

| GC cadence | beam | rps | vs baseline |
|---|---|---|---|
| none (default) | 97 MB | 183 K | — |
| every 16th req | ~96 MB | ~178 K | no mem gain, −3 % rps |
| every request | 67 MB | 169 K | **−31 % mem, −8 % rps** |

The benefit is steeply non-linear: 16 requests' garbage between
collects is already most of the steady state, so only near-per-request
GC moves the needle — and that costs throughput. `fullsweep_after`
tuning was also tried (changes GC *type*, not *frequency*) and made
memory slightly worse.

**Why no fix shipped:** forcing GC trades away roadrunner's throughput
lead to match cowboy's absolute memory, on a workload where roadrunner
is already more memory-efficient per request. Not a clear win, and
pre-v0.1 we don't add opt-in knobs. If a memory-constrained
deployment ever needs it, the lever is a per-request `garbage_collect/0`
at the keep-alive loop-back in `buffered_finish/3` (or an adaptive
heap-size-threshold check) — but that's a deliberate policy choice,
not a default.

### Reduce HTTP/2 per-stream worker heap

**What:** `json-h2c @ 4096c` uses 1.6 GiB at 124K rps in the HttpArena
benchmark, high vs the same scenario over h1 (513 MiB at 193K rps) and
vs peer h2 frameworks (actix at 1 GiB for 1.2M rps).

**Measured (local `multi_stream_h2 @ 1024c`, 16 streams/conn = 16 K live
streams):** beam total 296 MiB. Breakdown:

| Bucket | Size | Share |
|---|---|---|
| processes | 235 MiB | **76 %** |
| system | 71 MiB | 23 % |
| binary | 23 MiB | 7 % |
| code | 9 MiB | 3 % |
| ets | 3 MiB | 1 % |

Top processes mid-bench, init=proc_lib's `init_p/5`,
current=`gen:do_call/4`: all clustered at **~112 KiB each** (10 of 10
sampled).

**Granular per-`initial_call` breakdown (local
`multi_stream_h2 @ 1024c`, captured via
`test/roadrunner_bench_memprofile.erl` + `scripts/bench.escript
--with-resources`):**

| initial_call | count | total MB | per-proc avg | top current_function |
|---|---|---|---|---|
| roadrunner_conn_loop init_loop/3 | ~935 | 57 | ~60 KiB | roadrunner_conn_loop_http2 recv_more/1 |
| ssl_gen_statem init/1 | ~935 | 48 | ~53 KiB | gen_statem loop/3 |
| tls_sender init/1 | ~935 | 11 | ~12 KiB | gen_statem loop/3 |
| other 60 groups | ~2 K | ~8 | — | mixed |

Total accounted across all groups: **~125 MiB**. Process bucket at
the same instant: **~190 MiB**. The ~65 MiB gap is short-lived stream
workers — total processes count is ~12 K but only ~3.8 K survive long
enough to be `process_info`-d (8 K die between `erlang:processes/0`
and the iteration). Their per-proc heap is small but the high churn
sums.

**Per-proc detail on the top 10 conn_loop procs (full
`process_info` via the enhanced
`test/roadrunner_bench_memprofile.erl`):**

- `memory = 109 KiB`, `heap_size = 6772 words`,
  `total_heap_size = 13544 words`, `stack_size = 30`,
  **`message_queue_len = 16-29`**
- `current_function = gen:do_call/4` — parked inside `ssl:send/2`,
  which dispatches to the per-connection ssl gen_statem
- All 10 top procs match this profile

**Real bottleneck driving per-conn heap, not state layout:** the
conn_loop's heap balloons during TLS `ssl:send` blocking because
worker `h2_send_response` messages back up in the conn's mailbox.
Each pending message carries its response payload (headers list +
body iolist). With 16 concurrent streams per conn, the mailbox holds
on the order of 16+ response messages × iolist size each while the
conn is parked in `gen:do_call/4` waiting for the ssl gen_statem to
drain. The 60 KiB average + 109 KiB outliers come mostly from this
mailbox content, NOT the static `loop_state` record or the streams
map.

**Implications for the fix shape:**

- Field-level pruning of `stream_entry/0` (e.g. clear `headers` after
  worker dispatch) gives sub-1 % savings here — the workers already
  copy `headers`/`body` away from the conn, and the conn's static
  per-stream footprint is small relative to the in-flight mailbox.
- The mailbox inflation is intrinsic to "workers send full responses
  via messages to a conn that batches them onto a single TLS socket."
  Mitigations are architectural (split the wire-write off the conn
  loop, or have workers stage payloads in ets / persistent_term and
  message only the pointer) — every option is a sizeable refactor and
  trades message size for an indirection on the hot path.
- Worker hibernation in `sync/1` would not help: workers are already
  short-lived (the bench memprofile shows ~8 K procs die between
  `erlang:processes/0` and `process_info` per snapshot pass).

**General roadrunner-on-TLS implication:** any h2-over-TLS workload
shares this shape — the OTP ssl gen_statem dispatch is in the hot
path of every outbound frame. Profiling-driven changes that reduce
per-`ssl:send` latency (e.g. coalescing HEADERS + small DATA into a
single send when the response fits in one frame, already in place at
`send_buffered`) help across all TLS users.

**Where NOT to look:** binary (23 MiB) and ets (3 MiB) are small —
HPACK dynamic-table reaping and WINDOW_UPDATE batching wouldn't move
the needle. Per-stream state layout is similarly not the lever; the
streams map is small relative to the mailbox.

**h2c (cleartext) measured — the mailbox effect is TLS-only, and the
big number is mostly OS-level.** The bench now drives cleartext h2c
(`--protocols h2c`, plain-TCP `protocols => [http2]` listener), so the
HttpArena `*-h2c` profiles are reproducible locally. `multi_stream_h2`
over h2c:

| | rps | erlang:memory peak | RSS | per-conn |
|---|---|---|---|---|
| h2c @ 1024c | 535 k | 302 MiB | 426 MiB | ~60 KiB |
| h2c @ 4096c | 442 k | 212 MiB | 718 MiB | — |
| TLS @ 1024c | ~330 k | 296 MiB (incl. ssl procs) | — | ~60 KiB |

Findings:
- **No mailbox inflation on h2c.** The conn_loop sits in
  `roadrunner_conn_loop_http2:recv_more/1`, never `gen:do_call/4` —
  `gen_tcp:send` doesn't block on a gen_statem, so the inflation above
  is confirmed TLS-only.
- **h2c is ~60 % faster than TLS** and leaner (no `ssl_gen_statem` /
  `tls_sender` procs). The json-h2c throughput rank reflects the
  per-stream-worker model vs a native h2 stack, not a roadrunner-h2
  defect.
- **The 1.6 GiB on HttpArena `json-h2c @ 4096c` is mostly outside the
  BEAM.** At 4096c locally, `erlang:memory(total)` peaks ~212 MiB
  while RSS is 718 MiB — ~70 % is per-socket kernel buffers × 4096
  conns + allocator carriers. RSS scales with conn count; Erlang heap
  tracks in-flight work, not conns. json's variable-array payloads
  add the rest (in-flight response bytes), pushing RSS toward the
  HttpArena figure. h2o (C) uses *more* on the same profile (1.9 GiB),
  so this is the cost of 4096 concurrent connections, not a roadrunner
  leak.

**Shipped — idle-conn hibernation (h1 parity).** The h2 conn loop now
honors `hibernate_after` like the h1 loop: when the streams map is
empty and the conn is parked waiting for the next frame past the
window, it `erlang:hibernate/3`s, collapsing the heap until the next
frame wakes it. Demonstrated ~3.6× idle-conn heap reduction (4.9 KiB →
1.4 KiB on lightly-used conns; more for conns with a populated hpack
dynamic table). This is a **memory** win for idle/bursty keep-alive
(browsers, API clients) — opt-in, default off, zero throughput effect
(`recv_timeout/1` is ~60 ns/call and the hibernate branch never fires
under load). It does **not** touch the all-busy `json-h2c @ 4096c`
figure: those conns never idle past the window.

**Scope:** medium-to-large, and now de-prioritized. The remaining
reducible roadrunner-side memory is the *active* per-conn
`conn_loop_http2` state (~60 KiB: streams map, hpack contexts, recv
buffer) — ~246 MiB of Erlang heap at 4096c, a minority of the RSS
that's dominated by sockets + payload. Trimming it is a real but
capped win that won't move the headline RSS; the remaining big levers
(wire-write split, pointer-only worker→conn protocol) are
architectural and lack a workload that justifies the refactor.

### Large-POST auto-buffering memory — measured, no roadrunner-side fix in scope

**Status:** investigated on `perf/httparena-followups`; the
auto-vs-manual trade-off is intrinsic to the API.

**Measured (`httparena_upload_20mb_auto @ 32c`, 20 MB POST):**

| Bucket | Auto | Manual |
|---|---|---|
| beam total | 997 MB | 97 MB |
| binary | 944 MB | small |
| processes | 21 MB | small |
| throughput | 643 rps | 930 rps |

32 conns × 20 MB raw body = 640 MB. The 944 MB binary bucket is
640 MB of in-flight body data + ~300 MB overhead (BEAM refcounted
binary allocator's chunk pages, sub-binary refs, delayed GC of the
prior request's body iolist before the next one arrives).

**Why no fix:** auto-buffering's contract IS "the conn pre-buffers
the full body into the request map before dispatch." A roadrunner-
side change can't trim memory below that floor without either (a)
breaking the contract (e.g. flushing the body to disk — overkill
for small bodies, slow for large) or (b) tuning BEAM's binary
allocator (deep emulator-config territory, off-limits to the
framework). Users with large uploads should use
`body_buffering => manual` (see `roadrunner_listener` `opts/0`),
which the API already exposes and the docs steer towards.

**If revisited:** would need a workload where manual mode isn't
suitable (e.g. a use case that genuinely wants the whole body
present as one value) AND where 47 % overhead-above-raw matters.
No such workload identified to date.

### roadrunner_static FD cache for sendfile — investigated, not viable

**Status:** investigated on `perf/httparena-followups`; **don't
re-attempt** without new evidence.

**Finding 1 — global fd cache is infeasible in BEAM.** `file:open(_,
[raw, binary])` returns an fd that `prim_file:get_fd_data/1` tags
with the opening process's pid and rejects from any other caller
(`{error, not_on_controlling_process}`). `file:sendfile/5` goes
through the same check. There is no file equivalent of
`gen_tcp:controlling_process/2`.
A supervised gen_server holding fds for all conns therefore can't
hand them out to acceptors. See
`erts-17.0/src/prim_file.erl:499-504`.

**Finding 2 — per-conn fd cache (the BEAM-correct fallback) doesn't
move the needle.** Stashing `#{Path => {Fd, Tick}}` in the conn
process's pdict, with a 16-entry LRU cap, was implemented and
A/B'd against current HEAD on `httparena_static @ 16c` (3×5s per
side): mean 146.8 k → 143.8 k rps, post slightly **slower** (−2 %),
well inside run-to-run variance. `file:open(_, [raw, binary])` is
sub-µs on a hot OS page cache; the pdict map lookup + tick bump +
`maps:put` overhead cancels the saving.

**Finding 3 — the fd-term owner-rewrite hack works but is
catastrophically unsafe (do not use).** A raw fd CAN be handed to
another process by destructuring its term and rewriting the owner
field:

```erlang
{file_descriptor, prim_file, Data} = Fd,
Fd1 = {file_descriptor, prim_file, Data#{owner => self()}}.
```

This bypasses the `not_on_controlling_process` check, so a shared
cross-conn fd cache could in principle be built on it. It is
undocumented and unsafe: the runtime tracks fd ownership for cleanup
via an atomic compare-and-swap, so if the owning process dies while
operations are in flight from other processes, they all signal close
of the underlying OS fd. Since OS fd integers are reused, that can
close an UNRELATED descriptor (a live socket or another open file) —
rare but equivalent to memory corruption, with no recovery. OTP issue
#9239 (raw pread from multiple processes) is stalled awaiting the VM
team; POSIX pread/sendfile are thread-safe at the OS level but Erlang
exposes no sanctioned multi-process raw-fd API. Sources: erlang.org
file docs, OTP issue #9239, Erlang Forums "is it safe to share Fd
between processes".

**What we ship instead — raw open per process (the sanctioned path).**
Both the stat and the sendfile open use `raw` in the calling process
(`roadrunner_static` read_link_info / read_file_info, and
`roadrunner_transport:sendfile`'s `file:open(_, [read, raw, binary])`),
which bypasses the `file_server` gen_server with no fd sharing. On the
uncached static path the `raw` stat removed a `file_server`
serialization bottleneck under concurrency: 70k → 125k rps at 256c.

**If revisited:** would need either (a) a measured workload where
`file:open` shows up as a clear hotspot in fprof / eprof (none seen
to date), or (b) a NIF-backed cache that owns the fds and serves
reads/sendfile itself (custom C / Rust, well outside the "pure-Erlang"
property the framework markets) — the owner-rewrite hack in Finding 3
is NOT a safe shortcut around this.

### Sync headline scenarios in comparison.md + resource_results.md

**What:** `docs/comparison.md` and `docs/resource_results.md` still
carry their own scenario picks predating the curated
`?MAIN_SCENARIOS` in `scripts/bench.escript`. The README's
quick-look table and the two bench-script-driven docs
(`docs/bench_results.md`, `docs/wrk2_results.md`) have already
been resynced.

**Why deferred:** both docs cross-reference broader investigations
(memory shape, architectural trade-offs) — a mechanical sync isn't
the right move, but a deliberate re-pick against `?MAIN_SCENARIOS`
is.

**Scope:** small. Re-render the comparison-doc throughput tables
and refresh the resource doc's per-scenario notes against the new
headline.

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
