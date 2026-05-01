-module(cactus_telemetry_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% [cactus, request, start | stop | exception] events fire around the
%% middleware/handler pipeline. Verified end-to-end through a real listener
%% so the conn's `handle_and_send` is actually exercised.
%% =============================================================================

request_start_and_stop_fire_with_metadata_test_() ->
    {setup, fun setup_listener/0, fun cleanup_listener/1, fun({Name, Port}) ->
        {"buffered handler emits start + stop with status + duration", fun() ->
            HandlerId = attach([
                [cactus, request, start],
                [cactus, request, stop]
            ]),
            try
                ok = send_simple_get(Port),
                Events = collect_events(2),
                [{Start, StartM, StartMd}, {Stop, StopM, StopMd}] = sort_by_event(Events),
                ?assertEqual([cactus, request, start], Start),
                ?assertEqual([cactus, request, stop], Stop),
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
    HandlerId = attach([[cactus, response, send_failed]]),
    try
        ok = logger:set_process_metadata(#{
            request_id => ~"deadbeefcafef00d",
            method => ~"GET",
            path => ~"/probe",
            peer => {{127, 0, 0, 1}, 4242}
        }),
        Result = cactus_telemetry:response_send({error, closed}, buffered_response),
        ?assertEqual({error, closed}, Result),
        receive
            {telemetry_event, [cactus, response, send_failed], M, Md} ->
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
    HandlerId = attach([[cactus, response, send_failed]]),
    try
        ?assertEqual(ok, cactus_telemetry:response_send(ok, buffered_response)),
        receive
            {telemetry_event, [cactus, response, send_failed], _, _} ->
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
    HandlerId = attach([[cactus, response, send_failed]]),
    try
        _ = cactus_telemetry:response_send({error, closed}, buffered_response),
        receive
            {telemetry_event, [cactus, response, send_failed], _, Md} ->
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

request_exception_fires_on_handler_crash_test_() ->
    {setup, fun setup_crashing_listener/0, fun cleanup_listener/1, fun({_Name, Port}) ->
        {"crashing handler emits exception with kind + reason", fun() ->
            HandlerId = attach([
                [cactus, request, start],
                [cactus, request, stop],
                [cactus, request, exception]
            ]),
            try
                _ = send_simple_get(Port),
                %% Exception path: start fires, then exception (no stop).
                Events = collect_events(2),
                Names = [Name || {Name, _, _} <- Events],
                ?assert(lists:member([cactus, request, start], Names)),
                ?assert(lists:member([cactus, request, exception], Names)),
                ?assertNot(lists:member([cactus, request, stop], Names)),
                {_, ExcM, ExcMd} = lists:keyfind(
                    [cactus, request, exception], 1, Events
                ),
                ?assert(is_integer(maps:get(duration, ExcM))),
                ?assertEqual(error, maps:get(kind, ExcMd)),
                ?assertEqual(boom, maps:get(reason, ExcMd))
            after
                detach(HandlerId)
            end
        end}
    end}.

%% --- helpers ---

setup_listener() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Name = telemetry_test_listener,
    {ok, _} = cactus_listener:start_link(Name, #{
        port => 0, handler => cactus_hello_handler
    }),
    {Name, cactus_listener:port(Name)}.

setup_crashing_listener() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Name = telemetry_test_crashing,
    {ok, _} = cactus_listener:start_link(Name, #{
        port => 0, handler => cactus_crashing_handler
    }),
    {Name, cactus_listener:port(Name)}.

cleanup_listener({Name, _Port}) ->
    ok = cactus_listener:stop(Name).

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
        ([cactus, request, start]) -> 1;
        ([cactus, request, stop]) -> 2;
        ([cactus, request, exception]) -> 3
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
