-module(roadrunner_qs_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% parse/1
%% =============================================================================

parse_empty_test() ->
    ?assertEqual([], roadrunner_qs:parse(~"")).

parse_single_pair_test() ->
    ?assertEqual([{~"a", ~"1"}], roadrunner_qs:parse(~"a=1")).

parse_multiple_pairs_test() ->
    ?assertEqual(
        [{~"a", ~"1"}, {~"b", ~"2"}],
        roadrunner_qs:parse(~"a=1&b=2")
    ).

parse_flag_test() ->
    %% Bare key with no `=` is a flag — value is `true`.
    ?assertEqual(
        [{~"a", ~"1"}, {~"flag", true}],
        roadrunner_qs:parse(~"a=1&flag")
    ).

parse_empty_value_test() ->
    ?assertEqual([{~"a", ~""}], roadrunner_qs:parse(~"a=")).

parse_percent_encoded_value_test() ->
    ?assertEqual(
        [{~"q", ~"hello world"}],
        roadrunner_qs:parse(~"q=hello%20world")
    ).

parse_percent_encoded_key_test() ->
    ?assertEqual(
        [{~"q_name", ~"val"}],
        roadrunner_qs:parse(~"q%5Fname=val")
    ).

parse_plus_as_space_test() ->
    ?assertEqual(
        [{~"q", ~"hello world"}],
        roadrunner_qs:parse(~"q=hello+world")
    ).

parse_plus_and_percent_space_test() ->
    %% Both `+` and `%20` decode to space — `+` first, then percent.
    ?assertEqual(
        [{~"q", ~"hello  world"}],
        roadrunner_qs:parse(~"q=hello+%20world")
    ).

parse_skips_empty_pairs_test() ->
    ?assertEqual(
        [{~"a", ~"1"}, {~"b", ~"2"}],
        roadrunner_qs:parse(~"a=1&&b=2")
    ).

parse_trailing_amp_test() ->
    ?assertEqual([{~"a", ~"1"}], roadrunner_qs:parse(~"a=1&")).

parse_leading_amp_test() ->
    ?assertEqual([{~"a", ~"1"}], roadrunner_qs:parse(~"&a=1")).

parse_bad_percent_kept_as_raw_test() ->
    %% Lenient: malformed percent sequences pass through as-is.
    ?assertEqual([{~"a", ~"%ZZ"}], roadrunner_qs:parse(~"a=%ZZ")).

parse_value_with_equals_test() ->
    %% Only the first `=` separates key from value.
    ?assertEqual(
        [{~"a", ~"b=c"}],
        roadrunner_qs:parse(~"a=b=c")
    ).

%% =============================================================================
%% encode/1
%% =============================================================================

encode_empty_test() ->
    ?assertEqual(~"", roadrunner_qs:encode([])).

encode_single_pair_test() ->
    ?assertEqual(~"a=1", roadrunner_qs:encode([{~"a", ~"1"}])).

encode_multiple_pairs_test() ->
    ?assertEqual(
        ~"a=1&b=2",
        roadrunner_qs:encode([{~"a", ~"1"}, {~"b", ~"2"}])
    ).

encode_flag_test() ->
    ?assertEqual(~"flag", roadrunner_qs:encode([{~"flag", true}])).

encode_empty_value_test() ->
    ?assertEqual(~"a=", roadrunner_qs:encode([{~"a", ~""}])).

encode_space_as_plus_test() ->
    ?assertEqual(
        ~"q=hello+world",
        roadrunner_qs:encode([{~"q", ~"hello world"}])
    ).

encode_reserved_chars_test() ->
    %% '=' inside value gets percent-encoded so it isn't seen as a separator.
    ?assertEqual(
        ~"a=b%3Dc",
        roadrunner_qs:encode([{~"a", ~"b=c"}])
    ).

encode_unreserved_marks_test() ->
    %% RFC 3986 §2.3 unreserved set passes through.
    ?assertEqual(~"a=-._~", roadrunner_qs:encode([{~"a", ~"-._~"}])).

encode_literal_plus_test() ->
    %% Literal '+' must round-trip — encode it as %2B, not '+'.
    ?assertEqual(~"a=%2B", roadrunner_qs:encode([{~"a", ~"+"}])).

%% =============================================================================
%% Adversarial / edge cases — surfaced by reading the implementation and
%% by stressing inputs the property generators don't easily reach.
%% =============================================================================

parse_just_equals_test() ->
    %% A bare `=` is parsed as empty key + empty value — both `=` halves
    %% are present (one before, one after).
    ?assertEqual([{~"", ~""}], roadrunner_qs:parse(~"=")).

parse_just_amp_test() ->
    ?assertEqual([], roadrunner_qs:parse(~"&")).

parse_amp_amp_amp_test() ->
    ?assertEqual([], roadrunner_qs:parse(~"&&&")).

parse_equals_value_test() ->
    %% Empty key with explicit value — preserved.
    ?assertEqual([{~"", ~"v"}], roadrunner_qs:parse(~"=v")).

parse_lone_percent_passes_through_test() ->
    ?assertEqual(
        [{~"a", ~"%"}, {~"b", ~"%2"}],
        roadrunner_qs:parse(~"a=%&b=%2")
    ).

parse_high_bytes_test() ->
    %% Non-ASCII bytes pass through percent_decode unchanged.
    ?assertEqual(
        [{~"k", <<255, 254, 253>>}],
        roadrunner_qs:parse(<<"k=", 255, 254, 253>>)
    ).

%% Documented lossy round-trip: an empty-key bare flag encodes to <<>>,
%% which parses back to []. Asserts the asymmetry so refactors notice
%% it.
encode_empty_flag_is_dropped_on_roundtrip_test() ->
    Encoded = roadrunner_qs:encode([{~"", true}]),
    ?assertEqual(~"", Encoded),
    ?assertEqual([], roadrunner_qs:parse(Encoded)).

encode_separator_chars_in_key_test() ->
    %% `&` and `=` in a key would break parsing if not encoded.
    Encoded = roadrunner_qs:encode([{~"a&b=c", ~"x"}]),
    ?assertEqual(~"a%26b%3Dc=x", Encoded),
    ?assertEqual([{~"a&b=c", ~"x"}], roadrunner_qs:parse(Encoded)).

encode_all_unreserved_chars_passthrough_test() ->
    %% Every byte in the RFC 3986 unreserved set encodes to itself.
    Unreserved = <<
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        "abcdefghijklmnopqrstuvwxyz"
        "0123456789-._~"
    >>,
    ?assertEqual(
        <<"k=", Unreserved/binary>>,
        roadrunner_qs:encode([{~"k", Unreserved}])
    ).

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
            roadrunner_qs:parse(roadrunner_qs:encode(Pairs))
        )
     || Pairs <- Cases
    ].

parse_trigger_byte_at_every_position_test() ->
    %% A `+` or `%2B` at every position of a 17-byte value: each SWAR
    %% lane of both 7-byte words and the tail must send the string down
    %% the decoding path.
    Fill = binary:copy(~"a", 17),
    [
        begin
            <<Pre:Pos/binary, _, Post/binary>> = Fill,
            ?assertEqual(
                [{~"k", <<Pre/binary, " ", Post/binary>>}],
                roadrunner_qs:parse(<<"k=", Pre/binary, "+", Post/binary>>)
            ),
            ?assertEqual(
                [{~"k", <<Pre/binary, "+", Post/binary>>}],
                roadrunner_qs:parse(<<"k=", Pre/binary, "%2B", Post/binary>>)
            )
        end
     || Pos <- lists:seq(0, 16)
    ].

parse_decodes_a_trigger_at_every_position_test() ->
    %% A `+` or `%20` anywhere in a key of length 1 to 30 is decoded: each
    %% lane of a word pair, a lone word and every tail size of the scan
    %% that decides whether a key needs decoding at all.
    [
        begin
            Pre = binary:copy(~"a", Pos),
            Post = binary:copy(~"a", Len - Pos - 1),
            ?assertEqual(
                [{<<Pre/binary, " ", Post/binary>>, true}],
                roadrunner_qs:parse(<<Pre/binary, Trigger/binary, Post/binary>>),
                {Len, Pos, Trigger}
            )
        end
     || Len <- lists:seq(1, 30), Pos <- lists:seq(0, Len - 1), Trigger <- [~"+", ~"%20"]
    ].

%% `N` pairs `k=v` joined by `&`.
pairs(N) ->
    iolist_to_binary(lists:join($&, lists:duplicate(N, ~"k=v"))).

parse2_matches_parse1_test() ->
    lists:foreach(
        fun(Qs) -> ?assertEqual({ok, roadrunner_qs:parse(Qs)}, roadrunner_qs:parse(Qs, #{})) end,
        [~"", ~"a=1", ~"a=1&flag", ~"&&a=1&&b+c=%20d&", ~"x=%zz&y=+", ~"&", ~"a&"]
    ).

parse2_max_pairs_default_test() ->
    {ok, Pairs} = roadrunner_qs:parse(pairs(1000), #{}),
    ?assertEqual(1000, length(Pairs)),
    ?assertEqual({error, too_many_pairs}, roadrunner_qs:parse(pairs(1001), #{})).

parse2_max_pairs_option_test() ->
    Opts = #{max_pairs => 2},
    ?assertEqual({ok, [{~"a", ~"1"}, {~"b", true}]}, roadrunner_qs:parse(~"a=1&&b&", Opts)),
    ?assertEqual({error, too_many_pairs}, roadrunner_qs:parse(~"a=1&b&c", Opts)),
    ?assertEqual({error, too_many_pairs}, roadrunner_qs:parse(~"a=%201&b&c+d", Opts)).

parse2_long_pairs_test() ->
    %% Pairs longer than the window (4 bytes at `max_pairs => 2`).
    Opts = #{max_pairs => 2},
    ?assertEqual({ok, [{~"long", ~"value"}]}, roadrunner_qs:parse(~"long=value", Opts)),
    ?assertEqual(
        {ok, [{~"long", ~"value"}, {~"b", true}]}, roadrunner_qs:parse(~"long=value&b", Opts)
    ),
    ?assertEqual({error, too_many_pairs}, roadrunner_qs:parse(~"long=value&b&c", Opts)).

%% A guard: the string is scanned for `+` and `%` only once every window
%% is counted, which changes the cost of a refusal but not its result, so
%% this checks the results around the cap and that a `+` past the first
%% windows still decodes.
parse2_trigger_after_count_test() ->
    Bin = <<(binary:copy(~"a&", 4096))/binary, "k=x+y">>,
    ?assertEqual({error, too_many_pairs}, roadrunner_qs:parse(Bin, #{max_pairs => 1})),
    ?assertEqual({error, too_many_pairs}, roadrunner_qs:parse(Bin, #{max_pairs => 4096})),
    {ok, Pairs} = roadrunner_qs:parse(Bin, #{max_pairs => 4097}),
    ?assertEqual(4097, length(Pairs)),
    ?assertEqual({~"k", ~"x y"}, lists:last(Pairs)).

%% Every string of up to 7 bytes from `a=&+%2` (`%2` is a bad percent
%% sequence, kept raw): `parse/2` takes the pairs `parse/1` does, or
%% returns `too_many_pairs` past `max_pairs`.
parse2_agrees_with_parse1_test() ->
    Strings = lists:append([strings(N) || N <- lists:seq(0, 7)]),
    lists:foreach(
        fun(Qs) ->
            Pairs = roadrunner_qs:parse(Qs),
            lists:foreach(
                fun(Max) ->
                    Expected =
                        case length(Pairs) =< Max of
                            true -> {ok, Pairs};
                            false -> {error, too_many_pairs}
                        end,
                    ?assertEqual(Expected, roadrunner_qs:parse(Qs, #{max_pairs => Max}))
                end,
                [1, 2, 3]
            )
        end,
        Strings
    ).

strings(0) -> [<<>>];
strings(N) -> [<<S/binary, C>> || S <- strings(N - 1), C <- "a=&+%2"].
