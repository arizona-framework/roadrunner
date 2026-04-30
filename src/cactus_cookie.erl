-module(cactus_cookie).
-moduledoc """
HTTP cookie codec (RFC 6265).

Currently provides `parse/1` for the request-side `Cookie` header.
The response-side `Set-Cookie` builder will arrive in a later feature.
""".

-export([parse/1]).

-doc """
Parse a `Cookie` header value into a list of `{Name, Value}` pairs in
the order they appear on the wire.

OWS (SP and HTAB) around each pair is trimmed. Pairs missing `=` or
with an empty name are silently skipped (cowboy parity); empty values
are accepted. Only the first `=` in a pair separates name from value,
so a cookie like `sid=a=b=c` parses as a single pair with value `a=b=c`.
""".
-spec parse(binary()) -> [{binary(), binary()}].
parse(<<>>) ->
    [];
parse(Bin) when is_binary(Bin) ->
    parse_pairs(binary:split(Bin, ~";", [global])).

-spec parse_pairs([binary()]) -> [{binary(), binary()}].
parse_pairs([]) ->
    [];
parse_pairs([Pair | Rest]) ->
    case binary:split(trim_ows(Pair), ~"=") of
        [Name, Value] when Name =/= <<>> ->
            [{Name, Value} | parse_pairs(Rest)];
        _ ->
            parse_pairs(Rest)
    end.

%% Duplicated from cactus_http1 — both modules need OWS trimming. Extract
%% to a util module if a third caller appears.
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
