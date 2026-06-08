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
    NonEliciting = ?M:record(0, false, ?M:new()),
    ?assertNot(?M:needs_ack(NonEliciting)),
    Eliciting = ?M:record(1, true, NonEliciting),
    ?assert(?M:needs_ack(Eliciting)),
    ?assertNot(?M:needs_ack(?M:mark_ack_sent(Eliciting))).

record_all(PNs, Ack) ->
    lists:foldl(fun(PN, Acc) -> ?M:record(PN, true, Acc) end, Ack, PNs).
