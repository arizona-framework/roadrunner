-module(roadrunner_compress).
-moduledoc """
Response-compression middleware. Supports `gzip` and `deflate`
Content-Encoding per RFC 9110 §8.4.1.

Add to a listener's `middlewares` opt (or a route's `route_opts.middlewares`)
to compress eligible response bodies based on the request's `Accept-Encoding`
header. Replaces cowboy's deprecated `cowboy_compress_h` stream handler
for arizona's migration.

```erlang
roadrunner_listener:start_link(my_app, #{
    port => 8080,
    routes => Routes,
    middlewares => [roadrunner_compress]
}).
```

A response is compressed when **all** of these are true:

- The client's `Accept-Encoding` header includes `gzip` or `deflate`
  (substring match per token; qvalue ranking is a follow-up).
- The handler's response does not already carry a `Content-Encoding`
  header (i.e. it isn't already compressed).
- The body is at least `?THRESHOLD` bytes (default 860 — same as
  cowboy's default; below this the compression overhead outweighs
  the bandwidth saving).

When compressed:

- `Content-Encoding: gzip` (or `deflate`) is added.
- `Content-Length` is rewritten to the compressed size.
- `Vary: Accept-Encoding` is added.

When not compressed (body too small, client doesn't accept any
supported encoding, or response already encoded), the response
passes through unchanged **except** that `Vary: Accept-Encoding` is
added if the client indicated a supported encoding — caches that
key on this header will then handle the next variant correctly.

## Encoding selection

When the client accepts both gzip and deflate, **gzip wins**. gzip has
a more deterministic on-the-wire format (RFC 1952) and broader
client tolerance than `Content-Encoding: deflate` — historically
some servers shipped raw deflate (RFC 1951) instead of the
zlib-wrapped form RFC 9110 §8.4.1.3 mandates (RFC 1950), and a
handful of older clients still ship workarounds for both shapes.
gzip avoids the question.

## What this does NOT cover

- **`{loop, ...}` and `{websocket, ...}` returns** — passed through;
  these aren't HTTP body responses.
- **Brotli (`br`) Content-Encoding** — would require a NIF dep
  (`brotli`); deferred until there's user pull.
- **Qvalue-aware Accept-Encoding parsing** — current implementation
  is substring-match per token; treats `gzip;q=0` as "accepts gzip"
  (a real conformance bug). Tracked separately.
""".

-behaviour(roadrunner_middleware).

-export([call/2]).

-define(THRESHOLD, 860).

-type encoding() :: gzip | deflate | none.

-spec call(roadrunner_http1:request(), roadrunner_middleware:next()) -> roadrunner_handler:result().
call(Req, Next) ->
    {Response, Req2} = Next(Req),
    {transform(Req, Response), Req2}.

-spec transform(roadrunner_http1:request(), roadrunner_handler:response()) ->
    roadrunner_handler:response().
transform(Req, {Status, Headers, Body}) when is_integer(Status) ->
    Encoding = negotiate_encoding(Req),
    AlreadyEncoded = has_header(~"content-encoding", Headers),
    Size = iolist_size(Body),
    case Encoding =/= none andalso not AlreadyEncoded andalso Size >= ?THRESHOLD of
        true ->
            compress(Status, Headers, Body, Encoding);
        false ->
            HeadersWithVary =
                case Encoding =/= none andalso not AlreadyEncoded of
                    true -> add_vary(Headers);
                    false -> Headers
                end,
            {Status, HeadersWithVary, Body}
    end;
transform(Req, {stream, Status, Headers, Fun}) when is_integer(Status), is_function(Fun, 1) ->
    case negotiate_encoding(Req) of
        none ->
            {stream, Status, Headers, Fun};
        Encoding ->
            case has_header(~"content-encoding", Headers) of
                true -> {stream, Status, Headers, Fun};
                false -> wrap_stream(Status, Headers, Fun, Encoding)
            end
    end;
transform(_Req, Other) ->
    %% loop / websocket — pass through. Streaming gzip would need to
    %% intercept the per-message Push fun in `roadrunner_loop_response`,
    %% which isn't wired through the response shape; defer until needed.
    Other.

%% Wrap a stream response: each chunk passes through a deflate context
%% configured for the negotiated encoding. The user's `Fun` sees a
%% `Send2` callback that compresses on the way out and forwards the
%% bytes to the conn's real `Send`. The zlib context is released in
%% a `try/after` so a crashing user fun doesn't leak the resource.
-spec wrap_stream(
    roadrunner_http1:status(),
    roadrunner_http1:headers(),
    roadrunner_handler:stream_fun(),
    gzip | deflate
) ->
    roadrunner_handler:response().
wrap_stream(Status, Headers, Fun, Encoding) ->
    NewHeaders = [
        {~"content-encoding", encoding_token(Encoding)},
        {~"vary", ~"Accept-Encoding"}
        | Headers
    ],
    WrappedFun = fun(Send) ->
        Z = zlib:open(),
        try
            ok = zlib:deflateInit(Z, default, deflated, window_bits(Encoding), 8, default),
            Send2 = fun(Data, FinFlag) ->
                %% `{fin, Trailers}` is the same deflate-side action as
                %% `fin` — finish flushing — but the trailers themselves
                %% are chunked-encoding metadata and pass through to the
                %% conn's Send unchanged.
                Mode =
                    case FinFlag of
                        nofin -> none;
                        fin -> finish;
                        {fin, _Trailers} -> finish
                    end,
                Compressed = zlib:deflate(Z, Data, Mode),
                Send(Compressed, FinFlag)
            end,
            Fun(Send2)
        after
            zlib:close(Z)
        end
    end,
    {stream, Status, NewHeaders, WrappedFun}.

-spec compress(
    roadrunner_http1:status(),
    roadrunner_http1:headers(),
    iodata(),
    gzip | deflate
) -> roadrunner_handler:response().
compress(Status, Headers, Body, Encoding) ->
    Compressed = compress_body(Body, Encoding),
    NewLength = integer_to_binary(byte_size(Compressed)),
    %% Replace any existing Content-Length, then prepend
    %% Content-Encoding + Vary.
    Headers1 = lists:keystore(~"content-length", 1, Headers, {~"content-length", NewLength}),
    Headers2 = [
        {~"content-encoding", encoding_token(Encoding)},
        {~"vary", ~"Accept-Encoding"}
        | Headers1
    ],
    {Status, Headers2, Compressed}.

%% RFC 9110 §8.4.1.3: "deflate" = zlib data format (RFC 1950) — i.e.
%% the 2-byte zlib header + raw deflate stream + Adler-32 checksum.
%% `zlib:compress/1` produces exactly that. NOT `zlib:zip/1`, which
%% emits a header-less raw deflate stream (RFC 1951) — non-conformant
%% to RFC 9110 even though some servers historically shipped it.
-spec compress_body(iodata(), gzip | deflate) -> binary().
compress_body(Body, gzip) -> zlib:gzip(iolist_to_binary(Body));
compress_body(Body, deflate) -> zlib:compress(iolist_to_binary(Body)).

%% `windowBits` selects the zlib stream wrapper:
%%   16 + 15 → gzip (RFC 1952 header)
%%        15 → zlib-wrapped (RFC 1950 header) — what RFC 9110 §8.4.1.3
%%             specifies for `Content-Encoding: deflate`.
-spec window_bits(gzip | deflate) -> integer().
window_bits(gzip) -> 16 + 15;
window_bits(deflate) -> 15.

-spec encoding_token(gzip | deflate) -> binary().
encoding_token(gzip) -> ~"gzip";
encoding_token(deflate) -> ~"deflate".

%% Pick the strongest supported encoding from `Accept-Encoding` per
%% RFC 9110 §12.5.3. Each token may carry `;q=N` (0.0–1.0); `q=0`
%% means explicit refusal. The wildcard `*` covers any encoding the
%% server supports but we don't otherwise see listed. Default qvalue
%% (no `;q=`) is 1.0. When two encodings tie on qvalue, gzip wins
%% (see moduledoc rationale).
%%
%% Returned: `gzip | deflate | none`. `none` if neither has an
%% effective q > 0.
-spec negotiate_encoding(roadrunner_http1:request()) -> encoding().
negotiate_encoding(Req) ->
    case roadrunner_req:header(~"accept-encoding", Req) of
        undefined ->
            none;
        Value ->
            Lower = roadrunner_bin:ascii_lowercase(Value),
            %% Walk tokens once, recording per-encoding qvalues.
            %% `Wildcard` covers any encoding name not seen; `Gzip`
            %% / `Deflate` override the wildcard. `undefined` means
            %% the encoding wasn't mentioned at all.
            {Gzip, Deflate, Wildcard} =
                walk_tokens(binary:split(Lower, ~",", [global]), undefined, undefined, undefined),
            choose(effective_q(Gzip, Wildcard), effective_q(Deflate, Wildcard))
    end.

-type qvalue() :: float() | undefined.

%% `effective_q` resolves "what qvalue applies to this encoding" given
%% the explicit value (if any) and the wildcard's value (if any).
%% Explicit overrides wildcard (RFC 9110: a more specific entry wins).
-spec effective_q(qvalue(), qvalue()) -> float().
effective_q(undefined, undefined) -> 0.0;
effective_q(undefined, Wildcard) -> Wildcard;
effective_q(Q, _) -> Q.

-spec choose(float(), float()) -> encoding().
choose(GzipQ, DeflateQ) when GzipQ > 0.0, GzipQ >= DeflateQ -> gzip;
choose(_GzipQ, DeflateQ) when DeflateQ > 0.0 -> deflate;
choose(_, _) -> none.

%% Walk the comma-split token list once, accumulating per-encoding
%% qvalues. Unrecognized encoding names (br, identity, etc.) are
%% ignored — they don't affect the gzip/deflate pick.
-spec walk_tokens([binary()], qvalue(), qvalue(), qvalue()) ->
    {qvalue(), qvalue(), qvalue()}.
walk_tokens([], Gzip, Deflate, Wildcard) ->
    {Gzip, Deflate, Wildcard};
walk_tokens([Token | Rest], Gzip, Deflate, Wildcard) ->
    {Name, Q} = parse_token(Token),
    case Name of
        ~"gzip" -> walk_tokens(Rest, Q, Deflate, Wildcard);
        ~"deflate" -> walk_tokens(Rest, Gzip, Q, Wildcard);
        ~"*" -> walk_tokens(Rest, Gzip, Deflate, Q);
        _ -> walk_tokens(Rest, Gzip, Deflate, Wildcard)
    end.

%% Parse one `name[;q=value]` token. Other parameters (`;level=fast`
%% and similar — RFC allows them though they're rarely used for
%% Accept-Encoding) are ignored; only `q=` is recognized.
-spec parse_token(binary()) -> {binary(), float()}.
parse_token(Token) ->
    case binary:split(Token, ~";", [global]) of
        [Name] ->
            {string:trim(Name), 1.0};
        [Name | Params] ->
            {string:trim(Name), find_q(Params, 1.0)}
    end.

-spec find_q([binary()], float()) -> float().
find_q([], Default) ->
    Default;
find_q([Param | Rest], Default) ->
    case string:trim(Param) of
        <<"q=", QBin/binary>> -> parse_q(QBin, Default);
        _ -> find_q(Rest, Default)
    end.

%% Parse the qvalue itself. RFC 9110 §12.4.2 allows 0, 0.NNN, 1, or
%% 1.000 (max 3 decimals). Anything malformed falls back to the
%% default.
-spec parse_q(binary(), float()) -> float().
parse_q(QBin, Default) ->
    case string:to_float(QBin) of
        {Float, _} when Float >= 0.0, Float =< 1.0 -> Float;
        _ ->
            case string:to_integer(QBin) of
                {0, _} -> 0.0;
                {1, _} -> 1.0;
                _ -> Default
            end
    end.

-spec has_header(binary(), roadrunner_http1:headers()) -> boolean().
has_header(Name, Headers) ->
    lists:keymember(Name, 1, Headers).

-spec add_vary(roadrunner_http1:headers()) -> roadrunner_http1:headers().
add_vary(Headers) ->
    case has_header(~"vary", Headers) of
        true -> Headers;
        false -> [{~"vary", ~"Accept-Encoding"} | Headers]
    end.
