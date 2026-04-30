-module(cactus_uri).
-moduledoc """
URI percent-encoding helpers (RFC 3986 §2.1).

Pure binary in / binary out. Used by `cactus_qs` and the eventual router.
""".

-export([percent_decode/1]).

-doc """
Decode a percent-encoded binary.

Replaces every `%HH` triple with the byte it encodes. Hex digits are
case-insensitive. Returns `{error, badarg}` if `%` is not followed by
exactly two hex digits — including a lone `%` at end of input.
""".
-spec percent_decode(binary()) -> {ok, binary()} | {error, badarg}.
percent_decode(Bin) when is_binary(Bin) ->
    decode(Bin, <<>>).

-spec decode(binary(), binary()) -> {ok, binary()} | {error, badarg}.
decode(<<>>, Acc) ->
    {ok, Acc};
decode(<<$%, H1, H2, R/binary>>, Acc) ->
    case hex(H1) of
        error ->
            {error, badarg};
        N1 ->
            case hex(H2) of
                error -> {error, badarg};
                N2 -> decode(R, <<Acc/binary, (N1 * 16 + N2)>>)
            end
    end;
decode(<<$%, _/binary>>, _Acc) ->
    %% Lone `%` or `%H` at end of input.
    {error, badarg};
decode(<<C, R/binary>>, Acc) ->
    decode(R, <<Acc/binary, C>>).

-spec hex(byte()) -> 0..15 | error.
hex(C) when C >= $0, C =< $9 -> C - $0;
hex(C) when C >= $a, C =< $f -> C - $a + 10;
hex(C) when C >= $A, C =< $F -> C - $A + 10;
hex(_) -> error.
