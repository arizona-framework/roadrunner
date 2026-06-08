-module(roadrunner_quic_tls_handshake_props).
-moduledoc """
Property-based tests for `roadrunner_quic_tls_handshake`.

Round-trip invariant over random handshake messages: framing a type and
body with `encode/2` and decoding the result with `decode/1` recovers the
original `{Type, Body}` pair with no trailing bytes
(`{ok, {Type, Body}, <<>>}`).
""".

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct_property_test.hrl").

prop_encode_decode_round_trips() ->
    ?FORALL(
        {Type, Body},
        {integer(0, 255), binary()},
        begin
            Wire = iolist_to_binary(roadrunner_quic_tls_handshake:encode(Type, Body)),
            roadrunner_quic_tls_handshake:decode(Wire) =:= {ok, {Type, Body}, <<>>}
        end
    ).
