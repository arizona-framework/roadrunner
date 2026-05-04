-module(roadrunner_http2_frame_tests).
-include_lib("eunit/include/eunit.hrl").

-define(MAX, 16384).

%% =============================================================================
%% Frame header — incremental parse, MAX_FRAME_SIZE rejection.
%% =============================================================================

parse_returns_more_when_buffer_has_no_full_header_test() ->
    %% Frame header is 9 bytes; anything shorter must `more` for the
    %% delta needed to complete the header.
    ?assertEqual({more, 9}, roadrunner_http2_frame:parse(<<>>, ?MAX)),
    ?assertEqual({more, 7}, roadrunner_http2_frame:parse(<<1, 2>>, ?MAX)).

parse_returns_more_when_payload_short_test() ->
    %% Header announces length=10 but only 4 body bytes are present —
    %% caller must recv 6 more.
    Header = <<10:24, 0, 0, 0:32>>,
    Buf = <<Header/binary, 0, 1, 2, 3>>,
    ?assertEqual({more, 6}, roadrunner_http2_frame:parse(Buf, ?MAX)).

parse_rejects_oversized_frame_test() ->
    %% Length declares more than MaxFrameSize — `frame_size_error`
    %% before any body bytes are consumed.
    Bin = <<(?MAX + 1):24, 0, 0, 0:32>>,
    ?assertEqual({error, frame_size_error}, roadrunner_http2_frame:parse(Bin, ?MAX)).

parse_returns_remainder_after_frame_test() ->
    %% Two PING frames concatenated. parse returns the first plus
    %% the bytes of the second still-buffered.
    Ping1 = roadrunner_http2_frame:encode({ping, 0, <<1:64>>}),
    Ping2 = roadrunner_http2_frame:encode({ping, 0, <<2:64>>}),
    Buf = iolist_to_binary([Ping1, Ping2]),
    {ok, F1, Rest} = roadrunner_http2_frame:parse(Buf, ?MAX),
    ?assertEqual({ping, 0, <<1:64>>}, F1),
    ?assertEqual(iolist_to_binary(Ping2), Rest).

%% =============================================================================
%% Round-trip per frame type — encode then parse must be identity.
%% =============================================================================

data_frame_round_trip_test() ->
    Frame = {data, 1, 0, ~"hello"},
    ?assertEqual({ok, Frame, <<>>}, parse(Frame)).

data_frame_with_end_stream_round_trip_test() ->
    Frame = {data, 3, 16#01, ~"bye"},
    ?assertEqual({ok, Frame, <<>>}, parse(Frame)).

data_frame_with_padding_strips_pad_bytes_test() ->
    %% Manually encode a padded DATA frame: <<PadLen, Body, Pad>>.
    PadLen = 5,
    Body = ~"hello",
    Padding = <<0:(PadLen * 8)>>,
    Payload = <<PadLen:8, Body/binary, Padding/binary>>,
    Header = <<(byte_size(Payload)):24, 0, 16#08, 0:1, 1:31>>,
    Bin = <<Header/binary, Payload/binary>>,
    ?assertEqual({ok, {data, 1, 16#08, Body}, <<>>}, roadrunner_http2_frame:parse(Bin, ?MAX)).

data_frame_pad_too_long_returns_bad_padding_test() ->
    %% PadLen=10 but only 5 bytes available after the length byte —
    %% protocol error per §6.1.
    Payload = <<10:8, "hi">>,
    Header = <<(byte_size(Payload)):24, 0, 16#08, 0:1, 1:31>>,
    Bin = <<Header/binary, Payload/binary>>,
    ?assertEqual({error, bad_padding}, roadrunner_http2_frame:parse(Bin, ?MAX)).

data_on_stream_zero_is_protocol_error_test() ->
    Bin = <<0:24, 0, 0, 0:32>>,
    ?assertEqual({error, stream_id_violation}, roadrunner_http2_frame:parse(Bin, ?MAX)).

headers_frame_round_trip_no_priority_test() ->
    Frame = {headers, 1, 16#04, undefined, ~"\x00\x01a"},
    ?assertEqual({ok, Frame, <<>>}, parse(Frame)).

headers_frame_round_trip_with_priority_test() ->
    Priority = #{exclusive => true, stream_dependency => 7, weight => 16},
    Frame = {headers, 1, 16#24, Priority, ~"\x00\x01a"},
    ?assertEqual({ok, Frame, <<>>}, parse(Frame)).

headers_frame_with_priority_short_payload_is_protocol_error_test() ->
    %% PRIORITY flag set but payload shorter than the 5-byte priority
    %% block.
    Header = <<2:24, 1, 16#20, 0:1, 1:31>>,
    Bin = <<Header/binary, 0, 0>>,
    ?assertEqual({error, protocol_error}, roadrunner_http2_frame:parse(Bin, ?MAX)).

headers_with_padded_and_priority_round_trip_test() ->
    %% Both PADDED and PRIORITY flags; padding is stripped first,
    %% then the priority block prefix is parsed off the remainder.
    Priority = #{exclusive => false, stream_dependency => 0, weight => 1},
    HeaderBlock = ~"hb",
    Inner = <<0:1, 0:31, 1:8, HeaderBlock/binary>>,
    PadLen = 2,
    Payload = <<PadLen:8, Inner/binary, 0, 0>>,
    Header = <<(byte_size(Payload)):24, 1, 16#28, 0:1, 1:31>>,
    Bin = <<Header/binary, Payload/binary>>,
    ?assertEqual(
        {ok, {headers, 1, 16#28, Priority, HeaderBlock}, <<>>},
        roadrunner_http2_frame:parse(Bin, ?MAX)
    ).

headers_on_stream_zero_is_protocol_error_test() ->
    Bin = <<0:24, 1, 0, 0:32>>,
    ?assertEqual({error, stream_id_violation}, roadrunner_http2_frame:parse(Bin, ?MAX)).

headers_bad_padding_returns_error_test() ->
    %% PadLen=10 but only 2 bytes remain after the length byte.
    Payload = <<10:8, "hi">>,
    Header = <<(byte_size(Payload)):24, 1, 16#08, 0:1, 1:31>>,
    Bin = <<Header/binary, Payload/binary>>,
    ?assertEqual({error, bad_padding}, roadrunner_http2_frame:parse(Bin, ?MAX)).

priority_frame_round_trip_test() ->
    Priority = #{exclusive => true, stream_dependency => 5, weight => 32},
    Frame = {priority, 3, Priority},
    ?assertEqual({ok, Frame, <<>>}, parse(Frame)).

priority_on_stream_zero_is_protocol_error_test() ->
    Header = <<5:24, 2, 0, 0:32>>,
    Bin = <<Header/binary, 0:1, 0:31, 0:8>>,
    ?assertEqual({error, stream_id_violation}, roadrunner_http2_frame:parse(Bin, ?MAX)).

priority_bad_payload_length_returns_error_test() ->
    %% RFC 9113 §6.3: payload MUST be 5 bytes — anything else is
    %% FRAME_SIZE_ERROR but our parser tags it `bad_priority_payload`.
    Header = <<3:24, 2, 0, 0:1, 1:31>>,
    Bin = <<Header/binary, 0, 0, 0>>,
    ?assertEqual({error, bad_priority_payload}, roadrunner_http2_frame:parse(Bin, ?MAX)).

rst_stream_round_trip_test() ->
    Frame = {rst_stream, 1, no_error},
    ?assertEqual({ok, Frame, <<>>}, parse(Frame)).

rst_stream_with_unknown_code_round_trips_as_int_test() ->
    %% Unknown error codes (>= 0xE) MUST be passed through unchanged
    %% so callers can log them — RFC 9113 §11.4.
    Frame = {rst_stream, 1, 16#FFFF},
    ?assertEqual({ok, Frame, <<>>}, parse(Frame)).

rst_stream_on_stream_zero_is_protocol_error_test() ->
    Bin = <<4:24, 3, 0, 0:32, 0:32>>,
    ?assertEqual({error, stream_id_violation}, roadrunner_http2_frame:parse(Bin, ?MAX)).

rst_stream_bad_length_returns_error_test() ->
    Header = <<3:24, 3, 0, 0:1, 1:31>>,
    Bin = <<Header/binary, 0, 0, 0>>,
    ?assertEqual({error, bad_rst_stream_payload}, roadrunner_http2_frame:parse(Bin, ?MAX)).

settings_frame_round_trip_test() ->
    Frame = {settings, 0, [{1, 8192}, {5, 16384}]},
    ?assertEqual({ok, Frame, <<>>}, parse(Frame)).

settings_ack_round_trip_test() ->
    Frame = {settings, 16#01, []},
    ?assertEqual({ok, Frame, <<>>}, parse(Frame)).

settings_ack_with_body_is_protocol_error_test() ->
    %% Per §6.5: ACK SETTINGS MUST be empty.
    Header = <<6:24, 4, 16#01, 0:32>>,
    Bin = <<Header/binary, 1:16, 8192:32>>,
    ?assertEqual({error, bad_settings_payload}, roadrunner_http2_frame:parse(Bin, ?MAX)).

settings_on_non_zero_stream_is_protocol_error_test() ->
    Bin = <<0:24, 4, 0, 0:1, 1:31>>,
    ?assertEqual({error, stream_id_violation}, roadrunner_http2_frame:parse(Bin, ?MAX)).

settings_payload_not_multiple_of_six_returns_error_test() ->
    %% RFC 9113 §6.5: SETTINGS payload length MUST be a multiple of
    %% 6. 11 bytes hits the body-recursive catch-all after consuming
    %% the first 6-byte record, surfaces `bad_settings_payload`.
    Header = <<11:24, 4, 0, 0:32>>,
    Bin = <<Header/binary, 1:16, 8192:32, 0, 0, 0, 0, 0>>,
    ?assertEqual({error, bad_settings_payload}, roadrunner_http2_frame:parse(Bin, ?MAX)).

settings_short_payload_returns_error_test() ->
    %% 5 bytes — too short for a single record. Hits the
    %% catch-all on first call (no recursion).
    Header = <<5:24, 4, 0, 0:32>>,
    Bin = <<Header/binary, 0, 0, 0, 0, 0>>,
    ?assertEqual({error, bad_settings_payload}, roadrunner_http2_frame:parse(Bin, ?MAX)).

push_promise_round_trip_test() ->
    Frame = {push_promise, 1, 16#04, 2, ~"\x00hb"},
    ?assertEqual({ok, Frame, <<>>}, parse(Frame)).

push_promise_with_padding_strips_pad_bytes_test() ->
    %% PADDED PUSH_PROMISE: <<PadLen, R+PromisedId(4), HeaderBlock, Padding>>.
    PadLen = 3,
    Inner = <<0:1, 5:31, "h">>,
    Padding = <<0:(PadLen * 8)>>,
    Payload = <<PadLen:8, Inner/binary, Padding/binary>>,
    Header = <<(byte_size(Payload)):24, 5, 16#08, 0:1, 1:31>>,
    Bin = <<Header/binary, Payload/binary>>,
    ?assertEqual(
        {ok, {push_promise, 1, 16#08, 5, ~"h"}, <<>>},
        roadrunner_http2_frame:parse(Bin, ?MAX)
    ).

push_promise_on_stream_zero_is_protocol_error_test() ->
    Bin = <<4:24, 5, 0, 0:32, 0:32>>,
    ?assertEqual({error, stream_id_violation}, roadrunner_http2_frame:parse(Bin, ?MAX)).

push_promise_bad_padding_returns_error_test() ->
    Payload = <<10:8, "h">>,
    Header = <<(byte_size(Payload)):24, 5, 16#08, 0:1, 1:31>>,
    Bin = <<Header/binary, Payload/binary>>,
    ?assertEqual({error, bad_padding}, roadrunner_http2_frame:parse(Bin, ?MAX)).

push_promise_too_short_for_promised_id_test() ->
    %% After padding strip the body is only 3 bytes — can't fit the
    %% 4-byte promised stream id.
    Payload = <<0:1, 0:23>>,
    Header = <<(byte_size(Payload)):24, 5, 0, 0:1, 1:31>>,
    Bin = <<Header/binary, Payload/binary>>,
    ?assertEqual({error, bad_push_promise_payload}, roadrunner_http2_frame:parse(Bin, ?MAX)).

ping_round_trip_test() ->
    Frame = {ping, 0, <<1, 2, 3, 4, 5, 6, 7, 8>>},
    ?assertEqual({ok, Frame, <<>>}, parse(Frame)).

ping_ack_round_trip_test() ->
    Frame = {ping, 16#01, <<8, 7, 6, 5, 4, 3, 2, 1>>},
    ?assertEqual({ok, Frame, <<>>}, parse(Frame)).

ping_on_non_zero_stream_is_protocol_error_test() ->
    Bin = <<8:24, 6, 0, 0:1, 1:31, 0:64>>,
    ?assertEqual({error, stream_id_violation}, roadrunner_http2_frame:parse(Bin, ?MAX)).

ping_bad_length_returns_error_test() ->
    Header = <<7:24, 6, 0, 0:32>>,
    Bin = <<Header/binary, 0:56>>,
    ?assertEqual({error, bad_ping_payload}, roadrunner_http2_frame:parse(Bin, ?MAX)).

goaway_round_trip_test() ->
    Frame = {goaway, 5, no_error, <<>>},
    ?assertEqual({ok, Frame, <<>>}, parse(Frame)).

goaway_with_debug_round_trip_test() ->
    Frame = {goaway, 7, protocol_error, ~"oops"},
    ?assertEqual({ok, Frame, <<>>}, parse(Frame)).

goaway_on_non_zero_stream_is_protocol_error_test() ->
    Bin = <<8:24, 7, 0, 0:1, 1:31, 0:32, 0:32>>,
    ?assertEqual({error, stream_id_violation}, roadrunner_http2_frame:parse(Bin, ?MAX)).

goaway_bad_length_returns_error_test() ->
    Header = <<6:24, 7, 0, 0:32>>,
    Bin = <<Header/binary, 0:48>>,
    ?assertEqual({error, bad_goaway_payload}, roadrunner_http2_frame:parse(Bin, ?MAX)).

window_update_round_trip_on_connection_test() ->
    Frame = {window_update, 0, 1024},
    ?assertEqual({ok, Frame, <<>>}, parse(Frame)).

window_update_round_trip_on_stream_test() ->
    Frame = {window_update, 1, 65535},
    ?assertEqual({ok, Frame, <<>>}, parse(Frame)).

window_update_zero_increment_is_protocol_error_test() ->
    Header = <<4:24, 8, 0, 0:1, 1:31>>,
    Bin = <<Header/binary, 0:1, 0:31>>,
    ?assertEqual({error, window_update_zero_increment}, roadrunner_http2_frame:parse(Bin, ?MAX)).

window_update_bad_length_returns_error_test() ->
    Header = <<3:24, 8, 0, 0:32>>,
    Bin = <<Header/binary, 0, 0, 0>>,
    ?assertEqual({error, bad_window_update_payload}, roadrunner_http2_frame:parse(Bin, ?MAX)).

continuation_round_trip_test() ->
    Frame = {continuation, 1, 16#04, ~"\x00continued"},
    ?assertEqual({ok, Frame, <<>>}, parse(Frame)).

continuation_on_stream_zero_is_protocol_error_test() ->
    Bin = <<0:24, 9, 0, 0:32>>,
    ?assertEqual({error, stream_id_violation}, roadrunner_http2_frame:parse(Bin, ?MAX)).

unknown_frame_type_surfaces_unknown_tag_test() ->
    %% RFC 9113 §4.1 + §5.5: unknown frame types MUST be ignored.
    %% `parse/2` returns a `{unknown, Type, StreamId}` tag so the
    %% conn-loop can ignore them (default) BUT still enforce the
    %% §6.10 "no non-CONTINUATION between HEADERS and CONTINUATION"
    %% rule, which requires *seeing* the unknown frame.
    Unknown = <<0:24, 16#FF, 0, 0:32>>,
    ?assertMatch(
        {ok, {unknown, 16#FF, 0}, <<>>},
        roadrunner_http2_frame:parse(Unknown, ?MAX)
    ).

%% =============================================================================
%% Error code mapping (RFC 9113 §7).
%% =============================================================================

error_codes_round_trip_test() ->
    Codes = [
        no_error,
        protocol_error,
        internal_error,
        flow_control_error,
        settings_timeout,
        stream_closed,
        frame_size_error,
        refused_stream,
        cancel,
        compression_error,
        connect_error,
        enhance_your_calm,
        inadequate_security,
        http_1_1_required
    ],
    [
        ?assertEqual({ok, {rst_stream, 1, Code}, <<>>}, parse({rst_stream, 1, Code}))
     || Code <- Codes
    ].

%% =============================================================================
%% Encode helpers — flag bit cleanup, body framing.
%% =============================================================================

encode_headers_no_priority_clears_priority_flag_test() ->
    %% If a caller passes Flags with PRIORITY set but no Priority
    %% map, we MUST clear the bit to keep the wire-form consistent
    %% with the absent priority block.
    Frame = {headers, 1, 16#24, undefined, <<"hb">>},
    Encoded = iolist_to_binary(roadrunner_http2_frame:encode(Frame)),
    %% Flags byte is at offset 4.
    <<_:32, FlagsByte, _/binary>> = Encoded,
    ?assertEqual(0, FlagsByte band 16#20),
    ?assertEqual(16#04, FlagsByte band 16#04).

encode_headers_with_priority_sets_priority_flag_test() ->
    Priority = #{exclusive => false, stream_dependency => 0, weight => 1},
    Frame = {headers, 1, 16#04, Priority, <<"hb">>},
    Encoded = iolist_to_binary(roadrunner_http2_frame:encode(Frame)),
    <<_:32, FlagsByte, _/binary>> = Encoded,
    ?assertNotEqual(0, FlagsByte band 16#20).

encode_settings_with_unknown_int_code_round_trips_test() ->
    Frame = {rst_stream, 3, 16#1234},
    ?assertEqual({ok, Frame, <<>>}, parse(Frame)).

%% =============================================================================
%% helpers
%% =============================================================================

parse(Frame) ->
    Bin = iolist_to_binary(roadrunner_http2_frame:encode(Frame)),
    roadrunner_http2_frame:parse(Bin, ?MAX).
