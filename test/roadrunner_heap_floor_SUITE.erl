-module(roadrunner_heap_floor_SUITE).
-moduledoc """
The HTTP/1.1 connection's heap floor (`handler_spawn.heap_floor`): after a
request it keeps the heap that request needed as its `min_heap_size`, up
to the cap, and drops back to the base before it hibernates or runs a
WebSocket session. The handler is `roadrunner_heap_floor_handler`.
""".

-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_testcase/2, end_per_testcase/2]).
-export([
    floor_rises_after_a_large_request/1,
    floor_stops_at_the_cap/1,
    floor_off/1,
    floor_starts_at_the_spawn_min_heap_size/1,
    floor_off_when_the_cap_is_under_the_spawn_min_heap_size/1,
    floor_relearns_every_16_requests/1,
    floor_resets_before_hibernating/1,
    floor_resets_for_a_websocket_session/1
]).

-define(H, roadrunner_heap_floor_handler).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        floor_rises_after_a_large_request,
        floor_stops_at_the_cap,
        floor_off,
        floor_starts_at_the_spawn_min_heap_size,
        floor_off_when_the_cap_is_under_the_spawn_min_heap_size,
        floor_relearns_every_16_requests,
        floor_resets_before_hibernating,
        floor_resets_for_a_websocket_session
    ].

init_per_testcase(Case, Config) ->
    {ok, _} = roadrunner_listener:start_link(
        ?MODULE,
        maps:merge(listener_opts(Case), #{
            port => 0,
            routes => [
                {~"/alloc", ?H, {alloc, self()}},
                {~"/report", ?H, report},
                {~"/ws", ?H, {ws, self()}}
            ]
        })
    ),
    [{port, roadrunner_listener:port(?MODULE)} | Config].

end_per_testcase(_Case, _Config) ->
    ok = roadrunner_listener:stop(?MODULE).

listener_opts(floor_stops_at_the_cap) ->
    #{handler_spawn => #{heap_floor => 1000}};
listener_opts(floor_off) ->
    #{handler_spawn => #{heap_floor => 0}};
listener_opts(floor_starts_at_the_spawn_min_heap_size) ->
    #{handler_spawn => #{opts => [{min_heap_size, 2000}]}};
listener_opts(floor_off_when_the_cap_is_under_the_spawn_min_heap_size) ->
    #{handler_spawn => #{opts => [{min_heap_size, 2000}], heap_floor => 1000}};
listener_opts(floor_resets_before_hibernating) ->
    #{hibernate_after => 200};
listener_opts(_Case) ->
    #{}.

%% =============================================================================
%% Cases
%% =============================================================================

floor_rises_after_a_large_request(Config) ->
    Sock = connect(Config),
    ?assertEqual(base(), report(Sock)),
    ok = alloc(Sock),
    Floor = report(Sock),
    ?assert(Floor > base()),
    ?assert(Floor =< 46422).

%% The emulator rounds a `min_heap_size` up to a step of its heap-size
%% ladder, so the cap reads back as that step.
floor_stops_at_the_cap(Config) ->
    Sock = connect(Config),
    ok = alloc(Sock),
    ?assertEqual(rounded(1000), report(Sock)).

floor_off(Config) ->
    Sock = connect(Config),
    ok = alloc(Sock),
    ?assertEqual(base(), report(Sock)).

floor_starts_at_the_spawn_min_heap_size(Config) ->
    Sock = connect(Config),
    ?assertEqual(rounded(2000), report(Sock)),
    ok = alloc(Sock),
    ?assert(report(Sock) > rounded(2000)).

%% A cap no higher than the heap the connection starts with leaves it
%% there.
floor_off_when_the_cap_is_under_the_spawn_min_heap_size(Config) ->
    Sock = connect(Config),
    ok = alloc(Sock),
    ?assertEqual(rounded(2000), report(Sock)).

%% Every 16th request drops the floor, so the 17th starts at the base: a
%% connection whose requests got smaller can give the heap back. Each
%% report reads the floor before its own request is counted.
floor_relearns_every_16_requests(Config) ->
    Sock = connect(Config),
    ok = alloc(Sock),
    Floors = [report(Sock) || _ <- lists:seq(2, 16)],
    ?assert(lists:all(fun(Floor) -> Floor > base() end, Floors)),
    ?assertEqual(base(), report(Sock)),
    ok = alloc(Sock),
    ?assert(report(Sock) > base()).

%% The floor drops back before the connection hibernates, so it sleeps and
%% wakes small, and the next requests raise it again.
floor_resets_before_hibernating(Config) ->
    Sock = connect(Config),
    ok = alloc(Sock),
    Conn = conn_pid(),
    1 = erlang:trace(Conn, true, [running]),
    receive
        {trace, Conn, out, {erlang, hibernate, 3}} -> ok
    after 5000 -> ct:fail(not_hibernated)
    end,
    _ = erlang:trace(Conn, false, [running]),
    ?assertEqual({min_heap_size, base()}, process_info(Conn, min_heap_size)),
    ?assertEqual(base(), report(Sock)).

%% A WebSocket session sizes its own heap: the upgrade drops the floor the
%% requests before it raised.
floor_resets_for_a_websocket_session(Config) ->
    Sock = connect(Config),
    ok = alloc(Sock),
    ?assert(report(Sock) > base()),
    ok = gen_tcp:send(Sock, [
        ~"GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n",
        ~"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
    ]),
    receive
        {ws_min_heap_size, Words} -> ?assertEqual(base(), Words)
    after 5000 -> ct:fail(no_session)
    end.

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
    end.

connect(Config) ->
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, ?config(port, Config), [binary, {active, false}], 5000
    ),
    Sock.

alloc(Sock) ->
    ~"20000" = get(Sock, ~"/alloc"),
    ok.

report(Sock) ->
    binary_to_integer(get(Sock, ~"/report")).

conn_pid() ->
    receive
        {conn, Pid} -> Pid
    after 5000 -> ct:fail(no_conn_pid)
    end.

%% One keep-alive GET on the socket; returns the body.
get(Sock, Path) ->
    ok = gen_tcp:send(Sock, [~"GET ", Path, ~" HTTP/1.1\r\nHost: x\r\n\r\n"]),
    read_response(Sock, <<>>).

read_response(Sock, Acc) ->
    case binary:split(Acc, ~"\r\n\r\n") of
        [Head, Rest] ->
            read_body(Sock, Rest, content_length(Head));
        [_] ->
            {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
            read_response(Sock, <<Acc/binary, Data/binary>>)
    end.

content_length(Head) ->
    {match, [Len]} = re:run(Head, ~"(?i)content-length: (\\d+)", [{capture, all_but_first, binary}]),
    binary_to_integer(Len).

read_body(_Sock, Body, Len) when byte_size(Body) >= Len ->
    <<Exact:Len/binary, _/binary>> = Body,
    Exact;
read_body(Sock, Body, Len) ->
    {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
    read_body(Sock, <<Body/binary, Data/binary>>, Len).
