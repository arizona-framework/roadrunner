-module(roadrunner_route_ceiling_SUITE).
-moduledoc """
A route's own `max_concurrent_requests` and `overload_mode` in a listener.
""".

-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([
    route_queues_reaching_the_listener_ceiling_stop_the_start/1,
    route_queues_reaching_the_listener_ceiling_are_refused_on_reload/1,
    route_queues_under_the_listener_ceiling_start/1,
    info_reports_the_route_ceilings/1,
    reload_keeps_the_count_and_applies_the_new_ceiling/1,
    dropped_route_drains_then_goes/1,
    route_brought_back_keeps_its_count/1,
    route_dropped_twice_keeps_draining/1,
    drained_keeper_refuses_a_straggler/1,
    drained_keeper_of_a_route_brought_back_is_replaced/1,
    draining_keeper_serves_its_waiter_first/1,
    reload_adds_a_route_ceiling/1,
    failed_reload_stops_the_new_keepers/1,
    keeper_crash_is_taken_over_by_a_new_keeper/1,
    stop_ends_the_keepers/1
]).

suite() ->
    [{timetrap, {seconds, 60}}].

all() ->
    [
        route_queues_reaching_the_listener_ceiling_stop_the_start,
        route_queues_reaching_the_listener_ceiling_are_refused_on_reload,
        route_queues_under_the_listener_ceiling_start,
        info_reports_the_route_ceilings,
        reload_keeps_the_count_and_applies_the_new_ceiling,
        dropped_route_drains_then_goes,
        route_brought_back_keeps_its_count,
        route_dropped_twice_keeps_draining,
        drained_keeper_refuses_a_straggler,
        drained_keeper_of_a_route_brought_back_is_replaced,
        draining_keeper_serves_its_waiter_first,
        reload_adds_a_route_ceiling,
        failed_reload_stops_the_new_keepers,
        keeper_crash_is_taken_over_by_a_new_keeper,
        stop_ends_the_keepers
    ].

init_per_suite(Config) ->
    {ok, _} = roadrunner_test_event_handler:start(),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_Case, Config) ->
    Config.

end_per_testcase(_Case, _Config) ->
    ok.

%% --- the listener's ceiling and the route queues ---

route_queues_reaching_the_listener_ceiling_stop_the_start(_Config) ->
    %% Two queued routes may hold 4 + 4 and 2 + 6 listener slots, 16 in all,
    %% the whole listener ceiling: a cheap route could then find none free.
    %% The start fails in `init/1`, so this process traps the linked exit.
    process_flag(trap_exit, true),
    ?assertMatch(
        {error, {{route_queues_reach_max_concurrent_requests, 16, 16}, _}},
        roadrunner_listener:start_link(?FUNCTION_NAME, #{
            port => 0,
            max_concurrent_requests => 16,
            routes => [
                queued(~"/a", 4, #{}),
                queued(~"/b", 2, #{max_queued => 6}),
                %% A shed route waits for nothing, so it is not counted.
                #{
                    path => ~"/c",
                    handler => roadrunner_hello_handler,
                    max_concurrent_requests => 100
                }
            ]
        })
    ),
    %% Nothing published for a listener that never started.
    ?assertEqual(undefined, persistent_term:get({roadrunner_routes, ?FUNCTION_NAME}, undefined)).

route_queues_reaching_the_listener_ceiling_are_refused_on_reload(_Config) ->
    {ok, _} = roadrunner_listener:start_link(?FUNCTION_NAME, #{
        port => 0,
        max_concurrent_requests => 10,
        routes => [queued(~"/a", 4, #{})]
    }),
    Before = persistent_term:get({roadrunner_routes, ?FUNCTION_NAME}),
    ?assertEqual(
        {error, {route_queues_reach_max_concurrent_requests, 12, 10}},
        roadrunner_listener:reload_routes(?FUNCTION_NAME, [queued(~"/a", 6, #{})])
    ),
    ?assertEqual(Before, persistent_term:get({roadrunner_routes, ?FUNCTION_NAME})),
    ok = roadrunner_listener:stop(?FUNCTION_NAME).

route_queues_under_the_listener_ceiling_start(_Config) ->
    %% 4 + 4 under 9 leaves a slot for the other routes; with no listener
    %% ceiling there is nothing to starve.
    {ok, _} = roadrunner_listener:start_link(?FUNCTION_NAME, #{
        port => 0,
        max_concurrent_requests => 9,
        routes => [queued(~"/a", 4, #{})]
    }),
    ok = roadrunner_listener:stop(?FUNCTION_NAME),
    {ok, _} = roadrunner_listener:start_link(?FUNCTION_NAME, #{
        port => 0,
        routes => [queued(~"/a", 400, #{})]
    }),
    ok = roadrunner_listener:stop(?FUNCTION_NAME).

%% --- the counts a listener keeps ---

info_reports_the_route_ceilings(_Config) ->
    Name = ?FUNCTION_NAME,
    {ok, _} = roadrunner_listener:start_link(Name, #{
        port => 0,
        routes => [
            {~"/plain", roadrunner_hello_handler},
            capped(~"/a", 2),
            (queued(~"/b", 3, #{}))#{methods => [~"POST", ~"GET"]}
        ]
    }),
    Holder = holder(Name, ~"GET", ~"/a"),
    {ok, _} = result(Holder),
    {ok, _} = result(holder(Name, ~"GET", ~"/a")),
    {refused, 1} = result(holder(Name, ~"GET", ~"/a")),
    ?assertEqual(
        [
            #{
                path => ~"/a",
                methods => undefined,
                max_concurrent_requests => 2,
                in_flight => 2,
                queued => 0,
                throttled => 1
            },
            #{
                path => ~"/b",
                methods => [~"GET", ~"POST"],
                max_concurrent_requests => 3,
                in_flight => 0,
                queued => 0,
                throttled => 0
            }
        ],
        maps:get(routes, roadrunner_listener:info(Name))
    ),
    %% The listener's own ceiling counts none of it.
    ?assertMatch(#{throttled := 0}, roadrunner_listener:info(Name)),
    ok = roadrunner_listener:stop(Name),
    {ok, _} = roadrunner_listener:start_link(Name, #{port => 0, routes => roadrunner_hello_handler}),
    ?assertMatch(#{routes := []}, roadrunner_listener:info(Name)),
    ok = roadrunner_listener:stop(Name).

reload_keeps_the_count_and_applies_the_new_ceiling(_Config) ->
    Name = ?FUNCTION_NAME,
    {ok, _} = roadrunner_listener:start_link(Name, #{port => 0, routes => [capped(~"/a", 1)]}),
    A = holder(Name, ~"GET", ~"/a"),
    {ok, _} = result(A),
    Keeper = keeper(Name, ~"/a"),
    %% Same path and methods: the same count, now with a ceiling of 2 and
    %% a queue. The request already running counts against it.
    ok = roadrunner_listener:reload_routes(Name, [queued(~"/a", 2, #{max_queued => 1})]),
    ?assertEqual(Keeper, keeper(Name, ~"/a")),
    ?assertMatch([#{in_flight := 1, max_concurrent_requests := 2}], route_info(Name)),
    {ok, _} = result(holder(Name, ~"GET", ~"/a")),
    Waiter = holder(Name, ~"GET", ~"/a"),
    ok = wait_queued(Name, 1),
    ok = release(A),
    {ok, _} = result(Waiter),
    ok = roadrunner_listener:stop(Name).

dropped_route_drains_then_goes(_Config) ->
    %% A route the new table drops keeps counting the requests it still
    %% runs, under its old ceiling, until they end; then its keeper stops.
    Name = ?FUNCTION_NAME,
    {ok, Listener} = roadrunner_listener:start_link(Name, #{
        port => 0, routes => [capped(~"/a", 1), capped(~"/b", 1)]
    }),
    Old = persistent_term:get({roadrunner_routes, Name}),
    A = holder(Name, ~"GET", ~"/a"),
    {ok, _} = result(A),
    Keeper = keeper(Name, ~"/a"),
    Mon = monitor(process, Keeper),
    ok = roadrunner_listener:reload_routes(Name, [capped(~"/b", 1)]),
    ?assertMatch([#{path := ~"/b"}], route_info(Name)),
    %% A request still routed by the old table meets the old count.
    {refused, 1} = result(holder_on(Old, ~"GET", ~"/a")),
    ok = release(A),
    receive
        {'DOWN', Mon, process, Keeper, _} -> ok
    after 5000 -> ct:fail(keeper_kept)
    end,
    %% And the listener stays up, its other route served.
    ?assertEqual(accepting, roadrunner_listener:status(Name)),
    ?assert(is_process_alive(Listener)),
    {ok, _} = result(holder(Name, ~"GET", ~"/b")),
    ok = roadrunner_listener:stop(Name).

route_brought_back_keeps_its_count(_Config) ->
    %% Dropped and brought back before it drained: the same count.
    Name = ?FUNCTION_NAME,
    {ok, _} = roadrunner_listener:start_link(Name, #{port => 0, routes => [capped(~"/a", 1)]}),
    A = holder(Name, ~"GET", ~"/a"),
    {ok, _} = result(A),
    Keeper = keeper(Name, ~"/a"),
    ok = roadrunner_listener:reload_routes(Name, [{~"/plain", roadrunner_hello_handler}]),
    ok = roadrunner_listener:reload_routes(Name, [capped(~"/a", 1)]),
    ?assertEqual(Keeper, keeper(Name, ~"/a")),
    ?assertMatch([#{in_flight := 1}], route_info(Name)),
    ok = release(A),
    _ = sys:get_state(Keeper),
    _ = sys:get_state(Name),
    ?assert(is_process_alive(Keeper)),
    ?assertMatch([#{in_flight := 0}], route_info(Name)),
    ok = roadrunner_listener:stop(Name).

route_dropped_twice_keeps_draining(_Config) ->
    Name = ?FUNCTION_NAME,
    {ok, _} = roadrunner_listener:start_link(Name, #{port => 0, routes => [capped(~"/a", 1)]}),
    A = holder(Name, ~"GET", ~"/a"),
    {ok, _} = result(A),
    Keeper = keeper(Name, ~"/a"),
    Mon = monitor(process, Keeper),
    Plain = [{~"/plain", roadrunner_hello_handler}],
    ok = roadrunner_listener:reload_routes(Name, Plain),
    ok = roadrunner_listener:reload_routes(Name, Plain),
    ?assert(is_process_alive(Keeper)),
    ok = release(A),
    receive
        {'DOWN', Mon, process, Keeper, _} -> ok
    after 5000 -> ct:fail(keeper_kept)
    end,
    ok = roadrunner_listener:stop(Name).

drained_keeper_refuses_a_straggler(_Config) ->
    %% A request routed by the old table asks for a slot of a route the new
    %% table dropped, just as that route drains. Its keeper finds the route
    %% drained and stops in the same step, so the request is refused: it is
    %% never let in to run on a count the listener then deletes. A keeper
    %% that only reported the drain and went on serving until the listener
    %% stopped it would grant this request.
    Name = ?FUNCTION_NAME,
    {ok, _} = roadrunner_listener:start_link(Name, #{port => 0, routes => [capped(~"/a", 1)]}),
    Old = persistent_term:get({roadrunner_routes, Name}),
    {ok, _, _, _, _, {_Body, Ceiling}} = roadrunner_router:resolve(~"GET", ~"/a", Old),
    Keeper = keeper(Name, ~"/a"),
    Mon = monitor(process, Keeper),
    ok = sys:suspend(Keeper),
    ok = roadrunner_listener:reload_routes(Name, [{~"/plain", roadrunner_hello_handler}]),
    Straggler = holder_on(Old, ~"GET", ~"/a"),
    ok = wait_acquire(Keeper, Straggler),
    ok = sys:resume(Keeper),
    ?assertEqual({refused, 1}, result(Straggler)),
    receive
        {'DOWN', Mon, process, Keeper, Reason} -> ?assertEqual({shutdown, drained}, Reason)
    after 5000 -> ct:fail(keeper_kept)
    end,
    %% The listener deleted the count, and serves its other routes.
    ok = wait_deleted(element(2, Ceiling)),
    ?assertEqual([], route_info(Name)),
    ok = roadrunner_listener:stop(Name).

drained_keeper_of_a_route_brought_back_is_replaced(_Config) ->
    %% The route is dropped and brought back while its keeper lags behind:
    %% the keeper finds the route drained and stops, but the listener has
    %% the route back by then, so a new keeper takes over the same count.
    Name = ?FUNCTION_NAME,
    {ok, _} = roadrunner_listener:start_link(Name, #{port => 0, routes => [capped(~"/a", 1)]}),
    Keeper = keeper(Name, ~"/a"),
    Mon = monitor(process, Keeper),
    ok = sys:suspend(Keeper),
    ok = roadrunner_listener:reload_routes(Name, [{~"/plain", roadrunner_hello_handler}]),
    ok = roadrunner_listener:reload_routes(Name, [capped(~"/a", 1)]),
    ok = sys:resume(Keeper),
    receive
        {'DOWN', Mon, process, Keeper, Reason} -> ?assertEqual({shutdown, drained}, Reason)
    after 5000 -> ct:fail(keeper_kept)
    end,
    _ = wait_new_keeper(Name, ~"/a", Keeper),
    A = holder(Name, ~"GET", ~"/a"),
    {ok, _} = result(A),
    ?assertMatch([#{in_flight := 1}], route_info(Name)),
    {refused, 1} = result(holder(Name, ~"GET", ~"/a")),
    ok = release(A),
    ok = roadrunner_listener:stop(Name).

draining_keeper_serves_its_waiter_first(_Config) ->
    %% A dropped route's last slot is released while a request waits for
    %% it: the table is empty, the queue is not, so the keeper hands the
    %% slot on rather than stopping, and stops once that request ends too.
    Name = ?FUNCTION_NAME,
    {ok, _} = roadrunner_listener:start_link(Name, #{
        port => 0, routes => [queued(~"/a", 1, #{max_queued => 1})]
    }),
    A = holder(Name, ~"GET", ~"/a"),
    {ok, _} = result(A),
    Keeper = keeper(Name, ~"/a"),
    W = holder(Name, ~"GET", ~"/a"),
    ok = wait_queued(Name, 1),
    ok = roadrunner_listener:reload_routes(Name, [{~"/plain", roadrunner_hello_handler}]),
    ok = sys:suspend(Keeper),
    ok = release(A),
    ok = sys:resume(Keeper),
    {ok, _} = result(W),
    ?assert(is_process_alive(Keeper)),
    Mon = monitor(process, Keeper),
    ok = release(W),
    receive
        {'DOWN', Mon, process, Keeper, Reason} -> ?assertEqual({shutdown, drained}, Reason)
    after 5000 -> ct:fail(keeper_kept)
    end,
    ok = roadrunner_listener:stop(Name).

reload_adds_a_route_ceiling(_Config) ->
    Name = ?FUNCTION_NAME,
    {ok, _} = roadrunner_listener:start_link(Name, #{
        port => 0, routes => [{~"/plain", roadrunner_hello_handler}]
    }),
    ?assertEqual([], route_info(Name)),
    ok = roadrunner_listener:reload_routes(Name, [capped(~"/a", 3)]),
    ?assertMatch(
        [#{path := ~"/a", max_concurrent_requests := 3, in_flight := 0}], route_info(Name)
    ),
    {ok, _} = result(holder(Name, ~"GET", ~"/a")),
    ok = roadrunner_listener:stop(Name).

failed_reload_stops_the_new_keepers(_Config) ->
    Name = ?FUNCTION_NAME,
    {ok, Listener} = roadrunner_listener:start_link(Name, #{
        port => 0, routes => [capped(~"/a", 1)]
    }),
    Before = [P || {links, Links} <- [process_info(Listener, links)], P <- Links],
    Bad = #{
        path => ~"/bad",
        handler => roadrunner_init_route_handler,
        state => #{raise => bad_option}
    },
    ?assertMatch(
        {error, {init_failed, _}},
        roadrunner_listener:reload_routes(Name, [capped(~"/a", 2), capped(~"/b", 1), Bad])
    ),
    %% `/b`'s keeper goes again, and `/a` keeps its old ceiling.
    ok = wait_links(Listener, lists:sort(Before)),
    ?assertMatch([#{path := ~"/a", max_concurrent_requests := 1}], route_info(Name)),
    ok = roadrunner_listener:stop(Name).

keeper_crash_is_taken_over_by_a_new_keeper(_Config) ->
    %% The listener stays up and a new keeper serves the route with the
    %% count the old one left: the request still running holds its slot.
    Name = ?FUNCTION_NAME,
    {ok, Listener} = roadrunner_listener:start_link(Name, #{
        port => 0, routes => [capped(~"/a", 1)]
    }),
    A = holder(Name, ~"GET", ~"/a"),
    {ok, _} = result(A),
    Keeper = keeper(Name, ~"/a"),
    exit(Keeper, kill),
    NewKeeper = wait_new_keeper(Name, ~"/a", Keeper),
    ?assert(is_process_alive(Listener)),
    ?assertMatch([#{in_flight := 1}], route_info(Name)),
    {refused, 1} = result(holder(Name, ~"GET", ~"/a")),
    ok = release(A),
    _ = sys:get_state(NewKeeper),
    {ok, _} = result(holder(Name, ~"GET", ~"/a")),
    ok = roadrunner_listener:stop(Name).

stop_ends_the_keepers(_Config) ->
    Name = ?FUNCTION_NAME,
    {ok, _} = roadrunner_listener:start_link(Name, #{port => 0, routes => [capped(~"/a", 1)]}),
    Keeper = keeper(Name, ~"/a"),
    Mon = monitor(process, Keeper),
    ok = roadrunner_listener:stop(Name),
    receive
        {'DOWN', Mon, process, Keeper, _} -> ok
    after 5000 -> ct:fail(keeper_kept)
    end.

%% --- helpers ---

capped(Path, Max) ->
    #{path => Path, handler => roadrunner_hello_handler, max_concurrent_requests => Max}.

%% A process that takes a slot of the route `Method Path` resolves to in
%% listener `Name`'s table, as a connection does, reports what it got and
%% holds it until told to release it.
holder(Name, Method, Path) ->
    holder_on(persistent_term:get({roadrunner_routes, Name}), Method, Path).

holder_on(Compiled, Method, Path) ->
    {ok, _, _, _, _, {_Body, Ceiling}} = roadrunner_router:resolve(Method, Path, Compiled),
    Self = self(),
    spawn(fun() ->
        Result = roadrunner_route_keeper:acquire(Ceiling),
        Self ! {self(), Result},
        receive
            release ->
                {ok, Token} = Result,
                ok = roadrunner_route_keeper:release(Ceiling, Token),
                Self ! {self(), released}
        end
    end).

result(Pid) ->
    receive
        {Pid, Result} -> Result
    after 5000 -> ct:fail({no_result, Pid})
    end.

release(Pid) ->
    Pid ! release,
    released = result(Pid),
    ok.

%% The keeper serving `Path`'s ceiling, as named in its slot table.
keeper(Name, Path) ->
    {ok, _, _, _, _, {_Body, Ceiling}} =
        roadrunner_router:resolve(~"GET", Path, persistent_term:get({roadrunner_routes, Name})),
    ets:lookup_element(element(2, Ceiling), keeper, 2).

route_info(Name) ->
    maps:get(routes, roadrunner_listener:info(Name)).

wait_queued(Name, N) ->
    wait_queued(Name, N, 1000000).

wait_queued(_Name, N, 0) ->
    ct:fail({never_queued, N});
wait_queued(Name, N, Tries) ->
    case route_info(Name) of
        [#{queued := N} | _] ->
            ok;
        _ ->
            erlang:yield(),
            wait_queued(Name, N, Tries - 1)
    end.

wait_links(Pid, Links) ->
    wait_links(Pid, Links, 1000000).

wait_links(_Pid, Links, 0) ->
    ct:fail({links_never, Links});
wait_links(Pid, Links, Tries) ->
    case process_info(Pid, links) of
        {links, Now} when length(Now) =:= length(Links) ->
            ?assertEqual(Links, lists:sort(Now)),
            %% The listener handled the exit too.
            _ = sys:get_state(Pid),
            ok;
        {links, _} ->
            erlang:yield(),
            wait_links(Pid, Links, Tries - 1)
    end.

%% Until `Pid`'s acquire is in the (suspended) keeper's mailbox.
wait_acquire(Keeper, Pid) ->
    wait_acquire(Keeper, Pid, 1000000).

wait_acquire(_Keeper, Pid, 0) ->
    ct:fail({never_asked, Pid});
wait_acquire(Keeper, Pid, Tries) ->
    {messages, Messages} = erlang:process_info(Keeper, messages),
    case [P || {acquire, _Token, P, _Wait} <- Messages, P =:= Pid] of
        [_] ->
            ok;
        [] ->
            erlang:yield(),
            wait_acquire(Keeper, Pid, Tries - 1)
    end.

%% Until the listener has deleted a route's slot table.
wait_deleted(Slots) ->
    wait_deleted(Slots, 1000000).

wait_deleted(Slots, 0) ->
    ct:fail({table_kept, Slots});
wait_deleted(Slots, Tries) ->
    case ets:info(Slots, size) of
        undefined ->
            ok;
        _ ->
            erlang:yield(),
            wait_deleted(Slots, Tries - 1)
    end.

wait_new_keeper(Name, Path, Old) ->
    wait_new_keeper(Name, Path, Old, 1000000).

wait_new_keeper(_Name, _Path, _Old, 0) ->
    ct:fail(no_new_keeper);
wait_new_keeper(Name, Path, Old, Tries) ->
    _ = sys:get_state(Name),
    case keeper(Name, Path) of
        Old ->
            erlang:yield(),
            wait_new_keeper(Name, Path, Old, Tries - 1);
        New ->
            New
    end.

queued(Path, Max, Queue) ->
    #{
        path => Path,
        handler => roadrunner_hello_handler,
        max_concurrent_requests => Max,
        overload_mode => {queue, Queue}
    }.
