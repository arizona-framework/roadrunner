-module(roadrunner_http1_active_SUITE).
-moduledoc """
HTTP/1.1 over TLS reads its socket with `{active, N}` (`16` unless the
`http1` `active` option says otherwise): requests, pipelined requests,
heads and bodies split across TLS records, manual body reads and the
writer-owned responses all behave as with `once`. Most cases run with
`active => 1`, so the socket goes passive after every read and the
re-arm is exercised throughout.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([
    keep_alive_requests_over_the_default/1,
    keep_alive_requests_past_each_arm/1,
    pipelined_requests/1,
    head_split_across_records/1,
    body_split_across_records/1,
    chunked_body_split_across_records/1,
    manual_body_after_continue/1,
    streaming_handler_reads_its_body/1,
    loop_response_sees_no_socket_messages/1,
    stream_response/1,
    websocket_frame_sent_behind_the_upgrade/1,
    plain_tcp_with_active_n/1
]).

-define(RUNS, 40).

suite() ->
    [{timetrap, {seconds, 60}}].

all() ->
    [
        keep_alive_requests_over_the_default,
        keep_alive_requests_past_each_arm,
        pipelined_requests,
        head_split_across_records,
        body_split_across_records,
        chunked_body_split_across_records,
        manual_body_after_continue,
        streaming_handler_reads_its_body,
        loop_response_sees_no_socket_messages,
        stream_response,
        websocket_frame_sent_behind_the_upgrade,
        plain_tcp_with_active_n
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(ssl),
    {ok, _} = roadrunner_test_event_handler:start(),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(Case, Config) ->
    Opts = maps:merge(
        #{
            port => 0,
            protocols => [{http1, #{active => 1}}],
            routes => [
                {~"/size", roadrunner_body_size_handler, undefined},
                {~"/echo", roadrunner_manual_body_handler, stream_echo},
                {~"/loop", roadrunner_loop_handler, undefined},
                {~"/stream", roadrunner_stream_handler, undefined},
                {~"/ws", roadrunner_ws_upgrade_handler, undefined}
            ]
        },
        opts(Case)
    ),
    {ok, _} = roadrunner_listener:start_link(Case, with_tls(Case, Opts)),
    [{listener, Case}, {port, roadrunner_listener:port(Case)} | Config].

end_per_testcase(_Case, Config) ->
    ok = roadrunner_listener:stop(?config(listener, Config)).

opts(keep_alive_requests_over_the_default) ->
    %% Unset: TLS reads with `{active, 16}`; `hibernate_after` keeps it.
    #{protocols => [http1], hibernate_after => 60000};
opts(Case) when
    Case =:= manual_body_after_continue; Case =:= streaming_handler_reads_its_body
->
    #{body_buffering => manual};
opts(plain_tcp_with_active_n) ->
    #{protocols => [{http1, #{active => 2}}]};
opts(_Case) ->
    #{}.

with_tls(plain_tcp_with_active_n, Opts) -> Opts;
with_tls(_Case, Opts) -> Opts#{tls => roadrunner_test_certs:server_opts()}.

%% --- testcases ---

keep_alive_requests_over_the_default(Config) ->
    %% More requests than one `{active, 16}` arm covers.
    Sock = connect(Config),
    ok = lists:foreach(fun(_) -> ?assertEqual(~"0", get_size(Sock)) end, lists:seq(1, ?RUNS)),
    ok = ssl:close(Sock).

keep_alive_requests_past_each_arm(Config) ->
    Sock = connect(Config),
    ok = lists:foreach(fun(_) -> ?assertEqual(~"0", get_size(Sock)) end, lists:seq(1, ?RUNS)),
    ok = ssl:close(Sock).

pipelined_requests(Config) ->
    %% One write, many requests: their responses come back in order.
    Sock = connect(Config),
    Requests = [post(integer_to_binary(N)) || N <- lists:seq(1, ?RUNS)],
    ok = ssl:send(Sock, Requests),
    Bodies = recv_bodies(Sock, ?RUNS, <<>>),
    ?assertEqual(
        [integer_to_binary(byte_size(integer_to_binary(N))) || N <- lists:seq(1, ?RUNS)], Bodies
    ),
    ok = ssl:close(Sock).

head_split_across_records(Config) ->
    Sock = connect(Config),
    ok = ssl:send(Sock, ~"GET /size HTTP/1.1\r\n"),
    ok = ssl:send(Sock, ~"Host: x\r\n"),
    ok = ssl:send(Sock, ~"\r\n"),
    ?assertEqual([~"0"], recv_bodies(Sock, 1, <<>>)),
    ok = ssl:close(Sock).

body_split_across_records(Config) ->
    Sock = connect(Config),
    Piece = binary:copy(~"x", 3000),
    ok = ssl:send(Sock, ~"POST /size HTTP/1.1\r\nHost: x\r\nContent-Length: 30000\r\n\r\n"),
    ok = lists:foreach(fun(_) -> ok = ssl:send(Sock, Piece) end, lists:seq(1, 10)),
    ?assertEqual([~"30000"], recv_bodies(Sock, 1, <<>>)),
    ok = ssl:close(Sock).

chunked_body_split_across_records(Config) ->
    Sock = connect(Config),
    ok = ssl:send(Sock, ~"POST /size HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"),
    ok = lists:foreach(fun(_) -> ok = ssl:send(Sock, ~"5\r\nhello\r\n") end, lists:seq(1, 10)),
    ok = ssl:send(Sock, ~"0\r\n\r\n"),
    ?assertEqual([~"50"], recv_bodies(Sock, 1, <<>>)),
    ok = ssl:close(Sock).

manual_body_after_continue(Config) ->
    %% The handler reads the body itself, from the mailbox, once the 100
    %% asked for it.
    Sock = connect(Config),
    ok = ssl:send(
        Sock,
        ~"POST /size HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\nExpect: 100-continue\r\n\r\n"
    ),
    ?assertEqual({ok, ~"HTTP/1.1 100 Continue\r\n\r\n"}, ssl:recv(Sock, 25, 5000)),
    ok = ssl:send(Sock, ~"hello"),
    ok = ssl:send(Sock, ~"world"),
    ?assertEqual([~"10"], recv_bodies(Sock, 1, <<>>)),
    ok = ssl:close(Sock).

streaming_handler_reads_its_body(Config) ->
    %% The handler starts a stream, then reads its body: what came in
    %% while the socket was armed is read first, the rest off the socket.
    Sock = connect(Config),
    ok = ssl:send(Sock, ~"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\n"),
    ok = ssl:send(Sock, ~"hello"),
    ok = ssl:send(Sock, ~"world"),
    Reply = recv_until_closed(Sock, <<>>),
    ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, Reply),
    ?assertNotEqual(nomatch, binary:match(Reply, ~"helloworld")).

loop_response_sees_no_socket_messages(Config) ->
    %% `roadrunner_loop_handler` matches only its own messages, so a
    %% socket message reaching `handle_info/3` would crash it: with
    %% `active => 1` the passive message is queued by the time it runs.
    Sock = connect(Config),
    ok = ssl:send(Sock, ~"GET /loop HTTP/1.1\r\nHost: x\r\n\r\n"),
    _ = recv_until(Sock, ~"\r\n\r\n", <<>>),
    %% The handler registered its conn before the head went out.
    Conn = whereis(roadrunner_loop_test_conn),
    Conn ! {push, ~"one"},
    _ = recv_until(Sock, ~"data: one", <<>>),
    Conn ! stop,
    _ = recv_until(Sock, ~"bye(1)", <<>>),
    ok = ssl:close(Sock).

stream_response(Config) ->
    Sock = connect(Config),
    ok = ssl:send(Sock, ~"GET /stream HTTP/1.1\r\nHost: x\r\n\r\n"),
    Reply = recv_until_closed(Sock, <<>>),
    ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, Reply),
    ?assertNotEqual(nomatch, binary:match(Reply, ~"world")).

websocket_frame_sent_behind_the_upgrade(Config) ->
    %% A frame sent right behind the upgrade request, before the 101, is
    %% read by the session whether the conn already took it off the
    %% socket or not.
    Sock = connect(Config),
    ok = ssl:send(Sock, [
        ~"GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n",
        ~"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
    ]),
    ok = ssl:send(Sock, masked(16#81, ~"hi")),
    Reply = recv_until(Sock, <<16#81, 2, "hi">>, <<>>),
    ?assertMatch(<<"HTTP/1.1 101 ", _/binary>>, Reply),
    ok = ssl:close(Sock).

plain_tcp_with_active_n(Config) ->
    %% An explicit `active` applies to plain TCP too.
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, ?config(port, Config), [binary, {active, false}], 5000
    ),
    ok = lists:foreach(
        fun(_) ->
            ok = gen_tcp:send(Sock, ~"GET /size HTTP/1.1\r\nHost: x\r\n\r\n"),
            ?assertEqual([~"0"], recv_bodies(fun(T) -> gen_tcp:recv(Sock, 0, T) end, 1, <<>>))
        end,
        lists:seq(1, ?RUNS)
    ),
    ok = gen_tcp:close(Sock).

%% --- helpers ---

connect(Config) ->
    {ok, Sock} = ssl:connect(
        {127, 0, 0, 1},
        ?config(port, Config),
        [binary, {active, false}, {verify, verify_none}],
        5000
    ),
    Sock.

get_size(Sock) ->
    ok = ssl:send(Sock, ~"GET /size HTTP/1.1\r\nHost: x\r\n\r\n"),
    [Body] = recv_bodies(Sock, 1, <<>>),
    Body.

post(Body) ->
    [
        ~"POST /size HTTP/1.1\r\nHost: x\r\nContent-Length: ",
        integer_to_binary(byte_size(Body)),
        ~"\r\n\r\n",
        Body
    ].

%% The bodies of `N` responses, each framed by its `content-length`.
recv_bodies(Sock, N, Acc) when not is_function(Sock) ->
    recv_bodies(fun(T) -> ssl:recv(Sock, 0, T) end, N, Acc);
recv_bodies(_Recv, 0, ~"") ->
    [];
recv_bodies(Recv, N, Acc) ->
    case binary:split(Acc, ~"\r\n\r\n") of
        [Head, Rest] ->
            {match, [Len]} = re:run(
                Head, ~"content-length: ([0-9]+)", [{capture, all_but_first, binary}]
            ),
            Size = binary_to_integer(Len),
            case Rest of
                <<Body:Size/binary, Next/binary>> ->
                    [Body | recv_bodies(Recv, N - 1, Next)];
                _ ->
                    recv_bodies(Recv, N, more(Recv, Acc))
            end;
        [_] ->
            recv_bodies(Recv, N, more(Recv, Acc))
    end.

more(Recv, Acc) ->
    {ok, Data} = Recv(5000),
    <<Acc/binary, Data/binary>>.

recv_until(Sock, Pattern, Acc) ->
    case binary:match(Acc, Pattern) of
        nomatch ->
            {ok, Data} = ssl:recv(Sock, 0, 5000),
            recv_until(Sock, Pattern, <<Acc/binary, Data/binary>>);
        _ ->
            Acc
    end.

recv_until_closed(Sock, Acc) ->
    case ssl:recv(Sock, 0, 5000) of
        {ok, Data} -> recv_until_closed(Sock, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc
    end.

masked(OpByte, Payload) ->
    Key = <<1, 2, 3, 4>>,
    KeyBin = binary:copy(Key, (byte_size(Payload) div 4) + 1),
    <<KeySlice:(byte_size(Payload))/binary, _/binary>> = KeyBin,
    <<OpByte, (16#80 bor byte_size(Payload)), Key/binary, (crypto:exor(Payload, KeySlice))/binary>>.
