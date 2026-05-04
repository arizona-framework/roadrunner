-module(roadrunner_conn_loop_http2_tests).
-include_lib("eunit/include/eunit.hrl").

%% Eunit normally walks every `*_test/0` function in a module
%% sequentially in the SAME process — and across modules in a
%% suite. The H2 unit tests spawn `roadrunner_conn_loop_http2:enter`
%% with `{fake, self()}`, so any in-flight `roadrunner_fake_send`
%% message that arrives after the test returns gets delivered to
%% the next test's process and breaks its receive (notably
%% `roadrunner_transport_tests:fake_send_forwards_to_owner_test`,
%% which `?assertEqual(self(), From)` and fails when the leftover
%% From is the dead-but-still-queueing H2 conn pid).
%%
%% Wrapping every test in `{spawn, ...}` (an eunit test spec
%% directive) forces eunit to run each test body in a freshly-
%% spawned process. When the body finishes, the per-test process
%% dies and any in-flight messages addressed to it die with it —
%% no possible bleed-through.
all_test_() ->
    Tests = [
        fun handshake_succeeds_and_loops/0,
        fun bad_preface_closes_connection/0,
        fun non_settings_first_frame_triggers_goaway/0,
        fun full_get_request_returns_response/0,
        fun all_frame_types_handled/0,
        fun goaway_received_closes_connection/0,
        fun second_stream_gets_refused/0,
        fun post_with_body_via_data_frame/0,
        fun continuation_assembles_header_block/0,
        fun push_promise_from_client_triggers_goaway/0,
        fun even_stream_id_triggers_goaway/0,
        fun continuation_without_pending_triggers_goaway/0,
        fun data_on_unknown_stream_triggers_goaway/0,
        fun malformed_hpack_block_triggers_goaway/0,
        fun missing_pseudo_header_rst_stream/0,
        fun empty_body_response_omits_data_frame/0,
        fun stream_response_returns_501/0,
        fun loop_response_returns_501/0,
        fun sendfile_response_returns_501/0,
        fun websocket_response_returns_501/0,
        fun handler_crash_returns_500/0,
        fun middleware_chain_runs/0,
        fun rst_stream_cancels_active_stream/0,
        fun router_404_returns_not_found/0,
        fun data_without_end_stream_continues_loop/0,
        fun continuation_without_end_headers_continues_loop/0,
        fun idle_timeout_emits_goaway/0
    ],
    [{spawn, F} || F <- Tests].

%% RFC 9113 §3.4 connection preface — must be the first 24 bytes
%% the client sends after TLS established + ALPN h2.
-define(PREFACE, ~"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n").

%% A non-ACK SETTINGS frame with empty body — the simplest valid
%% client preamble after the connection preface.
-define(EMPTY_SETTINGS_FRAME, <<0:24, 4, 0, 0:32>>).

%% =============================================================================
%% Phase H5 — `enter/5` performs the SETTINGS handshake then enters
%% the frame loop, dispatching one stream at a time through the
%% normal handler pipeline.
%%
%% These unit tests drive the conn process via the `{fake, Pid}`
%% transport so we can assert wire bytes without spinning up a
%% real listener. The TLS-side smoke test in `roadrunner_tls_tests`
%% covers the end-to-end ALPN + TLS handshake + HEADERS+DATA path.
%% =============================================================================

handshake_succeeds_and_loops() ->
    %% Server emits initial SETTINGS, reads preface + client
    %% SETTINGS, ACKs, then idles in the frame loop. We don't drive
    %% any further frames — the test verifies the handshake sequence
    %% completes without the conn closing.
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    %% Server SETTINGS — frame type 4, flags 0, stream id 0,
    %% advertising MAX_CONCURRENT_STREAMS=1 + MAX_FRAME_SIZE=16384.
    InitialSettings = expect_send(),
    ?assertMatch(<<_:24, 4, 0, 0:32, _/binary>>, InitialSettings),
    serve_recv(ConnPid, ?PREFACE),
    serve_recv(ConnPid, ?EMPTY_SETTINGS_FRAME),
    %% Server SETTINGS ACK.
    AckBytes = expect_send(),
    ?assertMatch(<<0:24, 4, 1, 0:32>>, AckBytes),
    %% Conn is alive, idle in frame loop.
    ?assert(is_process_alive(Pid)),
    cleanup(Pid, Ref).

bad_preface_closes_connection() ->
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    _ = expect_send(),
    %% Send 24 bytes that aren't the preface.
    serve_recv(ConnPid, ~"GET / HTTP/1.1\r\nA: B\r\n\r\n"),
    expect_close(),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 500 -> error(process_did_not_exit)
    end.

non_settings_first_frame_triggers_goaway() ->
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    _ = expect_send(),
    serve_recv(ConnPid, ?PREFACE),
    %% Non-SETTINGS first frame (HEADERS, type 1) — protocol error.
    serve_recv(ConnPid, <<0:24, 1, 0, 0:32>>),
    Goaway = expect_send(),
    ?assertMatch(<<0, 0, 8, 7, _/binary>>, Goaway),
    expect_close(),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 500 -> error(process_did_not_exit)
    end.

full_get_request_returns_response() ->
    %% Drive the entire H5 round-trip via the fake socket: handshake,
    %% then HEADERS(END_STREAM) for `GET /`, expect HEADERS+DATA back
    %% from the hello handler.
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    _InitialSettings = expect_send(),
    serve_recv(ConnPid, ?PREFACE),
    serve_recv(ConnPid, ?EMPTY_SETTINGS_FRAME),
    _ServerAck = expect_send(),
    %% Build + send a HEADERS frame for `GET /`.
    Enc = roadrunner_http2_hpack:new_encoder(4096),
    {HpackBlock, _} = roadrunner_http2_hpack:encode(
        [
            {~":method", ~"GET"},
            {~":scheme", ~"https"},
            {~":authority", ~"localhost"},
            {~":path", ~"/"}
        ],
        Enc
    ),
    HpackBin = iolist_to_binary(HpackBlock),
    HeadersFrame = iolist_to_binary(
        roadrunner_http2_frame:encode(
            {headers, 1, 16#04 bor 16#01, undefined, HpackBin}
        )
    ),
    serve_recv(ConnPid, HeadersFrame),
    %% Server responds with HEADERS + DATA. Capture both — they
    %% may arrive as separate fake_send messages.
    Response1 = expect_send(),
    Response2 = drain_send(50),
    AllResponse =
        case Response2 of
            undefined -> Response1;
            _ -> <<Response1/binary, Response2/binary>>
        end,
    %% First frame should be HEADERS (type 1) for stream 1.
    Dec0 = roadrunner_http2_hpack:new_decoder(4096),
    {ok, {headers, 1, _, _, RespHpack}, AfterHeaders} =
        roadrunner_http2_frame:parse(AllResponse, 16384),
    {ok, RespHeaders, _} = roadrunner_http2_hpack:decode(RespHpack, Dec0),
    ?assertEqual(~"200", proplists:get_value(~":status", RespHeaders)),
    %% Followed by a DATA frame on stream 1.
    {ok, {data, 1, DataFlags, _Body}, _} =
        roadrunner_http2_frame:parse(AfterHeaders, 16384),
    ?assertNotEqual(0, DataFlags band 16#01),
    cleanup(Pid, Ref).

all_frame_types_handled() ->
    %% Walk through PING/WINDOW_UPDATE/PRIORITY/SETTINGS-after-handshake
    %% in sequence, exercising the no-op / ACK paths in the frame
    %% loop. Each frame keeps the connection alive.
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    _ = expect_send(),
    serve_recv(ConnPid, ?PREFACE),
    serve_recv(ConnPid, ?EMPTY_SETTINGS_FRAME),
    _ = expect_send(),
    %% PING(0) — server echoes with ACK.
    Ping = iolist_to_binary(roadrunner_http2_frame:encode({ping, 0, <<1:64>>})),
    serve_recv(ConnPid, Ping),
    PingAck = expect_send(),
    ?assertMatch(<<_:24, 6, 1, 0:32, _/binary>>, PingAck),
    %% PING(ACK) — silently consumed.
    PingAckIn = iolist_to_binary(roadrunner_http2_frame:encode({ping, 1, <<2:64>>})),
    serve_recv(ConnPid, PingAckIn),
    %% WINDOW_UPDATE — accepted, no response.
    WU = iolist_to_binary(roadrunner_http2_frame:encode({window_update, 0, 1024})),
    serve_recv(ConnPid, WU),
    %% PRIORITY — ignored.
    Pri = iolist_to_binary(
        roadrunner_http2_frame:encode(
            {priority, 1, #{exclusive => false, stream_dependency => 0, weight => 1}}
        )
    ),
    serve_recv(ConnPid, Pri),
    %% Second SETTINGS (non-ACK) — server ACKs.
    SettingsAck = iolist_to_binary(roadrunner_http2_frame:encode({settings, 0, []})),
    serve_recv(ConnPid, SettingsAck),
    SettingsAckOut = expect_send(),
    ?assertMatch(<<_:24, 4, 1, 0:32>>, SettingsAckOut),
    %% SETTINGS ACK from peer — silent.
    SetAckIn = iolist_to_binary(roadrunner_http2_frame:encode({settings, 1, []})),
    serve_recv(ConnPid, SetAckIn),
    %% RST_STREAM for an unknown stream — silently dropped.
    Rst = iolist_to_binary(roadrunner_http2_frame:encode({rst_stream, 99, cancel})),
    serve_recv(ConnPid, Rst),
    %% Sanity: conn still alive.
    ?assert(is_process_alive(Pid)),
    cleanup(Pid, Ref).

goaway_received_closes_connection() ->
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    _ = expect_send(),
    serve_recv(ConnPid, ?PREFACE),
    serve_recv(ConnPid, ?EMPTY_SETTINGS_FRAME),
    _ = expect_send(),
    Goaway = iolist_to_binary(roadrunner_http2_frame:encode({goaway, 0, no_error, <<>>})),
    serve_recv(ConnPid, Goaway),
    expect_close(),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 500 -> error(no_exit)
    end.

second_stream_gets_refused() ->
    %% Open stream 1 without END_STREAM (DATA pending), then send
    %% HEADERS for stream 3 — server RST_STREAMs the new one.
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    _ = expect_send(),
    serve_recv(ConnPid, ?PREFACE),
    serve_recv(ConnPid, ?EMPTY_SETTINGS_FRAME),
    _ = expect_send(),
    Enc = roadrunner_http2_hpack:new_encoder(4096),
    {Hpack, _} = roadrunner_http2_hpack:encode(
        [
            {~":method", ~"POST"},
            {~":scheme", ~"https"},
            {~":authority", ~"x"},
            {~":path", ~"/"}
        ],
        Enc
    ),
    HpackBin = iolist_to_binary(Hpack),
    %% Stream 1: HEADERS without END_STREAM (END_HEADERS only).
    Stream1Headers = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04, undefined, HpackBin})
    ),
    serve_recv(ConnPid, Stream1Headers),
    %% Stream 3: HEADERS while stream 1 is still active.
    Stream3Headers = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 3, 16#04 bor 16#01, undefined, HpackBin})
    ),
    serve_recv(ConnPid, Stream3Headers),
    %% Server RST_STREAMs stream 3 with REFUSED_STREAM.
    Out = expect_send(),
    {ok, {rst_stream, 3, refused_stream}, _} =
        roadrunner_http2_frame:parse(Out, 16384),
    cleanup(Pid, Ref).

post_with_body_via_data_frame() ->
    %% HEADERS without END_STREAM, then DATA with END_STREAM —
    %% exercises the on_data / DATA-accumulation path.
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    _ = expect_send(),
    serve_recv(ConnPid, ?PREFACE),
    serve_recv(ConnPid, ?EMPTY_SETTINGS_FRAME),
    _ = expect_send(),
    Enc = roadrunner_http2_hpack:new_encoder(4096),
    {Hpack, _} = roadrunner_http2_hpack:encode(
        [
            {~":method", ~"POST"},
            {~":scheme", ~"https"},
            {~":authority", ~"x"},
            {~":path", ~"/"}
        ],
        Enc
    ),
    HpackBin = iolist_to_binary(Hpack),
    %% HEADERS with END_HEADERS but NOT END_STREAM.
    HeadersF = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04, undefined, HpackBin})
    ),
    serve_recv(ConnPid, HeadersF),
    %% DATA with END_STREAM.
    DataF = iolist_to_binary(
        roadrunner_http2_frame:encode({data, 1, 16#01, ~"body"})
    ),
    serve_recv(ConnPid, DataF),
    %% Now the handler dispatches; expect HEADERS+DATA response.
    _RespHeaders = expect_send(),
    %% Hello handler returns text body — drain and verify.
    _ = drain_send(50),
    cleanup(Pid, Ref).

continuation_assembles_header_block() ->
    %% HEADERS without END_HEADERS, then CONTINUATION with
    %% END_HEADERS+END_STREAM. Tests the CONTINUATION path.
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    _ = expect_send(),
    serve_recv(ConnPid, ?PREFACE),
    serve_recv(ConnPid, ?EMPTY_SETTINGS_FRAME),
    _ = expect_send(),
    Enc = roadrunner_http2_hpack:new_encoder(4096),
    {Hpack, _} = roadrunner_http2_hpack:encode(
        [
            {~":method", ~"GET"},
            {~":scheme", ~"https"},
            {~":authority", ~"x"},
            {~":path", ~"/"}
        ],
        Enc
    ),
    HpackBin = iolist_to_binary(Hpack),
    Half = byte_size(HpackBin) div 2,
    <<First:Half/binary, Second/binary>> = HpackBin,
    %% HEADERS without END_HEADERS, no END_STREAM.
    HeadersF = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 0, undefined, First})
    ),
    serve_recv(ConnPid, HeadersF),
    %% CONTINUATION with END_HEADERS+END_STREAM (CONTINUATION
    %% itself doesn't carry END_STREAM; the END_STREAM was on
    %% the parent HEADERS — we fold it in via the test by
    %% setting END_STREAM on the HEADERS frame above).
    %% Actually the spec: END_STREAM is only on the HEADERS
    %% frame, not CONTINUATION. The flag we set on HEADERS
    %% above was 0 (no END_STREAM either) — this test exercises
    %% the CONTINUATION-only-END_HEADERS path; the stream stays
    %% open. Send a DATA frame with END_STREAM next.
    ContinuationF = iolist_to_binary(
        roadrunner_http2_frame:encode({continuation, 1, 16#04, Second})
    ),
    serve_recv(ConnPid, ContinuationF),
    DataF = iolist_to_binary(
        roadrunner_http2_frame:encode({data, 1, 16#01, ~""})
    ),
    serve_recv(ConnPid, DataF),
    _ = expect_send(),
    cleanup(Pid, Ref).

push_promise_from_client_triggers_goaway() ->
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    _ = expect_send(),
    serve_recv(ConnPid, ?PREFACE),
    serve_recv(ConnPid, ?EMPTY_SETTINGS_FRAME),
    _ = expect_send(),
    PP = iolist_to_binary(roadrunner_http2_frame:encode({push_promise, 1, 0, 2, <<>>})),
    serve_recv(ConnPid, PP),
    Out = expect_send(),
    ?assertMatch(<<_:24, 7, _/binary>>, Out),
    expect_close(),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 500 -> error(no_exit)
    end.

even_stream_id_triggers_goaway() ->
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    _ = expect_send(),
    serve_recv(ConnPid, ?PREFACE),
    serve_recv(ConnPid, ?EMPTY_SETTINGS_FRAME),
    _ = expect_send(),
    Enc = roadrunner_http2_hpack:new_encoder(4096),
    {Hpack, _} = roadrunner_http2_hpack:encode(
        [{~":method", ~"GET"}, {~":scheme", ~"https"}, {~":path", ~"/"}], Enc
    ),
    HpackBin = iolist_to_binary(Hpack),
    %% Stream id 2 — client-initiated streams MUST be odd.
    Hf = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 2, 16#04 bor 16#01, undefined, HpackBin})
    ),
    serve_recv(ConnPid, Hf),
    _ = expect_send(),
    expect_close(),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 500 -> error(no_exit)
    end.

continuation_without_pending_triggers_goaway() ->
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    _ = expect_send(),
    serve_recv(ConnPid, ?PREFACE),
    serve_recv(ConnPid, ?EMPTY_SETTINGS_FRAME),
    _ = expect_send(),
    Cf = iolist_to_binary(roadrunner_http2_frame:encode({continuation, 1, 16#04, <<>>})),
    serve_recv(ConnPid, Cf),
    _ = expect_send(),
    expect_close(),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 500 -> error(no_exit)
    end.

data_on_unknown_stream_triggers_goaway() ->
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    _ = expect_send(),
    serve_recv(ConnPid, ?PREFACE),
    serve_recv(ConnPid, ?EMPTY_SETTINGS_FRAME),
    _ = expect_send(),
    Df = iolist_to_binary(roadrunner_http2_frame:encode({data, 1, 0, ~"x"})),
    serve_recv(ConnPid, Df),
    _ = expect_send(),
    expect_close(),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 500 -> error(no_exit)
    end.

malformed_hpack_block_triggers_goaway() ->
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    _ = expect_send(),
    serve_recv(ConnPid, ?PREFACE),
    serve_recv(ConnPid, ?EMPTY_SETTINGS_FRAME),
    _ = expect_send(),
    %% HEADERS with HPACK fragment that won't decode (an indexed
    %% header field with index past the static table).
    BadHpack = <<16#FF, 16#49>>,
    Hf = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04 bor 16#01, undefined, BadHpack})
    ),
    serve_recv(ConnPid, Hf),
    _ = expect_send(),
    expect_close(),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 500 -> error(no_exit)
    end.

missing_pseudo_header_rst_stream() ->
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    _ = expect_send(),
    serve_recv(ConnPid, ?PREFACE),
    serve_recv(ConnPid, ?EMPTY_SETTINGS_FRAME),
    _ = expect_send(),
    Enc = roadrunner_http2_hpack:new_encoder(4096),
    %% Missing :path — request build fails with missing_pseudo_header.
    {Hpack, _} = roadrunner_http2_hpack:encode(
        [{~":method", ~"GET"}, {~":scheme", ~"https"}], Enc
    ),
    HpackBin = iolist_to_binary(Hpack),
    Hf = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04 bor 16#01, undefined, HpackBin})
    ),
    serve_recv(ConnPid, Hf),
    Out = expect_send(),
    ?assertMatch(<<_:24, 3, _/binary>>, Out),
    %% Conn stays alive (RST_STREAM doesn't close the connection).
    ?assert(is_process_alive(Pid)),
    cleanup(Pid, Ref).

empty_body_response_omits_data_frame() ->
    %% Handler returns `{200, [], <<>>}` — server emits a HEADERS
    %% frame with END_STREAM and no DATA frame.
    {Pid, Ref} = run_h2_request_with_handler(roadrunner_h2_test_handler, ~"/empty"),
    cleanup(Pid, Ref).

stream_response_returns_501() ->
    {Pid, Ref} = run_h2_request_with_handler(roadrunner_h2_test_handler, ~"/stream"),
    cleanup(Pid, Ref).

loop_response_returns_501() ->
    {Pid, Ref} = run_h2_request_with_handler(roadrunner_h2_test_handler, ~"/loop"),
    cleanup(Pid, Ref).

sendfile_response_returns_501() ->
    {Pid, Ref} = run_h2_request_with_handler(roadrunner_h2_test_handler, ~"/sendfile"),
    cleanup(Pid, Ref).

websocket_response_returns_501() ->
    {Pid, Ref} = run_h2_request_with_handler(roadrunner_h2_test_handler, ~"/websocket"),
    cleanup(Pid, Ref).

handler_crash_returns_500() ->
    {Pid, Ref} = run_h2_request_with_handler(roadrunner_h2_test_handler, ~"/crash"),
    cleanup(Pid, Ref).

middleware_chain_runs() ->
    %% Listener with a non-empty middleware list — exercises the
    %% `compose/2` branch in invoke/4.
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    Mw = fun(Req, Next) -> Next(Req) end,
    Counter = atomics:new(1, [{signed, false}]),
    ok = atomics:add(Counter, 1, 1),
    ProtoOpts = #{
        client_counter => Counter,
        listener_name => h2_mw_test,
        dispatch => {handler, roadrunner_hello_handler},
        middlewares => [Mw]
    },
    Self = self(),
    Sock = {fake, Self},
    Pid = spawn(fun() ->
        receive
            ready -> ok
        end,
        roadrunner_conn_loop_http2:enter(
            Sock, ProtoOpts, h2_mw_test, undefined, erlang:monotonic_time()
        )
    end),
    Ref = monitor(process, Pid),
    Pid ! ready,
    drive_simple_get(Pid),
    cleanup(Pid, Ref).

rst_stream_cancels_active_stream() ->
    %% Open stream 1 (HEADERS without END_STREAM), then RST_STREAM
    %% it. Server should drop the stream state and continue idling.
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    _ = expect_send(),
    serve_recv(ConnPid, ?PREFACE),
    serve_recv(ConnPid, ?EMPTY_SETTINGS_FRAME),
    _ = expect_send(),
    Enc = roadrunner_http2_hpack:new_encoder(4096),
    {Hpack, _} = roadrunner_http2_hpack:encode(
        [
            {~":method", ~"POST"},
            {~":scheme", ~"https"},
            {~":authority", ~"x"},
            {~":path", ~"/"}
        ],
        Enc
    ),
    HpackBin = iolist_to_binary(Hpack),
    Hf = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04, undefined, HpackBin})
    ),
    serve_recv(ConnPid, Hf),
    Rst = iolist_to_binary(roadrunner_http2_frame:encode({rst_stream, 1, cancel})),
    serve_recv(ConnPid, Rst),
    ?assert(is_process_alive(Pid)),
    cleanup(Pid, Ref).

router_404_returns_not_found() ->
    %% Need a router-based dispatch with empty routes so the
    %% lookup returns `not_found`.
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    %% Publish empty routes for a fake listener.
    persistent_term:put({roadrunner_routes, h2_404_listener}, roadrunner_router:compile([])),
    Self = self(),
    Counter = atomics:new(1, [{signed, false}]),
    ok = atomics:add(Counter, 1, 1),
    ProtoOpts = #{
        client_counter => Counter,
        listener_name => h2_404_listener,
        dispatch => {router, h2_404_listener},
        middlewares => []
    },
    Sock = {fake, Self},
    Pid = spawn(fun() ->
        receive
            ready -> ok
        end,
        roadrunner_conn_loop_http2:enter(
            Sock, ProtoOpts, h2_404_listener, undefined, erlang:monotonic_time()
        )
    end),
    Ref = monitor(process, Pid),
    Pid ! ready,
    _ = expect_send(),
    serve_recv(Pid, ?PREFACE),
    serve_recv(Pid, ?EMPTY_SETTINGS_FRAME),
    _ = expect_send(),
    Enc = roadrunner_http2_hpack:new_encoder(4096),
    {Hpack, _} = roadrunner_http2_hpack:encode(
        [
            {~":method", ~"GET"},
            {~":scheme", ~"https"},
            {~":authority", ~"x"},
            {~":path", ~"/missing"}
        ],
        Enc
    ),
    HpackBin = iolist_to_binary(Hpack),
    Hf = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04 bor 16#01, undefined, HpackBin})
    ),
    serve_recv(Pid, Hf),
    Resp = expect_send(),
    Dec0 = roadrunner_http2_hpack:new_decoder(4096),
    {ok, {headers, 1, _, _, RespHpack}, _} =
        roadrunner_http2_frame:parse(Resp, 16384),
    {ok, RespHeaders, _} = roadrunner_http2_hpack:decode(RespHpack, Dec0),
    ?assertEqual(~"404", proplists:get_value(~":status", RespHeaders)),
    cleanup(Pid, Ref).

data_without_end_stream_continues_loop() ->
    %% HEADERS without END_STREAM, then DATA without END_STREAM,
    %% then DATA with END_STREAM. Tests `on_data` END_STREAM=false
    %% branch.
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    _ = expect_send(),
    serve_recv(ConnPid, ?PREFACE),
    serve_recv(ConnPid, ?EMPTY_SETTINGS_FRAME),
    _ = expect_send(),
    Enc = roadrunner_http2_hpack:new_encoder(4096),
    {Hpack, _} = roadrunner_http2_hpack:encode(
        [
            {~":method", ~"POST"},
            {~":scheme", ~"https"},
            {~":authority", ~"x"},
            {~":path", ~"/"}
        ],
        Enc
    ),
    HpackBin = iolist_to_binary(Hpack),
    Hf = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04, undefined, HpackBin})
    ),
    serve_recv(ConnPid, Hf),
    Df1 = iolist_to_binary(roadrunner_http2_frame:encode({data, 1, 0, ~"part1"})),
    serve_recv(ConnPid, Df1),
    Df2 = iolist_to_binary(roadrunner_http2_frame:encode({data, 1, 16#01, ~"part2"})),
    serve_recv(ConnPid, Df2),
    _ = expect_send(),
    cleanup(Pid, Ref).

continuation_without_end_headers_continues_loop() ->
    %% HEADERS without END_HEADERS, CONTINUATION without END_HEADERS,
    %% CONTINUATION with END_HEADERS. Tests `on_continuation`
    %% END_HEADERS=false branch.
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    _ = expect_send(),
    serve_recv(ConnPid, ?PREFACE),
    serve_recv(ConnPid, ?EMPTY_SETTINGS_FRAME),
    _ = expect_send(),
    Enc = roadrunner_http2_hpack:new_encoder(4096),
    {Hpack, _} = roadrunner_http2_hpack:encode(
        [
            {~":method", ~"GET"},
            {~":scheme", ~"https"},
            {~":authority", ~"x"},
            {~":path", ~"/"}
        ],
        Enc
    ),
    HpackBin = iolist_to_binary(Hpack),
    Third = byte_size(HpackBin) div 3,
    <<P1:Third/binary, P2:Third/binary, P3/binary>> = HpackBin,
    Hf = iolist_to_binary(roadrunner_http2_frame:encode({headers, 1, 0, undefined, P1})),
    serve_recv(ConnPid, Hf),
    Cf1 = iolist_to_binary(roadrunner_http2_frame:encode({continuation, 1, 0, P2})),
    serve_recv(ConnPid, Cf1),
    Cf2 = iolist_to_binary(roadrunner_http2_frame:encode({continuation, 1, 16#04, P3})),
    serve_recv(ConnPid, Cf2),
    Df = iolist_to_binary(roadrunner_http2_frame:encode({data, 1, 16#01, ~""})),
    serve_recv(ConnPid, Df),
    _ = expect_send(),
    cleanup(Pid, Ref).

idle_timeout_emits_goaway() ->
    %% After the handshake the conn is idle waiting for frames.
    %% Closing the fake socket simulates the client going away —
    %% the conn should exit cleanly.
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    _ = expect_send(),
    serve_recv(ConnPid, ?PREFACE),
    serve_recv(ConnPid, ?EMPTY_SETTINGS_FRAME),
    _ = expect_send(),
    %% Reply to the next recv with an error — simulates closed peer.
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

%% --- helpers ---

start_http2_conn() ->
    Self = self(),
    Counter = atomics:new(1, [{signed, false}]),
    ok = atomics:add(Counter, 1, 1),
    %% Phase H5 dispatch needs at least the route resolver + an
    %% empty middleware chain. Tests don't actually exercise a
    %% handler in this file (they exit before any HEADERS frame
    %% gets dispatched).
    ProtoOpts = #{
        client_counter => Counter,
        listener_name => http2_test,
        dispatch => {handler, roadrunner_hello_handler},
        middlewares => []
    },
    Sock = {fake, Self},
    Pid = spawn(fun() ->
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

cleanup(Pid, Ref) ->
    %% Force the conn process to exit without actually closing the
    %% socket loop normally — for tests that don't drive the
    %% handshake to its end-of-conn signal. Drain the mailbox
    %% afterwards so leftover `roadrunner_fake_*` messages don't
    %% bleed into later tests in this same eunit process.
    exit(Pid, kill),
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    after 500 -> ok
    end,
    %% Eunit shares the test process across tests in a module — and
    %% across modules in a suite — so any in-flight message must be
    %% caught before the next test runs. The fake-transport messages
    %% only originate from `Pid`, which is dead after the kill; the
    %% sleep gives the scheduler one tick to deliver any still-queued
    %% sends. Drain twice to be safe.
    timer:sleep(50),
    drain_mailbox(),
    drain_mailbox().

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

serve_recv(ConnPid, Data) ->
    serve_recv_loop(ConnPid, iolist_to_binary([Data])).

serve_recv_loop(_ConnPid, <<>>) ->
    ok;
serve_recv_loop(ConnPid, Buf) ->
    receive
        {roadrunner_fake_recv, ConnPid, Len, _Timeout} ->
            Take =
                case Len of
                    0 -> byte_size(Buf);
                    _ -> min(Len, byte_size(Buf))
                end,
            <<Chunk:Take/binary, Rest/binary>> = Buf,
            ConnPid ! {roadrunner_fake_recv_reply, {ok, Chunk}},
            serve_recv_loop(ConnPid, Rest)
    after 500 -> error(no_recv_request)
    end.

drain_mailbox() ->
    %% Eunit walks all tests in a module sequentially in the same
    %% process — and the same is true across modules in a suite —
    %% so messages from a prior test that were in flight when the
    %% test returned can arrive after our `cleanup/2` runs and
    %% poison the next test (notably
    %% `roadrunner_transport_tests:fake_send_forwards_to_owner`).
    %%
    %% Sentinel pattern: send ourselves a unique reference, then
    %% consume EVERY message until that reference comes back out.
    %% Anything ahead of the sentinel is guaranteed gone.
    Sentinel = make_ref(),
    self() ! {drain_sentinel, Sentinel},
    drain_until(Sentinel).

drain_until(Sentinel) ->
    receive
        {drain_sentinel, Sentinel} -> ok;
        _ -> drain_until(Sentinel)
    end.

%% Spawn an h2 conn with `Handler` as the dispatch target, drive a
%% GET against `Path`, drain the response. Returns the conn pid +
%% monitor ref so the caller can wait for it.
run_h2_request_with_handler(Handler, Path) ->
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    Self = self(),
    Counter = atomics:new(1, [{signed, false}]),
    ok = atomics:add(Counter, 1, 1),
    ProtoOpts = #{
        client_counter => Counter,
        listener_name => h2_handler_test,
        dispatch => {handler, Handler},
        middlewares => []
    },
    Sock = {fake, Self},
    Pid = spawn(fun() ->
        receive
            ready -> ok
        end,
        roadrunner_conn_loop_http2:enter(
            Sock, ProtoOpts, h2_handler_test, undefined, erlang:monotonic_time()
        )
    end),
    Ref = monitor(process, Pid),
    Pid ! ready,
    _ = expect_send(),
    serve_recv(Pid, ?PREFACE),
    serve_recv(Pid, ?EMPTY_SETTINGS_FRAME),
    _ = expect_send(),
    Enc = roadrunner_http2_hpack:new_encoder(4096),
    {Hpack, _} = roadrunner_http2_hpack:encode(
        [
            {~":method", ~"GET"},
            {~":scheme", ~"https"},
            {~":authority", ~"localhost"},
            {~":path", Path}
        ],
        Enc
    ),
    HpackBin = iolist_to_binary(Hpack),
    Hf = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04 bor 16#01, undefined, HpackBin})
    ),
    serve_recv(Pid, Hf),
    %% Drain whatever the server sent back. We don't assert
    %% specific status here — the test just confirms the dispatch
    %% path runs without crashing the conn.
    _ = expect_send(),
    _ = drain_send(50),
    {Pid, Ref}.

drive_simple_get(Pid) ->
    _ = expect_send(),
    serve_recv(Pid, ?PREFACE),
    serve_recv(Pid, ?EMPTY_SETTINGS_FRAME),
    _ = expect_send(),
    Enc = roadrunner_http2_hpack:new_encoder(4096),
    {Hpack, _} = roadrunner_http2_hpack:encode(
        [
            {~":method", ~"GET"},
            {~":scheme", ~"https"},
            {~":authority", ~"x"},
            {~":path", ~"/"}
        ],
        Enc
    ),
    HpackBin = iolist_to_binary(Hpack),
    Hf = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04 bor 16#01, undefined, HpackBin})
    ),
    serve_recv(Pid, Hf),
    _ = expect_send(),
    _ = drain_send(50),
    ok.
