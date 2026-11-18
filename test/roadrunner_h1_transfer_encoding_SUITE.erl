-module(roadrunner_h1_transfer_encoding_SUITE).
-moduledoc """
HTTP/1.1 request framing by `Transfer-Encoding` over a real socket. The
field's lines combine into one list (RFC 9110 §5.3), and a list that is not
`chunked` alone is answered 400 and the connection closed (RFC 9112 §6.3),
so a body framed differently by a proxy in front cannot smuggle a request.
An HTTP/1.0 request with any `Transfer-Encoding` is answered the same way
(RFC 9112 §6.1).
""".
-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_group/2, end_per_group/2, init_per_testcase/2, end_per_testcase/2]).
-export([
    chunked_then_gzip_lines_rejected/1,
    gzip_then_chunked_lines_rejected/1,
    chunked_twice_across_lines_rejected/1,
    chunked_with_empty_elements_accepted/1,
    http10_chunked_rejected/1,
    http10_chunked_with_content_length_rejected/1
]).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [{group, auto}, {group, manual}].

groups() ->
    Cases = [
        chunked_then_gzip_lines_rejected,
        gzip_then_chunked_lines_rejected,
        chunked_twice_across_lines_rejected,
        chunked_with_empty_elements_accepted,
        http10_chunked_rejected,
        http10_chunked_with_content_length_rejected
    ],
    [{auto, [], Cases}, {manual, [], Cases}].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(roadrunner),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(roadrunner).

init_per_group(Mode, Config) ->
    [{body_buffering, Mode} | Config].

end_per_group(_Mode, _Config) ->
    ok.

init_per_testcase(_Case, Config) ->
    {ok, _} = roadrunner:start_listener(?MODULE, #{
        port => 0,
        routes => roadrunner_stream_body_handler,
        body_buffering => ?config(body_buffering, Config)
    }),
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, roadrunner_listener:port(?MODULE), [binary, {active, false}]
    ),
    [{sock, Sock} | Config].

end_per_testcase(_Case, Config) ->
    ok = gen_tcp:close(?config(sock, Config)),
    ok = roadrunner:stop_listener(?MODULE).

chunked_then_gzip_lines_rejected(Config) ->
    %% Combined, the list is `chunked, gzip`: chunked is not the final
    %% coding, so the body's length is unknown.
    assert_rejected(?config(sock, Config), request([~"chunked", ~"gzip"])).

gzip_then_chunked_lines_rejected(Config) ->
    %% `gzip, chunked` ends in chunked, but gzip is not a coding roadrunner
    %% decodes.
    assert_rejected(?config(sock, Config), request([~"gzip", ~"chunked"])).

chunked_twice_across_lines_rejected(Config) ->
    %% RFC 9112 §6.1: chunked is applied at most once.
    assert_rejected(?config(sock, Config), request([~"chunked", ~"Chunked"])).

chunked_with_empty_elements_accepted(Config) ->
    %% RFC 9110 §5.6.1: empty list elements are ignored, so `, chunked ,`
    %% is chunked, and the connection stays open for the next request.
    Sock = ?config(sock, Config),
    ok = gen_tcp:send(Sock, request([~", chunked ,"])),
    ?assertEqual({200, ~"hello"}, recv_response(Sock)),
    ok = gen_tcp:send(Sock, request([~"chunked"])),
    ?assertEqual({200, ~"hello"}, recv_response(Sock)).

http10_chunked_rejected(Config) ->
    %% RFC 9112 §6.1: an HTTP/1.0 request with Transfer-Encoding has faulty
    %% framing, even with `chunked` alone.
    assert_rejected(?config(sock, Config), request(~"HTTP/1.0", [~"chunked"], [])).

http10_chunked_with_content_length_rejected(Config) ->
    %% "even if a Content-Length is present".
    assert_rejected(
        ?config(sock, Config),
        request(~"HTTP/1.0", [~"chunked"], [~"Content-Length: 15\r\n"])
    ).

%% --- helpers ---

%% The request carries a chunked body and, behind it, a second request a
%% chunked reading would take as pipelined: neither must be answered past
%% the 400, and the server closes.
assert_rejected(Sock, Request) ->
    ok = gen_tcp:send(Sock, [Request, ~"GET /smuggled HTTP/1.1\r\nHost: x\r\n\r\n"]),
    Reply = recv_until_closed(Sock, <<>>),
    ?assertMatch(<<"HTTP/1.1 400 ", _/binary>>, Reply),
    ?assertEqual(nomatch, binary:match(Reply, ~"HTTP/1.1 ", [{scope, {1, byte_size(Reply) - 1}}])).

request(Lines) ->
    request(~"HTTP/1.1", Lines, []).

request(Version, Lines, Extra) ->
    [
        [~"POST /echo-keepalive ", Version, ~"\r\nHost: x\r\n"],
        [[~"Transfer-Encoding: ", L, ~"\r\n"] || L <- Lines],
        Extra,
        ~"\r\n5\r\nhello\r\n0\r\n\r\n"
    ].

recv_until_closed(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Data} -> recv_until_closed(Sock, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc
    end.

recv_response(Sock) ->
    recv_response(Sock, <<>>).

recv_response(Sock, Acc) ->
    maybe
        [Head, Body] ?= binary:split(Acc, ~"\r\n\r\n"),
        {match, [Length]} ?=
            re:run(Head, ~"content-length: (\\d+)", [caseless, {capture, all_but_first, binary}]),
        N = binary_to_integer(Length),
        true ?= byte_size(Body) >= N,
        <<"HTTP/1.1 ", Code:3/binary, _/binary>> = Head,
        {binary_to_integer(Code), binary:part(Body, 0, N)}
    else
        _ ->
            {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
            recv_response(Sock, <<Acc/binary, Data/binary>>)
    end.
