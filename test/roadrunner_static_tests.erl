-module(roadrunner_static_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Built-in static file handler — end-to-end via a real listener and tmpdir.
%% =============================================================================

static_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun({_Dir, Port}) ->
        [
            {"serves a file with text/html content-type", fun() ->
                Reply = http_get(Port, ~"/static/hello.html"),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
                {match, _} = re:run(
                    Reply, ~"content-type: text/html; charset=utf-8", [caseless]
                ),
                {match, _} = re:run(Reply, ~"<h1>Hello</h1>")
            end},
            {"serves a CSS file with text/css content-type", fun() ->
                Reply = http_get(Port, ~"/static/main.css"),
                {match, _} = re:run(Reply, ~"content-type: text/css", [caseless]),
                {match, _} = re:run(Reply, ~"color: red")
            end},
            {"serves an unknown extension as application/octet-stream", fun() ->
                Reply = http_get(Port, ~"/static/blob.bin"),
                {match, _} = re:run(
                    Reply, ~"content-type: application/octet-stream", [caseless]
                )
            end},
            {"missing file returns 404", fun() ->
                Reply = http_get(Port, ~"/static/missing.txt"),
                ?assertMatch(<<"HTTP/1.1 404 ", _/binary>>, Reply)
            end},
            {"path traversal with .. returns 404", fun() ->
                Reply = http_get(Port, ~"/static/../etc/passwd"),
                ?assertMatch(<<"HTTP/1.1 404 ", _/binary>>, Reply)
            end},
            {"empty path returns 404 (read on directory fails)", fun() ->
                Reply = http_get(Port, ~"/static/"),
                ?assertMatch(<<"HTTP/1.1 404 ", _/binary>>, Reply)
            end},
            {"sets an ETag header on successful responses", fun() ->
                Reply = http_get(Port, ~"/static/hello.html"),
                {match, [_, ETag]} = re:run(
                    Reply, ~"etag: (\"[^\"]+\")", [caseless, {capture, all, binary}]
                ),
                ?assertMatch(<<$", _/binary>>, ETag),
                %% Same request with the matching If-None-Match must 304.
                Reply2 = http_get_with(
                    Port,
                    ~"/static/hello.html",
                    [{~"If-None-Match", ETag}]
                ),
                ?assertMatch(<<"HTTP/1.1 304 ", _/binary>>, Reply2)
            end},
            {"non-matching If-None-Match still returns 200", fun() ->
                Reply = http_get_with(
                    Port,
                    ~"/static/hello.html",
                    [{~"If-None-Match", ~"\"stale-etag\""}]
                ),
                ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, Reply)
            end},
            {"Range: bytes=0-3 returns 206 with the first 4 bytes", fun() ->
                %% hello.html is "<h1>Hello</h1>" (14 bytes); 0-3 → "<h1>".
                Reply = http_get_with(
                    Port, ~"/static/hello.html", [{~"Range", ~"bytes=0-3"}]
                ),
                ?assertMatch(<<"HTTP/1.1 206 ", _/binary>>, Reply),
                {match, _} = re:run(Reply, ~"content-range: bytes 0-3/14", [caseless]),
                {match, _} = re:run(Reply, ~"content-length: 4", [caseless]),
                [_Headers, Body] = binary:split(Reply, ~"\r\n\r\n"),
                ?assertEqual(~"<h1>", Body)
            end},
            {"Range: bytes=4- returns suffix from byte 4 to end", fun() ->
                %% bytes 4..13 → "Hello</h1>" (10 bytes).
                Reply = http_get_with(
                    Port, ~"/static/hello.html", [{~"Range", ~"bytes=4-"}]
                ),
                ?assertMatch(<<"HTTP/1.1 206 ", _/binary>>, Reply),
                {match, _} = re:run(Reply, ~"content-range: bytes 4-13/14", [caseless]),
                [_Headers, Body] = binary:split(Reply, ~"\r\n\r\n"),
                ?assertEqual(~"Hello</h1>", Body)
            end},
            {"Range: bytes=-5 returns the last 5 bytes", fun() ->
                %% Last 5 bytes of "<h1>Hello</h1>" → "</h1>".
                Reply = http_get_with(
                    Port, ~"/static/hello.html", [{~"Range", ~"bytes=-5"}]
                ),
                ?assertMatch(<<"HTTP/1.1 206 ", _/binary>>, Reply),
                {match, _} = re:run(Reply, ~"content-range: bytes 9-13/14", [caseless]),
                [_Headers, Body] = binary:split(Reply, ~"\r\n\r\n"),
                ?assertEqual(~"</h1>", Body)
            end},
            {"unsatisfiable range returns 416", fun() ->
                Reply = http_get_with(
                    Port, ~"/static/hello.html", [{~"Range", ~"bytes=100-200"}]
                ),
                ?assertMatch(<<"HTTP/1.1 416 ", _/binary>>, Reply),
                %% Per RFC 7233 §4.4 the response should carry
                %% Content-Range: bytes */<size> so clients can detect
                %% the resource size.
                {match, _} = re:run(Reply, ~"content-range: bytes \\*/14", [caseless])
            end},
            {"malformed Range header falls through to 200", fun() ->
                %% RFC 7233 §3.1: server MUST ignore Range it doesn't
                %% understand. We'd rather serve the full file than 416.
                Reply = http_get_with(
                    Port, ~"/static/hello.html", [{~"Range", ~"items=0-3"}]
                ),
                ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, Reply)
            end},
            {"multi-range request falls through to 200", fun() ->
                %% Multipart/byteranges responses aren't implemented; we
                %% serve the full file rather than the first range only.
                Reply = http_get_with(
                    Port, ~"/static/hello.html", [{~"Range", ~"bytes=0-3,5-9"}]
                ),
                ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, Reply)
            end},
            {"suffix length of 0 is unsatisfiable", fun() ->
                Reply = http_get_with(
                    Port, ~"/static/hello.html", [{~"Range", ~"bytes=-0"}]
                ),
                ?assertMatch(<<"HTTP/1.1 416 ", _/binary>>, Reply)
            end},
            {"open-ended range with start beyond size is unsatisfiable", fun() ->
                Reply = http_get_with(
                    Port, ~"/static/hello.html", [{~"Range", ~"bytes=100-"}]
                ),
                ?assertMatch(<<"HTTP/1.1 416 ", _/binary>>, Reply)
            end},
            {"open-ended range with non-numeric start falls through to 200", fun() ->
                Reply = http_get_with(
                    Port, ~"/static/hello.html", [{~"Range", ~"bytes=abc-"}]
                ),
                ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, Reply)
            end},
            {"full range with non-numeric start falls through to 200", fun() ->
                Reply = http_get_with(
                    Port, ~"/static/hello.html", [{~"Range", ~"bytes=abc-5"}]
                ),
                ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, Reply)
            end},
            {"range with no dash falls through to 200", fun() ->
                Reply = http_get_with(
                    Port, ~"/static/hello.html", [{~"Range", ~"bytes=abc"}]
                ),
                ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, Reply)
            end},
            {"negative suffix length is malformed and falls through to 200", fun() ->
                %% `bytes=--1` parses to suffix-spec "-1" which is a
                %% negative integer — per RFC 7233 §3.1 the server MUST
                %% ignore a Range it doesn't understand.
                Reply = http_get_with(
                    Port, ~"/static/hello.html", [{~"Range", ~"bytes=--1"}]
                ),
                ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, Reply)
            end},
            {"non-numeric suffix length falls through to 200", fun() ->
                Reply = http_get_with(
                    Port, ~"/static/hello.html", [{~"Range", ~"bytes=-abc"}]
                ),
                ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, Reply)
            end},
            {"sets a Last-Modified header in IMF-fixdate format", fun() ->
                Reply = http_get(Port, ~"/static/hello.html"),
                {match, _} = re:run(
                    Reply,
                    %% Sun, 06 Nov 1994 08:49:37 GMT — three-letter
                    %% day, two-digit day, three-letter month, four-digit
                    %% year, HH:MM:SS, literal GMT.
                    ~"last-modified: [A-Z][a-z][a-z], \\d{2} [A-Z][a-z][a-z] \\d{4} \\d{2}:\\d{2}:\\d{2} GMT",
                    [caseless]
                )
            end},
            {"If-Modified-Since matching the file's mtime returns 304", fun() ->
                %% First fetch the actual Last-Modified to feed back.
                Reply1 = http_get(Port, ~"/static/hello.html"),
                {match, [_, LastMod]} = re:run(
                    Reply1,
                    ~"last-modified: ([^\r\n]+)",
                    [caseless, {capture, all, binary}]
                ),
                Reply2 = http_get_with(
                    Port,
                    ~"/static/hello.html",
                    [{~"If-Modified-Since", LastMod}]
                ),
                ?assertMatch(<<"HTTP/1.1 304 ", _/binary>>, Reply2)
            end},
            {"If-Modified-Since older than mtime returns 200", fun() ->
                Reply = http_get_with(
                    Port,
                    ~"/static/hello.html",
                    [{~"If-Modified-Since", ~"Mon, 01 Jan 1990 00:00:00 GMT"}]
                ),
                ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, Reply)
            end},
            {"malformed If-Modified-Since is ignored", fun() ->
                Reply = http_get_with(
                    Port,
                    ~"/static/hello.html",
                    [{~"If-Modified-Since", ~"not a real date"}]
                ),
                ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, Reply)
            end},
            {"If-Modified-Since with valid format but bogus month is ignored", fun() ->
                %% Pattern-matches the IMF-fixdate shape but `Xyz` isn't
                %% a real month — exercises the try/catch error path.
                Reply = http_get_with(
                    Port,
                    ~"/static/hello.html",
                    [{~"If-Modified-Since", ~"Sun, 06 Xyz 1994 08:49:37 GMT"}]
                ),
                ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, Reply)
            end},
            {"empty file with no Range serves 200 with empty body", fun() ->
                Reply = http_get(Port, ~"/static/empty.txt"),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
                {match, _} = re:run(Reply, ~"content-length: 0", [caseless]),
                [_Headers, Body] = binary:split(Reply, ~"\r\n\r\n"),
                ?assertEqual(~"", Body)
            end},
            {"suffix range on empty file is unsatisfiable", fun() ->
                %% Suffix `bytes=-5` against a 0-byte file: the suffix
                %% logic guard is `S > 0, Size > 0`; Size=0 fails → 416.
                Reply = http_get_with(
                    Port, ~"/static/empty.txt", [{~"Range", ~"bytes=-5"}]
                ),
                ?assertMatch(<<"HTTP/1.1 416 ", _/binary>>, Reply),
                {match, _} = re:run(Reply, ~"content-range: bytes \\*/0", [caseless])
            end},
            {"open-ended range on empty file is unsatisfiable", fun() ->
                Reply = http_get_with(
                    Port, ~"/static/empty.txt", [{~"Range", ~"bytes=0-"}]
                ),
                ?assertMatch(<<"HTTP/1.1 416 ", _/binary>>, Reply)
            end},
            {"range past end clamps to last byte", fun() ->
                %% hello.html is 14 bytes; bytes=10-100 → end clamps to 13.
                Reply = http_get_with(
                    Port, ~"/static/hello.html", [{~"Range", ~"bytes=10-100"}]
                ),
                ?assertMatch(<<"HTTP/1.1 206 ", _/binary>>, Reply),
                {match, _} = re:run(Reply, ~"content-range: bytes 10-13/14", [caseless]),
                [_Headers, Body] = binary:split(Reply, ~"\r\n\r\n"),
                ?assertEqual(~"/h1>", Body)
            end},
            {"range covering exactly the whole file returns 206", fun() ->
                %% bytes=0-13 against 14-byte file = entire content as 206.
                Reply = http_get_with(
                    Port, ~"/static/hello.html", [{~"Range", ~"bytes=0-13"}]
                ),
                ?assertMatch(<<"HTTP/1.1 206 ", _/binary>>, Reply),
                {match, _} = re:run(Reply, ~"content-range: bytes 0-13/14", [caseless]),
                [_Headers, Body] = binary:split(Reply, ~"\r\n\r\n"),
                ?assertEqual(~"<h1>Hello</h1>", Body)
            end},
            {"suffix length larger than file size returns whole file", fun() ->
                %% bytes=-100 on 14-byte file → suffix-spec 100, S > Size,
                %% Start = max(0, Size - S) = max(0, -86) = 0; range 0-13.
                Reply = http_get_with(
                    Port, ~"/static/hello.html", [{~"Range", ~"bytes=-100"}]
                ),
                ?assertMatch(<<"HTTP/1.1 206 ", _/binary>>, Reply),
                {match, _} = re:run(Reply, ~"content-range: bytes 0-13/14", [caseless])
            end},
            {"HEAD returns headers only — no body bytes follow", fun() ->
                Reply = http_request(Port, ~"HEAD", ~"/static/hello.html", []),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
                {match, _} = re:run(Reply, ~"content-length: 14", [caseless]),
                [_Head, Body] = binary:split(Reply, ~"\r\n\r\n"),
                ?assertEqual(<<>>, Body)
            end},
            {"percent-encoded .. is not normalized — stays a literal segment", fun() ->
                %% Defense-in-depth pin: the wildcard captures `%2E%2E`
                %% byte-for-byte, the `..` validator therefore lets it
                %% through, and `file:read_file_info/1` fails to locate
                %% a real entry by that name → 404. If we ever start
                %% percent-decoding wildcard segments, this test forces
                %% us to re-derive the traversal defense.
                Reply = http_get(Port, ~"/static/%2E%2E/hello.html"),
                ?assertMatch(<<"HTTP/1.1 404 ", _/binary>>, Reply)
            end},
            {"directory path resolves to a non-regular file → 404", fun() ->
                Reply = http_get(Port, ~"/static/subdir"),
                ?assertMatch(<<"HTTP/1.1 404 ", _/binary>>, Reply)
            end},
            {"trailing slash on a file still serves the file", fun() ->
                %% `filename:join([Dir, "hello.html", <<>>])` collapses
                %% the empty trailing segment back to `Dir/hello.html`,
                %% so `/static/hello.html/` and `/static/hello.html`
                %% are equivalent. Locked in so a future "strip empty
                %% segments differently" change is deliberate.
                Reply = http_get(Port, ~"/static/hello.html/"),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply)
            end},
            {"in-docroot symlink with relative target is followed by default", fun() ->
                %% Default `symlink_policy => refuse_escapes`
                %% allows relative-target symlinks that don't
                %% contain `..`. The notes_link.txt → notes.txt
                %% target lives in the same directory.
                Reply = http_get(Port, ~"/static/notes_link.txt"),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
                {match, _} = re:run(Reply, ~"hello via link")
            end},
            {"absolute symlink pointing outside the docroot is refused", fun() ->
                %% This is the headline hardening: a symlink whose
                %% absolute target leaves `dir` returns 404 by
                %% default, even though the kernel would happily
                %% follow it.
                Reply = http_get(Port, ~"/static/escape_link.txt"),
                ?assertMatch(<<"HTTP/1.1 404 ", _/binary>>, Reply)
            end},
            {"absolute symlink whose target lives inside the docroot is followed", fun() ->
                %% Covers the acceptance side of the absolute-pathtype
                %% branch; the prefix check on `[absname(Dir), $/]`
                %% must say `=/= nomatch`.
                Reply = http_get(Port, ~"/static/inside_abs_link.txt"),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
                {match, _} = re:run(Reply, ~"hello via link")
            end},
            {"absolute symlink to a sibling-prefixed dir is refused", fun() ->
                %% `<Dir>_evil/leak.txt` shares a prefix with `<Dir>`
                %% but is NOT inside it. The trailing `/` on the
                %% prefix check is what saves us here — without it,
                %% `string:prefix` would match and the leak would
                %% pass.
                Reply = http_get(Port, ~"/static/sibling_attack.txt"),
                ?assertMatch(<<"HTTP/1.1 404 ", _/binary>>, Reply)
            end},
            {"relative symlink with .. segments in target is refused", fun() ->
                Reply = http_get(Port, ~"/static/dotdot_link.txt"),
                ?assertMatch(<<"HTTP/1.1 404 ", _/binary>>, Reply)
            end},
            {"symlink whose target is a directory still returns 404", fun() ->
                %% After the symlink-policy gate approves the follow,
                %% `read_file_info` on the target reports
                %% `type = directory` — non-regular → 404.
                Reply = http_get(Port, ~"/static/subdir_link"),
                ?assertMatch(<<"HTTP/1.1 404 ", _/binary>>, Reply)
            end},
            {"Accept-Encoding gzip serves .gz sibling with Content-Encoding", fun() ->
                Reply = http_get_with(
                    Port,
                    ~"/static/compressible.css",
                    [{~"Accept-Encoding", ~"gzip"}]
                ),
                ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, Reply),
                {match, _} = re:run(Reply, ~"content-encoding: gzip", [caseless]),
                {match, _} = re:run(Reply, ~"vary: Accept-Encoding", [caseless]),
                %% Content-Type still reflects the original file's extension.
                {match, _} = re:run(Reply, ~"content-type: text/css", [caseless]),
                %% Body is the exact bytes of `<file>.gz` on disk.
                [_Headers, Body] = binary:split(Reply, ~"\r\n\r\n"),
                Expected = zlib:gzip(
                    <<"body { background: white; padding: 1em; }">>
                ),
                ?assertEqual(Expected, Body)
            end},
            {"Accept-Encoding gzip with no .gz sibling falls back to plain", fun() ->
                Reply = http_get_with(
                    Port, ~"/static/main.css", [{~"Accept-Encoding", ~"gzip"}]
                ),
                ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, Reply),
                nomatch = re:run(Reply, ~"content-encoding:", [caseless]),
                {match, _} = re:run(Reply, ~"color: red")
            end},
            {"no Accept-Encoding serves plain file even when .gz exists", fun() ->
                Reply = http_get(Port, ~"/static/compressible.css"),
                ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, Reply),
                nomatch = re:run(Reply, ~"content-encoding:", [caseless]),
                [_Headers, Body] = binary:split(Reply, ~"\r\n\r\n"),
                ?assertEqual(
                    <<"body { background: white; padding: 1em; }">>, Body
                )
            end},
            {"Range header disables gzip-sibling and serves raw bytes", fun() ->
                Reply = http_get_with(
                    Port,
                    ~"/static/compressible.css",
                    [
                        {~"Accept-Encoding", ~"gzip"},
                        {~"Range", ~"bytes=0-3"}
                    ]
                ),
                ?assertMatch(<<"HTTP/1.1 206 ", _/binary>>, Reply),
                nomatch = re:run(Reply, ~"content-encoding:", [caseless]),
                [_Headers, Body] = binary:split(Reply, ~"\r\n\r\n"),
                ?assertEqual(~"body", Body)
            end},
            {"If-None-Match from a gzip-served response still 304s", fun() ->
                %% ETag is the original file's, so cache validation
                %% works regardless of which variant the client first
                %% received.
                Reply = http_get_with(
                    Port,
                    ~"/static/compressible.css",
                    [{~"Accept-Encoding", ~"gzip"}]
                ),
                {match, [_, ETag]} = re:run(
                    Reply, ~"etag: (\"[^\"]+\")", [caseless, {capture, all, binary}]
                ),
                Reply2 = http_get_with(
                    Port,
                    ~"/static/compressible.css",
                    [
                        {~"Accept-Encoding", ~"gzip"},
                        {~"If-None-Match", ETag}
                    ]
                ),
                ?assertMatch(<<"HTTP/1.1 304 ", _/binary>>, Reply2)
            end},
            {"Accept-Encoding br serves the .br sibling with Content-Encoding", fun() ->
                Reply = http_get_with(
                    Port, ~"/static/bronly.css", [{~"Accept-Encoding", ~"br"}]
                ),
                ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, Reply),
                {match, _} = re:run(Reply, ~"content-encoding: br", [caseless]),
                {match, _} = re:run(Reply, ~"vary: Accept-Encoding", [caseless]),
                %% Content-Type reflects the original `.css`, not `.br`.
                {match, _} = re:run(Reply, ~"content-type: text/css", [caseless]),
                %% Content-Length is the `.br` sibling's size (19 bytes).
                {match, _} = re:run(Reply, ~"content-length: 19", [caseless]),
                [_Headers, Body] = binary:split(Reply, ~"\r\n\r\n"),
                ?assertEqual(~"brotli-bytes-bronly", Body)
            end},
            {"br is preferred over gzip when both siblings exist", fun() ->
                %% Browsers send `br;q=1, gzip;q=0.8`; plain substring of
                %% both tokens matches, and brotli wins.
                Reply = http_get_with(
                    Port,
                    ~"/static/both.css",
                    [{~"Accept-Encoding", ~"br;q=1, gzip;q=0.8"}]
                ),
                ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, Reply),
                {match, _} = re:run(Reply, ~"content-encoding: br", [caseless]),
                [_Headers, Body] = binary:split(Reply, ~"\r\n\r\n"),
                ?assertEqual(~"brotli-bytes-both", Body)
            end},
            {"br accepted but no .br sibling falls back to the .gz sibling", fun() ->
                %% compressible.css has a `.gz` but no `.br`; a client that
                %% accepts both gets gzip.
                Reply = http_get_with(
                    Port,
                    ~"/static/compressible.css",
                    [{~"Accept-Encoding", ~"br, gzip"}]
                ),
                ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, Reply),
                {match, _} = re:run(Reply, ~"content-encoding: gzip", [caseless]),
                [_Headers, Body] = binary:split(Reply, ~"\r\n\r\n"),
                ?assertEqual(
                    zlib:gzip(<<"body { background: white; padding: 1em; }">>), Body
                )
            end},
            {"br-only accept with just a .gz sibling serves raw", fun() ->
                %% br is accepted but no `.br` exists; gzip is not accepted,
                %% so the existing `.gz` is not served — raw file wins.
                Reply = http_get_with(
                    Port, ~"/static/compressible.css", [{~"Accept-Encoding", ~"br"}]
                ),
                ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, Reply),
                nomatch = re:run(Reply, ~"content-encoding:", [caseless]),
                [_Headers, Body] = binary:split(Reply, ~"\r\n\r\n"),
                ?assertEqual(<<"body { background: white; padding: 1em; }">>, Body)
            end},
            {"both encodings accepted but no siblings on disk serves raw", fun() ->
                Reply = http_get_with(
                    Port, ~"/static/main.css", [{~"Accept-Encoding", ~"br, gzip"}]
                ),
                ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, Reply),
                nomatch = re:run(Reply, ~"content-encoding:", [caseless]),
                {match, _} = re:run(Reply, ~"color: red")
            end},
            {"Range header disables the br-sibling and serves raw bytes", fun() ->
                Reply = http_get_with(
                    Port,
                    ~"/static/bronly.css",
                    [
                        {~"Accept-Encoding", ~"br"},
                        {~"Range", ~"bytes=0-1"}
                    ]
                ),
                ?assertMatch(<<"HTTP/1.1 206 ", _/binary>>, Reply),
                nomatch = re:run(Reply, ~"content-encoding:", [caseless]),
                [_Headers, Body] = binary:split(Reply, ~"\r\n\r\n"),
                ?assertEqual(~"h1", Body)
            end},
            {"If-None-Match from a br-served response still 304s", fun() ->
                %% ETag is the original file's, reused across variants.
                Reply = http_get_with(
                    Port, ~"/static/bronly.css", [{~"Accept-Encoding", ~"br"}]
                ),
                {match, [_, ETag]} = re:run(
                    Reply, ~"etag: (\"[^\"]+\")", [caseless, {capture, all, binary}]
                ),
                Reply2 = http_get_with(
                    Port,
                    ~"/static/bronly.css",
                    [
                        {~"Accept-Encoding", ~"br"},
                        {~"If-None-Match", ETag}
                    ]
                ),
                ?assertMatch(<<"HTTP/1.1 304 ", _/binary>>, Reply2)
            end}
        ]
    end}.

%% =============================================================================
%% Symlink policy modes — exercised on dedicated listeners so the route
%% opts differ from the default `refuse_escapes` setup above.
%% =============================================================================

symlink_policy_follow_test_() ->
    {setup, fun() -> setup_with_policy(static_test_follow, follow) end,
        fun({Name, _, _}) -> ok = roadrunner_listener:stop(Name) end, fun({_Name, _Dir, Port}) ->
            {"policy=follow serves a symlink that escapes the docroot", fun() ->
                Reply = http_get(Port, ~"/static/escape_link.txt"),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
                {match, _} = re:run(Reply, ~"escaped content")
            end}
        end}.

symlink_policy_refuse_test_() ->
    {setup, fun() -> setup_with_policy(static_test_refuse, refuse) end,
        fun({Name, _, _}) -> ok = roadrunner_listener:stop(Name) end, fun({_Name, _Dir, Port}) ->
            [
                {"policy=refuse rejects even an in-docroot relative symlink", fun() ->
                    Reply = http_get(Port, ~"/static/notes_link.txt"),
                    ?assertMatch(<<"HTTP/1.1 404 ", _/binary>>, Reply)
                end},
                {"policy=refuse still serves regular files", fun() ->
                    Reply = http_get(Port, ~"/static/notes.txt"),
                    ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply)
                end}
            ]
        end}.

%% =============================================================================
%% Cache-Control route opt — the configured value rides every cacheable
%% response (200 full file, 200 precompressed sibling, 206 range, 304) and
%% never the 404 / 416. A dedicated listener carries the opt; the default
%% setup (opt unset) guards the no-header regression.
%% =============================================================================

-define(CACHE_CONTROL_VALUE, ~"public, max-age=31536000, immutable").

cache_control_test_() ->
    {setup, fun cache_control_setup/0, fun cache_control_cleanup/1, fun({_Name, _Dir, Port}) ->
        [
            {"200 full file carries the configured Cache-Control verbatim", fun() ->
                Reply = http_get(Port, ~"/static/asset.css"),
                ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, Reply),
                assert_cache_control(Reply, ?CACHE_CONTROL_VALUE)
            end},
            {"200 gzip sibling carries Cache-Control", fun() ->
                Reply = http_get_with(
                    Port, ~"/static/asset.css", [{~"Accept-Encoding", ~"gzip"}]
                ),
                ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, Reply),
                {match, _} = re:run(Reply, ~"content-encoding: gzip", [caseless]),
                assert_cache_control(Reply, ?CACHE_CONTROL_VALUE)
            end},
            {"200 br sibling carries Cache-Control", fun() ->
                Reply = http_get_with(
                    Port, ~"/static/asset.css", [{~"Accept-Encoding", ~"br"}]
                ),
                ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, Reply),
                {match, _} = re:run(Reply, ~"content-encoding: br", [caseless]),
                assert_cache_control(Reply, ?CACHE_CONTROL_VALUE)
            end},
            {"206 range carries Cache-Control", fun() ->
                Reply = http_get_with(
                    Port, ~"/static/asset.css", [{~"Range", ~"bytes=0-3"}]
                ),
                ?assertMatch(<<"HTTP/1.1 206 ", _/binary>>, Reply),
                assert_cache_control(Reply, ?CACHE_CONTROL_VALUE)
            end},
            {"304 Not Modified carries Cache-Control", fun() ->
                Reply1 = http_get(Port, ~"/static/asset.css"),
                {match, [_, ETag]} = re:run(
                    Reply1, ~"etag: (\"[^\"]+\")", [caseless, {capture, all, binary}]
                ),
                Reply2 = http_get_with(
                    Port, ~"/static/asset.css", [{~"If-None-Match", ETag}]
                ),
                ?assertMatch(<<"HTTP/1.1 304 ", _/binary>>, Reply2),
                assert_cache_control(Reply2, ?CACHE_CONTROL_VALUE)
            end},
            {"416 unsatisfiable range never carries Cache-Control", fun() ->
                Reply = http_get_with(
                    Port, ~"/static/asset.css", [{~"Range", ~"bytes=999-1000"}]
                ),
                ?assertMatch(<<"HTTP/1.1 416 ", _/binary>>, Reply),
                assert_no_cache_control(Reply)
            end},
            {"404 missing file never carries Cache-Control", fun() ->
                Reply = http_get(Port, ~"/static/nope.css"),
                ?assertMatch(<<"HTTP/1.1 404 ", _/binary>>, Reply),
                assert_no_cache_control(Reply)
            end}
        ]
    end}.

cache_control_unset_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun({_Dir, Port}) ->
        [
            {"unset: 200 full file has no Cache-Control header", fun() ->
                Reply = http_get(Port, ~"/static/hello.html"),
                ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, Reply),
                assert_no_cache_control(Reply)
            end},
            {"unset: 200 gzip sibling has no Cache-Control header", fun() ->
                Reply = http_get_with(
                    Port, ~"/static/compressible.css", [{~"Accept-Encoding", ~"gzip"}]
                ),
                ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, Reply),
                assert_no_cache_control(Reply)
            end},
            {"unset: 206 range has no Cache-Control header", fun() ->
                Reply = http_get_with(
                    Port, ~"/static/hello.html", [{~"Range", ~"bytes=0-3"}]
                ),
                ?assertMatch(<<"HTTP/1.1 206 ", _/binary>>, Reply),
                assert_no_cache_control(Reply)
            end},
            {"unset: 304 has no Cache-Control header", fun() ->
                Reply1 = http_get(Port, ~"/static/hello.html"),
                {match, [_, ETag]} = re:run(
                    Reply1, ~"etag: (\"[^\"]+\")", [caseless, {capture, all, binary}]
                ),
                Reply2 = http_get_with(
                    Port, ~"/static/hello.html", [{~"If-None-Match", ETag}]
                ),
                ?assertMatch(<<"HTTP/1.1 304 ", _/binary>>, Reply2),
                assert_no_cache_control(Reply2)
            end},
            {"unset: 416 has no Cache-Control header", fun() ->
                Reply = http_get_with(
                    Port, ~"/static/hello.html", [{~"Range", ~"bytes=100-200"}]
                ),
                ?assertMatch(<<"HTTP/1.1 416 ", _/binary>>, Reply),
                assert_no_cache_control(Reply)
            end},
            {"unset: 404 has no Cache-Control header", fun() ->
                Reply = http_get(Port, ~"/static/missing.txt"),
                ?assertMatch(<<"HTTP/1.1 404 ", _/binary>>, Reply),
                assert_no_cache_control(Reply)
            end}
        ]
    end}.

cache_control_setup() ->
    Name = static_test_cache_control,
    Dir = filename:join(
        "/tmp", "rr_cache_control_" ++ integer_to_list(rand:uniform(1000000))
    ),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Css = ~"body { color: red; }",
    ok = file:write_file(filename:join(Dir, "asset.css"), Css),
    %% Both siblings present so the gzip and brotli 200 paths are reachable.
    ok = file:write_file(filename:join(Dir, "asset.css.gz"), zlib:gzip(Css)),
    ok = file:write_file(filename:join(Dir, "asset.css.br"), ~"brotli-bytes-asset"),
    {ok, _} = roadrunner_listener:start_link(Name, #{
        port => 0,
        routes => [
            {~"/static/*path", roadrunner_static, #{
                dir => Dir, cache_control => ?CACHE_CONTROL_VALUE
            }}
        ]
    }),
    {Name, Dir, roadrunner_listener:port(Name)}.

cache_control_cleanup({Name, Dir, _Port}) ->
    ok = roadrunner_listener:stop(Name),
    _ = file:del_dir_r(Dir),
    ok.

%% =============================================================================
%% Metadata cache — direct cache helpers plus end-to-end coverage of the
%% `cache_ttl_ms` route opt.
%% =============================================================================

cache_helpers_test_() ->
    {setup, fun cache_helpers_setup/0, fun cache_helpers_cleanup/1, fun({Dir}) ->
        [
            {"cache_get returns miss when no entry exists", fun() ->
                FilePath = filename:join(Dir, "no_cache_yet.txt"),
                ?assertEqual(miss, roadrunner_static_cache:lookup(FilePath))
            end},
            {"cache_put then cache_get within TTL returns the entry", fun() ->
                FilePath = filename:join(Dir, "fresh.txt"),
                ok = roadrunner_static_cache:store(
                    FilePath, 100, 1700000000, ~"etag-fresh", ~"lm-fresh", #{}, 60000
                ),
                ?assertEqual(
                    {ok, 100, 1700000000, ~"etag-fresh", ~"lm-fresh", #{}},
                    roadrunner_static_cache:lookup(FilePath)
                )
            end},
            {"cache_get returns miss after TTL expires", fun() ->
                FilePath = filename:join(Dir, "expiring.txt"),
                ok = roadrunner_static_cache:store(FilePath, 50, 1700000000, ~"e", ~"lm", #{}, 1),
                timer:sleep(20),
                ?assertEqual(miss, roadrunner_static_cache:lookup(FilePath))
            end},
            {"cache_ttl_ms => infinity entries never expire", fun() ->
                %% No `monotonic_time + infinity` arithmetic; sleeping
                %% past any finite TTL must still return the entry. The
                %% siblings map carries both encodings' sizes.
                FilePath = filename:join(Dir, "forever.txt"),
                ok = roadrunner_static_cache:store(
                    FilePath, 42, 1700000000, ~"etag-fvr", ~"lm-fvr", #{br => 9, gz => 17}, infinity
                ),
                ?assertEqual(
                    {ok, 42, 1700000000, ~"etag-fvr", ~"lm-fvr", #{br => 9, gz => 17}},
                    roadrunner_static_cache:lookup(FilePath)
                ),
                timer:sleep(10),
                ?assertEqual(
                    {ok, 42, 1700000000, ~"etag-fvr", ~"lm-fvr", #{br => 9, gz => 17}},
                    roadrunner_static_cache:lookup(FilePath)
                )
            end},
            {"cache_clear/0 drops every cached entry", fun() ->
                F1 = filename:join(Dir, "clear_a.txt"),
                F2 = filename:join(Dir, "clear_b.txt"),
                ok = roadrunner_static_cache:store(
                    F1, 10, 1700000000, ~"e1", ~"lm1", #{}, infinity
                ),
                ok = roadrunner_static_cache:store(F2, 20, 1700000000, ~"e2", ~"lm2", #{}, 60000),
                ok = roadrunner_static:cache_clear(),
                ?assertEqual(miss, roadrunner_static_cache:lookup(F1)),
                ?assertEqual(miss, roadrunner_static_cache:lookup(F2))
            end}
        ]
    end}.

cache_populated_after_request_test_() ->
    {setup, fun cache_enabled_setup/0, fun cache_enabled_cleanup/1, fun(
        {_Name, Dir, Port}
    ) ->
        [
            {"first request populates the metadata cache when ttl > 0", fun() ->
                %% The handler builds FilePath from `Dir` + binary segments
                %% so the resulting cache key is a binary; match that here.
                FilePath = filename:join([Dir, ~"cached.txt"]),
                ok = roadrunner_static:cache_clear(),
                ?assertEqual(miss, roadrunner_static_cache:lookup(FilePath)),
                _Reply = http_get(Port, ~"/static/cached.txt"),
                ?assertMatch(
                    {ok, _Size, _Mtime, _ETag, _LastMod, _Siblings},
                    roadrunner_static_cache:lookup(FilePath)
                )
            end},
            {"second request hits the cache and serves the same body", fun() ->
                %% Drive `serve_file` through its cache-hit branch by
                %% issuing a follow-up GET after the first populated the
                %% cache. Body must match.
                Reply1 = http_get(Port, ~"/static/cached.txt"),
                Reply2 = http_get(Port, ~"/static/cached.txt"),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply1),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply2),
                [_, Body1] = binary:split(Reply1, ~"\r\n\r\n"),
                [_, Body2] = binary:split(Reply2, ~"\r\n\r\n"),
                ?assertEqual(Body1, Body2),
                ?assertEqual(~"cached", Body1)
            end},
            {"cache hit serves the gzip sibling from the cached result", fun() ->
                %% Two gzip requests to a cached, .gz-backed file: the cold
                %% one caches the gzip-sibling result, the hit serves from it
                %% (no per-request `.gz` stat). Both carry gzip encoding.
                R1 = http_get_with(
                    Port, ~"/static/gz_cached.css", [{~"Accept-Encoding", ~"gzip"}]
                ),
                R2 = http_get_with(
                    Port, ~"/static/gz_cached.css", [{~"Accept-Encoding", ~"gzip"}]
                ),
                {match, _} = re:run(R1, ~"content-encoding: gzip", [caseless]),
                {match, _} = re:run(R2, ~"content-encoding: gzip", [caseless])
            end},
            {"cache hit serves the br sibling from the cached map", fun() ->
                R1 = http_get_with(
                    Port, ~"/static/br_cached.css", [{~"Accept-Encoding", ~"br"}]
                ),
                R2 = http_get_with(
                    Port, ~"/static/br_cached.css", [{~"Accept-Encoding", ~"br"}]
                ),
                {match, _} = re:run(R1, ~"content-encoding: br", [caseless]),
                {match, _} = re:run(R2, ~"content-encoding: br", [caseless]),
                [_, Body] = binary:split(R2, ~"\r\n\r\n"),
                ?assertEqual(~"brotli-cached-bytes", Body)
            end},
            {"cache hit prefers br over gz from the cached map", fun() ->
                R1 = http_get_with(
                    Port, ~"/static/dual_cached.css", [{~"Accept-Encoding", ~"br, gzip"}]
                ),
                R2 = http_get_with(
                    Port, ~"/static/dual_cached.css", [{~"Accept-Encoding", ~"br, gzip"}]
                ),
                {match, _} = re:run(R1, ~"content-encoding: br", [caseless]),
                {match, _} = re:run(R2, ~"content-encoding: br", [caseless]),
                [_, Body] = binary:split(R2, ~"\r\n\r\n"),
                ?assertEqual(~"brotli-dual-bytes", Body)
            end},
            {"cached br-absent falls back to gz from the map", fun() ->
                %% gz_cached.css has only a `.gz`; a client accepting both
                %% gets gzip from the cached map (no per-request stat).
                R1 = http_get_with(
                    Port, ~"/static/gz_cached.css", [{~"Accept-Encoding", ~"br, gzip"}]
                ),
                R2 = http_get_with(
                    Port, ~"/static/gz_cached.css", [{~"Accept-Encoding", ~"br, gzip"}]
                ),
                {match, _} = re:run(R1, ~"content-encoding: gzip", [caseless]),
                {match, _} = re:run(R2, ~"content-encoding: gzip", [caseless])
            end},
            {"cached gz-absent with gzip-only serves raw", fun() ->
                %% br_cached.css has only a `.br`; a gzip-only client gets
                %% the raw file from the cached map.
                R1 = http_get_with(
                    Port, ~"/static/br_cached.css", [{~"Accept-Encoding", ~"gzip"}]
                ),
                R2 = http_get_with(
                    Port, ~"/static/br_cached.css", [{~"Accept-Encoding", ~"gzip"}]
                ),
                nomatch = re:run(R1, ~"content-encoding:", [caseless]),
                nomatch = re:run(R2, ~"content-encoding:", [caseless]),
                [_, Body] = binary:split(R2, ~"\r\n\r\n"),
                ?assertEqual(~"a{}", Body)
            end}
        ]
    end}.

cache_default_off_test_() ->
    {setup,
        fun() ->
            ok = start_static_cache(),
            setup()
        end,
        fun(X) ->
            cleanup(X),
            ok = stop_static_cache()
        end,
        fun({Dir, Port}) ->
            {"default cache_ttl_ms is 0; nothing is cached", fun() ->
                FilePath = filename:join([Dir, ~"hello.html"]),
                ok = roadrunner_static:cache_clear(),
                _Reply = http_get(Port, ~"/static/hello.html"),
                ?assertEqual(miss, roadrunner_static_cache:lookup(FilePath))
            end}
        end}.

%% Cover the static-cache owner's gen_server callbacks (init is covered by
%% the start in the cache setups; the call/cast clauses are not otherwise
%% exercised). The sync call after the cast guarantees the cast was
%% processed (so handle_cast actually ran) before the assertion.
static_cache_owner_test_() ->
    {setup, fun() -> ok = start_static_cache() end, fun(_) -> ok = stop_static_cache() end, [
        {"handle_call replies ok", fun() ->
            ?assertEqual(ok, gen_server:call(roadrunner_static_cache, ping))
        end},
        {"handle_cast is accepted", fun() ->
            ok = gen_server:cast(roadrunner_static_cache, noop),
            ?assertEqual(ok, gen_server:call(roadrunner_static_cache, sync))
        end}
    ]}.

cache_helpers_setup() ->
    ok = start_static_cache(),
    Dir = filename:join(
        "/tmp", "rr_cache_helpers_" ++ integer_to_list(rand:uniform(1000000))
    ),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    {Dir}.

cache_helpers_cleanup({Dir}) ->
    ok = roadrunner_static:cache_clear(),
    ok = stop_static_cache(),
    _ = file:del_dir_r(Dir),
    ok.

%% The static-meta cache lives in a node-global ETS table owned by
%% `roadrunner_static_cache`. eunit bypasses the app supervisor, so the
%% tests that drive the cache start the owner themselves.
start_static_cache() ->
    case roadrunner_static_cache:start_link() of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end.

stop_static_cache() ->
    case whereis(roadrunner_static_cache) of
        undefined -> ok;
        Pid -> ok = gen_server:stop(Pid)
    end.

cache_enabled_setup() ->
    ok = start_static_cache(),
    Name = static_test_cache_on,
    Dir = filename:join(
        "/tmp", "rr_cache_on_" ++ integer_to_list(rand:uniform(1000000))
    ),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    ok = file:write_file(filename:join(Dir, "cached.txt"), ~"cached"),
    ok = file:write_file(filename:join(Dir, "gz_cached.css"), ~"body{}"),
    ok = file:write_file(filename:join(Dir, "gz_cached.css.gz"), zlib:gzip(~"body{}")),
    %% Brotli-only and both-siblings fixtures for the cached negotiation.
    ok = file:write_file(filename:join(Dir, "br_cached.css"), ~"a{}"),
    ok = file:write_file(filename:join(Dir, "br_cached.css.br"), ~"brotli-cached-bytes"),
    ok = file:write_file(filename:join(Dir, "dual_cached.css"), ~"b{}"),
    ok = file:write_file(filename:join(Dir, "dual_cached.css.br"), ~"brotli-dual-bytes"),
    ok = file:write_file(filename:join(Dir, "dual_cached.css.gz"), zlib:gzip(~"b{}")),
    {ok, _} = roadrunner_listener:start_link(Name, #{
        port => 0,
        routes => [
            {~"/static/*path", roadrunner_static, #{
                dir => Dir, cache_ttl_ms => 60000
            }}
        ]
    }),
    {Name, Dir, roadrunner_listener:port(Name)}.

cache_enabled_cleanup({Name, Dir, _Port}) ->
    ok = roadrunner_listener:stop(Name),
    ok = stop_static_cache(),
    _ = file:del_dir_r(Dir),
    ok.

%% =============================================================================
%% Sendfile responses are now keep-alive eligible (same wire framing as
%% buffered 3-tuple responses: Content-Length + bounded body).
%% =============================================================================

sendfile_response_supports_keep_alive_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun({_Dir, Port}) ->
        {"two sendfile responses succeed on a single TCP conn", fun() ->
            {ok, Sock} = gen_tcp:connect(
                {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
            ),
            %% No `Connection: close`: rely on HTTP/1.1's keep-alive
            %% default and the new sendfile keep-alive support.
            Req = ~"GET /static/hello.html HTTP/1.1\r\nHost: x\r\n\r\n",
            ok = gen_tcp:send(Sock, Req),
            {Reply1, Rest1} = recv_response_with_body(Sock, <<>>, 14),
            ok = gen_tcp:send(Sock, Req),
            {Reply2, _Rest2} = recv_response_with_body(Sock, Rest1, 14),
            ok = gen_tcp:close(Sock),
            ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply1),
            ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply2),
            ?assertNotEqual(nomatch, binary:match(Reply1, ~"<h1>Hello</h1>")),
            ?assertNotEqual(nomatch, binary:match(Reply2, ~"<h1>Hello</h1>"))
        end}
    end}.

sendfile_range_response_supports_keep_alive_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun({_Dir, Port}) ->
        {"two 206 range responses succeed on a single TCP conn", fun() ->
            {ok, Sock} = gen_tcp:connect(
                {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
            ),
            %% `bytes=0-3` against `hello.html` (14 bytes) returns
            %% 206 with the first 4 bytes `<h1>` as body. The 206 path
            %% emits a sendfile response with a partial Length; the
            %% conn must keep-alive after it just like a full 200.
            Req = ~"GET /static/hello.html HTTP/1.1\r\nHost: x\r\nRange: bytes=0-3\r\n\r\n",
            ok = gen_tcp:send(Sock, Req),
            {Reply1, Rest1} = recv_response_with_body(Sock, <<>>, 4),
            ok = gen_tcp:send(Sock, Req),
            {Reply2, _Rest2} = recv_response_with_body(Sock, Rest1, 4),
            ok = gen_tcp:close(Sock),
            ?assertMatch(<<"HTTP/1.1 206 ", _/binary>>, Reply1),
            ?assertMatch(<<"HTTP/1.1 206 ", _/binary>>, Reply2),
            ?assertNotEqual(nomatch, binary:match(Reply1, ~"<h1>")),
            ?assertNotEqual(nomatch, binary:match(Reply2, ~"<h1>"))
        end}
    end}.

pipelined_sendfile_responses_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun({_Dir, Port}) ->
        {"two pipelined sendfile GETs return ordered responses", fun() ->
            %% Pipelining: send two complete requests in a single
            %% `gen_tcp:send` before reading either response. The conn
            %% loop must process both, emit two responses in order, and
            %% keep the conn alive between them. Exercises the
            %% `pipelined_leftover` carry-forward in `buffered_finish`
            %% when sendfile takes that path.
            {ok, Sock} = gen_tcp:connect(
                {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
            ),
            Req = ~"GET /static/hello.html HTTP/1.1\r\nHost: x\r\n\r\n",
            ok = gen_tcp:send(Sock, <<Req/binary, Req/binary>>),
            {Reply1, Rest1} = recv_response_with_body(Sock, <<>>, 14),
            {Reply2, _Rest2} = recv_response_with_body(Sock, Rest1, 14),
            ok = gen_tcp:close(Sock),
            ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply1),
            ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply2),
            ?assertNotEqual(nomatch, binary:match(Reply1, ~"<h1>Hello</h1>")),
            ?assertNotEqual(nomatch, binary:match(Reply2, ~"<h1>Hello</h1>"))
        end}
    end}.

%% Read one response (headers + `BodyLen` body bytes) starting from any
%% bytes already in `Buf`, returning `{Response, Rest}` where `Rest` is
%% the unconsumed remainder. Pipelined callers feed `Rest` into the next
%% read: a single `gen_tcp:recv` often returns both pipelined responses
%% at once, and without carrying the remainder forward the second
%% response's bytes get dropped and the next recv then blocks.
recv_response_with_body(Sock, Buf, BodyLen) ->
    case binary:split(Buf, ~"\r\n\r\n") of
        [Head, Body] when byte_size(Body) >= BodyLen ->
            <<Resp:(byte_size(Head) + 4 + BodyLen)/binary, Rest/binary>> = Buf,
            {Resp, Rest};
        _ ->
            {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
            recv_response_with_body(Sock, <<Buf/binary, Data/binary>>, BodyLen)
    end.

setup_with_policy(Name, Policy) ->
    Dir = filename:join(
        "/tmp",
        "roadrunner_static_pol_" ++ atom_to_list(Policy) ++ "_" ++
            integer_to_list(rand:uniform(1000000))
    ),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    ok = file:write_file(filename:join(Dir, "notes.txt"), ~"plain"),
    _ = file:make_symlink("notes.txt", filename:join(Dir, "notes_link.txt")),
    OutsideDir = filename:join(
        "/tmp", "roadrunner_outside_" ++ integer_to_list(rand:uniform(1000000))
    ),
    ok = filelib:ensure_dir(filename:join(OutsideDir, "x")),
    ok = file:write_file(filename:join(OutsideDir, "escape.txt"), ~"escaped content"),
    _ = file:make_symlink(
        filename:join(OutsideDir, "escape.txt"),
        filename:join(Dir, "escape_link.txt")
    ),
    {ok, _} = roadrunner_listener:start_link(Name, #{
        port => 0,
        routes => [
            {~"/static/*path", roadrunner_static, #{
                dir => Dir, symlink_policy => Policy
            }}
        ]
    }),
    {Name, Dir, roadrunner_listener:port(Name)}.

%% --- helpers ---

setup() ->
    Dir = filename:join(
        "/tmp", "roadrunner_static_test_" ++ integer_to_list(rand:uniform(1000000))
    ),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    ok = file:write_file(filename:join(Dir, "hello.html"), <<"<h1>Hello</h1>">>),
    ok = file:write_file(filename:join(Dir, "main.css"), <<"body { color: red; }">>),
    ok = file:write_file(filename:join(Dir, "blob.bin"), <<1, 2, 3, 4>>),
    %% Gzip-sibling fixtures: a CSS file alongside its pre-compressed
    %% sibling. The .gz body intentionally differs from a fresh
    %% `zlib:gzip/1` of the original (different mtime/level) so tests
    %% that read the served bytes verify which file was opened.
    GzOriginal = <<"body { background: white; padding: 1em; }">>,
    ok = file:write_file(filename:join(Dir, "compressible.css"), GzOriginal),
    ok = file:write_file(filename:join(Dir, "compressible.css.gz"), zlib:gzip(GzOriginal)),
    %% Brotli-sibling fixtures. We serve a `.br` sibling verbatim with no
    %% codec dependency, so its bytes are an opaque marker — distinct from
    %% the original so tests can verify which file was opened.
    ok = file:write_file(filename:join(Dir, "bronly.css"), ~"h1 { color: blue; }"),
    ok = file:write_file(filename:join(Dir, "bronly.css.br"), ~"brotli-bytes-bronly"),
    %% Both siblings present — brotli must win when the client accepts both.
    ok = file:write_file(filename:join(Dir, "both.css"), ~"p { margin: 0; }"),
    ok = file:write_file(filename:join(Dir, "both.css.br"), ~"brotli-bytes-both"),
    ok = file:write_file(filename:join(Dir, "both.css.gz"), zlib:gzip(~"p { margin: 0; }")),
    ok = file:write_file(filename:join(Dir, "empty.txt"), <<>>),
    ok = file:write_file(filename:join(Dir, "notes.txt"), ~"hello via link"),
    %% Safe in-docroot symlink (relative target, no `..`).
    _ = file:make_symlink("notes.txt", filename:join(Dir, "notes_link.txt")),
    %% Hostile symlinks — the default policy must refuse both.
    OutsideDir = filename:join(
        "/tmp", "roadrunner_outside_" ++ integer_to_list(rand:uniform(1000000))
    ),
    ok = filelib:ensure_dir(filename:join(OutsideDir, "x")),
    ok = file:write_file(filename:join(OutsideDir, "escape.txt"), ~"escaped"),
    _ = file:make_symlink(
        filename:join(OutsideDir, "escape.txt"),
        filename:join(Dir, "escape_link.txt")
    ),
    _ = file:make_symlink(~"../etc/passwd", filename:join(Dir, "dotdot_link.txt")),
    %% Absolute symlink that DOES land inside the docroot — the
    %% pathtype/2 absolute branch must accept this. (The other
    %% absolute test only covers rejection.)
    _ = file:make_symlink(
        filename:join(Dir, "notes.txt"),
        filename:join(Dir, "inside_abs_link.txt")
    ),
    %% Sibling-prefix attack: a directory whose name shares a prefix
    %% with `Dir`. Without the trailing `/` in the prefix check,
    %% `string:prefix("<Dir>_evil/leak.txt", "<Dir>")` would match
    %% and let the symlink through. With the `/`, it must be refused.
    SiblingDir = Dir ++ "_evil",
    ok = filelib:ensure_dir(filename:join(SiblingDir, "x")),
    ok = file:write_file(filename:join(SiblingDir, "leak.txt"), ~"sibling leak"),
    _ = file:make_symlink(
        filename:join(SiblingDir, "leak.txt"),
        filename:join(Dir, "sibling_attack.txt")
    ),
    %% Empty subdirectory — `filename:join` can resolve a path to it,
    %% but `file:read_file_info` reports `type = directory` so the
    %% handler returns 404 instead of trying to send it.
    ok = filelib:ensure_dir(filename:join([Dir, "subdir", "x"])),
    %% In-docroot symlink whose target is a directory — passes the
    %% symlink-escape gate but fails the regular-file check.
    _ = file:make_symlink("subdir", filename:join(Dir, "subdir_link")),
    {ok, _} = roadrunner_listener:start_link(static_test, #{
        port => 0,
        routes => [{~"/static/*path", roadrunner_static, #{dir => Dir}}]
    }),
    {Dir, roadrunner_listener:port(static_test)}.

cleanup({Dir, _}) ->
    ok = roadrunner_listener:stop(static_test),
    _ = file:del_dir_r(Dir),
    ok.

http_get(Port, Path) ->
    http_get_with(Port, Path, []).

http_get_with(Port, Path, ExtraHeaders) ->
    http_request(Port, ~"GET", Path, ExtraHeaders).

http_request(Port, Method, Path, ExtraHeaders) ->
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
    ),
    Headers = [
        [Name, ~": ", Value, ~"\r\n"]
     || {Name, Value} <- ExtraHeaders
    ],
    Req = iolist_to_binary([
        Method,
        ~" ",
        Path,
        ~" HTTP/1.1\r\nHost: x\r\nConnection: close\r\n",
        Headers,
        ~"\r\n"
    ]),
    ok = gen_tcp:send(Sock, Req),
    Reply = recv_until_closed(Sock, <<>>),
    ok = gen_tcp:close(Sock),
    Reply.

recv_until_closed(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Data} -> recv_until_closed(Sock, <<Acc/binary, Data/binary>>);
        {error, _} -> Acc
    end.

assert_cache_control(Reply, Value) ->
    {match, [_, Got]} = re:run(
        Reply, ~"cache-control: ([^\r\n]+)", [caseless, {capture, all, binary}]
    ),
    ?assertEqual(Value, Got).

assert_no_cache_control(Reply) ->
    ?assertEqual(nomatch, re:run(Reply, ~"cache-control:", [caseless])).
