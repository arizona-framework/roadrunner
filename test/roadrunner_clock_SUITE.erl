-module(roadrunner_clock_SUITE).
-moduledoc """
The `Date` header clock under `roadrunner_sup`: it publishes the date
stamp on start, rewrites it on its own tick only, and clears it when it
or the application stops, after which readers format the system time.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1]).
-export([
    start_publishes_the_stamp/1,
    own_tick_rewrites_the_stamp/1,
    stray_tick_is_ignored/1,
    out_of_range_time_clears_the_stamp/1,
    stopped_clock_clears_the_stamp/1,
    stopped_application_clears_the_stamp/1,
    http1_date_line_follows_the_stamp/1,
    call_and_cast_are_accepted/1
]).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        start_publishes_the_stamp,
        own_tick_rewrites_the_stamp,
        stray_tick_is_ignored,
        out_of_range_time_clears_the_stamp,
        stopped_clock_clears_the_stamp,
        stopped_application_clears_the_stamp,
        http1_date_line_follows_the_stamp,
        call_and_cast_are_accepted
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(roadrunner),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(roadrunner).

start_publishes_the_stamp(_Config) ->
    %% The tick lands just past each second boundary, so the date read
    %% is this second's or, inside that gap, the previous one's.
    Now = erlang:system_time(second),
    Date = roadrunner_http:http_date_now(),
    ?assertEqual(Date, roadrunner_clock:stamp_to_date(roadrunner_clock:stamp())),
    ?assert(
        lists:member(Date, [roadrunner_http:format_http_date(S) || S <- [Now - 1, Now, Now + 1]])
    ).

own_tick_rewrites_the_stamp(_Config) ->
    %% Fire the clock's pending timer message early: it stores the stamp
    %% and aims a fresh timer, so the state moves on to a new reference.
    Timer = sys:get_state(roadrunner_clock),
    roadrunner_clock ! {timeout, Timer, tick},
    ?assertNotEqual(Timer, sys:get_state(roadrunner_clock)).

stray_tick_is_ignored(_Config) ->
    Timer = sys:get_state(roadrunner_clock),
    roadrunner_clock ! {timeout, make_ref(), tick},
    roadrunner_clock ! unexpected,
    After = sys:get_state(roadrunner_clock),
    %% Unless the real tick fired in between, the state is unchanged.
    case erlang:read_timer(Timer) of
        false -> ok;
        _ -> ?assertEqual(Timer, After)
    end.

out_of_range_time_clears_the_stamp(_Config) ->
    %% Before 1970 and from 2226 on the tables have no entry, so readers
    %% take the system-time path.
    ok = roadrunner_clock:put_stamp(-1),
    ?assertEqual(undefined, roadrunner_clock:stamp()),
    ok = roadrunner_clock:put_stamp(8078572800),
    ?assertEqual(undefined, roadrunner_clock:stamp()),
    ok = roadrunner_clock:put_stamp(erlang:system_time(second)),
    ?assert(is_integer(roadrunner_clock:stamp())).

stopped_clock_clears_the_stamp(_Config) ->
    ok = supervisor:terminate_child(roadrunner_sup, roadrunner_clock),
    ?assertEqual(undefined, roadrunner_clock:stamp()),
    {Date, Expected} = same_second(fun roadrunner_http:http_date_now/0),
    ?assertEqual(Expected, Date),
    {ok, _} = supervisor:restart_child(roadrunner_sup, roadrunner_clock),
    ?assert(is_integer(roadrunner_clock:stamp())).

stopped_application_clears_the_stamp(_Config) ->
    ok = application:stop(roadrunner),
    ?assertEqual(undefined, roadrunner_clock:stamp()),
    {ok, _} = application:ensure_all_started(roadrunner),
    ?assert(is_integer(roadrunner_clock:stamp())).

http1_date_line_follows_the_stamp(_Config) ->
    %% A fresh process: the first response builds and caches the line, a
    %% same-stamp response reuses it, a cleared stamp formats it directly.
    Self = self(),
    {Pid, Ref} = spawn_monitor(fun() ->
        Lines = [date_line() || _ <- [cold, warm]],
        ok = roadrunner_clock:clear_stamp(),
        Self ! {lines, Lines, date_line()}
    end),
    receive
        {lines, [Cold, Warm], Cleared} ->
            ?assertEqual(Cold, Warm),
            [?assertMatch(<<"date: ", _:29/binary, "\r\n">>, L) || L <- [Cold, Cleared]]
    end,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    end,
    ok = roadrunner_clock:put_stamp(erlang:system_time(second)).

call_and_cast_are_accepted(_Config) ->
    ?assertEqual(ok, gen_server:call(roadrunner_clock, ping)),
    ok = gen_server:cast(roadrunner_clock, noop),
    ?assertEqual(ok, gen_server:call(roadrunner_clock, sync)).

%% `Fun()` alongside the system time formatted the same second, retried
%% across a second boundary.
same_second(Fun) ->
    S0 = erlang:system_time(second),
    Value = Fun(),
    case erlang:system_time(second) of
        S0 -> {Value, roadrunner_http:format_http_date(S0)};
        _ -> same_second(Fun)
    end.

date_line() ->
    iolist_to_binary(
        lists:filter(
            fun(Part) -> is_binary(Part) andalso binary:match(Part, ~"date: ") =/= nomatch end,
            lists:flatten(roadrunner_http1:response(200, [], ~"", undefined))
        )
    ).
