-module(cactus_ws_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% accept_key/1 — RFC 6455 §1.3 worked example
%% =============================================================================

accept_key_rfc_example_test() ->
    %% Sec-WebSocket-Key:    dGhlIHNhbXBsZSBub25jZQ==
    %% Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
    ?assertEqual(
        ~"s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
        cactus_ws:accept_key(~"dGhlIHNhbXBsZSBub25jZQ==")
    ).

%% =============================================================================
%% handshake_response/1
%% =============================================================================

handshake_valid_test() ->
    Headers = [
        {~"host", ~"example.com"},
        {~"upgrade", ~"websocket"},
        {~"connection", ~"Upgrade"},
        {~"sec-websocket-key", ~"dGhlIHNhbXBsZSBub25jZQ=="},
        {~"sec-websocket-version", ~"13"}
    ],
    {ok, 101, RespHeaders, ~""} = cactus_ws:handshake_response(Headers),
    ?assertEqual(~"websocket", proplists:get_value(~"upgrade", RespHeaders)),
    ?assertEqual(~"upgrade", proplists:get_value(~"connection", RespHeaders)),
    ?assertEqual(
        ~"s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
        proplists:get_value(~"sec-websocket-accept", RespHeaders)
    ).

handshake_connection_with_keep_alive_test() ->
    %% Connection header may carry multiple tokens, e.g. `keep-alive, Upgrade`.
    Headers = [
        {~"upgrade", ~"websocket"},
        {~"connection", ~"keep-alive, Upgrade"},
        {~"sec-websocket-key", ~"dGhlIHNhbXBsZSBub25jZQ=="},
        {~"sec-websocket-version", ~"13"}
    ],
    ?assertMatch({ok, 101, _, _}, cactus_ws:handshake_response(Headers)).

handshake_missing_upgrade_header_test() ->
    Headers = [{~"host", ~"x"}],
    ?assertEqual(
        {error, missing_websocket_upgrade},
        cactus_ws:handshake_response(Headers)
    ).

handshake_wrong_upgrade_value_test() ->
    Headers = [
        {~"upgrade", ~"h2c"},
        {~"connection", ~"Upgrade"},
        {~"sec-websocket-key", ~"abc"}
    ],
    ?assertEqual(
        {error, missing_websocket_upgrade},
        cactus_ws:handshake_response(Headers)
    ).

handshake_missing_connection_test() ->
    Headers = [
        {~"upgrade", ~"websocket"},
        {~"sec-websocket-key", ~"abc"}
    ],
    ?assertEqual(
        {error, missing_connection_upgrade},
        cactus_ws:handshake_response(Headers)
    ).

handshake_connection_without_upgrade_test() ->
    Headers = [
        {~"upgrade", ~"websocket"},
        {~"connection", ~"keep-alive"},
        {~"sec-websocket-key", ~"abc"}
    ],
    ?assertEqual(
        {error, missing_connection_upgrade},
        cactus_ws:handshake_response(Headers)
    ).

handshake_missing_key_test() ->
    Headers = [
        {~"upgrade", ~"websocket"},
        {~"connection", ~"Upgrade"},
        {~"sec-websocket-version", ~"13"}
    ],
    ?assertEqual(
        {error, missing_websocket_key},
        cactus_ws:handshake_response(Headers)
    ).

handshake_missing_websocket_version_test() ->
    %% RFC 6455 §4.2: server requires `Sec-WebSocket-Version: 13`.
    %% Absent → reject (browsers always send it).
    Headers = [
        {~"upgrade", ~"websocket"},
        {~"connection", ~"Upgrade"},
        {~"sec-websocket-key", ~"dGhlIHNhbXBsZSBub25jZQ=="}
    ],
    ?assertEqual(
        {error, unsupported_websocket_version},
        cactus_ws:handshake_response(Headers)
    ).

handshake_wrong_websocket_version_test() ->
    %% Older drafts (hybi-08, etc.) use different handshake formats
    %% — reject anything that isn't `13`.
    Headers = [
        {~"upgrade", ~"websocket"},
        {~"connection", ~"Upgrade"},
        {~"sec-websocket-version", ~"8"},
        {~"sec-websocket-key", ~"dGhlIHNhbXBsZSBub25jZQ=="}
    ],
    ?assertEqual(
        {error, unsupported_websocket_version},
        cactus_ws:handshake_response(Headers)
    ).

%% =============================================================================
%% parse_frame/1
%% =============================================================================

parse_frame_rfc_text_example_test() ->
    %% RFC 6455 §5.7 single-frame masked text "Hello".
    Frame = <<16#81, 16#85, 16#37, 16#fa, 16#21, 16#3d, 16#7f, 16#9f, 16#4d, 16#51, 16#58>>,
    {ok, F, ~""} = cactus_ws:parse_frame(Frame),
    ?assertEqual(text, maps:get(opcode, F)),
    ?assertEqual(true, maps:get(fin, F)),
    ?assertEqual(~"Hello", maps:get(payload, F)).

parse_frame_binary_test() ->
    Payload = <<1, 2, 3, 4, 5>>,
    Mask = <<16#aa, 16#bb, 16#cc, 16#dd>>,
    Frame = <<16#82, 16#85, Mask/binary, (mask(Payload, Mask))/binary>>,
    {ok, F, ~""} = cactus_ws:parse_frame(Frame),
    ?assertEqual(binary, maps:get(opcode, F)),
    ?assertEqual(Payload, maps:get(payload, F)).

parse_frame_continuation_test() ->
    %% FIN=0, opcode=0
    Frame = <<16#00, 16#80, 1, 2, 3, 4>>,
    {ok, F, ~""} = cactus_ws:parse_frame(Frame),
    ?assertEqual(continuation, maps:get(opcode, F)),
    ?assertEqual(false, maps:get(fin, F)),
    ?assertEqual(~"", maps:get(payload, F)).

parse_frame_close_test() ->
    Frame = <<16#88, 16#80, 1, 2, 3, 4>>,
    {ok, F, ~""} = cactus_ws:parse_frame(Frame),
    ?assertEqual(close, maps:get(opcode, F)).

parse_frame_ping_test() ->
    Frame = <<16#89, 16#80, 1, 2, 3, 4>>,
    {ok, F, ~""} = cactus_ws:parse_frame(Frame),
    ?assertEqual(ping, maps:get(opcode, F)).

parse_frame_pong_test() ->
    Frame = <<16#8a, 16#80, 1, 2, 3, 4>>,
    {ok, F, ~""} = cactus_ws:parse_frame(Frame),
    ?assertEqual(pong, maps:get(opcode, F)).

parse_frame_extended_16bit_length_test() ->
    Payload = binary:copy(~"a", 200),
    Mask = <<1, 2, 3, 4>>,
    Masked = mask(Payload, Mask),
    Frame = <<16#82, 16#fe, 200:16, Mask/binary, Masked/binary>>,
    {ok, F, ~""} = cactus_ws:parse_frame(Frame),
    ?assertEqual(Payload, maps:get(payload, F)).

parse_frame_extended_64bit_length_test() ->
    %% Use 127 form for a small payload — parser doesn't enforce the
    %% RFC's "shortest form" rule, only correct decoding.
    Payload = ~"hi",
    Mask = <<1, 2, 3, 4>>,
    Masked = mask(Payload, Mask),
    Frame = <<16#82, 16#ff, 2:64, Mask/binary, Masked/binary>>,
    {ok, F, ~""} = cactus_ws:parse_frame(Frame),
    ?assertEqual(Payload, maps:get(payload, F)).

parse_frame_passes_rest_test() ->
    Frame = <<16#81, 16#85, 16#37, 16#fa, 16#21, 16#3d, 16#7f, 16#9f, 16#4d, 16#51, 16#58>>,
    Trailing = ~"NEXT_FRAME",
    {ok, _F, Rest} = cactus_ws:parse_frame(<<Frame/binary, Trailing/binary>>),
    ?assertEqual(Trailing, Rest).

parse_frame_empty_returns_more_test() ->
    ?assertMatch({more, _}, cactus_ws:parse_frame(~"")).

parse_frame_only_first_byte_returns_more_test() ->
    ?assertMatch({more, _}, cactus_ws:parse_frame(<<16#81>>)).

parse_frame_partial_payload_returns_more_test() ->
    %% Header says payload length 5, only 3 bytes of masked payload.
    Frame = <<16#81, 16#85, 1, 2, 3, 4, 99, 99, 99>>,
    ?assertMatch({more, _}, cactus_ws:parse_frame(Frame)).

parse_frame_partial_extended_length_returns_more_test() ->
    %% Len7 = 126 means a 16-bit length follows, but only 1 byte is present.
    Frame = <<16#81, 16#fe, 16#00>>,
    ?assertMatch({more, _}, cactus_ws:parse_frame(Frame)).

parse_frame_unmasked_rejected_test() ->
    %% MASK bit clear — server must reject per RFC 6455 §5.1.
    Frame = <<16#81, 16#05, "Hello">>,
    ?assertEqual({error, not_masked}, cactus_ws:parse_frame(Frame)).

parse_frame_bad_rsv_test() ->
    %% RSV1 set — no extensions negotiated.
    Frame = <<16#c1, 16#80, 1, 2, 3, 4>>,
    ?assertEqual({error, bad_rsv}, cactus_ws:parse_frame(Frame)).

parse_frame_bad_opcode_test() ->
    %% Opcode 3 is reserved per RFC 6455.
    Frame = <<16#83, 16#80, 1, 2, 3, 4>>,
    ?assertEqual({error, bad_opcode}, cactus_ws:parse_frame(Frame)).

%% =============================================================================
%% encode_frame/3 — server→client direction (unmasked)
%% =============================================================================

encode_text_fin_test() ->
    %% FIN=1, op=text → 0x81; MASK=0, len=5 → 0x05; payload Hello
    Encoded = iolist_to_binary(cactus_ws:encode_frame(text, ~"Hello", true)),
    ?assertEqual(<<16#81, 16#05, "Hello">>, Encoded).

encode_binary_test() ->
    Encoded = iolist_to_binary(cactus_ws:encode_frame(binary, <<1, 2, 3>>, true)),
    ?assertEqual(<<16#82, 16#03, 1, 2, 3>>, Encoded).

encode_continuation_no_fin_test() ->
    %% FIN=0, op=0 → 0x00
    Encoded = iolist_to_binary(cactus_ws:encode_frame(continuation, ~"part", false)),
    ?assertEqual(<<16#00, 16#04, "part">>, Encoded).

encode_close_test() ->
    Encoded = iolist_to_binary(cactus_ws:encode_frame(close, ~"", true)),
    ?assertEqual(<<16#88, 16#00>>, Encoded).

encode_ping_test() ->
    Encoded = iolist_to_binary(cactus_ws:encode_frame(ping, ~"hi", true)),
    ?assertEqual(<<16#89, 16#02, "hi">>, Encoded).

encode_pong_test() ->
    Encoded = iolist_to_binary(cactus_ws:encode_frame(pong, ~"hi", true)),
    ?assertEqual(<<16#8a, 16#02, "hi">>, Encoded).

encode_16bit_length_test() ->
    Payload = binary:copy(~"a", 200),
    Encoded = iolist_to_binary(cactus_ws:encode_frame(binary, Payload, true)),
    %% 0x82 + 0x7e (126) + 200:16 + payload
    ?assertEqual(
        <<16#82, 16#7e, 200:16, Payload/binary>>,
        Encoded
    ).

encode_64bit_length_test() ->
    Payload = binary:copy(~"x", 70000),
    Encoded = iolist_to_binary(cactus_ws:encode_frame(binary, Payload, true)),
    %% 0x82 + 0x7f (127) + 70000:64 + payload
    Expected = <<16#82, 16#7f, 70000:64, Payload/binary>>,
    ?assertEqual(Expected, Encoded).

encode_accepts_iodata_payload_test() ->
    Encoded = iolist_to_binary(cactus_ws:encode_frame(text, [~"hel", $l, ~"o"], true)),
    ?assertEqual(<<16#81, 16#05, "hello">>, Encoded).

%% =============================================================================
%% RFC 6455 §5.5 — control-frame constraints.
%% =============================================================================

parse_frame_rejects_control_with_payload_over_125_test() ->
    %% A close frame with a 200-byte payload uses the 16-bit extended
    %% length encoding. Per §5.5 control frames MUST be ≤125 bytes —
    %% reject regardless of the size encoding the client used.
    Payload = binary:copy(~"a", 200),
    MaskKey = <<1, 2, 3, 4>>,
    Masked = mask(Payload, MaskKey),
    %% byte 1: MASK=1, len7=126 → 0xFE; followed by 16-bit length 200.
    Frame = <<16#88, 16#FE, 200:16, MaskKey/binary, Masked/binary>>,
    ?assertEqual({error, control_frame_too_large}, cactus_ws:parse_frame(Frame)).

parse_frame_rejects_control_with_64bit_length_test() ->
    %% Same constraint applies regardless of which length encoding is
    %% used — len7=127 (64-bit extended) on a control frame is a
    %% protocol violation even before we see the actual length.
    Frame = <<16#88, 16#FF, 0:64, 1, 2, 3, 4>>,
    ?assertEqual({error, control_frame_too_large}, cactus_ws:parse_frame(Frame)).

parse_frame_rejects_fragmented_control_test() ->
    %% Per §5.5 control frames MUST NOT be fragmented. FIN=0 on a
    %% control opcode is a protocol violation.
    %% byte 0: FIN=0, RSV=0, opcode=close (8) → 0x08
    %% byte 1: MASK=1, len=0 → 0x80; then 4-byte mask key.
    Frame = <<16#08, 16#80, 1, 2, 3, 4>>,
    ?assertEqual({error, fragmented_control}, cactus_ws:parse_frame(Frame)).

parse_frame_rejects_fragmented_ping_test() ->
    %% byte 0: FIN=0, opcode=ping (9) → 0x09
    Frame = <<16#09, 16#80, 1, 2, 3, 4>>,
    ?assertEqual({error, fragmented_control}, cactus_ws:parse_frame(Frame)).

parse_frame_rejects_fragmented_pong_test() ->
    %% byte 0: FIN=0, opcode=pong (10) → 0x0A
    Frame = <<16#0A, 16#80, 1, 2, 3, 4>>,
    ?assertEqual({error, fragmented_control}, cactus_ws:parse_frame(Frame)).

%% Length 125 (max) on a control frame is still legal.
parse_frame_accepts_control_at_max_length_test() ->
    Payload = binary:copy(~"a", 125),
    MaskKey = <<1, 2, 3, 4>>,
    Masked = mask(Payload, MaskKey),
    Frame = <<16#88, (16#80 bor 125), MaskKey/binary, Masked/binary>>,
    ?assertMatch({ok, #{opcode := close, payload := Payload}, <<>>}, cactus_ws:parse_frame(Frame)).

%% =============================================================================
%% Handshake header value case-insensitivity (RFC 7230 §6.7).
%% =============================================================================

handshake_accepts_uppercase_websocket_test() ->
    Headers = [
        {~"upgrade", ~"WEBSOCKET"},
        {~"connection", ~"Upgrade"},
        {~"sec-websocket-key", ~"dGhlIHNhbXBsZSBub25jZQ=="},
        {~"sec-websocket-version", ~"13"}
    ],
    ?assertMatch({ok, 101, _, _}, cactus_ws:handshake_response(Headers)).

handshake_accepts_mixed_case_websocket_test() ->
    Headers = [
        {~"upgrade", ~"WebSocket"},
        {~"connection", ~"Upgrade"},
        {~"sec-websocket-key", ~"dGhlIHNhbXBsZSBub25jZQ=="},
        {~"sec-websocket-version", ~"13"}
    ],
    ?assertMatch({ok, 101, _, _}, cactus_ws:handshake_response(Headers)).

%% --- helpers ---

mask(Payload, MaskKey) ->
    list_to_binary(do_mask(binary_to_list(Payload), MaskKey, 0)).

do_mask([], _MaskKey, _I) ->
    [];
do_mask([B | Rest], MaskKey, I) ->
    [B bxor binary:at(MaskKey, I rem 4) | do_mask(Rest, MaskKey, I + 1)].
