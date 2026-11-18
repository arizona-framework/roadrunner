-module(roadrunner_conn_loop_http3_uni_tests).
-moduledoc """
Unit tests for the pure peer-unidirectional-stream state machine in
`roadrunner_conn_loop_http3` (`uni_event/4` + `uni_reset/1`). The live
QUIC wiring is covered end-to-end by `roadrunner_http3_SUITE`.

Connection-error codes asserted here are RFC 9114 §8.1 values:
`16#0103` = H3_STREAM_CREATION_ERROR, `16#0104` = H3_CLOSED_CRITICAL_STREAM,
`16#0105` = H3_FRAME_UNEXPECTED, `16#0106` = H3_FRAME_ERROR,
`16#0107` = H3_EXCESSIVE_LOAD, `16#0109` = H3_SETTINGS_ERROR,
`16#0108` = H3_ID_ERROR, `16#010A` = H3_MISSING_SETTINGS; and the RFC 9204 §8.3 value `16#0202` =
QPACK_DECODER_STREAM_ERROR.
""".
-include_lib("eunit/include/eunit.hrl").
-include("../include/roadrunner_http3_control.hrl").

ev(UniState, Critical, Data, Fin) ->
    roadrunner_conn_loop_http3:uni_event(UniState, Critical, Data, Fin).

%% --- frame / stream-type builders ---

%% The native encoders return iodata; these helpers build on-wire frames
%% (binary) fed into the decode-side state machine, so flatten them.
%% `encode_stream_type/1` is already a single varint binary.
t(Type) -> roadrunner_quic_h3_frame:encode_stream_type(Type).
settings() ->
    iolist_to_binary(roadrunner_quic_h3_frame:encode_settings(#{qpack_max_table_capacity => 0})).
goaway() -> goaway(0).
goaway(Id) -> iolist_to_binary(roadrunner_quic_h3_frame:encode_goaway(Id)).
%% MAX_PUSH_ID (0x0d) and CANCEL_PUSH (0x03): only a client sends them, so
%% the native h3 codec has no encoder; build the wire frames directly.
max_push_id(Id) -> id_frame(16#0d, Id).
cancel_push(Id) -> id_frame(16#03, Id).
id_frame(Type, Id) ->
    Payload = roadrunner_quic_varint:encode(Id),
    iolist_to_binary([
        roadrunner_quic_varint:encode(Type),
        roadrunner_quic_varint:encode(iolist_size(Payload)),
        Payload
    ]).
data() -> iolist_to_binary(roadrunner_quic_h3_frame:encode_data(~"x")).
headers() -> iolist_to_binary(roadrunner_quic_h3_frame:encode_headers(~"blk")).
%% PUSH_PROMISE (type 0x05): a server never sends one, so the native h3
%% codec has no encoder for it; build the wire frame directly to exercise
%% the decode-side rejection on the control stream.
push_promise() ->
    Payload = [roadrunner_quic_varint:encode(0), ~"blk"],
    iolist_to_binary([
        roadrunner_quic_varint:encode(16#05),
        roadrunner_quic_varint:encode(iolist_size(Payload)),
        Payload
    ]).

%% --- stream-type classification (from {pending, ...}) ---

pending_type_incomplete_open_test() ->
    %% No type byte yet and the stream stays open — keep buffering.
    ?assertEqual({{pending, <<>>}, #{}}, ev({pending, <<>>}, #{}, <<>>, false)).

pending_type_incomplete_fin_test() ->
    %% Closed before a type arrived — nothing to enforce, drop it.
    ?assertEqual({drop, #{}}, ev({pending, <<>>}, #{}, <<>>, true)).

control_stream_claimed_test() ->
    %% Control type + SETTINGS as the first (and only buffered) frame.
    ?assertEqual(
        {{control, <<>>, #h3_control{settings = #{qpack_max_table_capacity => 0}}}, #{
            control => true
        }},
        ev({pending, <<>>}, #{}, <<(t(control))/binary, (settings())/binary>>, false)
    ).

duplicate_control_stream_test() ->
    ?assertMatch(
        {conn_error, 16#0103, _},
        ev({pending, <<>>}, #{control => true}, t(control), false)
    ).

qpack_encoder_claimed_test() ->
    ?assertEqual(
        {{qpack_encoder, <<>>}, #{qpack_encoder => true}},
        ev({pending, <<>>}, #{}, t(qpack_encoder), false)
    ).

qpack_decoder_claimed_test() ->
    ?assertEqual(
        {{qpack_decoder, none}, #{qpack_decoder => true}},
        ev({pending, <<>>}, #{}, t(qpack_decoder), false)
    ).

duplicate_qpack_stream_test() ->
    ?assertMatch(
        {conn_error, 16#0103, _},
        ev({pending, <<>>}, #{qpack_encoder => true}, t(qpack_encoder), false)
    ).

qpack_stream_closed_test() ->
    %% A QPACK stream the peer immediately closes (FIN) is a critical
    %% stream close.
    ?assertMatch(
        {conn_error, 16#0104, _},
        ev({pending, <<>>}, #{}, t(qpack_decoder), true)
    ).

client_push_stream_test() ->
    ?assertMatch(
        {conn_error, 16#0103, _},
        ev({pending, <<>>}, #{}, t(push), false)
    ).

unknown_stream_drained_test() ->
    ?assertEqual({drain, #{}}, ev({pending, <<>>}, #{}, t(16#21), false)).

unknown_stream_closed_test() ->
    ?assertEqual({drop, #{}}, ev({pending, <<>>}, #{}, t(16#21), true)).

%% --- control-stream frame sequence (from {control, ...}) ---

control_settings_first_test() ->
    %% The peer's SETTINGS are kept on the stream state, so the conn loop
    %% can read its limits (SETTINGS_MAX_FIELD_SECTION_SIZE) from them.
    ?assertEqual(
        {{control, <<>>, #h3_control{settings = #{qpack_max_table_capacity => 0}}}, #{}},
        ev({control, <<>>, #h3_control{}}, #{}, settings(), false)
    ).

control_settings_kept_after_later_frames_test() ->
    Settings = iolist_to_binary(
        roadrunner_quic_h3_frame:encode_settings(#{max_field_section_size => 4096})
    ),
    ?assertEqual(
        {
            {control, <<>>, #h3_control{
                settings = #{max_field_section_size => 4096}, goaway_id = 0
            }},
            #{}
        },
        ev({control, <<>>, #h3_control{}}, #{}, <<Settings/binary, (goaway())/binary>>, false)
    ).

control_missing_settings_test() ->
    %% A non-SETTINGS frame before SETTINGS → H3_MISSING_SETTINGS.
    ?assertMatch(
        {conn_error, 16#010A, _}, ev({control, <<>>, #h3_control{}}, #{}, goaway(), false)
    ).

control_duplicate_settings_test() ->
    ?assertMatch(
        {conn_error, 16#0105, _},
        ev({control, <<>>, #h3_control{settings = #{}}}, #{}, settings(), false)
    ).

control_allowed_frame_after_settings_test() ->
    %% GOAWAY after SETTINGS is allowed.
    ?assertEqual(
        {{control, <<>>, #h3_control{settings = #{}, goaway_id = 0}}, #{}},
        ev({control, <<>>, #h3_control{settings = #{}}}, #{}, goaway(), false)
    ).

control_reserved_frame_ignored_test() ->
    %% A reserved (grease) frame type, 0x21 here, is ignored (RFC 9114 §7.2.8).
    Control = #h3_control{settings = #{}},
    ?assertEqual(
        {{control, <<>>, Control}, #{}}, ev({control, <<>>, Control}, #{}, <<16#21, 0>>, false)
    ).

control_data_frame_rejected_test() ->
    ?assertMatch(
        {conn_error, 16#0105, _},
        ev({control, <<>>, #h3_control{settings = #{}}}, #{}, data(), false)
    ).

control_headers_frame_rejected_test() ->
    ?assertMatch(
        {conn_error, 16#0105, _},
        ev({control, <<>>, #h3_control{settings = #{}}}, #{}, headers(), false)
    ).

control_push_promise_rejected_test() ->
    ?assertMatch(
        {conn_error, 16#0105, _},
        ev({control, <<>>, #h3_control{settings = #{}}}, #{}, push_promise(), false)
    ).

control_partial_frame_buffered_test() ->
    %% A lone frame-type byte (incomplete frame) is buffered as-is.
    ?assertEqual(
        {{control, <<4>>, #h3_control{}}, #{}},
        ev({control, <<>>, #h3_control{}}, #{}, <<4>>, false)
    ).

control_h2_reserved_frame_test() ->
    %% Frame type 0x02 is HTTP/2-reserved → H3_FRAME_UNEXPECTED.
    ?assertMatch(
        {conn_error, 16#0105, _},
        ev({control, <<>>, #h3_control{settings = #{}}}, #{}, <<2, 0>>, false)
    ).

control_oversized_frame_test() ->
    Oversized = iolist_to_binary([
        roadrunner_quic_varint:encode(0), roadrunner_quic_varint:encode(16#FFFFFFFF)
    ]),
    ?assertMatch(
        {conn_error, 16#0107, _},
        ev({control, <<>>, #h3_control{settings = #{}}}, #{}, Oversized, false)
    ).

control_truncated_settings_test() ->
    %% RFC 9114 §7.1: a SETTINGS payload ending inside a pair (an
    %% identifier with no value) is H3_FRAME_ERROR, not H3_SETTINGS_ERROR.
    ?assertMatch(
        {conn_error, 16#0106, _}, ev({control, <<>>, #h3_control{}}, #{}, <<16#04, 1, 1>>, false)
    ).

control_malformed_goaway_test() ->
    %% A GOAWAY (0x07) with a byte past its id is malformed (§7.1):
    %% H3_FRAME_ERROR.
    ?assertMatch(
        {conn_error, 16#0106, _},
        ev({control, <<>>, #h3_control{settings = #{}}}, #{}, <<16#07, 2, 0, 0>>, false)
    ).

control_malformed_push_promise_test() ->
    %% PUSH_PROMISE (0x05) never belongs on the control stream, so even an
    %% empty (malformed) one is H3_FRAME_UNEXPECTED.
    ?assertMatch(
        {conn_error, 16#0105, _},
        ev({control, <<>>, #h3_control{settings = #{}}}, #{}, <<16#05, 0>>, false)
    ).

control_forbidden_setting_test() ->
    %% An HTTP/2-only setting (MAX_CONCURRENT_STREAMS = 0x03) is
    %% forbidden in HTTP/3 → H3_SETTINGS_ERROR.
    Forbidden = iolist_to_binary(roadrunner_quic_h3_frame:encode_settings(#{16#03 => 100})),
    ?assertMatch(
        {conn_error, 16#0109, _}, ev({control, <<>>, #h3_control{}}, #{}, Forbidden, false)
    ).

control_stream_closed_test() ->
    %% FIN on the control stream is a critical stream close.
    ?assertMatch(
        {conn_error, 16#0104, _}, ev({control, <<>>, #h3_control{settings = #{}}}, #{}, <<>>, true)
    ).

%% --- IDs the client's control frames carry ---

control_max_push_id_kept_and_may_stay_or_grow_test() ->
    Control = #h3_control{settings = #{}},
    ?assertEqual(
        {{control, <<>>, Control#h3_control{max_push_id = 5}}, #{}},
        ev(
            {control, <<>>, Control},
            #{},
            <<(max_push_id(3))/binary, (max_push_id(3))/binary, (max_push_id(5))/binary>>,
            false
        )
    ).

control_max_push_id_going_down_test() ->
    %% RFC 9114 §7.2.7: a MAX_PUSH_ID below the last one → H3_ID_ERROR.
    ?assertMatch(
        {conn_error, 16#0108, _},
        ev(
            {control, <<>>, #h3_control{settings = #{}, max_push_id = 5}},
            #{},
            max_push_id(4),
            false
        )
    ).

control_cancel_push_within_max_push_id_test() ->
    %% RFC 9114 §7.2.3: a CANCEL_PUSH for a push ID no PUSH_PROMISE has
    %% mentioned → H3_ID_ERROR. Roadrunner never promises a push, so that
    %% holds even for a push ID the client's MAX_PUSH_ID allows.
    ?assertMatch(
        {conn_error, 16#0108, _},
        ev(
            {control, <<>>, #h3_control{settings = #{}, max_push_id = 5}},
            #{},
            cancel_push(0),
            false
        )
    ).

control_cancel_push_beyond_max_push_id_test() ->
    ?assertMatch(
        {conn_error, 16#0108, _},
        ev(
            {control, <<>>, #h3_control{settings = #{}, max_push_id = 5}},
            #{},
            cancel_push(6),
            false
        )
    ).

control_cancel_push_before_max_push_id_test() ->
    ?assertMatch(
        {conn_error, 16#0108, _},
        ev({control, <<>>, #h3_control{settings = #{}}}, #{}, cancel_push(0), false)
    ).

control_goaway_may_stay_or_go_down_test() ->
    Control = #h3_control{settings = #{}},
    ?assertEqual(
        {{control, <<>>, Control#h3_control{goaway_id = 2}}, #{}},
        ev(
            {control, <<>>, Control},
            #{},
            <<(goaway(4))/binary, (goaway(4))/binary, (goaway(2))/binary>>,
            false
        )
    ).

control_goaway_going_up_test() ->
    %% RFC 9114 §5.2: a GOAWAY ID above the last one → H3_ID_ERROR.
    ?assertMatch(
        {conn_error, 16#0108, _},
        ev({control, <<>>, #h3_control{settings = #{}, goaway_id = 4}}, #{}, goaway(8), false)
    ).

%% --- draining an unknown stream type (from drain) ---

drain_more_test() ->
    ?assertEqual({drain, #{}}, ev(drain, #{}, ~"junk", false)).

drain_closed_test() ->
    ?assertEqual({drop, #{}}, ev(drain, #{}, <<>>, true)).

%% --- QPACK encoder stream ---
%%
%% `uni_event/4` only hands the encoder stream's bytes back, the ones from
%% the stream-type chunk on and any partial instruction kept from before;
%% the conn applies them to its dynamic table (`roadrunner_qpack_tests`
%% covers the instructions).

encoder_bytes_after_type_test() ->
    ?assertEqual(
        {{qpack_encoder, <<16#20, 16#20>>}, #{qpack_encoder => true}},
        ev({pending, <<>>}, #{}, <<(t(qpack_encoder))/binary, 16#20, 16#20>>, false)
    ).

encoder_bytes_after_pending_test() ->
    %% A partial instruction kept from the last chunk comes first.
    ?assertEqual(
        {{qpack_encoder, <<16#3F, 16#E1, 16#1F>>}, #{}},
        ev({qpack_encoder, <<16#3F>>}, #{}, <<16#E1, 16#1F>>, false)
    ).

encoder_closed_test() ->
    %% RFC 9204 §4.2: closing the encoder stream is a closed critical
    %% stream, mid-instruction or not.
    ?assertMatch({conn_error, 16#0104, _}, ev({qpack_encoder, <<>>}, #{}, <<16#20>>, true)),
    ?assertMatch({conn_error, 16#0104, _}, ev({qpack_encoder, <<16#3F>>}, #{}, <<>>, true)),
    ?assertMatch(
        {conn_error, 16#0104, _}, ev({pending, <<>>}, #{}, t(qpack_encoder), true)
    ).

%% --- QPACK decoder stream (our encoder never inserts) ---

decoder_stream_cancellation_accepted_test() ->
    %% Stream Cancellation (01xxxxxx) with a stream id inside the prefix.
    ?assertEqual(
        {{qpack_decoder, none}, #{qpack_decoder => true}},
        ev({pending, <<>>}, #{}, <<(t(qpack_decoder))/binary, 16#44, 16#48>>, false)
    ).

decoder_stream_cancellation_split_test() ->
    %% A stream id past the 6-bit prefix (0x7F) continues in later bytes,
    %% possibly in a later chunk.
    ?assertEqual({{qpack_decoder, 0}, #{}}, ev({qpack_decoder, none}, #{}, <<16#7F>>, false)),
    ?assertEqual({{qpack_decoder, 1}, #{}}, ev({qpack_decoder, 0}, #{}, <<16#80>>, false)),
    ?assertEqual({{qpack_decoder, none}, #{}}, ev({qpack_decoder, 1}, #{}, <<16#01>>, false)).

decoder_integer_too_long_test() ->
    ?assertMatch({conn_error, 16#0202, _}, ev({qpack_decoder, 9}, #{}, <<16#80>>, false)).

decoder_section_ack_rejected_test() ->
    %% Section Acknowledgment (1xxxxxxx, §4.4.1): we never send a section
    %% with a non-zero Required Insert Count.
    ?assertMatch({conn_error, 16#0202, _}, ev({qpack_decoder, none}, #{}, <<16#84>>, false)).

decoder_insert_count_increment_rejected_test() ->
    %% Insert Count Increment (00xxxxxx, §4.4.3): zero, and any increment
    %% past the inserts we never made.
    ?assertMatch({conn_error, 16#0202, _}, ev({qpack_decoder, none}, #{}, <<16#00>>, false)),
    ?assertMatch({conn_error, 16#0202, _}, ev({qpack_decoder, none}, #{}, <<16#01>>, false)).

decoder_closed_test() ->
    ?assertMatch({conn_error, 16#0104, _}, ev({qpack_decoder, none}, #{}, <<>>, true)).

%% --- reset classification ---

reset_control_is_critical_test() ->
    ?assertEqual(
        critical, roadrunner_conn_loop_http3:uni_reset({control, <<>>, #h3_control{settings = #{}}})
    ).

reset_qpack_is_critical_test() ->
    ?assertEqual(critical, roadrunner_conn_loop_http3:uni_reset({qpack_encoder, <<>>})),
    ?assertEqual(critical, roadrunner_conn_loop_http3:uni_reset({qpack_decoder, none})).

reset_pending_is_noncritical_test() ->
    ?assertEqual(noncritical, roadrunner_conn_loop_http3:uni_reset({pending, <<>>})).

reset_unknown_is_noncritical_test() ->
    ?assertEqual(noncritical, roadrunner_conn_loop_http3:uni_reset(drain)).
