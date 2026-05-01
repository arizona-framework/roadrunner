-module(cactus_conn_statem).
-moduledoc """
HTTP/1.1 connection state machine — work-in-progress replacement
for the hand-rolled `cactus_conn` recursion.

This module is **not yet wired in**. `cactus_conn:start/2` continues
to spawn the legacy `proc_lib`-based loop. Phase 4 of the migration
plan stops here; later phases (5–7) extend the state callbacks and
finally swap `start/2` to spawn this gen_statem instead.

The plan keeps `cactus_conn`'s public pure-function surface intact —
`parse_loop/2`, `read_body/4`, `peer/1`, `try_acquire_slot/1`,
`release_slot/1`, `consume_body_state/2` — so the 44 closure-driven
unit tests keep passing through the migration. The state machine
just calls those from inside its state callbacks once the later
phases land.

States (only `awaiting_shoot` is implemented in Phase 4):
- `awaiting_shoot` — gates the lifecycle until the acceptor's
  `shoot` info message arrives. `cactus_acceptor:handle_accepted/2`
  spawns this gen_statem, transfers controlling-process, then sends
  `ConnPid ! shoot` (raw bang, not a gen_statem call) — we receive
  it as an info event.
- `reading_request | reading_body | dispatching | finishing |
  draining` — placeholders, implemented in later phases.

Telemetry: `[cactus, listener, accept]` fires at `init/1` (so the
event captures the wall-clock start of the conn's life); the
matching `[cactus, listener, conn_close]` fires from `terminate/3`
with the connection's duration and the keep-alive request count.
""".

-behaviour(gen_statem).

-export([start/2]).
-export([init/1, callback_mode/0, terminate/3]).
-export([handle_event/4]).

-record(data, {
    socket :: cactus_transport:socket(),
    proto_opts :: cactus_conn:proto_opts(),
    listener_name :: atom(),
    %% Captured at init/1 for the conn_close telemetry's `duration`.
    start_mono :: integer(),
    %% Peer is unknown until after the socket transfer; populated on
    %% entry to `reading_request` (Phase 5).
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
    %% Peer isn't known yet — `init/1` runs before the socket transfer.
    %% Listener-accept telemetry fires here so subscribers can correlate
    %% by listener regardless of when the peer becomes available.
    StartMono = cactus_telemetry:listener_accept(#{
        listener_name => ListenerName, peer => undefined
    }),
    {ok, awaiting_shoot, #data{
        socket = Socket,
        proto_opts = ProtoOpts,
        listener_name = ListenerName,
        start_mono = StartMono
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
        socket = Socket, proto_opts = ProtoOpts
    } = Data
) ->
    %% Socket ownership has just transferred from the acceptor — refine
    %% the proc_lib label with the peer (which we couldn't know in
    %% init/1 because the OS-level socket wasn't ours yet).
    Peer = cactus_conn:peer(Socket),
    ok = cactus_conn:refine_conn_label(ProtoOpts, Peer),
    Scheme = cactus_conn:scheme(Socket),
    {next_state, reading_request, Data#data{peer = Peer, scheme = Scheme}};
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
    #data{
        drain_pending = true
    } = Data
) ->
    %% Listener is draining — close before reading another request.
    {stop, normal, Data};
handle_event(
    state_timeout,
    parse,
    reading_request,
    #data{
        phase = Phase, proto_opts = ProtoOpts
    } = Data
) ->
    Timeout = request_timeout(Phase, ProtoOpts),
    do_read_request(Timeout, Data);
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
    %% Phase 6a/6b only handles buffered response keep-alive — the
    %% other response kinds (stream, loop, sendfile, websocket) close
    %% by construction in Phase 7's dispatch_response clauses.
    buffered_finish(Data, ProtoOpts, Req, Response, Served).

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

%% Phase 6a only handles the buffered response shape. Phase 6b/7 add
%% `stream | loop | sendfile | websocket` once integration tests
%% (real listener, real socket) drive the full dispatch and provide
%% natural coverage for those clauses.
-spec dispatch_response(
    cactus_transport:socket(),
    module(),
    cactus_http1:request(),
    cactus_handler:response()
) -> ok.
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
    %% Mirror the legacy spine's `serve_lifecycle/3` telemetry exactly.
    cactus_telemetry:listener_conn_close(StartMono, #{
        listener_name => ListenerName, peer => Peer, requests_served => Count
    }),
    _ = cactus_transport:close(Socket),
    cactus_conn:release_slot(ProtoOpts),
    ok.
