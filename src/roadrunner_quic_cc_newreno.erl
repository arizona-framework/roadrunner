-module(roadrunner_quic_cc_newreno).
-moduledoc false.

%% NewReno congestion control (RFC 9002 §7), pure.
%%
%% Tracks the congestion window and slow-start threshold for one
%% connection and decides how much may be in flight. In slow start
%% (`cwnd < ssthresh`) the window grows by the acknowledged bytes; in
%% congestion avoidance it grows by about one maximum datagram per window.
%% A loss starts a congestion recovery period: the window halves (floored
%% at the minimum) and further losses from packets sent during that period
%% are ignored, so one round trip of loss reduces the window once
%% (§7.3.2). The clock is passed in, so every decision is deterministic.
%%
%% The bytes in flight live in `roadrunner_quic_loss`; `can_send/2` takes
%% that count rather than tracking a second copy.

-export([
    new/0,
    on_packets_acked/3,
    on_congestion_event/3,
    can_send/2,
    cwnd/1,
    ssthresh/1,
    in_slow_start/1
]).

-export_type([t/0]).

%% RFC 9000 §14: the QUIC v1 fixed datagram size this server uses.
-define(MAX_DATAGRAM_SIZE, 1200).
%% RFC 9002 §7.2 initial window: min(10*MSS, max(2*MSS, 14720)) = 12000.
-define(INITIAL_WINDOW, 12000).
%% RFC 9002 §7.2 minimum window: 2 * MSS.
-define(MINIMUM_WINDOW, 2400).

-record(cc, {
    cwnd = ?INITIAL_WINDOW :: non_neg_integer(),
    ssthresh = infinity :: non_neg_integer() | infinity,
    %% Time of the latest congestion event; a packet sent at or before it
    %% is "in recovery" (RFC 9002 §7.3.2).
    recovery_start = undefined :: non_neg_integer() | undefined
}).

-opaque t() :: #cc{}.

-doc "A fresh congestion-control state: the RFC 9002 §7.2 initial window, no threshold yet.".
-spec new() -> t().
new() ->
    #cc{}.

-doc """
Grow the window for acknowledged bytes (RFC 9002 §7.3.1).
`LargestAckedSentTime` is the send time of the largest acknowledged
packet: while it falls within the current recovery period the window is
held, otherwise it grows by the acknowledged bytes in slow start or by
about one datagram per window in congestion avoidance.
""".
-spec on_packets_acked(non_neg_integer(), non_neg_integer(), t()) -> t().
on_packets_acked(_AckedBytes, LargestAckedSentTime, #cc{recovery_start = Start} = Cc) when
    Start =/= undefined, LargestAckedSentTime =< Start
->
    Cc;
on_packets_acked(AckedBytes, _LargestAckedSentTime, #cc{cwnd = Cwnd, ssthresh = SsThresh} = Cc) ->
    NewCwnd =
        case Cwnd < SsThresh of
            true -> Cwnd + AckedBytes;
            false -> Cwnd + ?MAX_DATAGRAM_SIZE * AckedBytes div Cwnd
        end,
    Cc#cc{cwnd = NewCwnd}.

-doc """
Enter congestion recovery for a lost packet sent at `SentTime` (RFC 9002
§7.3.2): if it was sent after the current recovery period started, halve
the window (floored at the minimum) and begin a new recovery period at
`Now`. A loss from a packet already within the period is ignored.
""".
-spec on_congestion_event(non_neg_integer(), non_neg_integer(), t()) -> t().
on_congestion_event(SentTime, Now, #cc{cwnd = Cwnd, recovery_start = Start} = Cc) when
    Start =:= undefined; SentTime > Start
->
    SsThresh = Cwnd div 2,
    Cc#cc{ssthresh = SsThresh, cwnd = max(SsThresh, ?MINIMUM_WINDOW), recovery_start = Now};
on_congestion_event(_SentTime, _Now, Cc) ->
    Cc.

-doc "Whether more bytes may be sent: the bytes in flight are below the window.".
-spec can_send(non_neg_integer(), t()) -> boolean().
can_send(BytesInFlight, #cc{cwnd = Cwnd}) ->
    BytesInFlight < Cwnd.

-doc "The congestion window in bytes.".
-spec cwnd(t()) -> non_neg_integer().
cwnd(#cc{cwnd = Cwnd}) ->
    Cwnd.

-doc "The slow-start threshold in bytes, or `infinity` before the first loss.".
-spec ssthresh(t()) -> non_neg_integer() | infinity.
ssthresh(#cc{ssthresh = SsThresh}) ->
    SsThresh.

-doc "Whether the window is still in slow start (below the threshold).".
-spec in_slow_start(t()) -> boolean().
in_slow_start(#cc{cwnd = Cwnd, ssthresh = SsThresh}) ->
    Cwnd < SsThresh.
