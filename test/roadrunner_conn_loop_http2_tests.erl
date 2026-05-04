-module(roadrunner_conn_loop_http2_tests).
-include_lib("eunit/include/eunit.hrl").

%% RFC 9113 §3.4 connection preface — must be the first 24 bytes
%% the client sends after TLS established + ALPN h2.
-define(PREFACE, ~"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n").

%% A non-ACK SETTINGS frame with empty body — the simplest valid
%% client preamble after the connection preface.
-define(EMPTY_SETTINGS_FRAME, <<0:24, 4, 0, 0:32>>).

%% =============================================================================
%% Phase H2 — `enter/5` performs the connection-level handshake:
%%   1. Send our initial SETTINGS frame.
%%   2. Read the 24-byte client preface.
%%   3. Read the client's initial SETTINGS frame.
%%   4. ACK the client SETTINGS, then GOAWAY(NO_ERROR).
%% Streams are not yet accepted (Phase H5+).
%% =============================================================================

happy_path_handshake_acks_settings_and_goaways_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    %% Step 1: server sent its SETTINGS frame.
    OurSettings = expect_send(),
    ?assertMatch(<<_:24, 4, 0, 0:32, _/binary>>, OurSettings),
    %% Step 2: server reads the client preface.
    serve_recv(ConnPid, ?PREFACE),
    %% Step 3: server reads the client's SETTINGS frame header (9 bytes)
    %% and any payload bytes (here zero — empty SETTINGS).
    serve_recv(ConnPid, ?EMPTY_SETTINGS_FRAME),
    %% Step 4: server emits ACK + GOAWAY in one send.
    AckPlusGoaway = expect_send(),
    %% ACK SETTINGS: type=4, flags=ACK (0x01), len=0, stream id=0.
    ?assertMatch(
        <<0:24, 4, 1, 0:32, _/binary>>, AckPlusGoaway
    ),
    %% GOAWAY follows: type=7, len=8, payload last_stream_id=0 +
    %% error_code=NO_ERROR.
    ?assertMatch(
        <<_:9/binary, 0, 0, 8, 7, 0, 0, 0, 0, 0, 0:32, 0:32>>,
        AckPlusGoaway
    ),
    %% Server closes the socket.
    expect_close(),
    %% Process exits normal.
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 500 -> error(process_did_not_exit)
    end.

bad_preface_exits_without_goaway_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    OurSettings = expect_send(),
    ?assertMatch(<<_:24, 4, 0, 0:32, _/binary>>, OurSettings),
    %% Send EXACTLY 24 bytes that are NOT the h2 preface. The server
    %% reads 24 (the preface length), sees the wrong bytes, and bails.
    %% Anything longer would leave the test driver's serve_recv_loop
    %% waiting to deliver remaining bytes that the server never asks
    %% for.
    serve_recv(ConnPid, ~"GET / HTTP/1.1\r\nA: B\r\n\r\n"),
    %% No GOAWAY — peer didn't establish the h2 conversation.
    %% Just close.
    expect_close(),
    %% No further sends. Drain a window to be sure.
    ?assertEqual(undefined, drain_send(50)),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 500 -> error(process_did_not_exit)
    end.

non_settings_first_frame_triggers_goaway_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    _ = expect_send(),
    serve_recv(ConnPid, ?PREFACE),
    %% After the preface the client sends a HEADERS frame instead
    %% of SETTINGS — RFC 9113 §3.4 violation. Server GOAWAYs and
    %% closes. Frame: type=1 (HEADERS), len=0 (just to trigger the
    %% wrong-type branch — the body length is irrelevant).
    serve_recv(ConnPid, <<0:24, 1, 0, 0:32>>),
    Goaway = expect_send(),
    ?assertMatch(<<0, 0, 8, 7, 0, 0, 0, 0, 0, 0:32, 0:32>>, Goaway),
    expect_close(),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 500 -> error(process_did_not_exit)
    end.

settings_with_ack_and_body_triggers_goaway_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    _ = expect_send(),
    serve_recv(ConnPid, ?PREFACE),
    %% SETTINGS frame with ACK flag set AND non-empty body — invalid
    %% per RFC 9113 §6.5. Triggers the catch-all flags branch and
    %% GOAWAY.
    serve_recv(ConnPid, <<6:24, 4, 1, 0:32>>),
    Goaway = expect_send(),
    ?assertMatch(<<0, 0, 8, 7, 0, 0, 0, 0, 0, 0:32, 0:32>>, Goaway),
    expect_close(),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 500 -> error(process_did_not_exit)
    end.

initial_send_error_exits_without_handshake_test() ->
    %% Server's first action is sending its initial SETTINGS. If the
    %% socket is already closed, `roadrunner_transport:send/2` returns
    %% `{error, _}` and the handshake bails through `exit_clean`.
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    Counter = atomics:new(1, [{signed, false}]),
    ok = atomics:add(Counter, 1, 1),
    ProtoOpts = #{client_counter => Counter, listener_name => http2_test},
    {ok, LSock} = gen_tcp:listen(0, [binary, {active, false}]),
    {ok, Port} = inet:port(LSock),
    {ok, Client} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}]),
    {ok, Server} = gen_tcp:accept(LSock),
    %% Shutdown the write side of the server socket so the very first
    %% send fails synchronously.
    ok = gen_tcp:shutdown(Server, read_write),
    ok = gen_tcp:close(Client),
    timer:sleep(20),
    Pid = spawn(fun() ->
        roadrunner_conn_loop_http2:enter(
            {gen_tcp, Server}, ProtoOpts, http2_test, undefined, erlang:monotonic_time()
        )
    end),
    Ref = monitor(process, Pid),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 1000 -> error(process_did_not_exit)
    end,
    ?assertEqual(0, atomics:get(Counter, 1)),
    ok = gen_tcp:close(LSock).

settings_payload_recv_error_exits_clean_test() ->
    %% Frame header announces Length>0, but the recv for the payload
    %% returns an error — server bails through exit_clean (no GOAWAY).
    {ok, _} = application:ensure_all_started(telemetry),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    _ = expect_send(),
    serve_recv(ConnPid, ?PREFACE),
    %% Frame header: Length=6, type=4 (SETTINGS), flags=0, stream id=0.
    serve_recv(ConnPid, <<6:24, 4, 0, 0:32>>),
    %% Server now asks for 6 bytes of payload — reply with an error.
    receive
        {roadrunner_fake_recv, ConnPid, _Len, _Timeout} ->
            ConnPid ! {roadrunner_fake_recv_reply, {error, closed}}
    after 500 -> error(no_recv_request)
    end,
    expect_close(),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 500 -> error(process_did_not_exit)
    end.

frame_header_short_read_exits_clean_test() ->
    %% Server reads the 9-byte frame header. Reply with too few bytes
    %% so the binary-pattern match fails — `read_frame_header/1`
    %% returns `error` and the server bails (sends GOAWAY since the
    %% conn-level handshake had progressed past the preface).
    {ok, _} = application:ensure_all_started(telemetry),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    _ = expect_send(),
    serve_recv(ConnPid, ?PREFACE),
    %% Reply with 5 bytes — too short for the 9-byte frame header,
    %% so the wrapper returns `error`.
    receive
        {roadrunner_fake_recv, ConnPid, _Len, _Timeout} ->
            ConnPid ! {roadrunner_fake_recv_reply, {ok, <<0, 0, 0, 0, 0>>}}
    after 500 -> error(no_recv_request)
    end,
    Goaway = expect_send(),
    ?assertMatch(<<0, 0, 8, 7, 0, 0, 0, 0, 0, 0:32, 0:32>>, Goaway),
    expect_close(),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 500 -> error(process_did_not_exit)
    end.

settings_with_payload_apply_path_test() ->
    %% Non-empty SETTINGS body — exercises the `Length > 0` branch
    %% that recv's the payload and runs `apply_payload/2`.
    {ok, _} = application:ensure_all_started(telemetry),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    _ = expect_send(),
    serve_recv(ConnPid, ?PREFACE),
    %% SETTINGS frame: length=12 (two parameter records), type=4,
    %% flags=0, stream id=0. Payload encodes
    %% header_table_size=8192 (id=1) and max_frame_size=32768 (id=5).
    Header = <<12:24, 4, 0, 0:32>>,
    Body = <<1:16, 8192:32, 5:16, 32768:32>>,
    serve_recv(ConnPid, [Header, Body]),
    AckPlusGoaway = expect_send(),
    ?assertMatch(<<0:24, 4, 1, 0:32, _/binary>>, AckPlusGoaway),
    expect_close(),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 500 -> error(process_did_not_exit)
    end.

%% --- helpers ---

start_http2_conn() ->
    %% Drain any leftover `roadrunner_fake_*` messages from a prior
    %% test that may have died mid-flow. Eunit runs tests
    %% sequentially in the same process; without this, a stale close
    %% message can corrupt downstream tests like
    %% `roadrunner_transport_tests:fake_close_forwards_to_owner_test`.
    drain_mailbox(),
    Self = self(),
    Counter = atomics:new(1, [{signed, false}]),
    ok = atomics:add(Counter, 1, 1),
    ProtoOpts = #{
        client_counter => Counter,
        listener_name => http2_test
    },
    Sock = {fake, Self},
    Pid = spawn(fun() ->
        %% Receive ConnPid handshake so the test driver can answer
        %% recv requests directed at us.
        receive
            ready -> ok
        end,
        roadrunner_conn_loop_http2:enter(
            Sock, ProtoOpts, http2_test, undefined, erlang:monotonic_time()
        )
    end),
    Ref = monitor(process, Pid),
    Pid ! ready,
    {Pid, Ref, Pid}.

expect_send() ->
    receive
        {roadrunner_fake_send, _Pid, Data} -> iolist_to_binary(Data)
    after 500 -> error(no_send)
    end.

drain_send(Timeout) ->
    receive
        {roadrunner_fake_send, _Pid, Data} -> iolist_to_binary(Data)
    after Timeout -> undefined
    end.

expect_close() ->
    receive
        {roadrunner_fake_close, _Pid} -> ok
    after 500 -> error(no_close)
    end.

drain_mailbox() ->
    receive
        {roadrunner_fake_send, _, _} -> drain_mailbox();
        {roadrunner_fake_close, _} -> drain_mailbox();
        {roadrunner_fake_recv, _, _, _} -> drain_mailbox();
        {'DOWN', _, _, _, _} -> drain_mailbox()
    after 0 -> ok
    end.

%% Reply to the conn's next `recv/3` request with the supplied bytes.
%% Splits across multiple recv calls if the conn asks for less than
%% we have buffered.
serve_recv(ConnPid, Data) ->
    serve_recv_loop(ConnPid, iolist_to_binary([Data])).

serve_recv_loop(_ConnPid, <<>>) ->
    ok;
serve_recv_loop(ConnPid, Buf) ->
    receive
        {roadrunner_fake_recv, ConnPid, Len, _Timeout} ->
            Take = min(Len, byte_size(Buf)),
            <<Chunk:Take/binary, Rest/binary>> = Buf,
            ConnPid ! {roadrunner_fake_recv_reply, {ok, Chunk}},
            serve_recv_loop(ConnPid, Rest)
    after 500 -> error(no_recv_request)
    end.
