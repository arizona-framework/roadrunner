-module(roadrunner_conn_loop_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Connection-loop tests — awaiting_shoot + read_request + dispatch.
%%
%% Asserts:
%%   - `start/2` returns `{ok, Pid}` shape.
%%   - `proc_lib:get_label/1` reflects awaiting_shoot before `shoot`.
%%   - The conn joins the drain pg group.
%%   - `Pid ! shoot` fires `listener_accept` telemetry.
%%   - `Pid ! {roadrunner_drain, _}` exits cleanly in awaiting_shoot
%%     (no telemetry — accept hadn't fired yet).
%%   - Stray info messages don't crash the conn.
%%   - After `shoot`, the conn enters reading_request, parses bytes
%%     via `roadrunner_http1:parse_request/1`, sends 400 on malformed
%%     input, sends 408 when the request_timeout fires before any
%%     bytes arrive, exits cleanly on drain mid-recv, stays alive
%%     across stray messages, exits silently on TCP close mid-headers.
%%   - Slot release on every clean exit path.
%%   - Telemetry pairing: every `accept` is paired with a `conn_close`.
%% =============================================================================

start_returns_ok_pid_test() ->
    ensure_pg(),
    {ok, Pid} = roadrunner_conn_loop:start({fake, spawn_sink()}, fake_opts(start_ok)),
    ?assert(is_pid(Pid)),
    ?assert(is_process_alive(Pid)),
    drain_then_wait(Pid).

conn_start_routes_through_loop_test() ->
    ensure_pg(),
    {ok, Pid} = roadrunner_conn:start({fake, spawn_sink()}, fake_opts(dispatch)),
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

%% --- read_request + dispatch ---

shoot_then_valid_request_dispatches_hello_handler_test() ->
    %% The conn parses the request, dispatches the configured handler
    %% (default `roadrunner_hello_handler`), writes the 200 response,
    %% and exits cleanly.
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
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    ?assertMatch(<<"HTTP/1.1 200", _/binary>>, Sent),
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
    %% the conn should write 408 before exiting.
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

tcp_closed_during_passive_recv_exits_silently_test() ->
    %% Phase A' default path uses passive recv. TCP close is signaled
    %% by `gen_tcp:recv` returning `{error, closed}` — script the sink
    %% to reply with that.
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_scripted_sink(Self, Tag, [{passive, {error, closed}}]),
    {ok, Pid} = roadrunner_conn_loop:start({fake, Sink}, fake_opts(closed)),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    %% No response — peer closed mid-headers.
    ?assertEqual(<<>>, iolist_to_binary(collect_sends(Tag, 50))),
    Sink ! stop.

tcp_error_during_passive_recv_exits_silently_test() ->
    %% Phase A' passive path: any non-timeout, non-closed recv error
    %% (e.g. econnreset) → silent exit.
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_scripted_sink(Self, Tag, [{passive, {error, econnreset}}]),
    {ok, Pid} = roadrunner_conn_loop:start({fake, Sink}, fake_opts(tcp_err)),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    ?assertEqual(<<>>, iolist_to_binary(collect_sends(Tag, 50))),
    Sink ! stop.

partial_request_then_remainder_parses_test() ->
    %% Drives the `{more, _}` branch — first packet has only the request
    %% line, second packet completes the headers. Both must parse + the
    %% handler dispatches a 200.
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
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    ?assertMatch(<<"HTTP/1.1 200", _/binary>>, Sent),
    Sink ! stop.

setopts_on_dead_socket_exits_silently_test() ->
    %% A dead sink causes `roadrunner_transport:setopts/2` to return
    %% `{error, einval}` (the fake transport mirrors real-socket
    %% behavior). The conn must exit cleanly without writing.
    %%
    %% Phase A' default path uses passive recv (no setopts call) —
    %% so to exercise this code path the test opts into the
    %% active-mode `recv_with_hibernate` branch via `hibernate_after`.
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    DeadSink = spawn(fun() -> ok end),
    DeadRef = monitor(process, DeadSink),
    receive
        {'DOWN', DeadRef, process, DeadSink, _} -> ok
    after 1000 -> error(dead_sink_didnt_exit)
    end,
    attach_telemetry(Tag, [
        [roadrunner, listener, accept],
        [roadrunner, listener, conn_close]
    ]),
    Opts = (fake_opts(deadsock))#{hibernate_after => 5000},
    {ok, Pid} = roadrunner_conn_loop:start({fake, DeadSink}, Opts),
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

slowloris_during_passive_recv_drops_client_test() ->
    %% Passive recv path: deliver a tiny amount of bytes after the
    %% 1 s grace, with `min_rate` set high enough that the running
    %% average falls under it. The conn must close silently.
    ensure_pg(),
    Self = self(),
    %% Sink that waits past the grace window, then delivers 3 bytes
    %% in response to the conn's first recv.
    Sink = spawn(fun() ->
        receive
            {roadrunner_fake_recv, ConnPid, _Len, _Timeout} ->
                timer:sleep(1100),
                ConnPid ! {roadrunner_fake_recv_reply, {ok, ~"GET"}}
        after 5000 -> ok
        end,
        receive
            stop -> ok
        after 5000 -> ok
        end
    end),
    Opts = (fake_opts(slow_passive))#{
        min_bytes_per_second => 1000000
    },
    {ok, Pid} = roadrunner_conn_loop:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 4000 -> error(no_normal_exit_on_slowloris)
    end,
    Sink ! stop,
    _ = Self.

slowloris_during_active_mode_recv_drops_client_test() ->
    %% Active-mode hibernate path: deliver a tiny amount of bytes
    %% after the 1 s grace, with `min_rate` set high enough that the
    %% running average falls under it. The conn must close silently
    %% (no 408, same as the passive path's slowloris branch).
    ensure_pg(),
    Self = self(),
    %% Sink that waits past the grace window, then delivers 3 bytes
    %% — running average becomes `3 * 1000 / 1100 ≈ 2.7 B/s`, well
    %% under 1 MB/s.
    Sink = spawn(fun() ->
        receive
            {roadrunner_fake_setopts, ConnPid, _Opts} ->
                timer:sleep(1100),
                ConnPid ! {roadrunner_fake_data, undefined, ~"GET"}
        after 5000 -> ok
        end,
        receive
            stop -> ok
        after 5000 -> ok
        end
    end),
    Opts = (fake_opts(slow_active))#{
        hibernate_after => 5000,
        min_bytes_per_second => 1000000
    },
    {ok, Pid} = roadrunner_conn_loop:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 4000 -> error(no_normal_exit_on_slowloris)
    end,
    Sink ! stop,
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

middleware_pipeline_runs_when_listener_has_middlewares_test() ->
    %% Covers the `false` branch of run_pipeline's empty-middleware
    %% short-circuit — when ListenerMws is non-empty, compose runs.
    %% The middleware sets a marker into the request body via a
    %% no-op continuation. Asserts the response still lands and the
    %% middleware ran (echo handler reflects the body).
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Body = ~"mw-marker",
    Req = iolist_to_binary([
        ~"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: ",
        integer_to_binary(byte_size(Body)),
        ~"\r\n\r\n",
        Body
    ]),
    Sink = spawn_active_sink_with_send_log(Self, Tag, Req),
    %% Identity middleware — just calls Inner(Req). Exercises the
    %% compose path without changing the response.
    Identity = fun(R, Inner) -> Inner(R) end,
    Opts = (fake_opts(mw))#{
        middlewares := [Identity],
        dispatch := {handler, roadrunner_echo_body_handler}
    },
    {ok, Pid} = roadrunner_conn_loop:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    ?assertMatch(<<"HTTP/1.1 200", _/binary>>, Sent),
    ?assertNotEqual(nomatch, binary:match(Sent, Body)),
    Sink ! stop.

handler_crash_writes_500_and_fires_request_exception_test() ->
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    attach_telemetry(Tag, [
        [roadrunner, request, start],
        [roadrunner, request, stop],
        [roadrunner, request, exception]
    ]),
    Sink = spawn_active_sink_with_send_log(
        Self, Tag, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"
    ),
    Opts = (fake_opts(crash))#{
        dispatch := {handler, roadrunner_crashing_handler}
    },
    {ok, Pid} = roadrunner_conn_loop:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    ?assertMatch(<<"HTTP/1.1 500", _/binary>>, Sent),
    %% start fired before exception; stop did NOT fire (crash branch).
    ?assertEqual([roadrunner, request, start], next_event_name(Tag, 200)),
    ?assertEqual([roadrunner, request, exception], next_event_name(Tag, 200)),
    ?assertEqual(timeout, next_event_name(Tag, 50)),
    detach_telemetry(Tag),
    Sink ! stop.

post_body_echoes_via_auto_mode_test() ->
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Body = ~"hello-body",
    Req = iolist_to_binary([
        ~"POST /echo HTTP/1.1\r\n",
        ~"Host: x\r\n",
        ~"Content-Length: ",
        integer_to_binary(byte_size(Body)),
        ~"\r\n\r\n",
        Body
    ]),
    Sink = spawn_active_sink_with_send_log(Self, Tag, Req),
    Opts = (fake_opts(echo))#{
        dispatch := {handler, roadrunner_echo_body_handler}
    },
    {ok, Pid} = roadrunner_conn_loop:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    %% Response includes the echoed body — assert the body bytes are
    %% present at the end of the wire output.
    ?assertMatch(<<"HTTP/1.1 200", _/binary>>, Sent),
    ?assertNotEqual(nomatch, binary:match(Sent, Body)),
    Sink ! stop.

oversized_body_writes_413_and_fires_request_rejected_test() ->
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    attach_telemetry(Tag, [[roadrunner, request, rejected]]),
    %% max_content_length is 5 bytes — declared CL of 100 must be rejected.
    Req = iolist_to_binary([
        ~"POST /echo HTTP/1.1\r\n",
        ~"Host: x\r\n",
        ~"Content-Length: 100\r\n\r\n",
        binary:copy(<<"x">>, 100)
    ]),
    Sink = spawn_active_sink_with_send_log(Self, Tag, Req),
    Opts = (fake_opts(big))#{
        max_content_length := 5,
        dispatch := {handler, roadrunner_echo_body_handler}
    },
    {ok, Pid} = roadrunner_conn_loop:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    ?assertMatch(<<"HTTP/1.1 413", _/binary>>, Sent),
    ?assertEqual([roadrunner, request, rejected], next_event_name(Tag, 200)),
    detach_telemetry(Tag),
    Sink ! stop.

body_recv_timeout_writes_408_test() ->
    %% Headers say Content-Length: 100 but body recv times out. read_body
    %% returns {error, request_timeout} → 408 + exit.
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Headers = ~"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\n",
    %% Default recv path is passive for headers AND body, so both
    %% script items are `{passive, _}` — no `{active, _}` setopts
    %% dispatch unless `hibernate_after` is set (covered by the
    %% hibernate_path_handles_* tests below).
    Sink = spawn_scripted_sink(Self, Tag, [
        {passive, {ok, Headers}},
        {passive, {error, timeout}}
    ]),
    Opts = (fake_opts(body_to))#{
        dispatch := {handler, roadrunner_echo_body_handler}
    },
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

body_slow_client_exits_silently_test() ->
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Headers = ~"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\n",
    Sink = spawn_scripted_sink(Self, Tag, [
        {passive, {ok, Headers}},
        {passive, {error, slow_client}}
    ]),
    Opts = (fake_opts(body_slow))#{
        dispatch := {handler, roadrunner_echo_body_handler}
    },
    {ok, Pid} = roadrunner_conn_loop:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    %% Slow client → silent close, no 4xx written.
    ?assertEqual(<<>>, iolist_to_binary(collect_sends(Tag, 50))),
    Sink ! stop.

body_recv_error_writes_400_test() ->
    %% Generic recv error mid-body (not timeout, not slow_client) maps
    %% to a 400.
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Headers = ~"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\n",
    Sink = spawn_scripted_sink(Self, Tag, [
        {passive, {ok, Headers}},
        {passive, {error, closed}}
    ]),
    Opts = (fake_opts(body_err))#{
        dispatch := {handler, roadrunner_echo_body_handler}
    },
    {ok, Pid} = roadrunner_conn_loop:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    ?assertMatch(<<"HTTP/1.1 400", _/binary>>, Sent),
    Sink ! stop.

manual_mode_dispatches_with_body_state_test() ->
    %% Manual mode skips the auto-buffer read and hands a body_state to
    %% the handler. The manual handler reads the body explicitly,
    %% returning 200 ok. Use `Connection: close` so the conn closes
    %% after the single request rather than looping back keep-alive
    %% (which the manual handler doesn't disable on its own).
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Headers = ~"POST / HTTP/1.1\r\nHost: x\r\nConnection: close\r\nContent-Length: 5\r\n\r\n",
    Sink = spawn_scripted_sink(Self, Tag, [
        {passive, {ok, Headers}},
        {passive, {ok, ~"hello"}}
    ]),
    Opts = (fake_opts(manual))#{
        body_buffering := manual,
        dispatch := {handler, roadrunner_manual_keepalive_handler}
    },
    {ok, Pid} = roadrunner_conn_loop:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    ?assertMatch(<<"HTTP/1.1 200", _/binary>>, Sent),
    Sink ! stop.

manual_mode_bad_framing_writes_400_test() ->
    %% Non-chunked Transfer-Encoding rejected by `body_framing/1` →
    %% 400 + exit, before the handler is invoked.
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Headers = ~"POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip\r\n\r\n",
    Sink = spawn_scripted_sink(Self, Tag, [{passive, {ok, Headers}}]),
    Opts = (fake_opts(manual_bad))#{
        body_buffering := manual,
        dispatch := {handler, roadrunner_manual_keepalive_handler}
    },
    {ok, Pid} = roadrunner_conn_loop:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    ?assertMatch(<<"HTTP/1.1 400", _/binary>>, Sent),
    Sink ! stop.

not_found_writes_404_test() ->
    %% Router dispatch with no matching route → 404.
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    %% Publish an empty route table under the listener name so
    %% `resolve_handler/2` finds the routes ets entry but returns
    %% `not_found` for any path.
    Listener = nf404,
    Compiled = roadrunner_router:compile([]),
    persistent_term:put({roadrunner_routes, Listener}, Compiled),
    Sink = spawn_active_sink_with_send_log(
        Self, Tag, ~"GET /missing HTTP/1.1\r\nHost: x\r\n\r\n"
    ),
    Opts = (fake_opts(Listener))#{
        dispatch := {router, Listener}
    },
    {ok, Pid} = roadrunner_conn_loop:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    ?assertMatch(<<"HTTP/1.1 404", _/binary>>, Sent),
    Sink ! stop,
    persistent_term:erase({roadrunner_routes, Listener}).

two_pipelined_requests_in_one_packet_serve_both_test() ->
    %% RFC 7230 §6.3 pipelining — two requests delivered as one TCP
    %% packet should both be served. The keepalive handler (no
    %% `Connection: close`) lets keep-alive engage. The second
    %% request closes via the test's `max_keep_alive_requests := 2`
    %% cap so the conn exits cleanly without a third iteration.
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Both =
        ~"GET / HTTP/1.1\r\nHost: x\r\n\r\nGET / HTTP/1.1\r\nHost: x\r\n\r\n",
    Sink = spawn_active_sink_with_send_log(Self, Tag, Both),
    Opts = (fake_opts(pipelined))#{
        dispatch := {handler, roadrunner_keepalive_handler},
        max_keep_alive_requests := 2
    },
    {ok, Pid} = roadrunner_conn_loop:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 200)),
    %% Two 200 OK responses on the wire (split into 3 tokens by the
    %% leading empty + one per response).
    ?assertEqual(3, length(binary:split(Sent, ~"HTTP/1.1 ", [global]))),
    Sink ! stop.

keep_alive_max_cap_closes_after_max_test() ->
    %% `max_keep_alive_requests := 1` — the single served request hits
    %% the cap and the conn closes (no second iteration even though
    %% keep-alive is otherwise eligible).
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Both =
        ~"GET / HTTP/1.1\r\nHost: x\r\n\r\nGET / HTTP/1.1\r\nHost: x\r\n\r\n",
    Sink = spawn_active_sink_with_send_log(Self, Tag, Both),
    Opts = (fake_opts(max1))#{max_keep_alive_requests := 1},
    {ok, Pid} = roadrunner_conn_loop:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 200)),
    %% Exactly one 200 OK on the wire — second request never dispatched.
    ?assertEqual(2, length(binary:split(Sent, ~"HTTP/1.1 ", [global]))),
    Sink ! stop.

manual_mode_drain_failure_closes_cleanly_test() ->
    %% Manual handler returns 200 without reading the body. drain_body/1
    %% then has to consume the body_state's unread bytes — when the
    %% recv in that drain returns `{error, closed}`, drain_body returns
    %% `{error, _}` and the conn must exit cleanly without crashing.
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Headers = ~"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\n",
    Sink = spawn_scripted_sink(Self, Tag, [
        {passive, {ok, Headers}},
        %% No body bytes pre-buffered. The drain will recv → fail.
        {passive, {error, closed}}
    ]),
    Opts = (fake_opts(drain_fail))#{
        body_buffering := manual,
        dispatch := {handler, roadrunner_conn_loop_lazy_manual_handler}
    },
    {ok, Pid} = roadrunner_conn_loop:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    %% Handler's 200 was written before drain failed.
    ?assertMatch(<<"HTTP/1.1 200", _/binary>>, Sent),
    Sink ! stop.

manual_mode_pipelined_leftover_uses_manual_drain_test() ->
    %% Manual handler reads its own body to completion, returns 200
    %% keep-alive friendly. Two pipelined requests are delivered as one
    %% packet — request 1's body is part of the packet, then request 2's
    %% headers + body. After dispatch 1, drain_body returns
    %% `{ok, ManualLeftover}` where ManualLeftover is request 2.
    %% `pipelined_leftover/3` MUST take the manual-mode branch (the
    %% req has `body_state` set) and feed ManualLeftover to the next
    %% iteration's read_request_phase. Covers the manual-mode clause
    %% of pipelined_leftover/3.
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Req1 = ~"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello",
    Req2 = ~"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nbye",
    Both = <<Req1/binary, Req2/binary>>,
    Sink = spawn_scripted_sink(Self, Tag, [{passive, {ok, Both}}]),
    Opts = (fake_opts(manual_pipe))#{
        body_buffering := manual,
        dispatch := {handler, roadrunner_manual_keepalive_handler},
        max_keep_alive_requests := 2
    },
    {ok, Pid} = roadrunner_conn_loop:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 200)),
    %% Two 200 responses on the wire — second one came from request 2
    %% which lived in ManualLeftover after request 1's drain.
    ?assertEqual(3, length(binary:split(Sent, ~"HTTP/1.1 ", [global]))),
    Sink ! stop.

keep_alive_idle_timeout_silently_closes_test() ->
    %% After the first request, the conn waits in `read_request_phase`
    %% (phase=keep_alive) for the next request bytes. With short
    %% `keep_alive_timeout`, the receive's `after` fires and the conn
    %% closes silently — NO 408 (the peer wasn't waiting on a reply).
    %% Uses the `roadrunner_keepalive_handler` (no `Connection: close`)
    %% so keep-alive engages — otherwise the hello handler would
    %% close after request 1 and we'd never enter `phase=keep_alive`.
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_active_sink_with_send_log(
        Self, Tag, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"
    ),
    Opts = (fake_opts(ka_to))#{
        dispatch := {handler, roadrunner_keepalive_handler},
        keep_alive_timeout := 50
    },
    {ok, Pid} = roadrunner_conn_loop:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 200)),
    %% Only the first request's 200 — no 408 written for the idle
    %% keep-alive timeout.
    ?assertEqual(2, length(binary:split(Sent, ~"HTTP/1.1 ", [global]))),
    ?assertEqual(nomatch, binary:match(Sent, ~"HTTP/1.1 408")),
    Sink ! stop.

hibernate_after_fires_during_keep_alive_idle_test() ->
    %% With `hibernate_after` set, the conn idle in keep-alive should
    %% enter `process_info(Pid, status) =:= waiting` AND show a
    %% drastically reduced `total_heap_size` after hibernation. We
    %% poll for status=waiting + heap < 5000 words.
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_active_sink_with_send_log(
        Self, Tag, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"
    ),
    Opts = (fake_opts(hib))#{
        dispatch := {handler, roadrunner_keepalive_handler},
        hibernate_after => 50,
        keep_alive_timeout := 5000
    },
    {ok, Pid} = roadrunner_conn_loop:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    %% Allow time for the request to dispatch and the conn to enter
    %% the keep-alive idle hibernate window.
    timer:sleep(150),
    case process_info(Pid, [status, total_heap_size]) of
        [{status, waiting}, {total_heap_size, Heap}] when Heap < 5000 ->
            ok;
        Other ->
            error({not_hibernated, Other})
    end,
    %% Send drain to wake + clean exit so the test runner doesn't
    %% leak a process.
    Pid ! {roadrunner_drain, infinity},
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit_after_drain)
    end,
    Sink ! stop.

hibernate_path_handles_close_test() ->
    %% Coverage: the hibernate path's ClosedTag clause.
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_active_sink_with_send_log(
        Self, Tag, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"
    ),
    Opts = (fake_opts(hib_closed))#{
        dispatch := {handler, roadrunner_keepalive_handler},
        hibernate_after => 50
    },
    {ok, Pid} = roadrunner_conn_loop:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    timer:sleep(20),
    Pid ! {roadrunner_fake_closed, undefined},
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    Sink ! stop.

hibernate_path_handles_tcp_error_test() ->
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_active_sink_with_send_log(
        Self, Tag, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"
    ),
    Opts = (fake_opts(hib_err))#{
        dispatch := {handler, roadrunner_keepalive_handler},
        hibernate_after => 50
    },
    {ok, Pid} = roadrunner_conn_loop:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    timer:sleep(20),
    Pid ! {roadrunner_fake_error, undefined, econnreset},
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    Sink ! stop.

hibernate_path_handles_deadline_fired_test() ->
    %% With short keep_alive_timeout AND hibernate_after, the
    %% deadline timer fires before hibernation does — covers the
    %% `{?MODULE, deadline_fired}` clause.
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_active_sink_with_send_log(
        Self, Tag, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"
    ),
    Opts = (fake_opts(hib_dl))#{
        dispatch := {handler, roadrunner_keepalive_handler},
        hibernate_after => 5000,
        keep_alive_timeout := 50
    },
    {ok, Pid} = roadrunner_conn_loop:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    Sink ! stop.

hibernate_path_drops_stray_messages_test() ->
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_active_sink_with_send_log(
        Self, Tag, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"
    ),
    Opts = (fake_opts(hib_stray))#{
        dispatch := {handler, roadrunner_keepalive_handler},
        hibernate_after => 5000,
        keep_alive_timeout := 200
    },
    {ok, Pid} = roadrunner_conn_loop:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    timer:sleep(20),
    Pid ! {junk, ref},
    Pid ! 12345,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    Sink ! stop.

request_start_and_stop_pair_with_shared_request_id_test() ->
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    attach_telemetry(Tag, [
        [roadrunner, request, start],
        [roadrunner, request, stop]
    ]),
    Sink = spawn_active_sink_with_send_log(
        Self, Tag, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"
    ),
    {ok, Pid} = roadrunner_conn_loop:start({fake, Sink}, fake_opts(pair)),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    {[roadrunner, request, start], StartMeta} = next_event(Tag, 200),
    {[roadrunner, request, stop], StopMeta} = next_event(Tag, 200),
    ?assertEqual(maps:get(request_id, StartMeta), maps:get(request_id, StopMeta)),
    detach_telemetry(Tag),
    Sink ! stop.

head_method_buffered_response_omits_body_test() ->
    %% RFC 9110 §9.3.2 — HEAD must NOT include a message body even
    %% when the handler returns one. The dispatch_response/4 fast
    %% path in conn_loop pattern-matches on `method := ~"HEAD"` and
    %% forces the body to `~""`. Headers (including content-length)
    %% stay as-is so the framing matches what GET would have returned.
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_active_sink_with_send_log(
        Self, Tag, ~"HEAD / HTTP/1.1\r\nHost: x\r\n\r\n"
    ),
    {ok, Pid} = roadrunner_conn_loop:start({fake, Sink}, fake_opts(head)),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    %% Status line + headers, but the hello body bytes should NOT
    %% be on the wire.
    ?assertMatch(<<"HTTP/1.1 200", _/binary>>, Sent),
    ?assertEqual(nomatch, binary:match(Sent, ~"Hello, roadrunner")),
    Sink ! stop.

stream_response_writes_chunked_body_test() ->
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_active_sink_with_send_log(
        Self, Tag, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"
    ),
    Opts = (fake_opts(stream))#{
        dispatch := {handler, roadrunner_stream_handler}
    },
    {ok, Pid} = roadrunner_conn_loop:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    %% Stream writes a chunked-encoding response — assert at least the
    %% 200 head landed on the wire.
    ?assertMatch(<<"HTTP/1.1 200", _/binary>>, Sent),
    ?assertNotEqual(nomatch, binary:match(Sent, ~"hello")),
    Sink ! stop.

loop_response_runs_until_stop_test() ->
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_active_sink_with_send_log(
        Self, Tag, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"
    ),
    Opts = (fake_opts(looprsp))#{
        dispatch := {handler, roadrunner_loop_handler}
    },
    {ok, Pid} = roadrunner_conn_loop:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    %% Loop handler registers itself under `roadrunner_loop_test_conn`
    %% and pushes one chunk per inbound msg. Wait for it, then stop.
    timer:sleep(50),
    case whereis(roadrunner_loop_test_conn) of
        undefined ->
            error(loop_handler_not_registered);
        LoopPid ->
            LoopPid ! stop
    end,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    ?assertMatch(<<"HTTP/1.1 200", _/binary>>, Sent),
    Sink ! stop.

sendfile_response_writes_head_then_body_test() ->
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Path = filename:join(["/tmp", "rr_conn_loop_sendfile.txt"]),
    ok = file:write_file(Path, ~"sendfile-content"),
    persistent_term:put({roadrunner_conn_loop_sendfile_handler, file}, Path),
    Sink = spawn_active_sink_with_send_log(
        Self, Tag, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"
    ),
    Opts = (fake_opts(sendf))#{
        dispatch := {handler, roadrunner_conn_loop_sendfile_handler}
    },
    {ok, Pid} = roadrunner_conn_loop:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    ?assertMatch(<<"HTTP/1.1 200", _/binary>>, Sent),
    ?assertNotEqual(nomatch, binary:match(Sent, ~"sendfile-content")),
    Sink ! stop,
    persistent_term:erase({roadrunner_conn_loop_sendfile_handler, file}),
    file:delete(Path).

sendfile_response_skips_body_for_head_method_test() ->
    %% RFC 9110 §9.3.2 — HEAD must not include a message body.
    %% Covers the `~"HEAD"` branch of dispatch_response/4's sendfile clause.
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Path = filename:join(["/tmp", "rr_conn_loop_sendfile_head.txt"]),
    ok = file:write_file(Path, ~"never-sent"),
    persistent_term:put({roadrunner_conn_loop_sendfile_handler, file}, Path),
    Sink = spawn_active_sink_with_send_log(
        Self, Tag, ~"HEAD / HTTP/1.1\r\nHost: x\r\n\r\n"
    ),
    Opts = (fake_opts(sendf_head))#{
        dispatch := {handler, roadrunner_conn_loop_sendfile_handler}
    },
    {ok, Pid} = roadrunner_conn_loop:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    ?assertMatch(<<"HTTP/1.1 200", _/binary>>, Sent),
    %% File body must NOT be on the wire — HEAD bypasses the sendfile call.
    ?assertEqual(nomatch, binary:match(Sent, ~"never-sent")),
    Sink ! stop,
    persistent_term:erase({roadrunner_conn_loop_sendfile_handler, file}),
    file:delete(Path).

websocket_dispatch_invokes_session_run_test() ->
    %% Without proper ws upgrade headers `ws_session:run/4` writes 400
    %% and returns. We're covering the dispatch_response websocket
    %% clause — a full handshake test lives in the WS suite.
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_active_sink_with_send_log(
        Self, Tag, ~"GET /ws HTTP/1.1\r\nHost: x\r\n\r\n"
    ),
    Opts = (fake_opts(wsdisp))#{
        dispatch := {handler, roadrunner_ws_upgrade_handler}
    },
    {ok, Pid} = roadrunner_conn_loop:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    %% Bad upgrade — ws_session writes a 400.
    ?assertMatch(<<"HTTP/1.1 400", _/binary>>, Sent),
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
        max_keep_alive_requests => 100,
        max_clients => 10,
        client_counter => atomics:new(1, [{signed, false}]),
        requests_counter => atomics:new(1, [{signed, false}]),
        min_bytes_per_second => 0,
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
            %% Active-mode delivery: simulate one inbound packet.
            ConnPid ! {roadrunner_fake_data, undefined, Bytes},
            active_sink_loop(Logger, Tag, Bytes, true);
        {roadrunner_fake_setopts, _ConnPid, _Opts} ->
            active_sink_loop(Logger, Tag, Bytes, Delivered);
        {roadrunner_fake_recv, ConnPid, _Len, _Timeout} when not Delivered ->
            %% Passive-mode delivery (Phase A'): reply with bytes once,
            %% then subsequent recvs return `{error, closed}` so the
            %% conn exits cleanly after parsing the request.
            ConnPid ! {roadrunner_fake_recv_reply, {ok, Bytes}},
            active_sink_loop(Logger, Tag, Bytes, true);
        {roadrunner_fake_recv, ConnPid, _Len, _Timeout} ->
            ConnPid ! {roadrunner_fake_recv_reply, {error, closed}},
            active_sink_loop(Logger, Tag, Bytes, Delivered);
        {roadrunner_fake_send, _Pid, Data} ->
            Logger ! {Tag, sent, Data},
            active_sink_loop(Logger, Tag, Bytes, Delivered);
        _Other ->
            active_sink_loop(Logger, Tag, Bytes, Delivered)
    end.

%% Scripted sink — handles BOTH active-mode setopts (replies with
%% `{roadrunner_fake_data, _, Bytes}`) and passive-mode recv (replies
%% with `{roadrunner_fake_recv_reply, Result}`). Script is a list of:
%%   - `{active, Bytes}` — next setopts arm delivers Bytes
%%   - `{passive, Result}` — next recv replies with Result
%% Items are consumed in order. Forwards `roadrunner_fake_send` to
%% `Logger` tagged with `Tag`.
spawn_scripted_sink(Logger, Tag, Script) ->
    spawn(fun() -> scripted_sink_loop(Logger, Tag, Script) end).

scripted_sink_loop(Logger, Tag, Script) ->
    receive
        stop ->
            ok;
        {roadrunner_fake_setopts, ConnPid, _Opts} ->
            case take_active(Script) of
                {ok, Bytes, Rest} ->
                    ConnPid ! {roadrunner_fake_data, undefined, Bytes},
                    scripted_sink_loop(Logger, Tag, Rest);
                empty ->
                    scripted_sink_loop(Logger, Tag, Script)
            end;
        {roadrunner_fake_recv, ConnPid, _Len, _Timeout} ->
            case take_passive(Script) of
                {ok, Result, Rest} ->
                    ConnPid ! {roadrunner_fake_recv_reply, Result},
                    scripted_sink_loop(Logger, Tag, Rest);
                empty ->
                    %% No script item — block (test will time out if it
                    %% reaches this state unexpectedly).
                    scripted_sink_loop(Logger, Tag, Script)
            end;
        {roadrunner_fake_send, _Pid, Data} ->
            Logger ! {Tag, sent, Data},
            scripted_sink_loop(Logger, Tag, Script);
        _Other ->
            scripted_sink_loop(Logger, Tag, Script)
    end.

take_active([{active, Bytes} | Rest]) -> {ok, Bytes, Rest};
take_active([_ | Rest]) -> take_active(Rest);
take_active([]) -> empty.

take_passive([{passive, Result} | Rest]) -> {ok, Result, Rest};
take_passive([_ | Rest]) -> take_passive(Rest);
take_passive([]) -> empty.

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
        {roadrunner_fake_recv, ConnPid, _Len, _Timeout} ->
            %% Passive-mode delivery: reply one chunk per recv.
            case Remaining of
                [Bytes | Rest] ->
                    ConnPid ! {roadrunner_fake_recv_reply, {ok, Bytes}},
                    two_chunk_sink_loop(Logger, Tag, Rest);
                [] ->
                    ConnPid ! {roadrunner_fake_recv_reply, {error, closed}},
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
        {roadrunner_fake_recv, _ConnPid, _Len, _Timeout} ->
            %% Passive-mode block: stay silent so request_timeout fires.
            %% The conn's deadline check will see the recv chunk timeout
            %% and exit on its own.
            silent_sink_loop(Logger, Tag);
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

%% The send-log helper and telemetry helpers both forward `{Tag, _, _}`
%% messages to the test runner — `sent` is from
%% `roadrunner_fake_send`, telemetry events have a list-shaped name.
%% Skip `sent` so callers asserting on event order don't get
%% cross-stream interference.
next_event_name(Tag, Timeout) ->
    receive
        {Tag, sent, _Data} -> next_event_name(Tag, Timeout);
        {Tag, Name, _Metadata} -> Name
    after Timeout ->
        timeout
    end.

next_event(Tag, Timeout) ->
    receive
        {Tag, sent, _Data} -> next_event(Tag, Timeout);
        {Tag, Name, Metadata} -> {Name, Metadata}
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
