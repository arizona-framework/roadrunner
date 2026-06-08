-module(roadrunner_quic_test_client_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("public_key/include/public_key.hrl").

-define(C, roadrunner_quic_test_client).

%% Each server-flight parser is proven by round-tripping the native server
%% builder: server build_X -> deframe -> client parse_X recovers the fields.
%% No dep oracle is involved; the native server modules are the reference.

server_hello_round_trip_test() ->
    Random = crypto:strong_rand_bytes(32),
    SessionId = crypto:strong_rand_bytes(8),
    {Pub, _Priv} = ?C:gen_keypair(),
    Framed = roadrunner_quic_tls_hello:build_server_hello(#{
        random => Random, session_id => SessionId, key_share => Pub
    }),
    [{2, Body}] = ?C:deframe_all(Framed),
    Parsed = ?C:parse_server_hello(Body),
    ?assertEqual(Random, maps:get(random, Parsed)),
    ?assertEqual(SessionId, maps:get(session_id, Parsed)),
    ?assertEqual(16#1301, maps:get(cipher, Parsed)),
    ?assertEqual(Pub, maps:get(key_share, Parsed)).

encrypted_extensions_round_trip_test() ->
    Params = #{initial_max_data => 65536},
    Framed = roadrunner_quic_tls_hello:build_encrypted_extensions(#{
        alpn => ~"h3", transport_params => Params
    }),
    [{8, Body}] = ?C:deframe_all(Framed),
    Parsed = ?C:parse_encrypted_extensions(Body),
    ?assertEqual(~"h3", maps:get(alpn, Parsed)),
    ?assertEqual(Params, maps:get(transport_params, Parsed)).

encrypted_extensions_absent_extensions_test() ->
    %% No ALPN, no transport params: both keys are simply absent.
    Framed = roadrunner_quic_tls_hello:build_encrypted_extensions(#{}),
    [{8, Body}] = ?C:deframe_all(Framed),
    ?assertEqual(#{}, ?C:parse_encrypted_extensions(Body)).

certificate_round_trip_test() ->
    Chain = [<<"leaf-der">>, <<"intermediate-der">>],
    Framed = roadrunner_quic_tls_auth:build_certificate(Chain),
    [{11, Body}] = ?C:deframe_all(Framed),
    ?assertEqual(Chain, ?C:parse_certificate(Body)).

certificate_verify_round_trip_test() ->
    {Scheme, PrivKey} = ?C:key_material(),
    Hash = crypto:strong_rand_bytes(32),
    Framed = roadrunner_quic_tls_auth:build_certificate_verify(Scheme, PrivKey, Hash),
    [{15, Body}] = ?C:deframe_all(Framed),
    {ParsedScheme, Signature} = ?C:parse_certificate_verify(Body),
    ?assertEqual(Scheme, ParsedScheme),
    ?assert(byte_size(Signature) > 0).

finished_round_trip_test() ->
    TrafficSecret = crypto:strong_rand_bytes(32),
    Hash = crypto:strong_rand_bytes(32),
    Framed = roadrunner_quic_tls_auth:build_finished(TrafficSecret, Hash),
    [{20, Body}] = ?C:deframe_all(Framed),
    FinishedKey = roadrunner_quic_tls_crypto:finished_key(TrafficSecret),
    Expected = roadrunner_quic_tls_crypto:verify_data(FinishedKey, Hash),
    ?assertEqual(Expected, ?C:parse_finished(Body)).

certificate_verify_signature_verifies_test() ->
    {Scheme, Priv} = ?C:key_material(),
    Pub = #'RSAPublicKey'{
        modulus = Priv#'RSAPrivateKey'.modulus,
        publicExponent = Priv#'RSAPrivateKey'.publicExponent
    },
    Hash = crypto:strong_rand_bytes(32),
    Framed = roadrunner_quic_tls_auth:build_certificate_verify(Scheme, Priv, Hash),
    [{15, Body}] = ?C:deframe_all(Framed),
    {Scheme, Signature} = ?C:parse_certificate_verify(Body),
    ?assert(?C:verify_server_certificate_verify(Scheme, Signature, Pub, Hash)),
    %% A signature over a different transcript hash must not verify.
    ?assertNot(
        ?C:verify_server_certificate_verify(Scheme, Signature, Pub, crypto:strong_rand_bytes(32))
    ).
