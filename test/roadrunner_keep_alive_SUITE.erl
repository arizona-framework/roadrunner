-module(roadrunner_keep_alive_SUITE).
-moduledoc """
How many requests an HTTP/1.1 connection serves (`max_keep_alive_requests`):
without a limit, as many as the client sends; with one, the response that
reaches it says `Connection: close`, and the close lingers over the requests
the client pipelined behind it, so the client reads that response instead of
losing it to a reset.
""".

-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([
    default_serves_past_a_thousand/1,
    limit_lingers_over_pipelined_requests/1
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

suite() ->
    [{timetrap, {seconds, 60}}].

all() ->
    [default_serves_past_a_thousand, limit_lingers_over_pipelined_requests].

init_per_testcase(Case, Config) ->
    Opts = maps:merge(#{port => 0, routes => roadrunner_keepalive_handler}, opts(Case)),
    {ok, _} = roadrunner_listener:start_link(Case, Opts),
    [{listener, Case}, {port, roadrunner_listener:port(Case)} | Config].

end_per_testcase(_Case, Config) ->
    ok = roadrunner_listener:stop(?config(listener, Config)).

opts(default_serves_past_a_thousand) ->
    #{};
opts(limit_lingers_over_pipelined_requests) ->
    #{max_keep_alive_requests => ?LIMIT}.

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

%% --- helpers ---

connect(Config) ->
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1},
        ?config(port, Config),
        [binary, {active, false}, {show_econnreset, true}],
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
