-module(roadrunner_quic_connection_tests).

-include_lib("eunit/include/eunit.hrl").

-define(CONN, roadrunner_quic_connection).
-define(TC, roadrunner_quic_test_client).
-define(FINISHED, 20).

%% A fixed client DCID (the server's routing id) and an 8-byte server SCID
%% (matching the server's fixed ?SCID_LEN).
-define(DCID, <<1, 2, 3, 4, 5, 6, 7, 8>>).
-define(SCID, <<8, 7, 6, 5, 4, 3, 2, 1>>).

%% Each case spawns a fresh shell over a pair of loopback sockets: the
%% server socket the shell sends on, and a client socket bound so the
%% shell's datagrams land where the test can read them.
shell_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun handshake_completes/1,
        fun system_message_handled/1,
        fun unsupported_call_replies/1,
        fun cast_ignored/1,
        fun stray_message_ignored/1,
        fun stale_timer_fire_ignored/1,
        fun loss_timer_fires/1
    ]}.

setup() ->
    {ok, ServerSocket} = roadrunner_quic_socket:open(0),
    {ok, ClientSocket} = roadrunner_quic_socket:open(0),
    {ok, {_Ip, ClientPort}} = roadrunner_quic_socket:sockname(ClientSocket),
    Peer = {{127, 0, 0, 1}, ClientPort},
    {Config, Ctx} = config(Peer),
    {ok, Shell} = ?CONN:start(ServerSocket, Config),
    #{shell => Shell, peer => Peer, client => ClientSocket, server => ServerSocket, ctx => Ctx}.

cleanup(#{shell := Shell, client := ClientSocket, server := ServerSocket}) ->
    exit(Shell, kill),
    ok = roadrunner_quic_socket:close(ClientSocket),
    ok = roadrunner_quic_socket:close(ServerSocket).

%% =============================================================================
%% A full handshake driven over real sockets reaches HANDSHAKE_DONE.
%% =============================================================================

handshake_completes(#{shell := Shell, peer := Peer, client := ClientSocket, ctx := Ctx}) ->
    fun() ->
        #{client_priv := ClientPriv, server_pub := ServerPub} = Ctx,

        %% Client Initial -> the shell answers with its first flight.
        {InitialDatagram, ClientHelloFramed} = client_hello(Ctx),
        Shell ! {quic_datagram, Peer, InitialDatagram},
        Flight1 = recv_all(ClientSocket),

        ServerHello = ?TC:crypto_bytes(
            Flight1,
            initial,
            #{initial => roadrunner_quic_keys:initial_server(?DCID)},
            byte_size(?DCID)
        ),
        ?assertNotEqual(<<>>, ServerHello),
        Shared = crypto:compute_key(ecdh, ServerPub, ClientPriv, x25519),
        HandshakeSecret = roadrunner_quic_tls_crypto:handshake_secret(
            roadrunner_quic_tls_crypto:early_secret(), Shared
        ),
        HelloHash = roadrunner_quic_tls_crypto:transcript_hash([ClientHelloFramed, ServerHello]),
        ClientHsSecret = roadrunner_quic_tls_crypto:traffic_secret(
            client, handshake, HandshakeSecret, HelloHash
        ),
        ServerHsSecret = roadrunner_quic_tls_crypto:traffic_secret(
            server, handshake, HandshakeSecret, HelloHash
        ),
        Flight = ?TC:crypto_bytes(
            Flight1,
            handshake,
            #{handshake => roadrunner_quic_keys:traffic_keys(ServerHsSecret)},
            byte_size(?DCID)
        ),
        FinishedHash = roadrunner_quic_tls_crypto:transcript_hash([
            ClientHelloFramed, ServerHello, Flight
        ]),

        %% Client Finished -> the shell becomes connected and sends HANDSHAKE_DONE.
        ClientFinishedBody = roadrunner_quic_tls_crypto:verify_data(
            roadrunner_quic_tls_crypto:finished_key(ClientHsSecret), FinishedHash
        ),
        ClientFinishedFramed = iolist_to_binary(
            roadrunner_quic_tls_handshake:encode(?FINISHED, ClientFinishedBody)
        ),
        FinishedDatagram = ?TC:seal(
            handshake,
            0,
            roadrunner_quic_keys:traffic_keys(ClientHsSecret),
            [{crypto, 0, ClientFinishedFramed}],
            ?DCID,
            ?SCID
        ),
        Shell ! {quic_datagram, Peer, FinishedDatagram},
        Flight2 = recv_all(ClientSocket),

        MasterSecret = roadrunner_quic_tls_crypto:master_secret(HandshakeSecret),
        ServerApSecret = roadrunner_quic_tls_crypto:traffic_secret(
            server, application, MasterSecret, FinishedHash
        ),
        AppFrames = ?TC:frames(
            Flight2,
            application,
            #{application => roadrunner_quic_keys:traffic_keys(ServerApSecret)},
            byte_size(?DCID)
        ),
        ?assert(lists:member(handshake_done, AppFrames))
    end.

%% =============================================================================
%% OTP / stray messages keep the long-lived loop alive.
%% =============================================================================

system_message_handled(#{shell := Shell}) ->
    fun() ->
        %% sys:get_state drives the {system, _, _} clause; the handler state
        %% is opaque, so the assertion is only that the loop resumed.
        _State = sys:get_state(Shell),
        ?assert(is_process_alive(Shell))
    end.

unsupported_call_replies(#{shell := Shell}) ->
    fun() ->
        ?assertEqual({error, not_supported}, gen_server:call(Shell, ping))
    end.

cast_ignored(#{shell := Shell}) ->
    fun() ->
        ok = gen_server:cast(Shell, anything),
        ?assert(still_running(Shell))
    end.

stray_message_ignored(#{shell := Shell}) ->
    fun() ->
        Shell ! some_stray_message,
        ?assert(still_running(Shell))
    end.

%% =============================================================================
%% Timers.
%% =============================================================================

stale_timer_fire_ignored(#{shell := Shell}) ->
    fun() ->
        %% A timer fire whose ref is not the armed one is dropped.
        Shell ! {?CONN, timer, pto, make_ref()},
        ?assert(still_running(Shell))
    end.

loss_timer_fires(#{shell := Shell, peer := Peer, client := ClientSocket, ctx := Ctx}) ->
    {timeout, 10, fun() ->
        %% Feed only the ClientHello so the handshake stalls; the shell sends
        %% its flight and arms a probe timer that fires with no peer response,
        %% driving the armed-ref timer path. The probe timeout is ~1s (initial
        %% RTT 333ms), so wait past it. That the re-arm backs off rather than
        %% busy-spinning is proven in roadrunner_quic_conn_state_tests
        %% (pto_backoff_advances_deadline_test); here we only confirm the shell
        %% handled the fire and stayed alive.
        {InitialDatagram, _ClientHelloFramed} = client_hello(Ctx),
        Shell ! {quic_datagram, Peer, InitialDatagram},
        _Flight = recv_all(ClientSocket),
        timer:sleep(1500),
        ?assert(still_running(Shell))
    end}.

%% =============================================================================
%% Helpers
%% =============================================================================

config(Peer) ->
    {Scheme, PrivKey} = ?TC:key_material(),
    {ClientPub, ClientPriv} = ?TC:gen_keypair(),
    {ServerPub, ServerPriv} = ?TC:gen_keypair(),
    Config = #{
        dcid => ?DCID,
        scid => ?SCID,
        peer => Peer,
        cert_chain => [~"leaf-cert-der"],
        priv_key => PrivKey,
        alpn => ~"h3",
        transport_params => #{
            original_destination_connection_id => ?DCID,
            initial_source_connection_id => ?SCID
        },
        eph_pub => ServerPub,
        eph_priv => ServerPriv,
        server_random => crypto:strong_rand_bytes(32)
    },
    {Config, #{
        scheme => Scheme,
        client_pub => ClientPub,
        client_priv => ClientPriv,
        server_pub => ServerPub
    }}.

client_hello(#{scheme := Scheme, client_pub := ClientPub}) ->
    Framed = ?TC:client_hello_framed(Scheme, ClientPub),
    Datagram = ?TC:seal(
        initial, 0, roadrunner_quic_keys:initial_client(?DCID), [{crypto, 0, Framed}], ?DCID, ?SCID
    ),
    {Datagram, Framed}.

%% Collect datagrams the shell sent until a quiet gap (no in-test loss, so
%% the whole flight arrives back to back).
recv_all(Socket) ->
    case roadrunner_quic_socket:recv(Socket, 200) of
        {ok, _Peer, Data} -> [Data | recv_all(Socket)];
        {error, timeout} -> []
    end.

%% A synchronous round-trip after an async message proves the loop consumed
%% that message (mailbox order) and is still looping.
still_running(Shell) ->
    _State = sys:get_state(Shell),
    is_process_alive(Shell).
