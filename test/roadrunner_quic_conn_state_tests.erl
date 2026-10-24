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
%% Key exchange groups (RFC 8446 §4.2.7).
-define(GROUP_SECP256R1, 16#0017).
-define(GROUP_X25519, 16#001D).

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

%% A client offering only TLS_CHACHA20_POLY1305_SHA256 completes the handshake
%% on ChaCha20-Poly1305 packet protection with ChaCha20 header protection (RFC
%% 9001 §5.3, §5.4.4): the driver reads the server's Handshake flight with
%% ChaCha20 keys, the server opens the ChaCha20-sealed client Finished, and its
%% HANDSHAKE_DONE opens under the ChaCha20 1-RTT keys. The Initial packets stay
%% AES-128-GCM (§5.2).
chacha20_handshake_reaches_connected_test() ->
    #{state2 := State2, effects2 := Effects2, server_ap_secret := ServerApSecret, aead := Aead} =
        connect(#{}, #{cipher_suites => [16#1303]}),
    ?assertEqual(chacha20_poly1305, Aead),
    ?assertEqual(connected, ?M:phase(State2)),
    Frames = ?TC:frames(
        sends(Effects2),
        application,
        #{application => roadrunner_quic_keys:traffic_keys(chacha20_poly1305, ServerApSecret)},
        byte_size(?DCID)
    ),
    ?assert(lists:member(handshake_done, Frames)).

%% The server answers in the group of the client's share (x25519) with its
%% own ephemeral share, generated per connection.
server_hello_carries_server_key_share_test() ->
    #{sh_framed := ServerHello, ctx := #{client_pub := ClientPub}} = connect(),
    [{2, Body}] = ?TC:deframe_all(ServerHello),
    #{group := Group, key_share := ServerShare} = ?TC:parse_server_hello(Body),
    ?assertEqual(?GROUP_X25519, Group),
    ?assertMatch(<<_:32/binary>>, ServerShare),
    ?assertNotEqual(ClientPub, ServerShare),
    #{sh_framed := OtherServerHello} = connect(),
    ?assertNotEqual(ServerShare, ?TC:server_hello_key_share(OtherServerHello)).

%% A client offering only secp256r1 completes the handshake over P-256 ECDHE:
%% the server's share is an uncompressed P-256 point (RFC 8446 §4.2.8.2).
p256_handshake_reaches_connected_test() ->
    {P256Pub, P256Priv} = crypto:generate_key(ecdh, secp256r1),
    #{state2 := State2, sh_framed := ServerHello} =
        connect(#{}, #{key_shares => [{?GROUP_SECP256R1, P256Pub}], client_priv => P256Priv}),
    ?assertEqual(connected, ?M:phase(State2)),
    [{2, Body}] = ?TC:deframe_all(ServerHello),
    ?assertMatch(
        #{group := ?GROUP_SECP256R1, key_share := <<4, _:64/binary>>},
        ?TC:parse_server_hello(Body)
    ).

%% A client that lists x25519 but sends no key share gets a HelloRetryRequest
%% as the only Initial CRYPTO data (RFC 8446 §4.1.4, RFC 9001 §4.7), and the
%% connection keeps handshaking. Its second ClientHello follows in the Initial
%% CRYPTO stream at the next offset; the ServerHello then follows the
%% HelloRetryRequest in the server's Initial CRYPTO stream, and the handshake
%% completes over the message_hash transcript (RFC 8446 §4.4.1).
hello_retry_request_reaches_connected_test() ->
    {State0, #{scheme := Scheme, client_pub := ClientPub, client_priv := ClientPriv}} =
        new_conn([~"leaf-cert-der"]),
    ClientHello1 = ?TC:client_hello_framed(#{
        scheme => Scheme, key_shares => [], groups => [?GROUP_X25519], client_scid => ?CLIENT_SCID
    }),
    {State1, Effects1} = ?M:handle_datagram(?NOW, initial_datagram(0, 0, ClientHello1), State0),
    ?assertEqual(handshaking, ?M:phase(State1)),
    InitialKeys = #{initial => roadrunner_quic_keys:initial_server(?DCID)},
    [{crypto, 0, HelloRetryRequest}] =
        [
            F
         || {crypto, _, _} = F <- ?TC:frames(
                sends(Effects1), initial, InitialKeys, byte_size(?DCID)
            )
        ],
    [{2, HelloRetryBody}] = ?TC:deframe_all(HelloRetryRequest),
    ?assertMatch(#{group := ?GROUP_X25519}, ?TC:parse_server_hello(HelloRetryBody)),
    ?assertNot(maps:is_key(key_share, ?TC:parse_server_hello(HelloRetryBody))),

    ClientHello2 = ?TC:client_hello_framed(#{
        scheme => Scheme, key_shares => [{?GROUP_X25519, ClientPub}], client_scid => ?CLIENT_SCID
    }),
    Datagram2 = initial_datagram(1, byte_size(ClientHello1), ClientHello2),
    {State2, Effects2} = ?M:handle_datagram(?NOW, Datagram2, State1),
    [{crypto, ServerHelloOffset, _}] =
        [
            F
         || {crypto, _, _} = F <- ?TC:frames(
                sends(Effects2), initial, InitialKeys, byte_size(?DCID)
            )
        ],
    ?assertEqual(byte_size(HelloRetryRequest), ServerHelloOffset),

    MessageHash = <<254, 32:24, (crypto:hash(sha256, ClientHello1))/binary>>,
    #{state2 := State3} = finish_handshake(
        State2, Effects2, [MessageHash, HelloRetryRequest, ClientHello2], ClientPriv
    ),
    ?assertEqual(connected, ?M:phase(State3)).

%% RFC 8446 §4.1.2: a ClientHello after the server flight (here a second one
%% at the next Initial CRYPTO offset, before the client Finished) closes with
%% the TLS unexpected_message alert, 0x010a.
client_hello_after_flight_closes_test() ->
    #{state1 := State1, ch_framed := ClientHello} = connect(),
    Datagram = initial_datagram(1, byte_size(ClientHello), ClientHello),
    {State2, Effects} = ?M:handle_datagram(?NOW, Datagram, with_owner(State1)),
    ?assertEqual(closed, ?M:phase(State2)),
    ?assertEqual([{emit, self(), {closed, {local, unexpected_message}}}], emits(Effects)),
    ?assertMatch([{connection_close, transport, 16#010a, 0, <<>>}], initial_close_frames(Effects)).

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
        #{application => roadrunner_quic_keys:traffic_keys(aes_128_gcm, ServerApSecret)},
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

ack_for_unsent_packet_closes_test() ->
    %% RFC 9000 §13.1: an ACK for a packet the server never sent in that space
    %% is a PROTOCOL_VIOLATION.
    #{state1 := State1} = connect(),
    Datagram = ?TC:seal(
        initial,
        1,
        roadrunner_quic_keys:initial_client(?DCID),
        [{ack, 70000, 0, 0, [], undefined}],
        ?DCID,
        ?SCID
    ),
    {State2, Effects} = ?M:handle_datagram(?NOW, Datagram, with_owner(State1)),
    ?assertEqual(closed, ?M:phase(State2)),
    ?assertEqual([{emit, self(), {closed, {local, protocol_violation}}}], emits(Effects)).

negative_ack_range_closes_test() ->
    %% RFC 9000 §19.3.1: an ACK range reaching below packet number 0 is a
    %% FRAME_ENCODING_ERROR.
    #{state1 := State1} = connect(),
    Datagram = ?TC:seal(
        initial,
        1,
        roadrunner_quic_keys:initial_client(?DCID),
        [{ack, 0, 0, 1, [], undefined}],
        ?DCID,
        ?SCID
    ),
    {State2, Effects} = ?M:handle_datagram(?NOW, Datagram, with_owner(State1)),
    ?assertEqual(closed, ?M:phase(State2)),
    ?assertEqual([{emit, self(), {closed, {local, frame_encoding_error}}}], emits(Effects)).

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
    WrongKeys = #{key => {aes_128_gcm, <<0:128>>}, iv => <<0:96>>, hp => {aes_128_ecb, <<0:128>>}},
    Datagram = ?TC:seal(initial, 0, WrongKeys, [{crypto, 0, ~"hello"}], ?DCID, ?SCID),
    {State1, Effects} = ?M:handle_datagram(?NOW, Datagram, State0),
    ?assertEqual(handshaking, ?M:phase(State1)),
    ?assertEqual([], sends(Effects)).

malformed_frame_closes_test() ->
    %% RFC 9000 §12.4: an authenticated payload that decodes to a malformed
    %% frame (a CRYPTO frame claiming eight bytes but carrying three) is a
    %% FRAME_ENCODING_ERROR.
    {State0, _Ctx} = new_conn([~"leaf-cert-der"]),
    Datagram = ?TC:seal_raw(
        initial,
        0,
        roadrunner_quic_keys:initial_client(?DCID),
        <<16#06, 16#00, 16#08, 1, 2, 3>>,
        ?DCID,
        ?SCID
    ),
    {State1, Effects} = ?M:handle_datagram(?NOW, Datagram, with_owner(State0)),
    ?assertEqual(closed, ?M:phase(State1)),
    ?assertEqual([{emit, self(), {closed, {local, frame_encoding_error}}}], emits(Effects)).

reserved_bits_close_with_protocol_violation_test() ->
    %% RFC 9000 §17.2: a long-header packet whose reserved bits are non-zero
    %% (detected only after the packet authenticates) is a PROTOCOL_VIOLATION;
    %% the decision core closes rather than processing the packet.
    {State0, _Ctx} = new_conn([~"leaf-cert-der"]),
    %% Pad like a real client Initial (RFC 9000 §14.1) so the server's 3x
    %% anti-amplification budget covers the 1200-byte Initial CONNECTION_CLOSE.
    Datagram = ?TC:seal_raw_reserved(
        initial,
        0,
        roadrunner_quic_keys:initial_client(?DCID),
        binary:copy(<<0>>, 400),
        ?DCID,
        ?SCID
    ),
    {State1, Effects} = ?M:handle_datagram(?NOW, Datagram, with_owner(State0)),
    ?assertEqual(closed, ?M:phase(State1)),
    ?assertEqual([{emit, self(), {closed, {local, protocol_violation}}}], emits(Effects)),
    Frames = ?TC:frames(
        sends(Effects),
        initial,
        #{initial => roadrunner_quic_keys:initial_server(?DCID)},
        byte_size(?DCID)
    ),
    Code = roadrunner_quic_error:code_int(protocol_violation),
    ?assertEqual([{connection_close, transport, Code, 0, <<>>}], Frames).

packet_for_discarded_space_ignored_test() ->
    %% One datagram coalescing the client Finished (which confirms the
    %% handshake and discards the Handshake space) with a trailing handshake
    %% packet that then lands on the now-absent space.
    #{state1 := State1, client_hs_secret := ClientHsSecret, cf_framed := ClientFinished} = connect(),
    HsKeys = roadrunner_quic_keys:traffic_keys(aes_128_gcm, ClientHsSecret),
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
    HsKeys = roadrunner_quic_keys:traffic_keys(aes_128_gcm, ClientHsSecret),
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

%% A ClientHello whose supported_versions lacks TLS 1.3 closes with the TLS
%% protocol_version alert (70), 0x0146, at the Initial level (RFC 8446 §4.2.1,
%% RFC 9001 §4.8).
no_tls_1_3_closes_with_protocol_version_test() ->
    assert_client_hello_closes(#{versions => [16#0303]}, protocol_version, 16#0146).

%% No cipher suite in common is a handshake_failure (40), 0x0128 (RFC 8446
%% §4.1.1, RFC 9001 §4.8).
no_common_cipher_suite_closes_test() ->
    assert_client_hello_closes(#{cipher_suites => [16#1302]}, no_common_cipher_suite, 16#0128).

%% No group in common is a handshake_failure too (RFC 8446 §4.1.1).
no_common_group_closes_test() ->
    assert_client_hello_closes(
        #{key_shares => [{16#0018, crypto:strong_rand_bytes(97)}]}, no_common_group, 16#0128
    ).

%% A ClientHello without supported_groups closes with the TLS
%% missing_extension alert (109), 0x016d (RFC 8446 §9.2).
missing_supported_groups_closes_test() ->
    assert_client_hello_closes(#{groups => none}, missing_extension, 16#016d).

%% A key share that is not a valid x25519 public value closes with the TLS
%% illegal_parameter alert (47), 0x012f (RFC 8446 §4.2.8.2).
invalid_key_share_closes_test() ->
    assert_client_hello_closes(
        #{key_shares => [{?GROUP_X25519, <<1, 2, 3>>}]}, illegal_parameter, 16#012f
    ).

assert_client_hello_closes(HelloOpts, Reason, Code) ->
    {State0, Ctx} = new_conn([~"leaf-cert-der"]),
    {Datagram, _Framed} = client_hello_datagram(Ctx, HelloOpts),
    {State1, Effects} = ?M:handle_datagram(?NOW, Datagram, with_owner(State0)),
    ?assertEqual(closed, ?M:phase(State1)),
    ?assertEqual([{emit, self(), {closed, {local, Reason}}}], emits(Effects)),
    ?assertMatch([{connection_close, transport, Code, 0, <<>>}], initial_close_frames(Effects)).

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
    ?assertEqual([{emit, self(), {closed, {local, unexpected_message}}}], emits(Effects)),
    %% RFC 9001 §4.8 / §6: the TLS unexpected_message alert (10), 0x010a.
    ?assertMatch([{connection_close, transport, 16#010a, 0, <<>>}], initial_close_frames(Effects)).

handshake_level_tls_message_closes_test_() ->
    %% RFC 9001 §6 / §8.3: a KeyUpdate after the client Finished, or an
    %% EndOfEarlyData before it, is a TLS unexpected_message (0x010a). The
    %% EndOfEarlyData stops the fold before the Finished confirms the
    %% handshake, so its close goes at the Handshake level; the KeyUpdate
    %% follows the Finished, so its close goes at 1-RTT (RFC 9000 §10.2.3).
    EndOfEarlyData = <<5, 0, 0, 0>>,
    KeyUpdate = <<16#18, 0, 0, 1, 1>>,
    [
        ?_test(
            assert_handshake_crypto_closes(
                fun(Fin) -> <<EndOfEarlyData/binary, Fin/binary>> end, handshake
            )
        ),
        ?_test(
            assert_handshake_crypto_closes(
                fun(Fin) -> <<Fin/binary, KeyUpdate/binary>> end, application
            )
        )
    ].

assert_handshake_crypto_closes(Wrap, CloseLevel) ->
    #{
        state1 := State1,
        client_hs_secret := ClientHsSecret,
        server_hs_secret := ServerHsSecret,
        server_ap_secret := ServerApSecret,
        cf_framed := ClientFinished
    } = connect(),
    {State1b, _} = ?M:handle_call(self(), make_ref(), {set_owner, self()}, 0, State1),
    Datagram = ?TC:seal(
        handshake,
        0,
        roadrunner_quic_keys:traffic_keys(aes_128_gcm, ClientHsSecret),
        [{crypto, 0, Wrap(ClientFinished)}],
        ?DCID,
        ?SCID
    ),
    {State2, Effects} = ?M:handle_datagram(?NOW, Datagram, State1b),
    ?assertMatch({emit, _, {closed, {local, unexpected_message}}}, lists:last(emits(Effects))),
    ?assertNotEqual(connected, ?M:phase(State2)),
    Secrets = #{handshake => ServerHsSecret, application => ServerApSecret},
    Frames = ?TC:frames(
        sends(Effects),
        CloseLevel,
        #{
            CloseLevel => roadrunner_quic_keys:traffic_keys(
                aes_128_gcm, maps:get(CloseLevel, Secrets)
            )
        },
        byte_size(?DCID)
    ),
    ?assert(lists:member({connection_close, transport, 16#010a, 0, <<>>}, Frames)).

crypto_beyond_buffer_limit_closes_test() ->
    %% RFC 9000 §7.5: a CRYPTO frame reaching past what the server buffers
    %% ahead of the TLS layer closes with CRYPTO_BUFFER_EXCEEDED.
    {State0, _Ctx} = new_conn([~"leaf-cert-der"]),
    Datagram = ?TC:seal(
        initial,
        0,
        roadrunner_quic_keys:initial_client(?DCID),
        [{crypto, 100000000, ~"x"}],
        ?DCID,
        ?SCID
    ),
    {State1, Effects} = ?M:handle_datagram(?NOW, Datagram, with_owner(State0)),
    ?assertEqual(closed, ?M:phase(State1)),
    ?assertEqual([{emit, self(), {closed, {local, crypto_buffer_exceeded}}}], emits(Effects)),
    ExpectedCode = roadrunner_quic_error:code_int(crypto_buffer_exceeded),
    ?assertMatch(
        [{connection_close, transport, ExpectedCode, 0, <<>>}], initial_close_frames(Effects)
    ).

crypto_within_buffer_limit_held_test() ->
    %% An out-of-order CRYPTO frame ending exactly at the limit is held.
    {State0, _Ctx} = new_conn([~"leaf-cert-der"]),
    Datagram = ?TC:seal(
        initial,
        0,
        roadrunner_quic_keys:initial_client(?DCID),
        [{crypto, 65535, ~"x"}],
        ?DCID,
        ?SCID
    ),
    {State1, Effects} = ?M:handle_datagram(?NOW, Datagram, with_owner(State0)),
    ?assertEqual(handshaking, ?M:phase(State1)),
    ?assertEqual([], emits(Effects)).

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

stream_frame_at_initial_level_closes_test() ->
    %% RFC 9000 §12.4 / §12.5: STREAM is 0-RTT/1-RTT only; one in an Initial
    %% packet is a protocol violation.
    {State0, _Ctx} = new_conn([~"leaf-cert-der"]),
    Datagram = ?TC:seal(
        initial,
        0,
        roadrunner_quic_keys:initial_client(?DCID),
        [{stream, 0, 0, ~"x", false}],
        ?DCID,
        ?SCID
    ),
    {State1, Effects} = ?M:handle_datagram(?NOW, Datagram, with_owner(State0)),
    ?assertEqual(closed, ?M:phase(State1)),
    ?assertEqual([{emit, self(), {closed, {local, protocol_violation}}}], emits(Effects)).

handshake_level_frame_placement_test_() ->
    %% RFC 9000 §12.4 / §12.5: PATH_CHALLENGE, DATA_BLOCKED and
    %% STREAM_DATA_BLOCKED are 0-RTT/1-RTT only; one in a Handshake packet is
    %% a protocol violation.
    [
        ?_test(assert_handshake_frame_closes(Frame))
     || Frame <- [
            {path_challenge, <<0:64>>}, {data_blocked, 0}, {stream_data_blocked, 0, 0}
        ]
    ].

assert_handshake_frame_closes(Frame) ->
    #{state1 := State1, client_hs_secret := ClientHsSecret} = connect(),
    Datagram = ?TC:seal(
        handshake,
        1,
        roadrunner_quic_keys:traffic_keys(aes_128_gcm, ClientHsSecret),
        [Frame],
        ?DCID,
        ?SCID
    ),
    {State2, Effects} = ?M:handle_datagram(?NOW, Datagram, with_owner(State1)),
    ?assertEqual(closed, ?M:phase(State2)),
    ?assertEqual([{emit, self(), {closed, {local, protocol_violation}}}], emits(Effects)).

server_only_frame_from_client_closes_test_() ->
    %% RFC 9000 §19.7 / §19.20: only a server sends NEW_TOKEN and
    %% HANDSHAKE_DONE; a server receiving either closes with
    %% PROTOCOL_VIOLATION, even at 1-RTT where both may appear.
    [
        ?_test(assert_1rtt_frame_closes(Frame))
     || Frame <- [{new_token, ~"token"}, handshake_done]
    ].

assert_1rtt_frame_closes(Frame) ->
    {State, ApSecret} = connected_with_owner(),
    {State1, Effects} = ?M:handle_datagram(?NOW, app_datagram([Frame], 0, ApSecret), State),
    ?assertEqual(draining, ?M:phase(State1)),
    ?assertEqual([{emit, self(), {closed, {local, protocol_violation}}}], emits(Effects)).

retire_unissued_connection_id_closes_test() ->
    %% RFC 9000 §19.16: the server only ever issued sequence number 0, so
    %% retiring a higher one is a PROTOCOL_VIOLATION.
    {State, ApSecret} = connected_with_owner(),
    Retire = app_datagram([{retire_connection_id, 1}], 0, ApSecret),
    {State1, Effects} = ?M:handle_datagram(?NOW, Retire, State),
    ?assertEqual(draining, ?M:phase(State1)),
    ?assertEqual([{emit, self(), {closed, {local, protocol_violation}}}], emits(Effects)).

unhandled_1rtt_frames_accepted_test() ->
    %% The 1-RTT frames the server does not act on yet are still legal there
    %% and leave the connection open.
    {State, ApSecret} = connected_with_owner(),
    Frames = [
        {data_blocked, 0},
        {path_challenge, <<0:64>>},
        {max_streams, bidi, 10},
        {retire_connection_id, 0}
    ],
    {State1, Effects} = ?M:handle_datagram(?NOW, app_datagram(Frames, 0, ApSecret), State),
    ?assertEqual(connected, ?M:phase(State1)),
    ?assertEqual([], emits(Effects)).

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

pto_sends_a_probe_test() ->
    %% RFC 9002 §6.2.4: a probe timeout sends an ack-eliciting probe. Loss
    %% detection only counts a packet older than one the peer acknowledged, so
    %% with nothing acknowledged it finds no loss to resend, and only a probe
    %% gets the flight acknowledged.
    {State, _ClientApSecret, ServerApSecret} = connect_owned(),
    {State1, _} = ?M:handle_send(self(), make_ref(), 0, ~"tail", true, ?NOW, State),
    {_State2, Effects} = ?M:handle_timeout(?NOW + 5000, pto, State1),
    ?assert(
        lists:any(
            fun roadrunner_quic_send:is_ack_eliciting/1, sent_app_frames(Effects, ServerApSecret)
        )
    ).

pto_probe_passes_a_full_congestion_window_test() ->
    %% Probes MUST NOT be blocked by the congestion controller (RFC 9002
    %% §7.5): with the window full of unacknowledged data, the probe still
    %% goes out.
    {State, _ClientApSecret, ServerApSecret} = connect_owned(),
    Payload = binary:copy(~"x", 100000),
    {State1, _} = ?M:handle_send(self(), make_ref(), 0, Payload, false, ?NOW, State),
    {_State2, Effects} = ?M:handle_timeout(?NOW + 5000, pto, State1),
    ?assertNotEqual([], sends(Effects)),
    ?assert(
        lists:any(
            fun roadrunner_quic_send:is_ack_eliciting/1, sent_app_frames(Effects, ServerApSecret)
        )
    ).

pto_probe_resends_what_it_finds_lost_test() ->
    %% With a later packet acknowledged, the probe timeout finds the older one
    %% lost on time: the resent data is the probe, with no PING added.
    {State, ClientApSecret, ServerApSecret} = connect_owned(),
    Payload = binary:copy(~"x", 2000),
    {State1, Sent} = ?M:handle_send(self(), make_ref(), 0, Payload, true, ?NOW, State),
    Largest = largest_app_pn(Sent, ServerApSecret),
    Ack = app_datagram([{ack, Largest, 0, 0, [], undefined}], 0, ClientApSecret),
    {State2, _} = ?M:handle_datagram(?NOW, Ack, State1),
    {_State3, Effects} = ?M:handle_timeout(?NOW + 5000, pto, State2),
    Frames = sent_app_frames(Effects, ServerApSecret),
    ?assertMatch([{stream, 0, 0, _, false} | _], [F || {stream, _, _, _, _} = F <- Frames]),
    ?assertNot(lists:member(ping, Frames)).

path_challenge_answered_test() ->
    %% RFC 9000 §8.2.2: a PATH_CHALLENGE gets a PATH_RESPONSE echoing its data.
    {State, ClientApSecret, ServerApSecret} = connect_owned(),
    Challenge = app_datagram([{path_challenge, ~"8 bytes!"}], 0, ClientApSecret),
    {State1, Effects} = ?M:handle_datagram(?NOW, Challenge, State),
    ?assertEqual(connected, ?M:phase(State1)),
    ?assert(lists:member({path_response, ~"8 bytes!"}, sent_app_frames(Effects, ServerApSecret))).

lost_path_response_not_resent_test() ->
    %% RFC 9000 §13.3: a PATH_RESPONSE is sent once. With a later packet
    %% acknowledged, the probe timeout finds the response's packet lost and
    %% resends the rest of it, never the response.
    {State, ClientApSecret, ServerApSecret} = connect_owned(),
    Challenge = app_datagram([{path_challenge, ~"8 bytes!"}], 0, ClientApSecret),
    {State1, _} = ?M:handle_datagram(?NOW, Challenge, State),
    {State2, Sent} = ?M:handle_send(self(), make_ref(), 0, ~"later", true, ?NOW, State1),
    Largest = largest_app_pn(Sent, ServerApSecret),
    Ack = app_datagram([{ack, Largest, 0, 0, [], undefined}], 1, ClientApSecret),
    {State3, _} = ?M:handle_datagram(?NOW, Ack, State2),
    {_State4, Effects} = ?M:handle_timeout(?NOW + 5000, pto, State3),
    Frames = sent_app_frames(Effects, ServerApSecret),
    ?assertNotEqual([], Frames),
    ?assertEqual([], [F || {path_response, _} = F <- Frames]).

retransmit_of_several_lost_packets_fits_datagrams_test() ->
    %% RFC 9000 §14: every datagram stays within 1200 bytes. Losing several
    %% full packets queues all their STREAM frames for retransmission; they go
    %% out over as many datagrams as they need, never one oversized one, and
    %% every lost byte is sent again.
    {State, ClientApSecret, ServerApSecret} = connect_owned(),
    Payload = binary:copy(~"x", 5000),
    {State1, Sent} = ?M:handle_send(self(), make_ref(), 0, Payload, true, ?NOW, State),
    Largest = largest_app_pn(Sent, ServerApSecret),
    Ack = app_datagram([{ack, Largest, 0, 0, [], undefined}], 0, ClientApSecret),
    {State2, AckEffects} = ?M:handle_datagram(?NOW, Ack, State1),
    {_State3, PtoEffects} = ?M:handle_timeout(?NOW + 5000, pto, State2),
    Resent = sends(AckEffects) ++ sends(PtoEffects),
    ?assertEqual([], [byte_size(D) || D <- Resent, byte_size(D) > 1200]),
    LastFrames = sent_stream_frames(Sent, ServerApSecret),
    LostBytes = lists:sum([byte_size(Data) || {stream, 0, _, Data, _} <- lists:droplast(LastFrames)]),
    ResentFrames =
        sent_stream_frames(AckEffects, ServerApSecret) ++
            sent_stream_frames(PtoEffects, ServerApSecret),
    ?assertEqual(
        LostBytes, lists:sum([byte_size(Data) || {stream, 0, _, Data, _} <- ResentFrames])
    ).

fit_frames_splits_crypto_test() ->
    %% A CRYPTO frame past the room splits at an offset: the head fills the
    %% room exactly and the tail carries on from where it stops.
    Data = binary:copy(~"c", 500),
    {[{crypto, 100, Head}], [{crypto, Next, Tail}]} = ?M:fit_frames([{crypto, 100, Data}], 200),
    ?assertEqual(200, iolist_size(roadrunner_quic_frame:encode({crypto, 100, Head}))),
    ?assertEqual(100 + byte_size(Head), Next),
    ?assertEqual(Data, <<Head/binary, Tail/binary>>).

fit_frames_keeps_what_does_not_fit_test() ->
    %% A frame that cannot be split, or a STREAM / CRYPTO frame with no room
    %% for a data byte, waits whole for the next packet, as does all after it.
    Token = {new_token, binary:copy(~"t", 50)},
    Ping = ping,
    ?assertEqual({[Ping], [Token, Ping]}, ?M:fit_frames([Ping, Token, Ping], 20)),
    ?assertEqual({[], [{crypto, 0, ~"abc"}]}, ?M:fit_frames([{crypto, 0, ~"abc"}], 3)),
    ?assertEqual(
        {[], [{stream, 0, 0, ~"abc", true}]}, ?M:fit_frames([{stream, 0, 0, ~"abc", true}], 3)
    ).

pto_deadline_not_pushed_back_by_peer_packets_test() ->
    %% RFC 9002 §6.2.1: the probe timeout counts from the last ack-eliciting
    %% packet sent. Peer PINGs arriving later (no RTT sample, nothing acked)
    %% re-arm the timer at the same deadline rather than one counted from
    %% their arrival. Two of them make the ACK due at once, so no delayed-ACK
    %% deadline comes before the probe.
    {State, ClientApSecret, _ServerApSecret} = connect_owned(),
    {State1, Sent} = ?M:handle_send(self(), make_ref(), 0, ~"data", false, ?NOW, State),
    [{arm_timer, pto, Deadline}] = [T || {arm_timer, _, _} = T <- Sent],
    {State2, _} = ?M:handle_datagram(?NOW + 100, app_datagram([ping], 0, ClientApSecret), State1),
    {_State3, Effects} = ?M:handle_datagram(
        ?NOW + 100, app_datagram([ping], 1, ClientApSecret), State2
    ),
    ?assertEqual([{arm_timer, pto, Deadline}], [T || {arm_timer, _, _} = T <- Effects]).

%% RFC 9002 §6.2.4: a probe timeout that finds nothing lost probes with the
%% oldest unacknowledged data rather than a PING, so a lost tail is already
%% on its way again instead of waiting for the ACK a PING would draw.
pto_probe_carries_unacked_tail_test() ->
    {State, ClientApSecret, ServerApSecret} = connect_owned(),
    AckDone = app_datagram([{ack, 0, 0, 0, [], undefined}], 0, ClientApSecret),
    {State1, _} = ?M:handle_datagram(?NOW, AckDone, State),
    {State2, _} = ?M:handle_send(self(), make_ref(), 0, ~"tail", true, ?NOW, State1),
    {_State3, Effects} = ?M:handle_timeout(?NOW + 5000, pto, State2),
    Frames = sent_app_frames(Effects, ServerApSecret),
    ?assert(lists:member({stream, 0, 0, ~"tail", true}, Frames)),
    ?assertNot(lists:member(ping, Frames)).

%% With only data that must not be resent in flight (a PATH_RESPONSE, sent
%% once, RFC 9000 §13.3), the probe falls back to a PING.
pto_probe_pings_when_nothing_to_resend_test() ->
    {State, ClientApSecret, ServerApSecret} = connect_owned(),
    AckDone = app_datagram([{ack, 0, 0, 0, [], undefined}], 0, ClientApSecret),
    {State1, _} = ?M:handle_datagram(?NOW, AckDone, State),
    Challenge = app_datagram([{path_challenge, ~"8 bytes!"}], 1, ClientApSecret),
    {State2, _} = ?M:handle_datagram(?NOW, Challenge, State1),
    {_State3, Effects} = ?M:handle_timeout(?NOW + 5000, pto, State2),
    Frames = sent_app_frames(Effects, ServerApSecret),
    ?assert(lists:member(ping, Frames)),
    ?assertEqual([], [F || {path_response, _} = F <- Frames]).

pto_probe_ack_recovers_a_lost_tail_test() ->
    %% The last packet of a response is lost. The probe draws an ACK of the
    %% probe alone, which shows the older packet lost, and it is sent again.
    {State, ClientApSecret, ServerApSecret} = connect_owned(),
    {State1, _} = ?M:handle_send(self(), make_ref(), 0, ~"tail", true, ?NOW, State),
    {State2, Probe} = ?M:handle_timeout(?NOW + 5000, pto, State1),
    ProbePN = largest_app_pn(Probe, ServerApSecret),
    Ack = app_datagram([{ack, ProbePN, 0, 0, [], undefined}], 0, ClientApSecret),
    {_State3, Effects} = ?M:handle_datagram(?NOW + 5010, Ack, State2),
    ?assertEqual([{stream, 0, 0, ~"tail", true}], sent_stream_frames(Effects, ServerApSecret)).

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
        roadrunner_quic_keys:traffic_keys(aes_128_gcm, ClientHsSecret),
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
        roadrunner_quic_keys:traffic_keys(aes_128_gcm, ClientHsSecret),
        [{crypto, 0, ClientFinished}],
        ?DCID,
        ?SCID
    ),
    {State2, FirstEffects} = ?M:handle_datagram(?NOW, Finished, State1b),
    ?assertEqual([{emit, Owner, {connected, expected_info()}}], emits(FirstEffects)),
    %% A processed 1-RTT packet once connected: still exactly zero re-emits.
    AppPing = ?TC:seal(
        application,
        0,
        roadrunner_quic_keys:traffic_keys(aes_128_gcm, ClientApSecret),
        [ping],
        ?DCID,
        ?SCID
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

%% With `stream_credit => on_read` a request stream's credit waits for its
%% owner to consume the data (`handle_consumed/4`): the connection's MAX_DATA
%% still goes out on receipt, MAX_STREAM_DATA only once 600 bytes are read.
held_stream_credit_granted_on_consumption_test() ->
    {State, ClientApSecret, ServerApSecret} = connect_owned(#{stream_credit => on_read}),
    Upload = app_datagram([{stream, 0, 0, binary:copy(~"u", 600), false}], 0, ClientApSecret),
    {State1, Effects} = ?M:handle_datagram(?NOW, Upload, State),
    Frames = sent_app_frames(Effects, ServerApSecret),
    ?assert(lists:member({max_data, 600 + ?CONN_RECV_WINDOW}, Frames)),
    ?assertEqual([], [F || {max_stream_data, _, _} = F <- Frames]),
    {_State2, Granted} = ?M:handle_consumed(0, 600, ?NOW, State1),
    ?assert(
        lists:member(
            {max_stream_data, 0, 600 + ?STREAM_RECV_WINDOW},
            sent_app_frames(Granted, ServerApSecret)
        )
    ).

%% Bytes consumed on a stream already gone grant nothing.
consumed_on_unknown_stream_test() ->
    {State, _ServerApSecret} = connected_for_send(),
    ?assertEqual({State, []}, ?M:handle_consumed(4, 100, ?NOW, State)).

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
        roadrunner_quic_keys:traffic_keys(aes_128_gcm, ClientHsSecret),
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

%% The server opens no more unidirectional streams than the client's
%% initial_max_streams_uni allows (RFC 9000 §4.6): with the limit of 1 used up,
%% the open is refused and a STREAMS_BLOCKED carrying the limit goes out
%% (§19.14).
open_uni_refused_past_peer_limit_test() ->
    {State, _ClientApSecret, ServerApSecret} = connect_owned(
        #{}, #{transport_params => #{initial_max_streams_uni => 1}}
    ),
    {State1, _} = ?M:handle_call(self(), make_ref(), open_uni, ?NOW, State),
    Ref = make_ref(),
    {_State2, Effects} = ?M:handle_call(self(), Ref, open_uni, ?NOW, State1),
    ?assertEqual({reply, self(), Ref, {error, stream_limit}}, hd(Effects)),
    ?assertEqual(
        [{streams_blocked, uni, 1}],
        [F || {streams_blocked, _, _} = F <- sent_app_frames(Effects, ServerApSecret)]
    ).

%% A client that advertises no initial_max_streams_uni allows none (absent ->
%% 0, RFC 9000 §18.2), so even the first open is refused.
open_uni_refused_without_peer_param_test() ->
    {State, _ClientApSecret, _ServerApSecret} = connect_owned(
        #{}, #{transport_params => #{initial_max_streams_uni => 0}}
    ),
    Ref = make_ref(),
    {_State1, Effects} = ?M:handle_call(self(), Ref, open_uni, ?NOW, State),
    ?assertEqual({reply, self(), Ref, {error, stream_limit}}, hd(Effects)).

%% A MAX_STREAMS (uni) raises the limit, so a refused open then succeeds
%% (RFC 9000 §19.11); a later one that would lower it is ignored, so the
%% raised limit still holds.
max_streams_uni_raises_server_limit_test() ->
    {State, ClientApSecret, _ServerApSecret} = connect_owned(
        #{}, #{transport_params => #{initial_max_streams_uni => 0}}
    ),
    Frames = [{max_streams, uni, 2}, {max_streams, uni, 1}],
    {State1, _} = ?M:handle_datagram(?NOW, app_datagram(Frames, 0, ClientApSecret), State),
    Ref1 = make_ref(),
    {State2, Effects1} = ?M:handle_call(self(), Ref1, open_uni, ?NOW, State1),
    ?assertEqual([{reply, self(), Ref1, {ok, 3}}], Effects1),
    Ref2 = make_ref(),
    {State3, Effects2} = ?M:handle_call(self(), Ref2, open_uni, ?NOW, State2),
    ?assertEqual([{reply, self(), Ref2, {ok, 7}}], Effects2),
    Ref3 = make_ref(),
    {_State4, Effects3} = ?M:handle_call(self(), Ref3, open_uni, ?NOW, State3),
    ?assertEqual({reply, self(), Ref3, {error, stream_limit}}, hd(Effects3)).

%% A MAX_STREAMS (bidi) is accepted and ignored: the server opens no
%% bidirectional streams (RFC 9114 §6.1), and it does not touch the uni limit.
max_streams_bidi_ignored_test() ->
    {State, ClientApSecret, _ServerApSecret} = connect_owned(
        #{}, #{transport_params => #{initial_max_streams_uni => 0}}
    ),
    Datagram = app_datagram([{max_streams, bidi, 10}], 0, ClientApSecret),
    {State1, _} = ?M:handle_datagram(?NOW, Datagram, State),
    ?assertEqual(connected, ?M:phase(State1)),
    Ref = make_ref(),
    {_State2, Effects} = ?M:handle_call(self(), Ref, open_uni, ?NOW, State1),
    ?assertEqual({reply, self(), Ref, {error, stream_limit}}, hd(Effects)).

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

send_window_exhaustion_emits_blocked_frames_test() ->
    %% RFC 9000 §4.1 / §19.12-13: when a send fills the connection and
    %% per-stream limits, the server signals each once with DATA_BLOCKED /
    %% STREAM_DATA_BLOCKED carrying the limit it hit, so the peer knows to
    %% grant more credit.
    {State, ClientApSecret, ServerApSecret} = connect_owned(),
    Window = 800000,
    Payload = binary:copy(~"x", Window + 1000),
    {State1, Effects} = ?M:handle_send(self(), make_ref(), 0, Payload, false, ?NOW, State),
    Frames = flush_app_frames(State1, Effects, ServerApSecret, ClientApSecret, 0),
    ?assertEqual([{data_blocked, Window}], [F || {data_blocked, _} = F <- Frames]),
    ?assertEqual(
        [{stream_data_blocked, 0, Window}], [F || {stream_data_blocked, _, _} = F <- Frames]
    ).

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
    %% not-ack-eliciting before consulting the window, full or not. Two peer
    %% PINGs with no server data to send make the ACK due at once, in exactly
    %% such an ACK-only datagram.
    {State, ClientApSecret, ServerApSecret} = connect_owned(),
    {State1, _} = ?M:handle_datagram(?NOW, app_datagram([ping], 0, ClientApSecret), State),
    {_State2, Effects} = ?M:handle_datagram(?NOW, app_datagram([ping], 1, ClientApSecret), State1),
    ?assert(lists:any(fun is_ack/1, sent_app_frames(Effects, ServerApSecret))).

%% RFC 9000 §13.2.1: a 1-RTT ACK may wait for data to ride with. One PING
%% sends nothing and arms the ACK timer; when it fires the ACK goes out alone,
%% reporting how long the PING waited (20 ms in 8 µs units, the default
%% ack_delay_exponent of 3).
delayed_ack_waits_then_goes_out_on_timer_test() ->
    {State, ClientApSecret, ServerApSecret} = connect_owned(),
    {State1, Effects} = ?M:handle_datagram(?NOW, app_datagram([ping], 0, ClientApSecret), State),
    ?assertEqual([], sends(Effects)),
    ?assertEqual([?NOW + 20], [At || {arm_timer, ack, At} <- Effects]),
    {_State2, Fired} = ?M:handle_timeout(?NOW + 20, ack, State1),
    ?assertMatch(
        [{ack, 0, 2500, 0, [], undefined}],
        [F || {ack, _, _, _, _, _} = F <- sent_app_frames(Fired, ServerApSecret)]
    ).

%% A packet past a gap (a lost packet before it) is acknowledged at once, so
%% the peer learns of the loss without waiting (RFC 9000 §13.2.1).
out_of_order_packet_acked_at_once_test() ->
    {State, ClientApSecret, ServerApSecret} = connect_owned(),
    {_State1, Effects} = ?M:handle_datagram(?NOW, app_datagram([ping], 3, ClientApSecret), State),
    ?assert(lists:any(fun is_ack/1, sent_app_frames(Effects, ServerApSecret))).

%% A waiting ACK rides in the next packet that carries data.
delayed_ack_rides_with_data_test() ->
    {State, ClientApSecret, ServerApSecret} = connect_owned(),
    {State1, Effects} = ?M:handle_datagram(?NOW, app_datagram([ping], 0, ClientApSecret), State),
    ?assertEqual([], sends(Effects)),
    {_State2, Sent} = ?M:handle_send(self(), make_ref(), 0, ~"reply", true, ?NOW + 1, State1),
    Frames = sent_app_frames(Sent, ServerApSecret),
    ?assert(lists:any(fun is_ack/1, Frames)),
    ?assert(lists:any(fun(F) -> element(1, F) =:= stream end, Frames)).

%% An ACK timer that fires once the connection is closing sends nothing.
ack_timeout_while_draining_sends_nothing_test() ->
    {State, ClientApSecret, _ServerApSecret} = connect_owned(),
    {State1, _} = ?M:handle_datagram(?NOW, app_datagram([ping], 0, ClientApSecret), State),
    Close = app_datagram([{connection_close, application, 0, undefined, <<>>}], 1, ClientApSecret),
    {State2, _} = ?M:handle_datagram(?NOW, Close, State1),
    ?assertEqual(draining, ?M:phase(State2)),
    ?assertEqual({State2, []}, ?M:handle_timeout(?NOW + 20, ack, State2)).

%% RFC 9002 §7: ACK-only packets are not congestion controlled. With the window
%% full of unacknowledged data, a due ACK still goes out on its own instead of
%% waiting behind the stream data it would have ridden with, which the window
%% holds back.
ack_goes_out_alone_when_window_blocks_data_test() ->
    {State, ClientApSecret, ServerApSecret} = connect_owned(),
    {State1, _} = ?M:handle_send(
        self(), make_ref(), 0, binary:copy(~"x", 100000), false, ?NOW, State
    ),
    {State2, _} = ?M:handle_datagram(?NOW, app_datagram([ping], 0, ClientApSecret), State1),
    {_State3, Effects} = ?M:handle_datagram(?NOW, app_datagram([ping], 1, ClientApSecret), State2),
    Frames = sent_app_frames(Effects, ServerApSecret),
    ?assert(lists:any(fun is_ack/1, Frames)),
    ?assertEqual([], [F || {stream, _, _, _, _} = F <- Frames]).

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

%% RFC 9000 §3.2: opening a stream opens every lower one of its type, so a
%% request whose first packet arrives after a higher stream's (its own was
%% lost and resent) is still a new stream: it opens and its data is delivered,
%% not dropped as if it had been pruned. Stream 8 arriving first skips 0 and 4.
reordered_lower_stream_opens_test() ->
    {State0, ClientApSecret, _ServerApSecret} = connect_owned(),
    Req8 = app_datagram([{stream, 8, 0, ~"c", true}], 0, ClientApSecret),
    {State1, _} = ?M:handle_datagram(?NOW, Req8, State0),
    Req0 = app_datagram([{stream, 0, 0, ~"a", true}], 1, ClientApSecret),
    {State2, Effects0} = ?M:handle_datagram(?NOW, Req0, State1),
    ?assertEqual(
        [{stream_opened, 0}, {stream_data, 0, ~"a", true}], [E || {emit, _, E} <- Effects0]
    ),
    Req4 = app_datagram([{stream, 4, 0, ~"b", true}], 2, ClientApSecret),
    {_State3, Effects4} = ?M:handle_datagram(?NOW, Req4, State2),
    ?assertEqual(
        [{stream_opened, 4}, {stream_data, 4, ~"b", true}], [E || {emit, _, E} <- Effects4]
    ).

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

%% --- deferred-ack backpressure (W3): park on a stalled stream, release on
%% drain or on the stream/connection going away (so the worker never hangs) ---

%% A payload larger than the initial congestion window cannot fully flush in one
%% pass, so handle_send WITHHOLDS the reply (the worker blocks) while the
%% credit-permitted bytes still go out. This is the primary backpressure branch.
stalled_send_parks_reply_test() ->
    {State, _ClientApSecret, ServerApSecret} = connect_owned(),
    Ref = make_ref(),
    Payload = binary:copy(~"x", 100000),
    {_State1, Effects} = ?M:handle_send(self(), Ref, 0, Payload, false, ?NOW, State),
    ?assertEqual([], replies_for(Effects, Ref)),
    ?assertNotEqual([], sent_stream_frames(Effects, ServerApSecret)).

%% A small send that fully drains in one pass is NOT parked: it replies ok
%% immediately, exactly as before the fix (the healthy/common path).
small_send_not_parked_test() ->
    {State, _ClientApSecret, _ServerApSecret} = connect_owned(),
    Ref = make_ref(),
    {_State1, Effects} = ?M:handle_send(self(), Ref, 0, ~"hi", true, ?NOW, State),
    ?assertEqual([ok], replies_for(Effects, Ref)).

%% A control-stream send (server-uni, Sid 3) is NEVER parked even when it cannot
%% fully flush — the conn-loop owner writes there synchronously and must not
%% block.
server_uni_send_not_parked_test() ->
    {State, _ClientApSecret, _ServerApSecret} = connect_owned(),
    Ref = make_ref(),
    Payload = binary:copy(~"x", 100000),
    {_State1, Effects} = ?M:handle_send(self(), Ref, 3, Payload, false, ?NOW, State),
    ?assertEqual([ok], replies_for(Effects, Ref)).

%% Growing the congestion window with a cumulative ACK drains the parked bytes
%% and releases the deferred reply with ok — the release scan sits after
%% process_ack in the same datagram fold, so the ACK-only credit path is covered.
parked_reply_released_on_ack_credit_test() ->
    {State, ClientApSecret, ServerApSecret} = connect_owned(),
    Ref = make_ref(),
    Payload = binary:copy(~"x", 13000),
    {State1, E1} = ?M:handle_send(self(), Ref, 0, Payload, false, ?NOW, State),
    ?assertEqual([], replies_for(E1, Ref)),
    Largest = largest_app_pn(E1, ServerApSecret),
    Ack = app_datagram([{ack, Largest, 0, Largest, [], undefined}], 0, ClientApSecret),
    {_State2, E2} = ?M:handle_datagram(?NOW, Ack, State1),
    ?assertEqual([ok], replies_for(E2, Ref)).

%% A peer RESET_STREAM while parked releases the reply with {error, closed} (not
%% ok), so a streaming worker does not treat the data as sent and re-send.
parked_reply_released_on_peer_reset_test() ->
    {State, ClientApSecret, _ServerApSecret} = connect_owned(),
    Ref = make_ref(),
    Payload = binary:copy(~"x", 100000),
    {State1, E1} = ?M:handle_send(self(), Ref, 0, Payload, false, ?NOW, State),
    ?assertEqual([], replies_for(E1, Ref)),
    Reset = app_datagram([{reset_stream, 0, 7, 0}], 0, ClientApSecret),
    {_State2, E2} = ?M:handle_datagram(?NOW, Reset, State1),
    ?assertEqual([{error, closed}], replies_for(E2, Ref)).

%% A peer STOP_SENDING while parked clears our send side and releases with
%% {error, closed} (closing the pre-existing no-handler hang), and surfaces a
%% stream reset to the owner so a response worker stops.
parked_reply_released_on_peer_stop_sending_test() ->
    {State, ClientApSecret, _ServerApSecret} = connect_owned(),
    Ref = make_ref(),
    Payload = binary:copy(~"x", 100000),
    {State1, E1} = ?M:handle_send(self(), Ref, 0, Payload, false, ?NOW, State),
    ?assertEqual([], replies_for(E1, Ref)),
    Stop = app_datagram([{stop_sending, 0, 7}], 0, ClientApSecret),
    {_State2, E2} = ?M:handle_datagram(?NOW, Stop, State1),
    ?assertEqual([{error, closed}], replies_for(E2, Ref)),
    ?assert(lists:member({stream_reset, 0, 7}, [Ev || {emit, _Owner, Ev} <- E2])).

%% A local reset (handle_call {reset_stream, _}) while a send on that stream is
%% parked releases the parked reply with {error, closed}; it clears send_buf, so
%% without the send_abandoned guard the generic drain scan would wrongly reply ok.
parked_reply_released_on_local_reset_test() ->
    {State, _ClientApSecret, _ServerApSecret} = connect_owned(),
    Ref = make_ref(),
    Payload = binary:copy(~"x", 100000),
    {State1, E1} = ?M:handle_send(self(), Ref, 0, Payload, false, ?NOW, State),
    ?assertEqual([], replies_for(E1, Ref)),
    {_State2, E2} = ?M:handle_call(self(), make_ref(), {reset_stream, 0, 7}, ?NOW, State1),
    ?assertEqual([{error, closed}], replies_for(E2, Ref)).

%% A peer CONNECTION_CLOSE while parked drains every parked reply with
%% {error, closed} (the draining transition skips the send pass), so the worker
%% unblocks promptly instead of stalling the drain window.
parked_reply_released_on_draining_test() ->
    {State, ClientApSecret, _ServerApSecret} = connect_owned(),
    Ref = make_ref(),
    Payload = binary:copy(~"x", 100000),
    {State1, E1} = ?M:handle_send(self(), Ref, 0, Payload, false, ?NOW, State),
    ?assertEqual([], replies_for(E1, Ref)),
    Close = app_datagram(
        [{connection_close, application, 9, undefined, <<>>}], 0, ClientApSecret
    ),
    {State2, E2} = ?M:handle_datagram(?NOW, Close, State1),
    ?assertEqual(draining, ?M:phase(State2)),
    ?assertEqual([{error, closed}], replies_for(E2, Ref)).

%% An owner close while parked releases the parked reply with {error, closed}.
parked_reply_released_on_owner_close_test() ->
    {State, _ClientApSecret, _ServerApSecret} = connect_owned(),
    Ref = make_ref(),
    Payload = binary:copy(~"x", 100000),
    {State1, E1} = ?M:handle_send(self(), Ref, 0, Payload, false, ?NOW, State),
    ?assertEqual([], replies_for(E1, Ref)),
    {State2, E2} = ?M:handle_call(self(), make_ref(), {close, 16#0100}, ?NOW, State1),
    ?assertEqual(draining, ?M:phase(State2)),
    ?assertEqual([{error, closed}], replies_for(E2, Ref)).

%% An idle timeout while parked releases the parked reply with {error, closed}.
parked_reply_released_on_idle_timeout_test() ->
    {State, _ClientApSecret, _ServerApSecret} = connect_owned(),
    Ref = make_ref(),
    Payload = binary:copy(~"x", 100000),
    {State1, E1} = ?M:handle_send(self(), Ref, 0, Payload, false, ?NOW, State),
    ?assertEqual([], replies_for(E1, Ref)),
    {State2, E2} = ?M:handle_timeout(?NOW, idle, State1),
    ?assertEqual(closed, ?M:phase(State2)),
    ?assertEqual([{error, closed}], replies_for(E2, Ref)).

%% A parked reply stays parked across a send pass that drains some but not all
%% of the buffer — backpressure holds until the buffer fully drains.
parked_reply_kept_while_still_draining_test() ->
    {State, ClientApSecret, ServerApSecret} = connect_owned(),
    Ref = make_ref(),
    Payload = binary:copy(~"x", 100000),
    {State1, E1} = ?M:handle_send(self(), Ref, 0, Payload, false, ?NOW, State),
    ?assertEqual([], replies_for(E1, Ref)),
    Largest = largest_app_pn(E1, ServerApSecret),
    Ack = app_datagram([{ack, Largest, 0, Largest, [], undefined}], 0, ClientApSecret),
    {_State2, E2} = ?M:handle_datagram(?NOW, Ack, State1),
    %% One ACK grows the window by far less than the 100000-byte payload, so the
    %% reply is still withheld.
    ?assertEqual([], replies_for(E2, Ref)).

%% A STOP_SENDING for a stream the server holds no send state for is ignored.
stop_sending_for_untracked_stream_ignored_test() ->
    {State, ClientApSecret, _ServerApSecret} = connect_owned(),
    Stop = app_datagram([{stop_sending, 8, 7}], 0, ClientApSecret),
    {State1, _Effects} = ?M:handle_datagram(?NOW, Stop, State),
    ?assertEqual(connected, ?M:phase(State1)).

%% RFC 9000 §19.5 / §19.10: STOP_SENDING or MAX_STREAM_DATA naming a stream
%% the server cannot send on is a STREAM_STATE_ERROR: a client unidirectional
%% stream (receive-only, id 2), a server bidirectional stream (never opened,
%% id 1), or a server unidirectional stream not opened yet (id 3).
unsendable_stream_frame_closes_test_() ->
    [
        ?_test(assert_stream_state_error(Frame))
     || Frame <- [
            {stop_sending, 2, 7},
            {max_stream_data, 2, 1000},
            {stop_sending, 1, 7},
            {max_stream_data, 1, 1000},
            {stop_sending, 3, 7},
            {max_stream_data, 3, 1000}
        ]
    ].

assert_stream_state_error(Frame) ->
    {State, ClientApSecret, _ServerApSecret} = connect_owned(),
    {State1, Effects} = ?M:handle_datagram(?NOW, app_datagram([Frame], 0, ClientApSecret), State),
    ?assertEqual(draining, ?M:phase(State1)),
    ?assertEqual([{emit, self(), {closed, {local, stream_state_error}}}], emits(Effects)).

%% Once the server has opened its unidirectional stream 3, both frames may
%% name it.
opened_server_uni_stream_frames_accepted_test() ->
    {State, ClientApSecret, _ServerApSecret} = connect_owned(),
    {State1, _} = ?M:handle_call(self(), make_ref(), open_uni, ?NOW, State),
    Frames = [{max_stream_data, 3, 1000}, {stop_sending, 3, 7}],
    {State2, _Effects} = ?M:handle_datagram(?NOW, app_datagram(Frames, 0, ClientApSecret), State1),
    ?assertEqual(connected, ?M:phase(State2)).

%% The final FIN-carrying push parks under the congestion window, then releases
%% ok once the window opens; the FIN reaches the wire (loop termination does not
%% deadlock).
parked_fin_push_released_on_drain_test() ->
    {State, ClientApSecret, ServerApSecret} = connect_owned(),
    Ref = make_ref(),
    Payload = binary:copy(~"x", 13000),
    {State1, E1} = ?M:handle_send(self(), Ref, 0, Payload, true, ?NOW, State),
    ?assertEqual([], replies_for(E1, Ref)),
    Largest = largest_app_pn(E1, ServerApSecret),
    Ack = app_datagram([{ack, Largest, 0, Largest, [], undefined}], 0, ClientApSecret),
    {_State2, E2} = ?M:handle_datagram(?NOW, Ack, State1),
    ?assertEqual([ok], replies_for(E2, Ref)),
    ?assert(
        lists:any(
            fun
                ({stream, 0, _, _, true}) -> true;
                (_) -> false
            end,
            sent_stream_frames(E2, ServerApSecret)
        )
    ).

%% After a peer RESET_STREAM, the server must NOT re-send STREAM frames on the
%% aborted stream even once the window opens (the aborted stream leaves the
%% sendable set despite its buffered bytes).
peer_reset_does_not_resend_test() ->
    {State, ClientApSecret, ServerApSecret} = connect_owned(),
    Payload = binary:copy(~"x", 100000),
    {State1, E1} = ?M:handle_send(self(), make_ref(), 0, Payload, false, ?NOW, State),
    Largest = largest_app_pn(E1, ServerApSecret),
    Reset = app_datagram([{reset_stream, 0, 7, 0}], 0, ClientApSecret),
    {State2, _E2} = ?M:handle_datagram(?NOW, Reset, State1),
    %% An ACK grows cwnd and frees the in-flight bytes; a non-aborted stream
    %% would re-send here, but the aborted stream must stay silent.
    Ack = app_datagram([{ack, Largest, 0, Largest, [], undefined}], 1, ClientApSecret),
    {_State3, E3} = ?M:handle_datagram(?NOW, Ack, State2),
    ?assertEqual([], sent_stream_frames(E3, ServerApSecret)).

%% A send on an already-aborted stream replies {error, closed} at once (it does
%% not park on a dead stream waiting for credit that will never come).
send_on_aborted_stream_replies_error_test() ->
    {State, ClientApSecret, _ServerApSecret} = connect_owned(),
    {State1, _E1} = ?M:handle_send(self(), make_ref(), 0, ~"hi", false, ?NOW, State),
    Reset = app_datagram([{reset_stream, 0, 7, 0}], 0, ClientApSecret),
    {State2, _E2} = ?M:handle_datagram(?NOW, Reset, State1),
    Ref = make_ref(),
    {_State3, E3} = ?M:handle_send(self(), Ref, 0, ~"more", false, ?NOW, State2),
    ?assertEqual([{error, closed}], replies_for(E3, Ref)).

%% A parked reply is released exactly once: after the release, a later send pass
%% does not emit a second {quic_reply} for the same Ref.
parked_reply_not_double_released_test() ->
    {State, ClientApSecret, _ServerApSecret} = connect_owned(),
    Ref = make_ref(),
    Payload = binary:copy(~"x", 100000),
    {State1, E1} = ?M:handle_send(self(), Ref, 0, Payload, false, ?NOW, State),
    ?assertEqual([], replies_for(E1, Ref)),
    Reset = app_datagram([{reset_stream, 0, 7, 0}], 0, ClientApSecret),
    {State2, E2} = ?M:handle_datagram(?NOW, Reset, State1),
    ?assertEqual([{error, closed}], replies_for(E2, Ref)),
    Ack = app_datagram([{ack, 0, 0, 0, [], undefined}], 1, ClientApSecret),
    {_State3, E3} = ?M:handle_datagram(?NOW, Ack, State2),
    ?assertEqual([], replies_for(E3, Ref)).

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
        roadrunner_quic_keys:traffic_keys(aes_128_gcm, ClientHsSecret),
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
        #{application => roadrunner_quic_keys:traffic_keys(aes_128_gcm, ServerApSecret)},
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
        handshake,
        1,
        roadrunner_quic_keys:traffic_keys(aes_128_gcm, ClientHsSecret),
        [ping],
        ?DCID,
        ?SCID
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

%% RFC 9000 §10.2.1: after our own CONNECTION_CLOSE, a late packet means the
%% peer may not have seen it, so the same close goes out again, at packet
%% counts 1, 2, 4, 8, ... so the answers stay rate-limited.
late_packet_after_local_close_resends_close_test() ->
    {State, ApSecret} = connected_with_owner(),
    Bad = app_datagram([{retire_connection_id, 1}], 0, ApSecret),
    {Closing, CloseEffects} = ?M:handle_datagram(?NOW, Bad, State),
    ?assertEqual(draining, ?M:phase(Closing)),
    [CloseDatagram] = sends(CloseEffects),
    Late = fun(PN, S) -> ?M:handle_datagram(?NOW + PN, app_datagram([ping], PN, ApSecret), S) end,
    {S1, E1} = Late(1, Closing),
    {S2, E2} = Late(2, S1),
    {S3, E3} = Late(3, S2),
    {_S4, E4} = Late(4, S3),
    ?assertEqual([[CloseDatagram], [CloseDatagram], [], [CloseDatagram]], [
        sends(E)
     || E <- [E1, E2, E3, E4]
    ]),
    ?assertEqual([], [T || E <- [E1, E2, E3, E4], {arm_timer, _, _} = T <- E]).

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
%% Key update (RFC 9001 §6)
%% =============================================================================

%% RFC 9001 §6.2: a packet in the other key phase that authenticates with the
%% next keys is a peer key update. The server updates its send keys too, so the
%% ACK of that packet goes out protected with the next generation and carrying
%% the flipped Key Phase bit; the old send keys no longer open anything.
peer_key_update_switches_both_directions_test() ->
    {State, ClientApSecret, ServerApSecret} = connect_owned(),
    Update = phase_datagram([ping], 0, generation_keys(ClientApSecret, 1), 1),
    {State1, Effects1} = ?M:handle_datagram(?NOW, Update, State),
    ?assertEqual(connected, ?M:phase(State1)),
    ?assertEqual([], sends(Effects1)),
    {_State2, Effects2} = ?M:handle_timeout(?NOW + 20, ack, State1),
    ?assertMatch(
        [{ok, #{key_phase := 1, frames := [{ack, 0, _, 0, [], undefined} | _]}}],
        app_packets(Effects2, generation_keys(ServerApSecret, 1))
    ),
    ?assertEqual(
        [{auth_failed, application}], app_packets(Effects2, generation_keys(ServerApSecret, 0))
    ).

%% A flipped Key Phase bit on a packet that does not authenticate with the next
%% keys (forged, or sealed with the current ones) is dropped and changes
%% nothing: the next packet in the current phase is processed, and the server
%% still answers in key phase 0 with its current keys.
forged_key_phase_changes_nothing_test() ->
    {State, ClientApSecret, ServerApSecret} = connect_owned(),
    Forged = phase_datagram([ping], 0, generation_keys(ClientApSecret, 0), 1),
    {State1, Effects1} = ?M:handle_datagram(?NOW, Forged, State),
    ?assertEqual([], sends(Effects1)),
    Data = phase_datagram(
        [{stream, 0, 0, ~"hello", true}], 1, generation_keys(ClientApSecret, 0), 0
    ),
    %% Packet 1 follows a gap (the dropped packet 0), so its ACK goes out at once.
    {_State2, Effects2} = ?M:handle_datagram(?NOW, Data, State1),
    ?assert(lists:member({emit, self(), {stream_data, 0, ~"hello", true}}, emits(Effects2))),
    ?assertMatch(
        [{ok, #{key_phase := 0, frames := [{ack, 1, _, 0, [], undefined} | _]}}],
        app_packets(Effects2, generation_keys(ServerApSecret, 0))
    ).

%% RFC 9001 §6.5: a packet from before the update, reordered behind the one
%% that began the new phase, still opens with the previous keys.
reordered_old_phase_packet_opens_with_previous_keys_test() ->
    {State, ClientApSecret, _ServerApSecret} = connect_owned(),
    State1 = updated_at(2, ClientApSecret, State),
    Late = phase_datagram(
        [{stream, 0, 0, ~"late", true}], 1, generation_keys(ClientApSecret, 0), 0
    ),
    {_State2, Effects} = ?M:handle_datagram(?NOW + 1, Late, State1),
    ?assert(lists:member({emit, self(), {stream_data, 0, ~"late", true}}, emits(Effects))).

%% RFC 9001 §6.5: the previous keys are discarded three PTOs after the update,
%% so an old-phase packet arriving later is dropped.
previous_keys_discarded_after_three_ptos_test() ->
    {State, ClientApSecret, _ServerApSecret} = connect_owned(),
    State1 = updated_at(2, ClientApSecret, State),
    Late = phase_datagram(
        [{stream, 0, 0, ~"late", true}], 1, generation_keys(ClientApSecret, 0), 0
    ),
    {State2, Effects} = ?M:handle_datagram(?NOW + 10000, Late, State1),
    ?assertEqual(connected, ?M:phase(State2)),
    ?assertEqual([], emits(Effects)).

%% RFC 9001 §6.4: packets numbered above the start of the new phase use the new
%% keys or newer, so an old-phase packet numbered there is not opened with the
%% previous keys: it is dropped.
old_phase_packet_above_new_phase_is_dropped_test() ->
    {State, ClientApSecret, _ServerApSecret} = connect_owned(),
    State1 = updated_at(2, ClientApSecret, State),
    Stale = phase_datagram(
        [{stream, 0, 0, ~"stale", true}], 3, generation_keys(ClientApSecret, 0), 0
    ),
    {State2, Effects} = ?M:handle_datagram(?NOW + 1, Stale, State1),
    ?assertEqual(connected, ?M:phase(State2)),
    ?assertEqual([], emits(Effects)).

%% A new-phase packet reordered below the one that began the phase lowers the
%% bound the previous keys apply under (RFC 9001 §6.5): an old-phase packet
%% between the two is then dropped (§6.4), one below both still opens.
reordered_new_phase_packet_lowers_previous_bound_test() ->
    {State, ClientApSecret, _ServerApSecret} = connect_owned(),
    State1 = updated_at(5, ClientApSecret, State),
    Reordered = phase_datagram([ping], 3, generation_keys(ClientApSecret, 1), 1),
    {State2, _} = ?M:handle_datagram(?NOW + 1, Reordered, State1),
    Between = phase_datagram(
        [{stream, 0, 0, ~"between", true}], 4, generation_keys(ClientApSecret, 0), 0
    ),
    {State3, Effects3} = ?M:handle_datagram(?NOW + 1, Between, State2),
    ?assertEqual([], emits(Effects3)),
    Below = phase_datagram(
        [{stream, 0, 0, ~"below", true}], 2, generation_keys(ClientApSecret, 0), 0
    ),
    {_State4, Effects4} = ?M:handle_datagram(?NOW + 1, Below, State3),
    ?assert(lists:member({emit, self(), {stream_data, 0, ~"below", true}}, emits(Effects4))).

%% RFC 9001 §6.2: a second update before the server has acknowledged a packet
%% of the current phase is a KEY_UPDATE_ERROR. The CONNECTION_CLOSE goes out
%% under the keys of the update that did complete.
second_update_before_ack_closes_test() ->
    {State, ClientApSecret, ServerApSecret} = connect_owned(),
    Update = phase_datagram([ping], 0, generation_keys(ClientApSecret, 1), 1),
    {State1, _} = ?M:handle_datagram(?NOW, Update, State),
    Again = phase_datagram([ping], 1, generation_keys(ClientApSecret, 2), 0),
    {State2, Effects} = ?M:handle_datagram(?NOW, Again, State1),
    ?assertEqual(draining, ?M:phase(State2)),
    ?assertEqual([{emit, self(), {closed, {local, key_update_error}}}], emits(Effects)),
    ?assertMatch(
        [{ok, #{key_phase := 1, frames := [{connection_close, transport, 16#0e, 0, <<>>}]}}],
        app_packets(Effects, generation_keys(ServerApSecret, 1))
    ).

%% Once the server's ACK of the new phase has gone out, the peer may update
%% again (RFC 9001 §6.1): the third generation takes over in key phase 0.
second_update_after_ack_commits_test() ->
    {State, ClientApSecret, ServerApSecret} = connect_owned(),
    Update = phase_datagram([ping], 0, generation_keys(ClientApSecret, 1), 1),
    {State1, _} = ?M:handle_datagram(?NOW, Update, State),
    {State2, _} = ?M:handle_timeout(?NOW + 20, ack, State1),
    Again = phase_datagram([ping], 1, generation_keys(ClientApSecret, 2), 0),
    {State3, _} = ?M:handle_datagram(?NOW + 30, Again, State2),
    ?assertEqual(connected, ?M:phase(State3)),
    {_State4, Effects} = ?M:handle_timeout(?NOW + 50, ack, State3),
    ?assertMatch(
        [{ok, #{key_phase := 0, frames := [{ack, 1, _, 1, [], undefined} | _]}}],
        app_packets(Effects, generation_keys(ServerApSecret, 2))
    ).

%% A key update never changes the cipher suite (RFC 9001 §6.1): on a
%% ChaCha20-Poly1305 connection every generation is a ChaCha20-Poly1305 key
%% with the ChaCha20 header-protection key of the first. The server commits
%% the peer's first update and answers in key phase 1 with its own next
%% ChaCha20 generation, then, after that ACK, commits a second update and
%% answers in key phase 0 with the generation after; the AES-128-GCM keys of
%% the same secrets open nothing.
chacha20_peer_key_update_test() ->
    {State, ClientApSecret, ServerApSecret} =
        connect_owned(#{}, #{cipher_suites => [16#1303]}),
    Update = phase_datagram(
        [ping], 0, generation_keys(chacha20_poly1305, ClientApSecret, 1), 1
    ),
    {State1, _} = ?M:handle_datagram(?NOW, Update, State),
    ?assertEqual(connected, ?M:phase(State1)),
    {State2, Effects2} = ?M:handle_timeout(?NOW + 20, ack, State1),
    ?assertMatch(
        [{ok, #{key_phase := 1, frames := [{ack, 0, _, 0, [], undefined} | _]}}],
        app_packets(Effects2, generation_keys(chacha20_poly1305, ServerApSecret, 1))
    ),
    ?assertEqual(
        [{auth_failed, application}], app_packets(Effects2, generation_keys(ServerApSecret, 1))
    ),
    Again = phase_datagram(
        [ping], 1, generation_keys(chacha20_poly1305, ClientApSecret, 2), 0
    ),
    {State3, _} = ?M:handle_datagram(?NOW + 30, Again, State2),
    ?assertEqual(connected, ?M:phase(State3)),
    {_State4, Effects4} = ?M:handle_timeout(?NOW + 50, ack, State3),
    ?assertMatch(
        [{ok, #{key_phase := 0, frames := [{ack, 1, _, 1, [], undefined} | _]}}],
        app_packets(Effects4, generation_keys(chacha20_poly1305, ServerApSecret, 2))
    ).

%% RFC 9001 §6.1: a key update before the handshake is confirmed (at the
%% server, before it completes) is a KEY_UPDATE_ERROR.
key_update_before_handshake_completes_closes_test() ->
    #{state1 := State1, client_ap_secret := ClientApSecret} = connect(),
    Update = phase_datagram([ping], 0, generation_keys(ClientApSecret, 1), 1),
    {State2, Effects} = ?M:handle_datagram(?NOW, Update, with_owner(State1)),
    ?assertEqual(closed, ?M:phase(State2)),
    ?assertEqual([{emit, self(), {closed, {local, key_update_error}}}], emits(Effects)).

%% RFC 9001 §6.6: past the AEAD_AES_128_GCM integrity limit of 2^52 packets
%% failing authentication, the connection closes with AEAD_LIMIT_REACHED and
%% processes no more packets. Up to the limit it carries on.
aead_integrity_limit_closes_test() ->
    {State, ClientApSecret, _ServerApSecret} = connect_owned(),
    AtLimit = ?M:auth_failed(application, 1 bsl 52, State),
    ?assertEqual(connected, ?M:phase(AtLimit)),
    Over = ?M:auth_failed(application, (1 bsl 52) + 1, State),
    ?assertEqual(draining, ?M:phase(Over)),
    Data = app_datagram([{stream, 0, 0, ~"x", true}], 0, ClientApSecret),
    {_Over1, Effects} = ?M:handle_datagram(?NOW, Data, Over),
    ?assertEqual([{emit, self(), {closed, {local, aead_limit_reached}}}], emits(Effects)).

%% The integrity limit is the negotiated AEAD's (RFC 9001 §6.6): 2^36 for
%% AEAD_CHACHA20_POLY1305.
chacha20_aead_integrity_limit_closes_test() ->
    {State, _ClientApSecret, _ServerApSecret} =
        connect_owned(#{}, #{cipher_suites => [16#1303]}),
    ?assertEqual(connected, ?M:phase(?M:auth_failed(application, 1 bsl 36, State))),
    ?assertEqual(draining, ?M:phase(?M:auth_failed(application, (1 bsl 36) + 1, State))).

%% RFC 9001 §6.6: halfway to the AES-128-GCM confidentiality limit of 2^23
%% packets, once the peer has acknowledged a packet of the current phase and
%% three PTOs have passed (§6.1, §6.5), the server starts a key update of its
%% own: its packets go out under the next generation with the Key Phase bit
%% flipped. The peer's response in the new phase moves only the receive keys,
%% so the server's ACK of it stays on the generation it moved to rather than
%% one further, and a later peer-initiated update still commits as usual.
own_key_update_then_peer_update_test() ->
    {State, ClientApSecret, ServerApSecret} = connect_owned(),
    Later = ?NOW + 60000,
    State1 = ?M:key_limit(1 bsl 22, Later, send_phase_acked(State, ClientApSecret)),
    {State2, Effects2} = ?M:handle_send(self(), make_ref(), 0, ~"hello", true, Later, State1),
    ?assertMatch(
        [{ok, #{key_phase := 1, frames := [{stream, 0, 0, ~"hello", true}]}}],
        app_packets(Effects2, generation_keys(ServerApSecret, 1))
    ),
    Response = phase_datagram([ping], 1, generation_keys(ClientApSecret, 1), 1),
    {State3, _} = ?M:handle_datagram(Later, Response, State2),
    ?assertEqual(connected, ?M:phase(State3)),
    {State4, Effects4} = ?M:handle_timeout(Later + 20, ack, State3),
    ?assertMatch(
        [{ok, #{key_phase := 1, frames := [{ack, 1, _, 1, [], undefined}]}}],
        app_packets(Effects4, generation_keys(ServerApSecret, 1))
    ),
    Again = phase_datagram([ping], 2, generation_keys(ClientApSecret, 2), 0),
    {State5, _} = ?M:handle_datagram(Later + 30, Again, State4),
    ?assertEqual(connected, ?M:phase(State5)),
    {_State6, Effects6} = ?M:handle_timeout(Later + 50, ack, State5),
    ?assertMatch(
        [{ok, #{key_phase := 0, frames := [{ack, 2, _, 2, [], undefined}]}}],
        app_packets(Effects6, generation_keys(ServerApSecret, 2))
    ).

%% Until the peer answers our key update in the new phase, its packets in the
%% old phase still open, and no second update starts even with the new phase
%% acknowledged and three PTOs gone: our keys would be two generations ahead
%% of what the peer can open (RFC 9001 §6.1).
own_key_update_waits_for_peer_response_test() ->
    {State, ClientApSecret, ServerApSecret} = connect_owned(),
    Later = ?NOW + 60000,
    State1 = ?M:key_limit(1 bsl 22, Later, send_phase_acked(State, ClientApSecret)),
    {State2, _} = ?M:handle_send(self(), make_ref(), 0, ~"a", false, Later, State1),
    OldPhase = app_datagram(
        [{ack, 1, 0, 1, [], undefined}, {stream, 0, 0, ~"old", false}], 1, ClientApSecret
    ),
    {State3, Effects3} = ?M:handle_datagram(Later, OldPhase, State2),
    ?assert(lists:member({emit, self(), {stream_data, 0, ~"old", false}}, emits(Effects3))),
    Much = Later + 60000,
    State4 = ?M:key_limit(1 bsl 22, Much, State3),
    {_State5, Effects5} = ?M:handle_send(self(), make_ref(), 0, ~"b", true, Much, State4),
    [{ok, #{key_phase := 1, frames := Frames}}] =
        app_packets(Effects5, generation_keys(ServerApSecret, 1)),
    ?assert(lists:member({stream, 0, 1, ~"b", true}, Frames)).

%% RFC 9001 §6.1 and §6.5: no key update of our own before the peer has
%% acknowledged a packet sent with the current keys, nor within three PTOs of
%% that ACK, nor before the handshake is confirmed. The packets stay in key
%% phase 0 under the first keys.
own_key_update_needs_acknowledged_phase_test() ->
    {State, ClientApSecret, ServerApSecret} = connect_owned(),
    Unacked = ?M:key_limit(1 bsl 22, ?NOW + 60000, State),
    {_, Effects1} = ?M:handle_send(self(), make_ref(), 0, ~"a", true, ?NOW + 60000, Unacked),
    ?assertMatch(
        [{ok, #{key_phase := 0}}], app_packets(Effects1, generation_keys(ServerApSecret, 0))
    ),
    TooSoon = ?M:key_limit(1 bsl 22, ?NOW + 1, send_phase_acked(State, ClientApSecret)),
    {_, Effects2} = ?M:handle_send(self(), make_ref(), 0, ~"a", true, ?NOW + 1, TooSoon),
    ?assertMatch(
        [{ok, #{key_phase := 0}}], app_packets(Effects2, generation_keys(ServerApSecret, 0))
    ),
    #{state1 := Handshaking} = connect(),
    ?assertEqual(
        closed, ?M:phase(?M:key_limit((1 bsl 23) - 1, ?NOW, with_owner(Handshaking)))
    ).

%% RFC 9001 §6.6: with no key update allowed, the keys protect at most the
%% 2^23 packets of the limit. The packet that reaches one short of it goes
%% out, then the connection closes with AEAD_LIMIT_REACHED, the close being
%% the last packet the keys protect, and drains.
confidentiality_limit_closes_without_update_test() ->
    {State, _ClientApSecret, ServerApSecret} = connect_owned(),
    Near = ?M:key_limit((1 bsl 23) - 2, ?NOW, State),
    ?assertEqual(connected, ?M:phase(Near)),
    {Closed, Effects} = ?M:handle_send(self(), make_ref(), 0, ~"last", true, ?NOW, Near),
    ?assertEqual(draining, ?M:phase(Closed)),
    ?assertMatch(
        [
            {ok, #{frames := [{stream, 0, 0, ~"last", true}]}},
            {ok, #{frames := [{connection_close, transport, 16#0f, 0, <<>>}]}}
        ],
        app_packets(Effects, generation_keys(ServerApSecret, 0))
    ),
    ?assert(lists:member({emit, self(), {closed, {local, aead_limit_reached}}}, emits(Effects))),
    ?assertMatch([_], [At || {arm_timer, drain, At} <- Effects]),
    ?assertEqual(draining, ?M:phase(?M:key_limit((1 bsl 23) - 1, ?NOW, State))).

%% The confidentiality limit is the negotiated AEAD's (RFC 9001 §6.6):
%% AEAD_CHACHA20_POLY1305's is beyond the 2^62 packet numbers, so 2^23
%% packets start no update; halfway to 2^62 one would.
chacha20_confidentiality_limit_test() ->
    {State, ClientApSecret, ServerApSecret} =
        connect_owned(#{}, #{cipher_suites => [16#1303]}),
    Later = ?NOW + 60000,
    Acked = send_phase_acked(
        State, generation_keys(chacha20_poly1305, ClientApSecret, 0)
    ),
    Gcm = ?M:key_limit(1 bsl 23, Later, Acked),
    {_, Effects1} = ?M:handle_send(self(), make_ref(), 0, ~"a", true, Later, Gcm),
    ?assertMatch(
        [{ok, #{key_phase := 0}}],
        app_packets(Effects1, generation_keys(chacha20_poly1305, ServerApSecret, 0))
    ),
    Half = ?M:key_limit(1 bsl 61, Later, Acked),
    {_, Effects2} = ?M:handle_send(self(), make_ref(), 0, ~"a", true, Later, Half),
    ?assertMatch(
        [{ok, #{key_phase := 1}}],
        app_packets(Effects2, generation_keys(chacha20_poly1305, ServerApSecret, 1))
    ).

%% =============================================================================
%% Handshake driver (plays the QUIC client with the shared test client)
%% =============================================================================

%% Run a full RSA handshake against a fresh connection and return every
%% intermediate the assertions need.
connect() ->
    connect(#{}).

connect(Extra) ->
    connect(Extra, #{}).

%% `HelloOpts` adds ClientHello options (`?TC:client_hello_framed/1`, such as
%% `transport_params` overriding the client's advertised transport
%% parameters, with `client_priv` the private half of a `key_shares` entry it
%% replaces); the packet keys follow the cipher suite and group the
%% ServerHello selected.
connect(Extra, HelloOpts) ->
    {State0, Ctx} = new_conn([~"leaf-cert-der"], Extra),
    #{client_priv := ClientPriv} = maps:merge(Ctx, HelloOpts),

    %% Client Initial carrying the ClientHello.
    {InitialDatagram, ClientHelloFramed} = client_hello_datagram(Ctx, HelloOpts),
    {State1, Effects1} = ?M:handle_datagram(?NOW, InitialDatagram, State0),
    Handshake = finish_handshake(State1, Effects1, ClientHelloFramed, ClientPriv),
    Handshake#{state0 => State0, ch_framed => ClientHelloFramed, ctx => Ctx}.

%% Complete the handshake from the server's reply (`Effects1`, `State1`) to
%% the client's last ClientHello: recover the ServerHello, derive the
%% handshake secrets over `Transcript` (every handshake message before the
%% ServerHello) and the ServerHello, read the server's flight, and send the
%% client Finished.
finish_handshake(State1, Effects1, Transcript, ClientPriv) ->
    Server1 = sends(Effects1),

    %% Recover the ServerHello and derive the handshake secrets.
    ServerHello = ?TC:crypto_bytes(
        Server1, initial, #{initial => roadrunner_quic_keys:initial_server(?DCID)}, byte_size(?DCID)
    ),
    [{2, ServerHelloBody}] = ?TC:deframe_all(ServerHello),
    #{cipher := Cipher, group := Group, key_share := ServerShare} =
        ?TC:parse_server_hello(ServerHelloBody),
    Aead = aead(Cipher),
    Shared = crypto:compute_key(ecdh, ServerShare, ClientPriv, curve(Group)),
    HandshakeSecret = roadrunner_quic_tls_crypto:handshake_secret(
        roadrunner_quic_tls_crypto:early_secret(), Shared
    ),
    HelloHash = roadrunner_quic_tls_crypto:transcript_hash([Transcript, ServerHello]),
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
        #{handshake => roadrunner_quic_keys:traffic_keys(Aead, ServerHsSecret)},
        byte_size(?DCID)
    ),
    FinishedHash = roadrunner_quic_tls_crypto:transcript_hash([Transcript, ServerHello, Flight]),

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
        roadrunner_quic_keys:traffic_keys(Aead, ClientHsSecret),
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
        state1 => State1,
        state2 => State2,
        effects1 => Effects1,
        effects2 => Effects2,
        sh_framed => ServerHello,
        flight => Flight,
        cf_framed => ClientFinishedFramed,
        client_hs_secret => ClientHsSecret,
        server_hs_secret => ServerHsSecret,
        server_ap_secret => ServerApSecret,
        client_ap_secret => ClientApSecret,
        aead => Aead
    }.

%% The packet-protection AEAD of a cipher suite (RFC 9001 §5.3).
aead(16#1301) -> aes_128_gcm;
aead(16#1303) -> chacha20_poly1305.

%% The `crypto` curve of a key exchange group (RFC 8446 §4.2.7).
curve(?GROUP_X25519) -> x25519;
curve(?GROUP_SECP256R1) -> secp256r1.

%% A fresh server connection plus the client material the driver reuses.
new_conn(CertChain) ->
    new_conn(CertChain, #{}).

%% `Extra` adds optional config keys (`stream_credit`).
new_conn(CertChain, Extra) ->
    {Scheme, PrivKey} = ?TC:key_material(),
    {ClientPub, ClientPriv} = ?TC:gen_keypair(),
    TransportParams = transport_params(),
    State = ?M:new(
        Extra#{
            dcid => ?DCID,
            scid => ?SCID,
            peer_scid => ?CLIENT_SCID,
            peer => ?PEER,
            cert_chain => CertChain,
            priv_key => PrivKey,
            alpn => ~"h3",
            transport_params => TransportParams,
            server_random => crypto:strong_rand_bytes(32)
        },
        ?NOW
    ),
    {State, #{
        scheme => Scheme,
        client_pub => ClientPub,
        client_priv => ClientPriv
    }}.

%% The client Initial datagram and the framed ClientHello it carries (the
%% first transcript element).
client_hello_datagram(Ctx) ->
    client_hello_datagram(Ctx, #{}).

client_hello_datagram(#{scheme := Scheme, client_pub := ClientPub}, HelloOpts) ->
    Framed = ?TC:client_hello_framed(
        maps:merge(
            #{
                scheme => Scheme,
                key_shares => [{?GROUP_X25519, ClientPub}],
                client_scid => ?CLIENT_SCID
            },
            HelloOpts
        )
    ),
    {initial_datagram(0, 0, Framed), Framed}.

%% A client Initial carrying `Bytes` at CRYPTO `Offset`, with packet number
%% `PN`.
initial_datagram(PN, Offset, Bytes) ->
    ?TC:seal(
        initial,
        PN,
        roadrunner_quic_keys:initial_client(?DCID),
        [{crypto, Offset, Bytes}],
        ?DCID,
        ?SCID
    ).

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
    connect_owned(#{}).

connect_owned(Extra) ->
    connect_owned(Extra, #{}).

%% `HelloOpts` as for connect/2.
connect_owned(Extra, HelloOpts) ->
    #{
        state1 := State1,
        client_hs_secret := ClientHsSecret,
        cf_framed := ClientFinished,
        client_ap_secret := ClientApSecret,
        server_ap_secret := ServerApSecret,
        aead := Aead
    } = connect(Extra, HelloOpts),
    {State1b, _} = ?M:handle_call(self(), make_ref(), {set_owner, self()}, 0, State1),
    Finished = ?TC:seal(
        handshake,
        0,
        roadrunner_quic_keys:traffic_keys(Aead, ClientHsSecret),
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
        application,
        PN,
        roadrunner_quic_keys:traffic_keys(aes_128_gcm, ClientApSecret),
        Frames,
        ?DCID,
        ?SCID
    ).

%% Seal a peer 1-RTT datagram with the given keys and Key Phase bit.
phase_datagram(Frames, PN, Keys, KeyPhase) ->
    Entry = #{frames => Frames, keys => Keys, pn => PN, key_phase => KeyPhase},
    {Datagram, _Sent} = roadrunner_quic_send:datagram(#{application => Entry}, ?DCID, ?SCID),
    Datagram.

%% A side's 1-RTT keys after `N` key updates (RFC 9001 §6.1): the AEAD key
%% and IV of the Nth "quic ku" generation, with the header-protection key of
%% the first, which never changes. Every generation is for the same AEAD
%% (AES-128-GCM unless given).
generation_keys(Secret, N) ->
    generation_keys(aes_128_gcm, Secret, N).

generation_keys(Aead, Secret, N) ->
    maps:merge(roadrunner_quic_keys:traffic_keys(Aead, Secret), packet_keys(Aead, Secret, N)).

packet_keys(Aead, Secret, 0) ->
    maps:with([key, iv], roadrunner_quic_keys:traffic_keys(Aead, Secret));
packet_keys(Aead, Secret, N) ->
    {Updated, _PacketKeys} = roadrunner_quic_keys:update(Aead, Secret),
    packet_keys(Aead, Updated, N - 1).

%% Drive a peer key update on a connected state: a PING numbered 0 in key
%% phase 0, then a PING numbered `PN` in key phase 1 under the next keys.
updated_at(PN, ClientApSecret, State) ->
    Old = phase_datagram([ping], 0, generation_keys(ClientApSecret, 0), 0),
    {State1, _} = ?M:handle_datagram(?NOW, Old, State),
    New = phase_datagram([ping], PN, generation_keys(ClientApSecret, 1), 1),
    {State2, _} = ?M:handle_datagram(?NOW, New, State1),
    State2.

%% The client acknowledges the server's first 1-RTT packet (its
%% HANDSHAKE_DONE) at `?NOW`, from its own first 1-RTT packet: a packet of the
%% server's current key phase is acknowledged (RFC 9001 §6.1). `Keys` seal it,
%% the client's AES-128-GCM first generation unless given.
send_phase_acked(State, #{} = Keys) ->
    Ack = phase_datagram([{ack, 0, 0, 0, [], undefined}], 0, Keys, 0),
    {State1, _} = ?M:handle_datagram(?NOW, Ack, State),
    State1;
send_phase_acked(State, ClientApSecret) ->
    send_phase_acked(State, generation_keys(ClientApSecret, 0)).

%% Every 1-RTT packet outcome of the server's datagrams, decoded with `Keys`.
app_packets(Effects, Keys) ->
    [
        Outcome
     || Datagram <- sends(Effects),
        Outcome <- roadrunner_quic_recv:datagram(
            Datagram, byte_size(?DCID), #{application => Keys}, #{}
        )
    ].

%% Decode the application (1-RTT) frames the connection sent, then keep just
%% the STREAM frames.
sent_stream_frames(Effects, ServerApSecret) ->
    Frames = ?TC:frames(
        sends(Effects),
        application,
        #{application => roadrunner_quic_keys:traffic_keys(aes_128_gcm, ServerApSecret)},
        byte_size(?DCID)
    ),
    [Frame || {stream, _Sid, _Off, _Data, _Fin} = Frame <- Frames].

%% Every frame the server put on the wire at the application level (decoded with
%% its 1-RTT keys), for asserting control frames like RESET_STREAM/STOP_SENDING.
sent_app_frames(Effects, ServerApSecret) ->
    ?TC:frames(
        sends(Effects),
        application,
        #{application => roadrunner_quic_keys:traffic_keys(aes_128_gcm, ServerApSecret)},
        byte_size(?DCID)
    ).

%% The frames of the server's Initial-level reply (a handshake-phase close).
initial_close_frames(Effects) ->
    ?TC:frames(
        sends(Effects),
        initial,
        #{initial => roadrunner_quic_keys:initial_server(?DCID)},
        byte_size(?DCID)
    ).

emits(Effects) ->
    [Emit || {emit, _Owner, _Event} = Emit <- Effects].

%% The reply results addressed to a given send Ref (a parked send emits none
%% until released; a released one emits exactly one).
replies_for(Effects, Ref) ->
    [Result || {reply, _From, R, Result} <- Effects, R =:= Ref].

%% The largest 1-RTT packet number among the server's sent datagrams, decoded
%% with the server's application keys; used to acknowledge what is in flight.
largest_app_pn(Effects, ServerApSecret) ->
    Keys = #{application => roadrunner_quic_keys:traffic_keys(aes_128_gcm, ServerApSecret)},
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

%% Like flush_with_acks/5 but accumulates every application frame across the
%% ACK-paced rounds, so a test can find frames other than STREAM (e.g.
%% DATA_BLOCKED). Stops once a round carries no more stream data; the
%% accumulator order is irrelevant to the membership assertions.
flush_app_frames(State, Effects, ServerApSecret, ClientApSecret, AckPN) ->
    flush_app_frames(State, Effects, ServerApSecret, ClientApSecret, AckPN, []).

flush_app_frames(State, Effects, ServerApSecret, ClientApSecret, AckPN, Acc) ->
    Frames = sent_app_frames(Effects, ServerApSecret),
    Acc1 = lists:foldl(fun(Frame, A) -> [Frame | A] end, Acc, Frames),
    case [D || {stream, 0, _, D, _} <- Frames] of
        [] ->
            Acc1;
        _ ->
            Largest = largest_app_pn(Effects, ServerApSecret),
            Ack = app_datagram([{ack, Largest, 0, Largest, [], undefined}], AckPN, ClientApSecret),
            {State1, Effects1} = ?M:handle_datagram(?NOW, Ack, State),
            flush_app_frames(State1, Effects1, ServerApSecret, ClientApSecret, AckPN + 1, Acc1)
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
