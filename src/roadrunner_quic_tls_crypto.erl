-module(roadrunner_quic_tls_crypto).
-moduledoc false.

%% TLS 1.3 key-schedule core (RFC 8446 §7.1) for the QUIC handshake.
%%
%% Builds the chain of secrets the handshake derives keys from: the Early
%% Secret (no pre-shared key in v1), the Handshake Secret (from the
%% (EC)DHE shared secret), and the Master Secret. `derive_secret/4` is the
%% TLS 1.3 Derive-Secret over `roadrunner_quic_hkdf`, and
%% `transcript_hash/2` hashes the running handshake transcript. Every step
%% runs over the negotiated cipher suite's hash (§7.1, Appendix B.4), the
%% first argument of each function: SHA-256 for `TLS_AES_128_GCM_SHA256`
%% and `TLS_CHACHA20_POLY1305_SHA256`, SHA-384 for
%% `TLS_AES_256_GCM_SHA384`. Secrets, transcript hashes and Finished
%% verify_data are all that hash's length (32 or 48 bytes).
%%
%% Derive-Secret takes the already-computed transcript hash rather than
%% the raw messages, so the caller is explicit about what is hashed (use
%% `transcript_hash(Hash, <<>>)` for the empty context of the "derived"
%% steps). After a HelloRetryRequest the transcript starts with
%% `message_hash/2` in place of the first ClientHello (RFC 8446 §4.4.1).
%%
%% From the Handshake and Master Secrets it derives the client/server
%% handshake and application traffic secrets, and from a traffic secret
%% the Finished key and a Finished message's verify_data (RFC 8446
%% §4.4.4), used to authenticate the handshake.

-export([
    transcript_hash/2,
    message_hash/2,
    derive_secret/4,
    early_secret/1,
    handshake_secret/3,
    master_secret/2,
    traffic_secret/5,
    finished_key/2,
    verify_data/3
]).

%% The synthetic message_hash handshake type (RFC 8446 §4, §4.4.1).
-define(MESSAGE_HASH, 254).

-doc "Transcript-Hash (RFC 8446 §4.4.1): the suite's hash over the handshake messages.".
-spec transcript_hash(roadrunner_quic_hkdf:hash(), iodata()) -> binary().
transcript_hash(Hash, Messages) ->
    crypto:hash(Hash, Messages).

-doc """
The synthetic message_hash handshake message (RFC 8446 §4.4.1) that takes
the first ClientHello's place in the transcript once the server answers it
with a HelloRetryRequest: handshake type 254, a 24-bit length, then the
transcript hash of `ClientHello1` (the framed first ClientHello), under the
hash of the cipher suite the HelloRetryRequest selected. Returned framed,
as an iolist.
""".
-spec message_hash(roadrunner_quic_hkdf:hash(), iodata()) -> iolist().
message_hash(Hash, ClientHello1) ->
    roadrunner_quic_tls_handshake:encode(?MESSAGE_HASH, transcript_hash(Hash, ClientHello1)).

-doc """
Derive-Secret (RFC 8446 §7.1): an HKDF-Expand-Label keyed by `Secret`,
labelled `Label`, over the transcript hash `TranscriptHash` (the output
of `transcript_hash/2`; pass `transcript_hash(Hash, <<>>)` for the empty
context), one hash length long.
""".
-spec derive_secret(roadrunner_quic_hkdf:hash(), binary(), binary(), binary()) -> binary().
derive_secret(Hash, Secret, Label, TranscriptHash) ->
    roadrunner_quic_hkdf:expand_label(
        Hash, Secret, Label, TranscriptHash, roadrunner_quic_hkdf:hash_len(Hash)
    ).

-doc "The no-PSK Early Secret (RFC 8446 §7.1): `HKDF-Extract(0, 0)`.".
-spec early_secret(roadrunner_quic_hkdf:hash()) -> binary().
early_secret(Hash) ->
    roadrunner_quic_hkdf:extract(Hash, zeros(Hash), zeros(Hash)).

-doc """
The Handshake Secret (RFC 8446 §7.1): `HKDF-Extract` over the (EC)DHE
shared secret, salted by the "derived" secret of the Early Secret.
""".
-spec handshake_secret(roadrunner_quic_hkdf:hash(), binary(), binary()) -> binary().
handshake_secret(Hash, EarlySecret, SharedSecret) ->
    Salt = derive_secret(Hash, EarlySecret, ~"derived", transcript_hash(Hash, <<>>)),
    roadrunner_quic_hkdf:extract(Hash, Salt, SharedSecret).

-doc """
The Master Secret (RFC 8446 §7.1): `HKDF-Extract` over a zero input,
salted by the "derived" secret of the Handshake Secret.
""".
-spec master_secret(roadrunner_quic_hkdf:hash(), binary()) -> binary().
master_secret(Hash, HandshakeSecret) ->
    Salt = derive_secret(Hash, HandshakeSecret, ~"derived", transcript_hash(Hash, <<>>)),
    roadrunner_quic_hkdf:extract(Hash, Salt, zeros(Hash)).

-doc """
A traffic secret (RFC 8446 §7.1), selected by `Direction` (client or
server) and `Level` (handshake or application), derived from the base
secret for that level (the Handshake Secret for `handshake`, the Master
Secret for `application`) and the transcript hash up to that point.
""".
-spec traffic_secret(
    roadrunner_quic_hkdf:hash(), client | server, handshake | application, binary(), binary()
) -> binary().
traffic_secret(Hash, client, handshake, HandshakeSecret, TranscriptHash) ->
    derive_secret(Hash, HandshakeSecret, ~"c hs traffic", TranscriptHash);
traffic_secret(Hash, server, handshake, HandshakeSecret, TranscriptHash) ->
    derive_secret(Hash, HandshakeSecret, ~"s hs traffic", TranscriptHash);
traffic_secret(Hash, client, application, MasterSecret, TranscriptHash) ->
    derive_secret(Hash, MasterSecret, ~"c ap traffic", TranscriptHash);
traffic_secret(Hash, server, application, MasterSecret, TranscriptHash) ->
    derive_secret(Hash, MasterSecret, ~"s ap traffic", TranscriptHash).

-doc """
The Finished key for a traffic secret (RFC 8446 §4.4.4):
`HKDF-Expand-Label(TrafficSecret, "finished", "", Hash.length)`.
""".
-spec finished_key(roadrunner_quic_hkdf:hash(), binary()) -> binary().
finished_key(Hash, TrafficSecret) ->
    roadrunner_quic_hkdf:expand_label(
        Hash, TrafficSecret, ~"finished", <<>>, roadrunner_quic_hkdf:hash_len(Hash)
    ).

-doc """
A Finished message's verify_data (RFC 8446 §4.4.4):
`HMAC(FinishedKey, TranscriptHash)` over the handshake context. The
server computes it with its own Finished key and verifies the client's
with the client's.
""".
-spec verify_data(roadrunner_quic_hkdf:hash(), binary(), binary()) -> binary().
verify_data(Hash, FinishedKey, TranscriptHash) ->
    crypto:mac(hmac, Hash, FinishedKey, TranscriptHash).

%% =============================================================================
%% Internal
%% =============================================================================

%% A hash-length string of zero bytes (the "0" of RFC 8446 §7.1's Extract
%% inputs).
-spec zeros(roadrunner_quic_hkdf:hash()) -> binary().
zeros(Hash) ->
    <<0:(roadrunner_quic_hkdf:hash_len(Hash) * 8)>>.
