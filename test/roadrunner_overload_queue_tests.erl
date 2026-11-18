-module(roadrunner_overload_queue_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Overload queue — parks requests over the in-flight ceiling.
%%
%% Every test drives the real gen_server against a real `counters` ref, so
%% the slot arithmetic under test is the same arithmetic the conn loops
%% use. `{spawn, _}` throughout because the tests receive the queue's
%% `{roadrunner_slot, _, _}` replies in their own mailbox.
%% =============================================================================

%% Max 1 slot, already taken, so the next acquire is guaranteed to park.
saturated(MaxQueued) ->
    Counter = counters:new(1, [write_concurrency]),
    true = roadrunner_conn:try_acquire_request_slot(1, Counter),
    {ok, Pid} = roadrunner_overload_queue:start_link(1, Counter, MaxQueued),
    {Pid, Counter}.

%% Enqueue and cancel are casts, so a test that depends on ordering has
%% to wait for them to land. `waiters_ref/1` is a call from the same
%% process, so returning from it means every earlier cast was processed.
sync(Pid) ->
    _ = roadrunner_overload_queue:waiters_ref(Pid),
    ok.

recv_slot(Token) ->
    receive
        {roadrunner_slot, Token, Outcome} -> Outcome
    after 2000 -> timeout_waiting_for_reply
    end.

release(Counter, Pid) ->
    ok = roadrunner_conn:release_request_slot(1, Counter, refuse),
    roadrunner_overload_queue:note_release(Pid).

granted_when_a_slot_frees_test_() ->
    {spawn, fun() ->
        {Pid, Counter} = saturated(8),
        ok = roadrunner_overload_queue:enqueue(Pid, s1, 5000),
        ok = sync(Pid),
        release(Counter, Pid),
        ?assertEqual(granted, recv_slot(s1)),
        %% The queue took the slot on our behalf: the counter is full again.
        ?assertEqual(1, counters:get(Counter, 1))
    end}.

fifo_order_test_() ->
    {spawn, fun() ->
        {Pid, Counter} = saturated(8),
        ok = roadrunner_overload_queue:enqueue(Pid, first, 5000),
        ok = sync(Pid),
        ok = roadrunner_overload_queue:enqueue(Pid, second, 5000),
        ok = sync(Pid),
        release(Counter, Pid),
        ?assertEqual(granted, recv_slot(first)),
        release(Counter, Pid),
        ?assertEqual(granted, recv_slot(second))
    end}.

expires_after_the_deadline_test_() ->
    {spawn, fun() ->
        {Pid, _Counter} = saturated(8),
        ok = roadrunner_overload_queue:enqueue(Pid, s1, 50),
        %% No slot ever frees — the queue owns the deadline and answers.
        ?assertEqual(timeout, recv_slot(s1))
    end}.

full_queue_sheds_immediately_test_() ->
    {spawn, fun() ->
        {Pid, _Counter} = saturated(1),
        ok = roadrunner_overload_queue:enqueue(Pid, s1, 5000),
        ok = sync(Pid),
        ok = roadrunner_overload_queue:enqueue(Pid, s2, 5000),
        %% The shed valve: overload sheds rather than queueing without bound.
        ?assertEqual(full, recv_slot(s2))
    end}.

cancelled_entry_is_skipped_test_() ->
    {spawn, fun() ->
        {Pid, Counter} = saturated(8),
        ok = roadrunner_overload_queue:enqueue(Pid, gone, 5000),
        ok = sync(Pid),
        ok = roadrunner_overload_queue:enqueue(Pid, kept, 5000),
        ok = sync(Pid),
        ok = roadrunner_overload_queue:cancel(Pid, gone),
        ok = sync(Pid),
        release(Counter, Pid),
        %% The stale head is dropped and the slot goes to the live entry.
        ?assertEqual(granted, recv_slot(kept))
    end}.

cancelling_an_unknown_token_is_a_noop_test_() ->
    {spawn, fun() ->
        {Pid, Counter} = saturated(8),
        ok = roadrunner_overload_queue:cancel(Pid, never_queued),
        ok = sync(Pid),
        ok = roadrunner_overload_queue:enqueue(Pid, s1, 5000),
        ok = sync(Pid),
        release(Counter, Pid),
        ?assertEqual(granted, recv_slot(s1))
    end}.

dead_waiter_is_dropped_test_() ->
    {spawn, fun() ->
        {Pid, Counter} = saturated(8),
        Self = self(),
        Dying = spawn(fun() ->
            ok = roadrunner_overload_queue:enqueue(Pid, doomed, 5000),
            Self ! queued,
            receive
                die -> ok
            end
        end),
        receive
            queued -> ok
        after 2000 -> error(never_queued)
        end,
        Ref = monitor(process, Dying),
        Dying ! die,
        receive
            {'DOWN', Ref, process, Dying, _} -> ok
        after 2000 -> error(never_died)
        end,
        %% Our own entry still gets the slot; nothing was taken for the
        %% dead one, so nothing leaked.
        ok = roadrunner_overload_queue:enqueue(Pid, mine, 5000),
        ok = sync(Pid),
        release(Counter, Pid),
        ?assertEqual(granted, recv_slot(mine))
    end}.

keeps_its_place_when_the_slot_is_lost_test_() ->
    {spawn, fun() ->
        {Pid, Counter} = saturated(8),
        ok = roadrunner_overload_queue:enqueue(Pid, s1, 5000),
        ok = sync(Pid),
        %% Notify without actually freeing anything: the queue tries to
        %% take a slot, fails, and must keep the entry at the head rather
        %% than dropping it.
        roadrunner_overload_queue:note_release(Pid),
        ?assertEqual(timeout_waiting_for_reply, recv_slot_short(s1)),
        release(Counter, Pid),
        ?assertEqual(granted, recv_slot(s1))
    end}.

recv_slot_short(Token) ->
    receive
        {roadrunner_slot, Token, Outcome} -> Outcome
    after 200 -> timeout_waiting_for_reply
    end.

release_on_an_empty_queue_is_harmless_test_() ->
    {spawn, fun() ->
        {Pid, Counter} = saturated(8),
        release(Counter, Pid),
        ?assert(is_process_alive(Pid))
    end}.

waiting_flag_tracks_the_queue_test_() ->
    {spawn, fun() ->
        {Pid, Counter} = saturated(8),
        Ref = roadrunner_overload_queue:waiters_ref(Pid),
        ?assertNot(roadrunner_overload_queue:waiting(Ref)),
        ok = roadrunner_overload_queue:enqueue(Pid, s1, 5000),
        ?assert(wait_until(fun() -> roadrunner_overload_queue:waiting(Ref) end)),
        release(Counter, Pid),
        ?assertEqual(granted, recv_slot(s1)),
        ?assert(wait_until(fun() -> not roadrunner_overload_queue:waiting(Ref) end))
    end}.

unknown_messages_do_not_disturb_it_test_() ->
    {spawn, fun() ->
        {Pid, Counter} = saturated(8),
        ?assertEqual({error, unknown_call}, gen_server:call(Pid, nonsense)),
        ok = gen_server:cast(Pid, nonsense),
        Pid ! nonsense,
        ok = roadrunner_overload_queue:enqueue(Pid, s1, 5000),
        ok = sync(Pid),
        release(Counter, Pid),
        ?assertEqual(granted, recv_slot(s1))
    end}.

%% A timer that fired just before its entry was served still delivers.
%% Resolving a key that is already gone must be a no-op.
late_expire_for_a_served_entry_is_ignored_test_() ->
    {spawn, fun() ->
        {Pid, Counter} = saturated(8),
        Pid ! {expire, {self(), never_queued}},
        ok = sync(Pid),
        ok = roadrunner_overload_queue:enqueue(Pid, s1, 5000),
        ok = sync(Pid),
        release(Counter, Pid),
        ?assertEqual(granted, recv_slot(s1))
    end}.

%% =============================================================================
%% Adopting the slots of handlers whose connection closed.
%% =============================================================================

%% An adopted worker keeps its slot until it ends, then the keeper
%% releases it and hands it to the oldest parked request.
adopted_worker_keeps_its_slot_until_it_ends_test_() ->
    {spawn, fun() ->
        {Pid, Counter} = saturated(8),
        Worker = spawn(fun() ->
            receive
                stop -> ok
            end
        end),
        Conn = spawn(fun() -> exit(roadrunner_overload_queue:adopt(Pid, [Worker])) end),
        Mon = monitor(process, Conn),
        receive
            {'DOWN', Mon, process, Conn, Granted} -> ?assertEqual(0, Granted)
        end,
        ?assertEqual(1, counters:get(Counter, 1)),
        ok = roadrunner_overload_queue:enqueue(Pid, s1, 5000),
        ok = sync(Pid),
        Worker ! stop,
        ?assertEqual(granted, recv_slot(s1)),
        ?assertEqual(1, counters:get(Counter, 1))
    end}.

%% A worker that ended before the hand-off is released at once.
adopted_dead_worker_is_released_at_once_test_() ->
    {spawn, fun() ->
        {Pid, Counter} = saturated(8),
        {Dead, Mon} = spawn_monitor(fun() -> ok end),
        receive
            {'DOWN', Mon, process, Dead, _} -> ok
        end,
        ?assertEqual(0, roadrunner_overload_queue:adopt(Pid, [Dead])),
        ok = sync(Pid),
        ?assertEqual(0, counters:get(Counter, 1))
    end}.

%% Adopting withdraws the caller's parked requests: a slot that frees later
%% is not granted to a connection that is gone.
adopt_withdraws_the_callers_parked_requests_test_() ->
    {spawn, fun() ->
        {Pid, Counter} = saturated(8),
        ok = roadrunner_overload_queue:enqueue(Pid, s1, 5000),
        ok = sync(Pid),
        ?assertEqual(0, roadrunner_overload_queue:adopt(Pid, [])),
        ?assertNot(roadrunner_overload_queue:waiting(roadrunner_overload_queue:waiters_ref(Pid))),
        release(Counter, Pid),
        ok = sync(Pid),
        ?assertEqual(0, counters:get(Counter, 1))
    end}.

%% A grant sent before the hand-off is already in the caller's mailbox when
%% it returns, and counted for the caller to give back.
adopt_counts_the_grants_that_raced_it_test_() ->
    {spawn, fun() ->
        {Pid, Counter} = saturated(8),
        ok = roadrunner_overload_queue:enqueue(Pid, s1, 5000),
        ok = sync(Pid),
        release(Counter, Pid),
        ok = sync(Pid),
        ?assertEqual(1, roadrunner_overload_queue:adopt(Pid, []))
    end}.

%% A keeper that is gone went down with its listener: nothing to hand over.
adopt_with_the_keeper_gone_test_() ->
    {spawn, fun() ->
        {Gone, Mon} = spawn_monitor(fun() -> ok end),
        receive
            {'DOWN', Mon, process, Gone, _} -> ok
        end,
        ?assertEqual(0, roadrunner_overload_queue:adopt(Gone, [self()]))
    end}.

wait_until(Fun) ->
    wait_until(Fun, 100).

wait_until(_Fun, 0) ->
    false;
wait_until(Fun, N) ->
    case Fun() of
        true ->
            true;
        false ->
            receive
            after 10 -> ok
            end,
            wait_until(Fun, N - 1)
    end.
