-module(cactus_statem_props).
-moduledoc """
PropEr properties for `cactus_conn_statem`.

The headline invariant: **for any combination of recv-script
responses, drain timing, and stray info events, the gen_statem must
terminate cleanly with `normal` reason and release its `client_counter`
slot.** This is a robustness property — random inputs cannot crash
the conn or leak the slot, regardless of how malformed the byte
stream is.

A second property covers **telemetry-pairing**: when a full request
makes it to dispatch (i.e. the conn actually serves a 200), the
`[cactus, request, start]` and `[cactus, request, stop]` events
share the same `request_id`.
""".

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct_property_test.hrl").

%% =============================================================================
%% Robustness — random recv responses and drain timings always terminate
%% cleanly. No crashes, no slot leaks.
%% =============================================================================

prop_conn_terminates_normal_on_random_inputs() ->
    ?FORALL(
        {Script, DrainBefore, DrainAfter, Stray},
        {
            list(recv_step()),
            boolean(),
            boolean(),
            list(stray_msg())
        },
        begin
            {ok, _} = application:ensure_all_started(telemetry),
            ensure_pg(),
            Counter = atomics:new(1, [{signed, false}]),
            Opts = proto_opts(prop_listener, Counter),
            %% Mirror the acceptor's slot acquisition so terminate's
            %% release brings the counter back to 0 (not below).
            true = cactus_conn:try_acquire_slot(Opts),
            Sink = spawn_recv_sink(Script),
            {ok, Pid} = cactus_conn_statem:start({fake, Sink}, Opts),
            Ref = monitor(process, Pid),
            case DrainBefore of
                true ->
                    Pid ! {cactus_drain, erlang:monotonic_time(millisecond) + 1000};
                false ->
                    ok
            end,
            Pid ! shoot,
            case DrainAfter of
                true ->
                    Pid ! {cactus_drain, erlang:monotonic_time(millisecond) + 1000};
                false ->
                    ok
            end,
            lists:foreach(fun(Msg) -> Pid ! Msg end, Stray),
            ExitOk =
                receive
                    {'DOWN', Ref, process, Pid, normal} -> true;
                    {'DOWN', Ref, process, Pid, _Other} -> false
                after 3000 ->
                    erlang:demonitor(Ref, [flush]),
                    exit(Pid, kill),
                    false
                end,
            Sink ! stop,
            %% terminate/3 calls release_slot, decrementing the counter
            %% from 1 (acquired above) back to 0. Anything else means
            %% the conn either crashed before terminate or something
            %% leaked the slot.
            CounterOk = atomics:get(Counter, 1) =:= 0,
            ExitOk andalso CounterOk
        end
    ).

%% =============================================================================
%% Telemetry pairing — when a full request reaches dispatch, the
%% request_start and request_stop events share the same request_id.
%% Restricted to the deterministic happy path because telemetry is a
%% global side-effect channel; mixing concurrent property iterations
%% with a real listener would cross-talk.
%% =============================================================================

prop_request_start_and_stop_share_request_id() ->
    ?FORALL(
        Method,
        method(),
        begin
            {ok, _} = application:ensure_all_started(telemetry),
            ensure_pg(),
            Self = self(),
            HandlerId = make_ref(),
            ok = telemetry:attach_many(
                HandlerId,
                [[cactus, request, start], [cactus, request, stop]],
                fun(Event, _M, Md, _) -> Self ! {ev, Event, Md} end,
                undefined
            ),
            try
                Counter = atomics:new(1, [{signed, false}]),
                Sink = spawn_recv_sink([
                    {recv,
                        <<Method/binary, " / HTTP/1.1\r\nHost: x\r\n",
                            "Connection: close\r\n\r\n">>}
                ]),
                Opts = proto_opts(prop_listener_tel, Counter),
                {ok, Pid} = cactus_conn_statem:start({fake, Sink}, Opts),
                Ref = monitor(process, Pid),
                Pid ! shoot,
                receive
                    {'DOWN', Ref, process, Pid, normal} -> ok
                after 2000 -> error(no_normal_exit)
                end,
                Sink ! stop,
                StartId = await_event([cactus, request, start]),
                StopId = await_event([cactus, request, stop]),
                StartId =/= undefined andalso StartId =:= StopId
            after
                telemetry:detach(HandlerId),
                drain_mailbox()
            end
        end
    ).

%% =============================================================================
%% Generators
%% =============================================================================

recv_step() ->
    oneof([
        {recv, request_like_binary()},
        {recv, {error, oneof([closed, timeout, slow_client])}}
    ]).

%% Bytes that occasionally LOOK like a request line but are mostly
%% random — drives the parser through both happy and error paths.
request_like_binary() ->
    oneof([
        binary(),
        ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n",
        ~"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n",
        ~"NOT-VALID\r\n\r\n",
        <<>>
    ]).

stray_msg() ->
    oneof([
        random_atom,
        {arbitrary_tuple, 1},
        {{nested, 2}, 3},
        [1, 2, 3]
    ]).

method() ->
    oneof([~"GET", ~"POST", ~"PUT", ~"DELETE", ~"HEAD", ~"OPTIONS"]).

%% =============================================================================
%% Helpers (mirror cactus_conn_statem_tests scaffold)
%% =============================================================================

ensure_pg() ->
    case whereis(pg) of
        undefined ->
            {ok, _} = pg:start_link(),
            ok;
        _ ->
            ok
    end.

proto_opts(ListenerName, Counter) ->
    #{
        dispatch => {handler, cactus_hello_handler},
        middlewares => [],
        max_content_length => 1_000_000,
        request_timeout => 200,
        keep_alive_timeout => 200,
        max_keep_alive_request => 100,
        max_clients => 1000,
        client_counter => Counter,
        requests_counter => atomics:new(1, [{signed, false}]),
        minimum_bytes_per_second => 0,
        body_buffering => auto,
        listener_name => ListenerName
    }.

spawn_recv_sink(Script) ->
    spawn(fun() -> recv_sink_loop(Script) end).

recv_sink_loop(Script) ->
    receive
        stop ->
            ok;
        {cactus_fake_recv, ConnPid, _Len, _Timeout} ->
            case Script of
                [] ->
                    ConnPid ! {cactus_fake_recv_reply, {error, closed}},
                    recv_sink_loop([]);
                [{recv, {error, _} = Err} | Rest] ->
                    ConnPid ! {cactus_fake_recv_reply, Err},
                    recv_sink_loop(Rest);
                [{recv, Bytes} | Rest] ->
                    ConnPid ! {cactus_fake_recv_reply, {ok, Bytes}},
                    recv_sink_loop(Rest)
            end;
        _ ->
            recv_sink_loop(Script)
    end.

await_event(Path) ->
    receive
        {ev, Path, Md} -> maps:get(request_id, Md, undefined)
    after 1000 -> undefined
    end.

drain_mailbox() ->
    receive
        _ -> drain_mailbox()
    after 0 -> ok
    end.
