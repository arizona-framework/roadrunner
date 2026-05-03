-module(roadrunner_bin).
-moduledoc """
Binary-level helpers — operations on `binary()` that several
modules need but don't belong to any specific protocol module
(`roadrunner_http1`, `roadrunner_ws`, `roadrunner_uri`, etc.).

Mirrors OTP's stdlib `binary` module in spirit: things that work
on bytes, with no protocol semantics. Don't put non-binary helpers
here — give them their own module.
""".

-export([ascii_lowercase/1]).

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
    iolist_to_binary(ascii_lowercase_walk(Bin)).

-spec ascii_lowercase_walk(binary()) -> iolist().
ascii_lowercase_walk(<<>>) ->
    [];
ascii_lowercase_walk(<<C, R/binary>>) when C >= $A, C =< $Z ->
    [C + 32 | ascii_lowercase_walk(R)];
ascii_lowercase_walk(<<C, R/binary>>) ->
    [C | ascii_lowercase_walk(R)].
