-module(roadrunner_stream_heap_floor_SUITE).
-moduledoc """
The heap floor of HTTP/2 stream workers (`handler_spawn.heap_floor`): each
worker raises its connection's floor to the heap its request needed, up to
the cap, and the next worker starts at that size; every 16th stream starts
at the base and learns it again. Over h2c, with
`roadrunner_heap_floor_handler`.
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
    floor_relearns_every_16_streams/1,
    smaller_need_leaves_a_higher_floor/1
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
        floor_relearns_every_16_streams,
        smaller_need_leaves_a_higher_floor
    ].

init_per_testcase(Case, Config) ->
    {ok, _} = roadrunner_listener:start_link(
        ?MODULE,
        maps:merge(listener_opts(Case), #{
            port => 0,
            protocols => [http2],
            routes => [
                {~"/alloc", ?H, {alloc, self()}},
                {~"/gated", ?H, {gated_alloc, self()}},
                {~"/report", ?H, report}
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
listener_opts(_Case) ->
    #{}.

%% =============================================================================
%% Cases
%% =============================================================================

floor_rises_after_a_large_request(Config) ->
    C = open(Config),
    {Base, C1} = report(C, 1),
    ?assertEqual(base(), Base),
    C2 = alloc(C1, 3),
    {Floor, _} = report(C2, 5),
    ?assert(Floor > base()),
    ?assert(Floor =< 46422).

%% A worker started at the cap answers without reading its heap; the next
%% one starts at the cap too.
floor_stops_at_the_cap(Config) ->
    C = open(Config),
    C1 = alloc(C, 1),
    C2 = alloc(C1, 3),
    {Floor, _} = report(C2, 5),
    ?assertEqual(rounded(1000), Floor).

floor_off(Config) ->
    C = open(Config),
    C1 = alloc(C, 1),
    {Floor, _} = report(C1, 3),
    ?assertEqual(base(), Floor).

floor_starts_at_the_spawn_min_heap_size(Config) ->
    C = open(Config),
    {Base, C1} = report(C, 1),
    ?assertEqual(rounded(2000), Base),
    C2 = alloc(C1, 3),
    {Floor, _} = report(C2, 5),
    ?assert(Floor > rounded(2000)).

floor_off_when_the_cap_is_under_the_spawn_min_heap_size(Config) ->
    C = open(Config),
    C1 = alloc(C, 1),
    {Floor, _} = report(C1, 3),
    ?assertEqual(rounded(2000), Floor).

%% Stream 33 is the 17th: it starts at the base and resets the floor.
floor_relearns_every_16_streams(Config) ->
    C = open(Config),
    C1 = alloc(C, 1),
    {Floors, C2} = lists:mapfoldl(fun(Id, Acc) -> report(Acc, Id) end, C1, lists:seq(3, 31, 2)),
    ?assert(lists:all(fun(Floor) -> Floor > base() end, Floors)),
    {Relearned, C3} = report(C2, 33),
    ?assertEqual(base(), Relearned),
    {Next, _} = report(C3, 35),
    ?assertEqual(base(), Next).

%% A worker that started before a larger one raised the floor, and needed
%% less than that, leaves the higher floor in place.
smaller_need_leaves_a_higher_floor(Config) ->
    C = open(Config),
    C1 = send_get(C, 1, ~"/gated"),
    Gated =
        receive
            {gated, Pid} -> Pid
        after 5000 -> ct:fail(not_gated)
        end,
    C2 = alloc(C1, 3),
    {Floor, C3} = report(C2, 5),
    Gated ! go,
    {_, C4} = response(C3, 1),
    {After, _} = report(C4, 7),
    ?assertEqual(Floor, After).

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

open(Config) ->
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, ?config(port, Config), [binary, {active, false}], 5000
    ),
    ok = gen_tcp:send(Sock, [
        ~"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", roadrunner_http2_frame:encode({settings, 0, []})
    ]),
    #{
        sock => Sock,
        buf => <<>>,
        enc => roadrunner_http2_hpack:new_encoder(4096),
        dec => roadrunner_http2_hpack:new_decoder(4096)
    }.

alloc(C, StreamId) ->
    {_, C1} = response(send_get(C, StreamId, ~"/alloc"), StreamId),
    receive
        {conn, _Worker} -> C1
    after 5000 -> ct:fail(no_alloc)
    end.

%% The `min_heap_size` the stream's worker started at.
report(C, StreamId) ->
    {Body, C1} = response(send_get(C, StreamId, ~"/report"), StreamId),
    {binary_to_integer(Body), C1}.

send_get(#{sock := Sock, enc := Enc} = C, StreamId, Path) ->
    Fields = [
        {~":method", ~"GET"},
        {~":scheme", ~"http"},
        {~":authority", ~"x"},
        {~":path", Path}
    ],
    {Block, Enc1} = roadrunner_http2_hpack:encode(Fields, Enc),
    %% END_HEADERS | END_STREAM
    ok = gen_tcp:send(
        Sock, roadrunner_http2_frame:encode({headers, StreamId, 16#05, undefined, Block})
    ),
    C#{enc := Enc1}.

%% Stream `StreamId`'s body, read until it ends.
response(C, StreamId) ->
    response(C, StreamId, <<>>).

response(C, StreamId, Body) ->
    case next_frame(C) of
        {{headers, StreamId, Flags, _Headers}, C1} when Flags band 16#01 =:= 0 ->
            response(C1, StreamId, Body);
        {{headers, StreamId, _Flags, _Headers}, C1} ->
            {Body, C1};
        {{data, StreamId, Flags, Data, _}, C1} ->
            case Flags band 16#01 of
                0 -> response(C1, StreamId, <<Body/binary, Data/binary>>);
                _ -> {<<Body/binary, Data/binary>>, C1}
            end;
        {_Other, C1} ->
            response(C1, StreamId, Body)
    end.

next_frame(#{sock := Sock, buf := Buf, dec := Dec} = C) ->
    case roadrunner_http2_frame:parse(Buf, 16384) of
        {ok, {headers, StreamId, Flags, _Priority, Block}, Rest} ->
            {ok, Headers, Dec1} = roadrunner_http2_hpack:decode(Block, Dec),
            {{headers, StreamId, Flags, Headers}, C#{buf := Rest, dec := Dec1}};
        {ok, Frame, Rest} ->
            {Frame, C#{buf := Rest}};
        _More ->
            {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
            next_frame(C#{buf := <<Buf/binary, Data/binary>>})
    end.
