-module(roadrunner_quic_listener).
-moduledoc false.

%% A single native QUIC listener: one UDP socket, a connection-id routing
%% table, and the per-connection spawn ordering. A hand-rolled proc_lib
%% receive loop (never a gen_server, mirroring the connection shell), driving
%% the socket in `active => once` mode so datagrams interleave with monitor
%% and system messages in one loop.
%%
%% Each datagram is routed by its Destination Connection ID
%% (`roadrunner_quic_cid_registry`): a hit forwards `{quic_datagram, Peer,
%% Bytes}` to the owning connection; a miss on a QUIC v1 Initial spawns a new
%% connection; a miss on an unsupported-version long header answers with a
%% Version Negotiation packet (RFC 9000 §5.2.2); a miss on a short header
%% goes to the connection a client stateless reset token in its last 16
%% bytes names, or else draws a Stateless Reset of our own (§10.3), so a
%% client the server has forgotten (after a restart, say) stops at once
%% instead of waiting out its idle timeout. Spawning follows the strict
%% ordering the handshake depends on
%% (RFC 9000): spawn the connection, link it (so the
%% listener's own shutdown tears its connections down, and a connection's death
%% reaps its routing rows), register its CIDs (so a fast follow-up datagram
%% already routes), run the connection_handler to get the application owner,
%% install the owner SYNCHRONOUSLY (so ownership transfers before the handshake
%% can complete and race the `{connected, _}` event), and only then feed the
%% first Initial. Slot limiting, telemetry, and drain stay in the owner the
%% handler returns; the listener owns none of them. A first Initial carrying
%% an address validation token one of our connections issued with NEW_TOKEN
%% (RFC 9000 §8.1.3) for the address it came from, still good and not spent
%% before, starts its connection with the address validated, so the
%% server's first flight is not held to three times what the client sent.
%%
%% A new server Source Connection ID is generated per connection at a fixed
%% length, so short-header 1-RTT packets (which carry no CID-length field)
%% demux by slicing that many leading bytes. The spare ids a connection issues
%% once connected (RFC 9000 §5.1.1) have the same length, and the connection
%% routes them itself through the same registry. A connection that closes
%% removes all its rows as it exits, so the listener only reaps (with a scan
%% of the registry) those of one that crashes. `roadrunner_quic_listener_sup`
%% runs a SO_REUSEPORT pool of these listeners sharing one injected registry.

-export([start_link/1, get_port/1, stop/1]).
-export([new_accept_gate/0, close_accept_gate/1]).
-export([init/1]).
%% Exported for exhaustive eunit branch coverage of the pure routing decision.
-export([classify/2]).
%% Exported for direct eunit branch coverage of the Stateless Reset size and
%% rate rules (RFC 9000 §10.3, §10.3.3).
-export([reset_size/1, reset_budget/2]).

-export_type([opts/0, accept_gate/0]).

%% Must match roadrunner_quic_conn_state's ?SCID_LEN: the server issues SCIDs
%% of this length so short-header packets demux by slicing it.
-define(SCID_LEN, 8).
%% QUIC version 1 (RFC 9000 §15); also defined in roadrunner_quic_send.
-define(QUIC_V1, 16#00000001).
%% The versions advertised in a Version Negotiation packet (RFC 9000 §17.2.1).
%% A reserved 0x?a?a?a?a "grease" version (§6.3) is an optional addition.
-define(SUPPORTED_VERSIONS, [?QUIC_V1]).
%% RFC 9000 §14.1: a server MUST discard an Initial packet carried in a UDP
%% datagram whose payload is smaller than 1200 bytes, so a too-small Initial
%% never spawns a connection (clients pad Initial datagrams to this floor).
-define(MIN_INITIAL_DATAGRAM, 1200).
%% Datagrams the shared socket delivers per re-arm: large enough that the
%% per-batch `{active, N}` setopts is a small fraction of the per-datagram work,
%% small enough that the listener mailbox between re-arms stays bounded.
-define(ACTIVE_N, 100).
%% RFC 9000 §10.3: a Stateless Reset is at least 21 bytes (5 before its
%% 16-byte token), and short-header packets smaller than that are never
%% valid, so only a larger one draws a reset, which is smaller still
%% (§10.3.3).
-define(MIN_STATELESS_RESET, 21).
-define(RESET_TOKEN_LEN, 16).
%% RFC 9000 §10.3: a reset answering a packet of 43 bytes or fewer SHOULD be
%% one byte shorter. One answering a larger packet is between 43 bytes (at
%% least 41 makes it hard to tell from a 1-RTT packet, §10.3.3) and this
%% many, whatever the trigger's size, so a forgotten client sending full
%% packets gets small answers.
-define(MAX_STATELESS_RESET, 64).
%% Stateless Resets a listener sends per second (RFC 9000 §10.3.3: an
%% endpoint can stop sending them past a limit). Each answers a packet to an
%% unknown connection, so the limit bounds what a flood of junk short
%% headers draws, while a forgotten client, which sends a few packets
%% before its reset arrives, is still answered.
-define(RESET_LIMIT, 100).

%% Whether a listener takes new connections. Shared by a whole pool, so one
%% write stops every listener in it (and a restarted listener keeps it, as
%% the gate rides in its child spec). Closing it only refuses new clients:
%% datagrams for connections already registered still route.
-opaque accept_gate() :: atomics:atomics_ref().

-type opts() :: #{
    port := inet:port_number(),
    cert_chain := [binary()],
    priv_key := public_key:private_key(),
    alpn := binary(),
    transport_params := roadrunner_quic_transport_params:params(),
    connection_handler := fun((pid()) -> {ok, pid()} | {error, term()}),
    reuseport => boolean(),
    %% Local interface to bind. Unset binds all interfaces; set to a
    %% specific address (e.g. `{127,0,0,1}`) to bind that one only.
    ip => inet:ip_address(),
    %% The connection-id routing table. A SO_REUSEPORT pool injects one shared
    %% table (owned by the pool supervisor) so a datagram landing on any pool
    %% socket routes to the owning connection; a standalone listener omits it
    %% and creates (and owns) its own.
    registry => roadrunner_quic_cid_registry:t(),
    %% When a request stream's receive credit is granted back
    %% (`roadrunner_quic_conn_state:config()`); `on_receipt` by default.
    stream_credit => on_receipt | on_read,
    %% When set and closed, a datagram that would start a new connection is
    %% dropped (RFC 9000 lets a server ignore an Initial). Unset, the
    %% listener always accepts.
    accept_gate => accept_gate()
}.

-record(listener, {
    socket :: roadrunner_quic_socket:socket(),
    port :: inet:port_number(),
    %% The process that started (and is linked to) the listener — the pool
    %% supervisor, or a standalone owner. Its `'EXIT'` is a shutdown request.
    parent :: pid(),
    registry :: roadrunner_quic_cid_registry:t(),
    cert_chain :: [binary()],
    priv_key :: public_key:private_key(),
    alpn :: binary(),
    %% The base transport parameters (flow/stream/idle limits); the per-
    %% connection original/initial connection ids are filled in at spawn.
    transport_params :: roadrunner_quic_transport_params:params(),
    handler :: fun((pid()) -> {ok, pid()} | {error, term()}),
    stream_credit = on_receipt :: on_receipt | on_read,
    accept_gate :: accept_gate() | undefined,
    %% The second (monotonic) the Stateless Resets counted were sent in, and
    %% how many (RFC 9000 §10.3.3).
    resets = undefined :: undefined | {integer(), non_neg_integer()}
}).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Start a listener bound to `port` (0 picks an ephemeral port, read back with
get_port/1). Returns once the socket is bound, so a bind failure surfaces
synchronously as `{error, _}`.
""".
-spec start_link(opts()) -> {ok, pid()} | {error, term()}.
start_link(Opts) ->
    proc_lib:start_link(?MODULE, init, [Opts]).

-doc "The port the listener is bound to.".
-spec get_port(pid()) -> inet:port_number().
get_port(Pid) ->
    gen_server:call(Pid, get_port).

-doc "Stop the listener and close its socket.".
-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_server:call(Pid, stop).

-doc "A new, open accept gate, to pass as the `accept_gate` opt.".
-spec new_accept_gate() -> accept_gate().
new_accept_gate() ->
    atomics:new(1, [{signed, false}]).

-doc "Close the gate: every listener holding it stops taking new connections.".
-spec close_accept_gate(accept_gate()) -> ok.
close_accept_gate(Gate) ->
    atomics:put(Gate, 1, 1).

%% =============================================================================
%% Loop
%% =============================================================================

-doc false.
-spec init(opts()) -> no_return().
init(
    #{
        port := Port,
        cert_chain := CertChain,
        priv_key := PrivKey,
        alpn := Alpn,
        transport_params := TransportParams,
        connection_handler := Handler
    } = Opts
) ->
    %% Trap exits and link each spawned connection (in spawn_connection): a
    %% crashed connection's `'EXIT'` reaps its routing rows, and the
    %% listener's own shutdown then tears its connections down (so their
    %% owners and stream workers stop), matching the dep's listener-stop
    %% semantics the drain relies on.
    process_flag(trap_exit, true),
    [Parent | _] = get('$ancestors'),
    ReusePort = maps:get(reuseport, Opts, false),
    SocketOpts =
        case Opts of
            #{ip := IP} -> #{active => ?ACTIVE_N, reuseport => ReusePort, ip => IP};
            #{} -> #{active => ?ACTIVE_N, reuseport => ReusePort}
        end,
    case roadrunner_quic_socket:open(Port, SocketOpts) of
        {ok, Socket} ->
            {ok, {_Ip, BoundPort}} = roadrunner_quic_socket:sockname(Socket),
            proc_lib:set_label({?MODULE, BoundPort}),
            proc_lib:init_ack({ok, self()}),
            %% A pool injects one shared registry; a standalone listener owns its
            %% own. Either way the listener never deletes the table on stop, so a
            %% shared one outlives any single listener.
            Registry =
                case Opts of
                    #{registry := Injected} -> Injected;
                    #{} -> roadrunner_quic_cid_registry:new()
                end,
            loop(#listener{
                socket = Socket,
                port = BoundPort,
                parent = Parent,
                registry = Registry,
                cert_chain = CertChain,
                priv_key = PrivKey,
                alpn = Alpn,
                transport_params = TransportParams,
                handler = Handler,
                stream_credit = maps:get(stream_credit, Opts, on_receipt),
                accept_gate = maps:get(accept_gate, Opts, undefined)
            });
        {error, Reason} ->
            proc_lib:init_ack({error, Reason}),
            exit(normal)
    end.

-spec loop(#listener{}) -> no_return().
loop(#listener{socket = Socket, parent = Parent} = State) ->
    receive
        {system, From, Req} ->
            roadrunner_loop_sys:handle_system(Req, From, State, fun loop/1);
        {'$gen_call', From, get_port} ->
            ok = gen_server:reply(From, State#listener.port),
            loop(State);
        {'$gen_call', From, stop} ->
            ok = gen_server:reply(From, ok),
            ok = roadrunner_quic_socket:close(Socket),
            exit(normal);
        {'$gen_call', From, _Request} ->
            ok = roadrunner_loop_sys:gen_call_unsupported(From),
            loop(State);
        {'$gen_cast', _Request} ->
            loop(State);
        {'EXIT', Parent, Reason} ->
            %% The (pool supervisor) parent is shutting us down: close the socket
            %% and exit with its reason so our linked connections are torn down
            %% with us (their owners and stream workers then stop on the loss).
            ok = roadrunner_quic_socket:close(Socket),
            exit(Reason);
        {'EXIT', _Pid, normal} ->
            %% A linked connection closed: it removed its own routing rows on
            %% the way out (one delete per id), so there is nothing to reap.
            loop(State);
        {'EXIT', Pid, _Reason} ->
            %% A linked connection crashed or was killed (or our teardown
            %% reaped it), leaving its routing rows; drop them. delete_pid keys
            %% on the pid, so it only reaps that connection's ids, at the cost
            %% of a scan of the whole registry.
            ok = roadrunner_quic_cid_registry:delete_pid(State#listener.registry, Pid),
            loop(State);
        Message ->
            loop(handle_message(Message, State))
    end.

%% A datagram from the active socket is routed; the socket delivers up to
%% `?ACTIVE_N` datagrams before a `passive` notice, at which point we re-arm
%% the whole batch in one syscall. Anything else is a stray message and dropped.
-spec handle_message(term(), #listener{}) -> #listener{}.
handle_message(Message, #listener{socket = Socket} = State) ->
    case roadrunner_quic_socket:from_message(Socket, Message) of
        {ok, Peer, Datagram} ->
            route(Datagram, Peer, State);
        passive ->
            ok = roadrunner_quic_socket:activate(Socket, ?ACTIVE_N),
            State;
        ignore ->
            State
    end.

%% =============================================================================
%% Routing
%% =============================================================================

%% Execute a datagram's routing decision: forward to the owning connection,
%% spawn one for a new client, answer with Version Negotiation or a
%% Stateless Reset, or drop.
-spec route(binary(), {inet:ip_address(), inet:port_number()}, #listener{}) -> #listener{}.
route(Datagram, Peer, #listener{registry = Registry} = State) ->
    case classify(Datagram, Registry) of
        {forward, ConnPid} ->
            _ = ConnPid ! {quic_datagram, Peer, Datagram},
            State;
        {spawn, ClientDCID, ClientSCID} ->
            case accepting(State) of
                true -> spawn_connection(Datagram, Peer, ClientDCID, ClientSCID, State);
                false -> State
            end;
        {version_negotiation, ClientDCID, ClientSCID} ->
            send_version_negotiation(ClientDCID, ClientSCID, Peer, State);
        {stateless_reset, DCID} ->
            send_stateless_reset(DCID, byte_size(Datagram), Peer, State);
        drop ->
            State
    end.

-spec accepting(#listener{}) -> boolean().
accepting(#listener{accept_gate = undefined}) ->
    true;
accepting(#listener{accept_gate = Gate}) ->
    atomics:get(Gate, 1) =:= 0.

%% RFC 9000 §17.2.1: a Version Negotiation packet lists the versions the server
%% supports and echoes the client's connection ids swapped (our destination id
%% is the client's source id, our source id is the client's destination id) so
%% the client accepts it. It consumes the whole datagram; exactly one is sent
%% per received datagram.
-spec send_version_negotiation(
    binary(), binary(), {inet:ip_address(), inet:port_number()}, #listener{}
) -> #listener{}.
send_version_negotiation(ClientDCID, ClientSCID, {Ip, Port}, #listener{socket = Socket} = State) ->
    Datagram = roadrunner_quic_packet:encode_version_negotiation(
        ClientSCID, ClientDCID, ?SUPPORTED_VERSIONS
    ),
    _ = roadrunner_quic_socket:send(Socket, Ip, Port, Datagram),
    State.

%% RFC 9000 §10.3: answer a short-header packet for a connection we do not
%% have with a Stateless Reset carrying the token of its Destination
%% Connection ID under the registry's reset key, the token a connection that
%% issued the id announced. Every reset is smaller than the packet that drew
%% it (§10.3.3 MUST, so two endpoints cannot loop, and far below the
%% three-times amplification bound, §10.3), and past ?RESET_LIMIT a second
%% none is sent.
-spec send_stateless_reset(
    binary(), pos_integer(), {inet:ip_address(), inet:port_number()}, #listener{}
) -> #listener{}.
send_stateless_reset(DCID, Size, {Ip, Port}, #listener{resets = Resets} = State) ->
    case reset_budget(erlang:monotonic_time(second), Resets) of
        {ok, Resets1} ->
            #listener{socket = Socket, registry = Registry} = State,
            Token = roadrunner_quic_cid_registry:reset_token(
                roadrunner_quic_cid_registry:reset_key(Registry), DCID
            ),
            Reset = roadrunner_quic_packet:encode_stateless_reset(Token, reset_size(Size)),
            _ = roadrunner_quic_socket:send(Socket, Ip, Port, Reset),
            State#listener{resets = Resets1};
        exhausted ->
            State
    end.

%% The size of the Stateless Reset answering a packet of `Trigger` bytes
%% (more than ?MIN_STATELESS_RESET): one byte shorter up to 43 bytes (RFC
%% 9000 §10.3 SHOULD), otherwise a random size from 43 bytes to the smaller
%% of ?MAX_STATELESS_RESET and one byte short of the trigger, so its size
%% does not mark it either (§10.3.3).
-doc false.
-spec reset_size(pos_integer()) -> pos_integer().
reset_size(Trigger) when Trigger =< 43 ->
    Trigger - 1;
reset_size(Trigger) ->
    Max = min(Trigger - 1, ?MAX_STATELESS_RESET),
    42 + rand:uniform(Max - 42).

%% Count one more Stateless Reset sent in second `Now`: allowed while fewer
%% than ?RESET_LIMIT went out in it (RFC 9000 §10.3.3).
-doc false.
-spec reset_budget(integer(), undefined | {integer(), non_neg_integer()}) ->
    {ok, {integer(), non_neg_integer()}} | exhausted.
reset_budget(Now, {Now, Count}) when Count < ?RESET_LIMIT ->
    {ok, {Now, Count + 1}};
reset_budget(Now, {Now, _Count}) ->
    exhausted;
reset_budget(Now, _Resets) ->
    {ok, {Now, 1}}.

%% Decide a datagram's fate from its connection ids and the routing table (a
%% pure decision given the table): `{forward, Pid}` to the owning connection,
%% `{spawn, DCID, SCID}` for a QUIC v1 Initial (at the RFC 9000 §14.1 1200-byte
%% floor) to an unknown id (carrying the client's source id, which the server's
%% replies address per §7.2), `{version_negotiation, DCID, SCID}` for an unsupported
%% version at that floor (RFC 9000 §5.2.2), `{stateless_reset, DCID}` for a
%% short-header packet to an unknown id large enough to answer (§10.3), or
%% `drop` otherwise: a malformed packet, a short header too small to answer, a
%% v1 Initial below the floor, or an unsupported-version packet below it (a
%% server MUST discard those). A short header to an unknown id whose last 16
%% bytes are a client's stateless reset token is `{forward, Pid}` to the
%% connection holding it, which checks it (§10.3.1). The forward path is
%% size-unconditional; the owning connection enforces §14.1 on its own
%% received Initials.
-doc false.
-spec classify(binary(), roadrunner_quic_cid_registry:t()) ->
    {forward, pid()}
    | {spawn, binary(), binary()}
    | {version_negotiation, binary(), binary()}
    | {stateless_reset, binary()}
    | drop.
classify(Datagram, Registry) ->
    case roadrunner_quic_packet:dcid(Datagram, ?SCID_LEN) of
        {ok, DCID} ->
            case roadrunner_quic_cid_registry:lookup(Registry, DCID) of
                {ok, ConnPid} -> {forward, ConnPid};
                error -> classify_unrouted(Datagram, DCID, Registry)
            end;
        {error, _Reason} ->
            %% A datagram whose routable connection id could not be read: a
            %% short header shorter than the fixed id length, or a long header
            %% carrying a connection id longer than v1 allows. It is no known
            %% connection and no v1 Initial, but an unsupported-version long
            %% header still triggers Version Negotiation (connection-id length
            %% must not gate that decision, RFC 9000 §17.2.1).
            maybe_version_negotiation(Datagram)
    end.

%% An unknown destination id at the §14.1 floor: a v1 Initial starts a
%% connection; anything else falls through to the Version Negotiation check. The
%% client's source id is read alongside the routing id: the server addresses its
%% replies with it (RFC 9000 §7.2), distinct from the client's destination id
%% (which derives the Initial keys and echoes as original_destination_connection_id).
%% A floor-sized v1 Initial always carries both ids, so long_header_info succeeds.
-spec classify_unrouted(binary(), binary(), roadrunner_quic_cid_registry:t()) ->
    {forward, pid()}
    | {spawn, binary(), binary()}
    | {version_negotiation, binary(), binary()}
    | {stateless_reset, binary()}
    | drop.
classify_unrouted(<<0:1, _:7, _/binary>> = Datagram, DCID, Registry) ->
    classify_short(Datagram, DCID, Registry);
classify_unrouted(Datagram, DCID, _Registry) ->
    case is_v1_initial(Datagram) andalso byte_size(Datagram) >= ?MIN_INITIAL_DATAGRAM of
        true ->
            {ok, #{scid := SCID}} = roadrunner_quic_packet:long_header_info(Datagram),
            {spawn, DCID, SCID};
        false ->
            maybe_version_negotiation(Datagram)
    end.

%% A short header to no connection id we route (RFC 9000 §10.3.1): its last
%% 16 bytes may be the stateless reset token of a client that has lost its
%% state, whose reset carries random bytes where our id would be, so the
%% connection holding that token gets it. Any other one large enough draws a
%% Stateless Reset of ours; one too small to hold a reset is no valid packet
%% (§10.3) and is dropped.
-spec classify_short(binary(), binary(), roadrunner_quic_cid_registry:t()) ->
    {forward, pid()} | {stateless_reset, binary()} | drop.
classify_short(Datagram, DCID, Registry) when byte_size(Datagram) >= ?MIN_STATELESS_RESET ->
    Skip = byte_size(Datagram) - ?RESET_TOKEN_LEN,
    <<_:Skip/binary, Tail/binary>> = Datagram,
    case roadrunner_quic_cid_registry:lookup_reset(Registry, Tail) of
        {ok, ConnPid} -> {forward, ConnPid};
        error when byte_size(Datagram) > ?MIN_STATELESS_RESET -> {stateless_reset, DCID};
        error -> drop
    end;
classify_short(_Datagram, _DCID, _Registry) ->
    drop.

%% RFC 9000 §5.2.2: answer an unsupported-version long header (one we cannot
%% serve, and which is not itself a Version Negotiation packet, version 0) with
%% Version Negotiation, provided the datagram is at the 1200-byte floor; a
%% server MUST drop smaller such packets, and short headers never negotiate.
-spec maybe_version_negotiation(binary()) -> {version_negotiation, binary(), binary()} | drop.
maybe_version_negotiation(Datagram) when byte_size(Datagram) >= ?MIN_INITIAL_DATAGRAM ->
    case roadrunner_quic_packet:long_header_info(Datagram) of
        {ok, #{version := Version, dcid := DCID, scid := SCID}} when
            Version =/= 0, Version =/= ?QUIC_V1
        ->
            {version_negotiation, DCID, SCID};
        _ ->
            drop
    end;
maybe_version_negotiation(_Datagram) ->
    drop.

-spec is_v1_initial(binary()) -> boolean().
is_v1_initial(<<1:1, _Fixed:1, 0:2, _TypeSpecific:4, Version:32, _/binary>>) ->
    Version =:= ?QUIC_V1;
is_v1_initial(_Datagram) ->
    false.

%% Spawn a connection for a new client and feed it its first Initial, in the
%% order the handshake depends on: spawn -> link -> register both connection
%% ids -> run the handler for the owner -> install the owner synchronously ->
%% feed. `ClientSCID` is the client's source id; the connection addresses its
%% replies with it (RFC 9000 §7.2), while `ClientDCID` is the routing id (also
%% the Initial-key and original_destination_connection_id anchor).
-spec spawn_connection(
    binary(), {inet:ip_address(), inet:port_number()}, binary(), binary(), #listener{}
) ->
    #listener{}.
spawn_connection(
    Datagram,
    Peer,
    ClientDCID,
    ClientSCID,
    #listener{socket = Socket, registry = Registry, handler = Handler} = State
) ->
    ServerSCID = crypto:strong_rand_bytes(?SCID_LEN),
    {Ip, _Port} = Peer,
    Config = conn_config(ClientDCID, ClientSCID, ServerSCID, Peer, State),
    {ok, ConnPid} = roadrunner_quic_connection:start(
        Socket, Config#{address_validated => token_validates(Datagram, Ip, Registry)}
    ),
    true = link(ConnPid),
    ok = roadrunner_quic_cid_registry:register_pair(Registry, ClientDCID, ServerSCID, ConnPid),
    ok = install_owner(ConnPid, Handler),
    _ = ConnPid ! {quic_datagram, Peer, Datagram},
    State.

%% RFC 9000 §8.1.3: whether the Initial's token validates the client's
%% address: one of ours, sealed for the IP the datagram came from, still
%% within its lifetime, and not spent before (§8.1.4: replay MUST be
%% prevented or limited). Any other token, including one this server cannot
%% open after losing its secret, is no token at all: the connection goes on
%% unvalidated rather than failing.
-spec token_validates(binary(), inet:ip_address(), roadrunner_quic_cid_registry:t()) -> boolean().
token_validates(Datagram, Ip, Registry) ->
    maybe
        {ok, <<_, _/binary>> = Token} ?= roadrunner_quic_packet:initial_token(Datagram),
        Now = erlang:system_time(second),
        {ok, Id} ?=
            roadrunner_quic_token:open(
                roadrunner_quic_cid_registry:token_key(Registry), Token, Ip, Now
            ),
        roadrunner_quic_cid_registry:spend_token(
            Registry, Id, roadrunner_quic_token:oldest(Now)
        )
    else
        _ -> false
    end.

%% Run the connection_handler to get the application owner and install it
%% synchronously. On a refusal (e.g. {error, max_clients}) the owner is simply
%% not installed; the connection will idle out (graceful refusal is a later
%% slice).
-spec install_owner(pid(), fun((pid()) -> {ok, pid()} | {error, term()})) -> ok.
install_owner(ConnPid, Handler) ->
    case Handler(ConnPid) of
        {ok, Owner} when is_pid(Owner) ->
            set_owner_sync(ConnPid, Owner);
        {error, Reason} ->
            logger:warning(#{what => quic_connection_handler_refused, reason => Reason}),
            ok
    end.

%% The synchronous set_owner round-trip (mirrors the connection's control-call
%% wire): the connection records the owner before any datagram drives the
%% handshake, so the {connected, _} event cannot race ahead of ownership. A
%% private monitor guards against the connection dying before it replies (e.g.
%% a crash in its init): without it the loop would block here forever, which in
%% a pool is a silent loss of one listener. The connection's id rows are reaped
%% by the loop's own monitor (set in spawn_connection), so the abort here only
%% skips the now-moot ownership install.
-spec set_owner_sync(pid(), pid()) -> ok.
set_owner_sync(ConnPid, Owner) ->
    Ref = make_ref(),
    MonRef = monitor(process, ConnPid),
    _ = ConnPid ! {quic_call, self(), Ref, {set_owner, Owner}},
    receive
        {quic_reply, Ref, ok} ->
            _ = demonitor(MonRef, [flush]),
            ok;
        {'DOWN', MonRef, process, ConnPid, _Reason} ->
            ok
    end.

-spec conn_config(
    binary(), binary(), binary(), {inet:ip_address(), inet:port_number()}, #listener{}
) ->
    roadrunner_quic_conn_state:config().
conn_config(ClientDCID, ClientSCID, ServerSCID, Peer, #listener{
    registry = Registry,
    cert_chain = CertChain,
    priv_key = PrivKey,
    alpn = Alpn,
    transport_params = TransportParams,
    stream_credit = StreamCredit
}) ->
    ResetKey = roadrunner_quic_cid_registry:reset_key(Registry),
    #{
        dcid => ClientDCID,
        scid => ServerSCID,
        peer_scid => ClientSCID,
        peer => Peer,
        %% The connection routes the spare ids it issues through the shared
        %% registry, each with a reset token under the registry's key.
        registry => Registry,
        reset_key => ResetKey,
        %% The key the NEW_TOKEN tokens the connection issues are sealed under.
        token_key => roadrunner_quic_cid_registry:token_key(Registry),
        cert_chain => CertChain,
        priv_key => PrivKey,
        alpn => Alpn,
        transport_params => TransportParams#{
            original_destination_connection_id => ClientDCID,
            initial_source_connection_id => ServerSCID,
            %% The handshake id's token (RFC 9000 §10.3, §18.2); the ids
            %% issued later carry theirs in NEW_CONNECTION_ID.
            stateless_reset_token => roadrunner_quic_cid_registry:reset_token(ResetKey, ServerSCID)
        },
        server_random => crypto:strong_rand_bytes(32),
        stream_credit => StreamCredit
    }.
