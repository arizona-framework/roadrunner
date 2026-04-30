-module(cactus_cookie_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% parse/1
%% =============================================================================

parse_empty_test() ->
    ?assertEqual([], cactus_cookie:parse(~"")).

parse_single_test() ->
    ?assertEqual(
        [{~"sid", ~"abc"}],
        cactus_cookie:parse(~"sid=abc")
    ).

parse_multiple_with_canonical_separator_test() ->
    ?assertEqual(
        [{~"sid", ~"abc"}, {~"theme", ~"dark"}],
        cactus_cookie:parse(~"sid=abc; theme=dark")
    ).

parse_multiple_no_space_after_semi_test() ->
    ?assertEqual(
        [{~"a", ~"1"}, {~"b", ~"2"}],
        cactus_cookie:parse(~"a=1;b=2")
    ).

parse_trims_leading_ows_test() ->
    ?assertEqual(
        [{~"sid", ~"abc"}, {~"theme", ~"dark"}],
        cactus_cookie:parse(~"sid=abc;   theme=dark")
    ).

parse_trims_trailing_ows_test() ->
    ?assertEqual(
        [{~"sid", ~"abc"}, {~"theme", ~"dark"}],
        cactus_cookie:parse(~"sid=abc   ; theme=dark   ")
    ).

parse_with_htab_separator_test() ->
    %% HTAB is also OWS per RFC 7230 — trim it on both sides.
    ?assertEqual(
        [{~"a", ~"1"}, {~"b", ~"2"}, {~"c", ~"3"}],
        cactus_cookie:parse(~"a=1;\tb=2\t;c=3")
    ).

parse_bad_no_equals_skipped_test() ->
    ?assertEqual([], cactus_cookie:parse(~"badnoequals")).

parse_empty_name_skipped_test() ->
    ?assertEqual([], cactus_cookie:parse(~"=value")).

parse_empty_value_accepted_test() ->
    ?assertEqual([{~"sid", ~""}], cactus_cookie:parse(~"sid=")).

parse_skip_bad_among_good_test() ->
    ?assertEqual(
        [{~"sid", ~"abc"}, {~"theme", ~"dark"}],
        cactus_cookie:parse(~"sid=abc; bad; theme=dark")
    ).

parse_all_whitespace_pair_skipped_test() ->
    ?assertEqual(
        [{~"a", ~"1"}, {~"b", ~"2"}],
        cactus_cookie:parse(~"a=1;   ;b=2")
    ).

parse_value_with_equals_test() ->
    %% Only the first '=' separates name from value.
    ?assertEqual(
        [{~"sid", ~"a=b=c"}],
        cactus_cookie:parse(~"sid=a=b=c")
    ).
