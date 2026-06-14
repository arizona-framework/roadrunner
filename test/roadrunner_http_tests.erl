-module(roadrunner_http_tests).
-include_lib("eunit/include/eunit.hrl").

http_date_now_format_matches_imf_fixdate_test() ->
    %% RFC 9110 §5.6.7: `Sun, 06 Nov 1994 08:49:37 GMT`. Validate the
    %% shape of the produced string — three-letter day, two-digit
    %% date, three-letter month, four-digit year, HH:MM:SS, GMT.
    Date = roadrunner_http:http_date_now(),
    %% Length is fixed: 29 bytes.
    ?assertEqual(29, byte_size(Date)),
    %% Last 3 chars are "GMT".
    ?assertEqual(~"GMT", binary:part(Date, 26, 3)),
    %% Day name is one of the seven.
    DayName = binary:part(Date, 0, 3),
    ?assert(
        lists:member(DayName, [~"Mon", ~"Tue", ~"Wed", ~"Thu", ~"Fri", ~"Sat", ~"Sun"])
    ),
    %% Month abbreviation is at offset 8..11.
    MonthName = binary:part(Date, 8, 3),
    ?assert(
        lists:member(MonthName, [
            ~"Jan",
            ~"Feb",
            ~"Mar",
            ~"Apr",
            ~"May",
            ~"Jun",
            ~"Jul",
            ~"Aug",
            ~"Sep",
            ~"Oct",
            ~"Nov",
            ~"Dec"
        ])
    ).

http_date_now_caches_per_process_test_() ->
    %% Run in a fresh process so the dictionary starts empty: the first
    %% read takes the reformat (miss) branch, and a same-second second
    %% read takes the cached (hit) branch. `same_second_pair/0` retries
    %% across a second boundary so the hit assertion is deterministic.
    {spawn, fun() ->
        %% Cold dictionary => miss branch.
        First = roadrunner_http:http_date_now(),
        ?assertEqual(29, byte_size(First)),
        {A, B} = same_second_pair(),
        ?assertEqual(A, B)
    end}.

same_second_pair() ->
    S0 = erlang:system_time(second),
    A = roadrunner_http:http_date_now(),
    B = roadrunner_http:http_date_now(),
    case erlang:system_time(second) of
        S0 -> {A, B};
        _ -> same_second_pair()
    end.

format_http_date_pads_single_digits_test() ->
    %% Pick a timestamp whose calendar fields all need two-digit padding
    %% (1970-01-01 00:00:00 UTC = Posix 0) so the `pad2/1` single-digit
    %% clause is exercised regardless of wall-clock at test run time.
    Date = roadrunner_http:format_http_date(0),
    ?assertEqual(~"Thu, 01 Jan 1970 00:00:00 GMT", Date).

header_list_size_sums_fields_with_overhead_test() ->
    %% RFC 7541 §4.1: each field contributes name + value + 32 bytes.
    ?assertEqual(0, roadrunner_http:header_list_size([])),
    %% "a"(1) + "bb"(2) + 32 = 35; plus "ccc"(3) + ""(0) + 32 = 35 → 70.
    ?assertEqual(
        70,
        roadrunner_http:header_list_size([{~"a", ~"bb"}, {~"ccc", ~""}])
    ).

%% --- with_defaults/2 ---

with_defaults_empty_defaults_returns_headers_unchanged_test() ->
    Headers = [{~"a", ~"1"}],
    ?assertEqual(Headers, roadrunner_http:with_defaults(Headers, [])).

with_defaults_prepends_absent_defaults_in_order_test() ->
    %% Absent defaults are prepended, keeping their order, ahead of the
    %% existing headers.
    ?assertEqual(
        [{~"x", ~"1"}, {~"y", ~"2"}, {~"a", ~"0"}],
        roadrunner_http:with_defaults([{~"a", ~"0"}], [{~"x", ~"1"}, {~"y", ~"2"}])
    ).

with_defaults_existing_header_wins_test() ->
    %% A default whose name the headers already carry is skipped (the
    %% existing value wins); the others are still added.
    ?assertEqual(
        [{~"y", ~"2"}, {~"a", ~"keep"}],
        roadrunner_http:with_defaults([{~"a", ~"keep"}], [{~"a", ~"drop"}, {~"y", ~"2"}])
    ).

%% --- drop_unset/1 ---

drop_unset_keeps_only_set_values_in_order_test() ->
    ?assertEqual(
        [{~"a", ~"1"}, {~"c", ~""}],
        roadrunner_http:drop_unset([{~"a", ~"1"}, {~"b", false}, {~"c", ~""}])
    ).

drop_unset_all_false_returns_empty_test() ->
    ?assertEqual([], roadrunner_http:drop_unset([{~"a", false}, {~"b", false}])).

drop_unset_empty_returns_empty_test() ->
    ?assertEqual([], roadrunner_http:drop_unset([])).
