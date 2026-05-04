-module(roadrunner_http2_hpack_huffman_tests).
-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% RFC 7541 Appendix C vectors. The Appendix C.4 examples encode
%% header field values with Huffman; these expected encodings are
%% listed in C.4.1, C.4.2, and C.4.3.
%% =============================================================================

rfc_c41_www_example_com_test() ->
    %% C.4.1: ":authority: www.example.com" — value "www.example.com"
    %% Huffman-encoded to f1e3 c2e5 f23a 6ba0 ab90 f4ff (12 bytes).
    Input = ~"www.example.com",
    Expected =
        <<16#F1, 16#E3, 16#C2, 16#E5, 16#F2, 16#3A, 16#6B, 16#A0, 16#AB, 16#90, 16#F4, 16#FF>>,
    ?assertEqual(Expected, roadrunner_http2_hpack_huffman:encode(Input)),
    ?assertEqual({ok, Input}, roadrunner_http2_hpack_huffman:decode(Expected)).

rfc_c42_no_cache_test() ->
    %% C.4.2: "cache-control: no-cache" — value "no-cache" Huffman-
    %% encoded to a8eb 1064 9cbf (6 bytes).
    Input = ~"no-cache",
    Expected = <<16#A8, 16#EB, 16#10, 16#64, 16#9C, 16#BF>>,
    ?assertEqual(Expected, roadrunner_http2_hpack_huffman:encode(Input)),
    ?assertEqual({ok, Input}, roadrunner_http2_hpack_huffman:decode(Expected)).

rfc_c43_custom_key_value_test() ->
    %% C.4.3 first request: "custom-key: custom-value".
    %% Name "custom-key" → 25a8 49e9 5ba9 7d7f (8 bytes).
    %% Value "custom-value" → 25a8 49e9 5bb8 e8b4 bf (9 bytes).
    NameInput = ~"custom-key",
    NameExpected = <<16#25, 16#A8, 16#49, 16#E9, 16#5B, 16#A9, 16#7D, 16#7F>>,
    ?assertEqual(NameExpected, roadrunner_http2_hpack_huffman:encode(NameInput)),
    ?assertEqual({ok, NameInput}, roadrunner_http2_hpack_huffman:decode(NameExpected)),
    ValueInput = ~"custom-value",
    ValueExpected = <<16#25, 16#A8, 16#49, 16#E9, 16#5B, 16#B8, 16#E8, 16#B4, 16#BF>>,
    ?assertEqual(ValueExpected, roadrunner_http2_hpack_huffman:encode(ValueInput)),
    ?assertEqual({ok, ValueInput}, roadrunner_http2_hpack_huffman:decode(ValueExpected)).

%% =============================================================================
%% Round-trip property — the codec is its own inverse for ALL inputs.
%% Without a property tester we exhaustively cover single-byte inputs
%% plus a few multibyte stress cases.
%% =============================================================================

round_trip_every_single_byte_test() ->
    [
        ?assertEqual(
            {ok, <<B>>},
            roadrunner_http2_hpack_huffman:decode(
                roadrunner_http2_hpack_huffman:encode(<<B>>)
            )
        )
     || B <- lists:seq(0, 255)
    ].

round_trip_byte_pairs_test() ->
    [
        ?assertEqual(
            {ok, <<A, B>>},
            roadrunner_http2_hpack_huffman:decode(
                roadrunner_http2_hpack_huffman:encode(<<A, B>>)
            )
        )
     || A <- lists:seq(0, 255, 17),
        B <- lists:seq(0, 255, 17)
    ].

round_trip_long_string_test() ->
    %% Stress test: 1024-byte random binary round-trips cleanly.
    Bin = crypto:strong_rand_bytes(1024),
    ?assertEqual(
        {ok, Bin},
        roadrunner_http2_hpack_huffman:decode(
            roadrunner_http2_hpack_huffman:encode(Bin)
        )
    ).

round_trip_empty_test() ->
    ?assertEqual(<<>>, roadrunner_http2_hpack_huffman:encode(<<>>)),
    ?assertEqual({ok, <<>>}, roadrunner_http2_hpack_huffman:decode(<<>>)).

%% =============================================================================
%% Decode failure modes (RFC 7541 §5.2 strictness).
%% =============================================================================

decode_eos_in_string_is_rejected_test() ->
    %% EOS code is 30 bits all `1`. Build a payload that contains it
    %% mid-stream and verify the decoder bails.
    %% Encode 'a' (5 bits, code 00011 -> 0x03) followed by EOS (30
    %% bits all 1) followed by padding.
    %%
    %% 'a' code: width 5, value 3. Bits: 00011.
    %% EOS code: width 30, all 1s.
    %% Combined: 00011 + 30 bits of 1s = 35 bits.
    %% Padded to next byte boundary (40 bits / 5 bytes) with 1-bit
    %% pads.
    Bits = (3 bsl 30) bor 16#3FFFFFFF,
    %% Total 35 bits — pad with 5 ones.
    Padded = (Bits bsl 5) bor 16#1F,
    %% 40 bits = 5 bytes.
    Bin = <<Padded:40/big-unsigned-integer>>,
    ?assertEqual({error, eos_in_string}, roadrunner_http2_hpack_huffman:decode(Bin)).

decode_invalid_padding_is_rejected_test() ->
    %% A complete 'a' code (5 bits) followed by 3 zero pad bits is
    %% invalid (padding MUST be `1`-bits per RFC 7541 §5.2).
    Bin = <<3:5, 0:3>>,
    ?assertEqual({error, invalid_padding}, roadrunner_http2_hpack_huffman:decode(Bin)).

decode_short_padding_is_accepted_test() ->
    %% 'a' encoded alone: 5 bits + 3 1-bit pads = 1 byte. Valid.
    Bin = <<3:5, 16#7:3>>,
    ?assertEqual({ok, ~"a"}, roadrunner_http2_hpack_huffman:decode(Bin)).

decode_eos_triggered_in_second_nibble_test() ->
    %% Construct an input where the EOS leaf is hit during the Lo
    %% nibble of a byte (not the Hi nibble) — exercises the
    %% second-nibble error-bubble in `decode_loop/4`. Data is
    %% `'a' + 'a' + EOS = 40 bits = 5 bytes`. EOS bit 30 lands at
    %% bit 4 of byte 5's Lo nibble.
    Bin = <<16#18, 16#FF, 16#FF, 16#FF, 16#FF>>,
    ?assertEqual({error, eos_in_string}, roadrunner_http2_hpack_huffman:decode(Bin)).
