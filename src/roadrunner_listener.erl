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
`max_clients` counter), and spawn-links `num_acceptors` (default: one per
online scheduler, at most 10)
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
    register_for_drain/2,
    port/1,
    info/1,
    status/1,
    reload_routes/2
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-export_type([opts/0]).

-define(DEFAULT_MAX_CONTENT_LENGTH, 10485760).
-define(DEFAULT_REQUEST_TIMEOUT, 30000).
%% Bound on `ssl:handshake/2`, run by the connection process after the
%% acceptor hands the socket over. Without one, a client that connects
%% to a TLS listener and never sends a ClientHello holds its
%% `max_clients` slot and descriptor indefinitely. 5 s comfortably
%% covers slow real clients.
-define(DEFAULT_TLS_HANDSHAKE_TIMEOUT, 5000).
-define(DEFAULT_KEEP_ALIVE_TIMEOUT, 60000).
%% A conn killed outright (`exit(Pid, kill)`, a `max_heap_size` kill) skips
%% its exit path and leaks a slot and a drain-registry row for the life of
%% the listener; only the reaper gives them back, so it runs by default.
%% One tick a minute costs at most one `is_process_alive` per registered
%% conn, and an orphan is reaped within two ticks.
-define(DEFAULT_SLOT_RECONCILIATION_INTERVAL, 60000).
%% How often the route rate-limit buckets that are full again are dropped.
%% Only full ones go, which a client cannot tell from none, so this bounds
%% how long idle buckets hold memory, not how the limits behave.
-define(ROUTE_RATE_LIMIT_SWEEP_INTERVAL, 10000).
%% The most acceptors spawned by default; fewer when there are fewer
%% online schedulers (`default_num_acceptors/0`).
-define(MAX_DEFAULT_NUM_ACCEPTORS, 10).
-define(DEFAULT_MAX_KEEP_ALIVE, 1000).
-define(DEFAULT_MAX_CLIENTS, 16384).
-define(DEFAULT_MAX_CONCURRENT_REQUESTS, infinity).
%% `Retry-After` seconds on a request shed at the in-flight ceiling.
-define(DEFAULT_SHED_RETRY_AFTER, 1).
-define(DEFAULT_MIN_BYTES_PER_SECOND, 100).
%% TCP listen backlog (kernel SYN/accept queue depth). OTP defaults to 5,
%% which a burst of concurrent connects overflows; 1024 matches cowboy.
%% Linux clamps the effective value at `net.core.somaxconn`.
-define(DEFAULT_SOCKET_BACKLOG, 1024).
%% Emulator user-space recv buffer per accepted socket (see the `buffer`
%% note in `base_listen_opts/1` for the throughput/memory trade-off).
-define(DEFAULT_RECV_BUFFER, 65536).
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
%% process. (The pool sup takes `pool_size`, the count BEYOND its base
%% listener, so the wiring passes `listeners - 1`.)
-define(DEFAULT_H3_LISTENERS, 8).
-define(MAX_H3_LISTENERS, 1024).
%% The shortest HTTP/3 `secret` accepted: 32 bytes, the key size of the
%% HMAC-SHA256 and AES-256 keys derived from it.
-define(MIN_H3_SECRET, 32).

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
  middlewares => [...]}` map. First match wins, so the specific
  route goes above the general one; a route the entries above it
  already answer in full is a config error and raises at listener
  start rather than turning into a runtime 404.

Whichever form is used, a handler that exports the optional
`roadrunner_handler` callback `init_route/1` has it run once per route
when the listener starts (and on `reload_routes/2`), turning the route's
state into the one the handler sees. A raise in it stops the listener
from starting, with `{init_route_failed, Path, Handler, Reason}`.

Optional middleware and timing knobs (durations in milliseconds):
- `middlewares` — listener-wide pipeline applied to every request.
- `max_content_length` — request-body cap across HTTP/1.1, HTTP/2, and
  HTTP/3; an over-cap body answers `413 Payload Too Large` (and resets
  the stream on h2/h3). Default 10 MB. A route can set its own, larger or
  smaller (`t:roadrunner_router:route/0`).
- `ws` — WebSocket session tunables as a nested map (see
  `t:ws_opts/0`): `max_frame_size` (per-frame payload cap) and
  `max_message_size` (reassembled + decompressed message cap), both
  defaulting to 10 MB with over-cap closing the connection with code
  1009, plus `recv_buffer` (per-session inet `buffer` override — bounds
  per-connection memory at high WebSocket concurrency; inherits the
  listener's `recv_buffer` when unset), `hibernate_after` (idle-session
  hibernation timeout in milliseconds; off when unset), `compress`
  (accept permessage-deflate; default `true`) and `idle_timeout` (close
  a session whose client sent nothing for that many milliseconds; off
  when unset). An upgrade can set each for its own session
  (`t:roadrunner_ws_handler:upgrade_opts/0`).
- `request_timeout` — header-read timeout on a fresh conn.
  Default 30 s.
- `tls_handshake_timeout` — bound on the TLS handshake (TLS listeners
  only). The handshake runs in the connection process, not the
  acceptor, so a slow or silent peer never blocks other connections
  from being accepted; one that exceeds the bound is closed and
  reported as a per-connection `{handshake, timeout}` accept error,
  releasing its `max_clients` slot. On a TLS listener that also reads
  the PROXY protocol, the same bound covers the header read that
  precedes the handshake. Default 5 s.
- `keep_alive_timeout` — idle timeout between requests on a
  keep-alive conn. Default 60 s.
- `num_acceptors` — size of the acceptor pool. Default: one per online
  scheduler, at most 10. Every acceptor waits on the same listen socket, so
  more acceptors than schedulers only adds contention: on one or two
  schedulers, matching them accepts 35-55% more connections a second than
  10 does, at about a third of the tail latency.
- `max_keep_alive_requests` — requests served per conn before
  forced close. Default 1000.
- `max_clients` — concurrent connection cap. Default 16384 (the modern
  Erlang/Elixir HTTP-server norm). A connection counts from the moment
  it is accepted, so on a TLS listener one still in its handshake holds
  a slot too. Connections accepted while already at the cap are closed
  immediately without a response. The effective cap is
  `min(max_clients, the OS file-descriptor limit)` — raise `ulimit -n`
  (and the systemd `LimitNOFILE`) for high concurrency, otherwise the
  acceptors hit `emfile` at the descriptor ceiling and emit
  `listener_accept_error`. Saturation memory scales as
  `max_clients × recv_buffer`, so memory-constrained deployments lower the
  cap or `recv_buffer`. Rejections are observable:
  each one emits `listener_conn_rejected` and increments
  the `rejected` count from `info/1`, so a rising `rejected` is the
  signal that the cap is the binding limit. For HTTP/2 and HTTP/3 the
  worst-case live-handler count is `max_clients × max_concurrent_streams`;
  bound it with `max_concurrent_requests` (default `infinity`) if heavy
  multiplexing memory is a concern.
- `max_concurrent_requests` — cap on concurrent in-flight requests
  (live handler processes) across the whole listener, for the
  multiplexed protocols (HTTP/2 and HTTP/3). Default `infinity` (off).
  `max_clients` bounds connections and `max_concurrent_streams` bounds
  streams per connection, but their product (the worst-case live-handler
  count) is otherwise unbounded; at the defaults that product
  (`16384 × 100` ≈ 1.6M) exceeds the BEAM process limit (`+P`, default
  262144), so under heavy multiplexing it can exhaust the VM-global
  process table — failing spawns everywhere, not just this listener — on
  top of unbounded handler memory. This caps the product directly; set it
  to a finite value when enabling HTTP/2 or HTTP/3 under a high
  `max_clients`. Over-limit streams
  are refused with `REFUSED_STREAM` (h2) / `H3_REQUEST_REJECTED` (h3),
  which RFC 9113 §8.7 marks safe to retry; each refusal emits
  `request_throttled` and increments the `throttled`
  count from `info/1`. HTTP/1 is unaffected (one request per connection,
  already bounded by `max_clients`), except in `shed` mode below.
- `overload_mode` — what happens to a request that arrives over
  `max_concurrent_requests`. Default `refuse`, which is the behavior
  described above. `{queue, Opts}` instead
  parks it until a slot frees, so handler memory stays bounded without
  shedding the request: latency rises under overload rather than the
  error rate. A request still waiting after `Ms` is refused exactly as
  `refuse` would, and one arriving when `N` are already parked is
  refused immediately, so overload still sheds rather than queueing
  without bound. Requires a finite `max_concurrent_requests` — there is
  nothing to queue behind otherwise, and asking for it without one is a
  configuration error.

  `Opts` takes `max_queued` and `timeout`, and both are derived when
  absent, so `{queue, #{}}` needs no tuning. `timeout` follows
  `request_timeout`, since a request already carries that deadline and
  waiting past it only produces a response nobody is left to read.
  `max_queued` follows the ceiling, so at most as many requests wait as
  run.

  Worth setting when a per-connection `max_concurrent_streams` is the
  only thing keeping handler memory down, because that ties concurrency
  to connection count: 64 connections with a window of 4 can never have
  more than 256 handlers running, however much budget is left. A
  listener-wide ceiling spends the budget you configured instead.
  Measured on 64 h2c connections against a cheap route, moving from a
  window of 4 to a window of 64 with a queued ceiling of 4096 took
  252,259 to 397,747 resp/s with no refusals and concurrency still
  bounded.

  `{shed, Opts}` answers a request over the ceiling with `503 Service
  Unavailable` and a `Retry-After` header (RFC 9110 §15.6.4, §10.2.3)
  instead of refusing its stream, so clients wait and come back rather
  than retrying at once. `REFUSED_STREAM` and `H3_REQUEST_REJECTED`
  invite an immediate retry (RFC 9113 §8.7), which suits a proxy that
  can send the request to another backend; a 503 with `Retry-After`
  is the signal for clients talking to this server directly. `Opts`
  takes `retry_after`, the seconds to send, default `1`. The 503 goes
  out before any handler runs and carries no body. In this mode HTTP/1
  requests count against the ceiling too, so it is one in-flight budget
  across every protocol: an HTTP/1 request over it gets the 503 with
  `connection: close`, before any of its body is read (the close lingers
  over a body the client may still be sending). A shed request is
  counted like a refused one: it emits `request_throttled` and
  increments the `throttled` count from `info/1`. A long-lived response
  (WebSocket, loop, stream) holds its slot until it ends, on every
  protocol. Requires a finite `max_concurrent_requests`.

  Shedding applies to the request ceiling only. A connection over
  `max_clients` is still closed without a response: answering it would
  mean a process, and on TLS a full handshake, for a client the server is
  turning away, which is the work the cap is there to stop. Set
  `max_concurrent_requests` below what `max_clients` allows, and the
  ceiling becomes the soft limit that sheds while `max_clients` stays the
  hard one.
- `socket_backlog` — TCP listen backlog (kernel SYN/accept queue
  depth). Default 1024. Raise it for connection bursts (load tests,
  health-check storms); Linux clamps the effective value at
  `net.core.somaxconn`.
- `ip` — local interface to bind. Unset (the default) binds all
  interfaces (`0.0.0.0` / `::`); set a specific address such as
  `{127,0,0,1}` to restrict the listener to loopback, e.g. a
  dev/admin/metrics endpoint that must not be reachable from the LAN.
  Applies to every socket the listener binds: plain TCP, TLS, and the
  HTTP/3 UDP socket.
- `recv_buffer` — emulator user-space buffer (bytes) for inbound TCP
  data, per accepted connection. Default 64 KB. Larger values cut the
  per-body message count on high-MTU paths; smaller values cut
  per-connection memory at scale. See the `buffer` note in
  `base_listen_opts/1`.
- `min_bytes_per_second` — slow-loris guard on the request-read
  phase (0 disables). Default 100.
- `rate_check_interval` — how often the rate guard re-checks
  (ms). Default 1000.
- `body_buffering` — `auto` (default; framework reads the full
  body before invoking the handler) or `manual` (handler calls
  `roadrunner_req:read_body/1,2`; a client sending
  `Expect: 100-continue` is asked for its body only when the handler
  first reads it, and one declaring a body over the cap gets its 413
  at once). In manual mode an HTTP/2 or HTTP/3 handler runs as
  soon as the headers are in, and a stream holds at most one
  flow-control window of body it has not read (its window, or its QUIC
  stream credit, is given back only as the handler reads); a handler that
  answers without reading the body ends the client's upload
  (`RST_STREAM(NO_ERROR)` on HTTP/2, `STOP_SENDING` on HTTP/3).
- `slot_reconciliation` — `#{interval := Ms}` (default 60000) for the
  periodic reaper that releases slots orphaned by brutal-kill exits,
  and with them the killed conns' rows in the drain registry, or
  `disabled` to turn it off. A `graceful_drain => false` listener keeps
  no registry to compare against, so the reaper is off there; asking
  for both is a configuration conflict.
- `graceful_drain` — opt out of the per-conn drain registry
  (`true` default; `false` trades drain notification for a little
  less per-conn work on short-lived workloads).
- `proxy_protocol` — `true` reads and strips the PROXY protocol header
  (HAProxy v1 / v2) an L4 balancer prepends, so `roadrunner_req:peer/1`
  is the real client. On TLS listeners the header is read before the
  handshake. TCP only. Default `false`. Enable it only behind a balancer
  that always sends the header, or a direct peer can spoof its address.
- `real_ip` — the real client IP behind HTTP reverse proxies, read from
  `X-Forwarded-For` (default) or `Forwarded` (`header => forwarded`).
  Set exactly one trust mode: `trusted_proxies => [CIDR]` (for example
  `[~"10.0.0.0/8"]`; `/0` is refused) or `trusted_hops => N`. The
  resolved address feeds `roadrunner_req:client_ip/1`, the `rate_limit`
  key, and `client_ip` in logger and telemetry metadata. Use
  `trusted_hops` only when clients can reach the listener through the
  proxies alone.
- `rate_limit` — per-client request-rate guard:
  `#{rate := N, period => Seconds, burst => N, sweep_interval => Ms}`
  (`period` default 1, `burst` default `rate`, `sweep_interval` default
  10000). A client over the rate gets `429 Too Many Requests` with
  `Retry-After` before the handler runs. Keyed on the real client IP;
  an IPv6 client is keyed by its /64. A route can add its own rate on
  top (`roadrunner_router:rate_limit()`).
- `hibernate_after` — when set, idle conns hibernate after this
  many milliseconds of main-loop idle time, which sweeps and shrinks
  the conn's heap. Pairs with `handler_spawn` below for a pool of
  mostly-idle connections; waking a hibernated conn is charged to the
  request that wakes it.
- `handler_spawn` — spawn config for every handler-running process (the
  connection process and HTTP/2/3 stream workers) as a nested map:
  `opts` (`spawn_opt` / `proc_lib` options, default
  `[{fullsweep_after, 0}]`) and `start_timeout` (init-ack deadline,
  default `infinity`). `opts` merges over the defaults per option key, so
  setting one option keeps the rest — asking for a heap hint does not
  silently change the GC policy.

  The default makes every collection a full sweep, so a connection that
  served a burst and went quiet holds far less heap than under the
  emulator's generational policy. That matters most for a pool of
  mostly-idle keep-alive connections, and it costs some throughput on
  handlers that allocate heavily. To take the emulator's generational
  policy instead, name `fullsweep_after` yourself (an empty list will
  not do, since `opts` merges): `[{fullsweep_after, 65535}]` for the
  emulator's usual value, or
  `[{fullsweep_after, element(2, erlang:system_info(fullsweep_after))}]`
  to follow whatever this node is set to, which `ERL_FULLSWEEP_AFTER` can
  move. Pair it with `hibernate_after` unless every connection stays
  busy, since idle connections otherwise keep their grown heaps. The
  intermediate values measured (5, 10 and 20) bought no middle ground.
  The measurements behind all of this are in
  [Resource limits](resource_limits.md).
- `protocols` — list of `t:protocol_entry/0`. Default `[http1]`.
  On TLS this drives `alpn_preferred_protocols` automatically.
- `tls` — `[ssl:tls_server_option()]` for HTTPS. Absent for plain
  HTTP. The listener starts the `ssl` application when it is set, so
  a release that serves TLS must include `ssl`. Prefer an ECDSA P-256
  certificate: every new TLS or QUIC connection signs with the
  certificate's key, and an ECDSA P-256 signature costs about 25 times
  less CPU than an RSA-2048 one (around 30 µs against 800 µs). In a
  connection-churn test that let the server accept 1.7 times more new
  HTTP/2 connections per second, with 44% less CPU per connection. All current
  browsers support it. To make a self-signed one for testing:
  `openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 365 -keyout key.pem -out cert.pem -subj /CN=localhost`.

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
    tls_handshake_timeout => pos_integer(),
    keep_alive_timeout => non_neg_integer(),
    num_acceptors => pos_integer(),
    max_keep_alive_requests => pos_integer(),
    max_clients => pos_integer(),
    max_concurrent_requests => infinity | pos_integer(),
    overload_mode =>
        refuse
        | {queue, #{max_queued => pos_integer(), timeout => pos_integer()}}
        | {shed, #{retry_after => pos_integer()}},
    socket_backlog => pos_integer(),
    %% Local interface to bind. Unset means all interfaces
    %% (`0.0.0.0` / `::`). Set to `{127,0,0,1}` to restrict the
    %% listener to loopback.
    ip => inet:ip_address(),
    recv_buffer => pos_integer(),
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
    %% Opt out of the per-conn drain registry. Default `true`
    %% (current behavior). Set to `false` for short-lived h1-only
    %% workloads (REST APIs, health-check probes, CLI clients) where
    %% conns finish on their own faster than any drain notification
    %% could fire. Trades graceful drain notification for ~10% lower
    %% per-conn overhead. Long-lived conns (loop handlers, SSE,
    %% WebSocket) still rely on this — keep `true` if your handlers
    %% have those.
    graceful_drain => boolean(),
    %% Opt in to the PROXY protocol (HAProxy v1 text / v2 binary). When `true`,
    %% the connection reads and strips the header an L4 balancer prepends before
    %% the first byte, so `roadrunner_req:peer/1` is the real client. On a TLS
    %% listener the header is read from the plain socket before the TLS
    %% handshake: the listener accepts plain TCP and upgrades each connection
    %% once the header is in. TCP-only: rejected on an HTTP/3-only listener.
    %% A connection whose header is missing or malformed is closed and
    %% reported as `listener_accept_error` with a
    %% `{proxy_protocol, Reason}` reason. Trust it only behind a balancer
    %% that always prepends the header (otherwise a direct peer can spoof its
    %% IP).
    proxy_protocol => boolean(),
    %% Opt in to the real client IP behind HTTP reverse proxies (load
    %% balancers, CDNs, ingress controllers) that pass it in a forwarding
    %% header. Exactly one trust mode: `trusted_proxies` lists the proxies'
    %% addresses as CIDR binaries (`~"10.0.0.0/8"`, `~"2001:db8::/32"`, or a
    %% bare address for one host; `/0`, or `::ffff:0.0.0.0/96` for all of
    %% IPv4, is refused, as it would trust hops a client writes), or
    %% `trusted_hops => N` trusts the `N` nearest hops
    %% whatever their address, for platforms that don't publish their proxy
    %% addresses. `header` reads `x_forwarded_for` (the default) or
    %% `forwarded` (RFC 7239). Starting from the socket peer, the chain is read
    %% right to left, trusted hops are skipped, and the first untrusted
    %% address is the client: `roadrunner_req:client_ip/1`, the `rate_limit`
    %% key, and `client_ip` in logger and telemetry metadata. With
    %% `trusted_proxies`, a peer outside them is itself the client, so a
    %% client that bypasses the proxies cannot spoof its address.
    %% `trusted_hops` trusts every peer, so use it only when the listener is
    %% reachable through the proxies alone: a client connecting directly would
    %% choose its own address. With `proxy_protocol`, the address the PROXY
    %% header reports is the first hop.
    real_ip => #{
        trusted_proxies => [binary()],
        trusted_hops => pos_integer(),
        header => x_forwarded_for | forwarded
    },
    %% Opt in to a per-peer request-rate guard keyed on the client IP. A map
    %% `#{rate := pos_integer()}` (requests allowed per `period`, required) with
    %% optional `period` (window in seconds, default 1, so `rate` is per-second
    %% unless set), `burst` (bucket capacity in requests, default = `rate`),
    %% and `sweep_interval` (ms between passes that drop the buckets full
    %% again, default 10000; a bucket still refilling is kept, so a peer cannot
    %% reset its limit by waiting). A peer exceeding the rate gets `429 Too
    %% Many Requests` + `Retry-After` before the handler runs. Keyed on the real
    %% client IP, so accurate behind a balancer when `proxy_protocol` is set;
    %% an IPv6 client is keyed by its /64, as a host can use any address in
    %% the /64 it is given.
    %% The per-IP bucket is lock-free (last-write-wins), so concurrent
    %% connections from one IP can momentarily admit up to that many requests
    %% past `burst`; it bounds the sustained per-source rate, not exact
    %% simultaneity. A route can add a rate of its own on top
    %% (`roadrunner_router:rate_limit()`).
    rate_limit => #{
        rate := pos_integer(),
        period => pos_integer(),
        burst => pos_integer(),
        sweep_interval => pos_integer()
    },
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
    %% between hundreds of MB and a few GB of resident memory. Pass
    %% `{fullsweep_after, 65535}` to restore the BEAM default, paired with
    %% `hibernate_after` for pools of mostly-idle conns. Also useful
    %% here: `{max_heap_size, _}` (OOM/DoS cap), `{message_queue_data,
    %% off_heap}`, `{min_bin_vheap_size, _}`. `link`/`monitor` are rejected —
    %% roadrunner owns process linkage. `start_timeout` is the `proc_lib:start`
    %% `Time`: how long to wait for a started process to ack init before
    %% killing it with `{error, timeout}` (default `infinity`); it applies to
    %% the connection process and the WebSocket session (the fire-and-forget
    %% HTTP/3 conn and stream-worker spawns have no init handshake).
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
    %%   `1..2^31-1`). Default `2^31-1`, the largest allowed, sent as
    %%   an early `WINDOW_UPDATE(0, peak - 65535)` after the server
    %%   SETTINGS (RFC 9113 §6.9.2 starts it at `65535`).
    %% - `stream_window` — the peak a stream's receive window grows to
    %%   (bytes, `1..2^31-1`). Default `16777216` (16 MB). Every stream
    %%   opens at the RFC `65535` and grows with its first refill once
    %%   its DATA is taken. An upload runs at most one window per round
    %%   trip. Setting above `conn_window` is allowed but not useful —
    %%   the conn-level peak is the binding constraint.
    %% - `window_refill_threshold` — refill trigger (bytes,
    %%   `pos_integer`). When a window drops below this, the conn
    %%   refills it back to its peak. Unset (the default), each window
    %%   refills below half its own peak.
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

The four `max_*` keys cap inbound request sizes; oversized input is
rejected before the handler runs (414 for the request line, 431 for
headers). Raise them for clients that send large headers (long JWTs /
cookies / tracing metadata); lower them to tighten the attack surface.

- `max_request_line` — request-line byte cap (method + target +
  version). Over-cap → `414 URI Too Long`. Default `8192`.
- `max_header_line` — per-header-line byte cap. Over-cap → `431`.
  Default `8192`.
- `max_header_block` — cumulative header-block byte cap. Over-cap →
  `431`. Default `10240`.
- `max_header_count` — maximum number of header lines. Over-cap →
  `431`. Default `100`.
- `linger_timeout` — after a response that closes the connection before
  the request was read to its end (a 413 over the body cap, a 431, a
  handler answering without reading its body), how long in milliseconds
  the connection keeps reading and dropping what the client still sends
  before it closes. Closing with unread input makes the kernel reset the
  connection, which can wipe the response before the client reads it
  (RFC 9112 §9.6); lingering lets it through. It ends as soon as the
  client closes. `0` closes at once. Default `1000`.
""".
-type http1_opts() :: #{
    max_request_line => 1..16#7FFFFFFF,
    max_header_line => 1..16#7FFFFFFF,
    max_header_block => 1..16#7FFFFFFF,
    max_header_count => 1..16#7FFFFFFF,
    linger_timeout => 0..16#7FFFFFFF
}.

-doc """
HTTP/2 listener tunables (under `{http2, ThisMap}` in `protocols`).

- `conn_window` — connection-level receive window peak in bytes
  (`1..2^31-1`). Default `2^31-1`, the largest allowed, sent as an
  early `WINDOW_UPDATE(0, peak - 65535)` after the server SETTINGS
  (RFC 9113 §6.9.2 starts it at `65535`). Its credit is returned as
  DATA arrives, so it bounds no memory.
- `stream_window` — the peak a stream's receive window grows to, in
  bytes (`1..2^31-1`). Default `16777216` (16 MB). Every stream
  opens at the RFC's `65535`, so a stream refused or rejected before
  its body is read can draw at most that much; its window grows to
  the peak with its first refill, once its DATA is taken. An upload
  sends at most one window per round trip, so this bounds its rate:
  16 MB allows about 160 MB/s over a 100 ms round trip, where the
  RFC's `65535` allows about 0.6 MB/s. A buffered body's credit is
  returned as it arrives, so the window bounds the rate, not the
  memory a body takes (`max_content_length` does). With manual body
  reading a stream holds at most its window until the handler reads
  it, up to `stream_window × max_concurrent_streams` per connection:
  lower `stream_window` if handlers read slowly and memory matters.
  Setting above `conn_window` is allowed but not useful — the
  conn-level peak is the binding constraint.
- `window_refill_threshold` — refill trigger in bytes. When a
  window drops below this, the conn refills it back to its peak.
  Unset (the default), each window refills once it drops below
  half its own peak.
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
  cap lifts this one too unless set explicitly. The other way round,
  response headers are kept within the limit a client sends in its own
  `SETTINGS_MAX_HEADER_LIST_SIZE` (see `t:roadrunner_handler:response/0`).
- `active`: how the connection reads its socket: `once` or an integer
  in `1..32767`. With `N`, the socket delivers up to `N` reads before
  the connection asks for more, which saves a socket call per read (on
  TLS each one is a call into the TLS connection process). With `once`,
  it asks after every read. A connection can hold up to `N` unread
  reads in its mailbox (each up to `recv_buffer` bytes on plain TCP),
  so a lower `N` bounds that memory more tightly. Default `16`. Change
  it only if you measure a reason to.
""".
-type http2_opts() :: #{
    conn_window => 1..16#7FFFFFFF,
    stream_window => 1..16#7FFFFFFF,
    window_refill_threshold => 1..16#7FFFFFFF,
    max_concurrent_streams => 1..16#7FFFFFFF,
    max_header_block => 1..16#7FFFFFFF,
    max_header_list_size => 1..16#7FFFFFFF,
    active => once | 1..32767
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
  `max_header_list_size` opt. The other way round, response headers
  are kept within the limit a client sends in its own
  `SETTINGS_MAX_FIELD_SECTION_SIZE` (see `t:roadrunner_handler:response/0`).
- `qpack_max_table_capacity`: the most bytes of QPACK dynamic table
  (RFC 9204 §3.2) a client may set up to compress its request headers,
  advertised via `SETTINGS_QPACK_MAX_TABLE_CAPACITY`. Each connection
  holds at most this much table (counted as name + value + 32 per entry,
  §3.2.1). Default `4096`, the HTTP/2 HPACK default; `0` turns the
  dynamic table off. The server's own response headers always use the
  static table.
- `qpack_blocked_streams`: how many request streams of a connection may
  wait for dynamic table entries still on their way (RFC 9204 §2.1.2),
  advertised via `SETTINGS_QPACK_BLOCKED_STREAMS`. Most clients only put
  headers in the dynamic table when this is above `0`. A waiting request
  is read once the entries it needs arrive; it holds no in-flight slot
  until then. Default `16`; `0` allows none, so a client may only use
  entries it knows the server has.
- `secret` — a binary of at least 32 random bytes the QUIC keys of the
  listener derive from: the key of the stateless reset tokens (RFC 9000
  §10.3), so a client still talking to a connection the server has lost
  (after a restart, say) is told at once to stop rather than waiting out
  its idle timeout, and the key of the address validation tokens sent
  with NEW_TOKEN (§8.1.3), so a client coming back within the hour skips
  the limit on what the server sends before its address is validated.
  Every listener of the pool shares it. Keep it as secret as the TLS key.
  Give another server the same secret only if every packet of a
  connection reaches the server holding it: a server sent a packet for a
  connection it does not have answers with a valid reset, so anyone who
  can route packets to it can close connections on the others (RFC 9000
  §10.3.2, §21.11). Unset, a random one is drawn when the listener
  starts, so a restarted listener can neither reset the connections of
  the one before it nor accept its tokens.
""".
-type http3_opts() :: #{
    listeners => 1..?MAX_H3_LISTENERS,
    max_header_block => 1..16#7FFFFFFF,
    max_streams_bidi => 1..16#7FFFFFFF,
    max_field_section_size => 1..16#7FFFFFFF,
    qpack_max_table_capacity => 0..16#7FFFFFFF,
    qpack_blocked_streams => 0..16#7FFFFFFF,
    secret => binary()
}.

-doc """
WebSocket session tunables (under `ws` in the listener opts).

- `max_frame_size` — per-frame payload cap in bytes. An inbound
  frame declaring more than this closes the connection with code
  1009 before the payload is buffered. Default 10 MB.
- `max_message_size` — cap on a reassembled message in bytes: the
  running fragment total, and the decompressed size when
  permessage-deflate is negotiated. Over-cap closes with 1009. Must
  be `>= max_frame_size`. Default 10 MB.
- `recv_buffer` — inet `buffer` (user-space receive buffer, bytes)
  applied to the socket when a connection upgrades to a WebSocket
  session — the session-level override of the top-level
  `recv_buffer` listener opt. The emulator keeps a buffer of this size alive per
  socket, so it bounds how many bytes one `{tcp, _, Data}` delivery
  carries AND what every connection pays in resident memory. Unset
  (the default) inherits the listener socket's `recv_buffer` (64 KB
  default) — sized for HTTP request flow, where bodies arrive in
  bulk. Long-lived
  WebSocket sessions that exchange small messages should set this
  lower in production: at high connection counts the inherited
  64 KB dominates per-connection memory (64 KB × connections),
  while a few KB is plenty for message-sized deliveries. Large
  inbound frames are still delivered correctly with a small buffer,
  just across more deliveries — deployments streaming multi-KB
  frames client→server should keep it larger.
- `hibernate_after` — idle milliseconds after which a WebSocket
  session hibernates (heap shrinks to the minimum until the next
  inbound event wakes it). The session-side counterpart of the
  top-level `hibernate_after` conn knob, with the same tradeoff:
  each wake costs a heap rebuild, so it suits mostly-idle sessions
  (presence, notifications, low-traffic subscriptions) where the
  per-connection heap held across long silences dominates. A busy
  session never pays — the next frame arrives before the timer.
  Unset (the default) never hibernates on idle; handlers can still
  opt in per event via the `hibernate` return option.
- `compress` — whether to accept a client's permessage-deflate offer
  (RFC 7692). Default `true`.
- `idle_timeout` — close a session whose client sent nothing for this
  many milliseconds, with close code 1001; the handler's `terminate/2`
  gets `timeout`. The session checks once per interval, so a silent
  client is closed between one and two intervals after its last bytes.
  Unset (the default) never closes on idle.
- `active` — how a session reads its socket: `once` or an integer in
  `1..32767`. With `N`, the socket delivers up to `N` reads before the
  session asks for more, which saves a socket call per message (on TLS
  each one is a call into the TLS connection process). With `once`, it
  asks after every message. A session can hold up to `N` unread reads
  in its mailbox (each up to `recv_buffer` bytes on plain TCP), so a
  lower `N` bounds that memory more tightly. Unset (the default), a
  plain TCP session reads with `once`, where the gap between arms lets
  several frames gather into one delivery and the socket keeps the
  quickest wake-up, and a TLS session with `16`. A value set here
  applies to both.

An upgrade can set each of these for its own session
(`t:roadrunner_ws_handler:upgrade_opts/0`).
""".
-type ws_opts() :: #{
    max_frame_size => 0..16#7FFFFFFF,
    max_message_size => 0..16#7FFFFFFF,
    recv_buffer => 1..16#7FFFFFFF,
    hibernate_after => 1..16#7FFFFFFF,
    compress => boolean(),
    idle_timeout => 1..16#7FFFFFFF,
    active => once | 1..32767
}.

-record(state, {
    %% `none` when the listener serves HTTP/3 only (no TCP socket);
    %% `closed` after `drain/2` shuts the TCP socket on its way out.
    listen_socket :: roadrunner_transport:socket() | closed | none,
    port :: inet:port_number(),
    proto_opts :: roadrunner_conn:proto_opts(),
    phase = accepting :: accepting | draining | stopped,
    %% Slot reconciliation (on by default, every 60 s). A periodic
    %% timer compares `client_counter` against the live registered conns
    %% and releases slots that have been orphaned by `kill`-style exits
    %% (which bypass `terminate/3`). `prev_diff` tracks the previous
    %% tick's diff to filter out spawn-time races (a freshly-started
    %% conn has bumped the counter but not yet registered) — only
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
    %% Kept after the fields above so their positions are unchanged
    %% (some tests read `proto_opts` positionally via `element/2`).
    quic_listener = undefined :: pid() | undefined,
    %% The bucket store of the routes with their own `rate_limit`, created
    %% when the route table first has one (at start or on `reload_routes/2`)
    %% and kept for the life of the listener; `undefined` until then.
    route_buckets = undefined :: ets:table() | undefined,
    %% Shared by the QUIC pool's listeners; `do_drain/2` closes it so no new
    %% h3 connection starts while the open ones finish. `undefined` on a
    %% listener without `http3`.
    quic_accept_gate :: roadrunner_quic_listener:accept_gate() | undefined
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
every active conn, and then polls the live-connection counter until it
hits zero or `Timeout` milliseconds elapse. Conns still alive at the
deadline are hard-killed via `exit(Pid, shutdown)`.

An idle HTTP/1.1 conn closes, and an HTTP/2 or HTTP/3 conn sends GOAWAY,
refuses new requests and closes once its in-flight requests finish. The
handler of every in-flight request gets the same message on every
protocol: on HTTP/1.1 it runs in the conn process itself, and an HTTP/2
or HTTP/3 conn passes the message on to each of its stream workers, so
a `{loop, ...}` handler sees it in `handle_info/3` (see
`roadrunner_handler`) and can wind down, as a WebSocket handler can in
`handle_drain/2`.

Returns `{ok, drained}` when the counter reached zero before the
deadline, or `{timeout, Remaining}` with the count that was still
alive when the timeout fired (those processes are torn down before
returning).

The listener then exits, and `drain/2` returns only once it is gone, so
the name is free and a `roadrunner:start_listener/2` or `start_link/2`
right after it starts a fresh listener.
""".
-spec drain(Name :: atom(), Timeout :: non_neg_integer()) ->
    {ok, drained} | {timeout, non_neg_integer()}.
drain(Name, Timeout) ->
    %% The listener replies, then stops. Wait for it to be gone so a
    %% caller that restarts it right away doesn't race its exit.
    Mon = monitor(process, Name),
    Reply = gen_server:call(Name, {drain, Timeout}, Timeout + 5000),
    receive
        {'DOWN', Mon, process, _, _} -> Reply
    end.

-doc """
Broadcast a `{roadrunner_drain, Deadline}` notification to every conn /
WS session in the listener's drain registry **without** stopping the
listener or waiting on the counter.

Use for soft-drain workflows — telling long-lived sessions to wind down
ahead of a deploy, or in test suites that want to observe drain
behavior without losing the listener for subsequent cases. Unlike
`drain/2`, the listener keeps accepting new connections. Handlers get
the message as they do from `drain/2`.

Like every other call into a listener, exits with `noproc` when no
listener by that name is running.
""".
-spec notify_drain(Name :: atom(), Deadline :: integer()) -> ok.
notify_drain(Name, Deadline) when is_atom(Name), is_integer(Deadline) ->
    gen_server:call(Name, {notify_drain, Deadline}).

-doc """
Register `Pid` in the listener's drain registry so `drain/2` and
`notify_drain/2` reach it with `{roadrunner_drain, Deadline}`. The
connection processes register themselves; this is for a process that
lives outside the conn lifecycle (a long-lived worker, say) and wants
the same notification. Exits with `noproc` when no listener by that
name is running.
""".
-spec register_for_drain(Name :: atom(), pid()) -> ok.
register_for_drain(Name, Pid) when is_atom(Name), is_pid(Pid) ->
    gen_server:call(Name, {register_for_drain, Pid}).

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
  Also emitted in real time as `listener_conn_rejected`.
- `max_concurrent_requests` — the configured in-flight ceiling
  (`infinity` when off).
- `throttled` — cumulative count of requests refused (or, in `shed`
  mode, answered 503) because the listener was at its
  `max_concurrent_requests` ceiling. A rising `throttled`
  means the in-flight cap is binding. Also emitted in real time as
  `request_throttled`.

Useful for ops dashboards / health endpoints.
""".
-spec info(Name :: atom()) ->
    #{
        active_clients := non_neg_integer(),
        max_clients := pos_integer(),
        requests_served := non_neg_integer(),
        rejected := non_neg_integer(),
        max_concurrent_requests := infinity | pos_integer(),
        throttled := non_neg_integer(),
        rate_limited := non_neg_integer()
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

Returns `ok` on success, `{error, no_routes}` if the listener was
started in single-handler mode (`routes => Module` or no `routes`
opt) since there's no router table to reload, or
`{error, Reason}` carrying a `t:roadrunner_router:validation_error/0`
if the replacement table cannot work. A rejected table is refused
whole: the listener keeps serving the routes it already had, and
nothing about the running table changes. The same holds when a hook
that runs for the new table fails, a per-route middleware's `init/1` or
a handler's `init_route/1` (such as `roadrunner_static` rejecting an
option): the reload returns `{error, {init_failed, Reason}}` and the
listener keeps its current routes. At listener start the same failure
stops the start, since there is no table to keep.
Both run again for the new table, once per route.

Each call performs one global `persistent_term` swap, which scans every
process heap to reclaim the old table. That cost is acceptable for a
whole-table swap at deploy time, but callers should batch route changes
into a single `reload_routes/2` rather than calling it per route.
""".
-spec reload_routes(Name :: atom(), roadrunner_router:routes()) ->
    ok
    | {error, no_routes}
    | {error, roadrunner_router:validation_error()}
    | {error, {init_failed, term()}}.
reload_routes(Name, Routes) ->
    gen_server:call(Name, {reload_routes, Routes}).

%% --- gen_server callbacks ---
-doc false.
-spec init(opts()) -> {ok, #state{}} | {stop, term()}.
init(#{port := Port} = Opts) ->
    %% Trap exits so a supervisor shutdown runs `terminate/2`, which erases
    %% what `publish_routes/3` puts in `persistent_term`. A linked process
    %% (acceptor, overload queue, QUIC pool) exiting abnormally still takes
    %% the listener down with it (`handle_info/2`).
    _ = process_flag(trap_exit, true),
    ok = ensure_ssl_started(Opts),
    ListenerName = listener_name(),
    ProtoOpts = build_proto_opts(Opts, ListenerName),
    RouteBuckets = publish_routes(ListenerName, Opts, ProtoOpts),
    proc_lib:set_label({roadrunner_listener, ListenerName, Port}),
    #{protocols := Protocols} = ProtoOpts,
    %% TCP (`http1`/`http2`) and QUIC (`http3`) are independent
    %% transports that co-listen on the same port number. Bring up
    %% whichever the `protocols` list selects; an `http3`-only listener
    %% has no TCP socket (`none`), and a TCP-only listener no QUIC pid.
    QuicAcceptGate = new_quic_accept_gate(Protocols),
    case start_tcp(Port, Opts, Protocols, ProtoOpts) of
        {ok, LSocket} ->
            case start_quic(Port, Opts, Protocols, ProtoOpts, QuicAcceptGate) of
                {ok, QuicListener} ->
                    Reconciliation = setup_reconciliation(Opts),
                    ok = setup_rate_limit_sweep(ProtoOpts),
                    {ok, #state{
                        listen_socket = LSocket,
                        quic_listener = QuicListener,
                        port = bound_port(LSocket, QuicListener),
                        proto_opts = ProtoOpts,
                        reconciliation = Reconciliation,
                        route_buckets = RouteBuckets,
                        quic_accept_gate = QuicAcceptGate
                    }};
                {error, Reason} ->
                    %% TCP bound but QUIC failed — release the TCP port
                    %% so the failed start doesn't leave it held.
                    ok = close_tcp(LSocket),
                    ok = erase_routes(ProtoOpts),
                    {stop, {listen_failed, Reason}}
            end;
        {error, Reason} ->
            %% A failed start never reaches `terminate/2`.
            ok = erase_routes(ProtoOpts),
            {stop, {listen_failed, Reason}}
    end.

%% `ssl` is not one of roadrunner's start-up applications: a plain-HTTP node
%% would load its modules for nothing, and code loading is most of the time
%% to a first response. A listener with `tls` (every `http3` one has it)
%% starts it here instead, so a release serving TLS must include `ssl`.
-spec ensure_ssl_started(opts()) -> ok.
ensure_ssl_started(#{tls := _}) ->
    {ok, _} = application:ensure_all_started(ssl),
    ok;
ensure_ssl_started(#{}) ->
    ok.

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
                    NumAcceptors =
                        case Opts of
                            #{num_acceptors := N} -> N;
                            #{} -> default_num_acceptors()
                        end,
                    ok = spawn_acceptors(LSocket, ProtoOpts, NumAcceptors),
                    {ok, LSocket};
                {error, _} = Error ->
                    Error
            end
    end.

%% Start the native QUIC listener pool roadrunner owns when `http3` is
%% requested. `roadrunner_quic_listener_sup` is a self-contained supervisor
%% (no OTP application to boot; `crypto` + `ssl` are already up as roadrunner's
%% own deps), started directly by this gen_server via `start_quic_pool/2`.
%% Each accepted QUIC connection is handed to a fresh
%% `roadrunner_conn_loop_http3` owner via the arity-1 `connection_handler`; the
%% listener then transfers ownership to the returned pid. `http3` having been
%% validated to require `tls`, the `tls` opt is always present here.
-spec start_quic(
    inet:port_number(),
    opts(),
    [http1 | http2 | http3, ...],
    roadrunner_conn:proto_opts(),
    roadrunner_quic_listener:accept_gate()
) -> {ok, pid() | undefined} | {error, term()}.
start_quic(Port, Opts, Protocols, ProtoOpts, AcceptGate) ->
    case lists:member(http3, Protocols) of
        false ->
            {ok, undefined};
        true ->
            #{tls := UserTlsOpts} = Opts,
            {Cert, CertChain, Key} = quic_cert_key(UserTlsOpts),
            Handler = fun(ConnPid) -> roadrunner_conn_loop_http3:start(ConnPid, ProtoOpts) end,
            %% Start a POOL of reuseport listeners (the native pool sup enables
            %% SO_REUSEPORT when there is more than one listener and shares one
            %% connection registry across them) so inbound demux parallelizes
            %% across cores rather than funnelling through one listener process.
            %% `roadrunner_quic_listener_sup:start_link` links the pool supervisor to
            %% this gen_server for shared fate; an `init`-time bind failure
            %% comes back as `{error, _}` from the synchronous start (so
            %% `init/1` can still close the already-opened TCP socket).
            %% A reuseport pool needs a CONCRETE port: binding port 0 on
            %% each listener would hand out a different ephemeral port. So
            %% when asked for an ephemeral port, hold a reuseport probe
            %% socket to pin a free port, start the pool on it, then drop
            %% the probe (the pool listeners keep the port via reuseport).
            Listeners = maps:get(http3_listeners, ProtoOpts, ?DEFAULT_H3_LISTENERS),
            {QuicPort, Probe} = resolve_quic_port(Port, Listeners, Opts),
            MaxStreamsBidi = maps:get(http3_max_streams_bidi, ProtoOpts, ?H3_MAX_STREAMS_BIDI),
            PoolOpts = #{
                cert => Cert,
                key => Key,
                cert_chain => CertChain,
                alpn => [~"h3"],
                max_streams_bidi => MaxStreamsBidi,
                connection_handler => Handler,
                pool_size => Listeners - 1,
                %% In manual body mode a request stream's credit is granted
                %% as its handler reads the body, not as the body arrives.
                stream_credit => stream_credit(ProtoOpts),
                accept_gate => AcceptGate
            },
            %% Bind the QUIC pool to the same interface as the TCP socket
            %% when `ip` is set, so an h3 listener honors loopback too.
            PoolOptsIp =
                case Opts of
                    #{ip := IP} -> PoolOpts#{ip => IP};
                    #{} -> PoolOpts
                end,
            Res = start_quic_pool(QuicPort, with_quic_secret(Opts, PoolOptsIp)),
            ok = close_quic_probe(Probe),
            Res
    end.

%% The `{http3, #{secret := _}}` secret (validated with the rest of the
%% http3 opts) goes to the QUIC pool straight from the listener opts. It is
%% kept out of the flattened proto opts, which every connection process
%% holds and a crash report would print.
-spec with_quic_secret(opts(), map()) -> map().
with_quic_secret(#{protocols := Protocols}, PoolOpts) ->
    case lists:keyfind(http3, 1, Protocols) of
        {http3, #{secret := Secret}} -> PoolOpts#{secret => Secret};
        _ -> PoolOpts
    end.

-spec stream_credit(roadrunner_conn:proto_opts()) -> on_receipt | on_read.
stream_credit(#{body_buffering := manual}) -> on_read;
stream_credit(_ProtoOpts) -> on_receipt.

%% The pool is a supervisor, so it can only be `start_link`ed - which
%% makes this gen_server its parent (the pool then lives as long as the
%% listener, and they share fate). The listener traps exits (`init/1`), so
%% a bind failure surfaces as `{error, _}` rather than the supervisor's
%% startup EXIT killing it, and `init/1` then stops.
-spec start_quic_pool(inet:port_number(), map()) -> {ok, pid()} | {error, term()}.
start_quic_pool(Port, PoolOpts) ->
    roadrunner_quic_listener_sup:start_link(Port, PoolOpts).

%% Pin a free UDP port with a reuseport probe socket so all pool
%% listeners bind the same concrete port; a fixed port is used as-is.
%% The probe binds the same interface as the pool (via `ip`) so the
%% pinned port is genuinely free on that address, not just on `0.0.0.0`.
%% A single listener binds without reuseport, so the probe would hold the
%% port against it: it binds port 0 itself instead, and the port is read
%% back from it.
-spec resolve_quic_port(inet:port_number(), pos_integer(), opts()) ->
    {inet:port_number(), gen_udp:socket() | undefined}.
resolve_quic_port(0, Listeners, Opts) when Listeners > 1 ->
    ProbeOpts =
        case Opts of
            #{ip := IP} -> [{reuseport, true}, {ip, IP}];
            #{} -> [{reuseport, true}]
        end,
    {ok, Probe} = gen_udp:open(0, ProbeOpts),
    {ok, ProbePort} = inet:port(Probe),
    {ProbePort, Probe};
resolve_quic_port(Port, _Listeners, _Opts) ->
    {Port, undefined}.

-spec close_quic_probe(gen_udp:socket() | undefined) -> ok.
close_quic_probe(undefined) -> ok;
close_quic_probe(Probe) -> gen_udp:close(Probe).

%% The bound port comes from whichever transport owns it. TCP wins when
%% present (co-listen reuses the same number for UDP); an HTTP/3-only
%% listener reads it back from the QUIC listener.
-spec bound_port(roadrunner_transport:socket() | none, pid() | undefined) -> inet:port_number().
bound_port(none, QuicPool) ->
    [Listener | _] = roadrunner_quic_listener_sup:get_listeners(QuicPool),
    roadrunner_quic_listener:get_port(Listener);
bound_port(LSocket, _QuicListener) ->
    {ok, BoundPort} = roadrunner_transport:port(LSocket),
    BoundPort.

%% Only an `http3` listener has a QUIC accept gate, so a TCP-only listener
%% never loads `roadrunner_quic_listener`: startup time is dominated by
%% code loading.
-spec new_quic_accept_gate([http1 | http2 | http3, ...]) ->
    roadrunner_quic_listener:accept_gate() | undefined.
new_quic_accept_gate(Protocols) ->
    case lists:member(http3, Protocols) of
        true -> roadrunner_quic_listener:new_accept_gate();
        false -> undefined
    end.

-spec close_quic_accept_gate(roadrunner_quic_listener:accept_gate() | undefined) -> ok.
close_quic_accept_gate(undefined) -> ok;
close_quic_accept_gate(Gate) -> roadrunner_quic_listener:close_accept_gate(Gate).

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

%% `graceful_drain => false` leaves no registry to compare the counter
%% against: every live conn would look like an orphan and lose its slot. So
%% the reaper is off on such a listener, and asking for it explicitly there
%% is a conflict rather than a silent no-op.
-spec setup_reconciliation(opts()) ->
    disabled | #{interval := pos_integer(), prev_diff := non_neg_integer()}.
setup_reconciliation(#{graceful_drain := false, slot_reconciliation := Explicit}) when
    Explicit =/= disabled
->
    error({listener_opt_conflict, slot_reconciliation, Explicit, no_drain_registry});
setup_reconciliation(#{graceful_drain := false}) ->
    disabled;
setup_reconciliation(#{slot_reconciliation := disabled}) ->
    disabled;
setup_reconciliation(#{slot_reconciliation := #{interval := IntervalMs}}) when
    is_integer(IntervalMs), IntervalMs > 0
->
    arm_reconciliation(IntervalMs);
setup_reconciliation(#{slot_reconciliation := Other}) ->
    error({invalid_listener_opt, slot_reconciliation, Other});
setup_reconciliation(_Opts) ->
    arm_reconciliation(?DEFAULT_SLOT_RECONCILIATION_INTERVAL).

-spec arm_reconciliation(pos_integer()) ->
    #{interval := pos_integer(), prev_diff := non_neg_integer()}.
arm_reconciliation(IntervalMs) ->
    _ = erlang:send_after(IntervalMs, self(), reconcile_slots),
    #{interval => IntervalMs, prev_diff => 0}.

%% Arm the periodic per-peer rate-limit bucket sweep when the guard is on. Like
%% `setup_reconciliation`, the `erlang:send_after` timer auto-cancels when the
%% listener exits, so there is no `terminate/2` cleanup; the ETS table dies with
%% its owner (this gen_server) for the same reason.
-spec setup_rate_limit_sweep(roadrunner_conn:proto_opts()) -> ok.
setup_rate_limit_sweep(#{rate_limit := #{sweep_interval := IntervalMs}}) ->
    _ = erlang:send_after(IntervalMs, self(), rate_limit_sweep),
    ok;
setup_rate_limit_sweep(_ProtoOpts) ->
    ok.

%% Compile + publish to `persistent_term` once, at listener start. The
%% conn reads via `persistent_term:get/1` on every request, so the
%% lookup is O(1) and the table is shared across all conns of this
%% listener without copying. A table with a route `rate_limit` gets its
%% bucket store first (`new_route_buckets/2`), returned for the state. A
%% store an earlier listener of this name left behind (one whose start
%% failed ends without `terminate/2`) is dropped rather than reused: its
%% table died with that listener.
-spec publish_routes(atom(), opts(), roadrunner_conn:proto_opts()) -> ets:table() | undefined.
publish_routes(ListenerName, #{routes := Routes} = Opts, ProtoOpts) when is_list(Routes) ->
    Compiled = roadrunner_router:compile(Routes, maps:get(middlewares, Opts, [])),
    RouteBuckets =
        case route_rate_limited(Routes) of
            true ->
                new_route_buckets(ListenerName, ProtoOpts);
            false ->
                _ = persistent_term:erase({roadrunner_route_rate_limit, ListenerName}),
                undefined
        end,
    persistent_term:put({roadrunner_routes, ListenerName}, Compiled),
    RouteBuckets;
publish_routes(_ListenerName, _Opts, _ProtoOpts) ->
    undefined.

%% Whether any route sets its own `rate_limit`.
-spec route_rate_limited(roadrunner_router:routes()) -> boolean().
route_rate_limited(Routes) ->
    lists:any(
        fun
            (#{rate_limit := _}) -> true;
            (_Route) -> false
        end,
        Routes
    ).

%% Create the bucket store of the route rate limits and publish it, with
%% the counter its refusals add to, under the name the conns look it up by
%% (`roadrunner_route_rate_limit`). It is published before the routes
%% that use it, so no request matches such a route without it. Like the
%% listener's own store, the table is owned by this gen_server and dies with
%% it, and the sweep timer cancels itself.
-spec new_route_buckets(atom(), roadrunner_conn:proto_opts()) -> ets:table().
new_route_buckets(ListenerName, #{rate_limited_counter := Counter}) ->
    Table = ets:new(roadrunner_route_rate_limit, [set, public, {write_concurrency, auto}]),
    persistent_term:put({roadrunner_route_rate_limit, ListenerName}, {Table, Counter}),
    _ = erlang:send_after(?ROUTE_RATE_LIMIT_SWEEP_INTERVAL, self(), route_rate_limit_sweep),
    Table.

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
open_listen_socket(Port, #{tls := _, proxy_protocol := true} = Opts, _Protocols) ->
    %% TLS behind a PROXY-protocol balancer: the header arrives in plaintext
    %% before the ClientHello, so the listen socket is plain TCP and the conn
    %% reads the header off the raw stream, then upgrades the socket with the
    %% `tls_upgrade` options carried in proto_opts (`maybe_tls_upgrade/3`).
    roadrunner_transport:listen(Port, base_listen_opts(Opts));
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
    %% (~106 lookups per connection). The new backend's
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
    %% typical request, comfortably above the per-MTU floor. Saturation
    %% memory scales as `max_clients × this buffer`, so it is the
    %% `recv_buffer` listener opt — lower it to trade body-path
    %% throughput for per-connection memory at a high `max_clients`. See
    %% `erlang/otp#9423` and `ninenines/cowlib#143` for the upstream
    %% context that prompted this tuning.
    Base = [
        binary,
        {active, false},
        {reuseaddr, true},
        {packet, raw},
        {nodelay, true},
        {backlog, maps:get(socket_backlog, Opts, ?DEFAULT_SOCKET_BACKLOG)},
        {buffer, validate_recv_buffer(Opts)}
    ],
    %% Prepend `{ip, IP}` only when the caller set it, so the default
    %% list (and the default all-interfaces bind) is unchanged. Both
    %% `gen_tcp:listen/2` and `ssl:listen/2` accept `{ip, _}`, and the
    %% TLS path builds on this list, so a loopback bind covers HTTP and
    %% HTTPS alike.
    case Opts of
        #{ip := IP} -> [{ip, IP} | Base];
        #{} -> Base
    end.

%% One acceptor per online scheduler, at most ?MAX_DEFAULT_NUM_ACCEPTORS.
%% Every acceptor waits on the one listen socket, so acceptors beyond the
%% schedulers contend for it: measured over sustained connection churn,
%% matching one or two schedulers accepted 35-55% more connections a second
%% than 10 acceptors, with less CPU per connection and a third of the p99;
%% at eight schedulers eight and 10 were even, so larger machines keep 10.
-spec default_num_acceptors() -> pos_integer().
default_num_acceptors() ->
    min(erlang:system_info(schedulers_online), ?MAX_DEFAULT_NUM_ACCEPTORS).

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

%% Queue and shed modes only mean something when there is a ceiling to
%% queue behind or shed at, so asking for either without
%% `max_concurrent_requests` is a configuration error rather than a
%% silent no-op.
%%
%% Both knobs are derived when absent, so `{queue, #{}}` is usable
%% without inventing numbers. `timeout` follows `request_timeout`,
%% because a request already carries that deadline and waiting past it
%% only produces a response nobody is left to read. `max_queued` follows
%% the ceiling, so at most as many requests wait as run: total requests
%% in the system stay under twice the ceiling, and the worst-case wait
%% stays around one service time per queued request.
%%
%% Shed mode's `retry_after` defaults to one second: a slot frees as soon
%% as one in-flight request ends, so the shortest wait `Retry-After` can
%% express (RFC 9110 §10.2.3, whole seconds) is the one that fits.
-spec validate_overload_mode(term(), infinity | pos_integer(), pos_integer()) ->
    refuse
    | {queue, #{max_queued := pos_integer(), timeout := pos_integer()}}
    | {shed, #{retry_after := pos_integer()}}.
validate_overload_mode(refuse, _Max, _RequestTimeout) ->
    refuse;
validate_overload_mode({Kind, _Opts} = Mode, infinity, _RequestTimeout) when
    Kind =:= queue; Kind =:= shed
->
    error({invalid_listener_opt, overload_mode, {Mode, requires_max_concurrent_requests}});
validate_overload_mode({queue, Queue}, Max, RequestTimeout) when is_map(Queue) ->
    MaxQueued = maps:get(max_queued, Queue, Max),
    Timeout = maps:get(timeout, Queue, RequestTimeout),
    case
        is_integer(MaxQueued) andalso MaxQueued > 0 andalso is_integer(Timeout) andalso Timeout > 0
    of
        true ->
            {queue, #{max_queued => MaxQueued, timeout => Timeout}};
        false ->
            error({invalid_listener_opt, overload_mode, {queue, Queue}})
    end;
validate_overload_mode({shed, Shed}, _Max, _RequestTimeout) when is_map(Shed) ->
    case maps:get(retry_after, Shed, ?DEFAULT_SHED_RETRY_AFTER) of
        RetryAfter when is_integer(RetryAfter), RetryAfter > 0 ->
            {shed, #{retry_after => RetryAfter}};
        _ ->
            error({invalid_listener_opt, overload_mode, {shed, Shed}})
    end;
validate_overload_mode(Other, _Max, _RequestTimeout) ->
    error({invalid_listener_opt, overload_mode, Other}).

%% `refuse` costs nothing at all on the release path; the queue form
%% carries the process, the atomic that says whether anyone is parked,
%% and the wait deadline, so the hot path never reads proto_opts again.
%% The shed form carries only its `Retry-After`, and like `refuse` has
%% nothing to wake on release.
-spec setup_overload(
    refuse
    | {queue, #{max_queued := pos_integer(), timeout := pos_integer()}}
    | {shed, #{retry_after := pos_integer()}},
    infinity | pos_integer(),
    counters:counters_ref()
) -> roadrunner_conn:overload().
setup_overload(refuse, _Max, _Counter) ->
    refuse;
setup_overload({queue, #{max_queued := MaxQueued, timeout := Timeout}}, Max, Counter) ->
    {ok, Pid} = roadrunner_overload_queue:start_link(Max, Counter, MaxQueued),
    {queue, Pid, roadrunner_overload_queue:waiters_ref(Pid), Timeout};
setup_overload({shed, #{retry_after := RetryAfter}}, _Max, _Counter) ->
    {shed, RetryAfter}.

%% A TLS listener that also reads the PROXY protocol cannot hand its
%% sockets out through `ssl:listen`: the header arrives in plaintext before
%% the ClientHello and has to come off the raw socket first. Such a
%% listener accepts plain TCP (`open_listen_socket/3`) and the connection
%% process upgrades each socket with these options once the header is in
%% (`roadrunner_conn_loop:awaiting_shoot/3`). Every other listener leaves
%% the key out, so the `ssl:listen` path is untouched.
-spec maybe_tls_upgrade(
    roadrunner_conn:proto_opts(), opts(), [http1 | http2 | http3, ...]
) -> roadrunner_conn:proto_opts().
maybe_tls_upgrade(#{proxy_protocol := true} = ProtoOpts, #{tls := UserTlsOpts}, Protocols) ->
    TcpProtocols = [P || P <- Protocols, P =/= http3],
    ProtoOpts#{tls_upgrade => roadrunner_transport:build_tls_opts(TcpProtocols, UserTlsOpts)};
maybe_tls_upgrade(ProtoOpts, _Opts, _Protocols) ->
    ProtoOpts.

%% Validate the opt-in `proxy_protocol` listener opt. It is a TCP-stream
%% feature (an L4 balancer prepends the header before the first byte), so it
%% conflicts with an HTTP/3-only (UDP) listener; on a mixed `[http1, http3]`
%% listener the TCP side honors it and h3 ignores it. On a TLS listener the
%% header precedes the ClientHello, which is why such a listener accepts
%% plain TCP and upgrades per connection (`maybe_tls_upgrade/3`).
-spec validate_proxy_protocol(term(), [http1 | http2 | http3, ...]) -> boolean().
validate_proxy_protocol(false, _Protocols) ->
    false;
validate_proxy_protocol(true, [http3]) ->
    error({listener_opt_conflict, proxy_protocol, true, no_tcp_listener});
validate_proxy_protocol(true, _Protocols) ->
    true;
validate_proxy_protocol(Other, _Protocols) ->
    error({invalid_listener_opt, proxy_protocol, Other}).

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
    %% Per-listener drain registry: every conn inserts its own pid as it
    %% starts and deletes it on exit, which is how `drain/2` and
    %% `notify_drain/2` find the processes to notify. A `write_concurrency`
    %% set owned by this process (it dies with the listener), so a join is
    %% a lock-free insert rather than a call into a registry process: 512
    %% simultaneous connection starts queued 3-4 ms behind the single `pg`
    %% scope this replaces. The by-name entry points (`notify_drain/2`,
    %% `register_for_drain/2`) go through this process
    %% instead of a shared pointer: they are rare, and a call to a stopped
    %% listener fails as `noproc` rather than reaching a table that died
    %% with it.
    DrainTable = ets:new(roadrunner_drain, [set, public, {write_concurrency, true}]),
    %% `inflight_counter` is the live in-flight-request gauge (h2/h3 stream
    %% workers acquire before spawn, release on `DOWN`), same lock-free
    %% `write_concurrency` shape as `client_counter`. `throttled_counter`
    %% is the cumulative count of streams refused at the
    %% `max_concurrent_requests` ceiling, mirroring `rejected_counter`.
    InflightCounter = counters:new(1, [write_concurrency]),
    ThrottledCounter = atomics:new(1, [{signed, false}]),
    %% `rate_limited_counter` is the cumulative count of requests refused at the
    %% per-peer `rate_limit`, mirroring `throttled_counter`. Always created (so
    %% `info/1` surfaces it as 0 when the guard is off); the per-peer bucket
    %% store is created only when `rate_limit` is configured.
    RateLimitedCounter = atomics:new(1, [{signed, false}]),
    RateLimit = build_rate_limit(maps:get(rate_limit, Opts, undefined)),
    MaxConcurrentRequests =
        maps:get(max_concurrent_requests, Opts, ?DEFAULT_MAX_CONCURRENT_REQUESTS),
    %% `overload_mode` decides what happens to a request that arrives over
    %% the ceiling. Queue mode needs a process to park waiters in; it is
    %% started here so it is linked to the listener and dies with it.
    Overload = setup_overload(
        validate_overload_mode(
            maps:get(overload_mode, Opts, refuse),
            MaxConcurrentRequests,
            maps:get(request_timeout, Opts, ?DEFAULT_REQUEST_TIMEOUT)
        ),
        MaxConcurrentRequests,
        InflightCounter
    ),
    %% Public `ws` opts are a nested map; flatten to the `ws_*`
    %% proto_opts keys the hot path reads, mirroring the `{http2, #{}}`
    %% → `http2_*` flattening above.
    #{
        max_frame_size := WsFrame,
        max_message_size := WsMsg,
        recv_buffer := WsBuffer,
        hibernate_after := WsHibernateAfter,
        compress := WsCompress,
        idle_timeout := WsIdleTimeout,
        active := WsActive
    } =
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
            ws_buffer => WsBuffer,
            ws_hibernate_after => WsHibernateAfter,
            ws_compress => WsCompress,
            ws_idle_timeout => WsIdleTimeout,
            ws_active => WsActive,
            request_timeout => maps:get(request_timeout, Opts, ?DEFAULT_REQUEST_TIMEOUT),
            tls_handshake_timeout =>
                maps:get(tls_handshake_timeout, Opts, ?DEFAULT_TLS_HANDSHAKE_TIMEOUT),
            keep_alive_timeout =>
                maps:get(keep_alive_timeout, Opts, ?DEFAULT_KEEP_ALIVE_TIMEOUT),
            max_keep_alive_requests =>
                maps:get(max_keep_alive_requests, Opts, ?DEFAULT_MAX_KEEP_ALIVE),
            max_clients => maps:get(max_clients, Opts, ?DEFAULT_MAX_CLIENTS),
            max_concurrent_requests => MaxConcurrentRequests,
            overload => Overload,
            client_counter => ClientCounter,
            drain_table => DrainTable,
            requests_counter => RequestsCounter,
            rejected_counter => RejectedCounter,
            inflight_counter => InflightCounter,
            throttled_counter => ThrottledCounter,
            rate_limited_counter => RateLimitedCounter,
            rate_limit => RateLimit,
            min_bytes_per_second =>
                maps:get(min_bytes_per_second, Opts, ?DEFAULT_MIN_BYTES_PER_SECOND),
            body_buffering => maps:get(body_buffering, Opts, auto),
            listener_name => ListenerName,
            graceful_drain => maps:get(graceful_drain, Opts, true),
            handler_spawn_opts => HandlerSpawnOpts,
            handler_start_timeout => HandlerStartTimeout,
            proxy_protocol => validate_proxy_protocol(
                maps:get(proxy_protocol, Opts, false), Protocols
            ),
            protocols => Protocols
        }),
        ProtoFlats
    ),
    WithTlsUpgrade = maybe_tls_upgrade(Base, Opts, Protocols),
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
                WithTlsUpgrade#{hibernate_after => Ms};
            #{} ->
                WithTlsUpgrade
        end,
    %% Optional `rate_check_interval` — the rate-check timer
    %% interval inside `reading_request`. Default 1000ms; ops can
    %% override.
    WithRateCheck =
        case Opts of
            #{rate_check_interval := IntervalMs} when is_integer(IntervalMs), IntervalMs > 0 ->
                WithHibernate#{rate_check_interval => IntervalMs};
            #{} ->
                WithHibernate
        end,
    %% Optional `real_ip`, compiled (and validated) here so a bad config fails
    %% the listener start; absent when off, the default, so a listener
    %% without it never loads `roadrunner_real_ip`.
    case Opts of
        #{real_ip := RealIpOpts} when RealIpOpts =/= undefined ->
            WithRateCheck#{real_ip => roadrunner_real_ip:compile(RealIpOpts)};
        #{} ->
            WithRateCheck
    end.

%% Resolve the public `handler_spawn` opt into the proto_opts shape the spawn
%% sites read: `#{opts := [start_spawn_option()], start_timeout := timeout()}`.
%% `link`/`monitor` are rejected — roadrunner owns process linkage (the conn is
%% intentionally unlinked, stream workers are monitored), so honoring them would
%% break that crash-isolation contract.
resolve_handler_spawn(Opts) ->
    case maps:get(handler_spawn, Opts, #{}) of
        HandlerSpawn when is_map(HandlerSpawn) ->
            UserOpts = maps:get(opts, HandlerSpawn, []),
            Timeout = maps:get(start_timeout, HandlerSpawn, ?DEFAULT_HANDLER_START_TIMEOUT),
            ok = validate_handler_spawn_opts(UserOpts, HandlerSpawn),
            ok = validate_handler_start_timeout(Timeout, HandlerSpawn),
            #{
                opts => merge_spawn_opts(?DEFAULT_HANDLER_SPAWN_OPTS, UserOpts),
                start_timeout => Timeout
            };
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

%% A caller's option wins per key and the rest of the defaults stay.
%% Replacing the list wholesale would mean setting any one option
%% silently drops the others — and dropping `fullsweep_after` alone
%% roughly doubles a listener's memory, with nothing in the config to
%% suggest why. To get the emulator's generational behaviour, name
%% `fullsweep_after` explicitly rather than passing an empty list.
merge_spawn_opts(Defaults, UserOpts) ->
    lists:foldr(
        fun(Default, Acc) ->
            Key = spawn_opt_key(Default),
            case lists:any(fun(Opt) -> spawn_opt_key(Opt) =:= Key end, UserOpts) of
                true -> Acc;
                false -> [Default | Acc]
            end
        end,
        UserOpts,
        Defaults
    ).

%% Everything reaching the merge is a `{Key, Value}` pair: `link` is the
%% only bare-atom spawn option and it is reserved below, rejected before
%% this runs.
spawn_opt_key(Opt) -> element(1, Opt).

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
%% to `persistent_term` by `publish_routes/3` — the dispatch tag
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
        max_header_count => 100,
        linger_timeout => 1000
    }.

-spec validate_http1_opts(map(), term()) -> http1_opts().
validate_http1_opts(Opts, Raw) ->
    Defaults = http1_defaults(),
    maps:fold(
        fun(K, V, Acc) ->
            case is_map_key(K, Defaults) of
                false -> error({invalid_listener_opt, protocols, Raw});
                true when K =:= linger_timeout, V =:= 0 -> Acc#{K => V};
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
            max_header_count := HdrCount,
            linger_timeout := Linger
        }} ->
            #{
                http1_max_request_line => ReqLine,
                http1_max_header_line => HdrLine,
                http1_max_header_block => HdrBlock,
                http1_max_header_count => HdrCount,
                http1_linger_timeout => Linger
            }
    end.

-spec http2_defaults() -> http2_opts().
http2_defaults() ->
    #{
        conn_window => 16#7FFFFFFF,
        stream_window => 16777216,
        max_concurrent_streams => 100,
        max_header_block => 16384,
        %% Placeholder: resolved to `2 * max_header_block` when not set
        %% explicitly (see `resolve_max_header_list_size/2`).
        max_header_list_size => 32768,
        active => 16
    }.

-spec validate_http2_opts(map(), term()) -> http2_opts().
validate_http2_opts(Opts, Raw) ->
    Defaults = http2_defaults(),
    Merged = maps:fold(
        fun(K, V, Acc) ->
            %% `window_refill_threshold` has no default entry: unset,
            %% each window refills at half its own peak.
            case K =:= window_refill_threshold orelse is_map_key(K, Defaults) of
                false -> error({invalid_listener_opt, protocols, Raw});
                true when K =:= active -> Acc#{K => validate_http2_active(V, Raw)};
                true when is_integer(V), V >= 1, V =< 16#7FFFFFFF -> Acc#{K => V};
                true -> error({invalid_listener_opt, protocols, Raw})
            end
        end,
        Defaults,
        Opts
    ),
    resolve_max_header_list_size(Merged, Opts).

%% `true` is rejected: an always-active socket has no bound on unread
%% data, so a fast peer could fill the mailbox. `32767` is the largest
%% count `inet:setopts/2` and `ssl:setopts/2` accept.
-spec validate_http2_active(term(), term()) -> once | 1..32767.
validate_http2_active(once, _Raw) ->
    once;
validate_http2_active(N, _Raw) when is_integer(N), N >= 1, N =< 32767 ->
    N;
validate_http2_active(_, Raw) ->
    error({invalid_listener_opt, protocols, Raw}).

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
        {http2,
            #{
                conn_window := Conn,
                stream_window := Stream,
                max_concurrent_streams := MaxStreams,
                max_header_block := MaxHeaderBlock,
                max_header_list_size := MaxHeaderListSize,
                active := Active
            } = Http2} ->
            Flat = #{
                http2_conn_window => Conn,
                http2_stream_window => Stream,
                http2_max_concurrent_streams => MaxStreams,
                http2_max_header_block => MaxHeaderBlock,
                http2_max_header_list_size => MaxHeaderListSize,
                http2_active => Active
            },
            case Http2 of
                #{window_refill_threshold := Threshold} ->
                    Flat#{http2_window_refill_threshold => Threshold};
                #{} ->
                    Flat
            end
    end.

-spec http3_defaults() -> http3_opts().
http3_defaults() ->
    #{
        listeners => ?DEFAULT_H3_LISTENERS,
        max_header_block => 16384,
        max_streams_bidi => ?H3_MAX_STREAMS_BIDI,
        %% Placeholder: resolved to `2 * max_header_block` when not set
        %% explicitly (see `resolve_max_field_section_size/2`).
        max_field_section_size => 32768,
        qpack_max_table_capacity => 4096,
        qpack_blocked_streams => 16
    }.

-spec validate_http3_opts(map(), term()) -> http3_opts().
validate_http3_opts(Opts, Raw) ->
    Defaults = http3_defaults(),
    Merged = maps:fold(
        fun
            (secret, V, Acc) when is_binary(V), byte_size(V) >= ?MIN_H3_SECRET ->
                Acc#{secret => V};
            (K, V, Acc) ->
                validate_http3_int_opt(K, V, Acc, Defaults, Raw)
        end,
        Defaults,
        Opts
    ),
    resolve_max_field_section_size(Merged, Opts).

%% One integer-valued http3 opt (anything else, a short or non-binary
%% `secret` included, is invalid).
-spec validate_http3_int_opt(term(), term(), http3_opts(), http3_opts(), term()) -> http3_opts().
validate_http3_int_opt(K, V, Acc, Defaults, Raw) ->
    %% `listeners` caps at the reuseport-pool limit; `max_header_block`
    %% (a byte size), `max_streams_bidi` (a stream count),
    %% `max_field_section_size` and `qpack_max_table_capacity` (byte sizes)
    %% and `qpack_blocked_streams` (a stream count) go up to the 31-bit
    %% ceiling. Only the QPACK opts may be 0: no dynamic table, or no
    %% stream waiting on it.
    {Min, Max} =
        case K of
            listeners -> {1, ?MAX_H3_LISTENERS};
            max_header_block -> {1, 16#7FFFFFFF};
            max_streams_bidi -> {1, 16#7FFFFFFF};
            max_field_section_size -> {1, 16#7FFFFFFF};
            qpack_max_table_capacity -> {0, 16#7FFFFFFF};
            qpack_blocked_streams -> {0, 16#7FFFFFFF};
            _ -> {1, 0}
        end,
    case is_map_key(K, Defaults) of
        false -> error({invalid_listener_opt, protocols, Raw});
        true when is_integer(V), V >= Min, V =< Max -> Acc#{K => V};
        true -> error({invalid_listener_opt, protocols, Raw})
    end.

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
            max_field_section_size := MaxFieldSection,
            qpack_max_table_capacity := QpackMaxTableCapacity,
            qpack_blocked_streams := QpackBlockedStreams
        }} ->
            #{
                http3_listeners => Listeners,
                http3_max_header_block => MaxHeaderBlock,
                http3_max_streams_bidi => MaxStreamsBidi,
                http3_max_field_section_size => MaxFieldSection,
                http3_qpack_max_table_capacity => QpackMaxTableCapacity,
                http3_qpack_blocked_streams => QpackBlockedStreams
            }
    end.

-spec ws_defaults() ->
    #{
        max_frame_size := non_neg_integer(),
        max_message_size := non_neg_integer(),
        recv_buffer := undefined,
        hibernate_after := infinity,
        compress := true,
        idle_timeout := infinity,
        active := undefined
    }.
ws_defaults() ->
    #{
        max_frame_size => ?DEFAULT_WS_MAX_FRAME_SIZE,
        max_message_size => ?DEFAULT_WS_MAX_MESSAGE_SIZE,
        %% `undefined` = no setopts on upgrade; the session keeps the
        %% listener socket's inherited `recv_buffer`.
        recv_buffer => undefined,
        %% `infinity` = the session's receive never times out into a
        %% hibernate — the `after infinity` clause is dead by the
        %% receive's own semantics, so the default costs nothing.
        hibernate_after => infinity,
        compress => true,
        %% `infinity` = no idle timer is armed.
        idle_timeout => infinity,
        %% `undefined` = per transport: `once` on plain TCP, `16` on TLS
        %% (`roadrunner_ws_session:read_mode/2`).
        active => undefined
    }.

%% Resolve the `ws` opts map against defaults, rejecting unknown keys
%% and out-of-range values (mirroring `validate_http2_opts/2`). A
%% reassembled message is built from frames, so a single unfragmented
%% frame is also a whole message: `max_message_size` below
%% `max_frame_size` is contradictory and rejected at startup.
-spec validate_ws_opts(term()) ->
    #{
        max_frame_size := non_neg_integer(),
        max_message_size := non_neg_integer(),
        recv_buffer := pos_integer() | undefined,
        hibernate_after := pos_integer() | infinity,
        compress := boolean(),
        idle_timeout := pos_integer() | infinity,
        active := once | 1..32767 | undefined
    }.
validate_ws_opts(Opts) when is_map(Opts) ->
    Defaults = ws_defaults(),
    Resolved = maps:fold(
        fun(K, V, Acc) ->
            case is_map_key(K, Defaults) andalso valid_ws_opt(K, V) of
                true -> Acc#{K => V};
                false -> error({invalid_listener_opt, ws, Opts})
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

%% Per-key range check for the `ws` sub-opts. The size caps allow 0
%% (reject every frame / message); `recv_buffer` and `hibernate_after`
%% are a buffer size and an idle interval, so zero is meaningless and
%% rejected for both. `active` takes what HTTP/2's does: `true` is
%% rejected (an always-active socket has no bound on unread data), and
%% `32767` is the largest count `inet:setopts/2` and `ssl:setopts/2`
%% accept.
-spec valid_ws_opt(
    max_frame_size
    | max_message_size
    | recv_buffer
    | hibernate_after
    | compress
    | idle_timeout
    | active,
    term()
) ->
    boolean().
valid_ws_opt(active, V) ->
    V =:= once orelse (is_integer(V) andalso V >= 1 andalso V =< 32767);
valid_ws_opt(compress, V) ->
    is_boolean(V);
valid_ws_opt(idle_timeout, V) ->
    is_integer(V) andalso V >= 1 andalso V =< 16#7FFFFFFF;
valid_ws_opt(recv_buffer, V) ->
    is_integer(V) andalso V >= 1 andalso V =< 16#7FFFFFFF;
valid_ws_opt(hibernate_after, V) ->
    is_integer(V) andalso V >= 1 andalso V =< 16#7FFFFFFF;
valid_ws_opt(_SizeCap, V) ->
    is_integer(V) andalso V >= 0 andalso V =< 16#7FFFFFFF.

%% Validate the `recv_buffer` opt (an inet buffer size — zero is
%% meaningless) rather than passing a bad value into `gen_tcp:listen/2`,
%% where it would surface as an opaque `{listen_failed, _}`. Mirrors the
%% strict `ws.recv_buffer` validation.
-spec validate_recv_buffer(map()) -> pos_integer().
validate_recv_buffer(Opts) ->
    case maps:get(recv_buffer, Opts, ?DEFAULT_RECV_BUFFER) of
        N when is_integer(N), N >= 1, N =< 16#7FFFFFFF -> N;
        Bad -> error({invalid_listener_opt, recv_buffer, Bad})
    end.

%% Validate the `rate_limit` opt and, when set, create its per-listener ETS
%% bucket store. `undefined` (the default) skips the guard entirely.
-spec build_rate_limit(term()) -> undefined | roadrunner_conn:rate_limit().
build_rate_limit(RawOpt) ->
    case validate_rate_limit(RawOpt) of
        undefined ->
            undefined;
        Config ->
            %% Anonymous public table, one per listener, owned by this
            %% gen_server so it dies with the listener. `write_concurrency, auto`
            %% adapts the lock count to load (matching the QUIC CID registry);
            %% no `read_concurrency` — each request reads then writes the same
            %% key (interleaved RMW), the one pattern it would slow down.
            Config#{
                table => ets:new(roadrunner_rate_limit, [
                    set, public, {write_concurrency, auto}
                ])
            }
    end.

-spec validate_rate_limit(term()) ->
    undefined
    | #{
        rate := pos_integer(),
        burst => pos_integer(),
        period => pos_integer(),
        sweep_interval := pos_integer()
    }.
validate_rate_limit(undefined) ->
    undefined;
validate_rate_limit(Opts) ->
    case roadrunner_rate_limit:valid(Opts, [rate, burst, period, sweep_interval]) of
        true -> maps:merge(#{sweep_interval => 10000}, Opts);
        false -> error({invalid_listener_opt, rate_limit, Opts})
    end.

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
%% alongside the pipeline so `roadrunner_router:match/3`-shaped
%% callers (and other introspection paths) can read it without
%% running the pipeline.
-spec bake_dispatch(
    module(),
    opts(),
    roadrunner_middleware:middleware_list(),
    no_state | {state, term()}
) -> roadrunner_conn:dispatch().
bake_dispatch(Handler, Opts, HandlerMws, StateArg0) ->
    %% The handler's `init_route/1` runs here, as it does for a routed one.
    StateArg = roadrunner_router:init_handler_state(undefined, Handler, StateArg0),
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
    {Reply, State1} = do_reload_routes(State, Routes),
    {reply, Reply, State1};
handle_call({notify_drain, Deadline}, _From, #state{proto_opts = #{drain_table := Table}} = State) ->
    {reply, notify_conns(Table, Deadline), State};
handle_call(
    {register_for_drain, Pid}, _From, #state{proto_opts = #{drain_table := Table}} = State
) ->
    true = ets:insert(Table, {Pid}),
    {reply, ok, State};
handle_call(info, _From, #state{proto_opts = ProtoOpts} = State) ->
    #{
        client_counter := ClientCounter,
        requests_counter := RequestsCounter,
        rejected_counter := RejectedCounter,
        throttled_counter := ThrottledCounter,
        rate_limited_counter := RateLimitedCounter,
        max_clients := MaxClients,
        max_concurrent_requests := MaxConcurrentRequests
    } = ProtoOpts,
    Reply = #{
        active_clients => counters:get(ClientCounter, 1),
        max_clients => MaxClients,
        requests_served => atomics:get(RequestsCounter, 1),
        rejected => atomics:get(RejectedCounter, 1),
        max_concurrent_requests => MaxConcurrentRequests,
        throttled => atomics:get(ThrottledCounter, 1),
        rate_limited => atomics:get(RateLimitedCounter, 1)
    },
    {reply, Reply, State}.

-spec do_reload_routes(#state{}, roadrunner_router:routes()) ->
    {ok | {error, no_routes} | {error, roadrunner_router:validation_error()}, #state{}}.
do_reload_routes(
    #state{
        proto_opts = #{dispatch := {router, Name}, middlewares := ListenerMws} = ProtoOpts,
        route_buckets = RouteBuckets
    } = State,
    Routes
) ->
    %% Check the replacement before touching anything. `compile/2` raises on a
    %% table that cannot work, and raising from here would take down a listener
    %% (and the caller) that has a perfectly good table already published, so
    %% the verdict comes back as a value and a bad table is simply refused.
    case roadrunner_router:validate(Routes) of
        ok ->
            reload_compiled(State, Routes, Name, ProtoOpts, RouteBuckets, ListenerMws);
        {error, _Reason} = Error ->
            {Error, State}
    end;
do_reload_routes(#state{proto_opts = #{dispatch := {handler, _, _, _}}} = State, _Routes) ->
    {{error, no_routes}, State}.

%% Compile a validated replacement table and publish it. Once `validate/1`
%% has passed, compiling can only fail in a hook that runs for the new table,
%% a handler's `init_route/1` or a middleware's `init/1` (a bad static option,
%% say). That failure is refused like a bad table, as `{error, {init_failed,
%% Reason}}`, so the listener keeps serving the table it has.
-spec reload_compiled(
    #state{},
    roadrunner_router:routes(),
    atom(),
    roadrunner_conn:proto_opts(),
    ets:table() | undefined,
    roadrunner_middleware:middleware_list()
) -> {ok | {error, {init_failed, term()}}, #state{}}.
reload_compiled(State, Routes, Name, ProtoOpts, RouteBuckets, ListenerMws) ->
    try roadrunner_router:compile(Routes, ListenerMws) of
        Compiled ->
            %% The first table with a route `rate_limit` gets the bucket
            %% store, published before the routes that use it.
            RouteBuckets1 =
                case RouteBuckets =:= undefined andalso route_rate_limited(Routes) of
                    true -> new_route_buckets(Name, ProtoOpts);
                    false -> RouteBuckets
                end,
            persistent_term:put({roadrunner_routes, Name}, Compiled),
            {ok, State#state{route_buckets = RouteBuckets1}}
    catch
        _Class:Reason ->
            {{error, {init_failed, Reason}}, State}
    end.

-spec do_drain(#state{}, non_neg_integer()) ->
    {{ok, drained} | {timeout, non_neg_integer()}, #state{}}.
do_drain(
    #state{
        listen_socket = LSocket,
        quic_listener = QuicListener,
        quic_accept_gate = QuicAcceptGate,
        proto_opts = ProtoOpts
    } = State,
    Timeout
) ->
    %% Stop taking new connections on both transports first. Close the TCP
    %% listen socket so accept fails and acceptors exit, and close the QUIC
    %% accept gate so a new client's Initial is dropped. Existing TCP conns
    %% keep their own sockets, and existing h3 conns keep routing, so both
    %% drain below. A connection started after the broadcast would never
    %% hear it and would hold the drain to its deadline.
    ok = close_tcp(LSocket),
    ok = close_quic_accept_gate(QuicAcceptGate),
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    #{client_counter := Counter, drain_table := Table} = ProtoOpts,
    notify_conns(Table, Deadline),
    Reply = wait_for_drain(Counter, Deadline, Table),
    %% Stop the QUIC pool LAST: its listeners link the connections they
    %% spawned, so stopping it before the notify/wait above would kill
    %% in-flight h3 conns instead of letting them drain (each sends
    %% GOAWAY and closes once its requests finish).
    ok = stop_quic(QuicListener),
    %% `phase = draining` was never observable here (the gen_server is
    %% blocked in wait_for_drain and the local state isn't committed),
    %% so settle straight to the final stopped state in one update.
    {Reply, State#state{listen_socket = closed, quic_listener = undefined, phase = stopped}}.

%% Best-effort broadcast to in-flight conns. Loop / SSE / WebSocket
%% handlers can pattern-match on `{roadrunner_drain, Deadline}` in
%% `handle_info/3` (an HTTP/2 or HTTP/3 conn passes it on to its stream
%% workers); non-loop HTTP/1.1 conns ignore the message and fall through
%% to the mailbox check at the next keep-alive boundary.
-spec notify_conns(ets:table(), integer()) -> ok.
notify_conns(Table, Deadline) ->
    _ = [Pid ! {roadrunner_drain, Deadline} || {Pid} <- ets:tab2list(Table)],
    ok.

%% Poll the active-clients counter every 50ms (or whatever remains,
%% if smaller) until it hits zero or the deadline expires.
-spec wait_for_drain(counters:counters_ref(), integer(), ets:table()) ->
    {ok, drained} | {timeout, non_neg_integer()}.
wait_for_drain(Counter, Deadline, Table) ->
    case counters:get(Counter, 1) of
        0 ->
            {ok, drained};
        N ->
            Remaining = Deadline - erlang:monotonic_time(millisecond),
            case Remaining =< 0 of
                true ->
                    _ = [exit(Pid, shutdown) || {Pid} <- ets:tab2list(Table)],
                    {timeout, N};
                false ->
                    timer:sleep(min(50, Remaining)),
                    wait_for_drain(Counter, Deadline, Table)
            end
    end.

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
        proto_opts = #{client_counter := Counter, listener_name := Name, drain_table := Table},
        reconciliation = #{interval := Interval, prev_diff := PrevDiff}
    } = State
) ->
    %% We only need to know whether `live members >= counter` (no
    %% orphans) or `live members < counter` (orphans = counter - live);
    %% a bounded count short-circuits at the counter so the alive checks
    %% per tick are capped at `min(members, counter)`.
    Counter0 = counters:get(Counter, 1),
    LiveBounded = count_live_up_to(Table, Counter0),
    NewDiff = Counter0 - LiveBounded,
    %% Only release slots that have been orphaned for two consecutive
    %% ticks — filters out the spawn-time race where a fresh conn has
    %% incremented the counter but hasn't yet registered.
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
                live_conns_bounded => LiveBounded
            }),
            ok = roadrunner_event:slots_reconciled(Name, N, Counter0, LiveBounded)
    end,
    erlang:send_after(Interval, self(), reconcile_slots),
    {noreply, State#state{
        reconciliation = #{interval => Interval, prev_diff => NewDiff - Release}
    }};
handle_info(
    rate_limit_sweep,
    #state{
        proto_opts = #{rate_limit := #{table := Table, sweep_interval := Interval} = RateLimit}
    } = State
) ->
    %% Evict the per-peer buckets full again, then reschedule. Keeps the store
    %% bounded by the peers inside their refill window.
    NowMs = erlang:monotonic_time(millisecond),
    {Rate, Cap, _Cost} = roadrunner_rate_limit:bucket(RateLimit),
    _ = roadrunner_conn:rate_limit_evict_full(Table, NowMs, Rate, Cap),
    _ = erlang:send_after(Interval, self(), rate_limit_sweep),
    {noreply, State};
handle_info(route_rate_limit_sweep, #state{route_buckets = Table} = State) ->
    %% Drop the route buckets that are full again, then reschedule. Keeps the
    %% store bounded by the clients still inside their routes' windows.
    _ = roadrunner_route_rate_limit:evict_full(Table, erlang:monotonic_time(millisecond)),
    _ = erlang:send_after(?ROUTE_RATE_LIMIT_SWEEP_INTERVAL, self(), route_rate_limit_sweep),
    {noreply, State};
handle_info({'EXIT', _Pid, normal}, State) ->
    %% An acceptor ends normally once the listen socket is closed.
    {noreply, State};
handle_info({'EXIT', _Pid, Reason}, State) ->
    %% A linked acceptor, overload queue or QUIC pool died: the listener
    %% goes down with it, as it would without trapping exits, but through
    %% `terminate/2`, and its supervisor restarts it.
    {stop, Reason, State};
handle_info(_Msg, State) ->
    {noreply, State}.

%% Count registered conns that are still alive, short-circuiting at
%% `Cap` (the `client_counter`, i.e. `max_clients`) so the per-tick
%% alive checks are bounded by the counter rather than by the registry
%% size. A conn that was `kill`ed never ran its exit path, so its pid is
%% still registered: it is dropped here, the same reaping this tick does
%% for its slot.
-spec count_live_up_to(ets:table(), non_neg_integer()) -> non_neg_integer().
count_live_up_to(Table, Cap) ->
    count_live_up_to(ets:tab2list(Table), Table, Cap, 0).

-spec count_live_up_to([{pid()}], ets:table(), non_neg_integer(), non_neg_integer()) ->
    non_neg_integer().
count_live_up_to(_, _Table, Cap, N) when N >= Cap ->
    Cap;
count_live_up_to([], _Table, _Cap, N) ->
    N;
count_live_up_to([{Pid} | T], Table, Cap, N) ->
    case is_process_alive(Pid) of
        true ->
            count_live_up_to(T, Table, Cap, N + 1);
        false ->
            true = ets:delete(Table, Pid),
            count_live_up_to(T, Table, Cap, N)
    end.

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
    roadrunner_quic_listener_sup:stop(QuicPool).

-spec erase_routes(roadrunner_conn:proto_opts()) -> ok.
erase_routes(#{dispatch := {router, Name}}) ->
    _ = persistent_term:erase({roadrunner_routes, Name}),
    _ = persistent_term:erase({roadrunner_route_rate_limit, Name}),
    ok;
erase_routes(_) ->
    ok.
