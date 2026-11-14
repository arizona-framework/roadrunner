-module(roadrunner_quic_ack_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_quic_ack).

%% =============================================================================
%% Range tracking: each branch of the insert/merge logic.
%% =============================================================================

empty_state_test() ->
    Ack = ?M:new(),
    ?assertEqual(undefined, ?M:largest(Ack)),
    ?assertEqual([], ?M:ranges(Ack)),
    ?assertEqual(none, ?M:to_ack(Ack)),
    ?assertNot(?M:needs_ack(Ack)).

single_run_coalesces_test() ->
    Ack = record_all([0, 1, 2, 3], ?M:new()),
    ?assertEqual([{0, 3}], ?M:ranges(Ack)),
    ?assertEqual(3, ?M:largest(Ack)),
    ?assertEqual({3, 3, []}, ?M:to_ack(Ack)).

gap_creates_new_range_test() ->
    ?assertEqual([{5, 5}, {0, 2}], ?M:ranges(record_all([0, 1, 2, 5], ?M:new()))).

duplicate_is_ignored_test() ->
    ?assertEqual([{0, 2}], ?M:ranges(record_all([0, 1, 2, 1], ?M:new()))).

extend_down_test() ->
    %% Recording Start-1 of the only range extends it downward.
    ?assertEqual([{2, 5}], ?M:ranges(record_all([3, 4, 5, 2], ?M:new()))).

bridge_merges_ranges_test() ->
    %% Recording the one missing number between two ranges merges them.
    ?assertEqual([{0, 5}], ?M:ranges(record_all([0, 1, 3, 4, 5, 2], ?M:new()))).

extend_down_without_merge_test() ->
    %% Extending downward but still short of the next range keeps both.
    ?assertEqual([{4, 7}, {0, 1}], ?M:ranges(record_all([0, 1, 5, 6, 7, 4], ?M:new()))).

insert_into_lower_range_test() ->
    %% A number below the highest range descends into the rest of the list.
    ?assertEqual([{5, 7}, {2, 2}], ?M:ranges(record_all([5, 6, 7, 2], ?M:new()))).

%% =============================================================================
%% ACK frame range fields (RFC 9000 §19.3 gap/range encoding).
%% =============================================================================

multi_range_ack_encoding_test() ->
    %% Received 0,1,2,4,5,7: ranges {7},{4,5},{0,2}; first range 7 (size 0),
    %% then gap 0/range 1 (4-5), gap 0/range 2 (0-2).
    Ack = record_all([0, 1, 2, 4, 5, 7], ?M:new()),
    ?assertEqual([{7, 7}, {4, 5}, {0, 2}], ?M:ranges(Ack)),
    ?assertEqual({7, 0, [{0, 1}, {0, 2}]}, ?M:to_ack(Ack)).

%% =============================================================================
%% ACK-eliciting / pending tracking.
%% =============================================================================

needs_ack_tracks_eliciting_test() ->
    NonEliciting = ?M:record(0, false, 0, ?M:new()),
    ?assertNot(?M:needs_ack(NonEliciting)),
    Eliciting = ?M:record(1, true, 0, NonEliciting),
    ?assert(?M:needs_ack(Eliciting)),
    ?assertNot(?M:needs_ack(?M:mark_ack_sent(Eliciting))).

record_all(PNs, Ack) ->
    lists:foldl(fun(PN, Acc) -> ?M:record(PN, true, 0, Acc) end, Ack, PNs).

%% =============================================================================
%% Delayed ACK (RFC 9000 §13.2.1, §13.2.2).
%% =============================================================================

ack_due_after_delay_test() ->
    %% One ack-eliciting packet may wait until the delay runs out.
    Ack = ?M:record(0, true, 100, ?M:new()),
    ?assertNot(?M:ack_due(Ack, 119, 20)),
    ?assert(?M:ack_due(Ack, 120, 20)),
    ?assertEqual(120, ?M:ack_deadline(Ack, 20)).

ack_due_after_second_eliciting_packet_test() ->
    Ack = ?M:record(1, true, 101, ?M:record(0, true, 100, ?M:new())),
    ?assert(?M:ack_due(Ack, 101, 20)).

ack_due_on_reordering_test() ->
    %% A packet past a gap, or below the largest received, is out of order.
    Gap = ?M:record(2, true, 100, ?M:record(0, false, 100, ?M:new())),
    ?assert(?M:ack_due(Gap, 100, 20)),
    Below = ?M:record(0, true, 100, ?M:record(1, false, 100, ?M:new())),
    ?assert(?M:ack_due(Below, 100, 20)),
    %% Packet numbers start at 0, so a first packet past 0 follows a gap.
    ?assert(?M:ack_due(?M:record(3, true, 100, ?M:new()), 100, 20)).

non_eliciting_packet_never_due_test() ->
    Ack = ?M:record(0, false, 100, ?M:new()),
    ?assertNot(?M:ack_due(Ack, 1000, 20)),
    ?assertEqual(undefined, ?M:ack_deadline(Ack, 20)).

mark_ack_sent_clears_the_wait_test() ->
    Ack = ?M:mark_ack_sent(?M:record(1, true, 101, ?M:record(0, true, 100, ?M:new()))),
    ?assertNot(?M:ack_due(Ack, 1000, 20)),
    ?assertEqual(undefined, ?M:ack_deadline(Ack, 20)),
    %% The next packet starts a fresh wait.
    ?assertEqual(220, ?M:ack_deadline(?M:record(2, true, 200, Ack), 20)).

ack_delay_counts_from_the_largest_packet_test() ->
    ?assertEqual(0, ?M:ack_delay(?M:new(), 50)),
    %% A lower packet arriving later does not move the largest's arrival time.
    Ack = ?M:record(3, true, 110, ?M:record(5, true, 100, ?M:new())),
    ?assertEqual(15, ?M:ack_delay(Ack, 115)),
    %% A clock reading before the arrival never reports a negative delay.
    ?assertEqual(0, ?M:ack_delay(Ack, 90)).

%% A number in any received range was received; one in a gap, below them all
%% or above the largest was not (RFC 9000 §12.3).
received_test() ->
    Ack = lists:foldl(
        fun(PN, A) -> ?M:record(PN, true, 0, A) end,
        ?M:new(),
        [2, 3, 7, 8, 9]
    ),
    ?assert(?M:received(8, Ack)),
    ?assert(?M:received(2, Ack)),
    ?assertNot(?M:received(5, Ack)),
    ?assertNot(?M:received(0, Ack)),
    ?assertNot(?M:received(10, Ack)),
    ?assertNot(?M:received(0, ?M:new())).

%% Packet numbers acknowledged by an ACK frame the peer has acknowledged are
%% forgotten (RFC 9000 §13.2.4): a range straddling the frame's Largest
%% Acknowledged keeps its upper part, the top range stays whole, and the
%% numbers forgotten count as received. An older frame's acknowledgment
%% then changes nothing.
forget_through_test() ->
    Ack = record_all([1, 2, 4, 5, 6, 8, 10, 11], ?M:new()),
    Forgot = ?M:forget_through(5, Ack),
    ?assertEqual([{10, 11}, {8, 8}, {6, 6}], ?M:ranges(Forgot)),
    ?assert(?M:received(3, Forgot)),
    ?assertNot(?M:received(7, Forgot)),
    ?assertEqual(Forgot, ?M:forget_through(4, Forgot)),
    ?assertEqual([{10, 11}], ?M:ranges(?M:forget_through(11, Forgot))).

%% A peer skipping packet numbers makes a range per gap; past 32 the lowest
%% is dropped and counts as received (RFC 9000 §13.2.3, §12.3).
ranges_capped_test() ->
    Ack = record_all(lists:seq(0, 70, 2), ?M:new()),
    Ranges = ?M:ranges(Ack),
    ?assertEqual(32, length(Ranges)),
    ?assertEqual({70, 70}, hd(Ranges)),
    ?assertEqual({8, 8}, lists:last(Ranges)),
    %% The floor sits just past the highest dropped range, {6, 6}.
    ?assert(?M:received(6, Ack)),
    ?assertNot(?M:received(7, Ack)),
    ?assertNot(?M:received(9, Ack)).
