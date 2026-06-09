-module(roadrunner_quic_tls_server_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("public_key/include/public_key.hrl").

-define(M, roadrunner_quic_tls_server).

%% Handshake message types (RFC 8446 §4).
-define(SERVER_HELLO, 2).
-define(ENCRYPTED_EXTENSIONS, 8).
-define(CERTIFICATE, 11).
-define(CERTIFICATE_VERIFY, 15).
-define(FINISHED, 20).

%% ClientHello wire constants.
-define(LEGACY_VERSION, 16#0303).
-define(CIPHER_AES_128_GCM_SHA256, 16#1301).
-define(GROUP_X25519, 16#001D).
-define(EXT_SIGNATURE_ALGORITHMS, 16#000D).
-define(EXT_ALPN, 16#0010).
-define(EXT_KEY_SHARE, 16#0033).
-define(EXT_QUIC_TRANSPORT_PARAMS, 16#0039).

-define(CERT_VERIFY_CONTEXT, ~"TLS 1.3, server CertificateVerify").

%% =============================================================================
%% Full-handshake integration, one per cert key type. Each drives the
%% sequencer with a fixed server ephemeral + a hand-built ClientHello, then
%% re-derives every boundary independently from the OUTPUT flight messages
%% (not from the production state) and checks the flight grouping, the key
%% installs, the CertificateVerify signature, the server Finished
%% verify_data, and the client Finished round-trip.
%% =============================================================================

rsa_handshake_test() ->
    assert_full_handshake(rsa).

ecdsa_handshake_test() ->
    assert_full_handshake(ecdsa).

ed25519_handshake_test() ->
    assert_full_handshake(ed25519).

assert_full_handshake(KeyType) ->
    {Scheme, PrivKey, VerifyKey, {SigAlg, HashAlg, SigOpts}} = key_material(KeyType),
    {ClientPub, ClientPriv} = crypto:generate_key(ecdh, x25519),
    {ServerPub, ServerPriv} = crypto:generate_key(ecdh, x25519),
    ServerRandom = crypto:strong_rand_bytes(32),
    %% The client's Initial SCID; its ClientHello advertises the same value as
    %% initial_source_connection_id so the §7.3 check passes.
    ClientSCID = <<10, 11, 12, 13>>,
    TransportParams = #{
        original_destination_connection_id => <<5, 6, 7, 8>>,
        initial_source_connection_id => <<1, 2, 3, 4>>
    },
    ClientHelloBody = client_hello_body(#{
        key_share => ClientPub,
        sig_algs => [Scheme],
        alpn => ~"h3",
        session_id => <<>>,
        transport_params => #{initial_source_connection_id => ClientSCID}
    }),
    State = ?M:new(#{
        cert_chain => [~"leaf-cert-der", ~"intermediate-cert-der"],
        priv_key => PrivKey,
        alpn => ~"h3",
        transport_params => TransportParams,
        eph_pub => ServerPub,
        eph_priv => ServerPriv,
        server_random => ServerRandom,
        peer_scid => ClientSCID
    }),

    {ok, Flight, Installs, _PeerParams, State1} = ?M:process_client_hello(ClientHelloBody, State),

    %% Flight grouping: ServerHello at Initial; EE/Cert/CertVerify/Finished
    %% at Handshake, in order, each properly framed and concatenable.
    #{initial := InitialGroup, handshake := [Ee, Cert, CertVerify, Finished]} = Flight,
    ?assertEqual([?SERVER_HELLO], [T || {T, _} <- deframe_all(InitialGroup)]),
    ?assertEqual(
        [?ENCRYPTED_EXTENSIONS, ?CERTIFICATE, ?CERTIFICATE_VERIFY, ?FINISHED],
        [T || {T, _} <- deframe_all([Ee, Cert, CertVerify, Finished])]
    ),

    %% Config routing: the emitted ServerHello carries the server ephemeral
    %% pubkey (the byte the client runs ECDHE against), the EE carries the
    %% selected ALPN and the encoded transport params, and the Certificate
    %% carries the configured DER chain. Without these, a wrong-pubkey or
    %% dropped-config flight would still pass the transcript checks.
    ?assertEqual(ServerPub, server_hello_key_share(InitialGroup)),
    {AlpnProtocol, TransportParamsExt} = encrypted_extensions(Ee),
    ?assertEqual(~"h3", AlpnProtocol),
    ?assertEqual(
        iolist_to_binary(roadrunner_quic_transport_params:encode(TransportParams)),
        TransportParamsExt
    ),
    ?assertEqual([~"leaf-cert-der", ~"intermediate-cert-der"], certificate_chain(Cert)),

    %% Re-derive the schedule independently from the emitted messages.
    Shared = crypto:compute_key(ecdh, ServerPub, ClientPriv, x25519),
    HandshakeSecret = roadrunner_quic_tls_crypto:handshake_secret(
        roadrunner_quic_tls_crypto:early_secret(), Shared
    ),
    ClientHelloFramed = roadrunner_quic_tls_handshake:encode(1, ClientHelloBody),
    ThroughServerHello = [ClientHelloFramed, InitialGroup],
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

    %% Installs: handshake keys before application keys, server then client.
    ?assertEqual(
        [
            {handshake, server, roadrunner_quic_keys:traffic_keys(ServerHsSecret)},
            {handshake, client, roadrunner_quic_keys:traffic_keys(ClientHsSecret)},
            {application, server, roadrunner_quic_keys:traffic_keys(ServerApSecret)},
            {application, client, roadrunner_quic_keys:traffic_keys(ClientApSecret)}
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
%% Error paths
%% =============================================================================

missing_key_share_rejected_test() ->
    State = rsa_state(),
    %% Offer a scheme the RSA cert does NOT match (0x0403), so a passing
    %% missing_key_share (rather than no_common_sig_alg) pins key_share as
    %% the earlier gate.
    Body = client_hello_body(#{sig_algs => [16#0403], alpn => ~"h3", session_id => <<>>}),
    ?assertEqual({error, missing_key_share}, ?M:process_client_hello(Body, State)).

no_application_protocol_rejected_test() ->
    State = rsa_state(),
    {ClientPub, _} = crypto:generate_key(ecdh, x25519),
    %% Valid key_share and the RSA cert's scheme, but the client offers
    %% only h2: the configured h3 is not on offer.
    Body = client_hello_body(#{
        key_share => ClientPub, sig_algs => [16#0804], alpn => ~"h2", session_id => <<>>
    }),
    ?assertEqual({error, no_application_protocol}, ?M:process_client_hello(Body, State)).

no_common_sig_alg_rejected_test() ->
    State = rsa_state(),
    {ClientPub, _} = crypto:generate_key(ecdh, x25519),
    %% Offer only ecdsa; the cert key is RSA (rsa_pss_rsae_sha256, 0x0804).
    Body = client_hello_body(#{
        key_share => ClientPub, sig_algs => [16#0403], alpn => ~"h3", session_id => <<>>
    }),
    ?assertEqual({error, no_common_sig_alg}, ?M:process_client_hello(Body, State)).

malformed_client_hello_rejected_test() ->
    State = rsa_state(),
    ?assertEqual(
        {error, malformed_client_hello}, ?M:process_client_hello(~"not a client hello", State)
    ).

%% RFC 9001 §8.2: a ClientHello without the quic_transport_parameters extension
%% MUST close the connection. The key_share/scheme/alpn gates pass, so the
%% missing-extension gate is what fails.
missing_transport_params_rejected_test() ->
    State = rsa_state(),
    {ClientPub, _} = crypto:generate_key(ecdh, x25519),
    Body = client_hello_body(#{
        key_share => ClientPub, sig_algs => [16#0804], alpn => ~"h3", session_id => <<>>
    }),
    ?assertEqual({error, missing_transport_params}, ?M:process_client_hello(Body, State)).

%% RFC 9000 §7.3: the quic_transport_parameters extension is present but omits
%% initial_source_connection_id, so the connection-id binding cannot be verified.
missing_initial_scid_rejected_test() ->
    State = rsa_state(),
    {ClientPub, _} = crypto:generate_key(ecdh, x25519),
    Body = client_hello_body(#{
        key_share => ClientPub,
        sig_algs => [16#0804],
        alpn => ~"h3",
        session_id => <<>>,
        transport_params => #{initial_max_data => 4096}
    }),
    ?assertEqual({error, transport_parameter_error}, ?M:process_client_hello(Body, State)).

%% RFC 9000 §7.3: the client's advertised initial_source_connection_id does not
%% equal the Source Connection ID of its Initial (rsa_state's peer_scid).
initial_scid_mismatch_rejected_test() ->
    State = rsa_state(),
    {ClientPub, _} = crypto:generate_key(ecdh, x25519),
    Body = client_hello_body(#{
        key_share => ClientPub,
        sig_algs => [16#0804],
        alpn => ~"h3",
        session_id => <<>>,
        transport_params => #{initial_source_connection_id => <<9, 9, 9, 9>>}
    }),
    ?assertEqual({error, transport_parameter_error}, ?M:process_client_hello(Body, State)).

%% =============================================================================
%% Helpers
%% =============================================================================

rsa_state() ->
    {_, PrivKey, _, _} = key_material(rsa),
    {ServerPub, ServerPriv} = crypto:generate_key(ecdh, x25519),
    ?M:new(#{
        cert_chain => [~"leaf-cert-der"],
        priv_key => PrivKey,
        alpn => ~"h3",
        transport_params => #{initial_source_connection_id => <<1, 2, 3, 4>>},
        eph_pub => ServerPub,
        eph_priv => ServerPriv,
        server_random => crypto:strong_rand_bytes(32),
        %% The client Initial SCID the §7.3 check compares against; the
        %% error-path tests fail at an earlier gate, so any binary serves.
        peer_scid => <<1, 2, 3, 4>>
    }).

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

%% Build a ClientHello body (RFC 8446 §4.1.2) carrying the requested
%% extensions; the x25519 key_share is omitted when no key is given.
client_hello_body(Opts) ->
    Random = maps:get(random, Opts, crypto:strong_rand_bytes(32)),
    SessionId = maps:get(session_id, Opts, <<>>),
    SigAlgs = maps:get(sig_algs, Opts, [16#0804]),
    Alpn = maps:get(alpn, Opts, ~"h3"),
    Extensions = iolist_to_binary([
        signature_algorithms_ext(SigAlgs),
        alpn_ext(Alpn),
        key_share_ext(maps:get(key_share, Opts, undefined)),
        transport_params_ext(maps:get(transport_params, Opts, undefined))
    ]),
    CipherSuites = <<?CIPHER_AES_128_GCM_SHA256:16>>,
    <<?LEGACY_VERSION:16, Random/binary, (byte_size(SessionId)):8, SessionId/binary,
        (byte_size(CipherSuites)):16, CipherSuites/binary, 1:8, 0:8, (byte_size(Extensions)):16,
        Extensions/binary>>.

signature_algorithms_ext(Schemes) ->
    List = <<<<S:16>> || S <- Schemes>>,
    extension(?EXT_SIGNATURE_ALGORITHMS, <<(byte_size(List)):16, List/binary>>).

alpn_ext(Protocol) ->
    Entry = <<(byte_size(Protocol)):8, Protocol/binary>>,
    extension(?EXT_ALPN, <<(byte_size(Entry)):16, Entry/binary>>).

key_share_ext(undefined) ->
    <<>>;
key_share_ext(PubKey) ->
    Entry = <<?GROUP_X25519:16, (byte_size(PubKey)):16, PubKey/binary>>,
    extension(?EXT_KEY_SHARE, <<(byte_size(Entry)):16, Entry/binary>>).

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

%% The server's x25519 public key from a ServerHello's key_share extension.
server_hello_key_share(ServerHello) ->
    {?SERVER_HELLO, Body, <<>>} = deframe(ServerHello),
    <<_LegacyVersion:16, _Random:32/binary, SessionLen:8, _Session:SessionLen/binary, _Cipher:16,
        _Compression:8, _ExtsLen:16, Extensions/binary>> = Body,
    <<?GROUP_X25519:16, KeyLen:16, PubKey:KeyLen/binary>> =
        extract_extension(?EXT_KEY_SHARE, Extensions),
    PubKey.

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
