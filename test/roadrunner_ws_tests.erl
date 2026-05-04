-module(roadrunner_ws_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% accept_key/1 — RFC 6455 §1.3 worked example
%% =============================================================================

accept_key_rfc_example_test() ->
    %% Sec-WebSocket-Key:    dGhlIHNhbXBsZSBub25jZQ==
    %% Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
    ?assertEqual(
        ~"s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
        roadrunner_ws:accept_key(~"dGhlIHNhbXBsZSBub25jZQ==")
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
    {ok, 101, RespHeaders, ~"", none} = roadrunner_ws:handshake_response(Headers),
    ?assertEqual(~"websocket", proplists:get_value(~"upgrade", RespHeaders)),
    ?assertEqual(~"upgrade", proplists:get_value(~"connection", RespHeaders)),
    ?assertEqual(
        ~"s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
        proplists:get_value(~"sec-websocket-accept", RespHeaders)
    ),
    %% No `Sec-WebSocket-Extensions` request header → no extension
    %% header in the response either.
    ?assertEqual(undefined, proplists:get_value(~"sec-websocket-extensions", RespHeaders)).

handshake_connection_with_keep_alive_test() ->
    %% Connection header may carry multiple tokens, e.g. `keep-alive, Upgrade`.
    Headers = [
        {~"upgrade", ~"websocket"},
        {~"connection", ~"keep-alive, Upgrade"},
        {~"sec-websocket-key", ~"dGhlIHNhbXBsZSBub25jZQ=="},
        {~"sec-websocket-version", ~"13"}
    ],
    ?assertMatch({ok, 101, _, _, _}, roadrunner_ws:handshake_response(Headers)).

handshake_missing_upgrade_header_test() ->
    Headers = [{~"host", ~"x"}],
    ?assertEqual(
        {error, missing_websocket_upgrade},
        roadrunner_ws:handshake_response(Headers)
    ).

handshake_wrong_upgrade_value_test() ->
    Headers = [
        {~"upgrade", ~"h2c"},
        {~"connection", ~"Upgrade"},
        {~"sec-websocket-key", ~"abc"}
    ],
    ?assertEqual(
        {error, missing_websocket_upgrade},
        roadrunner_ws:handshake_response(Headers)
    ).

handshake_missing_connection_test() ->
    Headers = [
        {~"upgrade", ~"websocket"},
        {~"sec-websocket-key", ~"abc"}
    ],
    ?assertEqual(
        {error, missing_connection_upgrade},
        roadrunner_ws:handshake_response(Headers)
    ).

handshake_connection_without_upgrade_test() ->
    Headers = [
        {~"upgrade", ~"websocket"},
        {~"connection", ~"keep-alive"},
        {~"sec-websocket-key", ~"abc"}
    ],
    ?assertEqual(
        {error, missing_connection_upgrade},
        roadrunner_ws:handshake_response(Headers)
    ).

handshake_missing_key_test() ->
    Headers = [
        {~"upgrade", ~"websocket"},
        {~"connection", ~"Upgrade"},
        {~"sec-websocket-version", ~"13"}
    ],
    ?assertEqual(
        {error, missing_websocket_key},
        roadrunner_ws:handshake_response(Headers)
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
        roadrunner_ws:handshake_response(Headers)
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
        roadrunner_ws:handshake_response(Headers)
    ).

%% =============================================================================
%% parse_extensions/1 — Sec-WebSocket-Extensions header (RFC 6455 §9.1).
%% =============================================================================

parse_extensions_undefined_returns_empty_test() ->
    ?assertEqual([], roadrunner_ws:parse_extensions(undefined)).

parse_extensions_empty_value_returns_empty_test() ->
    ?assertEqual([], roadrunner_ws:parse_extensions(<<>>)).

parse_extensions_single_offer_no_params_test() ->
    ?assertEqual(
        [{~"permessage-deflate", []}],
        roadrunner_ws:parse_extensions(~"permessage-deflate")
    ).

parse_extensions_single_offer_with_bare_param_test() ->
    %% Bare flag parameter (no `=`) — value is the atom `true`.
    ?assertEqual(
        [{~"permessage-deflate", [{~"client_no_context_takeover", true}]}],
        roadrunner_ws:parse_extensions(~"permessage-deflate; client_no_context_takeover")
    ).

parse_extensions_single_offer_with_keyvalue_param_test() ->
    ?assertEqual(
        [{~"permessage-deflate", [{~"server_max_window_bits", ~"10"}]}],
        roadrunner_ws:parse_extensions(~"permessage-deflate; server_max_window_bits=10")
    ).

parse_extensions_quoted_param_value_unquoted_test() ->
    %% RFC 6455 §9.1 allows quoted-string parameter values; the parser
    %% strips the surrounding quotes.
    ?assertEqual(
        [{~"permessage-deflate", [{~"server_max_window_bits", ~"10"}]}],
        roadrunner_ws:parse_extensions(~"permessage-deflate; server_max_window_bits=\"10\"")
    ).

parse_extensions_multiple_offers_preserves_order_test() ->
    ?assertEqual(
        [
            {~"permessage-deflate", [{~"client_max_window_bits", true}]},
            {~"x-custom", []}
        ],
        roadrunner_ws:parse_extensions(
            ~"permessage-deflate; client_max_window_bits, x-custom"
        )
    ).

parse_extensions_lowercases_names_and_keys_test() ->
    ?assertEqual(
        [{~"permessage-deflate", [{~"client_max_window_bits", ~"15"}]}],
        roadrunner_ws:parse_extensions(~"PerMessage-Deflate; Client_Max_Window_Bits=15")
    ).

parse_extensions_multiple_params_preserves_order_test() ->
    ?assertEqual(
        [
            {~"permessage-deflate", [
                {~"client_no_context_takeover", true},
                {~"server_max_window_bits", ~"10"}
            ]}
        ],
        roadrunner_ws:parse_extensions(
            ~"permessage-deflate; client_no_context_takeover; server_max_window_bits=10"
        )
    ).

parse_extensions_skips_empty_offers_from_double_commas_test() ->
    ?assertEqual(
        [{~"permessage-deflate", []}, {~"x-foo", []}],
        roadrunner_ws:parse_extensions(~"permessage-deflate, , x-foo")
    ).

parse_extensions_unterminated_quote_yields_rest_as_value_test() ->
    %% Malformed: opening `"` without a closing quote. The parser
    %% lenient-handles by returning everything after the opening
    %% quote as the value (better than crashing on a buggy client).
    ?assertEqual(
        [{~"permessage-deflate", [{~"server_max_window_bits", ~"10"}]}],
        roadrunner_ws:parse_extensions(~"permessage-deflate; server_max_window_bits=\"10")
    ).

%% =============================================================================
%% negotiate_extensions/1 — pick acceptable offer (RFC 7692 permessage-deflate).
%% =============================================================================

negotiate_extensions_empty_offers_returns_none_test() ->
    ?assertEqual(none, roadrunner_ws:negotiate_extensions([])).

negotiate_extensions_unsupported_extension_returns_none_test() ->
    ?assertEqual(
        none,
        roadrunner_ws:negotiate_extensions([{~"x-some-extension", []}])
    ).

negotiate_extensions_bare_permessage_deflate_accepts_with_defaults_test() ->
    %% Offer with no parameters → defaults: window bits 15, context
    %% takeover ON. Response header echoes only the extension name
    %% (no params since all values match defaults).
    ?assertEqual(
        {permessage_deflate,
            #{
                server_max_window_bits => 15,
                client_max_window_bits => 15,
                server_no_context_takeover => false,
                client_no_context_takeover => false
            },
            ~"permessage-deflate"},
        roadrunner_ws:negotiate_extensions([{~"permessage-deflate", []}])
    ).

negotiate_extensions_with_no_context_takeover_echoes_in_response_test() ->
    {permessage_deflate, Params, ResponseValue} =
        roadrunner_ws:negotiate_extensions([
            {~"permessage-deflate", [
                {~"client_no_context_takeover", true},
                {~"server_no_context_takeover", true}
            ]}
        ]),
    ?assertEqual(true, maps:get(client_no_context_takeover, Params)),
    ?assertEqual(true, maps:get(server_no_context_takeover, Params)),
    %% Response echoes the agreed flags (order: server first per
    %% format_pmd_response).
    ?assertEqual(
        ~"permessage-deflate; server_no_context_takeover; client_no_context_takeover",
        ResponseValue
    ).

negotiate_extensions_with_explicit_window_bits_test() ->
    {permessage_deflate, Params, ResponseValue} =
        roadrunner_ws:negotiate_extensions([
            {~"permessage-deflate", [
                {~"server_max_window_bits", ~"10"},
                {~"client_max_window_bits", ~"12"}
            ]}
        ]),
    ?assertEqual(10, maps:get(server_max_window_bits, Params)),
    ?assertEqual(12, maps:get(client_max_window_bits, Params)),
    ?assertEqual(
        ~"permessage-deflate; server_max_window_bits=10; client_max_window_bits=12",
        ResponseValue
    ).

negotiate_extensions_bare_client_max_window_bits_uses_default_test() ->
    %% `client_max_window_bits` (no value) means client accepts any
    %% choice — server picks the default (15).
    {permessage_deflate, Params, _ResponseValue} =
        roadrunner_ws:negotiate_extensions([
            {~"permessage-deflate", [{~"client_max_window_bits", true}]}
        ]),
    ?assertEqual(15, maps:get(client_max_window_bits, Params)).

negotiate_extensions_invalid_client_max_window_bits_value_skips_offer_test() ->
    %% `client_max_window_bits` with an unparseable value is invalid;
    %% the offer must be skipped (consistent with server_max_window_bits).
    ?assertEqual(
        none,
        roadrunner_ws:negotiate_extensions([
            {~"permessage-deflate", [{~"client_max_window_bits", ~"42"}]}
        ])
    ).

negotiate_extensions_bare_server_max_window_bits_skips_offer_test() ->
    %% `server_max_window_bits` (no value) is invalid per RFC 7692
    %% §7.1.2.2 — the parameter MUST carry a value when present in
    %% an offer. Skip the offer rather than guess.
    ?assertEqual(
        none,
        roadrunner_ws:negotiate_extensions([
            {~"permessage-deflate", [{~"server_max_window_bits", true}]}
        ])
    ).

negotiate_extensions_window_bits_out_of_range_skips_offer_test() ->
    %% RFC 7692 allows 8..15 only; 7 is invalid → skip the offer
    %% (return none rather than fall back to defaults — matches
    %% RFC 7692's intent of strict negotiation).
    ?assertEqual(
        none,
        roadrunner_ws:negotiate_extensions([
            {~"permessage-deflate", [{~"server_max_window_bits", ~"7"}]}
        ])
    ),
    ?assertEqual(
        none,
        roadrunner_ws:negotiate_extensions([
            {~"permessage-deflate", [{~"server_max_window_bits", ~"16"}]}
        ])
    ).

negotiate_extensions_unknown_pmd_param_is_ignored_test() ->
    %% Future PMD parameters we don't recognize should be skipped, not
    %% rejected — RFC 7692 §7 allows future param additions.
    ?assertMatch(
        {permessage_deflate, _, _},
        roadrunner_ws:negotiate_extensions([
            {~"permessage-deflate", [{~"x-future-param", ~"value"}]}
        ])
    ).

negotiate_extensions_picks_first_acceptable_in_order_test() ->
    %% Per RFC 6455 §9.1, server processes offers in order and picks
    %% the first acceptable one. With unsupported first, supported
    %% second → pick the second.
    ?assertMatch(
        {permessage_deflate, _, _},
        roadrunner_ws:negotiate_extensions([
            {~"x-unknown", []},
            {~"permessage-deflate", []}
        ])
    ).

%% Integration: full handshake_response/1 with extension negotiation.

handshake_with_permessage_deflate_offer_includes_response_header_test() ->
    Headers = [
        {~"upgrade", ~"websocket"},
        {~"connection", ~"Upgrade"},
        {~"sec-websocket-key", ~"dGhlIHNhbXBsZSBub25jZQ=="},
        {~"sec-websocket-version", ~"13"},
        {~"sec-websocket-extensions", ~"permessage-deflate"}
    ],
    {ok, 101, RespHeaders, ~"", Negotiated} = roadrunner_ws:handshake_response(Headers),
    ?assertMatch({permessage_deflate, _, _}, Negotiated),
    ?assertEqual(
        ~"permessage-deflate",
        proplists:get_value(~"sec-websocket-extensions", RespHeaders)
    ).

handshake_without_extensions_returns_none_negotiated_test() ->
    Headers = [
        {~"upgrade", ~"websocket"},
        {~"connection", ~"Upgrade"},
        {~"sec-websocket-key", ~"dGhlIHNhbXBsZSBub25jZQ=="},
        {~"sec-websocket-version", ~"13"}
    ],
    {ok, 101, _RespHeaders, ~"", Negotiated} = roadrunner_ws:handshake_response(Headers),
    ?assertEqual(none, Negotiated).

%% =============================================================================
%% parse_frame/1
%% =============================================================================

parse_frame_rfc_text_example_test() ->
    %% RFC 6455 §5.7 single-frame masked text "Hello".
    Frame = <<16#81, 16#85, 16#37, 16#fa, 16#21, 16#3d, 16#7f, 16#9f, 16#4d, 16#51, 16#58>>,
    {ok, F, ~""} = roadrunner_ws:parse_frame(Frame),
    ?assertEqual(text, maps:get(opcode, F)),
    ?assertEqual(true, maps:get(fin, F)),
    ?assertEqual(~"Hello", maps:get(payload, F)).

parse_frame_binary_test() ->
    Payload = <<1, 2, 3, 4, 5>>,
    Mask = <<16#aa, 16#bb, 16#cc, 16#dd>>,
    Frame = <<16#82, 16#85, Mask/binary, (mask(Payload, Mask))/binary>>,
    {ok, F, ~""} = roadrunner_ws:parse_frame(Frame),
    ?assertEqual(binary, maps:get(opcode, F)),
    ?assertEqual(Payload, maps:get(payload, F)).

parse_frame_continuation_test() ->
    %% FIN=0, opcode=0
    Frame = <<16#00, 16#80, 1, 2, 3, 4>>,
    {ok, F, ~""} = roadrunner_ws:parse_frame(Frame),
    ?assertEqual(continuation, maps:get(opcode, F)),
    ?assertEqual(false, maps:get(fin, F)),
    ?assertEqual(~"", maps:get(payload, F)).

parse_frame_close_test() ->
    Frame = <<16#88, 16#80, 1, 2, 3, 4>>,
    {ok, F, ~""} = roadrunner_ws:parse_frame(Frame),
    ?assertEqual(close, maps:get(opcode, F)).

parse_frame_ping_test() ->
    Frame = <<16#89, 16#80, 1, 2, 3, 4>>,
    {ok, F, ~""} = roadrunner_ws:parse_frame(Frame),
    ?assertEqual(ping, maps:get(opcode, F)).

parse_frame_pong_test() ->
    Frame = <<16#8a, 16#80, 1, 2, 3, 4>>,
    {ok, F, ~""} = roadrunner_ws:parse_frame(Frame),
    ?assertEqual(pong, maps:get(opcode, F)).

parse_frame_extended_16bit_length_test() ->
    Payload = binary:copy(~"a", 200),
    Mask = <<1, 2, 3, 4>>,
    Masked = mask(Payload, Mask),
    Frame = <<16#82, 16#fe, 200:16, Mask/binary, Masked/binary>>,
    {ok, F, ~""} = roadrunner_ws:parse_frame(Frame),
    ?assertEqual(Payload, maps:get(payload, F)).

parse_frame_extended_64bit_length_test() ->
    %% Use 127 form for a small payload — parser doesn't enforce the
    %% RFC's "shortest form" rule, only correct decoding.
    Payload = ~"hi",
    Mask = <<1, 2, 3, 4>>,
    Masked = mask(Payload, Mask),
    Frame = <<16#82, 16#ff, 2:64, Mask/binary, Masked/binary>>,
    {ok, F, ~""} = roadrunner_ws:parse_frame(Frame),
    ?assertEqual(Payload, maps:get(payload, F)).

parse_frame_passes_rest_test() ->
    Frame = <<16#81, 16#85, 16#37, 16#fa, 16#21, 16#3d, 16#7f, 16#9f, 16#4d, 16#51, 16#58>>,
    Trailing = ~"NEXT_FRAME",
    {ok, _F, Rest} = roadrunner_ws:parse_frame(<<Frame/binary, Trailing/binary>>),
    ?assertEqual(Trailing, Rest).

parse_frame_empty_returns_more_test() ->
    ?assertMatch({more, _}, roadrunner_ws:parse_frame(~"")).

parse_frame_only_first_byte_returns_more_test() ->
    ?assertMatch({more, _}, roadrunner_ws:parse_frame(<<16#81>>)).

parse_frame_partial_payload_returns_more_test() ->
    %% Header says payload length 5, only 3 bytes of masked payload.
    Frame = <<16#81, 16#85, 1, 2, 3, 4, 99, 99, 99>>,
    ?assertMatch({more, _}, roadrunner_ws:parse_frame(Frame)).

parse_frame_partial_extended_length_returns_more_test() ->
    %% Len7 = 126 means a 16-bit length follows, but only 1 byte is present.
    Frame = <<16#81, 16#fe, 16#00>>,
    ?assertMatch({more, _}, roadrunner_ws:parse_frame(Frame)).

parse_frame_unmasked_rejected_test() ->
    %% MASK bit clear — server must reject per RFC 6455 §5.1.
    Frame = <<16#81, 16#05, "Hello">>,
    ?assertEqual({error, not_masked}, roadrunner_ws:parse_frame(Frame)).

parse_frame_bad_rsv_test() ->
    %% RSV1 set — no extensions negotiated → reject.
    Frame = <<16#c1, 16#80, 1, 2, 3, 4>>,
    ?assertEqual({error, bad_rsv}, roadrunner_ws:parse_frame(Frame)).

parse_frame_rsv1_allowed_when_extension_active_test() ->
    %% RSV1=1 + allow_rsv1 => true (e.g. permessage-deflate negotiated)
    %% — accept and surface rsv1=true in the frame map.
    Frame = <<16#c1, 16#85, 16#37, 16#fa, 16#21, 16#3d, 16#7f, 16#9f, 16#4d, 16#51, 16#58>>,
    {ok, F, ~""} = roadrunner_ws:parse_frame(Frame, #{allow_rsv1 => true}),
    ?assertMatch(#{rsv1 := true, opcode := text, payload := ~"Hello"}, F).

parse_frame_rsv1_default_rejected_test() ->
    %% allow_rsv1 default is false — same shape as parse_frame/1.
    Frame = <<16#c1, 16#80, 1, 2, 3, 4>>,
    ?assertEqual({error, bad_rsv}, roadrunner_ws:parse_frame(Frame, #{})),
    ?assertEqual({error, bad_rsv}, roadrunner_ws:parse_frame(Frame, #{allow_rsv1 => false})).

parse_frame_rsv2_always_rejected_test() ->
    %% RSV2 set — no IETF extension uses it; reject even with
    %% allow_rsv1 => true.
    Frame = <<16#a1, 16#80, 1, 2, 3, 4>>,
    ?assertEqual({error, bad_rsv}, roadrunner_ws:parse_frame(Frame, #{allow_rsv1 => true})).

parse_frame_rsv3_always_rejected_test() ->
    Frame = <<16#91, 16#80, 1, 2, 3, 4>>,
    ?assertEqual({error, bad_rsv}, roadrunner_ws:parse_frame(Frame, #{allow_rsv1 => true})).

parse_frame_surfaces_rsv1_false_for_normal_frame_test() ->
    %% Even on the back-compat parse_frame/1 path, the new frame map
    %% includes `rsv1 => false` so consumers can rely on the field.
    Frame = <<16#81, 16#85, 16#37, 16#fa, 16#21, 16#3d, 16#7f, 16#9f, 16#4d, 16#51, 16#58>>,
    {ok, F, ~""} = roadrunner_ws:parse_frame(Frame),
    ?assertMatch(#{rsv1 := false}, F).

parse_frame_bad_opcode_test() ->
    %% Opcode 3 is reserved per RFC 6455.
    Frame = <<16#83, 16#80, 1, 2, 3, 4>>,
    ?assertEqual({error, bad_opcode}, roadrunner_ws:parse_frame(Frame)).

%% =============================================================================
%% encode_frame/3 — server→client direction (unmasked)
%% =============================================================================

encode_text_fin_test() ->
    %% FIN=1, op=text → 0x81; MASK=0, len=5 → 0x05; payload Hello
    Encoded = iolist_to_binary(roadrunner_ws:encode_frame(text, ~"Hello", true)),
    ?assertEqual(<<16#81, 16#05, "Hello">>, Encoded).

encode_binary_test() ->
    Encoded = iolist_to_binary(roadrunner_ws:encode_frame(binary, <<1, 2, 3>>, true)),
    ?assertEqual(<<16#82, 16#03, 1, 2, 3>>, Encoded).

encode_continuation_no_fin_test() ->
    %% FIN=0, op=0 → 0x00
    Encoded = iolist_to_binary(roadrunner_ws:encode_frame(continuation, ~"part", false)),
    ?assertEqual(<<16#00, 16#04, "part">>, Encoded).

encode_close_test() ->
    Encoded = iolist_to_binary(roadrunner_ws:encode_frame(close, ~"", true)),
    ?assertEqual(<<16#88, 16#00>>, Encoded).

encode_ping_test() ->
    Encoded = iolist_to_binary(roadrunner_ws:encode_frame(ping, ~"hi", true)),
    ?assertEqual(<<16#89, 16#02, "hi">>, Encoded).

encode_pong_test() ->
    Encoded = iolist_to_binary(roadrunner_ws:encode_frame(pong, ~"hi", true)),
    ?assertEqual(<<16#8a, 16#02, "hi">>, Encoded).

encode_16bit_length_test() ->
    Payload = binary:copy(~"a", 200),
    Encoded = iolist_to_binary(roadrunner_ws:encode_frame(binary, Payload, true)),
    %% 0x82 + 0x7e (126) + 200:16 + payload
    ?assertEqual(
        <<16#82, 16#7e, 200:16, Payload/binary>>,
        Encoded
    ).

encode_64bit_length_test() ->
    Payload = binary:copy(~"x", 70000),
    Encoded = iolist_to_binary(roadrunner_ws:encode_frame(binary, Payload, true)),
    %% 0x82 + 0x7f (127) + 70000:64 + payload
    Expected = <<16#82, 16#7f, 70000:64, Payload/binary>>,
    ?assertEqual(Expected, Encoded).

encode_accepts_iodata_payload_test() ->
    Encoded = iolist_to_binary(roadrunner_ws:encode_frame(text, [~"hel", $l, ~"o"], true)),
    ?assertEqual(<<16#81, 16#05, "hello">>, Encoded).

encode_frame_4_with_rsv1_sets_the_bit_test() ->
    %% encode_frame/4 with #{rsv1 => true} sets RSV1=1 in the first byte
    %% — used by the permessage-deflate sender path on the first frame
    %% of a compressed message.
    Encoded = iolist_to_binary(
        roadrunner_ws:encode_frame(text, ~"Hello", true, #{rsv1 => true})
    ),
    %% First byte: FIN(1) RSV1(1) RSV2(0) RSV3(0) opcode(0001) = 0xC1.
    ?assertEqual(<<16#c1, 16#05, "Hello">>, Encoded).

encode_frame_4_default_omits_rsv1_test() ->
    %% encode_frame/4 with empty opts behaves identically to
    %% encode_frame/3.
    A = iolist_to_binary(roadrunner_ws:encode_frame(text, ~"Hello", true, #{})),
    B = iolist_to_binary(roadrunner_ws:encode_frame(text, ~"Hello", true)),
    ?assertEqual(A, B),
    ?assertEqual(<<16#81, 16#05, "Hello">>, A).

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
    ?assertEqual({error, control_frame_too_large}, roadrunner_ws:parse_frame(Frame)).

parse_frame_rejects_control_with_64bit_length_test() ->
    %% Same constraint applies regardless of which length encoding is
    %% used — len7=127 (64-bit extended) on a control frame is a
    %% protocol violation even before we see the actual length.
    Frame = <<16#88, 16#FF, 0:64, 1, 2, 3, 4>>,
    ?assertEqual({error, control_frame_too_large}, roadrunner_ws:parse_frame(Frame)).

parse_frame_rejects_fragmented_control_test() ->
    %% Per §5.5 control frames MUST NOT be fragmented. FIN=0 on a
    %% control opcode is a protocol violation.
    %% byte 0: FIN=0, RSV=0, opcode=close (8) → 0x08
    %% byte 1: MASK=1, len=0 → 0x80; then 4-byte mask key.
    Frame = <<16#08, 16#80, 1, 2, 3, 4>>,
    ?assertEqual({error, fragmented_control}, roadrunner_ws:parse_frame(Frame)).

parse_frame_rejects_fragmented_ping_test() ->
    %% byte 0: FIN=0, opcode=ping (9) → 0x09
    Frame = <<16#09, 16#80, 1, 2, 3, 4>>,
    ?assertEqual({error, fragmented_control}, roadrunner_ws:parse_frame(Frame)).

parse_frame_rejects_fragmented_pong_test() ->
    %% byte 0: FIN=0, opcode=pong (10) → 0x0A
    Frame = <<16#0A, 16#80, 1, 2, 3, 4>>,
    ?assertEqual({error, fragmented_control}, roadrunner_ws:parse_frame(Frame)).

%% Length 125 (max) on a control frame is still legal.
parse_frame_accepts_control_at_max_length_test() ->
    Payload = binary:copy(~"a", 125),
    MaskKey = <<1, 2, 3, 4>>,
    Masked = mask(Payload, MaskKey),
    Frame = <<16#88, (16#80 bor 125), MaskKey/binary, Masked/binary>>,
    ?assertMatch(
        {ok, #{opcode := close, payload := Payload}, <<>>}, roadrunner_ws:parse_frame(Frame)
    ).

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
    ?assertMatch({ok, 101, _, _, _}, roadrunner_ws:handshake_response(Headers)).

handshake_accepts_mixed_case_websocket_test() ->
    Headers = [
        {~"upgrade", ~"WebSocket"},
        {~"connection", ~"Upgrade"},
        {~"sec-websocket-key", ~"dGhlIHNhbXBsZSBub25jZQ=="},
        {~"sec-websocket-version", ~"13"}
    ],
    ?assertMatch({ok, 101, _, _, _}, roadrunner_ws:handshake_response(Headers)).

%% --- helpers ---

mask(Payload, MaskKey) ->
    list_to_binary(do_mask(binary_to_list(Payload), MaskKey, 0)).

do_mask([], _MaskKey, _I) ->
    [];
do_mask([B | Rest], MaskKey, I) ->
    [B bxor binary:at(MaskKey, I rem 4) | do_mask(Rest, MaskKey, I + 1)].
