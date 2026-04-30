-module(cactus_qs_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% parse/1
%% =============================================================================

parse_empty_test() ->
    ?assertEqual([], cactus_qs:parse(~"")).

parse_single_pair_test() ->
    ?assertEqual([{~"a", ~"1"}], cactus_qs:parse(~"a=1")).

parse_multiple_pairs_test() ->
    ?assertEqual(
        [{~"a", ~"1"}, {~"b", ~"2"}],
        cactus_qs:parse(~"a=1&b=2")
    ).

parse_flag_test() ->
    %% Bare key with no `=` is a flag — value is `true`.
    ?assertEqual(
        [{~"a", ~"1"}, {~"flag", true}],
        cactus_qs:parse(~"a=1&flag")
    ).

parse_empty_value_test() ->
    ?assertEqual([{~"a", ~""}], cactus_qs:parse(~"a=")).

parse_percent_encoded_value_test() ->
    ?assertEqual(
        [{~"q", ~"hello world"}],
        cactus_qs:parse(~"q=hello%20world")
    ).

parse_percent_encoded_key_test() ->
    ?assertEqual(
        [{~"q_name", ~"val"}],
        cactus_qs:parse(~"q%5Fname=val")
    ).

parse_plus_as_space_test() ->
    ?assertEqual(
        [{~"q", ~"hello world"}],
        cactus_qs:parse(~"q=hello+world")
    ).

parse_plus_and_percent_space_test() ->
    %% Both `+` and `%20` decode to space — `+` first, then percent.
    ?assertEqual(
        [{~"q", ~"hello  world"}],
        cactus_qs:parse(~"q=hello+%20world")
    ).

parse_skips_empty_pairs_test() ->
    ?assertEqual(
        [{~"a", ~"1"}, {~"b", ~"2"}],
        cactus_qs:parse(~"a=1&&b=2")
    ).

parse_trailing_amp_test() ->
    ?assertEqual([{~"a", ~"1"}], cactus_qs:parse(~"a=1&")).

parse_leading_amp_test() ->
    ?assertEqual([{~"a", ~"1"}], cactus_qs:parse(~"&a=1")).

parse_bad_percent_kept_as_raw_test() ->
    %% Lenient: malformed percent sequences pass through as-is.
    ?assertEqual([{~"a", ~"%ZZ"}], cactus_qs:parse(~"a=%ZZ")).

parse_value_with_equals_test() ->
    %% Only the first `=` separates key from value.
    ?assertEqual(
        [{~"a", ~"b=c"}],
        cactus_qs:parse(~"a=b=c")
    ).
