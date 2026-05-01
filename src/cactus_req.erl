-module(cactus_req).
-moduledoc """
Pure accessors over a `cactus_http1:request()` map.

Decouples handler code from the underlying map shape — handlers should
prefer these functions over direct `maps:get/2` so the request
representation can evolve without breaking them.
""".

-export([
    method/1,
    method_is/2,
    path/1,
    qs/1,
    version/1,
    headers/1,
    header/2,
    has_header/2,
    parse_qs/1,
    parse_cookies/1,
    body/1,
    has_body/1,
    read_body/1,
    read_body/2,
    read_body_chunked/1,
    read_form/1,
    bindings/1,
    peer/1,
    forwarded_for/1,
    scheme/1,
    route_opts/1
]).

-doc "Return the request method (uppercase ASCII binary).".
-spec method(cactus_http1:request()) -> binary().
method(#{method := M}) -> M.

-doc """
Return whether the request method matches the given binary.

Comparison is byte-exact and case-sensitive — the parser already
enforces uppercase methods on the wire, so callers should pass
uppercase too (`~"GET"`, `~"POST"`, etc.).
""".
-spec method_is(binary(), cactus_http1:request()) -> boolean().
method_is(Method, #{method := M}) when is_binary(Method) ->
    Method =:= M.

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
Return whether `Name` is present in the request headers.

Lookup is case-insensitive on `Name` — same convention as `header/2`.
""".
-spec has_header(binary(), cactus_http1:request()) -> boolean().
has_header(Name, #{headers := H}) when is_binary(Name) ->
    lists:keymember(string:lowercase(Name), 1, H).

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
Return whether the request carries a non-empty body.

Returns `false` for both an absent `body` field and an empty body
binary — handlers can use this as a short-circuit before doing any
body-aware work.
""".
-spec has_body(cactus_http1:request()) -> boolean().
has_body(#{body := B}) -> B =/= <<>>;
has_body(_) -> false.

-doc """
Read the request body in one shot. Works in both `auto` and `manual`
body-buffering modes:

- **auto** (default): the conn already buffered the body before
  invoking the handler — this returns the buffered bytes unchanged.
  `Req` is returned as-is.
- **manual**: the conn parked the body on the socket. This drains it
  and returns the bytes. The returned `Req2` carries the updated
  body-read state — to enable keep-alive on the same connection in
  manual mode, hand `Req2` back via the 4-tuple handler return shape
  `{Status, Headers, Body, Req2}` so the conn can drain whatever the
  handler skipped.
""".
-spec read_body(cactus_http1:request()) ->
    {ok, binary(), cactus_http1:request()} | {error, term()}.
read_body(Req) ->
    read_body(Req, #{}).

-doc """
Read the request body, optionally bounded by `length`.

`Opts` may contain `length => non_neg_integer()`. If absent, behaves
like `read_body/1` (drain to end). When set, returns up to `Length`
bytes per call:

- `{ok, Bytes, Req2}` — body is fully drained (no more bytes left).
- `{more, Bytes, Req2}` — more bytes remain; call again with `Req2`.

Works for both content-length and chunked framing — chunked bodies
are streamed transparently across chunk boundaries up to `Length`
bytes per call.

In `auto` mode the body is already buffered, so `length` has no
effect — the buffered bytes are returned in one shot.
""".
-spec read_body(cactus_http1:request(), #{length => non_neg_integer()}) ->
    {ok, binary(), cactus_http1:request()}
    | {more, binary(), cactus_http1:request()}
    | {error, term()}.
read_body(#{body_state := BS} = Req, Opts) ->
    Mode =
        case Opts of
            #{length := L} -> {length, L};
            _ -> all
        end,
    case cactus_conn:consume_body_state(BS, Mode) of
        {ok, Bytes, BS2} ->
            {ok, Bytes, Req#{body_state := BS2, body => Bytes}};
        {more, Bytes, BS2} ->
            {more, Bytes, Req#{body_state := BS2}};
        {error, _} = E ->
            E
    end;
read_body(Req, _Opts) ->
    %% Auto mode (or a manually-constructed req): the body is already
    %% sitting in the `body` field — return it.
    {ok, body(Req), Req}.

-doc """
Read the next decoded HTTP chunk from a chunked-encoded request body.

Mirrors cowboy's chunk-at-a-time read pattern: each call returns one
chunk's payload. `{more, Bytes, Req2}` means more chunks remain;
`{ok, <<>>, Req2}` signals end-of-body (the size-0 last chunk has
been seen).

For non-chunked framing (auto mode, content-length, or no body),
`read_body_chunked/1` falls through to `read_body/1`'s behavior — the
buffered body comes back in one shot. The "chunk boundary" concept
only applies to wire-level chunked transfer encoding.

Threading is the same as `read_body/1,2`: hand `Req2` back to the
conn via the `{Response, Req2}` handler return shape so any unread
chunks get drained for keep-alive.
""".
-spec read_body_chunked(cactus_http1:request()) ->
    {ok, binary(), cactus_http1:request()}
    | {more, binary(), cactus_http1:request()}
    | {error, term()}.
read_body_chunked(#{body_state := BS} = Req) ->
    case cactus_conn:consume_body_state(BS, next_chunk) of
        {ok, Bytes, BS2} ->
            {ok, Bytes, Req#{body_state := BS2, body => Bytes}};
        {more, Bytes, BS2} ->
            {more, Bytes, Req#{body_state := BS2}};
        {error, _} = E ->
            E
    end;
read_body_chunked(Req) ->
    {ok, body(Req), Req}.

-doc """
Read and parse a form-encoded request body. Inspects the request's
`Content-Type` and dispatches:

- `application/x-www-form-urlencoded[; …]` →
  `{ok, urlencoded, [{Name, Value | true}], Req2}`. Values are
  percent-decoded (and `+` → space) per `cactus_qs:parse/1`. Bare
  flags come back as `{Name, true}`.
- `multipart/form-data; boundary=…` →
  `{ok, multipart, [Part], Req2}` where each `Part` is the map
  returned by `cactus_multipart:parse/2` (`#{headers, body}`).
  `{error, no_boundary}` if the boundary parameter is missing.

Other content types return `{error, unsupported_content_type}`;
absent `Content-Type` returns `{error, no_content_type}`. Reads the
body via `read_body/1` (so works in both `auto` and `manual`
buffering modes), and threads `Req2` back so trailing body bytes
get drained on keep-alive.
""".
-spec read_form(cactus_http1:request()) ->
    {ok, urlencoded, [{binary(), binary() | true}], cactus_http1:request()}
    | {ok, multipart, [cactus_multipart:part()], cactus_http1:request()}
    | {error, no_content_type | unsupported_content_type | no_boundary | term()}.
read_form(Req) ->
    case header(~"content-type", Req) of
        undefined ->
            {error, no_content_type};
        ContentType ->
            dispatch_form(content_type_kind(ContentType), ContentType, Req)
    end.

-spec content_type_kind(binary()) -> urlencoded | multipart | unsupported.
content_type_kind(ContentType) ->
    [Type | _] = binary:split(ContentType, ~";"),
    case string:lowercase(string:trim(Type)) of
        ~"application/x-www-form-urlencoded" -> urlencoded;
        ~"multipart/form-data" -> multipart;
        _ -> unsupported
    end.

-spec dispatch_form(urlencoded | multipart | unsupported, binary(), cactus_http1:request()) ->
    {ok, urlencoded, [{binary(), binary() | true}], cactus_http1:request()}
    | {ok, multipart, [cactus_multipart:part()], cactus_http1:request()}
    | {error, term()}.
dispatch_form(urlencoded, _ContentType, Req) ->
    case read_body(Req) of
        {ok, Body, Req2} -> {ok, urlencoded, cactus_qs:parse(Body), Req2};
        {error, _} = E -> E
    end;
dispatch_form(multipart, ContentType, Req) ->
    case cactus_multipart:boundary(ContentType) of
        {ok, Boundary} ->
            case read_body(Req) of
                {ok, Body, Req2} ->
                    case cactus_multipart:parse(Body, Boundary) of
                        {ok, Parts} -> {ok, multipart, Parts, Req2};
                        {error, _} = E -> E
                    end;
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end;
dispatch_form(unsupported, _ContentType, _Req) ->
    {error, unsupported_content_type}.

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

-doc """
Return the TCP peer (`{IpAddress, Port}`) for the connection that
delivered this request.

`cactus_conn` populates this from `inet:peername/1` once per
connection. Returns `undefined` when the request map has no peer
field (e.g. constructed manually outside the connection pipeline) or
when the OS call failed at accept time.
""".
-spec peer(cactus_http1:request()) ->
    {inet:ip_address(), inet:port_number()} | undefined.
peer(#{peer := P}) -> P;
peer(_) -> undefined.

-doc """
Return the leftmost client identifier from the `Forwarded` header
(RFC 7239) or, if absent, from `X-Forwarded-For`. Returns `undefined`
when neither header is set or the `Forwarded` header has no `for=`
parameter.

The returned binary is whatever the proxy chose to put there — for
RFC 7239 that's typically an IP literal (`192.0.2.60`) or a quoted
IPv6+port (`[2001:db8::1]:4711`); for `X-Forwarded-For` it's
conventionally just the IP. The caller decides how to parse it.

**No trust list is enforced.** Anyone who can speak to the listener
directly can spoof these headers — only call this when the deploy
sits behind a trusted reverse proxy that strips/overwrites them.
""".
-spec forwarded_for(cactus_http1:request()) -> binary() | undefined.
forwarded_for(Req) ->
    case header(~"forwarded", Req) of
        undefined ->
            x_forwarded_for(Req);
        Value ->
            %% First forwarded-element wins; multiple proxies append
            %% comma-separated entries with the original client leftmost.
            [First | _] = binary:split(Value, ~","),
            empty_to_undefined(
                find_for_param(binary:split(string:trim(First), ~";", [global]))
            )
    end.

%% Normalize empty values to `undefined` so callers can pattern-match
%% one shape regardless of which header path produced the result.
-spec empty_to_undefined(binary() | undefined) -> binary() | undefined.
empty_to_undefined(<<>>) -> undefined;
empty_to_undefined(Other) -> Other.

-spec x_forwarded_for(cactus_http1:request()) -> binary() | undefined.
x_forwarded_for(Req) ->
    case header(~"x-forwarded-for", Req) of
        undefined ->
            undefined;
        Value ->
            [First | _] = binary:split(Value, ~","),
            case string:trim(First) of
                <<>> -> undefined;
                Trimmed -> Trimmed
            end
    end.

-spec find_for_param([binary()]) -> binary() | undefined.
find_for_param([]) ->
    undefined;
find_for_param([Pair | Rest]) ->
    case binary:split(Pair, ~"=") of
        [Key, Val] ->
            case string:lowercase(string:trim(Key)) of
                ~"for" -> unquote_param(string:trim(Val));
                _ -> find_for_param(Rest)
            end;
        _ ->
            find_for_param(Rest)
    end.

-spec unquote_param(binary()) -> binary().
unquote_param(<<$", Rest/binary>>) ->
    case binary:match(Rest, ~"\"") of
        {End, _} -> binary:part(Rest, 0, End);
        nomatch -> Rest
    end;
unquote_param(Bin) ->
    Bin.

-doc """
Return the connection scheme — `http` for plain TCP, `https` for TLS.

`cactus_conn` sets this once per connection from the transport tag.
Defaults to `http` for request maps constructed manually outside the
connection pipeline.
""".
-spec scheme(cactus_http1:request()) -> http | https.
scheme(#{scheme := S}) -> S;
scheme(_) -> http.

-doc """
Return the opaque per-route opts attached at compile time via the
3-tuple route shape `{Path, Handler, Opts}`.

`undefined` for 2-tuple routes and for single-handler dispatch (no
router involved).
""".
-spec route_opts(cactus_http1:request()) -> term().
route_opts(#{route_opts := O}) -> O;
route_opts(_) -> undefined.
