-module(roadrunner_manual_continue_SUITE).
-moduledoc """
`Expect: 100-continue` in manual body mode over HTTP/1.1: the `100 Continue`
goes out when the handler first reads the body, so a handler that answers
from the headers alone never has the client upload it.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_testcase/2, end_per_testcase/2]).
-export([
    handler_answering_without_reading_gets_no_body/1,
    body_over_the_cap_refused_from_the_headers/1,
    empty_body_is_not_asked_for/1,
    handler_reading_asks_for_the_body/1,
    streamed_answer_asks_for_the_body_first/1,
    read_then_streamed_answer_gets_one_100/1,
    chunked_body_is_asked_for_on_read/1,
    earlier_response_goes_before_the_100/1,
    rate_window_starts_with_the_100/1
]).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        handler_answering_without_reading_gets_no_body,
        body_over_the_cap_refused_from_the_headers,
        empty_body_is_not_asked_for,
        handler_reading_asks_for_the_body,
        streamed_answer_asks_for_the_body_first,
        read_then_streamed_answer_gets_one_100,
        chunked_body_is_asked_for_on_read,
        earlier_response_goes_before_the_100,
        rate_window_starts_with_the_100
    ].

init_per_testcase(_Case, Config) ->
    {ok, _} = application:ensure_all_started(telemetry),
    {ok, _} = roadrunner_listener:start_link(?MODULE, #{
        port => 0,
        protocols => [http1],
        body_buffering => manual,
        min_bytes_per_second => 100,
        routes => roadrunner_continue_handler
    }),
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, roadrunner_listener:port(?MODULE), [binary, {active, false}], 5000
    ),
    [{sock, Sock} | Config].

end_per_testcase(_Case, Config) ->
    ok = gen_tcp:close(?config(sock, Config)),
    ok = roadrunner_listener:stop(?MODULE).

handler_answering_without_reading_gets_no_body(Config) ->
    %% The 401 is the first thing on the wire, no 100 before it, and the
    %% connection closes after it: the client may still send the body once
    %% it stops waiting, and those bytes are not a next request.
    Sock = ?config(sock, Config),
    ok = gen_tcp:send(Sock, expect_head(~"/reject", ~"content-length: 5")),
    Reply = recv_until_closed(Sock, <<>>),
    ?assertMatch(<<"HTTP/1.1 401 ", _/binary>>, Reply),
    {match, _} = re:run(Reply, "(?i)\r\nconnection: close\r\n").

body_over_the_cap_refused_from_the_headers(Config) ->
    %% A declared body over the cap gets its 413 from the headers alone,
    %% before the handler (which would answer 401) runs, as auto mode does.
    Sock = ?config(sock, Config),
    ok = gen_tcp:send(Sock, expect_head(~"/reject", ~"content-length: 100000000")),
    ?assertMatch(<<"HTTP/1.1 413 ", _/binary>>, recv_until_closed(Sock, <<>>)).

empty_body_is_not_asked_for(Config) ->
    %% No body to send, so no 100 asks for one: the response comes first.
    Sock = ?config(sock, Config),
    ok = gen_tcp:send(Sock, expect_head(~"/read", ~"content-length: 0")),
    ?assertEqual({200, ~"0"}, recv_response(Sock)).

handler_reading_asks_for_the_body(Config) ->
    Sock = ?config(sock, Config),
    ok = gen_tcp:send(Sock, expect_head(~"/read", ~"content-length: 5")),
    ?assertEqual({ok, ~"HTTP/1.1 100 Continue\r\n\r\n"}, gen_tcp:recv(Sock, 0, 5000)),
    ok = gen_tcp:send(Sock, ~"hello"),
    ?assertEqual({200, ~"5"}, recv_response(Sock)),
    %% The body was read, so the connection is kept.
    ok = gen_tcp:send(Sock, ~"GET /read HTTP/1.1\r\nHost: x\r\n\r\n"),
    ?assertEqual({200, ~"0"}, recv_response(Sock)).

streamed_answer_asks_for_the_body_first(Config) ->
    %% The handler starts a streamed answer before it reads the body: the 100
    %% goes out ahead of the 200, and none lands inside it.
    Sock = ?config(sock, Config),
    ok = gen_tcp:send(Sock, expect_head(~"/stream-echo", ~"content-length: 5")),
    First = recv_exactly(Sock, <<>>, 25),
    ?assertMatch(<<"HTTP/1.1 100 Continue\r\n\r\n", _/binary>>, First),
    ok = gen_tcp:send(Sock, ~"hello"),
    <<_:25/binary, Answer/binary>> = recv_until_closed(Sock, First),
    ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, Answer),
    ?assertEqual(nomatch, binary:match(Answer, ~"100 Continue")),
    {match, _} = re:run(Answer, "\r\n5\r\nhello\r\n0\r\n\r\n$").

read_then_streamed_answer_gets_one_100(Config) ->
    %% The read asks for the body; the streamed answer after it sends no
    %% second 100.
    Sock = ?config(sock, Config),
    ok = gen_tcp:send(Sock, expect_head(~"/read-then-stream", ~"content-length: 5")),
    ?assertEqual(~"HTTP/1.1 100 Continue\r\n\r\n", recv_exactly(Sock, <<>>, 25)),
    ok = gen_tcp:send(Sock, ~"hello"),
    Answer = recv_until_closed(Sock, <<>>),
    ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, Answer),
    ?assertEqual(nomatch, binary:match(Answer, ~"100 Continue")).

chunked_body_is_asked_for_on_read(Config) ->
    Sock = ?config(sock, Config),
    ok = gen_tcp:send(Sock, expect_head(~"/read", ~"transfer-encoding: chunked")),
    ?assertEqual({ok, ~"HTTP/1.1 100 Continue\r\n\r\n"}, gen_tcp:recv(Sock, 0, 5000)),
    ok = gen_tcp:send(Sock, ~"5\r\nhello\r\n0\r\n\r\n"),
    ?assertEqual({200, ~"5"}, recv_response(Sock)).

earlier_response_goes_before_the_100(Config) ->
    %% A pipelined request's response is queued while the next request is
    %% parsed; it reaches the wire before that request's 100.
    Sock = ?config(sock, Config),
    ok = gen_tcp:send(Sock, [
        ~"GET /read HTTP/1.1\r\nHost: x\r\n\r\n", expect_head(~"/read", ~"content-length: 5")
    ]),
    {{200, ~"0"}, Rest} = recv_response(Sock, <<>>),
    ?assertEqual(~"HTTP/1.1 100 Continue\r\n\r\n", recv_exactly(Sock, Rest, 25)),
    ok = gen_tcp:send(Sock, ~"hello"),
    ?assertEqual({200, ~"5"}, recv_response(Sock)).

rate_window_starts_with_the_100(Config) ->
    %% The handler spends 1.1 s before reading; the client cannot send before
    %% the 100, so that time does not count against its 100 bytes/s.
    Sock = ?config(sock, Config),
    ok = gen_tcp:send(Sock, expect_head(~"/slow-read", ~"content-length: 5")),
    ?assertEqual({ok, ~"HTTP/1.1 100 Continue\r\n\r\n"}, gen_tcp:recv(Sock, 0, 5000)),
    ok = gen_tcp:send(Sock, ~"hello"),
    ?assertEqual({200, ~"5"}, recv_response(Sock)).

%% --- helpers ---

expect_head(Path, Framing) ->
    [
        ~"POST ",
        Path,
        ~" HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\n",
        Framing,
        ~"\r\n\r\n"
    ].

%% One response on a kept-alive connection, its status and body, reading
%% exactly its `content-length` bytes of body.
recv_response(Sock) ->
    {Response, <<>>} = recv_response(Sock, <<>>),
    Response.

%% The same, starting from bytes already received (`Buf`), and returning
%% whatever arrived past the response.
recv_response(Sock, Buf) ->
    {Head, Rest} = recv_head(Sock, Buf),
    <<"HTTP/1.1 ", Code:3/binary, _/binary>> = Head,
    {match, [Length]} = re:run(
        Head, "(?i)\r\ncontent-length: ([0-9]+)", [{capture, all_but_first, binary}]
    ),
    Len = binary_to_integer(Length),
    <<Body:Len/binary, After/binary>> = recv_exactly(Sock, Rest, Len),
    {{binary_to_integer(Code), Body}, After}.

%% At least `Length` bytes, starting from `Acc`.
recv_exactly(_Sock, Acc, Length) when byte_size(Acc) >= Length ->
    Acc;
recv_exactly(Sock, Acc, Length) ->
    {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
    recv_exactly(Sock, <<Acc/binary, Data/binary>>, Length).

recv_head(Sock, Acc) ->
    case binary:split(Acc, ~"\r\n\r\n") of
        [Head, Rest] ->
            {Head, Rest};
        [_] ->
            {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
            recv_head(Sock, <<Acc/binary, Data/binary>>)
    end.

recv_until_closed(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Data} -> recv_until_closed(Sock, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc
    end.
