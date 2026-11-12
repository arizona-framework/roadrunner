-module(roadrunner_ws_heap_floor_SUITE).
-moduledoc """
The WebSocket session's heap floor (`ws.heap_floor`, by default
`handler_spawn.heap_floor`): after a `handle_info/2` that needed at least
its `min` the session keeps the heap that call needed as its
`min_heap_size`, up to the cap, learns it again every 16 messages while
raised, and drops back to its base before it hibernates. The handler is `roadrunner_heap_floor_handler`, driven
by messages to the session's `handle_info/2`.
""".

-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_testcase/2, end_per_testcase/2]).
-export([
    floor_rises_after_a_large_event/1,
    floor_stops_at_the_cap/1,
    floor_off/1,
    floor_starts_at_the_upgrade_min_heap_size/1,
    floor_off_when_the_cap_is_under_the_upgrade_min_heap_size/1,
    floor_relearns_every_16_events/1,
    small_events_leave_the_floor/1,
    small_events_raise_it_with_no_minimum/1,
    ws_cap_overrides_the_listener/1,
    ws_cap_off/1,
    upgrade_sets_the_floor/1,
    upgrade_turns_the_floor_off/1,
    floor_resets_when_the_handler_hibernates/1,
    floor_resets_when_the_session_idles/1
]).

-define(H, roadrunner_heap_floor_handler).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        floor_rises_after_a_large_event,
        floor_stops_at_the_cap,
        floor_off,
        floor_starts_at_the_upgrade_min_heap_size,
        floor_off_when_the_cap_is_under_the_upgrade_min_heap_size,
        floor_relearns_every_16_events,
        small_events_leave_the_floor,
        small_events_raise_it_with_no_minimum,
        ws_cap_overrides_the_listener,
        ws_cap_off,
        upgrade_sets_the_floor,
        upgrade_turns_the_floor_off,
        floor_resets_when_the_handler_hibernates,
        floor_resets_when_the_session_idles
    ].

init_per_testcase(Case, Config) ->
    {ok, _} = roadrunner_listener:start_link(
        ?MODULE,
        maps:merge(listener_opts(Case), #{
            port => 0,
            routes => [{~"/ws", ?H, route_state(Case)}]
        })
    ),
    [{port, roadrunner_listener:port(?MODULE)} | Config].

end_per_testcase(_Case, _Config) ->
    ok = roadrunner_listener:stop(?MODULE).

listener_opts(floor_stops_at_the_cap) ->
    #{handler_spawn => #{heap_floor => #{max => 1000}}};
listener_opts(floor_off) ->
    #{handler_spawn => #{heap_floor => false}};
listener_opts(floor_off_when_the_cap_is_under_the_upgrade_min_heap_size) ->
    #{handler_spawn => #{heap_floor => #{max => 1000}}};
listener_opts(small_events_raise_it_with_no_minimum) ->
    #{ws => #{heap_floor => #{min => 0}}};
listener_opts(ws_cap_overrides_the_listener) ->
    #{ws => #{heap_floor => #{max => 1000}}};
listener_opts(ws_cap_off) ->
    #{ws => #{heap_floor => false}};
listener_opts(floor_resets_when_the_session_idles) ->
    #{ws => #{hibernate_after => 200}};
listener_opts(_Case) ->
    #{}.

route_state(Case) when
    Case =:= floor_starts_at_the_upgrade_min_heap_size;
    Case =:= floor_off_when_the_cap_is_under_the_upgrade_min_heap_size
->
    {ws, self(), #{min_heap_size => 2000}};
route_state(upgrade_sets_the_floor) ->
    {ws, self(), #{heap_floor => #{max => 1000, min => 0}}};
route_state(upgrade_turns_the_floor_off) ->
    {ws, self(), #{heap_floor => false}};
route_state(_Case) ->
    {ws, self()}.

%% =============================================================================
%% Cases
%% =============================================================================

floor_rises_after_a_large_event(Config) ->
    Session = upgrade(Config),
    ok = alloc(Session),
    Floor = report(Session),
    ?assert(Floor > base()),
    ?assert(Floor =< 46422).

%% The emulator rounds a `min_heap_size` up to a step of its heap-size
%% ladder, so the cap reads back as that step. A second large event finds
%% the floor at the cap already.
floor_stops_at_the_cap(Config) ->
    Session = upgrade(Config),
    ok = alloc(Session),
    ok = alloc(Session),
    ?assertEqual(rounded(1000), report(Session)).

floor_off(Config) ->
    Session = upgrade(Config),
    ok = alloc(Session),
    ?assertEqual(base(), report(Session)).

floor_starts_at_the_upgrade_min_heap_size(Config) ->
    Session = upgrade(Config),
    ok = alloc(Session),
    ?assert(report(Session) > rounded(2000)).

floor_off_when_the_cap_is_under_the_upgrade_min_heap_size(Config) ->
    Session = upgrade(Config),
    ok = alloc(Session),
    ?assertEqual(rounded(2000), report(Session)).

%% Within 16 events of a large one the floor drops back to the base.
floor_relearns_every_16_events(Config) ->
    Session = upgrade(Config),
    ok = alloc(Session),
    ?assert(report(Session) > base()),
    Floors = [report(Session) || _ <- lists:seq(1, 17)],
    ?assert(lists:member(base(), Floors)).

%% An event that needed less than the floor's `min` leaves the floor
%% where it is.
small_events_leave_the_floor(Config) ->
    Session = upgrade(Config),
    ok = small_alloc(Session),
    ?assertEqual(base(), report(Session)).

%% With no minimum a small event raises the floor, and a larger one
%% raises it further.
small_events_raise_it_with_no_minimum(Config) ->
    Session = upgrade(Config),
    ok = small_alloc(Session),
    Small = report(Session),
    ?assert(Small > base()),
    ok = alloc(Session),
    ?assert(report(Session) > Small).

ws_cap_overrides_the_listener(Config) ->
    Session = upgrade(Config),
    ok = alloc(Session),
    ?assertEqual(rounded(1000), report(Session)).

ws_cap_off(Config) ->
    Session = upgrade(Config),
    ok = alloc(Session),
    ?assertEqual(base(), report(Session)).

%% The upgrade's own `heap_floor` `max` and `min` win over the
%% listener's.
upgrade_sets_the_floor(Config) ->
    Session = upgrade(Config),
    ok = small_alloc(Session),
    Floor = report(Session),
    ?assert(Floor > base()),
    ?assert(Floor =< rounded(1000)).

upgrade_turns_the_floor_off(Config) ->
    Session = upgrade(Config),
    ok = alloc(Session),
    ?assertEqual(base(), report(Session)).

%% A handler's `hibernate` drops the floor first, so the session wakes at
%% its base; hibernating again finds it there.
floor_resets_when_the_handler_hibernates(Config) ->
    Session = upgrade(Config),
    ok = alloc(Session),
    ?assert(report(Session) > base()),
    ok = hibernate(Session),
    ok = hibernate(Session),
    ?assertEqual(base(), report(Session)).

%% So does `ws.hibernate_after` when the session idles.
floor_resets_when_the_session_idles(Config) ->
    Session = upgrade(Config),
    ok = alloc(Session),
    ?assert(report(Session) > base()),
    1 = erlang:trace(Session, true, [running]),
    receive
        {trace, Session, out, {erlang, hibernate, 3}} -> ok
    after 5000 -> ct:fail(not_hibernated)
    end,
    _ = erlang:trace(Session, false, [running]),
    ?assertEqual({min_heap_size, base()}, process_info(Session, min_heap_size)).

%% =============================================================================
%% Helpers
%% =============================================================================

base() ->
    element(2, erlang:system_info(min_heap_size)).

%% `Words` as the emulator stores a `min_heap_size`: rounded up to a step of
%% its heap-size ladder.
rounded(Words) ->
    Self = self(),
    _ = spawn_opt(
        fun() -> Self ! {rounded, process_info(self(), min_heap_size)} end,
        [{min_heap_size, Words}]
    ),
    receive
        {rounded, {min_heap_size, Rounded}} -> Rounded
    after 5000 -> ct:fail(no_probe)
    end.

%% Upgrade and return the session's pid, once its `init/1` has run.
upgrade(Config) ->
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, ?config(port, Config), [binary, {active, false}], 5000
    ),
    ok = gen_tcp:send(Sock, [
        ~"GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n",
        ~"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
    ]),
    {ok, <<"HTTP/1.1 101", _/binary>>} = gen_tcp:recv(Sock, 0, 5000),
    Session =
        receive
            {ws_session, Pid} -> Pid
        after 5000 -> ct:fail(no_session)
        end,
    receive
        {ws_min_heap_size, _} -> Session
    after 5000 -> ct:fail(no_session)
    end.

alloc(Session) ->
    Session ! alloc,
    receive
        {ws_alloc, _} -> ok
    after 5000 -> ct:fail(no_alloc)
    end.

small_alloc(Session) ->
    Session ! small_alloc,
    receive
        {ws_alloc, _} -> ok
    after 5000 -> ct:fail(no_alloc)
    end.

hibernate(Session) ->
    Session ! hibernate,
    receive
        ws_hibernating -> ok
    after 5000 -> ct:fail(no_hibernate)
    end.

%% The session's `min_heap_size` while it handles this event: the floor the
%% events before it left.
report(Session) ->
    Session ! report,
    receive
        {ws_min_heap_size, Words} -> Words
    after 5000 -> ct:fail(no_report)
    end.
