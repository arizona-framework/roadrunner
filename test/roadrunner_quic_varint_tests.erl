-module(roadrunner_quic_varint_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% RFC 9000 Appendix A.1 fixed vectors — the authority.
%%
%% The four worked examples plus the §16 two-byte "151" example. Encoding
%% is minimal-length, so each value has exactly one valid binary.
%% =============================================================================

rfc_a1_one_byte_vector_test() ->
    %% 37 -> 0x25
    ?assertEqual(<<16#25>>, roadrunner_quic_varint:encode(37)),
    ?assertEqual({ok, 37, <<>>}, roadrunner_quic_varint:decode(<<16#25>>)).

rfc_a1_two_byte_vector_test() ->
    %% 15293 -> 0x7b 0xbd
    ?assertEqual(<<16#7b, 16#bd>>, roadrunner_quic_varint:encode(15293)),
    ?assertEqual({ok, 15293, <<>>}, roadrunner_quic_varint:decode(<<16#7b, 16#bd>>)).

rfc_a1_four_byte_vector_test() ->
    %% 494878333 -> 0x9d 0x7f 0x3e 0x7d
    Bytes = <<16#9d, 16#7f, 16#3e, 16#7d>>,
    ?assertEqual(Bytes, roadrunner_quic_varint:encode(494878333)),
    ?assertEqual({ok, 494878333, <<>>}, roadrunner_quic_varint:decode(Bytes)).

rfc_a1_eight_byte_vector_test() ->
    %% 151288809941952652 -> 0xc2 0x19 0x7c 0x5e 0xff 0x14 0xe8 0x8c
    Bytes = <<16#c2, 16#19, 16#7c, 16#5e, 16#ff, 16#14, 16#e8, 16#8c>>,
    ?assertEqual(Bytes, roadrunner_quic_varint:encode(151288809941952652)),
    ?assertEqual({ok, 151288809941952652, <<>>}, roadrunner_quic_varint:decode(Bytes)).

rfc_two_byte_151_test() ->
    %% RFC 9000 §16 worked example: 151 is two-byte 0x40 0x97 (NOT 0x40b7).
    ?assertEqual(<<16#40, 16#97>>, roadrunner_quic_varint:encode(151)),
    ?assertEqual({ok, 151, <<>>}, roadrunner_quic_varint:decode(<<16#40, 16#97>>)).

%% =============================================================================
%% Length-class boundaries — cover every encode clause at its edges.
%% =============================================================================

encode_class_boundaries_test() ->
    %% Each clause's first and last value, so the minimal-length selection
    %% (first matching clause wins) is exercised at every boundary.
    ?assertEqual(<<0:2, 0:6>>, roadrunner_quic_varint:encode(0)),
    ?assertEqual(<<0:2, 63:6>>, roadrunner_quic_varint:encode(63)),
    ?assertEqual(<<1:2, 64:14>>, roadrunner_quic_varint:encode(64)),
    ?assertEqual(<<1:2, 16383:14>>, roadrunner_quic_varint:encode(16383)),
    ?assertEqual(<<2:2, 16384:30>>, roadrunner_quic_varint:encode(16384)),
    ?assertEqual(<<2:2, 1073741823:30>>, roadrunner_quic_varint:encode(1073741823)),
    ?assertEqual(<<3:2, 1073741824:62>>, roadrunner_quic_varint:encode(1073741824)),
    ?assertEqual(
        <<3:2, 4611686018427387903:62>>,
        roadrunner_quic_varint:encode(4611686018427387903)
    ).

%% A value beyond 2^62-1 has no encoding (function_clause, let it crash).
encode_above_max_crashes_test() ->
    ?assertError(function_clause, roadrunner_quic_varint:encode(4611686018427387904)).

%% =============================================================================
%% decode/1 — trailing bytes, incomplete buffers, empty buffer.
%% =============================================================================

decode_keeps_trailing_bytes_test() ->
    ?assertEqual(
        {ok, 37, <<16#ff, 16#ee>>}, roadrunner_quic_varint:decode(<<16#25, 16#ff, 16#ee>>)
    ).

decode_incomplete_returns_more_test() ->
    %% First byte selects the 8-byte class but only 3 bytes are buffered.
    ?assertEqual({more, 5}, roadrunner_quic_varint:decode(<<3:2, 0:22>>)),
    %% Two-byte class, one byte buffered.
    ?assertEqual({more, 1}, roadrunner_quic_varint:decode(<<1:2, 0:6>>)),
    %% Four-byte class, two bytes buffered.
    ?assertEqual({more, 2}, roadrunner_quic_varint:decode(<<2:2, 0:14>>)).

decode_empty_returns_more_test() ->
    ?assertEqual({more, 1}, roadrunner_quic_varint:decode(<<>>)).

%% =============================================================================
%% Differential oracle vs the `quic` dep (kept as a test-profile dep).
%% =============================================================================

%% Encode is byte-for-byte identical (both emit the minimal form).
oracle_encode_matches_dep_test() ->
    [
        ?assertEqual(quic_varint:encode(V), roadrunner_quic_varint:encode(V))
     || V <- oracle_values()
    ].

%% Cross-decode: the dep yields {V, Rest}; the native form is {ok, V, Rest}.
%% Decode each dep-encoded value and assert the value + remainder agree.
oracle_decode_matches_dep_test() ->
    [
        begin
            Bin = quic_varint:encode(V),
            {DepV, DepRest} = quic_varint:decode(Bin),
            ?assertEqual({ok, DepV, DepRest}, roadrunner_quic_varint:decode(Bin))
        end
     || V <- oracle_values()
    ].

oracle_values() ->
    [
        0,
        37,
        63,
        64,
        151,
        15293,
        16383,
        16384,
        494878333,
        1073741823,
        1073741824,
        151288809941952652,
        4611686018427387903
    ].
