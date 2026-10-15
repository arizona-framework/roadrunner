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
%%% path. Exit 0 when every case is OK or INFORMATIONAL, 1 otherwise.

-mode(compile).

-define(DEFAULT_PORT, 9001).
-define(LISTENER, autobahn_listener).
-define(DOCKER_IMAGE, "crossbario/autobahn-testsuite:latest").

%% The default WebSocket limits cap a frame and a message at 10 MB; the
%% Autobahn 9.* category drives messages up to 16 MB. Raise them for the
%% conformance run so those cases aren't failed by our own guard.
-define(AUTOBAHN_MAX_MESSAGE_SIZE, 32 * 1024 * 1024).

%% Prefixes the container's exit status at the end of the command output.
-define(EXIT_STATUS_MARK, "autobahn container exit status: ").

%% The suite runs in batches, a fresh client container each. The client
%% keeps data from every case until it writes its report: on a CI runner
%% one compression section (12.* or 13.*) alone took it past 15 GB and the
%% kernel killed it. So the heavy parts run alone, down to each compression
%% subsection, and a final "rest" batch takes every case they don't, so a
%% category added upstream still runs.
-define(BATCHES, [
    {~"9", [~"9.*"]},
    {~"12.1", [~"12.1.*"]},
    {~"12.2", [~"12.2.*"]},
    {~"12.3", [~"12.3.*"]},
    {~"12.4", [~"12.4.*"]},
    {~"12.5", [~"12.5.*"]},
    {~"13.1", [~"13.1.*"]},
    {~"13.2", [~"13.2.*"]},
    {~"13.3", [~"13.3.*"]},
    {~"13.4", [~"13.4.*"]},
    {~"13.5", [~"13.5.*"]},
    {~"13.6", [~"13.6.*"]},
    {~"13.7", [~"13.7.*"]}
]).

main(Args) ->
    Opts = parse_args(Args),
    ProjectDir = project_dir(),
    ok = setup_code_paths(ProjectDir),
    Port = maps:get(port, Opts),
    {ok, _} = application:ensure_all_started(roadrunner),
    {ok, _} = roadrunner:start_listener(?LISTENER, #{
        port => Port,
        routes => roadrunner_autobahn_handler,
        ws => #{
            max_frame_size => ?AUTOBAHN_MAX_MESSAGE_SIZE,
            max_message_size => ?AUTOBAHN_MAX_MESSAGE_SIZE
        }
    }),
    BoundPort = roadrunner_listener:port(?LISTENER),
    io:format("autobahn|testsuite — roadrunner WS conformance~n"),
    io:format("  listener  : 127.0.0.1:~B~n", [BoundPort]),
    io:format("  config    : ~s~n", [config_path(ProjectDir)]),
    io:format("  reports   : ~s~n", [reports_dir(ProjectDir)]),
    Result = run_fuzzingclient(ProjectDir),
    ok = roadrunner:stop_listener(?LISTENER),
    case Result of
        ok ->
            {Summary, Verdict} = summary(ProjectDir),
            io:format("~n~ts~n", [Summary]),
            case Verdict of
                pass -> halt(0);
                fail -> halt(1)
            end;
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

run_fuzzingclient(ProjectDir) ->
    Reports = reports_dir(ProjectDir),
    ok = filelib:ensure_dir(filename:join(Reports, "x")),
    {ok, Json} = file:read_file(config_path(ProjectDir)),
    Base = json:decode(Json),
    run_batches(batches(Base), Base, Reports).

%% Each batch as `{Name, Cases, ExcludeCases}`: the "rest" batch first (the
%% quick core cases, so a basic break fails fast), then the heavy sections.
%% The config's own `exclude-cases` apply to every batch.
batches(#{~"exclude-cases" := Exclude}) ->
    Heavy = lists:append([Cases || {_Name, Cases} <- ?BATCHES]),
    [{~"rest", [~"*"], Exclude ++ Heavy} | [{Name, Cases, Exclude} || {Name, Cases} <- ?BATCHES]].

batch_names() ->
    [~"rest" | [Name || {Name, _Cases} <- ?BATCHES]].

batch_dir(Name) ->
    binary_to_list(<<"batch-", Name/binary>>).

run_batches([], _Base, _Reports) ->
    ok;
run_batches([{Name, Cases, Exclude} | Rest], Base, Reports) ->
    Spec = Base#{
        ~"cases" => Cases,
        ~"exclude-cases" => Exclude,
        ~"outdir" => iolist_to_binary(["./reports/", batch_dir(Name)])
    },
    SpecFile = binary_to_list(<<"spec-", Name/binary, ".json">>),
    ok = file:write_file(filename:join(Reports, SpecFile), json:encode(Spec)),
    %% Memory before each batch, so a container killed for memory shows
    %% what else was holding it (this BEAM, or the host).
    io:format("batch ~s: beam ~B MB, host available ~s", [
        Name,
        erlang:memory(total) div (1024 * 1024),
        os:cmd("free -m | awk '/Mem:/ {print $7 \" MB\"}'")
    ]),
    case run_container(Reports, SpecFile) of
        ok -> run_batches(Rest, Base, Reports);
        {error, _} = Error -> Error
    end.

run_container(Reports, SpecFile) ->
    %% `--network host` shares the host's network, so the container
    %% reaches the listener at the `ws://127.0.0.1:9001` URL in
    %% fuzzingclient.json. Don't use `host.docker.internal` there: it
    %% only resolves where the host's /etc/hosts maps it, which CI
    %% runners don't.
    Cmd = io_lib:format(
        "docker run --rm --network host -e PYTHONUNBUFFERED=1"
        " -v ~s:/reports"
        " ~s wstest -m fuzzingclient -s /reports/~s"
        " 2>&1; echo \"~s$?\"",
        [Reports, ?DOCKER_IMAGE, SpecFile, ?EXIT_STATUS_MARK]
    ),
    io:format("running: ~s~n", [Cmd]),
    Output = os:cmd(Cmd),
    io:format("~ts~n", [Output]),
    container_result(Output).

%% The command ends by echoing the container's exit status, which `os:cmd/1`
%% would otherwise drop. A client that dies mid-run (a killed or out-of-memory
%% container) writes no report, and the status says why.
container_result(Output) ->
    case string:split(string:trim(Output, trailing), ?EXIT_STATUS_MARK, trailing) of
        [Log, "0"] ->
            case string:find(Log, "Error") of
                nomatch -> ok;
                _ -> {error, fuzzingclient_error}
            end;
        [_Log, Status] ->
            {error, {container_exit_status, Status}};
        [_Log] ->
            {error, no_container_exit_status}
    end.

summary(ProjectDir) ->
    %% Each batch writes its own `index.json`; merge their per-case results.
    Reports = reports_dir(ProjectDir),
    case batch_cases(batch_names(), Reports, #{}) of
        {ok, Cases} -> summarize(Cases, filename:join(Reports, "batch-*"));
        {error, Text} -> {Text, fail}
    end.

batch_cases([], _Reports, Acc) ->
    {ok, Acc};
batch_cases([Name | Rest], Reports, Acc) ->
    %% JSON shape: {"roadrunner": {"1.1.1": {"behavior": "OK"}, ...}}
    Path = filename:join([Reports, batch_dir(Name), "index.json"]),
    case file:read_file(Path) of
        {ok, Json} ->
            case json:decode(Json) of
                #{~"roadrunner" := Cases} ->
                    batch_cases(Rest, Reports, maps:merge(Acc, Cases));
                _ ->
                    {error, io_lib:format("(unexpected report shape at ~s)", [Path])}
            end;
        {error, _} ->
            {error, io_lib:format("(report not found at ~s; fuzzingclient may have failed)", [Path])}
    end.

summarize(Cases, ReportGlob) ->
    %% behaviors: OK, NON-STRICT, INFORMATIONAL, FAILED, UNIMPLEMENTED.
    %% Strict conformance means every case is OK or INFORMATIONAL.
    Buckets = lists:foldl(
        fun({_Id, #{~"behavior" := B}}, Acc) ->
            maps:update_with(B, fun(N) -> N + 1 end, 1, Acc)
        end,
        #{},
        maps:to_list(Cases)
    ),
    NotStrict = lists:sort([
        Id
     || {Id, #{~"behavior" := B}} <- maps:to_list(Cases),
        B =/= ~"OK",
        B =/= ~"INFORMATIONAL"
    ]),
    Text = io_lib:format(
        "summary~n"
        "  total         : ~B~n"
        "  OK            : ~B~n"
        "  INFORMATIONAL : ~B~n"
        "  NON-STRICT    : ~B~n"
        "  UNIMPLEMENTED : ~B~n"
        "  FAILED        : ~B~n"
        "  not strict    : ~s~n"
        "  reports       : ~s~n",
        [
            map_size(Cases),
            maps:get(~"OK", Buckets, 0),
            maps:get(~"INFORMATIONAL", Buckets, 0),
            maps:get(~"NON-STRICT", Buckets, 0),
            maps:get(~"UNIMPLEMENTED", Buckets, 0),
            maps:get(~"FAILED", Buckets, 0),
            case NotStrict of
                [] -> ~"none";
                [_ | _] -> lists:join(~" ", NotStrict)
            end,
            ReportGlob
        ]
    ),
    case NotStrict of
        [] -> {Text, pass};
        [_ | _] -> {Text, fail}
    end.
