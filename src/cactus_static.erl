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

-spec serve_file(file:filename_all(), cactus_http1:request()) -> cactus_handler:response().
serve_file(FilePath, Req) ->
    case file:read_file_info(FilePath, [{time, posix}]) of
        {ok, #file_info{type = regular, size = Size, mtime = Mtime}} ->
            ETag = etag(Size, Mtime),
            LastMod = format_http_date(Mtime),
            case is_cached(Req, ETag, Mtime) of
                true ->
                    {304,
                        [
                            {~"etag", ETag},
                            {~"last-modified", LastMod},
                            {~"content-length", ~"0"}
                        ],
                        ~""};
                false ->
                    serve_with_range(FilePath, Size, ETag, LastMod, Req)
            end;
        _ ->
            cactus_resp:not_found()
    end.

%% Cache hit when either:
%% - `If-None-Match` matches the current ETag (strong validator), or
%% - `If-Modified-Since` ≥ the file's mtime (weak validator).
-spec is_cached(cactus_http1:request(), binary(), integer()) -> boolean().
is_cached(Req, ETag, Mtime) ->
    if_none_match(Req) =:= ETag orelse if_modified_since_satisfied(Req, Mtime).

-spec if_modified_since_satisfied(cactus_http1:request(), integer()) -> boolean().
if_modified_since_satisfied(Req, Mtime) ->
    case cactus_req:header(~"if-modified-since", Req) of
        undefined ->
            false;
        Value ->
            case parse_http_date(Value) of
                {ok, Posix} -> Posix >= Mtime;
                error -> false
            end
    end.

%% Branches on the Range header: satisfiable single range → 206,
%% unsatisfiable → 416, anything else (no header, malformed, multi-range)
%% → fall through to a normal 200 with the full body.
-spec serve_with_range(
    file:filename_all(),
    non_neg_integer(),
    binary(),
    binary(),
    cactus_http1:request()
) -> cactus_handler:response().
serve_with_range(FilePath, Size, ETag, LastMod, Req) ->
    case parse_range(cactus_req:header(~"range", Req), Size) of
        {range, Start, End} ->
            serve_range(FilePath, Size, ETag, LastMod, Start, End);
        unsatisfiable ->
            range_not_satisfiable(Size, ETag, LastMod);
        none ->
            serve_full_file(FilePath, Size, ETag, LastMod)
    end.

%% Returns a `{sendfile, ...}` response so the conn dispatches
%% `file:sendfile/5` (TCP) or a chunked read+send fallback (TLS) — the
%% file body is never copied through the Erlang heap.
-spec serve_full_file(
    file:filename_all(), non_neg_integer(), binary(), binary()
) -> cactus_handler:response().
serve_full_file(FilePath, Size, ETag, LastMod) ->
    {sendfile, 200,
        [
            {~"content-type", content_type_for(FilePath)},
            {~"content-length", integer_to_binary(Size)},
            {~"etag", ETag},
            {~"last-modified", LastMod}
        ],
        {FilePath, 0, Size}}.

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
    file:filename_all(),
    non_neg_integer(),
    binary(),
    binary(),
    non_neg_integer(),
    non_neg_integer()
) -> cactus_handler:response().
serve_range(FilePath, Size, ETag, LastMod, Start, End) ->
    Length = End - Start + 1,
    ContentRange = iolist_to_binary([
        ~"bytes ",
        integer_to_binary(Start),
        $-,
        integer_to_binary(End),
        $/,
        integer_to_binary(Size)
    ]),
    {sendfile, 206,
        [
            {~"content-type", content_type_for(FilePath)},
            {~"content-length", integer_to_binary(Length)},
            {~"content-range", ContentRange},
            {~"etag", ETag},
            {~"last-modified", LastMod}
        ],
        {FilePath, Start, Length}}.

-spec range_not_satisfiable(non_neg_integer(), binary(), binary()) -> cactus_handler:response().
range_not_satisfiable(Size, ETag, LastMod) ->
    %% RFC 7233 §4.4: 416 SHOULD include Content-Range with the total
    %% size so clients can recover.
    ContentRange = iolist_to_binary([~"bytes */", integer_to_binary(Size)]),
    {416,
        [
            {~"content-length", ~"0"},
            {~"content-range", ContentRange},
            {~"etag", ETag},
            {~"last-modified", LastMod}
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

%% Format a posix timestamp as IMF-fixdate (RFC 7231 §7.1.1.1) — the
%% canonical HTTP date format. Example: `Sun, 06 Nov 1994 08:49:37 GMT`.
-spec format_http_date(integer()) -> binary().
format_http_date(Posix) ->
    {{Y, M, D}, {H, Mi, S}} = calendar:system_time_to_universal_time(Posix, second),
    DayName = day_name(calendar:day_of_the_week(Y, M, D)),
    MonthName = month_name(M),
    iolist_to_binary(
        io_lib:format(
            "~s, ~2..0B ~s ~4..0B ~2..0B:~2..0B:~2..0B GMT",
            [DayName, D, MonthName, Y, H, Mi, S]
        )
    ).

%% Parse an IMF-fixdate header back into a posix timestamp. Returns
%% `error` for any other format (we don't bother with the legacy RFC 850
%% or asctime forms; modern clients all emit IMF-fixdate).
-spec parse_http_date(binary()) -> {ok, integer()} | error.
parse_http_date(<<
    _DayName:3/binary,
    ", ",
    D1,
    D2,
    " ",
    Mon:3/binary,
    " ",
    Y1,
    Y2,
    Y3,
    Y4,
    " ",
    H1,
    H2,
    ":",
    Mi1,
    Mi2,
    ":",
    S1,
    S2,
    " GMT"
>>) ->
    try
        Day = list_to_integer([D1, D2]),
        Year = list_to_integer([Y1, Y2, Y3, Y4]),
        Hour = list_to_integer([H1, H2]),
        Minute = list_to_integer([Mi1, Mi2]),
        Second = list_to_integer([S1, S2]),
        Month = month_number(Mon),
        DateTime = {{Year, Month, Day}, {Hour, Minute, Second}},
        Epoch = calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}),
        {ok, calendar:datetime_to_gregorian_seconds(DateTime) - Epoch}
    catch
        _:_ -> error
    end;
parse_http_date(_) ->
    error.

day_name(N) ->
    element(N, {"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"}).

month_name(N) ->
    element(
        N,
        {"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
    ).

%% `maps:get/2` raises `{badkey, _}` on an unknown month abbreviation;
%% the surrounding try/catch in `parse_http_date/1` turns that into
%% the `error` return, which is what we want for malformed input.
month_number(Mon) ->
    maps:get(Mon, #{
        ~"Jan" => 1,
        ~"Feb" => 2,
        ~"Mar" => 3,
        ~"Apr" => 4,
        ~"May" => 5,
        ~"Jun" => 6,
        ~"Jul" => 7,
        ~"Aug" => 8,
        ~"Sep" => 9,
        ~"Oct" => 10,
        ~"Nov" => 11,
        ~"Dec" => 12
    }).
