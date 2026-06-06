-module(roadrunner_quic_tls_auth).
-moduledoc false.

%% TLS 1.3 server authentication flight (RFC 8446 §4.4) for a server-only
%% QUIC v1 endpoint: build the Certificate (§4.4.2), CertificateVerify
%% (§4.4.3), and Finished (§4.4.4) messages, and verify the client's
%% Finished. v1 signs with one of rsa_pss_rsae_sha256, ecdsa_secp256r1_sha256,
%% or ed25519, all over SHA-256.
%%
%% `roadrunner_quic_tls_handshake` frames the messages, and
%% `roadrunner_quic_tls_crypto` (finished_key/1 + verify_data/2) backs the
%% Finished MAC. The chosen signature scheme and the signing key come from
%% the connection layer (which owns negotiation), and the certificate chain
%% from `roadrunner_listener:quic_cert_key/1`. Builders return the framed
%% handshake message as an iolist.
%%
%% Signing legitimately crashes on an out-of-contract scheme or key (a
%% function clause), unlike the pure wire codecs: the caller passes a
%% negotiated, supported scheme with a matching key.

-include_lib("public_key/include/public_key.hrl").

-export([
    build_certificate/1,
    build_certificate_verify/3,
    build_finished/2,
    verify_client_finished/3
]).

%% Handshake message types (RFC 8446 §4).
-define(CERTIFICATE, 11).
-define(CERTIFICATE_VERIFY, 15).
-define(FINISHED, 20).

%% Signature schemes (RFC 8446 §4.2.3) supported in v1.
-define(SIG_RSA_PSS_RSAE_SHA256, 16#0804).
-define(SIG_ECDSA_SECP256R1_SHA256, 16#0403).
-define(SIG_ED25519, 16#0807).

%% The server CertificateVerify signature context (RFC 8446 §4.4.3).
-define(CERT_VERIFY_CONTEXT, ~"TLS 1.3, server CertificateVerify").

%% =============================================================================
%% build_certificate/1
%% =============================================================================

-doc """
Build a Certificate message (RFC 8446 §4.4.2) from the server's DER
certificate chain (leaf first), framed as an iolist. The
certificate_request_context is empty (a server responding to a
ClientHello), and each entry carries an empty extensions vector.
""".
-spec build_certificate([binary()]) -> iolist().
build_certificate(Certs) ->
    CertList = cert_list(Certs),
    Body = [<<0:8, (iolist_size(CertList)):24>>, CertList],
    roadrunner_quic_tls_handshake:encode(?CERTIFICATE, Body).

%% =============================================================================
%% build_certificate_verify/3
%% =============================================================================

-doc """
Build a CertificateVerify message (RFC 8446 §4.4.3), framed as an iolist.
Signs the server CertificateVerify content (64 spaces, the context
string, a 0 separator, then `TranscriptHash` through the Certificate
message) with `PrivateKey` under `Scheme` (rsa_pss_rsae_sha256,
ecdsa_secp256r1_sha256, or ed25519). RSA-PSS and ECDSA signatures are
randomized, so the output is not reproducible byte-for-byte.
""".
-spec build_certificate_verify(non_neg_integer(), public_key:private_key(), binary()) -> iolist().
build_certificate_verify(Scheme, PrivateKey, TranscriptHash) ->
    Content = [binary:copy(<<16#20>>, 64), ?CERT_VERIFY_CONTEXT, 0, TranscriptHash],
    Signature = sign(Scheme, PrivateKey, iolist_to_binary(Content)),
    Body = [<<Scheme:16, (byte_size(Signature)):16>>, Signature],
    roadrunner_quic_tls_handshake:encode(?CERTIFICATE_VERIFY, Body).

%% =============================================================================
%% build_finished/2 + verify_client_finished/3
%% =============================================================================

-doc """
Build a Finished message (RFC 8446 §4.4.4), framed as an iolist. The
verify_data is `HMAC(finished_key(TrafficSecret), TranscriptHash)`; the
server passes its handshake traffic secret and the transcript hash
through CertificateVerify.
""".
-spec build_finished(binary(), binary()) -> iolist().
build_finished(TrafficSecret, TranscriptHash) ->
    roadrunner_quic_tls_handshake:encode(
        ?FINISHED, finished_verify_data(TrafficSecret, TranscriptHash)
    ).

-doc """
Verify a client's Finished verify_data (RFC 8446 §4.4.4) in constant
time. Recomputes `HMAC(finished_key(TrafficSecret), TranscriptHash)` (the
client's handshake traffic secret, over the transcript through the server
Finished) and compares it to `Received`.
""".
-spec verify_client_finished(binary(), binary(), binary()) -> boolean().
verify_client_finished(Received, TrafficSecret, TranscriptHash) ->
    crypto:hash_equals(Received, finished_verify_data(TrafficSecret, TranscriptHash)).

%% =============================================================================
%% Internal
%% =============================================================================

%% The CertificateEntry list (RFC 8446 §4.4.2): each cert is a 24-bit
%% length-prefixed DER blob followed by an empty extensions vector. Body
%% recursion, consing on the way out.
-spec cert_list([binary()]) -> iolist().
cert_list([]) ->
    [];
cert_list([Cert | Rest]) ->
    [<<(byte_size(Cert)):24>>, Cert, <<0:16>> | cert_list(Rest)].

%% The Finished verify_data via the C2 key schedule.
-spec finished_verify_data(binary(), binary()) -> binary().
finished_verify_data(TrafficSecret, TranscriptHash) ->
    FinishedKey = roadrunner_quic_tls_crypto:finished_key(TrafficSecret),
    roadrunner_quic_tls_crypto:verify_data(FinishedKey, TranscriptHash).

%% Sign the CertificateVerify content under the negotiated scheme, using
%% the same OTP crypto primitives as the dep.
-spec sign(non_neg_integer(), public_key:private_key(), binary()) -> binary().
sign(Scheme, PrivateKey, Content) ->
    {SigAlg, HashAlg, Options} = signature_params(Scheme),
    crypto:sign(SigAlg, HashAlg, Content, crypto_key(Scheme, PrivateKey), Options).

-spec signature_params(non_neg_integer()) -> {atom(), atom(), [{atom(), atom() | integer()}]}.
signature_params(?SIG_RSA_PSS_RSAE_SHA256) ->
    {rsa, sha256, [{rsa_padding, rsa_pkcs1_pss_padding}, {rsa_pss_saltlen, -1}]};
signature_params(?SIG_ECDSA_SECP256R1_SHA256) ->
    {ecdsa, sha256, []};
signature_params(?SIG_ED25519) ->
    {eddsa, none, []}.

%% Convert the public_key private-key record into the key form crypto:sign
%% expects for the scheme.
-spec crypto_key(non_neg_integer(), public_key:private_key()) -> [integer() | binary() | atom()].
crypto_key(?SIG_RSA_PSS_RSAE_SHA256, #'RSAPrivateKey'{
    publicExponent = E, modulus = N, privateExponent = D
}) ->
    [E, N, D];
crypto_key(?SIG_ECDSA_SECP256R1_SHA256, #'ECPrivateKey'{privateKey = Priv}) ->
    [Priv, secp256r1];
crypto_key(?SIG_ED25519, #'ECPrivateKey'{privateKey = Priv}) ->
    [Priv, ed25519].
