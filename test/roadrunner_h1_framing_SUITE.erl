-module(roadrunner_h1_framing_SUITE).
-moduledoc """
HTTP/1.1 framing of buffered responses built as plain tuples: one without
`content-length` or `transfer-encoding` gets a `content-length` from its body,
so a kept-alive connection can find where it ends.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([
    binary_body_gets_content_length/1,
    iolist_body_gets_its_size/1,
    head_gets_the_get_length/1,
    own_content_length_is_kept/1,
    chunked_response_is_left_alone/1,
    no_content_gets_no_content_length/1
]).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        binary_body_gets_content_length,
        iolist_body_gets_its_size,
        head_gets_the_get_length,
        own_content_length_is_kept,
        chunked_response_is_left_alone,
        no_content_gets_no_content_length
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(roadrunner),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(roadrunner).

init_per_testcase(_Case, Config) ->
    {ok, _} = roadrunner:start_listener(?MODULE, #{
        port => 0, routes => roadrunner_unframed_handler
    }),
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, roadrunner_listener:port(?MODULE), [binary, {active, false}]
    ),
    [{sock, Sock} | Config].

end_per_testcase(_Case, Config) ->
    ok = gen_tcp:close(?config(sock, Config)),
    ok = roadrunner:stop_listener(?MODULE).

binary_body_gets_content_length(Config) ->
    %% Two requests on one connection: the first response's length must
    %% let the second one be read.
    Sock = ?config(sock, Config),
    ?assertMatch({200, #{~"content-length" := [~"5"]}, ~"hello"}, get(Sock, ~"/binary")),
    ?assertMatch({200, _, ~"hello"}, get(Sock, ~"/binary")).

iolist_body_gets_its_size(Config) ->
    Sock = ?config(sock, Config),
    ?assertMatch({200, #{~"content-length" := [~"5"]}, ~"abcde"}, get(Sock, ~"/iolist")),
    ?assertMatch({200, _, ~"abcde"}, get(Sock, ~"/iolist")).

head_gets_the_get_length(Config) ->
    %% HEAD sends no body but reports the length a GET would send.
    Sock = ?config(sock, Config),
    ok = gen_tcp:send(Sock, ~"HEAD /binary HTTP/1.1\r\nHost: x\r\n\r\n"),
    {200, Headers, <<>>} = recv_head(Sock),
    ?assertMatch(#{~"content-length" := [~"5"]}, Headers),
    ?assertMatch({200, _, ~"hello"}, get(Sock, ~"/binary")).

own_content_length_is_kept(Config) ->
    Sock = ?config(sock, Config),
    ?assertMatch({200, #{~"content-length" := [~"5"]}, ~"hello"}, get(Sock, ~"/own-length")).

chunked_response_is_left_alone(Config) ->
    Sock = ?config(sock, Config),
    ok = gen_tcp:send(Sock, ~"GET /chunked HTTP/1.1\r\nHost: x\r\n\r\n"),
    {200, Headers, Rest} = recv_head(Sock),
    ?assertNot(is_map_key(~"content-length", Headers)),
    ?assertEqual(~"5\r\nhello\r\n0\r\n\r\n", recv_rest(Sock, Rest, 15)).

no_content_gets_no_content_length(Config) ->
    %% RFC 9110 §8.6: no `content-length` on a 204.
    Sock = ?config(sock, Config),
    ok = gen_tcp:send(Sock, ~"GET /no-content HTTP/1.1\r\nHost: x\r\n\r\n"),
    {204, Headers, <<>>} = recv_head(Sock),
    ?assertNot(is_map_key(~"content-length", Headers)),
    ?assertMatch({200, _, ~"hello"}, get(Sock, ~"/binary")).

%% --- helpers ---

%% One GET on the kept-alive connection: reads exactly `content-length`
%% bytes of body, so a missing or wrong length shows up as a stuck or
%% garbled next response rather than being hidden by a read to close.
get(Sock, Path) ->
    ok = gen_tcp:send(Sock, [~"GET ", Path, ~" HTTP/1.1\r\nHost: x\r\n\r\n"]),
    {Status, Headers, Rest} = recv_head(Sock),
    #{~"content-length" := [Length]} = Headers,
    {Status, Headers, recv_rest(Sock, Rest, binary_to_integer(Length))}.

%% The status, headers (name to list of values), and any body bytes
%% already read past the head.
recv_head(Sock) ->
    recv_head(Sock, <<>>).

recv_head(Sock, Acc) ->
    case binary:split(Acc, ~"\r\n\r\n") of
        [Head, Rest] ->
            [<<"HTTP/1.1 ", Code:3/binary, _/binary>> | Lines] = binary:split(
                Head, ~"\r\n", [global]
            ),
            {binary_to_integer(Code), headers(Lines), Rest};
        [_] ->
            {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
            recv_head(Sock, <<Acc/binary, Data/binary>>)
    end.

headers(Lines) ->
    lists:foldl(
        fun(Line, Acc) ->
            [Name, Value] = binary:split(Line, ~": "),
            maps:update_with(Name, fun(Vs) -> [Value | Vs] end, [Value], Acc)
        end,
        #{},
        Lines
    ).

recv_rest(_Sock, Rest, Length) when byte_size(Rest) =:= Length ->
    Rest;
recv_rest(Sock, Rest, Length) ->
    {ok, More} = gen_tcp:recv(Sock, Length - byte_size(Rest), 5000),
    <<Rest/binary, More/binary>>.
