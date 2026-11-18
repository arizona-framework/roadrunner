-module(roadrunner_keep_alive_SUITE).
-moduledoc """
How many requests an HTTP/1.1 connection serves (`max_keep_alive_requests`):
without a limit, as many as the client sends; with one, the response that
reaches it says `Connection: close`, and the close lingers over the requests
the client pipelined behind it, so the client reads that response instead of
losing it to a reset. A close the handler asks for lingers too when the
client already pipelined a request behind it, and is immediate otherwise.
""".

-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1]).
-export([forward/4]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([
    default_serves_past_a_thousand/1,
    limit_lingers_over_pipelined_requests/1,
    server_close_lingers_over_pipelined_requests/1,
    server_close_without_pipelining_is_immediate/1,
    client_close_with_pipelining_is_immediate/1
]).

%% Past the ceiling the default used to have.
-define(MANY, 1500).
-define(LIMIT, 2).
%% Each pipelined request carries a body, so the ones past the limit are
%% still unread in the socket when the connection closes.
-define(BODY_SIZE, 65536).
-define(POST_REQUEST, <<
    "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: ",
    (integer_to_binary(?BODY_SIZE))/binary,
    "\r\n\r\n",
    (binary:copy(~"a", ?BODY_SIZE))/binary
>>).

-define(REQUEST, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n").
%% Far longer than any wait here: a close that lingers when it should not
%% shows as a missing `conn_close` event.
-define(LINGER, 60000).

suite() ->
    [{timetrap, {seconds, 60}}].

all() ->
    [
        default_serves_past_a_thousand,
        limit_lingers_over_pipelined_requests,
        server_close_lingers_over_pipelined_requests,
        server_close_without_pipelining_is_immediate,
        client_close_with_pipelining_is_immediate
    ].

init_per_suite(Config) ->
    {ok, _} = roadrunner_test_event_handler:start(),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(Case, Config) ->
    Opts = maps:merge(#{port => 0, routes => roadrunner_keepalive_handler}, opts(Case)),
    {ok, _} = roadrunner_listener:start_link(Case, Opts),
    ok = telemetry:attach(
        ?MODULE, [roadrunner, listener, conn_close], fun ?MODULE:forward/4, self()
    ),
    [{listener, Case}, {port, roadrunner_listener:port(Case)} | Config].

end_per_testcase(_Case, Config) ->
    ok = telemetry:detach(?MODULE),
    ok = roadrunner_listener:stop(?config(listener, Config)).

forward(Event, _Measurements, Metadata, Pid) ->
    Pid ! {Event, Metadata}.

opts(default_serves_past_a_thousand) ->
    #{};
opts(limit_lingers_over_pipelined_requests) ->
    #{max_keep_alive_requests => ?LIMIT};
opts(_ServerClose) ->
    %% Answers with `Connection: close`.
    #{routes => roadrunner_hello_handler, protocols => [{http1, #{linger_timeout => ?LINGER}}]}.

%% --- testcases ---

default_serves_past_a_thousand(Config) ->
    Sock = connect(Config),
    %% In batches of 100 pipelined requests, each read back in full.
    Replies = [
        begin
            ok = gen_tcp:send(Sock, binary:copy(?REQUEST, 100)),
            recv_responses(Sock, 100, <<>>)
        end
     || _ <- lists:seq(1, ?MANY div 100)
    ],
    ?assertEqual(nomatch, binary:match(iolist_to_binary(Replies), ~"connection: close")),
    %% Still open.
    ok = gen_tcp:send(Sock, ?REQUEST),
    ?assertMatch(<<"HTTP/1.1 200", _/binary>>, recv_responses(Sock, 1, <<>>)),
    ok = gen_tcp:close(Sock).

limit_lingers_over_pipelined_requests(Config) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, binary:copy(?POST_REQUEST, 2 * ?LIMIT)),
    %% The server shuts its side once the last response is out: the client
    %% reads every byte up to that end of stream, not a reset.
    {Reply, closed} = recv_until_closed(Sock, <<>>),
    [<<>> | Responses] = binary:split(Reply, ~"HTTP/1.1 200 OK\r\n", [global]),
    ?assertMatch([_, _], Responses),
    [First, Last] = Responses,
    ?assertEqual(nomatch, binary:match(First, ~"connection: close")),
    ?assertNotEqual(nomatch, binary:match(Last, ~"connection: close\r\n")),
    %% The last response arrived whole.
    ?assertMatch(<<_:(byte_size(Last) - 7)/binary, "alive\r\n">>, Last),
    ok = gen_tcp:close(Sock).

server_close_lingers_over_pipelined_requests(Config) ->
    Sock = connect(Config),
    %% The second request, body and all, is on its way before the first is
    %% answered; most of it is still unread when the connection closes.
    ok = gen_tcp:send(Sock, [?REQUEST, ?POST_REQUEST]),
    {Reply, closed} = recv_until_closed(Sock, <<>>),
    ?assertMatch([<<>>, _], binary:split(Reply, ~"HTTP/1.1 200 OK\r\n", [global])),
    ?assertMatch(<<_:(byte_size(Reply) - 20)/binary, "Hello, roadrunner!\r\n">>, Reply),
    ok = gen_tcp:close(Sock),
    ?assertMatch(#{requests_served := 1}, conn_close(Config)).

server_close_without_pipelining_is_immediate(Config) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, ?REQUEST),
    {Reply, closed} = recv_until_closed(Sock, <<>>),
    ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
    %% The client keeps its side open (`exit_on_close` is off): a lingering
    %% close would wait for it for `?LINGER` ms before the connection ends.
    ?assertMatch(#{requests_served := 1}, conn_close(Config)),
    ok = gen_tcp:close(Sock).

client_close_with_pipelining_is_immediate(Config) ->
    %% A client that asks to close has no business pipelining after that
    %% request (RFC 9112 §9.6), so the close does not wait on it.
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, [~"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", ?REQUEST]),
    ?assertMatch(#{requests_served := 1}, conn_close(Config)),
    ok = gen_tcp:close(Sock).

%% --- helpers ---

%% Waits for this testcase's listener only: a connection from an earlier
%% testcase can still fire its close event after the next one starts.
conn_close(Config) ->
    Listener = ?config(listener, Config),
    receive
        {[roadrunner, listener, conn_close], #{listener_name := Listener} = Metadata} -> Metadata
    after 5000 -> ct:fail(no_conn_close)
    end.

connect(Config) ->
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1},
        ?config(port, Config),
        [binary, {active, false}, {show_econnreset, true}, {exit_on_close, false}],
        5000
    ),
    Sock.

recv_responses(Sock, N, Acc) ->
    case length(binary:matches(Acc, ~"alive\r\n")) of
        N ->
            Acc;
        _ ->
            {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
            recv_responses(Sock, N, <<Acc/binary, Data/binary>>)
    end.

recv_until_closed(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Data} -> recv_until_closed(Sock, <<Acc/binary, Data/binary>>);
        {error, Reason} -> {Acc, Reason}
    end.
