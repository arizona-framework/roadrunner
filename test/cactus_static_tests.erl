-module(cactus_static_tests).

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
            end}
        ]
    end}.

%% --- helpers ---

setup() ->
    Dir = filename:join(
        "/tmp", "cactus_static_test_" ++ integer_to_list(rand:uniform(1000000))
    ),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    ok = file:write_file(filename:join(Dir, "hello.html"), <<"<h1>Hello</h1>">>),
    ok = file:write_file(filename:join(Dir, "main.css"), <<"body { color: red; }">>),
    ok = file:write_file(filename:join(Dir, "blob.bin"), <<1, 2, 3, 4>>),
    {ok, _} = cactus_listener:start_link(static_test, #{
        port => 0,
        routes => [{~"/static/*path", cactus_static, #{dir => Dir}}]
    }),
    {Dir, cactus_listener:port(static_test)}.

cleanup({Dir, _}) ->
    ok = cactus_listener:stop(static_test),
    _ = file:del_dir_r(Dir),
    ok.

http_get(Port, Path) ->
    http_get_with(Port, Path, []).

http_get_with(Port, Path, ExtraHeaders) ->
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
    ),
    Headers = [
        [Name, ~": ", Value, ~"\r\n"]
     || {Name, Value} <- ExtraHeaders
    ],
    Req = iolist_to_binary([
        ~"GET ",
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
    case gen_tcp:recv(Sock, 0, 1000) of
        {ok, Data} -> recv_until_closed(Sock, <<Acc/binary, Data/binary>>);
        {error, _} -> Acc
    end.
