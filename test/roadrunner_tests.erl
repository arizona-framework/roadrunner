-module(roadrunner_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Public API: roadrunner:start_listener/2 + stop_listener/1
%% =============================================================================

roadrunner_test_() ->
    {setup, fun() -> {ok, _} = application:ensure_all_started(roadrunner) end,
        fun(_) -> ok = application:stop(roadrunner) end, [
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
    {ok, Pid} = start(public_test_serve),
    ?assert(is_pid(Pid)),
    Port = roadrunner_listener:port(public_test_serve),
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
    ok = gen_tcp:send(Sock, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"),
    Reply = recv_until_closed(Sock),
    ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
    ok = gen_tcp:close(Sock),
    ok = roadrunner:stop_listener(public_test_serve).

stops_listener_cleanly() ->
    {ok, _} = start(public_test_stop),
    ?assert(lists:member(public_test_stop, roadrunner:listeners())),
    ok = roadrunner:stop_listener(public_test_stop),
    %% After stop, the gen_server is gone — we don't probe the TCP port
    %% because the OS may briefly accept a connect against a freshly-
    %% closed listen socket, or another concurrent test may have
    %% allocated the same ephemeral port. The registry membership is
    %% the reliable cleanliness signal.
    ?assertNot(lists:member(public_test_stop, roadrunner:listeners())),
    ?assertExit(_, roadrunner_listener:port(public_test_stop)).

stop_unknown_listener() ->
    ?assertEqual({error, not_found}, roadrunner:stop_listener(public_test_nope)).

duplicate_listener_rejected() ->
    {ok, _} = start(public_test_dup),
    ?assertMatch({error, _}, start(public_test_dup)),
    ok = roadrunner:stop_listener(public_test_dup).

lists_active_listeners() ->
    ?assertEqual([], roadrunner:listeners()),
    {ok, _} = start(public_test_l1),
    {ok, _} = start(public_test_l2),
    Names = lists:sort(roadrunner:listeners()),
    ?assertEqual([public_test_l1, public_test_l2], Names),
    ok = roadrunner:stop_listener(public_test_l1),
    ok = roadrunner:stop_listener(public_test_l2),
    ?assertEqual([], roadrunner:listeners()).

%% --- helpers ---

start(Name) ->
    roadrunner:start_listener(Name, #{port => 0, handler => roadrunner_hello_handler}).

recv_until_closed(Sock) -> recv_until_closed(Sock, <<>>).

recv_until_closed(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 2000) of
        {ok, Data} -> recv_until_closed(Sock, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc;
        {error, _} -> Acc
    end.
