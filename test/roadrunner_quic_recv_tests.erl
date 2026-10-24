-module(roadrunner_quic_recv_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_quic_recv).

%% Server fixed connection-ID length (only used to locate short-header PNs).
-define(DCID_LEN, 8).
-define(DCID, <<1, 2, 3, 4, 5, 6, 7, 8>>).
-define(SCID, <<9, 10, 11, 12>>).

%% =============================================================================
%% RFC 9001 Appendix A.3 (Server Initial) — the authority. The published
%% protected packet, decrypted with the vector's keys, yields the vector's
%% frames at the Initial level with packet number 1.
%% =============================================================================

rfc9001_a3_server_initial_test() ->
    Keys = #{
        initial => #{
            key => hex(~"cf3a5331653c364c88f0f379b6067e37"),
            iv => hex(~"0ac1493ca1905853b0bba03e"),
            hp => hex(~"c206b8d9b9f0f37644430b490eeaa314")
        }
    },
    Packet = hex(
        ~"cf000000010008f067a5502a4262b5004075c0d95a482cd0991cd25b0aac406a5816b6394100f37a1c69797554780bb38cc5a99f5ede4cf73c3ec2493a1839b3dbcba3f6ea46c5b7684df3548e7ddeb9c3bf9c73cc3f3bded74b562bfb19fb84022f8ef4cdd93795d77d06edbb7aaf2f58891850abbdca3d20398c276456cbc42158407dd074ee"
    ),
    Plaintext = hex(
        ~"02000000000600405a020000560303eefce7f7b37ba1d1632e96677825ddf73988cfc79825df566dc5430b9a045a1200130100002e00330024001d00209d3c940d89690b84d08a60993c144eca684d1081287c834d5311bcf32bb9da1a002b00020304"
    ),
    {ok, Frames} = roadrunner_quic_frame:decode_all(Plaintext),
    ?assertEqual(
        [{ok, #{level => initial, pn => 1, frames => Frames}}],
        ?M:datagram(Packet, ?DCID_LEN, Keys, #{})
    ).

%% =============================================================================
%% Round trips per encryption level (seal+protect a packet, then decode).
%% =============================================================================

%% A Handshake packet, with the largest-received threaded in (the integer
%% reconstruction clause), decodes its frames at the handshake level.
handshake_round_trip_test() ->
    {Plaintext, Frames} = frames_for([{crypto, 0, <<"handshake-crypto-data">>}]),
    Wire = seal_long(handshake, 5, handshake_keys(), Plaintext),
    ?assertEqual(
        [{ok, #{level => handshake, pn => 5, frames => Frames}}],
        ?M:datagram(Wire, ?DCID_LEN, #{handshake => handshake_keys()}, #{handshake => 4})
    ).

%% A 1-RTT short-header packet decodes at the application level and surfaces
%% the key-phase bit. Keys without a key phase open it whatever the bit.
application_round_trip_test() ->
    {Plaintext, Frames} = frames_for([{stream, 0, 0, <<"application-body">>, true}]),
    Wire = seal_short(7, application_keys(), 1, Plaintext),
    ?assertEqual(
        [
            {ok, #{
                level => application,
                pn => 7,
                frames => Frames,
                key_phase => 1,
                generation => current
            }}
        ],
        ?M:datagram(Wire, ?DCID_LEN, #{application => application_keys()}, #{})
    ).

%% A packet whose wire packet number is narrower than the full number
%% forces real reconstruction: the truncated 0x05 plus a largest of
%% 0x10004 must recover 0x10005 (used as the AEAD nonce, so a wrong
%% reconstruction would fail to decrypt). Also pins key phase 0.
reconstructed_pn_round_trip_test() ->
    {Plaintext, Frames} = frames_for([{stream, 0, 0, <<"wrapped-pn-body">>, true}]),
    FullPN = 16#10005,
    Wire = seal_short_pn(FullPN, 1, application_keys(), 0, Plaintext),
    ?assertEqual(
        [
            {ok, #{
                level => application,
                pn => FullPN,
                frames => Frames,
                key_phase => 0,
                generation => current
            }}
        ],
        ?M:datagram(Wire, ?DCID_LEN, #{application => application_keys()}, #{
            application => 16#10004
        })
    ).

%% A coalesced datagram (Initial then Handshake) decodes each packet with
%% its own level keys, in order.
coalesced_datagram_test() ->
    {InitialPlain, InitialFrames} = frames_for([{crypto, 0, <<"initial-crypto-data">>}]),
    {HandshakePlain, HandshakeFrames} = frames_for([{crypto, 0, <<"handshake-crypto-data">>}]),
    Wire = <<
        (seal_long(initial, 0, initial_keys(), InitialPlain))/binary,
        (seal_long(handshake, 0, handshake_keys(), HandshakePlain))/binary
    >>,
    ?assertEqual(
        [
            {ok, #{level => initial, pn => 0, frames => InitialFrames}},
            {ok, #{level => handshake, pn => 0, frames => HandshakeFrames}}
        ],
        ?M:datagram(
            Wire, ?DCID_LEN, #{initial => initial_keys(), handshake => handshake_keys()}, #{}
        )
    ).

%% Trailing zero padding after a packet ends the datagram cleanly (no extra
%% outcome).
trailing_padding_test() ->
    {Plaintext, Frames} = frames_for([{crypto, 0, <<"handshake-crypto-data">>}]),
    Wire = <<(seal_long(handshake, 1, handshake_keys(), Plaintext))/binary, 0, 0, 0, 0>>,
    ?assertEqual(
        [{ok, #{level => handshake, pn => 1, frames => Frames}}],
        ?M:datagram(Wire, ?DCID_LEN, #{handshake => handshake_keys()}, #{})
    ).

%% =============================================================================
%% Drops (per packet, never the whole datagram) and frame errors.
%% =============================================================================

%% No keys installed for the packet's level yet.
no_keys_dropped_test() ->
    {Plaintext, _} = frames_for([{crypto, 0, <<"handshake-crypto-data">>}]),
    Wire = seal_long(handshake, 5, handshake_keys(), Plaintext),
    ?assertEqual([{drop, no_keys}], ?M:datagram(Wire, ?DCID_LEN, #{}, #{})).

%% A tampered tag fails authentication and drops only that packet, reported
%% with its level so the loop can count it (RFC 9001 §6.6).
decrypt_failure_dropped_test() ->
    {Plaintext, _} = frames_for([{crypto, 0, <<"handshake-crypto-data">>}]),
    Wire0 = seal_long(handshake, 5, handshake_keys(), Plaintext),
    Len = byte_size(Wire0) - 1,
    <<Head:Len/binary, Last>> = Wire0,
    Tampered = <<Head/binary, (Last bxor 1)>>,
    ?assertEqual(
        [{auth_failed, handshake}],
        ?M:datagram(Tampered, ?DCID_LEN, #{handshake => handshake_keys()}, #{})
    ).

%% =============================================================================
%% Key update generations (RFC 9001 §6). The 1-RTT keys carry the current
%% generation in key phase 0, the next generation, and the previous one for
%% packets numbered below 10. Every generation shares the header-protection
%% key (§6.1).
%% =============================================================================

%% The current Key Phase bit opens with the current keys.
current_phase_opens_with_current_keys_test() ->
    {Plaintext, Frames} = frames_for([{stream, 0, 0, ~"key-update-body", false}]),
    Wire = seal_short(12, application_keys(), 0, Plaintext),
    ?assertMatch(
        [{ok, #{pn := 12, frames := Frames, key_phase := 0, generation := current}}],
        ?M:datagram(Wire, ?DCID_LEN, #{application => update_keys()}, #{application => 11})
    ).

%% A flipped bit on a packet above the previous phase opens with the next
%% keys: the peer has updated.
flipped_phase_opens_with_next_keys_test() ->
    {Plaintext, Frames} = frames_for([{stream, 0, 0, ~"key-update-body", false}]),
    Wire = seal_short(12, generation(next_packet_keys()), 1, Plaintext),
    ?assertMatch(
        [{ok, #{pn := 12, frames := Frames, key_phase := 1, generation := next}}],
        ?M:datagram(Wire, ?DCID_LEN, #{application => update_keys()}, #{application => 11})
    ).

%% A flipped bit on a packet numbered below the current phase is a reordered
%% packet from before the update: it opens with the previous keys (§6.5).
flipped_phase_below_current_opens_with_previous_keys_test() ->
    {Plaintext, Frames} = frames_for([{stream, 0, 0, ~"key-update-body", false}]),
    Wire = seal_short(9, generation(prev_packet_keys()), 1, Plaintext),
    ?assertMatch(
        [{ok, #{pn := 9, frames := Frames, key_phase := 1, generation := previous}}],
        ?M:datagram(Wire, ?DCID_LEN, #{application => update_keys()}, #{application => 11})
    ).

%% Above the current phase's first packet a flipped bit takes the next keys
%% even when the previous ones are kept, so an old-key packet numbered there
%% does not authenticate (§6.4).
old_keys_above_current_phase_fail_test() ->
    {Plaintext, _} = frames_for([{stream, 0, 0, ~"key-update-body", false}]),
    Wire = seal_short(12, generation(prev_packet_keys()), 1, Plaintext),
    ?assertEqual(
        [{auth_failed, application}],
        ?M:datagram(Wire, ?DCID_LEN, #{application => update_keys()}, #{application => 11})
    ).

%% A forged flipped bit fails the next keys like any other forgery.
forged_flipped_phase_fails_test() ->
    {Plaintext, _} = frames_for([{stream, 0, 0, ~"key-update-body", false}]),
    Wire = seal_short(12, application_keys(), 1, Plaintext),
    ?assertEqual(
        [{auth_failed, application}],
        ?M:datagram(Wire, ?DCID_LEN, #{application => update_keys()}, #{application => 11})
    ).

%% A packet too small to hold the 16-byte header-protection sample.
sample_too_short_dropped_test() ->
    Tiny = <<16#C0, 0, 0, 0, 1, 0, 0, 0, 4, 16#AA, 16#BB, 16#CC, 16#DD>>,
    ?assertEqual(
        [{drop, sample_too_short}], ?M:datagram(Tiny, ?DCID_LEN, #{initial => initial_keys()}, #{})
    ).

%% A 0-RTT packet is unsupported for a server-only v1 endpoint.
unsupported_packet_dropped_test() ->
    Wire = enc(
        roadrunner_quic_packet:encode_long(
            zero_rtt, 1, ?DCID, ?SCID, #{payload => binary:copy(<<0>>, 24)}
        )
    ),
    ?assertEqual([{drop, unsupported_packet}], ?M:datagram(Wire, ?DCID_LEN, #{}, #{})).

%% A header truncated before its boundary can be found stops the datagram.
malformed_header_stops_test() ->
    ?assertEqual([], ?M:datagram(<<16#C0, 0, 0, 0, 1, 8>>, ?DCID_LEN, #{}, #{})).

%% An authenticated payload that decodes to a malformed frame is a
%% connection error, kept distinct from a silent drop.
frame_error_reported_test() ->
    %% CRYPTO frame claiming 8 bytes of data but carrying only 3.
    BadPlaintext = <<16#06, 16#00, 16#08, 1, 2, 3>>,
    ?assertMatch({error, _}, roadrunner_quic_frame:decode_all(BadPlaintext)),
    Wire = seal_long(handshake, 5, handshake_keys(), BadPlaintext),
    ?assertMatch(
        [{frame_error, handshake, _}],
        ?M:datagram(Wire, ?DCID_LEN, #{handshake => handshake_keys()}, #{})
    ).

%% RFC 9000 §12.4: an authenticated packet with no frames is a
%% PROTOCOL_VIOLATION. A 4-byte packet number leaves room for the
%% header-protection sample in the AEAD tag alone.
no_frames_protocol_violation_test() ->
    Wire = seal_long(handshake, 16#1000000, handshake_keys(), <<>>),
    ?assertEqual(
        [{frame_error, handshake, protocol_violation}],
        ?M:datagram(Wire, ?DCID_LEN, #{handshake => handshake_keys()}, #{})
    ).

%% RFC 9000 §17.3.1: a 1-RTT packet whose reserved bits are non-zero (after
%% header protection is removed and the packet authenticates) is a
%% PROTOCOL_VIOLATION, kept distinct from a silent drop.
short_header_reserved_bits_protocol_violation_test() ->
    {Plaintext, _Frames} = frames_for([{stream, 0, 0, <<"x">>, true}]),
    Wire = seal_short_reserved(7, application_keys(), Plaintext),
    ?assertEqual(
        [{frame_error, application, protocol_violation}],
        ?M:datagram(Wire, ?DCID_LEN, #{application => application_keys()}, #{})
    ).

%% =============================================================================
%% Packet-number reconstruction (RFC 9000 §A.3) — direct, all windows.
%% =============================================================================

reconstruct_pn_fresh_space_test() ->
    ?assertEqual(1234, ?M:reconstruct_pn(undefined, 4, 1234)).

reconstruct_pn_rfc_example_test() ->
    %% RFC 9000 §A.3: largest 0xa82f30ea, truncated 0x9b32 -> 0xa82f9b32.
    ?assertEqual(16#a82f9b32, ?M:reconstruct_pn(16#a82f30ea, 2, 16#9b32)).

reconstruct_pn_window_up_test() ->
    %% Truncated value wrapped below the window: add a window.
    ?assertEqual(1034, ?M:reconstruct_pn(1000, 1, 10)).

reconstruct_pn_window_down_test() ->
    %% Candidate (762) landed a window too high: subtract a window. The
    %% result differs from both the truncated value and the candidate.
    ?assertEqual(506, ?M:reconstruct_pn(600, 1, 250)).

%% =============================================================================
%% Helpers
%% =============================================================================

enc(Iolist) -> iolist_to_binary(Iolist).

hex(H) -> binary:decode_hex(string:uppercase(H)).

%% Distinct per-level keys; any valid AES-128 material round-trips.
initial_keys() -> #{key => <<31:128>>, iv => <<32:96>>, hp => <<33:128>>}.
handshake_keys() -> #{key => <<11:128>>, iv => <<12:96>>, hp => <<13:128>>}.
application_keys() -> #{key => <<21:128>>, iv => <<22:96>>, hp => <<23:128>>}.

%% Key update generations around `application_keys/0`, all sharing its
%% header-protection key.
next_packet_keys() -> #{key => <<41:128>>, iv => <<42:96>>}.
prev_packet_keys() -> #{key => <<51:128>>, iv => <<52:96>>}.

update_keys() ->
    (application_keys())#{
        phase => 0,
        next => next_packet_keys(),
        prev => prev_packet_keys(),
        prev_below => 10
    }.

%% A generation's full keys: its AEAD key and IV with the shared
%% header-protection key.
generation(PacketKeys) ->
    maps:merge(application_keys(), PacketKeys).

%% Encode a frame list to a payload and the frames it decodes back to.
frames_for(FrameList) ->
    Plaintext = enc([roadrunner_quic_frame:encode(F) || F <- FrameList]),
    {ok, Frames} = roadrunner_quic_frame:decode_all(Plaintext),
    {Plaintext, Frames}.

%% Build a protected long-header wire packet from level keys + plaintext,
%% mirroring the send path: size the header for the sealed payload, seal
%% with the header as AAD, then apply header protection.
seal_long(Type, PN, #{key := Key, iv := IV, hp := HP}, Plaintext) ->
    PNLen = roadrunner_quic_packet:pn_length(PN),
    SealedSize = byte_size(Plaintext) + 16,
    [Header, _] = roadrunner_quic_packet:encode_long(
        Type, 1, ?DCID, ?SCID, #{pn => PN, payload => <<0:(SealedSize * 8)>>}
    ),
    Sealed = roadrunner_quic_aead:seal(Key, IV, PN, Header, Plaintext),
    Protected = roadrunner_quic_aead:protect_header(HP, Header, Sealed, byte_size(Header) - PNLen),
    <<Protected/binary, Sealed/binary>>.

seal_short(PN, #{key := Key, iv := IV, hp := HP}, KeyPhase, Plaintext) ->
    PNLen = roadrunner_quic_packet:pn_length(PN),
    [Header, _] = roadrunner_quic_packet:encode_short(?DCID, PN, <<>>, false, KeyPhase),
    Sealed = roadrunner_quic_aead:seal(Key, IV, PN, Header, Plaintext),
    Protected = roadrunner_quic_aead:protect_header(HP, Header, Sealed, byte_size(Header) - PNLen),
    <<Protected/binary, Sealed/binary>>.

%% Build a short-header packet whose wire packet number is forced to
%% `WirePNLen` bytes (the low bytes of `FullPN`), while the AEAD nonce uses
%% the full number, the way a real sender truncates the PN against the
%% largest acknowledged.
seal_short_pn(FullPN, WirePNLen, #{key := Key, iv := IV, hp := HP}, KeyPhase, Plaintext) ->
    FirstByte = 2#01000000 bor ((KeyPhase band 1) bsl 2) bor (WirePNLen - 1),
    Header =
        <<FirstByte, ?DCID/binary, (roadrunner_quic_packet:encode_pn(FullPN, WirePNLen))/binary>>,
    Sealed = roadrunner_quic_aead:seal(Key, IV, FullPN, Header, Plaintext),
    Protected = roadrunner_quic_aead:protect_header(
        HP, Header, Sealed, byte_size(Header) - WirePNLen
    ),
    <<Protected/binary, Sealed/binary>>.

%% A short-header packet with the reserved bits (mask 0x18) set; a
%% conformant 1-RTT packet leaves them 0 (RFC 9000 §17.3.1).
seal_short_reserved(PN, #{key := Key, iv := IV, hp := HP}, Plaintext) ->
    PNLen = roadrunner_quic_packet:pn_length(PN),
    FirstByte = 2#01000000 bor 16#18 bor (PNLen - 1),
    Header = <<FirstByte, ?DCID/binary, (roadrunner_quic_packet:encode_pn(PN, PNLen))/binary>>,
    Sealed = roadrunner_quic_aead:seal(Key, IV, PN, Header, Plaintext),
    Protected = roadrunner_quic_aead:protect_header(HP, Header, Sealed, byte_size(Header) - PNLen),
    <<Protected/binary, Sealed/binary>>.
