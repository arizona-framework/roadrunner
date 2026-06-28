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

## Precompressed-sibling serving

When a request's `Accept-Encoding` opts into a compressed encoding
and the requested file has a matching precompressed sibling on disk,
the sibling is served verbatim with the corresponding
`Content-Encoding` plus `Vary: Accept-Encoding`. This matches nginx's
`gzip_static on` behaviour and lets operators pre-compress build
assets once instead of paying the compression cost per request.

Two encodings are negotiated, brotli first:

- `Accept-Encoding: br` with a `<file>.br` sibling on disk →
  `Content-Encoding: br`
- `Accept-Encoding: gzip` with a `<file>.gz` sibling on disk →
  `Content-Encoding: gzip`

Brotli wins when the client accepts both and the `.br` sibling
exists; gzip is the fallback. With neither sibling on disk (or
neither encoding accepted) the raw file is served. Roadrunner never
compresses on the fly — it only `sendfile`s a sibling an operator
placed on disk, so there is no brotli or gzip codec dependency.

`Accept-Encoding` is matched via plain substring (`br`, `gzip`)
rather than full RFC 9110 §12.5.3 qvalue ranking. Browsers and
clients that reach the static path send these tokens plainly.

The original file's ETag is reused for every variant, so a follow-up
`If-None-Match` returns 304 regardless of which variant was first
served. A `Range` request disables the precompressed path on that
request — byte offsets over a compressed representation have subtle
semantics and the simple "Range wins" rule matches what nginx does.
The `Content-Type` always reflects the original file's extension,
not the sibling's.

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

## Metadata cache

`#{cache_ttl_ms => N}` caches the `stat` result (size, mtime) for
each regular file in a node-global ETS table for `N` milliseconds. Hot
paths skip the per-request `read_link_info` syscall after the
first hit. Symlinks always bypass the cache because the policy
gate needs the un-followed lookup.

The default is `0` (disabled). Enabling the cache assumes files
are **immutable during the TTL window**: the cached `size` feeds
the `Content-Length` header while `sendfile` reads the file fresh
from disk, so a file replaced or resized mid-window produces a
length / body mismatch (truncated or short response). Safe for
deploy-then-restart workflows with versioned-by-hash assets;
unsafe for mutable files (user uploads, dev hot-reload).

Set to a positive integer to opt in (e.g., `cache_ttl_ms => 1000`),
or `infinity` for "cache for the lifetime of the listener; only a
listener restart re-stats". nginx's `open_file_cache` makes the same
trade-off and is also off by default.

Call `roadrunner_static:cache_clear/0` to flush every cached entry
without a listener restart — useful after a deploy that swaps files
under an `infinity` (or long) TTL.
""".

-behaviour(roadrunner_handler).

-include_lib("kernel/include/file.hrl").

-on_load(init_patterns/0).

-define(COMMA_CP_KEY, {?MODULE, comma_cp}).
-define(DASH_CP_KEY, {?MODULE, dash_cp}).

%% Caching is opt-in: default is `0` (disabled). See `## Metadata cache`
%% in the moduledoc above for when to enable and the trade-offs.
-define(DEFAULT_CACHE_TTL_MS, 0).

-export([handle/1, cache_clear/0]).

-export_type([siblings/0]).

-doc """
Precompressed siblings found on disk for a regular file, keyed by
encoding. A key is present only when that sibling is a regular file;
the value is its size in bytes. `#{}` means neither sibling exists.
""".
-type siblings() :: #{br => non_neg_integer(), gz => non_neg_integer()}.

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
    Segments = maps:get(~"path", roadrunner_req:bindings(Req), []),
    case validate_segments(Segments) of
        ok ->
            State = roadrunner_req:state(Req),
            TtlMs =
                case State of
                    #{cache_ttl_ms := T} -> T;
                    _ -> ?DEFAULT_CACHE_TTL_MS
                end,
            #{dir := Dir} = State,
            FilePath = filename:join([Dir | Segments]),
            {serve_file(FilePath, TtlMs, Req), Req};
        traversal ->
            {roadrunner_resp:not_found(), Req}
    end.

-doc """
Drop every cached static-file metadata entry. Pair with
`cache_ttl_ms => infinity` (or any TTL longer than your deploy
cycle) to flush stale metadata after replacing files in the
docroot, without restarting the listener.
""".
-spec cache_clear() -> ok.
cache_clear() ->
    roadrunner_static_cache:clear().

-spec serve_file(
    file:filename_all(), non_neg_integer() | infinity, roadrunner_req:request()
) -> roadrunner_handler:response().
serve_file(FilePath, TtlMs, Req) ->
    case cached_lookup(FilePath, TtlMs) of
        {ok, Size, Mtime, ETag, LastMod, Siblings} ->
            serve_regular_file(FilePath, Size, Mtime, ETag, LastMod, Siblings, Req);
        miss ->
            fresh_lookup(FilePath, TtlMs, Req)
    end.

%% Cache-aware regular-file metadata lookup. Returns `miss` when the
%% TTL is non-positive (caching disabled) or when no fresh entry is in
%% the cache. `infinity` entries stay a hit until cleared. Symlinks
%% always bypass the cache because the policy gate needs the un-followed
%% `read_link_info` result.
-spec cached_lookup(file:filename_all(), non_neg_integer() | infinity) ->
    {ok, non_neg_integer(), integer(), binary(), binary(), siblings()} | miss.
cached_lookup(_FilePath, TtlMs) when is_integer(TtlMs), TtlMs =< 0 ->
    miss;
cached_lookup(FilePath, _TtlMs) ->
    roadrunner_static_cache:lookup(FilePath).

%% Stat the file, populate the cache when applicable, and dispatch on
%% the file type. Mirrors the original `serve_file/2` body. Used on
%% cache miss and for symlink leaves (which never cache).
-spec fresh_lookup(
    file:filename_all(), non_neg_integer() | infinity, roadrunner_req:request()
) -> roadrunner_handler:response().
fresh_lookup(FilePath, TtlMs, Req) ->
    %% `read_link_info/1` does not follow the leaf symlink — we need
    %% the un-followed type so the symlink-policy gate can decide
    %% whether the target is allowed to be served.
    case file:read_link_info(FilePath, [raw, {time, posix}]) of
        {ok, #file_info{type = symlink}} ->
            case symlink_allowed(FilePath, Req) of
                true -> serve_followed_file(FilePath, Req);
                false -> roadrunner_resp:not_found()
            end;
        {ok, #file_info{type = regular, size = Size, mtime = Mtime}} ->
            ETag = etag(Size, Mtime),
            LastMod = roadrunner_http:format_http_date(Mtime),
            serve_and_maybe_cache(FilePath, Size, Mtime, ETag, LastMod, TtlMs, Req);
        _ ->
            roadrunner_resp:not_found()
    end.

%% Caching off (non-positive TTL): serve `lazy` — a precompressed sibling
%% is stat'd per request only for an encoding the client actually accepts,
%% the default-path behaviour, and nothing is cached. Caching on (positive
%% TTL or infinity): stat both siblings once now and cache the full
%% metadata, so every later hit skips both that stat and the
%% ETag/Last-Modified recompute.
-spec serve_and_maybe_cache(
    file:filename_all(),
    non_neg_integer(),
    integer(),
    binary(),
    binary(),
    non_neg_integer() | infinity,
    roadrunner_req:request()
) -> roadrunner_handler:response().
serve_and_maybe_cache(FilePath, Size, Mtime, ETag, LastMod, TtlMs, Req) when
    is_integer(TtlMs), TtlMs =< 0
->
    serve_regular_file(FilePath, Size, Mtime, ETag, LastMod, lazy, Req);
serve_and_maybe_cache(FilePath, Size, Mtime, ETag, LastMod, TtlMs, Req) ->
    Siblings = stat_siblings(FilePath),
    ok = roadrunner_static_cache:store(FilePath, Size, Mtime, ETag, LastMod, Siblings, TtlMs),
    serve_regular_file(FilePath, Size, Mtime, ETag, LastMod, Siblings, Req).

%% Read leaf-stat after the symlink-policy gate has approved follow.
-spec serve_followed_file(file:filename_all(), roadrunner_req:request()) ->
    roadrunner_handler:response().
serve_followed_file(FilePath, Req) ->
    case file:read_file_info(FilePath, [raw, {time, posix}]) of
        {ok, #file_info{type = regular, size = Size, mtime = Mtime}} ->
            ETag = etag(Size, Mtime),
            LastMod = roadrunner_http:format_http_date(Mtime),
            %% Symlink leaves never cache, so a precompressed sibling is
            %% resolved lazily (stat'd per request, only for an accepted
            %% encoding).
            serve_regular_file(FilePath, Size, Mtime, ETag, LastMod, lazy, Req);
        _ ->
            roadrunner_resp:not_found()
    end.

-spec serve_regular_file(
    file:filename_all(),
    non_neg_integer(),
    integer(),
    binary(),
    binary(),
    lazy | siblings(),
    roadrunner_req:request()
) -> roadrunner_handler:response().
serve_regular_file(FilePath, Size, Mtime, ETag, LastMod, Siblings, Req) ->
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
            case maybe_serve_precompressed(FilePath, ETag, LastMod, Siblings, Req) of
                {ok, Resp} -> Resp;
                none -> serve_with_range(FilePath, Size, ETag, LastMod, Req)
            end
    end.

%% Serve a precompressed `<file>.br` / `<file>.gz` sibling when the
%% client accepts a matching encoding and the sibling is on disk, brotli
%% preferred. `Range` requests skip this path — byte offsets over a
%% compressed representation have subtle semantics, so we let Range win
%% and serve the raw file.
-spec maybe_serve_precompressed(
    file:filename_all(),
    binary(),
    binary(),
    lazy | siblings(),
    roadrunner_req:request()
) -> {ok, roadrunner_handler:response()} | none.
maybe_serve_precompressed(FilePath, ETag, LastMod, Siblings, Req) ->
    case roadrunner_req:header(~"range", Req) of
        undefined ->
            case choose_sibling(FilePath, Siblings, Req) of
                {Encoding, SiblingPath, SiblingSize} ->
                    {ok,
                        precompressed_response(
                            FilePath, Encoding, SiblingPath, SiblingSize, ETag, LastMod
                        )};
                none ->
                    none
            end;
        _ ->
            none
    end.

%% Negotiate which precompressed sibling (if any) to serve. Brotli wins
%% over gzip when the client accepts both and the `.br` sibling exists.
%% Returns `{ContentEncoding, SiblingPath, SiblingSize}` or `none`.
-spec choose_sibling(file:filename_all(), lazy | siblings(), roadrunner_req:request()) ->
    {binary(), binary(), non_neg_integer()} | none.
choose_sibling(FilePath, Siblings, Req) ->
    AcceptEnc = roadrunner_req:header(~"accept-encoding", Req),
    case try_encoding(FilePath, br, ~"br", AcceptEnc, Siblings) of
        none -> try_encoding(FilePath, gz, ~"gzip", AcceptEnc, Siblings);
        Chosen -> Chosen
    end.

%% Resolve one candidate encoding: the client must accept its token and
%% the sibling must be on disk. The `andalso` short-circuits so the lazy
%% (no-cache) path only stats a sibling for an encoding the client
%% accepts. The accept token doubles as the `Content-Encoding` value.
-spec try_encoding(
    file:filename_all(), br | gz, binary(), binary() | undefined, lazy | siblings()
) -> {binary(), binary(), non_neg_integer()} | none.
try_encoding(FilePath, Key, Token, AcceptEnc, Siblings) ->
    case accepts(AcceptEnc, Token) andalso sibling_size(FilePath, Key, Siblings) of
        false -> none;
        none -> none;
        Size -> {Token, sibling_path(FilePath, suffix(Key)), Size}
    end.

%% Plain substring match of an `Accept-Encoding` token, matching the
%% module's documented simplification over RFC 9110 qvalue ranking.
-spec accepts(binary() | undefined, binary()) -> boolean().
accepts(undefined, _Token) -> false;
accepts(AcceptEnc, Token) -> binary:match(AcceptEnc, Token) =/= nomatch.

%% Size of a precompressed sibling, or `none` when it is not on disk.
%% `lazy` (no-cache / symlink path) stats the sibling now; a cached
%% `siblings()` map already carries the size under the encoding key.
-spec sibling_size(file:filename_all(), br | gz, lazy | siblings()) ->
    non_neg_integer() | none.
sibling_size(FilePath, Key, lazy) ->
    stat_sibling(sibling_path(FilePath, suffix(Key)));
sibling_size(_FilePath, Key, Siblings) ->
    case Siblings of
        #{Key := Size} -> Size;
        _ -> none
    end.

%% Stat both precompressed siblings once for caching: a `siblings()` map
%% carrying the size of each sibling that is a regular file on disk.
-spec stat_siblings(file:filename_all()) -> siblings().
stat_siblings(FilePath) ->
    Base = add_sibling(#{}, br, stat_sibling(sibling_path(FilePath, ~".br"))),
    add_sibling(Base, gz, stat_sibling(sibling_path(FilePath, ~".gz"))).

%% Insert an encoding's size into the siblings map only when on disk.
-spec add_sibling(siblings(), br | gz, non_neg_integer() | none) -> siblings().
add_sibling(Siblings, _Key, none) -> Siblings;
add_sibling(Siblings, Key, Size) -> Siblings#{Key => Size}.

%% Stat a precompressed sibling path: its byte size when it is a regular
%% file, `none` otherwise.
-spec stat_sibling(file:filename_all()) -> non_neg_integer() | none.
stat_sibling(Path) ->
    case file:read_file_info(Path, [raw, {time, posix}]) of
        {ok, #file_info{type = regular, size = Size}} -> Size;
        _ -> none
    end.

-spec suffix(br | gz) -> binary().
suffix(br) -> ~".br";
suffix(gz) -> ~".gz".

-spec sibling_path(file:filename_all(), binary()) -> binary().
sibling_path(FilePath, Suffix) ->
    iolist_to_binary([FilePath, Suffix]).

-spec precompressed_response(
    file:filename_all(), binary(), file:filename_all(), non_neg_integer(), binary(), binary()
) -> roadrunner_handler:response().
precompressed_response(OrigPath, Encoding, SiblingPath, SiblingSize, ETag, LastMod) ->
    {sendfile, 200,
        [
            {~"content-type", content_type_for(OrigPath)},
            {~"content-encoding", Encoding},
            {~"content-length", integer_to_binary(SiblingSize)},
            {~"etag", ETag},
            {~"last-modified", LastMod},
            {~"vary", ~"Accept-Encoding"}
        ],
        {SiblingPath, 0, SiblingSize}}.

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
    case roadrunner_req:state(Req) of
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
            #{dir := Dir} = roadrunner_req:state(Req),
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

%% `-on_load` callback. Compiles the binary patterns once into
%% `persistent_term` so the hot path reads a constant, not a recompile.
-spec init_patterns() -> ok.
init_patterns() ->
    persistent_term:put(?COMMA_CP_KEY, binary:compile_pattern(~",")),
    persistent_term:put(?DASH_CP_KEY, binary:compile_pattern(~"-")),
    ok.
