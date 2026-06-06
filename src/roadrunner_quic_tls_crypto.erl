-module(roadrunner_quic_tls_crypto).
-moduledoc false.

%% TLS 1.3 key-schedule core (RFC 8446 §7.1) for the QUIC handshake.
%%
%% Builds the chain of secrets the handshake derives keys from: the Early
%% Secret (no pre-shared key in v1), the Handshake Secret (from the
%% (EC)DHE shared secret), and the Master Secret. `derive_secret/3` is the
%% TLS 1.3 Derive-Secret over `roadrunner_quic_hkdf`, and
%% `transcript_hash/1` hashes the running handshake transcript. v1
%% negotiates `TLS_AES_128_GCM_SHA256`, so the hash is SHA-256 throughout.
%%
%% Derive-Secret takes the already-computed transcript hash rather than
%% the raw messages, so the caller is explicit about what is hashed (use
%% `transcript_hash(<<>>)` for the empty context of the "derived" steps).

-export([transcript_hash/1, derive_secret/3, early_secret/0, handshake_secret/2, master_secret/1]).

%% SHA-256 output length (the negotiated hash for v1).
-define(HASH_LEN, 32).

-doc "Transcript-Hash (RFC 8446 §4.4.1): SHA-256 over the concatenated handshake messages.".
-spec transcript_hash(iodata()) -> binary().
transcript_hash(Messages) ->
    crypto:hash(sha256, Messages).

-doc """
Derive-Secret (RFC 8446 §7.1): an HKDF-Expand-Label keyed by `Secret`,
labelled `Label`, over the transcript hash `TranscriptHash` (the output
of `transcript_hash/1`; pass `transcript_hash(<<>>)` for the empty
context).
""".
-spec derive_secret(binary(), binary(), binary()) -> binary().
derive_secret(Secret, Label, TranscriptHash) ->
    roadrunner_quic_hkdf:expand_label(Secret, Label, TranscriptHash, ?HASH_LEN).

-doc "The no-PSK Early Secret (RFC 8446 §7.1): `HKDF-Extract(0, 0)`.".
-spec early_secret() -> binary().
early_secret() ->
    roadrunner_quic_hkdf:extract(zeros(), zeros()).

-doc """
The Handshake Secret (RFC 8446 §7.1): `HKDF-Extract` over the (EC)DHE
shared secret, salted by the "derived" secret of the Early Secret.
""".
-spec handshake_secret(binary(), binary()) -> binary().
handshake_secret(EarlySecret, SharedSecret) ->
    Salt = derive_secret(EarlySecret, ~"derived", transcript_hash(<<>>)),
    roadrunner_quic_hkdf:extract(Salt, SharedSecret).

-doc """
The Master Secret (RFC 8446 §7.1): `HKDF-Extract` over a zero input,
salted by the "derived" secret of the Handshake Secret.
""".
-spec master_secret(binary()) -> binary().
master_secret(HandshakeSecret) ->
    Salt = derive_secret(HandshakeSecret, ~"derived", transcript_hash(<<>>)),
    roadrunner_quic_hkdf:extract(Salt, zeros()).

%% =============================================================================
%% Internal
%% =============================================================================

%% A SHA-256-length string of zero bytes (the "0" of RFC 8446 §7.1's
%% Extract inputs).
-spec zeros() -> binary().
zeros() ->
    <<0:(?HASH_LEN * 8)>>.
