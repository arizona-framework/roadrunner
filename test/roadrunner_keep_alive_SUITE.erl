-module(roadrunner_keep_alive_SUITE).
-moduledoc """
How many requests an HTTP/1.1 connection serves (`max_keep_alive_requests`):
without a limit, as many as the client sends.
""".

-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([
    default_serves_past_a_thousand/1
]).

%% Past the ceiling the default used to have.
-define(MANY, 1500).
-define(REQUEST, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n").

suite() ->
    [{timetrap, {seconds, 60}}].

all() ->
    [default_serves_past_a_thousand].

init_per_testcase(Case, Config) ->
    Opts = maps:merge(#{port => 0, routes => roadrunner_keepalive_handler}, opts(Case)),
    {ok, _} = roadrunner_listener:start_link(Case, Opts),
    [{listener, Case}, {port, roadrunner_listener:port(Case)} | Config].

end_per_testcase(_Case, Config) ->
    ok = roadrunner_listener:stop(?config(listener, Config)).

opts(default_serves_past_a_thousand) ->
    #{}.

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

%% --- helpers ---

connect(Config) ->
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, ?config(port, Config), [binary, {active, false}], 5000
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
