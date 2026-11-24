-module(roadrunner_route_ceiling_http_SUITE).
-moduledoc """
A route's own `max_concurrent_requests` as clients meet it over HTTP/1.1.
`/slow` runs one request at a time and holds it until the test releases
its handler (`roadrunner_h2_slot_handler`); `/cheap` has no ceiling.
""".

-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([
    shed_answers_503_and_keeps_the_connection/1,
    shed_with_a_body_to_come_closes/1,
    cheap_route_is_never_throttled/1,
    queue_grants_in_arrival_order/1,
    queue_timeout_answers_503/1,
    queue_full_answers_503/1,
    route_slot_comes_before_the_listener_slot/1,
    killed_connection_frees_its_slot/1,
    keeper_crash_refuses_the_waiting_request/1,
    websocket_releases_at_the_101/1,
    loop_response_holds_until_it_ends/1,
    continue_is_withheld_while_waiting/1,
    continue_is_never_sent_when_refused/1,
    pipelined_requests_take_turns/1,
    pipelined_refusal_keeps_the_rest/1,
    idle_connection_drops_the_route_heap/1
]).

-define(COLLECTOR, roadrunner_h2_slot_collector).

suite() ->
    [{timetrap, {seconds, 60}}].

all() ->
    [
        shed_answers_503_and_keeps_the_connection,
        shed_with_a_body_to_come_closes,
        cheap_route_is_never_throttled,
        queue_grants_in_arrival_order,
        queue_timeout_answers_503,
        queue_full_answers_503,
        route_slot_comes_before_the_listener_slot,
        killed_connection_frees_its_slot,
        keeper_crash_refuses_the_waiting_request,
        websocket_releases_at_the_101,
        loop_response_holds_until_it_ends,
        continue_is_withheld_while_waiting,
        continue_is_never_sent_when_refused,
        pipelined_requests_take_turns,
        pipelined_refusal_keeps_the_rest,
        idle_connection_drops_the_route_heap
    ].

init_per_suite(Config) ->
    {ok, _} = roadrunner_test_event_handler:start(),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(Case, Config) ->
    true = register(?COLLECTOR, self()),
    {Slow, Listener} = case_opts(Case),
    {ok, _} = roadrunner_listener:start_link(Case, Listener#{
        port => 0,
        routes => [
            maps:merge(
                #{
                    path => ~"/slow",
                    handler => roadrunner_h2_slot_handler,
                    max_concurrent_requests => 1,
                    overload_mode => {shed, #{retry_after => 5}}
                },
                Slow
            ),
            {~"/cheap", roadrunner_keepalive_handler},
            #{
                path => ~"/fast",
                handler => roadrunner_keepalive_handler,
                max_concurrent_requests => 1
            },
            #{
                path => ~"/ws",
                handler => roadrunner_ws_upgrade_handler,
                max_concurrent_requests => 1
            },
            #{path => ~"/loop", handler => roadrunner_loop_handler, max_concurrent_requests => 1},
            #{
                path => ~"/heap",
                handler => roadrunner_route_heap_handler,
                max_concurrent_requests => 4
            },
            {~"/heap_free", roadrunner_route_heap_handler}
        ]
    }),
    [{listener, Case}, {port, roadrunner_listener:port(Case)} | Config].

end_per_testcase(Case, _Config) ->
    ok = roadrunner_h2_slot_handler:stop_all(),
    true = unregister(?COLLECTOR),
    ok = roadrunner_listener:stop(Case).

%% The `/slow` route's own keys, and the listener's options.
case_opts(queue_grants_in_arrival_order) ->
    {#{overload_mode => {queue, #{max_queued => 5}}}, #{}};
case_opts(Case) when
    Case =:= keeper_crash_refuses_the_waiting_request;
    Case =:= continue_is_withheld_while_waiting
->
    {#{overload_mode => {queue, #{}}}, #{}};
case_opts(queue_timeout_answers_503) ->
    {#{overload_mode => {queue, #{timeout => 50}}}, #{}};
case_opts(queue_full_answers_503) ->
    {#{overload_mode => {queue, #{max_queued => 1}}}, #{}};
case_opts(route_slot_comes_before_the_listener_slot) ->
    {#{}, #{max_concurrent_requests => 1, overload_mode => {shed, #{retry_after => 9}}}};
case_opts(_Case) ->
    {#{}, #{}}.

%% --- shed ---

shed_answers_503_and_keeps_the_connection(Config) ->
    Throttled = attach(throttled),
    Holder = connect(Config),
    ok = gen_tcp:send(Holder, get_request(~"/slow")),
    First = expect_handler(),
    %% A bodyless request over the route's ceiling gets the 503 as an
    %% ordinary response: no close, and the connection serves on.
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, get_request(~"/slow")),
    {503, Headers, ~""} = recv_response(Sock),
    ?assertEqual(~"5", header(~"retry-after", Headers)),
    ?assertEqual(~"0", header(~"content-length", Headers)),
    ?assertEqual(undefined, header(~"connection", Headers)),
    ?assertEqual(route_max_concurrent_requests, throttled_reason(Throttled)),
    ?assertEqual(none, handler_started()),
    ok = gen_tcp:send(Sock, get_request(~"/cheap")),
    {200, _, _} = recv_response(Sock),
    ?assertMatch(
        #{throttled := 0, routes := [#{path := ~"/slow", throttled := 1, in_flight := 1} | _]},
        roadrunner_listener:info(?config(listener, Config))
    ),
    First ! release,
    {200, _, ~"ok"} = recv_response(Holder).

shed_with_a_body_to_come_closes(Config) ->
    %% The body is not read: the 503 goes out from the headers and the
    %% connection closes, lingering over the body.
    Holder = connect(Config),
    ok = gen_tcp:send(Holder, get_request(~"/slow")),
    First = expect_handler(),
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, ~"POST /slow HTTP/1.1\r\nHost: x\r\nContent-Length: 1000000\r\n\r\n"),
    {503, Headers, ~""} = recv_response(Sock),
    ?assertEqual(~"close", header(~"connection", Headers)),
    ?assertEqual(~"5", header(~"retry-after", Headers)),
    First ! release,
    {200, _, ~"ok"} = recv_response(Holder).

cheap_route_is_never_throttled(Config) ->
    Holder = connect(Config),
    ok = gen_tcp:send(Holder, get_request(~"/slow")),
    First = expect_handler(),
    Socks = [connect(Config) || _ <- lists:seq(1, 20)],
    [ok = gen_tcp:send(S, get_request(~"/cheap")) || S <- Socks],
    [{200, _, _} = recv_response(S) || S <- Socks],
    First ! release,
    {200, _, ~"ok"} = recv_response(Holder).

%% --- queue ---

queue_grants_in_arrival_order(Config) ->
    Name = ?config(listener, Config),
    Holder = connect(Config),
    ok = gen_tcp:send(Holder, get_request(~"/slow")),
    First = expect_handler(),
    Waiting = [
        begin
            S = connect(Config),
            ok = gen_tcp:send(S, get_request(~"/slow")),
            ok = wait_queued(Name, N),
            S
        end
     || N <- [1, 2, 3]
    ],
    lists:foldl(
        fun(Sock, Running) ->
            Running ! release,
            Next = expect_handler(),
            %% Only this one runs: the others still wait their turn.
            ?assertEqual(none, handler_started()),
            Next ! release,
            {200, _, ~"ok"} = recv_response(Sock),
            Next
        end,
        First,
        Waiting
    ),
    {200, _, ~"ok"} = recv_response(Holder),
    ?assertMatch(#{routes := [#{throttled := 0, queued := 0} | _]}, roadrunner_listener:info(Name)).

queue_timeout_answers_503(Config) ->
    Holder = connect(Config),
    ok = gen_tcp:send(Holder, get_request(~"/slow")),
    First = expect_handler(),
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, get_request(~"/slow")),
    {503, Headers, ~""} = recv_response(Sock),
    ?assertEqual(~"1", header(~"retry-after", Headers)),
    First ! release,
    {200, _, ~"ok"} = recv_response(Holder).

queue_full_answers_503(Config) ->
    Name = ?config(listener, Config),
    Holder = connect(Config),
    ok = gen_tcp:send(Holder, get_request(~"/slow")),
    First = expect_handler(),
    Waiter = connect(Config),
    ok = gen_tcp:send(Waiter, get_request(~"/slow")),
    ok = wait_queued(Name, 1),
    Over = connect(Config),
    ok = gen_tcp:send(Over, get_request(~"/slow")),
    {503, _, ~""} = recv_response(Over),
    First ! release,
    expect_handler() ! release,
    {200, _, ~"ok"} = recv_response(Holder),
    {200, _, ~"ok"} = recv_response(Waiter).

%% --- with the listener's ceiling ---

route_slot_comes_before_the_listener_slot(Config) ->
    %% The listener sheds over 1 and `/slow` holds the only slot of both.
    %% A second `/slow` is turned away by the route, taking no listener
    %% slot; `/cheap` by the listener; a 404 by neither.
    Name = ?config(listener, Config),
    Throttled = attach(throttled),
    Holder = connect(Config),
    ok = gen_tcp:send(Holder, get_request(~"/slow")),
    First = expect_handler(),
    Slow = connect(Config),
    ok = gen_tcp:send(Slow, get_request(~"/slow")),
    {503, SlowHeaders, _} = recv_response(Slow),
    ?assertEqual(~"5", header(~"retry-after", SlowHeaders)),
    ?assertEqual(route_max_concurrent_requests, throttled_reason(Throttled)),
    Throttled1 = attach(throttled),
    ok = gen_tcp:send(Slow, get_request(~"/cheap")),
    {503, CheapHeaders, _} = recv_response(Slow),
    ?assertEqual(~"9", header(~"retry-after", CheapHeaders)),
    ?assertEqual(max_concurrent_requests, throttled_reason(Throttled1)),
    %% `/fast` has its route slot free but the listener has none: the route
    %% slot it took goes back with the listener's 503.
    %% (The listener's 503 closed the connection.)
    Fast = connect(Config),
    ok = gen_tcp:send(Fast, get_request(~"/fast")),
    {503, FastHeaders, _} = recv_response(Fast),
    ?assertEqual(~"9", header(~"retry-after", FastHeaders)),
    ?assertMatch(#{in_flight := 0}, route(Name, ~"/fast")),
    Missing = connect(Config),
    ok = gen_tcp:send(Missing, get_request(~"/missing")),
    ?assertMatch(<<"HTTP/1.1 404 ", _/binary>>, recv_until_closed(Missing, <<>>)),
    ?assertMatch(
        #{throttled := 2, routes := [#{throttled := 1} | _]}, roadrunner_listener:info(Name)
    ),
    First ! release,
    {200, _, ~"ok"} = recv_response(Holder).

%% --- holders that go away ---

killed_connection_frees_its_slot(Config) ->
    Name = ?config(listener, Config),
    Holder = connect(Config),
    ok = gen_tcp:send(Holder, get_request(~"/slow")),
    %% The handler runs in the connection process.
    Conn = expect_handler(),
    exit(Conn, kill),
    ok = wait_in_flight(Name, 0),
    Next = connect(Config),
    ok = gen_tcp:send(Next, get_request(~"/slow")),
    expect_handler() ! release,
    {200, _, ~"ok"} = recv_response(Next).

keeper_crash_refuses_the_waiting_request(Config) ->
    %% The request running keeps its slot under the new keeper; the one
    %% waiting for the old keeper is answered 503.
    Name = ?config(listener, Config),
    Holder = connect(Config),
    ok = gen_tcp:send(Holder, get_request(~"/slow")),
    First = expect_handler(),
    Waiter = connect(Config),
    ok = gen_tcp:send(Waiter, get_request(~"/slow")),
    ok = wait_queued(Name, 1),
    exit(keeper(Name), kill),
    {503, _, ~""} = recv_response(Waiter),
    ?assertMatch(#{routes := [#{in_flight := 1} | _]}, roadrunner_listener:info(Name)),
    First ! release,
    {200, _, ~"ok"} = recv_response(Holder),
    ok = wait_in_flight(Name, 0),
    ok = gen_tcp:send(Waiter, get_request(~"/slow")),
    expect_handler() ! release,
    {200, _, ~"ok"} = recv_response(Waiter).

%% --- responses that outlast their handler ---

websocket_releases_at_the_101(Config) ->
    %% A session is a connection, not a request: the upgrade hands the slot
    %% back, so a second upgrade gets in while the first session is open.
    First = connect(Config),
    ok = gen_tcp:send(First, ws_upgrade(~"/ws")),
    ?assertMatch(<<"HTTP/1.1 101 ", _/binary>>, recv_head(First, <<>>)),
    Second = connect(Config),
    ok = gen_tcp:send(Second, ws_upgrade(~"/ws")),
    ?assertMatch(<<"HTTP/1.1 101 ", _/binary>>, recv_head(Second, <<>>)),
    ?assertMatch(
        #{routes := [_, _, #{path := ~"/ws", in_flight := 0, throttled := 0} | _]},
        roadrunner_listener:info(?config(listener, Config))
    ).

loop_response_holds_until_it_ends(Config) ->
    Name = ?config(listener, Config),
    Looping = connect(Config),
    ok = gen_tcp:send(Looping, get_request(~"/loop")),
    ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, recv_head(Looping, <<>>)),
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, get_request(~"/loop")),
    {503, _, ~""} = recv_response(Sock),
    roadrunner_loop_test_conn ! stop,
    _ = recv_until_closed(Looping, <<>>),
    ok = wait_in_flight(Name, ~"/loop", 0),
    ok = gen_tcp:send(Sock, get_request(~"/loop")),
    ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, recv_head(Sock, <<>>)),
    roadrunner_loop_test_conn ! stop.

%% --- 100 Continue ---

continue_is_withheld_while_waiting(Config) ->
    Name = ?config(listener, Config),
    Holder = connect(Config),
    ok = gen_tcp:send(Holder, get_request(~"/slow")),
    First = expect_handler(),
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, expect_continue(~"/slow", 5)),
    ok = wait_queued(Name, 1),
    %% Parked before its 100: nothing on the wire yet.
    ?assertEqual({error, timeout}, gen_tcp:recv(Sock, 0, 0)),
    First ! release,
    {200, _, ~"ok"} = recv_response(Holder),
    ?assertEqual({ok, ~"HTTP/1.1 100 Continue\r\n\r\n"}, gen_tcp:recv(Sock, 25, 5000)),
    ok = gen_tcp:send(Sock, ~"hello"),
    expect_handler() ! release,
    {200, _, ~"ok"} = recv_response(Sock).

continue_is_never_sent_when_refused(Config) ->
    Holder = connect(Config),
    ok = gen_tcp:send(Holder, get_request(~"/slow")),
    First = expect_handler(),
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, expect_continue(~"/slow", 5)),
    Reply = recv_until_closed(Sock, <<>>),
    ?assertMatch(<<"HTTP/1.1 503 ", _/binary>>, Reply),
    ?assertEqual(nomatch, binary:match(Reply, ~"100 Continue")),
    First ! release,
    {200, _, ~"ok"} = recv_response(Holder).

%% --- pipelining ---

pipelined_requests_take_turns(Config) ->
    %% One connection's requests run one after the other, each releasing
    %% its slot before the next takes it.
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, [get_request(~"/fast"), get_request(~"/fast"), get_request(~"/fast")]),
    [{200, _, _} = recv_response(Sock) || _ <- [1, 2, 3]],
    ?assertMatch(
        #{routes := [_, #{path := ~"/fast", throttled := 0, in_flight := 0} | _]},
        roadrunner_listener:info(?config(listener, Config))
    ).

pipelined_refusal_keeps_the_rest(Config) ->
    Holder = connect(Config),
    ok = gen_tcp:send(Holder, get_request(~"/slow")),
    First = expect_handler(),
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, [get_request(~"/slow"), get_request(~"/cheap"), get_request(~"/slow")]),
    {503, _, _} = recv_response(Sock),
    {200, _, _} = recv_response(Sock),
    {503, _, _} = recv_response(Sock),
    First ! release,
    {200, _, ~"ok"} = recv_response(Holder).

%% --- the connection's heap ---

idle_connection_drops_the_route_heap(Config) ->
    %% The handler builds a few MB on the connection's heap. Through a
    %% route with a ceiling the connection collects it before its next
    %% request; through one without, it keeps it while idle.
    Capped = connect(Config),
    ok = gen_tcp:send(Capped, get_request(~"/heap")),
    {200, _, CappedConn} = recv_response(Capped),
    Free = connect(Config),
    ok = gen_tcp:send(Free, get_request(~"/heap_free")),
    {200, _, FreeConn} = recv_response(Free),
    CappedHeap = heap_words(CappedConn),
    FreeHeap = heap_words(FreeConn),
    ct:pal("idle heap after the request: capped ~p words, uncapped ~p words", [
        CappedHeap, FreeHeap
    ]),
    %% 400,000 list cells are 800,000 words.
    ?assert(FreeHeap > 800000),
    ?assert(CappedHeap < 100000).

%% --- helpers ---

connect(Config) ->
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, ?config(port, Config), [binary, {active, false}], 5000
    ),
    Sock.

get_request(Path) ->
    [~"GET ", Path, ~" HTTP/1.1\r\nHost: x\r\n\r\n"].

expect_continue(Path, Length) ->
    [
        ~"POST ",
        Path,
        ~" HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: ",
        integer_to_binary(Length),
        ~"\r\n\r\n"
    ].

ws_upgrade(Path) ->
    [
        ~"GET ",
        Path,
        ~" HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n",
        ~"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
    ].

heap_words(PidBin) ->
    {total_heap_size, Words} = process_info(list_to_pid(binary_to_list(PidBin)), total_heap_size),
    Words.

expect_handler() ->
    receive
        {handler_started, Pid} -> Pid
    after 5000 -> ct:fail(handler_never_started)
    end.

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

%% The keeper serving `/slow`, as named in its slot table.
keeper(Name) ->
    {ok, _, _, _, _, {_Body, Ceiling}} =
        roadrunner_router:resolve(~"GET", ~"/slow", persistent_term:get({roadrunner_routes, Name})),
    ets:lookup_element(element(2, Ceiling), keeper, 2).

route(Name, Path) ->
    #{routes := Routes} = roadrunner_listener:info(Name),
    [Route] = [R || #{path := P} = R <- Routes, P =:= Path],
    Route.

wait_queued(Name, N) ->
    wait_route(Name, ~"/slow", queued, N).

wait_in_flight(Name, N) ->
    wait_route(Name, ~"/slow", in_flight, N).

wait_in_flight(Name, Path, N) ->
    wait_route(Name, Path, in_flight, N).

%% Until `Path`'s `Key` in `info/1` reads `N`, for up to 5 s. Each check is
%% a call to the listener; between them this process only yields.
wait_route(Name, Path, Key, N) ->
    wait_route(Name, Path, Key, N, erlang:monotonic_time(millisecond) + 5000).

wait_route(Name, Path, Key, N, Deadline) ->
    case route(Name, Path) of
        #{Key := N} ->
            ok;
        #{} ->
            erlang:monotonic_time(millisecond) < Deadline orelse ct:fail({never, Path, Key, N}),
            erlang:yield(),
            wait_route(Name, Path, Key, N, Deadline)
    end.

recv_until_closed(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Data} -> recv_until_closed(Sock, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc
    end.

%% A response head, up to its blank line.
recv_head(Sock, Acc) ->
    case binary:split(Acc, ~"\r\n\r\n") of
        [Head, _] ->
            Head;
        [_] ->
            {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
            recv_head(Sock, <<Acc/binary, Data/binary>>)
    end.

%% One response off the socket, as `{Status, Headers, Body}` with the body
%% its `content-length` frames. Bytes past it stay for the next call.
recv_response(Sock) ->
    {Status, Headers, Body, Rest} = recv_response(Sock, get_buffer(Sock)),
    ok = put_buffer(Sock, Rest),
    {Status, Headers, Body}.

recv_response(Sock, Acc) ->
    case binary:split(Acc, ~"\r\n\r\n") of
        [Head, Tail] ->
            [<<"HTTP/1.1 ", Code:3/binary, _/binary>> | Lines] = binary:split(
                Head, ~"\r\n", [global]
            ),
            Headers = [
                {roadrunner_bin:ascii_lowercase(N), V}
             || L <- Lines, [N, V] <- [binary:split(L, ~": ")]
            ],
            Len = binary_to_integer(header(~"content-length", Headers)),
            {Body, Rest} = recv_body(Sock, Tail, Len),
            {binary_to_integer(Code), Headers, Body, Rest};
        [_] ->
            {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
            recv_response(Sock, <<Acc/binary, Data/binary>>)
    end.

recv_body(_Sock, Buf, Len) when byte_size(Buf) >= Len ->
    <<Body:Len/binary, Rest/binary>> = Buf,
    {Body, Rest};
recv_body(Sock, Buf, Len) ->
    {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
    recv_body(Sock, <<Buf/binary, Data/binary>>, Len).

get_buffer(Sock) ->
    case get({buffer, Sock}) of
        undefined -> <<>>;
        Buf -> Buf
    end.

put_buffer(Sock, Buf) ->
    _ = put({buffer, Sock}, Buf),
    ok.

header(Name, Headers) ->
    case lists:keyfind(Name, 1, Headers) of
        {_, Value} -> Value;
        false -> undefined
    end.
