-module(roadrunner_quic_test_conn_SUITE).
-moduledoc false.

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1]).
-export([
    native_client_completes_handshake/1,
    native_client_completes_chacha20_handshake/1,
    native_client_completes_aes_256_gcm_handshake/1,
    native_client_completes_p256_handshake/1,
    lost_initial_is_resent/1,
    duplicate_initial_is_one_connection/1
]).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        native_client_completes_handshake,
        native_client_completes_chacha20_handshake,
        native_client_completes_aes_256_gcm_handshake,
        native_client_completes_p256_handshake,
        lost_initial_is_resent,
        duplicate_initial_is_one_connection
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(crypto),
    {ok, _} = application:ensure_all_started(ssl),
    Config.

end_per_suite(_Config) ->
    ok.

%% =============================================================================
%% The native QUIC client completes a real handshake against the native
%% connection shell over loopback, with no dep involved on either side.
%% =============================================================================

native_client_completes_handshake(_Config) ->
    assert_native_handshake(#{}).

%% The same over TLS_CHACHA20_POLY1305_SHA256, the only suite the client
%% offers: the Handshake and 1-RTT packets go out and come back under
%% ChaCha20-Poly1305 with ChaCha20 header protection (RFC 9001 §5.3, §5.4.4).
native_client_completes_chacha20_handshake(_Config) ->
    assert_native_handshake(#{cipher_suites => [16#1303]}).

%% The same over TLS_AES_256_GCM_SHA384: both ends run the key schedule over
%% SHA-384 (RFC 8446 §7.1), and the Handshake and 1-RTT packets use
%% AES-256-GCM with AES-256 header protection (RFC 9001 §5.3, §5.4.3).
native_client_completes_aes_256_gcm_handshake(_Config) ->
    assert_native_handshake(#{cipher_suites => [16#1302]}).

%% The same with secp256r1 as the only group the client offers: the server
%% answers with its own P-256 share (RFC 8446 §4.2.8.2).
native_client_completes_p256_handshake(_Config) ->
    assert_native_handshake(#{group => secp256r1}).

%% The client resends its Initial until the server answers (RFC 9002 §6.2.4),
%% so a first Initial lost on the way does not fail the connect.
lost_initial_is_resent(_Config) ->
    assert_one_connection(#{initial_sends => 0}).

%% A resent Initial that crosses the server's first reply reaches the server
%% as a duplicate: the listener routes it to the connection the first one
%% started, which still serves the request, and no second connection starts.
duplicate_initial_is_one_connection(_Config) ->
    assert_one_connection(#{initial_sends => 2}).

assert_one_connection(Opts) ->
    {ok, _} = roadrunner_listener:start_link(?MODULE, #{
        port => 0,
        protocols => [http3],
        tls => roadrunner_test_certs:server_opts(),
        routes => roadrunner_hello_handler
    }),
    try
        {ok, Conn} = roadrunner_quic_test_h3:connect(
            {127, 0, 0, 1}, roadrunner_listener:port(?MODULE), Opts
        ),
        Request = [
            {~":method", ~"GET"},
            {~":scheme", ~"https"},
            {~":authority", ~"localhost"},
            {~":path", ~"/"}
        ],
        ?assertMatch({200, _, _}, roadrunner_quic_test_h3:request(Conn, Request, <<>>)),
        ?assertMatch(#{active_clients := 1}, roadrunner_listener:info(?MODULE)),
        ok = roadrunner_quic_test_h3:close(Conn)
    after
        ok = roadrunner_listener:stop(?MODULE)
    end.

assert_native_handshake(Opts) ->
    %% A minimal in-test listener: the pump owns one UDP socket, reads it, and
    %% routes each datagram to a per-peer native shell that replies on the same
    %% socket (the same harness the dep-client interop suite uses).
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

    Result =
        case roadrunner_quic_test_conn:connect({127, 0, 0, 1}, Port, Opts) of
            {ok, Conn} ->
                ok = roadrunner_quic_test_conn:close(Conn),
                ok;
            {error, Reason} ->
                {error, Reason}
        end,

    unlink(Pump),
    exit(Pump, shutdown),
    ?assertEqual(ok, Result).

%% =============================================================================
%% Listener pump + per-connection shell wiring (mirrors the interop suite)
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

start_shell(Socket, Peer, FirstDatagram) ->
    {ok, ClientDCID} = roadrunner_quic_packet:dcid(FirstDatagram, 8),
    {ok, #{scid := ClientSCID}} = roadrunner_quic_packet:long_header_info(FirstDatagram),
    ServerSCID = crypto:strong_rand_bytes(8),
    {CertChain, PrivKey} = cert_key(),
    Config = #{
        dcid => ClientDCID,
        scid => ServerSCID,
        peer_scid => ClientSCID,
        peer => Peer,
        %% The pump routes by peer address, so the ids the connection issues
        %% are registered in a table nothing reads.
        registry => roadrunner_quic_cid_registry:new(),
        reset_key => crypto:strong_rand_bytes(32),
        token_key => crypto:strong_rand_bytes(32),
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
