-module(roadrunner_grpc_timeout_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_grpc_timeout).

units_test() ->
    ?assertEqual({ok, 7_200_000}, ?M:parse(~"2H")),
    ?assertEqual({ok, 180_000}, ?M:parse(~"3M")),
    ?assertEqual({ok, 1000}, ?M:parse(~"1S")),
    ?assertEqual({ok, 250}, ?M:parse(~"250m")),
    ?assertEqual({ok, 0}, ?M:parse(~"0S")).

%% A part of a millisecond rounds up, so the deadline never comes early.
sub_millisecond_rounds_up_test() ->
    ?assertEqual({ok, 1}, ?M:parse(~"1u")),
    ?assertEqual({ok, 1}, ?M:parse(~"1000u")),
    ?assertEqual({ok, 2}, ?M:parse(~"1001u")),
    ?assertEqual({ok, 1}, ?M:parse(~"1n")),
    ?assertEqual({ok, 0}, ?M:parse(~"0n")),
    ?assertEqual({ok, 3}, ?M:parse(~"2000001n")).

%% Eight digits at most; longer than a wait can take is infinity.
eight_digits_test() ->
    ?assertEqual({ok, 99_999_999}, ?M:parse(~"99999999m")),
    ?assertEqual(error, ?M:parse(~"123456789m")),
    ?assertEqual({ok, infinity}, ?M:parse(~"99999999H")),
    ?assertEqual({ok, 16#FFFFFFFF div 1000 * 1000}, ?M:parse(~"4294967S")),
    ?assertEqual({ok, infinity}, ?M:parse(~"4294968S")).

malformed_test() ->
    lists:foreach(
        fun(Value) -> ?assertEqual(error, ?M:parse(Value)) end,
        [~"", ~"S", ~"10", ~"10s", ~"10 S", ~" 10S", ~"10SS", ~"-1S", ~"1.5S", ~"1x"]
    ).
