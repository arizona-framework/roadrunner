-module(roadrunner_listener_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% start_link/2 + stop/1 + port/1
%% =============================================================================

listener_lifecycle_test_() ->
    {setup,
        fun() ->
            Name = listener_test_one,
            {ok, Pid} = roadrunner_listener:start_link(Name, #{
                port => 0, handler => roadrunner_hello_handler
            }),
            {Name, Pid}
        end,
        fun({Name, _Pid}) ->
            ok = roadrunner_listener:stop(Name)
        end,
        fun({Name, Pid}) ->
            [
                {"start_link returns alive pid",
                    ?_assert(is_pid(Pid) andalso is_process_alive(Pid))},
                {"port/1 returns a non-zero ephemeral port",
                    ?_assert(roadrunner_listener:port(Name) > 0)},
                {"two consecutive port/1 calls return the same value",
                    ?_assertEqual(roadrunner_listener:port(Name), roadrunner_listener:port(Name))}
            ]
        end}.

listener_accepts_tcp_handshake_test_() ->
    {setup,
        fun() ->
            Name = listener_test_handshake,
            {ok, _} = roadrunner_listener:start_link(Name, #{
                port => 0, handler => roadrunner_hello_handler
            }),
            roadrunner_listener:port(Name)
        end,
        fun(_Port) ->
            ok = roadrunner_listener:stop(listener_test_handshake)
        end,
        fun(Port) ->
            {"client can complete TCP handshake to the bound port", fun() ->
                {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
                ok = gen_tcp:close(Sock)
            end}
        end}.

listener_stops_releases_port_test_() ->
    {setup,
        fun() ->
            Name = listener_test_release,
            {ok, _} = roadrunner_listener:start_link(Name, #{
                port => 0, handler => roadrunner_hello_handler
            }),
            Port = roadrunner_listener:port(Name),
            ok = roadrunner_listener:stop(Name),
            Port
        end,
        fun(_) -> ok end, fun(Port) ->
            {"connecting to a stopped listener fails", fun() ->
                Result = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 200
                ),
                ?assertMatch({error, _}, Result)
            end}
        end}.

listener_listen_failure_returns_error_test() ->
    %% Bind listener A to an ephemeral port, then try to bind B to the
    %% same port — second listen() must fail with eaddrinuse.
    {ok, _} = roadrunner_listener:start_link(listener_test_busy_a, #{
        port => 0, handler => roadrunner_hello_handler
    }),
    Port = roadrunner_listener:port(listener_test_busy_a),
    process_flag(trap_exit, true),
    Result = roadrunner_listener:start_link(listener_test_busy_b, #{
        port => Port, handler => roadrunner_hello_handler
    }),
    ?assertMatch({error, _}, Result),
    ok = roadrunner_listener:stop(listener_test_busy_a).

listener_ignores_unknown_cast_test() ->
    {ok, _} = roadrunner_listener:start_link(listener_test_cast, #{
        port => 0, handler => roadrunner_hello_handler
    }),
    gen_server:cast(listener_test_cast, surprise),
    %% Process must still answer call/1 — proves it survived the cast.
    ?assert(roadrunner_listener:port(listener_test_cast) > 0),
    ok = roadrunner_listener:stop(listener_test_cast).

listener_honors_num_acceptors_opt_test() ->
    %% Explicit override exercises the opt path (default is exercised by
    %% every other listener test).
    {ok, _} = roadrunner_listener:start_link(listener_test_pool, #{
        port => 0,
        num_acceptors => 3,
        handler => roadrunner_hello_handler
    }),
    ?assert(roadrunner_listener:port(listener_test_pool) > 0),
    ok = roadrunner_listener:stop(listener_test_pool).

%% =============================================================================
%% info/1
%% =============================================================================

slot_reconciliation_releases_sustained_orphan_slots_test() ->
    %% With reconciliation enabled, an orphaned slot (counter > pg
    %% members for two consecutive ticks) is reaped — simulates
    %% `kill`-bypasses-`terminate` recovery. Also asserts the
    %% `[roadrunner, listener, slots_reconciled]` telemetry event fires
    %% with the released count.
    case whereis(pg) of
        undefined -> {ok, _} = pg:start_link();
        _ -> ok
    end,
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    HandlerId = make_ref(),
    ok = telemetry:attach(
        HandlerId,
        [roadrunner, listener, slots_reconciled],
        fun(Event, M, Md, _) -> Self ! {ev, Event, M, Md} end,
        undefined
    ),
    try
        Name = listener_test_reap,
        {ok, ListenerPid} = roadrunner_listener:start_link(Name, #{
            port => 0,
            max_clients => 100,
            slot_reconciliation => #{interval_ms => 30},
            handler => roadrunner_hello_handler
        }),
        %% Reach into state to grab the counter ref. {state, LSocket, Port,
        %% ProtoOpts, Phase, Reconciliation} — relies on field order.
        State = sys:get_state(ListenerPid),
        ProtoOpts = element(4, State),
        Counter = maps:get(client_counter, ProtoOpts),
        ?assertEqual(0, atomics:get(Counter, 1)),
        %% Plant 3 orphan slots — bumped without a corresponding pg join.
        ok = atomics:add(Counter, 1, 3),
        ?assertEqual(3, atomics:get(Counter, 1)),
        %% First tick at 30ms records prev_diff=3; second tick at 60ms
        %% reaps. Wait long enough to be safe across CI jitter.
        timer:sleep(200),
        ?assertEqual(0, atomics:get(Counter, 1)),
        receive
            {ev, [roadrunner, listener, slots_reconciled], _, Md} ->
                ?assertEqual(Name, maps:get(listener_name, Md)),
                ?assertEqual(3, maps:get(released, Md))
        after 500 -> error(no_slots_reconciled_event)
        end,
        ok = roadrunner_listener:stop(Name)
    after
        telemetry:detach(HandlerId)
    end.

slot_reconciliation_only_reaps_excess_over_pg_members_test() ->
    %% Counter > pg members → only the diff is orphan; pg members
    %% themselves represent live conns and must NOT be touched.
    case whereis(pg) of
        undefined -> {ok, _} = pg:start_link();
        _ -> ok
    end,
    Name = listener_test_reap_partial,
    {ok, ListenerPid} = roadrunner_listener:start_link(Name, #{
        port => 0,
        max_clients => 100,
        slot_reconciliation => #{interval_ms => 30},
        handler => roadrunner_hello_handler
    }),
    State = sys:get_state(ListenerPid),
    ProtoOpts = element(4, State),
    Counter = maps:get(client_counter, ProtoOpts),
    %% Plant 2 fake "live conn" pids in the drain group + bump
    %% counter to 5. Diff = 5 - 2 = 3 orphans. After two ticks the
    %% reaper should release 3, leaving counter at 2 (the live ones).
    Stub1 = spawn(fun() ->
        pg:join({roadrunner_drain, Name}, self()),
        receive
            stop -> ok
        end
    end),
    Stub2 = spawn(fun() ->
        pg:join({roadrunner_drain, Name}, self()),
        receive
            stop -> ok
        end
    end),
    %% Wait briefly for both joins to register.
    timer:sleep(20),
    ok = atomics:add(Counter, 1, 5),
    timer:sleep(200),
    ?assertEqual(2, atomics:get(Counter, 1)),
    Stub1 ! stop,
    Stub2 ! stop,
    ok = roadrunner_listener:stop(Name).

listener_threads_rate_check_interval_into_proto_opts_test() ->
    Name = listener_test_rate_check_interval,
    {ok, ListenerPid} = roadrunner_listener:start_link(Name, #{
        port => 0,
        rate_check_interval_ms => 500,
        handler => roadrunner_hello_handler
    }),
    State = sys:get_state(ListenerPid),
    ProtoOpts = element(4, State),
    ?assertEqual(500, maps:get(rate_check_interval_ms, ProtoOpts)),
    ok = roadrunner_listener:stop(Name).

listener_threads_hibernate_after_into_proto_opts_test() ->
    %% `hibernate_after` listener opt must thread into proto_opts so
    %% `roadrunner_conn_loop` reads it and routes the recv path through
    %% the active-mode hibernation branch. Verified by reaching into
    %% the listener state and checking the proto_opts map.
    Name = listener_test_hibernate_after,
    {ok, ListenerPid} = roadrunner_listener:start_link(Name, #{
        port => 0,
        hibernate_after => 5000,
        handler => roadrunner_hello_handler
    }),
    State = sys:get_state(ListenerPid),
    ProtoOpts = element(4, State),
    ?assertEqual(5000, maps:get(hibernate_after, ProtoOpts)),
    ok = roadrunner_listener:stop(Name).

slot_reconciliation_disabled_drops_reconcile_slots_message_test() ->
    %% A `reconcile_slots` arriving at a listener with reconciliation
    %% disabled (race after a hypothetical config change) is just
    %% dropped — gen_server stays alive.
    Name = listener_test_disabled_reap,
    {ok, ListenerPid} = roadrunner_listener:start_link(Name, #{
        port => 0, handler => roadrunner_hello_handler
    }),
    ListenerPid ! reconcile_slots,
    %% Process must still answer port/1.
    ?assert(roadrunner_listener:port(Name) > 0),
    ok = roadrunner_listener:stop(Name).

listener_drops_unknown_info_message_test() ->
    %% Generic info catch-all: arbitrary stray messages don't crash
    %% the listener.
    Name = listener_test_stray_info,
    {ok, ListenerPid} = roadrunner_listener:start_link(Name, #{
        port => 0, handler => roadrunner_hello_handler
    }),
    ListenerPid ! {stray, make_ref()},
    ?assert(roadrunner_listener:port(Name) > 0),
    ok = roadrunner_listener:stop(Name).

slot_reconciliation_disabled_by_default_test() ->
    case whereis(pg) of
        undefined -> {ok, _} = pg:start_link();
        _ -> ok
    end,
    Name = listener_test_no_reap,
    {ok, ListenerPid} = roadrunner_listener:start_link(Name, #{
        port => 0, handler => roadrunner_hello_handler
    }),
    State = sys:get_state(ListenerPid),
    ProtoOpts = element(4, State),
    Counter = maps:get(client_counter, ProtoOpts),
    %% Plant orphan slots; without reconciliation they stay forever.
    ok = atomics:add(Counter, 1, 3),
    timer:sleep(100),
    ?assertEqual(3, atomics:get(Counter, 1)),
    ok = roadrunner_listener:stop(Name).

listener_info_initial_zero_test() ->
    Name = listener_test_info_init,
    {ok, _} = roadrunner_listener:start_link(Name, #{
        port => 0, max_clients => 42, handler => roadrunner_hello_handler
    }),
    Info = roadrunner_listener:info(Name),
    ?assertEqual(0, maps:get(active_clients, Info)),
    ?assertEqual(42, maps:get(max_clients, Info)),
    ?assertEqual(0, maps:get(requests_served, Info)),
    ok = roadrunner_listener:stop(Name).

listener_info_counts_served_requests_test_() ->
    {setup,
        fun() ->
            Name = listener_test_info_count,
            {ok, _} = roadrunner_listener:start_link(Name, #{
                port => 0, handler => roadrunner_hello_handler
            }),
            {Name, roadrunner_listener:port(Name)}
        end,
        fun({Name, _Port}) -> ok = roadrunner_listener:stop(Name) end, fun({Name, Port}) ->
            {"requests_served increments after each request", fun() ->
                send_request(Port),
                send_request(Port),
                send_request(Port),
                ?assertEqual(3, maps:get(requests_served, roadrunner_listener:info(Name)))
            end}
        end}.

send_request(Port) ->
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
    ok = gen_tcp:send(Sock, ~"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"),
    %% Drain to EOF so the conn process completes (and bumps the counter)
    %% before we read it.
    drain(Sock),
    ok = gen_tcp:close(Sock).

drain(Sock) ->
    case gen_tcp:recv(Sock, 0, 1000) of
        {ok, _} -> drain(Sock);
        {error, _} -> ok
    end.

%% =============================================================================
%% Graceful shutdown via drain/2.
%% =============================================================================

drain_with_no_active_conns_returns_immediately_test_() ->
    {setup,
        fun() ->
            ensure_pg_started(),
            Name = listener_test_drain_idle,
            {ok, _} = roadrunner_listener:start_link(Name, #{
                port => 0, handler => roadrunner_hello_handler
            }),
            Name
        end,
        %% drain/2 stops the listener — cleanup is a no-op assertion.
        fun(_) -> ok end, fun(Name) ->
            {"drain returns ok,drained immediately when no conns are alive", fun() ->
                ?assertEqual({ok, drained}, roadrunner_listener:drain(Name, 1000)),
                wait_until_unregistered(Name)
            end}
        end}.

drain_waits_for_in_flight_loop_to_close_test_() ->
    {setup,
        fun() ->
            ensure_pg_started(),
            Name = listener_test_drain_loop,
            {ok, _} = roadrunner_listener:start_link(Name, #{
                port => 0,
                routes => [{~"/loop", roadrunner_drain_handler, #{}}]
            }),
            {Name, roadrunner_listener:port(Name)}
        end,
        fun(_) -> ok end, fun({Name, Port}) ->
            {"drain delivers roadrunner_drain msg; loop handler stops cleanly", fun() ->
                %% Open a long-lived loop conn: send the request, then
                %% leave the socket open so the conn is still alive.
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                ok = gen_tcp:send(Sock, ~"GET /loop HTTP/1.1\r\nHost: x\r\n\r\n"),
                %% Wait for the loop to start (it sends a `started` chunk).
                ok = wait_for_chunk(Sock, ~"started"),
                %% Drain — handler receives {roadrunner_drain, _} and stops.
                ?assertEqual({ok, drained}, roadrunner_listener:drain(Name, 2000)),
                wait_until_unregistered(Name),
                gen_tcp:close(Sock)
            end}
        end}.

drain_timeout_kills_unresponsive_conns_test_() ->
    {setup,
        fun() ->
            ensure_pg_started(),
            Name = listener_test_drain_kill,
            {ok, _} = roadrunner_listener:start_link(Name, #{
                port => 0,
                routes => [{~"/sleep", roadrunner_drain_ignore_handler, #{}}]
            }),
            {Name, roadrunner_listener:port(Name)}
        end,
        fun(_) -> ok end, fun({Name, Port}) ->
            {"drain timeout returns {timeout, N} and hard-kills remainders", fun() ->
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                ok = gen_tcp:send(
                    Sock, ~"GET /sleep HTTP/1.1\r\nHost: x\r\n\r\n"
                ),
                ok = wait_for_chunk(Sock, ~"started"),
                %% Handler ignores roadrunner_drain — drain must time out.
                ?assertMatch({timeout, N} when N > 0, roadrunner_listener:drain(Name, 100)),
                wait_until_unregistered(Name),
                gen_tcp:close(Sock)
            end}
        end}.

drain_closes_keep_alive_conn_after_in_flight_request_test_() ->
    {setup,
        fun() ->
            ensure_pg_started(),
            Name = listener_test_drain_ka,
            {ok, _} = roadrunner_listener:start_link(Name, #{
                port => 0, handler => roadrunner_drain_pause_handler
            }),
            {Name, roadrunner_listener:port(Name)}
        end,
        fun(_) -> ok end, fun({Name, Port}) ->
            {"keep-alive conn closes at next loop iteration when drain msg arrives", fun() ->
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                %% Send request 1; the handler sleeps 150ms before
                %% responding. While it sleeps we kick drain in another
                %% process, which sends {roadrunner_drain, _} to this conn.
                %% Once the handler finishes, serve_loop sees the drain
                %% message in its mailbox and closes without trying
                %% to read a second keep-alive request.
                ok = gen_tcp:send(Sock, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"),
                %% Brief warm-up so the conn has joined the `pg` drain
                %% group before drain queries members. The acceptor
                %% bumps the live-clients counter before spawning the
                %% conn; without this sleep, drain can observe
                %% counter=1 / pg=empty on a slow scheduler and time
                %% out before the handler's 150ms sleep finishes.
                timer:sleep(20),
                Self = self(),
                spawn_link(fun() ->
                    Self ! {drain_result, roadrunner_listener:drain(Name, 2000)}
                end),
                Resp1 = recv_one_full_response(Sock),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Resp1),
                %% drain returns ok,drained because the conn closes
                %% itself via the drain-pending check.
                receive
                    {drain_result, Got} ->
                        ?assertEqual({ok, drained}, Got)
                after 3000 -> error(no_drain_result)
                end,
                gen_tcp:close(Sock)
            end}
        end}.

recv_one_full_response(Sock) ->
    recv_one_full_response(Sock, <<>>).

recv_one_full_response(Sock, Acc) ->
    case binary:split(Acc, ~"\r\n\r\n") of
        [Head, Rest] ->
            CL = parse_cl(Head),
            case Rest of
                <<Body:CL/binary, _/binary>> ->
                    <<Head/binary, "\r\n\r\n", Body/binary>>;
                _ ->
                    recv_more_or_done(Sock, Acc)
            end;
        [_] ->
            recv_more_or_done(Sock, Acc)
    end.

recv_more_or_done(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 2000) of
        {ok, More} -> recv_one_full_response(Sock, <<Acc/binary, More/binary>>);
        %% Socket closed — return whatever's buffered so the parent
        %% match against `<<"HTTP/1.1 200 OK", _/binary>>` succeeds on
        %% the prefix bytes that did arrive before the close.
        {error, closed} -> Acc
    end.

parse_cl(Head) ->
    {match, [Cl]} = re:run(
        Head, ~"(?i)content-length:\\s*(\\d+)", [{capture, [1], binary}]
    ),
    binary_to_integer(Cl).

reload_routes_swaps_dispatch_table_test_() ->
    {setup,
        fun() ->
            ensure_pg_started(),
            Name = listener_test_reload,
            {ok, _} = roadrunner_listener:start_link(Name, #{
                port => 0,
                routes => [{~"/old", roadrunner_hello_handler, #{}}]
            }),
            {Name, roadrunner_listener:port(Name)}
        end,
        fun({Name, _Port}) -> ok = roadrunner_listener:stop(Name) end, fun({Name, Port}) ->
            {"reload_routes/2 makes new path resolvable, old one 404", fun() ->
                %% Old path is live.
                Reply1 = http_get_close(Port, ~"/old"),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply1),
                %% Swap routes — `/old` removed, `/new` added.
                ok = roadrunner_listener:reload_routes(
                    Name, [{~"/new", roadrunner_hello_handler, #{}}]
                ),
                Reply2 = http_get_close(Port, ~"/new"),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply2),
                Reply3 = http_get_close(Port, ~"/old"),
                ?assertMatch(<<"HTTP/1.1 404 ", _/binary>>, Reply3)
            end}
        end}.

reload_routes_on_handler_listener_returns_no_routes_error_test() ->
    Name = listener_test_reload_no_routes,
    {ok, _} = roadrunner_listener:start_link(Name, #{
        port => 0, handler => roadrunner_hello_handler
    }),
    try
        ?assertEqual(
            {error, no_routes},
            roadrunner_listener:reload_routes(Name, [{~"/x", roadrunner_hello_handler, #{}}])
        )
    after
        ok = roadrunner_listener:stop(Name)
    end.

routes_persistent_term_erased_on_listener_stop_test() ->
    Name = listener_test_pt_erase,
    Routes = [{~"/x", roadrunner_hello_handler, #{}}],
    {ok, _} = roadrunner_listener:start_link(Name, #{port => 0, routes => Routes}),
    %% Term is published.
    Compiled = persistent_term:get({roadrunner_routes, Name}),
    ?assertNotEqual(undefined, Compiled),
    ok = roadrunner_listener:stop(Name),
    %% Stopping the listener erases it.
    ?assertException(error, badarg, persistent_term:get({roadrunner_routes, Name})).

http_get_close(Port, Path) ->
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
    ),
    Req = iolist_to_binary([
        ~"GET ",
        Path,
        ~" HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
    ]),
    ok = gen_tcp:send(Sock, Req),
    Reply = drain_close(Sock, <<>>),
    ok = gen_tcp:close(Sock),
    Reply.

drain_close(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 1000) of
        {ok, Data} -> drain_close(Sock, <<Acc/binary, Data/binary>>);
        {error, _} -> Acc
    end.

status_returns_phase_test_() ->
    {setup,
        fun() ->
            ensure_pg_started(),
            Name = listener_test_status,
            {ok, _} = roadrunner_listener:start_link(Name, #{
                port => 0, handler => roadrunner_hello_handler
            }),
            Name
        end,
        fun(Name) ->
            case whereis(Name) of
                undefined -> ok;
                _ -> ok = roadrunner_listener:stop(Name)
            end
        end,
        fun(Name) ->
            {"status/1 returns accepting before drain", fun() ->
                ?assertEqual(accepting, roadrunner_listener:status(Name))
            end}
        end}.

ensure_pg_started() ->
    case whereis(pg) of
        undefined ->
            {ok, _} = pg:start_link();
        _ ->
            ok
    end.

%% gen_server replies to `drain/2` *before* `terminate/2` finishes, so
%% there's a brief window where `whereis/1` still returns the pid even
%% though the listener is on its way out. Poll until the name unregisters.
wait_until_unregistered(Name) ->
    wait_until_unregistered(Name, 50).

wait_until_unregistered(Name, 0) ->
    ?assertEqual(undefined, whereis(Name));
wait_until_unregistered(Name, N) ->
    case whereis(Name) of
        undefined ->
            ok;
        _ ->
            timer:sleep(20),
            wait_until_unregistered(Name, N - 1)
    end.

wait_for_chunk(Sock, Needle) ->
    wait_for_chunk(Sock, Needle, <<>>, 20).

wait_for_chunk(_Sock, _Needle, _Acc, 0) ->
    error(needle_not_found);
wait_for_chunk(Sock, Needle, Acc, Attempts) ->
    case gen_tcp:recv(Sock, 0, 200) of
        {ok, Data} ->
            New = <<Acc/binary, Data/binary>>,
            case binary:match(New, Needle) of
                nomatch -> wait_for_chunk(Sock, Needle, New, Attempts - 1);
                _ -> ok
            end;
        {error, _} ->
            wait_for_chunk(Sock, Needle, Acc, Attempts - 1)
    end.

%% =============================================================================
%% Per-request `logger` metadata + `roadrunner_req:request_id/1` correlation.
%% =============================================================================

logger_metadata_set_for_each_request_test_() ->
    {setup,
        fun() ->
            Name = listener_test_logger_md,
            {ok, _} = roadrunner_listener:start_link(Name, #{
                port => 0, handler => roadrunner_logger_probe_handler
            }),
            {Name, roadrunner_listener:port(Name)}
        end,
        fun({Name, _Port}) -> ok = roadrunner_listener:stop(Name) end, fun({_Name, Port}) ->
            [
                {"handler sees request_id + logger metadata populated", fun() ->
                    {Md, Id} = probe_one(Port),
                    ?assertMatch(<<_:16/binary>>, Id),
                    ?assert(is_hex_lowercase(Id)),
                    ?assertEqual(Id, maps:get(request_id, Md)),
                    ?assertEqual(~"GET", maps:get(method, Md)),
                    ?assertEqual(~"/", maps:get(path, Md)),
                    ?assertMatch({{127, 0, 0, 1}, _}, maps:get(peer, Md))
                end},
                {"keep-alive requests get distinct request_ids", fun() ->
                    {ok, Sock} = gen_tcp:connect(
                        {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                    ),
                    Id1 = probe_via_sock(Sock),
                    Id2 = probe_via_sock(Sock),
                    ok = gen_tcp:close(Sock),
                    ?assertNotEqual(Id1, Id2)
                end}
            ]
        end}.

probe_one(Port) ->
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
    ok = gen_tcp:send(Sock, ~"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"),
    Reply = drain_to_binary(Sock),
    ok = gen_tcp:close(Sock),
    Body = http_body(Reply),
    Probe = binary_to_term(Body, [safe]),
    {maps:get(logger_metadata, Probe), maps:get(request_id, Probe)}.

probe_via_sock(Sock) ->
    ok = gen_tcp:send(Sock, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"),
    Reply = drain_one_response(Sock),
    Probe = binary_to_term(http_body(Reply), [safe]),
    maps:get(request_id, Probe).

drain_to_binary(Sock) -> drain_to_binary(Sock, <<>>).
drain_to_binary(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 1000) of
        {ok, Data} -> drain_to_binary(Sock, <<Acc/binary, Data/binary>>);
        {error, _} -> Acc
    end.

%% Read until the body of one fixed-content-length response is buffered.
drain_one_response(Sock) ->
    drain_one_response(Sock, <<>>).
drain_one_response(Sock, Acc) ->
    case binary:split(Acc, ~"\r\n\r\n") of
        [Head, Rest] ->
            CL = parse_content_length(Head),
            case Rest of
                <<Body:CL/binary, _/binary>> -> <<Head/binary, "\r\n\r\n", Body/binary>>;
                _ -> drain_one_response(Sock, recv_more(Sock, Acc))
            end;
        [_] ->
            drain_one_response(Sock, recv_more(Sock, Acc))
    end.

recv_more(Sock, Acc) ->
    {ok, Data} = gen_tcp:recv(Sock, 0, 1000),
    <<Acc/binary, Data/binary>>.

http_body(Reply) ->
    [_Head, Body] = binary:split(Reply, ~"\r\n\r\n"),
    Body.

parse_content_length(Head) ->
    {match, [Cl]} = re:run(Head, ~"(?i)content-length:\\s*(\\d+)", [{capture, [1], binary}]),
    binary_to_integer(Cl).

is_hex_lowercase(Bin) ->
    lists:all(
        fun(C) -> (C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f) end,
        binary_to_list(Bin)
    ).
