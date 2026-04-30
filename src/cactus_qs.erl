-module(cactus_qs).
-moduledoc """
`application/x-www-form-urlencoded` query string codec.

Pairs are separated by `&`; key and value within each pair are
separated by `=`. `+` decodes to space (legacy form-encoding rule),
followed by RFC 3986 percent-decoding via `cactus_uri`. Bare keys
with no `=` are flags — their value is the atom `true`.

Lenient on malformed input (cowboy parity): empty pair entries
(`&&`, leading or trailing `&`) are skipped, and percent sequences
that fail to decode pass through as raw bytes.
""".

-export([parse/1]).

-doc """
Parse a query string into an ordered list of `{Key, Value}` pairs.

`Value` is `true` for bare flags, otherwise a binary (possibly empty).
""".
-spec parse(binary()) -> [{binary(), binary() | true}].
parse(<<>>) ->
    [];
parse(Bin) when is_binary(Bin) ->
    [parse_pair(P) || P <- binary:split(Bin, ~"&", [global]), P =/= <<>>].

-spec parse_pair(binary()) -> {binary(), binary() | true}.
parse_pair(Pair) ->
    case binary:split(Pair, ~"=") of
        [Key] -> {decode(Key), true};
        [Key, Value] -> {decode(Key), decode(Value)}
    end.

-spec decode(binary()) -> binary().
decode(Bin) ->
    Spaced = binary:replace(Bin, ~"+", ~" ", [global]),
    case cactus_uri:percent_decode(Spaced) of
        {ok, Decoded} -> Decoded;
        {error, badarg} -> Spaced
    end.
