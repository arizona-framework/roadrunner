-module(roadrunner_quic_cc_newreno_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_quic_cc_newreno).

%% =============================================================================
%% Initial state (RFC 9002 §7.2).
%% =============================================================================

new_test() ->
    Cc = ?M:new(),
    ?assertEqual(12000, ?M:cwnd(Cc)),
    ?assertEqual(infinity, ?M:ssthresh(Cc)),
    ?assert(?M:in_slow_start(Cc)),
    ?assert(?M:can_send(0, Cc)),
    ?assert(?M:can_send(11999, Cc)),
    ?assertNot(?M:can_send(12000, Cc)).

%% =============================================================================
%% Window growth (RFC 9002 §7.3.1).
%% =============================================================================

slow_start_grows_by_acked_bytes_test() ->
    Cc = ?M:on_packets_acked(1200, 0, ?M:new()),
    ?assertEqual(13200, ?M:cwnd(Cc)),
    ?assert(?M:in_slow_start(Cc)).

congestion_avoidance_grows_by_one_datagram_per_window_test() ->
    %% After a loss the window leaves slow start; growth is
    %% max_datagram_size * acked div cwnd = 1200 * 1200 div 6600 = 218.
    AfterLoss = ?M:on_congestion_event(5, 100, ?M:on_packets_acked(1200, 0, ?M:new())),
    ?assertEqual(6600, ?M:cwnd(AfterLoss)),
    ?assertNot(?M:in_slow_start(AfterLoss)),
    Grown = ?M:on_packets_acked(1200, 200, AfterLoss),
    ?assertEqual(6818, ?M:cwnd(Grown)).

%% =============================================================================
%% Congestion recovery (RFC 9002 §7.3.2).
%% =============================================================================

congestion_event_halves_window_test() ->
    Cc = ?M:on_congestion_event(5, 100, ?M:on_packets_acked(1200, 0, ?M:new())),
    ?assertEqual(6600, ?M:cwnd(Cc)),
    ?assertEqual(6600, ?M:ssthresh(Cc)).

%% A second loss from a packet sent within the recovery period is ignored;
%% one sent after it starts a new reduction.
recovery_period_deduplicates_loss_test() ->
    Cc = ?M:on_congestion_event(5, 100, ?M:on_packets_acked(1200, 0, ?M:new())),
    Same = ?M:on_congestion_event(50, 200, Cc),
    ?assertEqual(6600, ?M:cwnd(Same)),
    Newer = ?M:on_congestion_event(150, 200, Cc),
    ?assertEqual(3300, ?M:cwnd(Newer)).

%% The window is held while the largest acked was sent during recovery.
no_growth_during_recovery_test() ->
    Cc = ?M:on_congestion_event(5, 100, ?M:on_packets_acked(1200, 0, ?M:new())),
    Held = ?M:on_packets_acked(1200, 50, Cc),
    ?assertEqual(6600, ?M:cwnd(Held)).

%% Repeated losses floor the window at the minimum (2 * max_datagram_size).
minimum_window_floor_test() ->
    Cc0 = ?M:new(),
    Cc1 = ?M:on_congestion_event(10, 10, Cc0),
    Cc2 = ?M:on_congestion_event(20, 20, Cc1),
    Cc3 = ?M:on_congestion_event(30, 30, Cc2),
    ?assertEqual(1500, ?M:ssthresh(Cc3)),
    ?assertEqual(2400, ?M:cwnd(Cc3)).
