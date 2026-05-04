-module(roadrunner_conn_loop_h2_tests).
-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Phase H1 stub — `enter/5` sends an empty SETTINGS frame, a
%% GOAWAY(NO_ERROR), releases the listener slot, and closes the
%% socket. Subsequent phases will replace this with the real h2
%% connection process.
%% =============================================================================

enter_sends_settings_then_goaway_and_closes_test() ->
    %% `enter/5` fires `[roadrunner, listener, conn_close]` telemetry —
    %% needs the telemetry app started for the eunit isolated path.
    {ok, _} = application:ensure_all_started(telemetry),
    %% Use the {fake, Pid} transport so `send`/`close` deliver
    %% messages back to the test process and we can assert the wire
    %% bytes the stub emits.
    Self = self(),
    ProtoOpts = #{
        client_counter => atomics:new(1, [{signed, false}]),
        listener_name => h2_stub_test
    },
    Counter = maps:get(client_counter, ProtoOpts),
    %% Pre-acquire a slot so `release_slot` has something to release —
    %% mirrors the acceptor's `try_acquire_slot` happening upstream.
    ok = atomics:add(Counter, 1, 1),
    Sock = {fake, Self},
    Pid = spawn(fun() ->
        roadrunner_conn_loop_h2:enter(
            Sock, ProtoOpts, h2_stub_test, undefined, erlang:monotonic_time()
        )
    end),
    Ref = monitor(process, Pid),
    Sent = collect_sends(150),
    %% First frame: empty SETTINGS (length=0, type=4, flags=0, stream id=0).
    ?assertMatch(<<0, 0, 0, 4, 0, 0, 0, 0, 0, _/binary>>, Sent),
    %% Followed by GOAWAY (type 7, payload 8 bytes: last_stream_id=0 +
    %% error_code=NO_ERROR).
    ?assertMatch(
        <<_:9/binary, 0, 0, 8, 7, 0, 0, 0, 0, 0, 0:32, 0:32>>,
        Sent
    ),
    %% Confirm the close-message reached the fake owner.
    receive
        {roadrunner_fake_close, _} -> ok
    after 200 -> error(no_close_message)
    end,
    %% Process exits normal.
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 200 -> error(process_did_not_exit)
    end,
    %% Slot was released — counter decremented back to 0.
    ?assertEqual(0, atomics:get(Counter, 1)).

%% --- helpers ---

collect_sends(Timeout) ->
    iolist_to_binary(collect_sends(Timeout, [])).

collect_sends(Timeout, Acc) ->
    receive
        {roadrunner_fake_send, _Pid, Data} ->
            collect_sends(0, [Acc, Data])
    after Timeout ->
        Acc
    end.
