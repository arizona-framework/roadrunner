-module(cactus_uri_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% percent_decode/1
%% =============================================================================

decode_empty_test() ->
    ?assertEqual({ok, ~""}, cactus_uri:percent_decode(~"")).

decode_passthrough_test() ->
    ?assertEqual({ok, ~"hello"}, cactus_uri:percent_decode(~"hello")).

decode_space_test() ->
    ?assertEqual({ok, ~"hello world"}, cactus_uri:percent_decode(~"hello%20world")).

decode_lowercase_hex_test() ->
    %% 0x2a = '*'
    ?assertEqual({ok, ~"*"}, cactus_uri:percent_decode(~"%2a")).

decode_uppercase_hex_test() ->
    ?assertEqual({ok, ~"*"}, cactus_uri:percent_decode(~"%2A")).

decode_mixed_case_hex_test() ->
    %% 0xab = byte 171
    ?assertEqual({ok, <<16#ab>>}, cactus_uri:percent_decode(~"%aB")).

decode_low_byte_test() ->
    ?assertEqual({ok, <<0>>}, cactus_uri:percent_decode(~"%00")).

decode_high_byte_test() ->
    ?assertEqual({ok, <<255>>}, cactus_uri:percent_decode(~"%FF")).

decode_multiple_in_one_string_test() ->
    ?assertEqual(
        {ok, ~"a b c"},
        cactus_uri:percent_decode(~"a%20b%20c")
    ).

decode_lone_percent_rejected_test() ->
    ?assertEqual({error, badarg}, cactus_uri:percent_decode(~"%")).

decode_percent_one_digit_rejected_test() ->
    ?assertEqual({error, badarg}, cactus_uri:percent_decode(~"%2")).

decode_bad_first_hex_rejected_test() ->
    ?assertEqual({error, badarg}, cactus_uri:percent_decode(~"%ZZ")).

decode_bad_second_hex_rejected_test() ->
    ?assertEqual({error, badarg}, cactus_uri:percent_decode(~"%2Z")).

decode_percent_followed_by_text_rejected_test() ->
    %% % followed by 1 char then more — not 2 hex digits.
    ?assertEqual({error, badarg}, cactus_uri:percent_decode(~"abc%xyz")).

%% =============================================================================
%% percent_encode/1
%% =============================================================================

encode_empty_test() ->
    ?assertEqual(~"", cactus_uri:percent_encode(~"")).

encode_unreserved_alpha_lower_test() ->
    ?assertEqual(~"hello", cactus_uri:percent_encode(~"hello")).

encode_unreserved_alpha_upper_test() ->
    ?assertEqual(~"HELLO", cactus_uri:percent_encode(~"HELLO")).

encode_unreserved_digits_test() ->
    ?assertEqual(~"12345", cactus_uri:percent_encode(~"12345")).

encode_unreserved_marks_test() ->
    %% RFC 3986 §2.3 unreserved marks: '-', '.', '_', '~'.
    ?assertEqual(~"-._~", cactus_uri:percent_encode(~"-._~")).

encode_space_test() ->
    ?assertEqual(~"%20", cactus_uri:percent_encode(~" ")).

encode_reserved_chars_test() ->
    ?assertEqual(
        ~"a%2Fb%3Fc%3Dd",
        cactus_uri:percent_encode(~"a/b?c=d")
    ).

encode_low_byte_test() ->
    ?assertEqual(~"%00", cactus_uri:percent_encode(<<0>>)).

encode_high_byte_test() ->
    ?assertEqual(~"%FF", cactus_uri:percent_encode(<<255>>)).

encode_uses_uppercase_hex_test() ->
    %% RFC 3986 §2.1 recommends uppercase hex digits for normalization.
    ?assertEqual(~"%AB", cactus_uri:percent_encode(<<16#ab>>)).

encode_decode_roundtrip_test_() ->
    Cases = [
        ~"",
        ~"hello",
        ~"hello world",
        ~"a/b?c=d&e=f",
        ~"-._~",
        ~"0123456789",
        ~"ABC abc",
        <<0, 1, 2, 127, 255>>
    ],
    [
        ?_assertEqual(
            {ok, Bin},
            cactus_uri:percent_decode(cactus_uri:percent_encode(Bin))
        )
     || Bin <- Cases
    ].
