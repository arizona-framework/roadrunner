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
-export([awaiting_shoot/3, reading_request/3, reading_body/3]).

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
    %% Per-request scratch carried from `reading_request` into
    %% `reading_body`: the parsed request map and any post-headers
    %% bytes already buffered on the wire.
    req :: cactus_http1:request() | undefined,
    buffered = <<>> :: binary(),
    recv :: fun(() -> {ok, binary()} | {error, term()}) | undefined,
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
callback_mode() -> [state_functions, state_enter].

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

%% --- States ---

-spec awaiting_shoot(gen_statem:event_type(), term(), #data{}) ->
    gen_statem:event_handler_result(atom()).
awaiting_shoot(enter, _Old, _Data) ->
    keep_state_and_data;
awaiting_shoot(info, shoot, #data{socket = Socket, proto_opts = ProtoOpts} = Data) ->
    %% Socket ownership has just transferred from the acceptor — refine
    %% the proc_lib label with the peer (which we couldn't know in
    %% init/1 because the OS-level socket wasn't ours yet).
    Peer = cactus_conn:peer(Socket),
    ok = cactus_conn:refine_conn_label(ProtoOpts, Peer),
    Scheme = cactus_conn:scheme(Socket),
    {next_state, reading_request, Data#data{peer = Peer, scheme = Scheme}};
awaiting_shoot(info, {cactus_drain, _Deadline}, Data) ->
    %% Drain may arrive before `shoot` if the listener drains during
    %% the acceptor's hand-off window. Stash and check at parse time.
    {keep_state, Data#data{drain_pending = true}}.

-spec reading_request(gen_statem:event_type(), term(), #data{}) ->
    gen_statem:event_handler_result(atom()).
reading_request(enter, _Old, _Data) ->
    %% `state_timeout` is the only action a `state_enter` callback can
    %% use to schedule an internal-style follow-up. Zero delay fires
    %% the parse immediately on the next event-loop turn.
    {keep_state_and_data, [{state_timeout, 0, parse}]};
reading_request(state_timeout, parse, #data{drain_pending = true} = Data) ->
    %% Listener is draining — close before reading another request.
    %% (Phase 6 wires the `draining` state for the mid-keepalive case;
    %% the first-request drain just stops.)
    {stop, normal, Data};
reading_request(state_timeout, parse, #data{proto_opts = ProtoOpts} = Data) ->
    %% Phase 5 only handles the first request — `phase` is always
    %% `first`. Phase 6 introduces the keep-alive loop-back from
    %% `finishing`, at which point `phase = keep_alive` reads the
    %% `keep_alive_timeout` instead and `reading_request` grows an
    %% `info, {cactus_drain, _}` clause for messages arriving
    %% between requests.
    Timeout = maps:get(request_timeout, ProtoOpts),
    do_read_request(Timeout, Data).

-spec reading_body(gen_statem:event_type(), term(), #data{}) ->
    gen_statem:event_handler_result(atom()).
reading_body(enter, _Old, _Data) ->
    {keep_state_and_data, [{state_timeout, 0, read}]};
reading_body(
    state_timeout,
    read,
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
                    %% Phase 5 stops at `dispatching` — Phase 6 actually
                    %% calls the handler. For now we bump the served
                    %% counter (so conn_close telemetry reports a real
                    %% number) and exit normally.
                    _Req2 = Req#{body => Body},
                    {stop, normal, Data#data{requests_served = Data#data.requests_served + 1}};
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
                    _BodyState = #{
                        framing => Framing,
                        buffered => Buffered,
                        bytes_read => 0,
                        pending => <<>>,
                        done => false,
                        recv => Recv,
                        max => MaxCL
                    },
                    %% Phase 5 stop point — Phase 6 wires the handler
                    %% dispatch with the body_state.
                    {stop, normal, Data#data{requests_served = Data#data.requests_served + 1}}
            end
    end.

-spec do_read_request(non_neg_integer(), #data{}) ->
    gen_statem:event_handler_result(atom()).
do_read_request(
    Timeout,
    #data{
        socket = Socket,
        proto_opts = ProtoOpts,
        listener_name = ListenerName,
        peer = Peer,
        scheme = Scheme
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
            %% Phase 5 always sends 408 — only the first request can
            %% time out here. Phase 6's keep-alive iteration calls a
            %% silent variant via `phase = keep_alive`.
            _ = cactus_conn:send_request_timeout(Socket),
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
