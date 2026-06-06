-module(roadrunner_quic_tls_auth_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("public_key/include/public_key.hrl").

-define(M, roadrunner_quic_tls_auth).
%% The `quic` dep, kept as a test-profile differential oracle.
-define(DEP, quic_tls).
-define(FRAME, roadrunner_quic_tls_handshake).

-define(SIG_RSA_PSS_RSAE_SHA256, 16#0804).
-define(SIG_ECDSA_SECP256R1_SHA256, 16#0403).
-define(SIG_ED25519, 16#0807).

%% =============================================================================
%% Certificate (RFC 8446 §4.4.2).
%% =============================================================================

build_certificate_structure_test() ->
    Leaf = <<"leaf-cert-der">>,
    Chain = <<"chain-cert-der">>,
    {ok, {11, Body}, <<>>} = ?FRAME:decode(iolist_to_binary(?M:build_certificate([Leaf, Chain]))),
    CertList =
        <<(byte_size(Leaf)):24, Leaf/binary, 0:16, (byte_size(Chain)):24, Chain/binary, 0:16>>,
    %% Empty certificate_request_context, then the CertificateEntry list.
    ?assertEqual(<<0:8, (byte_size(CertList)):24, CertList/binary>>, Body).

build_certificate_single_cert_test() ->
    {ok, {11, Body}, <<>>} = ?FRAME:decode(iolist_to_binary(?M:build_certificate([<<"only">>]))),
    ?assertEqual(<<0:8, 9:24, 4:24, "only", 0:16>>, Body).

build_certificate_matches_dep_test() ->
    Certs = [<<1, 2, 3>>, <<4, 5, 6, 7>>],
    ?assertEqual(
        ?DEP:build_certificate(<<>>, Certs),
        iolist_to_binary(?M:build_certificate(Certs))
    ).

%% =============================================================================
%% CertificateVerify (RFC 8446 §4.4.3) — sign, then verify the signature.
%% RSA-PSS and ECDSA are randomized, so the test is a verify roundtrip.
%% =============================================================================

certificate_verify_rsa_test() ->
    #'RSAPrivateKey'{publicExponent = E, modulus = N} =
        Key = public_key:generate_key(
            {rsa, 2048, 65537}
        ),
    certificate_verify_roundtrip(
        ?SIG_RSA_PSS_RSAE_SHA256,
        Key,
        [E, N],
        {
            rsa, sha256, [{rsa_padding, rsa_pkcs1_pss_padding}, {rsa_pss_saltlen, -1}]
        }
    ).

certificate_verify_ecdsa_test() ->
    #'ECPrivateKey'{publicKey = Pub} = Key = public_key:generate_key({namedCurve, secp256r1}),
    certificate_verify_roundtrip(
        ?SIG_ECDSA_SECP256R1_SHA256,
        Key,
        [Pub, secp256r1],
        {
            ecdsa, sha256, []
        }
    ).

certificate_verify_ed25519_test() ->
    #'ECPrivateKey'{publicKey = Pub} = Key = public_key:generate_key({namedCurve, ed25519}),
    certificate_verify_roundtrip(?SIG_ED25519, Key, [Pub, ed25519], {eddsa, none, []}).

%% =============================================================================
%% Finished (RFC 8446 §4.4.4) — deterministic, RFC 8448 §3 vectors.
%% =============================================================================

build_finished_rfc8448_test() ->
    %% RFC 8448 §3: the server handshake traffic secret and the transcript
    %% hash through CertificateVerify yield the server Finished verify_data
    %% (the same vectors the C2 key-schedule tests pin).
    ServerHsSecret = hex("b67b7d690cc16c4e75e54213cb2d37b4e9c912bcded9105d42befd59d391ad38"),
    TranscriptHash = hex("91208a9082bb48b14e2f607d839c0d3a55c4f8e1fbb88e3c1ba0e2a32be88a59"),
    VerifyData = hex("5d84b2762deff4fcd2a765d6567d94a9f32e4553166893ad86769457e40564ca"),
    Built = iolist_to_binary(?M:build_finished(ServerHsSecret, TranscriptHash)),
    ?assertEqual(<<20, 0, 0, 32, VerifyData/binary>>, Built).

verify_client_finished_test() ->
    Secret = hex("b3eddb126e067f35a780b3abf45e2d8f3b1a950738f52e9600746a0e27a55a21"),
    Hash = hex("96088718a85d2c0d2b21a16a7f637eba132bd1a01feac57b8f8ec571ef41c47c"),
    Expected = roadrunner_quic_tls_crypto:verify_data(
        roadrunner_quic_tls_crypto:finished_key(Secret), Hash
    ),
    ?assert(?M:verify_client_finished(Expected, Secret, Hash)),
    %% A single flipped byte fails the constant-time compare.
    <<First, Rest/binary>> = Expected,
    ?assertNot(?M:verify_client_finished(<<(First bxor 1), Rest/binary>>, Secret, Hash)).

%% =============================================================================
%% Helpers
%% =============================================================================

%% Sign a CertificateVerify, peel the framing, and verify the signature
%% over the reconstructed signed content with the matching public key.
certificate_verify_roundtrip(Scheme, PrivateKey, PublicKey, {SigAlg, HashAlg, Options}) ->
    Hash = crypto:strong_rand_bytes(32),
    {ok, {15, Body}, <<>>} = ?FRAME:decode(
        iolist_to_binary(?M:build_certificate_verify(Scheme, PrivateKey, Hash))
    ),
    <<Scheme:16, SigLen:16, Signature:SigLen/binary>> = Body,
    Content =
        <<
            (binary:copy(<<16#20>>, 64))/binary, "TLS 1.3, server CertificateVerify", 0, Hash/binary
        >>,
    ?assert(crypto:verify(SigAlg, HashAlg, Content, Signature, PublicKey, Options)).

hex(Hex) ->
    Bytes = <<<<B>> || <<B>> <= iolist_to_binary(Hex), B =/= $\s, B =/= $\n>>,
    binary:decode_hex(string:uppercase(Bytes)).
