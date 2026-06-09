-module(roadrunner_quic_test_handshake_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("public_key/include/public_key.hrl").

-define(SERVER, roadrunner_quic_tls_server).
-define(CLIENT, roadrunner_quic_test_handshake).
-define(TC, roadrunner_quic_test_client).

%% The client driver is proven against the production server core: the client
%% builds a ClientHello, the server processes it and emits its flight, the
%% client drives the flight, and the two ends must agree on every key. The
%% server must then accept the client's Finished. No dep oracle is involved.

full_handshake_round_trip_test() ->
    Scheme = 16#0804,
    #'RSAPrivateKey'{modulus = N, publicExponent = E} =
        PrivKey = public_key:generate_key({rsa, 2048, 65537}),
    ServerPub = #'RSAPublicKey'{modulus = N, publicExponent = E},
    {ClientPub, ClientPriv} = crypto:generate_key(ecdh, x25519),
    {ServerEphPub, ServerEphPriv} = crypto:generate_key(ecdh, x25519),
    ClientSCID = <<1, 2, 3, 4>>,
    %% Server transport params the production decoder accepts as peer params
    %% (no server-only parameters, which the server-side decoder rejects).
    ServerParams = #{initial_source_connection_id => <<9, 9, 9, 9>>, initial_max_data => 65536},
    ServerState = ?SERVER:new(#{
        cert_chain => [~"leaf-der"],
        priv_key => PrivKey,
        alpn => ~"h3",
        transport_params => ServerParams,
        eph_pub => ServerEphPub,
        eph_priv => ServerEphPriv,
        server_random => crypto:strong_rand_bytes(32),
        peer_scid => ClientSCID
    }),

    ClientHelloFramed = ?TC:client_hello_framed(Scheme, ClientPub, ClientSCID),
    [{1, ClientHelloBody}] = ?TC:deframe_all(ClientHelloFramed),
    {ok, Flight, ServerInstalls, _PeerParams, ServerState1} =
        ?SERVER:process_client_hello(ClientHelloBody, ServerState),

    {ok, Result} = ?CLIENT:process_server_flight(
        #{
            eph_priv => ClientPriv,
            client_hello_framed => ClientHelloFramed,
            server_pubkey => ServerPub
        },
        Flight
    ),

    %% The client derived the same ordered key installs as the server.
    ?assertEqual(ServerInstalls, maps:get(installs, Result)),
    %% The client learned the negotiated ALPN and the server's transport
    %% params (captured as raw bytes, equal to the server's encoding).
    ?assertEqual(~"h3", maps:get(alpn, Result)),
    ?assertEqual(
        iolist_to_binary(roadrunner_quic_transport_params:encode(ServerParams)),
        maps:get(peer_transport_params, Result)
    ),
    %% The server accepts the client's Finished.
    [{20, ClientFinishedBody}] = ?TC:deframe_all(maps:get(client_finished, Result)),
    ?assertEqual(ok, ?SERVER:process_client_finished(ClientFinishedBody, ServerState1)).

%% A server CertificateVerify signed with the wrong key fails client verification.
rejects_bad_certificate_verify_test() ->
    Scheme = 16#0804,
    PrivKey = public_key:generate_key({rsa, 2048, 65537}),
    WrongKey = public_key:generate_key({rsa, 2048, 65537}),
    #'RSAPrivateKey'{modulus = N, publicExponent = E} = WrongKey,
    WrongPub = #'RSAPublicKey'{modulus = N, publicExponent = E},
    {ClientPub, ClientPriv} = crypto:generate_key(ecdh, x25519),
    {ServerEphPub, ServerEphPriv} = crypto:generate_key(ecdh, x25519),
    ClientSCID = <<1, 2, 3, 4>>,
    ServerState = ?SERVER:new(#{
        cert_chain => [~"leaf-der"],
        priv_key => PrivKey,
        alpn => ~"h3",
        transport_params => #{initial_source_connection_id => <<9, 9, 9, 9>>},
        eph_pub => ServerEphPub,
        eph_priv => ServerEphPriv,
        server_random => crypto:strong_rand_bytes(32),
        peer_scid => ClientSCID
    }),
    ClientHelloFramed = ?TC:client_hello_framed(Scheme, ClientPub, ClientSCID),
    [{1, ClientHelloBody}] = ?TC:deframe_all(ClientHelloFramed),
    {ok, Flight, _, _, _} = ?SERVER:process_client_hello(ClientHelloBody, ServerState),
    %% Verify the signature against a public key that did not sign it.
    ?assertEqual(
        {error, handshake_verification_failed},
        ?CLIENT:process_server_flight(
            #{
                eph_priv => ClientPriv,
                client_hello_framed => ClientHelloFramed,
                server_pubkey => WrongPub
            },
            Flight
        )
    ).
