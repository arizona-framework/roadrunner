-module(roadrunner_quic_hkdf_props).
-moduledoc """
Property-based tests for `roadrunner_quic_hkdf`.

Differential invariant over random inputs: HKDF-Extract, HKDF-Expand,
and HKDF-Expand-Label are byte-for-byte identical to the `quic` dep (the
oracle) for arbitrary salt, keying material, info, label, context, and
output length, including the empty-salt default and multi-block
expansion.
""".

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct_property_test.hrl").

prop_matches_dep() ->
    ?FORALL(
        {Salt, IKM, Info, Label, Context, Len},
        {binary(), binary(), binary(), binary(), binary(), integer(0, 96)},
        begin
            PRK = roadrunner_quic_hkdf:extract(Salt, IKM),
            PRK =:= quic_hkdf:extract(Salt, IKM) andalso
                roadrunner_quic_hkdf:expand(PRK, Info, Len) =:= quic_hkdf:expand(PRK, Info, Len) andalso
                roadrunner_quic_hkdf:expand_label(PRK, Label, Context, Len) =:=
                    quic_hkdf:expand_label(PRK, Label, Context, Len)
        end
    ).
