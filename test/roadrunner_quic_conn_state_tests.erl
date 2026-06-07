-module(roadrunner_quic_conn_state_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_quic_conn_state).
-define(TC, roadrunner_quic_test_client).

%% TLS handshake message types asserted on (RFC 8446 §4).
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

tampered_client_finished_crashes_test() ->
    %% A forged Finished fails verification; the decision core lets it crash
    %% rather than reaching `connected` (no graceful handshake-failure path
    %% in v1).
    #{state1 := State1, client_hs_secret := ClientHsSecret, cf_framed := ClientFinished} = connect(),
    <<Type, Len:24, First, Rest/binary>> = ClientFinished,
    Tampered = <<Type, Len:24, (First bxor 1), Rest/binary>>,
    HsKeys = roadrunner_quic_keys:traffic_keys(ClientHsSecret),
    Datagram = ?TC:seal(handshake, 0, HsKeys, [{crypto, 0, Tampered}], ?DCID, ?SCID),
    ?assertError(_, ?M:handle_datagram(?NOW, Datagram, State1)).

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

emits(Effects) ->
    [Emit || {emit, _Owner, _Event} = Emit <- Effects].

arm_deadline(Effects) ->
    [AtMs] = [At || {arm_timer, pto, At} <- Effects],
    AtMs.
