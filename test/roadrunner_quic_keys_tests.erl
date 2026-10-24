-module(roadrunner_quic_keys_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_quic_keys).

%% =============================================================================
%% RFC 9001 Appendix A.1 — the authority.
%%
%% The worked example derives Initial keys for both directions from the
%% client's DCID 0x8394c8f03e515708.
%% =============================================================================

rfc9001_a1_initial_secret_test() ->
    ?assertEqual(
        hex(~"7db5df06e7a69e432496adedb00851923595221596ae2ae9fb8115c1e9ed0a44"),
        ?M:initial_secret(a1_dcid())
    ).

%% Initial keys are always AES-128-GCM with AES header protection
%% (RFC 9001 §5.2, §5.4.3).
rfc9001_a1_server_keys_test() ->
    ?assertEqual(
        #{
            key => {aes_128_gcm, hex(~"cf3a5331653c364c88f0f379b6067e37")},
            iv => hex(~"0ac1493ca1905853b0bba03e"),
            hp => {aes_128_ecb, hex(~"c206b8d9b9f0f37644430b490eeaa314")}
        },
        ?M:initial_server(a1_dcid())
    ).

rfc9001_a1_client_keys_test() ->
    ?assertEqual(
        #{
            key => {aes_128_gcm, hex(~"1f369613dd76d5467730efcbe3b1a22d")},
            iv => hex(~"fa044b2f42a3fd3b46fb255c"),
            hp => {aes_128_ecb, hex(~"9f50449e04a0e810283a1e9933adedd2")}
        },
        ?M:initial_client(a1_dcid())
    ).

%% The server Initial keys derive straight from the server Initial secret
%% (RFC 9001 A.1), so `traffic_keys/2` for AES-128-GCM over that secret
%% reproduces them.
traffic_keys_test() ->
    ServerSecret = hex(~"3c199828fd139efd216c155ad844cc81fb82fa8d7446fa7d78be803acdda951b"),
    ?assertEqual(
        #{
            key => {aes_128_gcm, hex(~"cf3a5331653c364c88f0f379b6067e37")},
            iv => hex(~"0ac1493ca1905853b0bba03e"),
            hp => {aes_128_ecb, hex(~"c206b8d9b9f0f37644430b490eeaa314")}
        },
        ?M:traffic_keys(aes_128_gcm, ServerSecret)
    ).

%% RFC 9001 Appendix A.5: ChaCha20-Poly1305 keys from an application
%% secret, a 32-byte AEAD key and a 32-byte ChaCha20 header-protection key.
rfc9001_a5_chacha20_traffic_keys_test() ->
    ?assertEqual(
        #{
            key =>
                {chacha20_poly1305,
                    hex(~"c6d98ff3441c3fe1b2182094f69caa2ed4b716b65488960a7a984979fb23e1c8")},
            iv => hex(~"e0459b3474bdd0e44a41c144"),
            hp =>
                {chacha20, hex(~"25a282b9e82f06f21f488917a4fc8f1b73573685608597d0efcb076b0ab7a7a4")}
        },
        ?M:traffic_keys(chacha20_poly1305, a5_secret())
    ).

%% AES-256-GCM keys (TLS_AES_256_GCM_SHA384) expand over SHA-384: a 32-byte
%% AEAD key, a 12-byte IV and a 32-byte AES-256 header-protection key (RFC
%% 9001 §5.1, §5.4.3). RFC 9001 has no AES-256 vector; the expected values
%% are from Python's `cryptography` HKDF and OTP ssl's
%% `tls_v1:hkdf_expand_label/5`, which agree, over the SHA-384 server
%% handshake secret of `roadrunner_quic_tls_crypto_tests`.
aes_256_gcm_traffic_keys_test() ->
    ?assertEqual(
        #{
            key =>
                {aes_256_gcm,
                    hex(~"7501e53e394e2541a2f15bc462febcdda98414c8b53e3e2457944630350e12b8")},
            iv => hex(~"9f3186ec885e99cd55aa55df"),
            hp =>
                {aes_256_ecb,
                    hex(~"8c8299eb2ef6405e4ba7f451703409f8a0d37969067808805eec3a1209950a92")}
        },
        ?M:traffic_keys(aes_256_gcm, sha384_secret())
    ).

%% =============================================================================
%% Key update (RFC 9001 §6.1): the next secret is
%% Expand-Label(current, "quic ku", "", Hash.length) over the suite's hash,
%% and the AEAD key and IV for the connection's AEAD follow from it; the
%% header-protection key is not updated.
%% =============================================================================

%% RFC 9001 Appendix A.5 publishes the "quic ku" secret for its 1-RTT
%% secret; the update secret depends only on the secret and SHA-256, which
%% both SHA-256 suites share.
rfc9001_a5_key_update_secret_test_() ->
    UpdatedSecret = hex(~"1223504755036d556342ee9361d253421a826c9ecdf3c7148684b36b714881f9"),
    [
        ?_assertMatch({UpdatedSecret, _PacketKeys}, ?M:update(Cipher, a5_secret()))
     || Cipher <- [aes_128_gcm, chacha20_poly1305]
    ].

%% The updated generation's AEAD key and IV are the "quic key" and
%% "quic iv" expansions of the updated secret, and nothing else.
key_update_derives_packet_keys_test() ->
    Secret = binary:copy(<<16#2a>>, 32),
    {UpdatedSecret, PacketKeys} = ?M:update(aes_128_gcm, Secret),
    ?assertEqual(
        hex(~"c8dd004d0adc90d90ef286b8debce48f65a3ea342932fc5f4891207e96f8e862"),
        UpdatedSecret
    ),
    ?assertEqual(
        #{
            key => {aes_128_gcm, hex(~"d77beffa17a12a7697276ab00c5faa0b")},
            iv => hex(~"535303b03a85a983f4311f64")
        },
        PacketKeys
    ),
    ?assertEqual(maps:with([key, iv], ?M:traffic_keys(aes_128_gcm, UpdatedSecret)), PacketKeys).

%% A key update keeps the AEAD (§6.1): a ChaCha20-Poly1305 connection's next
%% generation is a 32-byte ChaCha20-Poly1305 key, here RFC 9001 A.5's
%% secret updated once.
chacha20_key_update_test() ->
    {UpdatedSecret, PacketKeys} = ?M:update(chacha20_poly1305, a5_secret()),
    ?assertMatch(#{key := {chacha20_poly1305, <<_:32/binary>>}, iv := <<_:12/binary>>}, PacketKeys),
    ?assertEqual(
        maps:with([key, iv], ?M:traffic_keys(chacha20_poly1305, UpdatedSecret)), PacketKeys
    ).

%% On an AES-256-GCM connection the "quic ku" expansion runs over SHA-384 and
%% is 48 bytes (RFC 9001 §6.1 uses the suite's hash, RFC 8446 §7.2), and the
%% next generation is AES-256-GCM again. Same cross-checked sources as
%% aes_256_gcm_traffic_keys_test.
aes_256_gcm_key_update_test() ->
    {UpdatedSecret, PacketKeys} = ?M:update(aes_256_gcm, sha384_secret()),
    ?assertEqual(
        hex(
            ~"06dba44492a51d07d4376f6bd9b5b5b59fc5449e4a7eafe955ec1fe3ba5ce2eb547842c5c725aaed6c6ef6253c7bc7d7"
        ),
        UpdatedSecret
    ),
    ?assertEqual(
        #{
            key =>
                {aes_256_gcm,
                    hex(~"5fa43c1d5b567ae4ee1c58d1580a4760012354b5040d31f324c7bd6fc541cd22")},
            iv => hex(~"c840feabf29ad96eb857d3ca")
        },
        PacketKeys
    ).

%% =============================================================================
%% Helpers
%% =============================================================================

a1_dcid() -> hex(~"8394c8f03e515708").

a5_secret() -> hex(~"9ac312a7f877468ebe69422748ad00a15443f18203a07d6060f688f30f21632b").

sha384_secret() ->
    hex(
        ~"e145cd264912ba03966f7d08cb7083046e08dba6cb2f6eafe63e89b643456b08aa3ecb44178e98a7f06deb1dd881d447"
    ).

%% Uppercase before decoding so the literals are portable across OTP
%% versions regardless of `binary:decode_hex/1`'s lowercase handling.
hex(Hex) -> binary:decode_hex(string:uppercase(Hex)).

for_connection_protects_like_the_raw_key_test() ->
    %% The connection's cipher state must mask exactly like the raw
    %% 16-byte header-protection key it was built from, packet after
    %% packet (ECB keeps no state between blocks).
    #{hp := Raw} = Keys = roadrunner_quic_keys:initial_server(<<16#8394c8f03e515708:64>>),
    #{hp := State} = roadrunner_quic_keys:for_connection(Keys, seal),
    Header = <<16#c3, 1:32, 8, 0:64, 0, 16#4499:16, 2:32>>,
    [
        ?assertEqual(
            roadrunner_quic_aead:protect_header(Raw, Header, Cipher, byte_size(Header) - 4),
            roadrunner_quic_aead:protect_header(State, Header, Cipher, byte_size(Header) - 4)
        )
     || Cipher <- [crypto:strong_rand_bytes(32) || _ <- lists:seq(1, 20)]
    ].

for_connection_protects_like_the_raw_aes_256_key_test() ->
    %% The same for an AES-256 header-protection key: the connection's
    %% AES-256-ECB state masks like the raw 32-byte key.
    #{hp := Raw} = Keys = roadrunner_quic_keys:traffic_keys(aes_256_gcm, sha384_secret()),
    #{hp := State} = roadrunner_quic_keys:for_connection(Keys, open),
    ?assertNotMatch({_, _}, State),
    Header = <<16#43, 1:32>>,
    [
        ?assertEqual(
            roadrunner_quic_aead:protect_header(Raw, Header, Cipher, 1),
            roadrunner_quic_aead:protect_header(State, Header, Cipher, 1)
        )
     || Cipher <- [crypto:strong_rand_bytes(32) || _ <- lists:seq(1, 20)]
    ].

for_connection_keeps_the_chacha20_hp_key_test() ->
    %% A ChaCha20 mask runs under a new IV per sample (RFC 9001 §5.4.4), so
    %% the header-protection key stays the raw tagged key.
    #{hp := Raw} = Keys = roadrunner_quic_keys:traffic_keys(chacha20_poly1305, a5_secret()),
    ?assertMatch(#{hp := Raw}, roadrunner_quic_keys:for_connection(Keys, seal)).

for_connection_seals_and_opens_like_the_raw_key_test_() ->
    %% The connection's sealing state must produce the raw key's bytes,
    %% and its opening state must open them, packet after packet, for
    %% every AEAD.
    [
        ?_test(assert_seals_and_opens_like_the_raw_key(Keys))
     || Keys <- [
            roadrunner_quic_keys:initial_server(<<16#8394c8f03e515708:64>>),
            roadrunner_quic_keys:traffic_keys(aes_256_gcm, sha384_secret()),
            roadrunner_quic_keys:traffic_keys(chacha20_poly1305, a5_secret())
        ]
    ].

assert_seals_and_opens_like_the_raw_key(Keys) ->
    #{key := Raw, iv := IV} = Keys,
    #{key := SealKey} = roadrunner_quic_keys:for_connection(Keys, seal),
    #{key := OpenKey} = roadrunner_quic_keys:for_connection(Keys, open),
    [
        begin
            Plaintext = crypto:strong_rand_bytes(Size),
            AAD = crypto:strong_rand_bytes(20),
            Sealed = roadrunner_quic_aead:seal(Raw, IV, PN, AAD, Plaintext),
            ?assertEqual(Sealed, roadrunner_quic_aead:seal(SealKey, IV, PN, AAD, Plaintext)),
            ?assertEqual({ok, Plaintext}, roadrunner_quic_aead:open(OpenKey, IV, PN, AAD, Sealed)),
            <<Flip, Rest/binary>> = Sealed,
            ?assertEqual(
                error,
                roadrunner_quic_aead:open(OpenKey, IV, PN, AAD, <<(Flip bxor 1), Rest/binary>>)
            )
        end
     || {PN, Size} <- [{0, 1}, {1, 64}, {2, 1200}, {16#FFFF, 300}]
    ].

for_connection_prepares_update_packet_keys_test_() ->
    %% A key update's packet keys carry no header-protection key; only the
    %% AEAD key is prepared, and it seals and opens like the raw key, for
    %% every AEAD.
    [
        ?_test(begin
            {_UpdatedSecret, #{key := Raw, iv := IV} = PacketKeys} =
                ?M:update(Cipher, binary:copy(<<7>>, 32)),
            #{key := SealKey, iv := IV} = Sealing = ?M:for_connection(PacketKeys, seal),
            #{key := OpenKey} = ?M:for_connection(PacketKeys, open),
            ?assertEqual([iv, key], lists:sort(maps:keys(Sealing))),
            Sealed = roadrunner_quic_aead:seal(Raw, IV, 5, ~"aad", ~"payload"),
            ?assertEqual(Sealed, roadrunner_quic_aead:seal(SealKey, IV, 5, ~"aad", ~"payload")),
            ?assertEqual(
                {ok, ~"payload"}, roadrunner_quic_aead:open(OpenKey, IV, 5, ~"aad", Sealed)
            )
        end)
     || Cipher <- [aes_128_gcm, aes_256_gcm, chacha20_poly1305]
    ].
