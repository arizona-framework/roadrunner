-module(roadrunner_uri_props).
-moduledoc """
Property-based tests for `roadrunner_uri`.

Driven through OTP's `ct_property_test` integration — the
`-include_lib("common_test/include/ct_property_test.hrl")` resolves
`?FORALL` against whichever framework is on the path (PropEr in our
setup, but QuickCheck or Triq would work the same).
""".

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct_property_test.hrl").

%% percent_encode/percent_decode are inverses for any binary input —
%% the encoder maps every non-unreserved byte to `%HH`, the decoder
%% reverses that. No information loss in either direction.
prop_percent_roundtrip() ->
    ?FORALL(
        Bin,
        binary(),
        {ok, Bin} =:= roadrunner_uri:percent_decode(roadrunner_uri:percent_encode(Bin))
    ).

%% Encoded output never contains a byte that would itself need
%% encoding — the only `%` in the output is the one that introduces a
%% percent-triple, every other byte is a raw unreserved char.
prop_encode_output_is_unreserved_or_percent() ->
    ?FORALL(
        Bin,
        binary(),
        is_safe_encoded(roadrunner_uri:percent_encode(Bin))
    ).

is_safe_encoded(<<>>) ->
    true;
is_safe_encoded(<<$%, H1, H2, Rest/binary>>) ->
    is_hex_digit(H1) andalso is_hex_digit(H2) andalso is_safe_encoded(Rest);
is_safe_encoded(<<C, Rest/binary>>) ->
    is_unreserved_byte(C) andalso is_safe_encoded(Rest).

is_unreserved_byte(C) when C >= $A, C =< $Z -> true;
is_unreserved_byte(C) when C >= $a, C =< $z -> true;
is_unreserved_byte(C) when C >= $0, C =< $9 -> true;
is_unreserved_byte($-) -> true;
is_unreserved_byte($.) -> true;
is_unreserved_byte($_) -> true;
is_unreserved_byte($~) -> true;
is_unreserved_byte(_) -> false.

is_hex_digit(C) when C >= $0, C =< $9 -> true;
is_hex_digit(C) when C >= $A, C =< $F -> true;
is_hex_digit(C) when C >= $a, C =< $f -> true;
is_hex_digit(_) -> false.
