-module(roadrunner_middleware_SUITE).
-moduledoc """
A `middlewares` entry that is not a middleware stops a real listener from
starting with `{invalid_middleware, Entry, Reason}`, whether it sits on a
route, on the listener, on a single-handler `routes` form or on the routes
`roadrunner_grpc:routes/1` builds, and a reload carrying one is refused.
Before, a loaded module without `call/3` started fine and every request
then crashed with `undef`.
""".

-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1, end_per_testcase/2]).
-export([
    route_middleware_stops_the_start/1,
    listener_middleware_stops_the_start/1,
    single_handler_middleware_stops_the_start/1,
    grpc_middlewares_stop_the_start/1,
    supervised_start_reports_it/1,
    reload_refuses_it/1
]).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        route_middleware_stops_the_start,
        listener_middleware_stops_the_start,
        single_handler_middleware_stops_the_start,
        grpc_middlewares_stop_the_start,
        supervised_start_reports_it,
        reload_refuses_it
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(roadrunner),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(roadrunner).

end_per_testcase(_Case, _Config) ->
    case whereis(?MODULE) of
        undefined -> ok;
        _Pid -> ok = roadrunner_listener:stop(?MODULE)
    end.

route_middleware_stops_the_start(_Config) ->
    %% A handler module passed as a middleware loads but has no `call/3`.
    ?assertMatch(
        {error, {{invalid_middleware, roadrunner_hello_handler, no_call_3}, _}},
        start(#{
            routes => [
                {~"/a", roadrunner_hello_handler},
                #{
                    path => ~"/b",
                    handler => roadrunner_hello_handler,
                    middlewares => [roadrunner_hello_handler]
                }
            ]
        })
    ).

listener_middleware_stops_the_start(_Config) ->
    Fun = fun(Req, Next) -> Next(Req) end,
    ?assertMatch(
        {error, {{invalid_middleware, {Fun, #{}}, bad_arity}, _}},
        start(#{
            routes => [{~"/a", roadrunner_hello_handler}],
            middlewares => [{Fun, #{}}]
        })
    ).

single_handler_middleware_stops_the_start(_Config) ->
    ?assertMatch(
        {error, {{invalid_middleware, roadrunner_no_such_middleware, {not_loaded, nofile}}, _}},
        start(#{
            routes => #{
                handler => roadrunner_hello_handler,
                middlewares => [roadrunner_no_such_middleware]
            }
        })
    ),
    ?assertMatch(
        {error, {{invalid_middleware, 42, not_a_middleware}, _}},
        start(#{routes => roadrunner_hello_handler, middlewares => [42]})
    ).

grpc_middlewares_stop_the_start(_Config) ->
    Routes = roadrunner_grpc:routes(#{
        services => [roadrunner_grpc_test_service],
        health => true,
        middlewares => [{roadrunner_grpc_test_codec, #{}}]
    }),
    ?assertMatch(
        {error, {{invalid_middleware, {roadrunner_grpc_test_codec, #{}}, no_call_3}, _}},
        start(#{protocols => [http2], body_buffering => manual, routes => Routes})
    ).

supervised_start_reports_it(_Config) ->
    %% The supervisor wraps the listener's `{Reason, Stack}` with the child spec.
    ?assertMatch(
        {error, {{{invalid_middleware, roadrunner_hello_handler, no_call_3}, _Stack}, _Child}},
        roadrunner:start_listener(?MODULE, #{
            port => 0,
            routes => [{~"/a", roadrunner_hello_handler}],
            middlewares => [roadrunner_hello_handler]
        })
    ),
    ?assertEqual(undefined, whereis(?MODULE)).

reload_refuses_it(_Config) ->
    {ok, _} = start(#{routes => [{~"/a", roadrunner_hello_handler}]}),
    ?assertMatch(
        {error, {init_failed, {invalid_middleware, roadrunner_hello_handler, no_call_3}}},
        roadrunner_listener:reload_routes(?MODULE, [
            #{
                path => ~"/a",
                handler => roadrunner_hello_handler,
                middlewares => [roadrunner_hello_handler]
            }
        ])
    ).

%% Start the listener linked to the test process, trapping the exit a failed
%% start sends so the case sees the `{error, _}` it returns.
start(Opts) ->
    process_flag(trap_exit, true),
    roadrunner_listener:start_link(?MODULE, Opts#{port => 0}).
