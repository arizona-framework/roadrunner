-module(cactus_listener_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% start_link/2 + stop/1 + port/1
%% =============================================================================

listener_lifecycle_test_() ->
    {setup,
        fun() ->
            Name = listener_test_one,
            {ok, Pid} = cactus_listener:start_link(Name, #{port => 0}),
            {Name, Pid}
        end,
        fun({Name, _Pid}) ->
            ok = cactus_listener:stop(Name)
        end,
        fun({Name, Pid}) ->
            [
                {"start_link returns alive pid",
                    ?_assert(is_pid(Pid) andalso is_process_alive(Pid))},
                {"port/1 returns a non-zero ephemeral port",
                    ?_assert(cactus_listener:port(Name) > 0)},
                {"two consecutive port/1 calls return the same value",
                    ?_assertEqual(cactus_listener:port(Name), cactus_listener:port(Name))}
            ]
        end}.

listener_accepts_tcp_handshake_test_() ->
    {setup,
        fun() ->
            Name = listener_test_handshake,
            {ok, _} = cactus_listener:start_link(Name, #{port => 0}),
            cactus_listener:port(Name)
        end,
        fun(_Port) ->
            ok = cactus_listener:stop(listener_test_handshake)
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
            {ok, _} = cactus_listener:start_link(Name, #{port => 0}),
            Port = cactus_listener:port(Name),
            ok = cactus_listener:stop(Name),
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
    {ok, _} = cactus_listener:start_link(listener_test_busy_a, #{port => 0}),
    Port = cactus_listener:port(listener_test_busy_a),
    process_flag(trap_exit, true),
    Result = cactus_listener:start_link(listener_test_busy_b, #{port => Port}),
    ?assertMatch({error, _}, Result),
    ok = cactus_listener:stop(listener_test_busy_a).

listener_ignores_unknown_cast_test() ->
    {ok, _} = cactus_listener:start_link(listener_test_cast, #{port => 0}),
    gen_server:cast(listener_test_cast, surprise),
    %% Process must still answer call/1 — proves it survived the cast.
    ?assert(cactus_listener:port(listener_test_cast) > 0),
    ok = cactus_listener:stop(listener_test_cast).
