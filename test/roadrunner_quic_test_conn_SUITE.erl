-module(roadrunner_quic_test_conn_SUITE).
-moduledoc false.

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1]).
-export([
    native_client_completes_handshake/1,
    native_client_completes_chacha20_handshake/1,
    native_client_completes_p256_handshake/1
]).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        native_client_completes_handshake,
        native_client_completes_chacha20_handshake,
        native_client_completes_p256_handshake
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

%% The same with secp256r1 as the only group the client offers: the server
%% answers with its own P-256 share (RFC 8446 §4.2.8.2).
native_client_completes_p256_handshake(_Config) ->
    assert_native_handshake(#{group => secp256r1}).

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
