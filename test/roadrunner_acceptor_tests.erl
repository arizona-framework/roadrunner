-module(roadrunner_acceptor_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Acceptor wired into roadrunner_listener — hand off to roadrunner_conn.
%% =============================================================================

acceptor_serves_request_test_() ->
    {setup,
        fun() ->
            {ok, _} = roadrunner_listener:start_link(acceptor_test_serves, #{
                port => 0, routes => roadrunner_hello_handler
            }),
            roadrunner_listener:port(acceptor_test_serves)
        end,
        fun(_) -> ok = roadrunner_listener:stop(acceptor_test_serves) end, fun(Port) ->
            {"connection is accepted, served, then closed", fun() ->
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                ok = gen_tcp:send(Sock, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"),
                Reply = recv_until_closed(Sock),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
                ok = gen_tcp:close(Sock)
            end}
        end}.

acceptor_serves_multiple_connections_test_() ->
    {setup,
        fun() ->
            {ok, _} = roadrunner_listener:start_link(acceptor_test_loop, #{
                port => 0, routes => roadrunner_hello_handler
            }),
            roadrunner_listener:port(acceptor_test_loop)
        end,
        fun(_) -> ok = roadrunner_listener:stop(acceptor_test_loop) end, fun(Port) ->
            {"three sequential requests are all served", fun() ->
                lists:foreach(
                    fun(_) ->
                        {ok, Sock} = gen_tcp:connect(
                            {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                        ),
                        ok = gen_tcp:send(Sock, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"),
                        Reply = recv_until_closed(Sock),
                        ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
                        ok = gen_tcp:close(Sock)
                    end,
                    lists:seq(1, 3)
                )
            end}
        end}.

acceptor_processes_carry_listener_name_and_index_label_test_() ->
    {setup,
        fun() ->
            {ok, _} = roadrunner_listener:start_link(
                acceptor_test_labels, #{
                    port => 0, num_acceptors => 3, routes => roadrunner_hello_handler
                }
            ),
            acceptor_test_labels
        end,
        fun(Name) -> ok = roadrunner_listener:stop(Name) end, fun(Name) ->
            {"acceptor pool labels include listener name + 1-based index", fun() ->
                ListenerPid = whereis(Name),
                {links, Links} = process_info(ListenerPid, links),
                Labels = [proc_lib:get_label(P) || P <- Links, is_pid(P)],
                AcceptorLabels = lists:sort([
                    L
                 || L <- Labels, is_tuple(L), element(1, L) =:= roadrunner_acceptor
                ]),
                ?assertEqual(
                    [
                        {roadrunner_acceptor, Name, 1},
                        {roadrunner_acceptor, Name, 2},
                        {roadrunner_acceptor, Name, 3}
                    ],
                    AcceptorLabels
                )
            end}
        end}.

conn_process_carries_listener_name_and_peer_label_test_() ->
    {setup,
        fun() ->
            {ok, _} = roadrunner_listener:start_link(conn_test_labels, #{
                port => 0, routes => roadrunner_hello_handler
            }),
            {conn_test_labels, roadrunner_listener:port(conn_test_labels)}
        end,
        fun({Name, _}) -> ok = roadrunner_listener:stop(Name) end, fun({Name, Port}) ->
            {"conn label is {roadrunner_conn, ListenerName, Peer} once peername is known", fun() ->
                %% Connect but don't send — the conn enters its recv loop
                %% holding the request_timeout (default 30s) so we have
                %% time to inspect its label.
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                %% Tiny grace for the spawn → set_label race.
                ok = wait_for_conn_label(Name, 50, 20),
                ConnLabels = matching_labels(roadrunner_conn, Name),
                ?assertMatch([{roadrunner_conn, Name, {{127, 0, 0, 1}, _}}], ConnLabels),
                gen_tcp:close(Sock)
            end}
        end}.

acceptor_retries_on_transient_accept_error_test() ->
    %% Accepting on a connected (non-listen) socket fails with a transient
    %% error (einval here, standing in for emfile descriptor exhaustion). The
    %% acceptor must report it via telemetry and keep looping, NOT exit and
    %% leave the listener silently deaf. Closing the socket then yields
    %% {error, closed}, which ends the loop cleanly.
    {ok, LSock} = gen_tcp:listen(0, [binary, {active, false}]),
    {ok, Port} = inet:port(LSock),
    {ok, CSock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    HandlerId = {?MODULE, make_ref()},
    ok = telemetry:attach(
        HandlerId,
        [roadrunner, listener, accept_error],
        fun(_Event, _Measure, Meta, _Cfg) -> Self ! {accept_error, Meta} end,
        undefined
    ),
    {ok, Pid} = roadrunner_acceptor:start_link(
        {gen_tcp, CSock},
        #{listener_name => acceptor_test_accept_error, tls_handshake_timeout => 5000},
        1
    ),
    receive
        {accept_error, Meta} ->
            ?assertEqual(acceptor_test_accept_error, maps:get(listener_name, Meta)),
            ?assertNotEqual(closed, maps:get(reason, Meta))
    after 2000 ->
        error(no_accept_error_telemetry)
    end,
    %% Survived the transient error.
    ?assert(is_process_alive(Pid)),
    %% Closing the socket turns the next accept into {error, closed} → exit.
    MRef = erlang:monitor(process, Pid),
    ok = gen_tcp:close(CSock),
    receive
        {'DOWN', MRef, process, Pid, normal} -> ok
    after 2000 ->
        error(acceptor_did_not_stop)
    end,
    ok = telemetry:detach(HandlerId),
    ok = gen_tcp:close(LSock).

accept_error_class_test() ->
    %% Per-connection failures retry immediately; resource exhaustion
    %% and unknowns back off. Exhaustive over the classifier's clauses.
    ?assertEqual(retry, roadrunner_acceptor:accept_error_class(econnaborted)),
    ?assertEqual(backoff, roadrunner_acceptor:accept_error_class(emfile)),
    ?assertEqual(backoff, roadrunner_acceptor:accept_error_class(enfile)),
    ?assertEqual(backoff, roadrunner_acceptor:accept_error_class(system_limit)),
    ?assertEqual(backoff, roadrunner_acceptor:accept_error_class(einval)).

pace_after_error_test() ->
    %% `retry` goes straight back to accept; `backoff` sits out the
    %% pause first.
    T0 = erlang:monotonic_time(millisecond),
    ?assertEqual(ok, roadrunner_acceptor:pace_after_error(retry)),
    ?assert(erlang:monotonic_time(millisecond) - T0 < 50),
    ?assertEqual(ok, roadrunner_acceptor:pace_after_error(backoff)),
    ?assert(erlang:monotonic_time(millisecond) - T0 >= 100).

acceptor_hands_tls_sockets_off_before_the_handshake_test() ->
    %% The acceptor takes a TLS socket pre-handshake and hands it to a
    %% conn, which runs the handshake itself. A garbage ClientHello
    %% therefore never touches the acceptor: the conn reports it as a
    %% `{handshake, _}` accept_error and gives the slot back, while the
    %% acceptor keeps accepting and reserves plain `closed` (the listen
    %% socket going away) for its clean exit.
    {ok, _} = application:ensure_all_started(ssl),
    {ok, _} = application:ensure_all_started(telemetry),
    ServerOpts =
        roadrunner_test_certs:server_opts() ++
            [binary, {active, false}, {reuseaddr, true}],
    {ok, LSock} = roadrunner_transport:listen_tls(0, ServerOpts),
    {ok, Port} = roadrunner_transport:port(LSock),
    Self = self(),
    HandlerId = {?MODULE, make_ref()},
    ok = telemetry:attach(
        HandlerId,
        [roadrunner, listener, accept_error],
        fun(_Event, _Measure, Meta, _Cfg) -> Self ! {accept_error, Meta} end,
        undefined
    ),
    Counter = counters:new(1, [write_concurrency]),
    {ok, Pid} = roadrunner_acceptor:start_link(
        LSock,
        #{
            listener_name => acceptor_test_tls_noise,
            tls_handshake_timeout => 5000,
            proxy_protocol => false,
            client_counter => Counter,
            max_clients => 10,
            graceful_drain => false,
            handler_spawn_opts => [{fullsweep_after, 0}],
            handler_start_timeout => infinity
        },
        1
    ),
    %% Plain-HTTP bytes can't form a TLS hello — the conn's handshake fails.
    {ok, Noise} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
    ok = gen_tcp:send(Noise, ~"GET / HTTP/1.1\r\n\r\n"),
    receive
        {accept_error, Meta} ->
            ?assertEqual(acceptor_test_tls_noise, maps:get(listener_name, Meta)),
            ?assertMatch({handshake, _}, maps:get(reason, Meta))
    after 5000 ->
        error(no_handshake_error_telemetry)
    end,
    ok = gen_tcp:close(Noise),
    %% The slot taken at accept is released by the failing conn.
    ok = wait_for_counter(Counter, 0, 200),
    %% Survived the noise connection.
    ?assert(is_process_alive(Pid)),
    %% Closing the listen socket ends the loop cleanly.
    MRef = erlang:monitor(process, Pid),
    ok = roadrunner_transport:close(LSock),
    receive
        {'DOWN', MRef, process, Pid, normal} -> ok
    after 2000 ->
        error(acceptor_did_not_stop)
    end,
    ok = telemetry:detach(HandlerId).

%% --- helpers ---

%% Poll the live-connection counter until it reads `Expected`; the slot
%% release runs after the accept_error event, so the first read can race it.
wait_for_counter(_Counter, Expected, 0) ->
    error({counter_never_reached, Expected});
wait_for_counter(Counter, Expected, Attempts) ->
    case counters:get(Counter, 1) of
        Expected ->
            ok;
        _ ->
            timer:sleep(10),
            wait_for_counter(Counter, Expected, Attempts - 1)
    end.

%% Poll until we see a refined `{roadrunner_conn, Name, Peer}` label or run
%% out of attempts. Avoids a fixed `timer:sleep` race on slow CI.
wait_for_conn_label(_Name, _Sleep, 0) ->
    error(no_conn_label);
wait_for_conn_label(Name, Sleep, Attempts) ->
    case matching_labels(roadrunner_conn, Name) of
        [{roadrunner_conn, Name, {_, _}}] ->
            ok;
        _ ->
            timer:sleep(Sleep),
            wait_for_conn_label(Name, Sleep, Attempts - 1)
    end.

matching_labels(Tag, Name) ->
    [
        L
     || P <- processes(),
        L <- [proc_lib:get_label(P)],
        is_tuple(L),
        element(1, L) =:= Tag,
        tuple_size(L) >= 2,
        element(2, L) =:= Name
    ].

recv_until_closed(Sock) ->
    recv_until_closed(Sock, <<>>).

recv_until_closed(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 2000) of
        {ok, Data} -> recv_until_closed(Sock, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc;
        {error, _} -> Acc
    end.
