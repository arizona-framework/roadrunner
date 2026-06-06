-module(roadrunner_quic_tls_handshake_props).
-moduledoc """
Property-based tests for `roadrunner_quic_tls_handshake`.

Differential + round-trip invariant over random handshake messages: the
framing is byte-for-byte identical to the `quic` dep (the oracle),
`decode(encode(...))` round-trips back to `{ok, {Type, Body}, <<>>}`, and
the dep decodes the native framing to the same value.
""".

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct_property_test.hrl").

prop_encode_decode_matches_dep() ->
    ?FORALL(
        {Type, Body},
        {integer(0, 255), binary()},
        begin
            Wire = iolist_to_binary(roadrunner_quic_tls_handshake:encode(Type, Body)),
            Wire =:= quic_tls:encode_handshake_message(Type, Body) andalso
                roadrunner_quic_tls_handshake:decode(Wire) =:= {ok, {Type, Body}, <<>>} andalso
                roadrunner_quic_tls_handshake:decode(Wire) =:=
                    quic_tls:decode_handshake_message(Wire)
        end
    ).
