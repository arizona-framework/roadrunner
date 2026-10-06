-module(roadrunner_quic_keys).
-moduledoc false.

%% QUIC v1 packet-protection key derivation (RFC 9001 §5).
%%
%% Initial keys come from the client's Destination Connection ID and the
%% version-1 Initial salt (§5.2); handshake and 1-RTT keys come from a TLS
%% 1.3 traffic secret. v1 negotiates `TLS_AES_128_GCM_SHA256`, so the AEAD
%% is AES-128-GCM throughout: a 16-byte key, a 12-byte IV, and a 16-byte
%% header-protection key, each via HKDF-Expand-Label over SHA-256
%% (`roadrunner_quic_hkdf`). `update/1` derives the next generation's
%% secret and keys so the server can answer a peer-initiated key update
%% (§6.1), which a v1 endpoint MUST support.

-export([
    initial_secret/1,
    initial_client/1,
    initial_server/1,
    traffic_keys/1,
    update/1,
    for_connection/2
]).

-export_type([keys/0]).

-type keys() :: #{
    key := roadrunner_quic_aead:aead_key(), iv := binary(), hp := roadrunner_quic_aead:hp()
}.

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
    roadrunner_quic_hkdf:extract(?INITIAL_SALT, DCID).

-doc """
Derive the client's Initial key/iv/hp from the DCID (RFC 9001 §5.2). The
server decrypts the client's Initial packets and removes their header
protection with these.
""".
-spec initial_client(binary()) -> keys().
initial_client(DCID) ->
    ClientSecret = roadrunner_quic_hkdf:expand_label(initial_secret(DCID), ~"client in", <<>>, 32),
    traffic_keys(ClientSecret).

-doc """
Derive the server's Initial key/iv/hp from the DCID (RFC 9001 §5.2). The
server protects its own Initial packets with these.
""".
-spec initial_server(binary()) -> keys().
initial_server(DCID) ->
    ServerSecret = roadrunner_quic_hkdf:expand_label(initial_secret(DCID), ~"server in", <<>>, 32),
    traffic_keys(ServerSecret).

-doc """
Derive the AES-128-GCM packet-protection keys from a traffic secret
(RFC 9001 §5.1): the AEAD key (`quic key`), the nonce IV (`quic iv`), and
the header-protection key (`quic hp`).
""".
-spec traffic_keys(binary()) -> keys().
traffic_keys(Secret) ->
    #{
        key => roadrunner_quic_hkdf:expand_label(Secret, ~"quic key", <<>>, 16),
        iv => roadrunner_quic_hkdf:expand_label(Secret, ~"quic iv", <<>>, 12),
        hp => roadrunner_quic_hkdf:expand_label(Secret, ~"quic hp", <<>>, 16)
    }.

-doc """
Derive the next key generation for a key update (RFC 9001 §6.1):
`HKDF-Expand-Label(current_secret, "quic ku", "", 32)` gives the updated
secret, and the new keys follow from it. Returns `{UpdatedSecret, Keys}`;
the caller keeps `UpdatedSecret` as the current secret for the following
update.
""".
-spec update(binary()) -> {binary(), keys()}.
update(Secret) ->
    UpdatedSecret = roadrunner_quic_hkdf:expand_label(Secret, ~"quic ku", <<>>, 32),
    {UpdatedSecret, traffic_keys(UpdatedSecret)}.

-doc """
Prepare derived keys for the connection process that will use them, in
the one direction it uses them for: `seal` for the server's own packets,
`open` for the peer's. The header-protection key becomes an initialized
AES-128-ECB state, so each packet's mask is one `crypto_update/2`
instead of a fresh key setup (RFC 9001 §5.4.3: ECB has no state between
blocks). From OTP 28 the packet-protection key likewise becomes an
AES-128-GCM sealing or opening state. A state must not be used from two
processes at once, so call this where the keys are installed and use
them only in that process.
""".
-spec for_connection(keys(), seal | open) -> keys().
for_connection(#{key := Key, hp := HP} = Keys, Direction) when is_binary(Key), is_binary(HP) ->
    Keys#{
        key := aead_state(Key, Direction),
        hp := crypto:crypto_init(aes_128_ecb, HP, true)
    }.

-if(?OTP_RELEASE >= 28).
-spec aead_state(binary(), seal | open) -> roadrunner_quic_aead:aead_key().
aead_state(Key, Direction) ->
    crypto:crypto_one_time_aead_init(aes_128_gcm, Key, 16, Direction =:= seal).
-else.
%% Before OTP 28 there is no AEAD state API: the raw key stays, for
%% either direction.
-spec aead_state(binary(), seal | open) -> roadrunner_quic_aead:aead_key().
aead_state(Key, seal) ->
    Key;
aead_state(Key, open) ->
    Key.
-endif.
