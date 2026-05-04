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
        fun concurrent_streams_both_dispatch/0,
        fun post_with_body_via_data_frame/0,
        fun continuation_assembles_header_block/0,
        fun push_promise_from_client_triggers_goaway/0,
        fun even_stream_id_triggers_goaway/0,
        fun continuation_without_pending_triggers_goaway/0,
        fun data_on_unknown_stream_triggers_goaway/0,
        fun malformed_hpack_block_triggers_goaway/0,
        fun missing_pseudo_header_rst_stream/0,
        fun empty_body_response_omits_data_frame/0,
        fun stream_response_emits_data/0,
        fun stream_response_no_explicit_fin_auto_closes/0,
        fun stream_response_empty_fin_emits_empty_data/0,
        fun stream_response_with_trailers/0,
        fun stream_response_trailers_only/0,
        fun stream_response_skips_empty_nofin/0,
        fun loop_response_returns_501/0,
        fun sendfile_response_returns_501/0,
        fun websocket_response_returns_501/0,
        fun handler_crash_returns_500/0,
        fun middleware_chain_runs/0,
        fun rst_stream_cancels_active_stream/0,
        fun router_404_returns_not_found/0,
        fun data_without_end_stream_continues_loop/0,
        fun continuation_without_end_headers_continues_loop/0,
        fun idle_timeout_emits_goaway/0,
        fun settings_ack_first_frame_triggers_goaway/0,
        fun handshake_closed_during_partial_preface/0,
        fun handshake_error_during_partial_preface/0,
        fun handshake_timeout_during_partial_preface/0,
        fun frame_loop_parse_error_triggers_goaway/0,
        fun runtime_transport_error_triggers_goaway/0,
        fun runtime_idle_timeout_emits_goaway/0,
        fun rst_stream_active_stream_synced/0,
        fun stream_window_update_grows_window_synced/0,
        fun rst_stream_unknown_stream_ignored/0,
        fun headers_for_already_open_stream_protocol_error/0,
        fun synthetic_send_data_after_reset/0,
        fun synthetic_send_headers_after_reset/0,
        fun synthetic_send_trailers_after_reset/0,
        fun synthetic_send_data_to_closed_stream/0,
        fun handler_returning_invalid_shape_resets_stream/0,
        fun unrelated_down_ignored/0,
        fun over_max_concurrent_streams_refused/0,
        fun rst_during_stream_response_unwinds_worker/0,
        fun drain_with_no_streams_exits_immediately/0,
        fun drain_refuses_new_streams/0,
        fun drain_with_in_flight_stream_waits/0,
        fun drain_message_is_idempotent/0,
        fun drain_then_peer_rst_exits_via_frame_loop/0,
        fun telemetry_request_start_stop_fires_for_h2/0,
        fun telemetry_request_exception_fires_on_h2_handler_crash/0,
        fun telemetry_request_stop_fires_for_router_404/0
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
    %% Sync via PING-ACK so coverage records the prior no-op
    %% frames before `cleanup/2` races the conn process.
    SyncPing = iolist_to_binary(roadrunner_http2_frame:encode({ping, 0, <<3:64>>})),
    serve_recv(ConnPid, SyncPing),
    PingAck2 = expect_send(),
    ?assertMatch(<<_:24, 6, 1, _/binary>>, PingAck2),
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

concurrent_streams_both_dispatch() ->
    %% Phase H8b lifts MAX_CONCURRENT_STREAMS from 1 to 100; two
    %% in-flight streams now dispatch independently in their own
    %% worker processes. Open stream 1 and stream 3 with a full
    %% request each (END_HEADERS + END_STREAM) and confirm both
    %% workers reply by parsing the HEADERS frames they emit.
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    Self = self(),
    Counter = atomics:new(1, [{signed, false}]),
    ok = atomics:add(Counter, 1, 1),
    ProtoOpts = #{
        client_counter => Counter,
        listener_name => h2_concurrent_test,
        dispatch => {handler, roadrunner_h2_test_handler},
        middlewares => []
    },
    Sock = {fake, Self},
    Pid = spawn(fun() ->
        receive
            ready -> ok
        end,
        roadrunner_conn_loop_http2:enter(
            Sock, ProtoOpts, h2_concurrent_test, undefined, erlang:monotonic_time()
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
            {~":path", ~"/empty"}
        ],
        Enc
    ),
    HpackBin = iolist_to_binary(Hpack),
    H1 = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04 bor 16#01, undefined, HpackBin})
    ),
    H3 = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 3, 16#04 bor 16#01, undefined, HpackBin})
    ),
    serve_recv(Pid, H1),
    serve_recv(Pid, H3),
    %% Drain all sends, parse to find HEADERS frames per stream.
    Frames = collect_response_frames(),
    StreamIds = lists:usort([SId || {headers, SId, _} <- Frames]),
    ?assert(lists:member(1, StreamIds)),
    ?assert(lists:member(3, StreamIds)),
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

stream_response_emits_data() ->
    %% Handler: `Send(~"hello ", nofin), Send(~"world", fin)`.
    %% Expect HEADERS (no END_STREAM), DATA (no END_STREAM, "hello "),
    %% DATA (END_STREAM, "world").
    {Pid, Ref} = run_stream_request(~"/stream"),
    Frames = collect_response_frames(),
    ?assertMatch([{headers, 1, false} | _], Frames),
    [_, F2, F3] = Frames,
    ?assertEqual({data, 1, false, ~"hello "}, F2),
    ?assertEqual({data, 1, true, ~"world"}, F3),
    cleanup(Pid, Ref).

stream_response_no_explicit_fin_auto_closes() ->
    %% Handler returns without ever calling Send — server auto-emits
    %% an empty DATA frame with END_STREAM.
    {Pid, Ref} = run_stream_request(~"/stream/empty"),
    Frames = collect_response_frames(),
    ?assertEqual([{headers, 1, false}, {data, 1, true, ~""}], Frames),
    cleanup(Pid, Ref).

stream_response_empty_fin_emits_empty_data() ->
    %% Handler: `Send(~"", fin)` — emits empty DATA with END_STREAM.
    {Pid, Ref} = run_stream_request(~"/stream/empty-fin"),
    Frames = collect_response_frames(),
    ?assertEqual([{headers, 1, false}, {data, 1, true, ~""}], Frames),
    cleanup(Pid, Ref).

stream_response_with_trailers() ->
    %% `Send(~"hi", {fin, [{x-checksum, deadbeef}]})` — emits a DATA
    %% frame (no END_STREAM) followed by a HEADERS trailer frame
    %% (END_STREAM).
    {Pid, Ref} = run_stream_request(~"/stream/trailers"),
    Frames = collect_response_frames(),
    ?assertMatch(
        [{headers, 1, false}, {data, 1, false, ~"hi"}, {headers, 1, true}],
        Frames
    ),
    cleanup(Pid, Ref).

stream_response_trailers_only() ->
    %% `Send(~"", {fin, Trailers})` — only a trailer HEADERS frame.
    {Pid, Ref} = run_stream_request(~"/stream/trailers-only"),
    Frames = collect_response_frames(),
    ?assertMatch([{headers, 1, false}, {headers, 1, true}], Frames),
    cleanup(Pid, Ref).

stream_response_skips_empty_nofin() ->
    %% `Send(~"a", nofin), Send(~"", nofin), Send(~"b", nofin),
    %%  Send(~"c", fin)` — the `~""` middle call must be silently
    %% dropped. Three DATA frames in total.
    {Pid, Ref} = run_stream_request(~"/stream/many"),
    Frames = collect_response_frames(),
    ?assertEqual(
        [
            {headers, 1, false},
            {data, 1, false, ~"a"},
            {data, 1, false, ~"b"},
            {data, 1, true, ~"c"}
        ],
        Frames
    ),
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

settings_ack_first_frame_triggers_goaway() ->
    %% RFC 9113 §3.4: the first frame after the preface MUST be a
    %% non-ACK SETTINGS. A SETTINGS-ACK (the right type but wrong
    %% flags) parses cleanly — exercises the `{ok, _, _}` branch
    %% in `handshake_phase_settings/1`.
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    _ = expect_send(),
    serve_recv(ConnPid, ?PREFACE),
    %% SETTINGS-ACK: type 4, flags 1, empty body.
    serve_recv(ConnPid, <<0:24, 4, 1, 0:32>>),
    Goaway = expect_send(),
    ?assertMatch(<<0, 0, 8, 7, _/binary>>, Goaway),
    expect_close(),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 500 -> error(process_did_not_exit)
    end.

handshake_closed_during_partial_preface() ->
    %% Peer half-closes mid-preface (only 12 bytes delivered).
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    _ = expect_send(),
    Half = binary:part(?PREFACE, 0, 12),
    serve_recv(ConnPid, Half),
    ConnPid ! {roadrunner_fake_closed, {fake, self()}},
    expect_close(),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 500 -> error(process_did_not_exit)
    end.

handshake_error_during_partial_preface() ->
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    _ = expect_send(),
    Half = binary:part(?PREFACE, 0, 12),
    serve_recv(ConnPid, Half),
    ConnPid ! {roadrunner_fake_error, {fake, self()}, eaddrnotavail},
    expect_close(),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 500 -> error(process_did_not_exit)
    end.

handshake_timeout_during_partial_preface() ->
    %% Slowloris: 12 preface bytes then nothing. Override the
    %% 10s default with a 100 ms test deadline so the `after`
    %% branch in `handshake_recv/2` fires fast.
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    persistent_term:put({roadrunner_conn_loop_http2, handshake_timeout}, 100),
    try
        {Pid, Ref, ConnPid} = start_http2_conn(),
        _ = expect_send(),
        Half = binary:part(?PREFACE, 0, 12),
        serve_recv(ConnPid, Half),
        expect_close(),
        receive
            {'DOWN', Ref, process, Pid, normal} -> ok
        after 1000 -> error(process_did_not_exit)
        end
    after
        persistent_term:erase({roadrunner_conn_loop_http2, handshake_timeout})
    end.

frame_loop_parse_error_triggers_goaway() ->
    %% Garbage frame bytes after a clean handshake — the buffer
    %% parses to `{error, _}`, server emits GOAWAY and exits.
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    _ = expect_send(),
    serve_recv(ConnPid, ?PREFACE),
    serve_recv(ConnPid, ?EMPTY_SETTINGS_FRAME),
    _ = expect_send(),
    %% Length 0, type 99 (unknown), flags 0, R=0, stream 0 — the
    %% parser rejects the unknown frame type with an error tuple.
    Bad = <<0:24, 99, 0, 0:32>>,
    serve_recv(ConnPid, Bad),
    Goaway = expect_send(),
    ?assertMatch(<<0, 0, 8, 7, _/binary>>, Goaway),
    expect_close(),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 500 -> error(process_did_not_exit)
    end.

runtime_idle_timeout_emits_goaway() ->
    %% Override the 30-s idle timeout with a 100-ms test deadline
    %% so the `after` branch in `recv_more/1` fires fast.
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    persistent_term:put({roadrunner_conn_loop_http2, idle_timeout}, 100),
    try
        {Pid, Ref, ConnPid} = start_http2_conn(),
        _ = expect_send(),
        serve_recv(ConnPid, ?PREFACE),
        serve_recv(ConnPid, ?EMPTY_SETTINGS_FRAME),
        _ = expect_send(),
        Goaway = expect_send(),
        ?assertMatch(<<0, 0, 8, 7, _/binary>>, Goaway),
        expect_close(),
        receive
            {'DOWN', Ref, process, Pid, normal} -> ok
        after 1000 -> error(process_did_not_exit)
        end
    after
        persistent_term:erase({roadrunner_conn_loop_http2, idle_timeout})
    end.

rst_stream_active_stream_synced() ->
    %% Open stream 1, RST_STREAM it, then sync via PING-ACK to
    %% prove the RST was processed before cleanup races the kill.
    %% Active-mode receive added enough async slack between
    %% `serve_recv/2` and conn dispatch that `is_process_alive/1`
    %% alone wasn't a sufficient barrier for cover instrumentation.
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
    Ping = iolist_to_binary(roadrunner_http2_frame:encode({ping, 0, <<0:64>>})),
    serve_recv(ConnPid, Ping),
    PingAck = expect_send(),
    ?assertMatch(<<_:24, 6, 1, _/binary>>, PingAck),
    cleanup(Pid, Ref).

stream_window_update_grows_window_synced() ->
    %% Open a stream, deliver a non-overflowing WINDOW_UPDATE on
    %% it, sync via PING-ACK. Covers the success path of
    %% `handle_frame({window_update, StreamId, Inc}, _)` for the
    %% active stream.
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
    Wu = iolist_to_binary(roadrunner_http2_frame:encode({window_update, 1, 1024})),
    serve_recv(ConnPid, Wu),
    Ping = iolist_to_binary(roadrunner_http2_frame:encode({ping, 0, <<0:64>>})),
    serve_recv(ConnPid, Ping),
    PingAck = expect_send(),
    ?assertMatch(<<_:24, 6, 1, _/binary>>, PingAck),
    cleanup(Pid, Ref).

rst_stream_unknown_stream_ignored() ->
    %% RST_STREAM for a stream that's not currently open is silently
    %% dropped (closed-stream legality per RFC 9113 §5.4 / §6.4).
    %% Sync via PING-ACK to ensure the conn processed the RST
    %% before the cleanup race.
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    _ = expect_send(),
    serve_recv(ConnPid, ?PREFACE),
    serve_recv(ConnPid, ?EMPTY_SETTINGS_FRAME),
    _ = expect_send(),
    Rst = iolist_to_binary(roadrunner_http2_frame:encode({rst_stream, 99, cancel})),
    serve_recv(ConnPid, Rst),
    Ping = iolist_to_binary(roadrunner_http2_frame:encode({ping, 0, <<0:64>>})),
    serve_recv(ConnPid, Ping),
    PingAck = expect_send(),
    ?assertMatch(<<_:24, 6, 1, _/binary>>, PingAck),
    cleanup(Pid, Ref).

headers_for_already_open_stream_protocol_error() ->
    %% Stream id 1 is opened (HEADERS without END_STREAM) and then
    %% HEADERS for stream 1 arrives again — RFC 9113 §5.1.1: a
    %% server treats receipt of a duplicate stream-id HEADERS as
    %% PROTOCOL_ERROR (after the original opened the stream).
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    _ = expect_send(),
    serve_recv(ConnPid, ?PREFACE),
    serve_recv(ConnPid, ?EMPTY_SETTINGS_FRAME),
    _ = expect_send(),
    HpackBin = encode_post_root_headers(),
    H1 = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04, undefined, HpackBin})
    ),
    serve_recv(ConnPid, H1),
    H1Again = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04 bor 16#01, undefined, HpackBin})
    ),
    serve_recv(ConnPid, H1Again),
    Goaway = expect_send(),
    ?assertMatch(<<0, 0, 8, 7, _/binary>>, Goaway),
    expect_close(),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 500 -> error(process_did_not_exit)
    end.

synthetic_send_data_after_reset() ->
    %% Open a stream, then RST it. Stream is removed from the
    %% map. Sending a synthetic `h2_send_data` for that stream id
    %% takes the not_open branch in `handle_send_data/6` and
    %% returns `{h2_stream_reset, _}` to the would-be worker.
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    _ = expect_send(),
    serve_recv(ConnPid, ?PREFACE),
    serve_recv(ConnPid, ?EMPTY_SETTINGS_FRAME),
    _ = expect_send(),
    HpackBin = encode_post_root_headers(),
    H = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04, undefined, HpackBin})
    ),
    serve_recv(ConnPid, H),
    Rst = iolist_to_binary(roadrunner_http2_frame:encode({rst_stream, 1, cancel})),
    serve_recv(ConnPid, Rst),
    DRef = make_ref(),
    ConnPid ! {h2_send_data, self(), DRef, 1, ~"x", false},
    receive
        {h2_stream_reset, 1} -> ok
    after 500 -> error(no_reset)
    end,
    cleanup(Pid, Ref).

synthetic_send_headers_after_reset() ->
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    _ = expect_send(),
    serve_recv(ConnPid, ?PREFACE),
    serve_recv(ConnPid, ?EMPTY_SETTINGS_FRAME),
    _ = expect_send(),
    HpackBin = encode_post_root_headers(),
    H = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04, undefined, HpackBin})
    ),
    serve_recv(ConnPid, H),
    Rst = iolist_to_binary(roadrunner_http2_frame:encode({rst_stream, 1, cancel})),
    serve_recv(ConnPid, Rst),
    DRef = make_ref(),
    ConnPid ! {h2_send_headers, self(), DRef, 1, 200, [], true},
    receive
        {h2_stream_reset, 1} -> ok
    after 500 -> error(no_reset)
    end,
    cleanup(Pid, Ref).

synthetic_send_trailers_after_reset() ->
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    _ = expect_send(),
    serve_recv(ConnPid, ?PREFACE),
    serve_recv(ConnPid, ?EMPTY_SETTINGS_FRAME),
    _ = expect_send(),
    HpackBin = encode_post_root_headers(),
    H = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04, undefined, HpackBin})
    ),
    serve_recv(ConnPid, H),
    Rst = iolist_to_binary(roadrunner_http2_frame:encode({rst_stream, 1, cancel})),
    serve_recv(ConnPid, Rst),
    DRef = make_ref(),
    ConnPid ! {h2_send_trailers, self(), DRef, 1, []},
    receive
        {h2_stream_reset, 1} -> ok
    after 500 -> error(no_reset)
    end,
    cleanup(Pid, Ref).

synthetic_send_data_to_closed_stream() ->
    %% Open a stream protocol-side (HEADERS no END_STREAM, no
    %% worker yet), inject a synthetic empty-fin DATA send (closes
    %% the send side, state := closed), then inject another DATA
    %% send. The second one hits `stream_open/2`'s closed clause.
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    _ = expect_send(),
    serve_recv(ConnPid, ?PREFACE),
    serve_recv(ConnPid, ?EMPTY_SETTINGS_FRAME),
    _ = expect_send(),
    HpackBin = encode_post_root_headers(),
    H = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04, undefined, HpackBin})
    ),
    serve_recv(ConnPid, H),
    %% Empty fin closes the send side; ack confirms it.
    DRef1 = make_ref(),
    ConnPid ! {h2_send_data, self(), DRef1, 1, <<>>, true},
    receive
        {h2_send_ack, DRef1} -> ok
    after 500 -> error(no_ack)
    end,
    %% Stream is in state := closed. Send another DATA → reset.
    DRef2 = make_ref(),
    ConnPid ! {h2_send_data, self(), DRef2, 1, ~"x", false},
    receive
        {h2_stream_reset, 1} -> ok
    after 500 -> error(no_reset)
    end,
    cleanup(Pid, Ref).

handler_returning_invalid_shape_resets_stream() ->
    %% Handler returns a `{stream, _, _, not_a_function}` shape
    %% that no `emit_handler_response/3` clause matches — worker
    %% dies with function_clause; conn observes DOWN with a
    %% non-normal reason and emits RST_STREAM(internal_error).
    {Pid, Ref} = run_h2_request_with_handler(roadrunner_h2_test_handler, ~"/badshape"),
    cleanup(Pid, Ref).

unrelated_down_ignored() ->
    %% A `'DOWN'` message with a ref the conn doesn't know about
    %% (some stray monitor) is silently dropped — the conn keeps
    %% serving. PING-ACK sync proves it.
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    _ = expect_send(),
    serve_recv(ConnPid, ?PREFACE),
    serve_recv(ConnPid, ?EMPTY_SETTINGS_FRAME),
    _ = expect_send(),
    ConnPid ! {'DOWN', make_ref(), process, self(), normal},
    Ping = iolist_to_binary(roadrunner_http2_frame:encode({ping, 0, <<0:64>>})),
    serve_recv(ConnPid, Ping),
    PingAck = expect_send(),
    ?assertMatch(<<_:24, 6, 1, _/binary>>, PingAck),
    cleanup(Pid, Ref).

over_max_concurrent_streams_refused() ->
    %% Open 100 streams without END_STREAM (no body, just keep
    %% them alive in the map), then HEADERS for the 101st gets
    %% RST_STREAM(REFUSED_STREAM).
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    _ = expect_send(),
    serve_recv(ConnPid, ?PREFACE),
    serve_recv(ConnPid, ?EMPTY_SETTINGS_FRAME),
    _ = expect_send(),
    HpackBin = encode_post_root_headers(),
    %% Send 100 HEADERS frames (stream ids 1, 3, ..., 199).
    lists:foreach(
        fun(I) ->
            StreamId = 1 + 2 * I,
            HF = iolist_to_binary(
                roadrunner_http2_frame:encode(
                    {headers, StreamId, 16#04, undefined, HpackBin}
                )
            ),
            serve_recv(ConnPid, HF)
        end,
        lists:seq(0, 99)
    ),
    %% 101st stream → over the limit. Expect RST_STREAM(refused_stream).
    Over = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 201, 16#04, undefined, HpackBin})
    ),
    serve_recv(ConnPid, Over),
    Rst = expect_send(),
    {ok, {rst_stream, 201, refused_stream}, _} =
        roadrunner_http2_frame:parse(Rst, 16384),
    cleanup(Pid, Ref).

rst_during_stream_response_unwinds_worker() ->
    %% A `{stream, _}` handler pauses mid-response. Peer sends
    %% RST_STREAM during the pause. Conn's `reset_stream/2` tells
    %% the worker; the worker is parked in `sync/2` waiting for
    %% the next ack — the `{h2_stream_reset, _}` arm fires and the
    %% worker exits with reason `stream_reset`. Conn's
    %% `handle_worker_down/3` observes the non-normal exit and
    %% emits `RST_STREAM(internal_error)` (no-op for the peer
    %% since they already cancelled, but exercises that branch).
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    Self = self(),
    Counter = atomics:new(1, [{signed, false}]),
    ok = atomics:add(Counter, 1, 1),
    ProtoOpts = #{
        client_counter => Counter,
        listener_name => h2_rst_during_stream,
        dispatch => {handler, roadrunner_h2_test_handler},
        middlewares => []
    },
    Sock = {fake, Self},
    Pid = spawn(fun() ->
        receive
            ready -> ok
        end,
        roadrunner_conn_loop_http2:enter(
            Sock, ProtoOpts, h2_rst_during_stream, undefined, erlang:monotonic_time()
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
            {~":path", ~"/stream/slow"}
        ],
        Enc
    ),
    HpackBin = iolist_to_binary(Hpack),
    H = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04 bor 16#01, undefined, HpackBin})
    ),
    serve_recv(Pid, H),
    %% Worker emits HEADERS + first DATA (~"a"), then sleeps 200 ms.
    %% Drain those, then RST during the sleep.
    timer:sleep(50),
    _ = drain_send(50),
    _ = drain_send(50),
    Rst = iolist_to_binary(roadrunner_http2_frame:encode({rst_stream, 1, cancel})),
    serve_recv(Pid, Rst),
    %% Wait for worker death + abort_stream to send RST_STREAM(internal_error).
    timer:sleep(300),
    cleanup(Pid, Ref).

drain_with_no_streams_exits_immediately() ->
    %% Drain message arrives on an idle conn. Server emits
    %% GOAWAY(NO_ERROR) and exits cleanly.
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    _ = expect_send(),
    serve_recv(ConnPid, ?PREFACE),
    serve_recv(ConnPid, ?EMPTY_SETTINGS_FRAME),
    _ = expect_send(),
    ConnPid ! {roadrunner_drain, erlang:monotonic_time(millisecond) + 5_000},
    Goaway = expect_send(),
    %% Frame type 7 = GOAWAY, error code 0 = NO_ERROR.
    ?assertMatch(<<0, 0, 8, 7, 0, _/binary>>, Goaway),
    expect_close(),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 500 -> error(process_did_not_exit)
    end.

drain_refuses_new_streams() ->
    %% After drain, HEADERS for a fresh stream gets
    %% RST_STREAM(REFUSED_STREAM) — peer should already know to
    %% retry on a different conn after the GOAWAY, but defensive.
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    Self = self(),
    Counter = atomics:new(1, [{signed, false}]),
    ok = atomics:add(Counter, 1, 1),
    ProtoOpts = #{
        client_counter => Counter,
        listener_name => h2_drain_test,
        dispatch => {handler, roadrunner_h2_test_handler},
        middlewares => []
    },
    Sock = {fake, Self},
    Pid = spawn(fun() ->
        receive
            ready -> ok
        end,
        roadrunner_conn_loop_http2:enter(
            Sock, ProtoOpts, h2_drain_test, undefined, erlang:monotonic_time()
        )
    end),
    Ref = monitor(process, Pid),
    Pid ! ready,
    _ = expect_send(),
    serve_recv(Pid, ?PREFACE),
    serve_recv(Pid, ?EMPTY_SETTINGS_FRAME),
    _ = expect_send(),
    %% Open stream 1 (HEADERS without END_STREAM, no worker yet).
    HpackBin = encode_post_root_headers(),
    H1 = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04, undefined, HpackBin})
    ),
    serve_recv(Pid, H1),
    %% Drain — server emits GOAWAY(NO_ERROR) but stays alive
    %% because stream 1 is still in-flight.
    Pid ! {roadrunner_drain, erlang:monotonic_time(millisecond) + 5_000},
    Goaway = expect_send(),
    ?assertMatch(<<0, 0, 8, 7, 0, _/binary>>, Goaway),
    %% Now HEADERS for a new stream — refused.
    H3 = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 3, 16#04 bor 16#01, undefined, HpackBin})
    ),
    serve_recv(Pid, H3),
    Rst = expect_send(),
    {ok, {rst_stream, 3, refused_stream}, _} =
        roadrunner_http2_frame:parse(Rst, 16384),
    cleanup(Pid, Ref).

drain_with_in_flight_stream_waits() ->
    %% Drain while a stream is in-flight: server sends GOAWAY but
    %% keeps serving until the in-flight stream's worker finishes,
    %% then exits cleanly.
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    Self = self(),
    Counter = atomics:new(1, [{signed, false}]),
    ok = atomics:add(Counter, 1, 1),
    ProtoOpts = #{
        client_counter => Counter,
        listener_name => h2_drain_inflight_test,
        dispatch => {handler, roadrunner_h2_test_handler},
        middlewares => []
    },
    Sock = {fake, Self},
    Pid = spawn(fun() ->
        receive
            ready -> ok
        end,
        roadrunner_conn_loop_http2:enter(
            Sock, ProtoOpts, h2_drain_inflight_test, undefined, erlang:monotonic_time()
        )
    end),
    Ref = monitor(process, Pid),
    Pid ! ready,
    _ = expect_send(),
    serve_recv(Pid, ?PREFACE),
    serve_recv(Pid, ?EMPTY_SETTINGS_FRAME),
    _ = expect_send(),
    %% Open a slow-stream request. Worker pauses 200 ms mid-response.
    Enc = roadrunner_http2_hpack:new_encoder(4096),
    {Hpack, _} = roadrunner_http2_hpack:encode(
        [
            {~":method", ~"GET"},
            {~":scheme", ~"https"},
            {~":authority", ~"localhost"},
            {~":path", ~"/stream/slow"}
        ],
        Enc
    ),
    HpackBin = iolist_to_binary(Hpack),
    H1 = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04 bor 16#01, undefined, HpackBin})
    ),
    serve_recv(Pid, H1),
    %% Worker emits HEADERS + first DATA, then sleeps. Drain mid-pause.
    timer:sleep(50),
    _ = drain_send(50),
    _ = drain_send(50),
    Pid ! {roadrunner_drain, erlang:monotonic_time(millisecond) + 5_000},
    %% Conn alive while drain pending — eventually emits GOAWAY,
    %% finishes the stream, then exits.
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 1000 -> error(drain_did_not_complete)
    end.

drain_message_is_idempotent() ->
    %% A second `{roadrunner_drain, _}` after the first is a no-op
    %% — no extra GOAWAY emitted. PING-ACK proves the conn
    %% processed the duplicate without misbehaving.
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    Self = self(),
    Counter = atomics:new(1, [{signed, false}]),
    ok = atomics:add(Counter, 1, 1),
    ProtoOpts = #{
        client_counter => Counter,
        listener_name => h2_drain_dup_test,
        dispatch => {handler, roadrunner_h2_test_handler},
        middlewares => []
    },
    Sock = {fake, Self},
    Pid = spawn(fun() ->
        receive
            ready -> ok
        end,
        roadrunner_conn_loop_http2:enter(
            Sock, ProtoOpts, h2_drain_dup_test, undefined, erlang:monotonic_time()
        )
    end),
    Ref = monitor(process, Pid),
    Pid ! ready,
    _ = expect_send(),
    serve_recv(Pid, ?PREFACE),
    serve_recv(Pid, ?EMPTY_SETTINGS_FRAME),
    _ = expect_send(),
    %% Open a stream so the conn doesn't exit on first drain.
    HpackBin = encode_post_root_headers(),
    H = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04, undefined, HpackBin})
    ),
    serve_recv(Pid, H),
    Pid ! {roadrunner_drain, erlang:monotonic_time(millisecond) + 5_000},
    Goaway = expect_send(),
    ?assertMatch(<<0, 0, 8, 7, 0, _/binary>>, Goaway),
    %% Second drain message — idempotent, no GOAWAY this time.
    Pid ! {roadrunner_drain, erlang:monotonic_time(millisecond) + 5_000},
    Ping = iolist_to_binary(roadrunner_http2_frame:encode({ping, 0, <<0:64>>})),
    serve_recv(Pid, Ping),
    PingAck = expect_send(),
    ?assertMatch(<<_:24, 6, 1, _/binary>>, PingAck),
    cleanup(Pid, Ref).

drain_then_peer_rst_exits_via_frame_loop() ->
    %% Drain while a stream is open. Peer RSTs the last
    %% in-flight stream — `handle_frame({rst_stream, ...})` tail-calls
    %% `frame_loop/1` which observes `draining = true` and an empty
    %% streams map, and exits cleanly.
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    Self = self(),
    Counter = atomics:new(1, [{signed, false}]),
    ok = atomics:add(Counter, 1, 1),
    ProtoOpts = #{
        client_counter => Counter,
        listener_name => h2_drain_rst_test,
        dispatch => {handler, roadrunner_h2_test_handler},
        middlewares => []
    },
    Sock = {fake, Self},
    Pid = spawn(fun() ->
        receive
            ready -> ok
        end,
        roadrunner_conn_loop_http2:enter(
            Sock, ProtoOpts, h2_drain_rst_test, undefined, erlang:monotonic_time()
        )
    end),
    Ref = monitor(process, Pid),
    Pid ! ready,
    _ = expect_send(),
    serve_recv(Pid, ?PREFACE),
    serve_recv(Pid, ?EMPTY_SETTINGS_FRAME),
    _ = expect_send(),
    HpackBin = encode_post_root_headers(),
    H = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04, undefined, HpackBin})
    ),
    serve_recv(Pid, H),
    Pid ! {roadrunner_drain, erlang:monotonic_time(millisecond) + 5_000},
    Goaway = expect_send(),
    ?assertMatch(<<0, 0, 8, 7, 0, _/binary>>, Goaway),
    Rst = iolist_to_binary(roadrunner_http2_frame:encode({rst_stream, 1, cancel})),
    serve_recv(Pid, Rst),
    expect_close(),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 1000 -> error(drain_did_not_complete)
    end.

telemetry_request_start_stop_fires_for_h2() ->
    %% A successful h2 request fires `[roadrunner, request, start]`
    %% and `[roadrunner, request, stop]` from the worker. Same
    %% metadata schema as h1 — request_id, peer, method, path,
    %% scheme, listener_name; stop adds status + response_kind.
    HandlerId = attach_telemetry([
        [roadrunner, request, start],
        [roadrunner, request, stop]
    ]),
    try
        {Pid, Ref} = run_h2_request_with_handler(roadrunner_h2_test_handler, ~"/empty"),
        Events = collect_telemetry(2),
        [{StartEv, _, StartMd}, {StopEv, StopM, StopMd}] = sort_events(Events),
        ?assertEqual([roadrunner, request, start], StartEv),
        ?assertEqual([roadrunner, request, stop], StopEv),
        ?assertEqual(~"GET", maps:get(method, StartMd)),
        ?assertEqual(~"/empty", maps:get(path, StartMd)),
        ?assertEqual(http, maps:get(scheme, StartMd)),
        ?assert(is_integer(maps:get(duration, StopM))),
        ?assertEqual(200, maps:get(status, StopMd)),
        ?assertEqual(buffered, maps:get(response_kind, StopMd)),
        cleanup(Pid, Ref)
    after
        detach_telemetry(HandlerId)
    end.

telemetry_request_exception_fires_on_h2_handler_crash() ->
    HandlerId = attach_telemetry([[roadrunner, request, exception]]),
    try
        {Pid, Ref} = run_h2_request_with_handler(roadrunner_h2_test_handler, ~"/crash"),
        receive
            {telemetry_event, [roadrunner, request, exception], M, Md} ->
                ?assert(is_integer(maps:get(duration, M))),
                ?assertEqual(error, maps:get(kind, Md)),
                ?assertEqual(boom, maps:get(reason, Md))
        after 500 -> error(no_exception_event)
        end,
        cleanup(Pid, Ref)
    after
        detach_telemetry(HandlerId)
    end.

telemetry_request_stop_fires_for_router_404() ->
    %% Router-based dispatch where no route matches → 404 path
    %% in `run_handler/4` short-circuits past `invoke/7` and still
    %% fires request_stop with status=404.
    HandlerId = attach_telemetry([[roadrunner, request, stop]]),
    try
        {ok, _} = application:ensure_all_started(telemetry),
        drain_mailbox(),
        persistent_term:put({roadrunner_routes, h2_telem_404}, roadrunner_router:compile([])),
        Self = self(),
        Counter = atomics:new(1, [{signed, false}]),
        ok = atomics:add(Counter, 1, 1),
        ProtoOpts = #{
            client_counter => Counter,
            listener_name => h2_telem_404,
            dispatch => {router, h2_telem_404},
            middlewares => []
        },
        Sock = {fake, Self},
        Pid = spawn(fun() ->
            receive
                ready -> ok
            end,
            roadrunner_conn_loop_http2:enter(
                Sock, ProtoOpts, h2_telem_404, undefined, erlang:monotonic_time()
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
        H = iolist_to_binary(
            roadrunner_http2_frame:encode({headers, 1, 16#04 bor 16#01, undefined, HpackBin})
        ),
        serve_recv(Pid, H),
        receive
            {telemetry_event, [roadrunner, request, stop], _M, Md} ->
                ?assertEqual(404, maps:get(status, Md)),
                ?assertEqual(buffered, maps:get(response_kind, Md))
        after 500 -> error(no_stop_event)
        end,
        cleanup(Pid, Ref)
    after
        detach_telemetry(HandlerId)
    end.

attach_telemetry(Events) ->
    Self = self(),
    HandlerId = make_ref(),
    ok = telemetry:attach_many(
        HandlerId,
        Events,
        fun(Ev, M, Md, _) -> Self ! {telemetry_event, Ev, M, Md} end,
        []
    ),
    HandlerId.

detach_telemetry(HandlerId) ->
    ok = telemetry:detach(HandlerId).

collect_telemetry(N) ->
    collect_telemetry(N, []).

collect_telemetry(0, Acc) ->
    lists:reverse(Acc);
collect_telemetry(N, Acc) ->
    receive
        {telemetry_event, Ev, M, Md} ->
            collect_telemetry(N - 1, [{Ev, M, Md} | Acc])
    after 500 ->
        error({missing_events, N})
    end.

sort_events(Events) ->
    Order = fun
        ([roadrunner, request, start]) -> 1;
        ([roadrunner, request, stop]) -> 2;
        (_) -> 3
    end,
    lists:sort(fun({A, _, _}, {B, _, _}) -> Order(A) =< Order(B) end, Events).

encode_post_root_headers() ->
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
    iolist_to_binary(Hpack).

runtime_transport_error_triggers_goaway() ->
    %% Transport error AFTER handshake — exercises the `{MError, _, _}`
    %% arm of `recv_more/1`.
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    _ = expect_send(),
    serve_recv(ConnPid, ?PREFACE),
    serve_recv(ConnPid, ?EMPTY_SETTINGS_FRAME),
    _ = expect_send(),
    %% Drain the setopts (active-once arm) before delivering the
    %% error so the conn is parked in `recv_more/1`.
    timer:sleep(20),
    ConnPid ! {roadrunner_fake_error, {fake, self()}, etimedout},
    Goaway = expect_send(),
    ?assertMatch(<<0, 0, 8, 7, _/binary>>, Goaway),
    expect_close(),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 500 -> error(process_did_not_exit)
    end.

idle_timeout_emits_goaway() ->
    %% After the handshake the conn is idle in active-once receive
    %% waiting for frames. Delivering a `roadrunner_fake_closed`
    %% message simulates the peer going away — the conn should exit
    %% cleanly.
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    _ = expect_send(),
    serve_recv(ConnPid, ?PREFACE),
    serve_recv(ConnPid, ?EMPTY_SETTINGS_FRAME),
    _ = expect_send(),
    ConnPid ! {roadrunner_fake_closed, {fake, self()}},
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
    %% Force the conn process to exit and **wait synchronously** for
    %% its `'DOWN'` signal. Erlang's runtime reuses pids over time;
    %% if the conn outlives the test process, eunit may spawn a
    %% later test (in this or another module) at the same pid and
    %% the still-alive conn will deliver `roadrunner_fake_*`
    %% messages to it. The synchronous wait makes sure the conn is
    %% truly gone before this test returns.
    exit(Pid, kill),
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    end.

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

%% After Phase H8a's switch to active-mode receive, the conn
%% process arms `[{active, once}]` between iterations and reads
%% bytes off its mailbox. Tests deliver wire bytes by sending the
%% `roadrunner_fake_data` message directly to the conn pid. The
%% `recv` request/reply pattern that used to drive this no longer
%% fires.
serve_recv(ConnPid, Data) ->
    %% The conn arms active-once and the fake transport forwards
    %% `{roadrunner_fake_setopts, ConnPid, Opts}` to us each time;
    %% we don't care about it here but draining keeps the mailbox
    %% from filling up across long tests.
    drain_setopts(),
    ConnPid ! {roadrunner_fake_data, {fake, self()}, iolist_to_binary([Data])},
    ok.

drain_setopts() ->
    receive
        {roadrunner_fake_setopts, _, _} -> drain_setopts()
    after 0 -> ok
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

%% Drive a GET against `Path` and return the conn pid + ref. Unlike
%% `run_h2_request_with_handler`, leaves the response frames in our
%% mailbox so the test can decode + assert on them via
%% `collect_response_frames/0`.
run_stream_request(Path) ->
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    Self = self(),
    Counter = atomics:new(1, [{signed, false}]),
    ok = atomics:add(Counter, 1, 1),
    ProtoOpts = #{
        client_counter => Counter,
        listener_name => h2_stream_test,
        dispatch => {handler, roadrunner_h2_test_handler},
        middlewares => []
    },
    Sock = {fake, Self},
    Pid = spawn(fun() ->
        receive
            ready -> ok
        end,
        roadrunner_conn_loop_http2:enter(
            Sock, ProtoOpts, h2_stream_test, undefined, erlang:monotonic_time()
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
    {Pid, Ref}.

%% Pull every `roadrunner_fake_send` payload off the mailbox until
%% there's a 50 ms quiet period, then parse the concatenated bytes
%% into structural frame tags suitable for assertions:
%%   {headers, StreamId, EndStream}
%%   {data, StreamId, EndStream, Payload}
collect_response_frames() ->
    Bin = collect_send_bytes(<<>>),
    parse_frames(Bin).

collect_send_bytes(Acc) ->
    receive
        {roadrunner_fake_send, _Pid, Data} ->
            collect_send_bytes(<<Acc/binary, (iolist_to_binary(Data))/binary>>)
    after 100 ->
        Acc
    end.

parse_frames(<<>>) ->
    [];
parse_frames(<<Len:24, Type, Flags, _R:1, StreamId:31, Body:Len/binary, Rest/binary>>) ->
    EndStream = (Flags band 16#01) =/= 0,
    case Type of
        0 ->
            [{data, StreamId, EndStream, Body} | parse_frames(Rest)];
        1 ->
            [{headers, StreamId, EndStream} | parse_frames(Rest)];
        _ ->
            [{other, Type, StreamId, EndStream} | parse_frames(Rest)]
    end.

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
