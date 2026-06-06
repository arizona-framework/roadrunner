-module(roadrunner_quic_amp_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_quic_amp).

%% A fresh state has received nothing, so the 3x cap is zero: a server
%% must receive the client's Initial before it can send.
new_starts_blocked_test() ->
    Amp = ?M:new(),
    ?assertEqual(0, ?M:budget(Amp)),
    ?assert(?M:can_send(0, Amp)),
    ?assertNot(?M:can_send(1, Amp)).

budget_is_three_times_received_test() ->
    ?assertEqual(300, ?M:budget(?M:received(100, ?M:new()))).

sent_spends_budget_test() ->
    Amp = ?M:sent(120, ?M:received(100, ?M:new())),
    ?assertEqual(180, ?M:budget(Amp)).

%% Sending more than 3x received (a padded Initial before the client's
%% next datagram arrives) floors the budget at zero, never negative.
budget_never_negative_test() ->
    Amp = ?M:sent(400, ?M:received(100, ?M:new())),
    ?assertEqual(0, ?M:budget(Amp)),
    %% can_send stays consistent with the floored budget: a zero-byte send
    %% is always allowed, a non-zero one is not.
    ?assert(?M:can_send(0, Amp)),
    ?assertNot(?M:can_send(1, Amp)).

can_send_at_and_over_limit_test() ->
    Amp = ?M:received(100, ?M:new()),
    ?assert(?M:can_send(300, Amp)),
    ?assertNot(?M:can_send(301, Amp)),
    Spent = ?M:sent(300, Amp),
    ?assert(?M:can_send(0, Spent)),
    ?assertNot(?M:can_send(1, Spent)).

%% After validation the limit is gone regardless of the byte counters.
validation_lifts_the_limit_test() ->
    Amp = ?M:validate(?M:sent(999, ?M:received(1, ?M:new()))),
    ?assertEqual(infinity, ?M:budget(Amp)),
    ?assert(?M:can_send(1000000, Amp)).

%% `infinity` orders above any integer, so min/2 caps a datagram size
%% cleanly whether or not the address is validated.
budget_caps_with_min_test() ->
    ?assertEqual(1200, min(1200, ?M:budget(?M:validate(?M:new())))),
    ?assertEqual(300, min(1200, ?M:budget(?M:received(100, ?M:new())))).
