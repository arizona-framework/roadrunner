-module(roadrunner_quic_test_handshake).
-moduledoc false.

%% The client side of the TLS 1.3 / QUIC handshake sequencer, the in-test
%% mirror of `roadrunner_quic_tls_server`. Given the client's x25519
%% ephemeral private key, the ClientHello it sent, and the server's public
%% key, it consumes the server's flight, runs ECDHE over the server's
%% key_share, derives the handshake and application traffic secrets exactly
%% as the server does, verifies the server's CertificateVerify and Finished,
%% and produces the client's Finished. Pure: no process, no socket; the
%% connection loop reassembles the CRYPTO bytes, installs the returned keys,
%% and emits the client Finished. The transcript is threaded across the four
%% hash boundaries (RFC 8446 §7.1) using the re-framed received messages,
%% byte-identical to the wire bytes.

-export([process_server_flight/2]).

-export_type([config/0, flight/0, install/0, result/0]).

%% Handshake message types (RFC 8446 §4).
-define(SERVER_HELLO, 2).
-define(ENCRYPTED_EXTENSIONS, 8).
-define(CERTIFICATE, 11).
-define(CERTIFICATE_VERIFY, 15).
-define(FINISHED, 20).

-type install() ::
    {handshake | application, server | client, roadrunner_quic_keys:keys()}.

-type config() :: #{
    eph_priv := binary(),
    client_hello_framed := binary(),
    server_pubkey := public_key:public_key()
}.

-type flight() :: #{initial := iodata(), handshake := iodata()}.

-type result() :: #{
    installs := [install()],
    client_finished := iolist(),
    alpn := binary(),
    peer_transport_params := roadrunner_quic_transport_params:params()
}.

-doc """
Drive the client through the server's flight. `Config` carries the client's
x25519 ephemeral private key, the framed ClientHello it sent (the transcript
head), and the server's public key (to verify CertificateVerify). `Flight`
is the server's `#{initial := ServerHello, handshake := EE++Cert++CertVerify++Finished}`
CRYPTO bytes. Returns the ordered key installs (handshake before application,
server then client), the framed client Finished, and the negotiated ALPN
protocol and the server's transport parameters. Fails with
`{error, handshake_verification_failed}` if the server CertificateVerify or
Finished does not check out.
""".
-spec process_server_flight(config(), flight()) -> {ok, result()} | {error, atom()}.
process_server_flight(
    #{eph_priv := EphPriv, client_hello_framed := ClientHelloFramed, server_pubkey := ServerPubKey},
    #{initial := InitialBytes, handshake := HandshakeBytes}
) ->
    [{?SERVER_HELLO, ShBody}] = roadrunner_quic_test_client:deframe_all(InitialBytes),
    [
        {?ENCRYPTED_EXTENSIONS, EeBody},
        {?CERTIFICATE, CertBody},
        {?CERTIFICATE_VERIFY, CvBody},
        {?FINISHED, FinBody}
    ] = roadrunner_quic_test_client:deframe_all(HandshakeBytes),

    #{key_share := ServerKeyShare} = roadrunner_quic_test_client:parse_server_hello(ShBody),
    #{alpn := Alpn, transport_params := PeerParams} =
        roadrunner_quic_test_client:parse_encrypted_extensions(EeBody),

    %% Re-frame the received bodies for the transcript (deterministic framing
    %% makes this byte-identical to the wire bytes).
    ServerHelloFramed = roadrunner_quic_tls_handshake:encode(?SERVER_HELLO, ShBody),
    EeFramed = roadrunner_quic_tls_handshake:encode(?ENCRYPTED_EXTENSIONS, EeBody),
    CertFramed = roadrunner_quic_tls_handshake:encode(?CERTIFICATE, CertBody),
    CvFramed = roadrunner_quic_tls_handshake:encode(?CERTIFICATE_VERIFY, CvBody),
    FinFramed = roadrunner_quic_tls_handshake:encode(?FINISHED, FinBody),

    %% Handshake traffic secrets from the transcript through ServerHello.
    ThroughServerHello = [ClientHelloFramed, ServerHelloFramed],
    SharedSecret = crypto:compute_key(ecdh, ServerKeyShare, EphPriv, x25519),
    HandshakeSecret = roadrunner_quic_tls_crypto:handshake_secret(
        roadrunner_quic_tls_crypto:early_secret(), SharedSecret
    ),
    HelloHash = roadrunner_quic_tls_crypto:transcript_hash(ThroughServerHello),
    ClientHsSecret = roadrunner_quic_tls_crypto:traffic_secret(
        client, handshake, HandshakeSecret, HelloHash
    ),
    ServerHsSecret = roadrunner_quic_tls_crypto:traffic_secret(
        server, handshake, HandshakeSecret, HelloHash
    ),

    %% The server CertificateVerify signs the transcript through Certificate.
    ThroughCertificate = [ThroughServerHello, EeFramed, CertFramed],
    CertificateHash = roadrunner_quic_tls_crypto:transcript_hash(ThroughCertificate),
    {Scheme, Signature} = roadrunner_quic_test_client:parse_certificate_verify(CvBody),

    %% The server Finished verify_data is over the transcript through CertVerify.
    ThroughCertVerify = [ThroughCertificate, CvFramed],
    CertVerifyHash = roadrunner_quic_tls_crypto:transcript_hash(ThroughCertVerify),
    ServerVerifyData = roadrunner_quic_test_client:parse_finished(FinBody),

    maybe
        true ?=
            roadrunner_quic_test_client:verify_server_certificate_verify(
                Scheme, Signature, ServerPubKey, CertificateHash
            ),
        true ?= verify_server_finished(ServerVerifyData, ServerHsSecret, CertVerifyHash),

        %% Application traffic secrets from the transcript through the server
        %% Finished; the client Finished is built over the same hash.
        ThroughFinished = [ThroughCertVerify, FinFramed],
        FinishedHash = roadrunner_quic_tls_crypto:transcript_hash(ThroughFinished),
        MasterSecret = roadrunner_quic_tls_crypto:master_secret(HandshakeSecret),
        ClientApSecret = roadrunner_quic_tls_crypto:traffic_secret(
            client, application, MasterSecret, FinishedHash
        ),
        ServerApSecret = roadrunner_quic_tls_crypto:traffic_secret(
            server, application, MasterSecret, FinishedHash
        ),
        ClientFinished = roadrunner_quic_tls_auth:build_finished(ClientHsSecret, FinishedHash),
        Installs = [
            {handshake, server, roadrunner_quic_keys:traffic_keys(ServerHsSecret)},
            {handshake, client, roadrunner_quic_keys:traffic_keys(ClientHsSecret)},
            {application, server, roadrunner_quic_keys:traffic_keys(ServerApSecret)},
            {application, client, roadrunner_quic_keys:traffic_keys(ClientApSecret)}
        ],
        {ok, #{
            installs => Installs,
            client_finished => ClientFinished,
            alpn => Alpn,
            peer_transport_params => PeerParams
        }}
    else
        false -> {error, handshake_verification_failed}
    end.

%% =============================================================================
%% Internal
%% =============================================================================

%% The server Finished verify_data is HMAC(finished_key(ServerHsSecret),
%% TranscriptHash); check it in constant time (RFC 8446 §4.4.4).
-spec verify_server_finished(binary(), binary(), binary()) -> boolean().
verify_server_finished(Received, ServerHsSecret, TranscriptHash) ->
    Expected = roadrunner_quic_tls_crypto:verify_data(
        roadrunner_quic_tls_crypto:finished_key(ServerHsSecret), TranscriptHash
    ),
    crypto:hash_equals(Received, Expected).
