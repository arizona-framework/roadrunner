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

%% =============================================================================
%% encode/1
%% =============================================================================

encode_empty_test() ->
    ?assertEqual(~"", cactus_qs:encode([])).

encode_single_pair_test() ->
    ?assertEqual(~"a=1", cactus_qs:encode([{~"a", ~"1"}])).

encode_multiple_pairs_test() ->
    ?assertEqual(
        ~"a=1&b=2",
        cactus_qs:encode([{~"a", ~"1"}, {~"b", ~"2"}])
    ).

encode_flag_test() ->
    ?assertEqual(~"flag", cactus_qs:encode([{~"flag", true}])).

encode_empty_value_test() ->
    ?assertEqual(~"a=", cactus_qs:encode([{~"a", ~""}])).

encode_space_as_plus_test() ->
    ?assertEqual(
        ~"q=hello+world",
        cactus_qs:encode([{~"q", ~"hello world"}])
    ).

encode_reserved_chars_test() ->
    %% '=' inside value gets percent-encoded so it isn't seen as a separator.
    ?assertEqual(
        ~"a=b%3Dc",
        cactus_qs:encode([{~"a", ~"b=c"}])
    ).

encode_unreserved_marks_test() ->
    %% RFC 3986 §2.3 unreserved set passes through.
    ?assertEqual(~"a=-._~", cactus_qs:encode([{~"a", ~"-._~"}])).

encode_literal_plus_test() ->
    %% Literal '+' must round-trip — encode it as %2B, not '+'.
    ?assertEqual(~"a=%2B", cactus_qs:encode([{~"a", ~"+"}])).

encode_parse_roundtrip_test_() ->
    Cases = [
        [],
        [{~"a", ~"1"}],
        [{~"a", ~"1"}, {~"b", ~"2"}],
        [{~"flag", true}],
        [{~"a", ~""}],
        [{~"q", ~"hello world"}],
        [{~"a", ~"b=c"}],
        [{~"key with space", ~"value with space"}],
        [{~"a", ~"+"}],
        [{~"unicode", ~"café"}]
    ],
    [
        ?_assertEqual(
            Pairs,
            cactus_qs:parse(cactus_qs:encode(Pairs))
        )
     || Pairs <- Cases
    ].
