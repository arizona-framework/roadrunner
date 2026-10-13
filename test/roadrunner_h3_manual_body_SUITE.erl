-module(roadrunner_h3_manual_body_SUITE).
-moduledoc """
Manual body mode over HTTP/3: the worker starts at the end of the headers and
reads the body as it arrives, the stream's QUIC credit given back only as it
reads. The handler is `roadrunner_manual_body_handler`; each route's state
picks what it does with the body.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([
    reads_the_body/1,
    reads_data_as_it_arrives/1,
    reads_nothing_without_a_body/1,
    trailers_end_the_body/1,
    answers_before_the_body/1,
    expect_continue_asks_on_the_first_read/1,
    streamed_answer_asks_for_the_body_first/1,
    read_then_streamed_answer_gets_one_100/1,
    expect_continue_rejected_on_the_headers/1,
    body_over_the_cap_fails_the_read/1,
    credit_waits_for_the_reader/1,
    credit_comes_back_as_the_reader_reads/1,
    credit_counts_the_headers/1,
    content_length_overrun_resets/1,
    malformed_content_length_resets/1,
    reset_while_reading/1,
    reset_of_a_stopped_stream/1,
    read_of_a_stopped_stream/1,
    read_times_out/1,
    parked_until_a_slot_frees/1
]).

-define(H, roadrunner_manual_body_handler).
-define(GATED, roadrunner_h3_manual_gated).
%% RFC 9114 §8.1.
-define(H3_REQUEST_CANCELLED, 16#10c).
-define(H3_MESSAGE_ERROR, 16#10e).
%% RFC 9000 §20.1 FLOW_CONTROL_ERROR.
-define(FLOW_CONTROL_ERROR, 16#3).

suite() ->
    [{timetrap, {seconds, 60}}].

all() ->
    [
        reads_the_body,
        reads_data_as_it_arrives,
        reads_nothing_without_a_body,
        trailers_end_the_body,
        answers_before_the_body,
        expect_continue_asks_on_the_first_read,
        streamed_answer_asks_for_the_body_first,
        read_then_streamed_answer_gets_one_100,
        expect_continue_rejected_on_the_headers,
        body_over_the_cap_fails_the_read,
        credit_waits_for_the_reader,
        credit_comes_back_as_the_reader_reads,
        credit_counts_the_headers,
        content_length_overrun_resets,
        malformed_content_length_resets,
        reset_while_reading,
        reset_of_a_stopped_stream,
        read_of_a_stopped_stream,
        read_times_out,
        parked_until_a_slot_frees
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(crypto),
    {ok, _} = application:ensure_all_started(ssl),
    {ok, _} = application:ensure_all_started(telemetry),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(Case, Config) ->
    {ok, _} = roadrunner_listener:start_link(
        ?MODULE,
        maps:merge(
            #{
                port => 0,
                protocols => [http3],
                tls => roadrunner_test_certs:server_opts(),
                body_buffering => manual,
                max_content_length => 64,
                routes => routes(self())
            },
            extra(Case)
        )
    ),
    {ok, Conn} = roadrunner_quic_test_h3:connect({127, 0, 0, 1}, roadrunner_listener:port(?MODULE)),
    [{conn, Conn} | Config].

end_per_testcase(_Case, Config) ->
    _ = roadrunner_quic_test_h3:close(?config(conn, Config)),
    case whereis(?GATED) of
        undefined -> ok;
        Pid -> exit(Pid, kill)
    end,
    ok = roadrunner_listener:stop(?MODULE).

extra(read_times_out) ->
    #{request_timeout => 100};
extra(parked_until_a_slot_frees) ->
    #{max_concurrent_requests => 1, overload_mode => {queue, #{max_queued => 4, timeout => 5000}}};
extra(_Case) ->
    #{}.

routes(TestPid) ->
    [
        {~"/read", ?H, read},
        {~"/reject", ?H, reject},
        #{path => ~"/gated", handler => ?H, state => {gated, ?GATED}, max_content_length => 500000},
        {~"/gated-small", ?H, {gated, ?GATED}},
        #{
            path => ~"/gated-pieces",
            handler => ?H,
            state => {gated_pieces, ?GATED, TestPid},
            max_content_length => 500000
        },
        {~"/report", ?H, {report, TestPid}},
        {~"/stream-echo", ?H, stream_echo},
        {~"/read-then-stream", ?H, read_then_stream}
    ].

%% =============================================================================
%% Reading
%% =============================================================================

reads_the_body(Config) ->
    Conn = ?config(conn, Config),
    StreamId = open(Conn, ~"/read", []),
    ok = roadrunner_quic_test_h3:send_data(Conn, StreamId, ~"hello", true),
    ?assertMatch({200, _, ~"5"}, roadrunner_quic_test_h3:collect(Conn, StreamId)).

reads_data_as_it_arrives(Config) ->
    %% The 100 shows the handler's read is waiting: each DATA then reaches it
    %% as it arrives, before the body ends.
    Conn = ?config(conn, Config),
    StreamId = open(Conn, ~"/read", [{~"expect", ~"100-continue"}]),
    ok = interim_100(Conn, StreamId),
    ok = roadrunner_quic_test_h3:send_data(Conn, StreamId, ~"hello", false),
    ok = roadrunner_quic_test_h3:send_data(Conn, StreamId, ~"world", true),
    ?assertMatch({200, _, ~"10"}, roadrunner_quic_test_h3:collect(Conn, StreamId)).

reads_nothing_without_a_body(Config) ->
    Conn = ?config(conn, Config),
    {ok, StreamId} = roadrunner_quic_test_h3:open_request(Conn, headers(~"/read")),
    ?assertMatch({200, _, ~"0"}, roadrunner_quic_test_h3:collect(Conn, StreamId)).

trailers_end_the_body(Config) ->
    Conn = ?config(conn, Config),
    StreamId = open(Conn, ~"/read", []),
    ok = roadrunner_quic_test_h3:send_data(Conn, StreamId, ~"hello", false),
    Trailers = roadrunner_quic_h3_frame:encode_headers(roadrunner_qpack:encode([{~"x-sum", ~"1"}])),
    ok = roadrunner_quic_test_conn:send(Conn, StreamId, iolist_to_binary(Trailers), true),
    ?assertMatch({200, _, ~"5"}, roadrunner_quic_test_h3:collect(Conn, StreamId)).

%% =============================================================================
%% Answering before the body
%% =============================================================================

answers_before_the_body(Config) ->
    %% The handler answers without reading; what the client still sends on
    %% the stream is dropped, not read as a new request, and the connection
    %% goes on serving.
    Conn = ?config(conn, Config),
    StreamId = open(Conn, ~"/reject", []),
    ?assertMatch({401, _, ~"no"}, roadrunner_quic_test_h3:collect(Conn, StreamId)),
    ok = roadrunner_quic_test_h3:send_data(Conn, StreamId, ~"late", true),
    ?assertMatch({200, _, ~"2"}, post(Conn, ~"/read", ~"ok")).

expect_continue_asks_on_the_first_read(Config) ->
    Conn = ?config(conn, Config),
    StreamId = open(Conn, ~"/read", [{~"expect", ~"100-continue"}]),
    ok = interim_100(Conn, StreamId),
    ok = roadrunner_quic_test_h3:send_data(Conn, StreamId, ~"hello", true),
    ?assertMatch({200, _, ~"5"}, roadrunner_quic_test_h3:collect(Conn, StreamId)).

streamed_answer_asks_for_the_body_first(Config) ->
    %% The handler starts a streamed answer before it reads the body: the 100
    %% comes first, not after the 200.
    Conn = ?config(conn, Config),
    StreamId = open(Conn, ~"/stream-echo", [{~"expect", ~"100-continue"}]),
    ok = roadrunner_quic_test_h3:send_data(Conn, StreamId, ~"hello", true),
    ?assertEqual({[100, 200], ~"hello"}, statuses_and_body(Conn, StreamId)).

read_then_streamed_answer_gets_one_100(Config) ->
    %% The read asks for the body; the streamed answer after it sends no
    %% second 100.
    Conn = ?config(conn, Config),
    StreamId = open(Conn, ~"/read-then-stream", [{~"expect", ~"100-continue"}]),
    ok = interim_100(Conn, StreamId),
    ok = roadrunner_quic_test_h3:send_data(Conn, StreamId, ~"hello", true),
    ?assertEqual({[200], ~"hello"}, statuses_and_body(Conn, StreamId)).

expect_continue_rejected_on_the_headers(Config) ->
    %% No 100: the 401 is the first answer, and the body is never asked for.
    Conn = ?config(conn, Config),
    Expect = [{~"expect", ~"100-continue"}, {~"content-length", ~"5"}],
    StreamId = open(Conn, ~"/reject", Expect),
    ?assertMatch({401, _, ~"no"}, roadrunner_quic_test_h3:collect(Conn, StreamId)).

%% =============================================================================
%% Caps and credit
%% =============================================================================

body_over_the_cap_fails_the_read(Config) ->
    %% Past the cap while the handler is not reading yet: the rest of the body
    %% is dropped, and the handler's read fails when it comes.
    Conn = ?config(conn, Config),
    StreamId = open(Conn, ~"/gated-small", []),
    ok = roadrunner_quic_test_h3:send_data(Conn, StreamId, binary:copy(~"x", 100), false),
    ok = roadrunner_quic_test_h3:send_data(Conn, StreamId, ~"more", true),
    {_, _, _} = post(Conn, ~"/read", ~"sync"),
    ok = go(),
    ?assertMatch(
        {413, _, ~"content_length_too_large"}, roadrunner_quic_test_h3:collect(Conn, StreamId)
    ).

credit_waits_for_the_reader(Config) ->
    %% The handler has not read yet, so the stream's 262144-byte window is
    %% never granted again: sending past it is a flow-control error.
    Conn = ?config(conn, Config),
    StreamId = open(Conn, ~"/gated", []),
    ok = roadrunner_quic_test_h3:send_data(Conn, StreamId, binary:copy(~"x", 270000), false),
    receive
        {quic_test_closed, Conn, Code} -> ?assertEqual(?FLOW_CONTROL_ERROR, Code)
    after 5000 -> ct:fail(no_flow_control_error)
    end.

credit_comes_back_as_the_reader_reads(Config) ->
    %% Once the handler reads, the stream's credit comes back: the client
    %% goes on past its first window.
    Conn = ?config(conn, Config),
    StreamId = open(Conn, ~"/gated-pieces", []),
    ok = roadrunner_quic_test_h3:send_data(Conn, StreamId, binary:copy(~"x", 200000), false),
    ok = go(),
    receive
        first_piece -> ok
    after 5000 -> ct:fail(no_first_piece)
    end,
    ok = roadrunner_quic_test_h3:send_data(Conn, StreamId, binary:copy(~"y", 200000), true),
    ?assertMatch({200, _, ~"400000"}, roadrunner_quic_test_h3:collect(Conn, StreamId)).

credit_counts_the_headers(Config) ->
    %% The credit given back covers every byte of the stream, its HEADERS
    %% frame too, so a reader never shrinks its own window.
    Conn = ?config(conn, Config),
    1 = erlang:trace_pattern({roadrunner_quic, consumed, 3}, true, [global]),
    _ = erlang:trace(all, true, [call]),
    try
        StreamId = open(Conn, ~"/gated", []),
        ok = go(),
        Body = binary:copy(~"x", 1000),
        ok = roadrunner_quic_test_h3:send_data(Conn, StreamId, Body, false),
        Sent =
            iolist_size(
                roadrunner_quic_h3_frame:encode_headers(roadrunner_qpack:encode(headers(~"/gated")))
            ) +
                iolist_size(roadrunner_quic_h3_frame:encode_data(Body)),
        ?assertEqual(Sent, given_back(StreamId, Sent, 0)),
        ok = roadrunner_quic_test_conn:send(Conn, StreamId, <<>>, true),
        ?assertMatch({200, _, ~"1000"}, roadrunner_quic_test_h3:collect(Conn, StreamId))
    after
        _ = erlang:trace(all, false, [call]),
        _ = erlang:trace_pattern({roadrunner_quic, consumed, 3}, false, [global])
    end.

content_length_overrun_resets(Config) ->
    Conn = ?config(conn, Config),
    StreamId = open(Conn, ~"/read", [{~"content-length", ~"3"}]),
    ok = roadrunner_quic_test_h3:send_data(Conn, StreamId, ~"hello", false),
    ?assertEqual(?H3_MESSAGE_ERROR, reset_code(Conn, StreamId)).

malformed_content_length_resets(Config) ->
    Conn = ?config(conn, Config),
    StreamId = open(Conn, ~"/read", [{~"content-length", ~"abc"}]),
    ?assertEqual(?H3_MESSAGE_ERROR, reset_code(Conn, StreamId)).

%% =============================================================================
%% Ending the read
%% =============================================================================

reset_while_reading(Config) ->
    %% The 100 shows the handler's read is waiting on the connection.
    Conn = ?config(conn, Config),
    StreamId = open(Conn, ~"/report", [{~"expect", ~"100-continue"}]),
    ok = interim_100(Conn, StreamId),
    ok = roadrunner_quic_test_conn:reset_stream(Conn, StreamId, ?H3_REQUEST_CANCELLED),
    ?assertEqual({error, closed}, read_result()).

reset_of_a_stopped_stream(Config) ->
    %% A malformed body stops the stream while its handler is still waiting:
    %% the client's reset then ends it, and the handler's read fails.
    Conn = ?config(conn, Config),
    StreamId = open(Conn, ~"/gated", [{~"content-length", ~"3"}]),
    ok = roadrunner_quic_test_h3:send_data(Conn, StreamId, ~"hello", false),
    ?H3_MESSAGE_ERROR = reset_code(Conn, StreamId),
    ok = roadrunner_quic_test_conn:reset_stream(Conn, StreamId, ?H3_REQUEST_CANCELLED),
    {_, _, _} = post(Conn, ~"/read", ~"sync"),
    ok = go(),
    ?assertMatch({200, _, ~"2"}, post(Conn, ~"/read", ~"ok")).

read_of_a_stopped_stream(Config) ->
    Conn = ?config(conn, Config),
    StreamId = open(Conn, ~"/gated", [{~"content-length", ~"3"}]),
    ok = roadrunner_quic_test_h3:send_data(Conn, StreamId, ~"hello", false),
    ?H3_MESSAGE_ERROR = reset_code(Conn, StreamId),
    ok = go(),
    ok = roadrunner_quic_test_h3:send_data(Conn, StreamId, ~"tail", true),
    ?assertMatch({200, _, ~"2"}, post(Conn, ~"/read", ~"ok")).

read_times_out(Config) ->
    Conn = ?config(conn, Config),
    _ = open(Conn, ~"/report", []),
    ?assertEqual({error, request_timeout}, read_result()).

parked_until_a_slot_frees(Config) ->
    %% One request at a time: the second, parked for the slot, keeps
    %% receiving its body and reads it once the first lets go.
    Conn = ?config(conn, Config),
    First = open(Conn, ~"/gated", []),
    ok = wait_gated(),
    Second = open(Conn, ~"/read", []),
    ok = roadrunner_quic_test_h3:send_data(Conn, Second, ~"hello", true),
    ok = roadrunner_quic_test_h3:send_data(Conn, First, ~"a", true),
    ok = go(),
    ?assertMatch({200, _, ~"1"}, roadrunner_quic_test_h3:collect(Conn, First)),
    ?assertMatch({200, _, ~"5"}, roadrunner_quic_test_h3:collect(Conn, Second)).

%% =============================================================================
%% Helpers
%% =============================================================================

headers(Path) ->
    [
        {~":method", ~"POST"},
        {~":scheme", ~"https"},
        {~":authority", ~"localhost"},
        {~":path", Path}
    ].

%% A POST's HEADERS with `Extra` fields, its body to follow.
open(Conn, Path, Extra) ->
    {ok, StreamId} = roadrunner_quic_test_h3:open_request(Conn, headers(Path) ++ Extra, false),
    StreamId.

post(Conn, Path, Body) ->
    StreamId = open(Conn, Path, []),
    ok = roadrunner_quic_test_h3:send_data(Conn, StreamId, Body, true),
    roadrunner_quic_test_h3:collect(Conn, StreamId).

%% The interim 100 on `StreamId`: a HEADERS frame with `:status` alone.
interim_100(Conn, StreamId) ->
    receive
        {quic_test_stream, Conn, StreamId, Bytes, false} ->
            {ok, {headers, Block}, <<>>} = roadrunner_quic_h3_frame:decode(Bytes),
            {ok, [{~":status", ~"100"}]} = roadrunner_qpack:decode(Block),
            ok
    after 5000 -> ct:fail(no_interim_100)
    end.

%% Every status `StreamId` answers with, in order, and its body, read until
%% the stream ends.
statuses_and_body(Conn, StreamId) ->
    frames(stream_bytes(Conn, StreamId, <<>>), [], <<>>).

stream_bytes(Conn, StreamId, Acc) ->
    receive
        {quic_test_stream, Conn, StreamId, Bytes, false} ->
            stream_bytes(Conn, StreamId, <<Acc/binary, Bytes/binary>>);
        {quic_test_stream, Conn, StreamId, Bytes, true} ->
            <<Acc/binary, Bytes/binary>>
    after 5000 -> ct:fail(stream_not_ended)
    end.

frames(<<>>, Statuses, Body) ->
    {lists:reverse(Statuses), Body};
frames(Bytes, Statuses, Body) ->
    case roadrunner_quic_h3_frame:decode(Bytes) of
        {ok, {headers, Block}, Rest} ->
            {ok, Fields} = roadrunner_qpack:decode(Block),
            {_, Status} = lists:keyfind(~":status", 1, Fields),
            frames(Rest, [binary_to_integer(Status) | Statuses], Body);
        {ok, {data, Data}, Rest} ->
            frames(Rest, Statuses, <<Body/binary, Data/binary>>)
    end.

reset_code(Conn, StreamId) ->
    receive
        {quic_test_stream_reset, Conn, StreamId, Code} -> Code
    after 5000 -> ct:fail(no_reset)
    end.

read_result() ->
    receive
        {read_result, Result} -> Result
    after 5000 -> ct:fail(no_read_result)
    end.

%% The bytes given back on `StreamId` (traced `roadrunner_quic:consumed/3`
%% calls), summed until they reach `Want` or a second passes with no more.
given_back(_StreamId, Want, Total) when Total >= Want ->
    Total;
given_back(StreamId, Want, Total) ->
    receive
        {trace, _Pid, call, {roadrunner_quic, consumed, [_Conn, StreamId, Bytes]}} ->
            given_back(StreamId, Want, Total + Bytes)
    after 1000 -> Total
    end.

wait_gated() ->
    wait_gated(erlang:monotonic_time(millisecond) + 5000).

wait_gated(Deadline) ->
    case whereis(?GATED) of
        undefined ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true -> wait_gated(Deadline);
                false -> ct:fail(gated_handler_never_registered)
            end;
        _ ->
            ok
    end.

%% Let the gated handler go on, once it has registered.
go() ->
    ok = wait_gated(),
    ?GATED ! go,
    ok.
