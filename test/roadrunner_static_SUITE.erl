-module(roadrunner_static_SUITE).
-moduledoc """
`roadrunner_static` options that `init_route/1` resolves when the listener
starts: a `dir` or `file` under an application's `priv` directory, a
single-file route, and a bad option stopping the listener from starting. The
application is a stand-in, `rr_static_app`, whose `ebin` the suite puts on the
code path so `code:priv_dir/1` finds its `priv` fixtures.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    suite/0,
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    end_per_testcase/2
]).
-export([
    priv_dir_route_serves_from_the_app/1,
    file_route_serves_its_file/1,
    file_route_answers_head/1,
    file_route_honours_etag_and_last_modified/1,
    file_route_serves_a_range/1,
    file_route_serves_a_precompressed_sibling/1,
    file_route_carries_cache_control_and_mime_types/1,
    file_route_follows_a_symlinked_file/1,
    file_route_caches_its_metadata/1,
    file_route_answers_404_when_missing/1,
    priv_file_route_serves_its_file/1,
    bad_options_stop_the_listener_from_starting/1
]).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        priv_dir_route_serves_from_the_app,
        file_route_serves_its_file,
        file_route_answers_head,
        file_route_honours_etag_and_last_modified,
        file_route_serves_a_range,
        file_route_serves_a_precompressed_sibling,
        file_route_carries_cache_control_and_mime_types,
        file_route_follows_a_symlinked_file,
        file_route_caches_its_metadata,
        file_route_answers_404_when_missing,
        priv_file_route_serves_its_file,
        bad_options_stop_the_listener_from_starting
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(roadrunner),
    Lib = filename:join(?config(priv_dir, Config), "rr_static_app-1.0"),
    Ebin = filename:join(Lib, "ebin"),
    Static = filename:join([Lib, "priv", "static"]),
    ok = filelib:ensure_dir(filename:join(Ebin, "x")),
    ok = filelib:ensure_path(filename:join(Static, "css")),
    ok = file:write_file(filename:join([Static, "css", "app.css"]), ~"body{}"),
    ok = file:write_file(filename:join(Static, "robots.txt"), ~"User-agent: *"),
    true = code:add_patha(Ebin),
    Files = filename:join(?config(priv_dir, Config), "files"),
    ok = filelib:ensure_path(Files),
    %% index.html is "<h1>Index</h1>", 14 bytes.
    ok = file:write_file(filename:join(Files, "index.html"), ~"<h1>Index</h1>"),
    ok = file:write_file(filename:join(Files, "index.html.br"), ~"brotli-index"),
    ok = file:write_file(filename:join(Files, "scene.glb"), ~"glTF"),
    Outside = filename:join(?config(priv_dir, Config), "outside.txt"),
    ok = file:write_file(Outside, ~"outside the files dir"),
    ok = file:make_symlink(Outside, filename:join(Files, "link.txt")),
    [{ebin, Ebin}, {files, Files} | Config].

end_per_suite(Config) ->
    true = code:del_path(?config(ebin, Config)),
    Config.

end_per_testcase(_Case, _Config) ->
    case whereis(?MODULE) of
        undefined -> ok;
        _Pid -> ok = roadrunner_listener:stop(?MODULE)
    end.

%% =============================================================================
%% Cases
%% =============================================================================

priv_dir_route_serves_from_the_app(_Config) ->
    Port = start([{~"/assets/*path", roadrunner_static, #{dir => {priv, rr_static_app, ~"static"}}}]),
    {200, Headers, Body} = http_get(Port, ~"/assets/css/app.css"),
    ?assertEqual(~"body{}", Body),
    ?assertEqual(~"text/css; charset=utf-8", header(~"content-type", Headers)),
    %% The string form of `SubPath` resolves the same way.
    ok = roadrunner_listener:stop(?MODULE),
    Port2 = start([{~"/assets/*path", roadrunner_static, #{dir => {priv, rr_static_app, "static"}}}]),
    ?assertMatch({200, _, ~"User-agent: *"}, http_get(Port2, ~"/assets/robots.txt")),
    ?assertMatch({404, _, _}, http_get(Port2, ~"/assets/missing.css")).

file_route_serves_its_file(Config) ->
    Port = start([{~"/", roadrunner_static, #{file => file(Config, "index.html")}}]),
    {200, Headers, Body} = http_get(Port, ~"/"),
    ?assertEqual(~"<h1>Index</h1>", Body),
    ?assertEqual(~"text/html; charset=utf-8", header(~"content-type", Headers)),
    ?assertEqual(~"14", header(~"content-length", Headers)).

file_route_answers_head(Config) ->
    Port = start([{~"/", roadrunner_static, #{file => file(Config, "index.html")}}]),
    {200, Headers, Body} = request(Port, ~"HEAD", ~"/", []),
    ?assertEqual(~"", Body),
    ?assertEqual(~"14", header(~"content-length", Headers)).

file_route_honours_etag_and_last_modified(Config) ->
    Port = start([{~"/", roadrunner_static, #{file => file(Config, "index.html")}}]),
    {200, Headers, _} = http_get(Port, ~"/"),
    ETag = header(~"etag", Headers),
    LastModified = header(~"last-modified", Headers),
    ?assertMatch({304, _, ~""}, request(Port, ~"GET", ~"/", [{~"if-none-match", ETag}])),
    ?assertMatch(
        {304, _, ~""}, request(Port, ~"GET", ~"/", [{~"if-modified-since", LastModified}])
    ).

file_route_serves_a_range(Config) ->
    Port = start([{~"/", roadrunner_static, #{file => file(Config, "index.html")}}]),
    {206, Headers, Body} = request(Port, ~"GET", ~"/", [{~"range", ~"bytes=0-3"}]),
    ?assertEqual(~"<h1>", Body),
    ?assertEqual(~"bytes 0-3/14", header(~"content-range", Headers)),
    ?assertEqual(~"text/html; charset=utf-8", header(~"content-type", Headers)).

file_route_serves_a_precompressed_sibling(Config) ->
    Port = start([{~"/", roadrunner_static, #{file => file(Config, "index.html")}}]),
    {200, Headers, Body} = request(Port, ~"GET", ~"/", [{~"accept-encoding", ~"br, gzip"}]),
    ?assertEqual(~"brotli-index", Body),
    ?assertEqual(~"br", header(~"content-encoding", Headers)),
    ?assertEqual(~"text/html; charset=utf-8", header(~"content-type", Headers)).

file_route_carries_cache_control_and_mime_types(Config) ->
    Port = start([
        {~"/scene", roadrunner_static, #{
            file => list_to_binary(file(Config, "scene.glb")),
            cache_control => ~"public, max-age=60",
            mime_types => #{~".GLB" => ~"model/gltf-binary"}
        }}
    ]),
    {200, Headers, ~"glTF"} = http_get(Port, ~"/scene"),
    ?assertEqual(~"model/gltf-binary", header(~"content-type", Headers)),
    ?assertEqual(~"public, max-age=60", header(~"cache-control", Headers)).

file_route_follows_a_symlinked_file(Config) ->
    %% The link points outside its directory: a `dir` route's default policy
    %% would refuse it, a `file` route serves what the operator named.
    Port = start([{~"/link", roadrunner_static, #{file => file(Config, "link.txt")}}]),
    ?assertMatch({200, _, ~"outside the files dir"}, http_get(Port, ~"/link")).

file_route_caches_its_metadata(Config) ->
    File = list_to_binary(file(Config, "index.html")),
    ok = roadrunner_static:cache_clear(),
    Port = start([{~"/", roadrunner_static, #{file => File, cache_ttl_ms => 60000}}]),
    ?assertMatch({200, _, ~"<h1>Index</h1>"}, http_get(Port, ~"/")),
    ?assertMatch({ok, 14, _, _, _, #{br := _}}, roadrunner_static_cache:lookup(File)),
    %% Served again from the cached metadata.
    ?assertMatch({200, _, ~"<h1>Index</h1>"}, http_get(Port, ~"/")),
    ok = roadrunner_static:cache_clear().

file_route_answers_404_when_missing(Config) ->
    Port = start([
        {~"/gone", roadrunner_static, #{file => file(Config, "missing.html")}},
        %% A directory is not a file to serve either.
        {~"/dir", roadrunner_static, #{file => ?config(files, Config)}},
        %% A `dir` route without a `*path` wildcard names the directory itself.
        {~"/docroot", roadrunner_static, #{dir => ?config(files, Config)}}
    ]),
    ?assertMatch({404, _, _}, http_get(Port, ~"/gone")),
    ?assertMatch({404, _, _}, http_get(Port, ~"/dir")),
    ?assertMatch({404, _, _}, http_get(Port, ~"/docroot")).

priv_file_route_serves_its_file(_Config) ->
    Port = start([
        {~"/robots.txt", roadrunner_static, #{file => {priv, rr_static_app, ~"static/robots.txt"}}}
    ]),
    {200, Headers, Body} = http_get(Port, ~"/robots.txt"),
    ?assertEqual(~"User-agent: *", Body),
    ?assertEqual(~"text/plain; charset=utf-8", header(~"content-type", Headers)).

bad_options_stop_the_listener_from_starting(_Config) ->
    process_flag(trap_exit, true),
    Cases = [
        {#{dir => ~"/x", typo => 1}, {unknown_static_opt, typo}},
        {#{dir => ~"/x", file => ~"/x/a"}, {static_opt_conflict, dir, file}},
        {#{}, {missing_static_opt, dir_or_file}},
        {#{dir => {priv, rr_no_such_app, ~"x"}}, {static_app_not_found, dir, rr_no_such_app}},
        {#{dir => 42}, {invalid_static_opt, dir, 42}},
        {#{file => ~"/x/a", symlink_policy => follow}, {static_opt_conflict, file, symlink_policy}},
        {#{dir => ~"/x", cache_control => 1}, {invalid_static_opt, cache_control, 1}},
        {#{dir => ~"/x", symlink_policy => folow}, {invalid_static_opt, symlink_policy, folow}},
        {#{dir => ~"/x", cache_ttl_ms => -5}, {invalid_static_opt, cache_ttl_ms, -5}},
        {#{dir => ~"/x", mime_types => [bad]}, {invalid_static_opt, mime_types, [bad]}}
    ],
    [
        ?assertMatch(
            {error, {{init_route_failed, ~"/s/*path", roadrunner_static, Reason}, _}},
            roadrunner_listener:start_link(?MODULE, #{
                port => 0, routes => [{~"/s/*path", roadrunner_static, Opts}]
            })
        )
     || {Opts, Reason} <- Cases
    ],
    %% The single-handler form runs the same check.
    ?assertMatch(
        {error, {{init_route_failed, undefined, roadrunner_static, {unknown_static_opt, typo}}, _}},
        roadrunner_listener:start_link(?MODULE, #{
            port => 0, routes => {roadrunner_static, #{dir => ~"/x", typo => 1}}
        })
    ).

%% =============================================================================
%% Helpers
%% =============================================================================

start(Routes) ->
    {ok, _} = roadrunner_listener:start_link(?MODULE, #{port => 0, routes => Routes}),
    roadrunner_listener:port(?MODULE).

file(Config, Name) ->
    filename:join(?config(files, Config), Name).

http_get(Port, Path) ->
    request(Port, ~"GET", Path, []).

%% One HTTP/1.1 exchange on its own connection: `{Status, Headers, Body}` with
%% lowercased header names.
request(Port, Method, Path, Headers) ->
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 5000),
    ok = gen_tcp:send(Sock, [
        Method,
        ~" ",
        Path,
        ~" HTTP/1.1\r\nhost: x\r\nconnection: close\r\n",
        [[Name, ~": ", Value, ~"\r\n"] || {Name, Value} <- Headers],
        ~"\r\n"
    ]),
    Reply = recv_until_closed(Sock, <<>>),
    ok = gen_tcp:close(Sock),
    [Head, Body] = binary:split(Reply, ~"\r\n\r\n"),
    [<<"HTTP/1.1 ", Status:3/binary, _/binary>> | Lines] = binary:split(Head, ~"\r\n", [global]),
    {binary_to_integer(Status), [parse_header(Line) || Line <- Lines], Body}.

parse_header(Line) ->
    [Name, Value] = binary:split(Line, ~": "),
    {roadrunner_bin:ascii_lowercase(Name), Value}.

header(Name, Headers) ->
    {Name, Value} = lists:keyfind(Name, 1, Headers),
    Value.

recv_until_closed(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Data} -> recv_until_closed(Sock, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc
    end.
