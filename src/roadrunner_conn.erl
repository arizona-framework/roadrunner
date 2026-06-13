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
    release_request_slot/2,
    release_request_slots/3,
    consume_body_reader/2,
    join_drain_group/2,
    join_drain_group_for/2
]).
%% Internal helpers shared with `roadrunner_conn_loop`. Marked `-doc false`
%% individually so they stay invisible to the public API surface but
%% are still reachable across the module boundary. They live here
%% (rather than inside the conn-loop module) because the closure-driven
%% unit tests in `roadrunner_conn_tests.erl` exercise the body-state
%% machinery directly through these functions.
-export([
    make_recv/3,
    rate_ok/3,
    body_framing/1,
    generate_request_id/1,
    set_request_logger_metadata/1,
    maybe_send_continue/3,
    refine_conn_label/2,
    scheme/1,
    make_body_reader/5,
    drain_body/1,
    keep_alive_decision/2,
    send_request_timeout/1,
    send_bad_request/1,
    send_status/2,
    parse_error_status/1,
    send_payload_too_large/1,
    send_rate_limited/2,
    rate_limit_check/6,
    resolve_rate_limit/2,
    rate_limited_telemetry/2,
    rate_limit_evict_idle/3,
    drain_oversized_body/3,
    send_internal_error/1,
    send_not_found/1,
    resolve_handler/2,
    response_status/1,
    response_kind/1,
    head_response/2
]).

-export_type([proto_opts/0, dispatch/0, rate_limit/0, rate_limit_state/0]).

-on_load(init_patterns/0).

-define(CONN_COMMA_CP_KEY, {?MODULE, conn_comma_cp}).

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
    request_timeout := non_neg_integer(),
    keep_alive_timeout := non_neg_integer(),
    max_keep_alive_requests := pos_integer(),
    max_clients := pos_integer(),
    client_counter := counters:counters_ref(),
    requests_counter := atomics:atomics_ref(),
    rejected_counter := atomics:atomics_ref(),
    %% Aggregate in-flight ceiling for the multiplexed protocols (h2/h3):
    %% a cap on concurrent live stream-worker processes across the whole
    %% listener, independent of `max_clients` and `max_concurrent_streams`.
    %% `infinity` (default) disables it. `inflight_counter` is the live
    %% gauge (acquired before a worker spawns, released on its `DOWN`);
    %% `throttled_counter` is the cumulative count of streams refused at
    %% the ceiling. h1 is bounded by `max_clients` and does not use these.
    max_concurrent_requests := infinity | pos_integer(),
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
    %% When `false`, conns skip the per-process `pg:join` into
    %% `{roadrunner_drain, ListenerName}`. The drain group is the
    %% mechanism `roadrunner_listener:drain/2` uses to broadcast
    %% `{roadrunner_drain, Deadline}` to in-flight conns; loop /
    %% SSE / WebSocket handlers depend on it. Short-lived h1
    %% workloads can opt out for ~10% lower per-conn overhead.
    graceful_drain => boolean(),
    %% When `true`, `roadrunner_conn_loop:awaiting_shoot/3` reads and strips a
    %% PROXY-protocol header (an L4 balancer prepends it) before serving, and
    %% the request peer is the real client. TCP-only; the listener rejects it on
    %% an HTTP/3-only listener.
    proxy_protocol => boolean(),
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
    %% HTTP/3 tuning, flattened from `{http3, #{...}}` when http3 is enabled.
    http3_listeners => 1..1024,
    http3_max_header_block => 1..16#7FFFFFFF,
    %% HTTP/1 inbound size limits, flattened from `{http1, #{...}}`.
    http1_max_request_line => 1..16#7FFFFFFF,
    http1_max_header_line => 1..16#7FFFFFFF,
    http1_max_header_block => 1..16#7FFFFFFF,
    http1_max_header_count => 1..16#7FFFFFFF,
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
%% bucket capacity, and an `idle_ttl`/`sweep_interval` (ms) eviction policy for
%% the ETS `table` holding each peer's bucket. The cumulative refusal count
%% lives in the top-level `rate_limited_counter`.
-type rate_limit() :: #{
    rate := pos_integer(),
    burst := pos_integer(),
    period := pos_integer(),
    idle_ttl := pos_integer(),
    sweep_interval := pos_integer(),
    table := ets:table()
}.

%% The per-connection rate-limit guard state cached on each conn loop's record:
%% the `{Rate, Burst, Period, Table, Counter, IP}` resolved from `proto_opts` +
%% the peer once at setup (see `resolve_rate_limit/2`), or `undefined` when the
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
Join the per-listener `pg` group so `roadrunner_listener:drain/2` can
broadcast a `{roadrunner_drain, Deadline}` notification to the calling
process. `pg` removes the caller automatically when the process
exits. The `pg` scope is started by `roadrunner_sup`; in tests that
drive `roadrunner_listener:start_link/2` directly without starting the
application, the scope is absent and the join is silently skipped
— drain will simply not see those conns.

Called by `roadrunner_conn_loop:init_loop/3` after the conn process
starts but before it accepts any work.
""".
-spec join_drain_group(atom(), boolean()) -> ok.
join_drain_group(_Name, false) ->
    ok;
join_drain_group(undefined, _) ->
    ok;
join_drain_group(Name, true) ->
    case whereis(pg) of
        undefined -> ok;
        _ -> pg:join({roadrunner_drain, Name}, self())
    end.

-doc """
Join `Pid` into the per-listener `pg` drain group on behalf of another
process. Reserved for future use cases where a non-conn process needs
direct drain membership (e.g., a long-lived worker spawned outside
the conn lifecycle). The WS upgrade path no longer calls this: the
conn (already in pg) forwards `{roadrunner_drain, _}` to its session
from `roadrunner_ws_session:wait_for_session/2` instead.

Silently no-ops when `Name` is `undefined` (manually constructed
requests in tests) or when the `pg` scope is absent (listener
started without the supervision tree).
""".
-spec join_drain_group_for(pid(), atom()) -> ok.
join_drain_group_for(_Pid, undefined) ->
    ok;
join_drain_group_for(Pid, Name) when is_pid(Pid), is_atom(Name) ->
    case whereis(pg) of
        undefined -> ok;
        _ -> pg:join({roadrunner_drain, Name}, Pid)
    end.

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
leaks become a real concern under chaos-test conditions, add a
periodic reaper that compares `pg:get_members({roadrunner_drain, _})`
against the live counter and reconciles the difference.
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
-spec release_slot(proto_opts()) -> ok.
release_slot(#{client_counter := Ref}) ->
    ok = counters:sub(Ref, 1, 1),
    ok.

-doc """
Try to bump the live in-flight-request counter under
`max_concurrent_requests`. Returns `true` if a worker may be spawned,
`false` if the listener is already at the ceiling (caller must refuse the
stream). `infinity` short-circuits to `true` with no counter touch, so an
unconfigured listener pays nothing on the hot path.

Same eventually-consistent overshoot contract as `try_acquire_slot/1`: the
`counters` ref uses `write_concurrency`, so a brief read slightly above the
cap is possible before rollbacks reconcile, bounded by in-flight admissions.
Paired with `release_request_slot/2`, which must run exactly once per
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
    #{
        rate_limit := #{rate := Rate, burst := Burst, period := Period, table := Table},
        rate_limited_counter := Counter
    },
    {IP, _Port}
) ->
    {Rate, Burst, Period, Table, Counter, IP};
resolve_rate_limit(_ProtoOpts, _Peer) ->
    undefined.

-doc """
Per-peer token-bucket check, the per-source sibling of
`try_acquire_request_slot/2`. Reads the peer `IP`'s bucket from the listener's
ETS `Table` (a never-seen peer starts full), refills it for the elapsed time,
and tries to spend one request. `allow` on success, `{deny, RetryAfterSecs}`
when the bucket is empty. The read-refill-write is last-write-wins: concurrent
connections from one IP can overshoot the bucket by a bounded amount, the same
contract `try_acquire_request_slot/2` documents.

`NowMs` is `erlang:monotonic_time(millisecond)` (passed in so the bucket math is
deterministically testable).
""".
-spec rate_limit_check(
    ets:table(), inet:ip_address(), pos_integer(), pos_integer(), pos_integer(), integer()
) ->
    allow | {deny, pos_integer()}.
rate_limit_check(Table, IP, Rate, Burst, Period, NowMs) ->
    %% `Rate` requests per `Period` seconds: one request costs `Cost` units,
    %% the bucket holds up to `Cap` (see `roadrunner_rate_limit`).
    Cost = Period * 1000,
    Cap = Burst * Cost,
    {Units0, LastMs} =
        case ets:lookup(Table, IP) of
            [{IP, U, L}] -> {U, L};
            %% First request from this peer: a full bucket.
            [] -> {Cap, NowMs}
        end,
    Refilled = roadrunner_rate_limit:refill(Units0, LastMs, NowMs, Rate, Cap),
    case roadrunner_rate_limit:spend(Refilled, Cost) of
        {ok, Remaining} ->
            true = ets:insert(Table, {IP, Remaining, NowMs}),
            allow;
        denied ->
            true = ets:insert(Table, {IP, Refilled, NowMs}),
            {deny, roadrunner_rate_limit:retry_after_secs(Refilled, Rate, Cost)}
    end.

-doc "Record a rate-limit refusal: bump the cumulative counter and emit telemetry.".
-spec rate_limited_telemetry(atom(), atomics:atomics_ref()) -> ok.
rate_limited_telemetry(ListenerName, Counter) ->
    ok = atomics:add(Counter, 1, 1),
    roadrunner_telemetry:request_throttled(#{
        listener_name => ListenerName,
        reason => rate_limit
    }).

-doc """
Evict every per-peer bucket idle since before `NowMs - IdleTtl`, in one
`select_delete` pass, returning the number evicted. A single pass (rather than a
per-tick row budget) is what actually bounds the store to the active-peer set: a
budget would cap eviction below the rate new buckets are created under a
high-cardinality scan, letting the table grow without limit. The pass runs on
the listener gen_server (control plane, off the request path), so a full
traversal every sweep tick is cheap.
""".
-spec rate_limit_evict_idle(ets:table(), integer(), pos_integer()) -> non_neg_integer().
rate_limit_evict_idle(Table, NowMs, IdleTtl) ->
    Cutoff = NowMs - IdleTtl,
    %% Row is `{IP, Units, LastMs}`; delete those last touched before `Cutoff`.
    Spec = [{{'_', '_', '$1'}, [{'<', '$1', Cutoff}], [true]}],
    ets:select_delete(Table, Spec).

-doc "Decrement the in-flight-request counter, paired with `try_acquire_request_slot/2`.".
-spec release_request_slot(infinity | pos_integer(), counters:counters_ref() | undefined) -> ok.
release_request_slot(infinity, _Counter) ->
    ok;
release_request_slot(_Max, Counter) ->
    ok = counters:sub(Counter, 1, 1),
    ok.

-doc """
Release `N` in-flight slots at once. Used by the conn clean-exit path to
account for stream workers still live at teardown (each held one slot), so
their slots are not leaked until the listener restarts. `N = 0` and
`infinity` are no-ops.
""".
-spec release_request_slots(
    infinity | pos_integer(), counters:counters_ref() | undefined, non_neg_integer()
) -> ok.
release_request_slots(_Max, _Counter, 0) ->
    ok;
release_request_slots(infinity, _Counter, _N) ->
    ok;
release_request_slots(_Max, Counter, N) ->
    ok = counters:sub(Counter, 1, N),
    ok.

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
%% `/1` accepts a per-conn buffer of pre-generated random bytes and
%% returns `{RequestId, NewBuffer}` — caller threads the buffer
%% through its own state. The conn_loop variant uses this to amortize
%% the CSPRNG NIF call: one `crypto:strong_rand_bytes/1` per ~32
%% requests instead of one per request. Each 8-byte slice still
%% carries a full 64 bits of independent entropy — the batch boundary
%% doesn't reduce randomness.

-define(REQ_ID_BATCH_BYTES, 256).

-doc false.
-spec generate_request_id(binary()) -> {binary(), binary()}.
generate_request_id(<<Slice:8/binary, Rest/binary>>) ->
    {binary:encode_hex(Slice, lowercase), Rest};
generate_request_id(_Empty) ->
    %% Buffer drained (or never initialized) — refill with one NIF call.
    <<Slice:8/binary, Rest/binary>> = crypto:strong_rand_bytes(?REQ_ID_BATCH_BYTES),
    {binary:encode_hex(Slice, lowercase), Rest}.

%% Replaces (not merges) the conn process's logger metadata so a
%% keep-alive request never inherits the previous request's correlation.
-doc false.
-spec set_request_logger_metadata(roadrunner_req:request()) -> ok.
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

%% Build a recv closure with a single overall deadline plus a rolling
%% rate check. `gen_tcp:recv` with a negative timeout is undefined, so
%% we cap at 0 — which makes gen_tcp return `{error, timeout}`
%% immediately when the deadline has passed. Any timeout here is, by
%% construction, the request_timeout.
%%
%% Rate enforcement (anti-Slowloris): track total bytes received and
%% time since the first recv. After a 1-second grace, require the
%% running average to meet `MinRate` bytes/sec, otherwise return
%% `{error, slow_client}`. The state is a per-conn atomics ref — no
%% cross-process contention.
-doc false.
-spec make_recv(roadrunner_transport:socket(), integer(), non_neg_integer()) ->
    fun(() -> {ok, binary()} | {error, request_timeout | slow_client | term()}).
make_recv(Socket, Deadline, MinRate) ->
    Bytes = atomics:new(1, [{signed, false}]),
    Start = erlang:monotonic_time(millisecond),
    fun() ->
        Now = erlang:monotonic_time(millisecond),
        Remaining = max(0, Deadline - Now),
        case roadrunner_transport:recv(Socket, 0, Remaining) of
            {ok, Data} ->
                Total = atomics:add_get(Bytes, 1, byte_size(Data)),
                case rate_ok(Now - Start, Total, MinRate) of
                    true -> {ok, Data};
                    false -> {error, slow_client}
                end;
            {error, timeout} ->
                {error, request_timeout};
            {error, _} = E ->
                E
        end
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

-doc false.
-spec scheme(roadrunner_transport:socket()) -> http | https.
scheme({gen_tcp, _}) -> http;
scheme({ssl, _}) -> https;
scheme({fake, _}) -> http.

-doc false.
-spec resolve_handler(dispatch(), roadrunner_req:request()) ->
    {ok, module(), roadrunner_router:bindings(), roadrunner_middleware:next(), term()}
    | not_found.
resolve_handler({handler, Mod, Pipeline, State}, _Req) ->
    {ok, Mod, #{}, Pipeline, State};
resolve_handler({router, ListenerName}, Req) ->
    %% Routes are stored in `persistent_term` by `roadrunner_listener` so
    %% the lookup is O(1) and `roadrunner_listener:reload_routes/2` can
    %% atomically swap the table without bouncing the listener.
    Compiled = persistent_term:get({roadrunner_routes, ListenerName}),
    roadrunner_router:match(roadrunner_req:path(Req), Compiled).

-doc false.
-spec read_body(
    roadrunner_req:request(),
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
read_body(Req, Buffered, RecvFun, MaxCL, TrailerLimits) ->
    case body_framing(Req) of
        none ->
            %% Per RFC 9112 §6.3: a request without `Content-Length`
            %% or `Transfer-Encoding` has a zero-length message body.
            %% Any leftover bytes in `Buffered` belong to a pipelined
            %% next request — preserve them as `Leftover` so the conn
            %% can feed them into the next `reading_request` parse.
            {ok, <<>>, Buffered};
        chunked ->
            read_chunked(Buffered, RecvFun, MaxCL, 0, TrailerLimits);
        {content_length, N} when N > MaxCL ->
            {error, content_length_too_large};
        {content_length, N} ->
            read_body_until(N, Buffered, RecvFun);
        {error, _} = Err ->
            Err
    end.

%% RFC 9110 §10.1.1: when a request carries `Expect: 100-continue` and
%% we're about to read a body, send `HTTP/1.1 100 Continue` so clients
%% that gate body transmission on this signal don't stall. We only do
%% this if no body bytes have already arrived in the buffer — once we
%% see body data the client clearly didn't wait, and the 100 line is
%% redundant.
-doc false.
-spec maybe_send_continue(roadrunner_transport:socket(), roadrunner_req:request(), binary()) ->
    ok.
maybe_send_continue(Socket, Req, Buffered) ->
    case Buffered =:= ~"" andalso has_continue_expectation(Req) of
        true ->
            _ = roadrunner_transport:send(Socket, ~"HTTP/1.1 100 Continue\r\n\r\n"),
            ok;
        false ->
            ok
    end.

-spec has_continue_expectation(roadrunner_req:request()) -> boolean().
has_continue_expectation(#{cached_decisions := #{expects_continue := EC}}) ->
    EC;
has_continue_expectation(Req) ->
    %% Manually-built request maps (tests, middleware) skip the parse-time
    %% precompute — fall back to the lowercase-and-compare path.
    case roadrunner_req:header(~"expect", Req) of
        undefined -> false;
        Value -> roadrunner_bin:ascii_lowercase(Value) =:= ~"100-continue"
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
    case roadrunner_req:header(~"transfer-encoding", Req) of
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
    non_neg_integer(),
    {pos_integer(), pos_integer(), pos_integer()}
) ->
    {ok, binary(), binary()} | {error, content_length_too_large | term()}.
read_chunked(Buf, RecvFun, MaxCL, Decoded, TrailerLimits) ->
    %% `parse_chunk/3` rejects a declared chunk size over the remaining
    %% budget on its size line, so an oversized chunk can't buffer past
    %% the cap before this loop sees it.
    case roadrunner_http1:parse_chunk(Buf, TrailerLimits, MaxCL - Decoded) of
        {ok, last, _Trailers, Leftover} ->
            %% Bytes after the size-0 last-chunk + trailer block are
            %% pipelined-next-request leftover; thread them up so the
            %% conn can feed them into the next parse.
            {ok, <<>>, Leftover};
        {ok, Data, Rest} ->
            NewDecoded = Decoded + byte_size(Data),
            case read_chunked(Rest, RecvFun, MaxCL, NewDecoded, TrailerLimits) of
                {ok, More, Leftover} ->
                    {ok, <<Data/binary, More/binary>>, Leftover};
                {error, _} = E ->
                    E
            end;
        {more, _} ->
            case RecvFun() of
                {ok, More} ->
                    read_chunked(
                        <<Buf/binary, More/binary>>, RecvFun, MaxCL, Decoded, TrailerLimits
                    );
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

%% Read and discard whatever the handler left in the manual-mode
%% `body_reader`, returning any post-body leftover bytes that belong
%% to a pipelined next request. Called only on the 4-tuple response
%% path; `roadrunner_conn_loop`'s finishing phase threads `Leftover`
%% forward into the next `reading_request` parse so pipelined
%% clients get their N+1 request seen.
-doc false.
-spec drain_body(roadrunner_req:request()) -> {ok, binary()} | {error, term()}.
drain_body(#{body_reader := BS}) ->
    case consume_body_reader(BS, all) of
        {ok, _Bytes, #{buffered := Leftover}} -> {ok, Leftover};
        {error, _} = E -> E
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
consume_body_reader(#{framing := none} = BS, _Mode) ->
    %% Per RFC 9112 §6.3: no framing means the body is empty.
    %% Any `buffered` bytes are pipelined-next-request leftovers —
    %% preserve them in the body_reader's `buffered` field so
    %% `roadrunner_conn_loop`'s finishing phase can thread them into
    %% the next `reading_request` parse for full pipelining support.
    {ok, <<>>, BS};
consume_body_reader(
    #{framing := {content_length, N}, bytes_read := Read} = BS, _Mode
) when Read >= N ->
    {ok, <<>>, BS};
consume_body_reader(
    #{
        framing := {content_length, N},
        bytes_read := Read,
        buffered := Buf,
        recv := Recv,
        max := Max
    } = BS,
    Mode
) ->
    Remaining = N - Read,
    Want =
        case Mode of
            all -> Remaining;
            next_chunk -> Remaining;
            {length, L} -> min(Remaining, L)
        end,
    case Want > Max of
        true ->
            {error, content_length_too_large};
        false ->
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
            end
    end;
consume_body_reader(#{framing := chunked} = BS, all) ->
    %% Drain everything left: any pending decoded bytes plus all
    %% remaining chunks, accumulated in one return. Iodata stays unflattened
    %% so callers that only need `iolist_size/1` or want to forward via
    %% `gen_tcp:send/2` skip a flatten.
    chunked_collect(BS, infinity);
consume_body_reader(#{framing := chunked} = BS, {length, N}) ->
    chunked_collect(BS, N);
consume_body_reader(#{framing := chunked} = BS, next_chunk) ->
    next_chunk(BS).
%% Non-chunked framing (none, content_length) is handled by the
%% earlier clauses above — `next_chunk` is treated as a full drain
%% inside those, since there are no chunk boundaries to honor.

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
                    chunked_collect(BS#{buffered := <<Buf/binary, More/binary>>}, Want);
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
                    next_chunk(BS#{buffered := <<Buf/binary, More/binary>>});
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
    case roadrunner_req:header(~"content-length", Req) of
        undefined ->
            none;
        Bin ->
            try binary_to_integer(Bin) of
                N when N >= 0 -> {ok, N};
                _ -> {error, bad_content_length}
            catch
                _:_ -> {error, bad_content_length}
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
                {ok, Data} -> parse_loop(<<Buf/binary, Data/binary>>, RecvFun);
                {error, _} = E -> E
            end;
        {error, _} = E ->
            E
    end.

%% Order matters — `{websocket, _, _}` is a 3-tuple too, so the
%% atom-tagged variants must precede the buffered catch-all.
-doc false.
-spec response_status(roadrunner_handler:response()) -> roadrunner_http:status().
response_status({stream, Status, _, _}) -> Status;
response_status({loop, Status, _, _}) -> Status;
response_status({sendfile, Status, _, _}) -> Status;
response_status({websocket, _, _}) -> 101;
response_status({Status, _, _}) when is_integer(Status) -> Status.

-doc false.
-spec response_kind(roadrunner_handler:response()) ->
    buffered | stream | loop | sendfile | websocket.
response_kind({stream, _, _, _}) -> stream;
response_kind({loop, _, _, _}) -> loop;
response_kind({sendfile, _, _, _}) -> sendfile;
response_kind({websocket, _, _}) -> websocket;
response_kind({_, _, _}) -> buffered.

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
%% empty, response has no `connection` header → `keep_alive` directly.
%% Skips the lowercase + has_token dance entirely. Most production
%% hello/echo responses hit this path.
keep_alive_decision(
    #{
        version := {1, 1},
        cached_decisions := #{connection_lower := <<>>}
    } = Req,
    RespHeaders
) when is_list(RespHeaders) ->
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
    case roadrunner_req:header(~"connection", Req) of
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
%% rejected before any handler runs.
-doc false.
-spec send_status(roadrunner_transport:socket(), roadrunner_http:status()) ->
    ok | {error, term()}.
send_status(Socket, Status) ->
    Resp = roadrunner_http1:response(
        Status,
        [{~"content-length", ~"0"}, {~"connection", ~"close"}],
        ~""
    ),
    roadrunner_transport:send(Socket, Resp).

%% Map an `roadrunner_http1:parse_request/2` error reason to its HTTP
%% status. Size-limit overruns get the RFC-specific codes (414 URI Too
%% Long per RFC 9110 §15.5.15, 431 Request Header Fields Too Large per
%% RFC 6585 §5); every other malformed-input reason is a generic 400.
-doc false.
-spec parse_error_status(atom()) -> roadrunner_http:status().
parse_error_status(request_line_too_long) -> 414;
parse_error_status(header_too_long) -> 431;
parse_error_status(header_block_too_long) -> 431;
parse_error_status(too_many_headers) -> 431;
parse_error_status(_) -> 400.

%% Drain up to `2 * MaxCL` bytes from the socket (counting the
%% already-buffered bytes), discarding them. Used to flush an
%% oversized in-flight body off the wire so the peer can read the
%% 413 we're about to send before we close. Bounded by `2 * MaxCL`
%% (memory) and a 1-second per-recv timeout (wall-clock) so a slow
%% peer can't pin us indefinitely.
-doc false.
-spec drain_oversized_body(binary(), roadrunner_transport:socket(), non_neg_integer()) -> ok.
drain_oversized_body(Buffered, Socket, MaxCL) ->
    Cap = 2 * MaxCL,
    drain_oversized_loop(Socket, byte_size(Buffered), Cap).

-spec drain_oversized_loop(
    roadrunner_transport:socket(), non_neg_integer(), non_neg_integer()
) -> ok.
drain_oversized_loop(_Socket, Read, Cap) when Read >= Cap ->
    ok;
drain_oversized_loop(Socket, Read, Cap) ->
    case roadrunner_transport:recv(Socket, 0, 1000) of
        {ok, Data} ->
            drain_oversized_loop(Socket, Read + byte_size(Data), Cap);
        {error, _} ->
            ok
    end.

-spec send_payload_too_large(roadrunner_transport:socket()) -> ok | {error, term()}.
send_payload_too_large(Socket) ->
    Resp = roadrunner_http1:response(
        413,
        [{~"content-length", ~"0"}, {~"connection", ~"close"}],
        ~""
    ),
    roadrunner_transport:send(Socket, Resp).

-spec send_rate_limited(roadrunner_transport:socket(), pos_integer()) -> ok | {error, term()}.
send_rate_limited(Socket, RetryAfterSecs) ->
    Resp = roadrunner_http1:response(
        429,
        [
            {~"content-length", ~"0"},
            {~"connection", ~"close"},
            {~"retry-after", integer_to_binary(RetryAfterSecs)}
        ],
        ~""
    ),
    roadrunner_transport:send(Socket, Resp).

-doc false.
-spec send_not_found(roadrunner_transport:socket()) -> ok | {error, term()}.
send_not_found(Socket) ->
    Resp = roadrunner_http1:response(
        404,
        [{~"content-length", ~"0"}, {~"connection", ~"close"}],
        ~""
    ),
    roadrunner_transport:send(Socket, Resp).

-doc false.
-spec send_request_timeout(roadrunner_transport:socket()) -> ok | {error, term()}.
send_request_timeout(Socket) ->
    Resp = roadrunner_http1:response(
        408,
        [{~"content-length", ~"0"}, {~"connection", ~"close"}],
        ~""
    ),
    roadrunner_transport:send(Socket, Resp).

-doc false.
-spec send_internal_error(roadrunner_transport:socket()) -> ok | {error, term()}.
send_internal_error(Socket) ->
    Resp = roadrunner_http1:response(
        500,
        [{~"content-length", ~"0"}, {~"connection", ~"close"}],
        ~""
    ),
    roadrunner_transport:send(Socket, Resp).
