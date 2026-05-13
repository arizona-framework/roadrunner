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
    Mw = fun(R, Next) -> Next(R) end,
    Handler = fun(R) -> {{201, [], ~"handler"}, R} end,
    Pipeline = roadrunner_middleware:compose([Mw], Handler),
    Req = req(),
    ?assertEqual({{201, [], ~"handler"}, Req}, Pipeline(Req)).

compose_halt_skips_handler_test() ->
    HandlerCalled = make_ref(),
    Self = self(),
    Mw = fun(R, _Next) -> {{401, [], ~"nope"}, R} end,
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
    Mw = fun(R, Next) ->
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
    Mw = fun(R, Next) ->
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
    Outer = fun(R, Next) ->
        {{S, H, B}, R2} = Next(R),
        {{S, H, <<"O(", B/binary, ")">>}, R2}
    end,
    Inner = fun(R, Next) ->
        {{S, H, B}, R2} = Next(R),
        {{S, H, <<"I(", B/binary, ")">>}, R2}
    end,
    Handler = fun(R) -> {{200, [], ~"x"}, R} end,
    Pipeline = roadrunner_middleware:compose([Outer, Inner], Handler),
    {{Status, Headers, Body}, _Req2} = Pipeline(req()),
    ?assertEqual({200, [], ~"O(I(x))"}, {Status, Headers, Body}).

compose_module_form_dispatches_via_call2_test() ->
    Handler = fun(R) ->
        {{200, [], roadrunner_req:header(~"x-mw-mod", R)}, R}
    end,
    Pipeline = roadrunner_middleware:compose([roadrunner_test_middlewares], Handler),
    {{Status, Headers, Body}, _Req2} = Pipeline(req()),
    ?assertEqual({200, [], ~"yes"}, {Status, Headers, Body}).

%% =============================================================================
%% End-to-end through roadrunner_conn — exercises route_opts.middlewares plumbing.
%% =============================================================================

route_middlewares_run_before_handler_test_() ->
    {setup,
        fun() ->
            {ok, _} = roadrunner_listener:start_link(mw_test_route, #{
                port => 0,
                routes => [
                    {~"/echo", roadrunner_echo_headers_handler, #{
                        middlewares => [
                            fun roadrunner_test_middlewares:tag_request/2,
                            roadrunner_test_middlewares
                        ]
                    }}
                ]
            }),
            roadrunner_listener:port(mw_test_route)
        end,
        fun(_) -> ok = roadrunner_listener:stop(mw_test_route) end, fun(Port) ->
            {"both fun-form and module-form middlewares mutate the request", fun() ->
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
                    {~"/secret", roadrunner_echo_headers_handler, #{
                        middlewares => [fun roadrunner_test_middlewares:halt_401/2]
                    }}
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
                    {~"/wrapped", roadrunner_echo_headers_handler, #{
                        middlewares => [fun roadrunner_test_middlewares:wrap_response/2]
                    }}
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
                    {~"/boom", roadrunner_echo_headers_handler, #{
                        middlewares => [fun roadrunner_test_middlewares:crash/2]
                    }}
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
                middlewares => [fun roadrunner_test_middlewares:tag_request/2]
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
                middlewares => [fun roadrunner_test_middlewares:wrap_response/2],
                routes => [
                    {~"/x", roadrunner_echo_headers_handler, #{
                        middlewares => [fun roadrunner_test_middlewares:tag_request/2]
                    }}
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
