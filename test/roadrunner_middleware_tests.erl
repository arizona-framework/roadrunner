-module(roadrunner_middleware_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% compose/2 — pure unit tests against the composition machinery.
%% =============================================================================

compose_empty_returns_handler_test() ->
    Handler = fun(R) -> {{200, [], ~"ok"}, R} end,
    Pipeline = roadrunner_middleware:compose([], Handler),
    Req = req(),
    ?assertEqual({{200, [], ~"ok"}, Req}, Pipeline(Req)).

compose_single_fun_passes_through_test() ->
    Mw = fun(R, Next, _State) -> Next(R) end,
    Handler = fun(R) -> {{201, [], ~"handler"}, R} end,
    Pipeline = roadrunner_middleware:compose([Mw], Handler),
    Req = req(),
    ?assertEqual({{201, [], ~"handler"}, Req}, Pipeline(Req)).

compose_halt_skips_handler_test() ->
    HandlerCalled = make_ref(),
    Self = self(),
    Mw = fun(R, _Next, _State) -> {{401, [], ~"nope"}, R} end,
    Handler = fun(R) ->
        Self ! HandlerCalled,
        {{200, [], ~"reached"}, R}
    end,
    Pipeline = roadrunner_middleware:compose([Mw], Handler),
    Req = req(),
    ?assertEqual({{401, [], ~"nope"}, Req}, Pipeline(Req)),
    %% Handler must NOT have been invoked.
    receive
        HandlerCalled -> error(handler_was_called)
    after 50 -> ok
    end.

compose_request_mutation_visible_to_handler_test() ->
    %% Middleware adds a header; handler reads it.
    Mw = fun(R, Next, _State) ->
        H = maps:get(headers, R),
        Next(R#{headers := [{~"x-from-mw", ~"yes"} | H]})
    end,
    Handler = fun(R) ->
        {{200, [], roadrunner_req:header(~"x-from-mw", R)}, R}
    end,
    Pipeline = roadrunner_middleware:compose([Mw], Handler),
    {{Status, Headers, Body}, _Req2} = Pipeline(req()),
    ?assertEqual({200, [], ~"yes"}, {Status, Headers, Body}).

compose_response_wrapping_works_test() ->
    %% Middleware calls Next then transforms the response.
    Mw = fun(R, Next, _State) ->
        {{S, H, B}, R2} = Next(R),
        {{S, [{~"x-wrapped", ~"1"} | H], <<"[", B/binary, "]">>}, R2}
    end,
    Handler = fun(R) -> {{200, [], ~"hi"}, R} end,
    Pipeline = roadrunner_middleware:compose([Mw], Handler),
    {{Status, Headers, Body}, _Req2} = Pipeline(req()),
    ?assertEqual({200, [{~"x-wrapped", ~"1"}], ~"[hi]"}, {Status, Headers, Body}).

compose_two_middlewares_outer_wraps_inner_test() ->
    %% First middleware in the list runs OUTERMOST. It sees the response
    %% the second middleware (and ultimately the handler) produced.
    Outer = fun(R, Next, _State) ->
        {{S, H, B}, R2} = Next(R),
        {{S, H, <<"O(", B/binary, ")">>}, R2}
    end,
    Inner = fun(R, Next, _State) ->
        {{S, H, B}, R2} = Next(R),
        {{S, H, <<"I(", B/binary, ")">>}, R2}
    end,
    Handler = fun(R) -> {{200, [], ~"x"}, R} end,
    Pipeline = roadrunner_middleware:compose([Outer, Inner], Handler),
    {{Status, Headers, Body}, _Req2} = Pipeline(req()),
    ?assertEqual({200, [], ~"O(I(x))"}, {Status, Headers, Body}).

compose_module_form_dispatches_via_call3_test() ->
    %% `{Mod, Config}` dispatches to the behaviour `call/3`. The fixture has
    %% no `init/1`, so the config reaches `call/3` verbatim (the optional-init
    %% path); `compose_runs_module_init_and_threads_output_test` covers the
    %% with-init case.
    Handler = fun(R) ->
        {{200, [], roadrunner_req:header(~"x-mw-mod", R)}, R}
    end,
    Pipeline = roadrunner_middleware:compose(
        [{roadrunner_test_middlewares, ~"yes"}], Handler
    ),
    {{Status, Headers, Body}, _Req2} = Pipeline(req()),
    ?assertEqual({200, [], ~"yes"}, {Status, Headers, Body}).

compose_fun_form_threads_state_test() ->
    %% A `{fun/3, State}` entry receives its State as the third argument.
    Mw =
        {
            fun(R, Next, S) ->
                {{St, H, B}, R2} = Next(R),
                {{St, [{~"x-state", S} | H], B}, R2}
            end,
            ~"xyz"
        },
    Handler = fun(R) -> {{200, [], ~"ok"}, R} end,
    Pipeline = roadrunner_middleware:compose([Mw], Handler),
    {{200, Headers, _Body}, _Req2} = Pipeline(req()),
    ?assertEqual(~"xyz", proplists:get_value(~"x-state", Headers)).

compose_same_module_twice_with_different_state_test() ->
    %% The headline benefit: the same module listed twice, each carrying
    %% its own State. Outermost ({Mod, ~"a"}) prepends first, then the
    %% inner ({Mod, ~"b"}) prepends, so the handler sees [b, a].
    Mod = roadrunner_test_middlewares,
    Handler = fun(R) ->
        Vals = [V || {~"x-mw-mod", V} <- maps:get(headers, R)],
        {{200, [], iolist_to_binary(lists:join(~",", Vals))}, R}
    end,
    Pipeline = roadrunner_middleware:compose([{Mod, ~"a"}, {Mod, ~"b"}], Handler),
    {{200, [], Body}, _Req2} = Pipeline(req()),
    ?assertEqual(~"b,a", Body).

compose_bare_module_defaults_config_to_empty_map_test() ->
    %% A bare `module()` entry is shorthand for `{module(), #{}}`: `init/1`
    %% receives `#{}`, and (identity here) `call/3` gets that `#{}` as its
    %% state, stamped into `x-mw-mod`.
    Handler = fun(R) -> {{200, maps:get(headers, R), ~"ok"}, R} end,
    Pipeline = roadrunner_middleware:compose([roadrunner_test_middlewares], Handler),
    {{200, Headers, ~"ok"}, _Req2} = Pipeline(req()),
    ?assertEqual(#{}, proplists:get_value(~"x-mw-mod", Headers)).

compose_bare_fun_defaults_state_to_empty_map_test() ->
    %% A bare `fun/3` entry is shorthand for `{fun/3, #{}}` — a fun has no
    %% init, so the default config is its state verbatim.
    Self = self(),
    Ref = make_ref(),
    Mw = fun(R, Next, State) ->
        Self ! {Ref, State},
        Next(R)
    end,
    Handler = fun(R) -> {{200, [], ~"ok"}, R} end,
    Pipeline = roadrunner_middleware:compose([Mw], Handler),
    Req = req(),
    ?assertEqual({{200, [], ~"ok"}, Req}, Pipeline(Req)),
    receive
        {Ref, State} -> ?assertEqual(#{}, State)
    after 50 -> error(no_state_received)
    end.

compose_runs_module_init_and_threads_output_test() ->
    %% A module entry's `init/1` runs at compose time and its OUTPUT (not
    %% the raw config) is what `call/3` receives. The fixture compiles
    %% `#{tag => ...}` into `{compiled, Tag}` and stamps the tag, so reading
    %% it back proves the transform ran and threaded through.
    Handler = fun(R) ->
        {{200, [], roadrunner_req:header(~"x-init-tag", R)}, R}
    end,
    Pipeline = roadrunner_middleware:compose(
        [{roadrunner_test_init_middleware, #{tag => ~"compiled-ok"}}], Handler
    ),
    {{200, [], Body}, _Req2} = Pipeline(req()),
    ?assertEqual(~"compiled-ok", Body).

resolve_unloadable_module_crashes_test() ->
    %% A middleware module that can't be loaded is a config error: it fails
    %% when the pipeline is resolved (listener start), not on a request.
    ?assertError(
        {middleware_module_not_loaded, roadrunner_no_such_middleware, _},
        roadrunner_middleware:resolve([roadrunner_no_such_middleware])
    ).

%% =============================================================================
%% End-to-end through roadrunner_conn — exercises the map-shape route's
%% top-level `middlewares` key.
%% =============================================================================

route_middlewares_run_before_handler_test_() ->
    {setup,
        fun() ->
            {ok, _} = roadrunner_listener:start_link(mw_test_route, #{
                port => 0,
                routes => [
                    #{
                        path => ~"/echo",
                        handler => roadrunner_echo_headers_handler,
                        middlewares => [
                            fun roadrunner_test_middlewares:tag_request/3,
                            {roadrunner_test_middlewares, ~"yes"}
                        ]
                    }
                ]
            }),
            roadrunner_listener:port(mw_test_route)
        end,
        fun(_) -> ok = roadrunner_listener:stop(mw_test_route) end, fun(Port) ->
            {"bare fun-form and stateful module-form middlewares mutate the request", fun() ->
                Reply = http_get(Port, ~"/echo"),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
                {match, _} = re:run(Reply, ~"fun=yes mod=yes")
            end}
        end}.

route_middleware_can_halt_test_() ->
    {setup,
        fun() ->
            {ok, _} = roadrunner_listener:start_link(mw_test_halt, #{
                port => 0,
                routes => [
                    #{
                        path => ~"/secret",
                        handler => roadrunner_echo_headers_handler,
                        middlewares => [fun roadrunner_test_middlewares:halt_401/3]
                    }
                ]
            }),
            roadrunner_listener:port(mw_test_halt)
        end,
        fun(_) -> ok = roadrunner_listener:stop(mw_test_halt) end, fun(Port) ->
            {"halting middleware short-circuits with its own response", fun() ->
                Reply = http_get(Port, ~"/secret"),
                ?assertMatch(<<"HTTP/1.1 401 ", _/binary>>, Reply)
            end}
        end}.

route_middleware_can_wrap_response_test_() ->
    {setup,
        fun() ->
            {ok, _} = roadrunner_listener:start_link(mw_test_wrap, #{
                port => 0,
                routes => [
                    #{
                        path => ~"/wrapped",
                        handler => roadrunner_echo_headers_handler,
                        middlewares => [fun roadrunner_test_middlewares:wrap_response/3]
                    }
                ]
            }),
            roadrunner_listener:port(mw_test_wrap)
        end,
        fun(_) -> ok = roadrunner_listener:stop(mw_test_wrap) end, fun(Port) ->
            {"middleware sees and transforms the handler's response", fun() ->
                Reply = http_get(Port, ~"/wrapped"),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
                {match, _} = re:run(Reply, ~"x-wrapped: yes", [caseless]),
                {match, _} = re:run(Reply, ~"\\[wrapped\\]")
            end}
        end}.

route_middleware_crash_returns_500_test_() ->
    {setup,
        fun() ->
            ok = logger:set_primary_config(level, none),
            {ok, _} = roadrunner_listener:start_link(mw_test_crash, #{
                port => 0,
                routes => [
                    #{
                        path => ~"/boom",
                        handler => roadrunner_echo_headers_handler,
                        middlewares => [fun roadrunner_test_middlewares:crash/3]
                    }
                ]
            }),
            roadrunner_listener:port(mw_test_crash)
        end,
        fun(_) ->
            ok = roadrunner_listener:stop(mw_test_crash),
            ok = logger:set_primary_config(level, notice)
        end,
        fun(Port) ->
            {"crashing middleware returns 500, same path as a crashing handler", fun() ->
                Reply = http_get(Port, ~"/boom"),
                ?assertMatch(<<"HTTP/1.1 500 ", _/binary>>, Reply)
            end}
        end}.

%% =============================================================================
%% Listener-level middleware — runs for every request, even single-handler
%% dispatch with no router involved.
%% =============================================================================

listener_middleware_runs_without_router_test_() ->
    {setup,
        fun() ->
            {ok, _} = roadrunner_listener:start_link(mw_test_listener, #{
                port => 0,
                routes => roadrunner_echo_headers_handler,
                middlewares => [fun roadrunner_test_middlewares:tag_request/3]
            }),
            roadrunner_listener:port(mw_test_listener)
        end,
        fun(_) -> ok = roadrunner_listener:stop(mw_test_listener) end, fun(Port) ->
            {"listener-level middleware applies to single-handler dispatch", fun() ->
                Reply = http_get(Port, ~"/anything"),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
                {match, _} = re:run(Reply, ~"fun=yes")
            end}
        end}.

listener_middleware_runs_outside_route_middleware_test_() ->
    {setup,
        fun() ->
            {ok, _} = roadrunner_listener:start_link(mw_test_combo, #{
                port => 0,
                middlewares => [fun roadrunner_test_middlewares:wrap_response/3],
                routes => [
                    #{
                        path => ~"/x",
                        handler => roadrunner_echo_headers_handler,
                        middlewares => [fun roadrunner_test_middlewares:tag_request/3]
                    }
                ]
            }),
            roadrunner_listener:port(mw_test_combo)
        end,
        fun(_) -> ok = roadrunner_listener:stop(mw_test_combo) end, fun(Port) ->
            {"listener middleware wraps the route middleware + handler", fun() ->
                Reply = http_get(Port, ~"/x"),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
                %% Listener wrap_response saw the inner result and added
                %% [wrapped] + x-wrapped header.
                {match, _} = re:run(Reply, ~"x-wrapped: yes", [caseless]),
                {match, _} = re:run(Reply, ~"\\[wrapped\\] fun=yes")
            end}
        end}.

%% =============================================================================
%% init/1 runs once at pipeline-compile time, never per request.
%% =============================================================================

init_runs_once_at_compile_not_per_request_test_() ->
    {setup,
        fun() ->
            Ref = counters:new(1, []),
            {ok, _} = roadrunner_listener:start_link(mw_test_init_once, #{
                port => 0,
                routes => #{
                    handler => roadrunner_echo_headers_handler,
                    middlewares => [
                        {roadrunner_test_init_middleware, #{counter => Ref, tag => ~"x"}}
                    ]
                }
            }),
            {roadrunner_listener:port(mw_test_init_once), Ref}
        end,
        fun(_) -> ok = roadrunner_listener:stop(mw_test_init_once) end, fun({Port, Ref}) ->
            {"init runs once while the pipeline is baked, not on each request", fun() ->
                %% The pipeline was compiled at listener start, so init has
                %% already run exactly once — before any request.
                ?assertEqual(1, counters:get(Ref, 1)),
                _ = http_get(Port, ~"/a"),
                _ = http_get(Port, ~"/b"),
                _ = http_get(Port, ~"/c"),
                %% call/3 ran three times; init ran zero more times.
                ?assertEqual(1, counters:get(Ref, 1))
            end}
        end}.

listener_middleware_init_runs_once_across_routes_test_() ->
    {setup,
        fun() ->
            Ref = counters:new(1, []),
            {ok, _} = roadrunner_listener:start_link(mw_test_listener_init_once, #{
                port => 0,
                middlewares => [{roadrunner_test_init_middleware, #{counter => Ref, tag => ~"x"}}],
                routes => [
                    #{path => ~"/a", handler => roadrunner_echo_headers_handler},
                    #{path => ~"/b", handler => roadrunner_echo_headers_handler},
                    #{path => ~"/c", handler => roadrunner_echo_headers_handler}
                ]
            }),
            Ref
        end,
        fun(_) -> ok = roadrunner_listener:stop(mw_test_listener_init_once) end, fun(Ref) ->
            {"a listener middleware is resolved once, not once per route", fun() ->
                %% Three routes share the one listener middleware, so its init
                %% ran a single time when the routes were compiled.
                ?assertEqual(1, counters:get(Ref, 1))
            end}
        end}.

%% --- helpers ---

req() ->
    #{method => ~"GET", target => ~"/", version => {1, 1}, headers => []}.

http_get(Port, Path) ->
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
    ),
    Req = <<"GET ", Path/binary, " HTTP/1.1\r\nHost: x\r\n\r\n">>,
    ok = gen_tcp:send(Sock, Req),
    Reply = recv_until_closed(Sock, <<>>),
    ok = gen_tcp:close(Sock),
    Reply.

recv_until_closed(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 1000) of
        {ok, Data} -> recv_until_closed(Sock, <<Acc/binary, Data/binary>>);
        {error, _} -> Acc
    end.
