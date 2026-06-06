-module(roadrunner_quic_ack).
-moduledoc false.

%% Received-packet tracking and ACK generation for one packet-number
%% space (RFC 9000 §13.2). A connection keeps one of these per space
%% (Initial, Handshake, Application).
%%
%% Received packet numbers are held as a list of inclusive `{Start, End}`
%% ranges, highest first and coalesced, so a long run of packets costs one
%% range. `to_ack/1` turns that into an ACK frame's range fields (largest
%% acknowledged, first range, then the gap/range pairs of RFC 9000 §19.3);
%% the connection adds the ACK delay (from its own clock) and any ECN
%% counts to assemble the frame. `needs_ack/1` reports whether an
%% ack-eliciting packet is still awaiting acknowledgement.

-export([new/0, record/3, largest/1, ranges/1, needs_ack/1, mark_ack_sent/1, to_ack/1]).

-export_type([t/0, range/0]).

-type range() :: {Start :: non_neg_integer(), End :: non_neg_integer()}.

-record(ack, {
    ranges = [] :: [range()],
    pending = false :: boolean()
}).

-opaque t() :: #ack{}.

-doc "A fresh ACK state for one packet-number space: nothing received yet.".
-spec new() -> t().
new() ->
    #ack{}.

-doc """
Record a received packet number. `AckEliciting` says whether the packet
carried an ack-eliciting frame, which is what later makes `needs_ack/1`
true.
""".
-spec record(non_neg_integer(), boolean(), t()) -> t().
record(PN, AckEliciting, #ack{ranges = Ranges, pending = Pending} = Ack) ->
    Ack#ack{ranges = add(PN, Ranges), pending = Pending orelse AckEliciting}.

-doc "The largest packet number received, or `undefined` if none.".
-spec largest(t()) -> non_neg_integer() | undefined.
largest(#ack{ranges = []}) -> undefined;
largest(#ack{ranges = [{_Start, End} | _]}) -> End.

-doc "The received ranges, each an inclusive `{Start, End}`, highest first.".
-spec ranges(t()) -> [range()].
ranges(#ack{ranges = Ranges}) ->
    Ranges.

-doc "Whether an ack-eliciting packet is still awaiting acknowledgement.".
-spec needs_ack(t()) -> boolean().
needs_ack(#ack{pending = Pending}) ->
    Pending.

-doc "Clear the pending flag once an ACK covering the received packets has been sent.".
-spec mark_ack_sent(t()) -> t().
mark_ack_sent(Ack) ->
    Ack#ack{pending = false}.

-doc """
The ACK frame range fields for the current state, or `none` if nothing
has been received: `{LargestAcked, FirstAckRange, AckRanges}`, where
`AckRanges` is the list of `{Gap, Range}` pairs (RFC 9000 §19.3). The
caller wraps these with an ACK delay and any ECN counts.
""".
-spec to_ack(t()) ->
    {non_neg_integer(), non_neg_integer(), [{non_neg_integer(), non_neg_integer()}]} | none.
to_ack(#ack{ranges = []}) ->
    none;
to_ack(#ack{ranges = [{FirstStart, FirstEnd} | Rest]}) ->
    {FirstEnd, FirstEnd - FirstStart, gap_ranges(FirstStart, Rest)}.

%% =============================================================================
%% Internal
%% =============================================================================

%% Insert a packet number into the high-to-low, coalesced range list
%% (RFC 9000 §13.2.3 keeps received packets as ranges). Body recursion
%% descends to the right range; extending a range down can bridge it with
%% the next one, so that case re-merges.
-spec add(non_neg_integer(), [range()]) -> [range()].
add(PN, []) ->
    [{PN, PN}];
add(PN, [{_Start, End} | _] = Ranges) when PN > End + 1 ->
    [{PN, PN} | Ranges];
add(PN, [{Start, End} | Rest]) when PN =:= End + 1 ->
    [{Start, PN} | Rest];
add(PN, [{Start, End} | Rest]) when PN >= Start, PN =< End ->
    [{Start, End} | Rest];
add(PN, [{Start, End} | Rest]) when PN =:= Start - 1 ->
    merge([{PN, End} | Rest]);
add(PN, [Range | Rest]) ->
    [Range | add(PN, Rest)].

%% Coalesce the head range with the next when they touch or overlap.
-spec merge([range()]) -> [range()].
merge([{S1, E1}, {S2, E2} | Rest]) when E2 + 1 >= S1 ->
    merge([{S2, max(E1, E2)} | Rest]);
merge(Ranges) ->
    Ranges.

%% Encode the lower ranges as `{Gap, Range}` pairs relative to the
%% previous range's start (RFC 9000 §19.3.1): Gap is the count of missing
%% packets between ranges minus one, Range the packets in this range minus
%% one.
-spec gap_ranges(non_neg_integer(), [range()]) -> [{non_neg_integer(), non_neg_integer()}].
gap_ranges(_PrevStart, []) ->
    [];
gap_ranges(PrevStart, [{Start, End} | Rest]) ->
    [{PrevStart - End - 2, End - Start} | gap_ranges(Start, Rest)].
