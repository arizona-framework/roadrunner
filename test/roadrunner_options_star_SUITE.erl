-module(roadrunner_options_star_SUITE).
-moduledoc """
`OPTIONS *` over HTTP/1.1 and HTTP/2 (RFC 9110 §9.3.7): a listener with
routes answers it itself, a `200` with an empty body that keeps the
connection open, without reaching a route or a middleware; a listener
with a single handler hands it to that handler. Any other method with
the asterisk-form target stays a bad request. HTTP/3 is covered in
`roadrunner_http3_SUITE`.
""".

-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_testcase/2, end_per_testcase/2]).
-export([mark/3]).
-export([
    h1_router_answers_options_star/1,
    h1_single_handler_gets_options_star/1,
    h1_other_method_with_star_is_bad_request/1,
    h2_router_answers_options_star/1,
    h2_other_method_with_star_is_malformed/1
]).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        h1_router_answers_options_star,
        h1_single_handler_gets_options_star,
        h1_other_method_with_star_is_bad_request,
        h2_router_answers_options_star,
        h2_other_method_with_star_is_malformed
    ].

init_per_testcase(Case, Config) ->
    {ok, _} = roadrunner_listener:start_link(?MODULE, listener_opts(Case)),
    [{port, roadrunner_listener:port(?MODULE)} | Config].

end_per_testcase(_Case, _Config) ->
    ok = roadrunner_listener:stop(?MODULE).

%% Routes a `*` path would match if it were routed: a root param and a
%% root wildcard. The listener middleware marks every response it wraps.
listener_opts(h1_single_handler_gets_options_star) ->
    #{port => 0, routes => roadrunner_test_handler};
listener_opts(Case) ->
    #{
        port => 0,
        protocols => [protocol(Case)],
        middlewares => [{fun mark/3, undefined}],
        routes => [
            {~"/", roadrunner_keepalive_handler},
            {~"/:id", roadrunner_test_handler},
            {~"/*path", roadrunner_test_handler}
        ]
    }.

%% A listener middleware that marks the response it passes on.
mark(Req, Next, _State) ->
    {{Status, Headers, Body}, Req2} = Next(Req),
    {{Status, [{~"x-mw", ~"yes"} | Headers], Body}, Req2}.

protocol(h2_router_answers_options_star) -> {http2, #{}};
protocol(h2_other_method_with_star_is_malformed) -> {http2, #{}};
protocol(_Case) -> http1.

%% =============================================================================
%% Cases
%% =============================================================================

h1_router_answers_options_star(Config) ->
    Sock = h1_connect(Config),
    ok = gen_tcp:send(Sock, ~"OPTIONS * HTTP/1.1\r\nHost: x\r\n\r\n"),
    {Head, <<>>} = h1_head(Sock, <<>>),
    ?assertMatch(<<"HTTP/1.1 200 OK\r\n", _/binary>>, Head),
    ?assertNotEqual(nomatch, binary:match(Head, ~"content-length: 0\r\n")),
    ?assertEqual(nomatch, binary:match(Head, ~"x-mw")),
    ?assertEqual(nomatch, binary:match(Head, ~"connection: close")),
    %% The connection stays open for the next request.
    ok = gen_tcp:send(Sock, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"),
    {Head2, _Body} = h1_head(Sock, <<>>),
    ?assertMatch(<<"HTTP/1.1 200 OK\r\n", _/binary>>, Head2),
    ?assertNotEqual(nomatch, binary:match(Head2, ~"x-mw: yes")),
    ok = gen_tcp:close(Sock).

h1_single_handler_gets_options_star(Config) ->
    %% A single handler answers every request the listener takes, the
    %% asterisk-form one included.
    Sock = h1_connect(Config),
    ok = gen_tcp:send(Sock, ~"OPTIONS * HTTP/1.1\r\nHost: x\r\n\r\n"),
    {Head, _Body} = h1_head(Sock, <<>>),
    ?assertMatch(<<"HTTP/1.1 201 ", _/binary>>, Head),
    ok = gen_tcp:close(Sock).

h1_other_method_with_star_is_bad_request(Config) ->
    Sock = h1_connect(Config),
    ok = gen_tcp:send(Sock, ~"GET * HTTP/1.1\r\nHost: x\r\n\r\n"),
    {Head, _Body} = h1_head(Sock, <<>>),
    ?assertMatch(<<"HTTP/1.1 400 ", _/binary>>, Head),
    ok = gen_tcp:close(Sock).

h2_router_answers_options_star(Config) ->
    C0 = h2_open(Config),
    C1 = h2_send_headers(C0, 1, ~"OPTIONS", ~"*"),
    {200, Headers, <<>>, C2} = h2_response(C1, 1),
    ?assertEqual(false, lists:keyfind(~"x-mw", 1, Headers)),
    C3 = h2_send_headers(C2, 3, ~"GET", ~"/"),
    {200, Headers3, ~"alive\r\n", _C4} = h2_response(C3, 3),
    ?assertEqual({~"x-mw", ~"yes"}, lists:keyfind(~"x-mw", 1, Headers3)).

h2_other_method_with_star_is_malformed(Config) ->
    %% A malformed request (RFC 9113 §8.1.1): its stream is reset with
    %% PROTOCOL_ERROR, and the connection lives on.
    C0 = h2_open(Config),
    C1 = h2_send_headers(C0, 1, ~"GET", ~"*"),
    {{rst_stream, 1, protocol_error}, C2} = h2_until(C1, fun(F) -> element(1, F) =:= rst_stream end),
    C3 = h2_send_headers(C2, 3, ~"GET", ~"/"),
    {200, _Headers, ~"alive\r\n", _C4} = h2_response(C3, 3).

%% =============================================================================
%% HTTP/1.1 client
%% =============================================================================

h1_connect(Config) ->
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, ?config(port, Config), [binary, {active, false}], 5000
    ),
    Sock.

%% A response head, up to its blank line, and what came after it.
h1_head(Sock, Buf) ->
    case binary:split(Buf, ~"\r\n\r\n") of
        [Head, Rest] ->
            {<<Head/binary, "\r\n">>, Rest};
        [_] ->
            {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
            h1_head(Sock, <<Buf/binary, Data/binary>>)
    end.

%% =============================================================================
%% HTTP/2 client (prior knowledge, plain TCP)
%% =============================================================================

h2_open(Config) ->
    Sock = h1_connect(Config),
    ok = gen_tcp:send(Sock, [
        ~"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", roadrunner_http2_frame:encode({settings, 0, []})
    ]),
    #{
        sock => Sock,
        buf => <<>>,
        enc => roadrunner_http2_hpack:new_encoder(4096),
        dec => roadrunner_http2_hpack:new_decoder(4096)
    }.

%% A request without a body (END_STREAM | END_HEADERS).
h2_send_headers(#{sock := Sock, enc := Enc} = C, StreamId, Method, Path) ->
    Fields = [
        {~":method", Method},
        {~":scheme", ~"http"},
        {~":authority", ~"x"},
        {~":path", Path}
    ],
    {Block, Enc1} = roadrunner_http2_hpack:encode(Fields, Enc),
    ok = gen_tcp:send(
        Sock, roadrunner_http2_frame:encode({headers, StreamId, 16#05, undefined, Block})
    ),
    C#{enc := Enc1}.

%% Stream `StreamId`'s status, headers and body, and the connection after.
h2_response(C, StreamId) ->
    h2_response(C, StreamId, undefined, [], <<>>).

h2_response(C, StreamId, Status, Headers, Body) ->
    case h2_next_frame(C) of
        {{headers, StreamId, Flags, Fields}, C1} ->
            {_, S} = lists:keyfind(~":status", 1, Fields),
            h2_end(C1, StreamId, Flags, binary_to_integer(S), Fields, Body);
        {{data, StreamId, Flags, Data, _}, C1} ->
            h2_end(C1, StreamId, Flags, Status, Headers, <<Body/binary, Data/binary>>);
        {_Other, C1} ->
            h2_response(C1, StreamId, Status, Headers, Body)
    end.

h2_end(C, StreamId, Flags, Status, Headers, Body) ->
    case Flags band 16#01 of
        0 -> h2_response(C, StreamId, Status, Headers, Body);
        _ -> {Status, Headers, Body, C}
    end.

%% The first frame `Pred` picks, and the connection after it.
h2_until(C, Pred) ->
    {Frame, C1} = h2_next_frame(C),
    case Pred(Frame) of
        true -> {Frame, C1};
        false -> h2_until(C1, Pred)
    end.

h2_next_frame(#{sock := Sock, buf := Buf, dec := Dec} = C) ->
    case roadrunner_http2_frame:parse(Buf, 16384) of
        {ok, {headers, StreamId, Flags, _Priority, Block}, Rest} ->
            {ok, Fields, Dec1} = roadrunner_http2_hpack:decode(Block, Dec),
            {{headers, StreamId, Flags, Fields}, C#{buf := Rest, dec := Dec1}};
        {ok, Frame, Rest} ->
            {Frame, C#{buf := Rest}};
        _More ->
            {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
            h2_next_frame(C#{buf := <<Buf/binary, Data/binary>>})
    end.
