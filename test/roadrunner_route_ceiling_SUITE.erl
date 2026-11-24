-module(roadrunner_route_ceiling_SUITE).
-moduledoc """
A route's own `max_concurrent_requests` and `overload_mode` in a listener.
""".

-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_testcase/2, end_per_testcase/2]).
-export([
    route_queues_reaching_the_listener_ceiling_stop_the_start/1,
    route_queues_reaching_the_listener_ceiling_are_refused_on_reload/1,
    route_queues_under_the_listener_ceiling_start/1
]).

suite() ->
    [{timetrap, {seconds, 60}}].

all() ->
    [
        route_queues_reaching_the_listener_ceiling_stop_the_start,
        route_queues_reaching_the_listener_ceiling_are_refused_on_reload,
        route_queues_under_the_listener_ceiling_start
    ].

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

%% --- helpers ---

queued(Path, Max, Queue) ->
    #{
        path => Path,
        handler => roadrunner_hello_handler,
        max_concurrent_requests => Max,
        overload_mode => {queue, Queue}
    }.
