-module(roadrunner_conn_loop_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Phase 1 + Phase 2 — awaiting_shoot + read_request phase.
%%
%% Asserts:
%%   - `start/2` returns `{ok, Pid}` shape.
%%   - `proc_lib:get_label/1` reflects awaiting_shoot before `shoot`.
%%   - The conn joins the drain pg group.
%%   - `Pid ! shoot` fires `listener_accept` telemetry.
%%   - `Pid ! {roadrunner_drain, _}` exits cleanly in awaiting_shoot
%%     (no telemetry — accept hadn't fired yet).
%%   - Stray info messages don't crash the conn.
%%   - **Phase 2** — after `shoot`, the conn enters reading_request,
%%     parses bytes via `roadrunner_http1:parse_request/1`, sends 400 on
%%     malformed input, sends 408 when the request_timeout fires
%%     before any bytes arrive, exits cleanly on drain mid-recv,
%%     stays alive across stray messages, exits silently on TCP close
%%     mid-headers.
%%   - Slot release on every clean exit path.
%%   - Telemetry pairing: every `accept` is paired with a `conn_close`.
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
    %% Loop sets a label that includes the explicit `awaiting_shoot`
    %% phase atom; use it to prove which branch was taken.
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
    ?assertEqual([Pid], pg:get_members({roadrunner_drain, Name})),
    drain_then_wait(Pid).

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
    after 2000 -> error(no_normal_exit)
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

slot_released_on_drain_in_awaiting_shoot_test() ->
    ensure_pg(),
    Counter = atomics:new(1, [{signed, false}]),
    _ = atomics:add(Counter, 1, 1),
    Opts = (fake_opts(slot))#{client_counter := Counter},
    {ok, Pid} = roadrunner_conn_loop:start({fake, spawn_sink()}, Opts),
    Ref = monitor(process, Pid),
    Pid ! {roadrunner_drain, infinity},
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    ?assertEqual(0, atomics:get(Counter, 1)).

%% --- Phase 2 — read_request phase ---

shoot_then_valid_request_parses_and_exits_normally_test() ->
    %% Phase 2 placeholder — the conn parses the request, then exits
    %% cleanly without dispatching (Phase 3 will dispatch). We assert
    %% it gets past the parse without writing 400 to the wire.
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_active_sink_with_send_log(
        Self, Tag, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"
    ),
    {ok, Pid} = roadrunner_conn_loop:start({fake, Sink}, fake_opts(parse_ok)),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    %% No 4xx written — request parsed clean.
    ?assertEqual(<<>>, iolist_to_binary(collect_sends(Tag, 50))),
    Sink ! stop.

bad_request_writes_400_then_exits_test() ->
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_active_sink_with_send_log(
        Self, Tag, ~"NOT-A-VALID-REQUEST-LINE\r\n\r\n"
    ),
    {ok, Pid} = roadrunner_conn_loop:start({fake, Sink}, fake_opts(bad_400)),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    ?assertMatch(<<"HTTP/1.1 400", _/binary>>, Sent),
    Sink ! stop.

request_timeout_writes_408_then_exits_test() ->
    %% No bytes — the request_timeout `after` clause should fire and
    %% the conn should write 408 before exiting (this is "first request
    %% on fresh conn" — Phase 2 only sees first; keep_alive lands in
    %% Phase 3).
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_silent_sink_with_send_log(Self, Tag),
    Opts = (fake_opts(timeout_408))#{request_timeout := 50},
    {ok, Pid} = roadrunner_conn_loop:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    ?assertMatch(<<"HTTP/1.1 408", _/binary>>, Sent),
    Sink ! stop.

drain_during_read_request_exits_silently_test() ->
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_silent_sink_with_send_log(Self, Tag),
    {ok, Pid} = roadrunner_conn_loop:start({fake, Sink}, fake_opts(drain_mid)),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    %% Tiny sleep so the conn has reached recv_request_bytes before
    %% we send drain. Without this, drain could land in the mailbox
    %% before `shoot` is consumed, exercising the awaiting_shoot drain
    %% branch instead of the read_request one.
    timer:sleep(20),
    Pid ! {roadrunner_drain, infinity},
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    %% No 4xx written — drain bypasses the response.
    ?assertEqual(<<>>, iolist_to_binary(collect_sends(Tag, 50))),
    Sink ! stop.

tcp_closed_during_read_request_exits_silently_test() ->
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_silent_sink_with_send_log(Self, Tag),
    {ok, Pid} = roadrunner_conn_loop:start({fake, Sink}, fake_opts(closed)),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    timer:sleep(20),
    Pid ! {roadrunner_fake_closed, undefined},
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    %% No response — peer closed mid-headers.
    ?assertEqual(<<>>, iolist_to_binary(collect_sends(Tag, 50))),
    Sink ! stop.

tcp_error_during_read_request_exits_silently_test() ->
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_silent_sink_with_send_log(Self, Tag),
    {ok, Pid} = roadrunner_conn_loop:start({fake, Sink}, fake_opts(tcp_err)),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    timer:sleep(20),
    Pid ! {roadrunner_fake_error, undefined, econnreset},
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    %% No response — TCP-level error, peer's gone.
    ?assertEqual(<<>>, iolist_to_binary(collect_sends(Tag, 50))),
    Sink ! stop.

partial_request_then_remainder_parses_test() ->
    %% Drives the `{more, _}` branch — first packet has only the request
    %% line, second packet completes the headers. Both must parse cleanly.
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_active_sink_two_chunks_with_log(
        Self, Tag, ~"GET / HTTP/1.1\r\n", ~"Host: x\r\n\r\n"
    ),
    {ok, Pid} = roadrunner_conn_loop:start({fake, Sink}, fake_opts(partial)),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    %% No 4xx — split request parsed clean.
    ?assertEqual(<<>>, iolist_to_binary(collect_sends(Tag, 50))),
    Sink ! stop.

setopts_on_dead_socket_exits_silently_test() ->
    %% A dead sink causes `roadrunner_transport:setopts/2` to return
    %% `{error, einval}` (the fake transport mirrors real-socket
    %% behavior). The conn must exit cleanly without writing.
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    DeadSink = spawn(fun() -> ok end),
    %% Wait for the sink to actually exit so its is_process_alive check
    %% is false by the time the conn calls setopts.
    DeadRef = monitor(process, DeadSink),
    receive
        {'DOWN', DeadRef, process, DeadSink, _} -> ok
    after 1000 -> error(dead_sink_didnt_exit)
    end,
    %% Use a separate live sink for the conn's send/close path so
    %% `send_request_timeout`-style writes don't crash if Phase 2's
    %% timeout `after` clause races. We pick the dead sink as the
    %% socket peer, so setopts targets it and fails.
    attach_telemetry(Tag, [
        [roadrunner, listener, accept],
        [roadrunner, listener, conn_close]
    ]),
    {ok, Pid} = roadrunner_conn_loop:start({fake, DeadSink}, fake_opts(deadsock)),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    %% accept fired (shoot transitioned to read_request_phase) and
    %% conn_close fired on exit_clean.
    ?assertEqual([roadrunner, listener, accept], next_event_name(Tag, 200)),
    ?assertEqual([roadrunner, listener, conn_close], next_event_name(Tag, 200)),
    detach_telemetry(Tag),
    _ = Self.

stray_msg_during_read_request_is_ignored_test() ->
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_silent_sink_with_send_log(Self, Tag),
    {ok, Pid} = roadrunner_conn_loop:start({fake, Sink}, fake_opts(stray2)),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    timer:sleep(20),
    Pid ! {junk, ref},
    Pid ! 42,
    timer:sleep(20),
    ?assert(is_process_alive(Pid)),
    Pid ! {roadrunner_drain, infinity},
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    Sink ! stop.

shoot_fires_accept_paired_with_conn_close_test() ->
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    attach_telemetry(Tag, [
        [roadrunner, listener, accept],
        [roadrunner, listener, conn_close]
    ]),
    Sink = spawn_active_sink_with_send_log(
        Self, Tag, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"
    ),
    Opts = (fake_opts(accept))#{listener_name => accept},
    {ok, Pid} = roadrunner_conn_loop:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    %% accept fired before close, both for the same listener
    ?assertEqual([roadrunner, listener, accept], next_event_name(Tag, 200)),
    ?assertEqual([roadrunner, listener, conn_close], next_event_name(Tag, 200)),
    detach_telemetry(Tag),
    Sink ! stop.

slot_released_after_parse_exit_test() ->
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_active_sink_with_send_log(
        Self, Tag, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"
    ),
    Counter = atomics:new(1, [{signed, false}]),
    _ = atomics:add(Counter, 1, 1),
    Opts = (fake_opts(slot_parse))#{client_counter := Counter},
    {ok, Pid} = roadrunner_conn_loop:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    ?assertEqual(0, atomics:get(Counter, 1)),
    Sink ! stop.

%% --- helpers ---

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

%% Plain sink — discards every message. Used when the test doesn't need
%% to drive bytes or capture sends; just absorbs the conn's
%% close/setopts/send chatter so it doesn't pollute the test runner.
spawn_sink() ->
    spawn(fun sink_loop/0).

sink_loop() ->
    receive
        stop -> ok;
        _ -> sink_loop()
    end.

%% Active-mode sink — when the conn arms `{active, once}`, this sink
%% delivers a single `{roadrunner_fake_data, _, Bytes}` event back to
%% the conn (simulating one inbound TCP packet). Subsequent setopts
%% calls are accepted but no further data is delivered. Also forwards
%% `roadrunner_fake_send` to `Logger` tagged with `Tag` so the test
%% can assert what the conn wrote.
spawn_active_sink_with_send_log(Logger, Tag, Bytes) ->
    spawn(fun() -> active_sink_loop(Logger, Tag, Bytes, false) end).

active_sink_loop(Logger, Tag, Bytes, Delivered) ->
    receive
        stop ->
            ok;
        {roadrunner_fake_setopts, ConnPid, _Opts} when not Delivered ->
            ConnPid ! {roadrunner_fake_data, undefined, Bytes},
            active_sink_loop(Logger, Tag, Bytes, true);
        {roadrunner_fake_setopts, _ConnPid, _Opts} ->
            active_sink_loop(Logger, Tag, Bytes, Delivered);
        {roadrunner_fake_send, _Pid, Data} ->
            Logger ! {Tag, sent, Data},
            active_sink_loop(Logger, Tag, Bytes, Delivered);
        _Other ->
            active_sink_loop(Logger, Tag, Bytes, Delivered)
    end.

%% Two-chunk active sink — exercises the `{more, _}` parse branch.
%% First setopts arms → deliver Chunk1. Second setopts arms → deliver
%% Chunk2. Subsequent setopts (none expected) accepted but no data.
spawn_active_sink_two_chunks_with_log(Logger, Tag, Chunk1, Chunk2) ->
    spawn(fun() -> two_chunk_sink_loop(Logger, Tag, [Chunk1, Chunk2]) end).

two_chunk_sink_loop(Logger, Tag, Remaining) ->
    receive
        stop ->
            ok;
        {roadrunner_fake_setopts, ConnPid, _Opts} ->
            case Remaining of
                [Bytes | Rest] ->
                    ConnPid ! {roadrunner_fake_data, undefined, Bytes},
                    two_chunk_sink_loop(Logger, Tag, Rest);
                [] ->
                    two_chunk_sink_loop(Logger, Tag, [])
            end;
        {roadrunner_fake_send, _Pid, Data} ->
            Logger ! {Tag, sent, Data},
            two_chunk_sink_loop(Logger, Tag, Remaining);
        _Other ->
            two_chunk_sink_loop(Logger, Tag, Remaining)
    end.

%% Silent sink — never delivers data. Used to exercise request_timeout
%% and drain-mid-recv. Forwards sends so the test can assert.
spawn_silent_sink_with_send_log(Logger, Tag) ->
    spawn(fun() -> silent_sink_loop(Logger, Tag) end).

silent_sink_loop(Logger, Tag) ->
    receive
        stop ->
            ok;
        {roadrunner_fake_send, _Pid, Data} ->
            Logger ! {Tag, sent, Data},
            silent_sink_loop(Logger, Tag);
        _Other ->
            silent_sink_loop(Logger, Tag)
    end.

drain_then_wait(Pid) ->
    Ref = monitor(process, Pid),
    Pid ! {roadrunner_drain, infinity},
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    after 2000 ->
        error(no_exit)
    end.

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

collect_sends(Tag, Timeout) ->
    collect_sends_loop(Tag, [], Timeout).

collect_sends_loop(Tag, Acc, Timeout) ->
    receive
        {Tag, sent, Data} -> collect_sends_loop(Tag, [Data | Acc], Timeout)
    after Timeout -> lists:reverse(Acc)
    end.
