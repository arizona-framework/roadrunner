-module(roadrunner_stream_heap_floor_SUITE).
-moduledoc """
The heap floor of HTTP/2 stream workers (`handler_spawn.heap_floor`): a
worker that collected raises its connection's floor, up to the cap, and the
workers after it start at that size; every 16th stream starts at half the
floor and lowers it to that when it runs without collecting. Over h2c, and
over HTTP/3 with the native test client (`roadrunner_quic_test_h3`), with
`roadrunner_heap_floor_handler`. A worker sets the floor as it ends, after
its response, so each case waits for a worker to end before the next
request.
""".

-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_testcase/2, end_per_testcase/2]).
-export([
    floor_rises_after_a_large_request/1,
    floor_rises_after_a_large_send_fun/1,
    floor_rises_after_short_lived_garbage/1,
    floor_rises_after_a_short_streamed_send_fun/1,
    floor_stops_at_the_cap/1,
    floor_off_under_a_max_heap_size/1,
    floor_off_follows_the_max_heap_size/1,
    spawn_follows_a_changed_default_max_heap_size/1,
    spawn_opts_put_the_floor_in_place_of_the_listener_min_heap_size/1,
    worker_at_the_cap_drops_its_min_heap_size/1,
    long_streams_leave_the_floor/1,
    long_send_streams_leave_the_floor/1,
    relearning_holds_a_large_request_to_the_cap/1,
    floor_off/1,
    floor_starts_at_the_spawn_min_heap_size/1,
    floor_off_when_the_cap_is_under_the_spawn_min_heap_size/1,
    floor_relearns_every_16_streams/1,
    smaller_need_leaves_a_higher_floor/1,
    h3_floor_rises_after_a_large_request/1,
    h3_floor_relearns_every_16_streams/1
]).

-define(H, roadrunner_heap_floor_handler).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        floor_rises_after_a_large_request,
        floor_rises_after_a_large_send_fun,
        floor_rises_after_short_lived_garbage,
        floor_rises_after_a_short_streamed_send_fun,
        floor_stops_at_the_cap,
        floor_off_under_a_max_heap_size,
        floor_off_follows_the_max_heap_size,
        spawn_follows_a_changed_default_max_heap_size,
        spawn_opts_put_the_floor_in_place_of_the_listener_min_heap_size,
        worker_at_the_cap_drops_its_min_heap_size,
        long_streams_leave_the_floor,
        long_send_streams_leave_the_floor,
        relearning_holds_a_large_request_to_the_cap,
        floor_off,
        floor_starts_at_the_spawn_min_heap_size,
        floor_off_when_the_cap_is_under_the_spawn_min_heap_size,
        floor_relearns_every_16_streams,
        smaller_need_leaves_a_higher_floor,
        h3_floor_rises_after_a_large_request,
        h3_floor_relearns_every_16_streams
    ].

init_per_testcase(Case, Config) ->
    {ok, _} = roadrunner_listener:start_link(
        ?MODULE,
        maps:merge(maps:merge(listener_opts(Case), protocol_opts(Case)), #{
            port => 0,
            routes => [
                {~"/alloc", ?H, {alloc, self()}},
                {~"/send_alloc", ?H, {send_alloc, self()}},
                {~"/gated", ?H, {gated_alloc, self()}},
                {~"/garbage", ?H, {garbage, self()}},
                {~"/heap", ?H, {heap, self()}},
                {~"/min_heap", ?H, {min_heap, self()}},
                {~"/stream_garbage", ?H, {stream_garbage, self()}},
                {~"/send_stream_garbage", ?H, {send_stream_garbage, self()}},
                {~"/send_stream_alloc", ?H, {send_stream_alloc, self()}}
            ]
        })
    ),
    [{port, roadrunner_listener:port(?MODULE)} | Config].

end_per_testcase(_Case, _Config) ->
    ok = roadrunner_listener:stop(?MODULE).

protocol_opts(Case) when
    Case =:= h3_floor_rises_after_a_large_request; Case =:= h3_floor_relearns_every_16_streams
->
    {ok, _} = application:ensure_all_started(ssl),
    #{protocols => [http3], tls => roadrunner_test_certs:server_opts()};
protocol_opts(_Case) ->
    #{protocols => [http2]}.

listener_opts(floor_stops_at_the_cap) ->
    #{handler_spawn => #{heap_floor => #{max => 1000}}};
listener_opts(floor_off_under_a_max_heap_size) ->
    %% `kill => false`: the 40,000-word request outgrows the limit.
    #{
        handler_spawn => #{
            opts => [
                {fullsweep_after, 0},
                {max_heap_size, #{size => 20000, kill => false, error_logger => false}}
            ]
        }
    };
listener_opts(relearning_holds_a_large_request_to_the_cap) ->
    #{
        handler_spawn => #{heap_floor => #{max => 1000}},
        max_header_count => 1000,
        max_header_list_size => 1000000
    };
listener_opts(floor_off) ->
    #{handler_spawn => #{heap_floor => false}};
listener_opts(floor_starts_at_the_spawn_min_heap_size) ->
    #{handler_spawn => #{opts => [{min_heap_size, 2000}]}};
listener_opts(floor_off_when_the_cap_is_under_the_spawn_min_heap_size) ->
    #{handler_spawn => #{opts => [{min_heap_size, 2000}], heap_floor => #{max => 1000}}};
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

%% A `{send, ...}` fun does the request's work after the handler returns:
%% the worker raises the floor once the fun has answered.
floor_rises_after_a_large_send_fun(Config) ->
    C = open(Config),
    {_, C1} = response(send_get(C, 3, ~"/send_alloc"), 3),
    ok = await_worker(),
    {Floor, _} = report(C1, 5),
    ?assert(Floor > base()),
    ?assert(Floor =< 46422).

%% A request that keeps little live ends with a small heap however often it
%% collected; that it collected is what raises the floor. Stream 1 relearns,
%% so it reads that from `garbage_collection_info`'s `recent_size` rather
%% than its heap's size.
floor_rises_after_short_lived_garbage(Config) ->
    C = open(Config),
    {_, C1} = response(send_get(C, 1, ~"/garbage"), 1),
    ok = await_worker(),
    {Floor, _} = report(C1, 3),
    ?assert(Floor > base()).

%% A `{send, ...}` fun whose streamed body took little work, as a gRPC
%% unary call's does, teaches the floor what it did after the body started.
floor_rises_after_a_short_streamed_send_fun(Config) ->
    C = open(Config),
    {_, C1} = response(send_get(C, 3, ~"/send_stream_alloc"), 3),
    ok = await_worker(),
    {Floor, _} = report(C1, 5),
    ?assert(Floor > rounded(5000)).

%% A worker started at the cap answers without reading its heap; the next
%% one starts at the cap too.
floor_stops_at_the_cap(Config) ->
    C = open(Config),
    C1 = alloc(C, 1),
    C2 = alloc(C1, 3),
    {Floor, _} = report(C2, 5),
    ?assertEqual(rounded(1000), Floor).

%% With a `max_heap_size` the floor is off: after a large request the
%% next worker still starts at the base.
floor_off_under_a_max_heap_size(Config) ->
    C = open(Config),
    C1 = alloc(C, 1),
    {Heap, C2} = report(C1, 3),
    ?assertEqual(base(), Heap),
    {Next, _} = report(C2, 5),
    ?assertEqual(base(), Next).

%% The listener's `max_heap_size`, in either form, or the emulator's
%% default turns the floor off; a size of 0 is no limit.
floor_off_follows_the_max_heap_size(_Config) ->
    Floor = fun(SpawnOpts) ->
        roadrunner_stream_worker:conn_heap_floor(
            roadrunner_test_proto_opts:new(#{
                heap_floor => 46422, handler_spawn_opts => SpawnOpts
            })
        )
    end,
    ?assertEqual(undefined, Floor([{max_heap_size, 20000}])),
    ?assertEqual(undefined, Floor([{max_heap_size, #{size => 20000}}])),
    ?assertMatch({_, _, 46422}, Floor([{max_heap_size, #{size => 0}}])),
    %% The spawn applies the last of repeated options, and so does the check.
    ?assertEqual(undefined, Floor([{max_heap_size, 0}, {max_heap_size, 50000}])),
    ?assertMatch({_, _, 46422}, Floor([{max_heap_size, 50000}, {max_heap_size, 0}])),
    ?assertMatch({_, _, 46422}, Floor([])),
    Default = erlang:system_flag(max_heap_size, 30000),
    try
        ?assertEqual(undefined, Floor([])),
        ?assertMatch({_, _, 46422}, Floor([{max_heap_size, 0}]))
    after
        erlang:system_flag(max_heap_size, Default)
    end.

%% The emulator's default `max_heap_size` set while a connection lives
%% applies at the next spawn: a worker spawned while it is set gets no
%% floor, and one spawned after it is cleared gets the floor again.
spawn_follows_a_changed_default_max_heap_size(_Config) ->
    HeapFloor = {atomics:new(1, []), 40000, base(), 46422, false},
    ProtoOpts = proto_opts([]),
    SpawnOpts = fun() -> roadrunner_stream_worker:spawn_opts(ProtoOpts, HeapFloor) end,
    ?assertEqual([monitor, {min_heap_size, 40000}], SpawnOpts()),
    Default = erlang:system_flag(max_heap_size, 30000),
    try
        ?assertEqual([monitor], SpawnOpts()),
        {Pid, Ref} = spawn_opt(fun() -> ok end, SpawnOpts()),
        receive
            {'DOWN', Ref, process, Pid, normal} -> ok
        end
    after
        erlang:system_flag(max_heap_size, Default)
    end,
    ?assertEqual([monitor, {min_heap_size, 40000}], SpawnOpts()).

%% The floor takes the place of the listener's own `min_heap_size`, and a
%% listener `max_heap_size` of 0 (no limit) keeps the floor whatever the
%% emulator's default.
spawn_opts_put_the_floor_in_place_of_the_listener_min_heap_size(_Config) ->
    HeapFloor = {atomics:new(1, []), 40000, base(), 46422, false},
    Listener = [{min_heap_size, 1000}, {fullsweep_after, 0}, {max_heap_size, 0}],
    ProtoOpts = proto_opts(Listener),
    ?assertEqual(
        {own_max_heap_size, [{fullsweep_after, 0}, {max_heap_size, 0}]},
        roadrunner_test_proto_opts:get(floor_spawn_opts, ProtoOpts)
    ),
    Default = erlang:system_flag(max_heap_size, 30000),
    try
        ?assertEqual(
            [monitor, {min_heap_size, 40000}, {fullsweep_after, 0}, {max_heap_size, 0}],
            roadrunner_stream_worker:spawn_opts(ProtoOpts, HeapFloor)
        )
    after
        erlang:system_flag(max_heap_size, Default)
    end,
    %% At the base, or with no floor, the listener's options go as they are.
    ?assertEqual(
        [monitor | Listener],
        roadrunner_stream_worker:spawn_opts(
            ProtoOpts, {atomics:new(1, []), base(), base(), 46422, false}
        )
    ),
    ?assertEqual(
        [monitor | Listener],
        roadrunner_stream_worker:spawn_opts(ProtoOpts, undefined)
    ).

%% Connection options with `SpawnOpts` as the listener's `handler_spawn`
%% options, made ready for a floor as the listener does.
proto_opts(SpawnOpts) ->
    roadrunner_test_proto_opts:new(#{
        handler_spawn_opts => SpawnOpts,
        floor_spawn_opts => roadrunner_stream_worker:floor_spawn_opts(SpawnOpts)
    }).

%% A worker started at the cap lowers its `min_heap_size` to the base, so
%% one that lives on does not hold the cap's heap after it collects.
worker_at_the_cap_drops_its_min_heap_size(Config) ->
    C = open(Config),
    C1 = alloc(C, 1),
    {Floor, C2} = report(C1, 3),
    ?assertEqual(46422, Floor),
    {MinHeap, _} = min_heap(C2, 5),
    ?assertEqual(base(), MinHeap).

%% A streamed body collects however large the floor: only what the handler
%% did before it started teaches the floor, so 17 streams that each make
%% about 160,000 words of garbage leave it at most a step or two over the
%% base (a worker can still collect at the base before its body starts).
long_streams_leave_the_floor(Config) ->
    long_streams(Config, ~"/stream_garbage").

%% The same for a `{send, ...}` fun that streams its body.
long_send_streams_leave_the_floor(Config) ->
    long_streams(Config, ~"/send_stream_garbage").

long_streams(Config, Path) ->
    C = open(Config),
    C1 = lists:foldl(
        fun(Id, Acc) ->
            {_, Acc1} = response(send_get(Acc, Id, Path), Id),
            ok = await_worker(),
            Acc1
        end,
        C,
        lists:seq(1, 33, 2)
    ),
    {Floor, _} = report(C1, 35),
    ?assert(Floor =< 610).

%% Stream 1 relearns at the base. Spawned with a request of 180
%% headers, its worker starts above the cap; running without collecting, it
%% lowers the floor to the cap, not to that size.
relearning_holds_a_large_request_to_the_cap(Config) ->
    C = open(Config),
    Extra = [
        {<<"x-header-", (integer_to_binary(N))/binary>>, binary:copy(~"v", 40)}
     || N <- lists:seq(1, 180)
    ],
    {Body, C1} = response(send_get(C, 1, ~"/heap", Extra), 1),
    ok = await_worker(),
    ?assert(binary_to_integer(Body) > rounded(1000)),
    {Floor, _} = report(C1, 3),
    ?assertEqual(rounded(1000), Floor).

floor_off(Config) ->
    C = open(Config),
    C1 = alloc(C, 1),
    {_, C2} = response(send_get(C1, 3, ~"/send_stream_alloc"), 3),
    ok = await_worker(),
    {Floor, _} = report(C2, 5),
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

%% Stream 33 is the 17th: it starts at half the floor and, running without
%% collecting, lowers the floor to that.
floor_relearns_every_16_streams(Config) ->
    C = open(Config),
    C1 = alloc(C, 1),
    {Floors, C2} = lists:mapfoldl(fun(Id, Acc) -> report(Acc, Id) end, C1, lists:seq(3, 31, 2)),
    ?assertEqual([46422], lists:usort(Floors)),
    {Relearned, C3} = report(C2, 33),
    ?assertEqual(rounded(46422 div 2), Relearned),
    {Next, _} = report(C3, 35),
    ?assertEqual(Relearned, Next).

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
    ok = await_down(Gated),
    {After, _} = report(C4, 7),
    ?assertEqual(Floor, After).

%% HTTP/3 request streams count up by 4 (0, 4, 8, ...); the first one
%% relearns, from half the base floor: the base.
h3_floor_rises_after_a_large_request(Config) ->
    Conn = h3_connect(Config),
    ?assertEqual(base(), h3_report(Conn)),
    ok = h3_alloc(Conn),
    Floor = h3_report(Conn),
    ?assert(Floor > base()),
    ?assert(Floor =< 46422),
    ok = roadrunner_quic_test_h3:close(Conn).

%% Stream 64 is the 17th: it starts at half the floor.
h3_floor_relearns_every_16_streams(Config) ->
    Conn = h3_connect(Config),
    ok = h3_alloc(Conn),
    Floors = [h3_report(Conn) || _ <- lists:seq(2, 16)],
    ?assertEqual([46422], lists:usort(Floors)),
    ?assertEqual(rounded(46422 div 2), h3_report(Conn)),
    ok = roadrunner_quic_test_h3:close(Conn).

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
    ok = await_worker(),
    C1.

%% The heap the stream's worker started at.
report(C, StreamId) ->
    {Body, C1} = response(send_get(C, StreamId, ~"/heap"), StreamId),
    ok = await_worker(),
    {binary_to_integer(Body), C1}.

%% The `min_heap_size` the stream's worker runs with.
min_heap(C, StreamId) ->
    {Body, C1} = response(send_get(C, StreamId, ~"/min_heap"), StreamId),
    ok = await_worker(),
    {binary_to_integer(Body), C1}.

%% Waits for the worker that just answered to end, having set the floor.
await_worker() ->
    receive
        {conn, Worker} -> await_down(Worker)
    after 5000 -> ct:fail(no_worker)
    end.

await_down(Worker) ->
    MRef = monitor(process, Worker),
    receive
        {'DOWN', MRef, process, Worker, _} -> ok
    after 5000 -> ct:fail(worker_alive)
    end.

send_get(C, StreamId, Path) ->
    send_get(C, StreamId, Path, []).

send_get(#{sock := Sock, enc := Enc} = C, StreamId, Path, Extra) ->
    Fields = [
        {~":method", ~"GET"},
        {~":scheme", ~"http"},
        {~":authority", ~"x"},
        {~":path", Path}
        | Extra
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

h3_connect(Config) ->
    {ok, Conn} = roadrunner_quic_test_h3:connect({127, 0, 0, 1}, ?config(port, Config)),
    Conn.

h3_alloc(Conn) ->
    {200, _Headers, _Body} = roadrunner_quic_test_h3:get(Conn, ~"/alloc"),
    await_worker().

%% The heap the stream's worker started at.
h3_report(Conn) ->
    {200, _Headers, Body} = roadrunner_quic_test_h3:get(Conn, ~"/heap"),
    ok = await_worker(),
    binary_to_integer(Body).
