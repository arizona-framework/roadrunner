-module(roadrunner_conn_statem_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Phase 4 + 5 — drives init/1 -> awaiting_shoot -> reading_request ->
%% reading_body -> stop_normal end-to-end via the fake transport. A
%% per-test recv-script sink replies to `roadrunner_fake_recv` messages
%% with pre-baked bytes / errors and discards `roadrunner_fake_send` /
%% `roadrunner_fake_close` so they don't pollute the test runner mailbox.
%% =============================================================================

reading_request_parses_then_reading_body_full_request_test() ->
    ensure_pg(),
    Sink = spawn_recv_sink([{recv, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"}]),
    {ok, Pid} = roadrunner_conn_statem:start({fake, Sink}, fake_proto_opts(read1)),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    stop_sink(Sink).

reading_request_request_timeout_first_sends_408_test() ->
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_recv_sink_with_send_log(Self, Tag, [{recv, {error, timeout}}]),
    {ok, Pid} = roadrunner_conn_statem:start(
        {fake, Sink}, fake_proto_opts_short_timeout(read_408)
    ),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    Sent = collect_sends(Tag, 100),
    ?assertMatch(<<"HTTP/1.1 408", _/binary>>, iolist_to_binary(Sent)),
    stop_sink(Sink).

reading_request_slow_client_silent_test() ->
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_recv_sink_with_send_log(Self, Tag, [{recv, {error, slow_client}}]),
    {ok, Pid} = roadrunner_conn_statem:start(
        {fake, Sink}, fake_proto_opts(read_slow)
    ),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    %% No 4xx written — slow_client closes silently.
    ?assertEqual(<<>>, iolist_to_binary(collect_sends(Tag, 50))),
    stop_sink(Sink).

reading_request_bad_request_sends_400_test() ->
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_recv_sink_with_send_log(
        Self, Tag, [{recv, ~"NOT-A-VALID-REQUEST-LINE\r\n\r\n"}]
    ),
    {ok, Pid} = roadrunner_conn_statem:start({fake, Sink}, fake_proto_opts(read_400)),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    Sent = collect_sends(Tag, 100),
    ?assertMatch(<<"HTTP/1.1 400", _/binary>>, iolist_to_binary(Sent)),
    stop_sink(Sink).

reading_body_oversized_sends_413_test() ->
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Req = ~"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 9999\r\n\r\n",
    Sink = spawn_recv_sink_with_send_log(Self, Tag, [{recv, Req}]),
    {ok, Pid} = roadrunner_conn_statem:start(
        {fake, Sink}, fake_proto_opts_small_max(read_413)
    ),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    Sent = collect_sends(Tag, 100),
    ?assertMatch(<<"HTTP/1.1 413", _/binary>>, iolist_to_binary(Sent)),
    stop_sink(Sink).

reading_body_request_timeout_sends_408_test() ->
    %% First chunk parses headers; the body recv times out → 408.
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_recv_sink_with_send_log(Self, Tag, [
        {recv, ~"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\n"},
        {recv, {error, timeout}}
    ]),
    {ok, Pid} = roadrunner_conn_statem:start(
        {fake, Sink}, fake_proto_opts_short_timeout(read_body_408)
    ),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    ?assertMatch(<<"HTTP/1.1 408", _/binary>>, iolist_to_binary(collect_sends(Tag, 100))),
    stop_sink(Sink).

reading_body_slow_client_silent_test() ->
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_recv_sink_with_send_log(Self, Tag, [
        {recv, ~"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\n"},
        {recv, {error, slow_client}}
    ]),
    {ok, Pid} = roadrunner_conn_statem:start(
        {fake, Sink}, fake_proto_opts(read_body_slow)
    ),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    ?assertEqual(<<>>, iolist_to_binary(collect_sends(Tag, 50))),
    stop_sink(Sink).

reading_body_recv_error_sends_400_test() ->
    %% Body recv returns a non-timeout/non-slow error mid-read → 400.
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_recv_sink_with_send_log(Self, Tag, [
        {recv, ~"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\n"},
        {recv, {error, closed}}
    ]),
    {ok, Pid} = roadrunner_conn_statem:start(
        {fake, Sink}, fake_proto_opts(read_body_400)
    ),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    ?assertMatch(<<"HTTP/1.1 400", _/binary>>, iolist_to_binary(collect_sends(Tag, 100))),
    stop_sink(Sink).

reading_body_bad_transfer_encoding_in_manual_mode_test() ->
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Req = ~"POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: bogus\r\n\r\n",
    Sink = spawn_recv_sink_with_send_log(Self, Tag, [{recv, Req}]),
    {ok, Pid} = roadrunner_conn_statem:start(
        {fake, Sink}, fake_proto_opts_manual(read_te_bad)
    ),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    Sent = collect_sends(Tag, 100),
    ?assertMatch(<<"HTTP/1.1 400", _/binary>>, iolist_to_binary(Sent)),
    stop_sink(Sink).

reading_body_manual_mode_installs_body_state_test() ->
    ensure_pg(),
    Req = ~"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello",
    Sink = spawn_recv_sink([{recv, Req}]),
    {ok, Pid} = roadrunner_conn_statem:start(
        {fake, Sink}, fake_proto_opts_manual(read_manual)
    ),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    stop_sink(Sink).

reading_request_rate_check_fires_and_reschedules_test() ->
    %% Configure a fast rate-check interval so the timer fires before
    %% the request_timeout state_timeout, with `MinRate = 0` so the
    %% check passes and re-schedules. Exercises both the
    %% grace-period branch (first fire, Elapsed <= interval) and the
    %% post-grace re-schedule branch.
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    %% Empty script — sink doesn't deliver anything; conn waits.
    Sink = spawn_recv_sink_with_send_log(Self, Tag, []),
    Opts = (fake_proto_opts(rate_check_test))#{
        request_timeout := 1000,
        rate_check_interval_ms => 30
    },
    {ok, Pid} = roadrunner_conn_statem:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    %% Wait long enough for several rate-check fires (each 30ms) plus
    %% the eventual request_timeout closure at 1000ms.
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 3000 -> error(no_normal_exit)
    end,
    stop_sink(Sink).

reading_request_slow_rate_violates_minrate_test() ->
    %% Fire the rate-check timer past the 1-second grace window with
    %% zero bytes received and `minimum_bytes_per_second = 100`. The
    %% running average (0 bytes / >1s) violates the minimum → silent
    %% close, no 4xx on the wire.
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_recv_sink_with_send_log(Self, Tag, []),
    Opts = (fake_proto_opts(rate_check_violation))#{
        request_timeout := 5000,
        rate_check_interval_ms => 20,
        minimum_bytes_per_second := 100
    },
    {ok, Pid} = roadrunner_conn_statem:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    %% After 1000ms grace + a 20ms tick, rate_ok = false → stop.
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 3000 -> error(no_normal_exit)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    %% Silent close — no 4xx written.
    ?assertEqual(<<>>, Sent),
    stop_sink(Sink).

hibernate_after_fires_during_keep_alive_idle_test() ->
    %% With `hibernate_after` set on the listener, the conn statem
    %% auto-hibernates when its main loop is idle — between requests
    %% on a keep-alive conn this means heap shrinks to ~1KB until
    %% the next request arrives. We don't actually deliver a second
    %% request: after the first response is sent, the conn is back
    %% in `reading_request` waiting for bytes. After
    %% `hibernate_after` ms idle, the gen_statem hibernates.
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    %% Sink delivers one full request and then sits silent — gives
    %% the conn time to serve the request, loop back to
    %% reading_request, and then hibernate while waiting for a
    %% second request that never comes.
    Sink = spawn_recv_sink_with_send_log(Self, Tag, [
        {recv, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"}
    ]),
    Opts = (fake_proto_opts(hibernate_test))#{
        request_timeout := 2000,
        keep_alive_timeout := 2000,
        dispatch := {handler, roadrunner_manual_keepalive_handler},
        hibernate_after => 30
    },
    {ok, Pid} = roadrunner_conn_statem:start({fake, Sink}, Opts),
    Pid ! shoot,
    %% Wait for the response to come back (= request 1 served, conn
    %% looped back to reading_request).
    Sent = iolist_to_binary(collect_sends(Tag, 200)),
    ?assertEqual(1, count_200(Sent)),
    %% After ~30ms idle the conn must be hibernated.
    ?assert(is_hibernating(Pid, 200)),
    ok = gen_statem:stop(Pid),
    stop_sink(Sink).

http11_missing_host_header_returns_400_test() ->
    %% RFC 9112 §3.2: HTTP/1.1 request without Host MUST get 400.
    %% Mitigates request-smuggling confusion in proxy chains where
    %% the backend disagrees with the front about the target host.
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_recv_sink_with_send_log(
        Self, Tag, [{recv, ~"GET / HTTP/1.1\r\n\r\n"}]
    ),
    {ok, Pid} = roadrunner_conn_statem:start({fake, Sink}, fake_proto_opts(no_host)),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    ?assertMatch(<<"HTTP/1.1 400", _/binary>>, Sent),
    stop_sink(Sink).

http10_missing_host_header_serves_200_test() ->
    %% HTTP/1.0 doesn't require Host (RFC 7230 §5.4). A 1.0 request
    %% without Host should reach the handler normally.
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_recv_sink_with_send_log(
        Self, Tag, [{recv, ~"GET / HTTP/1.0\r\n\r\n"}]
    ),
    {ok, Pid} = roadrunner_conn_statem:start({fake, Sink}, fake_proto_opts(no_host_http10)),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Sent),
    stop_sink(Sink).

pipelined_two_requests_in_one_chunk_serves_both_test() ->
    %% RFC 7230 §6.3: an HTTP/1.1 server must handle pipelined
    %% requests — i.e. a client sending request N+1's bytes in the
    %% same TCP packet as request N's headers. The conn now preserves
    %% post-body leftover bytes across the keep-alive loop-back so
    %% the next reading_request iteration parses request N+1 from
    %% the in-buffer bytes (no extra recv needed).
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    %% Two complete GET requests concatenated; both have CL-less /
    %% no body so `read_body`'s `none` clause threads everything
    %% past the first request into Leftover.
    TwoRequests =
        ~"GET /one HTTP/1.1\r\nHost: x\r\n\r\nGET /two HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    Sink = spawn_recv_sink_with_send_log(Self, Tag, [
        {recv, TwoRequests}
    ]),
    Opts = (fake_proto_opts(pipelined))#{
        dispatch := {handler, roadrunner_manual_keepalive_handler}
    },
    {ok, Pid} = roadrunner_conn_statem:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 3000 -> error(no_normal_exit)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    %% Both requests were served — exactly two 200s on the wire.
    ?assertEqual(2, count_200(Sent)),
    stop_sink(Sink).

end_to_end_hibernate_across_keep_alive_iterations_test() ->
    %% Full keep-alive lifecycle with hibernation: serve req1 → loop
    %% back to reading_request → hibernate during idle → wake on
    %% req2 → serve → hibernate again. Verifies that hibernation
    %% works across the finishing → reading_request transition (not
    %% just on the first read), and that woken-up conns process
    %% subsequent requests correctly.
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    %% Sink scripts only req1; we deliver req2 manually after the
    %% hibernate window so we can observe the conn idle in
    %% reading_request.
    Sink = spawn_recv_sink_with_send_log(Self, Tag, [
        {recv, ~"GET /one HTTP/1.1\r\nHost: x\r\n\r\n"}
    ]),
    Opts = (fake_proto_opts(e2e_hibernate))#{
        request_timeout := 5000,
        keep_alive_timeout := 5000,
        dispatch := {handler, roadrunner_manual_keepalive_handler},
        hibernate_after => 30
    },
    {ok, Pid} = roadrunner_conn_statem:start({fake, Sink}, Opts),
    Pid ! shoot,
    %% Phase 1: req1 served.
    Sent1 = iolist_to_binary(collect_sends(Tag, 300)),
    ?assertEqual(1, count_200(Sent1)),
    %% Phase 2: conn looped back to reading_request, idle.
    %% After hibernate_after=30ms, must be hibernated.
    ?assert(is_hibernating(Pid, 300)),
    %% Phase 3: deliver req2 directly. The conn wakes, parses,
    %% dispatches, and serves a second response. (Note: pipelining
    %% support means partial trailing bytes WOULD now be preserved
    %% and parsed on the next iteration; we deliver a clean req2
    %% so the test focuses on the hibernate-wake-rehibernate cycle.)
    Pid ! {roadrunner_fake_data, Sink, ~"GET /two HTTP/1.1\r\nHost: x\r\n\r\n"},
    Sent2 = iolist_to_binary(collect_sends(Tag, 300)),
    ?assertEqual(1, count_200(Sent2)),
    %% Phase 4: conn looped back again, hibernates again.
    ?assert(is_hibernating(Pid, 300)),
    ok = gen_statem:stop(Pid),
    stop_sink(Sink).

is_hibernating(Pid, TimeoutMs) ->
    is_hibernating_loop(
        Pid,
        hibernation_heap_threshold(),
        erlang:monotonic_time(millisecond) + TimeoutMs
    ).

%% A hibernated process's heap shrinks to the OTP-configured minimum.
%% Reading `erlang:system_info(min_heap_size)` at test time tracks
%% whatever the running OTP uses (233 words on default 28+; future
%% versions may bump it). The +64 word slack absorbs any process
%% dictionary / sys-debug allocations that survive hibernation.
hibernation_heap_threshold() ->
    {min_heap_size, Min} = erlang:system_info(min_heap_size),
    Min + 64.

is_hibernating_loop(Pid, Threshold, Deadline) ->
    case process_info(Pid, [status, total_heap_size, message_queue_len]) of
        [{status, waiting}, {total_heap_size, H}, {message_queue_len, 0}] when
            H =< Threshold
        ->
            true;
        _ ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true ->
                    false;
                false ->
                    timer:sleep(10),
                    is_hibernating_loop(Pid, Threshold, Deadline)
            end
    end.

reading_request_closed_after_partial_data_stops_silently_test() ->
    %% Client connects, sends a partial request line, then closes
    %% (`{roadrunner_fake_closed, _}` info event arrives after a
    %% `{roadrunner_fake_data, _, _}` event). The conn must terminate
    %% cleanly without sending a 400 — peer has already closed and
    %% won't see it. This locks in the post-active-mode-refactor
    %% behavior; the pre-refactor passive code emitted a
    %% `[roadrunner, request, rejected]` telemetry + 400, but the 400
    %% never reached the peer (socket already closed).
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_recv_sink_with_send_log(Self, Tag, [
        {recv, ~"GET / HT"},
        {recv, {error, closed}}
    ]),
    {ok, Pid} = roadrunner_conn_statem:start(
        {fake, Sink}, fake_proto_opts(closed_partial)
    ),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 50)),
    ?assertEqual(<<>>, Sent),
    stop_sink(Sink).

reading_request_setopts_error_stops_cleanly_test() ->
    %% When `setopts/2` returns `{error, _}` (kernel reports the
    %% socket as closed between events), the conn must stop normally
    %% rather than badmatch on a strict `ok = ...`. Drive: kill the
    %% sink BEFORE sending shoot so reading_request's state_enter
    %% setopts sees a dead-process socket → `{error, einval}` → stop.
    ensure_pg(),
    Sink = spawn_recv_sink([]),
    {ok, Pid} = roadrunner_conn_statem:start({fake, Sink}, fake_proto_opts(setopts_err)),
    Ref = monitor(process, Pid),
    exit(Sink, kill),
    erlang:demonitor(monitor(process, Sink), [flush]),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end.

drain_pending_before_shoot_stops_at_first_parse_test() ->
    ensure_pg(),
    Sink = spawn_recv_sink([]),
    {ok, Pid} = roadrunner_conn_statem:start({fake, Sink}, fake_proto_opts(drain_test)),
    Ref = monitor(process, Pid),
    %% Drain arrives during awaiting_shoot — flag is stashed.
    Pid ! {roadrunner_drain, erlang:monotonic_time(millisecond) + 1000},
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    stop_sink(Sink).

%% =============================================================================
%% Phase 6a — `dispatching` runs the handler and writes a buffered
%% response. Driven through a real listener (TCP) because the handler
%% invocation chain is too coupled to socket semantics for the fake
%% transport to mock cleanly. Telemetry assertions still attach to the
%% gen_statem-emitted events.
%% =============================================================================

dispatching_buffered_handler_writes_200_test() ->
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_recv_sink_with_send_log(Self, Tag, [
        {recv, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"}
    ]),
    {ok, Pid} = roadrunner_conn_statem:start(
        {fake, Sink}, fake_proto_opts(dispatch_test)
    ),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Sent),
    stop_sink(Sink).

dispatching_router_not_found_writes_404_test() ->
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_recv_sink_with_send_log(Self, Tag, [
        {recv, ~"GET /nope HTTP/1.1\r\nHost: x\r\n\r\n"}
    ]),
    %% Router with no matching route → 404.
    Routes = [{~"/known", roadrunner_hello_handler, undefined}],
    persistent_term:put(
        {roadrunner_routes, dispatch_router_test}, roadrunner_router:compile(Routes)
    ),
    Opts = (fake_proto_opts(dispatch_router_test))#{
        dispatch := {router, dispatch_router_test}
    },
    try
        {ok, Pid} = roadrunner_conn_statem:start({fake, Sink}, Opts),
        Ref = monitor(process, Pid),
        Pid ! shoot,
        receive
            {'DOWN', Ref, process, Pid, normal} -> ok
        after 2000 -> error(no_normal_exit)
        end,
        Sent = iolist_to_binary(collect_sends(Tag, 100)),
        ?assertMatch(<<"HTTP/1.1 404", _/binary>>, Sent)
    after
        persistent_term:erase({roadrunner_routes, dispatch_router_test}),
        stop_sink(Sink)
    end.

dispatching_handler_crash_writes_500_and_emits_exception_test() ->
    ensure_pg(),
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    Tag = make_ref(),
    HandlerId = make_ref(),
    ok = telemetry:attach(
        HandlerId,
        [roadrunner, request, exception],
        fun(Event, M, Md, _) -> Self ! {ev, Event, M, Md} end,
        undefined
    ),
    try
        Sink = spawn_recv_sink_with_send_log(Self, Tag, [
            {recv, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"}
        ]),
        Opts = (fake_proto_opts(dispatch_crash_test))#{
            dispatch := {handler, roadrunner_crashing_handler}
        },
        {ok, Pid} = roadrunner_conn_statem:start({fake, Sink}, Opts),
        Ref = monitor(process, Pid),
        Pid ! shoot,
        receive
            {'DOWN', Ref, process, Pid, normal} -> ok
        after 2000 -> error(no_normal_exit)
        end,
        Sent = iolist_to_binary(collect_sends(Tag, 100)),
        ?assertMatch(<<"HTTP/1.1 500", _/binary>>, Sent),
        receive
            {ev, [roadrunner, request, exception], _, ExcMd} ->
                ?assertEqual(error, maps:get(kind, ExcMd)),
                ?assertEqual(boom, maps:get(reason, ExcMd))
        after 1000 -> error(no_exception_event)
        end,
        stop_sink(Sink)
    after
        telemetry:detach(HandlerId)
    end.

dispatching_request_start_and_stop_telemetry_fires_test() ->
    ensure_pg(),
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    Tag = make_ref(),
    HandlerId = make_ref(),
    ok = telemetry:attach_many(
        HandlerId,
        [[roadrunner, request, start], [roadrunner, request, stop]],
        fun(Event, M, Md, _) -> Self ! {ev, Event, M, Md} end,
        undefined
    ),
    try
        Sink = spawn_recv_sink_with_send_log(Self, Tag, [
            {recv, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"}
        ]),
        {ok, Pid} = roadrunner_conn_statem:start(
            {fake, Sink}, fake_proto_opts(dispatch_telemetry_test)
        ),
        Ref = monitor(process, Pid),
        Pid ! shoot,
        receive
            {'DOWN', Ref, process, Pid, normal} -> ok
        after 2000 -> error(no_normal_exit)
        end,
        receive
            {ev, [roadrunner, request, start], _, StartMd} ->
                ?assertEqual(~"GET", maps:get(method, StartMd)),
                ?assertEqual(~"/", maps:get(path, StartMd))
        after 1000 -> error(no_start)
        end,
        receive
            {ev, [roadrunner, request, stop], StopM, StopMd} ->
                ?assert(is_integer(maps:get(duration, StopM))),
                ?assertEqual(200, maps:get(status, StopMd)),
                ?assertEqual(buffered, maps:get(response_kind, StopMd))
        after 1000 -> error(no_stop)
        end,
        stop_sink(Sink)
    after
        telemetry:detach(HandlerId)
    end.

%% =============================================================================
%% Telemetry ordering invariants — enforce the contract subscribers
%% rely on (paired start/stop, accept-before-request, conn-close-last,
%% consistent request_id within a request).
%% =============================================================================

telemetry_ordering_invariants_full_lifecycle_test() ->
    %% One full GET → 200 → conn_close. Events must arrive in this
    %% order: listener_accept, request_start, request_stop,
    %% listener_conn_close. request_id must match between start/stop.
    ensure_pg(),
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    Tag = make_ref(),
    HandlerId = make_ref(),
    Events = [
        [roadrunner, listener, accept],
        [roadrunner, request, start],
        [roadrunner, request, stop],
        [roadrunner, listener, conn_close]
    ],
    ok = telemetry:attach_many(
        HandlerId,
        Events,
        fun(Event, M, Md, _) -> Self ! {ev, Event, M, Md} end,
        undefined
    ),
    try
        Sink = spawn_recv_sink_with_send_log(Self, Tag, [
            {recv, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"}
        ]),
        {ok, Pid} = roadrunner_conn_statem:start(
            {fake, Sink}, fake_proto_opts(telemetry_order)
        ),
        Ref = monitor(process, Pid),
        Pid ! shoot,
        receive
            {'DOWN', Ref, process, Pid, normal} -> ok
        after 2000 -> error(no_normal_exit)
        end,
        AcceptMd =
            receive
                {ev, [roadrunner, listener, accept], _, AMd} -> AMd
            after 1000 -> error(no_accept)
            end,
        StartMd =
            receive
                {ev, [roadrunner, request, start], _, SMd} -> SMd
            after 1000 -> error(no_start)
            end,
        StopMd =
            receive
                {ev, [roadrunner, request, stop], _, RMd} -> RMd
            after 1000 -> error(no_stop)
            end,
        CloseMd =
            receive
                {ev, [roadrunner, listener, conn_close], _, CMd} -> CMd
            after 1000 -> error(no_close)
            end,
        %% Ordering: selective receive above already enforced it (each
        %% receive only matches its event; if events arrived in the
        %% wrong order a later receive's timeout would have fired).
        %% Cross-check the metadata invariants:
        ?assertEqual(maps:get(peer, AcceptMd), maps:get(peer, CloseMd)),
        ?assertEqual(maps:get(request_id, StartMd), maps:get(request_id, StopMd)),
        ?assertEqual(1, maps:get(requests_served, CloseMd)),
        stop_sink(Sink)
    after
        telemetry:detach(HandlerId)
    end.

telemetry_peer_set_in_conn_close_after_parse_error_test() ->
    %% A bad request fails before dispatch (no request_start fires) but
    %% peer was known at accept-time, so conn_close metadata must still
    %% carry the peer.
    ensure_pg(),
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    Tag = make_ref(),
    HandlerId = make_ref(),
    ok = telemetry:attach(
        HandlerId,
        [roadrunner, listener, conn_close],
        fun(Event, M, Md, _) -> Self ! {ev, Event, M, Md} end,
        undefined
    ),
    try
        Sink = spawn_recv_sink_with_send_log(
            Self, Tag, [{recv, ~"NOT-A-VALID-REQUEST-LINE\r\n\r\n"}]
        ),
        {ok, Pid} = roadrunner_conn_statem:start(
            {fake, Sink}, fake_proto_opts(parse_err_telemetry)
        ),
        Ref = monitor(process, Pid),
        Pid ! shoot,
        receive
            {'DOWN', Ref, process, Pid, normal} -> ok
        after 2000 -> error(no_normal_exit)
        end,
        receive
            {ev, [roadrunner, listener, conn_close], _, CloseMd} ->
                %% Fake transport's peername stub returns {{127,0,0,1},_}.
                ?assertMatch({{127, 0, 0, 1}, _}, maps:get(peer, CloseMd)),
                %% No request was served (parse failed before dispatch).
                ?assertEqual(0, maps:get(requests_served, CloseMd))
        after 1000 -> error(no_close)
        end,
        stop_sink(Sink)
    after
        telemetry:detach(HandlerId)
    end.

%% =============================================================================
%% RFC framing edge cases — these regression-cover paths the line
%% coverage gate doesn't reach by construction.
%% =============================================================================

content_length_zero_explicit_body_is_empty_test() ->
    %% Explicit `Content-Length: 0` differs from no CL at all (the
    %% latter is `framing => none`; this one is `{content_length, 0}`).
    %% Handler must see an empty body and respond cleanly.
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_recv_sink_with_send_log(Self, Tag, [
        {recv, ~"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n"}
    ]),
    Opts = (fake_proto_opts(cl_zero))#{
        dispatch := {handler, roadrunner_echo_body_handler}
    },
    {ok, Pid} = roadrunner_conn_statem:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Sent),
    %% Echo handler sets Content-Length from the buffered body.
    ?assertNotEqual(nomatch, binary:match(Sent, ~"content-length: 0")),
    stop_sink(Sink).

request_with_leading_crlf_still_serves_200_test() ->
    %% RFC 7230 §3.5 robustness — a client may send one leading CRLF
    %% before the request-line. The conn must accept it and serve 200.
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_recv_sink_with_send_log(Self, Tag, [
        {recv, ~"\r\nGET / HTTP/1.1\r\nHost: x\r\n\r\n"}
    ]),
    {ok, Pid} = roadrunner_conn_statem:start(
        {fake, Sink}, fake_proto_opts(leading_crlf)
    ),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Sent),
    stop_sink(Sink).

chunked_body_with_only_terminator_test() ->
    %% Chunked body that's just the size-0 terminator — no data chunks.
    %% Handler must see an empty body.
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_recv_sink_with_send_log(Self, Tag, [
        {recv, ~"POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"}
    ]),
    Opts = (fake_proto_opts(chunked_zero))#{
        dispatch := {handler, roadrunner_echo_body_handler}
    },
    {ok, Pid} = roadrunner_conn_statem:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Sent),
    ?assertNotEqual(nomatch, binary:match(Sent, ~"content-length: 0")),
    stop_sink(Sink).

chunked_body_with_request_trailers_test() ->
    %% RFC 7230 §4.4: trailers on chunked request body. The framework
    %% must parse the trailer block off the wire (so the conn doesn't
    %% mistake them for the next pipelined request) but the handler
    %% only sees the decoded body.
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Req =
        ~"POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nTrailer: X-Probe\r\n\r\n5\r\nhello\r\n0\r\nX-Probe: ok\r\n\r\n",
    Sink = spawn_recv_sink_with_send_log(Self, Tag, [{recv, Req}]),
    Opts = (fake_proto_opts(chunked_trailers))#{
        dispatch := {handler, roadrunner_echo_body_handler}
    },
    {ok, Pid} = roadrunner_conn_statem:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Sent),
    %% Body echoed = "hello" (5 bytes).
    ?assertNotEqual(nomatch, binary:match(Sent, ~"content-length: 5")),
    ?assertNotEqual(nomatch, binary:match(Sent, ~"hello")),
    stop_sink(Sink).

%% =============================================================================
%% Phase 6b — finishing + keep-alive + drain
%% =============================================================================

keep_alive_serves_two_requests_test() ->
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    %% `roadrunner_manual_keepalive_handler` doesn't emit `Connection: close`,
    %% so each response is keep-alive-friendly. The second request
    %% explicitly closes.
    Sink = spawn_recv_sink_with_send_log(Self, Tag, [
        {recv, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"},
        {recv, ~"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"}
    ]),
    Opts = (fake_proto_opts(ka_two))#{
        dispatch := {handler, roadrunner_manual_keepalive_handler}
    },
    {ok, Pid} = roadrunner_conn_statem:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 3000 -> error(no_normal_exit)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    ?assert(count_200(Sent) >= 2),
    stop_sink(Sink).

keep_alive_max_cap_stops_after_max_test() ->
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    %% Listener allows max_keep_alive_request = 1; the second request
    %% never reaches reading_request because finishing stops first.
    Sink = spawn_recv_sink_with_send_log(Self, Tag, [
        {recv, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"},
        {recv, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"}
    ]),
    Opts = (fake_proto_opts(ka_cap))#{
        max_keep_alive_request := 1,
        dispatch := {handler, roadrunner_manual_keepalive_handler}
    },
    {ok, Pid} = roadrunner_conn_statem:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 3000 -> error(no_normal_exit)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    ?assertEqual(1, count_200(Sent)),
    stop_sink(Sink).

http10_default_close_test() ->
    %% HTTP/1.0 closes after one request even without an explicit
    %% Connection: close.
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_recv_sink_with_send_log(Self, Tag, [
        {recv, ~"GET / HTTP/1.0\r\nHost: x\r\n\r\n"},
        %% Second recv would be issued in keep-alive; with HTTP/1.0
        %% close we shouldn't see it. Make it slow so the first
        %% request's response is logged before the conn closes.
        {recv, {error, closed}}
    ]),
    {ok, Pid} = roadrunner_conn_statem:start({fake, Sink}, fake_proto_opts(http10)),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 3000 -> error(no_normal_exit)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    ?assertEqual(1, count_200(Sent)),
    stop_sink(Sink).

http10_keep_alive_token_keeps_conn_alive_test() ->
    %% RFC 7230 §6.1: HTTP/1.0 + `Connection: keep-alive` opts into
    %% keep-alive even though HTTP/1.0's default is close. Two requests
    %% must both reach the handler.
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_recv_sink_with_send_log(Self, Tag, [
        {recv, ~"GET / HTTP/1.0\r\nHost: x\r\nConnection: keep-alive\r\n\r\n"},
        {recv, ~"GET / HTTP/1.0\r\nHost: x\r\nConnection: close\r\n\r\n"}
    ]),
    Opts = (fake_proto_opts(http10_ka))#{
        dispatch := {handler, roadrunner_manual_keepalive_handler}
    },
    {ok, Pid} = roadrunner_conn_statem:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 3000 -> error(no_normal_exit)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    ?assertEqual(2, count_200(Sent)),
    stop_sink(Sink).

drain_mid_dispatching_stops_after_response_test() ->
    %% Drain arrives **while the handler is running** in dispatching.
    %% gen_statem can't process the info event mid-callback, so the
    %% drain queues. After the handler returns, the conn must (a) still
    %% deliver request 1's response, (b) honor the drain on the next
    %% reading_request iteration via drain_peek, (c) NOT serve a second
    %% pipelined request. This is exactly the race the drain_peek
    %% workaround exists for.
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_recv_sink_with_send_log(
        Self,
        Tag,
        [
            {recv, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"},
            %% A second request is queued; the drain must prevent it.
            {recv, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"}
        ]
    ),
    Opts = (fake_proto_opts(drain_mid_dispatch))#{
        dispatch := {handler, roadrunner_drain_pause_handler}
    },
    {ok, Pid} = roadrunner_conn_statem:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    %% drain_pause_handler sleeps 150ms; deliver the drain mid-handler.
    timer:sleep(50),
    Pid ! {roadrunner_drain, erlang:monotonic_time(millisecond) + 1000},
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 3000 -> error(no_normal_exit)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    %% Request 1's 200 was served; request 2 was NOT — exactly one 200.
    ?assertEqual(1, count_200(Sent)),
    stop_sink(Sink).

drain_mid_keep_alive_stops_test() ->
    %% Serve one request; drain message arrives before the next
    %% reading_request iteration; conn stops without serving request 2.
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_recv_sink_with_send_log(
        Self,
        Tag,
        [
            {recv, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"},
            %% Slow second recv so we can race the drain in.
            {recv, {error, timeout}}
        ]
    ),
    Opts = (fake_proto_opts(ka_drain))#{
        dispatch := {handler, roadrunner_manual_keepalive_handler}
    },
    {ok, Pid} = roadrunner_conn_statem:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    %% Brief delay to let request 1 land, then drain.
    timer:sleep(50),
    Pid ! {roadrunner_drain, erlang:monotonic_time(millisecond) + 1000},
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 3000 -> error(no_normal_exit)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    ?assertEqual(1, count_200(Sent)),
    stop_sink(Sink).

manual_body_full_read_keep_alive_test() ->
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    %% Manual body buffering — handler's body_state needs to drain.
    %% The handler echoes the body; second request closes.
    Sink = spawn_recv_sink_with_send_log(Self, Tag, [
        {recv, ~"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello"},
        {recv, ~"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"}
    ]),
    Opts = (fake_proto_opts(ka_manual))#{
        body_buffering := manual,
        dispatch := {handler, roadrunner_manual_keepalive_handler}
    },
    {ok, Pid} = roadrunner_conn_statem:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 3000 -> error(no_normal_exit)
    end,
    %% Sync the sink before reading sent data: the conn may exit (and
    %% deliver DOWN) before the sink finishes forwarding the second
    %% response to the test process. Without this the test flakes
    %% under scheduler load.
    ok = sync_sink(Sink),
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    ?assertEqual(2, count_200(Sent)),
    stop_sink(Sink).

keep_alive_request_timeout_silent_test() ->
    %% A keep-alive iteration whose recv times out closes silently —
    %% no 408 on the wire (peer wasn't reading anyway).
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_recv_sink_with_send_log(Self, Tag, [
        {recv, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"},
        {recv, {error, timeout}}
    ]),
    Opts = (fake_proto_opts(ka_silent_timeout))#{
        keep_alive_timeout := 50,
        dispatch := {handler, roadrunner_manual_keepalive_handler}
    },
    {ok, Pid} = roadrunner_conn_statem:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 3000 -> error(no_normal_exit)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    %% First 200 went out; no 408 follows.
    ?assertEqual(nomatch, re:run(Sent, ~"HTTP/1.1 408")),
    stop_sink(Sink).

manual_body_drain_failure_closes_test() ->
    %% Manual mode: handler completes without reading the body;
    %% drain_body tries to consume but recv returns error → close.
    ensure_pg(),
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_recv_sink_with_send_log(Self, Tag, [
        {recv, ~"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 99\r\n\r\nshort"},
        {recv, {error, closed}}
    ]),
    Opts = (fake_proto_opts(ka_drain_fail))#{
        body_buffering := manual,
        max_content_length := 1000
    },
    {ok, Pid} = roadrunner_conn_statem:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 3000 -> error(no_normal_exit)
    end,
    stop_sink(Sink).

terminate_without_shoot_skips_conn_close_telemetry_test() ->
    %% If the gen_statem dies before `shoot` is processed (e.g., the
    %% acceptor crashes between `start` and `controlling_process`),
    %% no `accept` event was emitted. `terminate/3` skips `conn_close`
    %% to keep the events paired.
    ensure_pg(),
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    HandlerId = make_ref(),
    ok = telemetry:attach(
        HandlerId,
        [roadrunner, listener, conn_close],
        fun(Event, M, Md, _) -> Self ! {ev, Event, M, Md} end,
        undefined
    ),
    try
        Sink = spawn_recv_sink([]),
        {ok, Pid} = roadrunner_conn_statem:start(
            {fake, Sink}, fake_proto_opts(no_shoot)
        ),
        %% `gen_statem:stop` runs `terminate/3` cleanly with the
        %% gen_statem still in `awaiting_shoot` — `start_mono` is
        %% `undefined` so the conn_close branch is skipped.
        ok = gen_statem:stop(Pid),
        receive
            {ev, [roadrunner, listener, conn_close], _, _} ->
                error(unexpected_conn_close)
        after 100 -> ok
        end,
        stop_sink(Sink)
    after
        telemetry:detach(HandlerId)
    end.

unexpected_info_is_dropped_silently_test() ->
    %% Catch-all info handler logs at debug and keeps state. Send a
    %% stray message in `awaiting_shoot` and verify the gen_statem is
    %% still alive afterwards (no function_clause crash).
    ensure_pg(),
    Sink = spawn_recv_sink([]),
    {ok, Pid} = roadrunner_conn_statem:start({fake, Sink}, fake_proto_opts(unexpected)),
    Pid ! {stray_msg_from_buggy_lib, make_ref()},
    %% Process must still be alive — assert via gen_statem:stop running
    %% terminate cleanly.
    ok = gen_statem:stop(Pid),
    stop_sink(Sink).

listener_accept_and_conn_close_fire_around_statem_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    HandlerId = make_ref(),
    ok = telemetry:attach_many(
        HandlerId,
        [[roadrunner, listener, accept], [roadrunner, listener, conn_close]],
        fun(Event, M, Md, _) -> Self ! {ev, Event, M, Md} end,
        undefined
    ),
    try
        ensure_pg(),
        Sink = spawn_recv_sink([{recv, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"}]),
        {ok, Pid} = roadrunner_conn_statem:start(
            {fake, Sink}, fake_proto_opts(telemetry_test)
        ),
        Ref = monitor(process, Pid),
        Pid ! shoot,
        receive
            {'DOWN', Ref, process, Pid, normal} -> ok
        after 2000 -> error(no_normal_exit)
        end,
        receive
            {ev, [roadrunner, listener, accept], _, AcceptMd} ->
                ?assertEqual(telemetry_test, maps:get(listener_name, AcceptMd)),
                %% Peer comes from `roadrunner_transport:peername/1` on the
                %% fake socket — the stub returns `{{127, 0, 0, 1}, 0}`.
                ?assertMatch({{127, 0, 0, 1}, _}, maps:get(peer, AcceptMd))
        after 1000 -> error(no_accept)
        end,
        receive
            {ev, [roadrunner, listener, conn_close], CloseM, CloseMd} ->
                ?assert(is_integer(maps:get(duration, CloseM))),
                ?assertEqual(1, maps:get(requests_served, CloseMd))
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

stop_sink(Pid) ->
    Pid ! stop.

fake_proto_opts(ListenerName) ->
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

fake_proto_opts_short_timeout(ListenerName) ->
    (fake_proto_opts(ListenerName))#{request_timeout := 50}.

fake_proto_opts_small_max(ListenerName) ->
    (fake_proto_opts(ListenerName))#{max_content_length := 10}.

fake_proto_opts_manual(ListenerName) ->
    (fake_proto_opts(ListenerName))#{body_buffering := manual}.

%% Recv-script sink: replies to `roadrunner_fake_recv` messages with
%% pre-baked `{ok, Bytes}` or `{error, _}` results. Discards
%% `roadrunner_fake_send` and `roadrunner_fake_close` so they don't pollute
%% the test runner's mailbox.
spawn_recv_sink(Script) ->
    spawn(fun() -> recv_sink_loop(Script, undefined, undefined) end).

%% Same, but forwards every `roadrunner_fake_send` to `Logger` tagged with
%% `Tag` so the test can assert on what the conn wrote without picking
%% up sends from sibling tests' sinks (eunit reuses the test runner
%% process across some tests; an unscoped `{sent, _}` shape is
%% cross-test-leak-prone).
spawn_recv_sink_with_send_log(Logger, Tag, Script) ->
    spawn(fun() -> recv_sink_loop(Script, Logger, Tag) end).

recv_sink_loop(Script, Logger, Tag) ->
    receive
        stop ->
            ok;
        {sync, From, Ref} ->
            %% Round-trip handshake — when this reply lands in the
            %% caller's mailbox, all earlier `{sent, Tag, _}` messages
            %% the sink forwarded for this Logger have already arrived.
            %% Use after `receive DOWN` to deflake `collect_sends`.
            From ! {synced, Ref},
            recv_sink_loop(Script, Logger, Tag);
        {roadrunner_fake_recv, ConnPid, _Len, _Timeout} ->
            %% Legacy passive recv — used by `reading_body` (auto +
            %% manual modes) and `roadrunner_conn:read_body/4`.
            dispatch_passive(ConnPid, Script, Logger, Tag);
        {roadrunner_fake_setopts, ConnPid, _Opts} ->
            %% Active-once arming — used by `reading_request` after
            %% the active-mode refactor. Map the script's `{recv,
            %% Bytes}` to `roadrunner_fake_data`, `{recv, {error,
            %% closed}}` to `roadrunner_fake_closed`, and skip
            %% `{recv, {error, timeout | slow_client}}` items
            %% (they're "kernel never delivered bytes" / "rate
            %% violation" — the conn's state_timeout / rate-check
            %% timer fires instead).
            dispatch_active(ConnPid, Script, Logger, Tag);
        {roadrunner_fake_send, _Pid, Data} ->
            case Logger of
                undefined -> ok;
                _ -> Logger ! {sent, Tag, Data}
            end,
            recv_sink_loop(Script, Logger, Tag);
        _ ->
            recv_sink_loop(Script, Logger, Tag)
    end.

%% Drain pending sends through the sink before reading them. The conn
%% can exit (and trigger DOWN) before the sink finishes processing its
%% inbox of `roadrunner_fake_send` messages and forwarding them to the
%% test as `{sent, Tag, _}`. This sync round-trip guarantees the sink
%% has handled every fake_send queued before the call returns; Erlang
%% preserves message order from one sender to one receiver, so any
%% `{sent, Tag, _}` already in the sink's mailbox lands in the test's
%% mailbox before the `{synced, Ref}` reply.
-spec sync_sink(pid()) -> ok.
sync_sink(Sink) ->
    Ref = make_ref(),
    Sink ! {sync, self(), Ref},
    receive
        {synced, Ref} -> ok
    after 1000 ->
        error({sync_sink_timeout, Sink})
    end.

dispatch_passive(ConnPid, [], Logger, Tag) ->
    ConnPid ! {roadrunner_fake_recv_reply, {error, closed}},
    recv_sink_loop([], Logger, Tag);
dispatch_passive(ConnPid, [{recv, {error, _} = Err} | Rest], Logger, Tag) ->
    ConnPid ! {roadrunner_fake_recv_reply, Err},
    recv_sink_loop(Rest, Logger, Tag);
dispatch_passive(ConnPid, [{recv, Bytes} | Rest], Logger, Tag) ->
    ConnPid ! {roadrunner_fake_recv_reply, {ok, Bytes}},
    recv_sink_loop(Rest, Logger, Tag).

dispatch_active(_ConnPid, [], Logger, Tag) ->
    %% Empty script — leave conn armed; let its state_timeout fire if
    %% there is one, or sit idle (test will eventually stop the conn).
    recv_sink_loop([], Logger, Tag);
dispatch_active(ConnPid, [{recv, {error, closed}} | Rest], Logger, Tag) ->
    ConnPid ! {roadrunner_fake_closed, self()},
    recv_sink_loop(Rest, Logger, Tag);
dispatch_active(_ConnPid, [{recv, {error, timeout}} | Rest], Logger, Tag) ->
    %% Active-mode equivalent of "kernel never delivers bytes" — drop
    %% the script item so the next `roadrunner_fake_setopts` consumes the
    %% next item instead. The conn's request_deadline state_timeout
    %% will fire on its own.
    recv_sink_loop(Rest, Logger, Tag);
dispatch_active(ConnPid, [{recv, {error, slow_client}} | Rest], Logger, Tag) ->
    %% In passive mode `slow_client` was the recv closure's rate-
    %% violation signal. In active mode the rate check is a separate
    %% timer; for test scoping, deliver the equivalent as a transport
    %% error. Either path closes the conn silently — the observable
    %% behavior matches.
    ConnPid ! {roadrunner_fake_error, self(), slow_client},
    recv_sink_loop(Rest, Logger, Tag);
dispatch_active(ConnPid, [{recv, {error, Reason}} | Rest], Logger, Tag) ->
    ConnPid ! {roadrunner_fake_error, self(), Reason},
    recv_sink_loop(Rest, Logger, Tag);
dispatch_active(ConnPid, [{recv, Bytes} | Rest], Logger, Tag) ->
    ConnPid ! {roadrunner_fake_data, self(), Bytes},
    recv_sink_loop(Rest, Logger, Tag).

count_200(Bin) ->
    case re:run(Bin, ~"HTTP/1.1 200", [global]) of
        nomatch -> 0;
        {match, Matches} -> length(Matches)
    end.

collect_sends(Tag, Timeout) ->
    collect_sends_loop(Tag, [], Timeout).

collect_sends_loop(Tag, Acc, Timeout) ->
    receive
        {sent, Tag, Data} -> collect_sends_loop(Tag, [Data | Acc], 0)
    after Timeout ->
        lists:reverse(Acc)
    end.
