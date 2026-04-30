-module(cactus_acceptor_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Acceptor wired into cactus_listener — accept and close.
%% =============================================================================

acceptor_closes_each_connection_test_() ->
    {setup,
        fun() ->
            {ok, _} = cactus_listener:start_link(acceptor_test_close, #{port => 0}),
            cactus_listener:port(acceptor_test_close)
        end,
        fun(_) -> ok = cactus_listener:stop(acceptor_test_close) end, fun(Port) ->
            {"server-side close is observable as {error, closed} on recv", fun() ->
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                ?assertEqual({error, closed}, gen_tcp:recv(Sock, 0, 1000)),
                ok = gen_tcp:close(Sock)
            end}
        end}.

acceptor_keeps_accepting_after_close_test_() ->
    {setup,
        fun() ->
            {ok, _} = cactus_listener:start_link(acceptor_test_loop, #{port => 0}),
            cactus_listener:port(acceptor_test_loop)
        end,
        fun(_) -> ok = cactus_listener:stop(acceptor_test_loop) end, fun(Port) ->
            {"three sequential connections are all accepted+closed", fun() ->
                lists:foreach(
                    fun(_) ->
                        {ok, Sock} = gen_tcp:connect(
                            {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                        ),
                        ?assertEqual({error, closed}, gen_tcp:recv(Sock, 0, 1000)),
                        ok = gen_tcp:close(Sock)
                    end,
                    lists:seq(1, 3)
                )
            end}
        end}.
