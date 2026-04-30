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
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
    ),
    Req = <<
        "GET ",
        Path/binary,
        " HTTP/1.1\r\n"
        "Host: x\r\n"
        "Connection: close\r\n"
        "\r\n"
    >>,
    ok = gen_tcp:send(Sock, Req),
    Reply = recv_until_closed(Sock, <<>>),
    ok = gen_tcp:close(Sock),
    Reply.

recv_until_closed(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 1000) of
        {ok, Data} -> recv_until_closed(Sock, <<Acc/binary, Data/binary>>);
        {error, _} -> Acc
    end.
