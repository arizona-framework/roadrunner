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

%% --- resolve_rate_limit/2 ---

resolve_off_without_config_test() ->
    ?assertEqual(undefined, ?M:resolve_rate_limit(proto_opts(undefined), {?IP, 5000}, undefined)).

resolve_off_without_peer_test() ->
    Table = new_table(),
    ?assertEqual(undefined, ?M:resolve_rate_limit(proto_opts(Table), undefined, undefined)).

resolve_on_test() ->
    Table = new_table(),
    {Counter, Opts} = proto_opts_with_counter(Table),
    %% rate 10, burst 20, period 30 → Cost 30000, Cap 600000 baked in.
    ?assertEqual(
        {10, 600000, 30000, Table, Counter, ?IP},
        ?M:resolve_rate_limit(Opts, {?IP, 5000}, undefined)
    ).

resolve_on_with_trusted_peer_keys_per_request_test() ->
    %% A TRUSTED peer's client can differ per request, so the key stays the
    %% `client_ip` marker and the bucket follows the resolved client.
    Table = new_table(),
    RealIp = roadrunner_real_ip:compile(#{trusted_proxies => [~"127.0.0.1/32"]}),
    {Counter, Opts} = proto_opts_with_counter(Table, RealIp),
    Prepared = roadrunner_real_ip:prepare(RealIp, {?IP, 5000}),
    ?assertEqual(
        {10, 600000, 30000, Table, Counter, client_ip},
        ?M:resolve_rate_limit(Opts, {?IP, 5000}, Prepared)
    ).

resolve_on_with_untrusted_peer_bakes_the_key_test() ->
    %% An UNTRUSTED peer always resolves to the same client, so the concrete
    %% address is baked into the key and the per-request marker lookup is
    %% skipped entirely.
    Table = new_table(),
    Peer = {198, 51, 100, 9},
    RealIp = roadrunner_real_ip:compile(#{trusted_proxies => [~"127.0.0.1/32"]}),
    {Counter, Opts} = proto_opts_with_counter(Table, RealIp),
    Prepared = roadrunner_real_ip:prepare(RealIp, {Peer, 5000}),
    ?assertEqual(
        {10, 600000, 30000, Table, Counter, Peer},
        ?M:resolve_rate_limit(Opts, {Peer, 5000}, Prepared)
    ).

resolve_on_without_optional_keys_test() ->
    %% proto_opts that omit optional keys entirely must still resolve to an
    %% active guard keyed on the peer. Matching such a key in the function head
    %% would send this map to the `undefined` catch-all and silently disable
    %% rate limiting.
    Table = new_table(),
    Counter = atomics:new(1, [{signed, false}]),
    Opts = #{
        rate_limit => #{
            rate => 10,
            burst => 20,
            period => 30,
            idle_ttl => 60000,
            sweep_interval => 10000,
            table => Table
        },
        rate_limited_counter => Counter
    },
    ?assertEqual(
        {10, 600000, 30000, Table, Counter, ?IP},
        ?M:resolve_rate_limit(Opts, {?IP, 5000}, undefined)
    ).

%% --- rate_limit_key/2 ---

rate_limit_key_baked_ip_test() ->
    ?assertEqual(?IP, ?M:rate_limit_key(?IP, #{headers => []})).

rate_limit_key_marker_reads_client_ip_test() ->
    ?assertEqual(
        {203, 0, 113, 7},
        ?M:rate_limit_key(client_ip, #{client_ip => {203, 0, 113, 7}})
    ).

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
                    idle_ttl => 60000,
                    sweep_interval => 10000,
                    table => Table
                }
        end,
    #{
        rate_limit => Cfg,
        rate_limited_counter => atomics:new(1, [{signed, false}]),
        real_ip => undefined
    }.

proto_opts_with_counter(Table) ->
    proto_opts_with_counter(Table, undefined).

proto_opts_with_counter(Table, RealIp) ->
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
        rate_limited_counter => Counter,
        real_ip => RealIp
    }}.
