-module(roadrunner_quic_send_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_quic_send).

-define(DCID, <<1, 2, 3, 4, 5, 6, 7, 8>>).
-define(SCID, <<9, 10, 11, 12>>).

%% =============================================================================
%% Round trips: a sent datagram decodes back through roadrunner_quic_recv
%% (the RFC-9001-A.3-validated inverse) to the same frames/level/pn.
%% =============================================================================

%% An Initial-bearing datagram is padded to 1200 and decodes to its frames
%% (the trailing zero padding is ignored by the receiver).
initial_round_trip_test() ->
    Frames = [{crypto, 0, <<"server-hello-bytes">>}],
    Entries = #{initial => #{frames => Frames, keys => initial_keys(), pn => 0}},
    {Datagram, Sent} = ?M:datagram(Entries, ?DCID, ?SCID),
    ?assertEqual(1200, byte_size(Datagram)),
    ?assertEqual(
        [{ok, #{level => initial, pn => 0, frames => Frames}}],
        recv(Datagram, #{initial => initial_keys()})
    ),
    ?assertMatch([#{level := initial, pn := 0, ack_eliciting := true}], Sent).

%% A Handshake-only datagram is not padded to 1200.
handshake_round_trip_test() ->
    Frames = [{crypto, 0, <<"encrypted-extensions-and-cert">>}],
    Entries = #{handshake => #{frames => Frames, keys => handshake_keys(), pn => 5}},
    {Datagram, Sent} = ?M:datagram(Entries, ?DCID, ?SCID),
    ?assert(byte_size(Datagram) < 1200),
    ?assertEqual(
        [{ok, #{level => handshake, pn => 5, frames => Frames}}],
        recv(Datagram, #{handshake => handshake_keys()})
    ),
    %% A single non-Initial packet is the whole (unpadded) datagram, so its
    %% recorded length equals the datagram size; the record also carries the
    %% frames for retransmission.
    ?assertEqual(
        [
            #{
                level => handshake,
                pn => 5,
                length => byte_size(Datagram),
                ack_eliciting => true,
                frames => Frames
            }
        ],
        Sent
    ).

%% A multi-byte packet number is encoded at its minimal width and decodes
%% back to the same value.
multi_byte_pn_round_trip_test() ->
    Frames = [{crypto, 0, <<"handshake-with-a-wide-packet-number">>}],
    Entries = #{handshake => #{frames => Frames, keys => handshake_keys(), pn => 16#1234}},
    {Datagram, Sent} = ?M:datagram(Entries, ?DCID, ?SCID),
    ?assertEqual(
        [{ok, #{level => handshake, pn => 16#1234, frames => Frames}}],
        recv(Datagram, #{handshake => handshake_keys()})
    ),
    ?assertMatch([#{pn := 16#1234}], Sent).

%% Version, DCID, and SCID are not header-protected, so a produced long
%% packet's header fields can be read straight off the wire (pins the
%% encode_long arguments independently of the receiver).
header_fields_test() ->
    Frames = [{crypto, 0, <<"handshake-crypto-payload">>}],
    Entries = #{handshake => #{frames => Frames, keys => handshake_keys(), pn => 5}},
    {Datagram, _} = ?M:datagram(Entries, ?DCID, ?SCID),
    <<_FirstByte, Version:32, DCIDLen, AfterDCIDLen/binary>> = Datagram,
    <<DCID:DCIDLen/binary, SCIDLen, SCID:SCIDLen/binary, _/binary>> = AfterDCIDLen,
    ?assertEqual(16#00000001, Version),
    ?assertEqual(?DCID, DCID),
    ?assertEqual(?SCID, SCID).

%% Coalescing an Initial with a 1-RTT packet is a contract violation (the
%% trailing 1200 pad would corrupt the short-header packet).
initial_with_application_rejected_test() ->
    Entries = #{
        initial => #{frames => [{crypto, 0, <<"server-hello">>}], keys => initial_keys(), pn => 0},
        application => #{
            frames => [{stream, 0, 0, <<"body">>, true}], keys => application_keys(), pn => 0
        }
    },
    ?assertError(initial_with_application_coalesced, ?M:datagram(Entries, ?DCID, ?SCID)).

%% A 1-RTT short-header datagram carries the explicit key phase.
application_round_trip_test() ->
    Frames = [{stream, 0, 0, <<"application-response-body">>, true}],
    Entries = #{
        application => #{frames => Frames, keys => application_keys(), pn => 9, key_phase => 1}
    },
    {Datagram, _Sent} = ?M:datagram(Entries, ?DCID, ?SCID),
    ?assert(byte_size(Datagram) < 1200),
    ?assertEqual(
        [{ok, #{level => application, pn => 9, frames => Frames, key_phase => 1}}],
        recv(Datagram, #{application => application_keys()})
    ).

%% Key phase defaults to 0 when omitted.
application_default_key_phase_test() ->
    Frames = [{stream, 0, 0, <<"more-body-data">>, false}],
    Entries = #{application => #{frames => Frames, keys => application_keys(), pn => 1}},
    {Datagram, _} = ?M:datagram(Entries, ?DCID, ?SCID),
    ?assertEqual(
        [{ok, #{level => application, pn => 1, frames => Frames, key_phase => 0}}],
        recv(Datagram, #{application => application_keys()})
    ).

%% Initial and Handshake coalesce into one 1200-byte datagram, in order,
%% and each decodes with its own level keys.
coalesced_datagram_test() ->
    InitialFrames = [{crypto, 0, <<"server-hello">>}],
    HandshakeFrames = [{crypto, 0, <<"ee-cert-certverify-finished">>}],
    Entries = #{
        initial => #{frames => InitialFrames, keys => initial_keys(), pn => 0},
        handshake => #{frames => HandshakeFrames, keys => handshake_keys(), pn => 0}
    },
    {Datagram, Sent} = ?M:datagram(Entries, ?DCID, ?SCID),
    ?assertEqual(1200, byte_size(Datagram)),
    ?assertEqual(
        [
            {ok, #{level => initial, pn => 0, frames => InitialFrames}},
            {ok, #{level => handshake, pn => 0, frames => HandshakeFrames}}
        ],
        recv(Datagram, #{initial => initial_keys(), handshake => handshake_keys()})
    ),
    ?assertMatch([#{level := initial}, #{level := handshake}], Sent).

%% A sub-4-byte payload (one PING) is padded for the header-protection
%% sample; the PING survives and trailing PADDING frames fill the rest.
small_packet_padded_test() ->
    Entries = #{handshake => #{frames => [ping], keys => handshake_keys(), pn => 3}},
    {Datagram, _} = ?M:datagram(Entries, ?DCID, ?SCID),
    [{ok, #{frames := Frames}}] = recv(Datagram, #{handshake => handshake_keys()}),
    ?assertEqual(ping, hd(Frames)),
    ?assert(lists:all(fun(F) -> F =:= padding end, tl(Frames))).

%% =============================================================================
%% Sent records: ack-eliciting classification (RFC 9002 §2).
%% =============================================================================

ack_eliciting_classification_test() ->
    Cases = [
        {[{crypto, 0, <<"data">>}], true},
        {[{ack, 0, 0, 0, [], undefined}], false},
        {[{connection_close, transport, 0, 0, <<>>}], false},
        {[padding, padding, padding, padding], false}
    ],
    [
        begin
            Entry = #{frames => Frames, keys => handshake_keys(), pn => 1},
            {_, [#{ack_eliciting := AckEliciting}]} = ?M:datagram(
                #{handshake => Entry}, ?DCID, ?SCID
            ),
            ?assertEqual(Expected, AckEliciting)
        end
     || {Frames, Expected} <- Cases
    ].

%% =============================================================================
%% Helpers
%% =============================================================================

recv(Datagram, Keys) ->
    roadrunner_quic_recv:datagram(Datagram, byte_size(?DCID), Keys, #{}).

initial_keys() -> #{key => <<31:128>>, iv => <<32:96>>, hp => <<33:128>>}.
handshake_keys() -> #{key => <<11:128>>, iv => <<12:96>>, hp => <<13:128>>}.
application_keys() -> #{key => <<21:128>>, iv => <<22:96>>, hp => <<23:128>>}.
