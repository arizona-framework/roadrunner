-module(roadrunner_shed_SUITE).
-moduledoc """
`overload_mode => {shed, _}` over HTTP/1.1 and HTTP/2 (h2c). The ceiling
is 1 and a handler holds the only slot, so the next request is over it:
it is answered `503 Service Unavailable` with `Retry-After` before any
handler runs, and counted as throttled. HTTP/3 is covered next to its
other ceiling cases in `roadrunner_http3_SUITE`.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([
    h1_request_over_the_ceiling_gets_503/1,
    h1_shed_request_is_answered_before_its_body/1,
    h1_slot_is_released_between_requests/1,
    h1_slot_is_released_on_close/1,
    h1_refuse_mode_leaves_http1_out/1,
    h2_stream_over_the_ceiling_gets_503/1
]).

-define(COLLECTOR, roadrunner_h2_slot_collector).

suite() ->
    [{timetrap, {seconds, 60}}].

all() ->
    [
        h1_request_over_the_ceiling_gets_503,
        h1_shed_request_is_answered_before_its_body,
        h1_slot_is_released_between_requests,
        h1_slot_is_released_on_close,
        h1_refuse_mode_leaves_http1_out,
        h2_stream_over_the_ceiling_gets_503
    ].

init_per_suite(Config) ->
    {ok, _} = roadrunner_test_event_handler:start(),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(Case, Config) ->
    Opts = maps:merge(
        #{
            port => 0,
            routes => roadrunner_h2_slot_handler,
            max_concurrent_requests => 1,
            overload_mode => {shed, #{retry_after => 7}}
        },
        case_opts(Case)
    ),
    {ok, _} = roadrunner_listener:start_link(Case, Opts),
    [{listener, Case}, {port, roadrunner_listener:port(Case)} | Config].

end_per_testcase(_Case, Config) ->
    ok = roadrunner_listener:stop(?config(listener, Config)).

case_opts(h1_refuse_mode_leaves_http1_out) -> #{overload_mode => refuse};
case_opts(h2_stream_over_the_ceiling_gets_503) -> #{protocols => [http2]};
case_opts(_Case) -> #{}.

%% --- testcases ---

h1_request_over_the_ceiling_gets_503(Config) ->
    true = register(?COLLECTOR, self()),
    Throttled = attach(throttled),
    Holder = connect(Config),
    ok = gen_tcp:send(Holder, get_request()),
    First = expect_handler(),
    %% The slot is held, so a request on another connection is shed: a
    %% bodyless 503 with the configured Retry-After, and the close.
    Shed = connect(Config),
    ok = gen_tcp:send(Shed, get_request()),
    Reply = recv_until_closed(Shed, <<>>),
    ?assertMatch(<<"HTTP/1.1 503 Service Unavailable\r\n", _/binary>>, Reply),
    [Head, Body] = binary:split(Reply, ~"\r\n\r\n"),
    Headers = binary:split(Head, ~"\r\n", [global]),
    ?assert(lists:member(~"retry-after: 7", Headers)),
    ?assert(lists:member(~"connection: close", Headers)),
    ?assert(lists:member(~"content-length: 0", Headers)),
    ?assertEqual(~"", Body),
    %% Counted and reported like a refused request, and no handler ran.
    ?assertEqual(max_concurrent_requests, throttled_reason(Throttled)),
    ?assertMatch(#{throttled := 1}, roadrunner_listener:info(?config(listener, Config))),
    ?assertEqual(none, handler_started()),
    First ! release,
    ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, recv_response(Holder, <<>>)),
    ok = gen_tcp:close(Holder).

h1_shed_request_is_answered_before_its_body(Config) ->
    %% A request framing a large body is shed from its headers: the 503
    %% arrives while the client is still holding the body back.
    true = register(?COLLECTOR, self()),
    Holder = connect(Config),
    ok = gen_tcp:send(Holder, get_request()),
    First = expect_handler(),
    Shed = connect(Config),
    ok = gen_tcp:send(
        Shed, ~"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 1000000\r\n\r\n"
    ),
    ?assertMatch(<<"HTTP/1.1 503 ", _/binary>>, recv_response(Shed, <<>>)),
    ok = gen_tcp:close(Shed),
    First ! release,
    ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, recv_response(Holder, <<>>)),
    ok = gen_tcp:close(Holder).

h1_slot_is_released_between_requests(Config) ->
    %% A kept-alive connection hands its slot back after each response, so
    %% with a ceiling of 1 its next request is admitted rather than shed.
    true = register(?COLLECTOR, self()),
    Sock = connect(Config),
    lists:foreach(
        fun(_) ->
            ok = gen_tcp:send(Sock, get_request()),
            expect_handler() ! release,
            ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, recv_response(Sock, <<>>))
        end,
        [1, 2, 3]
    ),
    ok = gen_tcp:close(Sock),
    ?assertMatch(#{throttled := 0}, roadrunner_listener:info(?config(listener, Config))).

h1_slot_is_released_on_close(Config) ->
    %% A connection that closes after its response gives the slot back on
    %% its way out, so the next connection is admitted.
    true = register(?COLLECTOR, self()),
    Closing = connect(Config),
    ok = gen_tcp:send(Closing, ~"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"),
    expect_handler() ! release,
    ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, recv_until_closed(Closing, <<>>)),
    Next = connect(Config),
    ok = gen_tcp:send(Next, get_request()),
    expect_handler() ! release,
    ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, recv_response(Next, <<>>)),
    ok = gen_tcp:close(Next).

h1_refuse_mode_leaves_http1_out(Config) ->
    %% Outside shed mode HTTP/1 does not count against the ceiling, as
    %% before: with the only slot's worth of handlers already running, a
    %% second HTTP/1 request still runs its handler.
    true = register(?COLLECTOR, self()),
    First = connect(Config),
    ok = gen_tcp:send(First, get_request()),
    FirstHandler = expect_handler(),
    Second = connect(Config),
    ok = gen_tcp:send(Second, get_request()),
    SecondHandler = expect_handler(),
    FirstHandler ! release,
    SecondHandler ! release,
    ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, recv_response(First, <<>>)),
    ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, recv_response(Second, <<>>)),
    ok = gen_tcp:close(First),
    ok = gen_tcp:close(Second).

h2_stream_over_the_ceiling_gets_503(Config) ->
    %% Stream 1 holds the slot; stream 3 is answered 503 + Retry-After on
    %% its own stream (not REFUSED_STREAM), then reset with NO_ERROR.
    true = register(?COLLECTOR, self()),
    Throttled = attach(throttled),
    Sock = h2_connect(Config),
    ok = h2_request(Sock, 1),
    First = expect_handler(),
    ok = h2_request(Sock, 3),
    {Headers, Rst} = h2_answer(Sock, 3, roadrunner_http2_hpack:new_decoder(4096), <<>>),
    ?assertMatch(#{~":status" := ~"503", ~"retry-after" := ~"7"}, maps:from_list(Headers)),
    ?assertEqual(no_error, Rst),
    ?assertEqual(max_concurrent_requests, throttled_reason(Throttled)),
    ?assertMatch(#{throttled := 1}, roadrunner_listener:info(?config(listener, Config))),
    ?assertEqual(none, handler_started()),
    First ! release,
    ok = gen_tcp:close(Sock).

%% --- helpers ---

connect(Config) ->
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, ?config(port, Config), [binary, {active, false}], 5000
    ),
    Sock.

get_request() ->
    ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n".

expect_handler() ->
    receive
        {handler_started, Pid} -> Pid
    after 5000 -> ct:fail(handler_never_started)
    end.

%% A handler that started for a shed request would have announced itself
%% before its response, which the shed request never gets.
handler_started() ->
    receive
        {handler_started, Pid} -> Pid
    after 0 -> none
    end.

attach(Event) ->
    Self = self(),
    Ref = make_ref(),
    ok = telemetry:attach(
        Ref,
        [roadrunner, request, Event],
        fun(_Event, _Measurements, #{reason := Reason}, _Config) ->
            Self ! {Ref, Reason}
        end,
        undefined
    ),
    Ref.

throttled_reason(Ref) ->
    receive
        {Ref, Reason} ->
            ok = telemetry:detach(Ref),
            Reason
    after 5000 -> ct:fail(not_throttled)
    end.

recv_until_closed(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Data} -> recv_until_closed(Sock, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc
    end.

%% One response: its head, then the body its `content-length` frames.
recv_response(Sock, Acc) ->
    case binary:split(Acc, ~"\r\n\r\n") of
        [Head, Body] ->
            {match, [Len]} = re:run(
                Head, ~"content-length: ([0-9]+)", [{capture, all_but_first, binary}]
            ),
            recv_body(Sock, Head, Body, binary_to_integer(Len));
        [_] ->
            {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
            recv_response(Sock, <<Acc/binary, Data/binary>>)
    end.

recv_body(_Sock, Head, Body, Len) when byte_size(Body) >= Len ->
    <<Head/binary, "\r\n\r\n", Body/binary>>;
recv_body(Sock, Head, Body, Len) ->
    {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
    recv_body(Sock, Head, <<Body/binary, Data/binary>>, Len).

h2_connect(Config) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, [~"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", <<0:24, 4, 0, 0:32>>]),
    Sock.

h2_request(Sock, StreamId) ->
    {Block, _} = roadrunner_http2_hpack:encode(
        [
            {~":method", ~"GET"},
            {~":scheme", ~"http"},
            {~":authority", ~"localhost"},
            {~":path", ~"/"}
        ],
        roadrunner_http2_hpack:new_encoder(4096)
    ),
    gen_tcp:send(
        Sock,
        roadrunner_http2_frame:encode(
            {headers, StreamId, 16#04 bor 16#01, undefined, iolist_to_binary(Block)}
        )
    ).

%% Stream `StreamId`'s response headers and the RST_STREAM that follows
%% them. The decoder sees every HEADERS block in order, as HPACK needs.
h2_answer(Sock, StreamId, Dec, Buf) ->
    h2_answer(Sock, StreamId, Dec, Buf, undefined).

h2_answer(Sock, StreamId, Dec, Buf, Headers) ->
    case roadrunner_http2_frame:parse(Buf, 16384) of
        {ok, {headers, StreamId, _Flags, _Priority, Block}, Rest} ->
            {ok, Decoded, Dec1} = roadrunner_http2_hpack:decode(Block, Dec),
            h2_answer(Sock, StreamId, Dec1, Rest, Decoded);
        {ok, {headers, _Other, _Flags, _Priority, Block}, Rest} ->
            {ok, _, Dec1} = roadrunner_http2_hpack:decode(Block, Dec),
            h2_answer(Sock, StreamId, Dec1, Rest, Headers);
        {ok, {rst_stream, StreamId, Code}, _Rest} ->
            {Headers, Code};
        {ok, _Frame, Rest} ->
            h2_answer(Sock, StreamId, Dec, Rest, Headers);
        {more, _} ->
            {ok, More} = gen_tcp:recv(Sock, 0, 5000),
            h2_answer(Sock, StreamId, Dec, <<Buf/binary, More/binary>>, Headers)
    end.
