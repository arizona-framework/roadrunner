-module(cactus_conn_statem_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Phase 4 skeleton smoke — drives init/1 -> awaiting_shoot -> shoot -> exit.
%% Uses the fake transport with a throwaway sink process as the message
%% target so the gen_statem's terminate/3 -> cactus_transport:close/1
%% never sends `cactus_fake_close` to the test runner's mailbox (which
%% would contaminate later tests in the suite).
%% =============================================================================

skeleton_init_then_shoot_terminates_cleanly_test() ->
    ensure_pg(),
    Sink = spawn_sink(),
    {ok, Pid} = cactus_conn_statem:start(
        {fake, Sink}, fake_proto_opts(skeleton_test)
    ),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 1000 ->
        error(skeleton_did_not_terminate)
    end,
    stop_sink(Sink).

skeleton_join_drain_group_skipped_when_pg_absent_test() ->
    %% Even with no pg scope the skeleton must not crash on init.
    %% Use an undefined listener_name so join_drain_group/1 short-
    %% circuits before the whereis check anyway.
    Sink = spawn_sink(),
    {ok, Pid} = cactus_conn_statem:start(
        {fake, Sink}, fake_proto_opts_no_listener()
    ),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 1000 ->
        error(skeleton_did_not_terminate)
    end,
    stop_sink(Sink).

skeleton_listener_accept_and_conn_close_fire_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    HandlerId = make_ref(),
    ok = telemetry:attach_many(
        HandlerId,
        [[cactus, listener, accept], [cactus, listener, conn_close]],
        fun(Event, M, Md, _) -> Self ! {ev, Event, M, Md} end,
        undefined
    ),
    try
        ensure_pg(),
        Sink = spawn_sink(),
        {ok, Pid} = cactus_conn_statem:start(
            {fake, Sink}, fake_proto_opts(skeleton_telemetry_test)
        ),
        Ref = monitor(process, Pid),
        Pid ! shoot,
        receive
            {'DOWN', Ref, process, Pid, normal} -> ok
        after 1000 ->
            error(skeleton_did_not_terminate)
        end,
        receive
            {ev, [cactus, listener, accept], _, AcceptMd} ->
                ?assertEqual(skeleton_telemetry_test, maps:get(listener_name, AcceptMd))
        after 1000 -> error(no_accept)
        end,
        receive
            {ev, [cactus, listener, conn_close], CloseM, CloseMd} ->
                ?assert(is_integer(maps:get(duration, CloseM))),
                ?assertEqual(0, maps:get(requests_served, CloseMd))
        after 1000 -> error(no_close)
        end,
        stop_sink(Sink)
    after
        telemetry:detach(HandlerId)
    end.

%% --- helpers ---

ensure_pg() ->
    case whereis(pg) of
        undefined ->
            {ok, _} = pg:start_link(),
            ok;
        _ ->
            ok
    end.

%% Spawn a tiny mailbox-sink process: receives all `cactus_fake_send`
%% / `cactus_fake_recv` / `cactus_fake_close` messages and discards
%% them. Stops on `stop`. Used as the fake-transport owner so
%% terminate-time close messages never land in the test runner's mailbox.
spawn_sink() ->
    spawn(fun sink_loop/0).

stop_sink(Pid) ->
    Pid ! stop.

sink_loop() ->
    receive
        stop -> ok;
        _ -> sink_loop()
    end.

fake_proto_opts(ListenerName) ->
    #{
        dispatch => {handler, cactus_hello_handler},
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

fake_proto_opts_no_listener() ->
    Opts = fake_proto_opts(skip),
    maps:remove(listener_name, Opts).
