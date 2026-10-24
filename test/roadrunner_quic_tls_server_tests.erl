-module(roadrunner_quic_tls_server_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("public_key/include/public_key.hrl").

-define(M, roadrunner_quic_tls_server).

%% Handshake message types (RFC 8446 §4).
-define(CLIENT_HELLO, 1).
-define(SERVER_HELLO, 2).
-define(ENCRYPTED_EXTENSIONS, 8).
-define(CERTIFICATE, 11).
-define(CERTIFICATE_VERIFY, 15).
-define(FINISHED, 20).
-define(MESSAGE_HASH, 254).

%% ClientHello wire constants.
-define(LEGACY_VERSION, 16#0303).
-define(TLS_1_2, 16#0303).
-define(TLS_1_3, 16#0304).
-define(CIPHER_AES_128_GCM_SHA256, 16#1301).
-define(CIPHER_AES_256_GCM_SHA384, 16#1302).
-define(CIPHER_CHACHA20_POLY1305_SHA256, 16#1303).
-define(GROUP_SECP256R1, 16#0017).
-define(GROUP_SECP384R1, 16#0018).
-define(GROUP_X25519, 16#001D).
%% The post-quantum hybrid group, which the server does not support.
-define(GROUP_X25519MLKEM768, 16#11EC).
-define(EXT_SUPPORTED_GROUPS, 16#000A).
-define(EXT_SIGNATURE_ALGORITHMS, 16#000D).
-define(EXT_ALPN, 16#0010).
-define(EXT_SUPPORTED_VERSIONS, 16#002B).
-define(EXT_KEY_SHARE, 16#0033).
-define(EXT_QUIC_TRANSPORT_PARAMS, 16#0039).

-define(CERT_VERIFY_CONTEXT, ~"TLS 1.3, server CertificateVerify").

%% The client's Initial SCID; every ClientHello here advertises it as
%% initial_source_connection_id so the RFC 9000 §7.3 check passes.
-define(CLIENT_SCID, <<10, 11, 12, 13>>).

%% =============================================================================
%% Full-handshake integration, one per cert key type, cipher suite and group,
%% and one through a HelloRetryRequest. Each drives the sequencer with a
%% hand-built ClientHello, then re-derives every boundary independently from
%% the OUTPUT flight messages (not from the production state) and checks the
%% flight grouping, the selected cipher suite and group, the key installs, the
%% CertificateVerify signature, the server Finished verify_data, and the
%% client Finished round-trip.
%% =============================================================================

rsa_handshake_test() ->
    assert_full_handshake(rsa, #{}).

ecdsa_handshake_test() ->
    assert_full_handshake(ecdsa, #{}).

ed25519_handshake_test() ->
    assert_full_handshake(ed25519, #{}).

%% A client offering only TLS_CHACHA20_POLY1305_SHA256 gets it, and the
%% Handshake and 1-RTT keys are ChaCha20-Poly1305 keys (RFC 9001 §5.3).
chacha20_handshake_test() ->
    assert_full_handshake(rsa, #{
        suite => ?CIPHER_CHACHA20_POLY1305_SHA256, aead => chacha20_poly1305
    }).

%% A client offering only secp256r1 gets ECDHE over P-256 (RFC 8446 §7.4.2):
%% the server's share is an uncompressed P-256 point (§4.2.8.2).
p256_handshake_test() ->
    assert_full_handshake(rsa, #{curve => secp256r1}).

assert_full_handshake(KeyType, Opts) ->
    Client = client(KeyType, Opts),
    #{curve := Curve, client_pub := ClientPub, suite := Suite, priv_key := PrivKey} = Client,
    ClientHelloBody = client_hello_for(Client, #{
        key_shares => [{group(Curve), ClientPub}], cipher_suites => [Suite]
    }),
    {ok, Flight, Installs, _PeerParams, State1} =
        ?M:process_client_hello(ClientHelloBody, server_state(PrivKey)),
    assert_flight([], ClientHelloBody, Flight, Installs, State1, Client).

%% The client lists x25519 but sends a key share only for X25519MLKEM768,
%% which the server does not support: the server asks for an x25519 share
%% with a HelloRetryRequest (RFC 8446 §4.1.4) that echoes the session id and
%% names the cipher suite and group, then completes the handshake over the
%% second ClientHello, with the first one replaced by its message_hash in
%% the transcript (§4.4.1).
hello_retry_request_handshake_test() ->
    #{client_pub := ClientPub, priv_key := PrivKey} = Client = client(rsa, #{}),
    Offer = #{groups => [?GROUP_X25519MLKEM768, ?GROUP_X25519], session_id => <<7, 7, 7>>},
    ClientHello1 = client_hello_for(Client, Offer#{
        key_shares => [{?GROUP_X25519MLKEM768, crypto:strong_rand_bytes(1216)}]
    }),
    {retry, HelloRetryRequest, State1} =
        ?M:process_client_hello(ClientHello1, server_state(PrivKey)),
    ?assertEqual(
        #{
            random => crypto:hash(sha256, ~"HelloRetryRequest"),
            session_id => <<7, 7, 7>>,
            cipher_suite => ?CIPHER_AES_128_GCM_SHA256,
            key_share => ?GROUP_X25519
        },
        server_hello_fields(HelloRetryRequest)
    ),
    ClientHello2 = client_hello_for(Client, Offer#{key_shares => [{?GROUP_X25519, ClientPub}]}),
    {ok, Flight, Installs, _PeerParams, State2} = ?M:process_client_hello(ClientHello2, State1),
    ClientHello1Framed = iolist_to_binary(
        roadrunner_quic_tls_handshake:encode(?CLIENT_HELLO, ClientHello1)
    ),
    MessageHash = <<?MESSAGE_HASH, 32:24, (crypto:hash(sha256, ClientHello1Framed))/binary>>,
    assert_flight(
        [MessageHash, HelloRetryRequest], ClientHello2, Flight, Installs, State2, Client
    ).

%% Check a server flight answering `ClientHelloBody`, the transcript before
%% which is `Transcript` (empty, or the HelloRetryRequest exchange).
assert_flight(Transcript, ClientHelloBody, Flight, Installs, State1, #{
    curve := Curve,
    client_priv := ClientPriv,
    suite := Suite,
    aead := Aead,
    scheme := Scheme,
    verify_key := VerifyKey,
    verify_params := {SigAlg, HashAlg, SigOpts}
}) ->
    %% Flight grouping: ServerHello at Initial; EE/Cert/CertVerify/Finished
    %% at Handshake, in order, each properly framed and concatenable.
    #{initial := InitialGroup, handshake := [Ee, Cert, CertVerify, Finished]} = Flight,
    ?assertEqual([?SERVER_HELLO], [T || {T, _} <- deframe_all(InitialGroup)]),
    ?assertEqual(
        [?ENCRYPTED_EXTENSIONS, ?CERTIFICATE, ?CERTIFICATE_VERIFY, ?FINISHED],
        [T || {T, _} <- deframe_all([Ee, Cert, CertVerify, Finished])]
    ),

    %% Config routing: the emitted ServerHello carries the configured random,
    %% the selected suite and a share in the client's group (the bytes the
    %% client runs ECDHE against), the EE carries the selected ALPN and the
    %% encoded transport params, and the Certificate carries the configured
    %% DER chain. Without these, a wrong-share or dropped-config flight would
    %% still pass the transcript checks.
    Group = group(Curve),
    #{random := ServerRandom, cipher_suite := Suite, key_share := {Group, ServerShare}} =
        server_hello_fields(InitialGroup),
    ?assertEqual(server_random(), ServerRandom),
    {AlpnProtocol, TransportParamsExt} = encrypted_extensions(Ee),
    ?assertEqual(~"h3", AlpnProtocol),
    ?assertEqual(
        iolist_to_binary(roadrunner_quic_transport_params:encode(server_transport_params())),
        TransportParamsExt
    ),
    ?assertEqual([~"leaf-cert-der", ~"intermediate-cert-der"], certificate_chain(Cert)),

    %% Re-derive the schedule independently from the emitted messages.
    Shared = crypto:compute_key(ecdh, ServerShare, ClientPriv, Curve),
    HandshakeSecret = roadrunner_quic_tls_crypto:handshake_secret(
        roadrunner_quic_tls_crypto:early_secret(), Shared
    ),
    ClientHelloFramed = roadrunner_quic_tls_handshake:encode(?CLIENT_HELLO, ClientHelloBody),
    ThroughServerHello = [Transcript, ClientHelloFramed, InitialGroup],
    HelloHash = roadrunner_quic_tls_crypto:transcript_hash(ThroughServerHello),
    ClientHsSecret = roadrunner_quic_tls_crypto:traffic_secret(
        client, handshake, HandshakeSecret, HelloHash
    ),
    ServerHsSecret = roadrunner_quic_tls_crypto:traffic_secret(
        server, handshake, HandshakeSecret, HelloHash
    ),
    ThroughCertificate = [ThroughServerHello, Ee, Cert],
    CertificateHash = roadrunner_quic_tls_crypto:transcript_hash(ThroughCertificate),
    ThroughCertVerify = [ThroughCertificate, CertVerify],
    CertVerifyHash = roadrunner_quic_tls_crypto:transcript_hash(ThroughCertVerify),
    ThroughFinished = [ThroughCertVerify, Finished],
    FinishedHash = roadrunner_quic_tls_crypto:transcript_hash(ThroughFinished),
    MasterSecret = roadrunner_quic_tls_crypto:master_secret(HandshakeSecret),
    ClientApSecret = roadrunner_quic_tls_crypto:traffic_secret(
        client, application, MasterSecret, FinishedHash
    ),
    ServerApSecret = roadrunner_quic_tls_crypto:traffic_secret(
        server, application, MasterSecret, FinishedHash
    ),

    %% Installs: handshake secrets before application secrets, server then
    %% client.
    ?assertEqual(
        [
            {handshake, server, Aead, ServerHsSecret},
            {handshake, client, Aead, ClientHsSecret},
            {application, server, Aead, ServerApSecret},
            {application, client, Aead, ClientApSecret}
        ],
        Installs
    ),

    %% CertificateVerify signs the transcript through Certificate.
    {?CERTIFICATE_VERIFY, CertVerifyBody, <<>>} = deframe(CertVerify),
    <<Scheme:16, SigLen:16, Signature:SigLen/binary>> = CertVerifyBody,
    Content = iolist_to_binary([
        binary:copy(<<16#20>>, 64), ?CERT_VERIFY_CONTEXT, 0, CertificateHash
    ]),
    ?assert(crypto:verify(SigAlg, HashAlg, Content, Signature, VerifyKey, SigOpts)),

    %% Server Finished verify_data over the transcript through CertVerify.
    {?FINISHED, ServerFinishedBody, <<>>} = deframe(Finished),
    ?assertEqual(
        roadrunner_quic_tls_crypto:verify_data(
            roadrunner_quic_tls_crypto:finished_key(ServerHsSecret), CertVerifyHash
        ),
        ServerFinishedBody
    ),

    %% Client Finished round-trip: a correct one is accepted, a tampered
    %% one rejected. Built with the client handshake secret over the
    %% transcript through the server Finished.
    ClientFinishedBody = roadrunner_quic_tls_crypto:verify_data(
        roadrunner_quic_tls_crypto:finished_key(ClientHsSecret), FinishedHash
    ),
    ?assertEqual(ok, ?M:process_client_finished(ClientFinishedBody, State1)),
    <<First, Rest/binary>> = ClientFinishedBody,
    Tampered = <<(First bxor 1), Rest/binary>>,
    ?assertEqual({error, handshake_failure}, ?M:process_client_finished(Tampered, State1)).

%% =============================================================================
%% Cipher suite and version negotiation (RFC 8446 §4.1.1, §4.2.1)
%% =============================================================================

%% Both supported suites on offer, ChaCha20 first: the server's preference
%% (AES-128-GCM) wins.
prefers_aes_128_gcm_test() ->
    ?assertEqual(
        ?CIPHER_AES_128_GCM_SHA256,
        negotiated_cipher_suite([?CIPHER_CHACHA20_POLY1305_SHA256, ?CIPHER_AES_128_GCM_SHA256])
    ).

%% An offered suite the server does not support (TLS_AES_256_GCM_SHA384, and
%% an unassigned value) is ignored, not rejected (RFC 8446 §4.1.2, RFC 9001
%% §5.3).
ignores_unsupported_cipher_suites_test() ->
    ?assertEqual(
        ?CIPHER_CHACHA20_POLY1305_SHA256,
        negotiated_cipher_suite([
            16#7A7A, ?CIPHER_AES_256_GCM_SHA384, ?CIPHER_CHACHA20_POLY1305_SHA256
        ])
    ).

no_common_cipher_suite_rejected_test() ->
    ?assertEqual(
        {error, no_common_cipher_suite},
        process_offering(#{cipher_suites => [?CIPHER_AES_256_GCM_SHA384]})
    ).

%% supported_versions offering only TLS 1.2, or absent altogether (a TLS 1.2
%% ClientHello): no TLS 1.3 to negotiate (RFC 8446 §4.2.1, Appendix D.2).
tls_1_2_only_rejected_test() ->
    ?assertEqual({error, protocol_version}, process_offering(#{versions => [?TLS_1_2]})).

missing_supported_versions_rejected_test() ->
    ?assertEqual({error, protocol_version}, process_offering(#{versions => none})).

%% The version check runs first: a ClientHello with no TLS 1.3 and no common
%% suite reports the version.
version_checked_before_cipher_suite_test() ->
    ?assertEqual(
        {error, protocol_version},
        process_offering(#{versions => [?TLS_1_2], cipher_suites => [?CIPHER_AES_256_GCM_SHA384]})
    ).

%% =============================================================================
%% Group negotiation (RFC 8446 §4.1.1, §4.2.7, §4.2.8, §9.2)
%% =============================================================================

%% Shares for both supported groups, P-256 first: the server's preference
%% (x25519) wins.
prefers_x25519_share_test() ->
    {P256Pub, _} = crypto:generate_key(ecdh, secp256r1),
    {X25519Pub, _} = crypto:generate_key(ecdh, x25519),
    ?assertMatch(
        {?GROUP_X25519, <<_:32/binary>>},
        negotiated_key_share(#{
            groups => [?GROUP_SECP256R1, ?GROUP_X25519],
            key_shares => [{?GROUP_SECP256R1, P256Pub}, {?GROUP_X25519, X25519Pub}]
        })
    ).

%% x25519 is preferred but has no share; the P-256 share is used rather than
%% spending a round trip on a HelloRetryRequest.
uses_the_share_sent_test() ->
    {P256Pub, _} = crypto:generate_key(ecdh, secp256r1),
    ?assertMatch(
        {?GROUP_SECP256R1, <<4, _:64/binary>>},
        negotiated_key_share(#{
            groups => [?GROUP_X25519, ?GROUP_SECP256R1],
            key_shares => [{?GROUP_SECP256R1, P256Pub}]
        })
    ).

%% An empty key_share asks the server to pick (RFC 8446 §4.2.8): a
%% HelloRetryRequest names the server's preferred listed group.
empty_key_share_retries_for_preferred_group_test() ->
    ?assertEqual(
        {retry, ?GROUP_X25519},
        negotiated_key_share(#{groups => [?GROUP_SECP256R1, ?GROUP_X25519], key_shares => []})
    ),
    ?assertEqual(
        {retry, ?GROUP_SECP256R1},
        negotiated_key_share(#{groups => [?GROUP_SECP256R1], key_shares => []})
    ).

%% A share for a group the client does not list in supported_groups is not
%% used: the server MUST NOT answer in an unlisted group (RFC 8446 §4.2.8),
%% so it asks for the listed one.
ignores_share_for_unlisted_group_test() ->
    {X25519Pub, _} = crypto:generate_key(ecdh, x25519),
    ?assertEqual(
        {retry, ?GROUP_SECP256R1},
        negotiated_key_share(#{
            groups => [?GROUP_SECP256R1], key_shares => [{?GROUP_X25519, X25519Pub}]
        })
    ).

%% No supported group in common is a handshake_failure (RFC 8446 §4.1.1).
no_common_group_rejected_test() ->
    ?assertEqual(
        {error, no_common_group},
        process_offering(#{
            groups => [?GROUP_SECP384R1, ?GROUP_X25519MLKEM768],
            key_shares => [{?GROUP_SECP384R1, crypto:strong_rand_bytes(97)}]
        })
    ).

%% Without pre-shared keys, a ClientHello MUST carry both supported_groups and
%% key_share (RFC 8446 §9.2). Offer a scheme the RSA cert does NOT match
%% (0x0403), so a passing missing_extension (rather than no_common_sig_alg)
%% pins the group check as the earlier gate.
missing_key_share_rejected_test() ->
    ?assertEqual(
        {error, missing_extension},
        process_offering(#{groups => [?GROUP_X25519], key_shares => none, sig_algs => [16#0403]})
    ).

missing_supported_groups_rejected_test() ->
    {X25519Pub, _} = crypto:generate_key(ecdh, x25519),
    ?assertEqual(
        {error, missing_extension},
        process_offering(#{groups => none, key_shares => [{?GROUP_X25519, X25519Pub}]})
    ).

%% A key share that is not a valid public value for its group is an
%% illegal_parameter (RFC 8446 §4.2.8.2, §7.4.2): an x25519 share of the
%% wrong length, the all-zero and order-4 x25519 values (both give the
%% all-zero shared secret), a compressed P-256 point, a P-256 point off the
%% curve, and a truncated one.
invalid_key_share_rejected_test_() ->
    {P256Pub, _} = crypto:generate_key(ecdh, secp256r1),
    <<4, P256X:32/binary, _P256Y:32/binary>> = P256Pub,
    [
        ?_assertEqual(
            {error, illegal_parameter},
            process_offering(#{groups => [Group], key_shares => [{Group, Share}]})
        )
     || {Group, Share} <- [
            {?GROUP_X25519, <<1, 2, 3>>},
            {?GROUP_X25519, <<0:256>>},
            {?GROUP_X25519, <<1, 0:248>>},
            {?GROUP_SECP256R1, <<2, P256X/binary>>},
            {?GROUP_SECP256R1, <<4, 1:256, 1:256>>},
            {?GROUP_SECP256R1, binary:part(P256Pub, 0, 64)}
        ]
    ].

%% =============================================================================
%% HelloRetryRequest follow-up (RFC 8446 §4.1.2, §4.1.4)
%% =============================================================================

%% The second ClientHello MUST replace its key shares with exactly one share
%% for the group the HelloRetryRequest named (§4.1.2, §4.2.8), and the server
%% MUST negotiate the same cipher suite (§4.1.4). Each failure below is an
%% illegal_parameter: a share for another group, no share again (a second
%% retry, which a client MUST reject), an extra share, and a suite list that
%% would select another suite.
second_client_hello_must_answer_the_retry_test_() ->
    {X25519Pub, _} = crypto:generate_key(ecdh, x25519),
    {P256Pub, _} = crypto:generate_key(ecdh, secp256r1),
    Groups = [?GROUP_X25519, ?GROUP_SECP256R1],
    [
        ?_assertEqual({error, illegal_parameter}, retry_then(Groups, SecondOffer))
     || SecondOffer <- [
            #{key_shares => [{?GROUP_SECP256R1, P256Pub}]},
            #{key_shares => []},
            #{key_shares => [{?GROUP_X25519, X25519Pub}, {?GROUP_SECP256R1, P256Pub}]},
            #{
                key_shares => [{?GROUP_X25519, X25519Pub}],
                cipher_suites => [?CIPHER_CHACHA20_POLY1305_SHA256]
            }
        ]
    ].

%% The second ClientHello is held to the usual checks too: an invalid share
%% for the requested group is an illegal_parameter.
second_client_hello_invalid_share_rejected_test() ->
    ?assertEqual(
        {error, illegal_parameter},
        retry_then([?GROUP_X25519], #{key_shares => [{?GROUP_X25519, <<0:256>>}]})
    ).

%% RFC 8446 §4.1.2: TLS 1.3 has no renegotiation, so a ClientHello after the
%% server flight is an unexpected_message.
client_hello_after_flight_rejected_test() ->
    #{client_pub := ClientPub, priv_key := PrivKey} = Client = client(rsa, #{}),
    ClientHello = client_hello_for(Client, #{key_shares => [{?GROUP_X25519, ClientPub}]}),
    {ok, _Flight, _Installs, _PeerParams, State1} =
        ?M:process_client_hello(ClientHello, server_state(PrivKey)),
    ?assertEqual({error, unexpected_message}, ?M:process_client_hello(ClientHello, State1)).

%% =============================================================================
%% Error paths
%% =============================================================================

no_application_protocol_rejected_test() ->
    %% Valid key_share and the RSA cert's scheme, but the client offers
    %% only h2: the configured h3 is not on offer.
    ?assertEqual({error, no_application_protocol}, process_offering(#{alpn => ~"h2"})).

no_common_sig_alg_rejected_test() ->
    %% Offer only ecdsa; the cert key is RSA (rsa_pss_rsae_sha256, 0x0804).
    ?assertEqual({error, no_common_sig_alg}, process_offering(#{sig_algs => [16#0403]})).

malformed_client_hello_rejected_test() ->
    #{priv_key := PrivKey} = client(rsa, #{}),
    ?assertEqual(
        {error, malformed_client_hello},
        ?M:process_client_hello(~"not a client hello", server_state(PrivKey))
    ).

%% RFC 9001 §8.2: a ClientHello without the quic_transport_parameters extension
%% MUST close the connection. The group/scheme/alpn gates pass, so the
%% missing-extension gate is what fails.
missing_transport_params_rejected_test() ->
    ?assertEqual(
        {error, missing_transport_params}, process_offering(#{transport_params => undefined})
    ).

%% RFC 9000 §7.3: the quic_transport_parameters extension is present but omits
%% initial_source_connection_id, so the connection-id binding cannot be verified.
missing_initial_scid_rejected_test() ->
    ?assertEqual(
        {error, transport_parameter_error},
        process_offering(#{transport_params => #{initial_max_data => 4096}})
    ).

%% RFC 9000 §7.3: the client's advertised initial_source_connection_id does not
%% equal the Source Connection ID of its Initial (the server's peer_scid).
initial_scid_mismatch_rejected_test() ->
    ?assertEqual(
        {error, transport_parameter_error},
        process_offering(#{transport_params => #{initial_source_connection_id => <<9, 9, 9, 9>>}})
    ).

%% RFC 9000 §7.4 / §18.2: a transport parameter the codec rejects (here an
%% out-of-range max_ack_delay, and a server-only parameter) closes with
%% TRANSPORT_PARAMETER_ERROR rather than a TLS alert.
invalid_transport_param_rejected_test() ->
    ?assertEqual(
        {error, transport_parameter_error},
        process_offering(#{
            transport_params => #{
                initial_source_connection_id => ?CLIENT_SCID, max_ack_delay => 16384
            }
        })
    ).

server_only_transport_param_rejected_test() ->
    ?assertEqual(
        {error, transport_parameter_error},
        process_offering(#{
            transport_params => #{
                initial_source_connection_id => ?CLIENT_SCID,
                original_destination_connection_id => <<5, 6, 7, 8>>
            }
        })
    ).

%% =============================================================================
%% Helpers
%% =============================================================================

%% A fresh server handshake state signing with `PrivKey`.
server_state(PrivKey) ->
    ?M:new(#{
        cert_chain => [~"leaf-cert-der", ~"intermediate-cert-der"],
        priv_key => PrivKey,
        alpn => ~"h3",
        transport_params => server_transport_params(),
        server_random => server_random(),
        peer_scid => ?CLIENT_SCID
    }).

server_transport_params() ->
    #{
        original_destination_connection_id => <<5, 6, 7, 8>>,
        initial_source_connection_id => <<1, 2, 3, 4>>
    }.

server_random() ->
    binary:copy(<<16#5A>>, 32).

%% A handshake's key material: the server's cert key of `KeyType` with its
%% scheme and the client's inputs to verify it, plus the client's ephemeral
%% key pair on `curve` (default x25519) and the suite it offers and expects
%% (default TLS_AES_128_GCM_SHA256) with its AEAD.
client(KeyType, Opts) ->
    {Scheme, PrivKey, VerifyKey, VerifyParams} = key_material(KeyType),
    Curve = maps:get(curve, Opts, x25519),
    {ClientPub, ClientPriv} = crypto:generate_key(ecdh, Curve),
    #{
        curve => Curve,
        client_pub => ClientPub,
        client_priv => ClientPriv,
        suite => maps:get(suite, Opts, ?CIPHER_AES_128_GCM_SHA256),
        aead => maps:get(aead, Opts, aes_128_gcm),
        scheme => Scheme,
        priv_key => PrivKey,
        verify_key => VerifyKey,
        verify_params => VerifyParams
    }.

group(x25519) -> ?GROUP_X25519;
group(secp256r1) -> ?GROUP_SECP256R1.

%% A generated key pair per scheme, plus the crypto:verify inputs for its
%% public half (mirrors roadrunner_quic_tls_auth_props:signing_keys/0).
key_material(rsa) ->
    #'RSAPrivateKey'{publicExponent = E, modulus = N} =
        PrivKey = public_key:generate_key({rsa, 2048, 65537}),
    {16#0804, PrivKey, [E, N],
        {rsa, sha256, [{rsa_padding, rsa_pkcs1_pss_padding}, {rsa_pss_saltlen, -1}]}};
key_material(ecdsa) ->
    #'ECPrivateKey'{publicKey = Pub} = PrivKey = public_key:generate_key({namedCurve, secp256r1}),
    {16#0403, PrivKey, [Pub, secp256r1], {ecdsa, sha256, []}};
key_material(ed25519) ->
    #'ECPrivateKey'{publicKey = Pub} = PrivKey = public_key:generate_key({namedCurve, ed25519}),
    {16#0807, PrivKey, [Pub, ed25519], {eddsa, none, []}}.

%% A ClientHello body offering the cert key's scheme, h3, and the client
%% SCID, plus `Opts`.
client_hello_for(#{scheme := Scheme}, Opts) ->
    client_hello_body(
        maps:merge(
            #{
                sig_algs => [Scheme],
                transport_params => #{initial_source_connection_id => ?CLIENT_SCID}
            },
            Opts
        )
    ).

%% Build a ClientHello body (RFC 8446 §4.1.2) carrying the requested
%% extensions. It offers TLS 1.3 and TLS_AES_128_GCM_SHA256 unless
%% `versions` or `cipher_suites` say otherwise. `key_shares` lists the
%% `{Group, KeyExchange}` entries and `groups` the supported_groups (by
%% default, the groups of the shares). `none` omits supported_versions,
%% supported_groups or key_share; `transport_params => undefined` omits
%% quic_transport_parameters.
client_hello_body(Opts) ->
    Random = maps:get(random, Opts, crypto:strong_rand_bytes(32)),
    SessionId = maps:get(session_id, Opts, <<>>),
    KeyShares = maps:get(key_shares, Opts, none),
    Extensions = iolist_to_binary([
        supported_versions_ext(maps:get(versions, Opts, [?TLS_1_3])),
        supported_groups_ext(maps:get(groups, Opts, share_groups(KeyShares))),
        signature_algorithms_ext(maps:get(sig_algs, Opts, [16#0804])),
        alpn_ext(maps:get(alpn, Opts, ~"h3")),
        key_share_ext(KeyShares),
        transport_params_ext(maps:get(transport_params, Opts, undefined))
    ]),
    CipherSuites = <<<<C:16>> || C <- maps:get(cipher_suites, Opts, [?CIPHER_AES_128_GCM_SHA256])>>,
    <<?LEGACY_VERSION:16, Random/binary, (byte_size(SessionId)):8, SessionId/binary,
        (byte_size(CipherSuites)):16, CipherSuites/binary, 1:8, 0:8, (byte_size(Extensions)):16,
        Extensions/binary>>.

share_groups(none) -> none;
share_groups(KeyShares) -> [Group || {Group, _KeyExchange} <- KeyShares].

supported_versions_ext(none) ->
    <<>>;
supported_versions_ext(Versions) ->
    List = <<<<V:16>> || V <- Versions>>,
    extension(?EXT_SUPPORTED_VERSIONS, <<(byte_size(List)):8, List/binary>>).

supported_groups_ext(none) ->
    <<>>;
supported_groups_ext(Groups) ->
    List = <<<<G:16>> || G <- Groups>>,
    extension(?EXT_SUPPORTED_GROUPS, <<(byte_size(List)):16, List/binary>>).

signature_algorithms_ext(Schemes) ->
    List = <<<<S:16>> || S <- Schemes>>,
    extension(?EXT_SIGNATURE_ALGORITHMS, <<(byte_size(List)):16, List/binary>>).

alpn_ext(Protocol) ->
    Entry = <<(byte_size(Protocol)):8, Protocol/binary>>,
    extension(?EXT_ALPN, <<(byte_size(Entry)):16, Entry/binary>>).

key_share_ext(none) ->
    <<>>;
key_share_ext(KeyShares) ->
    Entries = <<<<Group:16, (byte_size(Key)):16, Key/binary>> || {Group, Key} <- KeyShares>>,
    extension(?EXT_KEY_SHARE, <<(byte_size(Entries)):16, Entries/binary>>).

%% `undefined` emits no quic_transport_parameters extension (so a test can
%% exercise the §8.2 missing-extension path); a params map is encoded with the
%% production codec.
transport_params_ext(undefined) ->
    <<>>;
transport_params_ext(Params) ->
    extension(
        ?EXT_QUIC_TRANSPORT_PARAMS,
        iolist_to_binary(roadrunner_quic_transport_params:encode(Params))
    ).

extension(Type, Data) ->
    <<Type:16, (byte_size(Data)):16, Data/binary>>.

%% The fields of a ServerHello or HelloRetryRequest: the random, echoed
%% session id, selected cipher suite, and key share, which is `{Group,
%% KeyExchange}` in a ServerHello and the bare selected group in a
%% HelloRetryRequest (RFC 8446 §4.2.8).
server_hello_fields(ServerHello) ->
    {?SERVER_HELLO, Body, <<>>} = deframe(ServerHello),
    <<?LEGACY_VERSION:16, Random:32/binary, SessionLen:8, SessionId:SessionLen/binary, Cipher:16,
        0:8, ExtsLen:16, Extensions:ExtsLen/binary>> = Body,
    <<?TLS_1_3:16>> = extract_extension(?EXT_SUPPORTED_VERSIONS, Extensions),
    KeyShare =
        case extract_extension(?EXT_KEY_SHARE, Extensions) of
            <<Group:16, KeyLen:16, PubKey:KeyLen/binary>> -> {Group, PubKey};
            <<Group:16>> -> Group
        end,
    #{random => Random, session_id => SessionId, cipher_suite => Cipher, key_share => KeyShare}.

%% The selected ALPN protocol and the raw transport-params extension body
%% from an EncryptedExtensions message.
encrypted_extensions(EncryptedExtensions) ->
    {?ENCRYPTED_EXTENSIONS, Body, <<>>} = deframe(EncryptedExtensions),
    <<_ExtsLen:16, Extensions/binary>> = Body,
    <<_ListLen:16, ProtocolLen:8, Protocol:ProtocolLen/binary>> =
        extract_extension(?EXT_ALPN, Extensions),
    {Protocol, extract_extension(?EXT_QUIC_TRANSPORT_PARAMS, Extensions)}.

%% The DER certificate chain (leaf first) from a Certificate message.
certificate_chain(Certificate) ->
    {?CERTIFICATE, Body, <<>>} = deframe(Certificate),
    <<0:8, _ListLen:24, CertList/binary>> = Body,
    cert_entries(CertList).

cert_entries(<<>>) ->
    [];
cert_entries(<<CertLen:24, Cert:CertLen/binary, ExtLen:16, _Exts:ExtLen/binary, Rest/binary>>) ->
    [Cert | cert_entries(Rest)].

%% The data of the first extension of Type in an extension vector; crashes
%% if it is absent, which a caller asserting its presence wants.
extract_extension(Type, <<Type:16, Len:16, Data:Len/binary, _/binary>>) ->
    Data;
extract_extension(Type, <<_OtherType:16, Len:16, _Data:Len/binary, Rest/binary>>) ->
    extract_extension(Type, Rest).

deframe(Iolist) ->
    {ok, {Type, Body}, Rest} = roadrunner_quic_tls_handshake:decode(iolist_to_binary(Iolist)),
    {Type, Body, Rest}.

deframe_all(Iolist) ->
    deframe_all_bin(iolist_to_binary(Iolist)).

deframe_all_bin(<<>>) ->
    [];
deframe_all_bin(Bin) ->
    {ok, {Type, Body}, Rest} = roadrunner_quic_tls_handshake:decode(Bin),
    [{Type, Body} | deframe_all_bin(Rest)].

%% Process an otherwise valid ClientHello (an x25519 share, the RSA scheme,
%% h3, a matching initial_source_connection_id) changed by `Opts` against a
%% fresh RSA server state.
process_offering(Opts) ->
    #{client_pub := ClientPub, priv_key := PrivKey} = Client = client(rsa, #{}),
    ClientHello = client_hello_for(
        Client, maps:merge(#{key_shares => [{?GROUP_X25519, ClientPub}]}, Opts)
    ),
    ?M:process_client_hello(ClientHello, server_state(PrivKey)).

%% The cipher suite the server selects from `Offered`.
negotiated_cipher_suite(Offered) ->
    {ok, #{initial := ServerHello}, _Installs, _PeerParams, _State} =
        process_offering(#{cipher_suites => Offered}),
    #{cipher_suite := Suite} = server_hello_fields(ServerHello),
    Suite.

%% The server's answer to a ClientHello offering `Opts`: the `{Group,
%% KeyExchange}` of its ServerHello, or `{retry, Group}` for a
%% HelloRetryRequest.
negotiated_key_share(Opts) ->
    case process_offering(Opts) of
        {ok, #{initial := ServerHello}, _Installs, _PeerParams, _State} ->
            #{key_share := KeyShare} = server_hello_fields(ServerHello),
            KeyShare;
        {retry, HelloRetryRequest, _State} ->
            #{key_share := Group} = server_hello_fields(HelloRetryRequest),
            {retry, Group}
    end.

%% Send a first ClientHello listing `Groups` with no key share, so the server
%% answers with a HelloRetryRequest (for x25519), then a second ClientHello
%% with the same groups changed by `SecondOffer`.
retry_then(Groups, SecondOffer) ->
    #{priv_key := PrivKey} = Client = client(rsa, #{}),
    ClientHello1 = client_hello_for(Client, #{groups => Groups, key_shares => []}),
    {retry, _HelloRetryRequest, State1} =
        ?M:process_client_hello(ClientHello1, server_state(PrivKey)),
    ClientHello2 = client_hello_for(Client, SecondOffer#{groups => Groups}),
    ?M:process_client_hello(ClientHello2, State1).
