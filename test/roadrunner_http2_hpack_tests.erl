-module(roadrunner_http2_hpack_tests).
-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% RFC 7541 Appendix C.2 — single-representation worked examples.
%% =============================================================================

c21_literal_indexed_with_incremental_indexing_test() ->
    %% C.2.1: New name, "custom-key: custom-header".
    %% Encoded: 400a 6375 7374 6f6d 2d6b 6579 0d63 7573 746f 6d2d 6865 6164 6572
    Bin = <<16#40, 16#0A, "custom-key", 16#0D, "custom-header">>,
    Ctx = roadrunner_http2_hpack:new_decoder(4096),
    {ok, Headers, NewCtx} = roadrunner_http2_hpack:decode(Bin, Ctx),
    ?assertEqual([{~"custom-key", ~"custom-header"}], Headers),
    %% Dynamic table now has the entry; size = 10 + 13 + 32 = 55.
    ?assertEqual([{~"custom-key", ~"custom-header"}], dyn(NewCtx)),
    ?assertEqual(55, ctx_size(NewCtx)).

c22_literal_without_indexing_test() ->
    %% C.2.2: ":path: /sample/path"
    %% Encoded: 040c 2f73 616d 706c 652f 7061 7468
    Bin = <<16#04, 16#0C, "/sample/path">>,
    Ctx = roadrunner_http2_hpack:new_decoder(4096),
    {ok, Headers, NewCtx} = roadrunner_http2_hpack:decode(Bin, Ctx),
    ?assertEqual([{~":path", ~"/sample/path"}], Headers),
    %% Literal w/o indexing — dynamic table NOT updated.
    ?assertEqual([], dyn(NewCtx)).

c23_literal_never_indexed_test() ->
    %% C.2.3: "password: secret"
    %% Encoded: 1008 7061 7373 776f 7264 0673 6563 7265 74
    Bin = <<16#10, 16#08, "password", 16#06, "secret">>,
    Ctx = roadrunner_http2_hpack:new_decoder(4096),
    {ok, Headers, NewCtx} = roadrunner_http2_hpack:decode(Bin, Ctx),
    ?assertEqual([{~"password", ~"secret"}], Headers),
    %% Never-indexed — also doesn't touch the dynamic table.
    ?assertEqual([], dyn(NewCtx)).

c24_indexed_header_field_test() ->
    %% C.2.4: indexed entry from static table.
    %% Index 2 = ":method: GET". Encoded as 0x82.
    Bin = <<16#82>>,
    Ctx = roadrunner_http2_hpack:new_decoder(4096),
    {ok, Headers, _} = roadrunner_http2_hpack:decode(Bin, Ctx),
    ?assertEqual([{~":method", ~"GET"}], Headers).

%% =============================================================================
%% RFC 7541 Appendix C.3 — multi-request sequence with dynamic table.
%% =============================================================================

c31_first_request_test() ->
    Bin = <<16#82, 16#86, 16#84, 16#41, 16#0F, "www.example.com">>,
    Ctx0 = roadrunner_http2_hpack:new_decoder(4096),
    {ok, H1, Ctx1} = roadrunner_http2_hpack:decode(Bin, Ctx0),
    ?assertEqual(
        [
            {~":method", ~"GET"},
            {~":scheme", ~"http"},
            {~":path", ~"/"},
            {~":authority", ~"www.example.com"}
        ],
        H1
    ),
    %% Dynamic table contains the new ":authority" entry.
    ?assertEqual([{~":authority", ~"www.example.com"}], dyn(Ctx1)).

c32_second_request_test() ->
    %% C.3.2 input depends on C.3.1's dynamic-table state. Replay
    %% them in sequence.
    Bin1 = <<16#82, 16#86, 16#84, 16#41, 16#0F, "www.example.com">>,
    Bin2 = <<16#82, 16#86, 16#84, 16#BE, 16#58, 16#08, "no-cache">>,
    Ctx0 = roadrunner_http2_hpack:new_decoder(4096),
    {ok, _, Ctx1} = roadrunner_http2_hpack:decode(Bin1, Ctx0),
    {ok, H2, Ctx2} = roadrunner_http2_hpack:decode(Bin2, Ctx1),
    ?assertEqual(
        [
            {~":method", ~"GET"},
            {~":scheme", ~"http"},
            {~":path", ~"/"},
            {~":authority", ~"www.example.com"},
            {~"cache-control", ~"no-cache"}
        ],
        H2
    ),
    %% After C.3.2, dynamic table holds:
    %% [1] cache-control: no-cache  (newest)
    %% [2] :authority: www.example.com
    ?assertEqual(
        [{~"cache-control", ~"no-cache"}, {~":authority", ~"www.example.com"}],
        dyn(Ctx2)
    ).

%% =============================================================================
%% Encoder — round-trip an arbitrary header list.
%% =============================================================================

encode_then_decode_round_trip_test() ->
    Headers = [
        {~":method", ~"GET"},
        {~":scheme", ~"https"},
        {~":path", ~"/api/v1/items"},
        {~":authority", ~"api.example.com"},
        {~"accept", ~"application/json"},
        {~"x-trace-id", ~"abc-123"}
    ],
    Enc0 = roadrunner_http2_hpack:new_encoder(4096),
    Dec0 = roadrunner_http2_hpack:new_decoder(4096),
    {Block, _Enc1} = roadrunner_http2_hpack:encode(Headers, Enc0),
    BlockBin = iolist_to_binary(Block),
    {ok, Decoded, _Dec1} = roadrunner_http2_hpack:decode(BlockBin, Dec0),
    ?assertEqual(Headers, Decoded).

encode_uses_indexed_for_known_static_pairs_test() ->
    %% ":method: GET" is static index 2 — encoder must emit a
    %% single 0x82 byte.
    Enc = roadrunner_http2_hpack:new_encoder(4096),
    {Block, _} = roadrunner_http2_hpack:encode([{~":method", ~"GET"}], Enc),
    ?assertEqual(<<16#82>>, iolist_to_binary(Block)).

%% =============================================================================
%% Static table coverage — exercise every entry of RFC 7541 Appendix A.
%% =============================================================================

%% Each entry of the static table (61 entries) is exercised via a
%% round-trip: encoder picks the indexed-name or indexed-pair shape,
%% decoder reads the index back to the same `{Name, Value}`. This
%% covers every clause of `static_full_match/2`, `static_name_match/1`
%% and `lookup_static/1` — they're function-clause-dispatched per
%% RFC 7541 Appendix A and the BEAM compiles them to a JIT'd jump
%% table; without this test most clauses sit uncovered.
static_table_round_trip_for_every_index_test_() ->
    [
        ?_assertEqual(
            {Name, Value},
            decode_via_index(Name, Value)
        )
     || {Name, Value} <- [
            {~":authority", ~""},
            {~":method", ~"GET"},
            {~":method", ~"POST"},
            {~":path", ~"/"},
            {~":path", ~"/index.html"},
            {~":scheme", ~"http"},
            {~":scheme", ~"https"},
            {~":status", ~"200"},
            {~":status", ~"204"},
            {~":status", ~"206"},
            {~":status", ~"304"},
            {~":status", ~"400"},
            {~":status", ~"404"},
            {~":status", ~"500"},
            {~"accept-charset", ~""},
            {~"accept-encoding", ~"gzip, deflate"},
            {~"accept-language", ~""},
            {~"accept-ranges", ~""},
            {~"accept", ~""},
            {~"access-control-allow-origin", ~""},
            {~"age", ~""},
            {~"allow", ~""},
            {~"authorization", ~""},
            {~"cache-control", ~""},
            {~"content-disposition", ~""},
            {~"content-encoding", ~""},
            {~"content-language", ~""},
            {~"content-length", ~""},
            {~"content-location", ~""},
            {~"content-range", ~""},
            {~"content-type", ~""},
            {~"cookie", ~""},
            {~"date", ~""},
            {~"etag", ~""},
            {~"expect", ~""},
            {~"expires", ~""},
            {~"from", ~""},
            {~"host", ~""},
            {~"if-match", ~""},
            {~"if-modified-since", ~""},
            {~"if-none-match", ~""},
            {~"if-range", ~""},
            {~"if-unmodified-since", ~""},
            {~"last-modified", ~""},
            {~"link", ~""},
            {~"location", ~""},
            {~"max-forwards", ~""},
            {~"proxy-authenticate", ~""},
            {~"proxy-authorization", ~""},
            {~"range", ~""},
            {~"referer", ~""},
            {~"refresh", ~""},
            {~"retry-after", ~""},
            {~"server", ~""},
            {~"set-cookie", ~""},
            {~"strict-transport-security", ~""},
            {~"transfer-encoding", ~""},
            {~"user-agent", ~""},
            {~"vary", ~""},
            {~"via", ~""},
            {~"www-authenticate", ~""}
        ]
    ].

%% Encode a header with the encoder (which picks the smallest static
%% representation) and decode the resulting bytes, asserting the
%% round-trip produced the same pair.
decode_via_index(Name, Value) ->
    Enc = roadrunner_http2_hpack:new_encoder(4096),
    {Block, _} = roadrunner_http2_hpack:encode([{Name, Value}], Enc),
    BlockBin = iolist_to_binary(Block),
    Dec = roadrunner_http2_hpack:new_decoder(4096),
    {ok, [Pair], _Dec1} = roadrunner_http2_hpack:decode(BlockBin, Dec),
    Pair.

%% Decode an Indexed Header Field (one byte: 1xxxxxxx) for every
%% static-table index 1..61. Exercises every clause of
%% `lookup_static/1` directly via the decoder's indexed-header
%% representation, which `encode/decode` round-trip in
%% `static_table_round_trip_for_every_index_test_/0` only does for
%% full-pair static entries (the empty-value rows go through
%% indexed-name + literal value on encode and don't reach
%% `lookup_static`).
indexed_header_decode_for_every_static_index_test_() ->
    StaticEntries =
        [
            {1, ~":authority", ~""},
            {2, ~":method", ~"GET"},
            {3, ~":method", ~"POST"},
            {4, ~":path", ~"/"},
            {5, ~":path", ~"/index.html"},
            {6, ~":scheme", ~"http"},
            {7, ~":scheme", ~"https"},
            {8, ~":status", ~"200"},
            {9, ~":status", ~"204"},
            {10, ~":status", ~"206"},
            {11, ~":status", ~"304"},
            {12, ~":status", ~"400"},
            {13, ~":status", ~"404"},
            {14, ~":status", ~"500"},
            {15, ~"accept-charset", ~""},
            {16, ~"accept-encoding", ~"gzip, deflate"},
            {17, ~"accept-language", ~""},
            {18, ~"accept-ranges", ~""},
            {19, ~"accept", ~""},
            {20, ~"access-control-allow-origin", ~""},
            {21, ~"age", ~""},
            {22, ~"allow", ~""},
            {23, ~"authorization", ~""},
            {24, ~"cache-control", ~""},
            {25, ~"content-disposition", ~""},
            {26, ~"content-encoding", ~""},
            {27, ~"content-language", ~""},
            {28, ~"content-length", ~""},
            {29, ~"content-location", ~""},
            {30, ~"content-range", ~""},
            {31, ~"content-type", ~""},
            {32, ~"cookie", ~""},
            {33, ~"date", ~""},
            {34, ~"etag", ~""},
            {35, ~"expect", ~""},
            {36, ~"expires", ~""},
            {37, ~"from", ~""},
            {38, ~"host", ~""},
            {39, ~"if-match", ~""},
            {40, ~"if-modified-since", ~""},
            {41, ~"if-none-match", ~""},
            {42, ~"if-range", ~""},
            {43, ~"if-unmodified-since", ~""},
            {44, ~"last-modified", ~""},
            {45, ~"link", ~""},
            {46, ~"location", ~""},
            {47, ~"max-forwards", ~""},
            {48, ~"proxy-authenticate", ~""},
            {49, ~"proxy-authorization", ~""},
            {50, ~"range", ~""},
            {51, ~"referer", ~""},
            {52, ~"refresh", ~""},
            {53, ~"retry-after", ~""},
            {54, ~"server", ~""},
            {55, ~"set-cookie", ~""},
            {56, ~"strict-transport-security", ~""},
            {57, ~"transfer-encoding", ~""},
            {58, ~"user-agent", ~""},
            {59, ~"vary", ~""},
            {60, ~"via", ~""},
            {61, ~"www-authenticate", ~""}
        ],
    [
        ?_assertEqual(
            {Name, Value},
            decode_indexed(Idx)
        )
     || {Idx, Name, Value} <- StaticEntries
    ].

%% Indexed Header Field representation: 1xxxxxxx with the index in
%% the low 7 bits (RFC 7541 §6.1). For Idx <= 127 this is a single
%% byte; the static table tops out at 61 so we always fit.
decode_indexed(Idx) ->
    Byte = 16#80 bor Idx,
    Dec = roadrunner_http2_hpack:new_decoder(4096),
    {ok, [Pair], _} = roadrunner_http2_hpack:decode(<<Byte>>, Dec),
    Pair.

%% Encode each static-table NAME with a deliberately-non-static
%% VALUE so the encoder takes the indexed-name + literal-value
%% path (RFC 7541 §6.2.1). Exercises every clause of
%% `static_name_match/1` directly. Round-trip via decode to
%% confirm the chosen index resolves back to the right name.
static_name_match_for_every_static_name_test_() ->
    StaticNames = [
        ~":authority",
        ~":method",
        ~":path",
        ~":scheme",
        ~":status",
        ~"accept-charset",
        ~"accept-encoding",
        ~"accept-language",
        ~"accept-ranges",
        ~"accept",
        ~"access-control-allow-origin",
        ~"age",
        ~"allow",
        ~"authorization",
        ~"cache-control",
        ~"content-disposition",
        ~"content-encoding",
        ~"content-language",
        ~"content-length",
        ~"content-location",
        ~"content-range",
        ~"content-type",
        ~"cookie",
        ~"date",
        ~"etag",
        ~"expect",
        ~"expires",
        ~"from",
        ~"host",
        ~"if-match",
        ~"if-modified-since",
        ~"if-none-match",
        ~"if-range",
        ~"if-unmodified-since",
        ~"last-modified",
        ~"link",
        ~"location",
        ~"max-forwards",
        ~"proxy-authenticate",
        ~"proxy-authorization",
        ~"range",
        ~"referer",
        ~"refresh",
        ~"retry-after",
        ~"server",
        ~"set-cookie",
        ~"strict-transport-security",
        ~"transfer-encoding",
        ~"user-agent",
        ~"vary",
        ~"via",
        ~"www-authenticate"
    ],
    %% A value unlikely to collide with any RFC 7541 static-pair
    %% entry — forces the encoder onto the indexed-name path.
    Value = ~"x-roadrunner-not-static",
    [
        ?_assertEqual({Name, Value}, encode_then_decode(Name, Value))
     || Name <- StaticNames
    ].

encode_then_decode(Name, Value) ->
    Enc = roadrunner_http2_hpack:new_encoder(4096),
    {Block, _} = roadrunner_http2_hpack:encode([{Name, Value}], Enc),
    BlockBin = iolist_to_binary(Block),
    Dec = roadrunner_http2_hpack:new_decoder(4096),
    {ok, [Pair], _} = roadrunner_http2_hpack:decode(BlockBin, Dec),
    Pair.

%% Names that don't resolve to a static-table entry must fall through
%% to the catch-all `none` clause of `static_name_match/1`.
static_name_match_unknown_falls_through_test() ->
    Enc = roadrunner_http2_hpack:new_encoder(4096),
    %% A name that's not in the static table — encoder emits literal-
    %% with-incremental-indexing using the new-name shape (header
    %% field representation 0x40), which exercises both
    %% `static_full_match/2` and `static_name_match/1` returning
    %% `none`.
    {Block, _} = roadrunner_http2_hpack:encode(
        [{~"x-roadrunner-test", ~"1"}], Enc
    ),
    BlockBin = iolist_to_binary(Block),
    Dec = roadrunner_http2_hpack:new_decoder(4096),
    {ok, [Pair], _} = roadrunner_http2_hpack:decode(BlockBin, Dec),
    ?assertEqual({~"x-roadrunner-test", ~"1"}, Pair).

%% =============================================================================
%% Dynamic table size update — RFC 7541 §6.3, §4.2.
%% =============================================================================

decode_size_update_evicts_entries_test() ->
    %% Push a couple of entries, then receive a size update that
    %% forces eviction.
    Push = <<16#40, 1, "a", 1, "1", 16#40, 1, "b", 1, "2">>,
    Ctx0 = roadrunner_http2_hpack:new_decoder(4096),
    {ok, _, Ctx1} = roadrunner_http2_hpack:decode(Push, Ctx0),
    ?assertEqual(2, length(dyn(Ctx1))),
    %% Size Update to 0 — should evict everything.
    {ok, [], Ctx2} = roadrunner_http2_hpack:decode(<<16#20>>, Ctx1),
    ?assertEqual(0, ctx_size(Ctx2)),
    ?assertEqual([], dyn(Ctx2)).

decode_size_update_above_limit_is_error_test() ->
    %% Limit is 100; Update for 200 → invalid_table_size.
    Ctx = roadrunner_http2_hpack:new_decoder(100),
    %% 0x3f then size encoding for 200-31 = 169.
    %% 169 in 0x80-bit-continuation: 169 = 0xA9 → first byte 0xA9 < 0x80? no, 169 > 127, needs 2 bytes.
    %% 169 - 128 = 41, so first cont byte 1xxxxxxx with low 7 = 169 band 0x7F = 0x29 → 0xA9
    %% second cont byte = 169 bsr 7 = 1.
    Bin = <<16#3F, 16#A9, 16#01>>,
    ?assertEqual(
        {error, invalid_table_size},
        roadrunner_http2_hpack:decode(Bin, Ctx)
    ).

decode_oversize_entry_evicts_table_test() ->
    %% RFC 7541 §4.4: an entry larger than the entire table size
    %% silently empties the table and is not added.
    Ctx = roadrunner_http2_hpack:new_decoder(50),
    Bin = <<16#40, 16#0A, "very-long!", 16#1A, "padding-padding-padding-12">>,
    {ok, [_], NewCtx} = roadrunner_http2_hpack:decode(Bin, Ctx),
    ?assertEqual([], dyn(NewCtx)),
    ?assertEqual(0, ctx_size(NewCtx)).

%% =============================================================================
%% Header name validation (RFC 9113 §8.2).
%% =============================================================================

decode_uppercase_literal_name_is_rejected_test() ->
    %% Capital letters in literal-name fields are an HTTP/2 protocol
    %% error.
    Bin = <<16#40, 4, "Host", 4, "test">>,
    Ctx = roadrunner_http2_hpack:new_decoder(4096),
    ?assertEqual(
        {error, bad_header_name},
        roadrunner_http2_hpack:decode(Bin, Ctx)
    ).

%% =============================================================================
%% Integer codec — multi-byte continuation.
%% =============================================================================

decode_long_integer_round_trips_test() ->
    %% Round-trip a literal w/ incremental indexing where the name
    %% is at static index 200 (we don't have such an index, but
    %% the integer codec must handle 200 anyway since the prefix
    %% is 6 bits → 200 - 63 = 137 + continuation. Actually the
    %% combined static+dynamic max here is 61 (no dynamic), so
    %% an index of 200 would be invalid_index. Use the literal
    %% w/o indexing path with a contrived but legal name index
    %% that fits inside the static table.
    %%
    %% Easier: just encode an integer larger than any prefix and
    %% confirm round-trip via encode/decode of a header that
    %% triggers it (e.g. very long value).
    Headers = [{~"x-payload", binary:copy(<<"x">>, 200)}],
    Enc = roadrunner_http2_hpack:new_encoder(4096),
    Dec = roadrunner_http2_hpack:new_decoder(4096),
    {Block, _} = roadrunner_http2_hpack:encode(Headers, Enc),
    {ok, Decoded, _} = roadrunner_http2_hpack:decode(iolist_to_binary(Block), Dec),
    ?assertEqual(Headers, Decoded).

%% =============================================================================
%% set_max_table_size/2 + pending update on encoder.
%% =============================================================================

encoder_emits_size_update_after_cap_change_test() ->
    Enc0 = roadrunner_http2_hpack:new_encoder(4096),
    Enc1 = roadrunner_http2_hpack:set_max_table_size(2048, Enc0),
    {Block, _} = roadrunner_http2_hpack:encode([{~":method", ~"GET"}], Enc1),
    %% Size Update prefix is 001xxxxx with 5-bit integer prefix.
    %% 2048 needs continuation: 2048 - 31 = 2017.
    %% 2017 band 0x7F = 0x21, 2017 bsr 7 = 15.
    BlockBin = iolist_to_binary(Block),
    ?assertMatch(<<16#3F, 16#E1, 16#0F, _:8>>, BlockBin).

%% =============================================================================
%% RFC 7541 §C.4 — Huffman-encoded string fields.
%% =============================================================================

c41_request_with_huffman_test() ->
    %% C.4.1: same as C.3.1 but with Huffman-coded literal value.
    %% Encoded: 8286 8441 8c f1e3 c2e5 f23a 6ba0 ab90 f4ff
    Bin = <<
        16#82,
        16#86,
        16#84,
        16#41,
        16#8C,
        16#F1,
        16#E3,
        16#C2,
        16#E5,
        16#F2,
        16#3A,
        16#6B,
        16#A0,
        16#AB,
        16#90,
        16#F4,
        16#FF
    >>,
    Ctx = roadrunner_http2_hpack:new_decoder(4096),
    {ok, Headers, _} = roadrunner_http2_hpack:decode(Bin, Ctx),
    ?assertEqual(
        [
            {~":method", ~"GET"},
            {~":scheme", ~"http"},
            {~":path", ~"/"},
            {~":authority", ~"www.example.com"}
        ],
        Headers
    ).

%% =============================================================================
%% Decode error paths — invalid index, malformed strings, bad integer
%% continuations, broken Huffman.
%% =============================================================================

decode_indexed_zero_is_error_test() ->
    %% Index 0 is reserved per RFC 7541 §6.1.
    Ctx = roadrunner_http2_hpack:new_decoder(4096),
    ?assertEqual(
        {error, invalid_index},
        roadrunner_http2_hpack:decode(<<16#80>>, Ctx)
    ).

decode_indexed_out_of_range_is_error_test() ->
    %% Index 200 — past the static table, no dynamic entries.
    Ctx = roadrunner_http2_hpack:new_decoder(4096),
    %% Encode index 200: 1xxxxxxx with 7-bit prefix; 200 - 127 = 73
    %% in continuation. Use existing helper via integer encode
    %% manually: 16#FF (127) then 73 (0x49).
    Bin = <<16#FF, 16#49>>,
    ?assertEqual({error, invalid_index}, roadrunner_http2_hpack:decode(Bin, Ctx)).

decode_indexed_dynamic_2nd_entry_test() ->
    %% Push 2 entries, index dyn[2] (= 63). Exercises the
    %% recursive `nth_or_undefined/2` clause.
    Push = <<16#40, 1, "a", 1, "1", 16#40, 1, "b", 1, "2">>,
    Ctx0 = roadrunner_http2_hpack:new_decoder(4096),
    {ok, _, Ctx1} = roadrunner_http2_hpack:decode(Push, Ctx0),
    %% 0xBF = 1011 1111 → 7-bit prefix = 63. Dyn index 2 (eldest).
    {ok, [{Name, Value}], _} = roadrunner_http2_hpack:decode(<<16#BF>>, Ctx1),
    ?assertEqual({~"a", ~"1"}, {Name, Value}).

decode_literal_with_oversize_string_length_is_error_test() ->
    %% Length declares 100 bytes but only 5 follow.
    Ctx = roadrunner_http2_hpack:new_decoder(4096),
    Bin = <<16#40, 100, "hello">>,
    ?assertEqual(
        {error, premature_end_of_block},
        roadrunner_http2_hpack:decode(Bin, Ctx)
    ).

decode_literal_with_indexed_name_out_of_range_is_error_test() ->
    %% Literal w/ Incremental Indexing referring to a name index
    %% that doesn't exist.
    Ctx = roadrunner_http2_hpack:new_decoder(4096),
    %% Prefix 6 bits, value 200 - 63 = 137 in continuation.
    %% 137 < 128? No — 137 > 127, multi-byte. 137 band 0x7F = 9,
    %% 137 bsr 7 = 1. So bytes: 0x7F, 0x89, 0x01.
    Bin = <<16#7F, 16#89, 16#01, 0>>,
    ?assertEqual({error, invalid_index}, roadrunner_http2_hpack:decode(Bin, Ctx)).

decode_literal_without_indexing_indexed_name_out_of_range_test() ->
    %% Same but with Literal w/o Indexing prefix (4 bits).
    Ctx = roadrunner_http2_hpack:new_decoder(4096),
    %% 4-bit prefix = 15 → continuation: 200 - 15 = 185.
    %% 185 band 0x7F = 0x39, 185 bsr 7 = 1. Bytes: 0x0F, 0xB9, 0x01.
    Bin = <<16#0F, 16#B9, 16#01, 0>>,
    ?assertEqual({error, invalid_index}, roadrunner_http2_hpack:decode(Bin, Ctx)).

decode_literal_never_indexed_indexed_name_out_of_range_test() ->
    Ctx = roadrunner_http2_hpack:new_decoder(4096),
    %% 4-bit prefix = 15 → continuation: 200 - 15 = 185.
    Bin = <<16#1F, 16#B9, 16#01, 0>>,
    ?assertEqual({error, invalid_index}, roadrunner_http2_hpack:decode(Bin, Ctx)).

decode_huffman_value_with_eos_is_error_test() ->
    %% Literal w/ Incremental Indexing, name "a" plain, value =
    %% Huffman bytes that contain EOS — Huffman decoder rejects.
    Ctx = roadrunner_http2_hpack:new_decoder(4096),
    %% Construct a Huffman value that triggers eos_in_string.
    BadHuff = <<16#18, 16#FF, 16#FF, 16#FF, 16#FF>>,
    LenByte = 16#80 bor byte_size(BadHuff),
    Bin = <<16#40, 1, "a", LenByte, BadHuff/binary>>,
    ?assertEqual(
        {error, huffman_decode_error},
        roadrunner_http2_hpack:decode(Bin, Ctx)
    ).

decode_truncated_after_indexed_byte_is_error_test() ->
    %% First byte starts an indexed-header rep (1xxxxxxx) with
    %% the prefix-7 marker for "needs continuation" but the
    %% continuation byte is missing.
    Ctx = roadrunner_http2_hpack:new_decoder(4096),
    Bin = <<16#FF>>,
    ?assertEqual({error, bad_integer}, roadrunner_http2_hpack:decode(Bin, Ctx)).

decode_integer_continuation_overflow_is_error_test() ->
    %% Cap the multi-byte continuation at 8 bytes (M < 56). 9
    %% continuation bytes with the high bit set should overflow
    %% the bound.
    Ctx = roadrunner_http2_hpack:new_decoder(4096),
    %% 0xFF (literal w/o indexing, indexed name with prefix=15) +
    %% 9 bytes 0xFF in continuation = bad_integer.
    Bin = <<16#0F, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF>>,
    ?assertEqual({error, bad_integer}, roadrunner_http2_hpack:decode(Bin, Ctx)).

%% =============================================================================
%% Edge case — empty bitstring after a representation cleared the
%% header-block fragment.
%% =============================================================================

decode_only_size_update_returns_empty_test() ->
    %% A header block consisting of only a Dynamic Table Size
    %% Update should return an empty header list.
    Ctx = roadrunner_http2_hpack:new_decoder(4096),
    {ok, [], _} = roadrunner_http2_hpack:decode(<<16#20>>, Ctx).

%% =============================================================================
%% Error bubbling — a malformed representation midway through a
%% header block must propagate up through every recursive
%% `decode_loop` call.
%% =============================================================================

decode_indexed_then_malformed_propagates_test() ->
    %% First rep: indexed header (0x82 = :method GET). Second rep:
    %% literal w/ incremental indexing with a truncated value.
    Ctx = roadrunner_http2_hpack:new_decoder(4096),
    Bin = <<16#82, 16#40, 1, "a", 100, "x">>,
    ?assertEqual(
        {error, premature_end_of_block},
        roadrunner_http2_hpack:decode(Bin, Ctx)
    ).

decode_literal_then_malformed_propagates_test() ->
    Ctx = roadrunner_http2_hpack:new_decoder(4096),
    Bin = <<16#40, 1, "a", 1, "1", 16#40, 1, "b", 100, "x">>,
    ?assertEqual(
        {error, premature_end_of_block},
        roadrunner_http2_hpack:decode(Bin, Ctx)
    ).

decode_size_update_then_malformed_propagates_test() ->
    Ctx = roadrunner_http2_hpack:new_decoder(4096),
    Bin = <<16#20, 16#40, 1, "a", 100, "x">>,
    ?assertEqual(
        {error, premature_end_of_block},
        roadrunner_http2_hpack:decode(Bin, Ctx)
    ).

decode_never_indexed_then_malformed_propagates_test() ->
    Ctx = roadrunner_http2_hpack:new_decoder(4096),
    Bin = <<16#10, 1, "a", 1, "1", 16#10, 1, "b", 100, "x">>,
    ?assertEqual(
        {error, premature_end_of_block},
        roadrunner_http2_hpack:decode(Bin, Ctx)
    ).

decode_without_indexing_then_malformed_propagates_test() ->
    Ctx = roadrunner_http2_hpack:new_decoder(4096),
    Bin = <<16#00, 1, "a", 1, "1", 16#00, 1, "b", 100, "x">>,
    ?assertEqual(
        {error, premature_end_of_block},
        roadrunner_http2_hpack:decode(Bin, Ctx)
    ).

%% =============================================================================
%% set_max_table_size raising the cap — no eviction, no pending
%% update side-effect on already-fitting state.
%% =============================================================================

set_max_table_size_raising_cap_does_not_evict_test() ->
    Ctx0 = roadrunner_http2_hpack:new_encoder(2048),
    Ctx1 = roadrunner_http2_hpack:set_max_table_size(8192, Ctx0),
    %% Limit raised. No entries to evict; size stays 0.
    ?assertEqual(0, ctx_size(Ctx1)).

%% =============================================================================
%% Dynamic-table partial eviction — exercises `keep_within/2`'s
%% recursive case + the empty-table base case.
%% =============================================================================

decode_size_update_partial_eviction_test() ->
    %% Push 3 entries, then size update to a value that evicts the
    %% oldest one only.
    %% Each entry: 1+1+32 = 34 bytes. 3 entries = 102 bytes.
    %% Update to 70 → keeps the 2 newest (68 bytes), drops the
    %% eldest. Walks through `keep_within` with the recursive
    %% case for entries 1 and 2, hits empty-list base for the
    %% truncated tail.
    Push = <<
        16#40,
        1,
        "a",
        1,
        "1",
        16#40,
        1,
        "b",
        1,
        "2",
        16#40,
        1,
        "c",
        1,
        "3"
    >>,
    Ctx0 = roadrunner_http2_hpack:new_decoder(4096),
    {ok, _, Ctx1} = roadrunner_http2_hpack:decode(Push, Ctx0),
    ?assertEqual(3, length(dyn(Ctx1))),
    %% Size update to 70: 70 - 31 = 39 in continuation. 39 < 128
    %% so single byte 0x27. Prefix marker 0x20 → 0x20 + 39 = 0x47.
    %% Wait — 39 < 31? No, 39 > 31. So we do need a continuation.
    %% Prefix 5 bits: max = 31. Encode 70: I=70, max=31, so
    %% emit 0x3F (marker 0x20 + 31), then continuation for 70-31=39.
    %% 39 < 128 → single byte 0x27.
    {ok, [], Ctx2} = roadrunner_http2_hpack:decode(<<16#3F, 16#27>>, Ctx1),
    ?assertEqual([{~"c", ~"3"}, {~"b", ~"2"}], dyn(Ctx2)),
    ?assertEqual(68, ctx_size(Ctx2)).

%% =============================================================================
%% Encoder picks dynamic-table indices when a previously-emitted
%% header re-appears.
%% =============================================================================

encoder_uses_dynamic_full_match_test() ->
    Enc0 = roadrunner_http2_hpack:new_encoder(4096),
    %% First emit pushes "x-trace: t1" into the dyn table.
    {Block1, Enc1} = roadrunner_http2_hpack:encode(
        [{~"x-trace", ~"t1"}], Enc0
    ),
    %% Second emit with the same pair — should be indexed.
    {Block2, _} = roadrunner_http2_hpack:encode(
        [{~"x-trace", ~"t1"}], Enc1
    ),
    %% First block: literal w/ inc indexing + new name + value.
    %% Second block: single byte indexed-header (0x80 + 62 = 0xBE).
    ?assertEqual(<<16#BE>>, iolist_to_binary(Block2)),
    %% Sanity: first block isn't a single byte.
    ?assert(byte_size(iolist_to_binary(Block1)) > 1).

encoder_uses_dynamic_name_match_test() ->
    Enc0 = roadrunner_http2_hpack:new_encoder(4096),
    %% Push "x-id: 1".
    {_, Enc1} = roadrunner_http2_hpack:encode([{~"x-id", ~"1"}], Enc0),
    %% Same name, different value.
    {Block, _} = roadrunner_http2_hpack:encode([{~"x-id", ~"2"}], Enc1),
    %% Should encode as literal w/ incremental indexing using
    %% indexed name 62 + literal value "2". Bytes:
    %%   01xxxxxx (indexed name prefix 6) for index 62 = 0x40 + 62
    %%   = wait, prefix 6 bits, max = 63. 62 fits → 0x40 + 62 = 0x7E.
    %% Then string "2": single byte 0x01 (length 1, not Huffman) +
    %% "2".
    ?assertEqual(<<16#7E, 1, "2">>, iolist_to_binary(Block)).

%% =============================================================================
%% bad_string — string-decode fed an empty bitstring.
%% =============================================================================

decode_size_update_with_bad_integer_continuation_test() ->
    %% Size update prefix (0x20-0x3F) with overflow in the integer
    %% continuation — bubbles up through decode_loop's size-update
    %% branch.
    Ctx = roadrunner_http2_hpack:new_decoder(4096),
    Bin = <<16#3F, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF>>,
    ?assertEqual({error, bad_integer}, roadrunner_http2_hpack:decode(Bin, Ctx)).

decode_indexed_name_then_truncated_value_test() ->
    %% Literal w/ inc indexing, name = static index 1
    %% (":authority"), value declares 100 bytes but provides 0.
    Ctx = roadrunner_http2_hpack:new_decoder(4096),
    Bin = <<16#41, 100>>,
    ?assertEqual(
        {error, premature_end_of_block},
        roadrunner_http2_hpack:decode(Bin, Ctx)
    ).

decode_string_with_overflow_length_is_error_test() ->
    %% String length integer overflows (9 cont bytes with high bit
    %% set). Bubbles up via `decode_string`'s integer error branch.
    Ctx = roadrunner_http2_hpack:new_decoder(4096),
    %% Literal w/ inc indexing, name index 0 (= new name), then
    %% string-length integer with overflow.
    Bin =
        <<16#40, 16#7F, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF>>,
    ?assertEqual({error, bad_integer}, roadrunner_http2_hpack:decode(Bin, Ctx)).

decode_string_with_empty_input_after_indicator_test() ->
    %% Literal w/ incremental indexing, name index 0 (= new name),
    %% then truncated before the name's H/length byte.
    Ctx = roadrunner_http2_hpack:new_decoder(4096),
    Bin = <<16#40>>,
    Result = roadrunner_http2_hpack:decode(Bin, Ctx),
    %% Either bad_integer (length missing) or bad_string —
    %% accept either since the prefix-byte is expected next.
    ?assert(
        Result =:= {error, bad_integer} orelse
            Result =:= {error, bad_string}
    ).

%% =============================================================================
%% Helpers — pull internals out of the opaque record for assertions.
%% =============================================================================

dyn(Ctx) ->
    %% The opaque type makes us peek via element/2 — index 2 of the
    %% record tuple is the table list.
    element(2, Ctx).

ctx_size(Ctx) ->
    element(3, Ctx).
