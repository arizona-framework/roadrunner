-module(roadrunner_h2_manual_body_SUITE).
-moduledoc """
Manual body mode over HTTP/2 (h2c): the worker starts at the end of the
headers and reads the body as DATA arrives, the stream's receive window
refilled only as it reads. The handler is `roadrunner_manual_body_handler`;
each route's state picks what it does with the body.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_testcase/2, end_per_testcase/2]).
-export([
    reads_the_body/1,
    reads_in_pieces/1,
    reads_chunk_by_chunk/1,
    reads_data_as_it_arrives/1,
    reads_nothing_without_a_body/1,
    trailers_end_the_body/1,
    answers_before_the_body/1,
    expect_continue_asks_on_the_first_read/1,
    streamed_answer_asks_for_the_body_first/1,
    read_then_streamed_answer_gets_one_100/1,
    expect_continue_rejected_on_the_headers/1,
    expect_continue_over_the_cap/1,
    body_over_the_cap_fails_the_read/1,
    route_cap_holds_the_read/1,
    stream_window_waits_for_the_reader/1,
    content_length_overrun_resets/1,
    content_length_shortfall_resets/1,
    malformed_content_length_resets/1,
    reset_while_reading/1,
    reset_before_reading/1,
    read_times_out/1,
    body_after_the_answer_is_dropped/1
]).

-define(H, roadrunner_manual_body_handler).
-define(GATED, roadrunner_h2_manual_gated).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        reads_the_body,
        reads_in_pieces,
        reads_chunk_by_chunk,
        reads_data_as_it_arrives,
        reads_nothing_without_a_body,
        trailers_end_the_body,
        answers_before_the_body,
        expect_continue_asks_on_the_first_read,
        streamed_answer_asks_for_the_body_first,
        read_then_streamed_answer_gets_one_100,
        expect_continue_rejected_on_the_headers,
        expect_continue_over_the_cap,
        body_over_the_cap_fails_the_read,
        route_cap_holds_the_read,
        stream_window_waits_for_the_reader,
        content_length_overrun_resets,
        content_length_shortfall_resets,
        malformed_content_length_resets,
        reset_while_reading,
        reset_before_reading,
        read_times_out,
        body_after_the_answer_is_dropped
    ].

init_per_testcase(Case, Config) ->
    {ok, _} = roadrunner_test_event_handler:start(),
    {ok, _} = roadrunner_listener:start_link(
        ?MODULE,
        maps:merge(
            #{
                port => 0,
                protocols => [http2],
                body_buffering => manual,
                max_content_length => 64,
                routes => routes(self())
            },
            extra(Case)
        )
    ),
    [{port, roadrunner_listener:port(?MODULE)} | Config].

end_per_testcase(_Case, _Config) ->
    case whereis(?GATED) of
        undefined -> ok;
        Pid -> exit(Pid, kill)
    end,
    ok = roadrunner_listener:stop(?MODULE).

extra(read_times_out) -> #{request_timeout => 100};
extra(_Case) -> #{}.

routes(TestPid) ->
    [
        {~"/read", ?H, read},
        {~"/reject", ?H, reject},
        {~"/pieces", ?H, pieces},
        {~"/chunks", ?H, chunks},
        #{path => ~"/gated", handler => ?H, state => {gated, ?GATED}, max_content_length => 100000},
        {~"/report", ?H, {report, TestPid}},
        {~"/gated-report", ?H, {gated_report, ?GATED, TestPid}},
        {~"/answer-first", ?H, {answer_first, ?GATED, TestPid}},
        {~"/stream-echo", ?H, stream_echo},
        {~"/read-then-stream", ?H, read_then_stream},
        #{path => ~"/small", handler => ?H, state => read, max_content_length => 2}
    ].

%% =============================================================================
%% Reading
%% =============================================================================

reads_the_body(Config) ->
    C0 = send_headers(open(Config), 1, ~"/read", [], false),
    C1 = send_data(C0, 1, ~"hello", true),
    ?assertMatch({[200], ~"5", end_stream, _}, response(C1, 1)).

reads_in_pieces(Config) ->
    %% 4 bytes a read across DATA boundaries: 4 + 4 + 2.
    C0 = send_headers(open(Config), 1, ~"/pieces", [], false),
    C1 = send_data(send_data(C0, 1, ~"hello", false), 1, ~"world", true),
    ?assertMatch({[200], ~"3:10", end_stream, _}, response(C1, 1)).

reads_chunk_by_chunk(Config) ->
    C0 = send_headers(open(Config), 1, ~"/chunks", [], false),
    C1 = send_data(send_data(C0, 1, ~"hello", false), 1, ~"world", true),
    {[200], Body, end_stream, _} = response(C1, 1),
    ?assertMatch([_, ~"10"], binary:split(Body, ~":")).

reads_data_as_it_arrives(Config) ->
    %% The 100 shows the handler's read is waiting: each DATA then reaches it
    %% as it arrives, before the body ends.
    C0 = send_headers(open(Config), 1, ~"/read", [{~"expect", ~"100-continue"}], false),
    {[100], <<>>, interim, C1} = response(C0, 1),
    {_, C2} = ping_sync(send_data(C1, 1, ~"hello", false)),
    C3 = send_data(C2, 1, ~"world", true),
    ?assertMatch({[200], ~"10", end_stream, _}, response(C3, 1)).

reads_nothing_without_a_body(Config) ->
    C = send_headers(open(Config), 1, ~"/read", [], true),
    ?assertMatch({[200], ~"0", end_stream, _}, response(C, 1)).

trailers_end_the_body(Config) ->
    C0 = send_headers(open(Config), 1, ~"/read", [], false),
    C1 = send_trailers(send_data(C0, 1, ~"hello", false), 1),
    ?assertMatch({[200], ~"5", end_stream, _}, response(C1, 1)).

%% =============================================================================
%% Answering before the body
%% =============================================================================

answers_before_the_body(Config) ->
    %% The worker starts with the headers, answers without reading, and the
    %% client is asked to stop sending (RFC 9113 §8.1).
    C0 = send_headers(open(Config), 1, ~"/reject", [], false),
    {[401], ~"no", end_stream, C1} = response(C0, 1),
    ?assertMatch({no_error, _}, rst(C1, 1)).

expect_continue_asks_on_the_first_read(Config) ->
    C0 = send_headers(open(Config), 1, ~"/read", [{~"expect", ~"100-continue"}], false),
    {[100], <<>>, interim, C1} = response(C0, 1),
    C2 = send_data(C1, 1, ~"hello", true),
    ?assertMatch({[200], ~"5", end_stream, _}, response(C2, 1)).

streamed_answer_asks_for_the_body_first(Config) ->
    %% The handler starts a streamed answer before it reads the body: the 100
    %% comes first, not after the 200.
    C0 = send_headers(open(Config), 1, ~"/stream-echo", [{~"expect", ~"100-continue"}], false),
    {[100], <<>>, interim, C1} = response(C0, 1),
    C2 = send_data(C1, 1, ~"hello", true),
    ?assertMatch({[200], ~"hello", end_stream, _}, response(C2, 1)).

read_then_streamed_answer_gets_one_100(Config) ->
    %% The read asks for the body; the streamed answer after it sends no
    %% second 100.
    C0 = send_headers(open(Config), 1, ~"/read-then-stream", [{~"expect", ~"100-continue"}], false),
    {[100], <<>>, interim, C1} = response(C0, 1),
    C2 = send_data(C1, 1, ~"hello", true),
    ?assertMatch({[200], ~"hello", end_stream, _}, response(C2, 1)).

expect_continue_rejected_on_the_headers(Config) ->
    %% No 100: the 401 is the first answer, and the body is never asked for.
    Expect = [{~"expect", ~"100-continue"}, {~"content-length", ~"5"}],
    C0 = send_headers(open(Config), 1, ~"/reject", Expect, false),
    {[401], ~"no", end_stream, C1} = response(C0, 1),
    ?assertMatch({no_error, _}, rst(C1, 1)).

expect_continue_over_the_cap(Config) ->
    %% Over the cap on the declared length alone: 413 at once, no worker.
    Expect = [{~"expect", ~"100-continue"}, {~"content-length", ~"100"}],
    C = send_headers(open(Config), 1, ~"/read", Expect, false),
    ?assertMatch({[413], _, end_stream, _}, response(C, 1)).

%% =============================================================================
%% Caps
%% =============================================================================

body_over_the_cap_fails_the_read(Config) ->
    %% The handler sees the failed read and answers.
    C0 = send_headers(open(Config), 1, ~"/read", [], false),
    C1 = send_data(C0, 1, binary:copy(~"x", 100), true),
    ?assertMatch({[413], ~"content_length_too_large", end_stream, _}, response(C1, 1)).

route_cap_holds_the_read(Config) ->
    C0 = send_headers(open(Config), 1, ~"/small", [], false),
    C1 = send_data(C0, 1, ~"hello", true),
    ?assertMatch({[413], ~"content_length_too_large", end_stream, _}, response(C1, 1)).

stream_window_waits_for_the_reader(Config) ->
    %% 40000 bytes take the stream's window below its refill threshold. Until
    %% the handler reads them the stream's window stays spent; once it does,
    %% the window comes back.
    C0 = send_headers(open(Config), 1, ~"/gated", [], false),
    C1 = send_data(C0, 1, binary:copy(~"x", 40000), false),
    {Frames, C2} = ping_sync(C1),
    ?assertEqual([], [F || {window_update, 1, _} = F <- Frames]),
    ok = go(),
    {_, C3} = until(C2, fun
        ({window_update, 1, _}) -> true;
        (_) -> false
    end),
    C4 = send_data(C3, 1, <<>>, true),
    ?assertMatch({[200], ~"40000", end_stream, _}, response(C4, 1)).

content_length_overrun_resets(Config) ->
    C0 = send_headers(open(Config), 1, ~"/read", [{~"content-length", ~"3"}], false),
    C1 = send_data(C0, 1, ~"hello", false),
    ?assertMatch({protocol_error, _}, rst(C1, 1)).

content_length_shortfall_resets(Config) ->
    C0 = send_headers(open(Config), 1, ~"/read", [{~"content-length", ~"10"}], false),
    C1 = send_data(C0, 1, ~"hello", true),
    ?assertMatch({protocol_error, _}, rst(C1, 1)).

malformed_content_length_resets(Config) ->
    C = send_headers(open(Config), 1, ~"/read", [{~"content-length", ~"abc"}], false),
    ?assertMatch({protocol_error, _}, rst(C, 1)).

%% =============================================================================
%% Ending the read
%% =============================================================================

reset_while_reading(Config) ->
    %% The 100 shows the handler's read is waiting on the connection.
    C0 = send_headers(open(Config), 1, ~"/report", [{~"expect", ~"100-continue"}], false),
    {[100], <<>>, interim, C1} = response(C0, 1),
    _ = send_rst(C1, 1),
    ?assertEqual({error, closed}, read_result()).

reset_before_reading(Config) ->
    C0 = send_headers(open(Config), 1, ~"/gated-report", [], false),
    {_, _} = ping_sync(send_rst(C0, 1)),
    ok = go(),
    ?assertEqual({error, closed}, read_result()).

read_times_out(Config) ->
    _ = send_headers(open(Config), 1, ~"/report", [], false),
    ?assertEqual({error, request_timeout}, read_result()).

body_after_the_answer_is_dropped(Config) ->
    %% The response ends before the client's body: reading then fails, the
    %% body that still comes is dropped, and the stream closes cleanly once
    %% the client ends it, leaving the connection serving.
    C0 = send_headers(open(Config), 1, ~"/answer-first", [], false),
    {[200], ~"done", end_stream, C1} = response(C0, 1),
    receive
        {read_after_answer, Result} -> ?assertEqual({error, closed}, Result)
    after 5000 -> ct:fail(no_read_after_answer)
    end,
    C2 = send_data(send_data(C1, 1, ~"late", false), 1, ~"end", true),
    {_, C3} = ping_sync(C2),
    ok = go(),
    C4 = send_data(send_headers(C3, 3, ~"/read", [], false), 3, ~"ok", true),
    ?assertMatch({[200], ~"2", end_stream, _}, response(C4, 3)).

%% =============================================================================
%% Helpers
%% =============================================================================

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

send_headers(#{sock := Sock, enc := Enc} = C, StreamId, Path, Extra, EndStream) ->
    Fields = [
        {~":method", ~"POST"},
        {~":scheme", ~"http"},
        {~":authority", ~"x"},
        {~":path", Path}
        | Extra
    ],
    {Block, Enc1} = roadrunner_http2_hpack:encode(Fields, Enc),
    ok = gen_tcp:send(
        Sock, roadrunner_http2_frame:encode({headers, StreamId, flags(EndStream), undefined, Block})
    ),
    C#{enc := Enc1}.

send_trailers(#{sock := Sock, enc := Enc} = C, StreamId) ->
    {Block, Enc1} = roadrunner_http2_hpack:encode([{~"x-checksum", ~"1"}], Enc),
    ok = gen_tcp:send(
        Sock, roadrunner_http2_frame:encode({headers, StreamId, flags(true), undefined, Block})
    ),
    C#{enc := Enc1}.

flags(true) -> 16#04 bor 16#01;
flags(false) -> 16#04.

%% DATA frames of at most 16384 bytes, the last one ending the stream when
%% `EndStream`.
send_data(#{sock := Sock} = C, StreamId, Bin, EndStream) ->
    ok = gen_tcp:send(Sock, data_frames(StreamId, Bin, EndStream)),
    C.

data_frames(StreamId, <<Chunk:16384/binary, Rest/binary>>, EndStream) when Rest =/= <<>> ->
    [
        roadrunner_http2_frame:encode({data, StreamId, 0, Chunk})
        | data_frames(StreamId, Rest, EndStream)
    ];
data_frames(StreamId, Bin, EndStream) ->
    Flags =
        case EndStream of
            true -> 16#01;
            false -> 0
        end,
    [roadrunner_http2_frame:encode({data, StreamId, Flags, Bin})].

send_rst(#{sock := Sock} = C, StreamId) ->
    ok = gen_tcp:send(Sock, roadrunner_http2_frame:encode({rst_stream, StreamId, cancel})),
    C.

%% Send a PING and collect every frame up to its ACK: the server handles
%% frames in order, so whatever it does about frames sent before the PING
%% is in what comes back first.
ping_sync(#{sock := Sock} = C) ->
    ok = gen_tcp:send(Sock, roadrunner_http2_frame:encode({ping, 0, <<1:64>>})),
    until(C, fun
        ({ping, 1, _}) -> true;
        (_) -> false
    end).

%% Let the gated handler go on, once it has registered.
go() ->
    go(erlang:monotonic_time(millisecond) + 5000).

go(Deadline) ->
    case whereis(?GATED) of
        undefined ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true -> go(Deadline);
                false -> ct:fail(gated_handler_never_registered)
            end;
        Pid ->
            Pid ! go,
            ok
    end.

read_result() ->
    receive
        {read_result, Result} -> Result
    after 5000 -> ct:fail(no_read_result)
    end.

%% Stream `StreamId`'s statuses, body and how it ended so far: `end_stream`,
%% `interim` (a 1xx came, the stream goes on) or `{rst, Code}`.
response(C, StreamId) ->
    response(C, StreamId, [], <<>>).

response(C, StreamId, Statuses, Body) ->
    case next_frame(C) of
        {{headers, StreamId, Flags, Headers}, C1} ->
            {_, Status} = lists:keyfind(~":status", 1, Headers),
            Statuses1 = Statuses ++ [binary_to_integer(Status)],
            case {binary_to_integer(Status), Flags band 16#01} of
                {S, _} when S < 200 -> {Statuses1, Body, interim, C1};
                {_, 0} -> response(C1, StreamId, Statuses1, Body);
                {_, _} -> {Statuses1, Body, end_stream, C1}
            end;
        {{data, StreamId, Flags, Data, _}, C1} ->
            Body1 = <<Body/binary, Data/binary>>,
            case Flags band 16#01 of
                0 -> response(C1, StreamId, Statuses, Body1);
                _ -> {Statuses, Body1, end_stream, C1}
            end;
        {{rst_stream, StreamId, Code}, C1} ->
            {Statuses, Body, {rst, Code}, C1};
        {_Other, C1} ->
            response(C1, StreamId, Statuses, Body)
    end.

%% The code of the next RST_STREAM on `StreamId`.
rst(C, StreamId) ->
    {Frames, C1} = until(C, fun
        ({rst_stream, Id, _}) -> Id =:= StreamId;
        (_) -> false
    end),
    {rst_stream, StreamId, Code} = lists:last(Frames),
    {Code, C1}.

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
