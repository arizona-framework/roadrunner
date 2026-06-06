-module(roadrunner_quic_amp_props).
-moduledoc """
Property-based tests for `roadrunner_quic_amp`.

Over a random interleaving of received/sent/validate operations, the
remaining budget is never negative, and `can_send/2` agrees with
`budget/1` at every size (including the `infinity` case once the address
is validated).
""".

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct_property_test.hrl").

prop_invariants() ->
    ?FORALL(
        Ops,
        list(op()),
        begin
            Amp = lists:foldl(fun apply_op/2, roadrunner_quic_amp:new(), Ops),
            Budget = roadrunner_quic_amp:budget(Amp),
            budget_ok(Budget) andalso can_send_agrees(Amp, Budget)
        end
    ).

budget_ok(infinity) -> true;
budget_ok(Budget) -> Budget >= 0.

can_send_agrees(Amp, Budget) ->
    lists:all(
        fun(N) ->
            roadrunner_quic_amp:can_send(N, Amp) =:= fits(N, Budget)
        end,
        [0, 1, 100, 1200, 1 bsl 20]
    ).

fits(_N, infinity) -> true;
fits(N, Budget) -> N =< Budget.

op() ->
    oneof([{received, integer(0, 5000)}, {sent, integer(0, 5000)}, validate]).

apply_op({received, N}, Amp) -> roadrunner_quic_amp:received(N, Amp);
apply_op({sent, N}, Amp) -> roadrunner_quic_amp:sent(N, Amp);
apply_op(validate, Amp) -> roadrunner_quic_amp:validate(Amp).
