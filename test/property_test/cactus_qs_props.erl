-module(cactus_qs_props).
-moduledoc """
Property-based tests for `cactus_qs`.

The headline property is the parse/encode round-trip:
`parse(encode(L)) =:= L`. There's an edge case to be aware of though:
`{<<>>, true}` (empty-key bare flag) encodes to `<<>>` and parse of
`<<>>` returns `[]` — that pair is silently dropped. The generator
below avoids producing it, and an explicit `cactus_qs_tests` eunit
case asserts the lossy behavior so it's documented.
""".

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct_property_test.hrl").

prop_parse_encode_roundtrip() ->
    ?FORALL(
        Pairs,
        list(qs_pair()),
        cactus_qs:parse(cactus_qs:encode(Pairs)) =:= Pairs
    ).

%% Excludes `{<<>>, true}` because it's a known lossy shape. Allows
%% `{<<>>, <<...>>}` (empty key with explicit value) which DOES round
%% trip via `=value`.
qs_pair() ->
    union([
        {non_empty_binary(), union([binary(), exactly(true)])},
        {binary(), binary()}
    ]).

non_empty_binary() ->
    ?SUCHTHAT(B, binary(), B =/= <<>>).
