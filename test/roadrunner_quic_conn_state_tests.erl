-module(roadrunner_quic_conn_state_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_quic_conn_state).
-define(TC, roadrunner_quic_test_client).

%% TLS handshake message types asserted on (RFC 8446 §4).
-define(CLIENT_HELLO, 1).
-define(ENCRYPTED_EXTENSIONS, 8).
-define(CERTIFICATE, 11).
-define(CERTIFICATE_VERIFY, 15).
-define(FINISHED, 20).

%% A fixed client DCID (the server's routing id), an 8-byte server SCID to
%% match the server's fixed ?SCID_LEN, the peer address, and a clock.
-define(DCID, <<1, 2, 3, 4, 5, 6, 7, 8>>).
-define(SCID, <<8, 7, 6, 5, 4, 3, 2, 1>>).
-define(PEER, {{127, 0, 0, 1}, 12345}).
-define(NOW, 1000).

%% =============================================================================
%% Construction
%% =============================================================================

new_starts_handshaking_test() ->
    {State, _Ctx} = new_conn([~"leaf-cert-der"]),
    ?assertEqual(handshaking, ?M:phase(State)).

peername_answers_in_handshaking_test() ->
    {State, _Ctx} = new_conn([~"leaf-cert-der"]),
    ?assertEqual({ok, ?PEER}, ?M:peername(State)).

%% =============================================================================
%% Full handshake: the in-test client completes a real handshake against the
%% decision core, end to end through the packet/crypto leaves.
%% =============================================================================

handshake_reaches_connected_test() ->
    #{state1 := State1, state2 := State2} = connect(),
    ?assertEqual(handshaking, ?M:phase(State1)),
    ?assertEqual(connected, ?M:phase(State2)).

server_hello_carries_server_key_share_test() ->
    #{sh_framed := ServerHello, ctx := #{server_pub := ServerPub}} = connect(),
    ?assertEqual(ServerPub, ?TC:server_hello_key_share(ServerHello)).

server_flight_carries_auth_messages_test() ->
    #{flight := Flight} = connect(),
    ?assertEqual(
        [?ENCRYPTED_EXTENSIONS, ?CERTIFICATE, ?CERTIFICATE_VERIFY, ?FINISHED],
        [Type || {Type, _Body} <- ?TC:deframe_all(Flight)]
    ).

initial_reply_acknowledges_client_test() ->
    #{effects1 := Effects1} = connect(),
    Frames = ?TC:frames(
        sends(Effects1),
        initial,
        #{initial => roadrunner_quic_keys:initial_server(?DCID)},
        byte_size(?DCID)
    ),
    ?assert(lists:any(fun is_ack/1, Frames)).

handshake_done_emitted_when_connected_test() ->
    #{effects2 := Effects2, server_ap_secret := ServerApSecret} = connect(),
    Frames = ?TC:frames(
        sends(Effects2),
        application,
        #{application => roadrunner_quic_keys:traffic_keys(ServerApSecret)},
        byte_size(?DCID)
    ),
    ?assert(lists:member(handshake_done, Frames)).

%% =============================================================================
%% Frame handling
%% =============================================================================

client_ack_processed_test() ->
    %% A valid ACK of the server's ServerHello drives loss detection and is
    %% itself not acknowledged (an ACK is not ack-eliciting).
    #{state1 := State1} = connect(),
    Datagram = ?TC:seal(
        initial,
        1,
        roadrunner_quic_keys:initial_client(?DCID),
        [{ack, 0, 0, 0, [], undefined}],
        ?DCID,
        ?SCID
    ),
    {State2, _Effects} = ?M:handle_datagram(?NOW, Datagram, State1),
    ?assertEqual(handshaking, ?M:phase(State2)).

oversized_ack_range_ignored_test() ->
    %% An ACK claiming more packets than the loss layer accepts is dropped
    %% without disturbing the connection.
    #{state1 := State1} = connect(),
    Datagram = ?TC:seal(
        initial,
        1,
        roadrunner_quic_keys:initial_client(?DCID),
        [{ack, 70000, 0, 70000, [], undefined}],
        ?DCID,
        ?SCID
    ),
    {State2, _Effects} = ?M:handle_datagram(?NOW, Datagram, State1),
    ?assertEqual(handshaking, ?M:phase(State2)).

ping_and_padding_frames_handled_test() ->
    %% A PING (ack-eliciting) padded for the header-protection sample
    %% exercises the catch-all frame handler for both PING and PADDING.
    #{state1 := State1} = connect(),
    Datagram = ?TC:seal(
        initial, 1, roadrunner_quic_keys:initial_client(?DCID), [ping], ?DCID, ?SCID
    ),
    {State2, _Effects} = ?M:handle_datagram(?NOW, Datagram, State1),
    ?assertEqual(handshaking, ?M:phase(State2)).

%% =============================================================================
%% Drop / error paths
%% =============================================================================

undecryptable_packet_dropped_test() ->
    %% A packet sealed with the wrong keys is silently dropped (RFC 9001
    %% §5.4.2); the connection neither advances nor replies.
    {State0, _Ctx} = new_conn([~"leaf-cert-der"]),
    WrongKeys = #{key => <<0:128>>, iv => <<0:96>>, hp => <<0:128>>},
    Datagram = ?TC:seal(initial, 0, WrongKeys, [{crypto, 0, ~"hello"}], ?DCID, ?SCID),
    {State1, Effects} = ?M:handle_datagram(?NOW, Datagram, State0),
    ?assertEqual(handshaking, ?M:phase(State1)),
    ?assertEqual([], sends(Effects)).

malformed_frame_ignored_test() ->
    %% An authenticated payload that decodes to a malformed frame is a
    %% connection error the decision core absorbs (a CRYPTO frame claiming
    %% eight bytes but carrying three).
    {State0, _Ctx} = new_conn([~"leaf-cert-der"]),
    Datagram = ?TC:seal_raw(
        initial,
        0,
        roadrunner_quic_keys:initial_client(?DCID),
        <<16#06, 16#00, 16#08, 1, 2, 3>>,
        ?DCID,
        ?SCID
    ),
    {State1, Effects} = ?M:handle_datagram(?NOW, Datagram, State0),
    ?assertEqual(handshaking, ?M:phase(State1)),
    ?assertEqual([], sends(Effects)).

packet_for_discarded_space_ignored_test() ->
    %% One datagram coalescing the client Finished (which confirms the
    %% handshake and discards the Handshake space) with a trailing handshake
    %% packet that then lands on the now-absent space.
    #{state1 := State1, client_hs_secret := ClientHsSecret, cf_framed := ClientFinished} = connect(),
    HsKeys = roadrunner_quic_keys:traffic_keys(ClientHsSecret),
    Finished = ?TC:seal(handshake, 0, HsKeys, [{crypto, 0, ClientFinished}], ?DCID, ?SCID),
    Trailing = ?TC:seal(handshake, 1, HsKeys, [ping], ?DCID, ?SCID),
    {State2, _Effects} = ?M:handle_datagram(?NOW, <<Finished/binary, Trailing/binary>>, State1),
    ?assertEqual(connected, ?M:phase(State2)).

tampered_client_finished_closes_test() ->
    %% A forged Finished fails verification: the connection closes gracefully
    %% with {closed, {local, handshake_failure}} rather than crashing.
    #{state1 := State1, client_hs_secret := ClientHsSecret, cf_framed := ClientFinished} = connect(),
    <<Type, Len:24, First, Rest/binary>> = ClientFinished,
    Tampered = <<Type, Len:24, (First bxor 1), Rest/binary>>,
    HsKeys = roadrunner_quic_keys:traffic_keys(ClientHsSecret),
    Datagram = ?TC:seal(handshake, 0, HsKeys, [{crypto, 0, Tampered}], ?DCID, ?SCID),
    {State2, Effects} = ?M:handle_datagram(?NOW, Datagram, with_owner(State1)),
    ?assertEqual(closed, ?M:phase(State2)),
    ?assertEqual([{emit, self(), {closed, {local, handshake_failure}}}], emits(Effects)).

malformed_client_hello_closes_test() ->
    %% A ClientHello body the TLS layer cannot parse closes the connection.
    {State0, _Ctx} = new_conn([~"leaf-cert-der"]),
    Garbage = iolist_to_binary(roadrunner_quic_tls_handshake:encode(?CLIENT_HELLO, ~"not a hello")),
    Datagram = ?TC:seal(
        initial, 0, roadrunner_quic_keys:initial_client(?DCID), [{crypto, 0, Garbage}], ?DCID, ?SCID
    ),
    {State1, Effects} = ?M:handle_datagram(?NOW, Datagram, with_owner(State0)),
    ?assertEqual(closed, ?M:phase(State1)),
    ?assertEqual([{emit, self(), {closed, {local, malformed_client_hello}}}], emits(Effects)),
    %% The CONNECTION_CLOSE is transmitted at the Initial level (a TLS error
    %% the client can still read with Initial keys).
    Frames = ?TC:frames(
        sends(Effects),
        initial,
        #{initial => roadrunner_quic_keys:initial_server(?DCID)},
        byte_size(?DCID)
    ),
    ?assertMatch([{connection_close, transport, _Code, 0, <<>>}], Frames).

unexpected_handshake_message_closes_test() ->
    %% An out-of-sequence handshake message type closes the connection.
    {State0, _Ctx} = new_conn([~"leaf-cert-der"]),
    Unexpected = iolist_to_binary(roadrunner_quic_tls_handshake:encode(?FINISHED, <<>>)),
    Datagram = ?TC:seal(
        initial,
        0,
        roadrunner_quic_keys:initial_client(?DCID),
        [{crypto, 0, Unexpected}],
        ?DCID,
        ?SCID
    ),
    {State1, Effects} = ?M:handle_datagram(?NOW, Datagram, with_owner(State0)),
    ?assertEqual(closed, ?M:phase(State1)),
    ?assertEqual([{emit, self(), {closed, {local, unexpected_message}}}], emits(Effects)).

application_close_at_initial_level_closes_test() ->
    %% An application-variant CONNECTION_CLOSE (0x1d) decoded from an Initial
    %% packet is a protocol violation (RFC 9000 §19.19, 0x1d is 1-RTT only):
    %% the connection closes with {closed, {local, protocol_violation}}.
    {State0, _Ctx} = new_conn([~"leaf-cert-der"]),
    Datagram = ?TC:seal(
        initial,
        0,
        roadrunner_quic_keys:initial_client(?DCID),
        [{connection_close, application, 7, undefined, <<>>}],
        ?DCID,
        ?SCID
    ),
    {State1, Effects} = ?M:handle_datagram(?NOW, Datagram, with_owner(State0)),
    ?assertEqual(closed, ?M:phase(State1)),
    ?assertEqual([{emit, self(), {closed, {local, protocol_violation}}}], emits(Effects)).

application_close_at_1rtt_closes_test() ->
    %% An application-variant CONNECTION_CLOSE (0x1d) is legal at 1-RTT (an h3
    %% client's graceful close) and surfaces {closed, {peer, ErrorCode}}.
    {State, ApSecret} = connected_with_owner(),
    Close = app_datagram([{connection_close, application, 9, undefined, <<>>}], 0, ApSecret),
    {State1, Effects} = ?M:handle_datagram(?NOW, Close, State),
    ?assertEqual(closed, ?M:phase(State1)),
    ?assertEqual([{emit, self(), {closed, {peer, 9}}}], emits(Effects)).

%% =============================================================================
%% Timers and anti-amplification
%% =============================================================================

pto_backoff_advances_deadline_test() ->
    %% Each probe timeout that detects no loss must re-arm strictly later
    %% (RFC 9002 §6.2.1 exponential backoff), never re-fire at the same past
    %% deadline. Two fires at the same clock prove the deadline advances, so
    %% the shell never busy-spins on send_after(0).
    #{state1 := State1} = connect(),
    {State2, Effects1} = ?M:handle_timeout(?NOW, pto, State1),
    {_State3, Effects2} = ?M:handle_timeout(?NOW, pto, State2),
    ?assert(arm_deadline(Effects2) > arm_deadline(Effects1)).

amplification_limit_caps_first_flight_test() ->
    %% A large certificate chain makes the server flight exceed 3x the
    %% client's 1200-byte Initial, so the send pass stops before sending it
    %% all (the connection stays handshaking until more client bytes lift
    %% the limit).
    {State0, Ctx} = new_conn([binary:copy(<<0>>, 6000)]),
    {Datagram, _CHFramed} = client_hello_datagram(Ctx),
    {State1, Effects} = ?M:handle_datagram(?NOW, Datagram, State0),
    ?assertEqual(handshaking, ?M:phase(State1)),
    ?assert(lists:sum([byte_size(D) || D <- sends(Effects)]) =< 3 * 1200).

%% =============================================================================
%% Control calls + owner notification
%% =============================================================================

peername_call_replies_test() ->
    {State, _Ctx} = new_conn([~"leaf-cert-der"]),
    Ref = make_ref(),
    ?assertEqual(
        {State, [{reply, self(), Ref, {ok, ?PEER}}]},
        ?M:handle_call(self(), Ref, peername, State)
    ).

owner_set_in_handshaking_gets_connected_on_completion_test() ->
    %% The normal listener ordering: the owner is installed while still
    %% handshaking (no emit yet), then the confirming datagram emits
    %% {connected, _} to it exactly once.
    #{state1 := State1, client_hs_secret := ClientHsSecret, cf_framed := ClientFinished} = connect(),
    Owner = self(),
    Ref = make_ref(),
    {State1b, Installed} = ?M:handle_call(Owner, Ref, {set_owner, Owner}, State1),
    ?assertEqual([{reply, Owner, Ref, ok}], Installed),
    Datagram = ?TC:seal(
        handshake,
        0,
        roadrunner_quic_keys:traffic_keys(ClientHsSecret),
        [{crypto, 0, ClientFinished}],
        ?DCID,
        ?SCID
    ),
    {State2, Effects} = ?M:handle_datagram(?NOW, Datagram, State1b),
    ?assertEqual(connected, ?M:phase(State2)),
    ?assertEqual([{emit, Owner, {connected, expected_info()}}], emits(Effects)).

owner_set_after_connection_gets_connected_now_test() ->
    %% The deferred ordering: if the handshake confirms before the owner is
    %% installed, set_owner emits {connected, _} immediately.
    #{state2 := State2} = connect(),
    Owner = self(),
    Ref = make_ref(),
    {_State3, Effects} = ?M:handle_call(Owner, Ref, {set_owner, Owner}, State2),
    ?assertEqual([{reply, Owner, Ref, ok}, {emit, Owner, {connected, expected_info()}}], Effects).

connected_not_re_emitted_on_later_datagram_test() ->
    %% The once-only guard: with an owner installed, a datagram AFTER the
    %% connection completes must NOT re-emit {connected, _}. There is no
    %% emitted-flag; this pins that the emit rides the handshaking -> connected
    %% transition only, so dropping that guard would be caught here.
    #{
        state1 := State1,
        client_hs_secret := ClientHsSecret,
        cf_framed := ClientFinished,
        client_ap_secret := ClientApSecret
    } = connect(),
    Owner = self(),
    {State1b, _} = ?M:handle_call(Owner, make_ref(), {set_owner, Owner}, State1),
    Finished = ?TC:seal(
        handshake,
        0,
        roadrunner_quic_keys:traffic_keys(ClientHsSecret),
        [{crypto, 0, ClientFinished}],
        ?DCID,
        ?SCID
    ),
    {State2, FirstEffects} = ?M:handle_datagram(?NOW, Finished, State1b),
    ?assertEqual([{emit, Owner, {connected, expected_info()}}], emits(FirstEffects)),
    %% A processed 1-RTT packet once connected: still exactly zero re-emits.
    AppPing = ?TC:seal(
        application, 0, roadrunner_quic_keys:traffic_keys(ClientApSecret), [ping], ?DCID, ?SCID
    ),
    {_State3, LaterEffects} = ?M:handle_datagram(?NOW, AppPing, State2),
    ?assertEqual([], emits(LaterEffects)).

%% =============================================================================
%% Application streams (receive side)
%% =============================================================================

stream_data_emitted_test() ->
    {State, ApSecret} = connected_with_owner(),
    Datagram = app_datagram([{stream, 0, 0, ~"hello", true}], 0, ApSecret),
    {_State1, Effects} = ?M:handle_datagram(?NOW, Datagram, State),
    ?assertEqual(
        [{emit, self(), {stream_opened, 0}}, {emit, self(), {stream_data, 0, ~"hello", true}}],
        emits(Effects)
    ).

stream_fin_only_emitted_test() ->
    %% Data first (no FIN), then a FIN-only frame at the final offset yields
    %% the {<<>>, true} end-of-stream the h3 layer dispatches on.
    {State, ApSecret} = connected_with_owner(),
    {State1, E1} = ?M:handle_datagram(
        ?NOW, app_datagram([{stream, 0, 0, ~"hi", false}], 0, ApSecret), State
    ),
    ?assertEqual(
        [{emit, self(), {stream_opened, 0}}, {emit, self(), {stream_data, 0, ~"hi", false}}],
        emits(E1)
    ),
    {_State2, E2} = ?M:handle_datagram(
        ?NOW, app_datagram([{stream, 0, 2, <<>>, true}], 1, ApSecret), State1
    ),
    ?assertEqual([{emit, self(), {stream_data, 0, <<>>, true}}], emits(E2)).

stream_reset_emitted_test() ->
    {State, ApSecret} = connected_with_owner(),
    {State1, _} = ?M:handle_datagram(
        ?NOW, app_datagram([{stream, 0, 0, ~"hi", false}], 0, ApSecret), State
    ),
    {_State2, Effects} = ?M:handle_datagram(
        ?NOW, app_datagram([{reset_stream, 0, 7, 2}], 1, ApSecret), State1
    ),
    ?assertEqual([{emit, self(), {stream_reset, 0, 7}}], emits(Effects)).

out_of_order_stream_not_delivered_test() ->
    %% A gap frame (offset ahead of the read cursor) buffers without
    %% delivering, so only stream_opened is emitted.
    {State, ApSecret} = connected_with_owner(),
    Datagram = app_datagram([{stream, 0, 5, ~"x", false}], 0, ApSecret),
    {_State1, Effects} = ?M:handle_datagram(?NOW, Datagram, State),
    ?assertEqual([{emit, self(), {stream_opened, 0}}], emits(Effects)).

stream_on_server_initiated_id_closes_test() ->
    %% A peer STREAM on a server-initiated id (rem 4 == 3, a send-only stream
    %% from the peer) is an RFC 9000 §19.8 STREAM_STATE_ERROR: the connection
    %% closes rather than delivering the data.
    {State, ApSecret} = connected_with_owner(),
    Bad = app_datagram([{stream, 3, 0, ~"x", true}], 0, ApSecret),
    {State1, Effects} = ?M:handle_datagram(?NOW, Bad, State),
    ?assertEqual(closed, ?M:phase(State1)),
    ?assertEqual([{emit, self(), {closed, {local, stream_state_error}}}], emits(Effects)).

reset_stream_on_server_initiated_id_closes_test() ->
    %% A RESET_STREAM on a server-initiated id (rem 4 == 1) is likewise an
    %% RFC 9000 §19.4 STREAM_STATE_ERROR.
    {State, ApSecret} = connected_with_owner(),
    Bad = app_datagram([{reset_stream, 1, 7, 0}], 0, ApSecret),
    {State1, Effects} = ?M:handle_datagram(?NOW, Bad, State),
    ?assertEqual(closed, ?M:phase(State1)),
    ?assertEqual([{emit, self(), {closed, {local, stream_state_error}}}], emits(Effects)).

stream_final_size_violation_closes_test() ->
    %% A FIN declaring a final size below the bytes already received is an
    %% RFC 9000 §4.5 connection error.
    {State, ApSecret} = connected_with_owner(),
    {State1, _} = ?M:handle_datagram(
        ?NOW, app_datagram([{stream, 0, 0, ~"hello", false}], 0, ApSecret), State
    ),
    Bad = app_datagram([{stream, 0, 0, <<>>, true}], 1, ApSecret),
    {State2, Effects} = ?M:handle_datagram(?NOW, Bad, State1),
    ?assertEqual(closed, ?M:phase(State2)),
    ?assertEqual([{emit, self(), {closed, {local, final_size_error}}}], emits(Effects)).

reset_final_size_violation_closes_test() ->
    %% A RESET_STREAM final size below the bytes already received is likewise
    %% an RFC 9000 §4.5 connection error.
    {State, ApSecret} = connected_with_owner(),
    {State1, _} = ?M:handle_datagram(
        ?NOW, app_datagram([{stream, 0, 0, ~"hello", false}], 0, ApSecret), State
    ),
    Bad = app_datagram([{reset_stream, 0, 7, 2}], 1, ApSecret),
    {State2, Effects} = ?M:handle_datagram(?NOW, Bad, State1),
    ?assertEqual(closed, ?M:phase(State2)),
    ?assertEqual([{emit, self(), {closed, {local, final_size_error}}}], emits(Effects)).

stream_over_connection_flow_limit_closes_test() ->
    %% A peer STREAM whose highest offset exceeds the connection's
    %% 786432-byte receive window is an RFC 9000 §4.1 flow-control connection
    %% error.
    {State, ApSecret} = connected_with_owner(),
    Oversized = binary:copy(~"x", 786433),
    Bad = app_datagram([{stream, 0, 0, Oversized, false}], 0, ApSecret),
    {State1, Effects} = ?M:handle_datagram(?NOW, Bad, State),
    ?assertEqual(closed, ?M:phase(State1)),
    ?assertEqual([{emit, self(), {closed, {local, flow_control_error}}}], emits(Effects)).

stream_retransmit_does_not_re_consume_flow_test() ->
    %% Flow control is charged by the increase in the highest received offset,
    %% so resending bytes already received does not re-consume the connection
    %% window (RFC 9000 §4.1) even when the raw byte sum exceeds it; the
    %% duplicate also delivers no new stream_data.
    {State, ApSecret} = connected_with_owner(),
    Chunk = binary:copy(~"x", 500000),
    {State1, _} = ?M:handle_datagram(
        ?NOW, app_datagram([{stream, 0, 0, Chunk, false}], 0, ApSecret), State
    ),
    {State2, Effects} = ?M:handle_datagram(
        ?NOW, app_datagram([{stream, 0, 0, Chunk, false}], 1, ApSecret), State1
    ),
    ?assertEqual(connected, ?M:phase(State2)),
    ?assertEqual([], emits(Effects)).

connected_precedes_stream_events_in_coalesced_datagram_test() ->
    %% A single datagram that coalesces the client Finished (completing the
    %% handshake) with a 1-RTT STREAM must deliver {connected, _} before the
    %% stream events, so the owner opens its control stream before the request.
    #{
        state1 := State1,
        client_hs_secret := ClientHsSecret,
        cf_framed := ClientFinished,
        client_ap_secret := ClientApSecret
    } = connect(),
    Owner = self(),
    {State1b, _} = ?M:handle_call(Owner, make_ref(), {set_owner, Owner}, State1),
    Finished = ?TC:seal(
        handshake,
        0,
        roadrunner_quic_keys:traffic_keys(ClientHsSecret),
        [{crypto, 0, ClientFinished}],
        ?DCID,
        ?SCID
    ),
    Request = app_datagram([{stream, 0, 0, ~"hi", true}], 0, ClientApSecret),
    {_State2, Effects} = ?M:handle_datagram(?NOW, <<Finished/binary, Request/binary>>, State1b),
    ?assertEqual(
        [
            {emit, Owner, {connected, expected_info()}},
            {emit, Owner, {stream_opened, 0}},
            {emit, Owner, {stream_data, 0, ~"hi", true}}
        ],
        emits(Effects)
    ).

stream_without_owner_not_emitted_test() ->
    %% A connection that reached connected with no owner installed drops
    %% stream events rather than crashing.
    #{state2 := State, client_ap_secret := ApSecret} = connect(),
    Datagram = app_datagram([{stream, 0, 0, ~"hi", true}], 0, ApSecret),
    {_State1, Effects} = ?M:handle_datagram(?NOW, Datagram, State),
    ?assertEqual([], emits(Effects)).

%% =============================================================================
%% Application streams (send side)
%% =============================================================================

open_uni_allocates_server_uni_ids_test() ->
    %% Each open_unidirectional_stream hands out the next server-initiated uni
    %% id (RFC 9000 §2.1: 3, 7, 11, ...) and replies with it.
    {State, _ApSecret} = connected_for_send(),
    Ref1 = make_ref(),
    {State1, Effects1} = ?M:handle_call(self(), Ref1, open_uni, State),
    ?assertEqual([{reply, self(), Ref1, {ok, 3}}], Effects1),
    Ref2 = make_ref(),
    {_State2, Effects2} = ?M:handle_call(self(), Ref2, open_uni, State1),
    ?assertEqual([{reply, self(), Ref2, {ok, 7}}], Effects2).

send_data_emits_stream_frame_with_fin_test() ->
    %% A finished send becomes a single STREAM frame carrying the data and FIN,
    %% and the call is acknowledged with ok.
    {State, ApSecret} = connected_for_send(),
    Ref = make_ref(),
    {_State1, Effects} = ?M:handle_send(self(), Ref, 0, ~"hello", true, ?NOW, State),
    ?assertEqual({reply, self(), Ref, ok}, hd(Effects)),
    ?assertEqual([{stream, 0, 0, ~"hello", true}], sent_stream_frames(Effects, ApSecret)).

send_data_without_fin_leaves_stream_open_test() ->
    %% A non-final send carries Fin = false (used for the control stream's
    %% SETTINGS, which keeps the stream open).
    {State, ApSecret} = connected_for_send(),
    {_State1, Effects} = ?M:handle_send(self(), make_ref(), 3, ~"settings", false, ?NOW, State),
    ?assertEqual([{stream, 3, 0, ~"settings", false}], sent_stream_frames(Effects, ApSecret)).

send_data_multi_call_advances_offset_test() ->
    %% Successive sends on one stream advance the stream offset; the FIN rides
    %% the final write.
    {State, ApSecret} = connected_for_send(),
    {State1, E1} = ?M:handle_send(self(), make_ref(), 0, ~"foo", false, ?NOW, State),
    ?assertEqual([{stream, 0, 0, ~"foo", false}], sent_stream_frames(E1, ApSecret)),
    {_State2, E2} = ?M:handle_send(self(), make_ref(), 0, ~"bar", true, ?NOW, State1),
    ?assertEqual([{stream, 0, 3, ~"bar", true}], sent_stream_frames(E2, ApSecret)).

send_data_slices_large_payload_test() ->
    %% A payload larger than the per-packet budget is sliced across datagrams
    %% (one STREAM frame each), offsets contiguous, FIN on the last slice, and
    %% the bytes reassemble to the original.
    {State, ApSecret} = connected_for_send(),
    Payload = binary:copy(~"x", 2500),
    {_State1, Effects} = ?M:handle_send(self(), make_ref(), 0, Payload, true, ?NOW, State),
    Frames = sent_stream_frames(Effects, ApSecret),
    ?assertEqual([0, 1000, 2000], [Off || {stream, 0, Off, _, _} <- Frames]),
    ?assertEqual([false, false, true], [Fin || {stream, 0, _, _, Fin} <- Frames]),
    ?assertEqual(Payload, iolist_to_binary([D || {stream, 0, _, D, _} <- Frames])).

send_data_on_control_then_request_stream_test() ->
    %% The two load-bearing GET writes: SETTINGS on the server control stream
    %% (id 3) then a response on the client request stream (id 0), each on its
    %% own stream.
    {State, ApSecret} = connected_for_send(),
    {State1, E1} = ?M:handle_send(self(), make_ref(), 3, ~"settings", false, ?NOW, State),
    ?assertEqual([{stream, 3, 0, ~"settings", false}], sent_stream_frames(E1, ApSecret)),
    {_State2, E2} = ?M:handle_send(self(), make_ref(), 0, ~"response", true, ?NOW, State1),
    ?assertEqual([{stream, 0, 0, ~"response", true}], sent_stream_frames(E2, ApSecret)).

fully_sent_stream_is_skipped_on_later_pass_test() ->
    %% Once a stream is finished and drained, a later send pass (here driven by
    %% a peer PING that elicits an ACK) emits no STREAM frame for it.
    {State, ClientApSecret, ServerApSecret} = connect_owned(),
    {State1, _} = ?M:handle_send(self(), make_ref(), 0, ~"done", true, ?NOW, State),
    Ping = app_datagram([ping], 0, ClientApSecret),
    {_State2, Effects} = ?M:handle_datagram(?NOW, Ping, State1),
    ?assertEqual([], sent_stream_frames(Effects, ServerApSecret)).

%% =============================================================================
%% Connection close (peer-initiated)
%% =============================================================================

peer_connection_close_emits_closed_and_sends_nothing_test() ->
    %% A peer CONNECTION_CLOSE moves the connection to `closed`, surfaces
    %% {closed, {peer, ErrorCode}} to the owner, and sends nothing back.
    {State, ApSecret} = connected_with_owner(),
    Close = app_datagram([{connection_close, transport, 0, 0, <<>>}], 0, ApSecret),
    {State1, Effects} = ?M:handle_datagram(?NOW, Close, State),
    ?assertEqual(closed, ?M:phase(State1)),
    ?assertEqual([{emit, self(), {closed, {peer, 0}}}], emits(Effects)),
    ?assertEqual([], sends(Effects)).

frames_after_connection_close_are_ignored_test() ->
    %% Once a CONNECTION_CLOSE is seen, the rest of the packet is dropped: a
    %% trailing STREAM frame produces no stream events.
    {State, ApSecret} = connected_with_owner(),
    Close = app_datagram(
        [{connection_close, transport, 7, 0, <<>>}, {stream, 0, 0, ~"x", true}], 0, ApSecret
    ),
    {State1, Effects} = ?M:handle_datagram(?NOW, Close, State),
    ?assertEqual(closed, ?M:phase(State1)),
    ?assertEqual([{emit, self(), {closed, {peer, 7}}}], emits(Effects)).

peer_handshake_level_close_test() ->
    %% A transport CONNECTION_CLOSE at the Handshake level (the peer aborting
    %% mid-handshake) closes the connection just like a 1-RTT one.
    #{state1 := State1, client_hs_secret := ClientHsSecret} = connect(),
    Close = ?TC:seal(
        handshake,
        0,
        roadrunner_quic_keys:traffic_keys(ClientHsSecret),
        [{connection_close, transport, 2, 0, <<>>}],
        ?DCID,
        ?SCID
    ),
    {State2, Effects} = ?M:handle_datagram(?NOW, Close, with_owner(State1)),
    ?assertEqual(closed, ?M:phase(State2)),
    ?assertEqual([{emit, self(), {closed, {peer, 2}}}], emits(Effects)).

local_error_transmits_connection_close_test() ->
    %% A locally-detected error transmits one CONNECTION_CLOSE at the
    %% triggering packet's level (here application), carrying the mapped wire
    %% error code; a peer-initiated close, by contrast, sends nothing back.
    {State, ClientApSecret, ServerApSecret} = connect_owned(),
    Bad = app_datagram([{stream, 3, 0, ~"x", true}], 0, ClientApSecret),
    {_State1, Effects} = ?M:handle_datagram(?NOW, Bad, State),
    Frames = ?TC:frames(
        sends(Effects),
        application,
        #{application => roadrunner_quic_keys:traffic_keys(ServerApSecret)},
        byte_size(?DCID)
    ),
    ?assertEqual(
        [
            {connection_close, transport, roadrunner_quic_error:code_int(stream_state_error), 0,
                <<>>}
        ],
        Frames
    ).

undersized_initial_close_is_suppressed_test() ->
    %% A close that would breach the §8.1 3x budget for an undersized (spoofed
    %% or non-conformant) peer Initial is dropped, so the server is never an
    %% amplification reflector. The connection still closes and the owner still
    %% learns via {closed, _}, but nothing is sent back.
    {State0, _Ctx} = new_conn([~"leaf-cert-der"]),
    CloseFrame = iolist_to_binary(
        roadrunner_quic_frame:encode({connection_close, application, 7, undefined, <<>>})
    ),
    Tiny = ?TC:seal_raw(
        initial, 0, roadrunner_quic_keys:initial_client(?DCID), CloseFrame, ?DCID, ?SCID
    ),
    {State1, Effects} = ?M:handle_datagram(?NOW, Tiny, with_owner(State0)),
    ?assertEqual(closed, ?M:phase(State1)),
    ?assertEqual([{emit, self(), {closed, {local, protocol_violation}}}], emits(Effects)),
    ?assertEqual([], sends(Effects)).

coalesced_initial_error_then_handshake_does_not_crash_test() ->
    %% A datagram coalescing an Initial-level error (a 0x1d at Initial) with a
    %% Handshake packet must not let the Handshake packet's space-discard run
    %% after the close; the connection closes cleanly without crashing on the
    %% Initial keys the pending close still needs.
    #{state1 := State1, client_hs_secret := ClientHsSecret} = connect(),
    CloseFrame = iolist_to_binary(
        roadrunner_quic_frame:encode({connection_close, application, 7, undefined, <<>>})
    ),
    BadInitial = ?TC:seal_raw(
        initial, 0, roadrunner_quic_keys:initial_client(?DCID), CloseFrame, ?DCID, ?SCID
    ),
    HandshakePing = ?TC:seal(
        handshake, 1, roadrunner_quic_keys:traffic_keys(ClientHsSecret), [ping], ?DCID, ?SCID
    ),
    {State2, Effects} = ?M:handle_datagram(
        ?NOW, <<BadInitial/binary, HandshakePing/binary>>, with_owner(State1)
    ),
    ?assertEqual(closed, ?M:phase(State2)),
    ?assertEqual([{emit, self(), {closed, {local, protocol_violation}}}], emits(Effects)).

%% =============================================================================
%% Handshake driver (plays the QUIC client with the shared test client)
%% =============================================================================

%% Run a full RSA handshake against a fresh connection and return every
%% intermediate the assertions need.
connect() ->
    {State0, Ctx} = new_conn([~"leaf-cert-der"]),
    #{client_priv := ClientPriv, server_pub := ServerPub} = Ctx,

    %% Client Initial carrying the ClientHello.
    {InitialDatagram, ClientHelloFramed} = client_hello_datagram(Ctx),
    {State1, Effects1} = ?M:handle_datagram(?NOW, InitialDatagram, State0),
    Server1 = sends(Effects1),

    %% Recover the ServerHello and derive the handshake secrets.
    ServerHello = ?TC:crypto_bytes(
        Server1, initial, #{initial => roadrunner_quic_keys:initial_server(?DCID)}, byte_size(?DCID)
    ),
    Shared = crypto:compute_key(ecdh, ServerPub, ClientPriv, x25519),
    HandshakeSecret = roadrunner_quic_tls_crypto:handshake_secret(
        roadrunner_quic_tls_crypto:early_secret(), Shared
    ),
    HelloHash = roadrunner_quic_tls_crypto:transcript_hash([ClientHelloFramed, ServerHello]),
    ClientHsSecret = roadrunner_quic_tls_crypto:traffic_secret(
        client, handshake, HandshakeSecret, HelloHash
    ),
    ServerHsSecret = roadrunner_quic_tls_crypto:traffic_secret(
        server, handshake, HandshakeSecret, HelloHash
    ),

    %% Recover the server's authentication flight.
    Flight = ?TC:crypto_bytes(
        Server1,
        handshake,
        #{handshake => roadrunner_quic_keys:traffic_keys(ServerHsSecret)},
        byte_size(?DCID)
    ),
    FinishedHash = roadrunner_quic_tls_crypto:transcript_hash([
        ClientHelloFramed, ServerHello, Flight
    ]),

    %% Build and send the client Finished at the handshake level.
    ClientFinishedBody = roadrunner_quic_tls_crypto:verify_data(
        roadrunner_quic_tls_crypto:finished_key(ClientHsSecret), FinishedHash
    ),
    ClientFinishedFramed = iolist_to_binary(
        roadrunner_quic_tls_handshake:encode(?FINISHED, ClientFinishedBody)
    ),
    HandshakeDatagram = ?TC:seal(
        handshake,
        0,
        roadrunner_quic_keys:traffic_keys(ClientHsSecret),
        [{crypto, 0, ClientFinishedFramed}],
        ?DCID,
        ?SCID
    ),
    {State2, Effects2} = ?M:handle_datagram(?NOW, HandshakeDatagram, State1),

    %% Application keys, for reading the HANDSHAKE_DONE and sealing a
    %% post-connected client 1-RTT packet.
    MasterSecret = roadrunner_quic_tls_crypto:master_secret(HandshakeSecret),
    ServerApSecret = roadrunner_quic_tls_crypto:traffic_secret(
        server, application, MasterSecret, FinishedHash
    ),
    ClientApSecret = roadrunner_quic_tls_crypto:traffic_secret(
        client, application, MasterSecret, FinishedHash
    ),

    #{
        state0 => State0,
        state1 => State1,
        state2 => State2,
        effects1 => Effects1,
        effects2 => Effects2,
        sh_framed => ServerHello,
        flight => Flight,
        cf_framed => ClientFinishedFramed,
        client_hs_secret => ClientHsSecret,
        server_ap_secret => ServerApSecret,
        client_ap_secret => ClientApSecret,
        ctx => Ctx
    }.

%% A fresh server connection plus the client material the driver reuses.
new_conn(CertChain) ->
    {Scheme, PrivKey} = ?TC:key_material(),
    {ClientPub, ClientPriv} = ?TC:gen_keypair(),
    {ServerPub, ServerPriv} = ?TC:gen_keypair(),
    TransportParams = transport_params(),
    State = ?M:new(#{
        dcid => ?DCID,
        scid => ?SCID,
        peer => ?PEER,
        cert_chain => CertChain,
        priv_key => PrivKey,
        alpn => ~"h3",
        transport_params => TransportParams,
        eph_pub => ServerPub,
        eph_priv => ServerPriv,
        server_random => crypto:strong_rand_bytes(32)
    }),
    {State, #{
        scheme => Scheme,
        client_pub => ClientPub,
        client_priv => ClientPriv,
        server_pub => ServerPub
    }}.

%% The client Initial datagram and the framed ClientHello it carries (the
%% first transcript element).
client_hello_datagram(#{scheme := Scheme, client_pub := ClientPub}) ->
    Framed = ?TC:client_hello_framed(Scheme, ClientPub),
    Datagram = ?TC:seal(
        initial, 0, roadrunner_quic_keys:initial_client(?DCID), [{crypto, 0, Framed}], ?DCID, ?SCID
    ),
    {Datagram, Framed}.

sends(Effects) ->
    [Datagram || {send, Datagram} <- Effects].

is_ack({ack, _Largest, _Delay, _First, _Ranges, _Ecn}) -> true;
is_ack(_Frame) -> false.

transport_params() ->
    #{original_destination_connection_id => ?DCID, initial_source_connection_id => ?SCID}.

%% The connected payload conn_state caches at new/1 (alpn + advertised params).
expected_info() ->
    #{alpn => ~"h3", transport_params => transport_params()}.

%% Install this process as the owner (no emit while handshaking) so a later
%% close surfaces {closed, _} here.
with_owner(State) ->
    {State1, _} = ?M:handle_call(self(), make_ref(), {set_owner, self()}, State),
    State1.

%% Drive to connected with this process installed as owner (set during
%% handshaking, the normal ordering). Returns the state plus both application
%% secrets: the client secret seals peer 1-RTT packets (receive-side tests),
%% the server secret decodes the connection's own 1-RTT (send-side tests).
connect_owned() ->
    #{
        state1 := State1,
        client_hs_secret := ClientHsSecret,
        cf_framed := ClientFinished,
        client_ap_secret := ClientApSecret,
        server_ap_secret := ServerApSecret
    } = connect(),
    {State1b, _} = ?M:handle_call(self(), make_ref(), {set_owner, self()}, State1),
    Finished = ?TC:seal(
        handshake,
        0,
        roadrunner_quic_keys:traffic_keys(ClientHsSecret),
        [{crypto, 0, ClientFinished}],
        ?DCID,
        ?SCID
    ),
    {State2, _Effects} = ?M:handle_datagram(?NOW, Finished, State1b),
    {State2, ClientApSecret, ServerApSecret}.

%% Connected, owner installed, with the client secret for sealing peer 1-RTT.
connected_with_owner() ->
    {State2, ClientApSecret, _ServerApSecret} = connect_owned(),
    {State2, ClientApSecret}.

%% Connected, owner installed, with the server secret for decoding the
%% connection's own outbound 1-RTT.
connected_for_send() ->
    {State2, _ClientApSecret, ServerApSecret} = connect_owned(),
    {State2, ServerApSecret}.

%% Seal a peer 1-RTT (application) datagram carrying the given frames.
app_datagram(Frames, PN, ClientApSecret) ->
    ?TC:seal(
        application, PN, roadrunner_quic_keys:traffic_keys(ClientApSecret), Frames, ?DCID, ?SCID
    ).

%% Decode the application (1-RTT) frames the connection sent, then keep just
%% the STREAM frames.
sent_stream_frames(Effects, ServerApSecret) ->
    Frames = ?TC:frames(
        sends(Effects),
        application,
        #{application => roadrunner_quic_keys:traffic_keys(ServerApSecret)},
        byte_size(?DCID)
    ),
    [Frame || {stream, _Sid, _Off, _Data, _Fin} = Frame <- Frames].

emits(Effects) ->
    [Emit || {emit, _Owner, _Event} = Emit <- Effects].

arm_deadline(Effects) ->
    [AtMs] = [At || {arm_timer, pto, At} <- Effects],
    AtMs.
