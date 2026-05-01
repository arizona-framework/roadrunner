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
- `reading_request` — drives `cactus_conn:parse_loop/2` against a
  `cactus_conn:make_recv/3` closure. The drain peek
  (`drain_peek/1`) checks the gen_statem mailbox for an info-queued
  drain message before parsing because state_timeout fires before
  info events under gen_statem's event priority.
- `reading_body` — calls `cactus_conn:read_body/4` (auto mode) or
  installs a `cactus_conn:make_body_state/4` body state (manual
  mode), then transitions to `dispatching`.
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
    drain_pending = false :: boolean()
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
    gen_statem:start(?MODULE, {Socket, ProtoOpts}, []).

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

%% Drain message handled identically in every state — flag is checked
%% by `reading_request` before reading the next request. Using a
%% wildcard state pattern avoids duplicating the clause across each
%% specific state.
handle_event(info, {cactus_drain, _Deadline}, _State, Data) ->
    {keep_state, Data#data{drain_pending = true}};
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
%% --- reading_request ---
handle_event(enter, _Old, reading_request, _Data) ->
    %% `state_timeout` is the only action a `state_enter` callback can
    %% use to schedule an internal-style follow-up. Zero delay fires
    %% the parse immediately on the next event-loop turn.
    {keep_state_and_data, [{state_timeout, 0, parse}]};
handle_event(
    state_timeout,
    parse,
    reading_request,
    #data{phase = Phase, proto_opts = ProtoOpts} = Data0
) ->
    %% Drain peek: a `{cactus_drain, _}` info event that arrived after
    %% `state_enter` set the parse timeout would otherwise be queued
    %% behind the state_timeout (which fires first under gen_statem's
    %% event priority). Mirror the legacy spine's `drain_pending/0`
    %% receive-with-after-0 by peeking the gen_statem process mailbox
    %% directly here.
    Data = drain_peek(Data0),
    case Data#data.drain_pending of
        true ->
            {stop, normal, Data};
        false ->
            Timeout = request_timeout(Phase, ProtoOpts),
            do_read_request(Timeout, Data)
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
                {ok, Body} ->
                    {next_state, dispatching, Data#data{req = Req#{body => Body}}};
                {error, content_length_too_large} ->
                    _ = cactus_conn:send_payload_too_large(Socket),
                    {stop, normal, Data};
                {error, request_timeout} ->
                    _ = cactus_conn:send_request_timeout(Socket),
                    {stop, normal, Data};
                {error, slow_client} ->
                    {stop, normal, Data};
                {error, _} ->
                    _ = cactus_conn:send_bad_request(Socket),
                    {stop, normal, Data}
            end;
        manual ->
            case cactus_conn:body_framing(Req) of
                {error, _} ->
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
        ok ->
            case cactus_conn:keep_alive_decision(Req, Headers) of
                close ->
                    {stop, normal, Data};
                keep_alive ->
                    Max = maps:get(max_keep_alive_request, ProtoOpts),
                    case Served >= Max of
                        true ->
                            {stop, normal, Data};
                        false ->
                            %% Reset per-request scratch and loop back.
                            {next_state, reading_request, Data#data{
                                phase = keep_alive,
                                req = undefined,
                                buffered = <<>>,
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

%% Non-blocking peek for a `{cactus_drain, _}` broadcast that may have
%% landed in the gen_statem mailbox after state_enter set the parse
%% timeout.
%%
%% **Why a raw receive instead of letting gen_statem dispatch?**
%% Per OTP's gen_statem event-priority rules (see
%% [the gen_statem User's Guide on event types](https://www.erlang.org/doc/system/statem.html#event-types)),
%% `state_timeout` events take precedence over `info` events. So even
%% if a `{cactus_drain, _}` info message is already in the mailbox
%% when state_enter sets `{state_timeout, 0, parse}`, gen_statem
%% will fire the parse timeout FIRST and only deliver the drain
%% afterward — by which point the next request's parse has already
%% begun. Tried alternatives: `postpone` (delays handling, not
%% priority); `{generic_timeout, _, _}` (same priority class as
%% state_timeout); reordering state_enter (can't, state_enter
%% rejects `next_event`).
%%
%% The peek bypasses gen_statem's queue once per reading_request
%% iteration to consume any pending drain message. The rest of the
%% time drain_pending is already true (caught by the first clause)
%% or the mailbox has no drain (after-0 path). If a future OTP
%% release adds a `peek_mailbox`-style primitive, revisit.
-spec drain_peek(#data{}) -> #data{}.
drain_peek(#data{drain_pending = true} = Data) ->
    Data;
drain_peek(Data) ->
    receive
        {cactus_drain, _Deadline} -> Data#data{drain_pending = true}
    after 0 ->
        Data
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

-spec do_read_request(non_neg_integer(), #data{}) ->
    gen_statem:event_handler_result(atom()).
do_read_request(
    Timeout,
    #data{
        socket = Socket,
        proto_opts = ProtoOpts,
        listener_name = ListenerName,
        peer = Peer,
        scheme = Scheme,
        phase = Phase
    } = Data
) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    MinRate = maps:get(minimum_bytes_per_second, ProtoOpts),
    Recv = cactus_conn:make_recv(Socket, Deadline, MinRate),
    case cactus_conn:parse_loop(<<>>, Recv) of
        {ok, Req0, Buffered} ->
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
            ok = cactus_conn:maybe_send_continue(Socket, Req, Buffered),
            {next_state, reading_body, Data#data{
                req = Req, buffered = Buffered, recv = Recv
            }};
        {error, request_timeout} ->
            _ = maybe_send_request_timeout(Socket, Phase),
            {stop, normal, Data};
        {error, slow_client} ->
            {stop, normal, Data};
        {error, _} ->
            _ = cactus_conn:send_bad_request(Socket),
            {stop, normal, Data}
    end.

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
