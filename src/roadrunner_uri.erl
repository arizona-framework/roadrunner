-module(roadrunner_uri).
-moduledoc """
URI percent-encoding helpers (RFC 3986 §2.1).

Pure binary in / binary out. Used by `roadrunner_qs` and the eventual router.
""".

-on_load(init_patterns/0).

-export([percent_decode/1, percent_encode/1]).

-define(PERCENT_CP_KEY, {?MODULE, percent_cp}).

-doc """
Decode a percent-encoded binary.

Replaces every `%HH` triple with the byte it encodes. Hex digits are
case-insensitive. Returns `{error, badarg}` if `%` is not followed by
exactly two hex digits — including a lone `%` at end of input.
""".
-spec percent_decode(binary()) -> {ok, binary()} | {error, badarg}.
percent_decode(Bin) when is_binary(Bin) ->
    %% Fast path: no `%` means no decoding needed — return the
    %% original binary untouched. The compiled-pattern `match/2`
    %% scans once; the original `decode/2` walks AND copies every
    %% byte even when the binary is `%`-free, so this avoids the
    %% byte-by-byte reconstruction cost on the typical input
    %% (form fields with safe ASCII keys/values, paths, etc.).
    case binary:match(Bin, persistent_term:get(?PERCENT_CP_KEY)) of
        nomatch -> {ok, Bin};
        _ -> decode(Bin, <<>>)
    end.

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

-doc """
Percent-encode a binary per RFC 3986.

Bytes in the unreserved set (ALPHA / DIGIT / `-` / `.` / `_` / `~`) pass
through unchanged; every other byte is replaced by `%HH` with uppercase
hex digits (per RFC 3986 §2.1 normalization recommendation).
""".
-spec percent_encode(binary()) -> binary().
percent_encode(Bin) when is_binary(Bin) ->
    encode(Bin, <<>>).

-spec encode(binary(), binary()) -> binary().
encode(<<>>, Acc) ->
    Acc;
encode(<<C, R/binary>>, Acc) ->
    case is_unreserved(C) of
        true ->
            encode(R, <<Acc/binary, C>>);
        false ->
            H1 = hex_digit(C div 16),
            H2 = hex_digit(C rem 16),
            encode(R, <<Acc/binary, $%, H1, H2>>)
    end.

-spec is_unreserved(byte()) -> boolean().
is_unreserved(C) when C >= $A, C =< $Z -> true;
is_unreserved(C) when C >= $a, C =< $z -> true;
is_unreserved(C) when C >= $0, C =< $9 -> true;
is_unreserved($-) -> true;
is_unreserved($.) -> true;
is_unreserved($_) -> true;
is_unreserved($~) -> true;
is_unreserved(_) -> false.

-spec hex_digit(0..15) -> byte().
hex_digit(N) when N < 10 -> $0 + N;
hex_digit(N) -> $A + N - 10.

%% `-on_load` callback. Compiles the percent trigger pattern once
%% at module load and stashes it in `persistent_term`, so the
%% `percent_decode/1` fast-path scans with a precompiled binary
%% pattern instead of building one per call. Conventional shape
%% across the codebase (see `roadrunner_compress`,
%% `roadrunner_http1`, `roadrunner_ws`).
-spec init_patterns() -> ok.
init_patterns() ->
    persistent_term:put(?PERCENT_CP_KEY, binary:compile_pattern(~"%")),
    ok.
