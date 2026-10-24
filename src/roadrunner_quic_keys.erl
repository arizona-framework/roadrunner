-module(roadrunner_quic_keys).
-moduledoc false.

%% QUIC v1 packet-protection key derivation (RFC 9001 §5).
%%
%% Initial keys come from the client's Destination Connection ID and the
%% version-1 Initial salt (§5.2) and always protect with AES-128-GCM;
%% handshake and 1-RTT keys come from a TLS 1.3 traffic secret and use the
%% AEAD of the negotiated cipher suite (§5.3): AES-128-GCM (a 16-byte key
%% and a 16-byte AES-128 header-protection key), AES-256-GCM (a 32-byte key
%% and a 32-byte AES-256 header-protection key) or ChaCha20-Poly1305 (a
%% 32-byte key and a 32-byte ChaCha20 header-protection key), each with a
%% 12-byte IV. Each AEAD belongs to exactly one supported suite, so it also
%% names the suite's hash, which every HKDF-Expand-Label over a traffic
%% secret runs on (`roadrunner_quic_hkdf`, §5.1): SHA-384 for AES-256-GCM
%% (TLS_AES_256_GCM_SHA384), SHA-256 for the others and for the Initial
%% keys. Each key is tagged with its algorithm for `roadrunner_quic_aead`.
%% `update/2` derives the next generation's secret and packet-protection key
%% and IV, for the same AEAD, so the server can answer a peer-initiated key
%% update (§6.1),
%% which a v1 endpoint MUST support, and start one of its own before the
%% AEAD confidentiality limit (§6.6).

-export([
    initial_secret/1,
    initial_client/1,
    initial_server/1,
    traffic_keys/2,
    update/2,
    for_connection/2
]).

-export_type([keys/0, packet_keys/0]).

-type keys() :: #{
    key := roadrunner_quic_aead:aead_key(), iv := binary(), hp := roadrunner_quic_aead:hp()
}.

%% The AEAD key and IV of one 1-RTT key generation: what a key update
%% changes, since the header-protection key stays the same (RFC 9001 §6.1).
-type packet_keys() :: #{key := roadrunner_quic_aead:aead_key(), iv := binary()}.

%% RFC 9001 §5.2: the QUIC v1 Initial salt,
%% 0x38762cf7f55934b34d179ae6a4c80cadccbb7f0a.
-define(INITIAL_SALT,
    <<16#38, 16#76, 16#2c, 16#f7, 16#f5, 16#59, 16#34, 16#b3, 16#4d, 16#17, 16#9a, 16#e6, 16#a4,
        16#c8, 16#0c, 16#ad, 16#cc, 16#bb, 16#7f, 16#0a>>
).

-doc """
Derive the Initial secret from a Destination Connection ID (RFC 9001
§5.2): `HKDF-Extract(v1_salt, DCID)`. Both Initial-key directions start
here.
""".
-spec initial_secret(binary()) -> binary().
initial_secret(DCID) ->
    roadrunner_quic_hkdf:extract(sha256, ?INITIAL_SALT, DCID).

-doc """
Derive the client's Initial key/iv/hp from the DCID (RFC 9001 §5.2). The
server decrypts the client's Initial packets and removes their header
protection with these.
""".
-spec initial_client(binary()) -> keys().
initial_client(DCID) ->
    ClientSecret = roadrunner_quic_hkdf:expand_label(
        sha256, initial_secret(DCID), ~"client in", <<>>, 32
    ),
    traffic_keys(aes_128_gcm, ClientSecret).

-doc """
Derive the server's Initial key/iv/hp from the DCID (RFC 9001 §5.2). The
server protects its own Initial packets with these.
""".
-spec initial_server(binary()) -> keys().
initial_server(DCID) ->
    ServerSecret = roadrunner_quic_hkdf:expand_label(
        sha256, initial_secret(DCID), ~"server in", <<>>, 32
    ),
    traffic_keys(aes_128_gcm, ServerSecret).

-doc """
Derive the packet-protection keys for an AEAD from a traffic secret
(RFC 9001 §5.1): the AEAD key (`quic key`), the nonce IV (`quic iv`), and
the header-protection key (`quic hp`), the two keys sized for the AEAD
and its header-protection cipher (§5.4.3, §5.4.4), each expanded with the
hash of the AEAD's cipher suite.
""".
-spec traffic_keys(roadrunner_quic_aead:cipher(), binary()) -> keys().
traffic_keys(Cipher, Secret) ->
    HP = roadrunner_quic_hkdf:expand_label(
        hash(Cipher), Secret, ~"quic hp", <<>>, key_len(Cipher)
    ),
    (packet_keys(Cipher, Secret))#{hp => {hp_cipher(Cipher), HP}}.

-doc """
Derive the next key generation for a key update (RFC 9001 §6.1):
`HKDF-Expand-Label(current_secret, "quic ku", "", Hash.length)` over the
hash of the AEAD's cipher suite gives the updated secret, and the new AEAD
key and IV follow from it (§5.1), for the same AEAD: a key update never
changes the cipher suite. The header-protection key is not updated, so
none is derived: the caller keeps the one it has.
Returns `{UpdatedSecret, PacketKeys}`; the caller keeps `UpdatedSecret` to
derive the generation after this one.
""".
-spec update(roadrunner_quic_aead:cipher(), binary()) -> {binary(), packet_keys()}.
update(Cipher, Secret) ->
    Hash = hash(Cipher),
    UpdatedSecret = roadrunner_quic_hkdf:expand_label(
        Hash, Secret, ~"quic ku", <<>>, roadrunner_quic_hkdf:hash_len(Hash)
    ),
    {UpdatedSecret, packet_keys(Cipher, UpdatedSecret)}.

-doc """
Prepare derived keys for the connection process that will use them, in
the one direction it uses them for: `seal` for the server's own packets,
`open` for the peer's. An AES header-protection key becomes an
initialized AES-ECB state, so each packet's mask is one
`crypto_update/2` instead of a fresh key setup (RFC 9001 §5.4.3: ECB has
no state between blocks); a ChaCha20 one stays the raw key, since every
mask runs under a new IV (§5.4.4). From OTP 28 the packet-protection key
likewise becomes a sealing or opening state for its AEAD. A state must
not be used from two processes at once, so call this where the keys are
installed and use them only in that process. The packet keys of a key
update (`update/2`) carry no header-protection key, so only their AEAD
key is prepared.
""".
-spec for_connection(Keys, seal | open) -> Keys when Keys :: keys() | packet_keys().
for_connection(#{key := {Cipher, Key}, hp := HP} = Keys, Direction) ->
    Keys#{key := aead_state(Cipher, Key, Direction), hp := hp_state(HP)};
for_connection(#{key := {Cipher, Key}} = Keys, Direction) ->
    Keys#{key := aead_state(Cipher, Key, Direction)}.

%% =============================================================================
%% Internal
%% =============================================================================

%% The AEAD key and IV for an AEAD from a traffic secret (RFC 9001 §5.1).
-spec packet_keys(roadrunner_quic_aead:cipher(), binary()) -> packet_keys().
packet_keys(Cipher, Secret) ->
    Hash = hash(Cipher),
    #{
        key =>
            {Cipher,
                roadrunner_quic_hkdf:expand_label(
                    Hash, Secret, ~"quic key", <<>>, key_len(Cipher)
                )},
        iv => roadrunner_quic_hkdf:expand_label(Hash, Secret, ~"quic iv", <<>>, 12)
    }.

%% The hash of the cipher suite an AEAD belongs to (RFC 8446 Appendix B.4):
%% TLS_AES_256_GCM_SHA384 hashes with SHA-384, TLS_AES_128_GCM_SHA256 and
%% TLS_CHACHA20_POLY1305_SHA256 with SHA-256.
-spec hash(roadrunner_quic_aead:cipher()) -> roadrunner_quic_hkdf:hash().
hash(aes_128_gcm) -> sha256;
hash(aes_256_gcm) -> sha384;
hash(chacha20_poly1305) -> sha256.

%% The AEAD key length, which the header-protection key shares: 16 bytes
%% for AES-128, 32 for AES-256 (RFC 9001 §5.4.3) and ChaCha20 (§5.4.4).
-spec key_len(roadrunner_quic_aead:cipher()) -> 16 | 32.
key_len(aes_128_gcm) -> 16;
key_len(aes_256_gcm) -> 32;
key_len(chacha20_poly1305) -> 32.

%% The header-protection cipher of an AEAD (RFC 9001 §5.4.3, §5.4.4).
-spec hp_cipher(roadrunner_quic_aead:cipher()) -> aes_128_ecb | aes_256_ecb | chacha20.
hp_cipher(aes_128_gcm) -> aes_128_ecb;
hp_cipher(aes_256_gcm) -> aes_256_ecb;
hp_cipher(chacha20_poly1305) -> chacha20.

-spec hp_state(roadrunner_quic_aead:hp()) -> roadrunner_quic_aead:hp().
hp_state({aes_128_ecb, HP}) ->
    crypto:crypto_init(aes_128_ecb, HP, true);
hp_state({aes_256_ecb, HP}) ->
    crypto:crypto_init(aes_256_ecb, HP, true);
hp_state({chacha20, _HP} = Raw) ->
    Raw.

-if(?OTP_RELEASE >= 28).
-spec aead_state(roadrunner_quic_aead:cipher(), binary(), seal | open) ->
    roadrunner_quic_aead:aead_key().
aead_state(Cipher, Key, Direction) ->
    crypto:crypto_one_time_aead_init(Cipher, Key, 16, Direction =:= seal).
-else.
%% Before OTP 28 there is no AEAD state API: the tagged raw key stays,
%% for either direction.
-spec aead_state(roadrunner_quic_aead:cipher(), binary(), seal | open) ->
    roadrunner_quic_aead:aead_key().
aead_state(Cipher, Key, seal) ->
    {Cipher, Key};
aead_state(Cipher, Key, open) ->
    {Cipher, Key}.
-endif.
