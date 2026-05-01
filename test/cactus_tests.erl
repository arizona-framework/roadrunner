-module(cactus_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Public API: cactus:start_listener/2 + stop_listener/1
%% =============================================================================

cactus_test_() ->
    {setup, fun() -> {ok, _} = application:ensure_all_started(cactus) end,
        fun(_) -> ok = application:stop(cactus) end, [
            {"start_listener returns {ok, Pid} and serves a request",
                fun starts_listener_and_serves/0},
            {"stop_listener removes the child", fun stops_listener_cleanly/0},
            {"stop_listener on unknown name returns {error, not_found}",
                fun stop_unknown_listener/0},
            {"start_listener with a name already in use returns an error",
                fun duplicate_listener_rejected/0},
            {"listeners/0 returns the registered names", fun lists_active_listeners/0}
        ]}.

starts_listener_and_serves() ->
    {ok, Pid} = cactus:start_listener(public_test_serve, #{port => 0}),
    ?assert(is_pid(Pid)),
    Port = cactus_listener:port(public_test_serve),
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
    ok = gen_tcp:send(Sock, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"),
    Reply = recv_until_closed(Sock),
    ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
    ok = gen_tcp:close(Sock),
    ok = cactus:stop_listener(public_test_serve).

stops_listener_cleanly() ->
    {ok, _} = cactus:start_listener(public_test_stop, #{port => 0}),
    ?assert(lists:member(public_test_stop, cactus:listeners())),
    ok = cactus:stop_listener(public_test_stop),
    %% After stop, the gen_server is gone — we don't probe the TCP port
    %% because the OS may briefly accept a connect against a freshly-
    %% closed listen socket, or another concurrent test may have
    %% allocated the same ephemeral port. The registry membership is
    %% the reliable cleanliness signal.
    ?assertNot(lists:member(public_test_stop, cactus:listeners())),
    ?assertExit(_, cactus_listener:port(public_test_stop)).

stop_unknown_listener() ->
    ?assertEqual({error, not_found}, cactus:stop_listener(public_test_nope)).

duplicate_listener_rejected() ->
    {ok, _} = cactus:start_listener(public_test_dup, #{port => 0}),
    ?assertMatch({error, _}, cactus:start_listener(public_test_dup, #{port => 0})),
    ok = cactus:stop_listener(public_test_dup).

lists_active_listeners() ->
    ?assertEqual([], cactus:listeners()),
    {ok, _} = cactus:start_listener(public_test_l1, #{port => 0}),
    {ok, _} = cactus:start_listener(public_test_l2, #{port => 0}),
    Names = lists:sort(cactus:listeners()),
    ?assertEqual([public_test_l1, public_test_l2], Names),
    ok = cactus:stop_listener(public_test_l1),
    ok = cactus:stop_listener(public_test_l2),
    ?assertEqual([], cactus:listeners()).

%% --- helpers ---

recv_until_closed(Sock) -> recv_until_closed(Sock, <<>>).

recv_until_closed(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 2000) of
        {ok, Data} -> recv_until_closed(Sock, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc;
        {error, _} -> Acc
    end.
