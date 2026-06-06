-module(roadrunner_qpack).
-moduledoc false.

%% QPACK field-section codec for HTTP/3 (RFC 9204), static-table only.
%%
%% roadrunner advertises `SETTINGS_QPACK_MAX_TABLE_CAPACITY = 0`, so neither
%% side uses the dynamic table: every field line is an indexed static entry,
%% a literal with a static name reference, or a literal with a literal name
%% (RFC 9204 §4.5). The Encoded Field Section Prefix is therefore always the
%% two bytes `00 00` (Required Insert Count 0, Base 0, §4.5.1).
%%
%% The prefixed-integer codec (RFC 9204 §4.1.1) is byte-identical to HPACK's
%% (RFC 7541 §5.1) and the string Huffman table is the shared RFC 7541
%% Appendix B table, so encoding/decoding reuses
%% `roadrunner_http2_hpack:encode_integer/3`+`decode_integer/2` and
%% `roadrunner_http2_hpack_huffman:encode/1`+`decode/1` rather than
%% duplicating them. The 99-entry static table (RFC 9204 Appendix A) is
%% function-clause dispatch, mirroring `roadrunner_http2_hpack`'s static
%% table (the BEAM turns it into a jump table, no `persistent_term` read).

-export([encode/1, decode/1]).

-export_type([headers/0]).

-type header() :: {Name :: binary(), Value :: binary()}.
-type headers() :: [header()].

-type decode_error() ::
    {qpack, dynamic_table_required}
    | {qpack, dynamic_field_line, byte()}
    | {qpack, invalid_static_index, non_neg_integer()}
    | {qpack, bad_integer}
    | {qpack, huffman}
    | {qpack, truncated}.

%% =============================================================================
%% encode/1
%% =============================================================================

-doc """
Encode a header list as a static-only QPACK field section, returned as
an iolist. The caller frames it with
`roadrunner_quic_h3_frame:encode_headers/1` and sends it as iodata, so the
field section is never flattened here.
""".
-spec encode(headers()) -> iolist().
encode(Headers) ->
    %% Field Section Prefix `00 00` (RIC 0, Base 0) then one field line each.
    [<<0, 0>> | encode_field_lines(Headers)].

-spec encode_field_lines(headers()) -> iolist().
encode_field_lines([]) ->
    [];
encode_field_lines([Header | Rest]) ->
    [encode_field_line(Header) | encode_field_lines(Rest)].

-spec encode_field_line(header()) -> iodata().
encode_field_line({Name, Value}) ->
    case static_full_match(Name, Value) of
        Index when is_integer(Index) ->
            %% Indexed Field Line, static (RFC 9204 §4.5.2): `1 1` + 6-bit index.
            roadrunner_http2_hpack:encode_integer(6, 2#11000000, Index);
        none ->
            encode_literal(Name, Value)
    end.

-spec encode_literal(binary(), binary()) -> iolist().
encode_literal(Name, Value) ->
    case static_name_match(Name) of
        Index when is_integer(Index) ->
            %% Literal Field Line with Name Reference, static (RFC 9204 §4.5.4):
            %% `0 1 N=0 T=1` + 4-bit name index, then the value string.
            [
                roadrunner_http2_hpack:encode_integer(4, 2#01010000, Index),
                encode_string(Value)
            ];
        none ->
            %% Literal Field Line with Literal Name (RFC 9204 §4.5.6):
            %% `0 0 1 N=0 H=0` + 3-bit name length, the raw name, then the
            %% value string. The name stays raw (matching the reference codec).
            [
                roadrunner_http2_hpack:encode_integer(3, 2#00100000, byte_size(Name)),
                Name,
                encode_string(Value)
            ]
    end.

%% A string is `H` (1 bit) + a 7-bit-prefix length + the octets, Huffman
%% coded when that is shorter (RFC 9204 §4.1.2).
-spec encode_string(binary()) -> iolist().
encode_string(Str) ->
    Huffman = roadrunner_http2_hpack_huffman:encode(Str),
    HuffmanSize = byte_size(Huffman),
    StrSize = byte_size(Str),
    case HuffmanSize < StrSize of
        true ->
            [roadrunner_http2_hpack:encode_integer(7, 2#10000000, HuffmanSize), Huffman];
        false ->
            [roadrunner_http2_hpack:encode_integer(7, 2#00000000, StrSize), Str]
    end.

%% =============================================================================
%% decode/1
%% =============================================================================

-doc """
Decode a static-only QPACK field section. Any field line that references
the dynamic table (which roadrunner never enables) is a decode error,
surfaced as `{error, {qpack, _}}` for the caller to map to
H3_QPACK_DECOMPRESSION_FAILED (RFC 9204 §2.2).
""".
-spec decode(binary()) -> {ok, headers()} | {error, decode_error()}.
decode(Data) ->
    maybe
        {ok, Rest} ?= decode_prefix(Data),
        decode_field_lines(Rest)
    end.

%% Field Section Prefix (RFC 9204 §4.5.1): an 8-bit-prefix Encoded Insert
%% Count then a Sign bit + 7-bit-prefix Delta Base. Static-only sections
%% carry Required Insert Count 0, so the first byte is 0; the Base is then
%% irrelevant (no dynamic entry is referenced) and skipped.
-spec decode_prefix(binary()) -> {ok, binary()} | {error, decode_error()}.
decode_prefix(<<0, _S:1, DeltaBaseBits/bitstring>>) ->
    maybe
        {ok, _DeltaBase, Rest} ?= integer(7, DeltaBaseBits),
        {ok, Rest}
    end;
decode_prefix(<<Eric, _/binary>>) when Eric =/= 0 ->
    {error, {qpack, dynamic_table_required}};
decode_prefix(_) ->
    {error, {qpack, truncated}}.

-spec decode_field_lines(binary()) -> {ok, headers()} | {error, decode_error()}.
decode_field_lines(<<>>) ->
    {ok, []};
decode_field_lines(Data) ->
    maybe
        {ok, Header, Rest} ?= decode_field_line(Data),
        {ok, Tail} ?= decode_field_lines(Rest),
        {ok, [Header | Tail]}
    end.

-spec decode_field_line(binary()) ->
    {ok, header(), binary()} | {error, decode_error()}.
decode_field_line(<<2#11:2, IndexBits/bitstring>>) ->
    %% Indexed Field Line, static.
    maybe
        {ok, Index, Rest} ?= integer(6, IndexBits),
        {ok, Entry} ?= static_indexed(Index),
        {ok, Entry, Rest}
    end;
decode_field_line(<<2#0101:4, IndexBits/bitstring>>) ->
    %% Literal Field Line with Name Reference, static.
    maybe
        {ok, Index, AfterIndex} ?= integer(4, IndexBits),
        {ok, Name} ?= static_name(Index),
        {ok, Value, Rest} ?= decode_string(AfterIndex),
        {ok, {Name, Value}, Rest}
    end;
decode_field_line(<<2#001:3, _N:1, H:1, LenBits/bitstring>>) ->
    %% Literal Field Line with Literal Name.
    maybe
        {ok, NameLen, AfterLen} ?= integer(3, LenBits),
        {ok, Name, AfterName} ?= take_string(H, NameLen, AfterLen),
        {ok, Value, Rest} ?= decode_string(AfterName),
        {ok, {Name, Value}, Rest}
    end;
decode_field_line(<<Byte, _/binary>>) ->
    %% `1 0` (dynamic indexed), `0 1 _ 0` (dynamic name ref), `0 0 0 1`
    %% (post-base index), `0 0 0 0` (post-base name ref): all reference the
    %% dynamic table, which is never enabled. `decode_field_lines/1` only
    %% calls this on a non-empty buffer, so a 1-byte match is total.
    {error, {qpack, dynamic_field_line, Byte}}.

%% A string: `H` bit + 7-bit-prefix length + octets (Huffman if H=1).
-spec decode_string(bitstring()) -> {ok, binary(), binary()} | {error, decode_error()}.
decode_string(<<H:1, LenBits/bitstring>>) ->
    maybe
        {ok, Len, AfterLen} ?= integer(7, LenBits),
        take_string(H, Len, AfterLen)
    end;
decode_string(<<>>) ->
    {error, {qpack, truncated}}.

%% Take `Len` octets from a byte-aligned buffer, Huffman-decoding when H=1.
-spec take_string(0..1, non_neg_integer(), bitstring()) ->
    {ok, binary(), binary()} | {error, decode_error()}.
take_string(0, Len, Bits) when bit_size(Bits) >= Len * 8 ->
    <<Str:Len/binary, Rest/binary>> = Bits,
    {ok, Str, Rest};
take_string(1, Len, Bits) when bit_size(Bits) >= Len * 8 ->
    <<Encoded:Len/binary, Rest/binary>> = Bits,
    case roadrunner_http2_hpack_huffman:decode(Encoded) of
        {ok, Decoded} -> {ok, Decoded, Rest};
        {error, _} -> {error, {qpack, huffman}}
    end;
take_string(_H, _Len, _Bits) ->
    {error, {qpack, truncated}}.

%% Reuse HPACK's prefixed-integer decoder, normalising its `bad_integer`
%% error into the QPACK error space.
-spec integer(pos_integer(), bitstring()) ->
    {ok, non_neg_integer(), bitstring()} | {error, decode_error()}.
integer(PrefixBits, Bits) ->
    case roadrunner_http2_hpack:decode_integer(PrefixBits, Bits) of
        {ok, _, _} = Ok -> Ok;
        {error, bad_integer} -> {error, {qpack, bad_integer}}
    end.

-spec static_indexed(non_neg_integer()) -> {ok, header()} | {error, decode_error()}.
static_indexed(Index) ->
    case static_entry(Index) of
        invalid -> {error, {qpack, invalid_static_index, Index}};
        Entry -> {ok, Entry}
    end.

-spec static_name(non_neg_integer()) -> {ok, binary()} | {error, decode_error()}.
static_name(Index) ->
    case static_entry(Index) of
        invalid -> {error, {qpack, invalid_static_index, Index}};
        {Name, _Value} -> {ok, Name}
    end.

%% =============================================================================
%% Static table (RFC 9204 Appendix A, indices 0-98)
%%
%% `static_entry/1` is the single source of truth (decode index -> entry).
%% `static_full_match/2` (exact name+value -> index, for entries with a
%% concrete value) and `static_name_match/1` (name -> lowest index) drive
%% encoding. Name-only entries (no concrete value) take an empty-binary
%% value here and never produce an exact match.
%% =============================================================================

-spec static_entry(non_neg_integer()) -> header() | invalid.
static_entry(0) ->
    {~":authority", ~""};
static_entry(1) ->
    {~":path", ~"/"};
static_entry(2) ->
    {~":age", ~"0"};
static_entry(3) ->
    {~"content-disposition", ~""};
static_entry(4) ->
    {~"content-length", ~"0"};
static_entry(5) ->
    {~"cookie", ~""};
static_entry(6) ->
    {~"date", ~""};
static_entry(7) ->
    {~"etag", ~""};
static_entry(8) ->
    {~"if-modified-since", ~""};
static_entry(9) ->
    {~"if-none-match", ~""};
static_entry(10) ->
    {~"last-modified", ~""};
static_entry(11) ->
    {~"link", ~""};
static_entry(12) ->
    {~"location", ~""};
static_entry(13) ->
    {~"referer", ~""};
static_entry(14) ->
    {~"set-cookie", ~""};
static_entry(15) ->
    {~":method", ~"CONNECT"};
static_entry(16) ->
    {~":method", ~"DELETE"};
static_entry(17) ->
    {~":method", ~"GET"};
static_entry(18) ->
    {~":method", ~"HEAD"};
static_entry(19) ->
    {~":method", ~"OPTIONS"};
static_entry(20) ->
    {~":method", ~"POST"};
static_entry(21) ->
    {~":method", ~"PUT"};
static_entry(22) ->
    {~":scheme", ~"http"};
static_entry(23) ->
    {~":scheme", ~"https"};
static_entry(24) ->
    {~":status", ~"103"};
static_entry(25) ->
    {~":status", ~"200"};
static_entry(26) ->
    {~":status", ~"304"};
static_entry(27) ->
    {~":status", ~"404"};
static_entry(28) ->
    {~":status", ~"503"};
static_entry(29) ->
    {~"accept", ~"*/*"};
static_entry(30) ->
    {~"accept", ~"application/dns-message"};
static_entry(31) ->
    {~"accept-encoding", ~"gzip, deflate, br"};
static_entry(32) ->
    {~"accept-ranges", ~"bytes"};
static_entry(33) ->
    {~"access-control-allow-headers", ~"cache-control"};
static_entry(34) ->
    {~"access-control-allow-headers", ~"content-type"};
static_entry(35) ->
    {~"access-control-allow-origin", ~"*"};
static_entry(36) ->
    {~"cache-control", ~"max-age=0"};
static_entry(37) ->
    {~"cache-control", ~"max-age=2592000"};
static_entry(38) ->
    {~"cache-control", ~"max-age=604800"};
static_entry(39) ->
    {~"cache-control", ~"no-cache"};
static_entry(40) ->
    {~"cache-control", ~"no-store"};
static_entry(41) ->
    {~"cache-control", ~"public, max-age=31536000"};
static_entry(42) ->
    {~"content-encoding", ~"br"};
static_entry(43) ->
    {~"content-encoding", ~"gzip"};
static_entry(44) ->
    {~"content-type", ~"application/dns-message"};
static_entry(45) ->
    {~"content-type", ~"application/javascript"};
static_entry(46) ->
    {~"content-type", ~"application/json"};
static_entry(47) ->
    {~"content-type", ~"application/x-www-form-urlencoded"};
static_entry(48) ->
    {~"content-type", ~"image/gif"};
static_entry(49) ->
    {~"content-type", ~"image/jpeg"};
static_entry(50) ->
    {~"content-type", ~"image/png"};
static_entry(51) ->
    {~"content-type", ~"text/css"};
static_entry(52) ->
    {~"content-type", ~"text/html; charset=utf-8"};
static_entry(53) ->
    {~"content-type", ~"text/plain"};
static_entry(54) ->
    {~"content-type", ~"text/plain;charset=utf-8"};
static_entry(55) ->
    {~"range", ~"bytes=0-"};
static_entry(56) ->
    {~"strict-transport-security", ~"max-age=31536000"};
static_entry(57) ->
    {~"strict-transport-security", ~"max-age=31536000; includesubdomains"};
static_entry(58) ->
    {~"strict-transport-security", ~"max-age=31536000; includesubdomains; preload"};
static_entry(59) ->
    {~"vary", ~"accept-encoding"};
static_entry(60) ->
    {~"vary", ~"origin"};
static_entry(61) ->
    {~"x-content-type-options", ~"nosniff"};
static_entry(62) ->
    {~"x-xss-protection", ~"1; mode=block"};
static_entry(63) ->
    {~":status", ~"100"};
static_entry(64) ->
    {~":status", ~"204"};
static_entry(65) ->
    {~":status", ~"206"};
static_entry(66) ->
    {~":status", ~"302"};
static_entry(67) ->
    {~":status", ~"400"};
static_entry(68) ->
    {~":status", ~"403"};
static_entry(69) ->
    {~":status", ~"421"};
static_entry(70) ->
    {~":status", ~"425"};
static_entry(71) ->
    {~":status", ~"500"};
static_entry(72) ->
    {~"accept-language", ~""};
static_entry(73) ->
    {~"access-control-allow-credentials", ~"FALSE"};
static_entry(74) ->
    {~"access-control-allow-credentials", ~"TRUE"};
static_entry(75) ->
    {~"access-control-allow-headers", ~"*"};
static_entry(76) ->
    {~"access-control-allow-methods", ~"get"};
static_entry(77) ->
    {~"access-control-allow-methods", ~"get, post, options"};
static_entry(78) ->
    {~"access-control-allow-methods", ~"options"};
static_entry(79) ->
    {~"access-control-expose-headers", ~"content-length"};
static_entry(80) ->
    {~"access-control-request-headers", ~"content-type"};
static_entry(81) ->
    {~"access-control-request-method", ~"get"};
static_entry(82) ->
    {~"access-control-request-method", ~"post"};
static_entry(83) ->
    {~"alt-svc", ~"clear"};
static_entry(84) ->
    {~"authorization", ~""};
static_entry(85) ->
    {~"content-security-policy", ~"script-src 'none'; object-src 'none'; base-uri 'none'"};
static_entry(86) ->
    {~"early-data", ~"1"};
static_entry(87) ->
    {~"expect-ct", ~""};
static_entry(88) ->
    {~"forwarded", ~""};
static_entry(89) ->
    {~"if-range", ~""};
static_entry(90) ->
    {~"origin", ~""};
static_entry(91) ->
    {~"purpose", ~"prefetch"};
static_entry(92) ->
    {~"server", ~""};
static_entry(93) ->
    {~"timing-allow-origin", ~"*"};
static_entry(94) ->
    {~"upgrade-insecure-requests", ~"1"};
static_entry(95) ->
    {~"user-agent", ~""};
static_entry(96) ->
    {~"x-forwarded-for", ~""};
static_entry(97) ->
    {~"x-frame-options", ~"deny"};
static_entry(98) ->
    {~"x-frame-options", ~"sameorigin"};
static_entry(_) ->
    invalid.

%% Exact name+value match -> index (concrete-value entries only).
-spec static_full_match(binary(), binary()) -> non_neg_integer() | none.
static_full_match(~":path", ~"/") ->
    1;
static_full_match(~":age", ~"0") ->
    2;
static_full_match(~"content-length", ~"0") ->
    4;
static_full_match(~":method", ~"CONNECT") ->
    15;
static_full_match(~":method", ~"DELETE") ->
    16;
static_full_match(~":method", ~"GET") ->
    17;
static_full_match(~":method", ~"HEAD") ->
    18;
static_full_match(~":method", ~"OPTIONS") ->
    19;
static_full_match(~":method", ~"POST") ->
    20;
static_full_match(~":method", ~"PUT") ->
    21;
static_full_match(~":scheme", ~"http") ->
    22;
static_full_match(~":scheme", ~"https") ->
    23;
static_full_match(~":status", ~"103") ->
    24;
static_full_match(~":status", ~"200") ->
    25;
static_full_match(~":status", ~"304") ->
    26;
static_full_match(~":status", ~"404") ->
    27;
static_full_match(~":status", ~"503") ->
    28;
static_full_match(~"accept", ~"*/*") ->
    29;
static_full_match(~"accept", ~"application/dns-message") ->
    30;
static_full_match(~"accept-encoding", ~"gzip, deflate, br") ->
    31;
static_full_match(~"accept-ranges", ~"bytes") ->
    32;
static_full_match(~"access-control-allow-headers", ~"cache-control") ->
    33;
static_full_match(~"access-control-allow-headers", ~"content-type") ->
    34;
static_full_match(~"access-control-allow-origin", ~"*") ->
    35;
static_full_match(~"cache-control", ~"max-age=0") ->
    36;
static_full_match(~"cache-control", ~"max-age=2592000") ->
    37;
static_full_match(~"cache-control", ~"max-age=604800") ->
    38;
static_full_match(~"cache-control", ~"no-cache") ->
    39;
static_full_match(~"cache-control", ~"no-store") ->
    40;
static_full_match(~"cache-control", ~"public, max-age=31536000") ->
    41;
static_full_match(~"content-encoding", ~"br") ->
    42;
static_full_match(~"content-encoding", ~"gzip") ->
    43;
static_full_match(~"content-type", ~"application/dns-message") ->
    44;
static_full_match(~"content-type", ~"application/javascript") ->
    45;
static_full_match(~"content-type", ~"application/json") ->
    46;
static_full_match(~"content-type", ~"application/x-www-form-urlencoded") ->
    47;
static_full_match(~"content-type", ~"image/gif") ->
    48;
static_full_match(~"content-type", ~"image/jpeg") ->
    49;
static_full_match(~"content-type", ~"image/png") ->
    50;
static_full_match(~"content-type", ~"text/css") ->
    51;
static_full_match(~"content-type", ~"text/html; charset=utf-8") ->
    52;
static_full_match(~"content-type", ~"text/plain") ->
    53;
static_full_match(~"content-type", ~"text/plain;charset=utf-8") ->
    54;
static_full_match(~"range", ~"bytes=0-") ->
    55;
static_full_match(~"strict-transport-security", ~"max-age=31536000") ->
    56;
static_full_match(~"strict-transport-security", ~"max-age=31536000; includesubdomains") ->
    57;
static_full_match(~"strict-transport-security", ~"max-age=31536000; includesubdomains; preload") ->
    58;
static_full_match(~"vary", ~"accept-encoding") ->
    59;
static_full_match(~"vary", ~"origin") ->
    60;
static_full_match(~"x-content-type-options", ~"nosniff") ->
    61;
static_full_match(~"x-xss-protection", ~"1; mode=block") ->
    62;
static_full_match(~":status", ~"100") ->
    63;
static_full_match(~":status", ~"204") ->
    64;
static_full_match(~":status", ~"206") ->
    65;
static_full_match(~":status", ~"302") ->
    66;
static_full_match(~":status", ~"400") ->
    67;
static_full_match(~":status", ~"403") ->
    68;
static_full_match(~":status", ~"421") ->
    69;
static_full_match(~":status", ~"425") ->
    70;
static_full_match(~":status", ~"500") ->
    71;
static_full_match(~"access-control-allow-credentials", ~"FALSE") ->
    73;
static_full_match(~"access-control-allow-credentials", ~"TRUE") ->
    74;
static_full_match(~"access-control-allow-headers", ~"*") ->
    75;
static_full_match(~"access-control-allow-methods", ~"get") ->
    76;
static_full_match(~"access-control-allow-methods", ~"get, post, options") ->
    77;
static_full_match(~"access-control-allow-methods", ~"options") ->
    78;
static_full_match(~"access-control-expose-headers", ~"content-length") ->
    79;
static_full_match(~"access-control-request-headers", ~"content-type") ->
    80;
static_full_match(~"access-control-request-method", ~"get") ->
    81;
static_full_match(~"access-control-request-method", ~"post") ->
    82;
static_full_match(~"alt-svc", ~"clear") ->
    83;
static_full_match(
    ~"content-security-policy", ~"script-src 'none'; object-src 'none'; base-uri 'none'"
) ->
    85;
static_full_match(~"early-data", ~"1") ->
    86;
static_full_match(~"purpose", ~"prefetch") ->
    91;
static_full_match(~"timing-allow-origin", ~"*") ->
    93;
static_full_match(~"upgrade-insecure-requests", ~"1") ->
    94;
static_full_match(~"x-frame-options", ~"deny") ->
    97;
static_full_match(~"x-frame-options", ~"sameorigin") ->
    98;
static_full_match(_, _) ->
    none.

%% Name -> lowest index carrying that name.
-spec static_name_match(binary()) -> non_neg_integer() | none.
static_name_match(~":authority") -> 0;
static_name_match(~":path") -> 1;
static_name_match(~":age") -> 2;
static_name_match(~"content-disposition") -> 3;
static_name_match(~"content-length") -> 4;
static_name_match(~"cookie") -> 5;
static_name_match(~"date") -> 6;
static_name_match(~"etag") -> 7;
static_name_match(~"if-modified-since") -> 8;
static_name_match(~"if-none-match") -> 9;
static_name_match(~"last-modified") -> 10;
static_name_match(~"link") -> 11;
static_name_match(~"location") -> 12;
static_name_match(~"referer") -> 13;
static_name_match(~"set-cookie") -> 14;
static_name_match(~":method") -> 15;
static_name_match(~":scheme") -> 22;
static_name_match(~":status") -> 24;
static_name_match(~"accept") -> 29;
static_name_match(~"accept-encoding") -> 31;
static_name_match(~"accept-ranges") -> 32;
static_name_match(~"access-control-allow-headers") -> 33;
static_name_match(~"access-control-allow-origin") -> 35;
static_name_match(~"cache-control") -> 36;
static_name_match(~"content-encoding") -> 42;
static_name_match(~"content-type") -> 44;
static_name_match(~"range") -> 55;
static_name_match(~"strict-transport-security") -> 56;
static_name_match(~"vary") -> 59;
static_name_match(~"x-content-type-options") -> 61;
static_name_match(~"x-xss-protection") -> 62;
static_name_match(~"accept-language") -> 72;
static_name_match(~"access-control-allow-credentials") -> 73;
static_name_match(~"access-control-allow-methods") -> 76;
static_name_match(~"access-control-expose-headers") -> 79;
static_name_match(~"access-control-request-headers") -> 80;
static_name_match(~"access-control-request-method") -> 81;
static_name_match(~"alt-svc") -> 83;
static_name_match(~"authorization") -> 84;
static_name_match(~"content-security-policy") -> 85;
static_name_match(~"early-data") -> 86;
static_name_match(~"expect-ct") -> 87;
static_name_match(~"forwarded") -> 88;
static_name_match(~"if-range") -> 89;
static_name_match(~"origin") -> 90;
static_name_match(~"purpose") -> 91;
static_name_match(~"server") -> 92;
static_name_match(~"timing-allow-origin") -> 93;
static_name_match(~"upgrade-insecure-requests") -> 94;
static_name_match(~"user-agent") -> 95;
static_name_match(~"x-forwarded-for") -> 96;
static_name_match(~"x-frame-options") -> 97;
static_name_match(_) -> none.
