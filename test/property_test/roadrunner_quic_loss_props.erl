-module(roadrunner_quic_loss_props).
-moduledoc """
Property-based tests for `roadrunner_quic_loss`.

RFC 9002 invariants asserted straight from the spec:

- over a random sequence of RTT samples, the §5.2 first-sample seeding,
  the latest sample recorded as-is, a non-increasing minimum, and the
  §6.2 probe timeout with its §6.2.1 exponential backoff; and
- over a random send-then-acknowledge cycle (the ACK built from a random
  acknowledged set via `roadrunner_quic_ack`), the §6.1 loss
  classification, §2 bytes in flight, and §6.2.1 PTO-count reset on ACK.
""".

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct_property_test.hrl").

%% =============================================================================
%% RFC 9002 invariants.
%% =============================================================================

apply_pto(0, State, _Expire) -> State;
apply_pto(N, State, Expire) -> apply_pto(N - 1, Expire(State), Expire).

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

%% RFC 9002 §5 (RTT estimation) + §6.2 (PTO and its exponential backoff),
%% asserted straight from the spec.
prop_rtt_and_pto_invariants() ->
    ?FORALL(
        {InitialRtt, MaxAckDelay, Samples, PtoCount},
        {integer(1, 1000), integer(0, 100), list({integer(1, 500), integer(0, 100)}),
            integer(0, 8)},
        begin
            S0 = roadrunner_quic_loss:new(#{
                initial_rtt => InitialRtt, max_ack_delay => MaxAckDelay
            }),
            {Sn, RttOk} = lists:foldl(fun rtt_step/2, {S0, true}, Samples),
            BasePto = roadrunner_quic_loss:get_pto(Sn),
            SnPto = apply_pto(PtoCount, Sn, fun roadrunner_quic_loss:on_pto_expired/1),
            RttOk andalso
                %% §6.2: the PTO is at least the smoothed RTT plus the peer's max ACK delay.
                BasePto >= roadrunner_quic_loss:smoothed_rtt(Sn) + MaxAckDelay andalso
                %% §6.2.1: each consecutive PTO doubles the timeout.
                roadrunner_quic_loss:get_pto(roadrunner_quic_loss:on_pto_expired(Sn)) =:=
                    2 * BasePto andalso
                roadrunner_quic_loss:get_pto(SnPto) =:= BasePto bsl PtoCount
        end
    ).

%% One folded RTT sample: the §5.2 first-sample seeding, the latest sample
%% recorded as-is, the minimum never rising, and the smoothed estimate
%% staying at or above that minimum.
rtt_step({Latest, AckDelay}, {S, Ok}) ->
    HadSample = roadrunner_quic_loss:has_rtt_sample(S),
    MinBefore = roadrunner_quic_loss:min_rtt(S),
    S1 = roadrunner_quic_loss:update_rtt(Latest, AckDelay, S),
    StepOk =
        roadrunner_quic_loss:latest_rtt(S1) =:= Latest andalso
            roadrunner_quic_loss:has_rtt_sample(S1) andalso
            min_not_increased(MinBefore, roadrunner_quic_loss:min_rtt(S1)) andalso
            first_sample_seeded(HadSample, S1, Latest) andalso
            roadrunner_quic_loss:smoothed_rtt(S1) >= roadrunner_quic_loss:min_rtt(S1),
    {S1, Ok andalso StepOk}.

min_not_increased(infinity, _After) -> true;
min_not_increased(Before, After) -> After =< Before.

first_sample_seeded(false, S1, Latest) ->
    roadrunner_quic_loss:smoothed_rtt(S1) =:= Latest andalso
        roadrunner_quic_loss:rtt_var(S1) =:= Latest div 2 andalso
        roadrunner_quic_loss:min_rtt(S1) =:= Latest;
first_sample_seeded(true, _S1, _Latest) ->
    true.

%% RFC 9002 §6.1 (loss detection), §6.2.1 (PTO reset on ACK), and §2 (bytes
%% in flight), asserted from the spec over a send-then-acknowledge cycle.
prop_loss_classification_invariants() ->
    ?FORALL(
        {Eliciting, AckedSet, AckDelay, Now, PtoBefore},
        {non_empty(list(boolean())), list(integer(0, 19)), integer(0, 5000),
            integer(0, 2000), integer(0, 5)},
        begin
            Opts = #{initial_rtt => 100, max_ack_delay => 25},
            NumPackets = length(Eliciting),
            Sent = lists:zip(lists:seq(0, NumPackets - 1), Eliciting),
            Ssent = lists:foldl(
                fun({PN, AckEliciting}, S) ->
                    roadrunner_quic_loss:on_packet_sent(PN, 100, AckEliciting, PN, PN, S)
                end,
                roadrunner_quic_loss:new(Opts),
                Sent
            ),
            InFlightOk =
                roadrunner_quic_loss:bytes_in_flight(Ssent) =:=
                    100 * length([E || E <- Eliciting, E]),
            Sready = apply_pto(PtoBefore, Ssent, fun roadrunner_quic_loss:on_pto_expired/1),
            Acked = lists:usort([PN || PN <- AckedSet, PN < NumPackets]),
            case build_ack(Acked) of
                none ->
                    InFlightOk;
                {Largest, FirstRange, AckRanges} ->
                    Ack = {ack, Largest, AckDelay, FirstRange, AckRanges},
                    {S1, AckedData, LostData} =
                        roadrunner_quic_loss:on_ack_received(Ack, Now, Sready),
                    InFlightOk andalso
                        %% §6.1: the acknowledged packets are exactly the sent ones in the ACK.
                        lists:sort(AckedData) =:= Acked andalso
                        disjoint(AckedData, LostData) andalso
                        %% §6.1: a packet is lost only once a higher-numbered one is acked.
                        lists:all(fun(PN) -> PN < Largest end, LostData) andalso
                        roadrunner_quic_loss:bytes_in_flight(S1) >= 0 andalso
                        %% §6.2.1: a received ACK resets the PTO count.
                        roadrunner_quic_loss:pto_count(S1) =:= 0
            end
        end
    ).

disjoint(As, Bs) ->
    [] =:= [A || A <- As, lists:member(A, Bs)].
