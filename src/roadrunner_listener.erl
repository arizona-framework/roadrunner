-module(roadrunner_listener).
-moduledoc """
Listener gen_server — owns the listening socket and the acceptor pool
for one named roadrunner instance.

Plain TCP is backed by `gen_tcp` with the legacy `inet_drv` backend.
The OTP-27 `{inet_backend, socket}` NIF path was tried but adds
significant own-time overhead on short-lived connections via
per-socket-option lookups. TLS is backed by `ssl`, gated by the
`tls` opt.
Both paths share the same `roadrunner_transport` tagged-socket abstraction.

On `init/1` the listener opens the listen socket, builds the shared
`roadrunner_conn:proto_opts()` (dispatch + body limits + timeouts +
`max_clients` counter), and spawn-links `num_acceptors` (default 10)
`roadrunner_acceptor` processes that pull from the same listen socket.
Connection workers are unlinked from the acceptor so a single
connection crash doesn't take the pool down.

All duration and interval values in `opts()` are in milliseconds —
`request_timeout`, `keep_alive_timeout`, `rate_check_interval`,
`hibernate_after`, and `slot_reconciliation.interval`.
""".

-behaviour(gen_server).

-export([
    start_link/2,
    stop/1,
    drain/2,
    notify_drain/2,
    port/1,
    info/1,
    status/1,
    reload_routes/2
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-export_type([opts/0]).

-define(DEFAULT_MAX_CONTENT_LENGTH, 10485760).
-define(DEFAULT_REQUEST_TIMEOUT, 30000).
-define(DEFAULT_KEEP_ALIVE_TIMEOUT, 60000).
-define(DEFAULT_NUM_ACCEPTORS, 10).
-define(DEFAULT_MAX_KEEP_ALIVE, 1000).
-define(DEFAULT_MAX_CLIENTS, 150).
-define(DEFAULT_MAX_CONCURRENT_REQUESTS, infinity).
-define(DEFAULT_MIN_BYTES_PER_SECOND, 100).
%% TCP listen backlog (kernel SYN/accept queue depth). OTP defaults to 5,
%% which a burst of concurrent connects overflows; 1024 matches cowboy.
%% Linux clamps the effective value at `net.core.somaxconn`.
-define(DEFAULT_SOCKET_BACKLOG, 1024).
%% Spawn config for every handler-running process (connection process +
%% HTTP/2/3 stream workers). `fullsweep_after, 0` reclaims the per-connection
%% heap that grows building a response (e.g. a JSON encoder's transient iolist)
%% instead of hoarding it as old-gen garbage across keep-alive requests — at
%% high connection counts the difference between hundreds of MB and a few GB.
-define(DEFAULT_HANDLER_SPAWN_OPTS, [{fullsweep_after, 0}]).
-define(DEFAULT_HANDLER_START_TIMEOUT, infinity).
-define(DEFAULT_WS_MAX_FRAME_SIZE, 10485760).
-define(DEFAULT_WS_MAX_MESSAGE_SIZE, 10485760).
%% Per-connection concurrent client-initiated request (bidirectional)
%% stream cap advertised to HTTP/3 peers. Set explicitly so the bound
%% (and the memory it implies: streams × `max_content_length`) is
%% roadrunner's, not whatever default the QUIC transport happens to use.
-define(H3_MAX_STREAMS_BIDI, 100).

%% Default number of reuseport listeners in the HTTP/3 pool, overridable
%% per listener via `{http3, #{listeners => N}}` in `protocols`. The N
%% listeners bind the same UDP port with SO_REUSEPORT and share one
%% connection registry; the kernel spreads inbound datagrams across them
%% so demux parallelizes across cores instead of funnelling through one
%% process. (The dep's pool takes `pool_size`, the count BEYOND its base
%% listener, so the wiring passes `listeners - 1`.)
-define(DEFAULT_H3_LISTENERS, 8).
-define(MAX_H3_LISTENERS, 1024).

-doc """
Listener configuration map.

Required:
- `port` — TCP port to bind. `0` lets the kernel pick an ephemeral
  port; query it back with `port/1`.

Routing (pick one):
- `routes => module()` — single-handler dispatch. Every request
  goes to `Module:handle/1` and `roadrunner_req:state/1`
  returns `undefined`.
- `routes => {module(), term()}` — single-handler dispatch with
  per-handler state. The opaque second element is reachable from
  the handler via `roadrunner_req:state/1`.
- `routes => #{handler := module(), state => term(),
   middlewares => [...]}` — map form for single-handler dispatch;
  use it to attach per-handler middlewares (or future per-handler
  framework knobs) alongside the state.
- `routes => roadrunner_router:routes()` — list of route entries;
  each entry is either a `{Path, Handler}` / `{Path, Handler, State}`
  tuple or a `#{path := Path, handler := Handler, state => ...,
  middlewares => [...]}` map. First match wins.

Optional middleware and timing knobs (durations in milliseconds):
- `middlewares` — listener-wide pipeline applied to every request.
- `max_content_length` — request-body cap across HTTP/1.1, HTTP/2, and
  HTTP/3; an over-cap body answers `413 Payload Too Large` (and resets
  the stream on h2/h3). Default 10 MB.
- `ws` — WebSocket inbound size caps as a nested map (see
  `t:ws_opts/0`): `max_frame_size` (per-frame payload cap) and
  `max_message_size` (reassembled + decompressed message cap). Both
  default to 10 MB; over-cap closes the connection with code 1009.
- `request_timeout` — header-read timeout on a fresh conn.
  Default 30 s.
- `keep_alive_timeout` — idle timeout between requests on a
  keep-alive conn. Default 60 s.
- `num_acceptors` — size of the acceptor pool. Default 10.
- `max_keep_alive_requests` — requests served per conn before
  forced close. Default 1000.
- `max_clients` — concurrent connection cap. Default 150. Connections
  accepted while already at the cap are closed immediately without a
  response. The default bounds memory (the recv `buffer` alone is
  `max_clients × 64 KB`), so high-concurrency deployments should raise
  it. Rejections are observable: each one emits
  `[roadrunner, listener, conn_rejected]` and increments the `rejected`
  count from `info/1`, so a rising `rejected` is the signal that the
  cap is the binding limit.
- `max_concurrent_requests` — cap on concurrent in-flight requests
  (live handler processes) across the whole listener, for the
  multiplexed protocols (HTTP/2 and HTTP/3). Default `infinity` (off).
  `max_clients` bounds connections and `max_concurrent_streams` bounds
  streams per connection, but their product (the worst-case live-handler
  count) is otherwise unbounded; a high `max_clients` set for burst
  tolerance can let concurrent handler memory grow without limit under
  heavy multiplexing. This caps the product directly. Over-limit streams
  are refused with `REFUSED_STREAM` (h2) / `H3_REQUEST_REJECTED` (h3),
  which RFC 9113 §8.7 marks safe to retry; each refusal emits
  `[roadrunner, request, throttled]` and increments the `throttled`
  count from `info/1`. HTTP/1 is unaffected (one request per connection,
  already bounded by `max_clients`).
- `socket_backlog` — TCP listen backlog (kernel SYN/accept queue
  depth). Default 1024. Raise it for connection bursts (load tests,
  health-check storms); Linux clamps the effective value at
  `net.core.somaxconn`.
- `min_bytes_per_second` — slow-loris guard on the request-read
  phase (0 disables). Default 100.
- `rate_check_interval` — how often the rate guard re-checks
  (ms). Default 1000.
- `body_buffering` — `auto` (default; framework reads the full
  body before invoking the handler) or `manual` (handler calls
  `roadrunner_req:read_body/1,2`).
- `slot_reconciliation` — `disabled` (default) or
  `#{interval := Ms}` to periodically reap slots orphaned by
  brutal-kill exits.
- `graceful_drain` — opt out of the per-conn pg drain group
  (`true` default; `false` trades drain notification for ~10 %
  lower per-conn overhead on short-lived workloads).
- `hibernate_after` — when set, idle conns hibernate after this
  many milliseconds of main-loop idle time.
- `handler_spawn` — spawn config for every handler-running process (the
  connection process and HTTP/2/3 stream workers) as a nested map:
  `opts` (`spawn_opt` / `proc_lib` options, default
  `[{fullsweep_after, 0}]` so the per-conn response heap is reclaimed
  instead of hoarding it as old-gen garbage across keep-alive
  requests) and `start_timeout` (init-ack deadline, default
  `infinity`). For the lowest *resident* memory you can also add
  `+MHacul 0 +MBacul 0` to `vm.args` to return freed allocator carriers
  to the OS, but that is a tradeoff, not a free win: it raises
  allocator↔OS traffic and can hurt throughput at high core counts, so
  measure it for your workload rather than enabling it blindly.
- `protocols` — list of `t:protocol_entry/0`. Default `[http1]`.
  On TLS this drives `alpn_preferred_protocols` automatically.
- `tls` — `[ssl:tls_server_option()]` for HTTPS. Empty / absent
  for plain HTTP.

The inline source comments next to each field carry the deeper
ops-tuning rationale.
""".
-type opts() :: #{
    port := inet:port_number(),
    routes =>
        module()
        | {module(), term()}
        | #{
            handler := module(),
            state => term(),
            middlewares => roadrunner_middleware:middleware_list()
        }
        | roadrunner_router:routes(),
    middlewares => roadrunner_middleware:middleware_list(),
    max_content_length => non_neg_integer(),
    ws => ws_opts(),
    request_timeout => non_neg_integer(),
    keep_alive_timeout => non_neg_integer(),
    num_acceptors => pos_integer(),
    max_keep_alive_requests => pos_integer(),
    max_clients => pos_integer(),
    max_concurrent_requests => infinity | pos_integer(),
    socket_backlog => pos_integer(),
    min_bytes_per_second => non_neg_integer(),
    %% How often `reading_request` re-checks the running
    %% bytes-per-second average against `min_bytes_per_second`.
    %% Default `1000` — matches the 1-second grace period of the
    %% rate check itself. Tests use shorter intervals (20–30) to
    %% exercise rate-check fires deterministically without
    %% second-scale waits; ops can tune for chattier observability.
    rate_check_interval => pos_integer(),
    body_buffering => auto | manual,
    slot_reconciliation => disabled | #{interval := pos_integer()},
    %% Opt out of the per-conn `pg` drain group. Default `true`
    %% (current behavior). Set to `false` for short-lived h1-only
    %% workloads (REST APIs, health-check probes, CLI clients) where
    %% conns finish on their own faster than any drain notification
    %% could fire. Trades graceful drain notification for ~10% lower
    %% per-conn overhead. Long-lived conns (loop handlers, SSE,
    %% WebSocket) still rely on this — keep `true` if your handlers
    %% have those.
    graceful_drain => boolean(),
    %% When set, the per-connection process auto-hibernates after
    %% `Ms` milliseconds of idle main-loop time. Most useful for
    %% long-lived keep-alive HTTP/1.1 connections that mostly sit
    %% idle between requests — drops process heap to ~1KB during
    %% the wait. Setting this routes `roadrunner_conn_loop`'s recv
    %% through the active-mode `recv_with_hibernate/3` path so the
    %% receive's `after` clause has a window to call
    %% `erlang:hibernate/3`.
    hibernate_after => pos_integer(),
    %% Spawn config for every handler-running process — the connection process
    %% and the HTTP/2/3 stream workers. `opts` is a passthrough to `spawn_opt`
    %% (default `[{fullsweep_after, 0}]`): the default reclaims the
    %% per-connection heap that grows building a response (e.g. a JSON
    %% encoder's transient iolist) instead of hoarding it as old-gen garbage
    %% across keep-alive requests — at high connection counts the difference
    %% between hundreds of MB and a few GB of resident memory. Free on
    %% allocation-heavy handlers; ~3-4% on trivial passthrough handlers, so
    %% pass `{fullsweep_after, 65535}` to restore the BEAM default. Also useful
    %% here: `{max_heap_size, _}` (OOM/DoS cap), `{message_queue_data,
    %% off_heap}`, `{min_bin_vheap_size, _}`. `link`/`monitor` are rejected —
    %% roadrunner owns process linkage. `start_timeout` is the `proc_lib:start`
    %% `Time`: how long to wait for a started process to ack init before
    %% killing it with `{error, timeout}` (default `infinity`); it applies to
    %% the connection process and the WebSocket session (the fire-and-forget
    %% HTTP/3 conn and stream-worker spawns have no init handshake). For lower
    %% OS-resident memory `+MHacul 0 +MBacul 0` in `vm.args` returns freed
    %% allocator carriers to the OS, but it trades throughput for RSS (more
    %% allocator↔OS traffic, costly at high core counts) — measure it, don't
    %% enable it blindly.
    handler_spawn => #{
        opts => [proc_lib:start_spawn_option()],
        start_timeout => timeout()
    },
    %% Protocols this listener accepts. Each entry is either a bare
    %% atom (`http1` / `http2`) or a `{Proto, Opts}` tuple carrying
    %% protocol-specific tuning. Bare atom means "default opts".
    %% Default `[http1]`.
    %%
    %% On TLS listeners the list drives `alpn_preferred_protocols`
    %% automatically (`http1` → `~"http/1.1"`, `http2` → `~"h2"`).
    %% An explicit `alpn_preferred_protocols` inside `tls` overrides
    %% the derivation.
    %%
    %% On plain TCP, `[http1]` serves HTTP/1.1 only; `[http2]` serves
    %% h2c prior-knowledge (client sends the h2 connection preface
    %% `PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n` directly, no Upgrade
    %% negotiation). `[http1, http2]` on plain TCP is rejected at
    %% `init/1` — roadrunner has no `Upgrade: h2c` implementation,
    %% so the two cannot share a plaintext port.
    %%
    %% HTTP/1 tunables live under the `http1` tuple's opts map (see
    %% `t:http1_opts/0`): `max_request_line`, `max_header_line`,
    %% `max_header_block`, `max_header_count` — the inbound request-size
    %% caps. An empty map keeps the defaults.
    %%
    %% HTTP/2 tunables live under the `http2` tuple's opts map:
    %%
    %% - `conn_window` — connection-level receive window peak (bytes,
    %%   `1..2^31-1`). RFC 9113 default `65535`; values above the RFC
    %%   default emit an early `WINDOW_UPDATE(0, peak - 65535)` after
    %%   the server SETTINGS. Useful for upload-heavy workloads on
    %%   non-LAN RTTs. Reference points: gun 8 MB, Go net/http2 1 GB,
    %%   h2o 16 MB+, Mint 16 MB. Worst-case memory is
    %%   `max_clients × peak`.
    %% - `stream_window` — stream-level receive window peak (bytes,
    %%   `1..2^31-1`). Advertised via `SETTINGS_INITIAL_WINDOW_SIZE`.
    %%   Default `65535`. Setting above `conn_window` is allowed but
    %%   not useful — the conn-level peak is the binding constraint.
    %% - `window_refill_threshold` — refill trigger (bytes,
    %%   `pos_integer`). When the remaining window drops below this,
    %%   the conn refills back to the peak. Lower threshold = fewer
    %%   `WINDOW_UPDATE` frames per byte consumed but a smaller live
    %%   window between refills. Default `32768`.
    %% - `max_concurrent_streams` — cap on concurrent client-initiated
    %%   streams per connection (`pos_integer`), advertised in our
    %%   SETTINGS; HEADERS that would exceed it get
    %%   RST_STREAM(REFUSED_STREAM). Default `100`.
    %% - `max_header_block` — cumulative HEADERS+CONTINUATION block cap
    %%   (`pos_integer`); over-cap closes the conn with
    %%   GOAWAY(ENHANCE_YOUR_CALM). Default `16384`.
    %%
    %% Empty list, unknown protocol atoms, duplicate entries, bad
    %% tuple shape, unknown sub-option keys, or out-of-range sub-
    %% option values are rejected at `init/1`. See
    %% `docs/roadmap.md` "h2 receive-window defaults" for the
    %% trade-off behind keeping the conservative RFC defaults.
    protocols => [protocol_entry(), ...],
    tls => [ssl:tls_server_option()]
}.

-doc """
One protocol entry in the listener's `protocols` list. Either a
bare atom (`http1` / `http2` / `http3`) for default opts, or a tuple
`{Proto, ProtoOpts}` carrying protocol-specific tuning. HTTP/1 tunables
live under `t:http1_opts/0`, HTTP/2 under `t:http2_opts/0`, and HTTP/3
under `t:http3_opts/0`.

On TLS the list drives `alpn_preferred_protocols` for the TCP
protocols. On plain TCP, `[http2]` means prior-knowledge h2c (client
sends the h2 preface directly); `[http1, http2]` on plain TCP is
rejected at `init/1` since there's no `Upgrade: h2c` implementation.

`http3` runs HTTP/3 over QUIC on the UDP port of the same number, and
requires `tls` (QUIC mandates TLS 1.3) — listing it without `tls` is
rejected at `init/1`. It co-listens with the TCP protocols: e.g.
`[http1, http2, http3]` serves h1/h2 over TCP and h3 over UDP on the
same port. The QUIC handshake advertises the `h3` ALPN itself, so
`http3` does not appear in the TCP `alpn_preferred_protocols`.
""".
-type protocol_entry() ::
    http1 | http2 | http3 | {http1, http1_opts()} | {http2, http2_opts()} | {http3, http3_opts()}.

-doc """
HTTP/1.1 listener tunables (under `{http1, ThisMap}` in `protocols`).

All four cap inbound request sizes; oversized input is rejected before
the handler runs (414 for the request line, 431 for headers). Raise them
for clients that send large headers (long JWTs / cookies / tracing
metadata); lower them to tighten the attack surface.

- `max_request_line` — request-line byte cap (method + target +
  version). Over-cap → `414 URI Too Long`. Default `8192`.
- `max_header_line` — per-header-line byte cap. Over-cap → `431`.
  Default `8192`.
- `max_header_block` — cumulative header-block byte cap. Over-cap →
  `431`. Default `10240`.
- `max_header_count` — maximum number of header lines. Over-cap →
  `431`. Default `100`.
""".
-type http1_opts() :: #{
    max_request_line => 1..16#7FFFFFFF,
    max_header_line => 1..16#7FFFFFFF,
    max_header_block => 1..16#7FFFFFFF,
    max_header_count => 1..16#7FFFFFFF
}.

-doc """
HTTP/2 listener tunables (under `{http2, ThisMap}` in `protocols`).

- `conn_window` — connection-level receive window peak in bytes
  (`1..2^31-1`). RFC 9113 default `65535`; values above the
  default emit an early `WINDOW_UPDATE(0, peak - 65535)` after
  the server SETTINGS. Worst-case memory is
  `max_clients × peak`.
- `stream_window` — stream-level receive window peak in bytes
  (`1..2^31-1`). Advertised via `SETTINGS_INITIAL_WINDOW_SIZE`.
  Default `65535`. Setting above `conn_window` is allowed but
  not useful — the conn-level peak is the binding constraint.
- `window_refill_threshold` — refill trigger in bytes. When the
  remaining window drops below this, the conn refills back to
  the peak. Lower threshold = fewer `WINDOW_UPDATE` frames per
  byte consumed but a smaller live window between refills.
  Default `32768`.
- `max_concurrent_streams` — cap on concurrent client-initiated
  streams per connection, advertised via
  `SETTINGS_MAX_CONCURRENT_STREAMS`. HEADERS that would exceed it
  get `RST_STREAM(REFUSED_STREAM)`. Default `100`.
- `max_header_block` — cumulative cap on an assembled
  HEADERS+CONTINUATION block (the CONTINUATION-flood guard);
  over-cap closes the connection with `GOAWAY(ENHANCE_YOUR_CALM)`.
  Default `16384`. This is the h2 counterpart to the `{http1, ...}`
  `max_header_block` opt, but the two are independent and default
  differently (h1 `10240`, h2 `16384`).
- `max_header_list_size` — cap on the *decoded* (uncompressed)
  header-list size (RFC 7541 §4.1: sum of name + value + 32 per
  field), advertised via `SETTINGS_MAX_HEADER_LIST_SIZE`; an
  over-cap request gets `431` + `RST_STREAM(NO_ERROR)`. Bounds a
  different unit than `max_header_block` (which caps the compressed
  block). Defaults to `2 * max_header_block`, so raising the encoded
  cap lifts this one too unless set explicitly.
""".
-type http2_opts() :: #{
    conn_window => 1..16#7FFFFFFF,
    stream_window => 1..16#7FFFFFFF,
    window_refill_threshold => 1..16#7FFFFFFF,
    max_concurrent_streams => 1..16#7FFFFFFF,
    max_header_block => 1..16#7FFFFFFF,
    max_header_list_size => 1..16#7FFFFFFF
}.

-doc """
HTTP/3 listener tunables (under `{http3, ThisMap}` in `protocols`).

- `listeners` — number of reuseport listener processes in the QUIC
  pool (`1..1024`). They bind the same UDP port and share one
  connection registry; the kernel spreads inbound datagrams across
  them, so inbound demux parallelizes across cores. Default 8.
  `1` disables pooling (a single listener, no `SO_REUSEPORT`).
- `max_header_block` — cap on the encoded request field section (the
  HEADERS block); over-cap answers `431`. Default `16384`. The h3
  counterpart to the `{http1, ...}` / `{http2, ...}` `max_header_block`
  opts; the three are independent (h1 defaults to `10240`, h2/h3 to
  `16384`).
- `max_streams_bidi` — cap on concurrent client-initiated bidirectional
  (request) streams, advertised to the peer in the QUIC transport
  parameters. Default `100`. The h3 counterpart to the `{http2, ...}`
  `max_concurrent_streams` opt.
- `max_field_section_size` — cap on the *decoded* (uncompressed)
  field-section size (RFC 7541 §4.1: sum of name + value + 32 per field),
  advertised via `SETTINGS_MAX_FIELD_SECTION_SIZE` (so conformant clients
  self-limit, RFC 9114 §4.2.2) and enforced after QPACK decode: an
  over-cap request gets `431`. Bounds a different unit than
  `max_header_block` (which caps the compressed block). Defaults to
  `2 * max_header_block`, so raising the encoded cap lifts this one too
  unless set explicitly. The h3 counterpart to the `{http2, ...}`
  `max_header_list_size` opt.
""".
-type http3_opts() :: #{
    listeners => 1..?MAX_H3_LISTENERS,
    max_header_block => 1..16#7FFFFFFF,
    max_streams_bidi => 1..16#7FFFFFFF,
    max_field_section_size => 1..16#7FFFFFFF
}.

-doc """
WebSocket inbound size caps (under `ws` in the listener opts).

- `max_frame_size` — per-frame payload cap in bytes. An inbound
  frame declaring more than this closes the connection with code
  1009 before the payload is buffered. Default 10 MB.
- `max_message_size` — cap on a reassembled message in bytes: the
  running fragment total, and the decompressed size when
  permessage-deflate is negotiated. Over-cap closes with 1009. Must
  be `>= max_frame_size`. Default 10 MB.
""".
-type ws_opts() :: #{
    max_frame_size => 0..16#7FFFFFFF,
    max_message_size => 0..16#7FFFFFFF
}.

-record(state, {
    %% `none` when the listener serves HTTP/3 only (no TCP socket);
    %% `closed` after `drain/2` shuts the TCP socket on its way out.
    listen_socket :: roadrunner_transport:socket() | closed | none,
    port :: inet:port_number(),
    proto_opts :: roadrunner_conn:proto_opts(),
    phase = accepting :: accepting | draining | stopped,
    %% Slot reconciliation (off by default). When enabled, a periodic
    %% timer compares `client_counter` against pg group membership and
    %% releases slots that have been orphaned by `kill`-style exits
    %% (which bypass `terminate/3`). `prev_diff` tracks the previous
    %% tick's diff to filter out spawn-time races (a freshly-started
    %% conn has bumped the counter but not yet pg:join'd) — only
    %% sustained diffs are reaped.
    reconciliation = disabled ::
        disabled
        | #{
            interval := pos_integer(),
            prev_diff := non_neg_integer()
        },
    %% QUIC listener pool supervisor pid when `http3` is in `protocols`,
    %% else `undefined`. roadrunner owns its lifecycle (started in
    %% `init/1`, stopped in `terminate/1` / `do_drain/2`); the pooled
    %% reuseport listeners drive the UDP sockets while roadrunner owns
    %% the h3 conn loop.
    %% Kept last so the record's existing field positions are unchanged
    %% (some tests read `proto_opts` positionally via `element/2`).
    quic_listener = undefined :: pid() | undefined
}).

-doc """
Start a named listener that binds the given TCP port.

`port => 0` lets the kernel choose an ephemeral port — query it back
with `port/1`.
""".
-spec start_link(Name :: atom(), opts()) -> {ok, pid()} | {error, term()}.
start_link(Name, Opts) when is_atom(Name), is_map(Opts) ->
    gen_server:start_link({local, Name}, ?MODULE, Opts, []).

-doc "Stop a listener and release its port. In-flight conns are not waited on.".
-spec stop(Name :: atom()) -> ok.
stop(Name) ->
    gen_server:stop(Name).

-doc """
Graceful shutdown. Closes the listen socket immediately so no new
connections are accepted, broadcasts `{roadrunner_drain, Deadline}` to
every active conn (so `{loop, ...}` handlers can opt to honor it),
and then polls the live-connection counter until it hits zero or
`Timeout` milliseconds elapse. Conns still alive at the deadline are
hard-killed via `exit(Pid, shutdown)`.

Returns `{ok, drained}` when the counter reached zero before the
deadline, or `{timeout, Remaining}` with the count that was still
alive when the timeout fired (those processes are torn down before
returning).

After `drain/2` returns the listener exits — call `start_link/2`
again to bring it back up.
""".
-spec drain(Name :: atom(), Timeout :: non_neg_integer()) ->
    {ok, drained} | {timeout, non_neg_integer()}.
drain(Name, Timeout) ->
    gen_server:call(Name, {drain, Timeout}, Timeout + 5000).

-doc """
Broadcast a `{roadrunner_drain, Deadline}` notification to every conn /
WS session in the listener's `pg` drain group **without** stopping the
listener or waiting on the counter.

Use for soft-drain workflows — telling long-lived sessions to wind down
ahead of a deploy, or in test suites that want to observe drain
behavior without losing the listener for subsequent cases. Unlike
`drain/2`, the listener keeps accepting new connections.

Requires the `pg` scope to be running (started by `roadrunner_sup`).
""".
-spec notify_drain(Name :: atom(), Deadline :: integer()) -> ok.
notify_drain(Name, Deadline) when is_atom(Name), is_integer(Deadline) ->
    lists:foreach(
        fun(Pid) -> Pid ! {roadrunner_drain, Deadline} end,
        pg:get_members({roadrunner_drain, Name})
    ).

-doc "Return the actual TCP port the listener is bound to.".
-spec port(Name :: atom()) -> inet:port_number().
port(Name) ->
    gen_server:call(Name, port).

-doc """
Return runtime introspection for a listener:

- `active_clients` — current number of connections held open.
- `max_clients` — the configured cap.
- `requests_served` — cumulative count of requests whose headers
  parsed successfully since the listener started. Includes 4xx
  responses from the router (404) and the body-size pre-check (413);
  excludes wire-level parse failures, idle keep-alive timeouts, and
  silent slow-client closes.
- `rejected` — cumulative count of connections dropped because the
  listener was at its `max_clients` cap when they arrived. A rising
  `rejected` means the cap is the binding limit and should be raised.
  Also emitted in real time as `[roadrunner, listener, conn_rejected]`.
- `max_concurrent_requests` — the configured in-flight ceiling
  (`infinity` when off).
- `throttled` — cumulative count of streams refused because the listener
  was at its `max_concurrent_requests` ceiling. A rising `throttled`
  means the in-flight cap is binding. Also emitted in real time as
  `[roadrunner, request, throttled]`.

Useful for ops dashboards / health endpoints.
""".
-spec info(Name :: atom()) ->
    #{
        active_clients := non_neg_integer(),
        max_clients := pos_integer(),
        requests_served := non_neg_integer(),
        rejected := non_neg_integer(),
        max_concurrent_requests := infinity | pos_integer(),
        throttled := non_neg_integer()
    }.
info(Name) ->
    gen_server:call(Name, info).

-doc """
Return the listener's lifecycle phase:

- `accepting` — normal serving; new connections are being accepted.
- `draining` — `drain/2` is in progress; the listen socket is
  closed and active conns are finishing.

After `drain/2` (or `stop/1`) returns the listener has exited and
this call would fail with a `noproc`.
""".
-spec status(Name :: atom()) -> accepting | draining.
status(Name) ->
    gen_server:call(Name, status).

-doc """
Atomically swap the listener's compiled route table without
restarting it. The new `Routes` are compiled via
`roadrunner_router:compile/2` (with the listener's `middlewares`
re-baked) and published to `persistent_term`;
in-flight conns keep using whatever they read at request-resolve
time, but every subsequent dispatch sees the new table.

Returns `ok` on success or `{error, no_routes}` if the listener was
started in single-handler mode (`routes => Module` or no `routes`
opt) — there's no router table to reload.

Each call performs one global `persistent_term` swap, which scans every
process heap to reclaim the old table. That cost is acceptable for a
whole-table swap at deploy time, but callers should batch route changes
into a single `reload_routes/2` rather than calling it per route.
""".
-spec reload_routes(Name :: atom(), roadrunner_router:routes()) ->
    ok | {error, no_routes}.
reload_routes(Name, Routes) ->
    gen_server:call(Name, {reload_routes, Routes}).

%% --- gen_server callbacks ---
-doc false.
-spec init(opts()) -> {ok, #state{}} | {stop, term()}.
init(#{port := Port} = Opts) ->
    ListenerName = listener_name(),
    publish_routes(ListenerName, Opts),
    ProtoOpts = build_proto_opts(Opts, ListenerName),
    proc_lib:set_label({roadrunner_listener, ListenerName, Port}),
    Protocols = maps:get(protocols, ProtoOpts),
    %% TCP (`http1`/`http2`) and QUIC (`http3`) are independent
    %% transports that co-listen on the same port number. Bring up
    %% whichever the `protocols` list selects; an `http3`-only listener
    %% has no TCP socket (`none`), and a TCP-only listener no QUIC pid.
    case start_tcp(Port, Opts, Protocols, ProtoOpts) of
        {ok, LSocket} ->
            case start_quic(Port, Opts, Protocols, ProtoOpts) of
                {ok, QuicListener} ->
                    Reconciliation = setup_reconciliation(Opts),
                    {ok, #state{
                        listen_socket = LSocket,
                        quic_listener = QuicListener,
                        port = bound_port(LSocket, QuicListener),
                        proto_opts = ProtoOpts,
                        reconciliation = Reconciliation
                    }};
                {error, Reason} ->
                    %% TCP bound but QUIC failed — release the TCP port
                    %% so the failed start doesn't leave it held.
                    ok = close_tcp(LSocket),
                    {stop, {listen_failed, Reason}}
            end;
        {error, Reason} ->
            {stop, {listen_failed, Reason}}
    end.

%% Open the TCP listen socket + acceptor pool when the listener serves
%% any TCP protocol (`http1`/`http2`). An HTTP/3-only listener skips
%% the TCP socket entirely and returns `none`.
-spec start_tcp(
    inet:port_number(), opts(), [http1 | http2 | http3, ...], roadrunner_conn:proto_opts()
) -> {ok, roadrunner_transport:socket() | none} | {error, term()}.
start_tcp(Port, Opts, Protocols, ProtoOpts) ->
    case [P || P <- Protocols, P =/= http3] of
        [] ->
            {ok, none};
        TcpProtocols ->
            case open_listen_socket(Port, Opts, TcpProtocols) of
                {ok, LSocket} ->
                    NumAcceptors = maps:get(num_acceptors, Opts, ?DEFAULT_NUM_ACCEPTORS),
                    ok = spawn_acceptors(LSocket, ProtoOpts, NumAcceptors),
                    {ok, LSocket};
                {error, _} = Error ->
                    Error
            end
    end.

%% Start the QUIC listener roadrunner owns when `http3` is requested.
%% Only the self-contained `quic_listener_sup` pool is started (via
%% `start_quic_pool/2`), NOT the whole `quic` application. That app's
%% supervisor tree backs the dep's own turnkey server (`server_registry`
%% / `server_sup`), client (`token_cache`), and distribution
%% (`dist_sup`) features — none of which roadrunner's owned listener
%% uses — and `crypto` + `ssl` are already up as roadrunner's own deps.
%% Keeping the `quic` app out of the boot path means a co-serving
%% instance carries no idle supervisors it never uses. Each accepted
%% QUIC connection is handed to a fresh `roadrunner_conn_loop_http3`
%% owner via the arity-1 `connection_handler`; the QUIC listener then
%% transfers ownership to the returned pid. `http3` having been
%% validated to require `tls`, the `tls` opt is always present here.
-spec start_quic(
    inet:port_number(), opts(), [http1 | http2 | http3, ...], roadrunner_conn:proto_opts()
) -> {ok, pid() | undefined} | {error, term()}.
start_quic(Port, Opts, Protocols, ProtoOpts) ->
    case lists:member(http3, Protocols) of
        false ->
            {ok, undefined};
        true ->
            #{tls := UserTlsOpts} = Opts,
            {Cert, CertChain, Key} = quic_cert_key(UserTlsOpts),
            Handler = fun(ConnPid) -> roadrunner_conn_loop_http3:start(ConnPid, ProtoOpts) end,
            %% Start a POOL of reuseport listeners (the dep enables
            %% SO_REUSEPORT when pool_size > 0 and shares one connection
            %% registry across them) so inbound demux parallelizes across
            %% cores rather than funnelling through one listener process.
            %% `quic_listener_sup:start_link` links the pool supervisor to
            %% this gen_server for shared fate; an `init`-time bind failure
            %% comes back as `{error, _}` from the synchronous start (so
            %% `init/1` can still close the already-opened TCP socket).
            %% A reuseport pool needs a CONCRETE port: binding port 0 on
            %% each listener would hand out a different ephemeral port. So
            %% when asked for an ephemeral port, hold a reuseport probe
            %% socket to pin a free port, start the pool on it, then drop
            %% the probe (the pool listeners keep the port via reuseport).
            {QuicPort, Probe} = resolve_quic_port(Port),
            Listeners = maps:get(http3_listeners, ProtoOpts, ?DEFAULT_H3_LISTENERS),
            MaxStreamsBidi = maps:get(http3_max_streams_bidi, ProtoOpts, ?H3_MAX_STREAMS_BIDI),
            Res = start_quic_pool(QuicPort, #{
                cert => Cert,
                key => Key,
                cert_chain => CertChain,
                alpn => [~"h3"],
                max_streams_bidi => MaxStreamsBidi,
                connection_handler => Handler,
                pool_size => Listeners - 1
            }),
            ok = close_quic_probe(Probe),
            Res
    end.

%% The pool is a supervisor, so it can only be `start_link`ed - which
%% makes this gen_server its parent (the pool then lives as long as the
%% listener, and they share fate). Trap exits only across the start so a
%% bind failure surfaces as `{error, _}` rather than the supervisor's
%% startup EXIT killing this otherwise non-trapping process. Trap is
%% restored immediately; any stray trapped EXIT left in the mailbox is
%% harmlessly dropped by the catch-all `handle_info/2`.
-spec start_quic_pool(inet:port_number(), map()) -> {ok, pid()} | {error, term()}.
start_quic_pool(Port, PoolOpts) ->
    OldTrap = process_flag(trap_exit, true),
    try
        quic_listener_sup:start_link(Port, PoolOpts)
    after
        _ = process_flag(trap_exit, OldTrap)
    end.

%% Pin a free UDP port with a reuseport probe socket so all pool
%% listeners bind the same concrete port; a fixed port is used as-is.
-spec resolve_quic_port(inet:port_number()) ->
    {inet:port_number(), gen_udp:socket() | undefined}.
resolve_quic_port(0) ->
    {ok, Probe} = gen_udp:open(0, [{reuseport, true}]),
    {ok, ProbePort} = inet:port(Probe),
    {ProbePort, Probe};
resolve_quic_port(Port) ->
    {Port, undefined}.

-spec close_quic_probe(gen_udp:socket() | undefined) -> ok.
close_quic_probe(undefined) -> ok;
close_quic_probe(Probe) -> gen_udp:close(Probe).

%% The bound port comes from whichever transport owns it. TCP wins when
%% present (co-listen reuses the same number for UDP); an HTTP/3-only
%% listener reads it back from the QUIC listener.
-spec bound_port(roadrunner_transport:socket() | none, pid() | undefined) -> inet:port_number().
bound_port(none, QuicPool) ->
    [Listener | _] = quic_listener_sup:get_listeners(QuicPool),
    quic_listener:get_port(Listener);
bound_port(LSocket, _QuicListener) ->
    {ok, BoundPort} = roadrunner_transport:port(LSocket),
    BoundPort.

-spec close_tcp(roadrunner_transport:socket() | none | closed) -> ok.
close_tcp(none) -> ok;
close_tcp(closed) -> ok;
close_tcp(LSocket) -> roadrunner_transport:close(LSocket).

%% Extract the leaf cert, its intermediate chain, and the decoded
%% private key from the user's `tls` opts for the QUIC listener, which
%% takes `cert => LeafDER`, `cert_chain => [IntermediateDER]`, and
%% `key => DecodedKey` rather than OTP `ssl`'s opt forms. Supports the
%% inline DER forms `ssl` and the test PKI produce (`{cert, DER}` /
%% `{key, {Algo, DER}}`), `certfile` / `keyfile` PEM paths (a `certfile`
%% may bundle the chain, e.g. a Let's Encrypt `fullchain.pem`), and
%% OTP's modern `{certs_keys, [...]}` form — so a TLS config that works
%% on the TCP listener also works on h3.
-spec quic_cert_key([ssl:tls_server_option()]) ->
    {binary(), [binary()], public_key:private_key()}.
quic_cert_key(TlsOpts) ->
    Source = certs_keys_source(TlsOpts),
    [Leaf | Chain] = cert_chain(Source),
    {Leaf, Chain, quic_key(Source)}.

%% A `certs_keys` entry (OTP's multi-config form) bundles cert + key in
%% one map; unwrap the first entry to a proplist so the same extraction
%% handles it. Plain `tls` opts are already in that shape.
-spec certs_keys_source([ssl:tls_server_option()]) -> [tuple()].
certs_keys_source(TlsOpts) ->
    case lists:keyfind(certs_keys, 1, TlsOpts) of
        {certs_keys, [Conf | _]} -> maps:to_list(Conf);
        false -> TlsOpts
    end.

%% The server certificate as `[Leaf | Intermediates]` (DER). Inline
%% `cert` is the single leaf; a `certfile` PEM may carry the leaf
%% followed by its intermediate chain.
-spec cert_chain([tuple()]) -> [binary()].
cert_chain(Source) ->
    case lists:keyfind(cert, 1, Source) of
        {cert, Der} when is_binary(Der) ->
            [Der];
        false ->
            {certfile, File} = lists:keyfind(certfile, 1, Source),
            cert_entries(File)
    end.

%% Every `Certificate` DER in a PEM file, in file order (leaf first).
-spec cert_entries(file:name_all()) -> [binary()].
cert_entries(File) ->
    {ok, Pem} = file:read_file(File),
    [Der || {'Certificate', Der, not_encrypted} <- public_key:pem_decode(Pem)].

-spec quic_key([tuple()]) -> public_key:private_key().
quic_key(Source) ->
    case lists:keyfind(key, 1, Source) of
        {key, {Algo, Der}} when is_atom(Algo), is_binary(Der) ->
            public_key:der_decode(Algo, Der);
        false ->
            {keyfile, File} = lists:keyfind(keyfile, 1, Source),
            {Algo, Der} = first_pem_entry(File),
            public_key:der_decode(Algo, Der)
    end.

%% First PEM entry of a key file as `{Asn1Type, DER}`.
-spec first_pem_entry(file:name_all()) -> {atom(), binary()}.
first_pem_entry(File) ->
    {ok, Pem} = file:read_file(File),
    [{Type, Der, not_encrypted} | _] = public_key:pem_decode(Pem),
    {Type, Der}.

-spec setup_reconciliation(opts()) ->
    disabled | #{interval := pos_integer(), prev_diff := non_neg_integer()}.
setup_reconciliation(#{slot_reconciliation := #{interval := IntervalMs}}) when
    is_integer(IntervalMs), IntervalMs > 0
->
    erlang:send_after(IntervalMs, self(), reconcile_slots),
    #{interval => IntervalMs, prev_diff => 0};
setup_reconciliation(_Opts) ->
    disabled.

%% Compile + publish to `persistent_term` once, at listener start. The
%% conn reads via `persistent_term:get/1` on every request, so the
%% lookup is O(1) and the table is shared across all conns of this
%% listener without copying.
-spec publish_routes(atom(), opts()) -> ok.
publish_routes(ListenerName, #{routes := Routes} = Opts) when is_list(Routes) ->
    ListenerMws = maps:get(middlewares, Opts, []),
    persistent_term:put(
        {roadrunner_routes, ListenerName},
        roadrunner_router:compile(Routes, ListenerMws)
    );
publish_routes(_ListenerName, _Opts) ->
    ok.

%% Recover the registered name we were started with. `start_link/2` always
%% calls `gen_server:start_link({local, Name}, ...)` so the name is set
%% before `init/1` runs.
-spec listener_name() -> atom().
listener_name() ->
    {registered_name, Name} = process_info(self(), registered_name),
    Name.

-spec open_listen_socket(
    inet:port_number(), opts(), [http1 | http2, ...]
) -> {ok, roadrunner_transport:socket()} | {error, term()}.
open_listen_socket(Port, #{tls := UserTlsOpts} = Opts, Protocols) ->
    %% TLS path — caller supplies cert/key. ALPN is derived from the
    %% normalized `protocols` list (`http2` → `~"h2"`, `http1` →
    %% `~"http/1.1"`) unless the user supplied
    %% `alpn_preferred_protocols` explicitly, in which case the
    %% explicit value wins. Hardened defaults are layered underneath
    %% (user values win), and the standard transport options sit on
    %% top so accepted sockets behave like the plain-TCP variant.
    TlsOpts = roadrunner_transport:build_tls_opts(Protocols, UserTlsOpts),
    roadrunner_transport:listen_tls(Port, TlsOpts ++ base_listen_opts(Opts));
open_listen_socket(Port, Opts, _Protocols) ->
    %% Plain TCP. The legacy `inet_drv` backend (gen_tcp default) has
    %% lower per-call overhead than the OTP-27 `socket` backend on
    %% short-lived connections. fprof on `connection_storm` shows the
    %% `socket` backend's `prim_socket:is_supported_option` + the
    %% `maps:fold_1` walking it costs ~46% of per-conn own time
    %% (~106 lookups per connection). See
    %% `docs/conn_lifecycle_investigation.md`. The new backend's
    %% async I/O wins are real for long-lived connections; revisit
    %% if/when the workload mix shifts there.
    roadrunner_transport:listen(Port, base_listen_opts(Opts)).

-spec base_listen_opts(opts()) -> [gen_tcp:listen_option()].
base_listen_opts(Opts) ->
    %% `nodelay` disables Nagle's algorithm on accepted sockets.
    %% RFC 9113 §5.2 doesn't mandate it, but every production h2
    %% server (nginx, h2o, cowboy, …) sets it because h2 responses
    %% emit multiple small frames per request (HEADERS + DATA),
    %% and Nagle holds the second write until the client ACKs the
    %% first — hitting Linux's 40 ms delayed-ACK timer and
    %% capping per-request latency at ~50 ms. h1 isn't affected
    %% (one `ssl:send/2` per response) but `nodelay` is the right
    %% default for any HTTP server.
    %%
    %% `backlog` overrides OTP's default of 5. With 5, a burst of
    %% concurrent connects (real apps, load tests, health-check
    %% storms) overflows the kernel listen queue and the new SYNs
    %% get dropped — `gen_tcp:connect` succeeds (kernel SYN-cookie
    %% path), then the first `send` returns `{error, closed}`
    %% because the conn was never queued for `accept`. Defaults to
    %% 1024 (matching cowboy), overridable via the `socket_backlog`
    %% listener opt. Linux clamps the effective value at
    %% `net.core.somaxconn` (typically 4096), so the default is
    %% safely non-truncated everywhere.
    %%
    %% `buffer` is the emulator's user-space buffer that bounds how
    %% many bytes each `{tcp, _, Data}` message carries in
    %% `{active, ...}` mode. The OTP default is `min(sndbuf,
    %% recbuf)` and on plain TCP with MTU-bounded delivery
    %% (1460-byte chunks) this can result in many small messages
    %% per request body, each paying the message-passing tax. 64 KB
    %% is enough to carry 4 default-sized HTTP/2 DATA frames or a
    %% typical request, comfortably above the per-MTU floor without
    %% wasting memory at scale (`max_clients × 64KB` ≈ 10 MB at the
    %% default `max_clients = 150`). See `erlang/otp#9423` and
    %% `ninenines/cowlib#143` for the upstream context that prompted
    %% this tuning.
    [
        binary,
        {active, false},
        {reuseaddr, true},
        {packet, raw},
        {nodelay, true},
        {backlog, maps:get(socket_backlog, Opts, ?DEFAULT_SOCKET_BACKLOG)},
        {buffer, 65536}
    ].

%% Multiple acceptor processes all calling gen_tcp:accept on the same listen
%% socket — Linux/BSD accept is thread-safe and avoids thundering-herd via
%% kernel-side queueing.
-spec spawn_acceptors(roadrunner_transport:socket(), roadrunner_conn:proto_opts(), pos_integer()) ->
    ok.
spawn_acceptors(LSocket, ProtoOpts, N) when is_integer(N), N >= 0 ->
    spawn_acceptors_loop(LSocket, ProtoOpts, 1, N).

-spec spawn_acceptors_loop(
    roadrunner_transport:socket(), roadrunner_conn:proto_opts(), pos_integer(), non_neg_integer()
) -> ok.
spawn_acceptors_loop(_LSocket, _ProtoOpts, I, N) when I > N ->
    ok;
spawn_acceptors_loop(LSocket, ProtoOpts, I, N) ->
    {ok, _Pid} = roadrunner_acceptor:start_link(LSocket, ProtoOpts, I),
    spawn_acceptors_loop(LSocket, ProtoOpts, I + 1, N).

-spec build_proto_opts(opts(), atom()) -> roadrunner_conn:proto_opts().
build_proto_opts(Opts, ListenerName) ->
    %% Validate + normalize the `protocols` list. Public input may
    %% nest `{http2, #{...}}` for protocol-specific tuning; the
    %% normalizer flattens HTTP/2 sub-opts onto proto_opts top-level
    %% with an `http2_` prefix so the hot path reads each knob via
    %% a single `maps:get/2` instead of a nested map dive.
    {Protocols, ProtoFlats} = normalize_protocols(Opts),
    %% Per-listener counters: live-connection counter (acceptors bump on
    %% accept; conns decrement on exit), a cumulative requests-served
    %% counter (conn bumps on each handler dispatch), and a cumulative
    %% rejected-connections counter (acceptor bumps when a connection is
    %% dropped at the `max_clients` cap). `client_counter` uses the
    %% `counters` module with `write_concurrency` so each scheduler bumps a
    %% private sub-counter (lock-free, no cache-line ping-pong across
    %% cores). `counters:get/2` returns an eventually-consistent sum, which
    %% matches the bounded-overshoot contract `try_acquire_slot/1` already
    %% documents.
    ClientCounter = counters:new(1, [write_concurrency]),
    RequestsCounter = atomics:new(1, [{signed, false}]),
    RejectedCounter = atomics:new(1, [{signed, false}]),
    %% `inflight_counter` is the live in-flight-request gauge (h2/h3 stream
    %% workers acquire before spawn, release on `DOWN`), same lock-free
    %% `write_concurrency` shape as `client_counter`. `throttled_counter`
    %% is the cumulative count of streams refused at the
    %% `max_concurrent_requests` ceiling, mirroring `rejected_counter`.
    InflightCounter = counters:new(1, [write_concurrency]),
    ThrottledCounter = atomics:new(1, [{signed, false}]),
    %% Public `ws` opts are a nested map; flatten to the `ws_*`
    %% proto_opts keys the hot path reads, mirroring the `{http2, #{}}`
    %% → `http2_*` flattening above.
    #{max_frame_size := WsFrame, max_message_size := WsMsg} =
        validate_ws_opts(maps:get(ws, Opts, #{})),
    %% Flatten the nested `handler_spawn` opt to top-level proto_opts keys the
    %% spawn sites read directly, mirroring the `ws` / `http2` flattening above.
    #{opts := HandlerSpawnOpts, start_timeout := HandlerStartTimeout} = resolve_handler_spawn(Opts),
    Base = maps:merge(
        maps:merge(maybe_alt_svc(Protocols, Opts), #{
            dispatch => build_dispatch(Opts, ListenerName),
            middlewares => maps:get(middlewares, Opts, []),
            max_content_length =>
                maps:get(max_content_length, Opts, ?DEFAULT_MAX_CONTENT_LENGTH),
            ws_max_frame_size => WsFrame,
            ws_max_message_size => WsMsg,
            request_timeout => maps:get(request_timeout, Opts, ?DEFAULT_REQUEST_TIMEOUT),
            keep_alive_timeout =>
                maps:get(keep_alive_timeout, Opts, ?DEFAULT_KEEP_ALIVE_TIMEOUT),
            max_keep_alive_requests =>
                maps:get(max_keep_alive_requests, Opts, ?DEFAULT_MAX_KEEP_ALIVE),
            max_clients => maps:get(max_clients, Opts, ?DEFAULT_MAX_CLIENTS),
            max_concurrent_requests =>
                maps:get(max_concurrent_requests, Opts, ?DEFAULT_MAX_CONCURRENT_REQUESTS),
            client_counter => ClientCounter,
            requests_counter => RequestsCounter,
            rejected_counter => RejectedCounter,
            inflight_counter => InflightCounter,
            throttled_counter => ThrottledCounter,
            min_bytes_per_second =>
                maps:get(min_bytes_per_second, Opts, ?DEFAULT_MIN_BYTES_PER_SECOND),
            body_buffering => maps:get(body_buffering, Opts, auto),
            listener_name => ListenerName,
            graceful_drain => maps:get(graceful_drain, Opts, true),
            handler_spawn_opts => HandlerSpawnOpts,
            handler_start_timeout => HandlerStartTimeout,
            protocols => Protocols
        }),
        ProtoFlats
    ),
    WithHibernate =
        %% Optional `hibernate_after` — `roadrunner_conn_loop` reads it
        %% from proto_opts and routes the recv path through
        %% `recv_with_hibernate/3` so the conn auto-hibernates after
        %% Ms of idle time. Omitted by default because hibernation has
        %% a per-wake CPU cost (~tens of microseconds for the GC); only
        %% worth enabling for workloads with mostly-idle keep-alive
        %% conns where the heap-shrink win dominates.
        case Opts of
            #{hibernate_after := Ms} when is_integer(Ms), Ms > 0 ->
                Base#{hibernate_after => Ms};
            #{} ->
                Base
        end,
    %% Optional `rate_check_interval` — the rate-check timer
    %% interval inside `reading_request`. Default 1000ms; ops can
    %% override.
    case Opts of
        #{rate_check_interval := IntervalMs} when is_integer(IntervalMs), IntervalMs > 0 ->
            WithHibernate#{rate_check_interval => IntervalMs};
        #{} ->
            WithHibernate
    end.

%% Resolve the public `handler_spawn` opt into the proto_opts shape the spawn
%% sites read: `#{opts := [start_spawn_option()], start_timeout := timeout()}`.
%% `link`/`monitor` are rejected — roadrunner owns process linkage (the conn is
%% intentionally unlinked, stream workers are monitored), so honoring them would
%% break that crash-isolation contract.
resolve_handler_spawn(Opts) ->
    case maps:get(handler_spawn, Opts, #{}) of
        HandlerSpawn when is_map(HandlerSpawn) ->
            SpawnOpts = maps:get(opts, HandlerSpawn, ?DEFAULT_HANDLER_SPAWN_OPTS),
            Timeout = maps:get(start_timeout, HandlerSpawn, ?DEFAULT_HANDLER_START_TIMEOUT),
            ok = validate_handler_spawn_opts(SpawnOpts, HandlerSpawn),
            ok = validate_handler_start_timeout(Timeout, HandlerSpawn),
            #{opts => SpawnOpts, start_timeout => Timeout};
        Other ->
            error({invalid_listener_opt, handler_spawn, Other})
    end.

validate_handler_spawn_opts(SpawnOpts, Raw) when is_list(SpawnOpts) ->
    case lists:any(fun is_reserved_spawn_opt/1, SpawnOpts) of
        true -> error({invalid_listener_opt, handler_spawn, Raw});
        false -> ok
    end;
validate_handler_spawn_opts(_SpawnOpts, Raw) ->
    error({invalid_listener_opt, handler_spawn, Raw}).

is_reserved_spawn_opt(link) -> true;
is_reserved_spawn_opt(monitor) -> true;
is_reserved_spawn_opt({monitor, _}) -> true;
is_reserved_spawn_opt(_) -> false.

validate_handler_start_timeout(infinity, _Raw) ->
    ok;
validate_handler_start_timeout(Timeout, _Raw) when
    is_integer(Timeout), Timeout >= 0, Timeout =< 16#7FFFFFFF
->
    ok;
validate_handler_start_timeout(_Timeout, Raw) ->
    error({invalid_listener_opt, handler_spawn, Raw}).

%% Precompute the `Alt-Svc` response-header value (RFC 7838) when the
%% listener co-serves HTTP/3 alongside a TCP protocol on a fixed port,
%% so h1/h2 responses advertise the h3 endpoint and browsers upgrade to
%% QUIC. Skipped on ephemeral (`port => 0`) listeners: there is no
%% stable port to advertise, and TCP/UDP would not even share one.
-spec maybe_alt_svc([http1 | http2 | http3, ...], opts()) -> map().
maybe_alt_svc(Protocols, #{port := Port}) ->
    case h3_co_served(Protocols) andalso is_integer(Port) andalso Port > 0 of
        true -> #{alt_svc => alt_svc_value(Port)};
        false -> #{}
    end.

-spec h3_co_served([http1 | http2 | http3, ...]) -> boolean().
h3_co_served(Protocols) ->
    lists:member(http3, Protocols) andalso lists:any(fun(P) -> P =/= http3 end, Protocols).

%% RFC 7838 §3: advertise h3 on the same host at `Port`; `ma` caps how
%% long clients cache the mapping (24h).
-spec alt_svc_value(inet:port_number()) -> binary().
alt_svc_value(Port) ->
    <<"h3=\":", (integer_to_binary(Port))/binary, "\"; ma=86400">>.

%% `routes` is the unified dispatch option. Single-handler forms
%% (bare atom, `{Mod, State}` tuple, or `#{handler := Mod, ...}` map)
%% all compile to a `{handler, Mod, Pipeline, State}` dispatch tag
%% where `Pipeline` is the pre-composed `next()` fun (listener mws
%% ++ per-handler mws, optionally wrapped in a state-injecting
%% closure, ending in `fun Mod:handle/1`) and `State` is the user's
%% attached state (or `undefined`) exposed alongside for callers
%% that need to introspect outside the request flow. A list of route
%% entries uses the router. When `routes` is omitted, fall back to
%% the default hello-world handler. List-form routes are published
%% to `persistent_term` by `publish_routes/2` — the dispatch tag
%% carries the listener name so the conn can look the table up.
-spec build_dispatch(opts(), atom()) -> roadrunner_conn:dispatch().
%% Validate + normalize the `protocols` opt. Returns a 2-tuple:
%%
%% - `Protocols :: [http1 | http2, ...]` — the enabled protocols as a
%%   flat atom list in user-supplied order (ALPN preference).
%% - `ProtoFlats :: #{atom() => term()}` — HTTP/2 sub-opts flattened
%%   with `http2_` prefix (`http2_conn_window`, `http2_stream_window`,
%%   `http2_window_refill_threshold`), defaults filled. Empty map
%%   when http2 is not in the list. Flat keys keep the hot path to
%%   one `maps:get/2` per knob; no nested map dives.
%%
%% Error shapes follow the existing `{invalid_listener_opt, K, V}` /
%% `{listener_opt_conflict, ...}` convention:
%%
%% - `{invalid_listener_opt, protocols, V}` for a bad list shape:
%%   empty list, non-list, unknown atom, malformed tuple, unknown
%%   sub-option key, out-of-range sub-option value, or duplicate
%%   entries.
%% - `{listener_opt_conflict, protocols, V, no_h2c_upgrade}` for the
%%   one combo we have to reject at config time: both `http1` and
%%   `http2` on a plain-TCP listener. Roadrunner has no
%%   `Upgrade: h2c` implementation, so the two cannot share a
%%   plaintext port; the reason token spells that out so the error
%%   message is honest.
-spec normalize_protocols(opts()) -> {[http1 | http2 | http3, ...], #{atom() => term()}}.
normalize_protocols(Opts) ->
    Raw = maps:get(protocols, Opts, [http1]),
    HasTls = maps:is_key(tls, Opts),
    Entries = normalize_protocols_list(Raw),
    Names = [N || {N, _} <- Entries],
    %% QUIC mandates TLS 1.3, so `http3` without `tls` is a config
    %% error — caught here before the `[http1, http2]` h2c check below
    %% (which only fires on plain TCP, where `http3` can't appear).
    ok = require_tls_for_h3(Names, HasTls, Raw),
    case Names of
        [http1, http2] when not HasTls ->
            error({listener_opt_conflict, protocols, Raw, no_h2c_upgrade});
        [http2, http1] when not HasTls ->
            error({listener_opt_conflict, protocols, Raw, no_h2c_upgrade});
        _ ->
            {Names,
                maps:merge(
                    flatten_http1_opts(Entries),
                    maps:merge(flatten_http2_opts(Entries), flatten_http3_opts(Entries))
                )}
    end.

-spec require_tls_for_h3([http1 | http2 | http3, ...], boolean(), term()) -> ok.
require_tls_for_h3(Names, HasTls, Raw) ->
    case lists:member(http3, Names) of
        true when not HasTls ->
            error({listener_opt_conflict, protocols, Raw, http3_requires_tls});
        _ ->
            ok
    end.

-type protocol_entry_norm() ::
    {http1, http1_opts()} | {http2, http2_opts()} | {http3, http3_opts()}.

-spec normalize_protocols_list(term()) -> [protocol_entry_norm(), ...].
normalize_protocols_list(L) when is_list(L), L =/= [] ->
    Entries = [normalize_protocol_entry(E, L) || E <- L],
    Names = [N || {N, _} <- Entries],
    case length(lists:usort(Names)) =:= length(Names) of
        true -> Entries;
        false -> error({invalid_listener_opt, protocols, L})
    end;
normalize_protocols_list(L) ->
    error({invalid_listener_opt, protocols, L}).

-spec normalize_protocol_entry(term(), term()) -> protocol_entry_norm().
normalize_protocol_entry(http1, _Raw) ->
    {http1, http1_defaults()};
normalize_protocol_entry(http2, _Raw) ->
    {http2, http2_defaults()};
normalize_protocol_entry({http1, Opts}, Raw) when is_map(Opts) ->
    {http1, validate_http1_opts(Opts, Raw)};
normalize_protocol_entry({http2, Opts}, Raw) when is_map(Opts) ->
    {http2, validate_http2_opts(Opts, Raw)};
normalize_protocol_entry(http3, _Raw) ->
    {http3, http3_defaults()};
normalize_protocol_entry({http3, Opts}, Raw) when is_map(Opts) ->
    {http3, validate_http3_opts(Opts, Raw)};
normalize_protocol_entry(_, Raw) ->
    error({invalid_listener_opt, protocols, Raw}).

-spec http1_defaults() -> http1_opts().
http1_defaults() ->
    #{
        max_request_line => 8192,
        max_header_line => 8192,
        max_header_block => 10240,
        max_header_count => 100
    }.

-spec validate_http1_opts(map(), term()) -> http1_opts().
validate_http1_opts(Opts, Raw) ->
    Defaults = http1_defaults(),
    maps:fold(
        fun(K, V, Acc) ->
            case is_map_key(K, Defaults) of
                false -> error({invalid_listener_opt, protocols, Raw});
                true when is_integer(V), V >= 1, V =< 16#7FFFFFFF -> Acc#{K => V};
                true -> error({invalid_listener_opt, protocols, Raw})
            end
        end,
        Defaults,
        Opts
    ).

%% Flatten the http1 sub-opts onto proto_opts top-level with an `http1_`
%% prefix so the conn loop reads each limit with a single `maps:get/2`.
%% Returns an empty map when http1 isn't in the list.
-spec flatten_http1_opts([protocol_entry_norm(), ...]) -> #{atom() => term()}.
flatten_http1_opts(Entries) ->
    case lists:keyfind(http1, 1, Entries) of
        false ->
            #{};
        {http1, #{
            max_request_line := ReqLine,
            max_header_line := HdrLine,
            max_header_block := HdrBlock,
            max_header_count := HdrCount
        }} ->
            #{
                http1_max_request_line => ReqLine,
                http1_max_header_line => HdrLine,
                http1_max_header_block => HdrBlock,
                http1_max_header_count => HdrCount
            }
    end.

-spec http2_defaults() -> http2_opts().
http2_defaults() ->
    #{
        conn_window => 65535,
        stream_window => 65535,
        window_refill_threshold => 32768,
        max_concurrent_streams => 100,
        max_header_block => 16384,
        %% Placeholder: resolved to `2 * max_header_block` when not set
        %% explicitly (see `resolve_max_header_list_size/2`).
        max_header_list_size => 32768
    }.

-spec validate_http2_opts(map(), term()) -> http2_opts().
validate_http2_opts(Opts, Raw) ->
    Defaults = http2_defaults(),
    Merged = maps:fold(
        fun(K, V, Acc) ->
            case is_map_key(K, Defaults) of
                false -> error({invalid_listener_opt, protocols, Raw});
                true when is_integer(V), V >= 1, V =< 16#7FFFFFFF -> Acc#{K => V};
                true -> error({invalid_listener_opt, protocols, Raw})
            end
        end,
        Defaults,
        Opts
    ),
    resolve_max_header_list_size(Merged, Opts).

%% MAX_HEADER_LIST_SIZE defaults to 2x the resolved encoded-block cap so
%% raising `max_header_block` lifts both gates together; an explicit value
%% (already range-checked above) is kept as-is.
-spec resolve_max_header_list_size(http2_opts(), map()) -> http2_opts().
resolve_max_header_list_size(Merged, Opts) when is_map_key(max_header_list_size, Opts) ->
    Merged;
resolve_max_header_list_size(#{max_header_block := MaxHeaderBlock} = Merged, _Opts) ->
    Merged#{max_header_list_size => 2 * MaxHeaderBlock}.

%% Flatten the http2 sub-opts onto proto_opts top-level with an
%% `http2_` prefix so the hot path reads each knob with a single
%% `maps:get/2`. Returns an empty map when http2 isn't in the list.
-spec flatten_http2_opts([protocol_entry_norm(), ...]) -> #{atom() => term()}.
flatten_http2_opts(Entries) ->
    case lists:keyfind(http2, 1, Entries) of
        false ->
            #{};
        {http2, #{
            conn_window := Conn,
            stream_window := Stream,
            window_refill_threshold := Threshold,
            max_concurrent_streams := MaxStreams,
            max_header_block := MaxHeaderBlock,
            max_header_list_size := MaxHeaderListSize
        }} ->
            #{
                http2_conn_window => Conn,
                http2_stream_window => Stream,
                http2_window_refill_threshold => Threshold,
                http2_max_concurrent_streams => MaxStreams,
                http2_max_header_block => MaxHeaderBlock,
                http2_max_header_list_size => MaxHeaderListSize
            }
    end.

-spec http3_defaults() -> http3_opts().
http3_defaults() ->
    #{
        listeners => ?DEFAULT_H3_LISTENERS,
        max_header_block => 16384,
        max_streams_bidi => ?H3_MAX_STREAMS_BIDI,
        %% Placeholder: resolved to `2 * max_header_block` when not set
        %% explicitly (see `resolve_max_field_section_size/2`).
        max_field_section_size => 32768
    }.

-spec validate_http3_opts(map(), term()) -> http3_opts().
validate_http3_opts(Opts, Raw) ->
    Defaults = http3_defaults(),
    Merged = maps:fold(
        fun(K, V, Acc) ->
            %% `listeners` caps at the reuseport-pool limit; `max_header_block`
            %% (a byte size), `max_streams_bidi` (a stream count) and
            %% `max_field_section_size` (a byte size) go up to the 31-bit ceiling.
            Max =
                case K of
                    listeners -> ?MAX_H3_LISTENERS;
                    max_header_block -> 16#7FFFFFFF;
                    max_streams_bidi -> 16#7FFFFFFF;
                    max_field_section_size -> 16#7FFFFFFF;
                    _ -> 0
                end,
            case is_map_key(K, Defaults) of
                false -> error({invalid_listener_opt, protocols, Raw});
                true when is_integer(V), V >= 1, V =< Max -> Acc#{K => V};
                true -> error({invalid_listener_opt, protocols, Raw})
            end
        end,
        Defaults,
        Opts
    ),
    resolve_max_field_section_size(Merged, Opts).

%% MAX_FIELD_SECTION_SIZE defaults to 2x the resolved encoded-block cap so
%% raising `max_header_block` lifts both gates together; an explicit value
%% (already range-checked above) is kept as-is.
-spec resolve_max_field_section_size(http3_opts(), map()) -> http3_opts().
resolve_max_field_section_size(Merged, Opts) when is_map_key(max_field_section_size, Opts) ->
    Merged;
resolve_max_field_section_size(#{max_header_block := MaxHeaderBlock} = Merged, _Opts) ->
    Merged#{max_field_section_size => 2 * MaxHeaderBlock}.

%% Flatten the http3 sub-opts onto proto_opts top-level (`http3_*`) so
%% the conn loop reads each knob with a single `maps:get/2`. Returns an
%% empty map when http3 isn't in the list.
-spec flatten_http3_opts([protocol_entry_norm(), ...]) -> #{atom() => term()}.
flatten_http3_opts(Entries) ->
    case lists:keyfind(http3, 1, Entries) of
        false ->
            #{};
        {http3, #{
            listeners := Listeners,
            max_header_block := MaxHeaderBlock,
            max_streams_bidi := MaxStreamsBidi,
            max_field_section_size := MaxFieldSection
        }} ->
            #{
                http3_listeners => Listeners,
                http3_max_header_block => MaxHeaderBlock,
                http3_max_streams_bidi => MaxStreamsBidi,
                http3_max_field_section_size => MaxFieldSection
            }
    end.

-spec ws_defaults() ->
    #{max_frame_size := non_neg_integer(), max_message_size := non_neg_integer()}.
ws_defaults() ->
    #{
        max_frame_size => ?DEFAULT_WS_MAX_FRAME_SIZE,
        max_message_size => ?DEFAULT_WS_MAX_MESSAGE_SIZE
    }.

%% Resolve the `ws` opts map against defaults, rejecting unknown keys
%% and out-of-range values (mirroring `validate_http2_opts/2`). A
%% reassembled message is built from frames, so a single unfragmented
%% frame is also a whole message: `max_message_size` below
%% `max_frame_size` is contradictory and rejected at startup.
-spec validate_ws_opts(term()) ->
    #{max_frame_size := non_neg_integer(), max_message_size := non_neg_integer()}.
validate_ws_opts(Opts) when is_map(Opts) ->
    Defaults = ws_defaults(),
    Resolved = maps:fold(
        fun(K, V, Acc) ->
            case is_map_key(K, Defaults) of
                false -> error({invalid_listener_opt, ws, Opts});
                true when is_integer(V), V >= 0, V =< 16#7FFFFFFF -> Acc#{K => V};
                true -> error({invalid_listener_opt, ws, Opts})
            end
        end,
        Defaults,
        Opts
    ),
    #{max_frame_size := Frame, max_message_size := Msg} = Resolved,
    Msg >= Frame orelse
        error({listener_opt_conflict, ws, Opts, max_message_size_below_max_frame_size}),
    Resolved;
validate_ws_opts(Other) ->
    error({invalid_listener_opt, ws, Other}).

build_dispatch(#{routes := Module} = Opts, _ListenerName) when is_atom(Module) ->
    bake_dispatch(Module, Opts, [], no_state);
build_dispatch(#{routes := {Module, State}} = Opts, _ListenerName) when is_atom(Module) ->
    bake_dispatch(Module, Opts, [], {state, State});
build_dispatch(#{routes := #{handler := Module} = Route} = Opts, _ListenerName) when
    is_atom(Module)
->
    HandlerMws = maps:get(middlewares, Route, []),
    StateArg =
        case Route of
            #{state := S} -> {state, S};
            _ -> no_state
        end,
    bake_dispatch(Module, Opts, HandlerMws, StateArg);
build_dispatch(#{routes := Routes}, ListenerName) when is_list(Routes) ->
    {router, ListenerName};
build_dispatch(Opts, _ListenerName) ->
    bake_dispatch(roadrunner_default_handler, Opts, [], no_state).

%% Single-handler dispatch counterpart of the router's compile path.
%% Defers to `roadrunner_middleware:compile_pipeline/3` after combining
%% the listener-wide and per-handler mws lists. State is exposed
%% alongside the pipeline so `roadrunner_router:match/2`-shaped
%% callers (and other introspection paths) can read it without
%% running the pipeline.
-spec bake_dispatch(
    module(),
    opts(),
    roadrunner_middleware:middleware_list(),
    no_state | {state, term()}
) -> roadrunner_conn:dispatch().
bake_dispatch(Handler, Opts, HandlerMws, StateArg) ->
    ListenerMws = maps:get(middlewares, Opts, []),
    Pipeline = roadrunner_middleware:compile_pipeline(
        ListenerMws ++ HandlerMws, Handler, StateArg
    ),
    State =
        case StateArg of
            no_state -> undefined;
            {state, S} -> S
        end,
    {handler, Handler, Pipeline, State}.

-doc false.
-spec handle_call(
    port
    | info
    | status
    | {drain, non_neg_integer()}
    | {reload_routes, roadrunner_router:routes()},
    gen_server:from(),
    #state{}
) -> {reply, term(), #state{}} | {stop, normal, term(), #state{}}.
handle_call(port, _From, #state{port = Port} = State) ->
    {reply, Port, State};
handle_call(status, _From, #state{phase = Phase} = State) ->
    {reply, Phase, State};
handle_call({drain, Timeout}, _From, State) ->
    {Reply, NewState} = do_drain(State, Timeout),
    {stop, normal, Reply, NewState};
handle_call({reload_routes, Routes}, _From, State) ->
    Reply = do_reload_routes(State, Routes),
    {reply, Reply, State};
handle_call(info, _From, #state{proto_opts = ProtoOpts} = State) ->
    #{
        client_counter := ClientCounter,
        requests_counter := RequestsCounter,
        rejected_counter := RejectedCounter,
        throttled_counter := ThrottledCounter,
        max_clients := MaxClients,
        max_concurrent_requests := MaxConcurrentRequests
    } = ProtoOpts,
    Reply = #{
        active_clients => counters:get(ClientCounter, 1),
        max_clients => MaxClients,
        requests_served => atomics:get(RequestsCounter, 1),
        rejected => atomics:get(RejectedCounter, 1),
        max_concurrent_requests => MaxConcurrentRequests,
        throttled => atomics:get(ThrottledCounter, 1)
    },
    {reply, Reply, State}.

-spec do_reload_routes(#state{}, roadrunner_router:routes()) ->
    ok | {error, no_routes}.
do_reload_routes(
    #state{proto_opts = #{dispatch := {router, Name}, middlewares := ListenerMws}},
    Routes
) ->
    persistent_term:put(
        {roadrunner_routes, Name},
        roadrunner_router:compile(Routes, ListenerMws)
    ),
    ok;
do_reload_routes(#state{proto_opts = #{dispatch := {handler, _, _, _}}}, _Routes) ->
    {error, no_routes}.

-spec do_drain(#state{}, non_neg_integer()) ->
    {{ok, drained} | {timeout, non_neg_integer()}, #state{}}.
do_drain(
    #state{listen_socket = LSocket, quic_listener = QuicListener, proto_opts = ProtoOpts} = State,
    Timeout
) ->
    %% Close the TCP listen socket so accept fails and acceptors exit;
    %% existing TCP conns keep their own sockets and drain below.
    ok = close_tcp(LSocket),
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    Group = drain_group(ProtoOpts),
    notify_conns(Group, Deadline),
    Counter = maps:get(client_counter, ProtoOpts),
    Reply = wait_for_drain(Counter, Deadline, Group),
    %% Stop the QUIC listener LAST: `quic_listener:stop/1` kills the
    %% connections it `start_link`ed (and the h3 conn loops linked to
    %% them), so doing it before the notify/wait above would abruptly
    %% kill in-flight h3 conns instead of letting them drain. (New h3
    %% conns can still arrive during the window — the QUIC listener has
    %% no "stop accepting but keep existing" mode; they're force-closed
    %% at the deadline like any other. A GOAWAY-based graceful h3 drain
    %% is a roadmap follow-up.)
    ok = stop_quic(QuicListener),
    %% `phase = draining` was never observable here (the gen_server is
    %% blocked in wait_for_drain and the local state isn't committed),
    %% so settle straight to the final stopped state in one update.
    {Reply, State#state{listen_socket = closed, quic_listener = undefined, phase = stopped}}.

%% Best-effort broadcast to in-flight conns. Loop / SSE / WebSocket
%% handlers can pattern-match on `{roadrunner_drain, Deadline}` in
%% `handle_info/3`; non-loop conns ignore the message and fall through
%% to the mailbox check at the next keep-alive boundary.
-spec notify_conns(term(), integer()) -> ok.
notify_conns(Group, Deadline) ->
    _ = [Pid ! {roadrunner_drain, Deadline} || Pid <- pg:get_members(Group)],
    ok.

%% Poll the active-clients counter every 50ms (or whatever remains,
%% if smaller) until it hits zero or the deadline expires.
-spec wait_for_drain(counters:counters_ref(), integer(), term()) ->
    {ok, drained} | {timeout, non_neg_integer()}.
wait_for_drain(Counter, Deadline, Group) ->
    case counters:get(Counter, 1) of
        0 ->
            {ok, drained};
        N ->
            Remaining = Deadline - erlang:monotonic_time(millisecond),
            case Remaining =< 0 of
                true ->
                    _ = [exit(Pid, shutdown) || Pid <- pg:get_members(Group)],
                    {timeout, N};
                false ->
                    timer:sleep(min(50, Remaining)),
                    wait_for_drain(Counter, Deadline, Group)
            end
    end.

-spec drain_group(roadrunner_conn:proto_opts()) -> {roadrunner_drain, atom()}.
drain_group(#{listener_name := Name}) ->
    {roadrunner_drain, Name}.

-doc false.
-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-doc false.
-spec handle_info(term(), #state{}) -> {noreply, #state{}}.
handle_info(reconcile_slots, #state{reconciliation = disabled} = State) ->
    %% Race: a `slot_reconciliation` opt change between scheduling and
    %% receipt would surface as the timer firing in disabled state.
    %% Just drop it; the new config is the source of truth.
    {noreply, State};
handle_info(
    reconcile_slots,
    #state{
        proto_opts = #{client_counter := Counter, listener_name := Name},
        reconciliation = #{interval := Interval, prev_diff := PrevDiff}
    } = State
) ->
    %% pg is supervised by roadrunner_sup so it's always up when the
    %% reconciler runs (which only fires when explicitly opted into).
    %%
    %% We avoid `length/1` on the member list because `max_clients`
    %% can be configured into the tens of thousands and a full O(N)
    %% length walk would dominate the tick. We only need to know
    %% whether `length(members) >= counter` (no orphans) or
    %% `length(members) < counter` (orphans = counter - length); a
    %% bounded count short-circuits at the counter so the worst case
    %% is `min(length(members), counter)` element visits.
    Counter0 = counters:get(Counter, 1),
    PgCountBounded = count_up_to(pg:get_members({roadrunner_drain, Name}), Counter0),
    NewDiff = Counter0 - PgCountBounded,
    %% Only release slots that have been orphaned for two consecutive
    %% ticks — filters out the spawn-time race where a fresh conn has
    %% incremented the counter but hasn't yet pg:join'd.
    Release = min(PrevDiff, NewDiff),
    case Release of
        0 ->
            ok;
        N when N > 0 ->
            ok = counters:sub(Counter, 1, N),
            logger:notice(#{
                msg => "roadrunner_listener reconciled orphan slots",
                listener_name => Name,
                released => N,
                counter_was => Counter0,
                pg_count_bounded => PgCountBounded
            }),
            ok = roadrunner_telemetry:slots_reconciled(#{
                listener_name => Name,
                released => N,
                counter_was => Counter0
            })
    end,
    erlang:send_after(Interval, self(), reconcile_slots),
    {noreply, State#state{
        reconciliation = #{interval => Interval, prev_diff => NewDiff - Release}
    }};
handle_info(_Msg, State) ->
    {noreply, State}.

%% Count list elements, short-circuiting at `Cap`. Used by the slot
%% reconciler so the worst-case walk per tick is bounded by the
%% `client_counter` (i.e. `max_clients`) rather than the absolute
%% size of the pg member list.
-spec count_up_to([term()], non_neg_integer()) -> non_neg_integer().
count_up_to(List, Cap) ->
    count_up_to(List, Cap, 0).

-spec count_up_to([term()], non_neg_integer(), non_neg_integer()) -> non_neg_integer().
count_up_to(_, Cap, N) when N >= Cap -> Cap;
count_up_to([], _Cap, N) -> N;
count_up_to([_ | T], Cap, N) -> count_up_to(T, Cap, N + 1).

-doc false.
-spec terminate(term(), #state{}) -> ok.
terminate(_Reason, #state{
    listen_socket = LSocket, quic_listener = QuicListener, proto_opts = ProtoOpts
}) ->
    erase_routes(ProtoOpts),
    ok = stop_quic(QuicListener),
    %% `drain/2` already closed the TCP socket on its way out
    %% (`closed`), and an HTTP/3-only listener never had one (`none`).
    close_tcp(LSocket).

-spec stop_quic(pid() | undefined) -> ok.
stop_quic(undefined) ->
    ok;
stop_quic(QuicPool) ->
    %% Unlink first so stopping the pool (which `exit/2`s the supervisor)
    %% doesn't deliver a teardown EXIT back to this gen_server.
    true = unlink(QuicPool),
    quic_listener_sup:stop(QuicPool).

-spec erase_routes(roadrunner_conn:proto_opts()) -> ok.
erase_routes(#{dispatch := {router, Name}}) ->
    _ = persistent_term:erase({roadrunner_routes, Name}),
    ok;
erase_routes(_) ->
    ok.
