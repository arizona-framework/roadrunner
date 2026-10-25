-module(roadrunner_qpack).
-moduledoc false.

%% QPACK codec for HTTP/3 (RFC 9204): field sections, and the instructions
%% of the encoder and decoder streams.
%%
%% roadrunner's encoder never uses the dynamic table, so every field section
%% it sends is static-only: an indexed static entry, a literal with a static
%% name reference, or a literal with a literal name per field line (RFC 9204
%% §4.5), behind the two-byte prefix `00 00` (Required Insert Count 0, Base 0,
%% §4.5.1). Its decoder takes a dynamic table the peer fills through its
%% encoder stream (`encoder_instructions/2` into a `roadrunner_qpack_table`),
%% and a field section may reference it (`decode/2`). `decode/1` is the
%% static-only decoder; `decode/2` hands a section whose Required Insert Count
%% is 0 straight to it, so a peer that never uses the dynamic table costs
%% nothing more than before.
%%
%% The prefixed-integer codec (RFC 9204 §4.1.1) is byte-identical to HPACK's
%% (RFC 7541 §5.1) and the string Huffman table is the shared RFC 7541
%% Appendix B table, so encoding/decoding reuses
%% `roadrunner_http2_hpack:encode_integer/3`+`prefix_integer/3` and
%% `roadrunner_http2_hpack_huffman:encode/1`+`decode/1` rather than
%% duplicating them. The 99-entry static table (RFC 9204 Appendix A) is
%% function-clause dispatch, mirroring `roadrunner_http2_hpack`'s static
%% table (the BEAM turns it into a jump table, no `persistent_term` read).

-export([encode/1, decode/1, decode/2]).
-export([encoder_instructions/2]).
-export([section_acknowledgment/1, stream_cancellation/1, insert_count_increment/1]).

-export_type([headers/0]).

-type header() :: {Name :: binary(), Value :: binary()}.
-type headers() :: [header()].

-type decode_error() ::
    {qpack, dynamic_table_required}
    | {qpack, dynamic_field_line, byte()}
    | {qpack, invalid_static_index, non_neg_integer()}
    | {qpack, invalid_dynamic_index, integer()}
    | {qpack, invalid_required_insert_count, non_neg_integer()}
    | {qpack, blocked, non_neg_integer()}
    | {qpack, invalid_base}
    | {qpack, bad_integer}
    | {qpack, huffman}
    | {qpack, truncated}.

-type instruction_error() ::
    {qpack, capacity_exceeded}
    | {qpack, entry_too_large}
    | {qpack, invalid_static_index, non_neg_integer()}
    | {qpack, invalid_dynamic_index, non_neg_integer()}
    | {qpack, instruction_too_large}
    | {qpack, bad_integer}
    | {qpack, huffman}.

%% What a field section's dynamic references resolve against: `none` for a
%% static-only section (any dynamic reference is an error), else the table
%% with the section's Base and Required Insert Count (§4.5.1).
-type section_table() ::
    none
    | {roadrunner_qpack_table:t(), Base :: non_neg_integer(), RequiredInsertCount :: pos_integer()}.

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
the dynamic table is a decode error, surfaced as `{error, {qpack, _}}` for
the caller to map to H3_QPACK_DECOMPRESSION_FAILED (RFC 9204 §2.2).
""".
-spec decode(binary()) -> {ok, headers()} | {error, decode_error()}.
decode(Data) ->
    maybe
        {ok, Rest} ?= decode_prefix(Data),
        decode_field_lines(Rest, none)
    end.

-doc """
Decode a QPACK field section against the connection's dynamic table,
returning the headers and the section's Required Insert Count (RFC 9204
§4.5.1.1): 0 for a static-only section, which needs no Section
Acknowledgment (§4.4.1). This side advertises
SETTINGS_QPACK_BLOCKED_STREAMS = 0, so a section that needs inserts the
table has not received yet is an error rather than a blocked stream
(§2.1.2), as is a reference to an evicted entry or to one at or past the
Required Insert Count (§2.2.3). Every error maps to
H3_QPACK_DECOMPRESSION_FAILED.
""".
-spec decode(binary(), roadrunner_qpack_table:t()) ->
    {ok, headers(), non_neg_integer()} | {error, decode_error()}.
decode(<<0, _/binary>> = Data, _Table) ->
    case decode(Data) of
        {ok, Headers} -> {ok, Headers, 0};
        {error, _} = Error -> Error
    end;
decode(<<B, Rest/binary>>, Table) ->
    maybe
        {ok, EncodedInsertCount, AfterCount} ?= integer(B, 16#FF, Rest),
        {ok, Ric} ?= required_insert_count(EncodedInsertCount, Table),
        {ok, Base, Lines} ?= base(Ric, AfterCount),
        {ok, Headers} ?= decode_field_lines(Lines, {Table, Base, Ric}),
        {ok, Headers, Ric}
    end;
decode(<<>>, _Table) ->
    {error, {qpack, truncated}}.

%% Reconstruct the Required Insert Count from its encoded form (RFC 9204
%% §4.5.1.1), which the encoder sent modulo `2 * MaxEntries`. A value no
%% conformant encoder could produce is an error, and so is one past the
%% inserts received: with no blocked streams allowed the section cannot
%% wait for them (§2.1.2).
-spec required_insert_count(pos_integer(), roadrunner_qpack_table:t()) ->
    {ok, pos_integer()} | {error, decode_error()}.
required_insert_count(Encoded, Table) ->
    MaxEntries = roadrunner_qpack_table:max_entries(Table),
    FullRange = 2 * MaxEntries,
    case Encoded > FullRange of
        true ->
            {error, {qpack, invalid_required_insert_count, Encoded}};
        false ->
            TotalInserts = roadrunner_qpack_table:insert_count(Table),
            MaxValue = TotalInserts + MaxEntries,
            MaxWrapped = (MaxValue div FullRange) * FullRange,
            unwrap_insert_count(MaxWrapped + Encoded - 1, MaxValue, FullRange, TotalInserts)
    end.

%% The unwrapping steps of the §4.5.1.1 algorithm: a value past the most the
%% encoder could have meant wrapped one fewer time, and 0 is never encoded
%% this way.
-spec unwrap_insert_count(
    non_neg_integer(), non_neg_integer(), pos_integer(), non_neg_integer()
) -> {ok, pos_integer()} | {error, decode_error()}.
unwrap_insert_count(Ric, MaxValue, FullRange, _TotalInserts) when
    Ric > MaxValue, Ric =< FullRange
->
    {error, {qpack, invalid_required_insert_count, Ric}};
unwrap_insert_count(Ric, MaxValue, FullRange, TotalInserts) when Ric > MaxValue ->
    check_insert_count(Ric - FullRange, TotalInserts);
unwrap_insert_count(Ric, _MaxValue, _FullRange, TotalInserts) ->
    check_insert_count(Ric, TotalInserts).

-spec check_insert_count(non_neg_integer(), non_neg_integer()) ->
    {ok, pos_integer()} | {error, decode_error()}.
check_insert_count(0, _TotalInserts) ->
    {error, {qpack, invalid_required_insert_count, 0}};
check_insert_count(Ric, TotalInserts) when Ric > TotalInserts ->
    {error, {qpack, blocked, Ric}};
check_insert_count(Ric, _TotalInserts) ->
    {ok, Ric}.

%% The Base (RFC 9204 §4.5.1.2): a Sign bit and a 7-bit-prefix Delta Base
%% relative to the Required Insert Count. A negative Base is invalid.
-spec base(pos_integer(), binary()) ->
    {ok, non_neg_integer(), binary()} | {error, decode_error()}.
base(Ric, <<Sign:1, Delta:7, Rest/binary>>) ->
    maybe
        {ok, DeltaBase, Lines} ?= integer(Delta, 16#7F, Rest),
        signed_base(Sign, Ric, DeltaBase, Lines)
    end;
base(_Ric, <<>>) ->
    {error, {qpack, truncated}}.

-spec signed_base(0..1, pos_integer(), non_neg_integer(), binary()) ->
    {ok, non_neg_integer(), binary()} | {error, decode_error()}.
signed_base(0, Ric, DeltaBase, Lines) ->
    {ok, Ric + DeltaBase, Lines};
signed_base(1, Ric, DeltaBase, Lines) when DeltaBase < Ric ->
    {ok, Ric - DeltaBase - 1, Lines};
signed_base(1, _Ric, _DeltaBase, _Lines) ->
    {error, {qpack, invalid_base}}.

%% Field Section Prefix (RFC 9204 §4.5.1): an 8-bit-prefix Encoded Insert
%% Count then a Sign bit + 7-bit-prefix Delta Base. Static-only sections
%% carry Required Insert Count 0, so the first byte is 0; the Base is then
%% irrelevant (no dynamic entry is referenced) and skipped.
-spec decode_prefix(binary()) -> {ok, binary()} | {error, decode_error()}.
decode_prefix(<<0, B, DeltaBaseRest/binary>>) ->
    maybe
        {ok, _DeltaBase, Rest} ?= integer(B band 16#7F, 16#7F, DeltaBaseRest),
        {ok, Rest}
    end;
decode_prefix(<<Eric, _/binary>>) when Eric =/= 0 ->
    {error, {qpack, dynamic_table_required}};
decode_prefix(_) ->
    {error, {qpack, truncated}}.

-spec decode_field_lines(binary(), section_table()) -> {ok, headers()} | {error, decode_error()}.
%% A field line whose integers fit their prefix plus at most one
%% continuation byte (every static index, and names and values below 135
%% bytes) is matched here and in the helpers below, so the rest of the
%% section stays a match context; `decode_field_line/1` returns each line
%% as an `{ok, Header, Rest}` tuple and takes the others.
decode_field_lines(<<>>, _Dyn) ->
    {ok, []};
decode_field_lines(<<B, Rest/binary>>, Dyn) when B >= 2#11000000, B =/= 16#FF ->
    maybe
        {ok, Entry} ?= static_indexed(B band 16#3F),
        {ok, Tail} ?= decode_field_lines(Rest, Dyn),
        {ok, [Entry | Tail]}
    end;
decode_field_lines(<<16#FF, C, Rest/binary>>, Dyn) when C < 128 ->
    maybe
        {ok, Entry} ?= static_indexed(16#3F + C),
        {ok, Tail} ?= decode_field_lines(Rest, Dyn),
        {ok, [Entry | Tail]}
    end;
decode_field_lines(<<B, Rest/binary>>, Dyn) when
    B band 2#11010000 =:= 2#01010000, B band 16#0F =/= 16#0F
->
    name_ref_line(B band 16#0F, Rest, Dyn);
decode_field_lines(<<B, C, Rest/binary>>, Dyn) when B band 2#11010000 =:= 2#01010000, C < 128 ->
    name_ref_line(16#0F + C, Rest, Dyn);
decode_field_lines(<<B, Rest/binary>>, Dyn) when
    B band 2#11100000 =:= 2#00100000, B band 2#111 =/= 2#111
->
    literal_name_line((B bsr 3) band 1, B band 2#111, Rest, Dyn);
decode_field_lines(<<B, C, Rest/binary>>, Dyn) when B band 2#11100000 =:= 2#00100000, C < 128 ->
    literal_name_line((B bsr 3) band 1, 2#111 + C, Rest, Dyn);
decode_field_lines(Data, Dyn) ->
    maybe
        {ok, Header, Rest} ?= decode_field_line(Data, Dyn),
        {ok, Tail} ?= decode_field_lines(Rest, Dyn),
        {ok, [Header | Tail]}
    end.

%% The value's length within its 7-bit prefix, else `decode_string/1`.
-spec name_ref_line(non_neg_integer(), binary(), section_table()) ->
    {ok, headers()} | {error, decode_error()}.
name_ref_line(Index, <<H:1, Len:7, Body:Len/binary, Rest/binary>>, Dyn) when Len < 127 ->
    maybe
        {ok, Name} ?= static_name(Index),
        {ok, Value} ?= string_value(H, Body),
        {ok, Tail} ?= decode_field_lines(Rest, Dyn),
        {ok, [{Name, Value} | Tail]}
    end;
name_ref_line(Index, Data, Dyn) ->
    maybe
        {ok, Name} ?= static_name(Index),
        {ok, Value, Rest} ?= decode_string(Data),
        {ok, Tail} ?= decode_field_lines(Rest, Dyn),
        {ok, [{Name, Value} | Tail]}
    end.

-spec literal_name_line(0..1, non_neg_integer(), binary(), section_table()) ->
    {ok, headers()} | {error, decode_error()}.
literal_name_line(NH, NameLen, Data, Dyn) ->
    case Data of
        <<NBody:NameLen/binary, VH:1, VLen:7, VBody:VLen/binary, Rest/binary>> when VLen < 127 ->
            maybe
                {ok, Name} ?= string_value(NH, NBody),
                {ok, Value} ?= string_value(VH, VBody),
                {ok, Tail} ?= decode_field_lines(Rest, Dyn),
                {ok, [{Name, Value} | Tail]}
            end;
        _ ->
            maybe
                {ok, Name, AfterName} ?= take_string(NH, NameLen, Data),
                {ok, Value, Rest} ?= decode_string(AfterName),
                {ok, Tail} ?= decode_field_lines(Rest, Dyn),
                {ok, [{Name, Value} | Tail]}
            end
    end.

%% The field lines `decode_field_lines/2` does not match inline: an integer
%% past one continuation byte, a line cut short, or a dynamic-table
%% reference (RFC 9204 §4.5). The pattern bits are tested with `band`, as
%% there.
-spec decode_field_line(binary(), section_table()) ->
    {ok, header(), binary()} | {error, decode_error()}.
decode_field_line(<<B, Rest/binary>>, _Dyn) when B >= 2#11000000 ->
    %% 11xxxxxx — Indexed Field Line, static, 6-bit index. One that gets
    %% here takes two or more continuation bytes (at least 191), past the
    %% 99-entry static table, or is cut short.
    maybe
        {ok, Index, _} ?= integer(B band 16#3F, 16#3F, Rest),
        {error, {qpack, invalid_static_index, Index}}
    end;
decode_field_line(<<B, Rest/binary>>, _Dyn) when B band 2#11010000 =:= 2#01010000 ->
    %% 01N1xxxx — Literal Field Line with Name Reference, static, 4-bit
    %% index; N (never index) only matters to intermediaries. As above, an
    %% index that gets here (at least 143) is past the table.
    maybe
        {ok, Index, _} ?= integer(B band 16#0F, 16#0F, Rest),
        {error, {qpack, invalid_static_index, Index}}
    end;
decode_field_line(<<B, Rest/binary>>, _Dyn) when B band 2#11100000 =:= 2#00100000 ->
    %% 001NHxxx — Literal Field Line with Literal Name. 3-bit name length.
    maybe
        {ok, NameLen, AfterLen} ?= integer(B band 2#111, 2#111, Rest),
        {ok, Name, AfterName} ?= take_string((B bsr 3) band 1, NameLen, AfterLen),
        {ok, Value, Rest1} ?= decode_string(AfterName),
        {ok, {Name, Value}, Rest1}
    end;
decode_field_line(<<Byte, _/binary>>, none) ->
    %% `1 0` (dynamic indexed), `0 1 _ 0` (dynamic name ref), `0 0 0 1`
    %% (post-base index), `0 0 0 0` (post-base name ref): all reference the
    %% dynamic table, which a section with Required Insert Count 0 cannot.
    %% `decode_field_lines/2` only calls this on a non-empty buffer, so a
    %% 1-byte match is total.
    {error, {qpack, dynamic_field_line, Byte}};
decode_field_line(<<B, Rest/binary>>, Dyn) when B >= 2#10000000 ->
    %% 10xxxxxx: Indexed Field Line, dynamic (§4.5.2): a 6-bit relative
    %% index, counted down from Base - 1.
    maybe
        {ok, Index, Rest1} ?= integer(B band 16#3F, 16#3F, Rest),
        {ok, Entry} ?= dynamic_entry(relative, Index, Dyn),
        {ok, Entry, Rest1}
    end;
decode_field_line(<<B, Rest/binary>>, Dyn) when B >= 2#01000000 ->
    %% 01N0xxxx: Literal Field Line with Name Reference, dynamic (§4.5.4):
    %% a 4-bit relative index for the name, then the value string.
    maybe
        {ok, Index, Rest1} ?= integer(B band 16#0F, 16#0F, Rest),
        {ok, {Name, _}} ?= dynamic_entry(relative, Index, Dyn),
        {ok, Value, Rest2} ?= decode_string(Rest1),
        {ok, {Name, Value}, Rest2}
    end;
decode_field_line(<<B, Rest/binary>>, Dyn) when B >= 2#00010000 ->
    %% 0001xxxx: Indexed Field Line with Post-Base Index (§4.5.3): a 4-bit
    %% index counted up from Base.
    maybe
        {ok, Index, Rest1} ?= integer(B band 16#0F, 16#0F, Rest),
        {ok, Entry} ?= dynamic_entry(post_base, Index, Dyn),
        {ok, Entry, Rest1}
    end;
decode_field_line(<<B, Rest/binary>>, Dyn) ->
    %% 0000Nxxx: Literal Field Line with Post-Base Name Reference
    %% (§4.5.5): a 3-bit post-base index for the name, then the value.
    maybe
        {ok, Index, Rest1} ?= integer(B band 2#111, 2#111, Rest),
        {ok, {Name, _}} ?= dynamic_entry(post_base, Index, Dyn),
        {ok, Value, Rest2} ?= decode_string(Rest1),
        {ok, {Name, Value}, Rest2}
    end.

%% The dynamic entry a field line references (RFC 9204 §3.2.5, §3.2.6): a
%% relative index counts down from Base - 1, a post-base index up from
%% Base. The absolute index must be below the section's Required Insert
%% Count and still in the table (§2.2.3).
-spec dynamic_entry(
    relative | post_base,
    non_neg_integer(),
    {roadrunner_qpack_table:t(), non_neg_integer(), pos_integer()}
) -> {ok, header()} | {error, decode_error()}.
dynamic_entry(relative, Index, {Table, Base, Ric}) ->
    absolute_entry(Base - 1 - Index, Table, Ric);
dynamic_entry(post_base, Index, {Table, Base, Ric}) ->
    absolute_entry(Base + Index, Table, Ric).

-spec absolute_entry(integer(), roadrunner_qpack_table:t(), pos_integer()) ->
    {ok, header()} | {error, decode_error()}.
absolute_entry(Absolute, Table, Ric) when Absolute >= 0, Absolute < Ric ->
    case roadrunner_qpack_table:absolute(Absolute, Table) of
        {ok, _} = Ok -> Ok;
        error -> {error, {qpack, invalid_dynamic_index, Absolute}}
    end;
absolute_entry(Absolute, _Table, _Ric) ->
    {error, {qpack, invalid_dynamic_index, Absolute}}.

%% A string: `H` bit + 7-bit-prefix length + octets (Huffman if H=1).
-spec decode_string(binary()) -> {ok, binary(), binary()} | {error, decode_error()}.
decode_string(<<B, Rest/binary>>) ->
    maybe
        {ok, Len, AfterLen} ?= integer(B band 16#7F, 16#7F, Rest),
        take_string(B bsr 7, Len, AfterLen)
    end;
decode_string(<<>>) ->
    {error, {qpack, truncated}}.

%% Take `Len` octets from the buffer, Huffman-decoding when H=1.
-spec take_string(0..1, non_neg_integer(), binary()) ->
    {ok, binary(), binary()} | {error, decode_error()}.
take_string(H, Len, Bin) ->
    case Bin of
        <<Str:Len/binary, Rest/binary>> ->
            maybe
                {ok, Value} ?= string_value(H, Str),
                {ok, Value, Rest}
            end;
        _ ->
            {error, {qpack, truncated}}
    end.

%% A string's octets as sent (H = 0) or Huffman-decoded (H = 1).
-spec string_value(0..1, binary()) -> {ok, binary()} | {error, decode_error()}.
string_value(0, Str) ->
    {ok, Str};
string_value(1, Encoded) ->
    case roadrunner_http2_hpack_huffman:decode(Encoded) of
        {ok, _} = Ok -> Ok;
        {error, _} -> {error, {qpack, huffman}}
    end.

%% Reuse HPACK's prefixed-integer decoder (the encoding is shared, RFC
%% 9204 §4.1.1), normalising its `bad_integer` error into the QPACK
%% error space.
-spec integer(non_neg_integer(), pos_integer(), binary()) ->
    {ok, non_neg_integer(), binary()} | {error, decode_error()}.
integer(Prefix, Max, Rest) ->
    case roadrunner_http2_hpack:prefix_integer(Prefix, Max, Rest) of
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
%% Encoder stream (RFC 9204 §4.3)
%% =============================================================================

-doc """
Apply the instructions in a chunk of the peer's encoder stream (RFC 9204
§4.3) to the dynamic table. Returns the table and the bytes of a last
instruction not fully received yet, for the caller to put in front of the
stream's next chunk. A capacity over the advertised maximum (§4.3.1), an
entry larger than the capacity (§3.2.2), a reference to a static or dynamic
entry that does not exist (§3.1, §2.2.3), an integer past 62 bits, or a
partial instruction already longer than any valid one could be is an
error, which the caller maps to QPACK_ENCODER_STREAM_ERROR.
""".
-spec encoder_instructions(binary(), roadrunner_qpack_table:t()) ->
    {ok, roadrunner_qpack_table:t(), binary()} | {error, instruction_error()}.
encoder_instructions(Data, Table) ->
    case encoder_instruction(Data, Table) of
        {ok, Table1, Rest} -> encoder_instructions(Rest, Table1);
        more -> pending_instruction(Data, Table);
        {error, _} = Error -> Error
    end.

%% A partial instruction waits for the rest of its bytes, but only up to the
%% size a valid one can reach: its entry fits the capacity, a Huffman-coded
%% string is at most 30/8 of its decoded length (RFC 7541 Appendix B codes
%% are 5 to 30 bits), and its integers take a few bytes more. So a peer
%% cannot make the connection buffer an instruction without bound.
-spec pending_instruction(binary(), roadrunner_qpack_table:t()) ->
    {ok, roadrunner_qpack_table:t(), binary()} | {error, instruction_error()}.
pending_instruction(Data, Table) ->
    case byte_size(Data) > 4 * roadrunner_qpack_table:capacity(Table) + 64 of
        true -> {error, {qpack, instruction_too_large}};
        false -> {ok, Table, Data}
    end.

%% One encoder instruction, `more` when its bytes have not all arrived.
-spec encoder_instruction(binary(), roadrunner_qpack_table:t()) ->
    {ok, roadrunner_qpack_table:t(), binary()} | more | {error, instruction_error()}.
encoder_instruction(<<1:1, T:1, Index:6, Rest/binary>>, Table) ->
    %% 1Txxxxxx: Insert with Name Reference (§4.3.2), the name from the
    %% static table (T = 1) or the dynamic one by relative index (T = 0).
    maybe
        {ok, NameIndex, AfterIndex} ?= stream_integer(Index, 16#3F, Rest),
        {ok, Name} ?= insert_name(T, NameIndex, Table),
        {ok, Value, AfterValue} ?= stream_string(AfterIndex),
        insert_entry(Name, Value, Table, AfterValue)
    end;
encoder_instruction(<<2#01:2, H:1, Len:5, Rest/binary>>, Table) ->
    %% 01Hxxxxx: Insert with Literal Name (§4.3.3), a 6-bit prefix name
    %% string then the value string.
    maybe
        {ok, NameLen, AfterLen} ?= stream_integer(Len, 16#1F, Rest),
        {ok, Name, AfterName} ?= stream_take(H, NameLen, AfterLen),
        {ok, Value, AfterValue} ?= stream_string(AfterName),
        insert_entry(Name, Value, Table, AfterValue)
    end;
encoder_instruction(<<2#001:3, Prefix:5, Rest/binary>>, Table) ->
    %% 001xxxxx: Set Dynamic Table Capacity (§4.3.1).
    maybe
        {ok, Capacity, After} ?= stream_integer(Prefix, 16#1F, Rest),
        {ok, Table1} ?= table_result(roadrunner_qpack_table:set_capacity(Capacity, Table)),
        {ok, Table1, After}
    end;
encoder_instruction(<<2#000:3, Index:5, Rest/binary>>, Table) ->
    %% 000xxxxx: Duplicate (§4.3.4) the entry at a relative index.
    maybe
        {ok, Relative, After} ?= stream_integer(Index, 16#1F, Rest),
        {ok, {Name, Value}} ?= relative_entry(Relative, Table),
        insert_entry(Name, Value, Table, After)
    end;
encoder_instruction(<<>>, _Table) ->
    more.

%% The name an Insert with Name Reference takes: a static entry's (T = 1)
%% or, by relative index, a dynamic entry's (T = 0), where 0 is the newest
%% (§3.2.5).
-spec insert_name(0..1, non_neg_integer(), roadrunner_qpack_table:t()) ->
    {ok, binary()} | {error, instruction_error()}.
insert_name(1, Index, _Table) ->
    static_name(Index);
insert_name(0, Index, Table) ->
    maybe
        {ok, {Name, _}} ?= relative_entry(Index, Table),
        {ok, Name}
    end.

-spec relative_entry(non_neg_integer(), roadrunner_qpack_table:t()) ->
    {ok, header()} | {error, instruction_error()}.
relative_entry(Index, Table) ->
    case roadrunner_qpack_table:relative(Index, Table) of
        {ok, _} = Ok -> Ok;
        error -> {error, {qpack, invalid_dynamic_index, Index}}
    end.

-spec insert_entry(binary(), binary(), roadrunner_qpack_table:t(), binary()) ->
    {ok, roadrunner_qpack_table:t(), binary()} | {error, instruction_error()}.
insert_entry(Name, Value, Table, Rest) ->
    maybe
        {ok, Table1} ?= table_result(roadrunner_qpack_table:insert(Name, Value, Table)),
        {ok, Table1, Rest}
    end.

-spec table_result({ok, roadrunner_qpack_table:t()} | {error, atom()}) ->
    {ok, roadrunner_qpack_table:t()} | {error, instruction_error()}.
table_result({ok, _} = Ok) -> Ok;
table_result({error, Reason}) -> {error, {qpack, Reason}}.

%% A prefixed integer (§4.1.1) on the encoder stream, which may end in the
%% middle of one: `more` while its continuation bytes are still coming.
%% Past 62 bits (nine continuation bytes) it is an error.
-spec stream_integer(non_neg_integer(), pos_integer(), binary()) ->
    {ok, non_neg_integer(), binary()} | more | {error, instruction_error()}.
stream_integer(Max, Max, Rest) ->
    stream_continuation(Rest, Max, 0);
stream_integer(Prefix, _Max, Rest) ->
    {ok, Prefix, Rest}.

-spec stream_continuation(binary(), non_neg_integer(), non_neg_integer()) ->
    {ok, non_neg_integer(), binary()} | more | {error, instruction_error()}.
stream_continuation(<<0:1, Bits:7, Rest/binary>>, I, Shift) ->
    {ok, I + (Bits bsl Shift), Rest};
stream_continuation(<<1:1, Bits:7, Rest/binary>>, I, Shift) when Shift < 56 ->
    stream_continuation(Rest, I + (Bits bsl Shift), Shift + 7);
stream_continuation(<<>>, _I, _Shift) ->
    more;
stream_continuation(_Rest, _I, _Shift) ->
    {error, {qpack, bad_integer}}.

%% An 8-bit prefix string literal (§4.1.2) on the encoder stream.
-spec stream_string(binary()) -> {ok, binary(), binary()} | more | {error, instruction_error()}.
stream_string(<<H:1, Len:7, Rest/binary>>) ->
    maybe
        {ok, Length, After} ?= stream_integer(Len, 16#7F, Rest),
        stream_take(H, Length, After)
    end;
stream_string(<<>>) ->
    more.

-spec stream_take(0..1, non_neg_integer(), binary()) ->
    {ok, binary(), binary()} | more | {error, instruction_error()}.
stream_take(H, Len, Bin) ->
    case Bin of
        <<Str:Len/binary, Rest/binary>> ->
            maybe
                {ok, Value} ?= string_value(H, Str),
                {ok, Value, Rest}
            end;
        _ ->
            more
    end.

%% =============================================================================
%% Decoder stream (RFC 9204 §4.4)
%% =============================================================================

-doc "A Section Acknowledgment (RFC 9204 §4.4.1) for a field section decoded on `StreamId`.".
-spec section_acknowledgment(non_neg_integer()) -> iodata().
section_acknowledgment(StreamId) ->
    roadrunner_http2_hpack:encode_integer(7, 2#10000000, StreamId).

-doc "A Stream Cancellation (RFC 9204 §4.4.2) for a stream abandoned before its field sections were all decoded.".
-spec stream_cancellation(non_neg_integer()) -> iodata().
stream_cancellation(StreamId) ->
    roadrunner_http2_hpack:encode_integer(6, 2#01000000, StreamId).

-doc "An Insert Count Increment (RFC 9204 §4.4.3) of `Increment`, which is never 0.".
-spec insert_count_increment(pos_integer()) -> iodata().
insert_count_increment(Increment) ->
    roadrunner_http2_hpack:encode_integer(6, 2#00000000, Increment).

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
    {~"age", ~"0"};
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
static_full_match(~"age", ~"0") ->
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
static_name_match(~"age") -> 2;
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
