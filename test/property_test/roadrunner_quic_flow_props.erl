-module(roadrunner_quic_flow_props).
-moduledoc """
Property-based tests for `roadrunner_quic_flow`.

Differential invariant over a random sequence of send / receive /
MAX_DATA / grant operations: every observable, the send and receive
windows, the byte counts, the blocked flag, the should-grant decision,
the granted value, and the flow-control-error result, stays identical to
the `quic` dep (the oracle).
""".

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct_property_test.hrl").

prop_matches_dep() ->
    ?FORALL(
        {Initial, Peer, Ops},
        {integer(1, 2000), integer(1, 2000), list(op())},
        begin
            Opts = #{initial_max_data => Initial, peer_initial_max_data => Peer},
            run(Ops, roadrunner_quic_flow:new(Opts), quic_flow:new(Opts))
        end
    ).

run([], Rr, Dep) ->
    states_match(Rr, Dep);
run([Op | Rest], Rr, Dep) ->
    case apply_both(Op, Rr, Dep) of
        mismatch -> false;
        {Rr1, Dep1} -> states_match(Rr1, Dep1) andalso run(Rest, Rr1, Dep1)
    end.

apply_both({send, Size}, Rr, Dep) ->
    {RrTag, Rr1} = roadrunner_quic_flow:on_data_sent(Size, Rr),
    {DepTag, Dep1} = quic_flow:on_data_sent(Dep, Size),
    same(RrTag =:= DepTag, Rr1, Dep1);
apply_both({recv, Size}, Rr, Dep) ->
    case {roadrunner_quic_flow:on_data_received(Size, Rr), quic_flow:on_data_received(Dep, Size)} of
        {{ok, Rr1}, {ok, Dep1}} -> {Rr1, Dep1};
        {{error, flow_control_error}, {error, flow_control_error}} -> {Rr, Dep};
        _ -> mismatch
    end;
apply_both({max_data, NewMax}, Rr, Dep) ->
    {roadrunner_quic_flow:on_max_data_received(NewMax, Rr), quic_flow:on_max_data_received(Dep, NewMax)};
apply_both(grant, Rr, Dep) ->
    {RrMax, Rr1} = roadrunner_quic_flow:grant_max_data(Rr),
    {DepMax, Dep1} = quic_flow:generate_max_data(Dep),
    same(RrMax =:= DepMax, Rr1, Dep1).

same(true, Rr, Dep) -> {Rr, Dep};
same(false, _Rr, _Dep) -> mismatch.

states_match(Rr, Dep) ->
    roadrunner_quic_flow:send_window(Rr) =:= quic_flow:send_window(Dep) andalso
        roadrunner_quic_flow:recv_window(Rr) =:= quic_flow:recv_window(Dep) andalso
        roadrunner_quic_flow:bytes_sent(Rr) =:= quic_flow:bytes_sent(Dep) andalso
        roadrunner_quic_flow:bytes_received(Rr) =:= quic_flow:bytes_received(Dep) andalso
        roadrunner_quic_flow:send_blocked(Rr) =:= quic_flow:send_blocked(Dep) andalso
        roadrunner_quic_flow:should_send_max_data(Rr) =:= quic_flow:should_send_max_data(Dep).

op() ->
    oneof([
        {send, integer(0, 2000)},
        {recv, integer(0, 2000)},
        {max_data, integer(0, 5000)},
        grant
    ]).
