-module(roadrunner_rate_limit_store_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_conn).
-define(IP, {127, 0, 0, 1}).

%% --- rate_limit_check/6 (real ETS bucket store, injected clock; Period 1 =
%% per-second unless noted) ---

%% `rate_limit_check` takes the resolved `Cap`/`Cost` (not burst/period); the
%% `cap/2` and `cost/1` helpers keep the burst/period intent visible.

first_request_allowed_test() ->
    Table = new_table(),
    ?assertEqual(allow, ?M:rate_limit_check(Table, ?IP, 2, cap(2, 1), cost(1), 1000)).

burst_then_denied_test() ->
    Table = new_table(),
    %% Burst of 2: two requests pass, the third is denied (Retry-After 1s).
    ?assertEqual(allow, ?M:rate_limit_check(Table, ?IP, 2, cap(2, 1), cost(1), 1000)),
    ?assertEqual(allow, ?M:rate_limit_check(Table, ?IP, 2, cap(2, 1), cost(1), 1000)),
    ?assertEqual({deny, 1}, ?M:rate_limit_check(Table, ?IP, 2, cap(2, 1), cost(1), 1000)).

refills_after_time_test() ->
    Table = new_table(),
    %% Drain the burst of 1, then a request 500ms later (2/sec → one back) passes.
    ?assertEqual(allow, ?M:rate_limit_check(Table, ?IP, 2, cap(1, 1), cost(1), 1000)),
    ?assertEqual({deny, 1}, ?M:rate_limit_check(Table, ?IP, 2, cap(1, 1), cost(1), 1000)),
    ?assertEqual(allow, ?M:rate_limit_check(Table, ?IP, 2, cap(1, 1), cost(1), 1500)).

different_ips_are_independent_test() ->
    Table = new_table(),
    IP2 = {10, 0, 0, 9},
    ?assertEqual(allow, ?M:rate_limit_check(Table, ?IP, 1, cap(1, 1), cost(1), 1000)),
    ?assertEqual({deny, 1}, ?M:rate_limit_check(Table, ?IP, 1, cap(1, 1), cost(1), 1000)),
    %% A different peer has its own full bucket.
    ?assertEqual(allow, ?M:rate_limit_check(Table, IP2, 1, cap(1, 1), cost(1), 1000)).

per_minute_rate_test() ->
    Table = new_table(),
    %% 1 request per 60s: the second is denied with a 60s Retry-After.
    ?assertEqual(allow, ?M:rate_limit_check(Table, ?IP, 1, cap(1, 60), cost(60), 1000)),
    ?assertEqual({deny, 60}, ?M:rate_limit_check(Table, ?IP, 1, cap(1, 60), cost(60), 1000)).

deny_leaves_the_bucket_test() ->
    %% A denied request spends nothing, so its bucket is left as it was.
    Table = new_table(),
    ?assertEqual(allow, ?M:rate_limit_check(Table, ?IP, 1, cap(1, 1), cost(1), 1000)),
    Row = ets:lookup(Table, ?IP),
    ?assertEqual({deny, 1}, ?M:rate_limit_check(Table, ?IP, 1, cap(1, 1), cost(1), 1500)),
    ?assertEqual(Row, ets:lookup(Table, ?IP)).

late_deny_refills_nothing_test() ->
    %% A deny that read the clock before another connection's request was
    %% stored (`NowMs` older than the bucket's time) must not set the
    %% bucket's time back, which would refill it for time that never passed.
    Table = new_table(),
    ?assertEqual(allow, ?M:rate_limit_check(Table, ?IP, 1, cap(1, 1), cost(1), 2000)),
    ?assertEqual({deny, 1}, ?M:rate_limit_check(Table, ?IP, 1, cap(1, 1), cost(1), 1500)),
    ?assertMatch({deny, _}, ?M:rate_limit_check(Table, ?IP, 1, cap(1, 1), cost(1), 2500)).

%% --- resolve_rate_limit/2 ---

resolve_off_without_config_test() ->
    ?assertEqual(undefined, ?M:resolve_rate_limit(proto_opts(undefined), {?IP, 5000})).

resolve_keys_the_peer_once_test() ->
    %% The peer's bucket key is baked in with the rest, once per connection:
    %% an IPv6 peer's /64, an IPv4-mapped peer's IPv4 address.
    Table = new_table(),
    Opts = proto_opts(Table),
    ?assertMatch(
        {_, _, _, _, _, {16#2001, 16#DB8, 0, 0, 0, 0, 0, 0}},
        ?M:resolve_rate_limit(Opts, {{16#2001, 16#DB8, 0, 0, 0, 0, 0, 9}, 5000})
    ),
    ?assertMatch(
        {_, _, _, _, _, ?IP},
        ?M:resolve_rate_limit(Opts, {{0, 0, 0, 0, 0, 16#FFFF, 16#7F00, 1}, 5000})
    ).

%% --- rate_limit/3 ---

rate_limit_off_allows_test() ->
    ?assertEqual(allow, ?M:rate_limit(undefined, #{}, some_listener)).

rate_limit_deny_counts_the_throttle_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Table = new_table(),
    Counter = atomics:new(1, [{signed, false}]),
    State = {1, cap(1, 1), cost(1), Table, Counter, ?IP},
    ?assertEqual(allow, ?M:rate_limit(State, #{}, some_listener)),
    ?assertEqual(0, atomics:get(Counter, 1)),
    ?assertEqual({deny, 1}, ?M:rate_limit(State, #{}, some_listener)),
    ?assertEqual(1, atomics:get(Counter, 1)).

rate_limit_keys_on_client_ip_test() ->
    %% A client `real_ip` resolved is keyed like a peer (an IPv6 one by its
    %% /64); otherwise the peer's baked key stands.
    Table = new_table(),
    Counter = atomics:new(1, [{signed, false}]),
    State = {1, cap(1, 1), cost(1), Table, Counter, ?IP},
    Client = #{client_ip => {16#2001, 16#DB8, 0, 0, 0, 0, 0, 7}},
    ?assertEqual(allow, ?M:rate_limit(State, Client, some_listener)),
    ?assertEqual(allow, ?M:rate_limit(State, #{}, some_listener)),
    ?assertEqual(
        [?IP, {16#2001, 16#DB8, 0, 0, 0, 0, 0, 0}],
        lists:sort([K || {K, _, _} <- ets:tab2list(Table)])
    ).

resolve_off_without_peer_test() ->
    Table = new_table(),
    ?assertEqual(undefined, ?M:resolve_rate_limit(proto_opts(Table), undefined)).

resolve_on_test() ->
    Table = new_table(),
    {Counter, Opts} = proto_opts_with_counter(Table),
    %% rate 10, burst 20, period 30 → Cost 30000, Cap 600000 baked in.
    ?assertEqual(
        {10, 600000, 30000, Table, Counter, ?IP}, ?M:resolve_rate_limit(Opts, {?IP, 5000})
    ).

%% --- throttled_telemetry/3 ---

telemetry_bumps_counter_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Counter = atomics:new(1, [{signed, false}]),
    ok = ?M:throttled_telemetry(some_listener, Counter, rate_limit),
    ok = ?M:throttled_telemetry(some_listener, Counter, max_concurrent_requests),
    ?assertEqual(2, atomics:get(Counter, 1)).

%% --- rate_limit_evict_full/4 ---

evicts_only_full_rows_test() ->
    Table = new_table(),
    %% Rate 2 units/ms, Cap 2000: an empty bucket at 0 is full at 1000, a
    %% half one at 500 full at 1000 too, one spent at 900 full at 1900.
    true = ets:insert(Table, {{1, 1, 1, 1}, 0, 0}),
    true = ets:insert(Table, {{2, 2, 2, 2}, 1000, 500}),
    true = ets:insert(Table, {{3, 3, 3, 3}, 0, 900}),
    ?assertEqual(0, ?M:rate_limit_evict_full(Table, 999, 2, 2000)),
    ?assertEqual(2, ?M:rate_limit_evict_full(Table, 1000, 2, 2000)),
    ?assertMatch([{{3, 3, 3, 3}, _, _}], ets:tab2list(Table)).

evict_empty_table_test() ->
    Table = new_table(),
    ?assertEqual(0, ?M:rate_limit_evict_full(Table, 2000, 2, 2000)).

evict_clears_all_full_in_one_pass_test() ->
    Table = new_table(),
    true = ets:insert(Table, {{1, 1, 1, 1}, 0, 0}),
    true = ets:insert(Table, {{2, 2, 2, 2}, 0, 0}),
    true = ets:insert(Table, {{3, 3, 3, 3}, 0, 0}),
    %% All three full rows are evicted in a single pass (no per-tick budget).
    ?assertEqual(3, ?M:rate_limit_evict_full(Table, 1000000, 1, cap(1, 1))),
    ?assertEqual(0, ets:info(Table, size)).

idle_bucket_keeps_its_limit_test() ->
    %% 100 requests an hour: a peer that spends them all and waits 70s is
    %% still about 98 requests short. The sweep must not hand it a fresh
    %% bucket, so it gets one more request and then waits for the refill.
    Table = new_table(),
    Rate = 100,
    Cap = cap(100, 3600),
    Cost = cost(3600),
    [allow = ?M:rate_limit_check(Table, ?IP, Rate, Cap, Cost, 0) || _ <- lists:seq(1, 100)],
    ?assertEqual(0, ?M:rate_limit_evict_full(Table, 70000, Rate, Cap)),
    ?assertEqual(allow, ?M:rate_limit_check(Table, ?IP, Rate, Cap, Cost, 70000)),
    ?assertMatch({deny, _}, ?M:rate_limit_check(Table, ?IP, Rate, Cap, Cost, 70000)),
    %% Full again an hour after the burst was spent: dropped.
    ?assertEqual(1, ?M:rate_limit_evict_full(Table, 3600000 + 72000, Rate, Cap)).

%% --- helpers ---

new_table() ->
    ets:new(rate_limit_test, [public, {write_concurrency, true}]).

%% Mirror the runtime derivation: one request costs `Period * 1000` units; a
%% bucket holds `Burst` requests.
cost(Period) -> Period * 1000.
cap(Burst, Period) -> Burst * cost(Period).

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
            sweep_interval => 10000,
            table => Table
        },
        rate_limited_counter => Counter
    }}.
