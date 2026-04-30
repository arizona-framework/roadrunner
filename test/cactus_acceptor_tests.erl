-module(cactus_acceptor_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Acceptor wired into cactus_listener — hand off to cactus_conn.
%% =============================================================================

acceptor_serves_request_test_() ->
    {setup,
        fun() ->
            {ok, _} = cactus_listener:start_link(acceptor_test_serves, #{port => 0}),
            cactus_listener:port(acceptor_test_serves)
        end,
        fun(_) -> ok = cactus_listener:stop(acceptor_test_serves) end, fun(Port) ->
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
            {ok, _} = cactus_listener:start_link(acceptor_test_loop, #{port => 0}),
            cactus_listener:port(acceptor_test_loop)
        end,
        fun(_) -> ok = cactus_listener:stop(acceptor_test_loop) end, fun(Port) ->
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

%% --- helpers ---

recv_until_closed(Sock) ->
    recv_until_closed(Sock, <<>>).

recv_until_closed(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 2000) of
        {ok, Data} -> recv_until_closed(Sock, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc;
        {error, _} -> Acc
    end.
