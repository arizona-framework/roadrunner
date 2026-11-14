-module(roadrunner_h1_body_timeout_SUITE).
-moduledoc """
`roadrunner_req:set_body_timeout/2` over HTTP/1.1 in manual body mode: a
handler moves the deadline of its body reads, and the drain of a body the
handler left unread stays within the request's own deadline, whatever the
handler moved its reads to. The listener's `request_timeout` is short, so
a drain that waited on the handler's `infinity` would fail the case.
""".

-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_testcase/2, end_per_testcase/2]).
-export([
    moved_deadline_ends_the_read/1,
    send_reply_after_a_failed_read_says_close/1,
    unread_body_is_drained_within_the_request_deadline/1
]).

-define(H, roadrunner_manual_body_handler).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        moved_deadline_ends_the_read,
        send_reply_after_a_failed_read_says_close,
        unread_body_is_drained_within_the_request_deadline
    ].

init_per_testcase(_Case, Config) ->
    {ok, _} = roadrunner_listener:start_link(?MODULE, #{
        port => 0,
        protocols => [{http1, #{linger_timeout => 100}}],
        body_buffering => manual,
        request_timeout => 200,
        routes => [
            {~"/retimed", ?H, {retimed, self()}},
            {~"/retimed-send", ?H, {retimed_send, self()}},
            {~"/answer-unread", ?H, answer_unread}
        ]
    }),
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, roadrunner_listener:port(?MODULE), [binary, {active, false}], 5000
    ),
    [{sock, Sock} | Config].

end_per_testcase(_Case, Config) ->
    ok = gen_tcp:close(?config(sock, Config)),
    ok = roadrunner_listener:stop(?MODULE).

moved_deadline_ends_the_read(Config) ->
    %% The handler gives its reads no time, though the listener's
    %% `request_timeout` would: the read times out at once. The failed read
    %% ends the body, so the answer says the connection closes, and it does.
    Sock = ?config(sock, Config),
    ok = gen_tcp:send(Sock, head(~"/retimed", 4)),
    receive
        {read_result, Result} -> ?assertEqual({error, request_timeout}, Result)
    after 5000 -> ct:fail(no_read_result)
    end,
    Reply = recv_until_closed(Sock, <<>>),
    ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, Reply),
    ?assertMatch({match, _}, re:run(Reply, "(?i)\r\nconnection: close\r\n")).

send_reply_after_a_failed_read_says_close(Config) ->
    %% The same from a `{send, ...}` fun replying after its read failed.
    Sock = ?config(sock, Config),
    ok = gen_tcp:send(Sock, head(~"/retimed-send", 4)),
    receive
        {read_result, Result} -> ?assertEqual({error, request_timeout}, Result)
    after 5000 -> ct:fail(no_read_result)
    end,
    Reply = recv_until_closed(Sock, <<>>),
    ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, Reply),
    ?assertMatch({match, _}, re:run(Reply, "(?i)\r\nconnection: close\r\n")).

unread_body_is_drained_within_the_request_deadline(Config) ->
    %% The handler answers without reading, after giving its reads no
    %% deadline. The client sends part of the body and then nothing: the
    %% drain gives up at the request's own deadline and the connection
    %% closes.
    Sock = ?config(sock, Config),
    ok = gen_tcp:send(Sock, [head(~"/answer-unread", 10), ~"ab"]),
    Reply = recv_until_closed(Sock, <<>>),
    ?assertMatch(<<"HTTP/1.1 400 ", _/binary>>, Reply).

head(Path, Length) ->
    [
        ~"POST ",
        Path,
        ~" HTTP/1.1\r\nHost: x\r\nContent-Length: ",
        integer_to_binary(Length),
        ~"\r\n\r\n"
    ].

recv_until_closed(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Data} -> recv_until_closed(Sock, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc
    end.
