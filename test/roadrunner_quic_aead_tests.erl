-module(roadrunner_quic_aead_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_quic_aead).
%% The `quic` dep, kept as a test-profile differential oracle.
-define(DEP, quic_aead).

%% =============================================================================
%% RFC 9001 Appendix A.3 (Server Initial) — the authority.
%%
%% A full packet-protection round trip against the published vector: seal
%% the payload, apply header protection to reproduce the on-wire packet,
%% then reverse both. The server Initial uses a 2-byte packet number
%% (first byte 0xc1) at offset 18 and is not padded to 1200 bytes.
%% =============================================================================

rfc9001_a3_server_initial_test() ->
    Key = hex(~"cf3a5331653c364c88f0f379b6067e37"),
    IV = hex(~"0ac1493ca1905853b0bba03e"),
    HP = hex(~"c206b8d9b9f0f37644430b490eeaa314"),
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
%% AEAD seal/open: byte-for-byte vs the dep, round-trip across inputs.
%% =============================================================================

seal_open_matches_dep_test() ->
    Key = hex(~"00112233445566778899aabbccddeeff"),
    IV = hex(~"0102030405060708090a0b0c"),
    Cases = [
        {0, <<>>, ~"x"},
        {1, ~"associated-data", binary:copy(<<7>>, 100)},
        {16#3fffffff, ~"hdr", ~"payload"},
        {16#ffffffffffff, <<>>, binary:copy(<<0>>, 64)}
    ],
    [
        begin
            CT = ?M:seal(Key, IV, PN, AAD, PT),
            ?assertEqual(?DEP:encrypt(Key, IV, PN, AAD, PT), CT),
            ?assertEqual({ok, PT}, ?M:open(Key, IV, PN, AAD, CT))
        end
     || {PN, AAD, PT} <- Cases
    ].

%% =============================================================================
%% Header protection: byte-for-byte vs the dep, removed exactly. Built on a
%% real short-header packet (the A.3 vector covers the long-header form).
%% =============================================================================

header_protection_matches_dep_test() ->
    HP = hex(~"33333333333333333333333333333333"),
    DCID = binary:copy(<<16#ab>>, 8),
    Ciphertext = binary:copy(<<16#5c>>, 40),
    PN = 42,
    [HeaderIo, _] = roadrunner_quic_packet:encode_short(DCID, PN, <<>>, false),
    Header = iolist_to_binary(HeaderIo),
    PNOffset = 1 + byte_size(DCID),
    Protected = ?M:protect_header(HP, Header, Ciphertext, PNOffset),
    ?assertEqual(?DEP:protect_header(aes_128_gcm, HP, Header, Ciphertext, PNOffset), Protected),
    Packet = <<Protected/binary, Ciphertext/binary>>,
    ?assertEqual({ok, Header, 1, PN, Ciphertext}, ?M:unprotect_header(HP, Packet, PNOffset)).

%% =============================================================================
%% Failure paths: open and unprotect never crash on bad input.
%% =============================================================================

open_rejects_tampered_payload_test() ->
    Key = hex(~"000102030405060708090a0b0c0d0e0f"),
    IV = hex(~"0a0b0c0d0e0f000102030405"),
    CT = ?M:seal(Key, IV, 7, ~"aad", ~"secret payload over the tag"),
    Size = byte_size(CT),
    <<Body:(Size - 1)/binary, Last>> = CT,
    Tampered = <<Body/binary, (Last bxor 1)>>,
    ?assertEqual(error, ?M:open(Key, IV, 7, ~"aad", Tampered)).

open_rejects_short_input_test() ->
    Key = hex(~"000102030405060708090a0b0c0d0e0f"),
    IV = hex(~"0a0b0c0d0e0f000102030405"),
    %% Fewer than the 16 tag bytes: cannot hold a tag.
    ?assertEqual(error, ?M:open(Key, IV, 0, <<>>, <<1, 2, 3>>)).

unprotect_header_rejects_short_packet_test() ->
    HP = hex(~"33333333333333333333333333333333"),
    %% Header present but the payload is too short to sample.
    ?assertEqual({error, sample_too_short}, ?M:unprotect_header(HP, <<16#40, 1, 2, 3>>, 1)),
    %% Packet shorter than the packet-number offset itself.
    ?assertEqual({error, sample_too_short}, ?M:unprotect_header(HP, <<1, 2>>, 5)).

%% Uppercase before decoding so the literals are portable across OTP
%% versions regardless of `binary:decode_hex/1`'s lowercase handling.
hex(Hex) -> binary:decode_hex(string:uppercase(Hex)).
