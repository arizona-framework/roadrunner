-module(roadrunner_conn).
-moduledoc false.

%% Public connection-process API and pure helpers.
%%
%% `start/2` spawns the per-connection process — `roadrunner_conn_loop`,
%% a tail-recursive loop with phase tracking via `proc_lib:set_label/1`
%% for observer / recon visibility.
%%
%% The other public functions are pure-ish helpers; many are also called
%% directly from `roadrunner_req` (manual body buffering) and from
%% `roadrunner_conn_tests.erl`'s closure-driven unit tests.
%%
%% Per-connection behavior — keep-alive (capped by
%% `max_keep_alive_requests`, idle-bound by `keep_alive_timeout`),
%% `Expect: 100-continue`, HEAD body suppression, anti-Slowloris rate
%% check (`min_bytes_per_second`), the five handler return shapes
%% (`{Status, Headers, Body}`, `{stream, ...}`, `{loop, ...}`,
%% `{sendfile, ...}`, `{websocket, ...}`) — lives in `roadrunner_conn_loop`
%% and the response-shape-specific modules (`roadrunner_stream_response`,
%% `roadrunner_loop_response`, `roadrunner_ws_session`).
%%
%% The 4xx/5xx error responses (400 on parse failure, 408 on
%% first-request silence, 413 on oversized bodies, 500 on handler
%% crashes) are emitted via the `send_*/1` helpers exported here. Idle
%% keep-alive timeouts and slow-client rate violations close the
%% connection silently — no response to a peer that wasn't going to
%% read it anyway.

-export([
    start/2,
    parse_loop/2,
    read_body/5,
    peer/1,
    try_acquire_slot/1,
    release_slot/1,
    try_acquire_request_slot/2,
    acquire_request_slot/4,
    cancel_slot_wait/2,
    release_request_slot/3,
    release_request_slots/4,
    consume_body_reader/2,
    register_for_drain/1,
    unregister_for_drain/1
]).
%% Internal helpers shared with `roadrunner_conn_loop`. Marked `-doc false`
%% individually so they stay invisible to the public API surface but
%% are still reachable across the module boundary. They live here
%% (rather than inside the conn-loop module) because the closure-driven
%% unit tests in `roadrunner_conn_tests.erl` exercise the body-state
%% machinery directly through these functions.
-export([
    make_recv/3,
    armed/1,
    disarmed/0,
    drain_check_interval_ms/0,
    rate_ok/3,
    body_framing/1,
    generate_request_id/1,
    set_request_logger_metadata/1,
    send_continue/1,
    expects_continue/1,
    refine_conn_label/2,
    scheme/1,
    conn_info/1,
    make_body_reader/5,
    latest_reader/1,
    stream_body_reader/5,
    with_body_reader/5,
    continue_before_stream/1,
    skip_continue/1,
    send_body/4,
    send_body_error/3,
    drain_reader/1,
    close_opts/1,
    keep_alive_decision/2,
    send_request_timeout/1,
    send_bad_request/1,
    send_status/2,
    parse_error_status/1,
    send_payload_too_large/1,
    send_retry_later/3,
    rate_limit_check/6,
    resolve_rate_limit/2,
    resolve_real_ip/2,
    rate_limit/3,
    rate_limit_spend/7,
    throttled_telemetry/3,
    rate_limit_evict_full/4,
    linger/2,
    send_internal_error/1,
    send_not_found/1,
    send_method_not_allowed/2,
    resolve_handler/2,
    body_cap/2,
    route_body_cap/3,
    expect_answer/3,
    with_client_ip/3,
    allow_header_value/1,
    response_status/1,
    final_response/3,
    response_kind/1,
    head_response/2
]).

-export_type([
    proto_opts/0,
    close_opts/0,
    dispatch/0,
    rate_limit/0,
    rate_limit_state/0,
    overload/0,
    resolved/0
]).

%% The part of `proto_opts()` a connection's close path reads
%% (`release_slot/1`, `unregister_for_drain/1`): what a WebSocket session
%% keeps for its whole lifetime instead of the full listener options.
-type close_opts() :: #{
    client_counter := counters:counters_ref(),
    drain_table => ets:table(),
    _ => _
}.

%% A request's routing outcome (`resolve_handler/2`): the handler, its
%% bindings, pipeline and state, and the matched route's limits.
-type resolved() ::
    {ok, module(), roadrunner_router:bindings(), roadrunner_middleware:next(), term(),
        roadrunner_router:limits()}
    | {method_not_allowed, [binary()]}
    | not_found.

-on_load(init_patterns/0).

-define(CONN_COMMA_CP_KEY, {?MODULE, conn_comma_cp}).

-doc """
How a request over the listener-wide `max_concurrent_requests` ceiling
is handled. `refuse` is the default and today's behavior: reject it
immediately. The queue form parks it until a slot frees, so handler
memory stays bounded without shedding the request; it carries the
listener's queue process, the atomic that says whether anyone is parked
(read on the release path to avoid a message per request), and the wait
deadline in milliseconds. The shed form answers it `503` with the
`Retry-After` seconds it carries.
""".
-type overload() ::
    refuse | {queue, pid(), atomics:atomics_ref(), pos_integer()} | {shed, pos_integer()}.

-type dispatch() ::
    {handler, module(), roadrunner_middleware:next(), State :: term()}
    | {router, ListenerName :: atom()}.

-type proto_opts() :: #{
    dispatch := dispatch(),
    middlewares := roadrunner_middleware:middleware_list(),
    max_content_length := non_neg_integer(),
    %% WebSocket inbound size caps. `ws_max_frame_size` bounds a single
    %% frame's declared payload (enforced before buffering);
    %% `ws_max_message_size` bounds a reassembled message (the running
    %% sum of fragment payloads, and the decompressed size under
    %% permessage-deflate). Both always present —
    %% `roadrunner_listener:build_proto_opts/2` fills defaults.
    ws_max_frame_size := non_neg_integer(),
    ws_max_message_size := non_neg_integer(),
    %% inet `buffer` applied to the socket on WebSocket upgrade;
    %% `undefined` inherits the listener socket's `recv_buffer`
    %% (64 KB default).
    ws_buffer := pos_integer() | undefined,
    %% Idle ms after which a WebSocket session hibernates; `infinity`
    %% (the default) never hibernates on idle.
    ws_hibernate_after := pos_integer() | infinity,
    %% Whether a WebSocket upgrade accepts permessage-deflate.
    ws_compress := boolean(),
    %% Ms of client silence after which a WebSocket session closes;
    %% `infinity` (the default) never does.
    ws_idle_timeout := pos_integer() | infinity,
    %% How a WebSocket session reads its socket: `once`, or up to `N`
    %% reads per arm (the listener's `ws.active`); `undefined` (the
    %% default) is `once` on plain TCP and `16` on TLS.
    ws_active := once | 1..32767 | undefined,
    request_timeout := non_neg_integer(),
    %% Bound on the TLS handshake in the accept path; see the
    %% `tls_handshake_timeout` listener opt.
    tls_handshake_timeout := pos_integer(),
    keep_alive_timeout := non_neg_integer(),
    max_keep_alive_requests := pos_integer(),
    max_clients := pos_integer(),
    client_counter := counters:counters_ref(),
    %% Per-listener drain registry (`{Pid}` rows). Optional so hand-built
    %% proto_opts in tests can leave it out; the listener always sets it.
    drain_table => ets:table(),
    requests_counter := atomics:atomics_ref(),
    rejected_counter := atomics:atomics_ref(),
    %% Aggregate in-flight ceiling for the multiplexed protocols (h2/h3):
    %% a cap on concurrent live stream-worker processes across the whole
    %% listener, independent of `max_clients` and `max_concurrent_streams`.
    %% `infinity` (default) disables it. `inflight_counter` is the live
    %% gauge (acquired before a worker spawns, released on its `DOWN`);
    %% `throttled_counter` is the cumulative count of streams refused at
    %% the ceiling. h1 is bounded by `max_clients` and uses these only in
    %% shed mode, where the ceiling is one budget across every protocol.
    max_concurrent_requests := infinity | pos_integer(),
    %% What happens to a request over that ceiling. Optional so a
    %% hand-built proto_opts map (tests, embedded callers) defaults to
    %% today's refuse behavior.
    overload => overload(),
    inflight_counter := counters:counters_ref(),
    throttled_counter := atomics:atomics_ref(),
    %% Per-peer request-rate guard (off by default). `rate_limit` carries the
    %% resolved config + per-listener ETS bucket store when the `rate_limit`
    %% opt is set, else `undefined`. `rate_limited_counter` is the cumulative
    %% count of requests refused at the per-peer rate, mirroring
    %% `throttled_counter`, surfaced in `roadrunner_listener:info/1` (always
    %% present, stays 0 when the guard is off).
    rate_limit := undefined | rate_limit(),
    rate_limited_counter := atomics:atomics_ref(),
    min_bytes_per_second := non_neg_integer(),
    body_buffering := auto | manual,
    listener_name => atom(),
    %% When `false`, conns skip registering in the listener's drain
    %% registry (`drain_table`). The registry is the mechanism
    %% `roadrunner_listener:drain/2` uses to broadcast
    %% `{roadrunner_drain, Deadline}` to in-flight conns; loop /
    %% SSE / WebSocket handlers depend on it. Short-lived h1
    %% workloads can opt out to skip the insert and delete per conn.
    graceful_drain => boolean(),
    %% When `true`, `roadrunner_conn_loop:awaiting_shoot/3` reads and strips a
    %% PROXY-protocol header (an L4 balancer prepends it) before serving, and
    %% the request peer is the real client. TCP-only; the listener rejects it on
    %% an HTTP/3-only listener.
    proxy_protocol => boolean(),
    %% The compiled `real_ip` listener option (`roadrunner_real_ip:compile/1`).
    %% Absent when the option is off.
    real_ip => roadrunner_real_ip:config(),
    %% TLS options for a TLS listener that also reads the PROXY protocol: it
    %% accepts plain TCP (the header comes before any TLS bytes) and the conn
    %% upgrades each socket with these once the header is in. Absent on every
    %% other listener; a TLS listener without the PROXY protocol handshakes
    %% the socket `ssl:listen` accepted.
    tls_upgrade => [ssl:tls_server_option()],
    %% Enabled protocols as a flat atom list in user-supplied (ALPN
    %% preference) order. On plain TCP with `[http2]`,
    %% `roadrunner_conn_loop:awaiting_shoot/3` routes straight to the
    %% h2 conn loop. HTTP/2 sub-opts are flattened onto proto_opts
    %% top-level as `http2_conn_window`, `http2_stream_window`,
    %% `http2_window_refill_threshold` — see those keys below. The
    %% user-facing nested shape (`{http2, #{conn_window => N, ...}}`)
    %% is documented in `t:roadrunner_listener:opts/0`.
    protocols => [http1 | http2 | http3, ...],
    %% HTTP/2 receive-window tuning, populated by the listener only
    %% when `http2` is in the protocols list. Pattern-match these
    %% keys directly in code paths that already know http2 is
    %% enabled (e.g. `roadrunner_conn_loop_http2:enter/5`) — they're
    %% guaranteed present, defaults filled at normalization time.
    %% See `t:roadrunner_listener:opts/0` for the user-facing shape
    %% (`{http2, #{conn_window => N, stream_window => N,
    %% window_refill_threshold => N}}`) and RFC 9113 §6.5.2 / §6.9.2
    %% for the wire semantics.
    http2_conn_window => 1..16#7FFFFFFF,
    http2_stream_window => 1..16#7FFFFFFF,
    http2_window_refill_threshold => 1..16#7FFFFFFF,
    http2_max_concurrent_streams => 1..16#7FFFFFFF,
    http2_max_header_block => 1..16#7FFFFFFF,
    http2_active => once | 1..32767,
    %% HTTP/3 tuning, flattened from `{http3, #{...}}` when http3 is enabled.
    http3_listeners => 1..1024,
    http3_max_header_block => 1..16#7FFFFFFF,
    http3_qpack_max_table_capacity => 0..16#7FFFFFFF,
    http3_qpack_blocked_streams => 0..16#7FFFFFFF,
    %% HTTP/1 inbound size limits and close linger, flattened from
    %% `{http1, #{...}}`.
    http1_max_request_line => 1..16#7FFFFFFF,
    http1_max_header_line => 1..16#7FFFFFFF,
    http1_max_header_block => 1..16#7FFFFFFF,
    http1_max_header_count => 1..16#7FFFFFFF,
    http1_linger_timeout => 0..16#7FFFFFFF,
    %% Set only when `{http1, #{active => ...}}` is given; unset, the
    %% conn picks by transport.
    http1_active => once | 1..32767,
    %% Optional fields the listener injects only when the user
    %% supplies them — see `roadrunner_listener:build_proto_opts/2`.
    %% Declared here so dialyzer accepts pattern matches like
    %% `#{hibernate_after := Ms}` against `proto_opts()`.
    hibernate_after => pos_integer(),
    rate_check_interval => pos_integer(),
    %% Flattened spawn config for every handler-running process. The public
    %% `handler_spawn => #{opts, start_timeout}` listener opt is expanded into
    %% these top-level keys by `roadrunner_listener:build_proto_opts/2` so the
    %% spawn sites read them with a single `maps:get/2`, never a nested lookup.
    handler_spawn_opts => [proc_lib:start_spawn_option()],
    handler_start_timeout => timeout()
}.

%% Resolved per-peer rate-limit config, built by `roadrunner_listener` when the
%% `rate_limit` opt is set: `rate` requests per `period` seconds with a `burst`
%% bucket capacity (`roadrunner_rate_limit:bucket/1`), the ETS `table` holding
%% each peer's bucket, and the `sweep_interval` (ms) between passes that drop
%% the buckets full again. The cumulative refusal count lives in the top-level
%% `rate_limited_counter`.
-type rate_limit() :: #{
    rate := pos_integer(),
    burst => pos_integer(),
    period => pos_integer(),
    sweep_interval := pos_integer(),
    table := ets:table()
}.

%% The per-connection rate-limit guard state cached on each conn loop's record:
%% the `{Rate, Cap, Cost, Table, Counter, IP}` resolved from `proto_opts` + the
%% peer once at setup (see `resolve_rate_limit/2`) — with `Cap`/`Cost` already
%% derived so the per-request check does no arithmetic — or `undefined` when the
%% guard is off or the peer IP is unknown. Checked by `rate_limit_check/6`.
-type rate_limit_state() ::
    {
        pos_integer(),
        pos_integer(),
        pos_integer(),
        ets:table(),
        atomics:atomics_ref(),
        inet:ip_address()
    }
    | undefined.

-doc """
Spawn an unlinked connection process for the accepted `Socket` and the
shared `ProtoOpts` (handler module, body limits, ...).

The caller (typically `roadrunner_acceptor`) must transfer socket
ownership via `roadrunner_transport:controlling_process/2` and then
send the process the atom `shoot` to release it.
""".
-spec start(roadrunner_transport:socket(), proto_opts()) -> {ok, pid()}.
start(Socket, ProtoOpts) when is_map(ProtoOpts) ->
    {ok, _Pid} = roadrunner_conn_loop:start(Socket, ProtoOpts).

-doc """
Register the calling connection process in its listener's drain
registry so `roadrunner_listener:drain/2` and `notify_drain/2` can send
it `{roadrunner_drain, Deadline}`. A lock-free ETS insert, so
connection starts never queue behind a registry process. Skipped when
the listener opted out with `graceful_drain => false`, or when the
proto_opts carry no registry (requests built by hand in tests).

Called by the connection loops as they start, before they accept any
work, and paired with `unregister_for_drain/1` on every exit path. A
process outside the conn lifecycle registers through
`roadrunner_listener:register_for_drain/2` instead.
""".
-spec register_for_drain(proto_opts()) -> ok.
register_for_drain(#{graceful_drain := false}) ->
    ok;
register_for_drain(#{drain_table := Table}) ->
    true = ets:insert(Table, {self()}),
    ok;
register_for_drain(#{}) ->
    ok.

-doc """
Remove the calling process from its listener's drain registry, paired
with `register_for_drain/1`. The listener owns the table, and `stop/1`
does not wait for in-flight conns, so a conn that outlives its listener
finds no registry to leave and that is fine.
""".
-spec unregister_for_drain(close_opts()) -> ok.
unregister_for_drain(#{drain_table := Table}) ->
    try ets:delete(Table, self()) of
        true -> ok
    catch
        error:badarg -> ok
    end;
unregister_for_drain(#{}) ->
    ok.

-doc """
Try to bump the live-connection counter under `max_clients`. Returns
`true` on success (caller may proceed to spawn a conn), `false` if
the cap is already met (caller must close the accepted socket).

The check is racy by a small amount. The counter uses `counters` with
`write_concurrency`, so `counters:get/2` returns an eventually-consistent
sum across per-scheduler sub-counters: a fresh increment on one
scheduler may not be visible to a concurrent read on another for a
short window. Combined with the increment / rollback pattern, this
allows the count to briefly observe a value slightly above the cap
before rollbacks reconcile. The overshoot is bounded by the number of
acceptors in flight at the moment of the storm: bounded and harmless.

## Slot leak under abnormal exits

The slot is released by `roadrunner_conn_loop:exit_clean/2` on every
normal exit path (handler crash, parse error, drain stop, peer
close). Under `exit(Pid, kill)` — sent by a supervisor or by an
operator using `recon:proc_count/2`-style cleanup — the runtime
skips the cleanup funnel, so the slot is **leaked** for the lifetime
of the listener process. This is bounded:
`max_clients` accepted connections each leak at most one slot
under killing, and the listener restart resets the counter. If
leaks become a real concern under chaos-test conditions, the
`slot_reconciliation` reaper (on by default) compares the registered
conns still alive against the live counter and reconciles the difference.
""".
-spec try_acquire_slot(proto_opts()) -> boolean().
try_acquire_slot(#{client_counter := Ref, max_clients := Max}) ->
    ok = counters:add(Ref, 1, 1),
    case counters:get(Ref, 1) of
        N when N =< Max ->
            true;
        _ ->
            ok = counters:sub(Ref, 1, 1),
            false
    end.

-doc "Decrement the live-connection counter, paired with `try_acquire_slot/1`.".
-spec release_slot(close_opts()) -> ok.
release_slot(#{client_counter := Ref}) ->
    ok = counters:sub(Ref, 1, 1),
    ok.

%% The close-path slice of `ProtoOpts` (`close_opts()`).
-doc false.
-spec close_opts(proto_opts()) -> close_opts().
close_opts(ProtoOpts) ->
    maps:with([client_counter, drain_table], ProtoOpts).

-doc """
Try to bump the live in-flight-request counter under
`max_concurrent_requests`. Returns `true` if a worker may be spawned,
`false` if the listener is already at the ceiling (caller must refuse the
stream). `infinity` short-circuits to `true` with no counter touch, so an
unconfigured listener pays nothing on the hot path.

Same eventually-consistent overshoot contract as `try_acquire_slot/1`: the
`counters` ref uses `write_concurrency`, so a brief read slightly above the
cap is possible before rollbacks reconcile, bounded by in-flight admissions.
Paired with `release_request_slot/3`, which must run exactly once per
successfully-acquired worker (tie it to the worker monitor-ref removal so a
worker is released by its `DOWN` or by the conn's clean exit, never both).

The `Max` and `Counter` are cached on the connection loop record at setup so
the per-stream path passes them directly instead of re-reading `proto_opts`.
""".
-spec try_acquire_request_slot(infinity | pos_integer(), counters:counters_ref() | undefined) ->
    boolean().
try_acquire_request_slot(infinity, _Counter) ->
    true;
try_acquire_request_slot(Max, Counter) ->
    ok = counters:add(Counter, 1, 1),
    case counters:get(Counter, 1) of
        N when N =< Max ->
            true;
        _ ->
            ok = counters:sub(Counter, 1, 1),
            false
    end.

%% Resolve the per-connection rate-limit tuple `{Rate, Burst, Table, Counter,
%% IP}` from `proto_opts` + the (constant-per-conn) peer once at setup, or
%% `undefined` when the guard is off, so the per-request check is a single
%% branch on a cached value. The peer IP is baked in here, so the catch-all
%% also covers a missing peer (a 2-tuple `{IP, _}` is required) as well as
%% `rate_limit => undefined` and the hand-built proto_opts in unit tests.
-doc false.
-spec resolve_rate_limit(
    proto_opts(), {inet:ip_address(), inet:port_number()} | undefined
) -> rate_limit_state().
resolve_rate_limit(
    #{rate_limit := #{table := Table} = RateLimit, rate_limited_counter := Counter},
    {IP, _Port}
) ->
    %% Bake the derived `Cost` (units/request) and `Cap` (bucket capacity),
    %% and the peer's bucket key, here, once per connection, so the
    %% per-request `rate_limit_check/6` does no arithmetic.
    {Rate, Cap, Cost} = roadrunner_rate_limit:bucket(RateLimit),
    {Rate, Cap, Cost, Table, Counter, roadrunner_rate_limit:client_key(IP)};
resolve_rate_limit(_ProtoOpts, _Peer) ->
    undefined.

%% The connection's `real_ip` trust (`roadrunner_real_ip:peer_trust/2`),
%% resolved once at setup. A listener without `real_ip`, the default, skips
%% the call so its connections never load `roadrunner_real_ip`: startup time
%% is dominated by code loading.
-doc false.
-spec resolve_real_ip(
    proto_opts(), {inet:ip_address(), inet:port_number()} | undefined
) -> undefined | roadrunner_real_ip:config().
resolve_real_ip(#{real_ip := RealIp}, Peer) ->
    roadrunner_real_ip:peer_trust(RealIp, Peer);
resolve_real_ip(_ProtoOpts, _Peer) ->
    undefined.

%% The per-peer rate-limit gate every protocol runs before it dispatches a
%% request: `allow`, or `{deny, RetryAfterSecs}` once the throttle is counted
%% and its telemetry emitted, leaving the protocol to send its own 429. The
%% guard being off (`undefined`, which also covers a connection with no peer
%% IP) always allows. The bucket is the request's resolved client IP behind a
%% trusted proxy (`real_ip`), else the peer's, baked into the state.
-doc false.
-spec rate_limit(rate_limit_state(), roadrunner_req:request(), atom()) ->
    allow | {deny, pos_integer()}.
rate_limit(undefined, _Req, _ListenerName) ->
    allow;
rate_limit({Rate, Cap, Cost, Table, Counter, PeerKey}, Req, ListenerName) ->
    rate_limit_spend(Table, rate_limit_key(Req, PeerKey), Rate, Cap, Cost, Counter, ListenerName).

%% The bucket key of one request: its resolved client IP's key
%% (`roadrunner_rate_limit:client_key/1`), else the peer's.
-spec rate_limit_key(roadrunner_req:request(), inet:ip_address()) -> inet:ip_address().
rate_limit_key(#{client_ip := IP}, _PeerKey) -> roadrunner_rate_limit:client_key(IP);
rate_limit_key(_Req, PeerKey) -> PeerKey.

%% Spend one request from the bucket under `Key` in `Table` now: `allow`, or
%% `{deny, RetryAfterSecs}` once the throttle is counted in `Counter` and its
%% telemetry emitted. The listener's per-peer limit (`rate_limit/3`) and a
%% route's own (`roadrunner_route_rate_limit`) both spend through it, each
%% from its own store.
-doc false.
-spec rate_limit_spend(
    ets:table(),
    inet:ip_address() | {term(), inet:ip_address()},
    pos_integer(),
    pos_integer(),
    pos_integer(),
    atomics:atomics_ref(),
    atom()
) -> allow | {deny, pos_integer()}.
rate_limit_spend(Table, Key, Rate, Cap, Cost, Counter, ListenerName) ->
    NowMs = erlang:monotonic_time(millisecond),
    maybe
        {deny, _} = Deny ?= rate_limit_check(Table, Key, Rate, Cap, Cost, NowMs),
        ok = throttled_telemetry(ListenerName, Counter, rate_limit),
        Deny
    end.

-doc """
Per-peer token-bucket check, the per-source sibling of
`try_acquire_request_slot/2`. Reads the bucket under `Key` (the peer's IP in
the listener's store, a route and a client IP in the route store of
`roadrunner_route_rate_limit`) from the ETS `Table` (a never-seen key starts
full), refills it for the elapsed time, and tries to spend one request. `allow` on success, `{deny, RetryAfterSecs}`
when the bucket is empty. The read-refill-write is last-write-wins: concurrent
connections from one IP can overshoot the bucket by a bounded amount, the same
contract `try_acquire_request_slot/2` documents.

`NowMs` is `erlang:monotonic_time(millisecond)` (passed in so the bucket math is
deterministically testable).
""".
-spec rate_limit_check(
    ets:table(),
    inet:ip_address() | {term(), inet:ip_address()},
    pos_integer(),
    pos_integer(),
    pos_integer(),
    integer()
) ->
    allow | {deny, pos_integer()}.
rate_limit_check(Table, Key, Rate, Cap, Cost, NowMs) ->
    %% `Cap` (bucket capacity) and `Cost` (units per request) are resolved once
    %% per connection (see `resolve_rate_limit/2`), not per request. A
    %% never-seen peer starts at a full bucket (`Cap`) and needs no refill; an
    %% existing one is refilled for the elapsed time in place (no intermediate
    %% tuple).
    Refilled =
        case ets:lookup(Table, Key) of
            [{Key, Units, LastMs}] ->
                roadrunner_rate_limit:refill(Units, LastMs, NowMs, Rate, Cap);
            [] ->
                Cap
        end,
    case roadrunner_rate_limit:spend(Refilled, Cost) of
        denied ->
            %% Nothing spent, so the bucket stays as it is: a refill from its
            %% stored level and time reaches the same level later, and a key
            %% is only denied once it has a row (a new one starts full).
            {deny, roadrunner_rate_limit:retry_after_secs(Refilled, Rate, Cost)};
        Remaining ->
            true = ets:insert(Table, {Key, Remaining, NowMs}),
            allow
    end.

-doc """
Record a throttled request, refused for `Reason` (the per-peer rate limit
or the listener's concurrent-request ceiling): bump the cumulative
counter and emit `request_throttled`.
""".
-spec throttled_telemetry(atom(), atomics:atomics_ref(), rate_limit | max_concurrent_requests) ->
    ok.
throttled_telemetry(ListenerName, Counter, Reason) ->
    ok = atomics:add(Counter, 1, 1),
    roadrunner_event:request_throttled(ListenerName, Reason).

-doc """
Evict every per-peer bucket that has refilled to its capacity `Cap` by `NowMs`
(refilling `Rate` units a millisecond), in one `select_delete` pass, returning
the number evicted. A full bucket is the same as none (a never-seen peer starts
full), so dropping it hands no peer anything back, while a bucket still
refilling stays however long its peer is idle: a peer cannot reset its limit by
waiting. A single pass (rather than a per-tick row budget) is what actually
bounds the store to the peers inside their refill window: a budget would cap
eviction below the rate new buckets are created under a high-cardinality scan,
letting the table grow without limit. The pass runs on the listener gen_server
(control plane, off the request path), so a full traversal every sweep tick is
cheap.
""".
-spec rate_limit_evict_full(ets:table(), integer(), pos_integer(), pos_integer()) ->
    non_neg_integer().
rate_limit_evict_full(Table, NowMs, Rate, Cap) ->
    %% Row is `{IP, Units, LastMs}`.
    Spec = [{{'_', '$1', '$2'}, [roadrunner_rate_limit:full_guard(NowMs, Rate, Cap)], [true]}],
    ets:select_delete(Table, Spec).

-doc """
Take an in-flight slot, or park the request when the listener is in
queue mode. The fast path is `try_acquire_request_slot/2` and nothing
else, so a listener that never reaches its ceiling pays a single
`counters` operation.

Returns `true` when the slot is held and the caller may spawn its
worker, `false` when the caller should refuse the request exactly as it
does today, `{shed, RetryAfterSecs}` when the listener sheds instead and
the caller answers `503` with that `Retry-After`, and `queued` when the
request is parked. A parked caller
MUST NOT block: it returns to its loop and later receives
`{roadrunner_slot, Token, granted | timeout | full}`. `granted` means the
slot is already held on its behalf, so a caller that has since dropped
the request has to release it rather than ignore it.

`Token` only has to be unique within the calling process; the stream id
is the natural choice.
""".
-spec acquire_request_slot(
    infinity | pos_integer(), counters:counters_ref() | undefined, overload(), term()
) -> true | false | queued | {shed, pos_integer()}.
acquire_request_slot(Max, Counter, Overload, Token) ->
    case try_acquire_request_slot(Max, Counter) of
        true -> true;
        false -> park(Overload, Token)
    end.

-spec park(overload(), term()) -> false | queued | {shed, pos_integer()}.
park(refuse, _Token) ->
    false;
park({queue, Pid, _Waiters, Timeout}, Token) ->
    ok = roadrunner_overload_queue:enqueue(Pid, Token, Timeout),
    queued;
park({shed, _RetryAfter} = Shed, _Token) ->
    Shed.

-doc """
Withdraw a parked request, because its stream was reset or its
connection is going away. Racing an in-flight grant is expected: the
caller may still receive `granted` afterwards and must release that slot.
""".
-spec cancel_slot_wait(overload(), term()) -> ok.
cancel_slot_wait({queue, Pid, _Waiters, _Timeout}, Token) ->
    roadrunner_overload_queue:cancel(Pid, Token);
cancel_slot_wait(_NeverParks, _Token) ->
    ok.

-doc """
Decrement the in-flight-request counter, paired with
`acquire_request_slot/4`, and wake a parked request if one is waiting.

The wake is guarded by an atomic read rather than sent unconditionally,
so a listener in queue mode that is not at its ceiling pays one extra
`atomics:get/2` per request and no message.
""".
-spec release_request_slot(
    infinity | pos_integer(), counters:counters_ref() | undefined, overload()
) -> ok.
release_request_slot(infinity, _Counter, _Overload) ->
    ok;
release_request_slot(_Max, Counter, Overload) ->
    ok = counters:sub(Counter, 1, 1),
    notify_release(Overload).

-spec notify_release(overload()) -> ok.
notify_release({queue, Pid, Waiters, _Timeout}) ->
    case roadrunner_overload_queue:waiting(Waiters) of
        true -> roadrunner_overload_queue:note_release(Pid);
        false -> ok
    end;
notify_release(_NeverParks) ->
    ok.

-doc """
Release `N` in-flight slots at once. Used by the conn clean-exit path to
account for stream workers still live at teardown (each held one slot), so
their slots are not leaked until the listener restarts. `N = 0` and
`infinity` are no-ops.
""".
-spec release_request_slots(
    infinity | pos_integer(), counters:counters_ref() | undefined, non_neg_integer(), overload()
) -> ok.
release_request_slots(_Max, _Counter, 0, _Overload) ->
    ok;
release_request_slots(infinity, _Counter, _N, _Overload) ->
    ok;
release_request_slots(_Max, Counter, N, Overload) ->
    ok = counters:sub(Counter, 1, N),
    notify_release(Overload).

-doc false.
-spec refine_conn_label(
    proto_opts(), {inet:ip_address(), inet:port_number()} | undefined
) -> ok.
refine_conn_label(ProtoOpts, Peer) ->
    ListenerName = maps:get(listener_name, ProtoOpts, undefined),
    proc_lib:set_label({roadrunner_conn, ListenerName, Peer}),
    ok.

%% 64 random bits in lowercase hex — collision-resistant for billions of
%% requests, short enough to embed in log lines.
%%
%% `/1` accepts a per-conn buffer of pre-generated ids and returns
%% `{RequestId, NewBuffer}` — caller threads the buffer through its own
%% state. A refill draws 256 random bytes in one `crypto:strong_rand_bytes/1`
%% call and hex-encodes them in one `binary:encode_hex/2` call, so ~32
%% requests share both, and each request takes the next 16 characters:
%% ~70 ns per id with the refill amortized, against ~76 ns hexing each
%% id's 8 bytes through a lookup table. Each slice still carries a full
%% 64 bits of independent entropy — the batch boundary doesn't reduce
%% randomness. The slice is copied out, so an id kept past its request (a
%% log line, a trace) doesn't hold the whole 512-byte batch alive.

-define(REQ_ID_BATCH_BYTES, 256).

-doc false.
-spec generate_request_id(binary()) -> {binary(), binary()}.
generate_request_id(<<Id:16/binary, Rest/binary>>) ->
    {binary:copy(Id), Rest};
generate_request_id(_Empty) ->
    %% Buffer drained (or never initialized) — refill with one NIF call and
    %% one encode.
    <<Id:16/binary, Rest/binary>> =
        binary:encode_hex(crypto:strong_rand_bytes(?REQ_ID_BATCH_BYTES), lowercase),
    {binary:copy(Id), Rest}.

%% Replaces (not merges) the conn process's logger metadata so a
%% keep-alive request never inherits the previous request's correlation.
%% A request resolved behind a trusted proxy (`real_ip`) also carries its
%% `client_ip`.
-doc false.
-spec set_request_logger_metadata(roadrunner_req:request()) -> ok.
set_request_logger_metadata(#{
    request_id := RequestId,
    method := Method,
    target := Target,
    peer := Peer,
    client_ip := ClientIP
}) ->
    logger:set_process_metadata(#{
        request_id => RequestId,
        method => Method,
        path => Target,
        peer => Peer,
        client_ip => ClientIP
    });
set_request_logger_metadata(#{
    request_id := RequestId,
    method := Method,
    target := Target,
    peer := Peer
}) ->
    logger:set_process_metadata(#{
        request_id => RequestId,
        method => Method,
        path => Target,
        peer => Peer
    }).

-define(RECV_BYTES_PDKEY, {?MODULE, recv_bytes}).

%% The `N` an HTTP/1 connection armed its socket with (`{active, N}`),
%% `queued` once it disarmed it with reads possibly still in the mailbox,
%% or unset while it reads passively as it always has. Body reads run
%% inside handler code, through closures that cannot see the loop state,
%% so the connection records it here (`armed/1`, `disarmed/0`), once per
%% connection rather than per request.
-define(ACTIVE_PDKEY, {?MODULE, active}).

%% Record that this HTTP/1 connection's socket is armed with
%% `{active, N}`: body reads then take its reads from the mailbox.
-doc false.
-spec armed(pos_integer()) -> ok.
armed(N) ->
    _ = put(?ACTIVE_PDKEY, N),
    ok.

%% Record that the socket reads passively again, after reads it
%% delivered while armed, which the mailbox may still hold.
-doc false.
-spec disarmed() -> ok.
disarmed() ->
    _ = put(?ACTIVE_PDKEY, queued),
    ok.

%% The manual-mode body reader of the request in flight, as its last read
%% left it (`remember_reader/1`).
-define(READER_PDKEY, {?MODULE, body_reader}).

%% Drain-detection cap when in passive recv. Each recv call is bounded
%% to at most this many ms so the conn re-checks its mailbox for
%% `{roadrunner_drain, _}` between blocks. Trade-off: shorter = lower
%% drain latency, more recv NIF calls; longer = the opposite. 100 ms
%% matches typical ops-tooling expectations for graceful-drain
%% detection.
-define(DRAIN_CHECK_INTERVAL_MS, 100).

%% Build a recv closure with a single overall deadline plus a rolling
%% rate check.
%%
%% Rate enforcement (anti-Slowloris): track total bytes received and
%% time since the first recv. After a 1-second grace, require the
%% running average to meet `MinRate` bytes/sec, otherwise return
%% `{error, slow_client}`. The byte counter is a per-request atomics ref
%% allocated lazily on the first recv (see `recv_byte_counter/0`), so a
%% request with no body to read from the socket skips the allocation
%% entirely. `Start` is captured eagerly here, so the rate window is
%% anchored at body-phase entry.
-doc false.
-spec make_recv(roadrunner_transport:socket(), integer(), non_neg_integer()) ->
    fun(() -> {ok, binary()} | {error, request_timeout | slow_client | drained | term()}).
make_recv(Socket, Deadline, MinRate) ->
    Start = erlang:monotonic_time(millisecond),
    _ = erase(?RECV_BYTES_PDKEY),
    fun() -> recv_body_chunk(Socket, Deadline, MinRate, Start) end.

%% One drain-aware body read, kept out of the closure so a
%% chunk-timeout tick can recurse without rebuilding it.
%%
%% Each read is bounded by `?DRAIN_CHECK_INTERVAL_MS` rather than by the
%% whole remaining deadline, so a peer that stalls mid-body still
%% notices a graceful drain. Passive recv cannot see the mailbox, so
%% without the cap a half-sent body would park here for the entire
%% `request_timeout`, outlive the drain deadline and be hard-killed by
%% `roadrunner_listener:drain/2` — turning a graceful drain into a
%% forced one and reporting `{timeout, N}` rather than `{ok, drained}`.
%% This is the same cap the header path takes in
%% `roadrunner_conn_loop:recv_passive/2`, for the same reason. Normal
%% traffic never pays for it: the next chunk of a body already in flight
%% arrives in microseconds, so the cap only fires for a client that
%% stopped sending.
%%
%% `gen_tcp:recv` with a negative timeout is undefined, hence the cap at
%% 0 — which makes gen_tcp return `{error, timeout}` immediately once
%% the deadline has passed. A timeout with time still left on the
%% deadline is a drain-check tick and loops; one without is the
%% request_timeout itself.
-spec recv_body_chunk(roadrunner_transport:socket(), integer(), non_neg_integer(), integer()) ->
    {ok, binary()} | {error, request_timeout | slow_client | drained | term()}.
recv_body_chunk(Socket, Deadline, MinRate, Start) ->
    case get(?ACTIVE_PDKEY) of
        undefined -> recv_body_passive(Socket, Deadline, MinRate, Start);
        queued -> recv_body_queued(Socket, Deadline, MinRate, Start);
        N -> recv_body_active(Socket, Deadline, MinRate, Start, N)
    end.

%% A body read on a socket disarmed with reads still in the mailbox:
%% those come first, in order, then the socket.
-spec recv_body_queued(roadrunner_transport:socket(), integer(), non_neg_integer(), integer()) ->
    {ok, binary()} | {error, request_timeout | slow_client | drained | term()}.
recv_body_queued(Socket, Deadline, MinRate, Start) ->
    {DataTag, _ClosedTag, _ErrorTag} = roadrunner_transport:messages(Socket),
    receive
        {DataTag, _Sock, Data} ->
            rate_checked(Data, erlang:monotonic_time(millisecond) - Start, MinRate)
    after 0 ->
        recv_body_passive(Socket, Deadline, MinRate, Start)
    end.

-spec recv_body_passive(roadrunner_transport:socket(), integer(), non_neg_integer(), integer()) ->
    {ok, binary()} | {error, request_timeout | slow_client | drained | term()}.
recv_body_passive(Socket, Deadline, MinRate, Start) ->
    case drain_pending() of
        drain ->
            {error, drained};
        ok ->
            Now = erlang:monotonic_time(millisecond),
            Remaining = max(0, Deadline - Now),
            ChunkTimeout = min(Remaining, ?DRAIN_CHECK_INTERVAL_MS),
            case roadrunner_transport:recv(Socket, 0, ChunkTimeout) of
                {ok, Data} ->
                    rate_checked(Data, Now - Start, MinRate);
                {error, timeout} when Remaining =< ChunkTimeout ->
                    {error, request_timeout};
                {error, timeout} ->
                    recv_body_passive(Socket, Deadline, MinRate, Start);
                {error, _} = E ->
                    E
            end
    end.

%% A body read on a socket armed with `{active, N}`: the bytes arrive as
%% messages, so it waits in `receive`, which also sees a drain the moment
%% it is sent (no `?DRAIN_CHECK_INTERVAL_MS` tick needed). It matches
%% only socket messages and the drain, so the rest of the mailbox, which
%% in manual body buffering may hold messages meant for the handler, is
%% left alone. The socket's passive message arms it again.
-spec recv_body_active(
    roadrunner_transport:socket(), integer(), non_neg_integer(), integer(), pos_integer()
) ->
    {ok, binary()} | {error, request_timeout | slow_client | drained | term()}.
recv_body_active(Socket, Deadline, MinRate, Start, N) ->
    {DataTag, ClosedTag, ErrorTag} = roadrunner_transport:messages(Socket),
    PassiveTag = roadrunner_transport:passive_message(Socket),
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {DataTag, _Sock, Data} ->
            rate_checked(Data, erlang:monotonic_time(millisecond) - Start, MinRate);
        {PassiveTag, _Sock} ->
            case roadrunner_transport:setopts(Socket, [{active, N}]) of
                ok -> recv_body_active(Socket, Deadline, MinRate, Start, N);
                {error, _} = E -> E
            end;
        {ClosedTag, _Sock} ->
            {error, closed};
        {ErrorTag, _Sock, Reason} ->
            {error, Reason};
        {roadrunner_drain, _DrainDeadline} ->
            {error, drained}
    after Remaining ->
        {error, request_timeout}
    end.

%% A body read's bytes, counted toward the request's running rate after
%% `Elapsed` ms of its window.
-spec rate_checked(binary(), integer(), non_neg_integer()) ->
    {ok, binary()} | {error, slow_client}.
rate_checked(Data, Elapsed, MinRate) ->
    Total = atomics:add_get(recv_byte_counter(), 1, byte_size(Data)),
    case rate_ok(Elapsed, Total, MinRate) of
        true -> {ok, Data};
        false -> {error, slow_client}
    end.

%% Zero-timeout look for a queued drain. Unlike
%% `roadrunner_conn_loop:drain_mailbox_check/0`, which also discards
%% every other message it finds, this matches selectively and leaves the
%% rest of the mailbox untouched: in `manual` body buffering the handler
%% itself drives these reads, so the conn's mailbox may already hold
%% messages meant for the handler (a `{loop, ...}` response's pushes,
%% say). Dropping those would lose user data. The loop's own version
%% runs before any handler code, where nothing else can be waiting.
-spec drain_pending() -> drain | ok.
drain_pending() ->
    receive
        {roadrunner_drain, _Deadline} -> drain
    after 0 ->
        ok
    end.

%% Cap on a single passive recv, shared with
%% `roadrunner_conn_loop:recv_passive/2`. Exposed as a function because
%% the two paths live in different modules and the value must not drift.
-doc false.
-spec drain_check_interval_ms() -> pos_integer().
drain_check_interval_ms() ->
    ?DRAIN_CHECK_INTERVAL_MS.

%% Get-or-create the per-request received-byte counter. Allocated lazily
%% on the first recv so a bodyless or fully-buffered request (whose recv
%% closure is never invoked) skips the `atomics` allocation; memoized in
%% the process dictionary until `make_recv/3` resets it for the next
%% request. Process-local state is safe because the HTTP/1 connection
%% process reads one request body at a time.
-spec recv_byte_counter() -> atomics:atomics_ref().
recv_byte_counter() ->
    case get(?RECV_BYTES_PDKEY) of
        undefined ->
            Ref = atomics:new(1, [{signed, false}]),
            _ = put(?RECV_BYTES_PDKEY, Ref),
            Ref;
        Ref ->
            Ref
    end.

-doc false.
%% A 1-second grace lets a slow handshake / TLS session start without
%% being misclassified. After that, the running average must meet the
%% minimum or the client is dropped. `MinRate = 0` falls through and
%% always passes — the inequality `Total * 1000 >= 0` is trivially true.
-spec rate_ok(integer(), non_neg_integer(), non_neg_integer()) -> boolean().
rate_ok(ElapsedMs, _Total, _MinRate) when ElapsedMs =< 1000 -> true;
rate_ok(ElapsedMs, Total, MinRate) -> Total * 1000 >= MinRate * ElapsedMs.

-doc false.
-spec peer(roadrunner_transport:socket()) -> {inet:ip_address(), inet:port_number()} | undefined.
peer(Socket) ->
    case roadrunner_transport:peername(Socket) of
        {ok, Peer} -> Peer;
        {error, _} -> undefined
    end.

%% The connection's `t:roadrunner_req:conn_info/0`, built once per
%% connection and carried on each request: it reads the socket only when
%% `roadrunner_req:sockname/1`, `peercert/1` or `tls_info/1` asks.
-doc false.
-spec conn_info(roadrunner_transport:socket()) -> roadrunner_req:conn_info().
conn_info(Socket) ->
    fun
        (sockname) -> roadrunner_transport:sockname(Socket);
        (peercert) -> roadrunner_transport:peercert(Socket);
        (tls_info) -> roadrunner_transport:tls_info(Socket)
    end.

-doc false.
-spec scheme(roadrunner_transport:socket()) -> http | https.
scheme({gen_tcp, _}) -> http;
scheme({ssl, _}) -> https;
scheme({fake, _}) -> http.

-doc false.
-spec resolve_handler(dispatch(), roadrunner_req:request()) -> resolved().
resolve_handler({handler, Mod, Pipeline, State}, _Req) ->
    {ok, Mod, #{}, Pipeline, State, undefined};
resolve_handler({router, ListenerName}, Req) ->
    %% Routes are stored in `persistent_term` by `roadrunner_listener` so
    %% the lookup is O(1) and `roadrunner_listener:reload_routes/2` can
    %% atomically swap the table without bouncing the listener.
    Compiled = persistent_term:get({roadrunner_routes, ListenerName}),
    roadrunner_router:resolve(roadrunner_req:method(Req), roadrunner_req:path(Req), Compiled).

%% The body cap of a resolved request: its route's `max_content_length` when
%% the route sets one, else the listener's `Default`.
-doc false.
-spec body_cap(resolved(), non_neg_integer()) -> non_neg_integer().
body_cap({ok, _Handler, _Bindings, _Pipeline, _State, #{max_content_length := Max}}, _Default) ->
    Max;
body_cap(_Resolved, Default) ->
    Default.

%% The body cap of an HTTP/2 or HTTP/3 request from its decoded field
%% section: the `max_content_length` of the route its `:method` and `:path`
%% resolve to, else the listener's `Default` (no such route setting one, a
%% listener without routes, or a section missing either field, which
%% dispatch then rejects). Those connections otherwise leave routing to the
%% stream worker, so this runs only when a body would outgrow `Default` or
%% an `Expect: 100-continue` request needs its answer now.
-doc false.
-spec route_body_cap(dispatch(), roadrunner_http:headers(), non_neg_integer()) ->
    non_neg_integer().
route_body_cap({router, ListenerName}, Headers, Default) ->
    case {lists:keyfind(~":method", 1, Headers), lists:keyfind(~":path", 1, Headers)} of
        {{_, Method}, {_, Target}} ->
            Compiled = persistent_term:get({roadrunner_routes, ListenerName}),
            body_cap(
                roadrunner_router:resolve(Method, roadrunner_req:target_path(Target), Compiled),
                Default
            );
        _ ->
            Default
    end;
route_body_cap({handler, _Mod, _Pipeline, _State}, _Headers, Default) ->
    Default.

%% How an HTTP/2 or HTTP/3 request whose body is still to come is answered
%% for its `Expect` field (RFC 9110 §10.1.1, HTTP/2 and HTTP/3 being "HTTP/1.1
%% or later"): `too_large` when it expects `100-continue` with a declared
%% `content-length` already over its route's body cap, the 413 its body would
%% earn anyway (the route looked up only then); `continue` when it otherwise
%% expects `100-continue`, the 100
%% that asks for the body; `malformed` when it expects `100-continue` with a
%% `content-length` that isn't one valid length (repeated, not digits, or
%% past 2^63 - 1), a malformed request (RFC 9113 §8.1.1, RFC 9114 §4.1.2)
%% that gets no 100; `none` when it expects nothing. HTTP/1.1 decides
%% from the request's framing instead (`roadrunner_conn_loop:expect_answer/4`).
-doc false.
-spec expect_answer(proto_opts(), roadrunner_http:headers(), non_neg_integer()) ->
    none | continue | too_large | malformed.
expect_answer(ProtoOpts, Headers, MaxCL) ->
    case lists:keyfind(~"expect", 1, Headers) of
        {_, Expect} ->
            case
                roadrunner_http:expectation(Expect) =:= continue andalso
                    roadrunner_http:request_content_length(Headers)
            of
                {ok, Declared} ->
                    #{dispatch := Dispatch} = ProtoOpts,
                    case Declared > route_body_cap(Dispatch, Headers, MaxCL) of
                        true -> too_large;
                        false -> continue
                    end;
                false ->
                    none;
                none ->
                    continue;
                error ->
                    malformed
            end;
        false ->
            none
    end.

%% A request with its client's address (`client_ip`) when its connection is
%% from a trusted proxy (`RealIp`, `roadrunner_real_ip:peer_trust/2`),
%% resolved from the request's forwarding header; `undefined` trust, the
%% common case, leaves the request as it is.
-doc false.
-spec with_client_ip(
    roadrunner_req:request(),
    undefined | roadrunner_real_ip:config(),
    {inet:ip_address(), inet:port_number()} | undefined
) -> roadrunner_req:request().
with_client_ip(Req, undefined, _Peer) ->
    Req;
with_client_ip(#{headers := Headers} = Req, RealIp, {PeerIP, _Port}) ->
    Req#{client_ip => roadrunner_real_ip:resolve(RealIp, PeerIP, Headers)}.

%% The `Allow` header value for a `405`, built from the methods
%% `roadrunner_router:match/3` reports as accepted on the path. Flattened here
%% because the HPACK and QPACK encoders size header values with `byte_size/1`,
%% so h2 and h3 need a binary rather than the iodata the HTTP/1 writer takes.
-doc false.
-spec allow_header_value([binary()]) -> binary().
allow_header_value(Allowed) ->
    iolist_to_binary(lists:join(~", ", Allowed)).

%% Read a whole body framed by `Framing` (from `body_framing/1`). A
%% request without one (`none`) has no body to read, so the conn loop
%% answers it without coming here.
-doc false.
-spec read_body(
    chunked
    | {content_length, non_neg_integer()}
    | {error, bad_content_length | bad_transfer_encoding},
    binary(),
    fun(() -> {ok, binary()} | {error, term()}),
    non_neg_integer(),
    {pos_integer(), pos_integer(), pos_integer()}
) ->
    {ok, Body :: iodata(), Leftover :: binary()}
    | {error,
        content_length_too_large
        | bad_content_length
        | bad_transfer_encoding
        | term()}.
read_body(chunked, Buffered, RecvFun, MaxCL, TrailerLimits) ->
    read_chunked(Buffered, RecvFun, MaxCL, <<>>, TrailerLimits);
read_body({content_length, N}, _Buffered, _RecvFun, MaxCL, _TrailerLimits) when N > MaxCL ->
    {error, content_length_too_large};
read_body({content_length, N}, Buffered, RecvFun, _MaxCL, _TrailerLimits) ->
    read_body_until(N, Buffered, RecvFun);
read_body({error, _} = Err, _Buffered, _RecvFun, _MaxCL, _TrailerLimits) ->
    Err.

%% RFC 9110 §10.1.1: send the interim `HTTP/1.1 100 Continue` to a
%% client that gates its body on it. The conn loop decides when
%% (`Expect: 100-continue` and no body bytes in hand yet, see
%% `expects_continue/1`).
-doc false.
-spec send_continue(roadrunner_transport:socket()) -> ok.
send_continue(Socket) ->
    _ = roadrunner_transport:send(Socket, ~"HTTP/1.1 100 Continue\r\n\r\n"),
    ok.

%% Whether the request carries an `Expect: 100-continue` the server
%% answers with the interim 100. Never for HTTP/1.0: RFC 9110 §10.1.1
%% ignores an HTTP/1.0 client's expectation, and §15.2 forbids sending it
%% a 1xx response.
-doc false.
-spec expects_continue(roadrunner_req:request()) -> boolean().
expects_continue(#{version := {1, 0}}) ->
    false;
expects_continue(#{cached_decisions := #{expectation := Expectation}}) ->
    Expectation =:= continue;
expects_continue(Req) ->
    %% Manually-built request maps (tests, middleware) skip the parse-time
    %% precompute — fall back to parsing the header.
    case roadrunner_req:header_normalized(~"expect", Req) of
        undefined -> false;
        Value -> roadrunner_http:expectation(Value) =:= continue
    end.

-doc false.
-spec make_body_reader(
    none | chunked | {content_length, non_neg_integer()},
    binary(),
    fun(() -> {ok, binary()} | {error, term()}),
    non_neg_integer(),
    {pos_integer(), pos_integer(), pos_integer()}
) -> roadrunner_req:body_reader().
make_body_reader(Framing, Buffered, Recv, Max, TrailerLimits) ->
    _ = erase(?READER_PDKEY),
    #{
        framing => Framing,
        buffered => Buffered,
        bytes_read => 0,
        pending => <<>>,
        done => false,
        recv => Recv,
        max => Max,
        trailer_limits => TrailerLimits
    }.

%% The body reader of an HTTP/2 request in manual body mode: its DATA is
%% delimited by the stream, so the reader pulls what the connection has
%% received through `recv` (`stream_recv/3`) until the stream's end, held to
%% `Max` bytes. A request whose stream already ended with its headers has no
%% body to pull (`Done`).
-doc false.
-spec stream_body_reader(pid(), pos_integer(), integer(), non_neg_integer(), boolean()) ->
    roadrunner_req:body_reader().
stream_body_reader(Conn, StreamId, Deadline, Max, Done) ->
    #{
        framing => stream,
        buffered => <<>>,
        bytes_read => 0,
        done => Done,
        recv => stream_recv(Conn, StreamId, Deadline),
        max => Max
    }.

%% A request whose handler reads its body as it arrives (HTTP/2 and HTTP/3
%% in manual mode): its buffered `body` gives way to a stream body reader
%% pulling from this connection process, until `Timeout` ms from now and
%% held to `Max` bytes. `ContinueOwed` marks a client holding its body back
%% for a 100 Continue, which a streaming response asks this connection for
%% before it starts (`continue_before_stream/1`).
-doc false.
-spec with_body_reader(
    roadrunner_req:request(), pos_integer(), non_neg_integer(), non_neg_integer(), boolean()
) ->
    roadrunner_req:request().
with_body_reader(Req, StreamId, Timeout, Max, ContinueOwed) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    Reader0 = stream_body_reader(self(), StreamId, Deadline, Max, false),
    Reader =
        case ContinueOwed of
            true -> Reader0#{continue => {self(), StreamId}};
            false -> Reader0
        end,
    (maps:remove(body, Req))#{body_reader => Reader}.

%% RFC 9110 §10.1.1, for a response about to stream (`stream`, `loop`) while
%% its client still holds the body back for the 100 Continue left to the
%% first read: the 100 goes out first, so a handler that reads the body as it
%% streams gets it, and no 100 lands after the final response. On HTTP/1.1
%% this process sends it; on HTTP/2 and HTTP/3 the connection does, ahead of
%% the response the worker sends next, and answers once it has. A complete
%% response (buffered, `sendfile`) does not ask: the client is answered, and
%% a body no handler reads is never asked for.
-doc false.
-spec continue_before_stream(roadrunner_req:request()) -> ok.
continue_before_stream(#{body_reader := #{continue := {Socket, _Deadline, _MinRate, Owed}}}) ->
    send_continue_once(Owed, Socket);
continue_before_stream(#{body_reader := #{continue := {Conn, StreamId}}}) ->
    MRef = monitor(process, Conn),
    Conn ! {roadrunner_continue, self(), StreamId},
    receive
        {roadrunner_continued, StreamId} -> ok;
        {'DOWN', MRef, process, Conn, _} -> ok
    end,
    true = demonitor(MRef, [flush]),
    ok;
continue_before_stream(_Req) ->
    ok.

%% A final response sent by a `roadrunner_send` fun while the 100 Continue
%% is still owed: the fun may read the body after it, and an interim
%% response goes before the final one, never after (RFC 9110 §15.2), so no
%% later read sends it. On HTTP/1.1 the reader's flag is set; on HTTP/2 and
%% HTTP/3 the connection is told, ahead of the reads it orders after it.
-doc false.
-spec skip_continue(roadrunner_req:request()) -> ok.
skip_continue(#{body_reader := #{continue := {_Socket, _Deadline, _MinRate, Owed}}}) ->
    atomics:put(Owed, 1, 1);
skip_continue(#{body_reader := #{continue := {Conn, StreamId}}}) ->
    _ = Conn ! {roadrunner_skip_continue, StreamId},
    ok;
skip_continue(_Req) ->
    ok.

%% The HTTP/1.1 100 Continue a body reader owes, asked for by its first read
%% and by a response that streams first (`continue_before_stream/1`), from
%% any copy of the request: sent once, by whichever asks first.
-spec send_continue_once(atomics:atomics_ref(), roadrunner_transport:socket()) -> ok.
send_continue_once(Owed, Socket) ->
    case atomics:exchange(Owed, 1, 1) of
        0 -> send_continue(Socket);
        1 -> ok
    end.

%% The connection's answer to a stream body reader's demand (`stream_recv/3`
%% receives it): DATA, `Fin` marking the body's end.
-doc false.
-spec send_body(pid(), pos_integer(), iodata(), boolean()) -> ok.
send_body(Reader, StreamId, Data, Fin) ->
    _ = Reader ! {roadrunner_body, StreamId, Data, Fin},
    ok.

%% The read failing with `Reason`, for a reader waiting on it (`undefined`:
%% none is).
-doc false.
-spec send_body_error(pid() | undefined, pos_integer(), atom()) -> ok.
send_body_error(undefined, _StreamId, _Reason) ->
    ok;
send_body_error(Reader, StreamId, Reason) ->
    _ = Reader ! {roadrunner_body_error, StreamId, Reason},
    ok.

%% The recv of a stream body reader, run in the worker that reads the body:
%% ask the connection for the stream's next DATA and wait for it, until the
%% request's `Deadline`. The connection answers with what it holds, or with
%% the next DATA to arrive, and `Fin` once the stream has ended; a stream it
%% no longer has, or a connection that goes away, ends the read.
-spec stream_recv(pid(), pos_integer(), integer()) ->
    fun(() -> {ok, iodata(), boolean()} | {error, term()}).
stream_recv(Conn, StreamId, Deadline) ->
    fun() ->
        MRef = monitor(process, Conn),
        Conn ! {roadrunner_body_demand, self(), StreamId},
        Timeout = max(0, Deadline - erlang:monotonic_time(millisecond)),
        Result =
            receive
                {roadrunner_body, StreamId, Data, Fin} -> {ok, Data, Fin};
                {roadrunner_body_error, StreamId, Reason} -> {error, Reason};
                {'DOWN', MRef, process, Conn, _} -> {error, closed}
            after Timeout -> {error, request_timeout}
            end,
        true = demonitor(MRef, [flush]),
        Result
    end.

-doc false.
-spec body_framing(roadrunner_req:request()) ->
    none
    | chunked
    | {content_length, non_neg_integer()}
    | {error, bad_content_length | bad_transfer_encoding}.
body_framing(#{cached_decisions := #{is_chunked := true}}) ->
    chunked;
body_framing(#{cached_decisions := #{has_transfer_encoding := true}}) ->
    %% Non-chunked Transfer-Encoding (e.g. `gzip`). Rejected per
    %% RFC 9112 §6.1 — we only support identity and chunked.
    {error, bad_transfer_encoding};
body_framing(#{cached_decisions := #{content_length := CL}}) ->
    %% No Transfer-Encoding header. `parse_request/1`'s `check_framing/1`
    %% already rejected TE+CL combos and inconsistent multi-CL, so the
    %% cached Content-Length is the body framing.
    case CL of
        none -> none;
        {ok, N} -> {content_length, N};
        {error, _} = Err -> Err
    end;
body_framing(Req) ->
    %% Manually-built request maps without cached_decisions — full path.
    case roadrunner_req:header_normalized(~"transfer-encoding", Req) of
        undefined ->
            case content_length(Req) of
                none -> none;
                {ok, N} -> {content_length, N};
                {error, _} = Err -> Err
            end;
        Value ->
            %% RFC 9110 §10.1.4: transfer-coding names are
            %% case-insensitive. Accept `chunked`, `Chunked`,
            %% `CHUNKED` etc. (clients in the wild send all variants).
            case roadrunner_bin:ascii_lowercase(Value) of
                ~"chunked" -> chunked;
                _ -> {error, bad_transfer_encoding}
            end
    end.

-spec read_body_until(
    non_neg_integer(),
    binary(),
    fun(() -> {ok, binary()} | {error, term()})
) ->
    {ok, iodata(), binary()} | {error, term()}.
read_body_until(N, Buffered, _RecvFun) when byte_size(Buffered) >= N ->
    <<Body:N/binary, Leftover/binary>> = Buffered,
    {ok, Body, Leftover};
read_body_until(N, Buffered, RecvFun) ->
    %% Body recursion: each level reads one recv-chunk and prepends it
    %% to the iolist returned from below on the way out. The auto-path
    %% body field is `iodata()` so handlers that only need
    %% `iolist_size/1` or want to forward the body via `gen_tcp:send/2`
    %% never pay the flatten cost. Handlers requiring a flat binary
    %% (e.g. pattern matching, `roadrunner_qs:parse/1`) call
    %% `iolist_to_binary/1` themselves.
    case read_body_until_io(N - byte_size(Buffered), RecvFun) of
        {ok, MoreIo, Leftover} ->
            {ok, [Buffered | MoreIo], Leftover};
        {error, _} = E ->
            E
    end.

-spec read_body_until_io(
    non_neg_integer(),
    fun(() -> {ok, binary()} | {error, term()})
) ->
    {ok, iolist(), binary()} | {error, term()}.
read_body_until_io(N, RecvFun) ->
    case RecvFun() of
        {ok, Data} ->
            DataSz = byte_size(Data),
            if
                DataSz >= N ->
                    <<Chunk:N/binary, Leftover/binary>> = Data,
                    {ok, [Chunk], Leftover};
                true ->
                    case read_body_until_io(N - DataSz, RecvFun) of
                        {ok, More, Leftover} -> {ok, [Data | More], Leftover};
                        {error, _} = E -> E
                    end
            end;
        {error, _} = E ->
            E
    end.

%% Read chunks until the size-0 last-chunk, concatenating decoded data
%% into the result. Caps the accumulated body at MaxCL — a malicious
%% client cannot stream unbounded chunked bytes past the configured
%% limit. Body recursion: each call returns the body of the remaining
%% chunks, the current call prepends its own data on the way out.
-spec read_chunked(
    binary(),
    fun(() -> {ok, binary()} | {error, term()}),
    non_neg_integer(),
    binary(),
    {pos_integer(), pos_integer(), pos_integer()}
) ->
    {ok, binary(), binary()} | {error, content_length_too_large | term()}.
read_chunked(Buf, RecvFun, MaxCL, Body, TrailerLimits) ->
    %% `parse_chunk/3` rejects a declared chunk size over the remaining
    %% budget on its size line, so an oversized chunk can't buffer past
    %% the cap before this loop sees it.
    case roadrunner_http1:parse_chunk(Buf, TrailerLimits, MaxCL - byte_size(Body)) of
        {ok, last, _Trailers, Leftover} ->
            %% Bytes after the size-0 last-chunk + trailer block are
            %% pipelined-next-request leftover; thread them up so the
            %% conn can feed them into the next parse.
            {ok, Body, Leftover};
        {ok, Data, Rest} ->
            %% Append each chunk to the body as it is decoded. Rebuilding
            %% `<<Data/binary, More/binary>>` on the way back up a body
            %% recursion copied the tail at every level, O(n^2) in the
            %% chunk count (64 x 1 KB chunks: 85 us against 14 us).
            read_chunked(Rest, RecvFun, MaxCL, <<Body/binary, Data/binary>>, TrailerLimits);
        {more, _} ->
            case RecvFun() of
                {ok, More} ->
                    read_chunked(
                        roadrunner_bin:append(Buf, More), RecvFun, MaxCL, Body, TrailerLimits
                    );
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

%% Read and discard whatever the handler left in a manual-mode
%% `body_reader`, returning any post-body leftover bytes that belong to a
%% pipelined next request. `roadrunner_conn_loop`'s finishing phase
%% threads `Leftover` forward into the next `reading_request` parse so
%% pipelined clients get their N+1 request seen; a WebSocket session's
%% close path, which keeps the reader but not the request, drains it too.
-doc false.
-spec drain_reader(roadrunner_req:body_reader()) -> {ok, binary()} | {error, term()}.
drain_reader(BS) ->
    case consume_reader(BS, all) of
        {ok, _Bytes, #{buffered := Leftover}} -> {ok, Leftover};
        {error, _} = E -> E
    end.

%% The request's body reader as its last read left it, or `BS` when it was
%% never read: a handler that read its body inside a stream, or handed
%% back an older request, leaves the connection a copy that does not know
%% what was read, and draining that copy would wait for bytes already
%% taken.
-doc false.
-spec latest_reader(roadrunner_req:body_reader()) -> roadrunner_req:body_reader().
latest_reader(BS) ->
    case erase(?READER_PDKEY) of
        undefined -> BS;
        Latest -> Latest
    end.

-doc """
Consume bytes from a manual-mode `roadrunner_req:body_reader()`. Returns either the
final tail (`{ok, Bytes, NewState}` — the body has been fully drained)
or a partial chunk (`{more, Bytes, NewState}` — more is still pending).
Used by `roadrunner_req:read_body/1,2`; not part of the public API.

`Mode` is `all` (drain to end) or `{length, N}` (read up to `N`
bytes — content-length framing only; chunked falls through to a
full read).
""".
-spec consume_body_reader(
    roadrunner_req:body_reader(), all | next_chunk | {length, non_neg_integer()}
) ->
    {ok, iodata(), roadrunner_req:body_reader()}
    | {more, iodata(), roadrunner_req:body_reader()}
    | {error, term()}.
consume_body_reader(BS, Mode) ->
    remember_reader(consume_reader(BS, Mode)).

%% The reader as the handler last left it, so the connection drains from
%% there (`latest_reader/1`) even when the request the handler hands
%% back, or none at all for a stream, still holds an older copy. One
%% reader per HTTP/1 connection process at a time; `make_body_reader/5`
%% clears it for the next request.
-spec remember_reader(
    {ok, iodata(), roadrunner_req:body_reader()}
    | {more, iodata(), roadrunner_req:body_reader()}
    | {error, term()}
) ->
    {ok, iodata(), roadrunner_req:body_reader()}
    | {more, iodata(), roadrunner_req:body_reader()}
    | {error, term()}.
remember_reader({error, _} = E) ->
    E;
remember_reader({_, _Bytes, BS} = Result) ->
    _ = put(?READER_PDKEY, BS),
    Result.

-spec consume_reader(
    roadrunner_req:body_reader(), all | next_chunk | {length, non_neg_integer()}
) ->
    {ok, iodata(), roadrunner_req:body_reader()}
    | {more, iodata(), roadrunner_req:body_reader()}
    | {error, term()}.
consume_reader(#{continue := {Socket, Deadline, MinRate, Owed}} = BS, Mode) ->
    %% The client is holding its body back for a 100 Continue the conn left
    %% to this first read (`roadrunner_conn_loop:read_body/8`): send it,
    %% then read with a recv whose slow-client rate window starts now, as the
    %% client can only start sending now.
    ok = send_continue_once(Owed, Socket),
    Recv = make_recv(Socket, Deadline, MinRate),
    consume_reader(maps:remove(continue, BS#{recv := Recv}), Mode);
consume_reader(#{framing := stream} = BS, all) ->
    stream_collect(BS, infinity, [], 0);
consume_reader(#{framing := stream} = BS, {length, N}) ->
    stream_collect(BS, N, [], 0);
consume_reader(#{framing := stream} = BS, next_chunk) ->
    stream_next(BS);
consume_reader(#{framing := none} = BS, _Mode) ->
    %% Per RFC 9112 §6.3: no framing means the body is empty.
    %% Any `buffered` bytes are pipelined-next-request leftovers —
    %% preserve them in the body_reader's `buffered` field so
    %% `roadrunner_conn_loop`'s finishing phase can thread them into
    %% the next `reading_request` parse for full pipelining support.
    {ok, <<>>, BS};
consume_reader(
    #{framing := {content_length, N}, bytes_read := Read} = BS, _Mode
) when Read >= N ->
    {ok, <<>>, BS};
consume_reader(#{framing := {content_length, N}, max := Max}, _Mode) when N > Max ->
    %% A declared length over the cap fails every read, one of a piece as
    %% much as one of the whole body, before any of it is read.
    {error, content_length_too_large};
consume_reader(
    #{framing := {content_length, N}, bytes_read := Read, buffered := Buf, recv := Recv} = BS,
    Mode
) ->
    Remaining = N - Read,
    Want =
        case Mode of
            all -> Remaining;
            next_chunk -> Remaining;
            {length, L} -> min(Remaining, L)
        end,
    case fill_n(Want, Buf, Recv) of
        {ok, Bytes, NewBuf} ->
            NewRead = Read + iolist_size(Bytes),
            NewState = BS#{buffered := NewBuf, bytes_read := NewRead},
            case NewRead >= N of
                true -> {ok, Bytes, NewState};
                false -> {more, Bytes, NewState}
            end;
        {error, _} = E ->
            E
    end;
consume_reader(#{framing := chunked} = BS, all) ->
    %% Drain everything left: any pending decoded bytes plus all
    %% remaining chunks, accumulated in one return. Iodata stays unflattened
    %% so callers that only need `iolist_size/1` or want to forward via
    %% `gen_tcp:send/2` skip a flatten.
    chunked_collect(BS, infinity);
consume_reader(#{framing := chunked} = BS, {length, N}) ->
    chunked_collect(BS, N);
consume_reader(#{framing := chunked} = BS, next_chunk) ->
    next_chunk(BS).
%% Non-chunked framing (none, content_length) is handled by the
%% earlier clauses above — `next_chunk` is treated as a full drain
%% inside those, since there are no chunk boundaries to honor.

%% Gather up to `Want` bytes of a stream body (`infinity`: all of them),
%% the bytes an earlier length-bounded read left in `buffered` first, then
%% more from the connection. `Acc` holds what is gathered, `Got` its size.
%% The result is `ok` once the body has ended with nothing left over, else
%% `more`.
-spec stream_collect(
    roadrunner_req:body_reader(), infinity | non_neg_integer(), iodata(), non_neg_integer()
) ->
    {ok, iodata(), roadrunner_req:body_reader()}
    | {more, iodata(), roadrunner_req:body_reader()}
    | {error, term()}.
stream_collect(#{buffered := Buf, done := Done} = BS, Want, Acc, Got) ->
    Size = iolist_size(Buf),
    case Want of
        infinity when Done ->
            {ok, [Acc, Buf], BS#{buffered := <<>>}};
        _ when is_integer(Want), Got + Size >= Want ->
            Take = Want - Got,
            <<Head:Take/binary, Rest/binary>> = iolist_to_binary(Buf),
            Status =
                case Done andalso Rest =:= <<>> of
                    true -> ok;
                    false -> more
                end,
            {Status, [Acc, Head], BS#{buffered := Rest}};
        _ when Done ->
            {ok, [Acc, Buf], BS#{buffered := <<>>}};
        _ ->
            case stream_pull(BS) of
                {ok, BS1} -> stream_collect(BS1, Want, [Acc, Buf], Got + Size);
                {error, _} = E -> E
            end
    end.

%% The next piece of a stream body: what an earlier read left over, else the
%% next DATA the connection hands over.
-spec stream_next(roadrunner_req:body_reader()) ->
    {ok, iodata(), roadrunner_req:body_reader()}
    | {more, iodata(), roadrunner_req:body_reader()}
    | {error, term()}.
stream_next(#{buffered := Buf, done := Done} = BS) ->
    case iolist_size(Buf) of
        0 when Done ->
            {ok, <<>>, BS};
        0 ->
            case stream_pull(BS#{buffered := <<>>}) of
                {ok, BS1} -> stream_next(BS1);
                {error, _} = E -> E
            end;
        _ when Done ->
            {ok, Buf, BS#{buffered := <<>>}};
        _ ->
            {more, Buf, BS#{buffered := <<>>}}
    end.

%% One round with the connection: its DATA becomes `buffered` (empty
%% before), held to the reader's `max`.
-spec stream_pull(roadrunner_req:body_reader()) ->
    {ok, roadrunner_req:body_reader()} | {error, term()}.
stream_pull(#{recv := Recv, bytes_read := Read, max := Max} = BS) ->
    case Recv() of
        {ok, Data, Fin} ->
            case Read + iolist_size(Data) of
                Total when Total > Max ->
                    {error, content_length_too_large};
                Total ->
                    {ok, BS#{buffered := Data, bytes_read := Total, done := Fin}}
            end;
        {error, _} = E ->
            E
    end.

%% Pull decoded chunked-body bytes out of `BS` until either `Want`
%% bytes are collected or the body is fully drained. `Want` is either
%% `infinity` (drain to end — caller asked for `all`) or a positive
%% integer (caller asked for `{length, N}`). Returns
%% `{ok | more, Bytes, BS2}` with Bytes as iodata (propagated through
%% `consume_body_reader` to the public API unflattened).
-spec chunked_collect(roadrunner_req:body_reader(), infinity | non_neg_integer()) ->
    {ok, iodata(), roadrunner_req:body_reader()}
    | {more, iodata(), roadrunner_req:body_reader()}
    | {error, term()}.
chunked_collect(#{pending := Pending} = BS, Want) when
    Want =/= infinity, byte_size(Pending) >= Want
->
    %% Pending alone satisfies the request — no need to look at the
    %% wire. The body may or may not have more bytes; we always tag
    %% `more` here and let the next call detect end-of-body via the
    %% `done` clause below.
    <<Take:Want/binary, RestPending/binary>> = Pending,
    {more, [Take], BS#{pending := RestPending}};
chunked_collect(#{pending := Pending} = BS, Want) when byte_size(Pending) > 0 ->
    %% Take everything pending, then try to fill more from the wire.
    %% Cons `Pending` in front of the recursion's result on the way
    %% out — body recursion replaces the old `[Pending | Acc]` /
    %% `lists:reverse` shape.
    NewWant =
        case Want of
            infinity -> infinity;
            N -> N - byte_size(Pending)
        end,
    case chunked_collect(BS#{pending := <<>>}, NewWant) of
        {Tag, RestIo, BS2} -> {Tag, [Pending | RestIo], BS2};
        {error, _} = E -> E
    end;
chunked_collect(#{done := true} = BS, _Want) ->
    {ok, [], BS};
chunked_collect(
    #{
        buffered := Buf,
        recv := Recv,
        max := Max,
        bytes_read := Read,
        trailer_limits := TrailerLimits
    } = BS,
    Want
) ->
    case roadrunner_http1:parse_chunk(Buf, TrailerLimits, Max - Read) of
        {ok, Data, Rest} ->
            NewRead = Read + byte_size(Data),
            BS2 = BS#{buffered := Rest, bytes_read := NewRead, pending := Data},
            chunked_collect(BS2, Want);
        {ok, last, _Trailers, Rest} ->
            chunked_collect(BS#{buffered := Rest, done := true}, Want);
        {more, _} ->
            case Recv() of
                {ok, More} ->
                    chunked_collect(BS#{buffered := roadrunner_bin:append(Buf, More)}, Want);
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

%% Pull exactly one decoded chunk out of a chunked body_reader. Pending
%% bytes (left over from a length-bounded read) are returned first; if
%% pending is empty, parse the next wire chunk. End-of-body returns
%% `{ok, <<>>, BS}`.
-spec next_chunk(roadrunner_req:body_reader()) ->
    {ok, binary(), roadrunner_req:body_reader()}
    | {more, binary(), roadrunner_req:body_reader()}
    | {error, term()}.
next_chunk(#{pending := Pending} = BS) when byte_size(Pending) > 0 ->
    {more, Pending, BS#{pending := <<>>}};
next_chunk(#{done := true} = BS) ->
    {ok, <<>>, BS};
next_chunk(
    #{
        buffered := Buf,
        recv := Recv,
        max := Max,
        bytes_read := Read,
        trailer_limits := TrailerLimits
    } = BS
) ->
    case roadrunner_http1:parse_chunk(Buf, TrailerLimits, Max - Read) of
        {ok, Data, Rest} ->
            NewRead = Read + byte_size(Data),
            {more, Data, BS#{buffered := Rest, bytes_read := NewRead}};
        {ok, last, _Trailers, Rest} ->
            {ok, <<>>, BS#{buffered := Rest, done := true}};
        {more, _} ->
            case Recv() of
                {ok, More} ->
                    next_chunk(BS#{buffered := roadrunner_bin:append(Buf, More)});
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

-spec fill_n(non_neg_integer(), binary(), fun(() -> {ok, binary()} | {error, term()})) ->
    {ok, iodata(), binary()} | {error, term()}.
fill_n(N, Buf, _Recv) when byte_size(Buf) >= N ->
    <<Bytes:N/binary, Rest/binary>> = Buf,
    {ok, Bytes, Rest};
fill_n(N, Buf, Recv) ->
    %% Body recursion that conses each recv chunk onto the iolist on
    %% the way OUT. The iolist propagates through `consume_body_reader`
    %% to the caller unflattened so callers that only need
    %% `iolist_size/1` (or want to forward via `gen_tcp:send/2`) avoid
    %% an O(total-body) copy.
    Need = N - byte_size(Buf),
    case fill_iolist(Need, Recv) of
        {ok, Iolist, Leftover} ->
            {ok, [Buf | Iolist], Leftover};
        {error, _} = E ->
            E
    end.

%% Always called with `Need >= 1` from `fill_n/3` (the
%% `byte_size(Buf) >= N` clause handles the Need = 0 case before
%% we get here). When `MoreSize == Need` exactly, the
%% `MoreSize >= Need` branch returns directly — we never recurse
%% with Need = 0, so no base clause is needed.
-spec fill_iolist(pos_integer(), fun(() -> {ok, binary()} | {error, term()})) ->
    {ok, iolist(), binary()} | {error, term()}.
fill_iolist(Need, Recv) ->
    case Recv() of
        {ok, More} ->
            MoreSize = byte_size(More),
            if
                MoreSize >= Need ->
                    <<Take:Need/binary, Leftover/binary>> = More,
                    {ok, [Take], Leftover};
                true ->
                    case fill_iolist(Need - MoreSize, Recv) of
                        {ok, Rest, Leftover} -> {ok, [More | Rest], Leftover};
                        {error, _} = E -> E
                    end
            end;
        {error, _} = E ->
            E
    end.

-spec content_length(roadrunner_req:request()) ->
    none | {ok, non_neg_integer()} | {error, bad_content_length}.
content_length(Req) ->
    case roadrunner_req:header_normalized(~"content-length", Req) of
        undefined ->
            none;
        Bin ->
            case roadrunner_bin:digits_to_integer(Bin) of
                {ok, _} = Ok -> Ok;
                error -> {error, bad_content_length}
            end
    end.

-doc false.
-spec parse_loop(binary(), fun(() -> {ok, binary()} | {error, term()})) ->
    {ok, roadrunner_req:request(), binary()} | {error, term()}.
parse_loop(Buf, RecvFun) ->
    case roadrunner_http1:parse_request(Buf) of
        {ok, Req, Rest} ->
            {ok, Req, Rest};
        {more, _} ->
            case RecvFun() of
                {ok, Data} -> parse_loop(roadrunner_bin:append(Buf, Data), RecvFun);
                {error, _} = E -> E
            end;
        {error, _} = E ->
            E
    end.

%% RFC 9110 §15.2: a 1xx is interim and cannot be a final response. The
%% single-response handler API cannot express "interim 1xx then final", so
%% a returned 1xx is always a misuse, whatever the response shape; replace
%% it with a buffered 500 rather than put an invalid final 1xx on the wire.
%% Every protocol runs this before sending, so the response it sends,
%% reports to telemetry and decides keep-alive on is the 500. Legitimate
%% interim 100-continue is sent by `send_continue/1`, not this path;
%% a `{websocket, _, _}` upgrade (status 101) is not a handler 1xx.
-doc false.
-spec final_response(h1 | h2 | h3, module(), roadrunner_handler:response()) ->
    roadrunner_handler:response().
final_response(_Protocol, _Handler, {websocket, _, _} = Response) ->
    Response;
final_response(_Protocol, Handler, {websocket, _, _, Headers}) when is_list(Headers) ->
    %% The 0.11 shape: the upgrade options became a map in 0.12. Named in
    %% the log, so the upgrade fails loudly instead of as a bare crash.
    logger:error(#{
        msg => "roadrunner websocket upgrade options must be a map, as #{headers => Headers}",
        handler => Handler
    }),
    {500, [{~"content-type", ~"text/plain"}], ~"Internal Server Error"};
final_response(_Protocol, _Handler, {websocket, _, _, _} = Response) ->
    Response;
final_response(Protocol, Handler, Response) ->
    case response_status(Response) of
        Status when Status >= 100, Status =< 199 ->
            logger:error(#{
                msg => interim_message(Protocol),
                handler => Handler,
                status => Status
            }),
            {500, [{~"content-type", ~"text/plain"}], ~"Internal Server Error"};
        _ ->
            Response
    end.

-spec interim_message(h1 | h2 | h3) -> string().
interim_message(h1) ->
    "roadrunner h1 handler returned an interim 1xx status as a final response";
interim_message(h2) ->
    "roadrunner h2 handler returned an interim 1xx status as a final response";
interim_message(h3) ->
    "roadrunner h3 handler returned an interim 1xx status as a final response".

%% Order matters — `{websocket, _, _}` is a 3-tuple too, so the
%% atom-tagged variants must precede the buffered catch-all.
-doc false.
-spec response_status(roadrunner_handler:response()) -> roadrunner_http:status().
response_status({websocket, _, _, _}) -> 101;
response_status({stream, Status, _, _}) -> Status;
response_status({loop, Status, _, _}) -> Status;
response_status({sendfile, Status, _, _}) -> Status;
response_status({websocket, _, _}) -> 101;
response_status({Status, _, _}) when is_integer(Status) -> Status.

-doc false.
-spec response_kind(roadrunner_handler:response()) ->
    buffered | stream | loop | sendfile | websocket.
response_kind({websocket, _, _, _}) -> websocket;
response_kind({stream, _, _, _}) -> stream;
response_kind({loop, _, _, _}) -> loop;
response_kind({sendfile, _, _, _}) -> sendfile;
response_kind({websocket, _, _}) -> websocket;
%% The status guard keeps `{send, ...}` out: its kind is the response
%% its fun sent, which the dispatch sites report themselves.
response_kind({Status, _, _}) when is_integer(Status) -> buffered.

%% RFC 9110 §9.3.2: a HEAD response carries the same headers the GET
%% would but no content. Collapse the body-bearing shapes (buffered,
%% sendfile) to a header-only response on a HEAD request; the streaming
%% shapes (stream / loop) are left to the handler, matching h1 (which
%% strips only buffered + sendfile). Used by the h2 / h3 workers, which
%% otherwise have no method-aware response step — h1 handles HEAD
%% directly in `dispatch_response/4`.
-doc false.
-spec head_response(roadrunner_handler:response(), binary()) -> roadrunner_handler:response().
head_response({sendfile, Status, Headers, _Spec}, ~"HEAD") ->
    {Status, Headers, <<>>};
head_response({Status, Headers, _Body}, ~"HEAD") when is_integer(Status) ->
    {Status, Headers, <<>>};
head_response(Response, _Method) ->
    Response.

%% HTTP/1.0 default close. HTTP/1.1 keep-alive unless either side
%% set Connection: close.
-doc false.
-spec keep_alive_decision(roadrunner_req:request(), roadrunner_http:headers()) ->
    keep_alive | close.
%% Common-case fast path: HTTP/1.1, parser-cached request `Connection`
%% empty or exactly `keep-alive` (what browsers send; on HTTP/1.1 it
%% carries no `close` token, so it decides the same as empty), response
%% has no `connection` header → `keep_alive` directly. Skips the
%% lowercase + has_token dance (~120 ns for `keep-alive`) entirely.
keep_alive_decision(
    #{
        version := {1, 1},
        cached_decisions := #{connection_lower := ReqConn}
    } = Req,
    RespHeaders
) when is_list(RespHeaders), (ReqConn =:= <<>> orelse ReqConn =:= ~"keep-alive") ->
    case lists:keymember(~"connection", 1, RespHeaders) of
        false -> keep_alive;
        true -> keep_alive_decision_full(Req, RespHeaders)
    end;
keep_alive_decision(Req, RespHeaders) ->
    keep_alive_decision_full(Req, RespHeaders).

-spec keep_alive_decision_full(roadrunner_req:request(), roadrunner_http:headers()) ->
    keep_alive | close.
keep_alive_decision_full(Req, RespHeaders) ->
    ReqConn = req_connection_lower(Req),
    RespConn = roadrunner_bin:ascii_lowercase(resp_connection_token(RespHeaders)),
    Close = ~"close",
    case roadrunner_req:version(Req) of
        {1, 0} ->
            %% RFC 9112 §9.3 + RFC 9110 §7.6.1: HTTP/1.0 default is close, but
            %% `Connection: keep-alive` from client opts in (so long
            %% as the response doesn't force close). `andalso` short-
            %% circuits on the keep-alive check so the response-side
            %% `has_token` only fires when the client opted in.
            case
                has_token(ReqConn, ~"keep-alive") andalso
                    not has_token(RespConn, Close)
            of
                true -> keep_alive;
                false -> close
            end;
        {1, 1} ->
            %% `orelse` short-circuits on ReqClose = true so the
            %% response-side `has_token` only fires when the client
            %% didn't already say `close`.
            case has_token(ReqConn, Close) orelse has_token(RespConn, Close) of
                true -> close;
                false -> keep_alive
            end
    end.

%% Returns the request's `Connection` header value, lowercased. Reads from
%% `cached_decisions` when present (parser populates it once per request)
%% and falls back to a per-call lowercase for manually-built request maps.
-spec req_connection_lower(roadrunner_req:request()) -> binary().
req_connection_lower(#{cached_decisions := #{connection_lower := V}}) ->
    V;
req_connection_lower(Req) ->
    case roadrunner_req:header_normalized(~"connection", Req) of
        undefined -> ~"";
        V -> roadrunner_bin:ascii_lowercase(V)
    end.

-spec resp_connection_token(roadrunner_http:headers()) -> binary().
resp_connection_token(Headers) ->
    case header_value(~"connection", Headers) of
        undefined -> ~"";
        V -> V
    end.

%% RFC 9110 §7.6.1: `Connection` is a comma-separated list of tokens, so
%% match `Token` against each comma-split, OWS-trimmed element, not as a
%% substring (`Connection: enclosed` must not match the `close` token).
%% Two fast paths skip the split/trim/persistent_term for the common
%% values: an empty header (the response side is almost always `<<>>`)
%% has no token, and a single-token value equals the token outright
%% (`Connection: close` / `keep-alive`).
-spec has_token(binary(), binary()) -> boolean().
has_token(<<>>, _Token) ->
    false;
has_token(Token, Token) ->
    true;
has_token(Value, Token) ->
    CommaCp = persistent_term:get(?CONN_COMMA_CP_KEY),
    lists:any(
        fun(Part) -> roadrunner_bin:trim_ows(Part) =:= Token end,
        binary:split(Value, CommaCp, [global])
    ).

-spec init_patterns() -> ok.
init_patterns() ->
    persistent_term:put(?CONN_COMMA_CP_KEY, binary:compile_pattern(~",")),
    ok.

-spec header_value(binary(), roadrunner_http:headers()) -> binary() | undefined.
header_value(Name, Headers) ->
    case lists:keyfind(Name, 1, Headers) of
        {_, V} -> V;
        false -> undefined
    end.

-doc false.
-spec send_bad_request(roadrunner_transport:socket()) -> ok | {error, term()}.
send_bad_request(Socket) ->
    send_status(Socket, 400).

%% Send a bare status line (empty body, `Connection: close`) for a request
%% rejected before any handler runs. Like every framework-built final
%% response below, it carries `Date` (RFC 9110 §6.6.1: MUST on 2xx-4xx),
%% through `roadrunner_http1:response/4` with no `Alt-Svc`.
-doc false.
-spec send_status(roadrunner_transport:socket(), roadrunner_http:status()) ->
    ok | {error, term()}.
send_status(Socket, Status) ->
    Resp = roadrunner_http1:response(
        Status,
        [{~"content-length", ~"0"}, {~"connection", ~"close"}],
        ~"",
        undefined
    ),
    roadrunner_transport:send(Socket, Resp).

%% Map an `roadrunner_http1:parse_request/2` error reason to its HTTP
%% status. Size-limit overruns get the RFC-specific codes (414 URI Too
%% Long per RFC 9110 §15.5.15, 431 Request Header Fields Too Large per
%% RFC 6585 §5), a method the server doesn't implement gets 501 (RFC 9110
%% §15.6.2), an expectation it can't meet gets 417 (RFC 9110 §10.1.1), and
%% every other malformed-input reason is a generic 400. HTTP/2 and HTTP/3
%% answer their requests' 501 and 417 from here too.
-doc false.
-spec parse_error_status(atom()) -> roadrunner_http:status().
parse_error_status(request_line_too_long) -> 414;
parse_error_status(not_implemented) -> 501;
parse_error_status(unsupported_expectation) -> 417;
parse_error_status(header_too_long) -> 431;
parse_error_status(header_block_too_long) -> 431;
parse_error_status(too_many_headers) -> 431;
parse_error_status(_) -> 400.

%% Close gently after a response sent while the client may still be sending
%% its request (RFC 9112 §9.6): closing a socket with unread input makes the
%% kernel send a reset, which can wipe the response from the client before it
%% reads it. So the write side is shut first, telling the client the response
%% is complete, and what still comes is read and dropped until the client
%% closes or `Timeout` ms pass, a bound a client sending on cannot stretch.
%% `0` skips it, for the close to follow at once.
-doc false.
-spec linger(roadrunner_transport:socket(), non_neg_integer()) -> ok.
linger(_Socket, 0) ->
    ok;
linger(Socket, Timeout) ->
    _ = roadrunner_transport:shutdown(Socket, write),
    %% The reads below are passive: a socket armed with `{active, N}`
    %% would fail them at once and close with input still unread.
    _ =
        case erase(?ACTIVE_PDKEY) of
            N when is_integer(N) -> roadrunner_transport:setopts(Socket, [{active, false}]);
            _Passive -> ok
        end,
    linger_until(Socket, erlang:monotonic_time(millisecond) + Timeout).

-spec linger_until(roadrunner_transport:socket(), integer()) -> ok.
linger_until(Socket, Deadline) ->
    case Deadline - erlang:monotonic_time(millisecond) of
        Left when Left > 0 ->
            case roadrunner_transport:recv(Socket, 0, Left) of
                {ok, _Dropped} -> linger_until(Socket, Deadline);
                {error, _} -> ok
            end;
        _ ->
            ok
    end.

-spec send_payload_too_large(roadrunner_transport:socket()) -> ok | {error, term()}.
send_payload_too_large(Socket) ->
    Resp = roadrunner_http1:response(
        413,
        [{~"content-length", ~"0"}, {~"connection", ~"close"}],
        ~"",
        undefined
    ),
    roadrunner_transport:send(Socket, Resp).

%% A `429` (over the per-peer rate) or `503` (shed at the in-flight
%% ceiling) that tells the client when to come back, then closes.
-spec send_retry_later(roadrunner_transport:socket(), 429 | 503, pos_integer()) ->
    ok | {error, term()}.
send_retry_later(Socket, Status, RetryAfterSecs) ->
    Resp = roadrunner_http1:response(
        Status,
        [
            {~"content-length", ~"0"},
            {~"connection", ~"close"},
            {~"retry-after", integer_to_binary(RetryAfterSecs)}
        ],
        ~"",
        undefined
    ),
    roadrunner_transport:send(Socket, Resp).

-doc false.
-spec send_not_found(roadrunner_transport:socket()) -> ok | {error, term()}.
send_not_found(Socket) ->
    Resp = roadrunner_http1:response(
        404,
        [{~"content-length", ~"0"}, {~"connection", ~"close"}],
        ~"",
        undefined
    ),
    roadrunner_transport:send(Socket, Resp).

-doc false.
-spec send_method_not_allowed(roadrunner_transport:socket(), [binary()]) -> ok | {error, term()}.
send_method_not_allowed(Socket, Allowed) ->
    Resp = roadrunner_http1:response(
        405,
        [
            {~"allow", iolist_to_binary(lists:join(~", ", Allowed))},
            {~"content-length", ~"0"},
            {~"connection", ~"close"}
        ],
        ~"",
        undefined
    ),
    roadrunner_transport:send(Socket, Resp).

-doc false.
-spec send_request_timeout(roadrunner_transport:socket()) -> ok | {error, term()}.
send_request_timeout(Socket) ->
    Resp = roadrunner_http1:response(
        408,
        [{~"content-length", ~"0"}, {~"connection", ~"close"}],
        ~"",
        undefined
    ),
    roadrunner_transport:send(Socket, Resp).

-doc false.
-spec send_internal_error(roadrunner_transport:socket()) -> ok | {error, term()}.
send_internal_error(Socket) ->
    Resp = roadrunner_http1:response(
        500,
        [{~"content-length", ~"0"}, {~"connection", ~"close"}],
        ~"",
        undefined
    ),
    roadrunner_transport:send(Socket, Resp).
