-module(roadrunner_quic_transport_params_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_quic_transport_params).

%% =============================================================================
%% RFC 9000 §18 framing structure — the authority.
%%
%% Each parameter is varint(Id), varint(Length), Value[Length].
%% =============================================================================

encode_varint_param_test() ->
    %% initial_max_streams_bidi (id 0x08) = 3: value is the 1-byte varint <<3>>.
    ?assertEqual(<<16#08, 16#01, 16#03>>, enc(?M:new([{initial_max_streams_bidi, 3}]))).

encode_connection_id_params_test() ->
    %% original_destination_connection_id (0x00) and
    %% initial_source_connection_id (0x0f) carry raw bytes.
    ?assertEqual(
        <<16#00, 16#02, 16#aa, 16#bb>>,
        enc(?M:new([{original_destination_connection_id, <<16#aa, 16#bb>>}]))
    ),
    ?assertEqual(
        <<16#0F, 16#04, 1, 2, 3, 4>>,
        enc(?M:new([{initial_source_connection_id, <<1, 2, 3, 4>>}]))
    ).

encode_stateless_reset_token_test() ->
    %% stateless_reset_token (0x02) carries the 16-byte token as raw bytes
    %% (RFC 9000 §18.2), and decode rejects it from a client.
    Token = <<16#5a:128>>,
    Wire = enc(?M:new([{stateless_reset_token, Token}])),
    ?assertEqual(<<16#02, 16#10, Token/binary>>, Wire),
    ?assertEqual({error, server_only_transport_parameter}, ?M:decode(Wire)).

encode_flag_param_test() ->
    %% disable_active_migration (0x0c) is a zero-length flag.
    ?assertEqual(<<16#0C, 16#00>>, enc(?M:new([{disable_active_migration, true}]))).

%% =============================================================================
%% decode/1 — round-trips and value types.
%% =============================================================================

decode_round_trips_client_set_test() ->
    M = client_param_set(),
    ?assertEqual({ok, M}, ?M:decode(enc(M))).

decode_each_value_type_test() ->
    ?assertEqual({ok, ?M:new([{initial_max_data, 3}])}, ?M:decode(<<16#04, 16#01, 16#03>>)),
    ?assertEqual(
        {ok, ?M:new([{initial_source_connection_id, <<1, 2, 3, 4>>}])},
        ?M:decode(<<16#0F, 16#04, 1, 2, 3, 4>>)
    ),
    ?assertEqual(
        {ok, ?M:new([{disable_active_migration, true}])},
        ?M:decode(<<16#0C, 16#00>>)
    ).

decode_empty_is_empty_set_test() ->
    ?assertEqual({ok, ?M:new([])}, ?M:decode(<<>>)).

%% =============================================================================
%% decode/1 — §18.2 validation.
%% =============================================================================

decode_rejects_server_only_params_test() ->
    %% A client MUST NOT send these (RFC 9000 §18.2); decode rejects each.
    ?assertEqual(
        {error, server_only_transport_parameter},
        ?M:decode(<<16#00, 16#01, 16#aa>>)
    ),
    ?assertEqual(
        {error, server_only_transport_parameter},
        ?M:decode(<<16#02, 16#10, 0:128>>)
    ),
    ?assertEqual(
        {error, server_only_transport_parameter},
        ?M:decode(<<16#0D, 16#00>>)
    ),
    ?assertEqual(
        {error, server_only_transport_parameter},
        ?M:decode(<<16#10, 16#01, 16#cc>>)
    ).

decode_rejects_duplicate_test() ->
    %% RFC 9000 §7.4: a duplicate is rejected regardless of whether the id
    %% is known, unknown, or reserved.
    %% A known parameter twice.
    ?assertEqual(
        {error, duplicate_transport_parameter},
        ?M:decode(<<16#04, 16#01, 16#01, 16#04, 16#01, 16#02>>)
    ),
    %% An unknown id (0x2A) twice.
    ?assertEqual(
        {error, duplicate_transport_parameter},
        ?M:decode(<<16#2A, 16#01, 16#ff, 16#2A, 16#01, 16#ee>>)
    ),
    %% A reserved id (27 = 31*0+27) twice.
    ?assertEqual(
        {error, duplicate_transport_parameter},
        ?M:decode(<<27, 16#00, 27, 16#00>>)
    ).

decode_range_checks_test() ->
    %% encode does not validate, so it builds the boundary and over-limit
    %% wires; decode is what enforces each §18.2 bound.
    Max = 1152921504606846976,
    ?assertEqual(
        {ok, ?M:new([{ack_delay_exponent, 20}])}, redecode(?M:new([{ack_delay_exponent, 20}]))
    ),
    ?assertEqual(
        {error, ack_delay_exponent_too_large}, redecode(?M:new([{ack_delay_exponent, 21}]))
    ),
    ?assertEqual(
        {ok, ?M:new([{max_ack_delay, 16383}])}, redecode(?M:new([{max_ack_delay, 16383}]))
    ),
    ?assertEqual({error, max_ack_delay_too_large}, redecode(?M:new([{max_ack_delay, 16384}]))),
    ?assertEqual(
        {ok, ?M:new([{max_udp_payload_size, 1200}])},
        redecode(?M:new([{max_udp_payload_size, 1200}]))
    ),
    ?assertEqual(
        {error, max_udp_payload_size_too_small}, redecode(?M:new([{max_udp_payload_size, 1199}]))
    ),
    ?assertEqual(
        {ok, ?M:new([{active_connection_id_limit, 2}])},
        redecode(?M:new([{active_connection_id_limit, 2}]))
    ),
    ?assertEqual(
        {error, active_connection_id_limit_too_small},
        redecode(?M:new([{active_connection_id_limit, 1}]))
    ),
    ?assertEqual(
        {ok, ?M:new([{initial_max_streams_bidi, Max}])},
        redecode(?M:new([{initial_max_streams_bidi, Max}]))
    ),
    ?assertEqual(
        {error, initial_max_streams_too_large},
        redecode(?M:new([{initial_max_streams_uni, Max + 1}]))
    ).

decode_ignores_unknown_and_reserved_test() ->
    %% Unknown id 0x2A (42) and a reserved id (27 = 31*0+27) are skipped;
    %% the known parameter between them still decodes. (0x2A is a 1-byte
    %% varint: its high bits are 00.)
    Wire = <<16#2A, 16#01, 16#ff, 16#04, 16#01, 16#07, 27, 16#00>>,
    ?assertEqual({ok, ?M:new([{initial_max_data, 7}])}, ?M:decode(Wire)).

decode_malformed_flag_test() ->
    %% disable_active_migration with a non-empty value is malformed.
    ?assertEqual(
        {error, malformed_transport_parameter},
        ?M:decode(<<16#0C, 16#01, 16#00>>)
    ).

decode_malformed_varint_value_test() ->
    %% A varint parameter whose value field has trailing bytes after the
    %% varint is malformed.
    ?assertEqual(
        {error, malformed_transport_parameter},
        ?M:decode(<<16#04, 16#02, 16#01, 16#ff>>)
    ).

decode_truncated_test() ->
    %% Truncated id, truncated length, and a length that overruns the body.
    ?assertEqual({error, truncated}, ?M:decode(<<16#40>>)),
    ?assertEqual({error, truncated}, ?M:decode(<<16#04, 16#40>>)),
    ?assertEqual({error, truncated}, ?M:decode(<<16#04, 16#08, 1, 2>>)),
    %% A varint value field too short for the varint class it declares.
    ?assertEqual({error, truncated}, ?M:decode(<<16#04, 16#01, 16#80>>)).

%% =============================================================================
%% Accessors: the value a set holds, else the RFC 9000 §18.2 default.
%% =============================================================================

accessors_answer_held_values_test() ->
    Params = ?M:set(stateless_reset_token, <<7:128>>, all_encodable_params()),
    ?assertEqual(<<16#a1, 16#a2>>, ?M:original_destination_connection_id(Params)),
    ?assertEqual(30000, ?M:max_idle_timeout(Params)),
    ?assertEqual(1500, ?M:max_udp_payload_size(Params)),
    ?assertEqual(1048576, ?M:initial_max_data(Params)),
    ?assertEqual(262144, ?M:initial_max_stream_data_bidi_local(Params)),
    ?assertEqual(262144, ?M:initial_max_stream_data_bidi_remote(Params)),
    ?assertEqual(131072, ?M:initial_max_stream_data_uni(Params)),
    ?assertEqual(100, ?M:initial_max_streams_bidi(Params)),
    ?assertEqual(3, ?M:initial_max_streams_uni(Params)),
    ?assertEqual(3, ?M:ack_delay_exponent(Params)),
    ?assertEqual(25, ?M:max_ack_delay(Params)),
    ?assert(?M:disable_active_migration(Params)),
    ?assertEqual(4, ?M:active_connection_id_limit(Params)),
    ?assertEqual(<<16#b1, 16#b2, 16#b3>>, ?M:initial_source_connection_id(Params)),
    ?assertEqual(<<7:128>>, ?M:stateless_reset_token(Params)).

accessors_answer_defaults_test() ->
    Params = ?M:new([]),
    ?assertEqual(undefined, ?M:original_destination_connection_id(Params)),
    ?assertEqual(0, ?M:max_idle_timeout(Params)),
    ?assertEqual(65527, ?M:max_udp_payload_size(Params)),
    ?assertEqual(0, ?M:initial_max_data(Params)),
    ?assertEqual(0, ?M:initial_max_stream_data_bidi_local(Params)),
    ?assertEqual(0, ?M:initial_max_stream_data_bidi_remote(Params)),
    ?assertEqual(0, ?M:initial_max_stream_data_uni(Params)),
    ?assertEqual(0, ?M:initial_max_streams_bidi(Params)),
    ?assertEqual(0, ?M:initial_max_streams_uni(Params)),
    ?assertEqual(3, ?M:ack_delay_exponent(Params)),
    ?assertEqual(25, ?M:max_ack_delay(Params)),
    ?assertNot(?M:disable_active_migration(Params)),
    ?assertEqual(2, ?M:active_connection_id_limit(Params)),
    ?assertEqual(undefined, ?M:initial_source_connection_id(Params)),
    ?assertEqual(undefined, ?M:stateless_reset_token(Params)).

%% A later value for a parameter replaces the earlier one.
new_later_value_wins_test() ->
    ?assertEqual(?M:new([{max_ack_delay, 9}]), ?M:new([{max_ack_delay, 1}, {max_ack_delay, 9}])).

%% =============================================================================
%% Fixtures and helpers
%% =============================================================================

%% Every parameter the encoder supports (one of each value type / clause).
all_encodable_params() ->
    ?M:new([{original_destination_connection_id, <<16#a1, 16#a2>>} | client_params()]).

%% A representative client set (no server-only parameters).
client_param_set() ->
    ?M:new(client_params()).

client_params() ->
    [
        {max_idle_timeout, 30000},
        {max_udp_payload_size, 1500},
        {initial_max_data, 1048576},
        {initial_max_stream_data_bidi_local, 262144},
        {initial_max_stream_data_bidi_remote, 262144},
        {initial_max_stream_data_uni, 131072},
        {initial_max_streams_bidi, 100},
        {initial_max_streams_uni, 3},
        {ack_delay_exponent, 3},
        {max_ack_delay, 25},
        {disable_active_migration, true},
        {active_connection_id_limit, 4},
        {initial_source_connection_id, <<16#b1, 16#b2, 16#b3>>}
    ].

%% Encode then decode, to check decode-side validation of values that
%% encode (which does not validate) happily produces.
redecode(Params) ->
    ?M:decode(enc(Params)).

enc(Params) ->
    iolist_to_binary(?M:encode(Params)).
