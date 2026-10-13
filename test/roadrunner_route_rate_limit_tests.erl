-module(roadrunner_route_rate_limit_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_route_rate_limit).
-define(IP, {127, 0, 0, 1}).

%% --- init/1 ---

init_compiles_bucket_terms_test() ->
    %% One request costs `Period * 1000` units, the bucket holds `Burst` of
    %% them (default `rate`), and the key carries the route and its settings.
    ?assertEqual(
        {5, 300000, 60000, {~"/login", undefined, 5, 60, 5}},
        ?M:init(#{rate_limit => #{rate => 5, period => 60}, path => ~"/login", methods => undefined})
    ),
    ?assertEqual(
        {2, 4000, 1000, {~"/up", [~"POST"], 2, 1, 4}},
        ?M:init(#{rate_limit => #{rate => 2, burst => 4}, path => ~"/up", methods => [~"POST"]})
    ).

%% --- evict_full/2 ---

evicts_each_route_bucket_once_full_test() ->
    %% Two routes with their own rates share the store: each bucket is dropped
    %% when full again at its own route's rate, read from its key.
    Table = ets:new(route_rl_test, [public]),
    {SlowRate, SlowCap, SlowCost, SlowKey} = ?M:init(stage(~"/slow", 1, 60)),
    {FastRate, FastCap, FastCost, FastKey} = ?M:init(stage(~"/fast", 1, 1)),
    allow = roadrunner_conn:rate_limit_check(
        Table, {SlowKey, ?IP}, SlowRate, SlowCap, SlowCost, 0
    ),
    allow = roadrunner_conn:rate_limit_check(
        Table, {FastKey, ?IP}, FastRate, FastCap, FastCost, 0
    ),
    %% `/fast` refills its one request in 1000ms, `/slow` in 60000ms.
    ?assertEqual(0, ?M:evict_full(Table, 999)),
    ?assertEqual(1, ?M:evict_full(Table, 1000)),
    ?assertMatch([{{SlowKey, ?IP}, _, _}], ets:tab2list(Table)),
    ?assertEqual(0, ?M:evict_full(Table, 59999)),
    ?assertEqual(1, ?M:evict_full(Table, 60000)).

%% --- call/3 ---

call_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Table = ets:new(route_rl_test, [public]),
    Counter = atomics:new(1, [{signed, false}]),
    persistent_term:put({roadrunner_route_rate_limit, route_rl_call}, {Table, Counter}),
    State = ?M:init(stage(~"/login", 1, 60)),
    Next = fun(Req) -> {{200, [], ~"ok"}, Req} end,
    Req = #{listener_name => route_rl_call, peer => {?IP, 5000}},
    try
        ?assertMatch({{200, _, ~"ok"}, _}, ?M:call(Req, Next, State)),
        ?assertMatch(
            {{429, [{~"content-length", ~"0"}, {~"retry-after", ~"60"}], ~""}, _},
            ?M:call(Req, Next, State)
        ),
        ?assertEqual(1, atomics:get(Counter, 1)),
        %% The bucket is the client's: one `real_ip` resolved has its own.
        ?assertMatch(
            {{200, _, _}, _}, ?M:call(Req#{client_ip => {10, 0, 0, 9}}, Next, State)
        ),
        %% No client address, no limit (as for the listener's).
        ?assertMatch({{200, _, _}, _}, ?M:call(maps:remove(peer, Req), Next, State))
    after
        persistent_term:erase({roadrunner_route_rate_limit, route_rl_call})
    end.

%% --- helpers ---

stage(Path, Rate, Period) ->
    #{rate_limit => #{rate => Rate, period => Period}, path => Path, methods => undefined}.
