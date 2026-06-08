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
    %% A Required Insert Count > 0 references the dynamic table we never enable.
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
%% Helpers
%% =============================================================================

%% `roadrunner_qpack:encode/1` returns iodata (it is framed and sent as
%% iodata in production); flatten it here, where the dep oracle and the
%% native decoder both want the on-wire binary.
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
    iolist_to_binary(roadrunner_http2_hpack:encode_integer(4, 2#01010000, Index)).
