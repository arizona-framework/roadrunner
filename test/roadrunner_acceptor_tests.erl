-module(roadrunner_acceptor_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Acceptor wired into roadrunner_listener — hand off to roadrunner_conn.
%% =============================================================================

acceptor_serves_request_test_() ->
    {setup,
        fun() ->
            {ok, _} = roadrunner_listener:start_link(acceptor_test_serves, #{
                port => 0, handler => roadrunner_hello_handler
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
                port => 0, handler => roadrunner_hello_handler
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
                    port => 0, num_acceptors => 3, handler => roadrunner_hello_handler
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
                port => 0, handler => roadrunner_hello_handler
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

%% --- helpers ---

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
