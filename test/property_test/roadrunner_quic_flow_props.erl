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

%% =============================================================================
%% RFC 9000 §4 invariants (independent of the dep oracle).
%% =============================================================================

prop_invariants() ->
    ?FORALL(
        {Initial, Peer, Ops},
        {integer(1, 2000), integer(1, 2000), list(op())},
        begin
            Opts = #{initial_max_data => Initial, peer_initial_max_data => Peer},
            %% RFC 9000 §4.1 refill fraction, matching roadrunner_quic_flow (3/4).
            Refill = Initial * 3 div 4,
            check(Ops, roadrunner_quic_flow:new(Opts), Initial, Refill)
        end
    ).

check([], _Flow, _Initial, _Refill) ->
    true;
check([Op | Rest], Flow, Initial, Refill) ->
    case step(Op, Flow, Initial) of
        {ok, Flow1} -> global_invariants(Flow1, Refill) andalso check(Rest, Flow1, Initial, Refill);
        false -> false
    end.

%% §4.1: a new MAX_DATA is due exactly once the remaining receive window
%% falls below the refill threshold; both windows are always non-negative.
global_invariants(Flow, Refill) ->
    roadrunner_quic_flow:send_window(Flow) >= 0 andalso
        roadrunner_quic_flow:recv_window(Flow) >= 0 andalso
        roadrunner_quic_flow:should_send_max_data(Flow) =:=
            (roadrunner_quic_flow:recv_window(Flow) < Refill).

step({send, Size}, Flow, _Initial) ->
    %% A permitted send stays within the advertised window (the converse
    %% can fail at the over-limit edge, so only this direction is asserted).
    WithinWindow =
        (not roadrunner_quic_flow:can_send(Size, Flow)) orelse
            Size =< roadrunner_quic_flow:send_window(Flow),
    {Tag, Flow1} = roadrunner_quic_flow:on_data_sent(Size, Flow),
    ok_if(
        WithinWindow andalso
            roadrunner_quic_flow:bytes_sent(Flow1) =:=
                roadrunner_quic_flow:bytes_sent(Flow) + Size andalso
            (Tag =:= blocked) =:= roadrunner_quic_flow:send_blocked(Flow1) andalso
            blocked_implies_no_window(Flow1),
        Flow1
    );
step({recv, Size}, Flow, _Initial) ->
    %% §4.1: an overrun of the advertised limit is rejected, nothing else is.
    Exceeds = Size > roadrunner_quic_flow:recv_window(Flow),
    case roadrunner_quic_flow:on_data_received(Size, Flow) of
        {error, flow_control_error} ->
            ok_if(Exceeds, Flow);
        {ok, Flow1} ->
            ok_if(
                (not Exceeds) andalso
                    roadrunner_quic_flow:bytes_received(Flow1) =:=
                        roadrunner_quic_flow:bytes_received(Flow) + Size,
                Flow1
            )
    end;
step({max_data, NewMax}, Flow, _Initial) ->
    %% Limits only increase, so the send window never shrinks.
    Flow1 = roadrunner_quic_flow:on_max_data_received(NewMax, Flow),
    ok_if(
        roadrunner_quic_flow:send_window(Flow1) >= roadrunner_quic_flow:send_window(Flow),
        Flow1
    );
step(grant, Flow, Initial) ->
    %% A grant restores a full initial-sized window above what is consumed.
    {NewMax, Flow1} = roadrunner_quic_flow:grant_max_data(Flow),
    ok_if(
        roadrunner_quic_flow:recv_window(Flow1) =:= Initial andalso
            NewMax >= roadrunner_quic_flow:bytes_received(Flow1),
        Flow1
    ).

blocked_implies_no_window(Flow) ->
    case roadrunner_quic_flow:send_blocked(Flow) of
        true -> roadrunner_quic_flow:send_window(Flow) =:= 0;
        false -> true
    end.

ok_if(true, Flow) -> {ok, Flow};
ok_if(false, _Flow) -> false.
