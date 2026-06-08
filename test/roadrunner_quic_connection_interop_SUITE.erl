-module(roadrunner_quic_connection_interop_SUITE).
-moduledoc false.

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1]).
-export([dep_client_completes_handshake/1]).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [dep_client_completes_handshake].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(crypto),
    {ok, _} = application:ensure_all_started(ssl),
    %% The dep `quic` app backs the test CLIENT; the native server shell
    %% does not need it. The default `pg` scope hosts the client's drain
    %% group, started unlinked so it outlives this transient process.
    {ok, _} = application:ensure_all_started(quic),
    ok = ensure_pg_started(),
    Config.

end_per_suite(_Config) ->
    ok.

%% =============================================================================
%% The dep `quic` client completes a real QUIC handshake against the native
%% connection shell over loopback.
%% =============================================================================

dep_client_completes_handshake(_Config) ->
    %% A minimal in-test listener: the pump owns one UDP socket, reads it,
    %% and routes each datagram to a per-peer native shell that sends its
    %% replies back on the same socket. Linking the pump (and its shells)
    %% to this process makes a handshake crash surface as a test failure
    %% rather than a silent timeout.
    Test = self(),
    Pump = spawn_link(fun() ->
        {ok, Socket} = roadrunner_quic_socket:open(0),
        {ok, {_Ip, Port}} = roadrunner_quic_socket:sockname(Socket),
        Test ! {pump_port, self(), Port},
        pump_loop(Socket, #{})
    end),
    Port =
        receive
            {pump_port, Pump, P} -> P
        after 2000 ->
            exit(pump_no_port)
        end,

    %% Drive the dep as a raw QUIC client. The QUIC `connected` event fires
    %% on transport-handshake completion; the H3 SETTINGS exchange (needed
    %% by quic_h3:wait_connected) belongs to the owner, a later slice, so we
    %% assert at the QUIC layer.
    {ok, Conn} = quic:connect(
        ~"127.0.0.1", Port, #{alpn => [~"h3"], verify => verify_none}, self()
    ),
    Result =
        receive
            {quic, Conn, {connected, _Info}} -> ok
        after 5000 ->
            timeout
        end,

    _ = quic:close(Conn),
    unlink(Pump),
    exit(Pump, shutdown),
    ?assertEqual(ok, Result).

%% =============================================================================
%% Listener pump + per-connection shell wiring
%% =============================================================================

pump_loop(Socket, Conns) ->
    case roadrunner_quic_socket:recv(Socket, 500) of
        {ok, Peer, Datagram} ->
            Shell =
                case Conns of
                    #{Peer := Existing} -> Existing;
                    #{} -> start_shell(Socket, Peer, Datagram)
                end,
            Shell ! {quic_datagram, Peer, Datagram},
            pump_loop(Socket, Conns#{Peer => Shell});
        {error, timeout} ->
            pump_loop(Socket, Conns)
    end.

%% Build the per-connection config from the first Initial and spawn (and
%% link) the native shell. The reply DCID echoes the client's source CID
%% (RFC 9000 §17.2/§7.2); the client's destination id is kept only as the
%% routing / Initial-key / original_destination_connection_id anchor.
start_shell(Socket, Peer, FirstDatagram) ->
    {ok, ClientDCID} = roadrunner_quic_packet:dcid(FirstDatagram, 8),
    {ok, #{scid := ClientSCID}} = roadrunner_quic_packet:long_header_info(FirstDatagram),
    ServerSCID = crypto:strong_rand_bytes(8),
    {EphPub, EphPriv} = crypto:generate_key(ecdh, x25519),
    {CertChain, PrivKey} = cert_key(),
    Config = #{
        dcid => ClientDCID,
        scid => ServerSCID,
        peer_scid => ClientSCID,
        peer => Peer,
        cert_chain => CertChain,
        priv_key => PrivKey,
        alpn => ~"h3",
        transport_params => #{
            original_destination_connection_id => ClientDCID,
            initial_source_connection_id => ServerSCID,
            initial_max_data => 1048576,
            initial_max_stream_data_bidi_local => 262144,
            initial_max_stream_data_bidi_remote => 262144,
            initial_max_stream_data_uni => 262144,
            initial_max_streams_bidi => 100,
            initial_max_streams_uni => 100,
            max_idle_timeout => 30000
        },
        eph_pub => EphPub,
        eph_priv => EphPriv,
        server_random => crypto:strong_rand_bytes(32)
    },
    {ok, Shell} = roadrunner_quic_connection:start(Socket, Config),
    true = link(Shell),
    Shell.

cert_key() ->
    Opts = roadrunner_test_certs:server_opts(),
    {cert, CertDer} = lists:keyfind(cert, 1, Opts),
    {key, {KeyType, KeyDer}} = lists:keyfind(key, 1, Opts),
    {[CertDer], public_key:der_decode(KeyType, KeyDer)}.

ensure_pg_started() ->
    case whereis(pg) of
        undefined ->
            case pg:start_link() of
                {ok, Pid} ->
                    _ = unlink(Pid),
                    ok;
                {error, {already_started, _}} ->
                    ok
            end;
        _ ->
            ok
    end.
