-module(cactus_static).
-moduledoc """
Built-in static file handler.

Configure via a 3-tuple route with `#{dir => Path}` opts and a
`*path` wildcard segment carrying the relative file path:

```
{~"/static/*path", cactus_static, #{dir => ~"/var/www"}}
```

Reads the file from disk, sets `Content-Type` from the extension,
returns 404 on a missing file or any path that contains `..`.
""".

-behaviour(cactus_handler).

-export([handle/1]).

-define(MIME_TYPES, #{
    ~".html" => ~"text/html; charset=utf-8",
    ~".css" => ~"text/css; charset=utf-8",
    ~".js" => ~"application/javascript",
    ~".json" => ~"application/json",
    ~".png" => ~"image/png",
    ~".jpg" => ~"image/jpeg",
    ~".jpeg" => ~"image/jpeg",
    ~".gif" => ~"image/gif",
    ~".svg" => ~"image/svg+xml",
    ~".ico" => ~"image/x-icon",
    ~".txt" => ~"text/plain; charset=utf-8"
}).

-spec handle(cactus_http1:request()) -> cactus_resp:response().
handle(Req) ->
    #{dir := Dir} = cactus_req:route_opts(Req),
    Segments = maps:get(~"path", cactus_req:bindings(Req), []),
    case validate_segments(Segments) of
        ok ->
            FilePath = filename:join([Dir | Segments]),
            serve_file(FilePath);
        traversal ->
            cactus_resp:not_found()
    end.

-spec serve_file(file:filename_all()) -> cactus_resp:response().
serve_file(FilePath) ->
    case file:read_file(FilePath) of
        {ok, Bytes} ->
            Ext = string:lowercase(
                iolist_to_binary(filename:extension(FilePath))
            ),
            ContentType = maps:get(Ext, ?MIME_TYPES, ~"application/octet-stream"),
            {200,
                [
                    {~"content-type", ContentType},
                    {~"content-length", integer_to_binary(byte_size(Bytes))}
                ],
                Bytes};
        {error, _} ->
            cactus_resp:not_found()
    end.

%% Reject any segment that's `..` — defense against path traversal.
%% Empty segments are already stripped by `cactus_router:path_segments/1`.
-spec validate_segments([binary()]) -> ok | traversal.
validate_segments(Segments) ->
    case lists:any(fun(S) -> S =:= ~".." end, Segments) of
        true -> traversal;
        false -> ok
    end.
