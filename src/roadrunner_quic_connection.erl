-module(roadrunner_quic_connection).
-moduledoc false.

%% The thin proc_lib shell over the pure `roadrunner_quic_conn_state`
%% decision core (a hand-rolled receive loop, never a gen_statem, mirroring
%% `roadrunner_conn_loop_http2`). The core owns the whole connection state
%% and every decision; this shell owns only the irreducible I/O: the shared
%% UDP socket handle (for sending), the peer address, the listener's
%% connection-id registry, the conn_state value, and the single loss/PTO
%% timer.
%%
%% The QUIC socket is passive and shared across connections (SO_REUSEPORT),
%% so the shell never reads it. The listener reads the socket and routes
%% each datagram to the owning connection as a `{quic_datagram, Peer,
%% Bytes}` message; the shell only sends on the socket. Every message drives
%% one conn_state entry point, and the returned effects are performed here:
%% `{send, Datagram}` goes out the socket to the peer, `{arm_timer, Kind,
%% AtMs}` sets the one deadline the core wants, and `{register_cid, CID}` /
%% `{unregister_cid, CID}` route a connection id the core issued to this
%% process in the registry, or stop routing one the peer retired (RFC 9000
%% §5.1). The listener reaps every row on the process's exit, so a closing
%% connection leaves none behind. The datagram's source address goes to the
%% core with it: when the client moves (RFC 9000 §9), `{migrate, Peer}`
%% points every later `{send, _}` at the new address, and `{send_to, Peer,
%% Datagram}` sends a probing packet to an address the connection is not
%% on. The shell re-arms its
%% timer lazily: a later deadline leaves an earlier armed timer running, and
%% when that one fires ahead of the deadline it is just re-armed, so a
%% deadline that keeps moving later (a PTO pushed back by each ACK) costs no
%% timer work per datagram. Only an earlier deadline cancels and re-arms. A
%% stale fire (from a timer cancelled after its message was queued) is
%% dropped by a timer-reference match.
%%
%% Synchronous control calls from the owner or listener arrive as
%% `{quic_call, From, Ref, Request}` and stream writes as `{quic_send, From,
%% Ref, Sid, IoData, Fin}`; both are answered with a `{reply, From, Ref,
%% Result}` effect (delivered as `From ! {quic_reply, Ref, Result}`). Owner
%% notifications go out as async `{emit, Owner, Event}` effects (`Owner !
%% {quic, self(), Event}`). The connection only ever sends to the owner
%% asynchronously, so it never blocks on it.

-export([start/2]).
-export([init/2]).

-record(shell, {
    socket :: roadrunner_quic_socket:socket(),
    peer :: {inet:ip_address(), inet:port_number()},
    conn :: roadrunner_quic_conn_state:t(),
    %% The armed timer and the time it fires at, never after `deadline`.
    timer :: {reference(), integer()} | undefined,
    %% The core's current deadline: the timer kind to run, and when.
    deadline :: {atom(), integer()} | undefined,
    %% The listener's connection-id routing table, where the ids the core
    %% issues are routed to this process.
    registry :: roadrunner_quic_cid_registry:t()
}).

%% =============================================================================
%% Start
%% =============================================================================

-doc """
Spawn a connection shell over the (shared) socket for the given
per-connection config. The first Initial arrives later as a
`{quic_datagram, _, _}` message, the same as every subsequent datagram.
""".
-spec start(roadrunner_quic_socket:socket(), roadrunner_quic_conn_state:config()) -> {ok, pid()}.
start(Socket, Config) ->
    {ok, proc_lib:spawn_opt(?MODULE, init, [Socket, Config], [])}.

-doc false.
-spec init(roadrunner_quic_socket:socket(), roadrunner_quic_conn_state:config()) ->
    ok | no_return().
init(Socket, #{peer := Peer, registry := Registry} = Config) ->
    proc_lib:set_label({?MODULE, Peer}),
    loop(#shell{
        socket = Socket,
        peer = Peer,
        conn = roadrunner_quic_conn_state:new(Config, erlang:monotonic_time(millisecond)),
        timer = undefined,
        deadline = undefined,
        registry = Registry
    }).

%% =============================================================================
%% Loop
%% =============================================================================

-spec loop(#shell{}) -> ok | no_return().
loop(State) ->
    receive
        {system, From, Req} ->
            roadrunner_loop_sys:handle_system(Req, From, State, fun loop/1);
        {'$gen_call', From, _Request} ->
            ok = roadrunner_loop_sys:gen_call_unsupported(From),
            loop(State);
        {'$gen_cast', _Request} ->
            loop(State);
        {quic_call, From, Ref, Request} ->
            Now = erlang:monotonic_time(millisecond),
            {Conn, Effects} = roadrunner_quic_conn_state:handle_call(
                From, Ref, Request, Now, State#shell.conn
            ),
            continue(perform(Effects, Now, State#shell{conn = Conn}));
        {quic_send, From, Ref, Sid, IoData, Fin} ->
            Now = erlang:monotonic_time(millisecond),
            {Conn, Effects} = roadrunner_quic_conn_state:handle_send(
                From, Ref, Sid, IoData, Fin, Now, State#shell.conn
            ),
            continue(perform(Effects, Now, State#shell{conn = Conn}));
        {quic_consumed, Sid, Bytes} ->
            Now = erlang:monotonic_time(millisecond),
            {Conn, Effects} = roadrunner_quic_conn_state:handle_consumed(
                Sid, Bytes, Now, State#shell.conn
            ),
            continue(perform(Effects, Now, State#shell{conn = Conn}));
        {quic_datagram, Peer, Datagram} ->
            Now = erlang:monotonic_time(millisecond),
            {Conn, Effects} = roadrunner_quic_conn_state:handle_datagram(
                Now, Peer, Datagram, State#shell.conn
            ),
            continue(perform(Effects, Now, State#shell{conn = Conn}));
        {timeout, TRef, ?MODULE} ->
            continue(fire_timer(TRef, State));
        _Other ->
            loop(State)
    end.

%% Resume the loop, or exit normally once the pure core has moved to the
%% `closed` phase. proc_lib treats a normal return as a clean process exit,
%% and the owner already learned of the close via the {closed, _} emit, so
%% there is no further teardown to do here.
-spec continue(#shell{}) -> ok | no_return().
continue(#shell{conn = Conn} = State) ->
    case roadrunner_quic_conn_state:phase(Conn) of
        closed -> ok;
        _ -> loop(State)
    end.

%% Act on a fired timer only when it is still the armed one; a stale fire
%% (the timer was cancelled after this message was queued) is dropped. A
%% timer armed for an earlier deadline than the current one is re-armed for
%% the rest of the wait; once the deadline is reached the core runs it.
-spec fire_timer(reference(), #shell{}) -> #shell{}.
fire_timer(TRef, #shell{timer = {TRef, _}, deadline = {Kind, AtMs}, conn = Conn} = State) ->
    Now = erlang:monotonic_time(millisecond),
    case AtMs =< Now of
        true ->
            {Conn1, Effects} = roadrunner_quic_conn_state:handle_timeout(Now, Kind, Conn),
            perform(Effects, Now, State#shell{conn = Conn1, timer = undefined, deadline = undefined});
        false ->
            arm(AtMs, Now, State)
    end;
fire_timer(_TRef, State) ->
    State.

%% =============================================================================
%% Effects
%% =============================================================================

%% Perform the effects in order. A run of consecutive sends goes to the
%% socket in one call, so it can hand them to the kernel together (GSO).
-spec perform([roadrunner_quic_conn_state:effect()], integer(), #shell{}) -> #shell{}.
perform([{send, _} | _] = Effects, Now, #shell{socket = Socket, peer = {Ip, Port}} = State) ->
    {Datagrams, Rest} = take_sends(Effects),
    ok = roadrunner_quic_socket:send_batch(Socket, Ip, Port, Datagrams),
    perform(Rest, Now, State);
perform([Effect | Rest], Now, State) ->
    perform(Rest, Now, perform_effect(Effect, Now, State));
perform([], _Now, State) ->
    State.

-spec take_sends([roadrunner_quic_conn_state:effect()]) ->
    {[binary()], [roadrunner_quic_conn_state:effect()]}.
take_sends([{send, Datagram} | Rest]) ->
    {Datagrams, Tail} = take_sends(Rest),
    {[Datagram | Datagrams], Tail};
take_sends(Effects) ->
    {[], Effects}.

-spec perform_effect(roadrunner_quic_conn_state:effect(), integer(), #shell{}) -> #shell{}.
perform_effect({emit, Owner, Event}, _Now, State) ->
    _ = Owner ! {quic, self(), Event},
    State;
perform_effect({reply, To, Ref, Result}, _Now, State) ->
    _ = To ! {quic_reply, Ref, Result},
    State;
perform_effect({register_cid, CID}, _Now, #shell{registry = Registry} = State) ->
    ok = roadrunner_quic_cid_registry:add(Registry, CID, self()),
    State;
perform_effect({unregister_cid, CID}, _Now, #shell{registry = Registry} = State) ->
    ok = roadrunner_quic_cid_registry:remove(Registry, CID, self()),
    State;
perform_effect({send_to, {Ip, Port}, Datagram}, _Now, #shell{socket = Socket} = State) ->
    %% A send error is a lost datagram, as for the batched sends.
    _ = roadrunner_quic_socket:send(Socket, Ip, Port, Datagram),
    State;
perform_effect({migrate, Peer}, _Now, State) ->
    State#shell{peer = Peer};
perform_effect({arm_timer, Kind, AtMs}, Now, #shell{timer = Timer} = State0) ->
    State = State0#shell{deadline = {Kind, AtMs}},
    case Timer of
        {_TRef, ArmedAt} when ArmedAt =< AtMs ->
            %% The armed timer fires first; fire_timer/2 re-arms from there.
            State;
        {TRef, _ArmedAt} ->
            _ = erlang:cancel_timer(TRef),
            arm(AtMs, Now, State);
        undefined ->
            arm(AtMs, Now, State)
    end.

-spec arm(integer(), integer(), #shell{}) -> #shell{}.
arm(AtMs, Now, State) ->
    TRef = erlang:start_timer(max(0, AtMs - Now), self(), ?MODULE),
    State#shell{timer = {TRef, AtMs}}.
