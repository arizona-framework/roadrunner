-module(roadrunner_quic_aead_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_quic_aead).

%% =============================================================================
%% RFC 9001 Appendix A.3 (Server Initial) — the authority.
%%
%% A full packet-protection round trip against the published vector: seal
%% the payload, apply header protection to reproduce the on-wire packet,
%% then reverse both. The server Initial uses a 2-byte packet number
%% (first byte 0xc1) at offset 18 and is not padded to 1200 bytes.
%% =============================================================================

rfc9001_a3_server_initial_test() ->
    Key = {aes_128_gcm, hex(~"cf3a5331653c364c88f0f379b6067e37")},
    IV = hex(~"0ac1493ca1905853b0bba03e"),
    HP = {aes_128_ecb, hex(~"c206b8d9b9f0f37644430b490eeaa314")},
    PN = 1,
    PNOffset = 18,
    Header = hex(~"c1000000010008f067a5502a4262b50040750001"),
    Plaintext = hex(
        ~"02000000000600405a020000560303eefce7f7b37ba1d1632e96677825ddf73988cfc79825df566dc5430b9a045a1200130100002e00330024001d00209d3c940d89690b84d08a60993c144eca684d1081287c834d5311bcf32bb9da1a002b00020304"
    ),
    Ciphertext = hex(
        ~"5a482cd0991cd25b0aac406a5816b6394100f37a1c69797554780bb38cc5a99f5ede4cf73c3ec2493a1839b3dbcba3f6ea46c5b7684df3548e7ddeb9c3bf9c73cc3f3bded74b562bfb19fb84022f8ef4cdd93795d77d06edbb7aaf2f58891850abbdca3d20398c276456cbc42158407dd074ee"
    ),
    Packet = hex(
        ~"cf000000010008f067a5502a4262b5004075c0d95a482cd0991cd25b0aac406a5816b6394100f37a1c69797554780bb38cc5a99f5ede4cf73c3ec2493a1839b3dbcba3f6ea46c5b7684df3548e7ddeb9c3bf9c73cc3f3bded74b562bfb19fb84022f8ef4cdd93795d77d06edbb7aaf2f58891850abbdca3d20398c276456cbc42158407dd074ee"
    ),
    ?assertEqual(Ciphertext, ?M:seal(Key, IV, PN, Header, Plaintext)),
    ?assertEqual({ok, Plaintext}, ?M:open(Key, IV, PN, Header, Ciphertext)),
    Protected = ?M:protect_header(HP, Header, Ciphertext, PNOffset),
    ?assertEqual(Packet, <<Protected/binary, Ciphertext/binary>>),
    ?assertEqual({ok, Header, 2, PN, Ciphertext}, ?M:unprotect_header(HP, Packet, PNOffset)).

%% =============================================================================
%% RFC 9001 Appendix A.5 (ChaCha20-Poly1305 Short Header Packet), the
%% authority for the ChaCha20-Poly1305 AEAD and the ChaCha20 header
%% protection (§5.4.4).
%%
%% A minimal 1-RTT packet with an empty Destination Connection ID, a single
%% PING frame, and the 3-byte packet number 654360564 (49140 on the wire),
%% so the packet number starts at offset 1 and the sample skips one
%% ciphertext byte.
%% =============================================================================

rfc9001_a5_chacha20_short_header_test() ->
    Key =
        {chacha20_poly1305,
            hex(~"c6d98ff3441c3fe1b2182094f69caa2ed4b716b65488960a7a984979fb23e1c8")},
    IV = hex(~"e0459b3474bdd0e44a41c144"),
    HP = {chacha20, hex(~"25a282b9e82f06f21f488917a4fc8f1b73573685608597d0efcb076b0ab7a7a4")},
    PN = 654360564,
    PNOffset = 1,
    Header = hex(~"4200bff4"),
    Plaintext = <<16#01>>,
    Ciphertext = hex(~"655e5cd55c41f69080575d7999c25a5bfb"),
    Packet = hex(~"4cfe4189655e5cd55c41f69080575d7999c25a5bfb"),
    ?assertEqual(Ciphertext, ?M:seal(Key, IV, PN, Header, Plaintext)),
    ?assertEqual({ok, Plaintext}, ?M:open(Key, IV, PN, Header, Ciphertext)),
    Protected = ?M:protect_header(HP, Header, Ciphertext, PNOffset),
    ?assertEqual(Packet, <<Protected/binary, Ciphertext/binary>>),
    %% The receive side recovers the 3-byte truncated packet number (49140).
    ?assertEqual(
        {ok, Header, 3, 49140, Ciphertext}, ?M:unprotect_header(HP, Packet, PNOffset)
    ).

%% =============================================================================
%% AES-256-GCM with AES-256 header protection (RFC 9001 §5.3, §5.4.3), the
%% AEAD of TLS_AES_256_GCM_SHA384, over the keys of
%% `roadrunner_quic_keys_tests:aes_256_gcm_traffic_keys_test`. RFC 9001 has
%% no AES-256 vector; the packet is A.5's (a PING, packet number 654360564
%% in 3 bytes, header 4200bff4) sealed and masked with Python's
%% `cryptography` AES-GCM and AES-ECB.
%% =============================================================================

aes_256_gcm_short_header_test() ->
    Key =
        {aes_256_gcm, hex(~"7501e53e394e2541a2f15bc462febcdda98414c8b53e3e2457944630350e12b8")},
    IV = hex(~"9f3186ec885e99cd55aa55df"),
    HP =
        {aes_256_ecb, hex(~"8c8299eb2ef6405e4ba7f451703409f8a0d37969067808805eec3a1209950a92")},
    PN = 654360564,
    PNOffset = 1,
    Header = hex(~"4200bff4"),
    Plaintext = <<16#01>>,
    Ciphertext = hex(~"32925f5daa5bbf574b93c50baa07f4db6b"),
    Packet = hex(~"599dc51832925f5daa5bbf574b93c50baa07f4db6b"),
    ?assertEqual(Ciphertext, ?M:seal(Key, IV, PN, Header, Plaintext)),
    ?assertEqual({ok, Plaintext}, ?M:open(Key, IV, PN, Header, Ciphertext)),
    Protected = ?M:protect_header(HP, Header, Ciphertext, PNOffset),
    ?assertEqual(Packet, <<Protected/binary, Ciphertext/binary>>),
    ?assertEqual(
        {ok, Header, 3, 49140, Ciphertext}, ?M:unprotect_header(HP, Packet, PNOffset)
    ).

%% =============================================================================
%% Failure paths: open and unprotect never crash on bad input.
%% =============================================================================

open_rejects_tampered_payload_test_() ->
    IV = hex(~"0a0b0c0d0e0f000102030405"),
    [
        ?_test(begin
            CT = ?M:seal(Key, IV, 7, ~"aad", ~"secret payload over the tag"),
            Size = byte_size(CT),
            <<Body:(Size - 1)/binary, Last>> = CT,
            Tampered = <<Body/binary, (Last bxor 1)>>,
            ?assertEqual(error, ?M:open(Key, IV, 7, ~"aad", Tampered))
        end)
     || Key <- [
            {aes_128_gcm, hex(~"000102030405060708090a0b0c0d0e0f")},
            {aes_256_gcm, binary:copy(<<16#2b>>, 32)},
            {chacha20_poly1305, binary:copy(<<16#2a>>, 32)}
        ]
    ].

open_rejects_short_input_test() ->
    Key = {aes_128_gcm, hex(~"000102030405060708090a0b0c0d0e0f")},
    IV = hex(~"0a0b0c0d0e0f000102030405"),
    %% Fewer than the 16 tag bytes: cannot hold a tag.
    ?assertEqual(error, ?M:open(Key, IV, 0, <<>>, <<1, 2, 3>>)).

unprotect_header_rejects_short_packet_test() ->
    HP = {aes_128_ecb, hex(~"33333333333333333333333333333333")},
    %% Header present but the payload is too short to sample.
    ?assertEqual({error, sample_too_short}, ?M:unprotect_header(HP, <<16#40, 1, 2, 3>>, 1)),
    %% Packet shorter than the packet-number offset itself.
    ?assertEqual({error, sample_too_short}, ?M:unprotect_header(HP, <<1, 2>>, 5)).

%% Uppercase before decoding so the literals are portable across OTP
%% versions regardless of `binary:decode_hex/1`'s lowercase handling.
hex(Hex) -> binary:decode_hex(string:uppercase(Hex)).
