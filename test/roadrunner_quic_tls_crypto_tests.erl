-module(roadrunner_quic_tls_crypto_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_quic_tls_crypto).

%% =============================================================================
%% RFC 8448 §3 (Simple 1-RTT Handshake) key schedule — the authority.
%% =============================================================================

transcript_hash_empty_test() ->
    %% SHA-256 of the empty string, the canonical digest.
    ?assertEqual(
        hex(~"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        ?M:transcript_hash(<<>>)
    ).

early_secret_test() ->
    %% The no-PSK Early Secret, HKDF-Extract(0, 0).
    ?assertEqual(
        hex(~"33ad0a1c607ec03b09e6cd9893680ce210adf300aa1f2660e1b22e10f170f92a"),
        ?M:early_secret()
    ).

derive_secret_test() ->
    %% Derive-Secret(early_secret, "derived", "").
    ?assertEqual(
        hex(~"6f2615a108c702c5678f54fc9dbab69716c076189c48250cebeac3576c3611ba"),
        ?M:derive_secret(?M:early_secret(), ~"derived", ?M:transcript_hash(<<>>))
    ).

handshake_secret_test() ->
    %% handshake_secret from the §3 x25519 shared secret.
    ?assertEqual(
        hex(~"1dc826e93606aa6fdc0aadc12f741b01046aa6b99f691ed221a9f0ca043fbeac"),
        ?M:handshake_secret(?M:early_secret(), shared_secret())
    ).

master_secret_test() ->
    HandshakeSecret = ?M:handshake_secret(?M:early_secret(), shared_secret()),
    ?assertEqual(
        hex(~"18df06843d13a08bf2a449844c5f8a478001bc4d4c627984d5a41da8d0402919"),
        ?M:master_secret(HandshakeSecret)
    ).

%% =============================================================================
%% RFC 8448 §3 traffic secrets + Finished — the authority. The
%% transcript-hash contexts are the §3 values.
%% =============================================================================

rfc8448_traffic_secrets_test() ->
    HandshakeSecret = ?M:handshake_secret(?M:early_secret(), shared_secret()),
    MasterSecret = ?M:master_secret(HandshakeSecret),
    HsHash = hex(~"860c06edc07858ee8e78f0e7428c58edd6b43f2ca3e6e95f02ed063cf0e1cad8"),
    ApHash = hex(~"96088718a85d2c0d2b21a16a7f637eba132bd1a01feac57b8f8ec571ef41c47c"),
    ?assertEqual(
        hex(~"b3eddb126e067f35a780b3abf45e2d8f3b1a950738f52e9600746a0e27a55a21"),
        ?M:traffic_secret(client, handshake, HandshakeSecret, HsHash)
    ),
    ?assertEqual(
        hex(~"b67b7d690cc16c4e75e54213cb2d37b4e9c912bcded9105d42befd59d391ad38"),
        ?M:traffic_secret(server, handshake, HandshakeSecret, HsHash)
    ),
    ?assertEqual(
        hex(~"775fae04efd2ee7a546c9544a5070c639fe9a67945b7d18310b269e0e9e98069"),
        ?M:traffic_secret(client, application, MasterSecret, ApHash)
    ),
    ?assertEqual(
        hex(~"40d3a34fd7b0c9651bb55866a650eddf179237a2923b2124be7f6eae319aeca0"),
        ?M:traffic_secret(server, application, MasterSecret, ApHash)
    ).

rfc8448_finished_test() ->
    HandshakeSecret = ?M:handshake_secret(?M:early_secret(), shared_secret()),
    HsHash = hex(~"860c06edc07858ee8e78f0e7428c58edd6b43f2ca3e6e95f02ed063cf0e1cad8"),
    ServerSecret = ?M:traffic_secret(server, handshake, HandshakeSecret, HsHash),
    FinishedKey = ?M:finished_key(ServerSecret),
    ?assertEqual(
        hex(~"008d3b66f816ea559f96b537e885c31fc068bf492c652f01f288a1d8cdc19fc8"),
        FinishedKey
    ),
    %% Transcript hash over ClientHello..server CertificateVerify.
    FinishedInput = hex(~"91208a9082bb48b14e2f607d839c0d3a55c4f8e1fbb88e3c1ba0e2a32be88a59"),
    ?assertEqual(
        hex(~"5d84b2762deff4fcd2a765d6567d94a9f32e4553166893ad86769457e40564ca"),
        ?M:verify_data(FinishedKey, FinishedInput)
    ).

%% RFC 8448 §3 ECDHE (x25519) shared secret.
shared_secret() ->
    hex(~"8bd4054fb55b9d63fdfbacf9f04b9f0d35e6d63f537563efd46272900f89492d").

%% Uppercase before decoding so the literals are portable across OTP
%% versions regardless of `binary:decode_hex/1`'s lowercase handling.
hex(Hex) -> binary:decode_hex(string:uppercase(Hex)).
