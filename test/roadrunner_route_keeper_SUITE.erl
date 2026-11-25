-module(roadrunner_route_keeper_SUITE).
-moduledoc """
`roadrunner_route_keeper` on its own: the slots of one route, taken by
processes standing in for HTTP/1.1 connections (which keep a home slot
across their requests) and for the stream workers of an HTTP/2 connection
or HTTP/3's loop (an owner, which starts and monitors its workers and frees
the slots they take on their own), with this suite standing in for the
listener that owns the tables and restarts the keeper.

The race cases stop a process between two of its steps
(`roadrunner_route_pause`) and run what races it there. Each fails when the
order it relies on changes: a request that ends reading the keeper's gate
before deleting its row, a keeper parking a request without closing its
gate first, a request taking its home past the gate, a drain or a lowered
ceiling, a worker checking its owner before writing its intent or inserting
before both, an owner freeing a worker's intent before its row, a keeper
watching a dead owner's workers before taking its registration.
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
    home_slot_needs_no_keeper/1,
    busy_home_moves_to_a_free_key/1,
    home_past_a_lowered_ceiling_moves/1,
    connection_gone_frees_its_home/1,
    release_before_the_last_look/1,
    release_against_a_park/1,
    release_reads_the_gate_after_its_delete/1,
    fast_request_queues_behind_a_waiter/1,
    drain_against_a_fast_request/1,
    lowered_ceiling_backs_a_fast_request_off/1,
    lowered_ceiling_backs_a_grant_off/1,
    lowered_ceiling_skips_keys_past_it/1,
    homes_fill_the_route_before_a_grant/1,
    table_deleted_mid_admission/1,
    killed_worker_frees_its_slot/1,
    dead_waiter_leaves_the_queue/1,
    reset_stops_the_wait/1,
    reset_after_a_grant_frees_the_slot/1,
    reset_waiter_times_out/1,
    connection_gone_stops_the_wait/1,
    worker_takes_an_owned_slot_without_the_keeper/1,
    worker_at_half_the_ceiling_asks_the_keeper/1,
    orphaned_worker_stays_counted/1,
    owner_gone_before_the_intent/1,
    owner_gone_before_the_insert/1,
    owner_gone_after_the_insert/1,
    owner_frees_the_row_before_the_intent/1,
    owner_down_takes_the_registration_first/1,
    keeper_crash_watches_an_orphaned_worker/1,
    keeper_restart_leaves_owned_slots_to_their_owner/1,
    late_intent_is_swept/1,
    handed_over_owner_leaves_its_workers_to_the_keeper/1,
    hand_over_after_the_route_went/1,
    hand_over_reaches_a_route_with_no_key/1,
    hand_over_before_any_registration/1,
    late_intent_after_a_hand_over_is_swept/1,
    sweep_spares_an_owner_registered_again/1,
    drain_against_a_fast_worker/1,
    worker_key_taken_asks_the_keeper/1,
    table_deleted_mid_worker_admission/1,
    keeper_crash_keeps_the_holders/1,
    keeper_crash_refuses_the_waiters/1,
    keeper_gone_before_its_answer_frees_the_row/1,
    keeper_gone_tells_the_next_keeper/1,
    homes_work_while_the_keeper_restarts/1,
    keeper_dies_before_a_new_home_is_answered/1,
    takeover_finds_a_grant_never_answered/1,
    takeover_frees_a_grant_of_a_dead_connection/1,
    raised_ceiling_serves_the_queue/1,
    lowered_ceiling_holds_new_requests/1,
    draining_keeper_stops_when_empty/1,
    keeper_taking_over_a_drained_route_stops/1,
    full_route_scan_finds_free_keys/1,
    scan_under_half_keeps_releases_quiet/1,
    gone_table_refuses_and_releases/1,
    unknown_messages_are_ignored/1,
    idle_keeper_hibernates/1,
    idle_connections_gone_leave_no_keys/1,
    worker_killed_after_its_insert_is_freed/1,
    protocol_steps_keep_their_order/1
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
        home_slot_needs_no_keeper,
        busy_home_moves_to_a_free_key,
        home_past_a_lowered_ceiling_moves,
        connection_gone_frees_its_home,
        release_before_the_last_look,
        release_against_a_park,
        release_reads_the_gate_after_its_delete,
        fast_request_queues_behind_a_waiter,
        drain_against_a_fast_request,
        lowered_ceiling_backs_a_fast_request_off,
        lowered_ceiling_backs_a_grant_off,
        lowered_ceiling_skips_keys_past_it,
        homes_fill_the_route_before_a_grant,
        table_deleted_mid_admission,
        killed_worker_frees_its_slot,
        dead_waiter_leaves_the_queue,
        reset_stops_the_wait,
        reset_after_a_grant_frees_the_slot,
        reset_waiter_times_out,
        connection_gone_stops_the_wait,
        worker_takes_an_owned_slot_without_the_keeper,
        worker_at_half_the_ceiling_asks_the_keeper,
        orphaned_worker_stays_counted,
        owner_gone_before_the_intent,
        owner_gone_before_the_insert,
        owner_gone_after_the_insert,
        owner_frees_the_row_before_the_intent,
        owner_down_takes_the_registration_first,
        keeper_crash_watches_an_orphaned_worker,
        keeper_restart_leaves_owned_slots_to_their_owner,
        late_intent_is_swept,
        handed_over_owner_leaves_its_workers_to_the_keeper,
        hand_over_after_the_route_went,
        hand_over_reaches_a_route_with_no_key,
        hand_over_before_any_registration,
        late_intent_after_a_hand_over_is_swept,
        sweep_spares_an_owner_registered_again,
        drain_against_a_fast_worker,
        worker_key_taken_asks_the_keeper,
        table_deleted_mid_worker_admission,
        keeper_crash_keeps_the_holders,
        keeper_crash_refuses_the_waiters,
        keeper_gone_before_its_answer_frees_the_row,
        keeper_gone_tells_the_next_keeper,
        homes_work_while_the_keeper_restarts,
        keeper_dies_before_a_new_home_is_answered,
        takeover_finds_a_grant_never_answered,
        takeover_frees_a_grant_of_a_dead_connection,
        raised_ceiling_serves_the_queue,
        lowered_ceiling_holds_new_requests,
        draining_keeper_stops_when_empty,
        keeper_taking_over_a_drained_route_stops,
        full_route_scan_finds_free_keys,
        scan_under_half_keeps_releases_quiet,
        gone_table_refuses_and_releases,
        unknown_messages_are_ignored,
        idle_keeper_hibernates,
        idle_connections_gone_leave_no_keys,
        worker_killed_after_its_insert_is_freed,
        protocol_steps_keep_their_order
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
    ?assertEqual({refused, 3}, result(holder(C))),
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
    %% The request reads a queue depth of 2 and asks; by the time the keeper
    %% looks, the depth is 1 and the queue full, so the keeper refuses.
    {Keeper, C} = route(1, {queue, 5000, 1}),
    {ok, _} = result(holder(C)),
    _Waiter = parked(Keeper, C),
    ok = sys:suspend(Keeper),
    ok = roadrunner_route_keeper:configure(Keeper, counts(C), {1, 2}),
    Over = holder(C),
    ok = wait_mailbox(Keeper, Over),
    ok = roadrunner_route_keeper:configure(Keeper, counts(C), {1, 1}),
    ok = sys:resume(Keeper),
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

%% --- home slots ---

home_slot_needs_no_keeper(_Config) ->
    %% A connection's first request gets its home from the keeper, which
    %% registers the connection. Its next requests take and hand back that
    %% slot while the keeper does nothing (suspended here), and nothing is
    %% sent to it.
    {Keeper, C} = route(2, shed),
    Conn = holder(C),
    {ok, Home} = result(Conn),
    ?assertEqual(Home, home(Conn, C)),
    ?assertEqual([{Conn, Home}], ets:lookup(regs(C), Conn)),
    ok = release(Conn),
    ok = sys:suspend(Keeper),
    lists:foreach(
        fun(_) ->
            {ok, Home} = request(Conn),
            ok = release(Conn)
        end,
        lists:seq(1, 3)
    ),
    ?assertEqual({message_queue_len, 0}, erlang:process_info(Keeper, message_queue_len)),
    ok = sys:resume(Keeper),
    ?assertMatch(#{in_flight := 0, throttled := 0}, stats(C)),
    ok = stop_keeper(Keeper).

busy_home_moves_to_a_free_key(_Config) ->
    %% A new connection gets key 1, A's home, while A is idle; A's next
    %% request finds it taken, and the keeper makes the free key A's home.
    {Keeper, C} = route(2, shed),
    A = holder(C),
    {ok, 1} = result(A),
    B = holder(C),
    {ok, 2} = result(B),
    ok = release(A),
    ok = release(B),
    {ok, 1} = result(holder(C)),
    ?assertEqual({ok, 2}, request(A)),
    ?assertEqual(2, home(A, C)),
    ?assertEqual([{A, 2}], ets:lookup(regs(C), A)),
    ok = stop_keeper(Keeper).

home_past_a_lowered_ceiling_moves(_Config) ->
    {Keeper, C} = route(2, shed),
    A = holder(C),
    {ok, 1} = result(A),
    B = holder(C),
    {ok, 2} = result(B),
    ok = release(A),
    ok = release(B),
    ok = roadrunner_route_keeper:configure(Keeper, counts(C), {1, 0}),
    ?assertEqual({ok, 1}, request(B)),
    ?assertEqual(1, home(B, C)),
    ok = stop_keeper(Keeper).

connection_gone_frees_its_home(_Config) ->
    %% A registered connection killed while it holds its home: the keeper
    %% removes its registration and the row, and the slot goes on.
    {Keeper, C} = route(1, {queue, 5000, 10}),
    Conn = holder(C),
    {ok, 1} = result(Conn),
    Waiter = parked(Keeper, C),
    exit(Conn, kill),
    ?assertEqual({ok, 1}, result(Waiter)),
    ?assertEqual([], ets:lookup(regs(C), Conn)),
    ok = stop_keeper(Keeper).

%% --- races ---

release_before_the_last_look(_Config) ->
    %% The slot frees between the keeper's first look, which found the
    %% route full, and its last: the request gets it without waiting, and
    %% the gate opens again.
    {Keeper, C} = route(1, {queue, 5000, 10}),
    Holder = holder(C),
    {ok, _} = result(Holder),
    ok = roadrunner_route_pause:arm(full, Keeper),
    Asker = holder(C),
    Keeper = roadrunner_route_pause:await(full),
    ok = release(Holder),
    ok = roadrunner_route_pause:resume(Keeper, full),
    ?assertMatch({ok, _}, result(Asker)),
    ok = wait_queued(Keeper, C, 0),
    ?assertEqual(0, gate(C)),
    ok = stop_keeper(Keeper).

release_against_a_park(_Config) ->
    %% The keeper found no room on its last look and is about to park the
    %% request when the slot's holder ends. The gate closed before that
    %% look, so the release tells the keeper, and the request gets the slot.
    {Keeper, C} = route(1, {queue, 5000, 10}),
    Holder = holder(C),
    {ok, _} = result(Holder),
    ok = roadrunner_route_pause:arm(parking, Keeper),
    Waiter = holder(C),
    Keeper = roadrunner_route_pause:await(parking),
    ok = release(Holder),
    ok = roadrunner_route_pause:resume(Keeper, parking),
    ?assertMatch({ok, _}, result(Waiter)),
    ok = stop_keeper(Keeper).

release_reads_the_gate_after_its_delete(_Config) ->
    %% A release stopped between deleting its row and reading the gate,
    %% while the keeper handles whatever it had: the keeper learns of the
    %% free slot only from what the release does next.
    {Keeper, C} = route(1, {queue, 5000, 10}),
    Holder = holder(C),
    {ok, _} = result(Holder),
    Waiter = parked(Keeper, C),
    ok = roadrunner_route_pause:arm(released, Holder),
    Holder ! release,
    Holder = roadrunner_route_pause:await(released),
    _ = sys:get_state(Keeper),
    ok = roadrunner_route_pause:resume(Holder, released),
    released = result(Holder),
    ?assertMatch({ok, _}, result(Waiter)),
    ok = stop_keeper(Keeper).

fast_request_queues_behind_a_waiter(_Config) ->
    %% A connection hands its home back while a request waits, then asks
    %% again at once, before the keeper serves the waiter: the closed gate
    %% sends it to the keeper, behind the waiter, though its home is free.
    {Keeper, C} = route(1, {queue, 5000, 10}),
    Conn = holder(C),
    {ok, 1} = result(Conn),
    Waiter = parked(Keeper, C),
    ok = sys:suspend(Keeper),
    ok = release(Conn),
    Conn ! request,
    ok = wait_mailbox(Keeper, Conn),
    ok = sys:resume(Keeper),
    ?assertEqual({ok, 1}, result(Waiter)),
    ok = wait_queued(Keeper, C, 1),
    ok = release(Waiter),
    ?assertMatch({ok, _}, result(Conn)),
    ok = stop_keeper(Keeper).

drain_against_a_fast_request(_Config) ->
    %% A connection read an open gate for its home just as its route was
    %% dropped. Nothing runs, so the keeper stops; the request then inserts
    %% its row, sees the drain and backs off, rather than run on a table
    %% the listener is about to delete.
    {Keeper, C} = route(1, shed),
    Conn = holder(C),
    {ok, 1} = result(Conn),
    ok = release(Conn),
    ok = roadrunner_route_pause:arm(home_open, Conn),
    Conn ! request,
    Conn = roadrunner_route_pause:await(home_open),
    ok = roadrunner_route_keeper:set_draining(Keeper, true),
    ?assertEqual({'EXIT', Keeper, {shutdown, drained}}, receive_exit(Keeper)),
    ok = roadrunner_route_pause:resume(Conn, home_open),
    ?assertEqual({refused, 3}, result(Conn)),
    ?assertMatch(#{in_flight := 0}, stats(C)).

lowered_ceiling_backs_a_fast_request_off(_Config) ->
    %% A's home is within the lowered ceiling, but B still runs past it:
    %% A inserts its row, sees the route over its ceiling and backs off.
    {Keeper, C} = route(2, shed),
    A = holder(C),
    {ok, 1} = result(A),
    B = holder(C),
    {ok, 2} = result(B),
    ok = release(A),
    ok = roadrunner_route_keeper:configure(Keeper, counts(C), {1, 0}),
    ?assertEqual({refused, 3}, request(A)),
    ?assertMatch(#{in_flight := 1}, stats(C)),
    ok = release(B),
    ?assertEqual({ok, 1}, request(A)),
    ok = stop_keeper(Keeper).

lowered_ceiling_backs_a_grant_off(_Config) ->
    %% D runs on key 3 past a ceiling lowered to 2. The keeper sees room
    %% for a new connection, and before it takes a key B takes its home: the
    %% key the keeper takes then puts the route over its ceiling, and goes.
    {Keeper, C} = route(3, shed),
    A = holder(C),
    {ok, 1} = result(A),
    B = holder(C),
    {ok, 2} = result(B),
    {ok, 3} = result(holder(C)),
    ok = release(A),
    ok = release(B),
    ok = roadrunner_route_keeper:configure(Keeper, counts(C), {2, 0}),
    ok = roadrunner_route_pause:arm(granting, Keeper),
    New = holder(C),
    Keeper = roadrunner_route_pause:await(granting),
    ?assertEqual({ok, 2}, request(B)),
    ok = roadrunner_route_pause:resume(Keeper, granting),
    ?assertEqual({refused, 3}, result(New)),
    ?assertMatch(#{in_flight := 2}, stats(C)),
    ok = stop_keeper(Keeper).

lowered_ceiling_skips_keys_past_it(_Config) ->
    %% A key the keeper kept from before a reload lowered the ceiling past
    %% it is not granted.
    {Keeper, C} = route(2, shed),
    Conn = holder(C),
    {ok, 1} = result(Conn),
    Worker = worker(C),
    {ok, 2} = result(Worker),
    ok = end_worker(Worker),
    ok = wait_in_flight(Keeper, C, 1),
    ok = roadrunner_route_keeper:configure(Keeper, counts(C), {1, 0}),
    ok = release(Conn),
    ?assertEqual({ok, 1}, result(holder(C))),
    ok = stop_keeper(Keeper).

homes_fill_the_route_before_a_grant(_Config) ->
    %% The keeper sees room for a new connection, and before it takes a key
    %% the registered connections take every one: it finds none, whether it
    %% tries them all in turn or, on a large route, scans the table.
    lists:foreach(
        fun(Max) ->
            {Keeper, C} = route(Max, shed),
            Conns = [holder(C) || _ <- lists:seq(1, Max)],
            lists:foreach(fun(Conn) -> {ok, _} = result(Conn) end, Conns),
            lists:foreach(fun(Conn) -> ok = release(Conn) end, Conns),
            ok = roadrunner_route_pause:arm(granting, Keeper),
            New = holder(C),
            Keeper = roadrunner_route_pause:await(granting),
            lists:foreach(fun(Conn) -> {ok, _} = request(Conn) end, Conns),
            ok = roadrunner_route_pause:resume(Keeper, granting),
            ?assertEqual({refused, 3}, result(New)),
            ok = stop_keeper(Keeper)
        end,
        [2, 17]
    ).

table_deleted_mid_admission(_Config) ->
    %% The route's tables go (its listener stopped, or it drained) while a
    %% connection takes its home: the request is refused, and the
    %% connection forgets its home there.
    {Keeper, C} = route(1, shed),
    Conn = holder(C),
    {ok, 1} = result(Conn),
    ok = release(Conn),
    ok = roadrunner_route_pause:arm(home_open, Conn),
    Conn ! request,
    Conn = roadrunner_route_pause:await(home_open),
    ok = stop_keeper(Keeper),
    true = roadrunner_route_keeper:delete_table(table(C)),
    ok = roadrunner_route_pause:resume(Conn, home_open),
    ?assertEqual({refused, 3}, result(Conn)),
    ?assertEqual(undefined, home(Conn, C)).

%% --- holders and waiters that die ---

killed_worker_frees_its_slot(_Config) ->
    {Keeper, C} = route(1, {queue, 5000, 10}),
    Worker = worker(C),
    {ok, _} = result(Worker),
    Waiter = parked(Keeper, C),
    exit(Worker, kill),
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
    ok = wait_queued(Keeper, C, 1),
    ok = release(Holder),
    {ok, _} = result(Next),
    ok = stop_keeper(Keeper).

%% --- a stream reset while waiting ---

reset_stops_the_wait(_Config) ->
    {Keeper, C} = route(1, {queue, 5000, 10}),
    Holder = holder(C),
    {ok, _} = result(Holder),
    Waiter = worker(C),
    ok = wait_queued(Keeper, C, 1),
    Waiter ! {reset, Waiter},
    ?assertEqual(reset, result(Waiter)),
    %% Still waiting as far as the keeper knows, until the worker ends.
    ok = end_worker(Waiter),
    ok = wait_queued(Keeper, C, 0),
    ?assertMatch(#{throttled := 0}, stats(C)),
    ok = release(Holder),
    ?assertMatch(#{in_flight := 0}, stats(C)),
    ok = stop_keeper(Keeper).

reset_after_a_grant_frees_the_slot(_Config) ->
    %% The grant crosses the reset: it arrived first, so the worker runs,
    %% and its slot frees when it ends.
    {Keeper, C} = route(1, {queue, 5000, 10}),
    Holder = holder(C),
    {ok, _} = result(Holder),
    Waiter = worker(C),
    ok = wait_queued(Keeper, C, 1),
    true = erlang:suspend_process(Waiter),
    ok = release(Holder),
    ok = wait_queued(Keeper, C, 0),
    Waiter ! {reset, Waiter},
    true = erlang:resume_process(Waiter),
    {ok, _} = result(Waiter),
    ok = end_worker(Waiter),
    ok = wait_in_flight(Keeper, C, 0),
    ok = stop_keeper(Keeper).

reset_waiter_times_out(_Config) ->
    {Keeper, C} = route(1, {queue, 50, 10}),
    {ok, _} = result(holder(C)),
    ?assertEqual({refused, 1}, result(worker(C))),
    ok = stop_keeper(Keeper).

connection_gone_stops_the_wait(_Config) ->
    %% A worker whose connection goes while it waits stops waiting: nobody
    %% is left to answer.
    {Keeper, C} = route(1, {queue, 5000, 10}),
    Holder = holder(C),
    {ok, _} = result(Holder),
    Conn = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    Waiter = worker(C, Conn),
    ok = wait_queued(Keeper, C, 1),
    exit(Conn, kill),
    ?assertEqual(reset, result(Waiter)),
    ok = end_worker(Waiter),
    ok = wait_queued(Keeper, C, 0),
    ok = release(Holder),
    ?assertMatch(#{in_flight := 0, throttled := 0}, stats(C)),
    ok = stop_keeper(Keeper).

%% --- stream workers and their owners ---

worker_takes_an_owned_slot_without_the_keeper(_Config) ->
    %% The first worker of an owner the keeper does not know asks it, and
    %% the keeper registers the owner. The owner's next workers take a slot
    %% the owner frees when they end, while the keeper does nothing
    %% (suspended here).
    {Keeper, C} = route(4, shed),
    Owner = owner(C),
    First = stream(Owner),
    {ok, K1} = result(First),
    ?assertEqual([{K1, First, First}], ets:lookup(slots(C), K1)),
    ?assertEqual([{Owner, none}], ets:lookup(regs(C), Owner)),
    ok = end_worker(First),
    ok = wait_in_flight(Keeper, C, 0),
    ok = sys:suspend(Keeper),
    Worker = stream(Owner),
    {ok, K} = result(Worker),
    ?assertEqual([{K, Owner, Worker}], ets:lookup(slots(C), K)),
    ?assertEqual([{Owner, Worker, K}], ets:lookup(intents(C), Owner)),
    ok = end_worker(Worker),
    ok = wait_rows(C, 0),
    ?assertEqual([], ets:tab2list(intents(C))),
    ?assertEqual({message_queue_len, 0}, erlang:process_info(Keeper, message_queue_len)),
    ok = sys:resume(Keeper),
    ok = stop_keeper(Keeper).

worker_at_half_the_ceiling_asks_the_keeper(_Config) ->
    %% One request of two runs: a worker of a registered owner asks the
    %% keeper rather than try a key likely taken.
    {Keeper, C} = route(2, shed),
    Owner = owner(C),
    {ok, _} = result(stream(Owner)),
    Worker = stream(Owner),
    {ok, K} = result(Worker),
    ?assertEqual([{K, Worker, Worker}], ets:lookup(slots(C), K)),
    ?assertEqual([], ets:tab2list(intents(C))),
    ok = stop_keeper(Keeper).

orphaned_worker_stays_counted(_Config) ->
    %% The owner dies while its worker runs: the keeper watches the worker
    %% from then on, its slot stays counted, and goes when it ends.
    {Keeper, C} = route(2, shed),
    Owner = registered_owner(Keeper, C),
    Worker = stream(Owner),
    {ok, K} = result(Worker),
    ok = kill_owner(Keeper, C, Owner),
    ?assertMatch(#{in_flight := 1}, stats(C)),
    %% The keeper looking again keeps the intent of a worker it watches.
    Keeper ! sweep,
    _ = sys:get_state(Keeper),
    ?assertEqual([{Owner, Worker, K}], ets:tab2list(intents(C))),
    ok = end_worker(Worker),
    ok = wait_in_flight(Keeper, C, 0),
    ?assertEqual([], ets:tab2list(intents(C))),
    ok = stop_keeper(Keeper).

owner_gone_before_the_intent(_Config) ->
    %% The owner, the worker's connection, dies after the worker told it its
    %% key: the worker writes its intent, finds the owner no longer
    %% registered, takes the intent back and asks the keeper, then stops
    %% waiting as its connection is gone. Nothing is left once it ends.
    {Keeper, C} = route(2, shed),
    Owner = registered_owner(Keeper, C),
    ok = roadrunner_route_pause:arm(worker_noted),
    Worker = stream(Owner),
    Worker = roadrunner_route_pause:await(worker_noted),
    ok = kill_owner(Keeper, C, Owner),
    ok = roadrunner_route_pause:resume(Worker, worker_noted),
    ?assertEqual(reset, result(Worker)),
    ?assertEqual([], ets:tab2list(intents(C))),
    ok = end_worker(Worker),
    ok = wait_in_flight(Keeper, C, 0),
    ok = stop_keeper(Keeper).

owner_gone_before_the_insert(_Config) ->
    %% The owner dies after the worker found it registered, with the
    %% worker's intent written: the keeper watches the worker, which takes
    %% its slot, and frees the slot when the worker ends.
    {Keeper, C} = route(2, shed),
    Owner = registered_owner(Keeper, C),
    ok = roadrunner_route_pause:arm(worker_checked),
    Worker = stream(Owner),
    Worker = roadrunner_route_pause:await(worker_checked),
    ok = kill_owner(Keeper, C, Owner),
    ok = roadrunner_route_pause:resume(Worker, worker_checked),
    {ok, _} = result(Worker),
    ?assertMatch(#{in_flight := 1}, stats(C)),
    ok = end_worker(Worker),
    ok = wait_in_flight(Keeper, C, 0),
    ?assertEqual([], ets:tab2list(intents(C))),
    ok = stop_keeper(Keeper).

owner_gone_after_the_insert(_Config) ->
    %% The owner, then the worker, die right after the worker's insert:
    %% the keeper, watching the worker from its intent, frees the slot.
    {Keeper, C} = route(2, shed),
    Owner = registered_owner(Keeper, C),
    ok = roadrunner_route_pause:arm(worker_inserted),
    Worker = stream(Owner),
    Worker = roadrunner_route_pause:await(worker_inserted),
    ok = kill_owner(Keeper, C, Owner),
    exit(Worker, kill),
    ok = wait_in_flight(Keeper, C, 0),
    ?assertEqual([], ets:tab2list(intents(C))),
    ok = stop_keeper(Keeper).

owner_frees_the_row_before_the_intent(_Config) ->
    %% A worker ended and its owner, freeing its slot, dies between the row
    %% and the intent: the keeper finds the intent, and nothing is left.
    {Keeper, C} = route(2, shed),
    Owner = registered_owner(Keeper, C),
    Worker = stream(Owner),
    {ok, _} = result(Worker),
    ok = roadrunner_route_pause:arm(owner_row_freed, Owner),
    Worker ! stop,
    Owner = roadrunner_route_pause:await(owner_row_freed),
    ok = kill_owner(Keeper, C, Owner),
    ok = wait_in_flight(Keeper, C, 0),
    ?assertEqual([], ets:tab2list(intents(C))),
    ok = stop_keeper(Keeper).

owner_down_takes_the_registration_first(_Config) ->
    %% A worker starts as the keeper handles its dead owner, after the
    %% keeper took the owner's registration and before it looked for the
    %% owner's workers: the worker finds the owner unregistered and asks the
    %% keeper, so its slot is never left without someone to free it.
    {Keeper, C} = route(2, shed),
    Owner = registered_owner(Keeper, C),
    ok = roadrunner_route_pause:arm(owner_taken, Keeper),
    exit(Owner, kill),
    Keeper = roadrunner_route_pause:await(owner_taken),
    Worker = worker(C, idle(), Owner),
    ok = roadrunner_route_pause:resume(Keeper, owner_taken),
    {ok, K} = result(Worker),
    ?assertEqual([{K, Worker, Worker}], ets:lookup(slots(C), K)),
    ok = end_worker(Worker),
    ok = wait_in_flight(Keeper, C, 0),
    ok = stop_keeper(Keeper).

keeper_crash_watches_an_orphaned_worker(_Config) ->
    %% The keeper took a dead owner's registration and died before it
    %% watched the owner's workers: the keeper taking over finds their
    %% intents, and frees each slot as its worker ends.
    {Keeper, C} = route(2, shed),
    Owner = registered_owner(Keeper, C),
    Worker = stream(Owner),
    {ok, _} = result(Worker),
    ok = roadrunner_route_pause:arm(owner_taken, Keeper),
    exit(Owner, kill),
    Keeper = roadrunner_route_pause:await(owner_taken),
    exit(Keeper, kill),
    {'EXIT', Keeper, killed} = receive_exit(Keeper),
    {ok, Next} = start_keeper(C, false),
    ?assertMatch(#{in_flight := 1}, stats(C)),
    ok = end_worker(Worker),
    ok = wait_in_flight(Next, C, 0),
    ?assertEqual([], ets:tab2list(intents(C))),
    ok = stop_keeper(Next).

keeper_restart_leaves_owned_slots_to_their_owner(_Config) ->
    %% A registered owner's workers' slots stay its own across a keeper
    %% restart: the owner frees them as they end.
    {Keeper, C} = route(2, shed),
    Owner = registered_owner(Keeper, C),
    Worker = stream(Owner),
    {ok, _} = result(Worker),
    exit(Keeper, kill),
    {'EXIT', Keeper, killed} = receive_exit(Keeper),
    {ok, Next} = start_keeper(C, false),
    {monitors, Monitors} = erlang:process_info(Next, monitors),
    ?assertEqual([{process, Owner}], Monitors),
    ok = end_worker(Worker),
    ok = wait_rows(C, 0),
    ?assertEqual([], ets:tab2list(intents(C))),
    ok = stop_keeper(Next).

late_intent_is_swept(_Config) ->
    %% A worker read its owner registered, the owner died and the keeper
    %% looked for its workers' intents, then the worker wrote its intent
    %% and died before taking it back: no row, only the intent, which the
    %% keeper removes when it looks again.
    {Keeper, C} = route(2, shed),
    Owner = registered_owner(Keeper, C),
    ok = roadrunner_route_pause:arm(worker_noted),
    Worker = stream(Owner),
    Worker = roadrunner_route_pause:await(worker_noted),
    ok = kill_owner(Keeper, C, Owner),
    ok = roadrunner_route_pause:arm(worker_intent, Worker),
    ok = roadrunner_route_pause:resume(Worker, worker_noted),
    Worker = roadrunner_route_pause:await(worker_intent),
    exit(Worker, kill),
    ?assertMatch([{Owner, Worker, _}], ets:tab2list(intents(C))),
    ?assertMatch(#{in_flight := 0}, stats(C)),
    %% Another owner dies before the keeper looks again: it looks for both,
    %% a second after the first died.
    ok = kill_owner(Keeper, C, registered_owner(Keeper, C)),
    ok = wait_no_intents(C, erlang:monotonic_time(millisecond) + 10000),
    ok = stop_keeper(Keeper).

handed_over_owner_leaves_its_workers_to_the_keeper(_Config) ->
    %% An owner that lives on but stops answering its workers hands its
    %% registration over: the keeper frees its worker's slot as the worker
    %% ends, and does not register the owner again for a worker that asks.
    {Keeper, C} = route(4, shed),
    Owner = registered_owner(Keeper, C),
    Worker = stream(Owner),
    {ok, K} = result(Worker),
    ?assertEqual([{K, Owner, Worker}], ets:lookup(slots(C), K)),
    ok = hand_over(Owner),
    ok = wait_unregistered(C, Owner, 1000000),
    ok = end_worker(Worker),
    ok = wait_in_flight(Keeper, C, 0),
    ?assertEqual([], ets:tab2list(intents(C))),
    Late = worker(C, idle(), Owner),
    {ok, K2} = result(Late),
    ?assertEqual([{K2, Late, Late}], ets:lookup(slots(C), K2)),
    ?assertNot(ets:member(regs(C), Owner)),
    %% Told again, the keeper has nothing to take.
    Keeper ! {hand_over, Owner},
    _ = sys:get_state(Keeper),
    ok = end_worker(Late),
    ok = wait_in_flight(Keeper, C, 0),
    ok = stop_keeper(Keeper).

hand_over_after_the_route_went(_Config) ->
    %% The listener went with the route's tables: the owner has no keeper
    %% to tell, and goes on.
    {Keeper, C} = route(4, shed),
    Owner = registered_owner(Keeper, C),
    {ok, _} = result(stream(Owner)),
    ok = stop_keeper(Keeper),
    true = roadrunner_route_keeper:delete_table(table(C)),
    ok = hand_over(Owner).

hand_over_reaches_a_route_with_no_key(_Config) ->
    %% The owner holds no slot of the route when it hands over, but is
    %% registered there: the keeper takes the registration all the same, so
    %% a worker of it starting later asks the keeper, which frees its slot
    %% as it ends, while the owner still lives.
    {Keeper, C} = route(4, shed),
    Owner = registered_owner(Keeper, C),
    ok = hand_over(Owner),
    ok = wait_unregistered(C, Owner, 1000000),
    Worker = worker(C, idle(), Owner),
    {ok, K} = result(Worker),
    ?assertEqual([{K, Worker, Worker}], ets:lookup(slots(C), K)),
    ok = end_worker(Worker),
    ok = wait_in_flight(Keeper, C, 0),
    ?assert(is_process_alive(Owner)),
    ok = stop_keeper(Keeper).

hand_over_before_any_registration(_Config) ->
    %% An owner the keeper never registered hands over: the keeper watches
    %% it, so its first worker to ask does not register it.
    {Keeper, C} = route(4, shed),
    Owner = owner(C),
    ok = hand_over(Owner),
    _ = sys:get_state(Keeper),
    Worker = worker(C, idle(), Owner),
    {ok, K} = result(Worker),
    ?assertEqual([{K, Worker, Worker}], ets:lookup(slots(C), K)),
    ?assertNot(ets:member(regs(C), Owner)),
    ok = end_worker(Worker),
    ok = wait_in_flight(Keeper, C, 0),
    ok = stop_keeper(Keeper).

late_intent_after_a_hand_over_is_swept(_Config) ->
    %% As `late_intent_is_swept`, the owner handing over rather than dying:
    %% a worker that read it registered writes its intent after the keeper
    %% looked for them, and dies before taking it back. The keeper looks
    %% again a second later and removes it.
    {Keeper, C} = route(4, shed),
    Owner = registered_owner(Keeper, C),
    ok = roadrunner_route_pause:arm(worker_noted),
    Worker = stream(Owner),
    Worker = roadrunner_route_pause:await(worker_noted),
    ok = hand_over(Owner),
    ok = wait_unregistered(C, Owner, 1000000),
    _ = sys:get_state(Keeper),
    ok = roadrunner_route_pause:arm(worker_intent, Worker),
    ok = roadrunner_route_pause:resume(Worker, worker_noted),
    Worker = roadrunner_route_pause:await(worker_intent),
    exit(Worker, kill),
    ?assertMatch([{Owner, Worker, _}], ets:tab2list(intents(C))),
    ok = wait_no_intents(C, erlang:monotonic_time(millisecond) + 10000),
    ok = stop_keeper(Keeper).

sweep_spares_an_owner_registered_again(_Config) ->
    %% An owner died, and a worker naming it asked the keeper before the
    %% keeper looked again for the owner's intents: the keeper registers the
    %% dead owner until it sees it die once more, and a worker may take a
    %% slot owned by it meanwhile. The look must leave that worker's intent,
    %% which the owner's next death leads the keeper to.
    {Keeper, C} = route(4, shed),
    Owner = registered_owner(Keeper, C),
    ok = kill_owner(Keeper, C, Owner),
    ok = sys:suspend(Keeper),
    Asker = worker(C, idle(), Owner),
    ok = wait_mailbox(Keeper, Asker),
    ok = wait_sweep(Keeper, erlang:monotonic_time(millisecond) + 10000),
    %% A worker holding a slot owned by the owner registered again.
    Holder = idle(),
    true = ets:insert(intents(C), {Owner, Holder, 4}),
    true = ets:insert(slots(C), {4, Owner, Holder}),
    ok = sys:resume(Keeper),
    {ok, _} = result(Asker),
    _ = sys:get_state(Keeper),
    ?assertNot(ets:member(regs(C), Owner)),
    ?assertEqual([{Owner, Holder, 4}], ets:lookup(intents(C), Owner)),
    ok = end_worker(Holder),
    ok = end_worker(Asker),
    ok = wait_in_flight(Keeper, C, 0),
    ok = stop_keeper(Keeper).

drain_against_a_fast_worker(_Config) ->
    %% A worker found its owner registered just as the route was dropped.
    %% Nothing runs, so the keeper stops; the worker then inserts its row,
    %% sees the drain and backs off.
    {Keeper, C} = route(2, shed),
    Owner = registered_owner(Keeper, C),
    ok = roadrunner_route_pause:arm(worker_checked),
    Worker = stream(Owner),
    Worker = roadrunner_route_pause:await(worker_checked),
    ok = roadrunner_route_keeper:set_draining(Keeper, true),
    ?assertEqual({'EXIT', Keeper, {shutdown, drained}}, receive_exit(Keeper)),
    ok = roadrunner_route_pause:resume(Worker, worker_checked),
    ?assertEqual({refused, 3}, result(Worker)),
    ?assertMatch(#{in_flight := 0}, stats(C)),
    ?assertEqual([], ets:tab2list(intents(C))).

worker_key_taken_asks_the_keeper(_Config) ->
    %% The key a worker picked is taken before it inserts its row: it takes
    %% its intent back and asks the keeper.
    {Keeper, C} = route(1, shed),
    Owner = registered_owner(Keeper, C),
    Conn = holder(C),
    {ok, 1} = result(Conn),
    ok = release(Conn),
    ok = roadrunner_route_pause:arm(worker_checked),
    Worker = stream(Owner),
    Worker = roadrunner_route_pause:await(worker_checked),
    {ok, 1} = request(Conn),
    ok = roadrunner_route_pause:resume(Worker, worker_checked),
    ?assertEqual({refused, 3}, result(Worker)),
    ?assertEqual([], ets:tab2list(intents(C))),
    ok = stop_keeper(Keeper).

table_deleted_mid_worker_admission(_Config) ->
    %% The route's tables go while a worker takes its slot: it is refused,
    %% and its owner, freeing what the worker told it of, goes on.
    {Keeper, C} = route(2, shed),
    Owner = registered_owner(Keeper, C),
    ok = roadrunner_route_pause:arm(worker_noted),
    Worker = stream(Owner),
    Worker = roadrunner_route_pause:await(worker_noted),
    ok = stop_keeper(Keeper),
    true = roadrunner_route_keeper:delete_table(table(C)),
    ok = roadrunner_route_pause:resume(Worker, worker_noted),
    ?assertEqual({refused, 3}, result(Worker)),
    ok = end_worker(Worker),
    ok = ping(Owner).

%% --- the keeper crashes ---

keeper_crash_keeps_the_holders(_Config) ->
    %% The tables outlive the keeper: one taking over counts the holders
    %% still running and frees each as it ends, never letting in more than
    %% the ceiling meanwhile.
    {Keeper, C} = route(2, {queue, 5000, 10}),
    A = worker(C),
    B = worker(C),
    {ok, _} = result(A),
    {ok, _} = result(B),
    exit(Keeper, kill),
    {'EXIT', Keeper, killed} = receive_exit(Keeper),
    {ok, NewKeeper} = start_keeper(C, false),
    ?assertMatch(#{in_flight := 2, queued := 0}, stats(C)),
    Waiter = parked(NewKeeper, C),
    %% A killed holder and one that ends: each frees its slot once.
    exit(A, kill),
    {ok, _} = result(Waiter),
    ok = end_worker(B),
    ok = wait_in_flight(NewKeeper, C, 1),
    ok = stop_keeper(NewKeeper).

keeper_crash_refuses_the_waiters(_Config) ->
    {Keeper, C} = route(1, {queue, 5000, 10}),
    {ok, _} = result(holder(C)),
    Waiter = parked(Keeper, C),
    Worker = worker(C),
    ok = wait_queued(Keeper, C, 2),
    exit(Keeper, kill),
    ?assertEqual({refused, 1}, result(Waiter)),
    ?assertEqual({refused, 1}, result(Worker)),
    {'EXIT', Keeper, killed} = receive_exit(Keeper),
    {ok, NewKeeper} = start_keeper(C, false),
    ?assertMatch(#{in_flight := 1, queued := 0, throttled := 2}, stats(C)),
    ok = stop_keeper(NewKeeper).

keeper_gone_before_its_answer_frees_the_row(_Config) ->
    %% The keeper added the row and died before its `granted` went out:
    %% the caller, seeing it gone, removes the row, so the slot is not left
    %% to a request that never ran.
    {Keeper, C} = route(1, shed),
    ok = sys:suspend(Keeper),
    Asker = holder(C),
    ok = wait_mailbox(Keeper, Asker),
    true = ets:insert(slots(C), {1, Asker, Asker}),
    exit(Keeper, kill),
    {'EXIT', Keeper, killed} = receive_exit(Keeper),
    ?assertEqual({refused, 3}, result(Asker)),
    ?assertEqual([], ets:tab2list(slots(C))),
    true = roadrunner_route_keeper:delete_table(table(C)),
    %% And with the tables gone as well, as when its listener went too.
    {Keeper2, C2} = route(1, shed),
    ok = sys:suspend(Keeper2),
    Asker2 = holder(C2),
    ok = wait_mailbox(Keeper2, Asker2),
    true = roadrunner_route_keeper:delete_table(table(C2)),
    exit(Keeper2, kill),
    {'EXIT', Keeper2, killed} = receive_exit(Keeper2),
    ?assertEqual({refused, 3}, result(Asker2)).

keeper_gone_tells_the_next_keeper(_Config) ->
    %% The old keeper added a row and died before answering; the new one
    %% took the row over and parked a request behind it. The asker, seeing
    %% the old keeper gone, removes the row and tells the new keeper, which
    %% hands the slot to the request waiting.
    {Keeper, C} = route(1, {queue, 5000, 10}),
    ok = sys:suspend(Keeper),
    Asker = holder(C),
    ok = wait_mailbox(Keeper, Asker),
    true = ets:insert(slots(C), {1, Asker, Asker}),
    true = erlang:suspend_process(Asker),
    exit(Keeper, kill),
    {'EXIT', Keeper, killed} = receive_exit(Keeper),
    {ok, Next} = start_keeper(C, false),
    Waiter = parked(Next, C),
    true = erlang:resume_process(Asker),
    ?assertEqual({refused, 1}, result(Asker)),
    ?assertEqual({ok, 1}, result(Waiter)),
    ?assertMatch(#{in_flight := 1, queued := 0}, stats(C)),
    ok = stop_keeper(Next).

homes_work_while_the_keeper_restarts(_Config) ->
    %% With no keeper at all, a registered connection still takes its home;
    %% the keeper taking over watches every registered connection again.
    {Keeper, C} = route(2, shed),
    A = holder(C),
    {ok, 1} = result(A),
    B = holder(C),
    {ok, 2} = result(B),
    ok = release(B),
    exit(Keeper, kill),
    {'EXIT', Keeper, killed} = receive_exit(Keeper),
    ?assertEqual({ok, 2}, request(B)),
    ok = release(B),
    {ok, Next} = start_keeper(C, false),
    {monitors, Monitors} = erlang:process_info(Next, monitors),
    ?assertEqual(lists:sort([{process, A}, {process, B}]), lists:sort(Monitors)),
    exit(A, kill),
    ok = wait_in_flight(Next, C, 0),
    ?assertEqual([], ets:lookup(regs(C), A)),
    ok = stop_keeper(Next).

keeper_dies_before_a_new_home_is_answered(_Config) ->
    %% A connection's home is taken, so it asks the keeper, which makes key 2
    %% its home and dies before the answer goes out. The connection is
    %% refused and forgets its home: kept, it would take home 1 again while
    %% the keeper taking over knows it by 2, and the slot would never be
    %% freed when it died.
    {Keeper, C} = route(2, shed),
    Conn = holder(C),
    {ok, 1} = result(Conn),
    ok = release(Conn),
    Other = idle(),
    true = ets:insert(slots(C), {1, Other, Other}),
    ok = roadrunner_route_pause:arm(held, Keeper),
    Conn ! request,
    Keeper = roadrunner_route_pause:await(held),
    ?assertEqual([{Conn, 2}], ets:lookup(regs(C), Conn)),
    exit(Keeper, kill),
    {'EXIT', Keeper, killed} = receive_exit(Keeper),
    {ok, Next} = start_keeper(C, false),
    ?assertEqual({refused, 3}, result(Conn)),
    ?assertEqual(undefined, home(Conn, C)),
    true = ets:delete_object(slots(C), {1, Other, Other}),
    ok = rehomed_and_freed(Next, C, Conn).

takeover_finds_a_grant_never_answered(_Config) ->
    %% The old keeper added key 2's row for a connection whose home is 1 and
    %% died before answering. The keeper taking over keeps the connection's
    %% home as it is; the connection removes the row, forgets its home, and
    %% its next request asks the keeper.
    {Keeper, C} = route(2, shed),
    Conn = holder(C),
    {ok, 1} = result(Conn),
    ok = release(Conn),
    Other = idle(),
    true = ets:insert(slots(C), {1, Other, Other}),
    ok = sys:suspend(Keeper),
    Conn ! request,
    ok = wait_mailbox(Keeper, Conn),
    true = ets:insert(slots(C), {2, Conn, Conn}),
    true = erlang:suspend_process(Conn),
    exit(Keeper, kill),
    {'EXIT', Keeper, killed} = receive_exit(Keeper),
    {ok, Next} = start_keeper(C, false),
    ?assertEqual([{Conn, 1}], ets:lookup(regs(C), Conn)),
    true = erlang:resume_process(Conn),
    ?assertEqual({refused, 3}, result(Conn)),
    ?assertEqual(undefined, home(Conn, C)),
    true = ets:delete_object(slots(C), {1, Other, Other}),
    ok = rehomed_and_freed(Next, C, Conn).

takeover_frees_a_grant_of_a_dead_connection(_Config) ->
    %% As above, but the connection dies before it can remove that row: the
    %% keeper taking over frees it with the connection's home.
    {Keeper, C} = route(2, shed),
    Conn = holder(C),
    {ok, 1} = result(Conn),
    ok = release(Conn),
    Other = idle(),
    true = ets:insert(slots(C), {1, Other, Other}),
    ok = sys:suspend(Keeper),
    Conn ! request,
    ok = wait_mailbox(Keeper, Conn),
    true = ets:insert(slots(C), {2, Conn, Conn}),
    exit(Conn, kill),
    exit(Keeper, kill),
    {'EXIT', Keeper, killed} = receive_exit(Keeper),
    {ok, Next} = start_keeper(C, false),
    ok = wait_registered(C, 0),
    ?assertEqual([{1, Other, Other}], ets:tab2list(slots(C))),
    ok = stop_keeper(Next).

%% --- reloads ---

raised_ceiling_serves_the_queue(_Config) ->
    {Keeper, C} = route(1, {queue, 5000, 10}),
    {ok, _} = result(holder(C)),
    Waiters = [parked(Keeper, C) || _ <- [1, 2]],
    ok = roadrunner_route_keeper:configure(Keeper, counts(C), {3, 10}),
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
    ok = roadrunner_route_keeper:configure(Keeper, counts(C), {1, 0}),
    ok = release(A),
    ?assertEqual({refused, 3}, result(holder(C))),
    ok = release(B),
    {ok, _} = result(holder(C)),
    ok = stop_keeper(Keeper).

%% --- drain ---

draining_keeper_stops_when_empty(_Config) ->
    %% Draining, the keeper stops in the step it finds nothing running or
    %% waiting; one whose route came back before that stays.
    {Keeper, C} = route(1, shed),
    Holder = holder(C),
    {ok, _} = result(Holder),
    ok = roadrunner_route_keeper:set_draining(Keeper, true),
    ok = roadrunner_route_keeper:set_draining(Keeper, false),
    ok = release(Holder),
    _ = sys:get_state(Keeper),
    ?assert(is_process_alive(Keeper)),
    Next = holder(C),
    {ok, _} = result(Next),
    ok = roadrunner_route_keeper:set_draining(Keeper, true),
    _ = sys:get_state(Keeper),
    ?assert(is_process_alive(Keeper)),
    ok = release(Next),
    ?assertEqual({'EXIT', Keeper, {shutdown, drained}}, receive_exit(Keeper)),
    %% It answers nothing after that: a request still asking is refused.
    ?assertEqual({refused, 3}, result(holder(C))).

keeper_taking_over_a_drained_route_stops(_Config) ->
    %% A keeper started on a dropped route stops at once when nothing runs,
    %% and serves until the last request ends otherwise.
    {Keeper, C} = route(1, shed),
    ok = stop_keeper(Keeper),
    {ok, Idle} = start_keeper(C, true),
    ?assertEqual({'EXIT', Idle, {shutdown, drained}}, receive_exit(Idle)),
    {ok, Serving} = start_keeper(C, false),
    Holder = holder(C),
    {ok, _} = result(Holder),
    ok = stop_keeper(Serving),
    {ok, Draining} = start_keeper(C, true),
    _ = sys:get_state(Draining),
    ?assert(is_process_alive(Draining)),
    ok = release(Holder),
    ?assertEqual({'EXIT', Draining, {shutdown, drained}}, receive_exit(Draining)).

%% --- finding a free key ---

full_route_scan_finds_free_keys(_Config) ->
    %% Twenty connections hold keys 1 to 20; 17 and 19 come back without the
    %% keeper hearing of it. The keys it tries in turn from 1 are taken, so
    %% it scans the table, and as the route is over half full, every request
    %% that ends tells it its key from then on, until the route is back
    %% under a quarter of its ceiling.
    {Keeper, C} = route(20, shed),
    Conns = [
        begin
            Conn = conn(C),
            {ok, K} = request(Conn),
            {K, Conn}
        end
     || K <- lists:seq(1, 20)
    ],
    ok = release(conn_of(17, Conns)),
    ok = release(conn_of(19, Conns)),
    ?assertEqual({ok, 17}, result(holder(C))),
    ?assertEqual(4, gate(C) band 4),
    %% A release is reported now: its key goes back to the keeper, which
    %% skips it once the connection has taken it again.
    ok = sys:suspend(Keeper),
    Three = conn_of(3, Conns),
    ok = release(Three),
    ?assertEqual({message_queue_len, 1}, erlang:process_info(Keeper, message_queue_len)),
    ok = sys:resume(Keeper),
    ?assertEqual({ok, 3}, request(Three)),
    ?assertEqual({ok, 19}, result(holder(C))),
    %% Down to four running, under a quarter of twenty: releases go quiet.
    Held = [Conn || {K, Conn} <- Conns, K =/= 17, K =/= 19],
    lists:foreach(fun(Conn) -> ok = release(Conn) end, lists:sublist(Held, 16)),
    _ = sys:get_state(Keeper),
    ?assertEqual(0, gate(C)),
    ?assertMatch(#{in_flight := 4}, stats(C)),
    ok = stop_keeper(Keeper).

scan_under_half_keeps_releases_quiet(_Config) ->
    %% A scan of a route under half full finds the free keys without having
    %% the requests that end tell the keeper theirs.
    {Keeper, C} = route(40, shed),
    Conns = [
        begin
            Conn = conn(C),
            {ok, K} = request(Conn),
            {K, Conn}
        end
     || K <- lists:seq(1, 40)
    ],
    _ = [ok = release(Conn) || {K, Conn} <- Conns, K > 16],
    ?assertEqual({ok, 17}, result(holder(C))),
    ?assertEqual(0, gate(C)),
    ok = stop_keeper(Keeper).

%% --- the tables gone, stray messages ---

gone_table_refuses_and_releases(_Config) ->
    %% The listener is gone with its tables: a request is refused, a release
    %% has nothing to do.
    {Keeper, C} = route(1, shed),
    Holder = holder(C),
    {ok, K} = result(Holder),
    ok = stop_keeper(Keeper),
    true = roadrunner_route_keeper:delete_table(table(C)),
    ?assertEqual({refused, 3}, roadrunner_route_keeper:acquire(C)),
    ?assertEqual({refused, 3}, roadrunner_route_keeper:acquire(C, reset, self(), self())),
    ?assertEqual(ok, roadrunner_route_keeper:release(C, K)),
    %% Tables without a keeper refuse too.
    Bare = roadrunner_route_keeper:ceiling(
        {ets:new(slots, [public]), ets:new(regs, [public]), ets:new(intents, [public])},
        atomics:new(4, [{signed, false}]),
        {shed, #{retry_after => 2}},
        ?MODULE
    ),
    ok = atomics:put(counts(Bare), 1, 5),
    ?assertEqual({refused, 2}, roadrunner_route_keeper:acquire(Bare)).

unknown_messages_are_ignored(_Config) ->
    {Keeper, C} = route(1, shed),
    ?assertEqual({error, unknown_call}, gen_server:call(Keeper, nonsense)),
    ok = gen_server:cast(Keeper, nonsense),
    Keeper ! nonsense,
    Keeper ! {expire, make_ref()},
    Keeper ! {'DOWN', make_ref(), process, self(), normal},
    {ok, _} = result(holder(C)),
    ok = stop_keeper(Keeper).

idle_keeper_hibernates(_Config) ->
    %% A keeper that watched many connections keeps none of that heap once
    %% they are gone and it is idle: it hibernates.
    {Keeper, C} = route(500, shed),
    Conns = [holder(C) || _ <- lists:seq(1, 500)],
    lists:foreach(fun(Conn) -> {ok, _} = result(Conn) end, Conns),
    {total_heap_size, Grown} = erlang:process_info(Keeper, total_heap_size),
    lists:foreach(fun(Conn) -> exit(Conn, kill) end, Conns),
    ok = wait_in_flight(Keeper, C, 0),
    ok = wait_heap_below(Keeper, Grown div 4, erlang:monotonic_time(millisecond) + 10000),
    ok = stop_keeper(Keeper).

idle_connections_gone_leave_no_keys(_Config) ->
    %% Five hundred connections took a slot through the keeper and went
    %% idle, then all close. Their homes held no row, so the keeper keeps
    %% none of those keys for later grants: once it has looked again for
    %% late intents, it holds no more than a keeper that never served one.
    {Fresh, _} = route(1000, shed),
    {Keeper, C} = route(1000, shed),
    Conns = [holder(C) || _ <- lists:seq(1, 500)],
    lists:foreach(
        fun(Conn) ->
            {ok, _} = result(Conn),
            ok = release(Conn)
        end,
        Conns
    ),
    lists:foreach(fun(Conn) -> exit(Conn, kill) end, Conns),
    ok = wait_registered(C, 0),
    Keeper ! sweep,
    ?assertEqual(
        erts_debug:flat_size(sys:get_state(Fresh)), erts_debug:flat_size(sys:get_state(Keeper))
    ),
    ok = stop_keeper(Fresh),
    ok = stop_keeper(Keeper).

worker_killed_after_its_insert_is_freed(_Config) ->
    %% A worker killed right after inserting its row, its owner alive: the
    %% owner heard of the key before the row went in, and frees it on the
    %% worker's `'DOWN'`.
    {Keeper, C} = route(2, shed),
    Owner = registered_owner(Keeper, C),
    ok = roadrunner_route_pause:arm(worker_inserted),
    Worker = stream(Owner),
    Worker = roadrunner_route_pause:await(worker_inserted),
    exit(Worker, kill),
    ok = wait_rows(C, 0),
    ?assertEqual([], ets:tab2list(intents(C))),
    ok = stop_keeper(Keeper).

protocol_steps_keep_their_order(_Config) ->
    %% The order of these steps is what keeps a slot from leaking or a
    %% request from waiting beside a free slot; the races it settles are
    %% too short for a test to force between two steps with nothing in
    %% between, so the order itself is checked, in the order each function
    %% makes its calls.
    Forms = abstract_code(roadrunner_route_keeper),
    lists:foreach(
        fun({Function, Steps}) ->
            Calls = calls(function(Forms, Function)),
            Positions = [index(Step, Calls) || Step <- Steps],
            ?assertEqual(
                {Function, Steps}, {Function, [S || {S, P} <- lists:zip(Steps, Positions), P > 0]}
            ),
            ?assertEqual({Function, lists:usort(Positions)}, {Function, Positions})
        end,
        [
            %% A worker tells its owner the key, writes its intent, checks the
            %% owner still registered, and only then inserts its row.
            {{take_owned, 3}, [
                {erlang, send, 'Owner'},
                {ets, insert, 'Intents'},
                {ets, member, 'Regs'},
                {ets, insert_new, 'Slots'}
            ]},
            %% An owner frees a worker's row before its intent.
            {{worker_down, 1}, [{ets, delete_object, 'Slots'}, {ets, delete_object, 'Intents'}]},
            %% A dead owner's registration goes before its workers are watched.
            {{watched_down, 3}, [{ets, take, 'Regs'}, adopt]},
            %% So does the registration of an owner that handed it over.
            {{handed_over, 2}, [{ets, take, 'Regs'}, adopt]},
            %% A request that ends deletes its row before it reads the gate.
            {{release, 2}, [{ets, delete_object, 'Slots'}, notify]},
            %% The keeper closes the gate before its last look for room.
            {{no_room, 5}, [close, last_look, park]},
            %% A home is taken through an open gate, and checked after.
            {{take_home, 2}, [open, {ets, insert_new, 'Slots'}, kept]},
            %% A grant's row and registration go in before its answer.
            {{grant, 5}, [claim, hold, {erlang, send, 'Token'}]}
        ]
    ).

%% --- helpers ---

%% The abstract code of `Mod` as loaded (from its beam on disk when it is
%% cover compiled).
abstract_code(Mod) ->
    Beam =
        case code:which(Mod) of
            cover_compiled ->
                filename:join([code:lib_dir(roadrunner), "ebin", atom_to_list(Mod) ++ ".beam"]);
            Loaded ->
                Loaded
        end,
    {ok, {Mod, [{abstract_code, {raw_abstract_v1, Forms}}]}} = beam_lib:chunks(Beam, [abstract_code]),
    Forms.

function(Forms, {Name, Arity}) ->
    [Function] = [F || {function, _, N, A, _} = F <- Forms, N =:= Name, A =:= Arity],
    Function.

%% The calls in `Term` in the order they are made: a call's arguments
%% before the call, left to right. A remote call is named with its first
%% argument when that is a variable (the table or process it acts on).
calls(Term) ->
    lists:reverse(calls(Term, [])).

calls({call, _, Fun, Args} = Call, Acc) ->
    [call_name(Call) | calls(Args, calls(Fun, Acc))];
calls(Tuple, Acc) when is_tuple(Tuple) ->
    calls(tuple_to_list(Tuple), Acc);
calls([Head | Tail], Acc) ->
    calls(Tail, calls(Head, Acc));
calls(_Other, Acc) ->
    Acc.

call_name({call, _, {remote, _, {atom, _, M}, {atom, _, F}}, [{var, _, V} | _]}) -> {M, F, V};
call_name({call, _, {remote, _, {atom, _, M}, {atom, _, F}}, _Args}) -> {M, F};
call_name({call, _, {atom, _, F}, _Args}) -> F;
call_name(_Call) -> other.

%% The position of the first `Step` in `Calls`, or 0.
index(Step, Calls) ->
    index(Step, Calls, 1).

index(_Step, [], _N) -> 0;
index(Step, [Step | _], N) -> N;
index(Step, [_ | Rest], N) -> index(Step, Rest, N + 1).

%% Until the route holds no intent, or `Deadline` (ms) passes.
%% Until the (suspended) keeper has its look for late intents queued.
wait_sweep(Keeper, Deadline) ->
    {messages, Messages} = erlang:process_info(Keeper, messages),
    case lists:member(sweep, Messages) of
        true ->
            ok;
        false ->
            erlang:monotonic_time(millisecond) < Deadline orelse ct:fail(no_sweep),
            erlang:yield(),
            wait_sweep(Keeper, Deadline)
    end.

wait_no_intents(Ceiling, Deadline) ->
    case ets:tab2list(intents(Ceiling)) of
        [] ->
            ok;
        Intents ->
            erlang:monotonic_time(millisecond) < Deadline orelse ct:fail({intents_kept, Intents}),
            erlang:yield(),
            wait_no_intents(Ceiling, Deadline)
    end.

%% A connection that forgot its home asks the keeper, which makes the key
%% it grants the connection's home in both their views; killed holding it,
%% the connection leaves no row.
rehomed_and_freed(Keeper, Ceiling, Conn) ->
    {ok, K} = request(Conn),
    ?assertEqual(K, home(Conn, Ceiling)),
    ?assertEqual([{Conn, K}], ets:lookup(regs(Ceiling), Conn)),
    exit(Conn, kill),
    ok = wait_in_flight(Keeper, Ceiling, 0),
    stop_keeper(Keeper).

%% Until the keeper has `N` connections registered.
wait_registered(Ceiling, N) ->
    wait_registered(Ceiling, N, 1000000).

wait_registered(_Ceiling, N, 0) ->
    ct:fail({registered_never, N});
wait_registered(Ceiling, N, Tries) ->
    case ets:info(regs(Ceiling), size) - 1 of
        N ->
            ok;
        _ ->
            erlang:yield(),
            wait_registered(Ceiling, N, Tries - 1)
    end.

%% Until `Pid`'s heap is under `Words`, or `Deadline` (ms) passes.
wait_heap_below(Pid, Words, Deadline) ->
    case erlang:process_info(Pid, total_heap_size) of
        {total_heap_size, Size} when Size < Words ->
            ok;
        {total_heap_size, Size} ->
            erlang:monotonic_time(millisecond) < Deadline orelse
                ct:fail({heap_kept, Pid, Size, Words}),
            erlang:yield(),
            wait_heap_below(Pid, Words, Deadline)
    end.

%% A route of ceiling `Max` whose requests shed or queue (`{queue,
%% TimeoutMs, MaxQueued}`), and its keeper.
route(Max, Wait) ->
    {Mode, MaxQueued} =
        case Wait of
            shed -> {{shed, #{retry_after => 3}}, 0};
            {queue, Timeout, Queued} -> {{queue, #{timeout => Timeout}}, Queued}
        end,
    {Keeper, Table, Counts} = roadrunner_route_keeper:new(Max, MaxQueued, false),
    {Keeper, roadrunner_route_keeper:ceiling(Table, Counts, Mode, ?MODULE)}.

slots(Ceiling) ->
    element(2, Ceiling).

regs(Ceiling) ->
    element(3, Ceiling).

intents(Ceiling) ->
    element(4, Ceiling).

counts(Ceiling) ->
    element(5, Ceiling).

table(Ceiling) ->
    {slots(Ceiling), regs(Ceiling), intents(Ceiling)}.

stats(Ceiling) ->
    roadrunner_route_keeper:stats({table(Ceiling), counts(Ceiling)}).

%% The gate's bits, as requests read them.
gate(Ceiling) ->
    ets:lookup_element(regs(Ceiling), '$keeper', 3).

start_keeper(Ceiling, Draining) ->
    roadrunner_route_keeper:start_link(table(Ceiling), counts(Ceiling), Draining).

stop_keeper(Keeper) ->
    true = unlink(Keeper),
    exit(Keeper, kill),
    ok.

%% A process standing in for an HTTP/1.1 connection: as each of its
%% requests starts it asks for a slot, and hands the slot back when told.
conn(Ceiling) ->
    Self = self(),
    spawn(fun() -> conn_loop(Ceiling, Self, none) end).

conn_loop(Ceiling, Test, Held) ->
    receive
        request ->
            Result = roadrunner_route_keeper:acquire(Ceiling),
            Test ! {self(), Result},
            conn_loop(Ceiling, Test, Result);
        release ->
            {ok, K} = Held,
            ok = roadrunner_route_keeper:release(Ceiling, K),
            Test ! {self(), released},
            conn_loop(Ceiling, Test, none)
    end.

%% A connection whose first request is asking.
holder(Ceiling) ->
    Conn = conn(Ceiling),
    Conn ! request,
    Conn.

%% A connection's next request.
request(Conn) ->
    Conn ! request,
    result(Conn).

release(Conn) ->
    Conn ! release,
    released = result(Conn),
    ok.

%% The home slot a connection keeps for the route.
home(Conn, Ceiling) ->
    {dictionary, Dictionary} = erlang:process_info(Conn, dictionary),
    proplists:get_value({roadrunner_route_keeper, slots(Ceiling)}, Dictionary).

conn_of(K, Conns) ->
    {K, Conn} = lists:keyfind(K, 1, Conns),
    Conn.

%% A stream worker whose owner the keeper does not know, so it asks the
%% keeper: it stops waiting on its reset message or when its connection
%% goes, and holds what it got until it ends.
worker(Ceiling) ->
    worker(Ceiling, idle()).

worker(Ceiling, Conn) ->
    worker(Ceiling, Conn, Conn).

worker(Ceiling, Conn, Owner) ->
    Self = self(),
    spawn(fun() ->
        Self ! {self(), roadrunner_route_keeper:acquire(Ceiling, {reset, self()}, Conn, Owner)},
        receive
            stop -> ok
        end
    end).

idle() ->
    spawn(fun() ->
        receive
            stop -> ok
        end
    end).

%% A process standing in for an HTTP/2 connection or HTTP/3's loop: it
%% starts its stream workers and monitors them, keeps the key each one
%% takes on its own, and frees it when the worker ends, taking both in one
%% receive as the real ones do.
owner(Ceiling) ->
    Self = self(),
    spawn(fun() -> owner_loop(Ceiling, Self) end).

owner_loop(Ceiling, Test) ->
    receive
        {stream, Ref} ->
            Owner = self(),
            {Worker, _Mon} = spawn_monitor(fun() ->
                Test !
                    {
                        self(),
                        roadrunner_route_keeper:acquire(Ceiling, {reset, self()}, Owner, Owner)
                    },
                receive
                    stop -> ok
                end
            end),
            Test ! {Ref, Worker},
            owner_loop(Ceiling, Test);
        {roadrunner_route_slot, _Worker, _Ceiling, _K} = Note ->
            ok = roadrunner_route_keeper:noted(Note),
            owner_loop(Ceiling, Test);
        {'DOWN', _Mon, process, Worker, _Reason} ->
            ok = roadrunner_route_keeper:worker_down(Worker),
            owner_loop(Ceiling, Test);
        {ping, Ref} ->
            Test ! {Ref, pong},
            owner_loop(Ceiling, Test);
        {hand_over, Ref} ->
            ok = roadrunner_route_keeper:hand_over([Ceiling]),
            Test ! {Ref, handed_over},
            receive
                stop -> ok
            end
    end.

%% Have an owner hand its registration over, after which it answers none
%% of its workers.
hand_over(Owner) ->
    Ref = make_ref(),
    Owner ! {hand_over, Ref},
    receive
        {Ref, handed_over} -> ok
    after 5000 -> ct:fail({no_hand_over, Owner})
    end.

%% A round trip to an owner: it has handled everything sent to it before.
ping(Owner) ->
    Ref = make_ref(),
    Owner ! {ping, Ref},
    receive
        {Ref, pong} -> ok
    after 5000 -> ct:fail({no_pong, Owner})
    end.

%% A stream worker its owner starts.
stream(Owner) ->
    Ref = make_ref(),
    Owner ! {stream, Ref},
    receive
        {Ref, Worker} -> Worker
    after 5000 -> ct:fail({no_stream, Owner})
    end.

%% An owner the keeper registered: its first worker asked the keeper, and
%% has ended.
registered_owner(Keeper, Ceiling) ->
    Owner = owner(Ceiling),
    First = stream(Owner),
    {ok, _} = result(First),
    ok = end_worker(First),
    ok = wait_in_flight(Keeper, Ceiling, 0),
    Owner.

%% Kill an owner, until its keeper has handled its death.
kill_owner(Keeper, Ceiling, Owner) ->
    exit(Owner, kill),
    ok = wait_unregistered(Ceiling, Owner, 1000000),
    _ = sys:get_state(Keeper),
    ok.

wait_unregistered(_Ceiling, Owner, 0) ->
    ct:fail({still_registered, Owner});
wait_unregistered(Ceiling, Owner, Tries) ->
    case ets:member(regs(Ceiling), Owner) of
        false ->
            ok;
        true ->
            erlang:yield(),
            wait_unregistered(Ceiling, Owner, Tries - 1)
    end.

%% Until the route's table holds `N` rows, without asking the keeper.
wait_rows(Ceiling, N) ->
    wait_rows(Ceiling, N, 1000000).

wait_rows(_Ceiling, N, 0) ->
    ct:fail({rows_never, N});
wait_rows(Ceiling, N, Tries) ->
    case ets:info(slots(Ceiling), size) of
        N ->
            ok;
        _ ->
            erlang:yield(),
            wait_rows(Ceiling, N, Tries - 1)
    end.

end_worker(Worker) ->
    Mon = monitor(process, Worker),
    Worker ! stop,
    receive
        {'DOWN', Mon, process, Worker, _} -> ok
    after 5000 -> ct:fail({worker_kept, Worker})
    end.

%% A connection whose request the keeper parked.
parked(Keeper, Ceiling) ->
    #{queued := Queued} = stats(Ceiling),
    Pid = holder(Ceiling),
    ok = wait_queued(Keeper, Ceiling, Queued + 1),
    Pid.

%% Until the route has `N` requests waiting (or running). Each check is a
%% round trip to the keeper first, so it has handled every message sent to
%% it before.
wait_queued(Keeper, Ceiling, N) ->
    wait_stat(Keeper, Ceiling, queued, N, 1000000).

wait_in_flight(Keeper, Ceiling, N) ->
    wait_stat(Keeper, Ceiling, in_flight, N, 1000000).

wait_stat(_Keeper, _Ceiling, Stat, N, 0) ->
    ct:fail({never, Stat, N});
wait_stat(Keeper, Ceiling, Stat, N, Tries) ->
    _ = sys:get_state(Keeper),
    case stats(Ceiling) of
        #{Stat := N} ->
            ok;
        #{} ->
            erlang:yield(),
            wait_stat(Keeper, Ceiling, Stat, N, Tries - 1)
    end.

%% Until `Pid`'s acquire is in the (suspended) keeper's mailbox.
wait_mailbox(Keeper, Pid) ->
    wait_mailbox(Keeper, Pid, 1000000).

wait_mailbox(_Keeper, Pid, 0) ->
    ct:fail({never_asked, Pid});
wait_mailbox(Keeper, Pid, Tries) ->
    {messages, Messages} = erlang:process_info(Keeper, messages),
    case [P || {acquire, _Token, P, _Kind, _Wait} <- Messages, P =:= Pid] of
        [_] ->
            ok;
        [] ->
            erlang:yield(),
            wait_mailbox(Keeper, Pid, Tries - 1)
    end.

result(Pid) ->
    receive
        {Pid, Result} -> Result
    after 5000 -> ct:fail({no_result, Pid})
    end.

receive_exit(Pid) ->
    receive
        {'EXIT', Pid, _} = Exit -> Exit
    after 5000 -> ct:fail({no_exit, Pid})
    end.
