-module(cactus_req).
-moduledoc """
Pure accessors over a `cactus_http1:request()` map.

Decouples handler code from the underlying map shape — handlers should
prefer these functions over direct `maps:get/2` so the request
representation can evolve without breaking them.
""".

-export([method/1, path/1, qs/1, version/1, headers/1, header/2]).

-doc "Return the request method (uppercase ASCII binary).".
-spec method(cactus_http1:request()) -> binary().
method(#{method := M}) -> M.

-doc """
Return the path component of the request-target.

If the target contains a `?` query separator, only the bytes before it
are returned. The path is **not** percent-decoded — that's the
router's job.
""".
-spec path(cactus_http1:request()) -> binary().
path(#{target := T}) ->
    case binary:split(T, ~"?") of
        [P, _Q] -> P;
        [P] -> P
    end.

-doc """
Return the raw query string portion of the request-target, without the
leading `?`. Empty binary when no `?` is present (or nothing follows it).

For decoded `{Key, Value}` pairs, pipe through `cactus_qs:parse/1`.
""".
-spec qs(cactus_http1:request()) -> binary().
qs(#{target := T}) ->
    case binary:split(T, ~"?") of
        [_P, Q] -> Q;
        [_P] -> <<>>
    end.

-doc "Return the HTTP version tuple ({1,0} or {1,1}).".
-spec version(cactus_http1:request()) -> cactus_http1:version().
version(#{version := V}) -> V.

-doc "Return the full ordered list of `{Name, Value}` header pairs.".
-spec headers(cactus_http1:request()) -> cactus_http1:headers().
headers(#{headers := H}) -> H.

-doc """
Look up a single header value by name. Returns `undefined` if absent.

The lookup is case-insensitive on `Name` — the parser already
lowercases header names on the wire, so any-case input is normalized
before searching.
""".
-spec header(binary(), cactus_http1:request()) -> binary() | undefined.
header(Name, #{headers := H}) when is_binary(Name) ->
    Lower = string:lowercase(Name),
    case lists:keyfind(Lower, 1, H) of
        {_, Value} -> Value;
        false -> undefined
    end.
