-module(roadrunner_rate_limit_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_rate_limit).

%% Units: one request costs `Period * 1000`. The cases below use the per-second
%% default (Cost = 1000, Cap = Burst * 1000) unless a period is called out.

%% --- refill/5 ---

refill_from_empty_accrues_test() ->
    %% 100ms at Rate 10 units/ms = 1000 units = one request, under a 5-request cap.
    ?assertEqual(1000, ?M:refill(0, 0, 100, 10, 5000)).

refill_partial_adds_to_existing_test() ->
    ?assertEqual(2500, ?M:refill(2000, 0, 50, 10, 5000)).

refill_caps_at_capacity_test() ->
    ?assertEqual(5000, ?M:refill(0, 0, 100000, 10, 5000)).

refill_already_full_stays_capped_test() ->
    ?assertEqual(5000, ?M:refill(5000, 0, 1000, 10, 5000)).

refill_backwards_clock_clamps_to_zero_test() ->
    ?assertEqual(2000, ?M:refill(2000, 100, 50, 10, 5000)).

%% --- spend/2 ---

spend_ok_returns_remaining_test() ->
    ?assertEqual(1500, ?M:spend(2500, 1000)).

spend_exactly_one_request_test() ->
    ?assertEqual(0, ?M:spend(1000, 1000)).

spend_denied_below_one_request_test() ->
    ?assertEqual(denied, ?M:spend(999, 1000)).

spend_denied_when_empty_test() ->
    ?assertEqual(denied, ?M:spend(0, 1000)).

%% --- retry_after_secs/3 ---

retry_after_per_second_is_one_test() ->
    %% Cost 1000 (period 1s): one request always refills within a second.
    ?assertEqual(1, ?M:retry_after_secs(0, 10, 1000)).

retry_after_per_minute_is_longer_test() ->
    %% 1 request per 60s → Cost 60000, Rate 1 unit/ms: an empty bucket takes
    %% 60s to refill one request.
    ?assertEqual(60, ?M:retry_after_secs(0, 1, 60000)).

retry_after_partial_deficit_test() ->
    %% 10 per 60s → Cost 60000, Rate 10 units/ms. Half a request short (30000
    %% units) → 3000ms → 3s.
    ?assertEqual(3, ?M:retry_after_secs(30000, 10, 60000)).

retry_after_never_below_one_test() ->
    ?assertEqual(1, ?M:retry_after_secs(999, 1000, 1000)).

%% --- client_key/1 ---

client_key_ipv4_is_itself_test() ->
    ?assertEqual({203, 0, 113, 7}, ?M:client_key({203, 0, 113, 7})).

client_key_ipv6_is_its_64_test() ->
    %% Every address of a /64 shares one key; another /64 has its own.
    Key = {16#2001, 16#DB8, 0, 0, 0, 0, 0, 0},
    ?assertEqual(Key, ?M:client_key({16#2001, 16#DB8, 0, 0, 0, 0, 0, 1})),
    ?assertEqual(Key, ?M:client_key({16#2001, 16#DB8, 0, 0, 16#ABCD, 1, 2, 3})),
    ?assertEqual(
        {16#2001, 16#DB8, 0, 1, 0, 0, 0, 0}, ?M:client_key({16#2001, 16#DB8, 0, 1, 0, 0, 0, 1})
    ).

client_key_ipv4_carried_in_ipv6_test() ->
    %% IPv4-mapped (a dual-stack listener's IPv4 peer) and NAT64
    %% (`64:ff9b::/96`) addresses are keyed as the IPv4 client they carry.
    ?assertEqual({203, 0, 113, 7}, ?M:client_key({0, 0, 0, 0, 0, 16#FFFF, 16#CB00, 16#7107})),
    ?assertEqual({203, 0, 113, 7}, ?M:client_key({16#64, 16#FF9B, 0, 0, 0, 0, 16#CB00, 16#7107})).
