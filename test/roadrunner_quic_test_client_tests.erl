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
        random => Random,
        session_id => SessionId,
        cipher_suite => 16#1303,
        key_share => {16#001D, Pub}
    }),
    [{2, Body}] = ?C:deframe_all(Framed),
    Parsed = ?C:parse_server_hello(Body),
    ?assertEqual(Random, maps:get(random, Parsed)),
    ?assertEqual(SessionId, maps:get(session_id, Parsed)),
    ?assertEqual(16#1303, maps:get(cipher, Parsed)),
    ?assertEqual(16#001D, maps:get(group, Parsed)),
    ?assertEqual(Pub, maps:get(key_share, Parsed)).

hello_retry_request_round_trip_test() ->
    %% A HelloRetryRequest names the group only, so it parses without a key.
    Framed = roadrunner_quic_tls_hello:build_hello_retry_request(#{
        session_id => <<>>, cipher_suite => 16#1301, group => 16#0017
    }),
    [{2, Body}] = ?C:deframe_all(Framed),
    ?assertEqual(
        #{
            random => crypto:hash(sha256, ~"HelloRetryRequest"),
            session_id => <<>>,
            cipher => 16#1301,
            group => 16#0017
        },
        ?C:parse_server_hello(Body)
    ).

encrypted_extensions_round_trip_test() ->
    Params = #{initial_max_data => 65536},
    Framed = roadrunner_quic_tls_hello:build_encrypted_extensions(#{
        alpn => ~"h3", transport_params => Params
    }),
    [{8, Body}] = ?C:deframe_all(Framed),
    Parsed = ?C:parse_encrypted_extensions(Body),
    ?assertEqual(~"h3", maps:get(alpn, Parsed)),
    %% The transport parameters are captured as raw bytes (the client does not
    %% decode them); they equal the server's encoding.
    ?assertEqual(
        iolist_to_binary(roadrunner_quic_transport_params:encode(Params)),
        maps:get(transport_params, Parsed)
    ).

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
    Framed = roadrunner_quic_tls_auth:build_finished(sha256, TrafficSecret, Hash),
    [{20, Body}] = ?C:deframe_all(Framed),
    FinishedKey = roadrunner_quic_tls_crypto:finished_key(sha256, TrafficSecret),
    Expected = roadrunner_quic_tls_crypto:verify_data(sha256, FinishedKey, Hash),
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
