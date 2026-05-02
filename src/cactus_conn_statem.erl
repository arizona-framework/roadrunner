-module(cactus_conn_statem).
-moduledoc """
HTTP/1.1 connection state machine — the per-connection process
spawned by `cactus_conn:start/2`. Replaces the hand-rolled
`proc_lib` recursion that lived in `cactus_conn` before Phase 7 of
the migration.

`callback_mode/0` is `[handle_event_function, state_enter]` — every
event funnels through `handle_event/4`, which lets the
`{cactus_drain, _}` info event match a single wildcard-state clause
without duplicating the handler in every named state.

## States

- `awaiting_shoot` — gates the lifecycle until the acceptor's
  `shoot` message arrives. `cactus_acceptor:handle_accepted/2`
  spawns this gen_statem, transfers controlling-process, then sends
  `ConnPid ! shoot` (raw bang) — we receive it as an info event.
- `reading_request` — runs in **active-once** mode
  (`cactus_transport:setopts(_, [{active, once}])`). Inbound bytes
  arrive as `info` events; the gen_statem returns to its main loop
  between events, which lets `{hibernate_after, _}` actually fire
  during keep-alive idle waits between pipelined requests. The
  request-timeout deadline is enforced via `state_timeout` and
  the anti-Slowloris rate check via `{generic_timeout,
  rate_check}`. Drain messages arriving in this state stop the
  conn immediately (no need to finish parsing a request that won't
  be served).
- `reading_body` — calls `cactus_conn:read_body/4` (auto mode) or
  installs a `cactus_conn:make_body_state/4` body state (manual
  mode), then transitions to `dispatching`. Body reads still use
  the synchronous `cactus_conn:make_recv/3` closure; the deadline
  passed to it is the same `read_deadline` set in `reading_request`
  so the request-timeout covers both phases.

  **Why mixed (active for headers, sync for body)?** Hibernation
  only fires when the gen_statem's main loop is idle. Between
  pipelined requests on a keep-alive conn, the gen_statem sits
  in `reading_request` waiting for bytes — that's the high-value
  hibernation window (most idle WebSocket / HTTP/1.1 keep-alive
  workloads). Once a request has been parsed, the conn proceeds
  through `reading_body → dispatching` synchronously; the handler
  blocks gen_statem anyway during dispatching, so making
  `reading_body` event-driven would gain nothing for hibernation
  and would significantly widen the refactor (manual-mode
  handlers call `cactus_req:read_body/1,2` synchronously, which
  would need a parallel async API). The mixed design is a
  deliberate cost/benefit trade — keep the simple synchronous
  body read; pay the active-mode complexity only where it
  unlocks hibernation.
- `dispatching` — runs the middleware/handler pipeline, dispatches
  the response (buffered / stream / loop / sendfile / websocket),
  fires `[cactus, request, start | stop | exception]` telemetry,
  bumps `requests_served`, transitions to `finishing`.
- `finishing` — drains any unread manual-mode body and decides
  keep-alive vs close. Buffered responses can loop back to
  `reading_request` (capped by `max_keep_alive_request`); stream /
  loop / sendfile / websocket all force close.

## Telemetry contract

- `[cactus, listener, accept]` — fired in the `shoot` handler once
  the peer is known.
- `[cactus, listener, conn_close]` — fired from `terminate/3`
  paired with the accept's `StartMono`. Skipped when termination
  happens before `shoot` (no matching accept event was emitted).
- `[cactus, request, start | stop | exception]` — fired from the
  dispatching pipeline.
- `[cactus, response, send_failed]` — bubbles up via
  `cactus_telemetry:response_send/2` from each socket write.
- `[cactus, ws, upgrade | frame_in | frame_out]` — fired by
  `cactus_ws_session` once dispatching delegates to it.
""".

-behaviour(gen_statem).

-export([start/2]).
-export([init/1, callback_mode/0, terminate/3]).
-export([handle_event/4]).

-record(data, {
    socket :: cactus_transport:socket(),
    proto_opts :: cactus_conn:proto_opts(),
    listener_name :: atom(),
    %% Captured by the `shoot` handler (once peer is known) and paired
    %% with the `[cactus, listener, conn_close]` event in `terminate/3`.
    start_mono :: integer() | undefined,
    %% Peer is unknown until after the socket transfer; populated by
    %% the `shoot` handler (which also fires the `accept` telemetry).
    peer :: {inet:ip_address(), inet:port_number()} | undefined,
    scheme = http :: http | https,
    %% First request on a fresh conn vs subsequent keep-alive requests
    %% — drives the timeout (request_timeout vs keep_alive_timeout) and
    %% silent-vs-408 behavior in `reading_request`.
    phase = first :: first | keep_alive,
    %% Per-request scratch carried from `reading_request` into
    %% `reading_body`: the parsed request map and any post-headers
    %% bytes already buffered on the wire.
    req :: cactus_http1:request() | undefined,
    buffered = <<>> :: binary(),
    recv :: fun(() -> {ok, binary()} | {error, term()}) | undefined,
    %% `reading_request` runs in active-mode (`setopts({active, once})`)
    %% so the gen_statem returns to its main loop between events and
    %% `{hibernate_after, _}` can fire during keep-alive idle waits.
    %% These three fields track the request-timeout deadline + the
    %% rate-check accumulator that used to live inside the synchronous
    %% recv closure.
    read_deadline :: integer() | undefined,
    read_start_mono :: integer() | undefined,
    read_bytes_total = 0 :: non_neg_integer(),
    %% Set by `dispatching`'s pipeline once the handler returns;
    %% consumed by `finishing` for the keep-alive / close decision.
    response :: cactus_handler:response() | undefined,
    %% Cumulative successfully-served requests on this conn —
    %% incremented as `dispatching` lands a response.
    requests_served = 0 :: non_neg_integer(),
    %% `cactus_listener:drain/2` broadcasts `{cactus_drain, Deadline}`
    %% via the `pg` group; the gen_statem handles it as an info event
    %% in any state and stashes a flag, which `reading_request` reads
    %% before parsing the next request.
    drain_received = false :: boolean()
}).

-doc """
Spawn an unlinked gen_statem for the accepted `Socket` and the
shared `ProtoOpts`. Mirrors `cactus_conn:start/2` exactly so the
acceptor's existing handoff dance (`controlling_process` then
`! shoot`) works without modification.

`gen_statem:start/3` (not `start_link/3`) — the conn is
intentionally unlinked from the acceptor so a single-conn crash
never propagates to the acceptor pool.
""".
-spec start(cactus_transport:socket(), cactus_conn:proto_opts()) ->
    {ok, pid()} | {error, term()}.
start(Socket, ProtoOpts) ->
    gen_statem:start(?MODULE, {Socket, ProtoOpts}, start_opts(ProtoOpts)).

-spec start_opts(cactus_conn:proto_opts()) -> [gen_statem:start_opt()].
start_opts(ProtoOpts) ->
    case maps:find(hibernate_after, ProtoOpts) of
        {ok, Ms} when is_integer(Ms), Ms > 0 ->
            [{hibernate_after, Ms}];
        _ ->
            []
    end.

-spec callback_mode() -> gen_statem:callback_mode_result().
callback_mode() -> [handle_event_function, state_enter].

-spec init({cactus_transport:socket(), cactus_conn:proto_opts()}) ->
    {ok, awaiting_shoot, #data{}}.
init({Socket, ProtoOpts}) ->
    ListenerName = maps:get(listener_name, ProtoOpts, undefined),
    proc_lib:set_label({cactus_conn, ListenerName}),
    ok = cactus_conn:join_drain_group(ListenerName),
    %% Listener-accept telemetry fires from the `shoot` handler once
    %% the peer is known (socket ownership has been transferred). The
    %% StartMono captured there is paired with `listener_conn_close`
    %% in `terminate/3` so the duration measures the conn's full
    %% lifetime past the acceptor handoff.
    {ok, awaiting_shoot, #data{
        socket = Socket,
        proto_opts = ProtoOpts,
        listener_name = ListenerName
    }}.

%% --- Single event handler covering every state. ---

-spec handle_event(gen_statem:event_type(), term(), atom(), #data{}) ->
    gen_statem:event_handler_result(atom()).

%% Drain message handling.
%%
%% In `reading_request` we're idle waiting for the next request bytes
%% — there's no in-flight work to preserve, so stop immediately when
%% drain arrives. In every other state we stash the flag; the next
%% reading_request iteration's state_enter sees it and stops there
%% (after the current request finishes).
handle_event(info, {cactus_drain, _Deadline}, reading_request, Data) ->
    {stop, normal, Data};
handle_event(info, {cactus_drain, _Deadline}, _State, Data) ->
    {keep_state, Data#data{drain_received = true}};
%% --- awaiting_shoot ---
handle_event(enter, _Old, awaiting_shoot, _Data) ->
    keep_state_and_data;
handle_event(
    info,
    shoot,
    awaiting_shoot,
    #data{
        socket = Socket, proto_opts = ProtoOpts, listener_name = ListenerName
    } = Data
) ->
    %% Socket ownership has just transferred from the acceptor — refine
    %% the proc_lib label with the peer (which we couldn't know in
    %% init/1 because the OS-level socket wasn't ours yet).
    Peer = cactus_conn:peer(Socket),
    ok = cactus_conn:refine_conn_label(ProtoOpts, Peer),
    Scheme = cactus_conn:scheme(Socket),
    StartMono = cactus_telemetry:listener_accept(#{
        listener_name => ListenerName, peer => Peer
    }),
    {next_state, reading_request, Data#data{
        peer = Peer, scheme = Scheme, start_mono = StartMono
    }};
%% --- reading_request (active-mode) ---
handle_event(enter, _Old, reading_request, #data{drain_received = true} = Data) ->
    %% Drain stashed during dispatching/finishing — bail before
    %% serving another request.
    {stop, normal, Data};
handle_event(
    enter,
    _Old,
    reading_request,
    #data{
        socket = Socket,
        phase = Phase,
        proto_opts = ProtoOpts,
        buffered = Buf
    } = Data0
) ->
    %% Buffered is `<<>>` on the first entry from `awaiting_shoot`
    %% and on keep-alive loop-backs that didn't pipeline. If a prior
    %% request's `read_body` / `drain_body` left post-body bytes
    %% (RFC 7230 §6.3 pipelining), `Buf` arrives non-empty and we
    %% parse it immediately via a state_timeout 0 instead of waiting
    %% on the next `{tcp, _, _}` info event.
    Timeout = request_timeout(Phase, ProtoOpts),
    Now = erlang:monotonic_time(millisecond),
    Data = Data0#data{
        read_deadline = Now + Timeout,
        read_start_mono = Now,
        read_bytes_total = byte_size(Buf)
    },
    case Buf of
        <<>> ->
            arm_or_stop(Socket, Data, reading_request_timeouts(Timeout, ProtoOpts));
        _ ->
            %% Use a generic_timeout (named) so it coexists with the
            %% `state_timeout` for `request_deadline`. gen_statem
            %% allows only one `state_timeout` per state — a second
            %% one in the same actions list silently replaces the
            %% first.
            {keep_state, Data, [
                {{timeout, parse_pipelined}, 0, parse_pipelined}
                | reading_request_timeouts(Timeout, ProtoOpts)
            ]}
    end;
handle_event({timeout, parse_pipelined}, parse_pipelined, reading_request, Data) ->
    parse_buffered_request(Data);
handle_event(
    state_timeout,
    request_deadline,
    reading_request,
    #data{
        socket = Socket, phase = Phase
    } = Data
) ->
    _ = maybe_send_request_timeout(Socket, Phase),
    {stop, normal, Data};
handle_event(
    {timeout, rate_check},
    rate_check,
    reading_request,
    #data{proto_opts = ProtoOpts} = Data
) ->
    MinRate = maps:get(minimum_bytes_per_second, ProtoOpts),
    Elapsed = erlang:monotonic_time(millisecond) - Data#data.read_start_mono,
    Interval = rate_check_interval(ProtoOpts),
    case rate_ok(Elapsed, Data#data.read_bytes_total, MinRate) of
        true ->
            {keep_state, Data, [{{timeout, rate_check}, Interval, rate_check}]};
        false ->
            %% Slow client — silent close, no 4xx (peer wasn't reading
            %% reliably anyway).
            {stop, normal, Data}
    end;
handle_event(info, Msg, reading_request, #data{socket = Socket} = Data) ->
    {DataTag, ClosedTag, ErrorTag} = cactus_transport:messages(Socket),
    %% `_Sock` discarded — one socket per conn (captured in
    %% `#data.socket` at init/shoot). The match on the dynamic tag
    %% atoms is sufficient; if we ever multiplex sockets per conn,
    %% bind `Sock = element(2, Socket)` and match it here.
    case Msg of
        {DataTag, _Sock, Bytes} ->
            handle_request_bytes(Bytes, Data);
        {ClosedTag, _Sock} ->
            {stop, normal, Data};
        {ErrorTag, _Sock, _Reason} ->
            {stop, normal, Data};
        _Other ->
            arm_or_stop(Socket, Data, [])
    end;
%% --- reading_body ---
handle_event(enter, _Old, reading_body, _Data) ->
    {keep_state_and_data, [{state_timeout, 0, read}]};
handle_event(
    state_timeout,
    read,
    reading_body,
    #data{
        socket = Socket,
        proto_opts = ProtoOpts,
        req = Req,
        buffered = Buffered,
        recv = Recv
    } = Data
) ->
    MaxCL = maps:get(max_content_length, ProtoOpts),
    BodyBuffering = maps:get(body_buffering, ProtoOpts),
    case BodyBuffering of
        auto ->
            case cactus_conn:read_body(Req, Buffered, Recv, MaxCL) of
                {ok, Body, Leftover} ->
                    %% `Leftover` is bytes past the body — belongs to a
                    %% pipelined next request. Stash in `buffered` so
                    %% the keep-alive loop-back's `reading_request`
                    %% state_enter can parse it.
                    {next_state, dispatching, Data#data{
                        req = Req#{body => Body},
                        buffered = Leftover
                    }};
                {error, content_length_too_large} ->
                    %% Drain a bounded prefix of the oversized body (up
                    %% to 2 * MaxCL bytes, 1s per recv) so the peer
                    %% finishes writing before we send 413 and close —
                    %% without that, an in-flight write sees
                    %% ECONNRESET instead of a clean 413. The byte +
                    %% time caps prevent this becoming a DoS vector.
                    _ = cactus_conn:drain_oversized_body(Buffered, Socket, MaxCL),
                    ok = cactus_telemetry:request_rejected(
                        rejection_metadata(Data, content_length_too_large)
                    ),
                    _ = cactus_conn:send_payload_too_large(Socket),
                    {stop, normal, Data};
                {error, request_timeout} ->
                    _ = cactus_conn:send_request_timeout(Socket),
                    {stop, normal, Data};
                {error, slow_client} ->
                    {stop, normal, Data};
                {error, BodyReason} ->
                    ok = cactus_telemetry:request_rejected(
                        rejection_metadata(Data, BodyReason)
                    ),
                    _ = cactus_conn:send_bad_request(Socket),
                    {stop, normal, Data}
            end;
        manual ->
            case cactus_conn:body_framing(Req) of
                {error, FramingReason} ->
                    ok = cactus_telemetry:request_rejected(
                        rejection_metadata(Data, FramingReason)
                    ),
                    _ = cactus_conn:send_bad_request(Socket),
                    {stop, normal, Data};
                Framing ->
                    BodyState = cactus_conn:make_body_state(Framing, Buffered, Recv, MaxCL),
                    {next_state, dispatching, Data#data{
                        req = Req#{body_state => BodyState}
                    }}
            end
    end;
%% --- dispatching ---
handle_event(enter, _Old, dispatching, _Data) ->
    {keep_state_and_data, [{state_timeout, 0, dispatch}]};
handle_event(
    state_timeout,
    dispatch,
    dispatching,
    #data{
        socket = Socket, proto_opts = ProtoOpts, req = Req
    } = Data
) ->
    Dispatch = maps:get(dispatch, ProtoOpts),
    ListenerMws = maps:get(middlewares, ProtoOpts),
    case cactus_conn:resolve_handler(Dispatch, Req) of
        {ok, Handler, Bindings, RouteOpts} ->
            FullReq = Req#{bindings => Bindings, route_opts => RouteOpts},
            run_pipeline(Socket, Handler, FullReq, ListenerMws, Data);
        not_found ->
            _ = cactus_conn:send_not_found(Socket),
            {stop, normal, Data}
    end;
%% --- finishing ---
handle_event(enter, _Old, finishing, _Data) ->
    {keep_state_and_data, [{state_timeout, 0, finalize}]};
handle_event(
    state_timeout,
    finalize,
    finishing,
    #data{
        proto_opts = ProtoOpts,
        req = Req,
        response = Response,
        requests_served = Served
    } = Data
) ->
    %% Stream / loop / sendfile / websocket all force close by
    %% construction — only buffered (3-tuple) considers keep-alive.
    case cactus_conn:response_kind(Response) of
        buffered ->
            buffered_finish(Data, ProtoOpts, Req, Response, Served);
        _ ->
            {stop, normal, Data}
    end;
%% Catch-all for unexpected info events. Conns are unlinked from the
%% acceptor and don't `trap_exit`, so stray `'EXIT'` signals never
%% reach here — but a buggy library or trace tooling could deliver an
%% out-of-band message. Drop it at debug level so observability is
%% preserved without flooding production warning/notice logs.
handle_event(info, Unexpected, State, Data) ->
    logger:debug(#{
        msg => "cactus_conn_statem dropping unexpected info",
        state => State,
        info => Unexpected
    }),
    {keep_state, Data}.

%% Mirror `cactus_conn:handle_and_send/4` exactly: bracket the
%% middleware/handler pipeline with `[cactus, request, start | stop |
%% exception]` telemetry, dispatch the response, count the request as
%% served, transition to `finishing` for the keep-alive decision.
-spec run_pipeline(
    cactus_transport:socket(),
    module(),
    cactus_http1:request(),
    cactus_middleware:middleware_list(),
    #data{}
) -> gen_statem:event_handler_result(atom()).
run_pipeline(Socket, Handler, Req, ListenerMws, #data{} = Data) ->
    RouteMws = cactus_conn:route_middlewares(Req),
    HandlerFun = fun(R) -> Handler:handle(R) end,
    Pipeline = cactus_middleware:compose(ListenerMws ++ RouteMws, HandlerFun),
    Metadata = telemetry_metadata(Req),
    StartMono = cactus_telemetry:request_start(Metadata),
    try Pipeline(Req) of
        {Response, Req2} when is_map(Req2) ->
            _ = dispatch_response(Socket, Handler, Req2, Response),
            ok = cactus_telemetry:request_stop(StartMono, Metadata, #{
                status => cactus_conn:response_status(Response),
                response_kind => cactus_conn:response_kind(Response)
            }),
            Served = Data#data.requests_served + 1,
            %% Hand the response and Req2 to `finishing` for body drain
            %% + keep-alive decision.
            {next_state, finishing, Data#data{
                req = Req2, requests_served = Served, response = Response
            }}
    catch
        Class:Reason:Stack ->
            ok = cactus_telemetry:request_exception(StartMono, Metadata, Class, Reason),
            logger:error(#{
                msg => "cactus handler crashed",
                handler => Handler,
                class => Class,
                reason => Reason,
                stacktrace => Stack
            }),
            _ = cactus_conn:send_internal_error(Socket),
            {stop, normal, Data}
    end.

-spec buffered_finish(
    #data{},
    cactus_conn:proto_opts(),
    cactus_http1:request(),
    cactus_handler:response(),
    non_neg_integer()
) -> gen_statem:event_handler_result(atom()).
buffered_finish(Data, ProtoOpts, Req, {_Status, Headers, _Body}, Served) ->
    case cactus_conn:drain_body(Req) of
        {ok, ManualLeftover} ->
            case cactus_conn:keep_alive_decision(Req, Headers) of
                close ->
                    {stop, normal, Data};
                keep_alive ->
                    Max = maps:get(max_keep_alive_request, ProtoOpts),
                    case Served >= Max of
                        true ->
                            {stop, normal, Data};
                        false ->
                            %% RFC 7230 §6.3: preserve any post-body
                            %% bytes for the pipelined next request.
                            %% In manual mode `drain_body` returns the
                            %% body_state's leftover; in auto mode the
                            %% leftover was already stashed in
                            %% `Data#data.buffered` by `reading_body`.
                            Leftover = pipelined_leftover(
                                Req, Data, ManualLeftover
                            ),
                            {next_state, reading_request, Data#data{
                                phase = keep_alive,
                                req = undefined,
                                buffered = Leftover,
                                recv = undefined,
                                response = undefined
                            }}
                    end
            end;
        {error, _} ->
            %% Drain failure — close.
            {stop, normal, Data}
    end.

-spec request_timeout(first | keep_alive, cactus_conn:proto_opts()) -> non_neg_integer().
request_timeout(first, ProtoOpts) -> maps:get(request_timeout, ProtoOpts);
request_timeout(keep_alive, ProtoOpts) -> maps:get(keep_alive_timeout, ProtoOpts).

%% Pick the right leftover-bytes source for the keep-alive loop-back.
%% Manual mode owns its leftover in the body_state (returned via
%% `drain_body/1`); auto mode stashes the leftover in
%% `Data#data.buffered` from `reading_body`'s `read_body/4` return.
-spec pipelined_leftover(cactus_http1:request(), #data{}, binary()) -> binary().
pipelined_leftover(Req, _Data, ManualLeftover) when is_map_key(body_state, Req) ->
    ManualLeftover;
pipelined_leftover(_Req, Data, _ManualLeftover) ->
    Data#data.buffered.

%% State timeouts that bound the request-line/header read phase. The
%% `state_timeout` enforces the absolute deadline; the
%% `{timeout, rate_check}` (a `{generic_timeout, _, _}`) checks the
%% running rate so a peer that's connected but not sending bytes
%% fast enough gets dropped silently before the full request_timeout
%% elapses. The interval defaults to 1000ms in production but is
%% read from `proto_opts` so tests can fire the rate check in
%% sub-second time without slowing the suite.
-spec reading_request_timeouts(non_neg_integer(), cactus_conn:proto_opts()) ->
    [gen_statem:enter_action()].
reading_request_timeouts(Timeout, ProtoOpts) ->
    Interval = rate_check_interval(ProtoOpts),
    [
        {state_timeout, Timeout, request_deadline},
        {{timeout, rate_check}, Interval, rate_check}
    ].

-spec rate_check_interval(cactus_conn:proto_opts()) -> pos_integer().
rate_check_interval(ProtoOpts) ->
    maps:get(rate_check_interval_ms, ProtoOpts, 1000).

%% Re-arm the active-mode socket and yield with `Actions`. If
%% `setopts/2` reports the socket is dead (peer RST between events,
%% kernel-side close), stop the conn cleanly instead of crashing on a
%% strict `ok = ...` match. The next info event would normally have
%% been `{tcp_closed, _}`, but with the socket already disposed the
%% event won't fire — terminate now so terminate/3's slot release +
%% conn_close telemetry still run.
-spec arm_or_stop(
    cactus_transport:socket(), #data{}, [gen_statem:enter_action()]
) ->
    gen_statem:event_handler_result(atom()).
arm_or_stop(Socket, Data, Actions) ->
    case cactus_transport:setopts(Socket, [{active, once}]) of
        ok -> {keep_state, Data, Actions};
        {error, _} -> {stop, normal, Data}
    end.

%% Anti-Slowloris rate check — same shape as the closure-era
%% `cactus_conn:rate_ok/3`. After a 1-second grace, require the
%% running average to meet `MinRate` bytes/sec.
-spec rate_ok(integer(), non_neg_integer(), non_neg_integer()) -> boolean().
rate_ok(ElapsedMs, _Total, _MinRate) when ElapsedMs =< 1000 -> true;
rate_ok(ElapsedMs, Total, MinRate) -> Total * 1000 >= MinRate * ElapsedMs.

-spec handle_request_bytes(binary(), #data{}) ->
    gen_statem:event_handler_result(atom()).
handle_request_bytes(Bytes, #data{buffered = Buf} = Data0) ->
    Data = Data0#data{
        buffered = <<Buf/binary, Bytes/binary>>,
        read_bytes_total = Data0#data.read_bytes_total + byte_size(Bytes)
    },
    parse_buffered_request(Data).

-spec parse_buffered_request(#data{}) ->
    gen_statem:event_handler_result(atom()).
parse_buffered_request(
    #data{
        socket = Socket,
        proto_opts = ProtoOpts,
        listener_name = ListenerName,
        peer = Peer,
        scheme = Scheme,
        buffered = Buf,
        read_deadline = Deadline
    } = Data
) ->
    case cactus_http1:parse_request(Buf) of
        {ok, Req0, Rest} ->
            ReqCounter = maps:get(requests_counter, ProtoOpts),
            _ = atomics:add(ReqCounter, 1, 1),
            RequestId = cactus_conn:generate_request_id(),
            Req = Req0#{
                peer => Peer,
                scheme => Scheme,
                request_id => RequestId,
                listener_name => ListenerName
            },
            ok = cactus_conn:set_request_logger_metadata(Req),
            ok = cactus_conn:maybe_send_continue(Socket, Req, Rest),
            %% Body read still uses the synchronous recv closure. The
            %% deadline is the same one set at reading_request entry so
            %% the request_timeout covers the whole request.
            MinRate = maps:get(minimum_bytes_per_second, ProtoOpts),
            Recv = cactus_conn:make_recv(Socket, Deadline, MinRate),
            {next_state, reading_body, Data#data{
                req = Req, buffered = Rest, recv = Recv
            }};
        {more, _} ->
            arm_or_stop(Socket, Data, []);
        {error, Reason} ->
            logger:debug(#{
                msg => "cactus rejecting malformed request",
                peer => Peer,
                listener_name => ListenerName,
                reason => Reason
            }),
            ok = cactus_telemetry:request_rejected(
                rejection_metadata(Data, Reason)
            ),
            _ = cactus_conn:send_bad_request(Socket),
            {stop, normal, Data}
    end.

%% Mirrors `cactus_conn:maybe_send_request_timeout/2` — only the very
%% first request gets a 408 on silence; idle keep-alive timeouts
%% close silently to avoid blasting at peers that weren't reading.
-spec maybe_send_request_timeout(cactus_transport:socket(), first | keep_alive) ->
    ok | {error, term()}.
maybe_send_request_timeout(Socket, first) -> cactus_conn:send_request_timeout(Socket);
maybe_send_request_timeout(_Socket, keep_alive) -> ok.

-spec telemetry_metadata(cactus_http1:request()) -> cactus_telemetry:metadata().
telemetry_metadata(Req) ->
    #{
        request_id => maps:get(request_id, Req),
        peer => maps:get(peer, Req),
        method => maps:get(method, Req),
        path => maps:get(target, Req),
        scheme => maps:get(scheme, Req),
        listener_name => maps:get(listener_name, Req, undefined)
    }.

-spec dispatch_response(
    cactus_transport:socket(),
    module(),
    cactus_http1:request(),
    cactus_handler:response()
) -> ok.
dispatch_response(Socket, _Handler, Req, {websocket, Mod, State}) when is_atom(Mod) ->
    _ = cactus_ws_session:run(Socket, Req, Mod, State),
    ok;
dispatch_response(Socket, _Handler, _Req, {stream, Status, Headers, Fun}) when
    is_function(Fun, 1)
->
    _ = cactus_stream_response:run(Socket, Status, Headers, Fun),
    ok;
dispatch_response(Socket, Handler, _Req, {loop, Status, Headers, LoopState}) when
    is_integer(Status)
->
    _ = cactus_loop_response:run(Socket, Status, Headers, Handler, LoopState),
    ok;
dispatch_response(
    Socket, _Handler, Req, {sendfile, Status, Headers, {Filename, Offset, Length}}
) when
    is_integer(Status)
->
    Head = cactus_http1:response(Status, Headers, ~""),
    _ = cactus_telemetry:response_send(
        cactus_transport:send(Socket, Head), sendfile_response_head
    ),
    _ =
        case cactus_req:method(Req) of
            ~"HEAD" ->
                ok;
            _ ->
                cactus_telemetry:response_send(
                    cactus_transport:sendfile(Socket, Filename, Offset, Length),
                    sendfile_body
                )
        end,
    ok;
dispatch_response(Socket, _Handler, Req, {Status, Headers, Body}) when is_integer(Status) ->
    RespBody = cactus_conn:response_body_for(Req, Body),
    Resp = cactus_http1:response(Status, Headers, RespBody),
    _ = cactus_telemetry:response_send(
        cactus_transport:send(Socket, Resp), buffered_response
    ),
    ok.

-spec rejection_metadata(#data{}, atom()) -> map().
rejection_metadata(#data{listener_name = ListenerName, peer = Peer}, Reason) ->
    #{listener_name => ListenerName, peer => Peer, reason => Reason}.

%% --- Termination ---

-spec terminate(term(), atom(), #data{}) -> ok.
terminate(_Reason, _State, #data{
    socket = Socket,
    proto_opts = ProtoOpts,
    listener_name = ListenerName,
    start_mono = StartMono,
    peer = Peer,
    requests_served = Count
}) ->
    %% Skip the `conn_close` event if the process never reached the
    %% `shoot` handler — `accept` never fired so a paired `conn_close`
    %% would be misleading.
    case StartMono of
        undefined ->
            ok;
        _ ->
            cactus_telemetry:listener_conn_close(StartMono, #{
                listener_name => ListenerName,
                peer => Peer,
                requests_served => Count
            })
    end,
    _ = cactus_transport:close(Socket),
    cactus_conn:release_slot(ProtoOpts),
    ok.
