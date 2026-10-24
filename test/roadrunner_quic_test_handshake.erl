-module(roadrunner_quic_test_handshake).
-moduledoc false.

%% The client side of the TLS 1.3 / QUIC handshake sequencer, the in-test
%% mirror of `roadrunner_quic_tls_server`. Given the client's ephemeral
%% private key, the ClientHello it sent, and the server's public key, it
%% consumes the server's flight, runs ECDHE over the server's key_share (in
%% the group the ServerHello selected), derives the handshake and
%% application traffic secrets exactly as the server does, verifies the
%% server's CertificateVerify and Finished, and produces the client's
%% Finished. Pure: no process, no socket; the connection loop reassembles
%% the CRYPTO bytes, installs keys from the returned traffic secrets, and
%% emits the client Finished. The transcript is threaded across the four
%% hash boundaries (RFC 8446 §7.1) using the re-framed received messages,
%% byte-identical to the wire bytes. The key schedule runs over the hash of
%% the cipher suite the ServerHello selected (RFC 8446 §7.1), and the packet
%% keys use its AEAD (RFC 9001 §5.3), which each install carries.
%%
%% `handshake_keys/2` derives just the handshake-level packet keys from the
%% ServerHello, so the connection loop can decrypt the Handshake-level
%% packets (which carry the rest of the flight) before it has the whole
%% flight.

-export([handshake_keys/2, process_server_flight/2]).

-export_type([config/0, flight/0, install/0, result/0]).

%% Handshake message types (RFC 8446 §4).
-define(SERVER_HELLO, 2).
-define(ENCRYPTED_EXTENSIONS, 8).
-define(CERTIFICATE, 11).
-define(CERTIFICATE_VERIFY, 15).
-define(FINISHED, 20).

-type install() ::
    {handshake | application, server | client, roadrunner_quic_aead:cipher(), Secret :: binary()}.

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
    %% The server's transport parameters as raw bytes (see
    %% roadrunner_quic_test_client:parse_encrypted_extensions/1).
    peer_transport_params := binary()
}.

%% The handshake-secret derivation context shared by handshake_keys/2 and
%% process_server_flight/2: the transcript through ServerHello and the
%% handshake traffic secrets both ends derive from it.
-type context() :: #{
    aead := roadrunner_quic_aead:cipher(),
    hash := roadrunner_quic_hkdf:hash(),
    handshake_secret := binary(),
    client_hs_secret := binary(),
    server_hs_secret := binary(),
    through_server_hello := iolist()
}.

-doc """
Derive the server and client handshake-level packet-protection keys from the
ServerHello alone (the framed ServerHello bytes from the Initial CRYPTO
stream). `Config` carries the client's ephemeral private key and the
framed ClientHello it sent. The connection loop uses the server keys to
decrypt the Handshake-level packets carrying the rest of the flight.
""".
-spec handshake_keys(config(), iodata()) ->
    #{server := roadrunner_quic_keys:keys(), client := roadrunner_quic_keys:keys()}.
handshake_keys(Config, ServerHelloFramed) ->
    #{aead := Aead, client_hs_secret := ClientHsSecret, server_hs_secret := ServerHsSecret} =
        through_server_hello(Config, ServerHelloFramed),
    #{
        server => roadrunner_quic_keys:traffic_keys(Aead, ServerHsSecret),
        client => roadrunner_quic_keys:traffic_keys(Aead, ClientHsSecret)
    }.

-doc """
Drive the client through the server's flight. `Config` carries the client's
ephemeral private key, the framed ClientHello it sent (the transcript
head), and the server's public key (to verify CertificateVerify). `Flight`
is the server's `#{initial := ServerHello, handshake := EE++Cert++CertVerify++Finished}`
CRYPTO bytes. Returns the ordered traffic-secret installs (handshake before
application, server then client), the framed client Finished, and the negotiated ALPN
protocol and the server's transport parameters. Fails with
`{error, handshake_verification_failed}` if the server CertificateVerify or
Finished does not check out.
""".
-spec process_server_flight(config(), flight()) -> {ok, result()} | {error, atom()}.
process_server_flight(
    #{server_pubkey := ServerPubKey} = Config,
    #{initial := InitialBytes, handshake := HandshakeBytes}
) ->
    #{
        aead := Aead,
        hash := Hash,
        handshake_secret := HandshakeSecret,
        client_hs_secret := ClientHsSecret,
        server_hs_secret := ServerHsSecret,
        through_server_hello := ThroughServerHello
    } = through_server_hello(Config, InitialBytes),
    [
        {?ENCRYPTED_EXTENSIONS, EeBody},
        {?CERTIFICATE, CertBody},
        {?CERTIFICATE_VERIFY, CvBody},
        {?FINISHED, FinBody}
    ] = roadrunner_quic_test_client:deframe_all(HandshakeBytes),
    #{alpn := Alpn, transport_params := PeerParams} =
        roadrunner_quic_test_client:parse_encrypted_extensions(EeBody),

    %% Re-frame the received bodies for the transcript (deterministic framing
    %% makes this byte-identical to the wire bytes).
    EeFramed = roadrunner_quic_tls_handshake:encode(?ENCRYPTED_EXTENSIONS, EeBody),
    CertFramed = roadrunner_quic_tls_handshake:encode(?CERTIFICATE, CertBody),
    CvFramed = roadrunner_quic_tls_handshake:encode(?CERTIFICATE_VERIFY, CvBody),
    FinFramed = roadrunner_quic_tls_handshake:encode(?FINISHED, FinBody),

    %% The server CertificateVerify signs the transcript through Certificate.
    ThroughCertificate = [ThroughServerHello, EeFramed, CertFramed],
    CertificateHash = roadrunner_quic_tls_crypto:transcript_hash(Hash, ThroughCertificate),
    {Scheme, Signature} = roadrunner_quic_test_client:parse_certificate_verify(CvBody),

    %% The server Finished verify_data is over the transcript through CertVerify.
    ThroughCertVerify = [ThroughCertificate, CvFramed],
    CertVerifyHash = roadrunner_quic_tls_crypto:transcript_hash(Hash, ThroughCertVerify),
    ServerVerifyData = roadrunner_quic_test_client:parse_finished(FinBody),

    maybe
        true ?=
            roadrunner_quic_test_client:verify_server_certificate_verify(
                Scheme, Signature, ServerPubKey, CertificateHash
            ),
        true ?= verify_server_finished(Hash, ServerVerifyData, ServerHsSecret, CertVerifyHash),

        %% Application traffic secrets from the transcript through the server
        %% Finished; the client Finished is built over the same hash.
        ThroughFinished = [ThroughCertVerify, FinFramed],
        FinishedHash = roadrunner_quic_tls_crypto:transcript_hash(Hash, ThroughFinished),
        MasterSecret = roadrunner_quic_tls_crypto:master_secret(Hash, HandshakeSecret),
        ClientApSecret = roadrunner_quic_tls_crypto:traffic_secret(
            Hash, client, application, MasterSecret, FinishedHash
        ),
        ServerApSecret = roadrunner_quic_tls_crypto:traffic_secret(
            Hash, server, application, MasterSecret, FinishedHash
        ),
        ClientFinished = roadrunner_quic_tls_auth:build_finished(
            Hash, ClientHsSecret, FinishedHash
        ),
        Installs = [
            {handshake, server, Aead, ServerHsSecret},
            {handshake, client, Aead, ClientHsSecret},
            {application, server, Aead, ServerApSecret},
            {application, client, Aead, ClientApSecret}
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

%% ECDHE over the server's key_share + the handshake key schedule, from the
%% transcript through ServerHello. Mirrors the first half of the server's
%% build_flight. Takes the framed ServerHello (the Initial CRYPTO bytes).
-spec through_server_hello(config(), iodata()) -> context().
through_server_hello(
    #{eph_priv := EphPriv, client_hello_framed := ClientHelloFramed}, InitialBytes
) ->
    [{?SERVER_HELLO, ShBody}] = roadrunner_quic_test_client:deframe_all(InitialBytes),
    #{cipher := Cipher, group := Group, key_share := ServerKeyShare} =
        roadrunner_quic_test_client:parse_server_hello(ShBody),
    ServerHelloFramed = roadrunner_quic_tls_handshake:encode(?SERVER_HELLO, ShBody),
    ThroughServerHello = [ClientHelloFramed, ServerHelloFramed],
    SharedSecret = crypto:compute_key(ecdh, ServerKeyShare, EphPriv, curve(Group)),
    {Aead, Hash} = suite(Cipher),
    HandshakeSecret = roadrunner_quic_tls_crypto:handshake_secret(
        Hash, roadrunner_quic_tls_crypto:early_secret(Hash), SharedSecret
    ),
    HelloHash = roadrunner_quic_tls_crypto:transcript_hash(Hash, ThroughServerHello),
    #{
        aead => Aead,
        hash => Hash,
        handshake_secret => HandshakeSecret,
        client_hs_secret => roadrunner_quic_tls_crypto:traffic_secret(
            Hash, client, handshake, HandshakeSecret, HelloHash
        ),
        server_hs_secret => roadrunner_quic_tls_crypto:traffic_secret(
            Hash, server, handshake, HandshakeSecret, HelloHash
        ),
        through_server_hello => ThroughServerHello
    }.

%% The `crypto` curve of a key exchange group (RFC 8446 §4.2.7).
-spec curve(non_neg_integer()) -> x25519 | secp256r1.
curve(16#001D) -> x25519;
curve(16#0017) -> secp256r1.

%% The packet-protection AEAD (RFC 9001 §5.3) and key-schedule hash (RFC
%% 8446 Appendix B.4) of a cipher suite.
-spec suite(non_neg_integer()) -> {roadrunner_quic_aead:cipher(), roadrunner_quic_hkdf:hash()}.
suite(16#1301) -> {aes_128_gcm, sha256};
suite(16#1302) -> {aes_256_gcm, sha384};
suite(16#1303) -> {chacha20_poly1305, sha256}.

%% The server Finished verify_data is HMAC(finished_key(ServerHsSecret),
%% TranscriptHash); check it in constant time (RFC 8446 §4.4.4).
-spec verify_server_finished(roadrunner_quic_hkdf:hash(), binary(), binary(), binary()) ->
    boolean().
verify_server_finished(Hash, Received, ServerHsSecret, TranscriptHash) ->
    Expected = roadrunner_quic_tls_crypto:verify_data(
        Hash, roadrunner_quic_tls_crypto:finished_key(Hash, ServerHsSecret), TranscriptHash
    ),
    crypto:hash_equals(Received, Expected).
