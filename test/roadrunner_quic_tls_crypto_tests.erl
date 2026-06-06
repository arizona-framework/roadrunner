-module(roadrunner_quic_tls_crypto_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_quic_tls_crypto).
%% The `quic` dep, kept as a test-profile differential oracle.
-define(DEP, quic_crypto).

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
%% Differential equivalence vs the dep oracle.
%% =============================================================================

matches_dep_test() ->
    [
        ?assertEqual(?DEP:transcript_hash(Msg), ?M:transcript_hash(Msg))
     || Msg <- [<<>>, ~"x", ~"the running handshake transcript", binary:copy(<<7>>, 200)]
    ],
    Early = ?M:early_secret(),
    [
        ?assertEqual(?DEP:derive_secret(Early, Label, Hash), ?M:derive_secret(Early, Label, Hash))
     || {Label, Hash} <- [
            {~"c hs traffic", ?M:transcript_hash(~"abc")},
            {~"s hs traffic", ?M:transcript_hash(<<>>)},
            {~"derived", ?M:transcript_hash(~"xyz")}
        ]
    ],
    [
        begin
            HandshakeSecret = ?M:handshake_secret(Early, Shared),
            ?assertEqual(?DEP:derive_handshake_secret(Early, Shared), HandshakeSecret),
            ?assertEqual(
                ?DEP:derive_master_secret(HandshakeSecret), ?M:master_secret(HandshakeSecret)
            )
        end
     || Shared <- [binary:copy(<<16#2a>>, 32), shared_secret()]
    ].

%% RFC 8448 §3 ECDHE (x25519) shared secret.
shared_secret() ->
    hex(~"8bd4054fb55b9d63fdfbacf9f04b9f0d35e6d63f537563efd46272900f89492d").

%% Uppercase before decoding so the literals are portable across OTP
%% versions regardless of `binary:decode_hex/1`'s lowercase handling.
hex(Hex) -> binary:decode_hex(string:uppercase(Hex)).
