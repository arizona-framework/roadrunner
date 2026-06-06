-module(roadrunner_quic_cc_newreno_props).
-moduledoc """
Property-based tests for `roadrunner_quic_cc_newreno`.

Over a random sequence of acknowledgements and congestion events, driven
by a monotonic clock so each event lands after the previous one (so a
congestion event is a genuine reduction, not a deduplicated no-op): the
congestion window never drops below the minimum (2 * max_datagram_size,
RFC 9002 §7.2), an acknowledgement never shrinks it, and a congestion
event never grows it.
""".

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct_property_test.hrl").

%% RFC 9002 §7.2 minimum window for a 1200-byte datagram.
-define(MINIMUM_WINDOW, 2400).

prop_cwnd_never_below_minimum() ->
    ?FORALL(
        Ops,
        list(op()),
        check(Ops, 0, roadrunner_quic_cc_newreno:new())
    ).

%% A monotonic clock (one tick per op) drives every event "now", so a
%% congestion event always sees SentTime past the prior recovery start and
%% genuinely halves the window, exercising the floor under repeated loss.
check([], _Clock, _Cc) ->
    true;
check([Op | Rest], Clock, Cc) ->
    Before = roadrunner_quic_cc_newreno:cwnd(Cc),
    Next = apply_op(Op, Clock, Cc),
    After = roadrunner_quic_cc_newreno:cwnd(Next),
    After >= ?MINIMUM_WINDOW andalso direction_ok(Op, Before, After) andalso
        check(Rest, Clock + 1, Next).

direction_ok({acked, _}, Before, After) -> After >= Before;
direction_ok(congestion, Before, After) -> After =< Before.

op() ->
    oneof([{acked, integer(0, 5000)}, congestion]).

apply_op({acked, AckedBytes}, Clock, Cc) ->
    roadrunner_quic_cc_newreno:on_packets_acked(AckedBytes, Clock, Cc);
apply_op(congestion, Clock, Cc) ->
    roadrunner_quic_cc_newreno:on_congestion_event(Clock, Clock, Cc).
