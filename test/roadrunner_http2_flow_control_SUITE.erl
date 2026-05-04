-module(roadrunner_http2_flow_control_SUITE).
-moduledoc """
HTTP/2 flow-control tests (Phase H6, RFC 9113 §5.2 / §6.9).

These tests drive the conn process via the `{fake, Pid}` transport
and exchange WINDOW_UPDATE frames to exercise the send-window
back-pressure + recv-window refill paths in
`roadrunner_conn_loop_http2`.

Lives as a CT suite (rather than an eunit module) so each
testcase runs in its own process with proper init/end fixtures —
eunit's shared test process leaked `roadrunner_fake_*` messages
between this module and `roadrunner_transport_tests` because the
H2 conn could survive the eunit test child long enough for its
queued sends to land in another module's mailbox after pid
reuse / scheduling races.
""".

-include_lib("common_test/include/ct.hrl").

-export([suite/0, all/0, init_per_testcase/2, end_per_testcase/2]).
-export([
    conn_window_update_overflow_triggers_goaway/1,
    stream_window_update_overflow_triggers_rst_stream/1,
    window_update_for_unknown_stream_ignored/1,
    stream_window_update_grows_send_window/1,
    large_response_chunks_through_send_window/1,
    large_response_blocked_resumes_on_window_update/1,
    large_inbound_body_refills_recv_windows/1,
    rst_stream_during_blocked_send_drops_body/1,
    ping_during_blocked_send_is_acked/1,
    settings_during_blocked_send_is_acked/1,
    priority_during_blocked_send_is_ignored/1,
    conn_window_update_overflow_during_blocked_send/1,
    stream_window_update_overflow_during_blocked_send/1,
    blocked_send_recv_error_exits_clean/1,
    blocked_send_garbage_frame_triggers_goaway/1,
    blocked_send_peer_closes_exits_clean/1,
    blocked_send_idle_timeout_emits_goaway/1
]).

-define(PREFACE, ~"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n").
-define(EMPTY_SETTINGS_FRAME, <<0:24, 4, 0, 0:32>>).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        conn_window_update_overflow_triggers_goaway,
        stream_window_update_overflow_triggers_rst_stream,
        window_update_for_unknown_stream_ignored,
        stream_window_update_grows_send_window,
        large_response_chunks_through_send_window,
        large_response_blocked_resumes_on_window_update,
        large_inbound_body_refills_recv_windows,
        rst_stream_during_blocked_send_drops_body,
        ping_during_blocked_send_is_acked,
        settings_during_blocked_send_is_acked,
        priority_during_blocked_send_is_ignored,
        conn_window_update_overflow_during_blocked_send,
        stream_window_update_overflow_during_blocked_send,
        blocked_send_recv_error_exits_clean,
        blocked_send_garbage_frame_triggers_goaway,
        blocked_send_peer_closes_exits_clean,
        blocked_send_idle_timeout_emits_goaway
    ].

init_per_testcase(_Case, Config) ->
    {ok, _} = application:ensure_all_started(telemetry),
    Config.

end_per_testcase(_Case, _Config) ->
    ok.

%% =============================================================================
%% Cases
%% =============================================================================

conn_window_update_overflow_triggers_goaway(_Config) ->
    %% A WINDOW_UPDATE that brings the conn-level send window above
    %% 2^31-1 is FLOW_CONTROL_ERROR per RFC 9113 §6.9.1.
    {Pid, Ref, ConnPid} = start_conn(roadrunner_hello_handler),
    handshake(ConnPid),
    Inc = 16#7FFFFFFF - 65535 + 1,
    Wu = encode_frame({window_update, 0, Inc}),
    serve_recv(ConnPid, Wu),
    expect_send_type(7),
    expect_close(),
    wait_down(Pid, Ref).

stream_window_update_overflow_triggers_rst_stream(_Config) ->
    %% RFC 9113 §6.9.1: stream-level WINDOW_UPDATE overflow is a
    %% stream error, not a connection error — RST_STREAM(FLOW_CONTROL_ERROR).
    {Pid, Ref, ConnPid} = start_conn(roadrunner_hello_handler),
    handshake(ConnPid),
    HpackBin = encode_request_headers(~"POST", ~"/"),
    Hf = encode_frame({headers, 1, 16#04, undefined, HpackBin}),
    serve_recv(ConnPid, Hf),
    Inc = 16#7FFFFFFF - 65535 + 1,
    Wu = encode_frame({window_update, 1, Inc}),
    serve_recv(ConnPid, Wu),
    expect_send_type(3),
    %% Conn stays alive — only the stream was reset.
    true = is_process_alive(Pid),
    cleanup(Pid, Ref).

window_update_for_unknown_stream_ignored(_Config) ->
    %% WINDOW_UPDATE for a stream that's not currently open is
    %% silently dropped (closed-stream legality per RFC 9113 §6.9).
    {Pid, Ref, ConnPid} = start_conn(roadrunner_hello_handler),
    handshake(ConnPid),
    Wu = encode_frame({window_update, 99, 1024}),
    serve_recv(ConnPid, Wu),
    true = is_process_alive(Pid),
    cleanup(Pid, Ref).

stream_window_update_grows_send_window(_Config) ->
    %% Open stream 1, send a normal-magnitude WINDOW_UPDATE that
    %% grows the stream send window without overflowing.
    {Pid, Ref, ConnPid} = start_conn(roadrunner_hello_handler),
    handshake(ConnPid),
    HpackBin = encode_request_headers(~"POST", ~"/"),
    Hf = encode_frame({headers, 1, 16#04, undefined, HpackBin}),
    serve_recv(ConnPid, Hf),
    Wu = encode_frame({window_update, 1, 1024}),
    serve_recv(ConnPid, Wu),
    true = is_process_alive(Pid),
    cleanup(Pid, Ref).

large_response_chunks_through_send_window(_Config) ->
    %% 50 KB body fits in default 65535-byte window but exceeds
    %% MAX_FRAME_SIZE (16384), so the server emits multiple DATA
    %% frames.
    {Pid, Ref, ConnPid} = start_conn(roadrunner_h2_test_handler),
    handshake(ConnPid),
    HpackBin = encode_request_headers(~"GET", ~"/large50k"),
    Hf = encode_frame({headers, 1, 16#04 bor 16#01, undefined, HpackBin}),
    serve_recv(ConnPid, Hf),
    %% Drain at least 50 KB + headers.
    drain_until_n_bytes(50_000),
    cleanup(Pid, Ref).

large_response_blocked_resumes_on_window_update(_Config) ->
    %% 100 KB body exceeds the default 65535-byte connection window,
    %% so the server stalls. We unblock with WINDOW_UPDATE frames
    %% on conn + stream and the response completes.
    {Pid, Ref, ConnPid} = start_conn(roadrunner_h2_test_handler),
    handshake(ConnPid),
    HpackBin = encode_request_headers(~"GET", ~"/large100k"),
    Hf = encode_frame({headers, 1, 16#04 bor 16#01, undefined, HpackBin}),
    serve_recv(ConnPid, Hf),
    drain_until_n_bytes(60_000),
    Wu = encode_frame({window_update, 0, 200_000}),
    serve_recv(ConnPid, Wu),
    Wu2 = encode_frame({window_update, 1, 200_000}),
    serve_recv(ConnPid, Wu2),
    drain_until_n_bytes(40_000),
    cleanup(Pid, Ref).

large_inbound_body_refills_recv_windows(_Config) ->
    %% Sending 4 × 10 KB DATA frames drops both recv windows below
    %% the refill threshold; the server emits two WINDOW_UPDATE
    %% frames (conn + stream).
    {Pid, Ref, ConnPid} = start_conn(roadrunner_hello_handler),
    handshake(ConnPid),
    HpackBin = encode_request_headers(~"POST", ~"/"),
    Hf = encode_frame({headers, 1, 16#04, undefined, HpackBin}),
    serve_recv(ConnPid, Hf),
    Chunk = binary:copy(<<"x">>, 10_000),
    [
        serve_recv(ConnPid, encode_frame({data, 1, 0, Chunk}))
     || _ <- lists:seq(1, 4)
    ],
    Out1 = expect_send(),
    Out2 = expect_send(),
    %% Both must be type-8 (WINDOW_UPDATE) — type byte at offset 3.
    <<_:24, 8, _/binary>> = Out1,
    <<_:24, 8, _/binary>> = Out2,
    cleanup(Pid, Ref).

rst_stream_during_blocked_send_drops_body(_Config) ->
    %% Stall a response on flow control, then RST_STREAM the active
    %% stream — the server must drop the pending body and resume
    %% the main loop.
    {Pid, Ref, ConnPid} = setup_blocked_send(),
    Rst = encode_frame({rst_stream, 1, cancel}),
    serve_recv(ConnPid, Rst),
    true = is_process_alive(Pid),
    cleanup(Pid, Ref).

ping_during_blocked_send_is_acked(_Config) ->
    {Pid, Ref, ConnPid} = setup_blocked_send(),
    Ping = encode_frame({ping, 0, <<1:64>>}),
    serve_recv(ConnPid, Ping),
    expect_send_ack(6),
    %% Unstall.
    Wu = encode_frame({window_update, 0, 200_000}),
    serve_recv(ConnPid, Wu),
    Wu2 = encode_frame({window_update, 1, 200_000}),
    serve_recv(ConnPid, Wu2),
    drain_until_n_bytes(40_000),
    cleanup(Pid, Ref).

settings_during_blocked_send_is_acked(_Config) ->
    {Pid, Ref, ConnPid} = setup_blocked_send(),
    Settings = encode_frame({settings, 0, []}),
    serve_recv(ConnPid, Settings),
    expect_send_ack(4),
    Wu = encode_frame({window_update, 0, 200_000}),
    serve_recv(ConnPid, Wu),
    Wu2 = encode_frame({window_update, 1, 200_000}),
    serve_recv(ConnPid, Wu2),
    drain_until_n_bytes(40_000),
    cleanup(Pid, Ref).

priority_during_blocked_send_is_ignored(_Config) ->
    %% PRIORITY arriving while we're stalled on flow control hits
    %% the catch-all `_Frame` clause in `handle_frame_during_send/3`
    %% — it's silently ignored and we keep waiting.
    {Pid, Ref, ConnPid} = setup_blocked_send(),
    Pri = encode_frame(
        {priority, 1, #{exclusive => false, stream_dependency => 0, weight => 1}}
    ),
    serve_recv(ConnPid, Pri),
    %% Conn still alive, still waiting.
    true = is_process_alive(Pid),
    %% Unstall.
    Wu = encode_frame({window_update, 0, 200_000}),
    serve_recv(ConnPid, Wu),
    Wu2 = encode_frame({window_update, 1, 200_000}),
    serve_recv(ConnPid, Wu2),
    drain_until_n_bytes(40_000),
    cleanup(Pid, Ref).

conn_window_update_overflow_during_blocked_send(_Config) ->
    %% Both send-windows sit at exactly 0 when stalled, so a single
    %% 2^31-1 increment lands AT the cap (not over). We grow the
    %% conn-level window first (keeping the stream window at 0 so
    %% the conn stays stalled — `min(conn, stream)` is still 0),
    %% then send a 2^31-1 WU which now overflows past MAX.
    {Pid, Ref, ConnPid} = setup_blocked_send(),
    drain_all_sends(),
    Wu1 = encode_frame({window_update, 0, 1}),
    serve_recv(ConnPid, Wu1),
    Wu2 = encode_frame({window_update, 0, 16#7FFFFFFF}),
    serve_recv(ConnPid, Wu2),
    expect_send_type(7),
    expect_close(),
    wait_down(Pid, Ref).

stream_window_update_overflow_during_blocked_send(_Config) ->
    %% Stream-level overflow during a blocked send is a stream
    %% error (RST_STREAM), not a connection error — the conn
    %% stays alive after the offending stream is dropped.
    {Pid, Ref, ConnPid} = setup_blocked_send(),
    drain_all_sends(),
    Wu1 = encode_frame({window_update, 1, 1}),
    serve_recv(ConnPid, Wu1),
    Wu2 = encode_frame({window_update, 1, 16#7FFFFFFF}),
    serve_recv(ConnPid, Wu2),
    expect_send_type(3),
    true = is_process_alive(Pid),
    cleanup(Pid, Ref).

blocked_send_recv_error_exits_clean(_Config) ->
    %% While stalled mid-response, the transport raises an error.
    %% The server should send GOAWAY and exit cleanly.
    {Pid, Ref, ConnPid} = setup_blocked_send(),
    ConnPid ! {roadrunner_fake_error, {fake, self()}, closed},
    expect_send_type(7),
    expect_close(),
    wait_down(Pid, Ref).

blocked_send_garbage_frame_triggers_goaway(_Config) ->
    %% Malformed RST_STREAM (5-byte payload, must be 4) during a
    %% blocked send — frame parse rejects with a real error and
    %% the conn GOAWAYs.
    {Pid, Ref, ConnPid} = setup_blocked_send(),
    drain_all_sends(),
    serve_recv(ConnPid, <<0, 0, 5, 3, 0, 0:32, 0:32, 0>>),
    expect_send_type(7),
    expect_close(),
    wait_down(Pid, Ref).

blocked_send_peer_closes_exits_clean(_Config) ->
    %% Peer half-closes during a stalled send — `recv_more_during_send`
    %% takes the `{MClosed, _}` arm and exits without GOAWAY.
    {Pid, Ref, ConnPid} = setup_blocked_send(),
    ConnPid ! {roadrunner_fake_closed, {fake, self()}},
    expect_close(),
    wait_down(Pid, Ref).

blocked_send_idle_timeout_emits_goaway(_Config) ->
    %% Stalled-send waits past the idle deadline. `idle_timeout()`
    %% is evaluated at receive entry, so we lower the deadline
    %% AFTER the body drain finishes and then poke the conn with
    %% an unknown-stream WINDOW_UPDATE — that's silently ignored
    %% by `handle_frame_during_send/4` and forces a re-entry into
    %% `recv_more_during_send/3`, which reads the new 100-ms
    %% timeout and fires shortly after.
    {Pid, Ref, ConnPid} = setup_blocked_send(),
    drain_all_sends(),
    persistent_term:put({roadrunner_conn_loop_http2, idle_timeout}, 100),
    try
        Wu = encode_frame({window_update, 99, 1024}),
        serve_recv(ConnPid, Wu),
        expect_send_type(7),
        expect_close(),
        wait_down(Pid, Ref)
    after
        persistent_term:erase({roadrunner_conn_loop_http2, idle_timeout})
    end.

%% =============================================================================
%% Helpers
%% =============================================================================

%% Spawn an h2 conn with `Handler` as the dispatch target. Returns
%% `{Pid, Ref, ConnPid}` — for the fake-socket pattern, `Pid` and
%% `ConnPid` are the same process; the duplication mirrors the
%% eunit suite's API for symmetry.
start_conn(Handler) ->
    Self = self(),
    Counter = atomics:new(1, [{signed, false}]),
    ok = atomics:add(Counter, 1, 1),
    ProtoOpts = #{
        client_counter => Counter,
        listener_name => h2_flow_test,
        dispatch => {handler, Handler},
        middlewares => []
    },
    Sock = {fake, Self},
    Pid = spawn(fun() ->
        receive
            ready -> ok
        end,
        roadrunner_conn_loop_http2:enter(
            Sock, ProtoOpts, h2_flow_test, undefined, erlang:monotonic_time()
        )
    end),
    Ref = monitor(process, Pid),
    Pid ! ready,
    {Pid, Ref, Pid}.

handshake(ConnPid) ->
    _ = expect_send(),
    serve_recv(ConnPid, ?PREFACE),
    serve_recv(ConnPid, ?EMPTY_SETTINGS_FRAME),
    _ = expect_send(),
    ok.

%% Build an HPACK-encoded request header block.
encode_request_headers(Method, Path) ->
    Enc = roadrunner_http2_hpack:new_encoder(4096),
    {Hpack, _} = roadrunner_http2_hpack:encode(
        [
            {~":method", Method},
            {~":scheme", ~"https"},
            {~":authority", ~"localhost"},
            {~":path", Path}
        ],
        Enc
    ),
    iolist_to_binary(Hpack).

encode_frame(Frame) ->
    iolist_to_binary(roadrunner_http2_frame:encode(Frame)).

%% Set up a stream that's mid-response and stalled on flow control.
setup_blocked_send() ->
    {Pid, Ref, ConnPid} = start_conn(roadrunner_h2_test_handler),
    handshake(ConnPid),
    HpackBin = encode_request_headers(~"GET", ~"/large100k"),
    Hf = encode_frame({headers, 1, 16#04 bor 16#01, undefined, HpackBin}),
    serve_recv(ConnPid, Hf),
    drain_until_n_bytes(60_000),
    {Pid, Ref, ConnPid}.

cleanup(Pid, Ref) ->
    %% Synchronous kill — wait for the conn process to fully exit
    %% before this case returns. CT runs each case in its own
    %% process, but we still keep the assertion strict.
    exit(Pid, kill),
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    end.

wait_down(Pid, Ref) ->
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    after 500 -> ct:fail(no_exit)
    end.

expect_send() ->
    receive
        {roadrunner_fake_send, _Pid, Data} -> iolist_to_binary(Data)
    after 1000 -> ct:fail(no_send)
    end.

%% Assert the next send is a frame of the given type byte. Type is
%% at byte offset 3 (after 24-bit length).
expect_send_type(Type) ->
    Bytes = expect_send(),
    case Bytes of
        <<_:24, T, _/binary>> when T =:= Type -> Bytes;
        _ -> ct:fail({wrong_frame_type, expected, Type, got, Bytes})
    end.

%% Assert the next send is an ACK frame of the given type (PING ACK
%% or SETTINGS ACK) — type at byte 3, ACK flag (0x01) at byte 4.
expect_send_ack(Type) ->
    Bytes = expect_send(),
    case Bytes of
        <<_:24, T, F, _/binary>> when T =:= Type, (F band 16#01) =/= 0 -> Bytes;
        _ -> ct:fail({wrong_ack, expected, Type, got, Bytes})
    end.

expect_close() ->
    receive
        {roadrunner_fake_close, _Pid} -> ok
    after 1000 -> ct:fail(no_close)
    end.

%% Drain all pending fake_send messages until a 200ms quiet period.
drain_all_sends() ->
    receive
        {roadrunner_fake_send, _Pid, _Data} -> drain_all_sends()
    after 200 -> ok
    end.

drain_until_n_bytes(Target) ->
    drain_until_n_bytes_loop(0, Target).

drain_until_n_bytes_loop(Got, Target) when Got >= Target ->
    ok;
drain_until_n_bytes_loop(Got, Target) ->
    receive
        {roadrunner_fake_send, _Pid, Data} ->
            drain_until_n_bytes_loop(Got + iolist_size(Data), Target)
    after 500 -> ok
    end.

%% After Phase H8a's switch to active-mode receive, the conn
%% process arms `[{active, once}]` between iterations and reads
%% bytes off its mailbox. We deliver wire bytes by sending a
%% `roadrunner_fake_data` message directly to the conn pid. The
%% old recv-request/reply pattern no longer fires.
serve_recv(ConnPid, Data) ->
    drain_setopts(),
    ConnPid ! {roadrunner_fake_data, {fake, self()}, iolist_to_binary([Data])},
    ok.

drain_setopts() ->
    receive
        {roadrunner_fake_setopts, _, _} -> drain_setopts()
    after 0 -> ok
    end.
