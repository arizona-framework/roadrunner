-module(cactus_conn_statem_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Phase 4 + 5 — drives init/1 -> awaiting_shoot -> reading_request ->
%% reading_body -> stop_normal end-to-end via the fake transport. A
%% per-test recv-script sink replies to `cactus_fake_recv` messages
%% with pre-baked bytes / errors and discards `cactus_fake_send` /
%% `cactus_fake_close` so they don't pollute the test runner mailbox.
%% =============================================================================

reading_request_parses_then_reading_body_full_request_test() ->
    ensure_pg(),
    Sink = spawn_recv_sink([{recv, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"}]),
    {ok, Pid} = cactus_conn_statem:start({fake, Sink}, fake_proto_opts(read1)),
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
    {ok, Pid} = cactus_conn_statem:start(
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
    {ok, Pid} = cactus_conn_statem:start(
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
    {ok, Pid} = cactus_conn_statem:start({fake, Sink}, fake_proto_opts(read_400)),
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
    {ok, Pid} = cactus_conn_statem:start(
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
    {ok, Pid} = cactus_conn_statem:start(
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
    {ok, Pid} = cactus_conn_statem:start(
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
    {ok, Pid} = cactus_conn_statem:start(
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
    {ok, Pid} = cactus_conn_statem:start(
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
    {ok, Pid} = cactus_conn_statem:start(
        {fake, Sink}, fake_proto_opts_manual(read_manual)
    ),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit)
    end,
    stop_sink(Sink).

drain_pending_before_shoot_stops_at_first_parse_test() ->
    ensure_pg(),
    Sink = spawn_recv_sink([]),
    {ok, Pid} = cactus_conn_statem:start({fake, Sink}, fake_proto_opts(drain_test)),
    Ref = monitor(process, Pid),
    %% Drain arrives during awaiting_shoot — flag is stashed.
    Pid ! {cactus_drain, erlang:monotonic_time(millisecond) + 1000},
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
    {ok, Pid} = cactus_conn_statem:start(
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
    Routes = [{~"/known", cactus_hello_handler, undefined}],
    persistent_term:put(
        {cactus_routes, dispatch_router_test}, cactus_router:compile(Routes)
    ),
    Opts = (fake_proto_opts(dispatch_router_test))#{
        dispatch := {router, dispatch_router_test}
    },
    try
        {ok, Pid} = cactus_conn_statem:start({fake, Sink}, Opts),
        Ref = monitor(process, Pid),
        Pid ! shoot,
        receive
            {'DOWN', Ref, process, Pid, normal} -> ok
        after 2000 -> error(no_normal_exit)
        end,
        Sent = iolist_to_binary(collect_sends(Tag, 100)),
        ?assertMatch(<<"HTTP/1.1 404", _/binary>>, Sent)
    after
        persistent_term:erase({cactus_routes, dispatch_router_test}),
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
        [cactus, request, exception],
        fun(Event, M, Md, _) -> Self ! {ev, Event, M, Md} end,
        undefined
    ),
    try
        Sink = spawn_recv_sink_with_send_log(Self, Tag, [
            {recv, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"}
        ]),
        Opts = (fake_proto_opts(dispatch_crash_test))#{
            dispatch := {handler, cactus_crashing_handler}
        },
        {ok, Pid} = cactus_conn_statem:start({fake, Sink}, Opts),
        Ref = monitor(process, Pid),
        Pid ! shoot,
        receive
            {'DOWN', Ref, process, Pid, normal} -> ok
        after 2000 -> error(no_normal_exit)
        end,
        Sent = iolist_to_binary(collect_sends(Tag, 100)),
        ?assertMatch(<<"HTTP/1.1 500", _/binary>>, Sent),
        receive
            {ev, [cactus, request, exception], _, ExcMd} ->
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
        [[cactus, request, start], [cactus, request, stop]],
        fun(Event, M, Md, _) -> Self ! {ev, Event, M, Md} end,
        undefined
    ),
    try
        Sink = spawn_recv_sink_with_send_log(Self, Tag, [
            {recv, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"}
        ]),
        {ok, Pid} = cactus_conn_statem:start(
            {fake, Sink}, fake_proto_opts(dispatch_telemetry_test)
        ),
        Ref = monitor(process, Pid),
        Pid ! shoot,
        receive
            {'DOWN', Ref, process, Pid, normal} -> ok
        after 2000 -> error(no_normal_exit)
        end,
        receive
            {ev, [cactus, request, start], _, StartMd} ->
                ?assertEqual(~"GET", maps:get(method, StartMd)),
                ?assertEqual(~"/", maps:get(path, StartMd))
        after 1000 -> error(no_start)
        end,
        receive
            {ev, [cactus, request, stop], StopM, StopMd} ->
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
        dispatch := {handler, cactus_echo_body_handler}
    },
    {ok, Pid} = cactus_conn_statem:start({fake, Sink}, Opts),
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
        dispatch := {handler, cactus_echo_body_handler}
    },
    {ok, Pid} = cactus_conn_statem:start({fake, Sink}, Opts),
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
        dispatch := {handler, cactus_echo_body_handler}
    },
    {ok, Pid} = cactus_conn_statem:start({fake, Sink}, Opts),
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
    %% `cactus_manual_keepalive_handler` doesn't emit `Connection: close`,
    %% so each response is keep-alive-friendly. The second request
    %% explicitly closes.
    Sink = spawn_recv_sink_with_send_log(Self, Tag, [
        {recv, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"},
        {recv, ~"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"}
    ]),
    Opts = (fake_proto_opts(ka_two))#{
        dispatch := {handler, cactus_manual_keepalive_handler}
    },
    {ok, Pid} = cactus_conn_statem:start({fake, Sink}, Opts),
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
        dispatch := {handler, cactus_manual_keepalive_handler}
    },
    {ok, Pid} = cactus_conn_statem:start({fake, Sink}, Opts),
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
    {ok, Pid} = cactus_conn_statem:start({fake, Sink}, fake_proto_opts(http10)),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 3000 -> error(no_normal_exit)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
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
        dispatch := {handler, cactus_manual_keepalive_handler}
    },
    {ok, Pid} = cactus_conn_statem:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    %% Brief delay to let request 1 land, then drain.
    timer:sleep(50),
    Pid ! {cactus_drain, erlang:monotonic_time(millisecond) + 1000},
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
        dispatch := {handler, cactus_manual_keepalive_handler}
    },
    {ok, Pid} = cactus_conn_statem:start({fake, Sink}, Opts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 3000 -> error(no_normal_exit)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    ?assert(count_200(Sent) >= 2),
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
        dispatch := {handler, cactus_manual_keepalive_handler}
    },
    {ok, Pid} = cactus_conn_statem:start({fake, Sink}, Opts),
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
    {ok, Pid} = cactus_conn_statem:start({fake, Sink}, Opts),
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
        [cactus, listener, conn_close],
        fun(Event, M, Md, _) -> Self ! {ev, Event, M, Md} end,
        undefined
    ),
    try
        Sink = spawn_recv_sink([]),
        {ok, Pid} = cactus_conn_statem:start(
            {fake, Sink}, fake_proto_opts(no_shoot)
        ),
        %% `gen_statem:stop` runs `terminate/3` cleanly with the
        %% gen_statem still in `awaiting_shoot` — `start_mono` is
        %% `undefined` so the conn_close branch is skipped.
        ok = gen_statem:stop(Pid),
        receive
            {ev, [cactus, listener, conn_close], _, _} ->
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
    {ok, Pid} = cactus_conn_statem:start({fake, Sink}, fake_proto_opts(unexpected)),
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
        [[cactus, listener, accept], [cactus, listener, conn_close]],
        fun(Event, M, Md, _) -> Self ! {ev, Event, M, Md} end,
        undefined
    ),
    try
        ensure_pg(),
        Sink = spawn_recv_sink([{recv, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"}]),
        {ok, Pid} = cactus_conn_statem:start(
            {fake, Sink}, fake_proto_opts(telemetry_test)
        ),
        Ref = monitor(process, Pid),
        Pid ! shoot,
        receive
            {'DOWN', Ref, process, Pid, normal} -> ok
        after 2000 -> error(no_normal_exit)
        end,
        receive
            {ev, [cactus, listener, accept], _, AcceptMd} ->
                ?assertEqual(telemetry_test, maps:get(listener_name, AcceptMd)),
                %% Peer comes from `cactus_transport:peername/1` on the
                %% fake socket — the stub returns `{{127, 0, 0, 1}, 0}`.
                ?assertMatch({{127, 0, 0, 1}, _}, maps:get(peer, AcceptMd))
        after 1000 -> error(no_accept)
        end,
        receive
            {ev, [cactus, listener, conn_close], CloseM, CloseMd} ->
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

fake_proto_opts_short_timeout(ListenerName) ->
    (fake_proto_opts(ListenerName))#{request_timeout := 50}.

fake_proto_opts_small_max(ListenerName) ->
    (fake_proto_opts(ListenerName))#{max_content_length := 10}.

fake_proto_opts_manual(ListenerName) ->
    (fake_proto_opts(ListenerName))#{body_buffering := manual}.

%% Recv-script sink: replies to `cactus_fake_recv` messages with
%% pre-baked `{ok, Bytes}` or `{error, _}` results. Discards
%% `cactus_fake_send` and `cactus_fake_close` so they don't pollute
%% the test runner's mailbox.
spawn_recv_sink(Script) ->
    spawn(fun() -> recv_sink_loop(Script, undefined, undefined) end).

%% Same, but forwards every `cactus_fake_send` to `Logger` tagged with
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
        {cactus_fake_recv, ConnPid, _Len, _Timeout} ->
            case Script of
                [] ->
                    ConnPid ! {cactus_fake_recv_reply, {error, closed}},
                    recv_sink_loop([], Logger, Tag);
                [{recv, {error, _} = Err} | Rest] ->
                    ConnPid ! {cactus_fake_recv_reply, Err},
                    recv_sink_loop(Rest, Logger, Tag);
                [{recv, Bytes} | Rest] ->
                    ConnPid ! {cactus_fake_recv_reply, {ok, Bytes}},
                    recv_sink_loop(Rest, Logger, Tag)
            end;
        {cactus_fake_send, _Pid, Data} ->
            case Logger of
                undefined -> ok;
                _ -> Logger ! {sent, Tag, Data}
            end,
            recv_sink_loop(Script, Logger, Tag);
        _ ->
            recv_sink_loop(Script, Logger, Tag)
    end.

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
