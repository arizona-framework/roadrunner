-module(roadrunner_quic_frame_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_quic_frame).

enc(F) -> iolist_to_binary(?M:encode(F)).

%% Frames in the native tuple representation (everything but ACK).
frames() ->
    [
        padding,
        ping,
        handshake_done,
        {reset_stream, 4, 16#0A, 1000},
        {stop_sending, 8, 5},
        {crypto, 0, <<"clienthello">>},
        {crypto, 100, <<>>},
        {new_token, <<"token-bytes">>},
        %% STREAM: no offset + fin, offset + no fin, empty + fin.
        {stream, 0, 0, <<"req">>, true},
        {stream, 4, 50, <<"data">>, false},
        {stream, 8, 0, <<>>, true},
        {max_data, 1000000},
        {max_stream_data, 4, 65536},
        {max_streams, bidi, 100},
        {max_streams, uni, 3},
        {data_blocked, 999},
        {stream_data_blocked, 4, 500},
        {streams_blocked, bidi, 10},
        {streams_blocked, uni, 1},
        {new_connection_id, 1, 0, <<1, 2, 3, 4>>, binary:copy(<<7>>, 16)},
        {retire_connection_id, 2},
        {path_challenge, <<1, 2, 3, 4, 5, 6, 7, 8>>},
        {path_response, <<8, 7, 6, 5, 4, 3, 2, 1>>},
        {connection_close, transport, 16#0A, 0, <<"bad">>},
        {connection_close, application, 16#0100, undefined, <<>>}
    ].

%% ACK frames in the native (raw-wire-field) representation.
ack_frames() ->
    [
        {ack, 10, 25, 5, [], undefined},
        {ack, 100, 0, 3, [{1, 2}, {0, 4}], undefined},
        {ack, 50, 10, 0, [], {1, 2, 3}}
    ].

%% =============================================================================
%% Round-trip: encode then decode every frame.
%% =============================================================================

roundtrip_test() ->
    [?assertEqual({ok, F, <<>>}, ?M:decode(enc(F))) || F <- frames() ++ ack_frames()].

%% A STREAM frame without the LEN flag: its data runs to the end of the
%% packet. The native encoder always sets LEN, so build this one by hand.
stream_without_length_test() ->
    Bin = <<16#08, (roadrunner_quic_varint:encode(12))/binary, "tail-data">>,
    ?assertEqual({ok, {stream, 12, 0, <<"tail-data">>, false}, <<>>}, ?M:decode(Bin)).

%% =============================================================================
%% decode_all/1.
%% =============================================================================

decode_all_test() ->
    Frames = [ping, {max_data, 1000}, {crypto, 0, <<"hi">>}, padding],
    Payload = iolist_to_binary([?M:encode(F) || F <- Frames]),
    ?assertEqual({ok, Frames}, ?M:decode_all(Payload)),
    ?assertEqual({ok, []}, ?M:decode_all(<<>>)).

decode_all_propagates_error_test() ->
    %% A valid PING followed by a CRYPTO frame truncated mid-field.
    Bin = <<16#01, 16#06, 16#00>>,
    ?assertEqual({error, truncated}, ?M:decode_all(Bin)).

%% A run of consecutive PADDING bytes decodes to a single `padding` frame
%% (RFC 9000 §19.1 makes padding a no-op), whether the run trails the packet
%% or sits between other frames.
decode_all_collapses_padding_run_test() ->
    %% A trailing run longer than a machine word exercises the word-wide skip
    %% and the single-byte tail; a short middle run uses the single-byte path.
    Trailing = iolist_to_binary([?M:encode(ping), binary:copy(<<0>>, 10)]),
    ?assertEqual({ok, [ping, padding]}, ?M:decode_all(Trailing)),
    Middle = iolist_to_binary([<<0, 0, 0>>, ?M:encode(ping), <<0, 0>>]),
    ?assertEqual({ok, [padding, ping, padding]}, ?M:decode_all(Middle)).

%% An error after a leading PADDING run still propagates (covers the run
%% fast-path's error branch).
decode_all_padding_run_then_error_test() ->
    %% Two PADDING bytes, then a CRYPTO frame truncated mid-field.
    ?assertEqual({error, truncated}, ?M:decode_all(<<0, 0, 16#06, 16#00>>)).

%% =============================================================================
%% Malformed input: errors, never a crash.
%% =============================================================================

decode_empty_test() ->
    ?assertEqual({error, empty}, ?M:decode(<<>>)).

decode_unknown_frame_type_test() ->
    ?assertEqual({error, {unknown_frame_type, 16#20}}, ?M:decode(<<16#20, 1, 2>>)).

decode_truncated_varint_test() ->
    %% RESET_STREAM type byte with no stream-id varint following.
    ?assertEqual({error, truncated}, ?M:decode(<<16#04>>)),
    %% MAX_DATA whose varint is missing (covers decode_one_varint failure).
    ?assertEqual({error, truncated}, ?M:decode(<<16#10>>)).

decode_truncated_data_test() ->
    %% CRYPTO offset 0, length 5, but only 2 data bytes present.
    ?assertEqual({error, truncated}, ?M:decode(<<16#06, 0, 5, 1, 2>>)).

decode_stream_truncated_test() ->
    %% STREAM with OFF+LEN+FIN flags but no stream-id following.
    ?assertEqual({error, truncated}, ?M:decode(<<16#0F>>)).

decode_path_frames_truncated_test() ->
    %% PATH_CHALLENGE / PATH_RESPONSE need exactly 8 data bytes.
    ?assertEqual({error, truncated}, ?M:decode(<<16#1A, 1, 2, 3>>)),
    ?assertEqual({error, truncated}, ?M:decode(<<16#1B, 1, 2, 3>>)).

decode_new_cid_errors_test() ->
    %% Connection ID length 0 is invalid (RFC 9000 §19.15: 1..20).
    Zero =
        <<16#18, (roadrunner_quic_varint:encode(1))/binary,
            (roadrunner_quic_varint:encode(0))/binary, 0>>,
    ?assertEqual({error, frame_encoding_error}, ?M:decode(Zero)),
    %% Connection ID length 21 is out of range.
    TooLong =
        <<16#18, (roadrunner_quic_varint:encode(1))/binary,
            (roadrunner_quic_varint:encode(0))/binary, 21>>,
    ?assertEqual({error, frame_encoding_error}, ?M:decode(TooLong)),
    %% Valid length but the CID + reset token are truncated.
    ShortToken =
        <<16#18, (roadrunner_quic_varint:encode(1))/binary,
            (roadrunner_quic_varint:encode(0))/binary, 4, 1, 2, 3, 4, 0, 0>>,
    ?assertEqual({error, truncated}, ?M:decode(ShortToken)).

decode_connection_close_truncated_test() ->
    %% Transport CONNECTION_CLOSE whose reason is shorter than its length.
    Bin =
        <<16#1C, (roadrunner_quic_varint:encode(16#0A))/binary,
            (roadrunner_quic_varint:encode(0))/binary, (roadrunner_quic_varint:encode(5))/binary, 1,
            2>>,
    ?assertEqual({error, truncated}, ?M:decode(Bin)).

decode_ack_truncated_test() ->
    %% ACK whose ECN counts are promised (type 0x03) but missing.
    Bin =
        <<16#03, (roadrunner_quic_varint:encode(10))/binary,
            (roadrunner_quic_varint:encode(0))/binary, (roadrunner_quic_varint:encode(0))/binary,
            (roadrunner_quic_varint:encode(5))/binary>>,
    ?assertEqual({error, truncated}, ?M:decode(Bin)).
