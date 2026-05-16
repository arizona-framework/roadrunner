-module(roadrunner_static).
-moduledoc """
Built-in static file handler.

Configure via a 3-tuple route with `#{dir => Path}` opts and a
`*path` wildcard segment carrying the relative file path:

```
{~"/static/*path", roadrunner_static, #{dir => ~"/var/www"}}
```

Reads the file from disk, sets `Content-Type` from the extension,
returns 404 on a missing file or any path that contains `..`.

## Gzip-sibling serving

When a request carries `Accept-Encoding: gzip` and the requested
file has a `<file>.gz` sibling on disk, the sibling is served
verbatim with `Content-Encoding: gzip` plus `Vary: Accept-Encoding`.
This matches nginx's `gzip_static on` behaviour and lets operators
pre-compress build assets once instead of paying the deflate cost
per request.

`Accept-Encoding` is matched via plain substring (`gzip`) rather
than full RFC 9110 §12.5.3 qvalue ranking. The static path is
typically hit by browsers and benchmark clients that always
include `gzip` plainly. Brotli (`.br`) siblings are not served —
gzip is the universally supported encoding.

The original file's ETag is reused for the gzip variant, so a
follow-up `If-None-Match` returns 304 regardless of which variant
was first served. A `Range` request disables the gzip path on that
request — byte offsets over a compressed representation have
subtle semantics and the simple "Range wins" rule matches what
nginx does.

## Symlink policy

`#{symlink_policy => Policy}` (default `refuse_escapes`) controls
how symlinks inside the docroot are handled. The policy applies to
the **leaf** of the requested path — symlinks in intermediate
directories are still followed by the kernel.

- `refuse_escapes` (default) — symlinks whose target resolves
  inside `dir` are followed; symlinks pointing outside (e.g. an
  absolute target like `/etc/passwd`, or a relative target with
  `..` segments) return 404. Stricter than nginx/Apache defaults
  but matches what an operator typically wants for a public
  docroot.
- `follow` — every symlink is followed regardless of where it
  points (nginx `disable_symlinks off` equivalent). Use only when
  the docroot's filesystem permissions prevent untrusted writes.
- `refuse` — every symlink returns 404, even safe in-docroot ones.
""".

-behaviour(roadrunner_handler).

-include_lib("kernel/include/file.hrl").

-on_load(init_patterns/0).

-define(COMMA_CP_KEY, {?MODULE, comma_cp}).
-define(DASH_CP_KEY, {?MODULE, dash_cp}).

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

-spec handle(roadrunner_req:request()) -> roadrunner_handler:result().
handle(Req) ->
    #{dir := Dir} = roadrunner_req:route_opts(Req),
    Segments = maps:get(~"path", roadrunner_req:bindings(Req), []),
    Resp =
        case validate_segments(Segments) of
            ok ->
                FilePath = filename:join([Dir | Segments]),
                serve_file(FilePath, Req);
            traversal ->
                roadrunner_resp:not_found()
        end,
    {Resp, Req}.

-spec serve_file(file:filename_all(), roadrunner_req:request()) -> roadrunner_handler:response().
serve_file(FilePath, Req) ->
    %% `read_link_info/1` does not follow the leaf symlink — we need
    %% the un-followed type so the symlink-policy gate can decide
    %% whether the target is allowed to be served.
    case file:read_link_info(FilePath, [{time, posix}]) of
        {ok, #file_info{type = symlink}} ->
            case symlink_allowed(FilePath, Req) of
                true -> serve_followed_file(FilePath, Req);
                false -> roadrunner_resp:not_found()
            end;
        {ok, #file_info{type = regular, size = Size, mtime = Mtime}} ->
            serve_regular_file(FilePath, Size, Mtime, Req);
        _ ->
            roadrunner_resp:not_found()
    end.

%% Read leaf-stat after the symlink-policy gate has approved follow.
-spec serve_followed_file(file:filename_all(), roadrunner_req:request()) ->
    roadrunner_handler:response().
serve_followed_file(FilePath, Req) ->
    case file:read_file_info(FilePath, [{time, posix}]) of
        {ok, #file_info{type = regular, size = Size, mtime = Mtime}} ->
            serve_regular_file(FilePath, Size, Mtime, Req);
        _ ->
            roadrunner_resp:not_found()
    end.

-spec serve_regular_file(
    file:filename_all(), non_neg_integer(), integer(), roadrunner_req:request()
) -> roadrunner_handler:response().
serve_regular_file(FilePath, Size, Mtime, Req) ->
    ETag = etag(Size, Mtime),
    LastMod = roadrunner_http:format_http_date(Mtime),
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
            case maybe_serve_gzip(FilePath, ETag, LastMod, Req) of
                {ok, Resp} -> Resp;
                none -> serve_with_range(FilePath, Size, ETag, LastMod, Req)
            end
    end.

%% When the client opted into gzip and a `<file>.gz` sibling is on
%% disk, serve the sibling with `Content-Encoding: gzip`. `Range`
%% requests skip this path — byte offsets over a compressed
%% representation have subtle semantics, so we let Range win and
%% serve the raw file.
-spec maybe_serve_gzip(file:filename_all(), binary(), binary(), roadrunner_req:request()) ->
    {ok, roadrunner_handler:response()} | none.
maybe_serve_gzip(FilePath, ETag, LastMod, Req) ->
    case
        (roadrunner_req:header(~"range", Req) =:= undefined) andalso
            accepts_gzip(Req)
    of
        true ->
            GzPath = iolist_to_binary([FilePath, ~".gz"]),
            case file:read_file_info(GzPath, [{time, posix}]) of
                {ok, #file_info{type = regular, size = GzSize}} ->
                    {ok, gzip_response(FilePath, GzPath, GzSize, ETag, LastMod)};
                _ ->
                    none
            end;
        false ->
            none
    end.

-spec accepts_gzip(roadrunner_req:request()) -> boolean().
accepts_gzip(Req) ->
    case roadrunner_req:header(~"accept-encoding", Req) of
        undefined -> false;
        Bin -> binary:match(Bin, ~"gzip") =/= nomatch
    end.

-spec gzip_response(
    file:filename_all(), file:filename_all(), non_neg_integer(), binary(), binary()
) -> roadrunner_handler:response().
gzip_response(OrigPath, GzPath, GzSize, ETag, LastMod) ->
    {sendfile, 200,
        [
            {~"content-type", content_type_for(OrigPath)},
            {~"content-encoding", ~"gzip"},
            {~"content-length", integer_to_binary(GzSize)},
            {~"etag", ETag},
            {~"last-modified", LastMod},
            {~"vary", ~"Accept-Encoding"}
        ],
        {GzPath, 0, GzSize}}.

%% Cache hit when either:
%% - `If-None-Match` matches the current ETag (strong validator), or
%% - `If-Modified-Since` ≥ the file's mtime (weak validator).
-spec is_cached(roadrunner_req:request(), binary(), integer()) -> boolean().
is_cached(Req, ETag, Mtime) ->
    if_none_match(Req) =:= ETag orelse if_modified_since_satisfied(Req, Mtime).

-spec if_modified_since_satisfied(roadrunner_req:request(), integer()) -> boolean().
if_modified_since_satisfied(Req, Mtime) ->
    case roadrunner_req:header(~"if-modified-since", Req) of
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
    roadrunner_req:request()
) -> roadrunner_handler:response().
serve_with_range(FilePath, Size, ETag, LastMod, Req) ->
    case parse_range(roadrunner_req:header(~"range", Req), Size) of
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
) -> roadrunner_handler:response().
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
    Ext = roadrunner_bin:ascii_lowercase(iolist_to_binary(filename:extension(FilePath))),
    maps:get(Ext, ?MIME_TYPES, ~"application/octet-stream").

%% Strong ETag derived from size + posix mtime — RFC 9110 §8.8.3
%% format: opaque-tag wrapped in double quotes. Two files with the
%% same size and mtime collide; that's intentional (and matches how
%% nginx/apache build their default ETags).
-spec etag(non_neg_integer(), integer()) -> binary().
etag(Size, Mtime) ->
    <<$", (integer_to_binary(Size))/binary, $-, (integer_to_binary(Mtime))/binary, $">>.

-spec if_none_match(roadrunner_req:request()) -> binary() | undefined.
if_none_match(Req) ->
    roadrunner_req:header(~"if-none-match", Req).

%% Parse a `Range: bytes=N-M`, `bytes=N-`, or `bytes=-S` header against
%% the file `Size`. `none` means "ignore Range and serve the full body"
%% — used for missing, malformed, multi-range, and other shapes we
%% don't honor (per RFC 9110 §14.1.1: servers MUST ignore unknown
%% range units). `unsatisfiable` triggers a 416.
-spec parse_range(binary() | undefined, non_neg_integer()) ->
    {range, non_neg_integer(), non_neg_integer()} | unsatisfiable | none.
parse_range(undefined, _Size) ->
    none;
parse_range(<<"bytes=", Spec/binary>>, Size) ->
    case binary:match(Spec, persistent_term:get(?COMMA_CP_KEY)) of
        nomatch -> parse_single_range(Spec, Size);
        %% Multi-range — falls back to a 200 with the full body.
        _ -> none
    end;
parse_range(_, _Size) ->
    none.

-spec parse_single_range(binary(), non_neg_integer()) ->
    {range, non_neg_integer(), non_neg_integer()} | unsatisfiable | none.
parse_single_range(Spec, Size) ->
    case binary:split(Spec, persistent_term:get(?DASH_CP_KEY)) of
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
                    %% Malformed (non-numeric, negative): per RFC 9110
                    %% §14.2 the server MUST ignore Range.
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
) -> roadrunner_handler:response().
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

-spec range_not_satisfiable(non_neg_integer(), binary(), binary()) -> roadrunner_handler:response().
range_not_satisfiable(Size, ETag, LastMod) ->
    %% RFC 9110 §15.5.17: 416 SHOULD include Content-Range with the
    %% total size so clients can recover.
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
%% Empty segments are already stripped by `roadrunner_router:path_segments/1`.
-spec validate_segments([binary()]) -> ok | traversal.
validate_segments(Segments) ->
    case lists:any(fun(S) -> S =:= ~".." end, Segments) of
        true -> traversal;
        false -> ok
    end.

%% Decide whether a symlink leaf may be served under the route's policy.
-spec symlink_allowed(file:filename_all(), roadrunner_req:request()) -> boolean().
symlink_allowed(FilePath, Req) ->
    case symlink_policy(Req) of
        follow -> true;
        refuse -> false;
        refuse_escapes -> target_inside_docroot(FilePath, Req)
    end.

-spec symlink_policy(roadrunner_req:request()) -> follow | refuse | refuse_escapes.
symlink_policy(Req) ->
    case roadrunner_req:route_opts(Req) of
        #{symlink_policy := follow} -> follow;
        #{symlink_policy := refuse} -> refuse;
        _ -> refuse_escapes
    end.

%% Resolve the symlink one level and check the result lives under
%% `dir`. Symlinks in intermediate path components are not inspected —
%% the kernel follows those when we eventually open the file. The
%% threat model is "an attacker plants a leaf symlink to escape", which
%% is the common case for upload-able directories.
-spec target_inside_docroot(file:filename_all(), roadrunner_req:request()) -> boolean().
target_inside_docroot(FilePath, Req) ->
    %% `serve_file/2` only calls us after `read_link_info` reported
    %% `type = symlink`, so `read_link` is expected to succeed —
    %% we let a TOCTOU race (symlink removed between the two stats)
    %% crash and bubble up as a 500 instead of silently 404'ing.
    {ok, Target} = file:read_link(FilePath),
    #{dir := Dir} = roadrunner_req:route_opts(Req),
    case filename:pathtype(Target) of
        relative ->
            %% A relative target without any `..` segments must land
            %% inside the directory containing the symlink, which by
            %% construction is inside `dir`. The framework runs with
            %% binary file names (default UTF-8 native encoding), so
            %% `filename:split/1` yields binaries and the `~".."`
            %% literal matches directly.
            not lists:member(~"..", filename:split(Target));
        _ ->
            %% `filename:absname/1` strips trailing slashes (except for
            %% the root `/` itself, which we don't reasonably support
            %% as a docroot anyway), so a single appended `/` is enough
            %% to make `string:prefix/2` an exact directory check
            %% rather than a sibling-prefix false positive. `string:prefix/2`
            %% accepts chardata, so neither argument needs flattening.
            string:prefix(Target, [filename:absname(Dir), $/]) =/= nomatch
    end.

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

%% `-on_load` callback. See `feedback_compile_pattern_convention`.
-spec init_patterns() -> ok.
init_patterns() ->
    persistent_term:put(?COMMA_CP_KEY, binary:compile_pattern(~",")),
    persistent_term:put(?DASH_CP_KEY, binary:compile_pattern(~"-")),
    ok.
