-module(roadrunner_ws_session_tests).

-include_lib("eunit/include/eunit.hrl").

%% `roadrunner_ws_session:run/4` must start the gen_statem **before** the
%% 101 upgrade response is written. If `gen_statem:start/3` fails
%% (here forced via an unknown handler module — `init/1` rejects it,
%% turning into `{error, _}` from start), the 101 must never reach
%% the wire and a 500 fallback must be sent instead.
run_with_unloadable_handler_sends_500_and_no_101_test() ->
    Tag = make_ref(),
    Self = self(),
    Sink = spawn_send_log_sink(Self, Tag),
    Headers = [
        {~"upgrade", ~"websocket"},
        {~"connection", ~"Upgrade"},
        {~"sec-websocket-key", ~"dGhlIHNhbXBsZSBub25jZQ=="},
        {~"sec-websocket-version", ~"13"}
    ],
    Req = #{
        headers => Headers,
        peer => undefined,
        listener_name => undefined,
        request_id => undefined
    },
    ok = roadrunner_ws_session:run(
        {fake, Sink}, Req, this_module_does_not_exist_xyz_42, undefined
    ),
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    Sink ! stop,
    ?assertEqual(nomatch, binary:match(Sent, ~"101")),
    ?assertNotEqual(nomatch, binary:match(Sent, ~"500")).

run_with_bad_handshake_still_returns_400_test() ->
    %% Regression check: bad handshake path is unchanged.
    Tag = make_ref(),
    Self = self(),
    Sink = spawn_send_log_sink(Self, Tag),
    Req = #{
        headers => [{~"host", ~"x"}],
        peer => undefined,
        listener_name => undefined,
        request_id => undefined
    },
    ok = roadrunner_ws_session:run({fake, Sink}, Req, roadrunner_ws_echo_handler, undefined),
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    Sink ! stop,
    ?assertNotEqual(nomatch, binary:match(Sent, ~"400")),
    ?assertEqual(nomatch, binary:match(Sent, ~"101")).

%% =============================================================================
%% Active-mode frame_loop — hibernate, transport error, and stray-info
%% paths. Drives the gen_statem directly (skipping the run/4 launcher)
%% with a script-driven fake sink that delivers `roadrunner_fake_data`
%% messages on `setopts({active, once})`.
%% =============================================================================

frame_loop_hibernates_when_handler_returns_hibernate_opt_test() ->
    %% Send a text frame; handler returns {reply, _, _, [hibernate]}.
    %% After processing the frame, the gen_statem must hibernate —
    %% verified via `process_info(Pid, status) =:= waiting` and
    %% `total_heap_size` shrunk to the OTP hibernation minimum
    %% (~233 words; we cap at 256 to absorb future drift).
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_active_sink(Self, Tag, [
        {recv, frame(text, ~"hello")}
    ]),
    {ok, Pid} = gen_statem:start(
        roadrunner_ws_session,
        {{fake, Sink}, roadrunner_ws_hibernate_handler, undefined, ws_ctx(), none},
        []
    ),
    Pid ! socket_ready,
    %% Wait for the echo reply to come back (= handler ran).
    Sent = iolist_to_binary(collect_sends(Tag, 200)),
    ?assertNotEqual(nomatch, binary:match(Sent, ~"hello")),
    %% Process must be hibernated.
    ?assert(is_hibernating(Pid, 200)),
    Sink ! stop,
    ok = gen_statem:stop(Pid).

frame_loop_hibernates_on_ok_opt_variant_test() ->
    %% Binary frame → {ok, _, [hibernate]} → no reply but hibernate.
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_active_sink(Self, Tag, [
        {recv, frame(binary, ~"data")}
    ]),
    {ok, Pid} = gen_statem:start(
        roadrunner_ws_session,
        {{fake, Sink}, roadrunner_ws_hibernate_handler, undefined, ws_ctx(), none},
        []
    ),
    Pid ! socket_ready,
    ?assert(is_hibernating(Pid, 500)),
    Sink ! stop,
    ok = gen_statem:stop(Pid).

frame_loop_no_hibernate_for_3_tuple_returns_test() ->
    %% Echo handler uses 3-tuple `{reply, _, _}`; without the opt the
    %% session must NOT hibernate.
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_active_sink(Self, Tag, [
        {recv, frame(text, ~"hello")}
    ]),
    {ok, Pid} = gen_statem:start(
        roadrunner_ws_session,
        {{fake, Sink}, roadrunner_ws_echo_handler, undefined, ws_ctx(), none},
        []
    ),
    Pid ! socket_ready,
    Sent = iolist_to_binary(collect_sends(Tag, 200)),
    ?assertNotEqual(nomatch, binary:match(Sent, ~"hello")),
    %% After echo, gen_statem is waiting for the next frame in active
    %% mode — but NOT hibernating. current_function should not be
    %% erlang:hibernate.
    timer:sleep(50),
    ?assertNotEqual({erlang, hibernate, 3}, current_function(Pid)),
    Sink ! stop,
    ok = gen_statem:stop(Pid).

frame_loop_stops_on_transport_error_event_test() ->
    %% A `{roadrunner_fake_error, _, _}` info event ends the session
    %% cleanly with `normal` exit (parity with `{tcp_error, _, _}`).
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_active_sink(Self, Tag, [{error, econnreset}]),
    {ok, Pid} = gen_statem:start(
        roadrunner_ws_session,
        {{fake, Sink}, roadrunner_ws_echo_handler, undefined, ws_ctx(), none},
        []
    ),
    Ref = monitor(process, Pid),
    Pid ! socket_ready,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 1000 -> error(no_normal_exit)
    end,
    Sink ! stop.

frame_loop_closed_after_partial_frame_stops_cleanly_test() ->
    %% A `roadrunner_fake_closed` arriving after a partial frame
    %% (parser sees `{more, _}`, re-arms setopts, then close fires)
    %% must terminate the session cleanly. Locks in the active-mode
    %% partial-then-close path.
    Self = self(),
    Tag = make_ref(),
    %% First chunk: 2 bytes of a frame header (parser returns {more, _}).
    %% Then close.
    Sink = spawn_active_sink(Self, Tag, [
        {recv, <<16#81, 16#80>>},
        {error, closed}
    ]),
    {ok, Pid} = gen_statem:start(
        roadrunner_ws_session,
        {{fake, Sink}, roadrunner_ws_echo_handler, undefined, ws_ctx(), none},
        []
    ),
    Ref = monitor(process, Pid),
    Pid ! socket_ready,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 1000 -> error(no_normal_exit)
    end,
    Sink ! stop.

frame_loop_setopts_error_stops_cleanly_test() ->
    %% If the kernel reports the socket as closed when re-arming
    %% (peer RST between events), `setopts/2` returns `{error, _}`.
    %% Pre-fix this badmatched and crashed; post-fix the session
    %% stops cleanly via `arm_or_stop/3` so terminate/3 still runs.
    %%
    %% Drive: spawn the gen_statem with a sink, kill the sink BEFORE
    %% sending socket_ready so frame_loop's state_enter `setopts`
    %% sees a dead-process socket and returns `{error, einval}`.
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_active_sink(Self, Tag, []),
    {ok, Pid} = gen_statem:start(
        roadrunner_ws_session,
        {{fake, Sink}, roadrunner_ws_echo_handler, undefined, ws_ctx(), none},
        []
    ),
    Ref = monitor(process, Pid),
    %% Kill the sink so the next `setopts` on `{fake, Sink}` returns
    %% an error.
    exit(Sink, kill),
    %% Wait for the sink to actually be dead.
    erlang:demonitor(monitor(process, Sink), [flush]),
    Pid ! socket_ready,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 1000 -> error(no_normal_exit)
    end.

frame_loop_processes_multiple_frames_in_one_chunk_test() ->
    %% Real `inet:setopts({active, once})` can deliver several
    %% complete frames in a single `{tcp, _, Bytes}` event when the
    %% kernel buffered them before we re-armed. `process_buffer/2`
    %% must drain ALL complete frames in one callback pass and
    %% reply to each, not just the first one. Verifies the inline
    %% recursive shape of process_buffer is correct under
    %% multi-frame buffering.
    Self = self(),
    Tag = make_ref(),
    %% One script item delivering two complete text frames
    %% concatenated. The echo handler replies to each.
    TwoFrames = <<(frame(text, ~"first"))/binary, (frame(text, ~"second"))/binary>>,
    Sink = spawn_active_sink(Self, Tag, [{recv, TwoFrames}]),
    {ok, Pid} = gen_statem:start(
        roadrunner_ws_session,
        {{fake, Sink}, roadrunner_ws_echo_handler, undefined, ws_ctx(), none},
        []
    ),
    Pid ! socket_ready,
    Sent = iolist_to_binary(collect_sends(Tag, 200)),
    %% Both frames echoed back — assert both payloads appear.
    ?assertNotEqual(nomatch, binary:match(Sent, ~"first")),
    ?assertNotEqual(nomatch, binary:match(Sent, ~"second")),
    Sink ! stop,
    ok = gen_statem:stop(Pid).

frame_loop_drops_unexpected_info_event_test() ->
    %% A stray info message that doesn't match any of the transport
    %% tags gets dropped and the session re-arms the socket; verified
    %% by the session still being alive afterwards.
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_active_sink(Self, Tag, []),
    {ok, Pid} = gen_statem:start(
        roadrunner_ws_session,
        {{fake, Sink}, roadrunner_ws_echo_handler, undefined, ws_ctx(), none},
        []
    ),
    Pid ! socket_ready,
    %% Let frame_loop arm the socket, then deliver a stray info.
    timer:sleep(20),
    Pid ! {stray, make_ref()},
    timer:sleep(20),
    ?assert(is_process_alive(Pid)),
    Sink ! stop,
    ok = gen_statem:stop(Pid).

%% =============================================================================
%% Optional callbacks: init/1 and handle_info/2 (arizona-compat)
%% =============================================================================

init_callback_runs_once_at_session_start_test() ->
    %% Handler exports `init/1`. It must run BEFORE the first frame
    %% arrives; verified by an `event init` arriving at the sink before
    %% any data is sent.
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_active_sink(Self, Tag, []),
    State = #{sink => Self, on_init => ok},
    {ok, Pid} = gen_statem:start(
        roadrunner_ws_session,
        {{fake, Sink}, roadrunner_ws_lifecycle_handler, State, ws_ctx(), none},
        []
    ),
    Pid ! socket_ready,
    receive
        {event, init} -> ok
    after 200 -> ?assert(false)
    end,
    ?assert(is_process_alive(Pid)),
    Sink ! stop,
    ok = gen_statem:stop(Pid).

init_callback_can_push_priming_frames_test() ->
    %% Handler returns `{reply, Frames, _}` from init — frames must
    %% reach the wire before the session reads any inbound bytes.
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_active_sink(Self, Tag, []),
    State = #{sink => Self, on_init => {reply, [{text, ~"snapshot"}]}},
    {ok, Pid} = gen_statem:start(
        roadrunner_ws_session,
        {{fake, Sink}, roadrunner_ws_lifecycle_handler, State, ws_ctx(), none},
        []
    ),
    Pid ! socket_ready,
    Sent = iolist_to_binary(collect_sends(Tag, 200)),
    ?assertNotEqual(nomatch, binary:match(Sent, ~"snapshot")),
    Sink ! stop,
    ok = gen_statem:stop(Pid).

init_callback_can_request_hibernate_test() ->
    %% Handler returns `{ok, _, [hibernate]}` from init — session must
    %% hibernate immediately after the transition to frame_loop.
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_active_sink(Self, Tag, []),
    State = #{sink => Self, on_init => ok_hibernate},
    {ok, Pid} = gen_statem:start(
        roadrunner_ws_session,
        {{fake, Sink}, roadrunner_ws_lifecycle_handler, State, ws_ctx(), none},
        []
    ),
    Pid ! socket_ready,
    receive
        {event, init} -> ok
    after 200 -> ?assert(false)
    end,
    ?assert(is_hibernating(Pid, 200)),
    Sink ! stop,
    ok = gen_statem:stop(Pid).

init_callback_close_terminates_session_test() ->
    %% Handler refuses the upgrade by returning `{close, _}` from init —
    %% session must send a close frame and stop normally.
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_active_sink(Self, Tag, []),
    State = #{sink => Self, on_init => close},
    {ok, Pid} = gen_statem:start(
        roadrunner_ws_session,
        {{fake, Sink}, roadrunner_ws_lifecycle_handler, State, ws_ctx(), none},
        []
    ),
    Ref = monitor(process, Pid),
    Pid ! socket_ready,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 500 -> ?assert(false)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 50)),
    %% A close frame is opcode 0x88 — first byte of the encoded frame.
    ?assertEqual(16#88, binary:first(Sent)),
    Sink ! stop.

handle_info_callback_forwards_stray_message_test() ->
    %% Handler exports `handle_info/2` and replies — a stray info
    %% message must reach the handler and produce wire output.
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_active_sink(Self, Tag, []),
    State = #{sink => Self, on_info => {reply, [{text, ~"forwarded"}]}},
    {ok, Pid} = gen_statem:start(
        roadrunner_ws_session,
        {{fake, Sink}, roadrunner_ws_lifecycle_handler, State, ws_ctx(), none},
        []
    ),
    Pid ! socket_ready,
    timer:sleep(20),
    Pid ! {pubsub, broadcast, payload},
    Sent = iolist_to_binary(collect_sends(Tag, 200)),
    ?assertNotEqual(nomatch, binary:match(Sent, ~"forwarded")),
    Sink ! stop,
    ok = gen_statem:stop(Pid).

handle_info_callback_can_request_hibernate_test() ->
    %% Handler returns `{ok, _, [hibernate]}` from handle_info — session
    %% hibernates after handling the stray message.
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_active_sink(Self, Tag, []),
    State = #{sink => Self, on_info => ok_hibernate},
    {ok, Pid} = gen_statem:start(
        roadrunner_ws_session,
        {{fake, Sink}, roadrunner_ws_lifecycle_handler, State, ws_ctx(), none},
        []
    ),
    Pid ! socket_ready,
    timer:sleep(20),
    Pid ! some_async_message,
    receive
        {event, info} -> ok
    after 200 -> ?assert(false)
    end,
    ?assert(is_hibernating(Pid, 200)),
    Sink ! stop,
    ok = gen_statem:stop(Pid).

handle_info_callback_close_terminates_session_test() ->
    %% Handler returns `{close, _}` from handle_info — session sends a
    %% close frame and stops normally.
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_active_sink(Self, Tag, []),
    State = #{sink => Self, on_info => close},
    {ok, Pid} = gen_statem:start(
        roadrunner_ws_session,
        {{fake, Sink}, roadrunner_ws_lifecycle_handler, State, ws_ctx(), none},
        []
    ),
    Ref = monitor(process, Pid),
    Pid ! socket_ready,
    timer:sleep(20),
    Pid ! shut_me_down,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 500 -> ?assert(false)
    end,
    Sent = iolist_to_binary(collect_sends(Tag, 50)),
    %% The handler emits exactly one frame — the close. Opcode 0x88.
    ?assertMatch(<<16#88, _/binary>>, Sent),
    Sink ! stop.

%% =============================================================================
%% permessage-deflate (RFC 7692) — end-to-end through the session.
%% =============================================================================

pmd_inflates_compressed_inbound_text_message_test() ->
    %% Client sends a single-fragment compressed text "hello"; server
    %% inflates it and dispatches to the echo handler. Echo replies
    %% with another compressed frame.
    Self = self(),
    Tag = make_ref(),
    Compressed = pmd_compress(~"hello"),
    %% RSV1=1, FIN=1, masked, opcode text.
    InboundFrame = pmd_frame(text, Compressed),
    Sink = spawn_active_sink(Self, Tag, [{recv, InboundFrame}]),
    Negotiated =
        {permessage_deflate,
            #{
                server_max_window_bits => 15,
                client_max_window_bits => 15,
                server_no_context_takeover => false,
                client_no_context_takeover => false
            },
            ~"permessage-deflate"},
    {ok, Pid} = gen_statem:start(
        roadrunner_ws_session,
        {{fake, Sink}, roadrunner_ws_echo_handler, undefined, ws_ctx(), Negotiated},
        []
    ),
    Pid ! socket_ready,
    Sent = iolist_to_binary(collect_sends(Tag, 200)),
    %% The wire response is also compressed (RSV1=1) — first byte
    %% has FIN(1) RSV1(1) opcode(0001) = 0xC1.
    ?assertMatch(<<16#c1, _/binary>>, Sent),
    %% Body bytes: strip the 2-byte header, append PMD trailer, inflate.
    <<16#c1, Len, Body/binary>> = Sent,
    ?assertEqual(Len, byte_size(Body)),
    Decompressed = pmd_decompress(Body),
    ?assertEqual(~"hello", Decompressed),
    Sink ! stop,
    ok = gen_statem:stop(Pid).

pmd_concatenates_compressed_fragments_before_inflate_test() ->
    %% Compressed message split across two fragments — first has
    %% RSV1=1 FIN=0, continuation has RSV1=0 FIN=1. Server must
    %% concatenate both fragment payloads, append the per-message
    %% trailer, then inflate.
    Self = self(),
    Tag = make_ref(),
    Compressed = pmd_compress(~"hello world"),
    %% Split the compressed bytes roughly in half.
    Mid = byte_size(Compressed) div 2,
    <<First:Mid/binary, Second/binary>> = Compressed,
    Frame1 = pmd_frame_fragment(text, First, false, true),
    Frame2 = pmd_frame_fragment(continuation, Second, true, false),
    TwoFrames = <<Frame1/binary, Frame2/binary>>,
    Sink = spawn_active_sink(Self, Tag, [{recv, TwoFrames}]),
    Negotiated =
        {permessage_deflate,
            #{
                server_max_window_bits => 15,
                client_max_window_bits => 15,
                server_no_context_takeover => false,
                client_no_context_takeover => false
            },
            ~"permessage-deflate"},
    {ok, Pid} = gen_statem:start(
        roadrunner_ws_session,
        {{fake, Sink}, roadrunner_ws_echo_handler, undefined, ws_ctx(), Negotiated},
        []
    ),
    Pid ! socket_ready,
    Sent = iolist_to_binary(collect_sends(Tag, 200)),
    <<16#c1, Len, Body/binary>> = Sent,
    ?assertEqual(Len, byte_size(Body)),
    Decompressed = pmd_decompress(Body),
    ?assertEqual(~"hello world", Decompressed),
    Sink ! stop,
    ok = gen_statem:stop(Pid).

pmd_uncompressed_frame_passes_through_when_pmd_negotiated_test() ->
    %% Even with PMD negotiated, a frame with RSV1=0 is uncompressed.
    %% Should reach the handler with payload as-sent.
    Self = self(),
    Tag = make_ref(),
    InboundFrame = frame(text, ~"plain"),
    Sink = spawn_active_sink(Self, Tag, [{recv, InboundFrame}]),
    Negotiated =
        {permessage_deflate,
            #{
                server_max_window_bits => 15,
                client_max_window_bits => 15,
                server_no_context_takeover => false,
                client_no_context_takeover => false
            },
            ~"permessage-deflate"},
    {ok, Pid} = gen_statem:start(
        roadrunner_ws_session,
        {{fake, Sink}, roadrunner_ws_echo_handler, undefined, ws_ctx(), Negotiated},
        []
    ),
    Pid ! socket_ready,
    Sent = iolist_to_binary(collect_sends(Tag, 200)),
    %% Server's reply is still compressed (PMD active for outbound) —
    %% RSV1=1 → 0xC1. Inflate to verify echo content.
    <<16#c1, Len, Body/binary>> = Sent,
    ?assertEqual(Len, byte_size(Body)),
    ?assertEqual(~"plain", pmd_decompress(Body)),
    Sink ! stop,
    ok = gen_statem:stop(Pid).

pmd_three_way_fragmented_compressed_message_test() ->
    %% 3 fragments: first (RSV1=1, FIN=0) + middle continuation (FIN=0)
    %% + last continuation (FIN=1). Exercises the per-fragment Acc
    %% accumulation branch (Acc is non-undefined when middle arrives).
    Self = self(),
    Tag = make_ref(),
    Compressed = pmd_compress(~"hello world!"),
    %% Split into 3 roughly-equal pieces.
    Sz = byte_size(Compressed),
    A = Sz div 3,
    B = (2 * Sz) div 3,
    <<P1:A/binary, P2:(B - A)/binary, P3/binary>> = Compressed,
    Frame1 = pmd_frame_fragment(text, P1, false, true),
    Frame2 = pmd_frame_fragment(continuation, P2, false, false),
    Frame3 = pmd_frame_fragment(continuation, P3, true, false),
    Three = <<Frame1/binary, Frame2/binary, Frame3/binary>>,
    Sink = spawn_active_sink(Self, Tag, [{recv, Three}]),
    Negotiated = pmd_negotiated(),
    {ok, Pid} = gen_statem:start(
        roadrunner_ws_session,
        {{fake, Sink}, roadrunner_ws_echo_handler, undefined, ws_ctx(), Negotiated},
        []
    ),
    Pid ! socket_ready,
    Sent = iolist_to_binary(collect_sends(Tag, 200)),
    <<16#c1, Len, Body/binary>> = Sent,
    ?assertEqual(Len, byte_size(Body)),
    ?assertEqual(~"hello world!", pmd_decompress(Body)),
    Sink ! stop,
    ok = gen_statem:stop(Pid).

pmd_corrupt_compressed_payload_stops_session_test() ->
    %% Garbage bytes in a frame with RSV1=1 — inflate fails. Session
    %% must terminate cleanly (no crash, no half-sent reply).
    Self = self(),
    Tag = make_ref(),
    Garbage = <<255, 254, 253, 252, 251>>,
    Frame = pmd_frame(text, Garbage),
    Sink = spawn_active_sink(Self, Tag, [{recv, Frame}]),
    Negotiated = pmd_negotiated(),
    {ok, Pid} = gen_statem:start(
        roadrunner_ws_session,
        {{fake, Sink}, roadrunner_ws_echo_handler, undefined, ws_ctx(), Negotiated},
        []
    ),
    Ref = monitor(process, Pid),
    Pid ! socket_ready,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 2000 -> error(no_normal_exit_on_corrupt_payload)
    end,
    Sink ! stop.

pmd_no_context_takeover_resets_inflate_after_each_message_test() ->
    %% With client_no_context_takeover negotiated, the server's
    %% inflate context resets after every message. Two compressed
    %% messages each compressed with a fresh deflate context — both
    %% must round-trip correctly even though the server's inflate
    %% state was reset between them.
    Self = self(),
    Tag = make_ref(),
    First = pmd_compress(~"hello"),
    Second = pmd_compress(~"world"),
    Two = <<(pmd_frame(text, First))/binary, (pmd_frame(text, Second))/binary>>,
    Sink = spawn_active_sink(Self, Tag, [{recv, Two}]),
    Negotiated =
        {permessage_deflate,
            #{
                server_max_window_bits => 15,
                client_max_window_bits => 15,
                server_no_context_takeover => true,
                client_no_context_takeover => true
            },
            ~"permessage-deflate; server_no_context_takeover; client_no_context_takeover"},
    {ok, Pid} = gen_statem:start(
        roadrunner_ws_session,
        {{fake, Sink}, roadrunner_ws_echo_handler, undefined, ws_ctx(), Negotiated},
        []
    ),
    Pid ! socket_ready,
    Sent = iolist_to_binary(collect_sends(Tag, 200)),
    %% Decompose into two RSV1=1 frames and verify each.
    <<16#c1, L1, B1:L1/binary, 16#c1, L2, B2:L2/binary>> = Sent,
    ?assertEqual(~"hello", pmd_decompress_fresh(B1)),
    ?assertEqual(~"world", pmd_decompress_fresh(B2)),
    Sink ! stop,
    ok = gen_statem:stop(Pid).

pmd_uncompressed_continuation_passes_through_test() ->
    %% Uncompressed continuation frame outside any compressed message.
    %% Tests `classify_data_frame` returning `regular` for that path
    %% (compressed_acc=undefined). The echo handler's catch-all clause
    %% handles it gracefully (no reply expected).
    Self = self(),
    Tag = make_ref(),
    %% First send a non-FIN text frame to put the wire in continuation
    %% state, then a FIN continuation frame. Both uncompressed.
    F1 = uncompressed_fragment(text, ~"part1", false),
    F2 = uncompressed_fragment(continuation, ~"part2", true),
    Sink = spawn_active_sink(Self, Tag, [{recv, <<F1/binary, F2/binary>>}]),
    Negotiated = pmd_negotiated(),
    {ok, Pid} = gen_statem:start(
        roadrunner_ws_session,
        {{fake, Sink}, roadrunner_ws_echo_handler, undefined, ws_ctx(), Negotiated},
        []
    ),
    Ref = monitor(process, Pid),
    Pid ! socket_ready,
    %% Echo handler replies to the non-FIN text frame with the same
    %% partial; then sees the continuation and falls through. The
    %% session stays alive until peer close. We just assert it
    %% doesn't crash on the continuation.
    timer:sleep(100),
    ?assert(is_process_alive(Pid)),
    Sink ! stop,
    Pid ! {roadrunner_fake_closed, Sink},
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 1000 -> error(no_normal_exit)
    end.

pmd_control_frames_stay_uncompressed_test() ->
    %% RFC 7692 §6.1: control frames MUST NOT be compressed. Server's
    %% auto-pong reply to an inbound ping must NOT have RSV1=1.
    Self = self(),
    Tag = make_ref(),
    Ping = ping_frame(~"hi"),
    Sink = spawn_active_sink(Self, Tag, [{recv, Ping}]),
    Negotiated =
        {permessage_deflate,
            #{
                server_max_window_bits => 15,
                client_max_window_bits => 15,
                server_no_context_takeover => false,
                client_no_context_takeover => false
            },
            ~"permessage-deflate"},
    {ok, Pid} = gen_statem:start(
        roadrunner_ws_session,
        {{fake, Sink}, roadrunner_ws_echo_handler, undefined, ws_ctx(), Negotiated},
        []
    ),
    Pid ! socket_ready,
    Sent = iolist_to_binary(collect_sends(Tag, 200)),
    %% Auto-pong: opcode 0xA, FIN=1, RSV1=0 → 0x8A.
    ?assertMatch(<<16#8a, _/binary>>, Sent),
    Sink ! stop,
    ok = gen_statem:stop(Pid).

%% --- helpers ---

ws_ctx() ->
    #{
        listener_name => probe_ws,
        peer => undefined,
        request_id => undefined,
        module => roadrunner_ws_echo_handler
    }.

%% A minimal text/binary single-fragment unmasked frame. Server-side
%% receives masked frames per the WebSocket spec, so we mark fin=true
%% and apply a XOR mask to the payload via roadrunner_ws.
frame(Opcode, Payload) ->
    Masked = mask(Payload, <<1, 2, 3, 4>>),
    Len = byte_size(Payload),
    OpcodeByte =
        case Opcode of
            text -> 16#81;
            binary -> 16#82
        end,
    <<OpcodeByte, (16#80 bor Len), 1, 2, 3, 4, Masked/binary>>.

mask(Bin, Key) ->
    KeyBin = binary:copy(Key, (byte_size(Bin) div 4) + 1),
    <<KeySlice:(byte_size(Bin))/binary, _/binary>> = KeyBin,
    crypto:exor(Bin, KeySlice).

%% Build a single-fragment compressed text/binary frame: FIN=1, RSV1=1,
%% masked, with the given (already-deflated) compressed payload.
pmd_frame(Opcode, Compressed) ->
    pmd_frame_fragment(Opcode, Compressed, true, true).

%% Build a compressed-message fragment with explicit FIN/RSV1 control.
pmd_frame_fragment(Opcode, CompressedPayload, Fin, Rsv1) ->
    OpcodeByte = pmd_opcode_byte(Opcode, Fin, Rsv1),
    Mask = <<5, 6, 7, 8>>,
    Masked = mask(CompressedPayload, Mask),
    Len = byte_size(CompressedPayload),
    <<OpcodeByte, (16#80 bor Len), Mask/binary, Masked/binary>>.

pmd_opcode_byte(text, Fin, Rsv1) ->
    pmd_byte_with_flags(16#01, Fin, Rsv1);
pmd_opcode_byte(binary, Fin, Rsv1) ->
    pmd_byte_with_flags(16#02, Fin, Rsv1);
pmd_opcode_byte(continuation, Fin, Rsv1) ->
    pmd_byte_with_flags(16#00, Fin, Rsv1).

pmd_byte_with_flags(OpNibble, Fin, Rsv1) ->
    FinBit =
        case Fin of
            true -> 16#80;
            false -> 0
        end,
    Rsv1Bit =
        case Rsv1 of
            true -> 16#40;
            false -> 0
        end,
    FinBit bor Rsv1Bit bor OpNibble.

%% Compress a payload through a fresh deflate context with windowBits=15
%% (raw deflate, matches the session's negotiated default), then strip
%% the trailing per-message DEFLATE tail (\x00\x00\xff\xff) per
%% RFC 7692 §7.2.1.
pmd_compress(Payload) ->
    Z = zlib:open(),
    try
        ok = zlib:deflateInit(Z, default, deflated, -15, 8, default),
        Bin = iolist_to_binary(zlib:deflate(Z, Payload, sync)),
        Size = byte_size(Bin),
        binary:part(Bin, 0, Size - 4)
    after
        zlib:close(Z)
    end.

%% Decompress a payload that the server emitted (RSV1=1 frame body) by
%% appending the per-message DEFLATE tail and inflating with
%% windowBits=15 (raw inflate).
pmd_decompress(CompressedBody) ->
    Z = zlib:open(),
    try
        ok = zlib:inflateInit(Z, -15),
        iolist_to_binary(zlib:inflate(Z, <<CompressedBody/binary, 0, 0, 16#FF, 16#FF>>))
    after
        zlib:close(Z)
    end.

%% Masked client ping frame with arbitrary payload (≤125 bytes).
ping_frame(Payload) ->
    Mask = <<9, 10, 11, 12>>,
    Masked = mask(Payload, Mask),
    Len = byte_size(Payload),
    %% Opcode 0x9 = ping, FIN=1, RSV*=0, MASK=1.
    <<16#89, (16#80 bor Len), Mask/binary, Masked/binary>>.

%% Uncompressed text/binary/continuation fragment with explicit FIN.
uncompressed_fragment(Opcode, Payload, Fin) ->
    Mask = <<13, 14, 15, 16>>,
    Masked = mask(Payload, Mask),
    Len = byte_size(Payload),
    OpByte =
        case {Opcode, Fin} of
            {text, true} -> 16#81;
            {text, false} -> 16#01;
            {binary, true} -> 16#82;
            {binary, false} -> 16#02;
            {continuation, true} -> 16#80;
            {continuation, false} -> 16#00
        end,
    <<OpByte, (16#80 bor Len), Mask/binary, Masked/binary>>.

%% Default-shape negotiated permessage-deflate (context takeover ON,
%% windowBits=15) — used by the majority of PMD tests.
pmd_negotiated() ->
    {permessage_deflate,
        #{
            server_max_window_bits => 15,
            client_max_window_bits => 15,
            server_no_context_takeover => false,
            client_no_context_takeover => false
        },
        ~"permessage-deflate"}.

%% Decompress with a FRESH inflate context — for asserting messages
%% emitted under server_no_context_takeover (server resets its deflate
%% context after each message, so each message is independently
%% decompressible from a fresh inflate state).
pmd_decompress_fresh(CompressedBody) ->
    pmd_decompress(CompressedBody).

is_hibernating(Pid, TimeoutMs) ->
    is_hibernating_loop(
        Pid,
        hibernation_heap_threshold(),
        erlang:monotonic_time(millisecond) + TimeoutMs
    ).

%% A hibernated process is in `status =:= waiting` AND has had its
%% heap shrunk to the OTP-configured minimum.
%% `current_function` for a process resumed from hibernation is the
%% M:F:A it'll re-enter when woken (so we can't rely on it being
%% `{erlang, hibernate, _}`). Read the actual minimum from
%% `erlang:system_info(min_heap_size)` so the threshold tracks the
%% running OTP version (233 words on default 28+; +64 word slack
%% for sys-debug / process-dict allocations that survive hibernation).
hibernation_heap_threshold() ->
    {min_heap_size, Min} = erlang:system_info(min_heap_size),
    Min + 64.

is_hibernating_loop(Pid, Threshold, Deadline) ->
    case process_info(Pid, [status, total_heap_size, message_queue_len]) of
        [{status, waiting}, {total_heap_size, H}, {message_queue_len, 0}] when
            H =< Threshold
        ->
            true;
        _ ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true ->
                    false;
                false ->
                    timer:sleep(10),
                    is_hibernating_loop(Pid, Threshold, Deadline)
            end
    end.

current_function(Pid) ->
    case process_info(Pid, current_function) of
        {current_function, MFA} -> MFA;
        undefined -> undefined
    end.

spawn_send_log_sink(Logger, Tag) ->
    spawn(fun() -> sink_loop(Logger, Tag) end).

sink_loop(Logger, Tag) ->
    receive
        stop ->
            ok;
        {roadrunner_fake_send, _Pid, Data} ->
            Logger ! {sent, Tag, Data},
            sink_loop(Logger, Tag);
        {roadrunner_fake_recv, ConnPid, _Len, _Timeout} ->
            ConnPid ! {roadrunner_fake_recv_reply, {error, closed}},
            sink_loop(Logger, Tag);
        _ ->
            sink_loop(Logger, Tag)
    end.

%% Active-mode sink: when the conn arms `setopts({active, once})`, the
%% sink dispatches the next script step (data | closed | error) to
%% the conn pid using the roadrunner_fake_* message tags from
%% `roadrunner_transport:messages/1`.
spawn_active_sink(Logger, Tag, Script) ->
    spawn(fun() -> active_sink_loop(Logger, Tag, Script) end).

active_sink_loop(Logger, Tag, Script) ->
    receive
        stop ->
            ok;
        {roadrunner_fake_send, _Pid, Data} ->
            Logger ! {sent, Tag, Data},
            active_sink_loop(Logger, Tag, Script);
        {roadrunner_fake_setopts, ConnPid, _Opts} ->
            case Script of
                [{recv, Bytes} | Rest] ->
                    ConnPid ! {roadrunner_fake_data, self(), Bytes},
                    active_sink_loop(Logger, Tag, Rest);
                [{error, closed} | Rest] ->
                    ConnPid ! {roadrunner_fake_closed, self()},
                    active_sink_loop(Logger, Tag, Rest);
                [{error, Reason} | Rest] ->
                    ConnPid ! {roadrunner_fake_error, self(), Reason},
                    active_sink_loop(Logger, Tag, Rest);
                [] ->
                    %% No more script — leave the session armed and
                    %% silently dormant; the test will stop the
                    %% gen_statem itself.
                    active_sink_loop(Logger, Tag, [])
            end;
        _ ->
            active_sink_loop(Logger, Tag, Script)
    end.

collect_sends(Tag, Timeout) ->
    collect_sends_loop(Tag, [], Timeout).

collect_sends_loop(Tag, Acc, Timeout) ->
    receive
        {sent, Tag, Data} -> collect_sends_loop(Tag, [Data | Acc], 0)
    after Timeout ->
        lists:reverse(Acc)
    end.
