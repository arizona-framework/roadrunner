-module(roadrunner_quic_ack_props).
-moduledoc """
Property-based tests for `roadrunner_quic_ack`.

Structural invariants over a random sequence of received packet numbers:
the coalesced ranges are sorted high-to-low with a real gap between each
adjacent pair (no touching or overlap), the largest acknowledged equals
the maximum packet number recorded, and the ACK frame range fields from
`to_ack/1` agree with those ranges.
""".

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct_property_test.hrl").

prop_range_invariants() ->
    ?FORALL(
        PNs,
        %% A dense packet-number domain so a random sequence routinely
        %% produces adjacent, duplicate, and gap-bridging numbers, which is
        %% where the coalescing and gap/range encoding could go wrong.
        list(integer(0, 30)),
        begin
            Ack = lists:foldl(
                fun(PN, Acc) -> roadrunner_quic_ack:record(PN, true, Acc) end,
                roadrunner_quic_ack:new(),
                PNs
            ),
            Ranges = roadrunner_quic_ack:ranges(Ack),
            ranges_descending_and_disjoint(Ranges) andalso
                ranges_cover(Ranges, PNs) andalso
                largest_is_max(roadrunner_quic_ack:largest(Ack), PNs) andalso
                to_ack_consistent(roadrunner_quic_ack:to_ack(Ack), Ranges)
        end
    ).

%% Every range is internally well-formed (Start =< End), and consecutive
%% ranges step strictly downward with a real gap: the next range's End is
%% at least two below this range's Start, so nothing touches or overlaps
%% (a touching pair would have been coalesced into one range).
ranges_descending_and_disjoint([]) ->
    true;
ranges_descending_and_disjoint([{Start, End}]) ->
    Start =< End;
ranges_descending_and_disjoint([{S1, E1}, {S2, E2} | Rest]) ->
    S1 =< E1 andalso S1 > E2 + 1 andalso
        ranges_descending_and_disjoint([{S2, E2} | Rest]).

%% The set of packet numbers covered by the ranges is exactly the set of
%% packet numbers recorded (no spurious additions, none dropped).
ranges_cover(Ranges, PNs) ->
    Covered = lists:foldl(
        fun({Start, End}, Acc) -> lists:seq(Start, End) ++ Acc end, [], Ranges
    ),
    lists:sort(Covered) =:= lists:usort(PNs).

%% The largest acknowledged is the max recorded packet number, or
%% `undefined` when nothing was recorded.
largest_is_max(undefined, []) -> true;
largest_is_max(_Largest, []) -> false;
largest_is_max(Largest, PNs) -> Largest =:= lists:max(PNs).

%% `to_ack/1` is `none` exactly when there are no ranges; otherwise its
%% LargestAcked is the head range's End and FirstAckRange is that range's
%% span, and the gap/range pairs decode back to the lower ranges.
to_ack_consistent(none, []) ->
    true;
to_ack_consistent({LargestAcked, FirstRange, AckRanges}, [{FirstStart, FirstEnd} | Rest]) ->
    LargestAcked =:= FirstEnd andalso
        FirstRange =:= FirstEnd - FirstStart andalso
        gaps_match(AckRanges, FirstStart, Rest);
to_ack_consistent(_ToAck, _Ranges) ->
    false.

%% Each {Gap, Range} pair must reconstruct the next lower range from the
%% previous range's start (RFC 9000 §19.3.1): the range's End sits Gap+2
%% below PrevStart and its span is Range.
gaps_match([], _PrevStart, []) ->
    true;
gaps_match([{Gap, Range} | PairRest], PrevStart, [{Start, End} | RangeRest]) ->
    Gap =:= PrevStart - End - 2 andalso
        Range =:= End - Start andalso
        gaps_match(PairRest, Start, RangeRest);
gaps_match(_Pairs, _PrevStart, _Ranges) ->
    false.
