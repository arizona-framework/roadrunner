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
%% match the server's fixed ?SCID_LEN, the client's source id (which the
%% server's replies are addressed to, RFC 9000 §7.2: distinct from both the
%% other two so a reply DCID can be attributed to exactly one of them), the
%% peer address, and a clock.
-define(DCID, <<1, 2, 3, 4, 5, 6, 7, 8>>).
-define(SCID, <<8, 7, 6, 5, 4, 3, 2, 1>>).
-define(CLIENT_SCID, <<11, 12, 13, 14, 15, 16, 17, 18>>).
-define(PEER, {{127, 0, 0, 1}, 12345}).
-define(NOW, 1000).
%% Must match roadrunner_quic_conn_state's ?IDLE_TIMEOUT default.
-define(IDLE_TIMEOUT, 30000).
%% Advertised receive windows (RFC 9000 §4.1), deliberately small and distinct
%% from roadrunner_quic_flow's 786432-byte default so a test can prove a window
%% is seeded from the advertised value rather than that default.
-define(CONN_RECV_WINDOW, 2000).
-define(STREAM_RECV_WINDOW, 1000).
%% Advertised stream-count limits (RFC 9000 §4.6), small and distinct so a
%% bidi/uni mix-up is caught. Existing tests open client-bidi ordinals 0..2
%% (stream ids 0, 4, 8), so the bidi limit must leave those within range.
-define(MAX_STREAMS_BIDI, 3).
-define(MAX_STREAMS_UNI, 2).

%% =============================================================================
%% Construction
%% =============================================================================

new_starts_handshaking_test() ->
    {State, _Ctx} = new_conn([~"leaf-cert-der"]),
    ?assertEqual(handshaking, ?M:phase(State)).

peername_answers_in_handshaking_test() ->
    {State, _Ctx} = new_conn([~"leaf-cert-der"]),
    ?assertEqual({ok, ?PEER}, ?M:peername(State)).

%% RFC 9000 §7.2/§17.2: a server addresses its replies with the client's source
%% connection id, not the client's destination id (which only derives the
%% Initial keys). A strict client matches inbound packets on its own source id,
%% so a reply carrying anything else is dropped. The reply's wire DCID must be
%% the configured peer_scid, distinct from both the routing dcid and the server
%% scid.
reply_addressed_to_client_source_cid_test() ->
    #{effects1 := Effects1} = connect(),
    [InitialReply | _] = sends(Effects1),
    {ok, #{dcid := ReplyDCID}} = roadrunner_quic_packet:long_header_info(InitialReply),
    ?assertEqual(?CLIENT_SCID, ReplyDCID),
    ?assertNotEqual(?DCID, ReplyDCID).

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

initial_scid_mismatch_closes_test() ->
    %% RFC 9000 §7.3: a client whose initial_source_connection_id does not equal
    %% the conn's peer_scid (?CLIENT_SCID) closes with transport_parameter_error,
    %% transmitted at the Initial level with wire code 0x08.
    {State0, #{scheme := Scheme, client_pub := ClientPub}} = new_conn([~"leaf-cert-der"]),
    Framed = ?TC:client_hello_framed(Scheme, ClientPub, ?DCID),
    Datagram = ?TC:seal(
        initial, 0, roadrunner_quic_keys:initial_client(?DCID), [{crypto, 0, Framed}], ?DCID, ?SCID
    ),
    {State1, Effects} = ?M:handle_datagram(?NOW, Datagram, with_owner(State0)),
    ?assertEqual(closed, ?M:phase(State1)),
    ?assertEqual([{emit, self(), {closed, {local, transport_parameter_error}}}], emits(Effects)),
    Frames = ?TC:frames(
        sends(Effects),
        initial,
        #{initial => roadrunner_quic_keys:initial_server(?DCID)},
        byte_size(?DCID)
    ),
    ExpectedCode = roadrunner_quic_error:code_int(transport_parameter_error),
    ?assertMatch([{connection_close, transport, ExpectedCode, 0, <<>>}], Frames).

missing_transport_params_closes_test() ->
    %% RFC 9001 §8.2: a ClientHello without the quic_transport_parameters
    %% extension closes with missing_transport_params, transmitted at the
    %% Initial level with wire code 0x016d (CRYPTO_ERROR + missing_extension).
    {State0, #{scheme := Scheme, client_pub := ClientPub}} = new_conn([~"leaf-cert-der"]),
    Framed = ?TC:client_hello_framed(Scheme, ClientPub, none),
    Datagram = ?TC:seal(
        initial, 0, roadrunner_quic_keys:initial_client(?DCID), [{crypto, 0, Framed}], ?DCID, ?SCID
    ),
    {State1, Effects} = ?M:handle_datagram(?NOW, Datagram, with_owner(State0)),
    ?assertEqual(closed, ?M:phase(State1)),
    ?assertEqual([{emit, self(), {closed, {local, missing_transport_params}}}], emits(Effects)),
    Frames = ?TC:frames(
        sends(Effects),
        initial,
        #{initial => roadrunner_quic_keys:initial_server(?DCID)},
        byte_size(?DCID)
    ),
    ExpectedCode = roadrunner_quic_error:code_int({crypto_error, 109}),
    ?assertMatch([{connection_close, transport, ExpectedCode, 0, <<>>}], Frames).

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
    ?assertEqual(draining, ?M:phase(State1)),
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

idle_timeout_closes_test() ->
    %% A fired idle timer silently closes the connection (RFC 9000 §10.1, no
    %% CONNECTION_CLOSE) and surfaces {closed, {local, idle_timeout}}.
    {State, _ApSecret} = connected_with_owner(),
    {State1, Effects} = ?M:handle_timeout(?NOW, idle, State),
    ?assertEqual(closed, ?M:phase(State1)),
    ?assertEqual([{emit, self(), {closed, {local, idle_timeout}}}], emits(Effects)),
    ?assertEqual([], sends(Effects)).

idle_timer_armed_when_nothing_in_flight_test() ->
    %% With no ack-eliciting bytes in flight (the peer just acknowledged the
    %% server's HANDSHAKE_DONE), the idle deadline (Now + ?IDLE_TIMEOUT) is the
    %% nearest, and only, timer armed.
    {State, ApSecret} = connected_with_owner(),
    Ack = app_datagram([{ack, 0, 0, 0, [], undefined}], 0, ApSecret),
    {_State1, Effects} = ?M:handle_datagram(?NOW, Ack, State),
    ?assertEqual([?NOW + ?IDLE_TIMEOUT], [At || {arm_timer, idle, At} <- Effects]).

idle_deadline_reset_on_receive_test() ->
    %% Each received datagram pushes the idle deadline to that datagram's Now +
    %% ?IDLE_TIMEOUT (RFC 9000 §10.1 reset-on-receive), proving the reset moved
    %% the deadline rather than leaving the birth anchor.
    {State, ApSecret} = connected_with_owner(),
    Later = ?NOW + 5000,
    Ack = app_datagram([{ack, 0, 0, 0, [], undefined}], 0, ApSecret),
    {_State1, Effects} = ?M:handle_datagram(Later, Ack, State),
    ?assertEqual([Later + ?IDLE_TIMEOUT], [At || {arm_timer, idle, At} <- Effects]).

idle_timer_armed_after_pto_backoff_test() ->
    %% With data in flight the probe timer is nearer (armed FIRST); only once
    %% repeated probe backoffs push the PTO deadline past the idle deadline is
    %% the idle timer armed instead.
    {State, _ApSecret} = connected_with_owner(),
    {State1, Effects1} = ?M:handle_timeout(?NOW, pto, State),
    ?assertNotEqual([], [At || {arm_timer, pto, At} <- Effects1]),
    ?assertNotEqual([], drive_until_idle_armed(State1, 12)).

drive_until_idle_armed(_State, 0) ->
    [];
drive_until_idle_armed(State, N) ->
    {State1, Effects} = ?M:handle_timeout(?NOW, pto, State),
    case [At || {arm_timer, idle, At} <- Effects] of
        [] -> drive_until_idle_armed(State1, N - 1);
        Idle -> Idle
    end.

negotiated_idle_timeout_test() ->
    %% RFC 9000 §10.1: the effective idle timeout is the minimum of the two
    %% advertised values, or the only non-zero one; with neither side advertising
    %% one it falls back to the ?IDLE_TIMEOUT default.
    ?assertEqual(?IDLE_TIMEOUT, ?M:negotiated_idle_timeout(#{}, #{})),
    ?assertEqual(5000, ?M:negotiated_idle_timeout(#{}, #{max_idle_timeout => 5000})),
    ?assertEqual(8000, ?M:negotiated_idle_timeout(#{max_idle_timeout => 8000}, #{})),
    ?assertEqual(
        5000,
        ?M:negotiated_idle_timeout(
            #{max_idle_timeout => 8000}, #{max_idle_timeout => 5000}
        )
    ).

%% =============================================================================
%% Control calls + owner notification
%% =============================================================================

peername_call_replies_test() ->
    {State, _Ctx} = new_conn([~"leaf-cert-der"]),
    Ref = make_ref(),
    ?assertEqual(
        {State, [{reply, self(), Ref, {ok, ?PEER}}]},
        ?M:handle_call(self(), Ref, peername, 0, State)
    ).

owner_set_in_handshaking_gets_connected_on_completion_test() ->
    %% The normal listener ordering: the owner is installed while still
    %% handshaking (no emit yet), then the confirming datagram emits
    %% {connected, _} to it exactly once.
    #{state1 := State1, client_hs_secret := ClientHsSecret, cf_framed := ClientFinished} = connect(),
    Owner = self(),
    Ref = make_ref(),
    {State1b, Installed} = ?M:handle_call(Owner, Ref, {set_owner, Owner}, 0, State1),
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
    {_State3, Effects} = ?M:handle_call(Owner, Ref, {set_owner, Owner}, 0, State2),
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
    {State1b, _} = ?M:handle_call(Owner, make_ref(), {set_owner, Owner}, 0, State1),
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
    ?assertEqual(draining, ?M:phase(State1)),
    ?assertEqual([{emit, self(), {closed, {local, stream_state_error}}}], emits(Effects)).

reset_stream_on_server_initiated_id_closes_test() ->
    %% A RESET_STREAM on a server-initiated id (rem 4 == 1) is likewise an
    %% RFC 9000 §19.4 STREAM_STATE_ERROR.
    {State, ApSecret} = connected_with_owner(),
    Bad = app_datagram([{reset_stream, 1, 7, 0}], 0, ApSecret),
    {State1, Effects} = ?M:handle_datagram(?NOW, Bad, State),
    ?assertEqual(draining, ?M:phase(State1)),
    ?assertEqual([{emit, self(), {closed, {local, stream_state_error}}}], emits(Effects)).

stream_over_advertised_bidi_count_closes_test() ->
    %% RFC 9000 §4.6: a client bidi stream whose ordinal (id div 4) reaches the
    %% advertised initial_max_streams_bidi is a STREAM_LIMIT_ERROR, transmitted
    %% at the 1-RTT level with wire code 0x04 (not the larger no-limit default).
    {State, ClientApSecret, ServerApSecret} = connect_owned(),
    OverLimit = ?MAX_STREAMS_BIDI * 4,
    Bad = app_datagram([{stream, OverLimit, 0, ~"x", true}], 0, ClientApSecret),
    {State1, Effects} = ?M:handle_datagram(?NOW, Bad, State),
    ?assertEqual(draining, ?M:phase(State1)),
    ?assertEqual([{emit, self(), {closed, {local, stream_limit_error}}}], emits(Effects)),
    ExpectedCode = roadrunner_quic_error:code_int(stream_limit_error),
    ?assert(
        lists:member(
            {connection_close, transport, ExpectedCode, 0, <<>>},
            sent_app_frames(Effects, ServerApSecret)
        )
    ).

stream_over_advertised_uni_count_closes_test() ->
    %% Same §4.6 limit on client unidirectional streams (rem 4 == 2), against the
    %% distinct initial_max_streams_uni.
    {State, ApSecret} = connected_with_owner(),
    OverLimit = ?MAX_STREAMS_UNI * 4 + 2,
    Bad = app_datagram([{stream, OverLimit, 0, ~"x", true}], 0, ApSecret),
    {State1, Effects} = ?M:handle_datagram(?NOW, Bad, State),
    ?assertEqual(draining, ?M:phase(State1)),
    ?assertEqual([{emit, self(), {closed, {local, stream_limit_error}}}], emits(Effects)).

reset_over_advertised_bidi_count_closes_test() ->
    %% A RESET_STREAM on an over-limit client bidi id is the same §4.6 error.
    {State, ApSecret} = connected_with_owner(),
    OverLimit = ?MAX_STREAMS_BIDI * 4,
    Bad = app_datagram([{reset_stream, OverLimit, 7, 0}], 0, ApSecret),
    {State1, Effects} = ?M:handle_datagram(?NOW, Bad, State),
    ?assertEqual(draining, ?M:phase(State1)),
    ?assertEqual([{emit, self(), {closed, {local, stream_limit_error}}}], emits(Effects)).

reset_over_advertised_uni_count_closes_test() ->
    %% A RESET_STREAM on an over-limit client uni id, against initial_max_streams_uni.
    {State, ApSecret} = connected_with_owner(),
    OverLimit = ?MAX_STREAMS_UNI * 4 + 2,
    Bad = app_datagram([{reset_stream, OverLimit, 7, 0}], 0, ApSecret),
    {State1, Effects} = ?M:handle_datagram(?NOW, Bad, State),
    ?assertEqual(draining, ?M:phase(State1)),
    ?assertEqual([{emit, self(), {closed, {local, stream_limit_error}}}], emits(Effects)).

stream_final_size_violation_closes_test() ->
    %% A FIN declaring a final size below the bytes already received is an
    %% RFC 9000 §4.5 connection error.
    {State, ApSecret} = connected_with_owner(),
    {State1, _} = ?M:handle_datagram(
        ?NOW, app_datagram([{stream, 0, 0, ~"hello", false}], 0, ApSecret), State
    ),
    Bad = app_datagram([{stream, 0, 0, <<>>, true}], 1, ApSecret),
    {State2, Effects} = ?M:handle_datagram(?NOW, Bad, State1),
    ?assertEqual(draining, ?M:phase(State2)),
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
    ?assertEqual(draining, ?M:phase(State2)),
    ?assertEqual([{emit, self(), {closed, {local, final_size_error}}}], emits(Effects)).

stream_over_advertised_stream_flow_limit_closes_test() ->
    %% A peer STREAM whose highest offset exceeds the per-stream receive window
    %% we advertised (initial_max_stream_data_bidi_remote) is an RFC 9000 §4.1
    %% flow-control connection error. The window is the advertised value (here
    %% ?STREAM_RECV_WINDOW, well under the connection window so it is what
    %% trips), not a larger hardcoded default that would let the overrun pass.
    {State, ApSecret} = connected_with_owner(),
    Oversized = binary:copy(~"x", ?STREAM_RECV_WINDOW + 1),
    Bad = app_datagram([{stream, 0, 0, Oversized, false}], 0, ApSecret),
    {State1, Effects} = ?M:handle_datagram(?NOW, Bad, State),
    ?assertEqual(draining, ?M:phase(State1)),
    ?assertEqual([{emit, self(), {closed, {local, flow_control_error}}}], emits(Effects)).

data_over_advertised_connection_flow_limit_closes_test() ->
    %% A STREAM frame whose length exceeds the advertised connection window
    %% (initial_max_data, checked before the per-stream window) is an RFC 9000
    %% §4.1 flow-control connection error. Incremental uploads within the window
    %% are instead kept flowing by MAX_DATA grants (see
    %% recv_window_refilled_with_max_data_and_max_stream_data_test); enforcement
    %% trips only on exceeding the current limit in one shot, ahead of any grant.
    {State, ApSecret} = connected_with_owner(),
    Oversized = binary:copy(~"x", ?CONN_RECV_WINDOW + 1),
    Bad = app_datagram([{stream, 0, 0, Oversized, false}], 0, ApSecret),
    {State1, Effects} = ?M:handle_datagram(?NOW, Bad, State),
    ?assertEqual(draining, ?M:phase(State1)),
    ?assertEqual([{emit, self(), {closed, {local, flow_control_error}}}], emits(Effects)).

%% As the peer uploads past the refill threshold, the server advertises fresh
%% receive credit with MAX_DATA (connection) and MAX_STREAM_DATA (stream) so a
%% large upload keeps flowing (RFC 9000 §4.1). 600 bytes is past 3/4 of both the
%% connection (2000) and stream (1000) windows.
recv_window_refilled_with_max_data_and_max_stream_data_test() ->
    {State, ClientApSecret, ServerApSecret} = connect_owned(),
    Upload = app_datagram([{stream, 0, 0, binary:copy(~"u", 600), false}], 0, ClientApSecret),
    {_State1, Effects} = ?M:handle_datagram(?NOW, Upload, State),
    Frames = sent_app_frames(Effects, ServerApSecret),
    ?assert(lists:member({max_data, 600 + ?CONN_RECV_WINDOW}, Frames)),
    ?assert(lists:member({max_stream_data, 0, 600 + ?STREAM_RECV_WINDOW}, Frames)).

stream_retransmit_does_not_re_consume_flow_test() ->
    %% Flow control is charged by the increase in the highest received offset,
    %% so resending bytes already received does not re-consume the receive
    %% window (RFC 9000 §4.1) even when the raw byte sum exceeds it; the
    %% duplicate also delivers no new stream_data.
    {State, ApSecret} = connected_with_owner(),
    Chunk = binary:copy(~"x", ?STREAM_RECV_WINDOW - 200),
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
    {State1b, _} = ?M:handle_call(Owner, make_ref(), {set_owner, Owner}, 0, State1),
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
    {State1, Effects1} = ?M:handle_call(self(), Ref1, open_uni, 0, State),
    ?assertEqual([{reply, self(), Ref1, {ok, 3}}], Effects1),
    Ref2 = make_ref(),
    {_State2, Effects2} = ?M:handle_call(self(), Ref2, open_uni, 0, State1),
    ?assertEqual([{reply, self(), Ref2, {ok, 7}}], Effects2).

send_data_emits_stream_frame_with_fin_test() ->
    %% A finished send becomes a single STREAM frame carrying the data and FIN,
    %% and the call is acknowledged with ok.
    {State, ApSecret} = connected_for_send(),
    Ref = make_ref(),
    {_State1, Effects} = ?M:handle_send(self(), Ref, 0, ~"hello", true, ?NOW, State),
    ?assertEqual({reply, self(), Ref, ok}, hd(Effects)),
    ?assertEqual([{stream, 0, 0, ~"hello", true}], sent_stream_frames(Effects, ApSecret)).

reset_stream_sends_reset_with_final_size_test() ->
    %% reset_stream abandons the send side and emits a RESET_STREAM whose Final
    %% Size is the bytes already sent (5 from the prior send), and replies ok.
    {State, ApSecret} = connected_for_send(),
    {State1, _} = ?M:handle_send(self(), make_ref(), 0, ~"hello", false, ?NOW, State),
    Ref = make_ref(),
    {_State2, Effects} = ?M:handle_call(self(), Ref, {reset_stream, 0, 7}, ?NOW, State1),
    ?assertEqual({reply, self(), Ref, ok}, hd(Effects)),
    ?assert(lists:member({reset_stream, 0, 7, 5}, sent_app_frames(Effects, ApSecret))).

stop_sending_sends_stop_sending_frame_test() ->
    %% stop_sending emits a STOP_SENDING frame for the stream and replies ok.
    {State, ApSecret} = connected_for_send(),
    Ref = make_ref(),
    {_State1, Effects} = ?M:handle_call(self(), Ref, {stop_sending, 0, 7}, ?NOW, State),
    ?assertEqual({reply, self(), Ref, ok}, hd(Effects)),
    ?assert(lists:member({stop_sending, 0, 7}, sent_app_frames(Effects, ApSecret))).

owner_close_sends_application_close_test() ->
    %% An owner close sends one application-variant CONNECTION_CLOSE carrying the
    %% h3 error code and reason phrase, lingers in draining with a drain timer
    %% armed, and replies ok (no {closed, _} back: the owner triggered it).
    {State, ApSecret} = connected_for_send(),
    Ref = make_ref(),
    {State1, Effects} = ?M:handle_call(self(), Ref, {close, 16#0100, ~"bye"}, ?NOW, State),
    ?assertEqual(draining, ?M:phase(State1)),
    ?assertEqual({reply, self(), Ref, ok}, hd(Effects)),
    ?assertEqual([], emits(Effects)),
    ?assertMatch([_], [At || {arm_timer, drain, At} <- Effects]),
    ?assert(
        lists:member(
            {connection_close, application, 16#0100, undefined, ~"bye"},
            sent_app_frames(Effects, ApSecret)
        )
    ).

owner_close_without_reason_sends_empty_phrase_test() ->
    %% close/2 (no reason) carries an empty reason phrase.
    {State, ApSecret} = connected_for_send(),
    {State1, Effects} = ?M:handle_call(self(), make_ref(), {close, 16#0100}, ?NOW, State),
    ?assertEqual(draining, ?M:phase(State1)),
    ?assert(
        lists:member(
            {connection_close, application, 16#0100, undefined, <<>>},
            sent_app_frames(Effects, ApSecret)
        )
    ).

owner_close_before_connected_closes_silently_test() ->
    %% A close before the handshake completes (no 1-RTT keys, e.g. the
    %% connection_handler refusing on max_clients) closes the connection without
    %% sending a CONNECTION_CLOSE there are no application keys to seal one.
    #{state0 := State0} = connect(),
    {State1, Effects} = ?M:handle_call(self(), make_ref(), {close, 16#0100}, ?NOW, State0),
    ?assertEqual(closed, ?M:phase(State1)),
    ?assertEqual([], sends(Effects)).

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
    %% the bytes reassemble to the original. Each slice fills toward the
    %% 1200-byte datagram, so the first slice carries well past the bytes an
    %% old fixed 1000-byte budget would have allowed.
    {State, ApSecret} = connected_for_send(),
    Payload = binary:copy(~"x", 2500),
    {_State1, Effects} = ?M:handle_send(self(), make_ref(), 0, Payload, true, ?NOW, State),
    Frames = sent_stream_frames(Effects, ApSecret),
    Sizes = [byte_size(D) || {stream, 0, _, D, _} <- Frames],
    ?assert(length(Frames) > 1),
    ?assert(hd(Sizes) > 1000),
    ?assertEqual(expected_offsets(0, Sizes), [Off || {stream, 0, Off, _, _} <- Frames]),
    ?assertEqual([false, false, true], [Fin || {stream, 0, _, _, Fin} <- Frames]),
    ?assertEqual(Payload, iolist_to_binary([D || {stream, 0, _, D, _} <- Frames])).

send_blocked_by_exhausted_send_window_test() ->
    %% Send-side flow control (RFC 9000 §4.1): across ACK-paced rounds (which grow
    %% the congestion window past the flow window) the server sends at most the
    %% client's advertised 800000-byte initial_max_data / initial_max_stream_data
    %% (see roadrunner_quic_test_client), proving the cap is sourced from the peer
    %% rather than roadrunner_quic_flow's 786432 default.
    {State, ClientApSecret, ServerApSecret} = connect_owned(),
    Window = 800000,
    Payload = binary:copy(~"x", Window + 1000),
    {State1, Effects} = ?M:handle_send(self(), make_ref(), 0, Payload, false, ?NOW, State),
    {Sent, _State2, _AckPN} = flush_with_acks(State1, Effects, ServerApSecret, ClientApSecret, 0),
    ?assertEqual(Window, byte_size(Sent)).

send_resumes_after_max_data_and_max_stream_data_test() ->
    %% After the send window fills (RFC 9000 §4.1), the peer's MAX_DATA /
    %% MAX_STREAM_DATA grants raise the connection and per-stream send limits and
    %% the rest of the payload reaches the wire on the following ACK-paced rounds.
    {State, ClientApSecret, ServerApSecret} = connect_owned(),
    Window = 800000,
    Payload = binary:copy(~"x", Window + 1000),
    {State1, Effects} = ?M:handle_send(self(), make_ref(), 0, Payload, false, ?NOW, State),
    {Sent1, State2, AckPN} = flush_with_acks(State1, Effects, ServerApSecret, ClientApSecret, 0),
    ?assertEqual(Window, byte_size(Sent1)),
    Grant = app_datagram(
        [{max_data, Window * 2}, {max_stream_data, 0, Window * 2}], AckPN, ClientApSecret
    ),
    {State3, E3} = ?M:handle_datagram(?NOW, Grant, State2),
    {Sent2, _State4, _} = flush_with_acks(State3, E3, ServerApSecret, ClientApSecret, AckPN + 1),
    ?assert(byte_size(Sent2) > 0),
    ?assertEqual(byte_size(Payload), byte_size(Sent1) + byte_size(Sent2)).

congestion_window_caps_first_burst_test() ->
    %% A payload far larger than the initial congestion window is capped at about
    %% one window on the first pass, with no ACKs yet to grow it (RFC 9002 §7).
    {State, ServerApSecret} = connected_for_send(),
    Payload = binary:copy(~"x", 100000),
    {State1, Effects} = ?M:handle_send(self(), make_ref(), 0, Payload, false, ?NOW, State),
    Sent = iolist_to_binary([
        D
     || {stream, 0, _, D, _} <- sent_stream_frames(Effects, ServerApSecret)
    ]),
    ?assert(byte_size(Sent) < byte_size(Payload)),
    %% Initial window 12000 bytes; the strict-< gate allows one datagram overshoot.
    ?assert(byte_size(Sent) =< 12000 + 1200),
    ?assertEqual(12000, ?M:cwnd(State1)).

ack_grows_congestion_window_test() ->
    %% Acknowledging in-flight packets grows the window in slow start (RFC 9002
    %% §7.3.1); a duplicate ACK that acknowledges nothing new does not.
    {State, ClientApSecret, ServerApSecret} = connect_owned(),
    Payload = binary:copy(~"x", 100000),
    {State1, Effects} = ?M:handle_send(self(), make_ref(), 0, Payload, false, ?NOW, State),
    Largest = largest_app_pn(Effects, ServerApSecret),
    Ack = app_datagram([{ack, Largest, 0, Largest, [], undefined}], 0, ClientApSecret),
    {State2, _E2} = ?M:handle_datagram(?NOW, Ack, State1),
    Grown = ?M:cwnd(State2),
    ?assert(Grown > ?M:cwnd(State1)),
    Dup = app_datagram([{ack, Largest, 0, Largest, [], undefined}], 1, ClientApSecret),
    {State3, _E3} = ?M:handle_datagram(?NOW, Dup, State2),
    ?assertEqual(Grown, ?M:cwnd(State3)).

loss_halves_congestion_window_test() ->
    %% A gap ACK that acknowledges only the largest packet leaves the older
    %% packets past the packet threshold, so they are declared lost and the window
    %% halves (RFC 9002 §7.3.2).
    {State, ClientApSecret, ServerApSecret} = connect_owned(),
    Payload = binary:copy(~"x", 100000),
    {State1, Effects} = ?M:handle_send(self(), make_ref(), 0, Payload, false, ?NOW, State),
    Largest = largest_app_pn(Effects, ServerApSecret),
    Gap = app_datagram([{ack, Largest, 0, 0, [], undefined}], 0, ClientApSecret),
    {State2, _E2} = ?M:handle_datagram(?NOW, Gap, State1),
    ?assert(?M:cwnd(State2) < ?M:cwnd(State1)).

ack_only_datagram_not_congestion_controlled_test() ->
    %% A datagram carrying only an ACK is not ack-eliciting, so the congestion
    %% window never gates it (RFC 9002 §7): the gate short-circuits on
    %% not-ack-eliciting before consulting the window, full or not. A peer PING
    %% with no server data to send produces exactly such an ACK-only datagram.
    {State, ClientApSecret, ServerApSecret} = connect_owned(),
    Ping = app_datagram([ping], 0, ClientApSecret),
    {_State1, Effects} = ?M:handle_datagram(?NOW, Ping, State),
    ?assert(lists:any(fun is_ack/1, sent_app_frames(Effects, ServerApSecret))).

max_stream_data_for_untracked_stream_ignored_test() ->
    %% A MAX_STREAM_DATA grant for a stream the server is not tracking is ignored
    %% (on_max_stream_data's unknown-id branch); the connection survives.
    {State, ClientApSecret, _ServerApSecret} = connect_owned(),
    Grant = app_datagram([{max_stream_data, 4, 1000000}], 0, ClientApSecret),
    {State1, _Effects} = ?M:handle_datagram(?NOW, Grant, State),
    ?assertEqual(connected, ?M:phase(State1)).

%% A request stream finishes both ways (client FIN received, server response +
%% FIN sent) and is pruned. A later STREAM frame for that id carrying data past
%% its final size would be a final_size_error and close the connection if the
%% stream were still tracked; pruned and guarded as closed (RFC 9000 §3) it is
%% ignored and the connection stays up.
terminal_stream_is_pruned_and_late_frame_ignored_test() ->
    {State0, ClientApSecret, _ServerApSecret} = connect_owned(),
    Req = app_datagram([{stream, 0, 0, ~"req", true}], 0, ClientApSecret),
    {State1, _} = ?M:handle_datagram(?NOW, Req, State0),
    {State2, _} = ?M:handle_send(self(), make_ref(), 0, ~"resp", true, ?NOW, State1),
    Late = app_datagram([{stream, 0, 100, ~"late", false}], 1, ClientApSecret),
    {State3, _} = ?M:handle_datagram(?NOW, Late, State2),
    ?assertEqual(connected, ?M:phase(State3)).

%% After a stream is pruned, a genuinely new request on a higher id (above the
%% per-type high-water) still opens normally.
new_stream_after_prune_opens_test() ->
    {State0, ClientApSecret, _ServerApSecret} = connect_owned(),
    Req0 = app_datagram([{stream, 0, 0, ~"a", true}], 0, ClientApSecret),
    {State1, _} = ?M:handle_datagram(?NOW, Req0, State0),
    {State2, _} = ?M:handle_send(self(), make_ref(), 0, ~"r", true, ?NOW, State1),
    Req4 = app_datagram([{stream, 4, 0, ~"b", true}], 1, ClientApSecret),
    {_State3, Effects} = ?M:handle_datagram(?NOW, Req4, State2),
    ?assert(lists:member({stream_opened, 4}, [E || {emit, _Owner, E} <- Effects])).

%% A late/reordered RESET_STREAM for a pruned stream is ignored as closed
%% (RFC 9000 §3), not recreated; the connection stays up.
reset_for_pruned_stream_ignored_test() ->
    {State0, ClientApSecret, _ServerApSecret} = connect_owned(),
    Req = app_datagram([{stream, 0, 0, ~"req", true}], 0, ClientApSecret),
    {State1, _} = ?M:handle_datagram(?NOW, Req, State0),
    {State2, _} = ?M:handle_send(self(), make_ref(), 0, ~"resp", true, ?NOW, State1),
    Rst = app_datagram([{reset_stream, 0, 7, 3}], 1, ClientApSecret),
    {State3, _} = ?M:handle_datagram(?NOW, Rst, State2),
    ?assertEqual(connected, ?M:phase(State3)).

%% As the peer opens bidi streams toward the advertised limit (test TP = 3), the
%% server raises the limit and sends MAX_STREAMS so the peer can keep opening
%% request streams (RFC 9000 §4.6). The first open is still within credit (no
%% grant); the second crosses the refill threshold and grants a fresh window.
max_streams_granted_as_bidi_credit_consumed_test() ->
    {State0, ClientApSecret, ServerApSecret} = connect_owned(),
    Open0 = app_datagram([{stream, 0, 0, ~"a", true}], 0, ClientApSecret),
    {State1, E0} = ?M:handle_datagram(?NOW, Open0, State0),
    ?assertEqual([], max_streams_frames(E0, ServerApSecret)),
    Open4 = app_datagram([{stream, 4, 0, ~"b", true}], 1, ClientApSecret),
    {_State2, E4} = ?M:handle_datagram(?NOW, Open4, State1),
    ?assertEqual([{max_streams, bidi, 5}], max_streams_frames(E4, ServerApSecret)).

max_streams_frames(Effects, ServerApSecret) ->
    [F || {max_streams, _, _} = F <- sent_app_frames(Effects, ServerApSecret)].

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
    %% A peer CONNECTION_CLOSE on an established connection lingers in `draining`
    %% with a drain timer armed, surfaces {closed, {peer, ErrorCode}} to the
    %% owner, and sends nothing back (RFC 9000 §10.2).
    {State, ApSecret} = connected_with_owner(),
    Close = app_datagram([{connection_close, transport, 0, 0, <<>>}], 0, ApSecret),
    {State1, Effects} = ?M:handle_datagram(?NOW, Close, State),
    ?assertEqual(draining, ?M:phase(State1)),
    ?assertEqual([{emit, self(), {closed, {peer, 0}}}], emits(Effects)),
    ?assertEqual([], sends(Effects)),
    [DrainAt] = [At || {arm_timer, drain, At} <- Effects],
    ?assert(DrainAt > ?NOW).

frames_after_connection_close_are_ignored_test() ->
    %% Once a CONNECTION_CLOSE is seen, the rest of the packet is dropped: a
    %% trailing STREAM frame produces no stream events.
    {State, ApSecret} = connected_with_owner(),
    Close = app_datagram(
        [{connection_close, transport, 7, 0, <<>>}, {stream, 0, 0, ~"x", true}], 0, ApSecret
    ),
    {State1, Effects} = ?M:handle_datagram(?NOW, Close, State),
    ?assertEqual(draining, ?M:phase(State1)),
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

late_packet_during_draining_is_absorbed_test() ->
    %% A packet arriving during the drain window is absorbed silently (RFC 9000
    %% §10.2.2): the phase stays draining, the late frame is not reprocessed,
    %% nothing is sent, and no timer is re-armed so the entry drain timer keeps
    %% running.
    {State, ApSecret} = connected_with_owner(),
    Close = app_datagram([{connection_close, transport, 0, 0, <<>>}], 0, ApSecret),
    {Draining, _} = ?M:handle_datagram(?NOW, Close, State),
    Late = app_datagram([{stream, 0, 0, ~"x", true}], 1, ApSecret),
    {Draining1, Effects} = ?M:handle_datagram(?NOW + 10, Late, Draining),
    ?assertEqual(draining, ?M:phase(Draining1)),
    ?assertEqual([], sends(Effects)),
    ?assertEqual([], emits(Effects)),
    ?assertEqual([], [E || {arm_timer, _, _} = E <- Effects]).

drain_timeout_closes_test() ->
    %% When the drain timer fires the connection becomes closed (the shell then
    %% tears it down); the owner already learned of the close on entry, so the
    %% timeout emits nothing.
    {State, ApSecret} = connected_with_owner(),
    Close = app_datagram([{connection_close, transport, 0, 0, <<>>}], 0, ApSecret),
    {Draining, _} = ?M:handle_datagram(?NOW, Close, State),
    {Closed, Effects} = ?M:handle_timeout(?NOW + 999999, drain, Draining),
    ?assertEqual(closed, ?M:phase(Closed)),
    ?assertEqual([], Effects).

send_on_draining_connection_is_rejected_test() ->
    %% RFC 9000 §10.2.2: a draining connection sends no application data; an owner
    %% write is answered {error, closed} and nothing goes out.
    {State, ApSecret} = connected_with_owner(),
    Close = app_datagram([{connection_close, transport, 0, 0, <<>>}], 0, ApSecret),
    {Draining, _} = ?M:handle_datagram(?NOW, Close, State),
    Ref = make_ref(),
    {Draining1, Effects} = ?M:handle_send(self(), Ref, 0, ~"data", true, ?NOW, Draining),
    ?assertEqual(draining, ?M:phase(Draining1)),
    ?assertEqual([{reply, self(), Ref, {error, closed}}], Effects),
    ?assertEqual([], sends(Effects)).

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
    State = ?M:new(
        #{
            dcid => ?DCID,
            scid => ?SCID,
            peer_scid => ?CLIENT_SCID,
            peer => ?PEER,
            cert_chain => CertChain,
            priv_key => PrivKey,
            alpn => ~"h3",
            transport_params => TransportParams,
            eph_pub => ServerPub,
            eph_priv => ServerPriv,
            server_random => crypto:strong_rand_bytes(32)
        },
        ?NOW
    ),
    {State, #{
        scheme => Scheme,
        client_pub => ClientPub,
        client_priv => ClientPriv,
        server_pub => ServerPub
    }}.

%% The client Initial datagram and the framed ClientHello it carries (the
%% first transcript element).
client_hello_datagram(#{scheme := Scheme, client_pub := ClientPub}) ->
    Framed = ?TC:client_hello_framed(Scheme, ClientPub, ?CLIENT_SCID),
    Datagram = ?TC:seal(
        initial, 0, roadrunner_quic_keys:initial_client(?DCID), [{crypto, 0, Framed}], ?DCID, ?SCID
    ),
    {Datagram, Framed}.

sends(Effects) ->
    [Datagram || {send, Datagram} <- Effects].

is_ack({ack, _Largest, _Delay, _First, _Ranges, _Ecn}) -> true;
is_ack(_Frame) -> false.

transport_params() ->
    #{
        original_destination_connection_id => ?DCID,
        initial_source_connection_id => ?SCID,
        initial_max_data => ?CONN_RECV_WINDOW,
        initial_max_stream_data_bidi_remote => ?STREAM_RECV_WINDOW,
        initial_max_stream_data_uni => ?STREAM_RECV_WINDOW,
        initial_max_streams_bidi => ?MAX_STREAMS_BIDI,
        initial_max_streams_uni => ?MAX_STREAMS_UNI
    }.

%% The connected payload conn_state caches at new/1 (alpn + advertised params).
expected_info() ->
    #{alpn => ~"h3", transport_params => transport_params()}.

%% Install this process as the owner (no emit while handshaking) so a later
%% close surfaces {closed, _} here.
with_owner(State) ->
    {State1, _} = ?M:handle_call(self(), make_ref(), {set_owner, self()}, 0, State),
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
    {State1b, _} = ?M:handle_call(self(), make_ref(), {set_owner, self()}, 0, State1),
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

%% Every frame the server put on the wire at the application level (decoded with
%% its 1-RTT keys), for asserting control frames like RESET_STREAM/STOP_SENDING.
sent_app_frames(Effects, ServerApSecret) ->
    ?TC:frames(
        sends(Effects),
        application,
        #{application => roadrunner_quic_keys:traffic_keys(ServerApSecret)},
        byte_size(?DCID)
    ).

emits(Effects) ->
    [Emit || {emit, _Owner, _Event} = Emit <- Effects].

%% The largest 1-RTT packet number among the server's sent datagrams, decoded
%% with the server's application keys; used to acknowledge what is in flight.
largest_app_pn(Effects, ServerApSecret) ->
    Keys = #{application => roadrunner_quic_keys:traffic_keys(ServerApSecret)},
    PNs = [
        PN
     || Datagram <- sends(Effects),
        {ok, #{level := application, pn := PN}} <-
            roadrunner_quic_recv:datagram(Datagram, byte_size(?DCID), Keys, #{})
    ],
    lists:max(PNs).

%% Drive send + ACK rounds until the server stops sending stream-0 data
%% (flow-blocked): each cumulative ACK grows the congestion window and frees the
%% in-flight bytes so the next pass sends more. Returns the total stream bytes
%% sent, the final state, and the next free client packet number.
flush_with_acks(State, Effects, ServerApSecret, ClientApSecret, AckPN) ->
    Sent = iolist_to_binary([
        D
     || {stream, 0, _, D, _} <- sent_stream_frames(Effects, ServerApSecret)
    ]),
    case Sent of
        <<>> ->
            {<<>>, State, AckPN};
        _ ->
            Largest = largest_app_pn(Effects, ServerApSecret),
            Ack = app_datagram([{ack, Largest, 0, Largest, [], undefined}], AckPN, ClientApSecret),
            {State1, Effects1} = ?M:handle_datagram(?NOW, Ack, State),
            {Rest, Final, FinalAckPN} = flush_with_acks(
                State1, Effects1, ServerApSecret, ClientApSecret, AckPN + 1
            ),
            {<<Sent/binary, Rest/binary>>, Final, FinalAckPN}
    end.

arm_deadline(Effects) ->
    [AtMs] = [At || {arm_timer, pto, At} <- Effects],
    AtMs.

%% The contiguous send offsets for a run of slice sizes: each offset is the
%% total bytes emitted before it.
expected_offsets(_Acc, []) ->
    [];
expected_offsets(Acc, [Size | Rest]) ->
    [Acc | expected_offsets(Acc + Size, Rest)].
