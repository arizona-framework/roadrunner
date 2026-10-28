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

%% The congestion-control signal an ACK leaves for the connection: acked bytes
%% and the send times of the largest acked / latest lost ack-eliciting packets.
cc_signal_test() ->
    Fresh = ?M:cc_signal(?M:new(#{})),
    ?assertEqual(0, maps:get(acked_bytes, Fresh)),
    ?assertEqual(undefined, maps:get(largest_acked_time, Fresh)),
    ?assertEqual(undefined, maps:get(largest_lost_time, Fresh)),
    %% Ack the largest of ten in-flight packets (send time = packet number): the
    %% signal carries the acked bytes, the largest's time, and the latest lost.
    Loss = send_run(0, 9, ?M:new(#{})),
    {Loss1, _, _} = ?M:on_ack_received({ack, 9, 0, 0, []}, 20, Loss),
    ?assertEqual(
        #{
            acked_bytes => 100,
            largest_acked_time => 9,
            largest_lost_time => 7,
            persistent_congestion => false
        },
        ?M:cc_signal(Loss1)
    ),
    %% A non-ack-eliciting largest acked yields no acked send time and no lost
    %% time, so the connection grows nothing.
    NonElic = ?M:on_packet_sent(3, 100, false, 3, 3, ?M:new(#{})),
    {Loss2, _, _} = ?M:on_ack_received({ack, 3, 0, 0, []}, 30, NonElic),
    ?assertEqual(
        #{
            acked_bytes => 0,
            largest_acked_time => undefined,
            largest_lost_time => undefined,
            persistent_congestion => false
        },
        ?M:cc_signal(Loss2)
    ).

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

%% RFC 9000 §19.3.1: an ACK whose ranges reach below packet number 0 is
%% rejected, through the first range, a gap range, and a gap range deeper in
%% the list (which propagates the error back up through the expansion).
on_ack_received_rejects_negative_range_test() ->
    Loss = send_run(0, 9, ?M:new(#{})),
    ?assertEqual({error, negative_ack_range}, ?M:on_ack_received({ack, 9, 0, 10, []}, 20, Loss)),
    ?assertEqual(
        {error, negative_ack_range}, ?M:on_ack_received({ack, 9, 0, 0, [{7, 1}]}, 20, Loss)
    ),
    ?assertEqual(
        {error, negative_ack_range},
        ?M:on_ack_received({ack, 9, 0, 0, [{0, 0}, {6, 0}]}, 20, Loss)
    ).

%% A range down to exactly packet number 0 is valid, however long.
on_ack_received_accepts_range_to_zero_test() ->
    Loss = send_run(0, 9, ?M:new(#{})),
    {_, Acked, []} = ?M:on_ack_received({ack, 9, 0, 0, [{0, 7}]}, 20, Loss),
    ?assertEqual(9, length(Acked)),
    {_, Acked2, []} = ?M:on_ack_received({ack, 100000, 0, 100000, []}, 20, Loss),
    ?assertEqual(10, length(Acked2)).

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
    {Loss2, Lost} = ?M:detect_lost(10000, Loss1),
    ?assertEqual([2, 3], lists:sort(Lost)),
    %% RFC 9002 Appendix B.8: the timer-detected loss leaves a congestion signal
    %% with the latest lost send time and nothing acknowledged.
    ?assertEqual(
        #{
            acked_bytes => 0,
            largest_acked_time => undefined,
            largest_lost_time => 3,
            persistent_congestion => false
        },
        ?M:cc_signal(Loss2)
    ).

detect_lost_stops_at_in_flight_packet_test() ->
    %% Packets numbered above the largest acknowledged were sent ahead and are
    %% not loss candidates; the loss timer reaches the oldest of them and stops,
    %% declaring nothing lost and leaving the in-flight set unchanged. The ACK's
    %% signal is replaced by an empty one, so it is never applied twice.
    Loss0 = send_run(0, 4, ?M:new(#{})),
    {Loss1, _, _} = ?M:on_ack_received({ack, 0, 0, 0, []}, 100, Loss0),
    {Loss2, []} = ?M:detect_lost(100, Loss1),
    ?assertEqual(?M:bytes_in_flight(Loss1), ?M:bytes_in_flight(Loss2)),
    ?assertEqual(
        #{
            acked_bytes => 0,
            largest_acked_time => undefined,
            largest_lost_time => undefined,
            persistent_congestion => false
        },
        ?M:cc_signal(Loss2)
    ).

loss_time_test() ->
    ?assertEqual(undefined, ?M:loss_time(?M:new(#{}))),
    %% First sample sets srtt; oldest packet sent at 0, loss delay 9*srtt/8.
    Loss = ?M:update_rtt(40, 0, ?M:on_packet_sent(0, 100, true, d0, 0, ?M:new(#{}))),
    ?assertEqual(0 + (9 * 40 div 8), ?M:loss_time(Loss)).

%% =============================================================================
%% Persistent congestion (RFC 9002 §7.6).
%% =============================================================================

%% The §7.6.3 example in milliseconds: packet 0 is acknowledged at 10 (the
%% first RTT sample, 10ms), packets 1..8 go out 20ms apart, and only packet 8
%% is acknowledged, at 170. The ACK's sample leaves srtt 10 and rttvar 3, so
%% with no max_ack_delay the duration is (10 + 12 + 0) * 3 = 66; the lost
%% packets 1..7 span 20..140, 120ms with nothing between them acknowledged.
persistent_congestion_established_test() ->
    Loss = sampled_then_sent(#{max_ack_delay => 0}, [{PN, 20 * PN, true} || PN <- lists:seq(1, 8)]),
    {Loss1, _, Lost} = ?M:on_ack_received({ack, 8, 0, 0, []}, 170, Loss),
    ?assertEqual([1, 2, 3, 4, 5, 6, 7], lists:sort(Lost)),
    ?assertMatch(#{persistent_congestion := true}, ?M:cc_signal(Loss1)).

%% The same losses with a 25ms max_ack_delay: the duration grows to
%% (10 + 12 + 25) * 3 = 141, past the 120ms span (§7.6.1).
persistent_congestion_needs_the_duration_test() ->
    Loss = sampled_then_sent(#{max_ack_delay => 25}, [{PN, 20 * PN, true} || PN <- lists:seq(1, 8)]),
    {Loss1, _, _} = ?M:on_ack_received({ack, 8, 0, 0, []}, 170, Loss),
    ?assertMatch(#{persistent_congestion := false}, ?M:cc_signal(Loss1)).

%% Acknowledging packet 4 too splits the losses into 1..3 and 5..7, each
%% spanning 40ms: a packet between them was acknowledged (§7.6.2).
persistent_congestion_broken_by_an_acknowledged_packet_test() ->
    Loss = sampled_then_sent(#{max_ack_delay => 0}, [{PN, 20 * PN, true} || PN <- lists:seq(1, 8)]),
    {Loss1, _, Lost} = ?M:on_ack_received({ack, 8, 0, 0, [{2, 0}]}, 170, Loss),
    ?assertEqual([1, 2, 3, 5, 6, 7], lists:sort(Lost)),
    ?assertMatch(#{persistent_congestion := false}, ?M:cc_signal(Loss1)).

%% Only ack-eliciting packets are endpoints (§7.6.2): with 1, 2 and 7 not
%% ack-eliciting, the eligible 3..6 span 60ms, under the 66ms duration. The
%% non-ack-eliciting packets still continue the run.
persistent_congestion_needs_ack_eliciting_endpoints_test() ->
    Sends = [{PN, 20 * PN, not lists:member(PN, [1, 2, 7])} || PN <- lists:seq(1, 8)],
    Loss = sampled_then_sent(#{max_ack_delay => 0}, Sends),
    {Loss1, _, Lost} = ?M:on_ack_received({ack, 8, 0, 0, []}, 170, Loss),
    ?assertEqual([1, 2, 3, 4, 5, 6, 7], lists:sort(Lost)),
    ?assertMatch(#{persistent_congestion := false}, ?M:cc_signal(Loss1)).

%% Only packets sent after the first RTT sample count (Appendix B.8): here
%% the ACK itself takes the first sample, so none of the 160ms of losses do.
persistent_congestion_needs_a_prior_rtt_sample_test() ->
    Loss = send_at([{PN, 20 * PN, true} || PN <- lists:seq(0, 8)], ?M:new(#{max_ack_delay => 0})),
    {Loss1, _, Lost} = ?M:on_ack_received({ack, 8, 0, 0, []}, 170, Loss),
    ?assertEqual([0, 1, 2, 3, 4, 5, 6, 7], lists:sort(Lost)),
    ?assertMatch(#{persistent_congestion := false}, ?M:cc_signal(Loss1)).

%% Packet 0 sent at 0 and acknowledged at 10 (the first RTT sample, 10ms),
%% then the given `{PN, Time, AckEliciting}` sends.
sampled_then_sent(Opts, Sends) ->
    Sent0 = ?M:on_packet_sent(0, 100, true, 0, 0, ?M:new(Opts)),
    {Sampled, [0], []} = ?M:on_ack_received({ack, 0, 0, 0, []}, 10, Sent0),
    send_at(Sends, Sampled).

%% Send each `{PN, Time, AckEliciting}` as a 100-byte packet carrying its number.
send_at(Sends, Loss) ->
    lists:foldl(
        fun({PN, Time, AckEliciting}, Acc) ->
            ?M:on_packet_sent(PN, 100, AckEliciting, PN, Time, Acc)
        end,
        Loss,
        Sends
    ).

%% Send packets PN First..Last, each 100 bytes ack-eliciting, sent at
%% time = PN, carrying their own number as the retransmit data.
%% RFC 9002 §6.2.1: the probe timeout runs from the last ack-eliciting packet
%% sent, so a later non-ack-eliciting send does not move it, and with nothing
%% ack-eliciting in flight there is none.
pto_deadline_counts_from_last_ack_eliciting_send_test() ->
    ?assertEqual(undefined, ?M:pto_deadline(?M:new(#{}))),
    Sent = ?M:on_packet_sent(0, 100, true, d0, 1000, ?M:new(#{})),
    Deadline = 1000 + ?M:get_pto(Sent),
    ?assertEqual(Deadline, ?M:pto_deadline(Sent)),
    ?assertEqual(Deadline, ?M:pto_deadline(?M:on_packet_sent(1, 40, false, d1, 1500, Sent))),
    Later = ?M:on_packet_sent(1, 100, true, d1, 1500, Sent),
    ?assertEqual(1500 + ?M:get_pto(Later), ?M:pto_deadline(Later)),
    ?assertEqual(undefined, ?M:pto_deadline(?M:on_packet_sent(0, 40, false, d0, 0, ?M:new(#{})))).

%% RFC 9002 §6.2.4: the data a probe can carry again is the oldest
%% unacknowledged ack-eliciting packet's, skipping ACK-only packets.
oldest_ack_eliciting_test() ->
    ?assertEqual([], ?M:oldest_ack_eliciting(?M:new(#{}))),
    AckOnly = ?M:on_packet_sent(0, 40, false, d0, 0, ?M:new(#{})),
    ?assertEqual([], ?M:oldest_ack_eliciting(AckOnly)),
    Mixed = ?M:on_packet_sent(2, 100, true, d2, 2, ?M:on_packet_sent(1, 100, true, d1, 1, AckOnly)),
    ?assertEqual([d1], ?M:oldest_ack_eliciting(Mixed)).

%% RFC 9002 §6.2.4: a handshake probe can carry every unacknowledged
%% ack-eliciting packet's data, oldest first, skipping ACK-only packets.
unacked_ack_eliciting_test() ->
    ?assertEqual([], ?M:unacked_ack_eliciting(?M:new(#{}))),
    AckOnly = ?M:on_packet_sent(0, 40, false, d0, 0, ?M:new(#{})),
    ?assertEqual([], ?M:unacked_ack_eliciting(AckOnly)),
    Mixed = ?M:on_packet_sent(2, 100, true, d2, 2, ?M:on_packet_sent(1, 100, true, d1, 1, AckOnly)),
    ?assertEqual([d1, d2], ?M:unacked_ack_eliciting(Mixed)).

send_run(First, Last, Loss) ->
    lists:foldl(
        fun(PN, Acc) -> ?M:on_packet_sent(PN, 100, true, PN, PN, Acc) end,
        Loss,
        lists:seq(First, Last)
    ).

%% RFC 9000 §9.4: on a new path every RTT estimate starts over from the
%% initial value, and a packet sent before the reset (on the old path) gives
%% no sample, while one sent after it does.
reset_rtt_test() ->
    Opts = #{initial_rtt => 100},
    L0 = ?M:on_packet_sent(0, 100, true, d0, 0, ?M:new(Opts)),
    {L1, _, _} = ?M:on_ack_received({ack, 0, 0, 0, []}, 40, L0),
    ?assertEqual(40, ?M:smoothed_rtt(L1)),
    L2 = ?M:on_packet_sent(1, 100, true, d1, 50, L1),
    Reset = ?M:reset_rtt(60, L2),
    ?assertEqual(100, ?M:smoothed_rtt(Reset)),
    ?assertEqual(50, ?M:rtt_var(Reset)),
    ?assertEqual(infinity, ?M:min_rtt(Reset)),
    ?assertEqual(0, ?M:latest_rtt(Reset)),
    ?assertNot(?M:has_rtt_sample(Reset)),
    {L3, [d1], []} = ?M:on_ack_received({ack, 1, 0, 0, []}, 90, Reset),
    ?assertNot(?M:has_rtt_sample(L3)),
    L4 = ?M:on_packet_sent(2, 100, true, d2, 100, L3),
    {L5, [d2], []} = ?M:on_ack_received({ack, 2, 0, 0, []}, 130, L4),
    ?assertEqual(30, ?M:smoothed_rtt(L5)).
