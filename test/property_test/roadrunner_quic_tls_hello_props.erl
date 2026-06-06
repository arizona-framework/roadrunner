-module(roadrunner_quic_tls_hello_props).
-moduledoc """
Property-based tests for `roadrunner_quic_tls_hello`.

Robustness invariant: `parse_client_hello/1` returns a flat
`{ok, _} | {error, _}` for any input and never crashes, including on
buffers that look like a ClientHello (the `0x0303` legacy-version prefix)
but carry garbage in the nested length-prefixed vectors.
""".

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct_property_test.hrl").

prop_parse_client_hello_never_crashes() ->
    ?FORALL(
        Bin,
        oneof([binary(), ?LET(B, binary(), <<16#0303:16, B/binary>>)]),
        case roadrunner_quic_tls_hello:parse_client_hello(Bin) of
            {ok, Map} when is_map(Map) -> true;
            {error, Reason} when is_atom(Reason) -> true
        end
    ).
