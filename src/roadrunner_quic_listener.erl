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
%% Version Negotiation packet (RFC 9000 §5.2.2). Spawning follows the strict
%% ordering the handshake depends on
%% (RFC 9000 / the dep's contract): spawn the connection, link it (so the
%% listener's own shutdown tears its connections down, and a connection's death
%% reaps its routing rows), register its CIDs (so a fast follow-up datagram
%% already routes), run the connection_handler to get the application owner,
%% install the owner SYNCHRONOUSLY (so ownership transfers before the handshake
%% can complete and race the `{connected, _}` event), and only then feed the
%% first Initial. Slot limiting, telemetry, and drain stay in the owner the
%% handler returns; the listener owns none of them.
%%
%% A new server Source Connection ID is generated per connection at a fixed
%% length, so short-header 1-RTT packets (which carry no CID-length field)
%% demux by slicing that many leading bytes. `roadrunner_quic_listener_sup`
%% runs a SO_REUSEPORT pool of these listeners sharing one injected registry.

-export([start_link/1, get_port/1, stop/1]).
-export([init/1]).
%% Exported for exhaustive eunit branch coverage of the pure routing decision.
-export([classify/2]).

-export_type([opts/0]).

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

-type opts() :: #{
    port := inet:port_number(),
    cert_chain := [binary()],
    priv_key := public_key:private_key(),
    alpn := binary(),
    transport_params := roadrunner_quic_transport_params:params(),
    connection_handler := fun((pid()) -> {ok, pid()} | {error, term()}),
    reuseport => boolean(),
    %% The connection-id routing table. A SO_REUSEPORT pool injects one shared
    %% table (owned by the pool supervisor) so a datagram landing on any pool
    %% socket routes to the owning connection; a standalone listener omits it
    %% and creates (and owns) its own.
    registry => roadrunner_quic_cid_registry:t()
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
    handler :: fun((pid()) -> {ok, pid()} | {error, term()})
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
    %% connection's `'EXIT'` reaps its routing rows, and the listener's own
    %% shutdown then tears its connections down (so their owners and stream
    %% workers stop), matching the dep's listener-stop semantics the drain
    %% relies on.
    process_flag(trap_exit, true),
    [Parent | _] = get('$ancestors'),
    ReusePort = maps:get(reuseport, Opts, false),
    case roadrunner_quic_socket:open(Port, #{active => once, reuseport => ReusePort}) of
        {ok, Socket} ->
            {ok, {_Ip, BoundPort}} = roadrunner_quic_socket:sockname(Socket),
            proc_lib:set_label({?MODULE, BoundPort}),
            proc_lib:init_ack({ok, self()}),
            %% A pool injects one shared registry; a standalone listener owns its
            %% own. Either way the listener never deletes the table on stop, so a
            %% shared one outlives any single listener.
            Registry = maps:get(registry, Opts, roadrunner_quic_cid_registry:new()),
            loop(#listener{
                socket = Socket,
                port = BoundPort,
                parent = Parent,
                registry = Registry,
                cert_chain = CertChain,
                priv_key = PrivKey,
                alpn = Alpn,
                transport_params = TransportParams,
                handler = Handler
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
        {'EXIT', Pid, _Reason} ->
            %% A linked connection ended (clean close, error, or our teardown
            %% reaping it); drop its routing rows. delete_pid keys on the pid, so
            %% it only reaps that connection's ids.
            ok = roadrunner_quic_cid_registry:delete_pid(State#listener.registry, Pid),
            loop(State);
        Message ->
            loop(handle_message(Message, State))
    end.

%% A datagram from the active socket is routed (re-arming the socket first so
%% the next datagram is already queued during the spawn round-trip); anything
%% else is a stray message and dropped.
-spec handle_message(term(), #listener{}) -> #listener{}.
handle_message(Message, #listener{socket = Socket} = State) ->
    case roadrunner_quic_socket:from_message(Socket, Message) of
        {ok, Peer, Datagram} ->
            ok = roadrunner_quic_socket:activate(Socket),
            route(Datagram, Peer, State);
        ignore ->
            State
    end.

%% =============================================================================
%% Routing
%% =============================================================================

%% Execute a datagram's routing decision: forward to the owning connection,
%% spawn one for a new client, answer with Version Negotiation, or drop.
-spec route(binary(), {inet:ip_address(), inet:port_number()}, #listener{}) -> #listener{}.
route(Datagram, Peer, #listener{registry = Registry} = State) ->
    case classify(Datagram, Registry) of
        {forward, ConnPid} ->
            _ = ConnPid ! {quic_datagram, Peer, Datagram},
            State;
        {spawn, ClientDCID, ClientSCID} ->
            spawn_connection(Datagram, Peer, ClientDCID, ClientSCID, State);
        {version_negotiation, ClientDCID, ClientSCID} ->
            send_version_negotiation(ClientDCID, ClientSCID, Peer, State);
        drop ->
            State
    end.

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

%% Decide a datagram's fate from its connection ids and the routing table (a
%% pure decision given the table): `{forward, Pid}` to the owning connection,
%% `{spawn, DCID, SCID}` for a QUIC v1 Initial (at the RFC 9000 §14.1 1200-byte
%% floor) to an unknown id (carrying the client's source id, which the server's
%% replies address per §7.2), `{version_negotiation, DCID, SCID}` for an unsupported
%% version at that floor (RFC 9000 §5.2.2), or `drop` otherwise: a malformed or
%% short-header packet to an unknown id, a v1 Initial below the floor, or an
%% unsupported-version packet below it (a server MUST discard those). The
%% forward path is size-unconditional; the owning connection enforces §14.1 on
%% its own received Initials.
-doc false.
-spec classify(binary(), roadrunner_quic_cid_registry:t()) ->
    {forward, pid()}
    | {spawn, binary(), binary()}
    | {version_negotiation, binary(), binary()}
    | drop.
classify(Datagram, Registry) ->
    case roadrunner_quic_packet:dcid(Datagram, ?SCID_LEN) of
        {ok, DCID} ->
            case roadrunner_quic_cid_registry:lookup(Registry, DCID) of
                {ok, ConnPid} -> {forward, ConnPid};
                error -> classify_unrouted(Datagram, DCID)
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
-spec classify_unrouted(binary(), binary()) ->
    {spawn, binary(), binary()} | {version_negotiation, binary(), binary()} | drop.
classify_unrouted(Datagram, DCID) ->
    case is_v1_initial(Datagram) andalso byte_size(Datagram) >= ?MIN_INITIAL_DATAGRAM of
        true ->
            {ok, #{scid := SCID}} = roadrunner_quic_packet:long_header_info(Datagram),
            {spawn, DCID, SCID};
        false ->
            maybe_version_negotiation(Datagram)
    end.

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
    {ok, ConnPid} = roadrunner_quic_connection:start(
        Socket, conn_config(ClientDCID, ClientSCID, ServerSCID, Peer, State)
    ),
    true = link(ConnPid),
    ok = roadrunner_quic_cid_registry:register_pair(Registry, ClientDCID, ServerSCID, ConnPid),
    ok = install_owner(ConnPid, Handler),
    _ = ConnPid ! {quic_datagram, Peer, Datagram},
    State.

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
    cert_chain = CertChain, priv_key = PrivKey, alpn = Alpn, transport_params = TransportParams
}) ->
    {EphPub, EphPriv} = crypto:generate_key(ecdh, x25519),
    #{
        dcid => ClientDCID,
        scid => ServerSCID,
        peer_scid => ClientSCID,
        peer => Peer,
        cert_chain => CertChain,
        priv_key => PrivKey,
        alpn => Alpn,
        transport_params => TransportParams#{
            original_destination_connection_id => ClientDCID,
            initial_source_connection_id => ServerSCID
        },
        eph_pub => EphPub,
        eph_priv => EphPriv,
        server_random => crypto:strong_rand_bytes(32)
    }.
