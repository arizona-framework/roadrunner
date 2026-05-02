-module(roadrunner_qs).
-moduledoc """
`application/x-www-form-urlencoded` query string codec.

Pairs are separated by `&`; key and value within each pair are
separated by `=`. `+` decodes to space (legacy form-encoding rule),
followed by RFC 3986 percent-decoding via `roadrunner_uri`. Bare keys
with no `=` are flags — their value is the atom `true`.

Lenient on malformed input (cowboy parity): empty pair entries
(`&&`, leading or trailing `&`) are skipped, and percent sequences
that fail to decode pass through as raw bytes.
""".

-export([parse/1, encode/1]).

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
    case roadrunner_uri:percent_decode(Spaced) of
        {ok, Decoded} -> Decoded;
        {error, badarg} -> Spaced
    end.

-doc """
Encode a list of `{Key, Value}` pairs as a query string.

`Value` may be `true` (bare flag, no `=`) or a binary. Spaces are
encoded as `+` (form-encoding convention); other non-unreserved bytes
become `%HH` triples — including a literal `+`, which becomes `%2B`
so it round-trips through `parse/1`.
""".
-spec encode([{binary(), binary() | true}]) -> binary().
encode(Pairs) when is_list(Pairs) ->
    iolist_to_binary(lists:join(~"&", [encode_pair(P) || P <- Pairs])).

-spec encode_pair({binary(), binary() | true}) -> iodata().
encode_pair({Key, true}) ->
    encode_component(Key);
encode_pair({Key, Value}) when is_binary(Value) ->
    [encode_component(Key), $=, encode_component(Value)].

-spec encode_component(binary()) -> binary().
encode_component(Bin) ->
    %% Use the URI-style percent encoder, then collapse %20 to '+' so the
    %% output is form-encoded. Other percent triples are unaffected because
    %% only literal 0x20 ever produces "%20".
    Encoded = roadrunner_uri:percent_encode(Bin),
    binary:replace(Encoded, ~"%20", ~"+", [global]).
