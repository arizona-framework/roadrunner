-module(roadrunner_quic_varint_props).
-moduledoc """
Property-based tests for `roadrunner_quic_varint`.

Two invariants over the whole 62-bit domain: the encoding is
byte-for-byte identical to the `quic` dep (the differential oracle),
and `decode(encode(V))` round-trips back to `{ok, V, <<>>}`.
""".

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct_property_test.hrl").

%% 2^62 - 1, the largest value a QUIC varint can carry.
-define(MAX_62, 4611686018427387903).

prop_encode_matches_dep_and_round_trips() ->
    ?FORALL(
        V,
        integer(0, ?MAX_62),
        begin
            Bin = roadrunner_quic_varint:encode(V),
            Bin =:= quic_varint:encode(V) andalso
                roadrunner_quic_varint:decode(Bin) =:= {ok, V, <<>>}
        end
    ).
