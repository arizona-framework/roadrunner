-module(cactus_req).
-moduledoc """
Pure accessors over a `cactus_http1:request()` map.

Decouples handler code from the underlying map shape — handlers should
prefer these functions over direct `maps:get/2` so the request
representation can evolve without breaking them.
""".

-export([
    method/1,
    path/1,
    qs/1,
    version/1,
    headers/1,
    header/2,
    parse_qs/1,
    parse_cookies/1,
    body/1,
    bindings/1
]).

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

-doc """
Parse the query string portion of the request target into a list of
`{Key, Value}` pairs (or `{Key, true}` for bare flags) via
`cactus_qs:parse/1`.

Returns `[]` when the target has no query component.
""".
-spec parse_qs(cactus_http1:request()) -> [{binary(), binary() | true}].
parse_qs(Req) ->
    cactus_qs:parse(qs(Req)).

-doc """
Parse the `Cookie` request header into a list of `{Name, Value}` pairs
via `cactus_cookie:parse/1`.

Returns `[]` when the request carries no `Cookie` header.
""".
-spec parse_cookies(cactus_http1:request()) -> [{binary(), binary()}].
parse_cookies(Req) ->
    case header(~"cookie", Req) of
        undefined -> [];
        Value -> cactus_cookie:parse(Value)
    end.

-doc """
Return the buffered request body bytes as seen by the handler.

The connection process embeds whatever bytes followed the header block
under the `body` map key before invoking the handler. Body framing
(Content-Length / chunked) is not yet applied — this exposes the raw
buffer the parser carried over.

Returns `<<>>` when the request has no body field (e.g. when a request
map is constructed manually outside the connection pipeline).
""".
-spec body(cactus_http1:request()) -> binary().
body(#{body := B}) -> B;
body(_) -> <<>>.

-doc """
Return the router-captured bindings for this request as a
`#{Name => Value}` map of binaries.

`cactus_conn` populates this from `cactus_router:match/2` before
invoking the handler. Empty map when the listener is in single-handler
mode (no router) or the matched route has no `:param` segments.
""".
-spec bindings(cactus_http1:request()) -> cactus_router:bindings().
bindings(#{bindings := B}) -> B;
bindings(_) -> #{}.
