-module(roadrunner_manual_drain_SUITE).
-moduledoc """
In manual body mode over HTTP/1.1 the connection drains what a handler left
of its body before it moves on. A handler that read its body inside a
stream, or read it and handed back the request it was given, leaves the
connection a copy of the reader that does not know what was read: the drain
starts from where the last read left off instead, so it neither waits for
bytes already taken nor lingers over a body it thinks was never asked for.
Each case sends the body only after the handler has its reader, so the copy
holds none of it; timeouts here are a minute, so a drain that waited on
them would fail the case.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_testcase/2, end_per_testcase/2]).
-export([
    stream_that_reads_the_body_closes_at_once/1,
    stream_that_asks_for_the_body_does_not_linger/1,
    read_then_stream_does_not_linger/1,
    handed_back_request_keeps_the_connection/1,
    handed_back_request_keeps_a_pipelined_request/1
]).

-define(H, roadrunner_manual_body_handler).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        stream_that_reads_the_body_closes_at_once,
        stream_that_asks_for_the_body_does_not_linger,
        read_then_stream_does_not_linger,
        handed_back_request_keeps_the_connection,
        handed_back_request_keeps_a_pipelined_request
    ].

init_per_testcase(_Case, Config) ->
    {ok, _} = roadrunner_test_event_handler:start(),
    {ok, _} = roadrunner_listener:start_link(?MODULE, #{
        port => 0,
        protocols => [{http1, #{linger_timeout => 60000}}],
        body_buffering => manual,
        request_timeout => 60000,
        keep_alive_timeout => 60000,
        routes => [
            {~"/stream-echo", ?H, stream_echo},
            {~"/read-then-stream", ?H, read_then_stream},
            {~"/report", ?H, {announce_report, self()}}
        ]
    }),
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1},
        roadrunner_listener:port(?MODULE),
        %% Kept open after the server's end of stream, as a client that
        %% half-closes would: a lingering connection then stays open.
        [binary, {active, false}, {exit_on_close, false}],
        5000
    ),
    [{sock, Sock} | Config].

end_per_testcase(_Case, Config) ->
    ok = gen_tcp:close(?config(sock, Config)),
    ok = roadrunner_listener:stop(?MODULE).

stream_that_reads_the_body_closes_at_once(Config) ->
    %% The stream's head goes out before its read, so the body is sent
    %% after the reader was made.
    Sock = ?config(sock, Config),
    ok = gen_tcp:send(Sock, head(~"/stream-echo", [])),
    Head = recv_until(Sock, ~"\r\n\r\n", <<>>),
    ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, Head),
    ok = gen_tcp:send(Sock, ~"hello"),
    Reply = recv_until_closed(Sock, Head),
    {match, _} = re:run(Reply, "\r\n5\r\nhello\r\n0\r\n\r\n$").

stream_that_asks_for_the_body_does_not_linger(Config) ->
    %% The read inside the stream sent the 100 and took the body, so the
    %% connection closes at once instead of lingering over a body it would
    %% take as never asked for. Lingering would keep it open, past its
    %% response, until this client closes.
    Sock = ?config(sock, Config),
    Closed = attach_conn_close(),
    ok = gen_tcp:send(Sock, head(~"/stream-echo", [~"Expect: 100-continue\r\n"])),
    ?assertEqual({ok, ~"HTTP/1.1 100 Continue\r\n\r\n"}, gen_tcp:recv(Sock, 25, 5000)),
    ok = gen_tcp:send(Sock, ~"hello"),
    ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, recv_until_closed(Sock, <<>>)),
    ?assertEqual(normal, conn_closed(Closed)).

read_then_stream_does_not_linger(Config) ->
    Sock = ?config(sock, Config),
    Closed = attach_conn_close(),
    ok = gen_tcp:send(Sock, head(~"/read-then-stream", [~"Expect: 100-continue\r\n"])),
    ?assertEqual({ok, ~"HTTP/1.1 100 Continue\r\n\r\n"}, gen_tcp:recv(Sock, 25, 5000)),
    ok = gen_tcp:send(Sock, ~"hello"),
    ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, recv_until_closed(Sock, <<>>)),
    ?assertEqual(normal, conn_closed(Closed)).

handed_back_request_keeps_the_connection(Config) ->
    %% The handler reads the body, then answers with the request it was
    %% given: the next request on the connection is still served.
    Sock = ?config(sock, Config),
    ok = lists:foreach(
        fun(_) ->
            ok = gen_tcp:send(Sock, head(~"/report", [])),
            ok = reading(),
            ok = gen_tcp:send(Sock, ~"hello"),
            ?assertEqual({read_result, {ok, 5}}, read_result()),
            ?assertEqual(~"ok", recv_body(Sock, <<>>))
        end,
        [1, 2]
    ).

handed_back_request_keeps_a_pipelined_request(Config) ->
    %% A request pipelined behind the body is the drain's leftover, from
    %% where the handler's read stopped.
    Sock = ?config(sock, Config),
    ok = gen_tcp:send(Sock, head(~"/report", [])),
    ok = reading(),
    ok = gen_tcp:send(Sock, [~"hello", head(~"/report", []), ~"again"]),
    ?assertEqual({read_result, {ok, 5}}, read_result()),
    ok = reading(),
    ?assertEqual({read_result, {ok, 5}}, read_result()),
    {Body, Rest} = recv_response(Sock, <<>>),
    ?assertEqual(~"ok", Body),
    ?assertEqual(~"ok", element(1, recv_response(Sock, Rest))).

%% --- helpers ---

%% A request head declaring a 5-byte body.
head(Path, Extra) ->
    [~"POST ", Path, ~" HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n", Extra, ~"\r\n"].

reading() ->
    receive
        reading -> ok
    after 5000 -> ct:fail(handler_not_reading)
    end.

read_result() ->
    receive
        {read_result, _} = R -> R
    after 5000 -> ct:fail(no_read_result)
    end.

attach_conn_close() ->
    Self = self(),
    Ref = make_ref(),
    ok = telemetry:attach(
        Ref,
        [roadrunner, listener, conn_close],
        fun(_Event, _Measurements, #{reason := Reason}, _Config) -> Self ! {Ref, Reason} end,
        undefined
    ),
    Ref.

%% The connection closed on its own, while this client still holds it.
conn_closed(Ref) ->
    receive
        {Ref, Reason} ->
            ok = telemetry:detach(Ref),
            Reason
    after 5000 -> ct:fail(conn_still_open)
    end.

recv_until(Sock, Pattern, Acc) ->
    case binary:match(Acc, Pattern) of
        nomatch ->
            {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
            recv_until(Sock, Pattern, <<Acc/binary, Data/binary>>);
        _ ->
            Acc
    end.

recv_until_closed(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Data} -> recv_until_closed(Sock, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc
    end.

recv_body(Sock, Acc) ->
    element(1, recv_response(Sock, Acc)).

%% The body of the next response, framed by its `content-length`, and the
%% bytes after it.
recv_response(Sock, Acc) ->
    case binary:split(Acc, ~"\r\n\r\n") of
        [Head, Rest] ->
            {match, [Len]} = re:run(
                Head, ~"(?i)content-length: ([0-9]+)", [{capture, all_but_first, binary}]
            ),
            Size = binary_to_integer(Len),
            case Rest of
                <<Body:Size/binary, After/binary>> ->
                    {Body, After};
                _ ->
                    {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
                    recv_response(Sock, <<Acc/binary, Data/binary>>)
            end;
        [_] ->
            {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
            recv_response(Sock, <<Acc/binary, Data/binary>>)
    end.
