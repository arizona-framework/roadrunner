-module(roadrunner_quic_loss_props).
-moduledoc """
Property-based tests for `roadrunner_quic_loss`.

Two differential invariants against the `quic` dep (the oracle):

- over a random sequence of RTT samples, the smoothed/variance/min/latest
  estimates and the probe timeout (with backoff) match; and
- over a random send-then-acknowledge cycle (the ACK built from a random
  acknowledged set via `roadrunner_quic_ack`), the acknowledged and lost
  packet sets, the bytes in flight, and the smoothed RTT match.
""".

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct_property_test.hrl").

%% =============================================================================
%% RTT estimation + PTO.
%% =============================================================================

prop_rtt_matches_dep() ->
    ?FORALL(
        {InitialRtt, MaxAckDelay, Samples, PtoCount},
        {integer(1, 1000), integer(0, 100), list({integer(1, 500), integer(0, 100)}), integer(0, 8)},
        begin
            Opts = #{initial_rtt => InitialRtt, max_ack_delay => MaxAckDelay},
            {Rr, Dep} = lists:foldl(
                fun({Latest, AckDelay}, {R, D}) ->
                    {roadrunner_quic_loss:update_rtt(Latest, AckDelay, R),
                        quic_loss:update_rtt(D, Latest, AckDelay)}
                end,
                {roadrunner_quic_loss:new(Opts), quic_loss:new(Opts)},
                Samples
            ),
            RrPto = apply_pto(PtoCount, Rr, fun roadrunner_quic_loss:on_pto_expired/1),
            DepPto = apply_pto(PtoCount, Dep, fun quic_loss:on_pto_expired/1),
            roadrunner_quic_loss:smoothed_rtt(Rr) =:= quic_loss:smoothed_rtt(Dep) andalso
                roadrunner_quic_loss:rtt_var(Rr) =:= quic_loss:rtt_var(Dep) andalso
                roadrunner_quic_loss:min_rtt(Rr) =:= quic_loss:min_rtt(Dep) andalso
                roadrunner_quic_loss:latest_rtt(Rr) =:= quic_loss:latest_rtt(Dep) andalso
                roadrunner_quic_loss:get_pto(RrPto) =:= quic_loss:get_pto(DepPto)
        end
    ).

apply_pto(0, State, _Expire) -> State;
apply_pto(N, State, Expire) -> apply_pto(N - 1, Expire(State), Expire).

%% =============================================================================
%% Send + acknowledge cycle.
%% =============================================================================

prop_loss_matches_dep() ->
    ?FORALL(
        {Eliciting, AckedSet, AckDelay, Now},
        {non_empty(list(boolean())), list(integer(0, 19)), integer(0, 5000), integer(0, 2000)},
        begin
            Opts = #{initial_rtt => 100, max_ack_delay => 25},
            NumPackets = length(Eliciting),
            Sent = lists:zip(lists:seq(0, NumPackets - 1), Eliciting),
            {RrSent, DepSent} = lists:foldl(
                fun({PN, AckEliciting}, {R, D}) ->
                    {roadrunner_quic_loss:on_packet_sent(PN, 100, AckEliciting, PN, PN, R),
                        quic_loss:on_packet_sent(D, PN, 100, AckEliciting, PN, PN)}
                end,
                {roadrunner_quic_loss:new(Opts), quic_loss:new(Opts)},
                Sent
            ),
            Acked = lists:usort([PN || PN <- AckedSet, PN < NumPackets]),
            case build_ack(Acked) of
                none ->
                    true;
                {Largest, FirstRange, AckRanges} ->
                    Ack = {ack, Largest, AckDelay, FirstRange, AckRanges},
                    {RrState, RrAcked, RrLost} = roadrunner_quic_loss:on_ack_received(Ack, Now, RrSent),
                    {DepState, DepAckedL, DepLostL, _Meta} = quic_loss:on_ack_received(
                        DepSent, Ack, Now
                    ),
                    lists:sort(RrAcked) =:= lists:sort(pns(DepAckedL)) andalso
                        lists:sort(RrLost) =:= lists:sort(pns(DepLostL)) andalso
                        roadrunner_quic_loss:bytes_in_flight(RrState) =:=
                            quic_loss:bytes_in_flight(DepState) andalso
                        roadrunner_quic_loss:smoothed_rtt(RrState) =:=
                            quic_loss:smoothed_rtt(DepState)
            end
        end
    ).

%% Build a valid ACK frame's range fields from a set of acknowledged
%% packet numbers, reusing the receive-side ACK generator.
build_ack([]) ->
    none;
build_ack(PNs) ->
    Ack = lists:foldl(
        fun(PN, Acc) -> roadrunner_quic_ack:record(PN, true, Acc) end,
        roadrunner_quic_ack:new(),
        PNs
    ),
    roadrunner_quic_ack:to_ack(Ack).

%% The dep stores each sent packet as a record whose first field is the
%% packet number.
pns(SentPackets) ->
    [element(2, P) || P <- SentPackets].
