-module(roadrunner_rate_limit_store_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_conn).
-define(IP, {127, 0, 0, 1}).

%% --- rate_limit_check/6 (real ETS bucket store, injected clock; Period 1 =
%% per-second unless noted) ---

first_request_allowed_test() ->
    Table = new_table(),
    ?assertEqual(allow, ?M:rate_limit_check(Table, ?IP, 2, 2, 1, 1000)).

burst_then_denied_test() ->
    Table = new_table(),
    %% Burst of 2: two requests pass, the third is denied (Retry-After 1s).
    ?assertEqual(allow, ?M:rate_limit_check(Table, ?IP, 2, 2, 1, 1000)),
    ?assertEqual(allow, ?M:rate_limit_check(Table, ?IP, 2, 2, 1, 1000)),
    ?assertEqual({deny, 1}, ?M:rate_limit_check(Table, ?IP, 2, 2, 1, 1000)).

refills_after_time_test() ->
    Table = new_table(),
    %% Drain the burst of 1, then a request 500ms later (2/sec → one back) passes.
    ?assertEqual(allow, ?M:rate_limit_check(Table, ?IP, 2, 1, 1, 1000)),
    ?assertEqual({deny, 1}, ?M:rate_limit_check(Table, ?IP, 2, 1, 1, 1000)),
    ?assertEqual(allow, ?M:rate_limit_check(Table, ?IP, 2, 1, 1, 1500)).

different_ips_are_independent_test() ->
    Table = new_table(),
    IP2 = {10, 0, 0, 9},
    ?assertEqual(allow, ?M:rate_limit_check(Table, ?IP, 1, 1, 1, 1000)),
    ?assertEqual({deny, 1}, ?M:rate_limit_check(Table, ?IP, 1, 1, 1, 1000)),
    %% A different peer has its own full bucket.
    ?assertEqual(allow, ?M:rate_limit_check(Table, IP2, 1, 1, 1, 1000)).

per_minute_rate_test() ->
    Table = new_table(),
    %% 1 request per 60s: the second is denied with a 60s Retry-After.
    ?assertEqual(allow, ?M:rate_limit_check(Table, ?IP, 1, 1, 60, 1000)),
    ?assertEqual({deny, 60}, ?M:rate_limit_check(Table, ?IP, 1, 1, 60, 1000)).

%% --- resolve_rate_limit/2 ---

resolve_off_without_config_test() ->
    ?assertEqual(undefined, ?M:resolve_rate_limit(proto_opts(undefined), {?IP, 5000})).

resolve_off_without_peer_test() ->
    Table = new_table(),
    ?assertEqual(undefined, ?M:resolve_rate_limit(proto_opts(Table), undefined)).

resolve_on_test() ->
    Table = new_table(),
    {Counter, Opts} = proto_opts_with_counter(Table),
    ?assertEqual({10, 20, 30, Table, Counter, ?IP}, ?M:resolve_rate_limit(Opts, {?IP, 5000})).

%% --- rate_limited_telemetry/2 ---

telemetry_bumps_counter_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Counter = atomics:new(1, [{signed, false}]),
    ok = ?M:rate_limited_telemetry(some_listener, Counter),
    ?assertEqual(1, atomics:get(Counter, 1)).

%% --- rate_limit_evict_idle/4 ---

evicts_only_idle_rows_test() ->
    Table = new_table(),
    true = ets:insert(Table, {{1, 1, 1, 1}, 5000, 0}),
    true = ets:insert(Table, {{2, 2, 2, 2}, 5000, 1000}),
    %% Now=2000, ttl=1500 → cutoff 500. Only the row last touched at 0 is idle.
    ?assertEqual(1, ?M:rate_limit_evict_idle(Table, 2000, 1500)),
    ?assertEqual([], ets:lookup(Table, {1, 1, 1, 1})),
    ?assertMatch([{{2, 2, 2, 2}, _, _}], ets:lookup(Table, {2, 2, 2, 2})).

evict_empty_table_test() ->
    Table = new_table(),
    ?assertEqual(0, ?M:rate_limit_evict_idle(Table, 2000, 1500)).

evict_clears_all_idle_in_one_pass_test() ->
    Table = new_table(),
    true = ets:insert(Table, {{1, 1, 1, 1}, 0, 0}),
    true = ets:insert(Table, {{2, 2, 2, 2}, 0, 0}),
    true = ets:insert(Table, {{3, 3, 3, 3}, 0, 0}),
    %% All three idle rows are evicted in a single pass (no per-tick budget).
    ?assertEqual(3, ?M:rate_limit_evict_idle(Table, 1000000, 1)),
    ?assertEqual(0, ets:info(Table, size)).

%% --- helpers ---

new_table() ->
    ets:new(rate_limit_test, [public, {write_concurrency, true}]).

proto_opts(RateLimit) ->
    Cfg =
        case RateLimit of
            undefined ->
                undefined;
            Table ->
                #{
                    rate => 10,
                    burst => 20,
                    period => 30,
                    idle_ttl => 60000,
                    sweep_interval => 10000,
                    table => Table
                }
        end,
    #{
        rate_limit => Cfg,
        rate_limited_counter => atomics:new(1, [{signed, false}])
    }.

proto_opts_with_counter(Table) ->
    Counter = atomics:new(1, [{signed, false}]),
    {Counter, #{
        rate_limit => #{
            rate => 10,
            burst => 20,
            period => 30,
            idle_ttl => 60000,
            sweep_interval => 10000,
            table => Table
        },
        rate_limited_counter => Counter
    }}.
