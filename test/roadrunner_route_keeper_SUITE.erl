-module(roadrunner_route_keeper_SUITE).
-moduledoc """
`roadrunner_route_keeper` on its own: the slots of one route, handed out
by its keeper to holder processes, with this suite standing in for the
listener that owns the table and restarts the keeper.
""".

-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([
    shed_grants_up_to_the_ceiling/1,
    shed_full_route_refuses_without_the_keeper/1,
    queue_grants_in_arrival_order/1,
    queue_refuses_after_its_timeout/1,
    queue_full_refuses_at_once/1,
    queue_full_refuses_without_the_keeper/1,
    killed_holder_frees_its_slot/1,
    dead_waiter_leaves_the_queue/1,
    reset_stops_the_wait/1,
    reset_after_a_grant_frees_the_slot/1,
    reset_waiter_times_out/1,
    raised_ceiling_serves_the_queue/1,
    lowered_ceiling_holds_new_requests/1,
    draining_keeper_reports_when_empty/1,
    keeper_crash_keeps_the_holders/1,
    keeper_crash_refuses_the_waiters/1,
    keeper_gone_before_its_answer_frees_the_row/1,
    gone_table_refuses_and_releases/1,
    unknown_messages_are_ignored/1
]).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        shed_grants_up_to_the_ceiling,
        shed_full_route_refuses_without_the_keeper,
        queue_grants_in_arrival_order,
        queue_refuses_after_its_timeout,
        queue_full_refuses_at_once,
        queue_full_refuses_without_the_keeper,
        killed_holder_frees_its_slot,
        dead_waiter_leaves_the_queue,
        reset_stops_the_wait,
        reset_after_a_grant_frees_the_slot,
        reset_waiter_times_out,
        raised_ceiling_serves_the_queue,
        lowered_ceiling_holds_new_requests,
        draining_keeper_reports_when_empty,
        keeper_crash_keeps_the_holders,
        keeper_crash_refuses_the_waiters,
        keeper_gone_before_its_answer_frees_the_row,
        gone_table_refuses_and_releases,
        unknown_messages_are_ignored
    ].

init_per_suite(Config) ->
    {ok, _} = roadrunner_test_event_handler:start(),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_Case, Config) ->
    %% This process is the listener: the keeper is linked to it.
    process_flag(trap_exit, true),
    Config.

end_per_testcase(_Case, _Config) ->
    ok.

%% --- shed ---

shed_grants_up_to_the_ceiling(_Config) ->
    {Keeper, C} = route(2, shed),
    A = holder(C),
    B = holder(C),
    {ok, _} = result(A),
    {ok, _} = result(B),
    Refused = holder(C),
    ?assertEqual({refused, 3}, result(Refused)),
    ?assertMatch(
        #{in_flight := 2, queued := 0, throttled := 1, max_concurrent_requests := 2}, stats(C)
    ),
    %% A release lets the next one in.
    ok = release(A),
    {ok, _} = result(holder(C)),
    ?assertMatch(#{in_flight := 2}, stats(C)),
    ok = stop_keeper(Keeper).

shed_full_route_refuses_without_the_keeper(_Config) ->
    %% A full shed route turns a request away from the table's size alone:
    %% with the keeper suspended, the refusal still comes back.
    {Keeper, C} = route(1, shed),
    {ok, _} = result(holder(C)),
    ok = sys:suspend(Keeper),
    ?assertEqual({refused, 3}, roadrunner_route_keeper:acquire(C)),
    ok = sys:resume(Keeper),
    ok = stop_keeper(Keeper).

%% --- queue ---

queue_grants_in_arrival_order(_Config) ->
    {Keeper, C} = route(1, {queue, 5000, 10}),
    First = holder(C),
    {ok, _} = result(First),
    Waiters = [parked(Keeper, C) || _ <- lists:seq(1, 4)],
    ?assertMatch(#{in_flight := 1, queued := 4}, stats(C)),
    %% Each release hands the slot to the oldest waiter.
    lists:foldl(
        fun(Next, Holding) ->
            ok = release(Holding),
            {ok, _} = result(Next),
            Next
        end,
        First,
        Waiters
    ),
    ?assertMatch(#{in_flight := 1, queued := 0, throttled := 0}, stats(C)),
    ok = stop_keeper(Keeper).

queue_refuses_after_its_timeout(_Config) ->
    {Keeper, C} = route(1, {queue, 50, 10}),
    {ok, _} = result(holder(C)),
    Waiter = parked(Keeper, C),
    ?assertEqual({refused, 1}, result(Waiter)),
    ?assertMatch(#{in_flight := 1, queued := 0, throttled := 1}, stats(C)),
    ok = stop_keeper(Keeper).

queue_full_refuses_at_once(_Config) ->
    %% The queue holds one; with the keeper's view of the queue not yet
    %% full in `counts` (it is read first), the keeper itself refuses.
    {Keeper, C} = route(1, {queue, 5000, 1}),
    {ok, _} = result(holder(C)),
    _Waiter = parked(Keeper, C),
    Counts = element(3, C),
    ok = sys:suspend(Keeper),
    ok = atomics:put(Counts, 2, 2),
    Over = holder(C),
    ok = wait_mailbox(Keeper, Over),
    ok = atomics:put(Counts, 2, 1),
    ok = sys:resume(Keeper),
    %% `max_queued` was 2 when the request looked, 1 when the keeper did.
    ?assertEqual({refused, 1}, result(Over)),
    ?assertMatch(#{queued := 1, throttled := 1}, stats(C)),
    ok = stop_keeper(Keeper).

queue_full_refuses_without_the_keeper(_Config) ->
    {Keeper, C} = route(1, {queue, 5000, 1}),
    {ok, _} = result(holder(C)),
    _Waiter = parked(Keeper, C),
    ok = sys:suspend(Keeper),
    ?assertEqual({refused, 1}, roadrunner_route_keeper:acquire(C)),
    ok = sys:resume(Keeper),
    ok = stop_keeper(Keeper).

%% --- holders and waiters that die ---

killed_holder_frees_its_slot(_Config) ->
    {Keeper, C} = route(1, {queue, 5000, 10}),
    Holder = holder(C),
    {ok, _} = result(Holder),
    Waiter = parked(Keeper, C),
    exit(Holder, kill),
    {ok, _} = result(Waiter),
    ?assertMatch(#{in_flight := 1, queued := 0}, stats(C)),
    ok = stop_keeper(Keeper).

dead_waiter_leaves_the_queue(_Config) ->
    {Keeper, C} = route(1, {queue, 5000, 10}),
    Holder = holder(C),
    {ok, _} = result(Holder),
    Gone = parked(Keeper, C),
    Next = parked(Keeper, C),
    exit(Gone, kill),
    ok = wait_parked(Keeper, 1),
    ?assertMatch(#{queued := 1}, stats(C)),
    ok = release(Holder),
    {ok, _} = result(Next),
    ok = stop_keeper(Keeper).

%% --- a stream reset while waiting ---

reset_stops_the_wait(_Config) ->
    {Keeper, C} = route(1, {queue, 5000, 10}),
    Holder = holder(C),
    {ok, _} = result(Holder),
    Self = self(),
    Waiter = spawn(fun() ->
        Self ! {self(), roadrunner_route_keeper:acquire(C, {reset, 7})},
        receive
            stop -> ok
        end
    end),
    ok = wait_parked(Keeper, 1),
    Waiter ! {reset, 7},
    ?assertEqual(reset, result(Waiter)),
    %% Still waiting as far as the keeper knows, until the worker ends.
    Waiter ! stop,
    ok = wait_parked(Keeper, 0),
    ?assertMatch(#{queued := 0, throttled := 0}, stats(C)),
    ok = release(Holder),
    ?assertMatch(#{in_flight := 0}, stats(C)),
    ok = stop_keeper(Keeper).

reset_after_a_grant_frees_the_slot(_Config) ->
    %% The grant crosses the reset: the worker never sees it, and its slot
    %% frees when it ends.
    {Keeper, C} = route(1, {queue, 5000, 10}),
    Holder = holder(C),
    {ok, _} = result(Holder),
    Self = self(),
    Waiter = spawn(fun() ->
        receive
            go -> ok
        end,
        Self ! {self(), roadrunner_route_keeper:acquire(C, {reset, 7})},
        receive
            stop -> ok
        end
    end),
    Waiter ! go,
    ok = wait_parked(Keeper, 1),
    true = erlang:suspend_process(Waiter),
    ok = release(Holder),
    _ = sys:get_state(Keeper),
    ?assertMatch(#{in_flight := 1}, stats(C)),
    Waiter ! {reset, 7},
    true = erlang:resume_process(Waiter),
    %% The grant arrived first, so it wins.
    {ok, _} = result(Waiter),
    Waiter ! stop,
    ok = wait_in_flight(Keeper, C, 0),
    ok = stop_keeper(Keeper).

reset_waiter_times_out(_Config) ->
    {Keeper, C} = route(1, {queue, 50, 10}),
    {ok, _} = result(holder(C)),
    Self = self(),
    Waiter = spawn(fun() -> Self ! {self(), roadrunner_route_keeper:acquire(C, {reset, 7})} end),
    ?assertEqual({refused, 1}, result(Waiter)),
    ok = stop_keeper(Keeper).

%% --- reloads ---

raised_ceiling_serves_the_queue(_Config) ->
    {Keeper, C} = route(1, {queue, 5000, 10}),
    {ok, _} = result(holder(C)),
    Waiters = [parked(Keeper, C) || _ <- [1, 2]],
    ok = roadrunner_route_keeper:configure(Keeper, element(3, C), {3, 10}),
    [{ok, _} = result(W) || W <- Waiters],
    ?assertMatch(#{in_flight := 3, max_concurrent_requests := 3}, stats(C)),
    ok = stop_keeper(Keeper).

lowered_ceiling_holds_new_requests(_Config) ->
    %% The requests running keep running; no new one runs until they are
    %% under the new ceiling.
    {Keeper, C} = route(2, shed),
    A = holder(C),
    B = holder(C),
    {ok, _} = result(A),
    {ok, _} = result(B),
    ok = roadrunner_route_keeper:configure(Keeper, element(3, C), {1, 0}),
    ok = release(A),
    ?assertEqual({refused, 3}, result(holder(C))),
    ok = release(B),
    {ok, _} = result(holder(C)),
    ok = stop_keeper(Keeper).

draining_keeper_reports_when_empty(_Config) ->
    {Keeper, C} = route(1, shed),
    Holder = holder(C),
    {ok, _} = result(Holder),
    ok = roadrunner_route_keeper:set_draining(Keeper, true),
    _ = sys:get_state(Keeper),
    ok = release(Holder),
    receive
        {route_keeper_drained, Keeper} -> ok
    after 5000 -> ct:fail(never_drained)
    end,
    %% Brought back, it stays.
    ok = roadrunner_route_keeper:set_draining(Keeper, false),
    _ = sys:get_state(Keeper),
    ?assertEqual(none, drained_message()),
    ok = stop_keeper(Keeper).

%% --- the keeper crashes ---

keeper_crash_keeps_the_holders(_Config) ->
    %% The table outlives the keeper: one taking over counts the holders
    %% still running and frees each as it ends, never letting in more than
    %% the ceiling meanwhile.
    {Keeper, C} = route(2, {queue, 5000, 10}),
    A = holder(C),
    B = holder(C),
    {ok, _} = result(A),
    {ok, _} = result(B),
    exit(Keeper, kill),
    {'EXIT', Keeper, killed} = receive_exit(Keeper),
    {ok, NewKeeper} = roadrunner_route_keeper:start_link(slots(C), element(3, C), {false, self()}),
    ?assertMatch(#{in_flight := 2, queued := 0}, stats(C)),
    Waiter = parked(NewKeeper, C),
    %% A killed holder and a released one: each frees its slot once.
    exit(A, kill),
    {ok, _} = result(Waiter),
    ok = release(B),
    ok = wait_in_flight(NewKeeper, C, 1),
    ok = stop_keeper(NewKeeper).

keeper_crash_refuses_the_waiters(_Config) ->
    {Keeper, C} = route(1, {queue, 5000, 10}),
    {ok, _} = result(holder(C)),
    Waiter = parked(Keeper, C),
    exit(Keeper, kill),
    ?assertEqual({refused, 1}, result(Waiter)),
    {'EXIT', Keeper, killed} = receive_exit(Keeper),
    {ok, NewKeeper} = roadrunner_route_keeper:start_link(slots(C), element(3, C), {false, self()}),
    ?assertMatch(#{in_flight := 1, queued := 0, throttled := 1}, stats(C)),
    ok = stop_keeper(NewKeeper).

keeper_gone_before_its_answer_frees_the_row(_Config) ->
    %% The keeper added the row and died before its `granted` went out:
    %% the caller, seeing it gone, removes the row, so the slot is not left
    %% to a request that never ran.
    {Keeper, C} = route(1, shed),
    ok = sys:suspend(Keeper),
    Asker = holder(C),
    ok = wait_mailbox(Keeper, Asker),
    %% Stand in for the keeper's half-done grant: the row of the caller's
    %% token, then the keeper gone.
    [Token] = [T || {T, P} <- tracer_acquires(Keeper), P =:= Asker],
    true = ets:insert(slots(C), {Token, Asker}),
    exit(Keeper, kill),
    {'EXIT', Keeper, killed} = receive_exit(Keeper),
    ?assertEqual({refused, 3}, result(Asker)),
    ?assertEqual([], [Row || {T, _} = Row <- ets:tab2list(slots(C)), is_reference(T)]),
    true = ets:delete(slots(C)),
    %% And with the table gone as well, as when its listener went too.
    {Keeper2, C2} = route(1, shed),
    ok = sys:suspend(Keeper2),
    Asker2 = holder(C2),
    ok = wait_mailbox(Keeper2, Asker2),
    true = ets:delete(slots(C2)),
    exit(Keeper2, kill),
    {'EXIT', Keeper2, killed} = receive_exit(Keeper2),
    ?assertEqual({refused, 3}, result(Asker2)).

gone_table_refuses_and_releases(_Config) ->
    %% The listener is gone with its table: a request is refused, a release
    %% has nothing to do.
    {Keeper, C} = route(1, shed),
    Holder = holder(C),
    {ok, Token} = result(Holder),
    ok = stop_keeper(Keeper),
    true = ets:delete(slots(C)),
    ?assertEqual({refused, 3}, roadrunner_route_keeper:acquire(C)),
    ?assertEqual(ok, roadrunner_route_keeper:release(C, Token)),
    %% A table without its keeper row (between keepers) refuses too.
    Slots = ets:new(no_keeper, [public]),
    true = ets:insert(Slots, {placeholder, 0}),
    Bare = roadrunner_route_keeper:ceiling(
        Slots, atomics:new(4, [{signed, false}]), {shed, #{retry_after => 2}}, ?MODULE
    ),
    ok = atomics:put(element(3, Bare), 1, 5),
    ?assertEqual({refused, 2}, roadrunner_route_keeper:acquire(Bare)).

unknown_messages_are_ignored(_Config) ->
    {Keeper, C} = route(1, shed),
    ?assertEqual({error, unknown_call}, gen_server:call(Keeper, nonsense)),
    ok = gen_server:cast(Keeper, nonsense),
    Keeper ! nonsense,
    Keeper ! {done, make_ref()},
    Keeper ! {expire, make_ref()},
    Keeper ! {'DOWN', make_ref(), process, self(), normal},
    {ok, _} = result(holder(C)),
    ok = stop_keeper(Keeper).

%% --- helpers ---

%% A route of ceiling `Max` whose requests shed or queue (`{queue,
%% TimeoutMs, MaxQueued}`), and its keeper.
route(Max, Wait) ->
    {Mode, MaxQueued} =
        case Wait of
            shed -> {{shed, #{retry_after => 3}}, 0};
            {queue, Timeout, Queued} -> {{queue, #{timeout => Timeout}}, Queued}
        end,
    {Keeper, Slots, Counts} = roadrunner_route_keeper:new(Max, MaxQueued, false, self()),
    {Keeper, roadrunner_route_keeper:ceiling(Slots, Counts, Mode, ?MODULE)}.

slots(Ceiling) ->
    element(2, Ceiling).

stats(Ceiling) ->
    roadrunner_route_keeper:stats({slots(Ceiling), element(3, Ceiling)}).

stop_keeper(Keeper) ->
    true = unlink(Keeper),
    exit(Keeper, kill),
    ok.

%% A process that asks for a slot, reports what it got, and holds it
%% until told to release it.
holder(Ceiling) ->
    Self = self(),
    spawn(fun() ->
        Result = roadrunner_route_keeper:acquire(Ceiling),
        Self ! {self(), Result},
        receive
            release ->
                {ok, Token} = Result,
                ok = roadrunner_route_keeper:release(Ceiling, Token),
                Self ! {self(), released},
                receive
                    stop -> ok
                end
        end
    end).

%% A holder whose request the keeper parked.
parked(Keeper, Ceiling) ->
    #{queued := Queued} = stats(Ceiling),
    Pid = holder(Ceiling),
    ok = wait_parked(Keeper, Queued + 1),
    Pid.

%% Until the keeper has `N` requests waiting. Each check is a round trip to
%% the keeper, so it has handled every message sent to it before.
wait_parked(Keeper, N) ->
    wait_parked(Keeper, N, 1000000).

wait_parked(_Keeper, N, 0) ->
    ct:fail({never_parked, N});
wait_parked(Keeper, N, Tries) ->
    State = sys:get_state(Keeper),
    case map_size(element(7, State)) of
        N ->
            ok;
        _ ->
            erlang:yield(),
            wait_parked(Keeper, N, Tries - 1)
    end.

wait_in_flight(Keeper, Ceiling, N) ->
    wait_in_flight(Keeper, Ceiling, N, 1000000).

wait_in_flight(_Keeper, _Ceiling, N, 0) ->
    ct:fail({in_flight_never, N});
wait_in_flight(Keeper, Ceiling, N, Tries) ->
    _ = sys:get_state(Keeper),
    case stats(Ceiling) of
        #{in_flight := N} ->
            ok;
        #{} ->
            erlang:yield(),
            wait_in_flight(Keeper, Ceiling, N, Tries - 1)
    end.

%% Until `Pid`'s acquire is in the (suspended) keeper's mailbox.
wait_mailbox(Keeper, Pid) ->
    wait_mailbox(Keeper, Pid, 1000000).

wait_mailbox(_Keeper, Pid, 0) ->
    ct:fail({never_asked, Pid});
wait_mailbox(Keeper, Pid, Tries) ->
    case lists:keymember(Pid, 2, tracer_acquires(Keeper)) of
        true ->
            ok;
        false ->
            erlang:yield(),
            wait_mailbox(Keeper, Pid, Tries - 1)
    end.

%% The acquires queued in a suspended keeper's mailbox.
tracer_acquires(Keeper) ->
    {messages, Messages} = erlang:process_info(Keeper, messages),
    [{Token, Pid} || {acquire, Token, Pid, _Wait} <- Messages].

result(Pid) ->
    receive
        {Pid, Result} -> Result
    after 5000 -> ct:fail({no_result, Pid})
    end.

release(Pid) ->
    Pid ! release,
    released = result(Pid),
    ok.

receive_exit(Pid) ->
    receive
        {'EXIT', Pid, _} = Exit -> Exit
    after 5000 -> ct:fail({no_exit, Pid})
    end.

drained_message() ->
    receive
        {route_keeper_drained, _} = Msg -> Msg
    after 0 -> none
    end.
