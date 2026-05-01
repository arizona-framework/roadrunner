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
                    serve_with_range(FilePath, Size, ETag, Req)
            end;
        _ ->
            cactus_resp:not_found()
    end.

%% Branches on the Range header: satisfiable single range → 206,
%% unsatisfiable → 416, anything else (no header, malformed, multi-range)
%% → fall through to a normal 200 with the full body.
-spec serve_with_range(file:filename_all(), non_neg_integer(), binary(), cactus_http1:request()) ->
    cactus_resp:response().
serve_with_range(FilePath, Size, ETag, Req) ->
    case parse_range(cactus_req:header(~"range", Req), Size) of
        {range, Start, End} ->
            serve_range(FilePath, Size, ETag, Start, End);
        unsatisfiable ->
            range_not_satisfiable(Size, ETag);
        none ->
            serve_full_file(FilePath, ETag)
    end.

%% read_file_info already established the file exists and is regular;
%% if read_file then fails (race with deletion, permission flip, etc.)
%% the exception bubbles up to the conn's standard handler-crash path
%% and the client sees a 500. That's a strictly rarer case than
%% 404-on-missing-file which is handled in `serve_file/2` above.
-spec serve_full_file(file:filename_all(), binary()) -> cactus_resp:response().
serve_full_file(FilePath, ETag) ->
    {ok, Bytes} = file:read_file(FilePath),
    {200,
        [
            {~"content-type", content_type_for(FilePath)},
            {~"content-length", integer_to_binary(byte_size(Bytes))},
            {~"etag", ETag}
        ],
        Bytes}.

-spec content_type_for(file:filename_all()) -> binary().
content_type_for(FilePath) ->
    Ext = string:lowercase(iolist_to_binary(filename:extension(FilePath))),
    maps:get(Ext, ?MIME_TYPES, ~"application/octet-stream").

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

%% Parse a `Range: bytes=N-M`, `bytes=N-`, or `bytes=-S` header against
%% the file `Size`. `none` means "ignore Range and serve the full body"
%% — used for missing, malformed, multi-range, and other shapes we
%% don't honor (per RFC 7233 §3.1: servers MUST ignore unknown range
%% units). `unsatisfiable` triggers a 416.
-spec parse_range(binary() | undefined, non_neg_integer()) ->
    {range, non_neg_integer(), non_neg_integer()} | unsatisfiable | none.
parse_range(undefined, _Size) ->
    none;
parse_range(<<"bytes=", Spec/binary>>, Size) ->
    case binary:match(Spec, ~",") of
        nomatch -> parse_single_range(Spec, Size);
        %% Multi-range — falls back to a 200 with the full body.
        _ -> none
    end;
parse_range(_, _Size) ->
    none.

-spec parse_single_range(binary(), non_neg_integer()) ->
    {range, non_neg_integer(), non_neg_integer()} | unsatisfiable | none.
parse_single_range(Spec, Size) ->
    case binary:split(Spec, ~"-") of
        [<<>>, SuffixLen] ->
            %% `bytes=-S` — last S bytes.
            case bin_to_pos_int(SuffixLen) of
                {ok, S} when S > 0, Size > 0 ->
                    Start = max(0, Size - S),
                    {range, Start, Size - 1};
                {ok, _} ->
                    %% Well-formed but unsatisfiable: zero-length suffix
                    %% or empty file.
                    unsatisfiable;
                error ->
                    %% Malformed (non-numeric, negative): per RFC 7233
                    %% §3.1 the server MUST ignore Range.
                    none
            end;
        [StartBin, <<>>] ->
            %% `bytes=N-` — open-ended.
            case bin_to_pos_int(StartBin) of
                {ok, Start} when Start < Size ->
                    {range, Start, Size - 1};
                {ok, _} ->
                    unsatisfiable;
                error ->
                    none
            end;
        [StartBin, EndBin] ->
            case {bin_to_pos_int(StartBin), bin_to_pos_int(EndBin)} of
                {{ok, Start}, {ok, End}} when Start =< End, Start < Size ->
                    {range, Start, min(End, Size - 1)};
                {{ok, _}, {ok, _}} ->
                    unsatisfiable;
                _ ->
                    none
            end;
        _ ->
            none
    end.

-spec bin_to_pos_int(binary()) -> {ok, non_neg_integer()} | error.
bin_to_pos_int(Bin) ->
    try binary_to_integer(Bin) of
        N when N >= 0 -> {ok, N};
        _ -> error
    catch
        _:_ -> error
    end.

-spec serve_range(
    file:filename_all(), non_neg_integer(), binary(), non_neg_integer(), non_neg_integer()
) -> cactus_resp:response().
serve_range(FilePath, Size, ETag, Start, End) ->
    Length = End - Start + 1,
    {ok, IoDevice} = file:open(FilePath, [read, binary, raw]),
    try
        {ok, Bytes} = file:pread(IoDevice, Start, Length),
        ContentRange = iolist_to_binary([
            ~"bytes ",
            integer_to_binary(Start),
            $-,
            integer_to_binary(End),
            $/,
            integer_to_binary(Size)
        ]),
        {206,
            [
                {~"content-type", content_type_for(FilePath)},
                {~"content-length", integer_to_binary(byte_size(Bytes))},
                {~"content-range", ContentRange},
                {~"etag", ETag}
            ],
            Bytes}
    after
        ok = file:close(IoDevice)
    end.

-spec range_not_satisfiable(non_neg_integer(), binary()) -> cactus_resp:response().
range_not_satisfiable(Size, ETag) ->
    %% RFC 7233 §4.4: 416 SHOULD include Content-Range with the total
    %% size so clients can recover.
    ContentRange = iolist_to_binary([~"bytes */", integer_to_binary(Size)]),
    {416,
        [
            {~"content-length", ~"0"},
            {~"content-range", ContentRange},
            {~"etag", ETag}
        ],
        ~""}.

%% Reject any segment that's `..` — defense against path traversal.
%% Empty segments are already stripped by `cactus_router:path_segments/1`.
-spec validate_segments([binary()]) -> ok | traversal.
validate_segments(Segments) ->
    case lists:any(fun(S) -> S =:= ~".." end, Segments) of
        true -> traversal;
        false -> ok
    end.
