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
