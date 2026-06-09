-module(roadrunner_quic_loss).
-moduledoc false.

%% Loss detection and RTT estimation for one packet-number space
%% (RFC 9002 §5-§6). A connection keeps one of these per space.
%%
%% The module is pure: the monotonic clock is passed in as `Now`
%% (milliseconds) on every state transition, so all timing decisions are
%% deterministic and unit-testable. Sent packets are tracked in a queue,
%% oldest at the front (an O(1) enqueue on send); on an ACK only the
%% packets at or below the largest acknowledged are resolved off the front
%% (acknowledged, lost, or a still-in-flight gap), while the higher-numbered
%% packets sent ahead stay in the queue untouched. This keeps ACK processing
%% O(packets-this-ack-resolves) rather than O(in flight), which matters for a
%% large response burst with no congestion window to bound the in-flight set.
%% The RTT is updated from the largest acknowledged ack-eliciting packet (RFC
%% 9002 §5) and loss is judged by the packet and time thresholds (§6.1). The
%% caller retransmits the data carried by the returned lost packets and feeds
%% the acknowledged/lost byte counts to congestion control.

-export([
    new/1,
    on_packet_sent/6,
    on_ack_received/3,
    detect_lost/2,
    loss_time/1,
    update_rtt/3,
    get_pto/1,
    on_pto_expired/1,
    smoothed_rtt/1,
    rtt_var/1,
    latest_rtt/1,
    min_rtt/1,
    has_rtt_sample/1,
    largest_acked/1,
    bytes_in_flight/1,
    pto_count/1
]).

-export_type([t/0, opts/0]).

%% RFC 9002 §6.1.1: a packet is lost if one numbered at least three higher
%% has been acknowledged.
-define(PACKET_THRESHOLD, 3).
%% RFC 9002 §6.1.2: the time threshold is 9/8 of the larger of the latest
%% and smoothed RTT (kept as integer arithmetic, matching trunc(1.125*x)).
-define(TIME_THRESHOLD_NUM, 9).
-define(TIME_THRESHOLD_DEN, 8).
%% RFC 9002 §6.1.2 kGranularity (1ms) and §6.2.2 kInitialRtt (333ms).
-define(GRANULARITY, 1).
-define(DEFAULT_INITIAL_RTT, 333).
%% RFC 9000 default max_ack_delay (§18.2), in milliseconds.
-define(DEFAULT_MAX_ACK_DELAY, 25).
%% RFC 9000 §18.2 default ack_delay_exponent: a peer's ACK Delay field is
%% carried in units of 2^exponent microseconds.
-define(DEFAULT_ACK_DELAY_EXPONENT, 3).
%% Bound the packet numbers expanded from one received ACK frame, so a
%% peer cannot make us materialise an enormous range (RFC 9000 §13.2.3).
-define(MAX_ACK_RANGE, 65536).

-record(sent, {
    pn :: non_neg_integer(),
    time_sent :: non_neg_integer(),
    ack_eliciting :: boolean(),
    size :: non_neg_integer(),
    data :: term()
}).

-record(loss, {
    %% Sent-but-not-resolved packets, a queue with the oldest (lowest packet
    %% number) at the front, so an ACK resolves them from the front and the
    %% higher-numbered in-flight packets stay as the shared remaining queue.
    sent = queue:new() :: queue:queue(#sent{}),
    %% RTT estimation (RFC 9002 §5).
    latest_rtt = 0 :: non_neg_integer(),
    smoothed_rtt :: non_neg_integer(),
    rtt_var :: non_neg_integer(),
    min_rtt = infinity :: non_neg_integer() | infinity,
    has_sample = false :: boolean(),
    %% Loss detection.
    largest_acked = undefined :: non_neg_integer() | undefined,
    %% Probe timeout (RFC 9002 §6.2).
    pto_count = 0 :: non_neg_integer(),
    %% Congestion-controlled bytes outstanding.
    bytes_in_flight = 0 :: non_neg_integer(),
    max_ack_delay :: non_neg_integer(),
    ack_delay_exponent :: non_neg_integer()
}).

-opaque t() :: #loss{}.

-type opts() :: #{
    initial_rtt => non_neg_integer(),
    max_ack_delay => non_neg_integer(),
    ack_delay_exponent => non_neg_integer()
}.

%% =============================================================================
%% State
%% =============================================================================

-doc """
A fresh loss-detection state. `initial_rtt` seeds the smoothed RTT until
the first sample (RFC 9002 §6.2.2, default 333ms); `max_ack_delay` and
`ack_delay_exponent` are the peer's advertised values (defaults 25ms and
3), the latter used to decode the ACK Delay field.
""".
-spec new(opts()) -> t().
new(Opts) ->
    InitialRtt = maps:get(initial_rtt, Opts, ?DEFAULT_INITIAL_RTT),
    #loss{
        smoothed_rtt = InitialRtt,
        rtt_var = InitialRtt div 2,
        max_ack_delay = maps:get(max_ack_delay, Opts, ?DEFAULT_MAX_ACK_DELAY),
        ack_delay_exponent = maps:get(ack_delay_exponent, Opts, ?DEFAULT_ACK_DELAY_EXPONENT)
    }.

%% =============================================================================
%% Packet tracking
%% =============================================================================

-doc """
Record a sent packet. `Data` is an opaque term the caller can retrieve
from the returned lost packets to retransmit. Ack-eliciting packets add
to the bytes in flight (RFC 9002 §2); the PTO count is deliberately not
reset here.
""".
-spec on_packet_sent(
    non_neg_integer(), non_neg_integer(), boolean(), term(), non_neg_integer(), t()
) ->
    t().
on_packet_sent(
    PN, Size, AckEliciting, Data, Now, #loss{sent = Sent, bytes_in_flight = InFlight} = Loss
) ->
    Packet = #sent{
        pn = PN, time_sent = Now, ack_eliciting = AckEliciting, size = Size, data = Data
    },
    Loss#loss{
        sent = queue:in(Packet, Sent),
        bytes_in_flight = InFlight + ack_eliciting_bytes(AckEliciting, Size)
    }.

%% =============================================================================
%% ACK processing
%% =============================================================================

-doc """
Process a received ACK frame (RFC 9002 §5-§6). Classifies the tracked
packets, updates the RTT from the largest acknowledged ack-eliciting
packet, detects losses among the rest, and returns the new state with the
acknowledged and lost packets' caller data (the lost data is what to
retransmit). `{error, ack_range_too_large}` rejects an ACK whose ranges
would expand past a sane bound.
""".
-spec on_ack_received(tuple(), non_neg_integer(), t()) ->
    {t(), Acked :: [term()], Lost :: [term()]} | {error, ack_range_too_large}.
on_ack_received(Ack, Now, Loss) ->
    {LargestAcked, AckDelay, FirstRange, AckRanges} = ack_fields(Ack),
    case ack_to_ranges(LargestAcked, FirstRange, AckRanges) of
        {error, _} = Error ->
            Error;
        Ranges ->
            NewLargest = max_largest_acked(Loss#loss.largest_acked, LargestAcked),
            %% Only packets at or below the largest acknowledged can be
            %% acknowledged or declared lost by this ACK; the higher-numbered
            %% packets sent ahead stay in flight. Resolving just that prefix off
            %% the front keeps the work O(packets-this-ack-resolves).
            {Resolvable, Ahead} = pop_resolvable(Loss#loss.sent, NewLargest, []),
            {Acked, Unacked} = classify(Resolvable, Ranges),
            Loss1 = maybe_update_rtt(Loss, LargestAcked, Acked, AckDelay, Now),
            {Lost, Survivors} = split_lost(Unacked, NewLargest, Now, loss_delay(Loss1)),
            AckedBytes = in_flight_bytes(Acked),
            LostBytes = in_flight_bytes(Lost),
            Loss2 = Loss1#loss{
                sent = requeue(Survivors, Ahead),
                largest_acked = NewLargest,
                pto_count = 0,
                bytes_in_flight = max(0, Loss1#loss.bytes_in_flight - AckedBytes - LostBytes)
            },
            {Loss2, datas(Acked), datas(Lost)}
    end.

%% =============================================================================
%% Loss detection
%% =============================================================================

-doc """
Re-run loss detection when the loss timer fires (RFC 9002 §6.1), without a
new ACK. Returns the new state and any packets now past the time
threshold; `{State, []}` when nothing is lost or nothing has been
acknowledged yet. The returned list is the lost packets' caller data, to
retransmit.
""".
-spec detect_lost(non_neg_integer(), t()) -> {t(), Lost :: [term()]}.
detect_lost(_Now, #loss{largest_acked = undefined} = Loss) ->
    {Loss, []};
detect_lost(Now, #loss{sent = Sent, largest_acked = LargestAcked} = Loss) ->
    %% The loss condition is monotonic from the oldest end (lowest number,
    %% earliest sent), so the lost packets are a front prefix: take them off
    %% and stop at the first survivor (the rest of the queue stays).
    {Lost, Survivors} = take_lost_front(Sent, LargestAcked, Now, loss_delay(Loss), []),
    Loss1 = Loss#loss{
        sent = Survivors,
        bytes_in_flight = max(0, Loss#loss.bytes_in_flight - in_flight_bytes(Lost))
    },
    {Loss1, datas(Lost)}.

-doc """
When the loss timer should next fire: the oldest sent packet's send time
plus the loss delay, or `undefined` if nothing is outstanding.
""".
-spec loss_time(t()) -> non_neg_integer() | undefined.
loss_time(#loss{sent = Sent} = Loss) ->
    case queue:peek(Sent) of
        empty -> undefined;
        {value, #sent{time_sent = Oldest}} -> Oldest + loss_delay(Loss)
    end.

%% =============================================================================
%% RTT estimation (RFC 9002 §5)
%% =============================================================================

-doc """
Fold a new RTT sample into the estimates (RFC 9002 §5.3). The first sample
seeds every estimate; later samples adjust for the peer's ACK delay
(capped at `max_ack_delay`) and update the smoothed RTT and its variance.
""".
-spec update_rtt(non_neg_integer(), non_neg_integer(), t()) -> t().
update_rtt(LatestRtt, _AckDelay, #loss{has_sample = false} = Loss) ->
    Loss#loss{
        latest_rtt = LatestRtt,
        smoothed_rtt = LatestRtt,
        rtt_var = LatestRtt div 2,
        min_rtt = LatestRtt,
        has_sample = true
    };
update_rtt(
    LatestRtt,
    AckDelay,
    #loss{smoothed_rtt = SRtt, rtt_var = RttVar, min_rtt = MinRtt, max_ack_delay = MaxAckDelay} =
        Loss
) ->
    NewMinRtt = min(MinRtt, LatestRtt),
    Adjusted =
        case LatestRtt > NewMinRtt + AckDelay of
            true -> LatestRtt - min(AckDelay, MaxAckDelay);
            false -> LatestRtt
        end,
    Loss#loss{
        latest_rtt = LatestRtt,
        min_rtt = NewMinRtt,
        rtt_var = (3 * RttVar + abs(SRtt - Adjusted)) div 4,
        smoothed_rtt = (7 * SRtt + Adjusted) div 8
    }.

%% =============================================================================
%% Probe timeout (RFC 9002 §6.2)
%% =============================================================================

-doc """
The probe timeout: `smoothed_rtt + max(4 * rtt_var, granularity) +
max_ack_delay`, doubled per consecutive PTO (RFC 9002 §6.2.1).
""".
-spec get_pto(t()) -> non_neg_integer().
get_pto(#loss{smoothed_rtt = SRtt, rtt_var = RttVar, max_ack_delay = MaxAckDelay, pto_count = Count}) ->
    Pto = SRtt + max(4 * RttVar, ?GRANULARITY) + MaxAckDelay,
    Pto bsl Count.

-doc "Record a PTO expiry, which doubles the next probe timeout.".
-spec on_pto_expired(t()) -> t().
on_pto_expired(#loss{pto_count = Count} = Loss) ->
    Loss#loss{pto_count = Count + 1}.

%% =============================================================================
%% Queries
%% =============================================================================

-doc "The smoothed RTT estimate (milliseconds).".
-spec smoothed_rtt(t()) -> non_neg_integer().
smoothed_rtt(#loss{smoothed_rtt = SRtt}) -> SRtt.

-doc "The RTT variance estimate (milliseconds).".
-spec rtt_var(t()) -> non_neg_integer().
rtt_var(#loss{rtt_var = RttVar}) -> RttVar.

-doc "The most recent RTT sample (milliseconds), `0` before the first sample.".
-spec latest_rtt(t()) -> non_neg_integer().
latest_rtt(#loss{latest_rtt = Latest}) -> Latest.

-doc "The minimum RTT observed, or `infinity` before the first sample.".
-spec min_rtt(t()) -> non_neg_integer() | infinity.
min_rtt(#loss{min_rtt = Min}) -> Min.

-doc "Whether at least one RTT sample has been taken.".
-spec has_rtt_sample(t()) -> boolean().
has_rtt_sample(#loss{has_sample = Has}) -> Has.

-doc "The largest packet number the peer has acknowledged, or `undefined`.".
-spec largest_acked(t()) -> non_neg_integer() | undefined.
largest_acked(#loss{largest_acked = Largest}) -> Largest.

-doc "The congestion-controlled bytes currently outstanding.".
-spec bytes_in_flight(t()) -> non_neg_integer().
bytes_in_flight(#loss{bytes_in_flight = InFlight}) -> InFlight.

-doc "The consecutive PTO count (RFC 9002 §6.2.1).".
-spec pto_count(t()) -> non_neg_integer().
pto_count(#loss{pto_count = Count}) -> Count.

%% =============================================================================
%% Internal
%% =============================================================================

%% The B2 ACK frame carries the same fields with or without ECN counts.
ack_fields({ack, LargestAcked, AckDelay, FirstRange, AckRanges, _Ecn}) ->
    {LargestAcked, AckDelay, FirstRange, AckRanges};
ack_fields({ack, LargestAcked, AckDelay, FirstRange, AckRanges}) ->
    {LargestAcked, AckDelay, FirstRange, AckRanges}.

ack_eliciting_bytes(true, Size) -> Size;
ack_eliciting_bytes(false, _Size) -> 0.

max_largest_acked(undefined, Largest) -> Largest;
max_largest_acked(Current, Largest) -> max(Current, Largest).

%% Body recursion (cons on the way out) preserves the newest-first order
%% in both output lists.
-spec classify([#sent{}], [{non_neg_integer(), non_neg_integer()}]) -> {[#sent{}], [#sent{}]}.
classify([], _Ranges) ->
    {[], []};
classify([#sent{pn = PN} = Packet | Rest], Ranges) ->
    {Acked, Unacked} = classify(Rest, Ranges),
    case pn_in_ranges(PN, Ranges) of
        true -> {[Packet | Acked], Unacked};
        false -> {Acked, [Packet | Unacked]}
    end.

%% Split the unacknowledged packets into newly lost and still-in-flight by
%% the packet threshold (a packet at least 3 below the largest acked) and
%% the time threshold (RFC 9002 §6.1). Survivors keep their newest-first
%% order for the next prepend.
-spec split_lost([#sent{}], non_neg_integer(), non_neg_integer(), non_neg_integer()) ->
    {[#sent{}], [#sent{}]}.
split_lost([], _LargestAcked, _Now, _LossDelay) ->
    {[], []};
split_lost([Packet | Rest], LargestAcked, Now, LossDelay) ->
    {Lost, Survivors} = split_lost(Rest, LargestAcked, Now, LossDelay),
    case lost_packet(Packet, LargestAcked, Now, LossDelay) of
        true -> {[Packet | Lost], Survivors};
        false -> {Lost, [Packet | Survivors]}
    end.

%% Whether a still-unacknowledged packet is lost (RFC 9002 §6.1): only packets
%% below the largest acknowledged are candidates (declaring loss requires a
%% later packet to have been acknowledged), then by the packet threshold (at
%% least three below the largest acked) or the time threshold.
-spec lost_packet(#sent{}, non_neg_integer(), non_neg_integer(), non_neg_integer()) -> boolean().
lost_packet(#sent{pn = PN, time_sent = Sent}, LargestAcked, Now, LossDelay) ->
    PN < LargestAcked andalso
        (PN =< LargestAcked - ?PACKET_THRESHOLD orelse Now - Sent > LossDelay).

%% Take the packets at or below `NewLargest` off the front (oldest first) into a
%% newest-first list, the candidates this ACK can resolve; the higher-numbered
%% in-flight packets stay in the returned queue. The queue is ordered by packet
%% number, so the candidates are exactly a front prefix.
-spec pop_resolvable(queue:queue(#sent{}), non_neg_integer(), [#sent{}]) ->
    {[#sent{}], queue:queue(#sent{})}.
pop_resolvable(Queue, NewLargest, Acc) ->
    case queue:peek(Queue) of
        {value, #sent{pn = PN} = Packet} when PN =< NewLargest ->
            {{value, Packet}, Rest} = queue:out(Queue),
            pop_resolvable(Rest, NewLargest, [Packet | Acc]);
        _ ->
            {Acc, Queue}
    end.

%% Take the lost packets off the front (oldest first), stopping at the first
%% survivor; `lost_packet/4` is monotonic from the front, so the lost packets
%% are a prefix and the rest of the queue stays in flight.
-spec take_lost_front(
    queue:queue(#sent{}), non_neg_integer(), non_neg_integer(), non_neg_integer(), [#sent{}]
) -> {[#sent{}], queue:queue(#sent{})}.
take_lost_front(Queue, LargestAcked, Now, LossDelay, Acc) ->
    case queue:peek(Queue) of
        {value, #sent{} = Packet} ->
            case lost_packet(Packet, LargestAcked, Now, LossDelay) of
                true ->
                    {{value, Packet}, Rest} = queue:out(Queue),
                    take_lost_front(Rest, LargestAcked, Now, LossDelay, [Packet | Acc]);
                false ->
                    {Acc, Queue}
            end;
        empty ->
            {Acc, Queue}
    end.

%% Put the still-in-flight gap survivors (newest-first, all numbered below the
%% queue's front) back onto the front, restoring the by-packet-number order.
-spec requeue([#sent{}], queue:queue(#sent{})) -> queue:queue(#sent{}).
requeue(Survivors, Queue) ->
    lists:foldl(fun queue:in_r/2, Queue, Survivors).

%% RFC 9002 §6.1.2: max(time_threshold * max(latest, smoothed), granularity).
loss_delay(#loss{latest_rtt = Latest, smoothed_rtt = SRtt}) ->
    Rtt = max(Latest, SRtt),
    max(?TIME_THRESHOLD_NUM * Rtt div ?TIME_THRESHOLD_DEN, ?GRANULARITY).

%% Update the RTT from the largest acknowledged packet when it is
%% ack-eliciting (RFC 9002 §5.1); ignore the ACK otherwise. The ACK Delay
%% field is decoded from its 2^exponent-microsecond units to milliseconds
%% (RFC 9000 §19.3) before it reaches the millisecond RTT estimator.
maybe_update_rtt(#loss{ack_delay_exponent = Exp} = Loss, LargestAcked, Acked, AckDelay, Now) ->
    case lists:keyfind(LargestAcked, #sent.pn, Acked) of
        #sent{ack_eliciting = true, time_sent = Sent} ->
            update_rtt(Now - Sent, (AckDelay bsl Exp) div 1000, Loss);
        _ ->
            Loss
    end.

-spec in_flight_bytes([#sent{}]) -> non_neg_integer().
in_flight_bytes(Packets) ->
    lists:sum([Size || #sent{ack_eliciting = true, size = Size} <- Packets]).

%% The caller-supplied data of each packet, in order.
-spec datas([#sent{}]) -> [term()].
datas(Packets) ->
    [Data || #sent{data = Data} <- Packets].

%% Expand an ACK frame's largest/first-range/gap-range fields into the
%% acknowledged {Start, End} ranges (RFC 9000 §19.3), rejecting a range
%% that would materialise more than ?MAX_ACK_RANGE packet numbers.
-spec ack_to_ranges(non_neg_integer(), non_neg_integer(), [{non_neg_integer(), non_neg_integer()}]) ->
    [{non_neg_integer(), non_neg_integer()}] | {error, ack_range_too_large}.
ack_to_ranges(LargestAcked, FirstRange, AckRanges) when FirstRange =< ?MAX_ACK_RANGE ->
    Start = LargestAcked - FirstRange,
    case gap_ranges(Start, AckRanges) of
        {error, _} = Error -> Error;
        Rest -> [{Start, LargestAcked} | Rest]
    end;
ack_to_ranges(_LargestAcked, _FirstRange, _AckRanges) ->
    {error, ack_range_too_large}.

gap_ranges(_PrevStart, []) ->
    [];
gap_ranges(PrevStart, [{Gap, Range} | Rest]) when Range =< ?MAX_ACK_RANGE ->
    End = PrevStart - Gap - 2,
    Start = End - Range,
    case gap_ranges(Start, Rest) of
        {error, _} = Error -> Error;
        Tail -> [{Start, End} | Tail]
    end;
gap_ranges(_PrevStart, _Ranges) ->
    {error, ack_range_too_large}.

pn_in_ranges(_PN, []) ->
    false;
pn_in_ranges(PN, [{Start, End} | _]) when PN >= Start, PN =< End ->
    true;
pn_in_ranges(PN, [_ | Rest]) ->
    pn_in_ranges(PN, Rest).
