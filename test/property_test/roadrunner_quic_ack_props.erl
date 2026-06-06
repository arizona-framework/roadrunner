-module(roadrunner_quic_ack_props).
-moduledoc """
Property-based tests for `roadrunner_quic_ack`.

Differential invariant over a random sequence of (packet number,
ack-eliciting) receptions: the coalesced ranges, the largest received,
the pending-ACK flag, and the generated ACK frame range fields all match
the `quic` dep (the oracle).
""".

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct_property_test.hrl").

prop_matches_dep() ->
    ?FORALL(
        Events,
        %% A dense packet-number domain so a random sequence routinely
        %% produces adjacent, duplicate, and gap-bridging numbers, which is
        %% where the coalescing and gap/range encoding could go wrong.
        list({integer(0, 30), boolean()}),
        begin
            Rr = lists:foldl(fun record_rr/2, roadrunner_quic_ack:new(), Events),
            Dep = lists:foldl(fun record_dep/2, quic_ack:new(), Events),
            roadrunner_quic_ack:ranges(Rr) =:= quic_ack:ack_ranges(Dep) andalso
                roadrunner_quic_ack:largest(Rr) =:= quic_ack:largest_received(Dep) andalso
                roadrunner_quic_ack:needs_ack(Rr) =:= quic_ack:needs_ack(Dep) andalso
                to_ack_matches(Rr, Dep)
        end
    ).

record_rr({PN, Eliciting}, Acc) -> roadrunner_quic_ack:record(PN, Eliciting, Acc).

record_dep({PN, Eliciting}, Acc) -> quic_ack:record_received(Acc, PN, Eliciting).

%% The dep's generate_ack also carries an ACK delay (a timing value); only
%% the range fields are compared here.
to_ack_matches(Rr, Dep) ->
    case quic_ack:generate_ack(Dep) of
        {error, no_packets} ->
            roadrunner_quic_ack:to_ack(Rr) =:= none;
        {ok, {ack, Largest, _AckDelay, FirstRange, AckRanges}} ->
            roadrunner_quic_ack:to_ack(Rr) =:= {Largest, FirstRange, AckRanges}
    end.
