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
%%
%% An ACK may wait (RFC 9000 §13.2.1): `ack_due/3` says when it no longer
%% may, after a second ack-eliciting packet (§13.2.2), a packet out of order,
%% or the delay running out since the first unacknowledged one arrived, and
%% `ack_deadline/2` when that delay runs out. `ack_delay/2` is how long the
%% largest packet has waited, for the ACK frame's ACK Delay field.

-export([new/0, record/4, received/2, forget_through/2, largest/1, ranges/1, needs_ack/1]).
-export([mark_ack_sent/1, to_ack/1]).
-export([ack_due/3, ack_deadline/2, ack_delay/2]).

-export_type([t/0, range/0]).

-type range() :: {Start :: non_neg_integer(), End :: non_neg_integer()}.

%% The most ranges remembered, which keeps an ACK frame well inside one
%% packet (RFC 9000 §13.2.3): a peer that skips packet numbers makes one
%% range per gap.
-define(MAX_RANGES, 32).

-record(ack, {
    ranges = [] :: [range()],
    %% Packet numbers below it are no longer tracked, and count as received:
    %% a packet numbered there is discarded (RFC 9000 §12.3).
    floor = 0 :: non_neg_integer(),
    pending = false :: boolean(),
    %% Ack-eliciting packets received since the last ACK was sent.
    eliciting = 0 :: non_neg_integer(),
    %% When the first of those arrived.
    first_at = undefined :: integer() | undefined,
    %% Whether one of those arrived out of order: below the largest received,
    %% or past a gap above it.
    reordered = false :: boolean(),
    %% When the largest packet number arrived.
    largest_at = undefined :: integer() | undefined
}).

-opaque t() :: #ack{}.

-doc "A fresh ACK state for one packet-number space: nothing received yet.".
-spec new() -> t().
new() ->
    #ack{}.

-doc """
Record a packet number received at `Now` (milliseconds). `AckEliciting`
says whether the packet carried an ack-eliciting frame, which is what later
makes `needs_ack/1` true.
""".
-spec record(non_neg_integer(), boolean(), integer(), t()) -> t().
record(PN, AckEliciting, Now, #ack{ranges = Ranges} = Ack) ->
    Largest = largest(Ack),
    Ack1 = capped(PN, Largest, Ack#ack{
        ranges = add(PN, Ranges), largest_at = largest_at(PN, Largest, Now, Ack)
    }),
    case AckEliciting of
        true -> eliciting(PN, Largest, Now, Ack1);
        false -> Ack1
    end.

-spec largest_at(non_neg_integer(), non_neg_integer() | undefined, integer(), t()) ->
    integer() | undefined.
largest_at(PN, Largest, Now, _Ack) when Largest =:= undefined; PN > Largest ->
    Now;
largest_at(_PN, _Largest, _Now, #ack{largest_at = At}) ->
    At.

-spec eliciting(non_neg_integer(), non_neg_integer() | undefined, integer(), t()) -> t().
eliciting(
    PN, Largest, Now, #ack{eliciting = Count, first_at = FirstAt, reordered = Reordered} = Ack
) ->
    Ack#ack{
        pending = true,
        eliciting = Count + 1,
        first_at =
            case FirstAt of
                undefined -> Now;
                _ -> FirstAt
            end,
        reordered = Reordered orelse out_of_order(PN, Largest)
    }.

%% A packet below the largest received, or one leaving a gap above it. Packet
%% numbers start at 0, so a first packet past 0 leaves a gap too.
-spec out_of_order(non_neg_integer(), non_neg_integer() | undefined) -> boolean().
out_of_order(PN, undefined) -> PN > 0;
out_of_order(PN, Largest) -> PN < Largest orelse PN > Largest + 1.

-doc "The largest packet number received, or `undefined` if none.".
-spec largest(t()) -> non_neg_integer() | undefined.
largest(#ack{ranges = []}) -> undefined;
largest(#ack{ranges = [{_Start, End} | _]}) -> End.

-doc """
Whether packet number `PN` was already received in this space, so that a
copy of it is discarded (RFC 9000 §12.3): it is in the ranges, or below the
floor the ranges no longer reach, which counts as received. A number above
the largest, the usual case, is answered by the first range.
""".
-spec received(non_neg_integer(), t()) -> boolean().
received(PN, #ack{floor = Floor}) when PN < Floor ->
    true;
received(PN, #ack{ranges = Ranges}) ->
    in_ranges(PN, Ranges).

-doc """
Stop tracking the packet numbers up to `Largest`, the Largest Acknowledged
of an ACK frame the peer has acknowledged (RFC 9000 §13.2.3, §13.2.4): later
ACK frames leave them out. The top range stays, so there is always a
largest to acknowledge, and the numbers forgotten count as received.
""".
-spec forget_through(non_neg_integer(), t()) -> t().
forget_through(Largest, #ack{ranges = [Top | Rest], floor = Floor} = Ack) when Largest >= Floor ->
    Ack#ack{ranges = [Top | above(Largest, Rest)], floor = Largest + 1};
forget_through(_Largest, Ack) ->
    Ack.

%% The part of `Ranges` above `Largest`.
-spec above(non_neg_integer(), [range()]) -> [range()].
above(Largest, [{Start, End} | Rest]) when Start > Largest ->
    [{Start, End} | above(Largest, Rest)];
above(Largest, [{_Start, End} | _]) when End > Largest ->
    [{Largest + 1, End}];
above(_Largest, _Ranges) ->
    [].

%% A packet number that left a gap, above the largest or within the ranges,
%% may have made one range more than ?MAX_RANGES: the lowest goes, and the
%% floor rises past it. The usual next-in-order packet only extends the top
%% range, so it skips the count.
-spec capped(non_neg_integer(), non_neg_integer() | undefined, t()) -> t().
capped(PN, Largest, Ack) when PN =:= Largest + 1 ->
    Ack;
capped(_PN, _Largest, #ack{ranges = Ranges} = Ack) ->
    case length(Ranges) > ?MAX_RANGES of
        true ->
            {Kept, [{_Start, End} | _]} = lists:split(?MAX_RANGES, Ranges),
            Ack#ack{ranges = Kept, floor = End + 1};
        false ->
            Ack
    end.

-spec in_ranges(non_neg_integer(), [range()]) -> boolean().
in_ranges(PN, [{Start, End} | _]) when PN >= Start, PN =< End -> true;
in_ranges(PN, [{Start, _End} | Rest]) when PN < Start -> in_ranges(PN, Rest);
in_ranges(_PN, _Ranges) -> false.

-doc "The received ranges, each an inclusive `{Start, End}`, highest first.".
-spec ranges(t()) -> [range()].
ranges(#ack{ranges = Ranges}) ->
    Ranges.

-doc "Whether an ack-eliciting packet is still awaiting acknowledgement.".
-spec needs_ack(t()) -> boolean().
needs_ack(#ack{pending = Pending}) ->
    Pending.

-doc "Clear the pending state once an ACK covering the received packets has been sent.".
-spec mark_ack_sent(t()) -> t().
mark_ack_sent(Ack) ->
    Ack#ack{pending = false, eliciting = 0, first_at = undefined, reordered = false}.

-doc """
Whether a pending ACK must go out at `Now` rather than wait for a packet
to ride in: once two ack-eliciting packets are unacknowledged (RFC 9000
§13.2.2), once one arrived out of order (§13.2.1), or once the first
unacknowledged one has waited `MaxDelay` milliseconds.
""".
-spec ack_due(t(), integer(), non_neg_integer()) -> boolean().
ack_due(#ack{pending = false}, _Now, _MaxDelay) ->
    false;
ack_due(#ack{eliciting = Count, reordered = Reordered, first_at = FirstAt}, Now, MaxDelay) ->
    Count >= 2 orelse Reordered orelse Now >= FirstAt + MaxDelay.

-doc "When a pending ACK may wait no longer, or `undefined` with none pending.".
-spec ack_deadline(t(), non_neg_integer()) -> integer() | undefined.
ack_deadline(#ack{pending = true, first_at = FirstAt}, MaxDelay) ->
    FirstAt + MaxDelay;
ack_deadline(#ack{pending = false}, _MaxDelay) ->
    undefined.

-doc """
How long, in milliseconds, the largest received packet has waited at `Now`:
the ACK Delay an ACK frame reports (RFC 9000 §19.3). 0 with nothing received.
""".
-spec ack_delay(t(), integer()) -> non_neg_integer().
ack_delay(#ack{largest_at = undefined}, _Now) ->
    0;
ack_delay(#ack{largest_at = At}, Now) ->
    max(0, Now - At).

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
