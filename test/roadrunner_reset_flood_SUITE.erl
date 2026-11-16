-module(roadrunner_reset_flood_SUITE).
-moduledoc """
A client that resets its requests while their handlers still run (the
HTTP/2 rapid reset attack, CVE-2023-44487) gets no more handlers running
at once on a connection than the connection's stream limit. The handler
(`roadrunner_h2_slot_handler`) announces itself and runs until released, ignoring the reset, so each one stands for work a
client abandons.
""".

-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([
    h2_reset_handlers_hold_the_stream_limit/1,
    h2_slot_frees_when_a_reset_handler_ends/1,
    h2_reset_flood_gets_goaway/1,
    h2_client_with_open_streams_is_only_refused/1,
    h2_reset_at_a_normal_rate_is_served/1,
    h2_reset_of_an_answered_stream_frees_it/1
]).

-define(MAX_STREAMS, 4).
-define(COLLECTOR, roadrunner_h2_slot_collector).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        h2_reset_handlers_hold_the_stream_limit,
        h2_slot_frees_when_a_reset_handler_ends,
        h2_reset_flood_gets_goaway,
        h2_client_with_open_streams_is_only_refused,
        h2_reset_at_a_normal_rate_is_served,
        h2_reset_of_an_answered_stream_frees_it
    ].

init_per_testcase(_Case, Config) ->
    true = register(?COLLECTOR, self()),
    {ok, _} = roadrunner_listener:start_link(?MODULE, listener_opts()),
    [{port, roadrunner_listener:port(?MODULE)} | Config].

end_per_testcase(_Case, _Config) ->
    ok = roadrunner_listener:stop(?MODULE),
    true = unregister(?COLLECTOR),
    ok.

listener_opts() ->
    #{
        port => 0,
        protocols => [{http2, #{max_concurrent_streams => ?MAX_STREAMS}}],
        routes => [
            {~"/", roadrunner_h2_slot_handler},
            {~"/answered", roadrunner_answer_then_hold_handler}
        ]
    }.

%% =============================================================================
%% HTTP/2
%% =============================================================================

h2_reset_handlers_hold_the_stream_limit(Config) ->
    %% Eight requests, each reset at once: only the first four start a
    %% handler, which keeps running after its reset; the rest are refused
    %% (retry-safe REFUSED_STREAM, RFC 9113 §8.7) until one of them ends.
    Ids = stream_ids(1, 2 * ?MAX_STREAMS),
    C0 = lists:foldl(fun(Id, C) -> send_rst(send_headers(C, Id), Id) end, open(Config), Ids),
    {Frames, _C1} = ping_sync(C0),
    Handlers = handlers_started(?MAX_STREAMS),
    ?assert(lists:all(fun erlang:is_process_alive/1, Handlers)),
    ?assertEqual(
        [{rst_stream, Id, refused_stream} || Id <- lists:nthtail(?MAX_STREAMS, Ids)],
        [F || {rst_stream, _, _} = F <- Frames]
    ),
    ?assertEqual([], [F || {goaway, _, _, _} = F <- Frames]),
    release(Handlers).

h2_slot_frees_when_a_reset_handler_ends(Config) ->
    %% A reset handler gives its stream back when it ends: the next request
    %% is served.
    C = fill_with_reset_handlers(open(Config)),
    [First | Rest] = handlers_started(?MAX_STREAMS),
    Over = 2 * ?MAX_STREAMS + 1,
    {Frames, C0} = ping_sync(send_headers(C, Over)),
    ?assertEqual([{rst_stream, Over, refused_stream}], [F || {rst_stream, _, _} = F <- Frames]),
    Ref = monitor(process, First),
    First ! release,
    receive
        {'DOWN', Ref, process, First, _} -> ok
    end,
    {Id, C1} = admitted(C0, Over + 2),
    [Next] = handlers_started(1),
    Next ! release,
    ?assertMatch({200, _, _}, response(C1, Id)),
    release(Rest).

h2_reset_flood_gets_goaway(Config) ->
    %% With the limit held by handlers whose streams were reset, a client
    %% that keeps opening streams past it is refused up to the limit's worth
    %% of times, then told to calm down (RFC 9113 §5.4.1, §7) and closed.
    C0 = fill_with_reset_handlers(open(Config)),
    Handlers = handlers_started(?MAX_STREAMS),
    Refused = stream_ids(2 * ?MAX_STREAMS + 1, ?MAX_STREAMS),
    Over = 4 * ?MAX_STREAMS + 1,
    C1 = lists:foldl(fun(Id, C) -> send_headers(C, Id) end, C0, Refused ++ [Over]),
    {Frames, _C2} = until(C1, fun
        ({goaway, _, _, _}) -> true;
        (_) -> false
    end),
    ?assertEqual(
        [{rst_stream, Id, refused_stream} || Id <- Refused],
        [F || {rst_stream, _, _} = F <- Frames]
    ),
    ?assertMatch({goaway, 2 * ?MAX_STREAMS - 1, enhance_your_calm, _}, lists:last(Frames)),
    release(Handlers).

h2_client_with_open_streams_is_only_refused(Config) ->
    %% One reset handler and three streams the client still waits on fill
    %% the limit. The client may well have opened more before it learnt the
    %% reset stream still counts, so it is only refused, however often, and
    %% its open streams are served.
    Open = stream_ids(1, ?MAX_STREAMS - 1),
    Reset = 2 * ?MAX_STREAMS - 1,
    C0 = lists:foldl(fun(Id, C) -> send_headers(C, Id) end, open(Config), Open),
    C1 = send_rst(send_headers(C0, Reset), Reset),
    Handlers = handlers_started(?MAX_STREAMS),
    Refused = stream_ids(2 * ?MAX_STREAMS + 1, 2 * ?MAX_STREAMS),
    C2 = lists:foldl(fun(Id, C) -> send_headers(C, Id) end, C1, Refused),
    {Frames, C3} = ping_sync(C2),
    ?assertEqual(
        [{rst_stream, Id, refused_stream} || Id <- Refused],
        [F || {rst_stream, _, _} = F <- Frames]
    ),
    ?assertEqual([], [F || {goaway, _, _, _} = F <- Frames]),
    release(Handlers),
    ?assertMatch({200, _, _}, response(C3, hd(Open))).

h2_reset_at_a_normal_rate_is_served(Config) ->
    %% A client that resets one request at a time, each handler ending
    %% before the next request, is served every time: no refusal, no GOAWAY,
    %% however many it resets over the connection's life.
    C = lists:foldl(
        fun(Id, C0) ->
            C1 = send_headers(C0, Id),
            [Handler] = handlers_started(1),
            C2 = send_rst(C1, Id),
            {_, C3} = ping_sync(C2),
            ok = stop(Handler),
            C3
        end,
        open(Config),
        stream_ids(1, 4 * ?MAX_STREAMS)
    ),
    Id = 8 * ?MAX_STREAMS + 1,
    C1 = send_headers(C, Id),
    [Handler] = handlers_started(1),
    Handler ! release,
    ?assertMatch({200, _, _}, response(C1, Id)).

h2_reset_of_an_answered_stream_frees_it(Config) ->
    %% A stream whose response is complete no longer counts toward the
    %% limit (RFC 9113 §5.1.2), even while its handler still runs; a reset
    %% from the client, sent before it saw the end, does not make it count
    %% again.
    {C0, Handlers} = lists:foldl(
        fun(Id, {C, Acc}) ->
            C1 = send_headers(C, Id, ~"/answered"),
            {200, ~"ok", C2} = response(C1, Id),
            [Handler] = handlers_started(1),
            {send_rst(C2, Id), [Handler | Acc]}
        end,
        {open(Config), []},
        stream_ids(1, ?MAX_STREAMS)
    ),
    Id = 2 * ?MAX_STREAMS + 1,
    C1 = send_headers(C0, Id),
    [Handler] = handlers_started(1),
    Handler ! release,
    {200, ~"ok", C2} = response(C1, Id),
    lists:foreach(fun(H) -> ok = stop(H) end, Handlers),
    {_, _} = ping_sync(C2).

%% =============================================================================
%% Helpers
%% =============================================================================

%% `Count` odd stream ids from `First`.
stream_ids(First, Count) ->
    [First + 2 * N || N <- lists:seq(0, Count - 1)].

%% Open the connection's whole stream limit and reset every stream while
%% its handler runs.
fill_with_reset_handlers(C0) ->
    Ids = stream_ids(1, ?MAX_STREAMS),
    C1 = lists:foldl(fun(Id, C) -> send_rst(send_headers(C, Id), Id) end, C0, Ids),
    {Frames, C2} = ping_sync(C1),
    [] = [F || {rst_stream, _, _} = F <- Frames],
    C2.

%% Open stream `Id` once the connection has taken the end of a reset
%% handler in: until then it is refused, and the next id is tried.
admitted(C0, Id) ->
    C1 = send_headers(C0, Id),
    {Frames, C2} = ping_sync(C1),
    case [F || {rst_stream, StreamId, _} = F <- Frames, StreamId =:= Id] of
        [] -> {Id, C2};
        [{rst_stream, Id, refused_stream}] -> admitted(C2, Id + 2)
    end.

handlers_started(0) ->
    [];
handlers_started(N) ->
    receive
        {handler_started, Pid} -> [Pid | handlers_started(N - 1)]
    after 5000 -> ct:fail({handlers_not_started, N})
    end.

release(Handlers) ->
    lists:foreach(fun(Pid) -> Pid ! release end, Handlers).

%% Release a handler and wait for it to end.
stop(Handler) ->
    Ref = monitor(process, Handler),
    Handler ! release,
    receive
        {'DOWN', Ref, process, Handler, _} -> ok
    end.

%% --- HTTP/2 client ---

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

%% A GET with END_STREAM: its handler starts at once.
send_headers(C, StreamId) ->
    send_headers(C, StreamId, ~"/").

send_headers(#{sock := Sock, enc := Enc} = C, StreamId, Path) ->
    Fields = [
        {~":method", ~"GET"},
        {~":scheme", ~"http"},
        {~":authority", ~"x"},
        {~":path", Path}
    ],
    {Block, Enc1} = roadrunner_http2_hpack:encode(Fields, Enc),
    ok = gen_tcp:send(
        Sock, roadrunner_http2_frame:encode({headers, StreamId, 16#05, undefined, Block})
    ),
    C#{enc := Enc1}.

send_rst(#{sock := Sock} = C, StreamId) ->
    ok = gen_tcp:send(Sock, roadrunner_http2_frame:encode({rst_stream, StreamId, cancel})),
    C.

%% Send a PING and collect every frame up to its ACK: the server handles
%% frames in order, so what it does about the frames sent before the PING
%% comes back first.
ping_sync(#{sock := Sock} = C) ->
    ok = gen_tcp:send(Sock, roadrunner_http2_frame:encode({ping, 0, <<1:64>>})),
    until(C, fun
        ({ping, 1, _}) -> true;
        (_) -> false
    end).

%% Stream `StreamId`'s status and body, and the connection after them.
response(C, StreamId) ->
    response(C, StreamId, undefined, <<>>).

response(C, StreamId, Status, Body) ->
    case next_frame(C) of
        {{headers, StreamId, Flags, Headers}, C1} ->
            {_, S} = lists:keyfind(~":status", 1, Headers),
            Status1 = binary_to_integer(S),
            case Flags band 16#01 of
                0 -> response(C1, StreamId, Status1, Body);
                _ -> {Status1, Body, C1}
            end;
        {{data, StreamId, Flags, Data, _}, C1} ->
            Body1 = <<Body/binary, Data/binary>>,
            case Flags band 16#01 of
                0 -> response(C1, StreamId, Status, Body1);
                _ -> {Status, Body1, C1}
            end;
        {_Other, C1} ->
            response(C1, StreamId, Status, Body)
    end.

until(C, Pred) ->
    until(C, Pred, []).

until(C, Pred, Acc) ->
    {Frame, C1} = next_frame(C),
    case Pred(Frame) of
        true -> {lists:reverse([Frame | Acc]), C1};
        false -> until(C1, Pred, [Frame | Acc])
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
