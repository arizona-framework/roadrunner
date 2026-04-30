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

-include_lib("kernel/include/file.hrl").

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

-spec handle(cactus_http1:request()) -> cactus_handler:result().
handle(Req) ->
    #{dir := Dir} = cactus_req:route_opts(Req),
    Segments = maps:get(~"path", cactus_req:bindings(Req), []),
    Resp =
        case validate_segments(Segments) of
            ok ->
                FilePath = filename:join([Dir | Segments]),
                serve_file(FilePath, Req);
            traversal ->
                cactus_resp:not_found()
        end,
    {Resp, Req}.

-spec serve_file(file:filename_all(), cactus_http1:request()) -> cactus_resp:response().
serve_file(FilePath, Req) ->
    case file:read_file_info(FilePath, [{time, posix}]) of
        {ok, #file_info{type = regular, size = Size, mtime = Mtime}} ->
            ETag = etag(Size, Mtime),
            case if_none_match(Req) =:= ETag of
                true ->
                    {304, [{~"etag", ETag}, {~"content-length", ~"0"}], ~""};
                false ->
                    serve_full_file(FilePath, ETag)
            end;
        _ ->
            cactus_resp:not_found()
    end.

%% read_file_info already established the file exists and is regular;
%% if read_file then fails (race with deletion, permission flip, etc.)
%% the exception bubbles up to the conn's standard handler-crash path
%% and the client sees a 500. That's a strictly rarer case than
%% 404-on-missing-file which is handled in `serve_file/2` above.
-spec serve_full_file(file:filename_all(), binary()) -> cactus_resp:response().
serve_full_file(FilePath, ETag) ->
    {ok, Bytes} = file:read_file(FilePath),
    Ext = string:lowercase(iolist_to_binary(filename:extension(FilePath))),
    ContentType = maps:get(Ext, ?MIME_TYPES, ~"application/octet-stream"),
    {200,
        [
            {~"content-type", ContentType},
            {~"content-length", integer_to_binary(byte_size(Bytes))},
            {~"etag", ETag}
        ],
        Bytes}.

%% Strong ETag derived from size + posix mtime — RFC 9110 §8.8.3
%% format: opaque-tag wrapped in double quotes. Two files with the
%% same size and mtime collide; that's intentional (and matches how
%% nginx/apache build their default ETags).
-spec etag(non_neg_integer(), integer()) -> binary().
etag(Size, Mtime) ->
    <<$", (integer_to_binary(Size))/binary, $-, (integer_to_binary(Mtime))/binary, $">>.

-spec if_none_match(cactus_http1:request()) -> binary() | undefined.
if_none_match(Req) ->
    cactus_req:header(~"if-none-match", Req).

%% Reject any segment that's `..` — defense against path traversal.
%% Empty segments are already stripped by `cactus_router:path_segments/1`.
-spec validate_segments([binary()]) -> ok | traversal.
validate_segments(Segments) ->
    case lists:any(fun(S) -> S =:= ~".." end, Segments) of
        true -> traversal;
        false -> ok
    end.
