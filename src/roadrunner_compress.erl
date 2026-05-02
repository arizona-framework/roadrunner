-module(roadrunner_compress).
-moduledoc """
Gzip response-compression middleware.

Add to a listener's `middlewares` opt (or a route's `route_opts.middlewares`)
to gzip eligible response bodies based on the request's `Accept-Encoding`
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

- The client's `Accept-Encoding` header includes `gzip` (substring match).
- The handler's response does not already carry a `Content-Encoding`
  header (i.e. it isn't already compressed).
- The body is at least `?THRESHOLD` bytes (default 860 — same as
  cowboy's default; below this the compression overhead outweighs
  the bandwidth saving).

When compressed:

- `Content-Encoding: gzip` is added.
- `Content-Length` is rewritten to the compressed size.
- `Vary: Accept-Encoding` is added.

When not compressed (body too small, client doesn't accept gzip,
or response already encoded), the response passes through unchanged
**except** that `Vary: Accept-Encoding` is added if the client
indicated `Accept-Encoding: gzip` — caches that key on this header
will then handle the next variant correctly.

## What this does NOT cover

- **Streaming responses (`{stream, ...}`)** — passed through unchanged.
  Wrapping the user's `Send` callback with a deflate context is a
  follow-up; `zlib:deflateInit/2,6` + `zlib:deflate/3` + final
  `zlib:deflate(_, finish)` is the recipe.
- **`{loop, ...}` and `{websocket, ...}` returns** — passed through;
  these aren't HTTP body responses.
""".

-behaviour(roadrunner_middleware).

-export([call/2]).

-define(THRESHOLD, 860).

-spec call(roadrunner_http1:request(), roadrunner_middleware:next()) -> roadrunner_handler:result().
call(Req, Next) ->
    {Response, Req2} = Next(Req),
    {transform(Req, Response), Req2}.

-spec transform(roadrunner_http1:request(), roadrunner_handler:response()) ->
    roadrunner_handler:response().
transform(Req, {Status, Headers, Body}) when is_integer(Status) ->
    AcceptsGzip = accepts_gzip(Req),
    AlreadyEncoded = has_header(~"content-encoding", Headers),
    Size = iolist_size(Body),
    case AcceptsGzip andalso not AlreadyEncoded andalso Size >= ?THRESHOLD of
        true ->
            compress(Status, Headers, Body);
        false ->
            HeadersWithVary =
                case AcceptsGzip andalso not AlreadyEncoded of
                    true -> add_vary(Headers);
                    false -> Headers
                end,
            {Status, HeadersWithVary, Body}
    end;
transform(Req, {stream, Status, Headers, Fun}) when is_integer(Status), is_function(Fun, 1) ->
    case accepts_gzip(Req) andalso not has_header(~"content-encoding", Headers) of
        true ->
            wrap_stream(Status, Headers, Fun);
        false ->
            {stream, Status, Headers, Fun}
    end;
transform(_Req, Other) ->
    %% loop / websocket — pass through. Streaming gzip would need to
    %% intercept the per-message Push fun in `roadrunner_conn:loop_response/5`,
    %% which isn't wired through the response shape; defer until needed.
    Other.

%% Wrap a stream response: each chunk passes through a deflate context
%% configured for gzip output (windowBits = 16 + 15). The user's `Fun`
%% sees a `Send2` callback that compresses on the way out and forwards
%% the deflated bytes to the conn's real `Send`. The zlib context is
%% released in a `try/after` so a crashing user fun doesn't leak the
%% resource (the conn process death would also release it via the VM,
%% but explicit cleanup is clearer).
-spec wrap_stream(
    roadrunner_http1:status(), roadrunner_http1:headers(), roadrunner_handler:stream_fun()
) ->
    roadrunner_handler:response().
wrap_stream(Status, Headers, Fun) ->
    NewHeaders = [
        {~"content-encoding", ~"gzip"},
        {~"vary", ~"Accept-Encoding"}
        | Headers
    ],
    WrappedFun = fun(Send) ->
        Z = zlib:open(),
        try
            ok = zlib:deflateInit(Z, default, deflated, 16 + 15, 8, default),
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

-spec compress(roadrunner_http1:status(), roadrunner_http1:headers(), iodata()) ->
    roadrunner_handler:response().
compress(Status, Headers, Body) ->
    Compressed = zlib:gzip(iolist_to_binary(Body)),
    NewLength = integer_to_binary(byte_size(Compressed)),
    %% Replace any existing Content-Length, drop the no-op (since gzip is
    %% already absent at this point per the caller's check), then prepend
    %% Content-Encoding + Vary.
    Headers1 = lists:keystore(~"content-length", 1, Headers, {~"content-length", NewLength}),
    Headers2 = [
        {~"content-encoding", ~"gzip"},
        {~"vary", ~"Accept-Encoding"}
        | Headers1
    ],
    {Status, Headers2, Compressed}.

-spec accepts_gzip(roadrunner_http1:request()) -> boolean().
accepts_gzip(Req) ->
    case roadrunner_req:header(~"accept-encoding", Req) of
        undefined ->
            false;
        Value ->
            Lower = string:lowercase(Value),
            lists:any(
                fun(Token) ->
                    Trimmed = string:trim(Token),
                    Trimmed =:= ~"gzip" orelse
                        binary:match(Trimmed, ~"gzip") =/= nomatch
                end,
                binary:split(Lower, ~",", [global])
            )
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
