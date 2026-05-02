-module(roadrunner_conn_loop_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Phase 1 — awaiting_shoot only.
%%
%% Asserts the new `roadrunner_conn_loop` module's startup + cleanup
%% contract:
%%
%%   1. `start/2` returns `{ok, Pid}` matching `gen_statem:start/3`'s shape.
%%   2. `proc_lib:get_label/1` shows the conn in `awaiting_shoot` phase.
%%   3. The conn joins the drain pg group (proven via `pg:get_members/1`).
%%   4. `Pid ! shoot` triggers `listener_accept` telemetry, then a clean
%%      `normal` exit paired with `listener_conn_close`.
%%   5. `Pid ! {roadrunner_drain, _}` while in awaiting_shoot triggers a
%%      clean `normal` exit with NO telemetry (accept never fired).
%%   6. Stray info messages do not crash the conn.
%%
%% Subsequent phases of the conn-loop refactor lift the read-request,
%% read-body, dispatch, and finishing phases; their tests will live
%% here too (parametrized in Phase 6 of the plan).
%% =============================================================================

start_returns_ok_pid_test() ->
    ensure_pg(),
    {ok, Pid} = roadrunner_conn_loop:start({fake, spawn_sink()}, fake_opts(start_ok)),
    ?assert(is_pid(Pid)),
    ?assert(is_process_alive(Pid)),
    drain_then_wait(Pid).

conn_start_dispatches_to_loop_when_conn_impl_loop_test() ->
    ensure_pg(),
    Opts = (fake_opts(dispatch))#{conn_impl => loop},
    {ok, Pid} = roadrunner_conn:start({fake, spawn_sink()}, Opts),
    %% Loop sets a different label than the gen_statem variant — it
    %% includes the explicit `awaiting_shoot` phase atom. Use it to
    %% prove which branch was taken.
    ?assertMatch({roadrunner_conn, awaiting_shoot, dispatch}, proc_lib:get_label(Pid)),
    drain_then_wait(Pid).

awaiting_shoot_label_set_test() ->
    ensure_pg(),
    {ok, Pid} = roadrunner_conn_loop:start({fake, spawn_sink()}, fake_opts(label)),
    ?assertMatch({roadrunner_conn, awaiting_shoot, label}, proc_lib:get_label(Pid)),
    drain_then_wait(Pid).

awaiting_shoot_joins_drain_group_test() ->
    ensure_pg(),
    Name = drain_join,
    {ok, Pid} = roadrunner_conn_loop:start({fake, spawn_sink()}, fake_opts(Name)),
    %% pg:get_members/1 takes the {Group, ListenerName} tag the conn
    %% joined under via roadrunner_conn:join_drain_group/1.
    ?assertEqual([Pid], pg:get_members({roadrunner_drain, Name})),
    drain_then_wait(Pid).

shoot_fires_accept_then_exits_normally_test() ->
    ensure_pg(),
    Tag = make_ref(),
    attach_telemetry(Tag, [
        [roadrunner, listener, accept],
        [roadrunner, listener, conn_close]
    ]),
    Opts = (fake_opts(accept))#{listener_name => accept},
    {ok, Pid} = roadrunner_conn_loop:start({fake, spawn_sink()}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 ->
        error(no_normal_exit)
    end,
    %% accept fired before close, both for the same listener
    ?assertEqual([roadrunner, listener, accept], next_event_name(Tag, 200)),
    ?assertEqual([roadrunner, listener, conn_close], next_event_name(Tag, 200)),
    detach_telemetry(Tag).

drain_in_awaiting_shoot_exits_without_telemetry_test() ->
    ensure_pg(),
    Tag = make_ref(),
    attach_telemetry(Tag, [
        [roadrunner, listener, accept],
        [roadrunner, listener, conn_close]
    ]),
    {ok, Pid} = roadrunner_conn_loop:start({fake, spawn_sink()}, fake_opts(drain_pre_shoot)),
    Ref = monitor(process, Pid),
    Pid ! {roadrunner_drain, infinity},
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 ->
        error(no_normal_exit)
    end,
    %% Neither accept nor conn_close fired — accept pairs with `shoot`,
    %% which never arrived.
    ?assertEqual(timeout, next_event_name(Tag, 100)),
    detach_telemetry(Tag).

stray_msg_in_awaiting_shoot_is_ignored_test() ->
    ensure_pg(),
    {ok, Pid} = roadrunner_conn_loop:start({fake, spawn_sink()}, fake_opts(stray)),
    Pid ! {stray_msg_from_buggy_lib, make_ref()},
    Pid ! 12345,
    Pid ! [some, list],
    %% Conn must still be alive after a barrage of stray messages.
    timer:sleep(20),
    ?assert(is_process_alive(Pid)),
    drain_then_wait(Pid).

slot_released_on_drain_exit_test() ->
    ensure_pg(),
    Counter = atomics:new(1, [{signed, false}]),
    %% Acceptor would have bumped the counter before spawn — simulate that.
    _ = atomics:add(Counter, 1, 1),
    Opts = (fake_opts(slot))#{client_counter := Counter},
    {ok, Pid} = roadrunner_conn_loop:start({fake, spawn_sink()}, Opts),
    Ref = monitor(process, Pid),
    Pid ! {roadrunner_drain, infinity},
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 ->
        error(no_normal_exit)
    end,
    ?assertEqual(0, atomics:get(Counter, 1)).

slot_released_on_shoot_exit_test() ->
    ensure_pg(),
    Counter = atomics:new(1, [{signed, false}]),
    _ = atomics:add(Counter, 1, 1),
    Opts = (fake_opts(slot_shoot))#{client_counter := Counter},
    {ok, Pid} = roadrunner_conn_loop:start({fake, spawn_sink()}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 ->
        error(no_normal_exit)
    end,
    ?assertEqual(0, atomics:get(Counter, 1)).

%% --- helpers (mirroring conn_statem_tests.erl shape) ---

ensure_pg() ->
    case whereis(pg) of
        undefined ->
            {ok, _} = pg:start_link(),
            ok;
        _ ->
            ok
    end.

fake_opts(ListenerName) ->
    #{
        dispatch => {handler, roadrunner_hello_handler},
        middlewares => [],
        max_content_length => 10485760,
        request_timeout => 5000,
        keep_alive_timeout => 5000,
        max_keep_alive_request => 100,
        max_clients => 10,
        client_counter => atomics:new(1, [{signed, false}]),
        requests_counter => atomics:new(1, [{signed, false}]),
        minimum_bytes_per_second => 0,
        body_buffering => auto,
        listener_name => ListenerName
    }.

%% Discards every `{roadrunner_fake_*, ...}` message so close/send
%% notifications from the conn don't cross-contaminate sibling tests'
%% mailboxes (the test runner is shared across eunit tests).
spawn_sink() ->
    spawn(fun sink_loop/0).

sink_loop() ->
    receive
        stop -> ok;
        _ -> sink_loop()
    end.

drain_then_wait(Pid) ->
    Ref = monitor(process, Pid),
    Pid ! {roadrunner_drain, infinity},
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    after 2000 ->
        error(no_exit)
    end.

%% Each handler forwards the matched event to the test runner with the
%% Tag — scoped so eunit's shared mailbox doesn't cross-contaminate.
attach_telemetry(Tag, EventNames) ->
    Self = self(),
    [
        telemetry:attach(
            {?MODULE, Tag, Event},
            Event,
            fun(EvName, _Measurements, Metadata, _) ->
                Self ! {Tag, EvName, Metadata}
            end,
            undefined
        )
     || Event <- EventNames
    ].

detach_telemetry(Tag) ->
    [
        telemetry:detach({?MODULE, Tag, Event})
     || Event <- [
            [roadrunner, listener, accept],
            [roadrunner, listener, conn_close],
            [roadrunner, request, start],
            [roadrunner, request, stop],
            [roadrunner, request, exception]
        ]
    ].

next_event_name(Tag, Timeout) ->
    receive
        {Tag, Name, _Metadata} -> Name
    after Timeout ->
        timeout
    end.
