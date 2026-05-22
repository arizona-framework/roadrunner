-module(roadrunner_conn_loop_http3_uni_tests).
-moduledoc """
Unit tests for the pure peer-unidirectional-stream state machine in
`roadrunner_conn_loop_http3` (`uni_event/4` + `uni_reset/1`). The live
QUIC wiring is covered end-to-end by `roadrunner_http3_SUITE`.

Connection-error codes asserted here are RFC 9114 §8.1 values:
`16#0103` = H3_STREAM_CREATION_ERROR, `16#0104` = H3_CLOSED_CRITICAL_STREAM,
`16#0105` = H3_FRAME_UNEXPECTED, `16#0106` = H3_FRAME_ERROR,
`16#010A` = H3_MISSING_SETTINGS.
""".
-include_lib("eunit/include/eunit.hrl").

ev(UniState, Critical, Data, Fin) ->
    roadrunner_conn_loop_http3:uni_event(UniState, Critical, Data, Fin).

%% --- frame / stream-type builders ---

t(Type) -> quic_h3_frame:encode_stream_type(Type).
settings() -> quic_h3_frame:encode_settings(#{qpack_max_table_capacity => 0}).
goaway() -> quic_h3_frame:encode_goaway(0).
data() -> quic_h3_frame:encode_data(~"x").
headers() -> quic_h3_frame:encode_headers(~"blk").
push_promise() -> quic_h3_frame:encode_push_promise(0, ~"blk").

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
        {{control, <<>>, true}, #{control => true}},
        ev({pending, <<>>}, #{}, <<(t(control))/binary, (settings())/binary>>, false)
    ).

duplicate_control_stream_test() ->
    ?assertMatch(
        {conn_error, 16#0103, _},
        ev({pending, <<>>}, #{control => true}, t(control), false)
    ).

qpack_encoder_claimed_test() ->
    ?assertEqual(
        {{drain, critical}, #{qpack_encoder => true}},
        ev({pending, <<>>}, #{}, t(qpack_encoder), false)
    ).

qpack_decoder_claimed_test() ->
    ?assertEqual(
        {{drain, critical}, #{qpack_decoder => true}},
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
    ?assertEqual({{drain, noncritical}, #{}}, ev({pending, <<>>}, #{}, t(16#21), false)).

unknown_stream_closed_test() ->
    ?assertEqual({drop, #{}}, ev({pending, <<>>}, #{}, t(16#21), true)).

%% --- control-stream frame sequence (from {control, ...}) ---

control_settings_first_test() ->
    ?assertEqual({{control, <<>>, true}, #{}}, ev({control, <<>>, false}, #{}, settings(), false)).

control_missing_settings_test() ->
    %% A non-SETTINGS frame before SETTINGS → H3_MISSING_SETTINGS.
    ?assertMatch({conn_error, 16#010A, _}, ev({control, <<>>, false}, #{}, goaway(), false)).

control_duplicate_settings_test() ->
    ?assertMatch({conn_error, 16#0105, _}, ev({control, <<>>, true}, #{}, settings(), false)).

control_allowed_frame_after_settings_test() ->
    %% GOAWAY after SETTINGS is allowed.
    ?assertEqual({{control, <<>>, true}, #{}}, ev({control, <<>>, true}, #{}, goaway(), false)).

control_data_frame_rejected_test() ->
    ?assertMatch({conn_error, 16#0105, _}, ev({control, <<>>, true}, #{}, data(), false)).

control_headers_frame_rejected_test() ->
    ?assertMatch({conn_error, 16#0105, _}, ev({control, <<>>, true}, #{}, headers(), false)).

control_push_promise_rejected_test() ->
    ?assertMatch({conn_error, 16#0105, _}, ev({control, <<>>, true}, #{}, push_promise(), false)).

control_partial_frame_buffered_test() ->
    %% A lone frame-type byte (incomplete frame) is buffered as-is.
    ?assertEqual({{control, <<4>>, false}, #{}}, ev({control, <<>>, false}, #{}, <<4>>, false)).

control_h2_reserved_frame_test() ->
    %% Frame type 0x02 is HTTP/2-reserved → H3_FRAME_UNEXPECTED.
    ?assertMatch({conn_error, 16#0105, _}, ev({control, <<>>, true}, #{}, <<2, 0>>, false)).

control_oversized_frame_test() ->
    Oversized = iolist_to_binary([quic_varint:encode(0), quic_varint:encode(16#FFFFFFFF)]),
    ?assertMatch({conn_error, 16#0106, _}, ev({control, <<>>, true}, #{}, Oversized, false)).

control_forbidden_setting_test() ->
    %% An HTTP/2-only setting (MAX_CONCURRENT_STREAMS = 0x03) is
    %% forbidden in HTTP/3 → H3_SETTINGS_ERROR.
    Forbidden = quic_h3_frame:encode_settings(#{16#03 => 100}),
    ?assertMatch({conn_error, 16#0109, _}, ev({control, <<>>, false}, #{}, Forbidden, false)).

control_stream_closed_test() ->
    %% FIN on the control stream is a critical stream close.
    ?assertMatch({conn_error, 16#0104, _}, ev({control, <<>>, true}, #{}, <<>>, true)).

%% --- draining streams (from {drain, ...}) ---

drain_critical_more_test() ->
    ?assertEqual({{drain, critical}, #{}}, ev({drain, critical}, #{}, ~"junk", false)).

drain_critical_closed_test() ->
    ?assertMatch({conn_error, 16#0104, _}, ev({drain, critical}, #{}, <<>>, true)).

drain_noncritical_closed_test() ->
    ?assertEqual({drop, #{}}, ev({drain, noncritical}, #{}, <<>>, true)).

%% --- reset classification ---

reset_control_is_critical_test() ->
    ?assertEqual(critical, roadrunner_conn_loop_http3:uni_reset({control, <<>>, true})).

reset_qpack_is_critical_test() ->
    ?assertEqual(critical, roadrunner_conn_loop_http3:uni_reset({drain, critical})).

reset_pending_is_noncritical_test() ->
    ?assertEqual(noncritical, roadrunner_conn_loop_http3:uni_reset({pending, <<>>})).

reset_unknown_is_noncritical_test() ->
    ?assertEqual(noncritical, roadrunner_conn_loop_http3:uni_reset({drain, noncritical})).
