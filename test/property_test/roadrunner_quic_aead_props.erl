-module(roadrunner_quic_aead_props).
-moduledoc """
Property-based tests for `roadrunner_quic_aead`.

Round-trip invariants over random inputs, for both packet-protection
AEADs (AES-128-GCM and ChaCha20-Poly1305) with their header protection:
opening a sealed payload recovers the plaintext, and header protection
applied to a real short-header packet is removed exactly, recovering the
header, the packet-number length, the wire packet number, and the
trailing ciphertext.
""".

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct_property_test.hrl").

%% 2^62 - 1, the largest QUIC packet number.
-define(MAX_PN, 4611686018427387903).

prop_round_trips() ->
    ?FORALL(
        {{Key, HP}, IV, PN, DCID, Plaintext},
        {keys(), binary(12), pn(), dcid(), payload()},
        begin
            %% A short-header packet's header depends only on DCID + PN, so
            %% it can be built before sealing and used as the AEAD AAD.
            [HeaderIo, _] = roadrunner_quic_packet:encode_short(DCID, PN, <<>>, false),
            Header = iolist_to_binary(HeaderIo),
            PNOffset = 1 + byte_size(DCID),
            PNLen = roadrunner_quic_packet:pn_length(PN),
            %% The wire carries the packet number truncated to its width, so
            %% unprotect_header returns that truncated value (full-number
            %% reconstruction from the largest received is the conn's job).
            WirePN = binary:decode_unsigned(roadrunner_quic_packet:encode_pn(PN, PNLen)),
            Ciphertext = roadrunner_quic_aead:seal(Key, IV, PN, Header, Plaintext),
            Protected = roadrunner_quic_aead:protect_header(HP, Header, Ciphertext, PNOffset),
            Packet = <<Protected/binary, Ciphertext/binary>>,
            roadrunner_quic_aead:open(Key, IV, PN, Header, Ciphertext) =:= {ok, Plaintext} andalso
                roadrunner_quic_aead:unprotect_header(HP, Packet, PNOffset) =:=
                    {ok, Header, PNLen, WirePN, Ciphertext}
        end
    ).

%% A packet-protection key and its header-protection key, for either AEAD
%% (RFC 9001 §5.3, §5.4.3, §5.4.4).
keys() ->
    oneof([
        ?LET({K, H}, {binary(16), binary(16)}, {{aes_128_gcm, K}, {aes_128_ecb, H}}),
        ?LET({K, H}, {binary(32), binary(32)}, {{chacha20_poly1305, K}, {chacha20, H}})
    ]).

%% A packet number, one band per wire width (1-4 bytes) plus a band above
%% 2^32 for the AEAD nonce's high bits. Banding by lower bound forces every
%% width to be produced; a single `integer(0, ?MAX_PN)` scales with the
%% PropEr size and would only ever yield tiny, 1-byte numbers.
pn() ->
    oneof([
        integer(0, 16#FF),
        integer(16#100, 16#FFFF),
        integer(16#10000, 16#FFFFFF),
        integer(16#1000000, 16#FFFFFFFF),
        integer(16#100000000, ?MAX_PN)
    ]).

%% A Destination Connection ID, 0..20 bytes (RFC 9000 §17.2).
dcid() -> ?LET(N, integer(0, 20), binary(N)).

%% A payload large enough that the ciphertext always holds the 16-byte
%% header-protection sample taken 4 bytes past the packet number.
payload() -> ?LET(N, integer(16, 256), binary(N)).
