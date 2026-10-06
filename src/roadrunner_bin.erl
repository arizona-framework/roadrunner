-module(roadrunner_bin).
-moduledoc false.

%% Binary-level helpers — operations on `binary()` that several
%% modules need but don't belong to any specific protocol module
%% (`roadrunner_http1`, `roadrunner_ws`, `roadrunner_uri`, etc.).
%%
%% Mirrors OTP's stdlib `binary` module in spirit: things that work
%% on bytes, with no protocol semantics. Don't put non-binary helpers
%% here — give them their own module.

-export([append/2, ascii_lowercase/1, digits_to_integer/1, trim_ows/1, trim_trailing_ows/1]).

-doc """
Fast ASCII-only lowercase. Bytes in `[A-Z]` are mapped to `[a-z]`;
everything else (including high-bit / non-ASCII bytes) passes
through unchanged.

About 1.6× faster than `string:lowercase/1` (which routes per byte
through `unicode_util`) for inputs that are already ASCII —
typical HTTP header names and RFC tokens.

## ⚠️ Not a Unicode lowercase

`ascii_lowercase(~"CAFÉ")` returns `<<"cafÉ"/utf8>>`, not `<<"café"/utf8>>`.
Non-ASCII letters are **left unchanged**. Use this only when the
input domain is RFC-bounded to ASCII bytes:

- HTTP header names (RFC 9110 §5.6.2 `tchar` token grammar — pure ASCII).
- Known case-insensitive HTTP tokens: `Connection` values
  (`close`, `keep-alive`, `upgrade`), `Transfer-Encoding` values
  (`chunked`), `Expect` values (`100-continue`).

If a malformed client smuggles non-ASCII into one of those fields,
case-insensitive ASCII comparison still produces the spec-correct
result (`Transfer-Encoding: chunkéd` does not match `chunked` by
either lowercase function). For inputs that may contain real
Unicode requiring case folding (multipart filenames, user-supplied
form values, cookie values), use `string:lowercase/1`.

## Implementation note

Builds an iolist via body recursion and finalizes with
`iolist_to_binary`. The seemingly-simpler `<<Acc/binary, B>>`
segment append is O(N²) in this shape — Erlang's match-context
reuse optimization doesn't kick in across the recursive calls, so
each append re-copies the accumulator. Microbench confirmed
iolist build is 3× faster.
""".
-spec ascii_lowercase(binary()) -> binary().
ascii_lowercase(Bin) when is_binary(Bin) ->
    %% Already-lowercase fast path: scan for any A–Z byte first; if
    %% none, return the input untouched. Skips the iolist build +
    %% `iolist_to_binary` copy entirely. Wins ~65 % on lowercase
    %% inputs (the dominant case for header lookups via lowercase
    %% literals) at ~15 % cost on mixed-case.
    case has_uppercase(Bin) of
        false -> Bin;
        true -> iolist_to_binary(ascii_lowercase_walk(Bin))
    end.

%% SWAR scan, 7 bytes per step: 56 bits stays a small integer on a
%% 64-bit BEAM, where a 64-bit word would be a heap bignum. This is
%% `hasbetween(X, $A - 1, $Z + 1)` from Bit Twiddling Hacks: per byte,
%% `Low` is the byte without its high bit, `?BYTES(127 + $Z + 1) - Low`
%% has its high bit set when the byte is below `$Z + 1`, and
%% `Low + ?BYTES(127 - ($A - 1))` has it set when the byte is above
%% `$A - 1`. ANDing with the complement of `X` drops bytes >= 128.
%% Neither sum borrows or carries across bytes, so each high bit
%% answers for its own byte. 1.8-3.7x faster than the byte loop from
%% 10 bytes up; the byte loop finishes the < 7 byte tail.
-define(BYTES(B), (16#01010101010101 * (B))).

-spec has_uppercase(binary()) -> boolean().
has_uppercase(<<X:56, R/binary>>) ->
    Low = X band ?BYTES(127),
    case
        (?BYTES(127 + $Z + 1) - Low) band (X bxor ?BYTES(255)) band
            (Low + ?BYTES(127 - ($A - 1))) band ?BYTES(128)
    of
        0 -> has_uppercase(R);
        _ -> true
    end;
has_uppercase(Tail) ->
    has_uppercase_tail(Tail).

-spec has_uppercase_tail(binary()) -> boolean().
has_uppercase_tail(<<C, _/binary>>) when C >= $A, C =< $Z -> true;
has_uppercase_tail(<<_, R/binary>>) -> has_uppercase_tail(R);
has_uppercase_tail(<<>>) -> false.

%% 26 explicit head clauses + literal lowercase byte instead of
%% `when C >= $A, C =< $Z -> [C + 32 | ...]`. The compiler converts
%% the explicit form into a single `select_val` jump table (BEAM
%% switch/case) with each target putting the literal lowercase byte
%% — no runtime guard comparisons, no runtime `+ 32` arithmetic.
%% `erlc -S` confirms: guard form emits 2× `is_ge` + `gc_bif '+'`
%% per byte; explicit form emits one `select_val` over 26 entries
%% per byte. Faster on ASCII-heavy inputs and indistinguishable on
%% the (already lowercase) common case where the catch-all clause
%% runs.
-spec ascii_lowercase_walk(binary()) -> iolist().
ascii_lowercase_walk(<<>>) -> [];
ascii_lowercase_walk(<<$A, R/binary>>) -> [$a | ascii_lowercase_walk(R)];
ascii_lowercase_walk(<<$B, R/binary>>) -> [$b | ascii_lowercase_walk(R)];
ascii_lowercase_walk(<<$C, R/binary>>) -> [$c | ascii_lowercase_walk(R)];
ascii_lowercase_walk(<<$D, R/binary>>) -> [$d | ascii_lowercase_walk(R)];
ascii_lowercase_walk(<<$E, R/binary>>) -> [$e | ascii_lowercase_walk(R)];
ascii_lowercase_walk(<<$F, R/binary>>) -> [$f | ascii_lowercase_walk(R)];
ascii_lowercase_walk(<<$G, R/binary>>) -> [$g | ascii_lowercase_walk(R)];
ascii_lowercase_walk(<<$H, R/binary>>) -> [$h | ascii_lowercase_walk(R)];
ascii_lowercase_walk(<<$I, R/binary>>) -> [$i | ascii_lowercase_walk(R)];
ascii_lowercase_walk(<<$J, R/binary>>) -> [$j | ascii_lowercase_walk(R)];
ascii_lowercase_walk(<<$K, R/binary>>) -> [$k | ascii_lowercase_walk(R)];
ascii_lowercase_walk(<<$L, R/binary>>) -> [$l | ascii_lowercase_walk(R)];
ascii_lowercase_walk(<<$M, R/binary>>) -> [$m | ascii_lowercase_walk(R)];
ascii_lowercase_walk(<<$N, R/binary>>) -> [$n | ascii_lowercase_walk(R)];
ascii_lowercase_walk(<<$O, R/binary>>) -> [$o | ascii_lowercase_walk(R)];
ascii_lowercase_walk(<<$P, R/binary>>) -> [$p | ascii_lowercase_walk(R)];
ascii_lowercase_walk(<<$Q, R/binary>>) -> [$q | ascii_lowercase_walk(R)];
ascii_lowercase_walk(<<$R, R/binary>>) -> [$r | ascii_lowercase_walk(R)];
ascii_lowercase_walk(<<$S, R/binary>>) -> [$s | ascii_lowercase_walk(R)];
ascii_lowercase_walk(<<$T, R/binary>>) -> [$t | ascii_lowercase_walk(R)];
ascii_lowercase_walk(<<$U, R/binary>>) -> [$u | ascii_lowercase_walk(R)];
ascii_lowercase_walk(<<$V, R/binary>>) -> [$v | ascii_lowercase_walk(R)];
ascii_lowercase_walk(<<$W, R/binary>>) -> [$w | ascii_lowercase_walk(R)];
ascii_lowercase_walk(<<$X, R/binary>>) -> [$x | ascii_lowercase_walk(R)];
ascii_lowercase_walk(<<$Y, R/binary>>) -> [$y | ascii_lowercase_walk(R)];
ascii_lowercase_walk(<<$Z, R/binary>>) -> [$z | ascii_lowercase_walk(R)];
ascii_lowercase_walk(<<C, R/binary>>) -> [C | ascii_lowercase_walk(R)].

-doc """
Trim ASCII optional whitespace (RFC 9110 §5.6.3 — `OWS = *( SP / HTAB )`)
from both ends of a binary. Faster than `string:trim/1` (~25–80 ns vs
~2 µs) because it stays ASCII-bounded and skips the unicode_util
dispatch path the BIF takes per character.

## ⚠️ Not a Unicode whitespace trim

Bytes other than 0x20 (SP) and 0x09 (HTAB) are NOT trimmed. CR, LF,
form-feed, vertical-tab, NBSP, etc. all pass through. Use this only
when the input domain is RFC-bounded to OWS:

- HTTP header values (RFC 9110 §5.6.3).
- Multipart parameter tokens (RFC 7578 inherits HTTP grammar).
- Cookie name / value (RFC 6265 §5.2).
- WebSocket extension offer tokens (RFC 6455 §9.1 inherits HTTP grammar).

For inputs that may contain real Unicode whitespace, use
`string:trim/1`.
""".
-spec trim_ows(binary()) -> binary().
trim_ows(B) -> trim_trailing_ows(trim_leading_ows(B)).

-spec trim_leading_ows(binary()) -> binary().
trim_leading_ows(<<C, R/binary>>) when C =:= $\s; C =:= $\t ->
    trim_leading_ows(R);
trim_leading_ows(B) ->
    B.

-spec trim_trailing_ows(binary()) -> binary().
trim_trailing_ows(<<>>) ->
    <<>>;
trim_trailing_ows(B) ->
    Size = byte_size(B),
    case binary:at(B, Size - 1) of
        C when C =:= $\s; C =:= $\t ->
            trim_trailing_ows(binary:part(B, 0, Size - 1));
        _ ->
            B
    end.

-doc """
Parse a `1*DIGIT` field (RFC 9110 §5.6.1 grammar, as used by
`Content-Length` and byte ranges) into a non-negative integer.

Rejects a leading `+` or `-`, which `binary_to_integer/1` alone
accepts: `+5` and `-0` are not valid `Content-Length` values, and a
server that reads them while an upstream proxy does not is a request
smuggling risk. A sign can only appear as the first byte, so checking
that byte is enough; `binary_to_integer/1` rejects every other
non-digit.
""".
-spec digits_to_integer(binary()) -> {ok, non_neg_integer()} | error.
digits_to_integer(<<C, _/binary>> = Bin) when C >= $0, C =< $9 ->
    try binary_to_integer(Bin) of
        N -> {ok, N}
    catch
        error:badarg -> error
    end;
digits_to_integer(_) ->
    error.

-doc """
Append freshly received bytes to a receive buffer.

An empty buffer hands `Bytes` back as is: `<<Buf/binary, Bytes/binary>>`
copies `Bytes` into a new writable binary even when `Buf` is `<<>>`,
which costs 70-300 ns per packet (40 B to 16 KB) on the common path
where the previous request left nothing behind. A non-empty buffer is
appended as before.
""".
-spec append(binary(), binary()) -> binary().
append(<<>>, Bytes) ->
    Bytes;
append(Buf, Bytes) ->
    <<Buf/binary, Bytes/binary>>.
