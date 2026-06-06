-module(roadrunner_quic_transport_params_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_quic_transport_params).
%% The `quic` dep, kept as a test-profile differential oracle.
-define(DEP, quic_tls).

%% =============================================================================
%% RFC 9000 §18 framing structure — the authority.
%%
%% Each parameter is varint(Id), varint(Length), Value[Length].
%% =============================================================================

encode_varint_param_test() ->
    %% initial_max_streams_bidi (id 0x08) = 3: value is the 1-byte varint <<3>>.
    ?assertEqual(<<16#08, 16#01, 16#03>>, enc(#{initial_max_streams_bidi => 3})).

encode_connection_id_params_test() ->
    %% original_destination_connection_id (0x00) and
    %% initial_source_connection_id (0x0f) carry raw bytes.
    ?assertEqual(
        <<16#00, 16#02, 16#aa, 16#bb>>,
        enc(#{original_destination_connection_id => <<16#aa, 16#bb>>})
    ),
    ?assertEqual(
        <<16#0F, 16#04, 1, 2, 3, 4>>,
        enc(#{initial_source_connection_id => <<1, 2, 3, 4>>})
    ).

encode_flag_param_test() ->
    %% disable_active_migration (0x0c) is a zero-length flag.
    ?assertEqual(<<16#0C, 16#00>>, enc(#{disable_active_migration => true})).

encode_all_params_decoded_by_dep_test() ->
    %% Every encodable parameter at once (including the server-only
    %% original_destination_connection_id), exercising each encode clause.
    %% The dep decoder (which does not reject server-only params) reads it
    %% back to the same values, order-independently.
    All = all_encodable_params(),
    {ok, DepMap} = ?DEP:decode_transport_params(enc(All)),
    ?assertEqual(All, from_dep_params(DepMap)).

%% =============================================================================
%% decode/1 — round-trips and value types.
%% =============================================================================

decode_round_trips_client_set_test() ->
    M = client_param_set(),
    ?assertEqual({ok, M}, ?M:decode(enc(M))).

decode_each_value_type_test() ->
    ?assertEqual({ok, #{initial_max_data => 3}}, ?M:decode(<<16#04, 16#01, 16#03>>)),
    ?assertEqual(
        {ok, #{initial_source_connection_id => <<1, 2, 3, 4>>}},
        ?M:decode(<<16#0F, 16#04, 1, 2, 3, 4>>)
    ),
    ?assertEqual(
        {ok, #{disable_active_migration => true}},
        ?M:decode(<<16#0C, 16#00>>)
    ).

decode_empty_is_empty_map_test() ->
    ?assertEqual({ok, #{}}, ?M:decode(<<>>)).

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
    ?assertEqual({ok, #{ack_delay_exponent => 20}}, redecode(#{ack_delay_exponent => 20})),
    ?assertEqual(
        {error, ack_delay_exponent_too_large}, redecode(#{ack_delay_exponent => 21})
    ),
    ?assertEqual({ok, #{max_ack_delay => 16383}}, redecode(#{max_ack_delay => 16383})),
    ?assertEqual({error, max_ack_delay_too_large}, redecode(#{max_ack_delay => 16384})),
    ?assertEqual({ok, #{max_udp_payload_size => 1200}}, redecode(#{max_udp_payload_size => 1200})),
    ?assertEqual(
        {error, max_udp_payload_size_too_small}, redecode(#{max_udp_payload_size => 1199})
    ),
    ?assertEqual(
        {ok, #{active_connection_id_limit => 2}}, redecode(#{active_connection_id_limit => 2})
    ),
    ?assertEqual(
        {error, active_connection_id_limit_too_small},
        redecode(#{active_connection_id_limit => 1})
    ),
    ?assertEqual(
        {ok, #{initial_max_streams_bidi => Max}}, redecode(#{initial_max_streams_bidi => Max})
    ),
    ?assertEqual(
        {error, initial_max_streams_too_large}, redecode(#{initial_max_streams_uni => Max + 1})
    ).

decode_ignores_unknown_and_reserved_test() ->
    %% Unknown id 0x2A (42) and a reserved id (27 = 31*0+27) are skipped;
    %% the known parameter between them still decodes. (0x2A is a 1-byte
    %% varint: its high bits are 00.)
    Wire = <<16#2A, 16#01, 16#ff, 16#04, 16#01, 16#07, 27, 16#00>>,
    ?assertEqual({ok, #{initial_max_data => 7}}, ?M:decode(Wire)).

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
%% Differential oracle vs the `quic` dep (kept as a test-profile dep).
%% =============================================================================

%% Per single parameter the wire is order-independent, so byte-for-byte
%% equality with the dep holds (the dep emits a whole map in maps:fold
%% order, which is unspecified).
oracle_encode_matches_dep_test() ->
    [
        ?assertEqual(
            ?DEP:encode_transport_params(dep_params(#{Key => Value})),
            enc(#{Key => Value})
        )
     || {Key, Value} <- oracle_single_params()
    ].

%% The dep decodes the native wire to the same values, and the native
%% decoder round-trips the same client set.
oracle_decode_matches_dep_test() ->
    [
        begin
            Wire = enc(M),
            ?assertEqual({ok, M}, ?M:decode(Wire)),
            {ok, DepMap} = ?DEP:decode_transport_params(Wire),
            ?assertEqual(M, from_dep_params(DepMap))
        end
     || M <- oracle_client_sets()
    ].

%% =============================================================================
%% Fixtures and helpers
%% =============================================================================

%% Every parameter the encoder supports (one of each value type / clause).
all_encodable_params() ->
    #{
        original_destination_connection_id => <<16#a1, 16#a2>>,
        max_idle_timeout => 30000,
        max_udp_payload_size => 1500,
        initial_max_data => 1048576,
        initial_max_stream_data_bidi_local => 262144,
        initial_max_stream_data_bidi_remote => 262144,
        initial_max_stream_data_uni => 131072,
        initial_max_streams_bidi => 100,
        initial_max_streams_uni => 3,
        ack_delay_exponent => 3,
        max_ack_delay => 25,
        disable_active_migration => true,
        active_connection_id_limit => 4,
        initial_source_connection_id => <<16#b1, 16#b2, 16#b3>>
    }.

%% A representative client set (no server-only parameters).
client_param_set() ->
    maps:remove(original_destination_connection_id, all_encodable_params()).

oracle_client_sets() ->
    [
        #{initial_max_data => 1000000},
        #{
            initial_max_stream_data_bidi_local => 65536,
            initial_max_streams_bidi => 16,
            max_idle_timeout => 10000
        },
        #{disable_active_migration => true, active_connection_id_limit => 8},
        client_param_set()
    ].

oracle_single_params() ->
    [
        {original_destination_connection_id, <<1, 2, 3, 4, 5>>},
        {max_idle_timeout, 0},
        {max_udp_payload_size, 65527},
        {initial_max_data, 4611686018427387903},
        {initial_max_stream_data_bidi_local, 16383},
        {initial_max_stream_data_bidi_remote, 64},
        {initial_max_stream_data_uni, 63},
        {initial_max_streams_bidi, 100},
        {initial_max_streams_uni, 0},
        {ack_delay_exponent, 3},
        {max_ack_delay, 25},
        {disable_active_migration, true},
        {active_connection_id_limit, 2},
        {initial_source_connection_id, <<16#cc, 16#dd>>}
    ].

%% The dep names three connection-id parameters differently.
dep_params(M) ->
    maps:fold(fun(K, V, Acc) -> Acc#{to_dep_key(K) => V} end, #{}, M).

to_dep_key(original_destination_connection_id) -> original_dcid;
to_dep_key(initial_source_connection_id) -> initial_scid;
to_dep_key(retry_source_connection_id) -> retry_scid;
to_dep_key(K) -> K.

from_dep_params(M) ->
    maps:fold(fun(K, V, Acc) -> Acc#{from_dep_key(K) => V} end, #{}, M).

from_dep_key(original_dcid) -> original_destination_connection_id;
from_dep_key(initial_scid) -> initial_source_connection_id;
from_dep_key(retry_scid) -> retry_source_connection_id;
from_dep_key(K) -> K.

%% Encode then decode, to check decode-side validation of values that
%% encode (which does not validate) happily produces.
redecode(Params) ->
    ?M:decode(enc(Params)).

enc(Params) ->
    iolist_to_binary(?M:encode(Params)).
