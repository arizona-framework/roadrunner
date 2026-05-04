-module(roadrunner_http2_settings_tests).
-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% RFC 9113 §6.5 SETTINGS frame helpers — payload parsing, encode of
%% the diff-from-defaults, and the ACK frame literal.
%% =============================================================================

new_returns_default_settings_test() ->
    %% `new/0` should be the zero-argument constructor; encoding it
    %% yields no parameter records since every field equals its
    %% default.
    Default = roadrunner_http2_settings:new(),
    ?assertEqual([], iolist_to_list(roadrunner_http2_settings:encode_settings(Default))).

apply_payload_empty_returns_unchanged_test() ->
    %% Empty body is valid (RFC 9113 §6.5: "may contain any number of
    %% parameters, including zero").
    Default = roadrunner_http2_settings:new(),
    ?assertEqual({ok, Default}, roadrunner_http2_settings:apply_payload(<<>>, Default)).

apply_payload_records_update_state_test() ->
    %% Two parameter records: header_table_size=8192 (id=1),
    %% max_frame_size=32768 (id=5). Re-encoding the result must
    %% include both as diffs from the defaults.
    Payload = <<1:16, 8192:32, 5:16, 32768:32>>,
    {ok, Updated} = roadrunner_http2_settings:apply_payload(
        Payload, roadrunner_http2_settings:new()
    ),
    Encoded = iolist_to_binary(roadrunner_http2_settings:encode_settings(Updated)),
    ?assertEqual(Payload, Encoded).

apply_payload_all_known_ids_round_trip_test() ->
    %% Cover the per-id `apply_one` clauses for every known SETTINGS
    %% identifier (1..6 per RFC 9113 §6.5.2). Each value is non-default
    %% so the round-trip through encode_settings emits the same record.
    Payload = <<
        1:16,
        8192:32,
        2:16,
        0:32,
        3:16,
        100:32,
        4:16,
        32768:32,
        5:16,
        24576:32,
        6:16,
        16384:32
    >>,
    {ok, Updated} = roadrunner_http2_settings:apply_payload(
        Payload, roadrunner_http2_settings:new()
    ),
    Encoded = iolist_to_binary(roadrunner_http2_settings:encode_settings(Updated)),
    %% Sort by id is irrelevant — the wire-form is fully ordered by id.
    ?assertEqual(Payload, Encoded).

apply_payload_unknown_id_is_ignored_test() ->
    %% RFC 9113 §6.5.2: unknown identifiers MUST be ignored. An ID of
    %% 99 (no current SETTINGS uses that number) must roundtrip as
    %% zero diffs.
    Payload = <<99:16, 1234:32>>,
    {ok, Updated} = roadrunner_http2_settings:apply_payload(
        Payload, roadrunner_http2_settings:new()
    ),
    ?assertEqual([], iolist_to_list(roadrunner_http2_settings:encode_settings(Updated))).

apply_payload_bad_length_returns_frame_size_error_test() ->
    %% RFC 9113 §6.5: payload length MUST be a multiple of 6. 5 bytes
    %% is invalid.
    ?assertEqual(
        {error, frame_size_error},
        roadrunner_http2_settings:apply_payload(
            <<0, 0, 0, 0, 0>>, roadrunner_http2_settings:new()
        )
    ).

settings_ack_frame_is_one_byte_flag_zero_payload_test() ->
    %% Type=4 (SETTINGS), flags=0x01 (ACK), length=0, stream id=0.
    ?assertEqual(<<0:24, 4, 1, 0:32>>, roadrunner_http2_settings:settings_ack_frame()).

initial_settings_frame_is_well_formed_test() ->
    %% A SETTINGS frame from default settings: 9-byte header with
    %% length=0 (no diffs to encode) + empty payload.
    Frame = iolist_to_binary(
        roadrunner_http2_settings:initial_settings_frame(roadrunner_http2_settings:new())
    ),
    ?assertEqual(<<0:24, 4, 0, 0:32>>, Frame).

initial_settings_frame_includes_diffs_test() ->
    %% Walk through apply_payload to set non-default values, then
    %% verify initial_settings_frame emits a non-empty body that
    %% round-trips via apply_payload again.
    {ok, S} = roadrunner_http2_settings:apply_payload(
        <<1:16, 8192:32>>, roadrunner_http2_settings:new()
    ),
    Frame = iolist_to_binary(roadrunner_http2_settings:initial_settings_frame(S)),
    %% Header: length=6, type=4, flags=0, stream id=0.
    ?assertMatch(<<6:24, 4, 0, 0:32, _:6/binary>>, Frame),
    %% The 6-byte payload is the same parameter record that produced
    %% the modified state.
    <<_:9/binary, Body/binary>> = Frame,
    ?assertEqual(<<1:16, 8192:32>>, Body).

%% --- helpers ---

iolist_to_list(IoData) ->
    binary_to_list(iolist_to_binary(IoData)).
