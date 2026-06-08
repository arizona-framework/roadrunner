-module(roadrunner_quic_transport_params_props).
-moduledoc """
Property-based tests for `roadrunner_quic_transport_params`.

Round-trip invariant over random client parameter sets: encoding a valid
parameters map and decoding the wire back recovers the same map
(`decode(encode(M)) =:= {ok, M}`). The generated set excludes the
server-only parameters a client must not send (the native decoder
rejects those, by design).
""".

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct_property_test.hrl").

%% 2^62 - 1, the largest value a QUIC varint can carry.
-define(MAX_VARINT, 4611686018427387903).
%% 2^60, the RFC 9000 §18.2 ceiling for initial_max_streams_*.
-define(MAX_STREAMS, 1152921504606846976).

prop_encode_decode_round_trips() ->
    ?FORALL(
        Params,
        params_gen(),
        begin
            Wire = iolist_to_binary(roadrunner_quic_transport_params:encode(Params)),
            roadrunner_quic_transport_params:decode(Wire) =:= {ok, Params}
        end
    ).

%% A map of a random subset of client parameters with in-range values.
%% maps:from_list dedupes keys, so the set never has a duplicate.
params_gen() ->
    ?LET(Pairs, list(param_gen()), maps:from_list(Pairs)).

param_gen() ->
    oneof([
        {max_idle_timeout, varint()},
        {max_udp_payload_size, integer(1200, ?MAX_VARINT)},
        {initial_max_data, varint()},
        {initial_max_stream_data_bidi_local, varint()},
        {initial_max_stream_data_bidi_remote, varint()},
        {initial_max_stream_data_uni, varint()},
        {initial_max_streams_bidi, integer(0, ?MAX_STREAMS)},
        {initial_max_streams_uni, integer(0, ?MAX_STREAMS)},
        {ack_delay_exponent, integer(0, 20)},
        {max_ack_delay, integer(0, 16383)},
        {active_connection_id_limit, integer(2, 1000)},
        {disable_active_migration, true},
        {initial_source_connection_id, cid()}
    ]).

varint() -> integer(0, ?MAX_VARINT).

cid() -> ?LET(N, integer(0, 20), binary(N)).
