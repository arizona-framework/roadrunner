-module(roadrunner_quic_loss_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_quic_loss).

%% =============================================================================
%% State + queries.
%% =============================================================================

new_defaults_test() ->
    Loss = ?M:new(#{}),
    ?assertEqual(333, ?M:smoothed_rtt(Loss)),
    ?assertEqual(166, ?M:rtt_var(Loss)),
    ?assertEqual(infinity, ?M:min_rtt(Loss)),
    ?assertEqual(0, ?M:latest_rtt(Loss)),
    ?assertNot(?M:has_rtt_sample(Loss)),
    ?assertEqual(undefined, ?M:largest_acked(Loss)),
    ?assertEqual(0, ?M:bytes_in_flight(Loss)),
    ?assertEqual(0, ?M:pto_count(Loss)).

%% =============================================================================
%% Packet tracking: ack-eliciting packets count toward bytes in flight.
%% =============================================================================

bytes_in_flight_counts_ack_eliciting_test() ->
    Loss0 = ?M:new(#{}),
    Loss1 = ?M:on_packet_sent(0, 1200, true, d0, 0, Loss0),
    ?assertEqual(1200, ?M:bytes_in_flight(Loss1)),
    %% A non-ack-eliciting packet (e.g. ACK-only) does not add.
    Loss2 = ?M:on_packet_sent(1, 40, false, d1, 1, Loss1),
    ?assertEqual(1200, ?M:bytes_in_flight(Loss2)).

%% =============================================================================
%% RTT estimation (RFC 9002 §5.3).
%% =============================================================================

update_rtt_first_sample_seeds_estimates_test() ->
    Loss = ?M:update_rtt(50, 5, ?M:new(#{})),
    ?assertEqual(50, ?M:smoothed_rtt(Loss)),
    ?assertEqual(25, ?M:rtt_var(Loss)),
    ?assertEqual(50, ?M:min_rtt(Loss)),
    ?assertEqual(50, ?M:latest_rtt(Loss)),
    ?assert(?M:has_rtt_sample(Loss)).

update_rtt_subsequent_sample_test() ->
    Base = ?M:update_rtt(50, 5, ?M:new(#{})),
    %% Latest (40) within min + ack delay: no ack-delay adjustment.
    NoAdjust = ?M:update_rtt(40, 2, Base),
    ?assertEqual(40, ?M:min_rtt(NoAdjust)),
    ?assert(?M:smoothed_rtt(NoAdjust) < 50),
    %% Latest (70) beyond min + ack delay: subtract the (capped) ack delay.
    Adjust = ?M:update_rtt(70, 10, Base),
    ?assertEqual(50, ?M:min_rtt(Adjust)),
    ?assert(?M:smoothed_rtt(Adjust) > 50).

%% =============================================================================
%% Probe timeout (RFC 9002 §6.2).
%% =============================================================================

pto_with_backoff_test() ->
    Loss = ?M:new(#{initial_rtt => 100}),
    %% 100 + max(4*50, 1) + 25 = 325.
    ?assertEqual(325, ?M:get_pto(Loss)),
    ?assertEqual(650, ?M:get_pto(?M:on_pto_expired(Loss))),
    ?assertEqual(1, ?M:pto_count(?M:on_pto_expired(Loss))).

%% =============================================================================
%% ACK processing + loss detection (RFC 9002 §5-§6).
%% =============================================================================

%% Send 0..9 at times 0..9; ACK only packet 9 at time 20. Packet 9 is
%% acknowledged, the RTT sample is 11; packets 0..6 fall to the packet
%% threshold and 7 to the time threshold, leaving 8 in flight.
on_ack_received_acks_and_detects_loss_test() ->
    Loss = send_run(0, 9, ?M:new(#{})),
    ?assertEqual(1000, ?M:bytes_in_flight(Loss)),
    {Loss1, Acked, Lost} = ?M:on_ack_received({ack, 9, 0, 0, []}, 20, Loss),
    ?assertEqual([9], Acked),
    ?assertEqual([0, 1, 2, 3, 4, 5, 6, 7], lists:sort(Lost)),
    ?assertEqual(100, ?M:bytes_in_flight(Loss1)),
    ?assertEqual(11, ?M:smoothed_rtt(Loss1)),
    ?assertEqual(9, ?M:largest_acked(Loss1)).

%% A gap range acknowledges two disjoint runs.
on_ack_received_gap_range_test() ->
    Loss = send_run(0, 9, ?M:new(#{})),
    %% Largest 9, first range [9,9], gap 0 / range 0 -> [7,7].
    {_Loss1, Acked, _Lost} = ?M:on_ack_received({ack, 9, 0, 0, [{0, 0}]}, 20, Loss),
    ?assertEqual([7, 9], lists:sort(Acked)).

%% The ECN variant carries the same fields plus counts.
on_ack_received_ecn_variant_test() ->
    Loss = send_run(0, 9, ?M:new(#{})),
    {_Loss1, Acked, _Lost} = ?M:on_ack_received({ack, 9, 0, 0, [], {1, 2, 3}}, 20, Loss),
    ?assertEqual([9], Acked).

%% A non-ack-eliciting largest acked, and a largest we never sent, both
%% leave the RTT untouched (no sample taken).
on_ack_received_no_rtt_sample_test() ->
    NonElic = ?M:on_packet_sent(0, 40, false, d0, 5, ?M:new(#{})),
    {Loss1, [d0], []} = ?M:on_ack_received({ack, 0, 0, 0, []}, 20, NonElic),
    ?assertNot(?M:has_rtt_sample(Loss1)),
    %% Largest acked 99 was never sent: nothing acked, no RTT sample.
    Sent = ?M:on_packet_sent(0, 100, true, d0, 0, ?M:new(#{})),
    {Loss2, [], _} = ?M:on_ack_received({ack, 99, 0, 0, []}, 20, Sent),
    ?assertNot(?M:has_rtt_sample(Loss2)).

%% Packets numbered above the largest acknowledged must stay in flight,
%% even when old: loss requires a higher-numbered packet to be acked
%% (RFC 9002 §6.1). Here the largest acked (1) is not ack-eliciting, so no
%% RTT sample is taken and the loss delay stays small, yet 2..5 survive
%% while 0 (below the largest, long past) is lost.
on_ack_received_keeps_above_largest_test() ->
    L0 = ?M:on_packet_sent(0, 100, true, d0, 0, ?M:new(#{})),
    L1 = ?M:on_packet_sent(1, 100, false, d1, 1, L0),
    L2 = lists:foldl(
        fun(PN, Acc) -> ?M:on_packet_sent(PN, 100, true, PN, PN, Acc) end, L1, [2, 3, 4, 5]
    ),
    {Loss, Acked, Lost} = ?M:on_ack_received({ack, 1, 0, 0, []}, 500, L2),
    ?assertEqual([d1], Acked),
    ?assertEqual([d0], Lost),
    ?assertEqual(400, ?M:bytes_in_flight(Loss)).

%% The ACK Delay field is in 2^ack_delay_exponent microsecond units
%% (RFC 9000 §19.3) and must be decoded to milliseconds. With a 50ms
%% minimum and a 150ms sample, the decoded delay (8000 -> 64ms) triggers
%% the ack-delay adjustment; the raw value (8000) never would.
on_ack_received_decodes_ack_delay_test() ->
    Opts = #{initial_rtt => 100, max_ack_delay => 1000},
    L0 = ?M:on_packet_sent(0, 100, true, d0, 0, ?M:new(Opts)),
    {L1, _, _} = ?M:on_ack_received({ack, 0, 0, 0, []}, 50, L0),
    L2 = ?M:on_packet_sent(1, 100, true, d1, 100, L1),
    {L3, _, _} = ?M:on_ack_received({ack, 1, 8000, 0, []}, 250, L2),
    ?assertEqual(54, ?M:smoothed_rtt(L3)).

%% The largest acked carries across ACKs (kept as the maximum).
largest_acked_is_monotonic_test() ->
    Loss = send_run(0, 9, ?M:new(#{})),
    {Loss1, _, _} = ?M:on_ack_received({ack, 5, 0, 0, []}, 20, Loss),
    ?assertEqual(5, ?M:largest_acked(Loss1)),
    {Loss2, _, _} = ?M:on_ack_received({ack, 3, 0, 0, []}, 21, Loss1),
    ?assertEqual(5, ?M:largest_acked(Loss2)).

%% A malicious ACK whose ranges would expand hugely is rejected.
on_ack_received_rejects_oversized_range_test() ->
    Loss = send_run(0, 9, ?M:new(#{})),
    %% Oversized first range; an oversized first gap range; and an
    %% oversized gap range deeper in the list (which propagates the error
    %% back up through the range expansion).
    ?assertEqual(
        {error, ack_range_too_large},
        ?M:on_ack_received({ack, 9, 0, 16#FFFFFFFF, []}, 20, Loss)
    ),
    ?assertEqual(
        {error, ack_range_too_large},
        ?M:on_ack_received({ack, 9, 0, 0, [{0, 16#FFFFFFFF}]}, 20, Loss)
    ),
    ?assertEqual(
        {error, ack_range_too_large},
        ?M:on_ack_received({ack, 9, 0, 0, [{0, 0}, {0, 16#FFFFFFFF}]}, 20, Loss)
    ).

%% =============================================================================
%% Timer-driven loss detection + the loss timer.
%% =============================================================================

detect_lost_test() ->
    %% Nothing acknowledged yet: no loss decision possible.
    Loss0 = send_run(0, 4, ?M:new(#{})),
    ?assertEqual({Loss0, []}, ?M:detect_lost(100, Loss0)),
    %% ACK packet 4 at time 100: the RTT sample (96) makes the loss delay
    %% large enough that 2 and 3 survive the ACK (0 and 1 fall to the
    %% packet threshold). A much later timer pass then declares 2 and 3
    %% lost by the time threshold.
    {Loss1, _, _} = ?M:on_ack_received({ack, 4, 0, 0, []}, 100, Loss0),
    {_Loss2, Lost} = ?M:detect_lost(10000, Loss1),
    ?assertEqual([2, 3], lists:sort(Lost)).

detect_lost_stops_at_in_flight_packet_test() ->
    %% Packets numbered above the largest acknowledged were sent ahead and are
    %% not loss candidates; the loss timer reaches the oldest of them and stops,
    %% declaring nothing lost and leaving the in-flight set unchanged.
    Loss0 = send_run(0, 4, ?M:new(#{})),
    {Loss1, _, _} = ?M:on_ack_received({ack, 0, 0, 0, []}, 100, Loss0),
    ?assertEqual({Loss1, []}, ?M:detect_lost(100, Loss1)).

loss_time_test() ->
    ?assertEqual(undefined, ?M:loss_time(?M:new(#{}))),
    %% First sample sets srtt; oldest packet sent at 0, loss delay 9*srtt/8.
    Loss = ?M:update_rtt(40, 0, ?M:on_packet_sent(0, 100, true, d0, 0, ?M:new(#{}))),
    ?assertEqual(0 + (9 * 40 div 8), ?M:loss_time(Loss)).

%% Send packets PN First..Last, each 100 bytes ack-eliciting, sent at
%% time = PN, carrying their own number as the retransmit data.
send_run(First, Last, Loss) ->
    lists:foldl(
        fun(PN, Acc) -> ?M:on_packet_sent(PN, 100, true, PN, PN, Acc) end,
        Loss,
        lists:seq(First, Last)
    ).
