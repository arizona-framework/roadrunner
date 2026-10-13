-module(roadrunner_route_body_cap_SUITE).
-moduledoc """
A route's own `max_content_length` over HTTP/1.1 (buffered and manual body
reads) and HTTP/2 (h2c). The listener caps bodies at 8 bytes; `/up` raises
its cap to 64, `/small` lowers it to 2 and `/plain` keeps the listener's. The
HTTP/3 cases live in `roadrunner_http3_SUITE`.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    suite/0,
    all/0,
    groups/0,
    init_per_group/2,
    end_per_group/2,
    init_per_testcase/2,
    end_per_testcase/2
]).
-export([
    body_within_raised_cap/1,
    body_over_raised_cap/1,
    body_over_lowered_cap/1,
    route_without_cap_keeps_listener_cap/1,
    unmatched_path_keeps_listener_cap/1,
    chunked_body_within_raised_cap/1,
    expect_continue_within_raised_cap/1,
    expect_continue_over_lowered_cap/1,
    h2_body_within_raised_cap/1,
    h2_body_over_raised_cap/1,
    h2_body_over_lowered_cap/1,
    h2_route_without_cap_keeps_listener_cap/1,
    h2_expect_continue_within_raised_cap/1,
    h2_expect_continue_over_lowered_cap/1,
    h2_expect_continue_without_length/1
]).

-define(LISTENER_CAP, 8).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [{group, http1}, {group, http1_manual}, {group, http2}].

groups() ->
    Http1 = [
        body_within_raised_cap,
        body_over_raised_cap,
        body_over_lowered_cap,
        route_without_cap_keeps_listener_cap,
        chunked_body_within_raised_cap,
        expect_continue_within_raised_cap,
        expect_continue_over_lowered_cap
    ],
    [
        {http1, [], [unmatched_path_keeps_listener_cap | Http1]},
        {http1_manual, [], Http1},
        {http2, [], [
            h2_body_within_raised_cap,
            h2_body_over_raised_cap,
            h2_body_over_lowered_cap,
            h2_route_without_cap_keeps_listener_cap,
            h2_expect_continue_within_raised_cap,
            h2_expect_continue_over_lowered_cap,
            h2_expect_continue_without_length
        ]}
    ].

init_per_group(http1, Config) ->
    [{listener_opts, #{protocols => [http1]}} | Config];
init_per_group(http1_manual, Config) ->
    [{listener_opts, #{protocols => [http1], body_buffering => manual}} | Config];
init_per_group(http2, Config) ->
    [{listener_opts, #{protocols => [http2]}} | Config].

end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(_Case, Config) ->
    {ok, _} = application:ensure_all_started(telemetry),
    {ok, _} = roadrunner_listener:start_link(
        ?MODULE,
        maps:merge(
            #{
                port => 0,
                max_content_length => ?LISTENER_CAP,
                routes => [
                    #{
                        path => ~"/up",
                        handler => roadrunner_body_size_handler,
                        max_content_length => 64
                    },
                    #{
                        path => ~"/small",
                        handler => roadrunner_body_size_handler,
                        max_content_length => 2
                    },
                    {~"/plain", roadrunner_body_size_handler}
                ]
            },
            ?config(listener_opts, Config)
        )
    ),
    [{port, roadrunner_listener:port(?MODULE)} | Config].

end_per_testcase(_Case, _Config) ->
    ok = roadrunner_listener:stop(?MODULE).

%% =============================================================================
%% HTTP/1.1
%% =============================================================================

body_within_raised_cap(Config) ->
    ?assertEqual({200, ~"20"}, h1_post(Config, ~"/up", binary:copy(~"x", 20))).

body_over_raised_cap(Config) ->
    ?assertMatch({413, _}, h1_post(Config, ~"/up", binary:copy(~"x", 65))).

body_over_lowered_cap(Config) ->
    ?assertMatch({413, _}, h1_post(Config, ~"/small", ~"abc")).

route_without_cap_keeps_listener_cap(Config) ->
    ?assertEqual({200, ~"8"}, h1_post(Config, ~"/plain", binary:copy(~"x", 8))),
    ?assertMatch({413, _}, h1_post(Config, ~"/plain", binary:copy(~"x", 9))).

unmatched_path_keeps_listener_cap(Config) ->
    %% A request no route answers still has its body read, under the
    %% listener's cap, before the 404.
    ?assertMatch({404, _}, h1_post(Config, ~"/missing", ~"abc")),
    ?assertMatch({413, _}, h1_post(Config, ~"/missing", binary:copy(~"x", 20))).

chunked_body_within_raised_cap(Config) ->
    Reply = h1_exchange(Config, [
        ~"POST /up HTTP/1.1\r\nHost: x\r\nConnection: close\r\n",
        ~"Transfer-Encoding: chunked\r\n\r\n",
        ~"a\r\n0123456789\r\na\r\n0123456789\r\n0\r\n\r\n"
    ]),
    ?assertEqual({200, ~"20"}, status_body(Reply)).

expect_continue_within_raised_cap(Config) ->
    %% The declared length is over the listener's cap but within the
    %% route's, so the client is asked for its body.
    {ok, Sock} = h1_connect(Config),
    ok = gen_tcp:send(Sock, expect_head(~"/up", 20)),
    {ok, Interim} = gen_tcp:recv(Sock, 0, 5000),
    ?assertEqual(~"HTTP/1.1 100 Continue\r\n\r\n", Interim),
    ok = gen_tcp:send(Sock, binary:copy(~"x", 20)),
    ?assertEqual({200, ~"20"}, status_body(recv_until_closed(Sock, <<>>))).

expect_continue_over_lowered_cap(Config) ->
    %% Over the route's cap: the final 413 comes first, with no 100 asking
    %% for a body that would be refused.
    {ok, Sock} = h1_connect(Config),
    ok = gen_tcp:send(Sock, expect_head(~"/small", 3)),
    ?assertMatch({413, _}, status_body(recv_until_closed(Sock, <<>>))).

%% =============================================================================
%% HTTP/2 (h2c)
%% =============================================================================

h2_body_within_raised_cap(Config) ->
    %% Three DATA frames: the second takes the body past the listener's cap,
    %% the route raises it, and the third is held to the raised cap.
    Chunk = binary:copy(~"x", 7),
    ?assertEqual(
        {[200], ~"21"}, h2_request(Config, ~"/up", [], [Chunk, Chunk, Chunk])
    ).

h2_body_over_raised_cap(Config) ->
    ?assertMatch({[413], _}, h2_request(Config, ~"/up", [], [binary:copy(~"x", 65)])).

h2_body_over_lowered_cap(Config) ->
    %% The connection holds the body to the listener's cap; the route's
    %% smaller one is applied once the request is routed.
    ?assertMatch({[413], _}, h2_request(Config, ~"/small", [], [~"abc"])).

h2_route_without_cap_keeps_listener_cap(Config) ->
    ?assertEqual({[200], ~"8"}, h2_request(Config, ~"/plain", [], [binary:copy(~"x", 8)])),
    ?assertMatch({[413], _}, h2_request(Config, ~"/plain", [], [binary:copy(~"x", 9)])).

h2_expect_continue_within_raised_cap(Config) ->
    Expect = [{~"content-length", ~"20"}, {~"expect", ~"100-continue"}],
    ?assertEqual(
        {[100, 200], ~"20"}, h2_request(Config, ~"/up", Expect, [binary:copy(~"x", 20)])
    ).

h2_expect_continue_over_lowered_cap(Config) ->
    %% Answered from the headers alone; the body is never sent.
    Expect = [{~"content-length", ~"3"}, {~"expect", ~"100-continue"}],
    ?assertMatch({[413], _}, h2_request(Config, ~"/small", Expect, [])).

h2_expect_continue_without_length(Config) ->
    %% No declared length to hold against a cap: the client is asked for
    %% its body, and the cap applies as it arrives.
    Expect = [{~"expect", ~"100-continue"}],
    ?assertEqual({[100, 200], ~"5"}, h2_request(Config, ~"/plain", Expect, [~"abcde"])).

%% =============================================================================
%% Helpers
%% =============================================================================

h1_connect(Config) ->
    gen_tcp:connect({127, 0, 0, 1}, ?config(port, Config), [binary, {active, false}], 5000).

h1_post(Config, Path, Body) ->
    status_body(
        h1_exchange(Config, [
            ~"POST ",
            Path,
            ~" HTTP/1.1\r\nHost: x\r\nConnection: close\r\nContent-Length: ",
            integer_to_binary(byte_size(Body)),
            ~"\r\n\r\n",
            Body
        ])
    ).

h1_exchange(Config, Request) ->
    {ok, Sock} = h1_connect(Config),
    ok = gen_tcp:send(Sock, Request),
    recv_until_closed(Sock, <<>>).

expect_head(Path, Length) ->
    [
        ~"POST ",
        Path,
        ~" HTTP/1.1\r\nHost: x\r\nConnection: close\r\nExpect: 100-continue\r\n",
        ~"Content-Length: ",
        integer_to_binary(Length),
        ~"\r\n\r\n"
    ].

recv_until_closed(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Data} ->
            recv_until_closed(Sock, <<Acc/binary, Data/binary>>);
        {error, closed} ->
            ok = gen_tcp:close(Sock),
            Acc
    end.

status_body(<<"HTTP/1.1 ", Code:3/binary, _/binary>> = Reply) ->
    [_Head, Body] = binary:split(Reply, ~"\r\n\r\n"),
    {binary_to_integer(Code), Body}.

%% One h2c request on its own connection: HEADERS with `Extra` fields, then
%% each of `Chunks` as a DATA frame (the last one ending the stream). With
%% an `expect` field the body goes out only after the 100. Returns every
%% status the stream got and its response body.
h2_request(Config, Path, Extra, Chunks) ->
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, ?config(port, Config), [binary, {active, false}], 5000
    ),
    {Block, _Enc} = roadrunner_http2_hpack:encode(
        [
            {~":method", ~"POST"},
            {~":scheme", ~"http"},
            {~":authority", ~"x"},
            {~":path", Path}
            | Extra
        ],
        roadrunner_http2_hpack:new_encoder(4096)
    ),
    %% A client waiting for its 100 keeps the stream open.
    Expects = lists:keymember(~"expect", 1, Extra),
    EndStream =
        case {Chunks, Expects} of
            {[], false} -> 16#01;
            _ -> 0
        end,
    ok = gen_tcp:send(Sock, [
        ~"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n",
        roadrunner_http2_frame:encode({settings, 0, []}),
        roadrunner_http2_frame:encode({headers, 1, 16#04 bor EndStream, undefined, Block})
    ]),
    Dec = roadrunner_http2_hpack:new_decoder(4096),
    case Expects of
        true ->
            case h2_recv(Sock, <<>>, Dec, {[], <<>>}) of
                {{[100], <<>>}, Buf, Dec1} ->
                    ok = send_data(Sock, Chunks),
                    h2_response(Sock, Buf, Dec1, {[100], <<>>});
                {Final, _Buf, _Dec1} ->
                    h2_close(Sock, Final)
            end;
        false ->
            ok = send_data(Sock, Chunks),
            h2_response(Sock, <<>>, Dec, {[], <<>>})
    end.

send_data(_Sock, []) ->
    ok;
send_data(Sock, [Last]) ->
    gen_tcp:send(Sock, roadrunner_http2_frame:encode({data, 1, 16#01, Last}));
send_data(Sock, [Chunk | Rest]) ->
    ok = gen_tcp:send(Sock, roadrunner_http2_frame:encode({data, 1, 0, Chunk})),
    send_data(Sock, Rest).

h2_response(Sock, Buf, Dec, Acc) ->
    {Final, _Buf, _Dec} = h2_recv(Sock, Buf, Dec, Acc),
    h2_close(Sock, Final).

h2_close(Sock, {Statuses, Body}) ->
    ok = gen_tcp:close(Sock),
    {lists:reverse(Statuses), Body}.

%% Read stream 1's frames until it ends or sends a 100 (returned as soon as
%% it arrives, so the caller can send the body). The HPACK decoder is
%% threaded, as it is per connection.
h2_recv(Sock, Buf, Dec, {Statuses, Body} = Acc) ->
    case roadrunner_http2_frame:parse(Buf, 16384) of
        {ok, {headers, 1, Flags, _Priority, Block}, Rest} ->
            {ok, Headers, Dec1} = roadrunner_http2_hpack:decode(Block, Dec),
            {_, Status} = lists:keyfind(~":status", 1, Headers),
            Acc1 = {[binary_to_integer(Status) | Statuses], Body},
            case {Status, Flags band 16#01} of
                {~"100", _} -> {Acc1, Rest, Dec1};
                {_, 0} -> h2_recv(Sock, Rest, Dec1, Acc1);
                {_, _} -> {Acc1, Rest, Dec1}
            end;
        {ok, {data, 1, Flags, Data, _FlowLen}, Rest} ->
            Acc1 = {Statuses, <<Body/binary, Data/binary>>},
            case Flags band 16#01 of
                0 -> h2_recv(Sock, Rest, Dec, Acc1);
                _ -> {Acc1, Rest, Dec}
            end;
        {ok, _Other, Rest} ->
            h2_recv(Sock, Rest, Dec, Acc);
        _More ->
            {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
            h2_recv(Sock, <<Buf/binary, Data/binary>>, Dec, Acc)
    end.
