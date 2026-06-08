-module(roadrunner_quic_varint_props).
-moduledoc """
Property-based tests for `roadrunner_quic_varint`.

Over the whole 62-bit domain, `decode(encode(V))` round-trips back to
`{ok, V, <<>>}`: the native encoder produces a buffer the native decoder
reads as exactly `V` with no trailing bytes.
""".

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct_property_test.hrl").

%% 2^62 - 1, the largest value a QUIC varint can carry.
-define(MAX_62, 4611686018427387903).

prop_round_trips() ->
    ?FORALL(
        V,
        integer(0, ?MAX_62),
        roadrunner_quic_varint:decode(roadrunner_quic_varint:encode(V)) =:= {ok, V, <<>>}
    ).
