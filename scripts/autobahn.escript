#!/usr/bin/env escript
%%% Autobahn|Testsuite WebSocket conformance harness.
%%%
%%% Boots a roadrunner WS listener on localhost:9001 with the canonical
%%% echo handler (`roadrunner_autobahn_handler`), runs the
%%% `crossbario/autobahn-testsuite` Docker image's fuzzingclient
%%% against it, and prints a pass/fail summary.
%%%
%%% Requires Docker. The image is pulled on first run.
%%%
%%% Usage:
%%%   ./scripts/autobahn.escript [--port N]
%%%
%%% Output: pass/fail counts per case category, plus the HTML report
%%% path. Exit 0 on full pass, 1 on any failure.

-mode(compile).

-define(DEFAULT_PORT, 9001).
-define(LISTENER, autobahn_listener).
-define(DOCKER_IMAGE, "crossbario/autobahn-testsuite:latest").

%% Most listeners ship a 10 MB content-length cap by default; the
%% Autobahn 9.* category drives messages up to 16 MB. Bump for the
%% conformance run so those cases aren't artificially failed by our
%% own framework guard.
-define(AUTOBAHN_MAX_CONTENT_LENGTH, 32 * 1024 * 1024).

main(Args) ->
    Opts = parse_args(Args),
    ProjectDir = project_dir(),
    ok = setup_code_paths(ProjectDir),
    Port = maps:get(port, Opts),
    {ok, _} = application:ensure_all_started(roadrunner),
    {ok, _} = roadrunner:start_listener(?LISTENER, #{
        port => Port,
        routes => roadrunner_autobahn_handler,
        max_content_length => ?AUTOBAHN_MAX_CONTENT_LENGTH
    }),
    BoundPort = roadrunner_listener:port(?LISTENER),
    io:format("autobahn|testsuite — roadrunner WS conformance~n"),
    io:format("  listener  : 127.0.0.1:~B~n", [BoundPort]),
    io:format("  config    : ~s~n", [config_path(ProjectDir)]),
    io:format("  reports   : ~s~n", [reports_dir(ProjectDir)]),
    Result = run_fuzzingclient(ProjectDir, BoundPort),
    ok = roadrunner:stop_listener(?LISTENER),
    case Result of
        ok ->
            io:format("~n~s~n", [fmt_summary(ProjectDir)]),
            halt(0);
        {error, Reason} ->
            io:format("~nautobahn run failed: ~p~n", [Reason]),
            halt(1)
    end.

parse_args([]) ->
    #{port => ?DEFAULT_PORT};
parse_args(["--port", PortStr | Rest]) ->
    Acc = parse_args(Rest),
    Acc#{port => list_to_integer(PortStr)};
parse_args(["-h" | _]) ->
    print_help(),
    halt(0);
parse_args(["--help" | _]) ->
    print_help(),
    halt(0);
parse_args([Unknown | _]) ->
    io:format("unknown arg: ~s~n", [Unknown]),
    print_help(),
    halt(2).

print_help() ->
    io:format(
        "usage: autobahn.escript [--port N]~n"
        "  --port N    listener port (default ~B)~n",
        [?DEFAULT_PORT]
    ).

project_dir() ->
    Script = escript:script_name(),
    filename:dirname(filename:dirname(filename:absname(Script))).

config_path(ProjectDir) ->
    filename:join([ProjectDir, "test", "autobahn", "fuzzingclient.json"]).

reports_dir(ProjectDir) ->
    filename:join([ProjectDir, "test", "autobahn", "reports"]).

setup_code_paths(ProjectDir) ->
    %% Pull in the test profile build (where the autobahn handler lives).
    %% rebar3 puts test-only modules under `<app>/test/` rather than
    %% `<app>/ebin/`, so add both globs.
    Lib = filename:join([ProjectDir, "_build", "test", "lib"]),
    Ebins = filelib:wildcard(filename:join([Lib, "*", "ebin"])),
    Tests = filelib:wildcard(filename:join([Lib, "*", "test"])),
    [code:add_pathz(P) || P <- Ebins ++ Tests],
    ok.

run_fuzzingclient(ProjectDir, _Port) ->
    %% `--network host` lets the container reach the host's
    %% 127.0.0.1:9001 directly (matches the "host.docker.internal"
    %% URL in fuzzingclient.json on Linux too — the Docker daemon
    %% maps it).
    Reports = reports_dir(ProjectDir),
    Config = config_path(ProjectDir),
    ok = filelib:ensure_dir(filename:join(Reports, "x")),
    Cmd = io_lib:format(
        "docker run --rm --network host"
        " -v ~s:/config"
        " -v ~s:/reports"
        " ~s wstest -m fuzzingclient -s /config/fuzzingclient.json",
        [
            filename:dirname(Config),
            Reports,
            ?DOCKER_IMAGE
        ]
    ),
    io:format("running: ~s~n", [Cmd]),
    Output = os:cmd(Cmd),
    io:format("~s~n", [Output]),
    case string:find(Output, "Error") of
        nomatch -> ok;
        _ -> {error, fuzzingclient_error}
    end.

fmt_summary(ProjectDir) ->
    %% The fuzzingclient writes `index.json` in the reports dir; parse
    %% it for the per-case results.
    Path = filename:join([reports_dir(ProjectDir), "clients", "index.json"]),
    case file:read_file(Path) of
        {ok, Json} ->
            summarize_json(Json, Path);
        {error, _} ->
            io_lib:format("(report not found at ~s — fuzzingclient may have failed)", [Path])
    end.

summarize_json(Json, Path) ->
    %% Parse the fuzzingclient index. JSON shape:
    %%   {"roadrunner": {"1.1.1": {"behavior": "OK"}, ...}}
    %% behaviors: OK, NON-STRICT, INFORMATIONAL, FAILED, UNIMPLEMENTED.
    case json:decode(Json) of
        #{~"roadrunner" := Cases} ->
            Buckets = lists:foldl(
                fun({_Id, #{~"behavior" := B}}, Acc) ->
                    maps:update_with(B, fun(N) -> N + 1 end, 1, Acc)
                end,
                #{},
                maps:to_list(Cases)
            ),
            io_lib:format(
                "summary~n"
                "  total      : ~B~n"
                "  OK         : ~B~n"
                "  NON-STRICT : ~B~n"
                "  FAILED     : ~B~n"
                "  report     : ~s~n",
                [
                    map_size(Cases),
                    maps:get(~"OK", Buckets, 0),
                    maps:get(~"NON-STRICT", Buckets, 0),
                    maps:get(~"FAILED", Buckets, 0),
                    Path
                ]
            );
        _ ->
            io_lib:format("(unexpected report shape at ~s)", [Path])
    end.
