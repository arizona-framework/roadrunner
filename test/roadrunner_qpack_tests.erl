-module(roadrunner_qpack_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_qpack).

%% =============================================================================
%% Static table — full clause coverage via the public API.
%% =============================================================================

%% Decode an indexed-static field line for every index 0..98 (exercising each
%% static_entry clause), then re-encode the decoded entry and confirm it round
%% trips. Concrete entries re-encode as an Indexed Field Line (exercising the
%% static_full_match clauses); name-only entries (empty value) re-encode as a
%% Literal with Name Reference.
roundtrip_every_static_index_test() ->
    [
        begin
            {ok, [Entry]} = ?M:decode(indexed_section(I)),
            ?assertEqual({ok, [Entry]}, ?M:decode(enc([Entry])))
        end
     || I <- lists:seq(0, 98)
    ].

%% For every distinct static name, a header carrying that name with a value
%% absent from the table encodes as a Literal with Name Reference, exercising
%% each static_name_match clause.
name_reference_every_static_name_test() ->
    Names = lists:usort([
        element(1, Entry)
     || I <- lists:seq(0, 98), {ok, [Entry]} <- [?M:decode(indexed_section(I))]
    ]),
    [
        ?assertEqual(
            {ok, [{Name, ~"zzz-not-in-table"}]}, ?M:decode(enc([{Name, ~"zzz-not-in-table"}]))
        )
     || Name <- Names
    ].

%% RFC 9204 Appendix A index 2 is `age: 0`; a full match must encode as the
%% bare index-2 Indexed Field Line.
static_index_2_is_age_test() ->
    ?assertEqual({ok, [{~"age", ~"0"}]}, ?M:decode(indexed_section(2))),
    ?assertEqual(indexed_section(2), enc([{~"age", ~"0"}])).

%% RFC 9204 §4.5.4: a Literal with Name Reference may set N (never index,
%% `01N1xxxx`); it decodes the same as with N clear.
name_reference_never_indexed_test() ->
    ?assertEqual({ok, [{~":path", ~"/ab"}]}, ?M:decode(<<0, 0, 16#71, 3, "/ab">>)).

%% A name absent from the table encodes as a Literal with Literal Name.
literal_literal_name_test() ->
    H = [{~"x-totally-unknown", ~"value"}],
    ?assertEqual({ok, H}, ?M:decode(enc(H))).

%% =============================================================================
%% Encode string: Huffman vs raw branch.
%% =============================================================================

encode_string_branches_test() ->
    %% A long repetitive value compresses (Huffman branch); a 1-char value
    %% does not (raw branch). Both round-trip.
    Huffy = [{~"x-h", binary:copy(~"a", 40)}],
    Raw = [{~"x-r", ~"q"}],
    ?assertEqual({ok, Huffy}, ?M:decode(enc(Huffy))),
    ?assertEqual({ok, Raw}, ?M:decode(enc(Raw))).

%% =============================================================================
%% Decode error paths.
%% =============================================================================

decode_non_zero_ric_test() ->
    %% A Required Insert Count > 0 needs the dynamic table, which the
    %% static-only `decode/1` does not take (`decode/2` does).
    ?assertEqual({error, {qpack, dynamic_table_required}}, ?M:decode(<<5, 0, 16#80>>)).

decode_truncated_prefix_test() ->
    ?assertEqual({error, {qpack, truncated}}, ?M:decode(<<0>>)),
    ?assertEqual({error, {qpack, truncated}}, ?M:decode(<<>>)).

decode_bad_delta_base_test() ->
    %% RIC byte 0, then a Delta Base varint (7-bit prefix) that promises a
    %% continuation byte that never arrives.
    ?assertEqual({error, {qpack, bad_integer}}, ?M:decode(<<0, 16#FF>>)).

decode_dynamic_field_line_test() ->
    %% 0x80 = 10xxxxxx, a dynamic Indexed Field Line.
    ?assertEqual({error, {qpack, dynamic_field_line, 16#80}}, ?M:decode(<<0, 0, 16#80>>)).

decode_bad_index_varint_test() ->
    %% 0xFF = 11xxxxxx (indexed static) whose 6-bit index promises a
    %% continuation byte that never arrives.
    ?assertEqual({error, {qpack, bad_integer}}, ?M:decode(<<0, 0, 16#FF>>)).

decode_invalid_static_index_test() ->
    %% Indexed static field line referencing index 200 (out of range).
    Section = indexed_section(200),
    ?assertEqual({error, {qpack, invalid_static_index, 200}}, ?M:decode(Section)),
    %% Name-reference field line referencing name index 200.
    NameRef = <<0, 0, (name_ref_prefix(200))/binary, 0>>,
    ?assertEqual({error, {qpack, invalid_static_index, 200}}, ?M:decode(NameRef)).

decode_truncated_value_string_test() ->
    %% Name reference index 0, then no value-string bytes at all.
    NoValue = <<0, 0, (name_ref_prefix(0))/binary>>,
    ?assertEqual({error, {qpack, truncated}}, ?M:decode(NoValue)),
    %% Value string claims length 5 but only 2 bytes follow.
    ShortValue = <<0, 0, (name_ref_prefix(0))/binary, 16#05, 1, 2>>,
    ?assertEqual({error, {qpack, truncated}}, ?M:decode(ShortValue)).

decode_truncated_huffman_value_test() ->
    %% Static name ref to `:path` (index 1), then a Huffman value whose
    %% declared 10 octets are not all there.
    ?assertEqual({error, {qpack, truncated}}, ?M:decode(<<0, 0, 16#51, 16#8A, 1, 2>>)).

decode_bad_huffman_value_test() ->
    %% Value string H=1, length 1, byte 0xFF: 8 one-bits is invalid Huffman
    %% padding (RFC 7541 §5.2).
    Bad = <<0, 0, (name_ref_prefix(0))/binary, 2#10000001, 16#FF>>,
    ?assertEqual({error, {qpack, huffman}}, ?M:decode(Bad)).

decode_second_field_line_error_propagates_test() ->
    %% A valid Indexed Field Line (:method GET) followed by a dynamic byte:
    %% the error from the recursive tail must surface.
    Section = <<0, 0, (iolist_to_binary(indexed_prefix(17)))/binary, 16#80>>,
    ?assertEqual({error, {qpack, dynamic_field_line, 16#80}}, ?M:decode(Section)).

%% =============================================================================
%% Field lines matched in the clause heads vs through decode_field_line/2.
%% =============================================================================

%% Integers within their prefix or one continuation byte take the inline
%% clauses; longer ones take `decode_field_line/1`. Every line form decodes
%% the same either way, with N set or clear, plain or Huffman.
field_line_lengths_agree_test() ->
    [
        begin
            Name = binary:copy(~"n", NameLen),
            Value = binary:copy(~"v", ValueLen),
            NameRef = <<(name_ref_prefix(1, N))/binary, (str(H, Value))/binary>>,
            ?assertEqual({ok, [{~":path", Value}]}, ?M:decode(<<0, 0, NameRef/binary>>)),
            LitName = <<(literal_name(N, H, Name))/binary, (str(H, Value))/binary>>,
            ?assertEqual({ok, [{Name, Value}]}, ?M:decode(<<0, 0, LitName/binary>>))
        end
     || N <- [0, 1],
        H <- [0, 1],
        NameLen <- [1, 6, 7, 30, 134, 135, 300],
        ValueLen <- [0, 126, 127, 300]
    ],
    %% Static indexes past the 6-bit prefix (one continuation byte).
    ?assertEqual({ok, [{~"x-frame-options", ~"sameorigin"}]}, ?M:decode(indexed_section(98))).

inline_field_line_errors_test() ->
    BadHuff = <<2#10000001, 16#FF>>,
    ?assertEqual(
        {error, {qpack, invalid_static_index, 100}}, ?M:decode(indexed_section(100))
    ),
    ?assertEqual(
        {error, {qpack, invalid_static_index, 100}},
        ?M:decode(<<0, 0, (name_ref_prefix(100))/binary, 1, "x">>)
    ),
    ?assertEqual(
        {error, {qpack, huffman}}, ?M:decode(<<0, 0, (name_ref_prefix(1))/binary, BadHuff/binary>>)
    ),
    ?assertEqual(
        {error, {qpack, huffman}}, ?M:decode(<<0, 0, 2#00101001, 16#FF, 1, "x">>)
    ),
    ?assertEqual(
        {error, {qpack, huffman}}, ?M:decode(<<0, 0, 2#00100001, "x", BadHuff/binary>>)
    ),
    %% A good line, then a dynamic one: the error from the tail surfaces.
    [
        ?assertEqual(
            {error, {qpack, dynamic_field_line, 16#80}}, ?M:decode(<<0, 0, Line/binary, 16#80>>)
        )
     || Line <- [
            indexed_prefix_bin(98),
            <<(name_ref_prefix(1))/binary, 1, "x">>,
            <<(name_ref_prefix(1))/binary, (str(0, binary:copy(~"v", 200)))/binary>>,
            <<2#00100001, "x", 1, "y">>,
            <<(literal_name(0, 0, binary:copy(~"n", 300)))/binary, 1, "y">>
        ]
    ].

%% =============================================================================
%% Dynamic table: RFC 9204 Appendix B, run in order on one table.
%% =============================================================================

appendix_b_test() ->
    Table0 = roadrunner_qpack_table:new(4096),
    %% B.1: a static-only section decodes against the table as it is, with
    %% Required Insert Count 0 (no acknowledgment owed).
    ?assertEqual(
        {ok, [{~":path", ~"/index.html"}], 0},
        ?M:decode(hex("0000 510b 2f69 6e64 6578 2e68 746d 6c"), Table0)
    ),
    %% B.2: capacity 220, two inserts with static name references, then a
    %% section of two post-base references (Required Insert Count 2, Base 0)
    %% and its acknowledgment.
    {ok, Table1, <<>>} = ?M:encoder_instructions(
        hex(
            "3fbd01 c00f 7777 772e 6578 616d 706c 652e 636f 6d"
            " c10c 2f73 616d 706c 652f 7061 7468"
        ),
        Table0
    ),
    ?assertEqual(220, roadrunner_qpack_table:capacity(Table1)),
    ?assertEqual(
        {ok, [{~":authority", ~"www.example.com"}, {~":path", ~"/sample/path"}], 2},
        ?M:decode(hex("0381 10 11"), Table1)
    ),
    ?assertEqual(hex("84"), iolist_to_binary(?M:section_acknowledgment(4))),
    %% B.3: a speculative insert with a literal name, and the Insert Count
    %% Increment for it.
    {ok, Table2, <<>>} = ?M:encoder_instructions(
        hex("4a63 7573 746f 6d2d 6b65 790c 6375 7374 6f6d 2d76 616c 7565"), Table1
    ),
    ?assertEqual(
        {ok, {~"custom-key", ~"custom-value"}}, roadrunner_qpack_table:absolute(2, Table2)
    ),
    ?assertEqual(hex("01"), iolist_to_binary(?M:insert_count_increment(1))),
    %% B.4: a Duplicate of relative index 2 (absolute 0), then a section
    %% (Required Insert Count 4, Base 4) mixing dynamic and static lines,
    %% and the Stream Cancellation the example sends instead of decoding it.
    {ok, Table3, <<>>} = ?M:encoder_instructions(hex("02"), Table2),
    ?assertEqual(
        {ok,
            [
                {~":authority", ~"www.example.com"},
                {~":path", ~"/"},
                {~"custom-key", ~"custom-value"}
            ],
            4},
        ?M:decode(hex("0500 80 c1 81"), Table3)
    ),
    ?assertEqual(hex("48"), iolist_to_binary(?M:stream_cancellation(8))),
    %% B.5: an insert with a dynamic name reference (relative 1, absolute 2)
    %% evicts the oldest entry, absolute 0.
    {ok, Table4, <<>>} = ?M:encoder_instructions(
        hex("810d 6375 7374 6f6d 2d76 616c 7565 32"), Table3
    ),
    ?assertEqual(
        {ok, {~"custom-key", ~"custom-value2"}}, roadrunner_qpack_table:absolute(4, Table4)
    ),
    ?assertEqual(error, roadrunner_qpack_table:absolute(0, Table4)),
    %% A section referencing the evicted entry (Required Insert Count 5,
    %% Base 5, relative index 4 = absolute 0) fails (RFC 9204 §2.2.3).
    ?assertEqual(
        {error, {qpack, invalid_dynamic_index, 0}}, ?M:decode(hex("0600 84"), Table4)
    ).

%% Every split of the B.2 encoder-stream bytes into two chunks applies the
%% same: an instruction cut short waits for the next chunk.
encoder_instructions_split_test() ->
    Bytes = hex(
        "3fbd01 c00f 7777 772e 6578 616d 706c 652e 636f 6d"
        " c10c 2f73 616d 706c 652f 7061 7468"
    ),
    {ok, Whole, <<>>} = ?M:encoder_instructions(Bytes, roadrunner_qpack_table:new(4096)),
    [
        begin
            <<First:N/binary, Second/binary>> = Bytes,
            {ok, Table1, Pending} = ?M:encoder_instructions(
                First, roadrunner_qpack_table:new(4096)
            ),
            ?assertEqual(
                {ok, Whole, <<>>},
                ?M:encoder_instructions(<<Pending/binary, Second/binary>>, Table1)
            )
        end
     || N <- lists:seq(0, byte_size(Bytes))
    ].

encoder_huffman_strings_test() ->
    %% Insert with Literal Name with both strings Huffman coded (H = 1).
    Name = roadrunner_http2_hpack_huffman:encode(~"x-custom"),
    Value = roadrunner_http2_hpack_huffman:encode(~"some value"),
    Instruction = <<
        (iolist_to_binary(roadrunner_http2_hpack:encode_integer(5, 2#01100000, byte_size(Name))))/binary,
        Name/binary,
        (str_huffman(Value))/binary
    >>,
    {ok, Table, <<>>} = ?M:encoder_instructions(<<16#3F, 16#E1, 16#1F, Instruction/binary>>, new()),
    ?assertEqual({ok, {~"x-custom", ~"some value"}}, roadrunner_qpack_table:relative(0, Table)).

encoder_instruction_errors_test() ->
    Cap = <<16#3F, 16#E1, 16#1F>>,
    Errors = [
        %% A capacity over the advertised 4096 (§4.3.1).
        {capacity_exceeded, <<16#3F, 16#E2, 16#1F>>},
        %% An entry that does not fit the capacity (§3.2.2): capacity 0.
        {entry_too_large, <<16#C0, 16#01, $x>>},
        %% A capacity integer past 62 bits.
        {bad_integer, <<16#3F, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF>>},
        %% A value string that is not valid Huffman (EOS padding of 0s).
        {huffman, <<Cap/binary, 16#C0, 16#81, 16#00>>}
    ],
    [
        ?assertMatch({error, {qpack, Reason}}, ?M:encoder_instructions(Bytes, new()))
     || {Reason, Bytes} <- Errors
    ].

encoder_instruction_bad_references_test() ->
    Cap = <<16#3F, 16#E1, 16#1F>>,
    %% Insert with Name Reference to static index 99, past the table (§3.1),
    %% and to a dynamic entry that is not there; a Duplicate of one (§4.3.4).
    ?assertEqual(
        {error, {qpack, invalid_dynamic_index, 0}},
        ?M:encoder_instructions(<<Cap/binary, 16#80, 16#01, $x>>, new())
    ),
    ?assertEqual(
        {error, {qpack, invalid_static_index, 99}},
        ?M:encoder_instructions(<<Cap/binary, 16#FF, 16#24, 16#01, $x>>, new())
    ),
    ?assertEqual(
        {error, {qpack, invalid_dynamic_index, 0}},
        ?M:encoder_instructions(<<Cap/binary, 16#00>>, new())
    ).

encoder_pending_bound_test() ->
    %% A partial instruction may grow to what a valid one could take, 4
    %% times the capacity plus 64 bytes, and no further.
    Cap = <<16#3F, 16#01>>,
    {ok, Table, _} = ?M:encoder_instructions(Cap, new()),
    ?assertEqual(32, roadrunner_qpack_table:capacity(Table)),
    Partial = <<16#40, 16#7F, 16#FF, 16#01>>,
    Fits = <<Partial/binary, (binary:copy(~"a", 4 * 32 + 64 - byte_size(Partial)))/binary>>,
    ?assertEqual({ok, Table, Fits}, ?M:encoder_instructions(Fits, Table)),
    ?assertEqual(
        {error, {qpack, instruction_too_large}},
        ?M:encoder_instructions(<<Fits/binary, $a>>, Table)
    ).

encoder_capacity_zero_test() ->
    %% With the dynamic table off (maximum 0) the one valid instruction is
    %% a capacity of 0.
    Off = roadrunner_qpack_table:new(0),
    ?assertMatch({ok, _, <<>>}, ?M:encoder_instructions(<<16#20, 16#20>>, Off)),
    ?assertEqual(
        {error, {qpack, capacity_exceeded}}, ?M:encoder_instructions(<<16#21>>, Off)
    ).

%% RFC 9204 §4.5.1.1's example: a 100-byte table (MaxEntries 3, so the
%% count goes modulo 6) that has had 10 inserts reads an encoded 4 as a
%% Required Insert Count of 9.
required_insert_count_wraps_test() ->
    Ten = lists:foldl(
        fun(_, Acc) -> insert(~"", ~"", Acc) end, table(100), lists:seq(1, 10)
    ),
    ?assertEqual({ok, [{~"", ~""}], 9}, ?M:decode(<<4, 16#00, 16#80>>, Ten)),
    %% An encoded 2 reads as 13, past the 10 inserts: a section that has to
    %% wait for 3 more (§2.1.2).
    ?assertEqual({error, {qpack, blocked, 13}}, ?M:decode(<<2, 16#00, 16#80>>, Ten)),
    %% Past 2 * MaxEntries no encoder could have sent it.
    ?assertEqual(
        {error, {qpack, invalid_required_insert_count, 7}}, ?M:decode(<<7, 0>>, Ten)
    ).

required_insert_count_invalid_test() ->
    Empty = table(100),
    %% With no inserts an encoded 5 reads as 4, past the most the encoder
    %% could mean (inserts + MaxEntries = 3) yet within 2 * MaxEntries.
    ?assertEqual(
        {error, {qpack, invalid_required_insert_count, 4}}, ?M:decode(<<5, 0>>, Empty)
    ),
    %% An encoded 1 reads as 0, which is only ever encoded as 0.
    ?assertEqual(
        {error, {qpack, invalid_required_insert_count, 0}}, ?M:decode(<<1, 0>>, Empty)
    ),
    %% A table with no room (maximum capacity 0) takes no Required Insert
    %% Count but 0.
    ?assertEqual(
        {error, {qpack, invalid_required_insert_count, 1}},
        ?M:decode(<<1, 0>>, roadrunner_qpack_table:new(0))
    ),
    %% An integer that runs out.
    ?assertEqual({error, {qpack, bad_integer}}, ?M:decode(<<16#FF>>, Empty)).

blocked_test() ->
    %% Only the prefix is read (§2.2.1): a Required Insert Count past the
    %% inserts received blocks, one within them does not, and a prefix that
    %% does not decode is left to the decoder to report.
    Ten = lists:foldl(
        fun(_, Acc) -> insert(~"", ~"", Acc) end, table(100), lists:seq(1, 10)
    ),
    ?assertEqual({blocked, 13}, ?M:blocked(<<2, 16#00, 16#80>>, Ten)),
    ?assertEqual(ok, ?M:blocked(<<4, 16#00, 16#80>>, Ten)),
    ?assertEqual(ok, ?M:blocked(<<4>>, Ten)),
    ?assertEqual(ok, ?M:blocked(<<7, 0>>, Ten)),
    ?assertEqual(ok, ?M:blocked(<<16#FF>>, Ten)).

base_test() ->
    Table = two_entries(),
    %% Sign 1: Base = Required Insert Count - Delta Base - 1 = 2 - 0 - 1 = 1,
    %% so relative 0 is absolute 0 and post-base 0 is absolute 1.
    ?assertEqual(
        {ok, [{~"a", ~"1"}, {~"b", ~"2"}], 2}, ?M:decode(<<3, 16#80, 16#80, 16#10>>, Table)
    ),
    %% Sign 1 with Delta Base >= Required Insert Count: a negative Base.
    ?assertEqual({error, {qpack, invalid_base}}, ?M:decode(<<3, 16#82>>, Table)),
    %% Sign 0: Base = 2 + 1 = 3, relative 1 is absolute 1.
    ?assertEqual({ok, [{~"b", ~"2"}], 2}, ?M:decode(<<3, 16#01, 16#81>>, Table)),
    %% A prefix that ends before the Base, or inside it.
    ?assertEqual({error, {qpack, truncated}}, ?M:decode(<<3>>, Table)),
    ?assertEqual({error, {qpack, bad_integer}}, ?M:decode(<<3, 16#7F>>, Table)).

dynamic_name_references_test() ->
    Table = two_entries(),
    %% Literal with dynamic Name Reference (01N0, §4.5.4), relative 1 from
    %% Base 2 = absolute 0, N set; then Literal with Post-Base Name
    %% Reference (0000N, §4.5.5), post-base 0 from Base 1 = absolute 1.
    ?assertEqual(
        {ok, [{~"a", ~"x"}], 2}, ?M:decode(<<3, 16#00, 16#61, (str(0, ~"x"))/binary>>, Table)
    ),
    ?assertEqual(
        {ok, [{~"b", ~"y"}], 2},
        ?M:decode(<<3, 16#80, 16#08, (str(1, ~"y"))/binary>>, Table)
    ),
    %% A static line in a dynamic section takes the inline paths.
    ?assertEqual(
        {ok, [{~":method", ~"GET"}, {~"b", ~"2"}], 2},
        ?M:decode(<<3, 16#00, 16#D1, 16#80>>, Table)
    ).

dynamic_reference_errors_test() ->
    Table = two_entries(),
    %% Relative index past Base: a negative absolute index.
    ?assertEqual(
        {error, {qpack, invalid_dynamic_index, -1}}, ?M:decode(<<3, 16#00, 16#82>>, Table)
    ),
    %% Post-base index at the Required Insert Count (§2.2.3), indexed and
    %% as a name.
    ?assertEqual(
        {error, {qpack, invalid_dynamic_index, 2}}, ?M:decode(<<3, 16#00, 16#10>>, Table)
    ),
    ?assertEqual(
        {error, {qpack, invalid_dynamic_index, 2}},
        ?M:decode(<<3, 16#00, 16#00, (str(0, ~"v"))/binary>>, Table)
    ),
    %% A dynamic name reference whose index runs out, or whose value does.
    ?assertEqual({error, {qpack, bad_integer}}, ?M:decode(<<3, 16#00, 16#4F>>, Table)),
    ?assertEqual({error, {qpack, truncated}}, ?M:decode(<<3, 16#00, 16#41>>, Table)),
    ?assertEqual({error, {qpack, bad_integer}}, ?M:decode(<<3, 16#00, 16#BF>>, Table)),
    ?assertEqual({error, {qpack, bad_integer}}, ?M:decode(<<3, 16#00, 16#1F>>, Table)),
    ?assertEqual({error, {qpack, bad_integer}}, ?M:decode(<<3, 16#00, 16#07>>, Table)),
    %% An entry the table has evicted (§2.2.3): capacity 34 keeps only the
    %% newest of the two.
    {ok, One} = roadrunner_qpack_table:set_capacity(34, Table),
    ?assertEqual(
        {error, {qpack, invalid_dynamic_index, 0}}, ?M:decode(<<3, 16#00, 16#81>>, One)
    ).

decode_with_table_static_errors_test() ->
    %% A section with Required Insert Count 0 is the static decoder's,
    %% errors included; an empty one has no prefix.
    ?assertEqual(
        {error, {qpack, dynamic_field_line, 16#80}}, ?M:decode(<<0, 0, 16#80>>, new())
    ),
    ?assertEqual({error, {qpack, truncated}}, ?M:decode(<<>>, new())).

decoder_instructions_test() ->
    %% RFC 9204 §4.4: 7-, 6- and 6-bit prefixes, with continuations.
    ?assertEqual(<<16#FF, 16#01>>, iolist_to_binary(?M:section_acknowledgment(128))),
    ?assertEqual(<<16#7F, 16#01>>, iolist_to_binary(?M:stream_cancellation(64))),
    ?assertEqual(<<16#3F, 16#01>>, iolist_to_binary(?M:insert_count_increment(64))).

%% =============================================================================
%% Helpers
%% =============================================================================

%% A table advertising and set to 4096 bytes.
new() ->
    roadrunner_qpack_table:new(4096).

table(Capacity) ->
    {ok, Table} = roadrunner_qpack_table:set_capacity(
        Capacity, roadrunner_qpack_table:new(Capacity)
    ),
    Table.

insert(Name, Value, Table) ->
    {ok, Table1} = roadrunner_qpack_table:insert(Name, Value, Table),
    Table1.

%% A 4096-byte table holding `a: 1` (absolute 0) and `b: 2` (absolute 1).
two_entries() ->
    insert(~"b", ~"2", insert(~"a", ~"1", table(4096))).

%% Bytes from a hex dump as RFC 9204 Appendix B prints them.
hex(Dump) ->
    binary:decode_hex(<<<<C>> || <<C>> <= iolist_to_binary(Dump), C =/= $\s>>).

%% An 8-bit prefix string literal whose octets are already Huffman coded.
str_huffman(Encoded) ->
    <<
        (iolist_to_binary(roadrunner_http2_hpack:encode_integer(7, 2#10000000, byte_size(Encoded))))/binary,
        Encoded/binary
    >>.

%% `roadrunner_qpack:encode/1` returns iodata (it is framed and sent as
%% iodata in production); flatten it here, where the decoder wants the
%% on-wire binary.
enc(Headers) ->
    iolist_to_binary(roadrunner_qpack:encode(Headers)).

%% A field section whose single field line is an Indexed Field Line (static)
%% for `Index`.
indexed_section(Index) ->
    <<0, 0, (iolist_to_binary(indexed_prefix(Index)))/binary>>.

indexed_prefix(Index) ->
    roadrunner_http2_hpack:encode_integer(6, 2#11000000, Index).

%% The leading bytes of a Literal Field Line with Name Reference (static).
name_ref_prefix(Index) ->
    name_ref_prefix(Index, 0).

name_ref_prefix(Index, N) ->
    iolist_to_binary(roadrunner_http2_hpack:encode_integer(4, 2#01010000 bor (N bsl 5), Index)).

indexed_prefix_bin(Index) ->
    iolist_to_binary(indexed_prefix(Index)).

%% Literal with Literal Name: `001NH` + 3-bit name length, then the name.
literal_name(N, H, Name) ->
    Body = string_body(H, Name),
    Prefix = 2#00100000 bor (N bsl 4) bor (H bsl 3),
    <<
        (iolist_to_binary(roadrunner_http2_hpack:encode_integer(3, Prefix, byte_size(Body))))/binary,
        Body/binary
    >>.

%% A string: H bit + 7-bit-prefix length, then the octets.
str(H, Value) ->
    Body = string_body(H, Value),
    <<
        (iolist_to_binary(roadrunner_http2_hpack:encode_integer(7, H bsl 7, byte_size(Body))))/binary,
        Body/binary
    >>.

string_body(0, Bin) -> Bin;
string_body(1, Bin) -> roadrunner_http2_hpack_huffman:encode(Bin).
