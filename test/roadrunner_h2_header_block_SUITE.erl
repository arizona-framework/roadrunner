-module(roadrunner_h2_header_block_SUITE).
-moduledoc """
An HTTP/2 request whose header block is over `max_header_block` but within
the `SETTINGS_MAX_HEADER_LIST_SIZE` the server advertises is refused on its
own stream with a `431`, and the connection serves on: its block is still
decoded, so the HPACK state stays in step with the client's. A block past
the larger of the two limits closes the connection (the CONTINUATION flood
guard).
""".

-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([
    block_over_cap_gets_431_and_the_conn_serves_on/1,
    block_over_the_list_size_gets_goaway/1
]).

-define(MAX_FRAME_SIZE, 16384).
-define(MAX_HEADER_BLOCK, 16384).
-define(MAX_HEADER_LIST_SIZE, 32768).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        block_over_cap_gets_431_and_the_conn_serves_on,
        block_over_the_list_size_gets_goaway
    ].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_Case, Config) ->
    {ok, _} = roadrunner_listener:start_link(?MODULE, #{
        port => 0,
        protocols => [{http2, #{}}],
        routes => [{~"/sync-check", roadrunner_h2_test_handler}]
    }),
    [{port, roadrunner_listener:port(?MODULE)} | Config].

end_per_testcase(_Case, _Config) ->
    ok = roadrunner_listener:stop(?MODULE).

%% =============================================================================
%% Cases
%% =============================================================================

block_over_cap_gets_431_and_the_conn_serves_on(Config) ->
    %% Stream 1 waits for its body while stream 3 sends a block of ~20 KB
    %% (over the 16 KB `max_header_block`, under the advertised 32 KB list
    %% size). Stream 3 alone gets a 431, then stream 1 is served. Stream 3's
    %% block puts `x-sync` in the HPACK dynamic table after a large field
    %% has emptied it, and stream 5 refers to that entry: it decodes only if
    %% the server decoded the refused block too.
    C0 = open(Config),
    C1 = send_block(C0, 1, 0, request(~"POST", [])),
    {Big, C2} = encode(C1, request(~"GET", [{~"x-big", big_value(20_000)}, {~"x-sync", ~"s1"}])),
    ?assert(byte_size(Big) > ?MAX_HEADER_BLOCK),
    ?assert(byte_size(Big) < ?MAX_HEADER_LIST_SIZE),
    C3 = send_encoded(C2, 3, 16#01, Big),
    {431, ~"Request Header Fields Too Large", C4} = response(C3, 3),
    {Frames, C5} = until(C4, fun
        ({rst_stream, 3, _}) -> true;
        (_) -> false
    end),
    ?assertEqual({rst_stream, 3, no_error}, lists:last(Frames)),
    C6 = send_data(C5, 1, ~"body"),
    {200, ~"ok", C7} = response(C6, 1),
    {Sync, C8} = encode(C7, request(~"GET", [{~"x-sync", ~"s1"}])),
    %% `x-sync: s1` goes as a one-byte reference into the dynamic table.
    ?assertEqual(nomatch, binary:match(Sync, ~"x-sync")),
    C9 = send_encoded(C8, 5, 16#01, Sync),
    ?assertMatch({200, ~"ok", _}, response(C9, 5)).

block_over_the_list_size_gets_goaway(Config) ->
    %% A block that grows past the advertised list size, which no client
    %% keeping to it sends, is not read to its end: the connection is
    %% closed with GOAWAY(ENHANCE_YOUR_CALM).
    C0 = send_block(open(Config), 1, 16#01, request(~"GET", [])),
    {200, ~"ok", C1} = response(C0, 1),
    C2 = send_block(C1, 3, 16#01, request(~"GET", [{~"x-big", big_value(40_000)}])),
    {Frames, C3} = until(C2, fun
        ({goaway, _, _, _}) -> true;
        (_) -> false
    end),
    ?assertMatch({goaway, _, enhance_your_calm, _}, lists:last(Frames)),
    ?assertEqual({error, closed}, gen_tcp:recv(maps:get(sock, C3), 0, 5000)).

%% =============================================================================
%% HTTP/2 client
%% =============================================================================

request(Method, Extra) ->
    [
        {~":method", Method},
        {~":scheme", ~"http"},
        {~":authority", ~"localhost"},
        {~":path", ~"/sync-check"}
        | Extra
    ].

%% Printable, so it is a valid field value.
big_value(Size) ->
    binary:part(binary:copy(~"abcdefghijklmnopqrstuvwxyz0123456789", Size div 36 + 1), 0, Size).

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

encode(#{enc := Enc} = C, Fields) ->
    {Block, Enc1} = roadrunner_http2_hpack:encode(Fields, Enc),
    {iolist_to_binary(Block), C#{enc := Enc1}}.

send_block(C0, StreamId, Flags, Fields) ->
    {Block, C1} = encode(C0, Fields),
    send_encoded(C1, StreamId, Flags, Block).

%% A HEADERS frame and as many CONTINUATION frames as the block needs, the
%% last with END_HEADERS.
send_encoded(#{sock := Sock} = C, StreamId, Flags, Block) ->
    ok = gen_tcp:send(Sock, header_frames(StreamId, Flags, Block, headers)),
    C.

header_frames(StreamId, Flags, Block, Type) when byte_size(Block) =< ?MAX_FRAME_SIZE ->
    [header_frame(Type, StreamId, Flags bor 16#04, Block)];
header_frames(StreamId, Flags, <<Chunk:?MAX_FRAME_SIZE/binary, Rest/binary>>, Type) ->
    [header_frame(Type, StreamId, Flags, Chunk) | header_frames(StreamId, 0, Rest, continuation)].

header_frame(headers, StreamId, Flags, Fragment) ->
    roadrunner_http2_frame:encode({headers, StreamId, Flags, undefined, Fragment});
header_frame(continuation, StreamId, Flags, Fragment) ->
    roadrunner_http2_frame:encode({continuation, StreamId, Flags, Fragment}).

send_data(#{sock := Sock} = C, StreamId, Data) ->
    ok = gen_tcp:send(Sock, roadrunner_http2_frame:encode({data, StreamId, 16#01, Data})),
    C.

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
    case roadrunner_http2_frame:parse(Buf, ?MAX_FRAME_SIZE) of
        {ok, {headers, StreamId, Flags, _Priority, Block}, Rest} ->
            {ok, Headers, Dec1} = roadrunner_http2_hpack:decode(Block, Dec),
            {{headers, StreamId, Flags, Headers}, C#{buf := Rest, dec := Dec1}};
        {ok, Frame, Rest} ->
            {Frame, C#{buf := Rest}};
        _More ->
            {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
            next_frame(C#{buf := <<Buf/binary, Data/binary>>})
    end.
