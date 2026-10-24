-module(roadrunner_quic_tls_server).
-moduledoc false.

%% TLS 1.3 server-handshake sequencer (RFC 8446 §4, RFC 9001 §4-5) for a
%% server-only QUIC v1 endpoint: the pure decision core that drives the
%% handshake forward over the message-layer modules
%% (`roadrunner_quic_tls_hello`, `_auth`, `_crypto`, `_transport_params`).
%% It is not a process and touches no socket; the connection loop
%% reassembles CRYPTO frames, calls these functions with the deframed
%% handshake-message bodies, emits the returned flight at the named
%% encryption levels, and installs packet-protection keys derived from the
%% returned traffic secrets.
%%
%% `process_client_hello/2` consumes the ClientHello body and produces the
%% whole server flight grouped by QUIC encryption level (ServerHello at
%% Initial; EncryptedExtensions, Certificate, CertificateVerify, Finished
%% at Handshake) plus the ordered key installs each level unlocks.
%% `process_client_finished/2` verifies the client's Finished. The running
%% TLS transcript is threaded across the four transcript-hash points
%% (RFC 8446 §7.1/§4.4): handshake traffic secrets from the transcript
%% through ServerHello, the CertificateVerify signature from the transcript
%% through Certificate, the server Finished verify_data from the transcript
%% through CertificateVerify, and the application traffic secrets (plus the
%% client Finished it must check) from the transcript through the server
%% Finished.
%%
%% Negotiation that the codec layer leaves out is done here: the TLS version
%% (the client must offer TLS 1.3 in supported_versions, RFC 8446 §4.2.1), the
%% cipher suite (TLS_AES_128_GCM_SHA256 or TLS_CHACHA20_POLY1305_SHA256, picked
%% from the client's offer, RFC 8446 §4.1.1), the x25519 shared secret (ECDHE
%% over the client's key_share), the CertificateVerify signature scheme (the
%% cert key's scheme intersected with the client's offer), and the ALPN
%% protocol (the client must offer the configured one, RFC 7301 §3.2). The
%% mandatory quic_transport_parameters extension (RFC 9001 §8.2) and the
%% client's initial_source_connection_id binding (RFC 9000 §7.3, against the
%% Initial Source Connection ID passed in as `peer_scid`) are also enforced
%% here. Both cipher suites hash with SHA-256, so the key schedule is the same
%% for either; the suite picks the AEAD of the Handshake and 1-RTT packet keys
%% (RFC 9001 §5.3). Attacker-controlled inputs fail with a flat `{error,
%% atom()}` (a malformed ClientHello, no TLS 1.3 on offer, no common cipher
%% suite, a missing x25519 key_share, no common signature scheme, no offered
%% ALPN match, a missing transport-parameters extension, a connection-id
%% mismatch, a client Finished mismatch); a cert/key whose type is unsupported
%% is server config and legitimately crashes.
%%
%% The server's x25519 ephemeral key pair and ServerHello random are
%% inputs (the connection loop generates them per connection), which keeps
%% the core deterministic and testable against fixed vectors.

-include_lib("public_key/include/public_key.hrl").

-export([new/1, process_client_hello/2, process_client_finished/2]).

-export_type([t/0, config/0, flight/0, install/0]).

%% ClientHello handshake type (RFC 8446 §4), for re-framing the body into
%% the transcript; the server messages are framed by their builders.
-define(CLIENT_HELLO, 1).

%% The one TLS version the server speaks (RFC 8446 §4.2.1, RFC 9001 §4.2).
-define(TLS_1_3, 16#0304).

%% Cipher suites (RFC 8446 Appendix B.4) supported in v1.
-define(TLS_AES_128_GCM_SHA256, 16#1301).
-define(TLS_CHACHA20_POLY1305_SHA256, 16#1303).

%% Signature schemes (RFC 8446 §4.2.3) supported in v1, one per key type.
-define(SIG_RSA_PSS_RSAE_SHA256, 16#0804).
-define(SIG_ECDSA_SECP256R1_SHA256, 16#0403).
-define(SIG_ED25519, 16#0807).

-record(server, {
    cert_chain :: [binary()],
    priv_key :: public_key:private_key(),
    alpn :: binary(),
    transport_params :: roadrunner_quic_transport_params:params(),
    eph_pub :: binary(),
    eph_priv :: binary(),
    server_random :: binary(),
    %% The Source Connection ID of the client's first Initial packet: the
    %% client's initial_source_connection_id transport parameter must equal it
    %% (RFC 9000 §7.3).
    peer_scid :: binary(),
    %% Filled by process_client_hello/2, read by process_client_finished/2.
    client_hs_secret = <<>> :: binary(),
    client_finished_hash = <<>> :: binary()
}).

-opaque t() :: #server{}.

-type config() :: #{
    cert_chain := [binary()],
    priv_key := public_key:private_key(),
    alpn := binary(),
    transport_params := roadrunner_quic_transport_params:params(),
    eph_pub := binary(),
    eph_priv := binary(),
    server_random := binary(),
    peer_scid := binary()
}.

-type flight() :: #{initial := iolist(), handshake := iolist()}.

%% A traffic secret for one level and direction (RFC 8446 §7.1), with the
%% AEAD of the negotiated cipher suite that the packet keys derived from it
%% use (RFC 9001 §5.3).
-type install() ::
    {handshake | application, server | client, roadrunner_quic_aead:cipher(), Secret :: binary()}.

-doc """
Build the handshake state from the per-connection config: the server's DER
certificate chain (leaf first) and private key, the selected ALPN
protocol, the server transport parameters (already carrying the
`original_destination_connection_id` and `initial_source_connection_id`
the loop fills in), the server's x25519 ephemeral key pair, the ServerHello
random, and the client's Initial Source Connection ID (`peer_scid`, the value
the client's `initial_source_connection_id` transport parameter must match,
RFC 9000 §7.3).
""".
-spec new(config()) -> t().
new(#{
    cert_chain := CertChain,
    priv_key := PrivKey,
    alpn := Alpn,
    transport_params := TransportParams,
    eph_pub := EphPub,
    eph_priv := EphPriv,
    server_random := ServerRandom,
    peer_scid := PeerSCID
}) ->
    #server{
        cert_chain = CertChain,
        priv_key = PrivKey,
        alpn = Alpn,
        transport_params = TransportParams,
        eph_pub = EphPub,
        eph_priv = EphPriv,
        server_random = ServerRandom,
        peer_scid = PeerSCID
    }.

-doc """
Process the client's ClientHello body (as handed up by
`roadrunner_quic_tls_handshake:decode/1`) and produce the server's whole
first flight.

Returns `{ok, Flight, Installs, State}` where `Flight` groups the framed
handshake messages by QUIC encryption level (`initial` carries the
ServerHello; `handshake` carries EncryptedExtensions, Certificate,
CertificateVerify, and the server Finished) and `Installs` is the ordered
list of traffic secrets the loop derives its packet-protection keys from
(RFC 9001 §5.1), each with the negotiated suite's AEAD (§5.3): the
handshake secrets (so it can read the client's encrypted Finished) before
the application secrets. The loop keeps the application secrets to derive
later key generations from, for the same AEAD (§6.1).
The returned `State` carries what `process_client_finished/2` needs.

Fails with `{error, Reason}` on a malformed ClientHello, a
supported_versions that does not offer TLS 1.3 (`protocol_version`), no
cipher suite shared with the client's offer (`no_common_cipher_suite`), a
missing x25519 key_share (`missing_key_share`), no signature scheme shared
between the cert key and the client's offer (`no_common_sig_alg`), a client
that did not offer the configured ALPN protocol (`no_application_protocol`), a
ClientHello without the quic_transport_parameters extension
(`missing_transport_params`, RFC 9001 §8.2), or a client
`initial_source_connection_id` that does not equal (or is absent for) the
Source Connection ID of its first Initial packet (`transport_parameter_error`,
RFC 9000 §7.3).
""".
-spec process_client_hello(binary(), t()) ->
    {ok, flight(), [install()], roadrunner_quic_transport_params:params(), t()} | {error, atom()}.
process_client_hello(
    ClientHelloBody, #server{priv_key = PrivKey, alpn = Alpn, peer_scid = PeerSCID} = State
) ->
    maybe
        {ok,
            #{
                session_id := SessionId,
                supported_versions := Versions,
                cipher_suites := CipherSuites,
                signature_algorithms := SigAlgs,
                alpn_protocols := ClientAlpns
            } = ClientHello} ?=
            roadrunner_quic_tls_hello:parse_client_hello(ClientHelloBody),
        ok ?= check_version(Versions),
        {ok, CipherSuite} ?= select_cipher_suite(CipherSuites),
        {ok, ClientKeyShare} ?= client_key_share(ClientHello),
        {ok, Scheme} ?= negotiate_scheme(PrivKey, SigAlgs),
        ok ?= check_alpn(Alpn, ClientAlpns),
        ok ?= check_transport_params(ClientHello),
        ok ?= check_initial_scid(ClientHello, PeerSCID),
        {ok, Flight, Installs, State1} =
            build_flight(ClientHelloBody, SessionId, CipherSuite, ClientKeyShare, Scheme, State),
        %% Surface the client's advertised transport params (presence already
        %% checked) so the loop can seed its send windows from them.
        {ok, Flight, Installs, maps:get(transport_params, ClientHello), State1}
    end.

-doc """
Verify the client's Finished body (RFC 8446 §4.4.4) against the transcript
through the server Finished, using the client handshake traffic secret.
Returns `ok` on success or `{error, handshake_failure}` on a mismatch.
After this the loop confirms the handshake and emits HANDSHAKE_DONE.
""".
-spec process_client_finished(binary(), t()) -> ok | {error, handshake_failure}.
process_client_finished(ClientFinishedBody, #server{
    client_hs_secret = ClientHsSecret, client_finished_hash = TranscriptHash
}) ->
    case
        roadrunner_quic_tls_auth:verify_client_finished(
            ClientFinishedBody, ClientHsSecret, TranscriptHash
        )
    of
        true -> ok;
        false -> {error, handshake_failure}
    end.

%% =============================================================================
%% Internal
%% =============================================================================

%% RFC 8446 §4.2.1: the server negotiates TLS 1.3 only (as QUIC requires, RFC
%% 9001 §4.2), so the client's supported_versions must list 0x0304. Without it
%% there is no version both ends speak: a ClientHello offering only older
%% versions, or carrying no supported_versions at all (a TLS 1.2 ClientHello,
%% RFC 8446 Appendix D.2, which the codec reads as an empty list), is a
%% protocol_version alert.
-spec check_version([non_neg_integer()]) -> ok | {error, protocol_version}.
check_version(Versions) ->
    case lists:member(?TLS_1_3, Versions) of
        true -> ok;
        false -> {error, protocol_version}
    end.

%% The cipher suite and its packet-protection AEAD (RFC 9001 §5.3), in server
%% preference order: TLS_AES_128_GCM_SHA256 (mandatory to implement, RFC 8446
%% §9.1, and the Initial packets' AEAD) before TLS_CHACHA20_POLY1305_SHA256.
%% The first one the client offered wins. Offered suites the server does not
%% support are ignored (RFC 8446 §4.1.2, RFC 9001 §5.3); no overlap at all is a
%% handshake_failure (RFC 8446 §4.1.1).
-spec select_cipher_suite([non_neg_integer()]) ->
    {ok, {non_neg_integer(), roadrunner_quic_aead:cipher()}} | {error, no_common_cipher_suite}.
select_cipher_suite(Offered) ->
    Supported = [
        {?TLS_AES_128_GCM_SHA256, aes_128_gcm},
        {?TLS_CHACHA20_POLY1305_SHA256, chacha20_poly1305}
    ],
    case [Suite || {Codepoint, _Aead} = Suite <- Supported, lists:member(Codepoint, Offered)] of
        [Suite | _] -> {ok, Suite};
        [] -> {error, no_common_cipher_suite}
    end.

%% The client's x25519 public key, or an error when it offered none (v1
%% requires an x25519 key_share; HelloRetryRequest is not implemented).
-spec client_key_share(roadrunner_quic_tls_hello:client_hello()) ->
    {ok, binary()} | {error, missing_key_share}.
client_key_share(#{key_share := ClientPub}) -> {ok, ClientPub};
client_key_share(#{}) -> {error, missing_key_share}.

%% RFC 9001 §8.2: a ClientHello MUST carry the quic_transport_parameters
%% extension; its absence is a fatal missing_extension. The codec leaves an
%% absent extension out of the parsed map, so presence is the key being set (a
%% present-but-malformed extension already failed the parse with its own error).
-spec check_transport_params(roadrunner_quic_tls_hello:client_hello()) ->
    ok | {error, missing_transport_params}.
check_transport_params(#{transport_params := _}) -> ok;
check_transport_params(#{}) -> {error, missing_transport_params}.

%% RFC 9000 §7.3: the client's initial_source_connection_id transport parameter
%% MUST equal the Source Connection ID of its first Initial packet (the value
%% the loop captured as peer_scid). The first clause binds PeerSCID twice (the
%% function argument and the map value), so it matches ONLY when they are equal;
%% a mismatch, a missing initial_source_connection_id, or (after
%% check_transport_params) an absent extension all fall to the second clause as
%% a transport_parameter_error.
-spec check_initial_scid(roadrunner_quic_tls_hello:client_hello(), binary()) ->
    ok | {error, transport_parameter_error}.
check_initial_scid(#{transport_params := #{initial_source_connection_id := PeerSCID}}, PeerSCID) ->
    ok;
check_initial_scid(#{}, _PeerSCID) ->
    {error, transport_parameter_error}.

%% The CertificateVerify scheme for the cert key, if the client offered it
%% in its signature_algorithms. The scheme is fixed by the key type (v1
%% supports one per type); a cert key of an unsupported type is server
%% config and crashes here.
-spec negotiate_scheme(public_key:private_key(), [non_neg_integer()]) ->
    {ok, non_neg_integer()} | {error, no_common_sig_alg}.
negotiate_scheme(PrivKey, Offered) ->
    Scheme = scheme_for_key(PrivKey),
    case lists:member(Scheme, Offered) of
        true -> {ok, Scheme};
        false -> {error, no_common_sig_alg}
    end.

%% v1 offers a single ALPN protocol, so negotiation degenerates to the
%% client having offered it; no overlap is a no_application_protocol alert
%% (RFC 7301 §3.2).
-spec check_alpn(binary(), [binary()]) -> ok | {error, no_application_protocol}.
check_alpn(Configured, Offered) ->
    case lists:member(Configured, Offered) of
        true -> ok;
        false -> {error, no_application_protocol}
    end.

-spec scheme_for_key(public_key:private_key()) -> non_neg_integer().
scheme_for_key(#'RSAPrivateKey'{}) ->
    ?SIG_RSA_PSS_RSAE_SHA256;
scheme_for_key(#'ECPrivateKey'{parameters = {namedCurve, ?'id-Ed25519'}}) ->
    ?SIG_ED25519;
scheme_for_key(#'ECPrivateKey'{parameters = {namedCurve, ?'secp256r1'}}) ->
    ?SIG_ECDSA_SECP256R1_SHA256.

%% Build the full server flight, threading the transcript across the four
%% hash boundaries and deriving the handshake then application traffic
%% secrets, whose packet keys protect with the selected suite's AEAD. The
%% transcript is an iolist of framed messages; `transcript_hash/1` accepts
%% iodata, so it is never flattened here.
-spec build_flight(
    binary(),
    binary(),
    {non_neg_integer(), roadrunner_quic_aead:cipher()},
    binary(),
    non_neg_integer(),
    t()
) -> {ok, flight(), [install()], t()}.
build_flight(
    ClientHelloBody,
    SessionId,
    {CipherSuite, Aead},
    ClientKeyShare,
    Scheme,
    #server{
        cert_chain = CertChain,
        priv_key = PrivKey,
        alpn = Alpn,
        transport_params = TransportParams,
        eph_pub = EphPub,
        eph_priv = EphPriv,
        server_random = ServerRandom
    } = State
) ->
    %% ServerHello (Initial level); the running transcript starts with the
    %% re-framed ClientHello (byte-identical to the wire message).
    ClientHelloFramed = roadrunner_quic_tls_handshake:encode(?CLIENT_HELLO, ClientHelloBody),
    ServerHello = roadrunner_quic_tls_hello:build_server_hello(#{
        random => ServerRandom,
        session_id => SessionId,
        cipher_suite => CipherSuite,
        key_share => EphPub
    }),
    ThroughServerHello = [ClientHelloFramed, ServerHello],

    %% Handshake traffic secrets from the transcript through ServerHello.
    SharedSecret = crypto:compute_key(ecdh, ClientKeyShare, EphPriv, x25519),
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

    %% EncryptedExtensions + Certificate (Handshake level).
    EncryptedExtensions = roadrunner_quic_tls_hello:build_encrypted_extensions(#{
        alpn => Alpn, transport_params => TransportParams
    }),
    Certificate = roadrunner_quic_tls_auth:build_certificate(CertChain),
    ThroughCertificate = [ThroughServerHello, EncryptedExtensions, Certificate],

    %% CertificateVerify signs the transcript through Certificate; the
    %% emitted (randomized) bytes feed the transcript, not a rebuild.
    CertificateHash = roadrunner_quic_tls_crypto:transcript_hash(ThroughCertificate),
    CertificateVerify = roadrunner_quic_tls_auth:build_certificate_verify(
        Scheme, PrivKey, CertificateHash
    ),
    ThroughCertificateVerify = [ThroughCertificate, CertificateVerify],

    %% Server Finished verify_data over the transcript through CertVerify.
    CertVerifyHash = roadrunner_quic_tls_crypto:transcript_hash(ThroughCertificateVerify),
    Finished = roadrunner_quic_tls_auth:build_finished(ServerHsSecret, CertVerifyHash),
    ThroughFinished = [ThroughCertificateVerify, Finished],

    %% Application traffic secrets from the transcript through the server
    %% Finished; the client Finished is verified over the same hash.
    MasterSecret = roadrunner_quic_tls_crypto:master_secret(HandshakeSecret),
    FinishedHash = roadrunner_quic_tls_crypto:transcript_hash(ThroughFinished),
    ClientApSecret = roadrunner_quic_tls_crypto:traffic_secret(
        client, application, MasterSecret, FinishedHash
    ),
    ServerApSecret = roadrunner_quic_tls_crypto:traffic_secret(
        server, application, MasterSecret, FinishedHash
    ),

    Flight = #{
        initial => ServerHello,
        handshake => [EncryptedExtensions, Certificate, CertificateVerify, Finished]
    },
    Installs = [
        {handshake, server, Aead, ServerHsSecret},
        {handshake, client, Aead, ClientHsSecret},
        {application, server, Aead, ServerApSecret},
        {application, client, Aead, ClientApSecret}
    ],
    State1 = State#server{client_hs_secret = ClientHsSecret, client_finished_hash = FinishedHash},
    {ok, Flight, Installs, State1}.
