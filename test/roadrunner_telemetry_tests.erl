-module(roadrunner_telemetry_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% [roadrunner, request, start | stop | exception] events fire around the
%% middleware/handler pipeline. Verified end-to-end through a real listener
%% so the conn's `handle_and_send` is actually exercised.
%% =============================================================================

request_start_and_stop_fire_with_metadata_test_() ->
    {setup, fun setup_listener/0, fun cleanup_listener/1, fun({Name, Port}) ->
        {"buffered handler emits start + stop with status + duration", fun() ->
            HandlerId = attach([
                [roadrunner, request, start],
                [roadrunner, request, stop]
            ]),
            try
                ok = send_simple_get(Port),
                Events = collect_events(2),
                [{Start, StartM, StartMd}, {Stop, StopM, StopMd}] = sort_by_event(Events),
                ?assertEqual([roadrunner, request, start], Start),
                ?assertEqual([roadrunner, request, stop], Stop),
                %% Start measurements: system_time only.
                ?assertMatch(#{system_time := _}, StartM),
                %% Start metadata: request_id, peer, method, path, scheme, listener_name.
                ?assertMatch(<<_:16/binary>>, maps:get(request_id, StartMd)),
                ?assertEqual(~"GET", maps:get(method, StartMd)),
                ?assertEqual(~"/", maps:get(path, StartMd)),
                ?assertEqual(http, maps:get(scheme, StartMd)),
                ?assertEqual(Name, maps:get(listener_name, StartMd)),
                ?assertMatch({{127, 0, 0, 1}, _}, maps:get(peer, StartMd)),
                %% Stop measurements: duration in native units.
                ?assert(is_integer(maps:get(duration, StopM))),
                ?assert(maps:get(duration, StopM) > 0),
                %% Stop metadata: start metadata + status + response_kind.
                ?assertEqual(maps:get(request_id, StartMd), maps:get(request_id, StopMd)),
                ?assertEqual(200, maps:get(status, StopMd)),
                ?assertEqual(buffered, maps:get(response_kind, StopMd))
            after
                detach(HandlerId)
            end
        end}
    end}.

response_send_failed_event_fires_on_error_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    HandlerId = attach([[roadrunner, response, send_failed]]),
    try
        ok = logger:set_process_metadata(#{
            request_id => ~"deadbeefcafef00d",
            method => ~"GET",
            path => ~"/probe",
            peer => {{127, 0, 0, 1}, 4242}
        }),
        Result = roadrunner_telemetry:response_send({error, closed}, buffered_response),
        ?assertEqual({error, closed}, Result),
        receive
            {telemetry_event, [roadrunner, response, send_failed], M, Md} ->
                ?assert(is_integer(maps:get(system_time, M))),
                ?assertEqual(buffered_response, maps:get(phase, Md)),
                ?assertEqual(closed, maps:get(reason, Md)),
                ?assertEqual(~"deadbeefcafef00d", maps:get(request_id, Md)),
                ?assertEqual(~"GET", maps:get(method, Md)),
                ?assertEqual(~"/probe", maps:get(path, Md))
        after 1000 -> error(no_send_failed_event)
        end
    after
        logger:unset_process_metadata(),
        detach(HandlerId)
    end.

response_send_ok_does_not_emit_event_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    HandlerId = attach([[roadrunner, response, send_failed]]),
    try
        ?assertEqual(ok, roadrunner_telemetry:response_send(ok, buffered_response)),
        receive
            {telemetry_event, [roadrunner, response, send_failed], _, _} ->
                error(unexpected_event)
        after 100 -> ok
        end
    after
        detach(HandlerId)
    end.

response_send_failed_works_without_logger_metadata_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    %% Ensure no metadata is set on this process.
    logger:unset_process_metadata(),
    HandlerId = attach([[roadrunner, response, send_failed]]),
    try
        _ = roadrunner_telemetry:response_send({error, closed}, buffered_response),
        receive
            {telemetry_event, [roadrunner, response, send_failed], _, Md} ->
                %% Only `phase` and `reason` populated when there's no
                %% process metadata yet (rare pre-handshake error path).
                ?assertEqual(buffered_response, maps:get(phase, Md)),
                ?assertEqual(closed, maps:get(reason, Md)),
                ?assertNot(maps:is_key(request_id, Md))
        after 1000 -> error(no_send_failed_event)
        end
    after
        detach(HandlerId)
    end.

request_rejected_event_fires_on_bad_request_line_test() ->
    %% Malformed request line is dropped at the parser layer; emit
    %% `[roadrunner, request, rejected]` with the parser's reason atom so
    %% ops tooling can track protocol-attack-shaped traffic.
    {ok, _} = application:ensure_all_started(telemetry),
    case whereis(pg) of
        undefined -> {ok, _} = pg:start_link();
        _ -> ok
    end,
    HandlerId = attach([[roadrunner, request, rejected]]),
    try
        Self = self(),
        Tag = make_ref(),
        Sink = spawn(fun() -> drain_recv_sink(Tag, Self, [{recv, ~"NOT-A-REQUEST\r\n\r\n"}]) end),
        Opts = #{
            dispatch => {handler, roadrunner_hello_handler},
            middlewares => [],
            max_content_length => 1_000_000,
            request_timeout => 200,
            keep_alive_timeout => 200,
            max_keep_alive_request => 100,
            max_clients => 10,
            client_counter => atomics:new(1, [{signed, false}]),
            requests_counter => atomics:new(1, [{signed, false}]),
            minimum_bytes_per_second => 0,
            body_buffering => auto,
            listener_name => probe_listener_rej
        },
        true = roadrunner_conn:try_acquire_slot(Opts),
        {ok, Pid} = roadrunner_conn:start({fake, Sink}, Opts),
        Ref = monitor(process, Pid),
        Pid ! shoot,
        receive
            {'DOWN', Ref, process, Pid, normal} -> ok
        after 2000 -> error(no_normal_exit)
        end,
        receive
            {telemetry_event, [roadrunner, request, rejected], _, Md} ->
                ?assertEqual(probe_listener_rej, maps:get(listener_name, Md)),
                ?assertEqual(bad_request_line, maps:get(reason, Md))
        after 1000 -> error(no_request_rejected_event)
        end,
        Sink ! stop
    after
        detach(HandlerId)
    end.

drain_recv_sink(Tag, Logger, Script) ->
    receive
        stop ->
            ok;
        {roadrunner_fake_recv, ConnPid, _Len, _Timeout} ->
            case Script of
                [] ->
                    ConnPid ! {roadrunner_fake_recv_reply, {error, closed}},
                    drain_recv_sink(Tag, Logger, []);
                [{recv, Bytes} | Rest] ->
                    ConnPid ! {roadrunner_fake_recv_reply, {ok, Bytes}},
                    drain_recv_sink(Tag, Logger, Rest)
            end;
        {roadrunner_fake_setopts, ConnPid, _Opts} ->
            %% Active-mode arming — deliver the next script item via
            %% `roadrunner_fake_data` (or close on empty script).
            case Script of
                [] ->
                    ConnPid ! {roadrunner_fake_closed, self()},
                    drain_recv_sink(Tag, Logger, []);
                [{recv, Bytes} | Rest] ->
                    ConnPid ! {roadrunner_fake_data, self(), Bytes},
                    drain_recv_sink(Tag, Logger, Rest)
            end;
        {roadrunner_fake_send, _, Data} ->
            Logger ! {sent, Tag, Data},
            drain_recv_sink(Tag, Logger, Script);
        _ ->
            drain_recv_sink(Tag, Logger, Script)
    end.

drain_acknowledged_event_fires_with_request_metadata_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    HandlerId = attach([[roadrunner, drain, acknowledged]]),
    try
        Req = #{
            listener_name => probe_listener,
            peer => {{127, 0, 0, 1}, 9999},
            request_id => ~"abcd0123abcd0123",
            method => ~"GET",
            target => ~"/sse",
            scheme => http,
            headers => []
        },
        ok = roadrunner:acknowledge_drain(Req),
        receive
            {telemetry_event, [roadrunner, drain, acknowledged], M, Md} ->
                ?assertMatch(#{system_time := _}, M),
                ?assertEqual(probe_listener, maps:get(listener_name, Md)),
                ?assertEqual({{127, 0, 0, 1}, 9999}, maps:get(peer, Md)),
                ?assertEqual(~"abcd0123abcd0123", maps:get(request_id, Md)),
                ?assertEqual(undefined, maps:get(deadline, Md))
        after 1000 -> error(no_drain_acknowledged_event)
        end
    after
        detach(HandlerId)
    end.

drain_acknowledged_with_deadline_threads_metadata_test() ->
    %% `acknowledge_drain/2` threads the `Deadline` from the
    %% `{roadrunner_drain, Deadline}` message into the event metadata so
    %% subscribers can compute remaining grace.
    {ok, _} = application:ensure_all_started(telemetry),
    HandlerId = attach([[roadrunner, drain, acknowledged]]),
    try
        Req = #{
            listener_name => probe_listener_d,
            peer => {{127, 0, 0, 1}, 9999},
            request_id => ~"deadline00000000",
            method => ~"GET",
            target => ~"/sse",
            scheme => http,
            headers => []
        },
        Deadline = erlang:monotonic_time(millisecond) + 5_000,
        ok = roadrunner:acknowledge_drain(Req, Deadline),
        receive
            {telemetry_event, [roadrunner, drain, acknowledged], _, Md} ->
                ?assertEqual(Deadline, maps:get(deadline, Md))
        after 1000 -> error(no_drain_acknowledged_event)
        end
    after
        detach(HandlerId)
    end.

listener_accept_and_conn_close_fire_around_a_keep_alive_conn_test_() ->
    {setup, fun setup_listener/0, fun cleanup_listener/1, fun({Name, Port}) ->
        {"accept fires on connect; conn_close fires once the conn exits", fun() ->
            HandlerId = attach([
                [roadrunner, listener, accept],
                [roadrunner, listener, conn_close]
            ]),
            try
                ok = send_simple_get(Port),
                Events = collect_events(2),
                {_, AcceptM, AcceptMd} = lists:keyfind(
                    [roadrunner, listener, accept], 1, Events
                ),
                {_, CloseM, CloseMd} = lists:keyfind(
                    [roadrunner, listener, conn_close], 1, Events
                ),
                ?assert(is_integer(maps:get(system_time, AcceptM))),
                ?assertEqual(Name, maps:get(listener_name, AcceptMd)),
                ?assertMatch({{127, 0, 0, 1}, _}, maps:get(peer, AcceptMd)),
                ?assert(is_integer(maps:get(duration, CloseM))),
                ?assert(maps:get(duration, CloseM) > 0),
                ?assertEqual(Name, maps:get(listener_name, CloseMd)),
                ?assertMatch({{127, 0, 0, 1}, _}, maps:get(peer, CloseMd)),
                ?assertEqual(1, maps:get(requests_served, CloseMd))
            after
                detach(HandlerId)
            end
        end}
    end}.

listener_conn_close_requests_served_does_not_count_parse_errors_test_() ->
    {setup, fun setup_listener/0, fun cleanup_listener/1, fun({_Name, Port}) ->
        {"a malformed first request keeps requests_served at 0", fun() ->
            HandlerId = attach([[roadrunner, listener, conn_close]]),
            try
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                %% Garbage that fails parse_request_line — conn replies
                %% 400 then closes; no real request was served.
                ok = gen_tcp:send(Sock, ~"NOT-A-VALID-REQUEST-LINE\r\n\r\n"),
                drain(Sock),
                ok = gen_tcp:close(Sock),
                receive
                    {telemetry_event, [roadrunner, listener, conn_close], _, Md} ->
                        ?assertEqual(0, maps:get(requests_served, Md))
                after 2000 -> error(no_conn_close_event)
                end
            after
                detach(HandlerId)
            end
        end}
    end}.

request_exception_fires_on_handler_crash_test_() ->
    {setup, fun setup_crashing_listener/0, fun cleanup_listener/1, fun({_Name, Port}) ->
        {"crashing handler emits exception with kind + reason", fun() ->
            HandlerId = attach([
                [roadrunner, request, start],
                [roadrunner, request, stop],
                [roadrunner, request, exception]
            ]),
            try
                _ = send_simple_get(Port),
                %% Exception path: start fires, then exception (no stop).
                Events = collect_events(2),
                Names = [Name || {Name, _, _} <- Events],
                ?assert(lists:member([roadrunner, request, start], Names)),
                ?assert(lists:member([roadrunner, request, exception], Names)),
                ?assertNot(lists:member([roadrunner, request, stop], Names)),
                {_, ExcM, ExcMd} = lists:keyfind(
                    [roadrunner, request, exception], 1, Events
                ),
                ?assert(is_integer(maps:get(duration, ExcM))),
                ?assertEqual(error, maps:get(kind, ExcMd)),
                ?assertEqual(boom, maps:get(reason, ExcMd))
            after
                detach(HandlerId)
            end
        end}
    end}.

ws_telemetry_fires_around_upgrade_and_each_frame_test_() ->
    {setup,
        fun() ->
            {ok, _} = application:ensure_all_started(telemetry),
            Name = telemetry_test_ws,
            {ok, _} = roadrunner_listener:start_link(Name, #{
                port => 0,
                routes => [{~"/ws", roadrunner_ws_upgrade_handler, undefined}]
            }),
            {Name, roadrunner_listener:port(Name)}
        end,
        fun({Name, _Port}) -> ok = roadrunner_listener:stop(Name) end, fun({_Name, Port}) ->
            {"upgrade + frame_in + frame_out events fire with the right metadata", fun() ->
                HandlerId = attach([
                    [roadrunner, ws, upgrade],
                    [roadrunner, ws, frame_in],
                    [roadrunner, ws, frame_out]
                ]),
                try
                    Sock = ws_handshake(Port),
                    %% One masked text frame "Hi" — handler echoes it.
                    send_masked_text(Sock, ~"Hi"),
                    {ok, Echo} = gen_tcp:recv(Sock, 4, 1000),
                    ?assertEqual(<<16#81, 16#02, "Hi">>, Echo),
                    ok = gen_tcp:close(Sock),
                    Events = collect_events(3),
                    {_, _, UpgradeMd} = lists:keyfind(
                        [roadrunner, ws, upgrade], 1, Events
                    ),
                    ?assertEqual(
                        roadrunner_ws_echo_handler, maps:get(module, UpgradeMd)
                    ),
                    ?assertMatch(<<_:16/binary>>, maps:get(request_id, UpgradeMd)),
                    ?assertMatch({{127, 0, 0, 1}, _}, maps:get(peer, UpgradeMd)),
                    {_, InM, InMd} = lists:keyfind(
                        [roadrunner, ws, frame_in], 1, Events
                    ),
                    ?assertEqual(text, maps:get(opcode, InMd)),
                    ?assertEqual(2, maps:get(payload_size, InM)),
                    {_, OutM, OutMd} = lists:keyfind(
                        [roadrunner, ws, frame_out], 1, Events
                    ),
                    ?assertEqual(text, maps:get(opcode, OutMd)),
                    ?assertEqual(2, maps:get(payload_size, OutM))
                after
                    detach(HandlerId)
                end
            end}
        end}.

ws_handshake(Port) ->
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
    ),
    Req = iolist_to_binary([
        ~"GET /ws HTTP/1.1\r\n",
        ~"Host: x\r\n",
        ~"Upgrade: websocket\r\n",
        ~"Connection: Upgrade\r\n",
        ~"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n",
        ~"Sec-WebSocket-Version: 13\r\n",
        ~"\r\n"
    ]),
    ok = gen_tcp:send(Sock, Req),
    %% Drain the 101 handshake response so subsequent recv only sees frames.
    recv_until_blank_line(Sock, <<>>),
    Sock.

recv_until_blank_line(Sock, Acc) ->
    case binary:match(Acc, ~"\r\n\r\n") of
        nomatch ->
            {ok, More} = gen_tcp:recv(Sock, 0, 1000),
            recv_until_blank_line(Sock, <<Acc/binary, More/binary>>);
        _ ->
            ok
    end.

send_masked_text(Sock, Payload) ->
    Mask = <<1, 2, 3, 4>>,
    Masked = mask(Payload, Mask, <<>>, 0),
    Len = byte_size(Payload),
    %% FIN=1, opcode=text(1), MASK=1, payload-len = Len.
    ok = gen_tcp:send(Sock, <<16#81, (16#80 bor Len), Mask/binary, Masked/binary>>).

mask(<<>>, _Mask, Acc, _I) ->
    Acc;
mask(<<B, Rest/binary>>, Mask, Acc, I) ->
    M = binary:at(Mask, I rem 4),
    mask(Rest, Mask, <<Acc/binary, (B bxor M)>>, I + 1).

%% --- helpers ---

setup_listener() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Name = telemetry_test_listener,
    {ok, _} = roadrunner_listener:start_link(Name, #{
        port => 0, handler => roadrunner_hello_handler
    }),
    {Name, roadrunner_listener:port(Name)}.

setup_crashing_listener() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Name = telemetry_test_crashing,
    {ok, _} = roadrunner_listener:start_link(Name, #{
        port => 0, handler => roadrunner_crashing_handler
    }),
    {Name, roadrunner_listener:port(Name)}.

cleanup_listener({Name, _Port}) ->
    ok = roadrunner_listener:stop(Name).

%% Attach a single handler to a list of event paths. The handler forwards
%% `{Event, Measurements, Metadata}` tuples to the calling process.
attach(Events) ->
    Self = self(),
    HandlerId = make_ref(),
    ok = telemetry:attach_many(
        HandlerId,
        Events,
        fun(Event, Measurements, Metadata, _Config) ->
            Self ! {telemetry_event, Event, Measurements, Metadata}
        end,
        undefined
    ),
    HandlerId.

detach(HandlerId) ->
    ok = telemetry:detach(HandlerId).

collect_events(N) -> collect_events(N, []).
collect_events(0, Acc) ->
    lists:reverse(Acc);
collect_events(N, Acc) ->
    receive
        {telemetry_event, Ev, M, Md} ->
            collect_events(N - 1, [{Ev, M, Md} | Acc])
    after 2000 ->
        error({telemetry_timeout, missing, N, got, Acc})
    end.

sort_by_event(Events) ->
    Order = fun
        ([roadrunner, request, start]) -> 1;
        ([roadrunner, request, stop]) -> 2;
        ([roadrunner, request, exception]) -> 3
    end,
    lists:sort(fun({A, _, _}, {B, _, _}) -> Order(A) =< Order(B) end, Events).

send_simple_get(Port) ->
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
    ok = gen_tcp:send(Sock, ~"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"),
    drain(Sock),
    ok = gen_tcp:close(Sock),
    ok.

drain(Sock) ->
    case gen_tcp:recv(Sock, 0, 1000) of
        {ok, _} -> drain(Sock);
        {error, _} -> ok
    end.
