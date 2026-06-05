-module(roadrunner_quic_h3_frame_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_quic_h3_frame).
%% The `quic` dep, kept as a test-profile differential oracle.
-define(DEP, quic_h3_frame).

%% =============================================================================
%% Encoding — byte-for-byte vs the dep oracle.
%%
%% The native encoders return iodata (so a large payload is never
%% recopied); flatten before comparing to the dep's binary output.
%% =============================================================================

encode_data_matches_dep_test() ->
    [
        ?assertEqual(?DEP:encode_data(P), iolist_to_binary(?M:encode_data(P)))
     || P <- [<<>>, <<"hello">>, binary:copy(<<"x">>, 1000)]
    ].

encode_headers_matches_dep_test() ->
    [
        ?assertEqual(?DEP:encode_headers(B), iolist_to_binary(?M:encode_headers(B)))
     || B <- [<<>>, <<1, 2, 3>>, binary:copy(<<0>>, 500)]
    ].

encode_goaway_matches_dep_test() ->
    [
        ?assertEqual(?DEP:encode_goaway(Id), iolist_to_binary(?M:encode_goaway(Id)))
     || Id <- [0, 4, 1000, 16383, 16384]
    ].

encode_settings_matches_dep_test() ->
    Maps = [
        #{},
        #{qpack_max_table_capacity => 0},
        #{
            qpack_max_table_capacity => 0,
            qpack_blocked_streams => 0,
            max_field_section_size => 65536
        },
        #{enable_connect_protocol => 1},
        %% Unknown integer id round-trips through the integer setting_to_id clause.
        #{16#0b => 5}
    ],
    [
        ?assertEqual(?DEP:encode_settings(M), iolist_to_binary(?M:encode_settings(M)))
     || M <- Maps
    ].

encode_stream_type_matches_dep_test() ->
    [
        ?assertEqual(?DEP:encode_stream_type(T), ?M:encode_stream_type(T))
     || T <- [control, qpack_encoder, qpack_decoder, push, 16#21, 0]
    ].

%% =============================================================================
%% Decoding — equivalence vs the dep on complete frames.
%% =============================================================================

decode_complete_frames_match_dep_test() ->
    Frames = [
        ?DEP:encode_data(<<"body">>),
        ?DEP:encode_headers(<<9, 8, 7>>),
        ?DEP:encode_goaway(12),
        ?DEP:encode_settings(#{qpack_max_table_capacity => 0, max_field_section_size => 65536}),
        ?DEP:encode_max_push_id(3),
        ?DEP:encode_cancel_push(7),
        ?DEP:encode_push_promise(5, <<1, 2>>)
    ],
    [?assertEqual(?DEP:decode(F), ?M:decode(F)) || F <- Frames].

decode_keeps_trailing_bytes_test() ->
    Frame = iolist_to_binary(?M:encode_data(<<"ab">>)),
    Buf = <<Frame/binary, 16#ff, 16#ee>>,
    ?assertEqual({ok, {data, <<"ab">>}, <<16#ff, 16#ee>>}, ?M:decode(Buf)),
    ?assertEqual(?DEP:decode(Buf), ?M:decode(Buf)).

decode_unknown_grease_frame_test() ->
    %% Type 0x21 (a reserved/grease type) with a 2-byte payload.
    Buf = <<16#21, 2, 16#aa, 16#bb>>,
    ?assertEqual({ok, {unknown, 16#21, <<16#aa, 16#bb>>}, <<>>}, ?M:decode(Buf)),
    ?assertEqual(?DEP:decode(Buf), ?M:decode(Buf)).

decode_h2_reserved_frames_test() ->
    [
        begin
            Buf = <<Type, 0>>,
            ?assertEqual({error, {h2_reserved_frame, Type}}, ?M:decode(Buf)),
            ?assertEqual(?DEP:decode(Buf), ?M:decode(Buf))
        end
     || Type <- [16#02, 16#06, 16#08, 16#09]
    ].

decode_oversized_frame_test() ->
    %% A Length varint past the 1 MiB cap is rejected before allocation.
    Oversized = 16#100000 + 1,
    Buf = <<0, (roadrunner_quic_varint:encode(Oversized))/binary>>,
    ?assertMatch({error, {frame_error, oversized, Oversized}}, ?M:decode(Buf)).

decode_incomplete_returns_more_test() ->
    %% Empty buffer, a partial header, and a complete header with a
    %% short payload all report {more, _}.
    ?assertMatch({more, _}, ?M:decode(<<>>)),
    ?assertMatch({more, _}, ?M:decode(<<16#40>>)),
    %% DATA type 0, length 5, but only 2 payload bytes buffered.
    ?assertEqual({more, 3}, ?M:decode(<<0, 5, 1, 2>>)),
    %% Type present, length varint truncated (needs more).
    ?assertMatch({more, _}, ?M:decode(<<0, 16#40>>)).

decode_single_id_extra_and_malformed_test() ->
    %% GOAWAY (type 0x07) whose payload carries a trailing byte after the id.
    Extra = <<16#07, 2, 5, 16#ff>>,
    ?assertEqual({error, {frame_error, goaway, extra_data}}, ?M:decode(Extra)),
    %% MAX_PUSH_ID with a truncated (multi-byte) varint as its whole payload.
    Malformed = <<16#0d, 1, 16#40>>,
    ?assertEqual({error, {frame_error, max_push_id, malformed_varint}}, ?M:decode(Malformed)).

decode_push_promise_malformed_test() ->
    %% PUSH_PROMISE (type 5) whose payload is a truncated push-id varint.
    Buf = <<16#05, 1, 16#40>>,
    ?assertEqual({error, {frame_error, push_promise, malformed_varint}}, ?M:decode(Buf)).

%% =============================================================================
%% SETTINGS payload edge cases.
%% =============================================================================

decode_settings_forbidden_and_duplicate_test() ->
    %% Each HTTP/2 setting forbidden in HTTP/3 (RFC 9114 §7.2.4.1):
    %% ENABLE_PUSH, MAX_CONCURRENT_STREAMS, INITIAL_WINDOW_SIZE, MAX_FRAME_SIZE.
    [
        begin
            Forbidden = <<16#04, 2, Id, 0>>,
            ?assertEqual(
                {error, {frame_error, settings, {forbidden_setting, Id}}}, ?M:decode(Forbidden)
            ),
            ?assertEqual(?DEP:decode(Forbidden), ?M:decode(Forbidden))
        end
     || Id <- [16#02, 16#03, 16#04, 16#05]
    ],
    %% Duplicate identifier 0x06 (max_field_section_size).
    Dup = <<16#04, 4, 16#06, 1, 16#06, 2>>,
    ?assertEqual(
        {error, {frame_error, settings, {duplicate_setting, max_field_section_size}}},
        ?M:decode(Dup)
    ),
    ?assertEqual(?DEP:decode(Dup), ?M:decode(Dup)).

decode_settings_malformed_pairs_test() ->
    %% SETTINGS payload with an id but a truncated value varint.
    BadValue = <<16#04, 2, 16#06, 16#40>>,
    ?assertEqual({error, {frame_error, settings, malformed_varint}}, ?M:decode(BadValue)),
    %% SETTINGS payload that is a single truncated id varint.
    BadId = <<16#04, 1, 16#40>>,
    ?assertEqual({error, {frame_error, settings, malformed_varint}}, ?M:decode(BadId)).

decode_settings_unknown_id_kept_as_integer_test() ->
    %% Unknown id 0x0b survives as its integer key (RFC 9114 §7.2.4.1).
    Buf = iolist_to_binary(?M:encode_settings(#{16#0b => 9})),
    ?assertEqual({ok, {settings, #{16#0b => 9}}, <<>>}, ?M:decode(Buf)).

decode_settings_all_standard_ids_test() ->
    %% Every id that maps to an atom (ids 1, 6, 7, 8) decodes to its atom key.
    Buf = iolist_to_binary(
        ?M:encode_settings(#{
            qpack_max_table_capacity => 0,
            max_field_section_size => 65536,
            qpack_blocked_streams => 0,
            enable_connect_protocol => 1
        })
    ),
    Expected = #{
        qpack_max_table_capacity => 0,
        max_field_section_size => 65536,
        qpack_blocked_streams => 0,
        enable_connect_protocol => 1
    },
    ?assertEqual({ok, {settings, Expected}, <<>>}, ?M:decode(Buf)),
    ?assertEqual(?DEP:decode(Buf), ?M:decode(Buf)).

%% =============================================================================
%% decode_stream_type/1 — all classes vs the dep.
%% =============================================================================

decode_stream_type_matches_dep_test() ->
    [
        begin
            Bin = ?DEP:encode_stream_type(T),
            ?assertEqual(?DEP:decode_stream_type(Bin), ?M:decode_stream_type(Bin))
        end
     || T <- [control, push, qpack_encoder, qpack_decoder, 16#21]
    ].

decode_stream_type_more_test() ->
    ?assertMatch({more, _}, ?M:decode_stream_type(<<>>)),
    %% A multi-byte stream-type varint that is not fully buffered.
    ?assertMatch({more, _}, ?M:decode_stream_type(<<16#40>>)).
