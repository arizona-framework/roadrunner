-module(roadrunner_h2_overload_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% HTTP/2 admission under `overload_mode`.
%%
%% Drives a real h2c listener with the in-tree codec. The ceiling is 1, so
%% the second stream always has to wait: with `refuse` it is rejected the
%% way it is today, and with a queue it is served once the first handler
%% lets go of its slot.
%%
%% The loop must NOT block while waiting. It releases slots by processing
%% its own workers' `DOWN` messages, so a blocked loop would wait on
%% something only it can deliver — the whole reason admission is
%% asynchronous.
%% =============================================================================

queue_mode_serves_a_parked_stream_test_() ->
    {timeout, 30,
        {spawn, fun() ->
            {Name, Port} = start_listener(
                queue_serves, {queue, #{max_queued => 4, timeout => 5000}}
            ),
            try
                Sock = h2_connect(Port),
                ok = send_request(Sock, 1),
                First = expect_handler(),
                %% Stream 1 holds the only slot, so stream 3 parks rather
                %% than being refused.
                ok = send_request(Sock, 3),
                ?assertEqual(no_handler, expect_no_handler()),
                First ! release,
                Second = expect_handler(),
                Second ! release,
                {Ok, Refused} = collect(Sock, 2, 0, 0),
                ?assertEqual(2, Ok),
                ?assertEqual(0, Refused),
                ok = gen_tcp:close(Sock)
            after
                ok = roadrunner_listener:stop(Name)
            end
        end}}.

queue_mode_refuses_after_the_deadline_test_() ->
    {timeout, 30,
        {spawn, fun() ->
            {Name, Port} = start_listener(
                queue_expires, {queue, #{max_queued => 4, timeout => 50}}
            ),
            try
                Sock = h2_connect(Port),
                ok = send_request(Sock, 1),
                First = expect_handler(),
                ok = send_request(Sock, 3),
                %% Nothing frees a slot in time, so the parked stream falls
                %% back to exactly today's refusal.
                {Ok, Refused} = collect(Sock, 1, 0, 0),
                ?assertEqual(0, Ok),
                ?assertEqual(1, Refused),
                First ! release,
                ok = gen_tcp:close(Sock)
            after
                ok = roadrunner_listener:stop(Name)
            end
        end}}.

refuse_mode_is_unchanged_test_() ->
    {timeout, 30,
        {spawn, fun() ->
            {Name, Port} = start_listener(refuse_default, refuse),
            try
                Sock = h2_connect(Port),
                ok = send_request(Sock, 1),
                First = expect_handler(),
                ok = send_request(Sock, 3),
                {Ok, Refused} = collect(Sock, 1, 0, 0),
                ?assertEqual(0, Ok),
                ?assertEqual(1, Refused),
                First ! release,
                ok = gen_tcp:close(Sock)
            after
                ok = roadrunner_listener:stop(Name)
            end
        end}}.

%% A client RST while a stream is parked has to withdraw it from the
%% queue, or the entry outlives its stream.
queue_mode_reset_withdraws_a_parked_stream_test_() ->
    {timeout, 30,
        {spawn, fun() ->
            {Name, Port} = start_listener(
                queue_reset, {queue, #{max_queued => 4, timeout => 5000}}
            ),
            try
                Sock = h2_connect(Port),
                ok = send_request(Sock, 1),
                First = expect_handler(),
                ok = send_request(Sock, 3),
                ?assertEqual(no_handler, expect_no_handler()),
                %% Withdraw the parked stream, then free the slot it was
                %% waiting for. It must not be dispatched afterwards.
                ok = gen_tcp:send(
                    Sock, roadrunner_http2_frame:encode({rst_stream, 3, cancel})
                ),
                %% Frames are processed in order, so a PING ack proves the
                %% RST has been handled. Without the barrier the connection
                %% can see the first worker's DOWN, free the slot and
                %% dispatch the parked stream before it ever reads the RST.
                ok = await_ping_ack(Sock),
                First ! release,
                ?assertEqual(no_handler, expect_no_handler()),
                ?assertMatch({1, _}, collect(Sock, 1, 0, 0)),
                ok = gen_tcp:close(Sock)
            after
                ok = roadrunner_listener:stop(Name)
            end
        end}}.

%% A grant that arrives for a stream the loop no longer has is the one
%% leak the design must handle: the queue took that slot on our behalf,
%% so it has to be given back rather than dropped. Injected directly
%% because the window it happens in is a race by nature.
queue_mode_hands_back_a_stale_grant_test_() ->
    {timeout, 30,
        {spawn, fun() ->
            {Name, Port} = start_listener(
                queue_stale, {queue, #{max_queued => 4, timeout => 5000}}
            ),
            try
                Sock = h2_connect(Port),
                ok = send_request(Sock, 1),
                First = expect_handler(),
                Conn = conn_pid(Name),
                Conn ! {roadrunner_slot, 99, granted},
                Conn ! {roadrunner_slot, 99, timeout},
                First ! release,
                %% The connection carries on serving as if nothing happened.
                ?assertMatch({1, _}, collect(Sock, 1, 0, 0)),
                ?assert(is_process_alive(Conn)),
                ok = gen_tcp:close(Sock)
            after
                ok = roadrunner_listener:stop(Name)
            end
        end}}.

await_ping_ack(Sock) ->
    ok = gen_tcp:send(
        Sock, roadrunner_http2_frame:encode({ping, 0, <<1, 2, 3, 4, 5, 6, 7, 8>>})
    ),
    await_ping_ack(Sock, <<>>).

await_ping_ack(Sock, Buf) ->
    case roadrunner_http2_frame:parse(Buf, 16384) of
        {ok, {ping, 1, _}, _Rest} ->
            ok;
        {ok, _, Rest} ->
            await_ping_ack(Sock, Rest);
        {more, _} ->
            {ok, More} = gen_tcp:recv(Sock, 0, 5000),
            await_ping_ack(Sock, <<Buf/binary, More/binary>>)
    end.

conn_pid(Name) ->
    [Pid] = pg:get_members({roadrunner_drain, Name}),
    Pid.

%% --- harness ---

start_listener(Name, OverloadMode) ->
    _ = ensure_pg(),
    %% Each test runs in its own process, so the previous one's
    %% registration may still be settling. Take the name rather than
    %% racing for it.
    _ =
        case whereis(roadrunner_h2_slot_collector) of
            undefined -> ok;
            _ -> unregister(roadrunner_h2_slot_collector)
        end,
    true = register(roadrunner_h2_slot_collector, self()),
    {ok, _} = roadrunner_listener:start_link(Name, #{
        port => 0,
        routes => roadrunner_h2_slot_handler,
        protocols => [http2],
        max_concurrent_requests => 1,
        overload_mode => OverloadMode
    }),
    {Name, roadrunner_listener:port(Name)}.

ensure_pg() ->
    case whereis(pg) of
        undefined -> pg:start_link();
        Pid -> {ok, Pid}
    end.

expect_handler() ->
    receive
        {handler_started, Pid} -> Pid
    after 5000 -> error(handler_never_started)
    end.

expect_no_handler() ->
    receive
        {handler_started, _} -> handler_started_unexpectedly
    after 300 -> no_handler
    end.

h2_connect(Port) ->
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, Port, [binary, {active, false}, {nodelay, true}], 5000
    ),
    ok = gen_tcp:send(Sock, [~"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", <<0:24, 4, 0, 0:32>>]),
    Sock.

send_request(Sock, StreamId) ->
    Enc = roadrunner_http2_hpack:new_encoder(4096),
    {Block, _} = roadrunner_http2_hpack:encode(
        [
            {~":method", ~"GET"},
            {~":scheme", ~"http"},
            {~":authority", ~"localhost"},
            {~":path", ~"/"}
        ],
        Enc
    ),
    gen_tcp:send(
        Sock,
        roadrunner_http2_frame:encode(
            {headers, StreamId, 16#04 bor 16#01, undefined, iolist_to_binary(Block)}
        )
    ).

%% Read until `Want` streams have ended, counting completions against
%% RST_STREAM refusals.
collect(Sock, Want, Ok, Refused) ->
    collect(Sock, Want, Ok, Refused, <<>>).

collect(_Sock, Want, Ok, Refused, _Buf) when Ok + Refused >= Want ->
    {Ok, Refused};
collect(Sock, Want, Ok, Refused, Buf) ->
    case roadrunner_http2_frame:parse(Buf, 16384) of
        {ok, {rst_stream, _, _}, Rest} ->
            collect(Sock, Want, Ok, Refused + 1, Rest);
        {ok, {data, _, Flags, _, _}, Rest} when (Flags band 16#01) =/= 0 ->
            collect(Sock, Want, Ok + 1, Refused, Rest);
        {ok, {headers, _, Flags, _, _}, Rest} when (Flags band 16#01) =/= 0 ->
            collect(Sock, Want, Ok + 1, Refused, Rest);
        {ok, _, Rest} ->
            collect(Sock, Want, Ok, Refused, Rest);
        {more, _} ->
            case gen_tcp:recv(Sock, 0, 10000) of
                {ok, More} -> collect(Sock, Want, Ok, Refused, <<Buf/binary, More/binary>>);
                _ -> {Ok, Refused}
            end
    end.
