-module(roadrunner_route_ceiling_http_SUITE).
-moduledoc """
A route's own `max_concurrent_requests` as clients meet it over HTTP/1.1,
HTTP/2 (h2c) and HTTP/3. `/slow` runs one request at a time and holds it
until the test releases its handler (`roadrunner_h2_slot_handler`);
`/cheap` has no ceiling. The `h2_` and `h3_` cases run their protocol
alone.
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
    idle_connection_drops_the_route_heap/1,
    idle_connection_drops_the_route_binaries/1,
    idle_generational_connection_drops_the_route_heap/1,
    wait_does_not_eat_the_body_deadline/1,
    h2_connection_gone_leaves_the_queue/1,
    h3_connection_gone_leaves_the_queue/1,
    h2_shed_answers_503/1,
    h2_queue_grants_in_arrival_order/1,
    h2_queue_timeout_answers_503/1,
    h2_reset_while_waiting_leaves_the_queue/1,
    h2_killed_worker_frees_its_slot/1,
    h2_waiting_streams_leave_cheap_routes_a_slot/1,
    h2_owned_slot_frees_in_order/1,
    h3_shed_answers_503/1,
    h3_queue_grants_in_arrival_order/1,
    h3_queue_timeout_answers_503/1,
    h3_reset_while_waiting_leaves_the_queue/1,
    h3_killed_worker_frees_its_slot/1,
    h3_owned_slot_frees_in_order/1,
    slot_and_down_share_every_receive/1
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
        idle_connection_drops_the_route_heap,
        idle_connection_drops_the_route_binaries,
        idle_generational_connection_drops_the_route_heap,
        wait_does_not_eat_the_body_deadline,
        h2_connection_gone_leaves_the_queue,
        h3_connection_gone_leaves_the_queue,
        h2_shed_answers_503,
        h2_queue_grants_in_arrival_order,
        h2_queue_timeout_answers_503,
        h2_reset_while_waiting_leaves_the_queue,
        h2_killed_worker_frees_its_slot,
        h2_waiting_streams_leave_cheap_routes_a_slot,
        h2_owned_slot_frees_in_order,
        h3_shed_answers_503,
        h3_queue_grants_in_arrival_order,
        h3_queue_timeout_answers_503,
        h3_reset_while_waiting_leaves_the_queue,
        h3_killed_worker_frees_its_slot,
        h3_owned_slot_frees_in_order,
        slot_and_down_share_every_receive
    ].

init_per_suite(Config) ->
    {ok, _} = roadrunner_test_event_handler:start(),
    {ok, _} = application:ensure_all_started(ssl),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(Case, Config) ->
    true = register(?COLLECTOR, self()),
    {Slow, Listener0} = case_opts(Case),
    Listener = maps:merge(Listener0, protocol_opts(Case)),
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
            {~"/heap_free", roadrunner_route_heap_handler},
            #{
                path => ~"/binary",
                handler => roadrunner_route_binary_handler,
                max_concurrent_requests => 4
            },
            {~"/binary_free", roadrunner_route_binary_handler},
            #{
                path => ~"/old_heap",
                handler => roadrunner_route_old_heap_handler,
                max_concurrent_requests => 4
            },
            {~"/old_heap_free", roadrunner_route_old_heap_handler}
        ]
    }),
    [{listener, Case}, {port, roadrunner_listener:port(Case)} | Config].

end_per_testcase(Case, _Config) ->
    ok = roadrunner_h2_slot_handler:stop_all(),
    true = unregister(?COLLECTOR),
    ok = roadrunner_listener:stop(Case).

protocol_opts(Case) ->
    case atom_to_list(Case) of
        "h2_" ++ _ -> #{protocols => [http2]};
        "h3_" ++ _ -> #{protocols => [http3], tls => roadrunner_test_certs:server_opts()};
        _ -> #{}
    end.

%% The `/slow` route's own keys, and the listener's options.
case_opts(Case) when
    Case =:= h2_queue_grants_in_arrival_order;
    Case =:= h3_queue_grants_in_arrival_order;
    Case =:= h2_reset_while_waiting_leaves_the_queue;
    Case =:= h3_reset_while_waiting_leaves_the_queue
->
    {#{overload_mode => {queue, #{max_queued => 5}}}, #{}};
case_opts(Case) when Case =:= h2_queue_timeout_answers_503; Case =:= h3_queue_timeout_answers_503 ->
    {#{overload_mode => {queue, #{timeout => 50}}}, #{}};
case_opts(Case) when
    Case =:= h2_connection_gone_leaves_the_queue; Case =:= h3_connection_gone_leaves_the_queue
->
    {#{overload_mode => {queue, #{max_queued => 5}}}, #{}};
case_opts(wait_does_not_eat_the_body_deadline) ->
    {#{overload_mode => {queue, #{timeout => 10000}}}, #{request_timeout => 300}};
case_opts(h2_waiting_streams_leave_cheap_routes_a_slot) ->
    %% `/slow` may hold two listener slots, one running and one waiting:
    %% the third stays for the other routes.
    {#{overload_mode => {queue, #{max_queued => 1}}}, #{
        max_concurrent_requests => 3, overload_mode => {shed, #{retry_after => 9}}
    }};
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
case_opts(idle_generational_connection_drops_the_route_heap) ->
    {#{}, #{handler_spawn => #{opts => [{fullsweep_after, 65535}]}}};
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

idle_connection_drops_the_route_binaries(Config) ->
    %% The handler drops a 512 KB binary. A first request raised each
    %% connection's heap floor to its cap, so the binary leaves garbage
    %% only off the heap, within the floor: the capped connection collects
    %% it before its next request all the same, while the connection on a
    %% route without a ceiling keeps it while idle.
    Capped = connect(Config),
    ok = gen_tcp:send(Capped, get_request(~"/heap")),
    {200, _, _} = recv_response(Capped),
    ok = gen_tcp:send(Capped, get_request(~"/binary")),
    {200, _, CappedConn} = recv_response(Capped),
    Free = connect(Config),
    ok = gen_tcp:send(Free, get_request(~"/heap_free")),
    {200, _, _} = recv_response(Free),
    ok = gen_tcp:send(Free, get_request(~"/binary_free")),
    {200, _, FreeConn} = recv_response(Free),
    CappedBytes = binary_bytes(CappedConn),
    FreeBytes = binary_bytes(FreeConn),
    ct:pal("idle binaries after the request: capped ~p bytes, uncapped ~p bytes", [
        CappedBytes, FreeBytes
    ]),
    ?assert(FreeBytes >= 524288),
    ?assert(CappedBytes < 65536).

idle_generational_connection_drops_the_route_heap(Config) ->
    %% Under the emulator's generational policy, what the handler builds
    %% moves to the old heap at its minor collections, while the young
    %% heap stays within the floor a first request raised to its cap: the
    %% capped connection collects it before its next request all the
    %% same, while the connection on a route without a ceiling keeps it.
    Capped = connect(Config),
    ok = gen_tcp:send(Capped, get_request(~"/heap")),
    {200, _, _} = recv_response(Capped),
    ok = gen_tcp:send(Capped, get_request(~"/old_heap")),
    {200, _, CappedConn} = recv_response(Capped),
    Free = connect(Config),
    ok = gen_tcp:send(Free, get_request(~"/heap_free")),
    {200, _, _} = recv_response(Free),
    ok = gen_tcp:send(Free, get_request(~"/old_heap_free")),
    {200, _, FreeConn} = recv_response(Free),
    CappedHeap = heap_words(CappedConn),
    FreeHeap = heap_words(FreeConn),
    ct:pal("idle heap after the request: capped ~p words, uncapped ~p words", [
        CappedHeap, FreeHeap
    ]),
    %% The floor's cap is 46,422 words.
    ?assert(FreeHeap > 100000),
    ?assert(CappedHeap < 50000).

wait_does_not_eat_the_body_deadline(Config) ->
    %% A request that waited for its slot past its `request_timeout` still
    %% has the time to send its body: the wait is added to its deadline.
    Name = ?config(listener, Config),
    Holder = connect(Config),
    ok = gen_tcp:send(Holder, get_request(~"/slow")),
    First = expect_handler(),
    Sock = connect(Config),
    Sent = erlang:monotonic_time(millisecond),
    ok = gen_tcp:send(Sock, expect_continue(~"/slow", 5)),
    ok = wait_queued(Name, 1),
    ok = wait_until(Sent + 600),
    First ! release,
    {200, _, ~"ok"} = recv_response(Holder),
    ?assertEqual({ok, ~"HTTP/1.1 100 Continue\r\n\r\n"}, gen_tcp:recv(Sock, 25, 5000)),
    ok = gen_tcp:send(Sock, ~"hello"),
    expect_handler() ! release,
    {200, _, ~"ok"} = recv_response(Sock).

%% --- HTTP/2 ---

h2_shed_answers_503(Config) ->
    Throttled = attach(throttled),
    Sock = h2_connect(Config),
    ok = h2_get(Sock, 1, ~"/slow"),
    First = expect_handler(),
    ok = h2_get(Sock, 3, ~"/slow"),
    {503, Headers, ~""} = h2_response(Sock, 3),
    ?assertEqual(~"5", header(~"retry-after", Headers)),
    ?assertEqual(route_max_concurrent_requests, throttled_reason(Throttled)),
    ?assertEqual(none, handler_started()),
    %% The connection carries on.
    ok = h2_get(Sock, 5, ~"/cheap"),
    {200, _, _} = h2_response(Sock, 5),
    First ! release,
    {200, _, ~"ok"} = h2_response(Sock, 1).

h2_queue_grants_in_arrival_order(Config) ->
    Name = ?config(listener, Config),
    Sock = h2_connect(Config),
    ok = h2_get(Sock, 1, ~"/slow"),
    First = expect_handler(),
    [
        begin
            ok = h2_get(Sock, Id, ~"/slow"),
            ok = wait_queued(Name, N)
        end
     || {Id, N} <- [{3, 1}, {5, 2}, {7, 3}]
    ],
    lists:foldl(
        fun(Id, Running) ->
            Running ! release,
            Next = expect_handler(),
            ?assertEqual(none, handler_started()),
            Next ! release,
            {200, _, ~"ok"} = h2_response(Sock, Id),
            Next
        end,
        First,
        [3, 5, 7]
    ),
    {200, _, ~"ok"} = h2_response(Sock, 1).

h2_queue_timeout_answers_503(Config) ->
    Sock = h2_connect(Config),
    ok = h2_get(Sock, 1, ~"/slow"),
    First = expect_handler(),
    ok = h2_get(Sock, 3, ~"/slow"),
    {503, Headers, ~""} = h2_response(Sock, 3),
    ?assertEqual(~"1", header(~"retry-after", Headers)),
    First ! release,
    {200, _, ~"ok"} = h2_response(Sock, 1).

h2_reset_while_waiting_leaves_the_queue(Config) ->
    %% The client gives up on a waiting stream: its worker stops waiting
    %% and ends, so the slot freed next goes to the stream behind it.
    Name = ?config(listener, Config),
    Sock = h2_connect(Config),
    ok = h2_get(Sock, 1, ~"/slow"),
    First = expect_handler(),
    ok = h2_get(Sock, 3, ~"/slow"),
    ok = wait_queued(Name, 1),
    ok = h2_get(Sock, 5, ~"/slow"),
    ok = wait_queued(Name, 2),
    ok = gen_tcp:send(Sock, roadrunner_http2_frame:encode({rst_stream, 3, cancel})),
    ok = wait_queued(Name, 1),
    First ! release,
    {200, _, ~"ok"} = h2_response(Sock, 1),
    expect_handler() ! release,
    {200, _, ~"ok"} = h2_response(Sock, 5),
    ?assertEqual(none, handler_started()),
    ok = wait_in_flight(Name, 0).

h2_killed_worker_frees_its_slot(Config) ->
    Name = ?config(listener, Config),
    Sock = h2_connect(Config),
    ok = h2_get(Sock, 1, ~"/slow"),
    exit(expect_handler(), kill),
    ok = wait_in_flight(Name, 0),
    ok = h2_get(Sock, 3, ~"/slow"),
    expect_handler() ! release,
    {200, _, ~"ok"} = h2_response(Sock, 3).

h2_waiting_streams_leave_cheap_routes_a_slot(Config) ->
    %% Each stream takes a listener slot before it is routed. `/slow` holds
    %% one running and one waiting, the most its ceiling and queue allow,
    %% and the listener's third slot still serves `/cheap`.
    Name = ?config(listener, Config),
    Sock = h2_connect(Config),
    ok = h2_get(Sock, 1, ~"/slow"),
    First = expect_handler(),
    ok = h2_get(Sock, 3, ~"/slow"),
    ok = wait_queued(Name, 1),
    ok = h2_get(Sock, 5, ~"/slow"),
    {503, _, _} = h2_response(Sock, 5),
    ok = h2_get(Sock, 7, ~"/cheap"),
    {200, _, _} = h2_response(Sock, 7),
    ?assertMatch(#{throttled := 0}, roadrunner_listener:info(Name)),
    First ! release,
    {200, _, ~"ok"} = h2_response(Sock, 1),
    expect_handler() ! release,
    {200, _, ~"ok"} = h2_response(Sock, 3).

h2_owned_slot_frees_in_order(Config) ->
    %% A stream worker takes a slot owned by its connection, then ends while
    %% the connection is not running: the connection takes the worker's key
    %% and its `'DOWN'` in the order they came, and frees the slot.
    Name = ?config(listener, Config),
    Sock = h2_connect(Config),
    %% The first stream asks the keeper, which registers the connection.
    ok = h2_get(Sock, 1, ~"/slow"),
    expect_handler() ! release,
    {200, _, ~"ok"} = h2_response(Sock, 1),
    ok = wait_in_flight(Name, 0),
    ok = roadrunner_route_pause:arm(worker_noted),
    ok = h2_get(Sock, 3, ~"/slow"),
    ok = owned_slot_ends_while_its_owner_waits(Name).

h2_connection_gone_leaves_the_queue(Config) ->
    %% The client goes while a stream waits: its worker stops waiting, and
    %% no handler runs for it once a slot frees.
    Name = ?config(listener, Config),
    Sock = h2_connect(Config),
    ok = h2_get(Sock, 1, ~"/slow"),
    First = expect_handler(),
    ok = h2_get(Sock, 3, ~"/slow"),
    ok = wait_queued(Name, 1),
    ok = gen_tcp:close(Sock),
    ok = wait_queued(Name, 0),
    First ! release,
    ok = wait_in_flight(Name, 0),
    ?assertEqual(none, handler_started()).

%% --- HTTP/3 ---

h3_shed_answers_503(Config) ->
    Throttled = attach(throttled),
    Conn = h3_connect(Config),
    {ok, Holding} = h3_get(Conn, ~"/slow"),
    First = expect_handler(),
    {ok, Shed} = h3_get(Conn, ~"/slow"),
    {503, Headers, Body} = roadrunner_quic_test_h3:collect(Conn, Shed),
    ?assertEqual(~"", iolist_to_binary(Body)),
    ?assertEqual(~"5", header(~"retry-after", Headers)),
    ?assertEqual(route_max_concurrent_requests, throttled_reason(Throttled)),
    ?assertEqual(none, handler_started()),
    {ok, Cheap} = h3_get(Conn, ~"/cheap"),
    {200, _, _} = roadrunner_quic_test_h3:collect(Conn, Cheap),
    First ! release,
    {200, _, _} = roadrunner_quic_test_h3:collect(Conn, Holding),
    ok = h3_close(Conn).

h3_queue_grants_in_arrival_order(Config) ->
    Name = ?config(listener, Config),
    Conn = h3_connect(Config),
    {ok, Holding} = h3_get(Conn, ~"/slow"),
    First = expect_handler(),
    Waiting = [
        begin
            {ok, Id} = h3_get(Conn, ~"/slow"),
            ok = wait_queued(Name, N),
            Id
        end
     || N <- [1, 2, 3]
    ],
    lists:foldl(
        fun(Id, Running) ->
            Running ! release,
            Next = expect_handler(),
            ?assertEqual(none, handler_started()),
            Next ! release,
            {200, _, _} = roadrunner_quic_test_h3:collect(Conn, Id),
            Next
        end,
        First,
        Waiting
    ),
    {200, _, _} = roadrunner_quic_test_h3:collect(Conn, Holding),
    ok = h3_close(Conn).

h3_queue_timeout_answers_503(Config) ->
    Conn = h3_connect(Config),
    {ok, Holding} = h3_get(Conn, ~"/slow"),
    First = expect_handler(),
    {ok, Late} = h3_get(Conn, ~"/slow"),
    {503, Headers, _} = roadrunner_quic_test_h3:collect(Conn, Late),
    ?assertEqual(~"1", header(~"retry-after", Headers)),
    First ! release,
    {200, _, _} = roadrunner_quic_test_h3:collect(Conn, Holding),
    ok = h3_close(Conn).

h3_reset_while_waiting_leaves_the_queue(Config) ->
    Name = ?config(listener, Config),
    Conn = h3_connect(Config),
    {ok, Holding} = h3_get(Conn, ~"/slow"),
    First = expect_handler(),
    {ok, Cancelled} = h3_get(Conn, ~"/slow"),
    ok = wait_queued(Name, 1),
    {ok, Next} = h3_get(Conn, ~"/slow"),
    ok = wait_queued(Name, 2),
    ok = roadrunner_quic_test_h3:cancel(Conn, Cancelled),
    ok = wait_queued(Name, 1),
    First ! release,
    {200, _, _} = roadrunner_quic_test_h3:collect(Conn, Holding),
    expect_handler() ! release,
    {200, _, _} = roadrunner_quic_test_h3:collect(Conn, Next),
    ?assertEqual(none, handler_started()),
    ok = wait_in_flight(Name, 0),
    ok = h3_close(Conn).

h3_killed_worker_frees_its_slot(Config) ->
    Name = ?config(listener, Config),
    Conn = h3_connect(Config),
    {ok, _Killed} = h3_get(Conn, ~"/slow"),
    exit(expect_handler(), kill),
    ok = wait_in_flight(Name, 0),
    {ok, Next} = h3_get(Conn, ~"/slow"),
    expect_handler() ! release,
    {200, _, _} = roadrunner_quic_test_h3:collect(Conn, Next),
    ok = h3_close(Conn).

h3_owned_slot_frees_in_order(Config) ->
    %% As `h2_owned_slot_frees_in_order`, the owner being HTTP/3's loop.
    Name = ?config(listener, Config),
    Conn = h3_connect(Config),
    {ok, First} = h3_get(Conn, ~"/slow"),
    expect_handler() ! release,
    {200, _, _} = roadrunner_quic_test_h3:collect(Conn, First),
    ok = wait_in_flight(Name, 0),
    ok = roadrunner_route_pause:arm(worker_noted),
    {ok, _Second} = h3_get(Conn, ~"/slow"),
    ok = owned_slot_ends_while_its_owner_waits(Name),
    ok = h3_close(Conn).

h3_connection_gone_leaves_the_queue(Config) ->
    Name = ?config(listener, Config),
    Conn = h3_connect(Config),
    {ok, _Holding} = h3_get(Conn, ~"/slow"),
    First = expect_handler(),
    {ok, _Waiting} = h3_get(Conn, ~"/slow"),
    ok = wait_queued(Name, 1),
    ok = h3_close(Conn),
    ok = wait_queued(Name, 0),
    First ! release,
    ok = wait_in_flight(Name, 0),
    ?assertEqual(none, handler_started()).

%% --- the receive contract ---

slot_and_down_share_every_receive(_Config) ->
    %% A stream worker that takes a slot of its route on its own tells the
    %% process that monitors it (the HTTP/2 connection, HTTP/3's loop) its
    %% key, and that process frees the slot on the worker's `'DOWN'`, which
    %% comes after. So every receive those processes may run, in any module,
    %% that could take a worker's `'DOWN'` or a key must take both, each by
    %% its own clause before any other that could take it: a catch-all, or
    %% a `'DOWN'` taken apart from the keys, would handle a worker's
    %% `'DOWN'` before the key it sent first, however busy the process was.
    %% A `'DOWN'` of a monitor bound before the receive cannot be told from
    %% a worker's here, so each such receive is listed with why it is not.
    Allowed = [
        %% A call to the QUIC connection, waiting on its own monitor of it.
        {roadrunner_quic, await, 3},
        %% Body reads, run by the stream worker on its own monitor of the
        %% connection; reached here only through the readers the
        %% connection builds for its workers.
        {roadrunner_conn, await_reply, 4},
        {roadrunner_conn, withdraw_demand, 3}
    ],
    {Checked, Bad} = owner_receives(),
    ?assert(lists:member({roadrunner_conn_loop_http2, recv_more, 1}, Checked)),
    ?assert(lists:member({roadrunner_conn_loop_http3, loop, 1}, Checked)),
    ?assertEqual([], [B || {MFA, _Line, _Why} = B <- Bad, not lists:member(MFA, Allowed)]).

%% The functions with a receive that could take a worker's `'DOWN'` or a
%% key, among those the owners may run (every function the two loop
%% modules call, transitively), and those whose receive could take one
%% other than by its own clause, with why.
owner_receives() ->
    ok = load(roadrunner),
    {ok, Mods} = application:get_key(roadrunner, modules),
    Forms = maps:from_list([{M, abstract_code(M)} || M <- Mods]),
    Roots = [
        {M, F, A}
     || M <- [roadrunner_conn_loop_http2, roadrunner_conn_loop_http3],
        {function, _, F, A, _} <- maps:get(M, Forms)
    ],
    Found = [
        {MFA, Line, Clauses}
     || MFA <- reach(Roots, Forms, #{}), {Line, Clauses} <- receives(form(Forms, MFA))
    ],
    Taking = [{MFA, Line, Clauses} || {MFA, Line, Clauses} <- Found, takes_any(Clauses)],
    {
        [MFA || {MFA, _Line, _Clauses} <- Taking],
        [{MFA, Line, Why} || {MFA, Line, Clauses} <- Taking, Why <- [verdict(Clauses)], Why =/= ok]
    }.

load(App) ->
    case application:load(App) of
        ok -> ok;
        {error, {already_loaded, App}} -> ok
    end.

%% The abstract code of `Mod` as loaded (from its beam on disk when it is
%% cover compiled).
abstract_code(Mod) ->
    Beam =
        case code:which(Mod) of
            cover_compiled ->
                filename:join([code:lib_dir(roadrunner), "ebin", atom_to_list(Mod) ++ ".beam"]);
            Loaded ->
                Loaded
        end,
    {ok, {Mod, [{abstract_code, {raw_abstract_v1, Forms}}]}} = beam_lib:chunks(Beam, [abstract_code]),
    Forms.

form(Forms, {M, F, A}) ->
    [Form] = [Fn || {function, _, N, Ar, _} = Fn <- maps:get(M, Forms), N =:= F, Ar =:= A],
    Form.

%% Every function of the app reached from `Queue` by calls.
reach([], _Forms, Seen) ->
    maps:keys(Seen);
reach([MFA | Rest], Forms, Seen) when is_map_key(MFA, Seen) ->
    reach(Rest, Forms, Seen);
reach([{M, F, A} = MFA | Rest], Forms, Seen) ->
    case
        is_map_key(M, Forms) andalso
            [x || {function, _, F1, A1, _} <- maps:get(M, Forms), F1 =:= F, A1 =:= A]
    of
        [x] -> reach(called(M, form(Forms, MFA), Rest), Forms, Seen#{MFA => true});
        _ -> reach(Rest, Forms, Seen)
    end.

called(M, {call, _, {atom, _, F}, Args} = Call, Acc) ->
    [{M, F, length(Args)} | called(M, tl(tuple_to_list(Call)), Acc)];
called(M, {call, _, {remote, _, {atom, _, M2}, {atom, _, F}}, Args} = Call, Acc) ->
    [{M2, F, length(Args)} | called(M, tl(tuple_to_list(Call)), Acc)];
called(M, {'fun', _, {function, F, A}}, Acc) ->
    [{M, F, A} | Acc];
called(_M, {'fun', _, {function, {atom, _, M2}, {atom, _, F}, {integer, _, A}}}, Acc) ->
    [{M2, F, A} | Acc];
called(M, Tuple, Acc) when is_tuple(Tuple) ->
    called(M, tuple_to_list(Tuple), Acc);
called(M, [Head | Tail], Acc) ->
    called(M, Head, called(M, Tail, Acc));
called(_M, _Other, Acc) ->
    Acc.

%% Each receive of a function, with each clause's pattern and the
%% variables bound before it.
receives(Form) ->
    erl_syntax_lib:fold(
        fun(Node, Acc) ->
            case erl_syntax:type(Node) of
                receive_expr ->
                    Clauses = [
                        {
                            hd(erl_syntax:clause_patterns(C)),
                            proplists:get_value(env, erl_syntax:get_ann(C), [])
                        }
                     || C <- erl_syntax:receive_expr_clauses(Node)
                    ],
                    [{erl_syntax:get_pos(Node), Clauses} | Acc];
                _ ->
                    Acc
            end
        end,
        [],
        erl_syntax_lib:annotate_bindings(Form, ordsets:new())
    ).

takes_any(Clauses) ->
    lists:any(
        fun({P, Env}) ->
            may_take(P, 'DOWN', 5, Env) orelse may_take(P, roadrunner_route_slot, 4, Env)
        end,
        Clauses
    ).

%% `ok`, or which of a worker's `'DOWN'` and a key the receive could take
%% other than by its own clause.
verdict(Clauses) ->
    case {first(Clauses, 'DOWN', 5), first(Clauses, roadrunner_route_slot, 4)} of
        {named, named} -> ok;
        Why -> Why
    end.

%% The first clause that could take a `{Tag, ...}` tuple of `Size`: one
%% naming the tag, one that would take it otherwise, or none.
first([], _Tag, _Size) ->
    none;
first([{P, Env} | Rest], Tag, Size) ->
    case may_take(P, Tag, Size, Env) of
        true ->
            case names(P, Tag, Size) of
                true -> named;
                false -> unnamed
            end;
        false ->
            first(Rest, Tag, Size)
    end.

%% Whether pattern `P` could match a `{Tag, ...}` tuple of `Size`: a free
%% variable or `_`, or such a tuple whose first element is `Tag` or free.
may_take(P, Tag, Size, Env) ->
    case erl_syntax:type(P) of
        underscore ->
            true;
        variable ->
            not lists:member(erl_syntax:variable_name(P), Env);
        match_expr ->
            may_take(erl_syntax:match_expr_pattern(P), Tag, Size, Env) andalso
                may_take(erl_syntax:match_expr_body(P), Tag, Size, Env);
        tuple ->
            case erl_syntax:tuple_elements(P) of
                [First | _] = Elements when length(Elements) =:= Size ->
                    may_take(First, Tag, 0, Env) orelse
                        (erl_syntax:type(First) =:= atom andalso
                            erl_syntax:atom_value(First) =:= Tag);
                _ ->
                    false
            end;
        _ ->
            false
    end.

names(P, Tag, Size) ->
    case erl_syntax:type(P) of
        match_expr ->
            names(erl_syntax:match_expr_pattern(P), Tag, Size) orelse
                names(erl_syntax:match_expr_body(P), Tag, Size);
        tuple ->
            case erl_syntax:tuple_elements(P) of
                [First | _] = Elements when length(Elements) =:= Size ->
                    erl_syntax:type(First) =:= atom andalso erl_syntax:atom_value(First) =:= Tag;
                _ ->
                    false
            end;
        _ ->
            false
    end.

%% --- helpers ---

%% A worker stopped after telling its owner its key: the owner is suspended,
%% the worker takes its slot and runs, and is killed, so its key and its
%% `'DOWN'` both wait for the owner, which then frees the slot.
owned_slot_ends_while_its_owner_waits(Name) ->
    Worker = roadrunner_route_pause:await(worker_noted),
    [Owner] = [P || {P, none} <- ets:tab2list(regs(Name))],
    true = erlang:suspend_process(Owner),
    ok = roadrunner_route_pause:resume(Worker, worker_noted),
    Worker = expect_handler(),
    ?assertMatch([{_, Owner, Worker}], ets:tab2list(slots(Name))),
    Mon = monitor(process, Worker),
    exit(Worker, kill),
    receive
        {'DOWN', Mon, process, Worker, _} -> ok
    end,
    true = erlang:resume_process(Owner),
    wait_in_flight(Name, 0).

%% Until the clock reads `At` (ms): the condition under test is that time.
wait_until(At) ->
    case erlang:monotonic_time(millisecond) >= At of
        true ->
            ok;
        false ->
            erlang:yield(),
            wait_until(At)
    end.

h2_connect(Config) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, [
        ~"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", roadrunner_http2_frame:encode({settings, 0, []})
    ]),
    _ = put({h2, Sock}, {<<>>, roadrunner_http2_hpack:new_decoder(4096), #{}}),
    Sock.

h2_get(Sock, StreamId, Path) ->
    {Block, _} = roadrunner_http2_hpack:encode(
        [{~":method", ~"GET"}, {~":scheme", ~"http"}, {~":authority", ~"x"}, {~":path", Path}],
        roadrunner_http2_hpack:new_encoder(4096)
    ),
    gen_tcp:send(
        Sock,
        roadrunner_http2_frame:encode(
            {headers, StreamId, 16#04 bor 16#01, undefined, iolist_to_binary(Block)}
        )
    ).

%% Stream `StreamId`'s response, `{Status, Headers, Body}`. Frames of other
%% streams read on the way are kept for their own call; the HPACK decoder is
%% the connection's, so every HEADERS block is decoded in order.
h2_response(Sock, StreamId) ->
    {Buf, Dec, Streams} = get({h2, Sock}),
    case Streams of
        #{StreamId := {done, Status, Headers, Body}} ->
            _ = put({h2, Sock}, {Buf, Dec, maps:remove(StreamId, Streams)}),
            {Status, Headers, Body};
        #{} ->
            case roadrunner_http2_frame:parse(Buf, 16384) of
                {ok, Frame, Rest} ->
                    {Dec1, Streams1} = h2_frame(Frame, Dec, Streams),
                    _ = put({h2, Sock}, {Rest, Dec1, Streams1}),
                    h2_response(Sock, StreamId);
                _More ->
                    {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
                    _ = put({h2, Sock}, {<<Buf/binary, Data/binary>>, Dec, Streams}),
                    h2_response(Sock, StreamId)
            end
    end.

h2_frame({headers, Id, Flags, _Priority, Block}, Dec, Streams) ->
    {ok, Headers, Dec1} = roadrunner_http2_hpack:decode(Block, Dec),
    {_, Status} = lists:keyfind(~":status", 1, Headers),
    {Dec1, h2_part(Id, Flags, {binary_to_integer(Status), Headers, <<>>}, Streams)};
h2_frame({data, Id, Flags, Data, _FlowLen}, Dec, Streams) ->
    #{Id := {open, Status, Headers, Body}} = Streams,
    {Dec, h2_part(Id, Flags, {Status, Headers, <<Body/binary, Data/binary>>}, Streams)};
h2_frame(_Other, Dec, Streams) ->
    {Dec, Streams}.

h2_part(Id, Flags, {Status, Headers, Body}, Streams) when Flags band 16#01 =:= 16#01 ->
    Streams#{Id => {done, Status, Headers, Body}};
h2_part(Id, _Flags, {Status, Headers, Body}, Streams) ->
    Streams#{Id => {open, Status, Headers, Body}}.

h3_connect(Config) ->
    {ok, Conn} = roadrunner_quic_test_h3:connect({127, 0, 0, 1}, ?config(port, Config)),
    Conn.

h3_close(Conn) ->
    _ = roadrunner_quic_test_h3:close(Conn),
    ok.

h3_get(Conn, Path) ->
    roadrunner_quic_test_h3:open_request(Conn, [
        {~":method", ~"GET"},
        {~":scheme", ~"https"},
        {~":authority", ~"localhost"},
        {~":path", Path}
    ]).

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
    {total_heap_size, Words} = process_info(idle_conn(PidBin), total_heap_size),
    Words.

%% The connection sends its response before it collects: wait for it to
%% wait for its next request.
idle_conn(PidBin) ->
    Pid = list_to_pid(binary_to_list(PidBin)),
    wait_idle(Pid),
    Pid.

wait_idle(Pid) ->
    case process_info(Pid, status) of
        {status, waiting} ->
            ok;
        {status, _} ->
            erlang:yield(),
            wait_idle(Pid)
    end.

binary_bytes(PidBin) ->
    {binary, Binaries} = process_info(idle_conn(PidBin), binary),
    lists:sum([Size || {_Id, Size, _Refs} <- Binaries]).

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

%% The keeper serving `/slow`, as named in its tables.
keeper(Name) ->
    ets:lookup_element(regs(Name), '$keeper', 2).

%% `/slow`'s slot table and the table of the processes its keeper knows.
slots(Name) ->
    element(2, slow_ceiling(Name)).

regs(Name) ->
    element(3, slow_ceiling(Name)).

slow_ceiling(Name) ->
    {ok, _, _, _, _, {_Body, Ceiling}} =
        roadrunner_router:resolve(~"GET", ~"/slow", persistent_term:get({roadrunner_routes, Name})),
    Ceiling.

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
