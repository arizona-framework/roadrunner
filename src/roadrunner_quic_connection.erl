-module(roadrunner_quic_connection).
-moduledoc false.

%% The thin proc_lib shell over the pure `roadrunner_quic_conn_state`
%% decision core (a hand-rolled receive loop, never a gen_statem, mirroring
%% `roadrunner_conn_loop_http2`). The core owns the whole connection state
%% and every decision; this shell owns only the irreducible I/O: the shared
%% UDP socket handle (for sending), the peer address, the conn_state value,
%% and the single loss/PTO timer.
%%
%% The QUIC socket is passive and shared across connections (SO_REUSEPORT),
%% so the shell never reads it. The listener reads the socket and routes
%% each datagram to the owning connection as a `{quic_datagram, Peer,
%% Bytes}` message; the shell only sends on the socket. Every message drives
%% one conn_state entry point, and the returned effects are performed here:
%% `{send, Datagram}` goes out the socket to the peer, and `{arm_timer,
%% Kind, AtMs}` (re)arms a self-tagged timer whose stale fires (from a timer
%% that was re-armed before firing) are dropped by a reference match.
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
    timer :: reference() | undefined
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
-spec init(roadrunner_quic_socket:socket(), roadrunner_quic_conn_state:config()) -> no_return().
init(Socket, #{peer := Peer} = Config) ->
    proc_lib:set_label({?MODULE, Peer}),
    loop(#shell{
        socket = Socket,
        peer = Peer,
        conn = roadrunner_quic_conn_state:new(Config),
        timer = undefined
    }).

%% =============================================================================
%% Loop
%% =============================================================================

-spec loop(#shell{}) -> no_return().
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
                From, Ref, Request, State#shell.conn
            ),
            loop(perform(Effects, Now, State#shell{conn = Conn}));
        {quic_send, From, Ref, Sid, IoData, Fin} ->
            Now = erlang:monotonic_time(millisecond),
            {Conn, Effects} = roadrunner_quic_conn_state:handle_send(
                From, Ref, Sid, IoData, Fin, Now, State#shell.conn
            ),
            loop(perform(Effects, Now, State#shell{conn = Conn}));
        {quic_datagram, _Peer, Datagram} ->
            Now = erlang:monotonic_time(millisecond),
            {Conn, Effects} = roadrunner_quic_conn_state:handle_datagram(
                Now, Datagram, State#shell.conn
            ),
            loop(perform(Effects, Now, State#shell{conn = Conn}));
        {?MODULE, timer, Kind, Ref} ->
            loop(fire_timer(Ref, Kind, State));
        _Other ->
            loop(State)
    end.

%% Run a fired timer only when its ref is still the armed one; a stale fire
%% (the timer was re-armed before this message was delivered) is dropped.
-spec fire_timer(reference(), atom(), #shell{}) -> #shell{}.
fire_timer(Ref, Kind, #shell{timer = Ref, conn = Conn} = State) ->
    Now = erlang:monotonic_time(millisecond),
    {Conn1, Effects} = roadrunner_quic_conn_state:handle_timeout(Now, Kind, Conn),
    perform(Effects, Now, State#shell{conn = Conn1, timer = undefined});
fire_timer(_Ref, _Kind, State) ->
    State.

%% =============================================================================
%% Effects
%% =============================================================================

-spec perform([roadrunner_quic_conn_state:effect()], integer(), #shell{}) -> #shell{}.
perform(Effects, Now, State) ->
    lists:foldl(fun(Effect, Acc) -> perform_effect(Effect, Now, Acc) end, State, Effects).

-spec perform_effect(roadrunner_quic_conn_state:effect(), integer(), #shell{}) -> #shell{}.
perform_effect({send, Datagram}, _Now, #shell{socket = Socket, peer = {Ip, Port}} = State) ->
    _ = roadrunner_quic_socket:send(Socket, Ip, Port, Datagram),
    State;
perform_effect({emit, Owner, Event}, _Now, State) ->
    _ = Owner ! {quic, self(), Event},
    State;
perform_effect({reply, To, Ref, Result}, _Now, State) ->
    _ = To ! {quic_reply, Ref, Result},
    State;
perform_effect({arm_timer, Kind, AtMs}, Now, #shell{timer = Prev} = State) ->
    _ = cancel(Prev),
    Ref = make_ref(),
    _ = erlang:send_after(max(0, AtMs - Now), self(), {?MODULE, timer, Kind, Ref}),
    State#shell{timer = Ref}.

-spec cancel(reference() | undefined) -> ok.
cancel(undefined) ->
    ok;
cancel(Ref) ->
    _ = erlang:cancel_timer(Ref),
    ok.
