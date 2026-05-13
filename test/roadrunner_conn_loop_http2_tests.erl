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
        fun h2c_dispatch_routes_plaintext_to_http2_loop/0,
        fun plaintext_listener_without_h2c_stays_h1/0,
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
        fun loop_response_emits_data_then_closes_on_stop/0,
        fun loop_response_filters_otp_messages/0,
        fun sendfile_empty_emits_empty_data/0,
        fun sendfile_small_file_emits_single_data_frame/0,
        fun sendfile_multi_frame_chunks_at_max_frame_size/0,
        fun sendfile_offset_and_length_window/0,
        fun sendfile_missing_file_resets_stream/0,
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
        fun headers_for_already_open_stream_without_end_stream_protocol_error/0,
        fun synthetic_send_data_after_reset/0,
        fun synthetic_send_headers_after_reset/0,
        fun synthetic_send_response_after_reset/0,
        fun synthetic_send_response_empty_after_reset/0,
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
        fun telemetry_request_stop_fires_for_router_404/0,
        fun compress_middleware_gzips_buffered_h2_response/0,
        fun compress_middleware_passthrough_when_no_accept_encoding/0,
        fun data_on_stream_zero_protocol_error/0,
        fun data_on_idle_stream_protocol_error/0,
        fun data_on_closed_stream_rst/0,
        fun headers_self_dependency_rst_stream/0,
        fun priority_self_dependency_rst_stream/0,
        fun enable_push_invalid_value_protocol_error/0,
        fun initial_window_size_too_large_flow_control_error/0,
        fun max_frame_size_too_small_protocol_error/0,
        fun max_frame_size_too_large_protocol_error/0,
        fun initial_window_size_change_overflows_flow_control_error/0,
        fun content_length_mismatch_rst_stream/0,
        fun request_trailers_dispatched/0,
        fun request_trailers_via_continuation/0,
        fun awaiting_continuation_blocks_other_frames/0,
        fun unknown_frame_silently_ignored/0,
        fun rst_stream_on_idle_stream_protocol_error/0,
        fun window_update_on_idle_stream_protocol_error/0,
        fun window_update_on_closed_stream_ignored/0,
        fun unsolicited_continuation_protocol_error/0,
        fun trailers_with_malformed_hpack_goaway/0,
        fun content_length_match_dispatches/0,
        fun content_length_non_integer_rst_stream/0,
        fun hpack_table_size_update_after_block_goaway/0,
        fun headers_for_closed_stream_protocol_error/0,
        fun settings_initial_window_size_shifts_stream_window/0,
        fun content_length_multi_valued_rst_stream/0,
        fun trailers_after_first_end_stream_protocol_error/0
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

h2c_dispatch_routes_plaintext_to_http2_loop() ->
    %% Drive the dispatch decision through `roadrunner_conn_loop:start/2`
    %% with a `{fake, _}` socket and `h2c => enabled`. Without the h2c
    %% opt the plain TCP path stays h1 and the conn waits for a request
    %% line; the h2 path proactively emits SETTINGS right after `shoot`.
    %% Receiving an h2 SETTINGS frame here proves the new dispatch
    %% (`http2_negotiated/1 orelse h2c_enabled/1`) routed to the h2 loop.
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    Self = self(),
    Counter = atomics:new(1, [{signed, false}]),
    ok = atomics:add(Counter, 1, 1),
    RequestsCounter = atomics:new(1, [{signed, false}]),
    ProtoOpts = #{
        client_counter => Counter,
        requests_counter => RequestsCounter,
        listener_name => h2c_dispatch_test,
        dispatch => {handler, roadrunner_hello_handler},
        middlewares => [],
        max_content_length => 1_048_576,
        request_timeout => 30000,
        keep_alive_timeout => 60000,
        max_keep_alive_requests => 1000,
        max_clients => 100,
        minimum_bytes_per_second => 0,
        body_buffering => auto,
        drain_group => disabled,
        h2c => enabled,
        h2_initial_conn_window => 65535,
        h2_initial_stream_window => 65535,
        h2_window_refill_threshold => 32768
    },
    Sock = {fake, Self},
    {ok, Pid} = roadrunner_conn_loop:start(Sock, ProtoOpts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    %% h2 SETTINGS frame: 24-bit length, type=4, 8-bit flags, 31-bit
    %% reserved+stream-id (zero for conn-level). Length is non-negative
    %% (server SETTINGS is at least zero bytes). The exact value
    %% depends on which SETTINGS entries roadrunner advertises; we
    %% match the frame shape rather than pin the bytes.
    Out = expect_send(),
    ?assertMatch(<<_Len:24, 4, _Flags, _Reserved:1, _StreamId:31, _/binary>>, Out),
    cleanup(Pid, Ref).

plaintext_listener_without_h2c_stays_h1() ->
    %% Regression guard for the dispatch's false branch. Without
    %% `h2c => enabled` and without TLS ALPN, `awaiting_shoot/3`
    %% must fall through to the HTTP/1.1 path. Discriminator:
    %%
    %% - The h2 path proactively sends a SETTINGS frame on the wire
    %%   right after `shoot` (`{roadrunner_fake_send, _, _}`).
    %% - The h1 path enters passive recv and asks the fake transport
    %%   for bytes (`{roadrunner_fake_recv, _, _, _}`).
    %%
    %% Receiving the recv message (and no send) proves we routed to h1.
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    Self = self(),
    Counter = atomics:new(1, [{signed, false}]),
    ok = atomics:add(Counter, 1, 1),
    RequestsCounter = atomics:new(1, [{signed, false}]),
    ProtoOpts = #{
        client_counter => Counter,
        requests_counter => RequestsCounter,
        listener_name => h1_dispatch_test,
        dispatch => {handler, roadrunner_hello_handler},
        middlewares => [],
        max_content_length => 1_048_576,
        request_timeout => 30000,
        keep_alive_timeout => 60000,
        max_keep_alive_requests => 1000,
        max_clients => 100,
        minimum_bytes_per_second => 0,
        body_buffering => auto,
        drain_group => disabled,
        h2c => disabled,
        h2_initial_conn_window => 65535,
        h2_initial_stream_window => 65535,
        h2_window_refill_threshold => 32768
    },
    Sock = {fake, Self},
    {ok, Pid} = roadrunner_conn_loop:start(Sock, ProtoOpts),
    Ref = monitor(process, Pid),
    Pid ! shoot,
    %% h1 issues a passive recv on the socket; on a fake socket that
    %% surfaces as a `{roadrunner_fake_recv, ConnPid, Len, Timeout}`
    %% message to our process. h2 would never do this — it goes
    %% active-once via setopts and proactively writes SETTINGS first.
    receive
        {roadrunner_fake_recv, _, _, _} -> ok;
        {roadrunner_fake_send, _, _} -> error(unexpected_h2_send)
    after 500 ->
        error(no_recv_call)
    end,
    ?assert(is_process_alive(Pid)),
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

loop_response_emits_data_then_closes_on_stop() ->
    %% Drive the worker into the info_loop, push two messages, then
    %% stop. The handler registers `roadrunner_h2_loop_test` so we
    %% can address it from outside the worker. Expected wire frame
    %% sequence: HEADERS (no END_STREAM), DATA(`data: hi\n\n`),
    %% DATA(`data: bye(1)\n\n`), DATA(<<>>, END_STREAM).
    {Pid, Ref} = run_stream_request(~"/loop"),
    wait_for_register(roadrunner_h2_loop_test, 1000),
    roadrunner_h2_loop_test ! {push, ~"hi"},
    roadrunner_h2_loop_test ! stop,
    Frames = collect_response_frames(),
    ?assertMatch(
        [
            {headers, 1, false},
            {data, 1, false, ~"data: hi\n\n"},
            {data, 1, false, ~"data: bye(1)\n\n"},
            {data, 1, true, ~""}
        ],
        Frames
    ),
    cleanup(Pid, Ref).

loop_response_filters_otp_messages() ->
    %% sys / gen_call / gen_cast shapes must NOT reach `handle_info/3`.
    %% The handler increments `N` only on `{push, _}`; if any OTP
    %% message slipped through to handle_info the `bye(N)` chunk
    %% would show a larger counter.
    {Pid, Ref} = run_stream_request(~"/loop"),
    wait_for_register(roadrunner_h2_loop_test, 1000),
    roadrunner_h2_loop_test ! {system, make_ref(), get_state},
    roadrunner_h2_loop_test ! {'$gen_call', {self(), make_ref()}, ping},
    roadrunner_h2_loop_test ! {'$gen_cast', whatever},
    roadrunner_h2_loop_test ! {push, ~"real"},
    roadrunner_h2_loop_test ! stop,
    Frames = collect_response_frames(),
    ?assertMatch(
        [
            {headers, 1, false},
            {data, 1, false, ~"data: real\n\n"},
            {data, 1, false, ~"data: bye(1)\n\n"},
            {data, 1, true, ~""}
        ],
        Frames
    ),
    cleanup(Pid, Ref).

sendfile_empty_emits_empty_data() ->
    %% Length=0: file is opened but never read. The base clause of
    %% sendfile_loop emits Send(<<>>, fin) → empty DATA with END_STREAM.
    {Pid, Ref} = run_stream_request(~"/sendfile"),
    Frames = collect_response_frames(),
    ?assertEqual([{headers, 1, false}, {data, 1, true, ~""}], Frames),
    cleanup(Pid, Ref).

sendfile_small_file_emits_single_data_frame() ->
    %% 100-byte file fits in a single DATA frame.
    Path = "/tmp/rr_h2_sf_small.bin",
    Body = binary:copy(<<"x">>, 100),
    ok = file:write_file(Path, Body),
    try
        {Pid, Ref} = run_stream_request(~"/sendfile/small"),
        Frames = collect_response_frames(),
        ?assertEqual(
            [{headers, 1, false}, {data, 1, true, Body}],
            Frames
        ),
        cleanup(Pid, Ref)
    after
        _ = file:delete(Path)
    end.

sendfile_multi_frame_chunks_at_max_frame_size() ->
    %% 40000-byte file splits into 3 DATA frames: 16384, 16384, 7232.
    %% Only the last carries END_STREAM. The wire body re-assembled
    %% from all three DATA payloads must equal the original file.
    Path = "/tmp/rr_h2_sf_multi.bin",
    Body = iolist_to_binary([
        binary:copy(<<"a">>, 16384),
        binary:copy(<<"b">>, 16384),
        binary:copy(<<"c">>, 7232)
    ]),
    ok = file:write_file(Path, Body),
    try
        {Pid, Ref} = run_stream_request(~"/sendfile/multi"),
        Frames = collect_response_frames(),
        ?assertMatch(
            [
                {headers, 1, false},
                {data, 1, false, _},
                {data, 1, false, _},
                {data, 1, true, _}
            ],
            Frames
        ),
        [_H, {data, 1, false, D1}, {data, 1, false, D2}, {data, 1, true, D3}] =
            Frames,
        ?assertEqual(16384, byte_size(D1)),
        ?assertEqual(16384, byte_size(D2)),
        ?assertEqual(7232, byte_size(D3)),
        ?assertEqual(Body, <<D1/binary, D2/binary, D3/binary>>),
        cleanup(Pid, Ref)
    after
        _ = file:delete(Path)
    end.

sendfile_offset_and_length_window() ->
    %% 1000-byte file, sendfile (Offset=200, Length=500). Wire body
    %% must equal bytes [200, 700) of the file.
    Path = "/tmp/rr_h2_sf_window.bin",
    Body = list_to_binary([X rem 256 || X <- lists:seq(0, 999)]),
    ok = file:write_file(Path, Body),
    try
        {Pid, Ref} = run_stream_request(~"/sendfile/window"),
        Frames = collect_response_frames(),
        ?assertMatch(
            [{headers, 1, false}, {data, 1, true, _}],
            Frames
        ),
        [_H, {data, 1, true, Slice}] = Frames,
        ?assertEqual(binary:part(Body, 200, 500), Slice),
        cleanup(Pid, Ref)
    after
        _ = file:delete(Path)
    end.

sendfile_missing_file_resets_stream() ->
    %% File open fails inside the StreamFun before any HEADERS are
    %% sent. The worker crashes; the conn RST_STREAMs the stream and
    %% the loop continues. The conn process must still be alive
    %% afterwards.
    _ = file:delete("/tmp/rr_h2_sf_does_not_exist.bin"),
    {Pid, Ref} = run_h2_request_with_handler(
        roadrunner_h2_test_handler, ~"/sendfile/missing"
    ),
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
    %% RST_STREAM with a 5-byte payload (must be exactly 4 bytes
    %% per RFC 9113 §6.4) — parser returns `{error, _}`.
    Bad = <<0, 0, 5, 3, 0, 0:32, 0:32, 0>>,
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
    %% RST_STREAM for a stream we previously opened then RST'd
    %% (id <= last_stream_id, no longer in map) is silently
    %% dropped per RFC 9113 §5.4 / §6.4. Idle (id > last_stream_id)
    %% is a different case — covered by
    %% `rst_stream_on_idle_stream_protocol_error/0`.
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    _ = expect_send(),
    serve_recv(ConnPid, ?PREFACE),
    serve_recv(ConnPid, ?EMPTY_SETTINGS_FRAME),
    _ = expect_send(),
    %% Open + RST stream 1 so it's a closed (not idle) id.
    HpackBin = encode_post_root_headers(),
    H = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04, undefined, HpackBin})
    ),
    serve_recv(ConnPid, H),
    Rst1 = iolist_to_binary(roadrunner_http2_frame:encode({rst_stream, 1, cancel})),
    serve_recv(ConnPid, Rst1),
    %% Second RST for the same now-closed stream — silently ignored.
    Rst2 = iolist_to_binary(roadrunner_http2_frame:encode({rst_stream, 1, cancel})),
    serve_recv(ConnPid, Rst2),
    Ping = iolist_to_binary(roadrunner_http2_frame:encode({ping, 0, <<0:64>>})),
    serve_recv(ConnPid, Ping),
    PingAck = expect_send(),
    ?assertMatch(<<_:24, 6, 1, _/binary>>, PingAck),
    cleanup(Pid, Ref).

headers_for_already_open_stream_without_end_stream_protocol_error() ->
    %% Two HEADERS frames on the same stream without END_STREAM on
    %% either: the first opens the stream, the second is invalid
    %% (only a trailer HEADERS with END_STREAM is allowed after
    %% the body). Per RFC 9113 §8.1 → PROTOCOL_ERROR.
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
        roadrunner_http2_frame:encode({headers, 1, 16#04, undefined, HpackBin})
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

synthetic_send_response_after_reset() ->
    %% New buffered-response message path: send a synthetic
    %% `h2_send_response` for a stream that's been RST'd. Conn
    %% replies `{h2_stream_reset, _}`. Body non-empty path.
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
    ConnPid ! {h2_send_response, self(), DRef, 1, 200, [], ~"hi"},
    receive
        {h2_stream_reset, 1} -> ok
    after 500 -> error(no_reset)
    end,
    cleanup(Pid, Ref).

synthetic_send_response_empty_after_reset() ->
    %% Same as above but empty body — exercises the
    %% `handle_send_response/_, _, _, _, _, _, <<>>)` clause's
    %% `not_open` arm.
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
    ConnPid ! {h2_send_response, self(), DRef, 1, 200, [], <<>>},
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

compress_middleware_gzips_buffered_h2_response() ->
    %% Verify Phase H11's hypothesis: `roadrunner_compress` works
    %% unchanged over h2 because it operates on the abstract
    %% request/response shape, not on h1 wire syntax. Send a GET
    %% with `accept-encoding: gzip` over h2 → response carries
    %% `content-encoding: gzip` and the decoded body matches the
    %% original.
    Body = binary:copy(<<"hello world! ">>, 1000),
    {Pid, Ref, Frames} = run_h2_with_compress_middleware(
        ~"/compressible", [{~"accept-encoding", ~"gzip"}]
    ),
    {200, RespHeaders, GzipPayload} = decode_response(Frames),
    ?assertEqual(~"gzip", proplists:get_value(~"content-encoding", RespHeaders)),
    ?assertEqual(Body, zlib:gunzip(GzipPayload)),
    %% Compressed body should be smaller than original (sanity).
    ?assert(byte_size(GzipPayload) < byte_size(Body)),
    cleanup(Pid, Ref).

compress_middleware_passthrough_when_no_accept_encoding() ->
    %% No `accept-encoding` header → middleware passes through
    %% uncompressed. Body matches handler output verbatim.
    Body = binary:copy(<<"hello world! ">>, 1000),
    {Pid, Ref, Frames} = run_h2_with_compress_middleware(~"/compressible", []),
    {200, RespHeaders, Payload} = decode_response(Frames),
    ?assertEqual(undefined, proplists:get_value(~"content-encoding", RespHeaders)),
    ?assertEqual(Body, Payload),
    cleanup(Pid, Ref).

run_h2_with_compress_middleware(Path, ExtraHeaders) ->
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    Self = self(),
    Counter = atomics:new(1, [{signed, false}]),
    ok = atomics:add(Counter, 1, 1),
    ProtoOpts = #{
        client_counter => Counter,
        listener_name => h2_compress_test,
        dispatch => {handler, roadrunner_h2_test_handler},
        middlewares => [roadrunner_compress]
    },
    Sock = {fake, Self},
    Pid = spawn(fun() ->
        receive
            ready -> ok
        end,
        roadrunner_conn_loop_http2:enter(
            Sock, ProtoOpts, h2_compress_test, undefined, erlang:monotonic_time()
        )
    end),
    Ref = monitor(process, Pid),
    Pid ! ready,
    _ = expect_send(),
    serve_recv(Pid, ?PREFACE),
    serve_recv(Pid, ?EMPTY_SETTINGS_FRAME),
    _ = expect_send(),
    Enc = roadrunner_http2_hpack:new_encoder(4096),
    BaseHeaders = [
        {~":method", ~"GET"},
        {~":scheme", ~"https"},
        {~":authority", ~"localhost"},
        {~":path", Path}
    ],
    {Hpack, _} = roadrunner_http2_hpack:encode(BaseHeaders ++ ExtraHeaders, Enc),
    HpackBin = iolist_to_binary(Hpack),
    H = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04 bor 16#01, undefined, HpackBin})
    ),
    serve_recv(Pid, H),
    Bytes = collect_send_bytes(<<>>),
    {Pid, Ref, parse_full_frames(Bytes)}.

%% Parse raw response bytes into structured frames preserving
%% HPACK blocks + DATA payloads. Different from
%% `parse_frames/1` (which discards bodies) — needed for
%% compression tests where we have to decode HPACK headers and
%% concatenate DATA payloads.
parse_full_frames(<<>>) ->
    [];
parse_full_frames(<<Len:24, Type, Flags, _R:1, StreamId:31, Body:Len/binary, Rest/binary>>) ->
    EndStream = (Flags band 16#01) =/= 0,
    case Type of
        0 ->
            [{data, StreamId, EndStream, Body} | parse_full_frames(Rest)];
        1 ->
            [{headers, StreamId, EndStream, Body} | parse_full_frames(Rest)];
        _ ->
            parse_full_frames(Rest)
    end.

decode_response(Frames) ->
    Dec = roadrunner_http2_hpack:new_decoder(4096),
    decode_response_loop(Frames, Dec, undefined, [], <<>>).

decode_response_loop([], _Dec, Status, RespHeaders, Body) ->
    {Status, RespHeaders, Body};
decode_response_loop([{headers, _, _, Block} | Rest], Dec, _Status, _RespHeaders, Body) ->
    {ok, Decoded, Dec1} = roadrunner_http2_hpack:decode(Block, Dec),
    StatusBin = proplists:get_value(~":status", Decoded),
    Status1 = binary_to_integer(StatusBin),
    Regular = [{N, V} || {N, V} <- Decoded, binary:first(N) =/= $:],
    decode_response_loop(Rest, Dec1, Status1, Regular, Body);
decode_response_loop([{data, _, _, Payload} | Rest], Dec, Status, RespHeaders, Body) ->
    decode_response_loop(Rest, Dec, Status, RespHeaders, <<Body/binary, Payload/binary>>).

data_on_stream_zero_protocol_error() ->
    %% RFC 9113 §6.1: DATA on stream 0 is a connection error.
    {Pid, Ref, ConnPid} = post_handshake_conn(),
    serve_recv(ConnPid, <<1:24, 0, 0, 0:32, 0>>),
    Goaway = expect_send(),
    ?assertMatch(<<0, 0, 8, 7, _/binary>>, Goaway),
    expect_close(),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 500 -> error(no_exit)
    end.

data_on_idle_stream_protocol_error() ->
    %% RFC 9113 §5.1: DATA on a stream id > last_stream_id is a
    %% connection error PROTOCOL_ERROR.
    {Pid, Ref, ConnPid} = post_handshake_conn(),
    serve_recv(ConnPid, <<1:24, 0, 0, 0:1, 99:31, 0>>),
    Goaway = expect_send(),
    ?assertMatch(<<0, 0, 8, 7, _/binary>>, Goaway),
    expect_close(),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 500 -> error(no_exit)
    end.

data_on_closed_stream_rst() ->
    %% DATA on a stream id we previously closed (<= last_stream_id,
    %% not in map) is a stream error STREAM_CLOSED.
    {Pid, Ref, ConnPid} = post_handshake_conn(),
    HpackBin = encode_post_root_headers(),
    H = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04, undefined, HpackBin})
    ),
    serve_recv(ConnPid, H),
    %% RST stream 1 — removes from map.
    Rst = iolist_to_binary(roadrunner_http2_frame:encode({rst_stream, 1, cancel})),
    serve_recv(ConnPid, Rst),
    %% Now send DATA on closed stream 1.
    serve_recv(ConnPid, <<1:24, 0, 0, 0:1, 1:31, 0>>),
    Out = expect_send(),
    ?assertMatch(<<_:24, 3, _/binary>>, Out),
    cleanup(Pid, Ref).

headers_self_dependency_rst_stream() ->
    %% RFC 9113 §5.3.1: HEADERS with PRIORITY flag where stream
    %% depends on itself — stream-error PROTOCOL_ERROR.
    {Pid, Ref, ConnPid} = post_handshake_conn(),
    HpackBin = encode_post_root_headers(),
    %% PRIORITY-payload prefix: E:1, Dep:31, Weight:8 — Dep = stream id 1.
    PriPayload = <<0:1, 1:31, 0>>,
    Body = <<PriPayload/binary, HpackBin/binary>>,
    %% Flags: END_HEADERS (0x04) | PRIORITY (0x20) = 0x24.
    Frame = <<(byte_size(Body)):24, 1, 16#24, 0:1, 1:31, Body/binary>>,
    serve_recv(ConnPid, Frame),
    Out = expect_send(),
    ?assertMatch(<<_:24, 3, _/binary>>, Out),
    cleanup(Pid, Ref).

priority_self_dependency_rst_stream() ->
    %% RFC 9113 §5.3.1: PRIORITY frame depending on its own
    %% stream — stream-error PROTOCOL_ERROR.
    {Pid, Ref, ConnPid} = post_handshake_conn(),
    Pri = iolist_to_binary(
        roadrunner_http2_frame:encode(
            {priority, 1, #{exclusive => false, stream_dependency => 1, weight => 0}}
        )
    ),
    serve_recv(ConnPid, Pri),
    Out = expect_send(),
    ?assertMatch(<<_:24, 3, _/binary>>, Out),
    cleanup(Pid, Ref).

enable_push_invalid_value_protocol_error() ->
    {Pid, Ref, ConnPid} = post_handshake_conn(),
    Settings = iolist_to_binary(
        roadrunner_http2_frame:encode({settings, 0, [{2, 2}]})
    ),
    serve_recv(ConnPid, Settings),
    Goaway = expect_send(),
    ?assertMatch(<<0, 0, 8, 7, _/binary>>, Goaway),
    expect_close(),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 500 -> error(no_exit)
    end.

initial_window_size_too_large_flow_control_error() ->
    {Pid, Ref, ConnPid} = post_handshake_conn(),
    Settings = iolist_to_binary(
        roadrunner_http2_frame:encode({settings, 0, [{4, 16#80000000}]})
    ),
    serve_recv(ConnPid, Settings),
    Goaway = expect_send(),
    %% Frame type 7 (GOAWAY); error code 3 (FLOW_CONTROL_ERROR).
    ?assertMatch(<<0, 0, 8, 7, 0, 0:32, _:32, 3:32>>, Goaway),
    expect_close(),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 500 -> error(no_exit)
    end.

max_frame_size_too_small_protocol_error() ->
    {Pid, Ref, ConnPid} = post_handshake_conn(),
    Settings = iolist_to_binary(
        roadrunner_http2_frame:encode({settings, 0, [{5, 1024}]})
    ),
    serve_recv(ConnPid, Settings),
    Goaway = expect_send(),
    ?assertMatch(<<0, 0, 8, 7, _/binary>>, Goaway),
    expect_close(),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 500 -> error(no_exit)
    end.

max_frame_size_too_large_protocol_error() ->
    {Pid, Ref, ConnPid} = post_handshake_conn(),
    Settings = iolist_to_binary(
        roadrunner_http2_frame:encode({settings, 0, [{5, 16#1000000}]})
    ),
    serve_recv(ConnPid, Settings),
    Goaway = expect_send(),
    ?assertMatch(<<0, 0, 8, 7, _/binary>>, Goaway),
    expect_close(),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 500 -> error(no_exit)
    end.

initial_window_size_change_overflows_flow_control_error() ->
    %% Open a stream (default send_window=65535), then a SETTINGS
    %% with INITIAL_WINDOW_SIZE = 2^31-1. Delta = (2^31-1) - 65535,
    %% pushes existing stream window to 2^31-1 + 65535 - 65535 ... no
    %% wait: stream's send_window = 65535 + delta = 2^31-1. Doesn't
    %% overflow. To force overflow, first WINDOW_UPDATE the stream
    %% to a high value, then change INITIAL_WINDOW_SIZE.
    {Pid, Ref, ConnPid} = post_handshake_conn(),
    HpackBin = encode_post_root_headers(),
    H = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04, undefined, HpackBin})
    ),
    serve_recv(ConnPid, H),
    %% Grow stream 1's send_window to near the cap.
    Wu = iolist_to_binary(
        roadrunner_http2_frame:encode({window_update, 1, 16#7FFFFFFF - 65535})
    ),
    serve_recv(ConnPid, Wu),
    %% Now: stream 1 send_window = 2^31-1. Default initial = 65535.
    %% A SETTINGS with INITIAL_WINDOW_SIZE = 65535 + 1 → delta = 1
    %% → existing stream window = 2^31-1 + 1 = 2^31 > MAX → overflow.
    Settings = iolist_to_binary(
        roadrunner_http2_frame:encode({settings, 0, [{4, 65536}]})
    ),
    serve_recv(ConnPid, Settings),
    Goaway = expect_send(),
    ?assertMatch(<<0, 0, 8, 7, 0, 0:32, _:32, 3:32>>, Goaway),
    expect_close(),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 500 -> error(no_exit)
    end.

content_length_mismatch_rst_stream() ->
    %% Request declares content-length: 5 but body is 3 bytes.
    {Pid, Ref, ConnPid} = post_handshake_conn(),
    Enc = roadrunner_http2_hpack:new_encoder(4096),
    {Hpack, _} = roadrunner_http2_hpack:encode(
        [
            {~":method", ~"POST"},
            {~":scheme", ~"https"},
            {~":authority", ~"x"},
            {~":path", ~"/"},
            {~"content-length", ~"5"}
        ],
        Enc
    ),
    HpackBin = iolist_to_binary(Hpack),
    H = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04, undefined, HpackBin})
    ),
    serve_recv(ConnPid, H),
    %% Send 3-byte body with END_STREAM.
    Data = <<3:24, 0, 1, 0:1, 1:31, "abc">>,
    serve_recv(ConnPid, Data),
    Out = expect_send(),
    ?assertMatch(<<_:24, 3, _/binary>>, Out),
    cleanup(Pid, Ref).

request_trailers_dispatched() ->
    %% HEADERS (no END_STREAM) → DATA (no END_STREAM) → HEADERS
    %% (END_STREAM). Server treats the second HEADERS as trailers
    %% and dispatches the request.
    {Pid, Ref, ConnPid} = post_handshake_handler(roadrunner_h2_test_handler),
    HpackBin = encode_post_root_headers(),
    H1 = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04, undefined, HpackBin})
    ),
    serve_recv(ConnPid, H1),
    D = <<5:24, 0, 0, 0:1, 1:31, "hello">>,
    serve_recv(ConnPid, D),
    %% Encode a trailer header block separately.
    Enc = roadrunner_http2_hpack:new_encoder(4096),
    {Trailer, _} = roadrunner_http2_hpack:encode([{~"x-trace", ~"abc"}], Enc),
    TrailerBin = iolist_to_binary(Trailer),
    H2 = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04 bor 16#01, undefined, TrailerBin})
    ),
    serve_recv(ConnPid, H2),
    %% Drain whatever the response was; just confirm the conn
    %% didn't GOAWAY.
    _ = expect_send(),
    cleanup(Pid, Ref).

request_trailers_via_continuation() ->
    %% Trailer block split across HEADERS + CONTINUATION (both
    %% within the trailer-fragment phase).
    {Pid, Ref, ConnPid} = post_handshake_handler(roadrunner_h2_test_handler),
    HpackBin = encode_post_root_headers(),
    H1 = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04, undefined, HpackBin})
    ),
    serve_recv(ConnPid, H1),
    D = <<5:24, 0, 0, 0:1, 1:31, "hello">>,
    serve_recv(ConnPid, D),
    Enc = roadrunner_http2_hpack:new_encoder(4096),
    {Trailer, _} = roadrunner_http2_hpack:encode([{~"x-trace", ~"abc"}], Enc),
    TrailerBin = iolist_to_binary(Trailer),
    %% Split trailer block in two halves.
    HalfLen = byte_size(TrailerBin) div 2,
    <<TrFirst:HalfLen/binary, TrRest/binary>> = TrailerBin,
    %% First HEADERS: END_STREAM, no END_HEADERS.
    H2 = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#01, undefined, TrFirst})
    ),
    serve_recv(ConnPid, H2),
    %% CONTINUATION with END_HEADERS.
    C = iolist_to_binary(
        roadrunner_http2_frame:encode({continuation, 1, 16#04, TrRest})
    ),
    serve_recv(ConnPid, C),
    _ = expect_send(),
    cleanup(Pid, Ref).

awaiting_continuation_blocks_other_frames() ->
    %% HEADERS without END_HEADERS — server expects CONTINUATION
    %% next. Sending PRIORITY instead is PROTOCOL_ERROR (RFC §6.10).
    {Pid, Ref, ConnPid} = post_handshake_conn(),
    HpackBin = encode_post_root_headers(),
    %% HEADERS no END_HEADERS, no END_STREAM.
    H = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 0, undefined, HpackBin})
    ),
    serve_recv(ConnPid, H),
    Pri = iolist_to_binary(
        roadrunner_http2_frame:encode(
            {priority, 1, #{exclusive => false, stream_dependency => 0, weight => 0}}
        )
    ),
    serve_recv(ConnPid, Pri),
    Goaway = expect_send(),
    ?assertMatch(<<0, 0, 8, 7, _/binary>>, Goaway),
    expect_close(),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 500 -> error(no_exit)
    end.

unknown_frame_silently_ignored() ->
    %% Unknown frame type 99 mid-conn — silently ignored (RFC §4.1).
    {Pid, Ref, ConnPid} = post_handshake_conn(),
    serve_recv(ConnPid, <<0:24, 99, 0, 0:32>>),
    %% Sync via PING-ACK to confirm conn still alive + processed.
    Ping = iolist_to_binary(roadrunner_http2_frame:encode({ping, 0, <<0:64>>})),
    serve_recv(ConnPid, Ping),
    PingAck = expect_send(),
    ?assertMatch(<<_:24, 6, 1, _/binary>>, PingAck),
    cleanup(Pid, Ref).

rst_stream_on_idle_stream_protocol_error() ->
    {Pid, Ref, ConnPid} = post_handshake_conn(),
    Rst = iolist_to_binary(roadrunner_http2_frame:encode({rst_stream, 99, cancel})),
    serve_recv(ConnPid, Rst),
    Goaway = expect_send(),
    ?assertMatch(<<0, 0, 8, 7, _/binary>>, Goaway),
    expect_close(),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 500 -> error(no_exit)
    end.

window_update_on_idle_stream_protocol_error() ->
    {Pid, Ref, ConnPid} = post_handshake_conn(),
    Wu = iolist_to_binary(roadrunner_http2_frame:encode({window_update, 99, 1024})),
    serve_recv(ConnPid, Wu),
    Goaway = expect_send(),
    ?assertMatch(<<0, 0, 8, 7, _/binary>>, Goaway),
    expect_close(),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 500 -> error(no_exit)
    end.

window_update_on_closed_stream_ignored() ->
    %% WU on a stream id we previously closed (id <= last_stream_id,
    %% not in map) is silently ignored per RFC 9113 §6.9.
    {Pid, Ref, ConnPid} = post_handshake_conn(),
    HpackBin = encode_post_root_headers(),
    H = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04, undefined, HpackBin})
    ),
    serve_recv(ConnPid, H),
    Rst = iolist_to_binary(roadrunner_http2_frame:encode({rst_stream, 1, cancel})),
    serve_recv(ConnPid, Rst),
    Wu = iolist_to_binary(roadrunner_http2_frame:encode({window_update, 1, 1024})),
    serve_recv(ConnPid, Wu),
    %% Sync via PING-ACK to confirm processing order.
    Ping = iolist_to_binary(roadrunner_http2_frame:encode({ping, 0, <<0:64>>})),
    serve_recv(ConnPid, Ping),
    PingAck = expect_send(),
    ?assertMatch(<<_:24, 6, 1, _/binary>>, PingAck),
    cleanup(Pid, Ref).

unsolicited_continuation_protocol_error() ->
    %% CONTINUATION arriving with no in-flight HEADERS block is a
    %% PROTOCOL_ERROR per RFC 9113 §6.10.
    {Pid, Ref, ConnPid} = post_handshake_conn(),
    Cont = iolist_to_binary(
        roadrunner_http2_frame:encode({continuation, 1, 16#04, <<>>})
    ),
    serve_recv(ConnPid, Cont),
    Goaway = expect_send(),
    ?assertMatch(<<0, 0, 8, 7, _/binary>>, Goaway),
    expect_close(),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 500 -> error(no_exit)
    end.

trailers_with_malformed_hpack_goaway() ->
    %% Trailer block fails to decode → connection error
    %% (PROTOCOL_ERROR via finalize_trailers).
    {Pid, Ref, ConnPid} = post_handshake_conn(),
    HpackBin = encode_post_root_headers(),
    H1 = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04, undefined, HpackBin})
    ),
    serve_recv(ConnPid, H1),
    %% Garbage HPACK block as the trailer payload.
    H2 = iolist_to_binary(
        roadrunner_http2_frame:encode(
            {headers, 1, 16#04 bor 16#01, undefined, <<16#FF, 16#FF, 16#FF>>}
        )
    ),
    serve_recv(ConnPid, H2),
    Goaway = expect_send(),
    ?assertMatch(<<0, 0, 8, 7, _/binary>>, Goaway),
    expect_close(),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 500 -> error(no_exit)
    end.

content_length_match_dispatches() ->
    %% content-length matches body bytes — request dispatches normally.
    {Pid, Ref, ConnPid} = post_handshake_handler(roadrunner_h2_test_handler),
    Enc = roadrunner_http2_hpack:new_encoder(4096),
    {Hpack, _} = roadrunner_http2_hpack:encode(
        [
            {~":method", ~"POST"},
            {~":scheme", ~"https"},
            {~":authority", ~"x"},
            {~":path", ~"/"},
            {~"content-length", ~"5"}
        ],
        Enc
    ),
    HpackBin = iolist_to_binary(Hpack),
    H = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04, undefined, HpackBin})
    ),
    serve_recv(ConnPid, H),
    %% 5-byte body with END_STREAM.
    Data = <<5:24, 0, 1, 0:1, 1:31, "abcde">>,
    serve_recv(ConnPid, Data),
    %% Server replies — confirms dispatch happened.
    _ = expect_send(),
    cleanup(Pid, Ref).

content_length_non_integer_rst_stream() ->
    %% Non-integer content-length → RST_STREAM(PROTOCOL_ERROR).
    {Pid, Ref, ConnPid} = post_handshake_handler(roadrunner_h2_test_handler),
    Enc = roadrunner_http2_hpack:new_encoder(4096),
    {Hpack, _} = roadrunner_http2_hpack:encode(
        [
            {~":method", ~"POST"},
            {~":scheme", ~"https"},
            {~":authority", ~"x"},
            {~":path", ~"/"},
            {~"content-length", ~"banana"}
        ],
        Enc
    ),
    HpackBin = iolist_to_binary(Hpack),
    H = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04 bor 16#01, undefined, HpackBin})
    ),
    serve_recv(ConnPid, H),
    Out = expect_send(),
    ?assertMatch(<<_:24, 3, _/binary>>, Out),
    cleanup(Pid, Ref).

hpack_table_size_update_after_block_goaway() ->
    %% RFC 7541 §4.2: a Dynamic Table Size Update only at the
    %% beginning of a header block. A block that decodes a literal
    %% then attempts a table-size update is a COMPRESSION_ERROR.
    {Pid, Ref, ConnPid} = post_handshake_conn(),
    %% Build manually: 1 indexed-pseudo (`:method GET` = idx 2) =
    %% 0x82, then a 0x20 (Dynamic Table Size Update of 0).
    %% That gets us a header reps then an update — should error.
    %% But indexed alone isn't enough to dispatch; we need a valid
    %% pseudo set. Easier: encode a valid request, then append
    %% a table-size-update byte. Decoder rejects on the trailing
    %% update.
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
    Bad = <<HpackBin/binary, 16#20>>,
    H = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04 bor 16#01, undefined, Bad})
    ),
    serve_recv(ConnPid, H),
    Goaway = expect_send(),
    ?assertMatch(<<0, 0, 8, 7, _/binary>>, Goaway),
    expect_close(),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 500 -> error(no_exit)
    end.

headers_for_closed_stream_protocol_error() ->
    %% Open + complete stream 1 (handler runs, worker exits, stream
    %% removed from map). Then HEADERS for stream 1 — id <=
    %% last_stream_id, not in map → connection error PROTOCOL_ERROR.
    {Pid, Ref, ConnPid} = post_handshake_handler(roadrunner_h2_test_handler),
    Enc = roadrunner_http2_hpack:new_encoder(4096),
    {Hpack, _} = roadrunner_http2_hpack:encode(
        [
            {~":method", ~"GET"},
            {~":scheme", ~"https"},
            {~":authority", ~"x"},
            {~":path", ~"/empty"}
        ],
        Enc
    ),
    HpackBin = iolist_to_binary(Hpack),
    H1 = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04 bor 16#01, undefined, HpackBin})
    ),
    serve_recv(ConnPid, H1),
    %% Drain the response so the worker finishes + cleans up.
    _ = expect_send(),
    timer:sleep(50),
    drain_send(50),
    %% Now send HEADERS for stream id 1 again — closed.
    H1Again = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04 bor 16#01, undefined, HpackBin})
    ),
    serve_recv(ConnPid, H1Again),
    Goaway = expect_send(),
    ?assertMatch(<<0, 0, 8, 7, _/binary>>, Goaway),
    expect_close(),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 500 -> error(no_exit)
    end.

settings_initial_window_size_shifts_stream_window() ->
    %% Open a stream, then SETTINGS with a new INITIAL_WINDOW_SIZE
    %% mixed with an unrelated setting id (3, MAX_CONCURRENT_STREAMS)
    %% so `last_setting/3` walks past a non-id-4 entry before
    %% finding the value we care about. No overflow → server
    %% applies the shift and ACKs. Sync via PING-ACK to confirm
    %% processing order.
    {Pid, Ref, ConnPid} = post_handshake_conn(),
    HpackBin = encode_post_root_headers(),
    H = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04, undefined, HpackBin})
    ),
    serve_recv(ConnPid, H),
    Settings = iolist_to_binary(
        roadrunner_http2_frame:encode({settings, 0, [{3, 100}, {4, 32768}]})
    ),
    serve_recv(ConnPid, Settings),
    SettingsAck = expect_send(),
    ?assertMatch(<<_:24, 4, 1, _/binary>>, SettingsAck),
    Ping = iolist_to_binary(roadrunner_http2_frame:encode({ping, 0, <<0:64>>})),
    serve_recv(ConnPid, Ping),
    PingAck = expect_send(),
    ?assertMatch(<<_:24, 6, 1, _/binary>>, PingAck),
    cleanup(Pid, Ref).

content_length_multi_valued_rst_stream() ->
    %% Two `content-length` headers on the request — content_length_matches
    %% rejects with the multi-valued branch.
    {Pid, Ref, ConnPid} = post_handshake_handler(roadrunner_h2_test_handler),
    Enc = roadrunner_http2_hpack:new_encoder(4096),
    {Hpack, _} = roadrunner_http2_hpack:encode(
        [
            {~":method", ~"POST"},
            {~":scheme", ~"https"},
            {~":authority", ~"x"},
            {~":path", ~"/"},
            {~"content-length", ~"5"},
            {~"content-length", ~"7"}
        ],
        Enc
    ),
    HpackBin = iolist_to_binary(Hpack),
    H = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04 bor 16#01, undefined, HpackBin})
    ),
    serve_recv(ConnPid, H),
    Out = expect_send(),
    ?assertMatch(<<_:24, 3, _/binary>>, Out),
    cleanup(Pid, Ref).

trailers_after_first_end_stream_protocol_error() ->
    %% Stream's `end_stream_seen` is set on the first HEADERS+END_STREAM,
    %% the worker is dispatched but might still be running. A second
    %% HEADERS arriving in that window hits `is_trailer_block` and
    %% sees end_stream_seen=true → not a valid trailer → goaway.
    %% Use the slow handler so the worker is guaranteed alive when
    %% the second HEADERS arrives.
    {Pid, Ref, ConnPid} = post_handshake_handler(roadrunner_h2_test_handler),
    Enc = roadrunner_http2_hpack:new_encoder(4096),
    {Hpack, _} = roadrunner_http2_hpack:encode(
        [
            {~":method", ~"GET"},
            {~":scheme", ~"https"},
            {~":authority", ~"x"},
            {~":path", ~"/stream/slow"}
        ],
        Enc
    ),
    HpackBin = iolist_to_binary(Hpack),
    H1 = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04 bor 16#01, undefined, HpackBin})
    ),
    serve_recv(ConnPid, H1),
    %% Worker spawned, sleeping. Drain the initial HEADERS+DATA it emits.
    timer:sleep(50),
    drain_send(50),
    drain_send(50),
    %% Second HEADERS for the same in-flight stream — invalid.
    H2 = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04 bor 16#01, undefined, HpackBin})
    ),
    serve_recv(ConnPid, H2),
    %% Eventually GOAWAY after pending sends drain.
    drain_until_goaway(),
    cleanup(Pid, Ref).

drain_until_goaway() ->
    receive
        {roadrunner_fake_send, _, Data} ->
            case iolist_to_binary(Data) of
                <<_:24, 7, _/binary>> -> ok;
                _ -> drain_until_goaway()
            end
    after 500 -> error(no_goaway)
    end.

%% Common pre-test scaffolding: spawn a conn, run the handshake,
%% return the handles so the test can drive whatever frame it
%% wants next.
post_handshake_conn() ->
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    {Pid, Ref, ConnPid} = start_http2_conn(),
    _ = expect_send(),
    serve_recv(ConnPid, ?PREFACE),
    serve_recv(ConnPid, ?EMPTY_SETTINGS_FRAME),
    _ = expect_send(),
    {Pid, Ref, ConnPid}.

post_handshake_handler(Handler) ->
    {ok, _} = application:ensure_all_started(telemetry),
    drain_mailbox(),
    Self = self(),
    Counter = atomics:new(1, [{signed, false}]),
    ok = atomics:add(Counter, 1, 1),
    ProtoOpts = #{
        client_counter => Counter,
        listener_name => h2_strict_test,
        dispatch => {handler, Handler},
        middlewares => []
    },
    Sock = {fake, Self},
    Pid = spawn(fun() ->
        receive
            ready -> ok
        end,
        roadrunner_conn_loop_http2:enter(
            Sock, ProtoOpts, h2_strict_test, undefined, erlang:monotonic_time()
        )
    end),
    Ref = monitor(process, Pid),
    Pid ! ready,
    _ = expect_send(),
    serve_recv(Pid, ?PREFACE),
    serve_recv(Pid, ?EMPTY_SETTINGS_FRAME),
    _ = expect_send(),
    {Pid, Ref, Pid}.

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

%% Spin-wait for a registered name to appear. Used by tests where
%% the handler registers itself inside `handle/1`; without the wait,
%% the test races with the worker's spawn and `Name ! Msg` crashes
%% with `badarg`.
wait_for_register(_Name, RemainingMs) when RemainingMs =< 0 ->
    error({wait_for_register_timeout, _Name});
wait_for_register(Name, RemainingMs) ->
    case whereis(Name) of
        undefined ->
            Step = 10,
            timer:sleep(Step),
            wait_for_register(Name, RemainingMs - Step);
        Pid ->
            Pid
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
