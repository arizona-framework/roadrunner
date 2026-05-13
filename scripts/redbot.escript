#!/usr/bin/env escript
%%% REDbot HTTP/1.1 response-conformance harness.
%%%
%%% Boots a roadrunner listener with `roadrunner_redbot_handler` on a
%%% known port, then runs Mark Nottingham's `redbot` CLI against a
%%% fixed set of probe URLs. Captures the text-format reports under
%%% `test/redbot/reports/` and prints a one-line summary per probe
%%% (and a count of WARN / FAIL findings).
%%%
%%% Requires Docker. The image (`ghcr.io/mnot/redbot`) is pulled on
%%% first run.
%%%
%%% Usage:
%%%   ./scripts/redbot.escript [--port N]
%%%
%%% Exit 0 always — REDbot's findings are advisory; the script is
%%% useful as a one-shot audit, not a CI gate.

-mode(compile).

-define(DEFAULT_PORT, 9090).
-define(LISTENER, redbot_listener).
-define(DOCKER_IMAGE, "ghcr.io/mnot/redbot:latest").

%% Probe paths covering caching, validators, content-negotiation,
%% conditional requests, and the gzip middleware path.
-define(PROBES, [
    "/",
    "/json",
    "/cached",
    "/etag",
    "/last-modified",
    "/conditional",
    "/large"
]).

main(Args) ->
    Opts = parse_args(Args),
    ProjectDir = project_dir(),
    ok = setup_code_paths(ProjectDir),
    Port = maps:get(port, Opts),
    {ok, _} = application:ensure_all_started(roadrunner),
    {ok, _} = roadrunner:start_listener(?LISTENER, #{
        port => Port,
        routes => roadrunner_redbot_handler,
        middlewares => [roadrunner_compress]
    }),
    BoundPort = roadrunner_listener:port(?LISTENER),
    Reports = reports_dir(ProjectDir),
    ok = filelib:ensure_dir(filename:join(Reports, "x")),
    io:format("redbot — roadrunner HTTP/1.1 response audit~n"),
    io:format("  listener  : 127.0.0.1:~B~n", [BoundPort]),
    io:format("  reports   : ~s~n~n", [Reports]),
    Results = [run_probe(BoundPort, Path, Reports) || Path <- ?PROBES],
    ok = roadrunner:stop_listener(?LISTENER),
    print_summary(Results),
    halt(0).

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
    io:format(standard_error, "unknown arg: ~s~n", [Unknown]),
    print_help(),
    halt(2).

print_help() ->
    io:format(
        "usage: redbot.escript [--port N]~n"
        "  --port N    listener port (default ~B)~n",
        [?DEFAULT_PORT]
    ).

project_dir() ->
    Script = escript:script_name(),
    filename:dirname(filename:dirname(filename:absname(Script))).

reports_dir(ProjectDir) ->
    filename:join([ProjectDir, "test", "redbot", "reports"]).

setup_code_paths(ProjectDir) ->
    Lib = filename:join([ProjectDir, "_build", "test", "lib"]),
    Ebins = filelib:wildcard(filename:join([Lib, "*", "ebin"])),
    Tests = filelib:wildcard(filename:join([Lib, "*", "test"])),
    [code:add_pathz(P) || P <- Ebins ++ Tests],
    ok.

run_probe(Port, Path, Reports) ->
    Url = io_lib:format("http://127.0.0.1:~B~s", [Port, Path]),
    Cmd = io_lib:format(
        "docker run --rm --network host --entrypoint redbot ~s ~s -o text",
        [?DOCKER_IMAGE, Url]
    ),
    Out = os:cmd(Cmd),
    Filename = report_filename(Path),
    OutPath = filename:join(Reports, Filename),
    ok = file:write_file(OutPath, Out),
    {Path, count_findings(Out)}.

%% Map a URL path to a flat filename — `/` → `root.txt`, `/json` →
%% `json.txt`, `/last-modified` → `last-modified.txt`, etc.
report_filename("/") -> "root.txt";
report_filename(Path) ->
    Stripped = string:trim(Path, leading, "/"),
    Stripped ++ ".txt".

%% REDbot's text output marks issues as `WARN:`, `BAD:`, `INFO:`, or
%% `GOOD:`. Count the actionable ones.
count_findings(Out) ->
    Lines = string:split(Out, "\n", all),
    lists:foldl(
        fun(Line, #{warn := W, bad := B, good := G, info := I} = Acc) ->
            case classify_line(Line) of
                warn -> Acc#{warn => W + 1};
                bad -> Acc#{bad => B + 1};
                good -> Acc#{good => G + 1};
                info -> Acc#{info => I + 1};
                none -> Acc
            end
        end,
        #{warn => 0, bad => 0, good => 0, info => 0},
        Lines
    ).

classify_line(Line) ->
    Trimmed = string:trim(Line),
    case Trimmed of
        "WARN:" ++ _ -> warn;
        "BAD:" ++ _ -> bad;
        "GOOD:" ++ _ -> good;
        "INFO:" ++ _ -> info;
        _ -> none
    end.

print_summary(Results) ->
    io:format("~nsummary~n"),
    io:format("  ~-18s ~6s ~6s ~6s ~6s~n", ["path", "GOOD", "INFO", "WARN", "BAD"]),
    io:format("  ~s~n", [string:copies("-", 50)]),
    {TG, TI, TW, TB} = lists:foldl(
        fun({Path, #{good := G, info := I, warn := W, bad := B}}, {AG, AI, AW, AB}) ->
            io:format("  ~-18s ~6B ~6B ~6B ~6B~n", [Path, G, I, W, B]),
            {AG + G, AI + I, AW + W, AB + B}
        end,
        {0, 0, 0, 0},
        Results
    ),
    io:format("  ~s~n", [string:copies("-", 50)]),
    io:format("  ~-18s ~6B ~6B ~6B ~6B~n", ["total", TG, TI, TW, TB]),
    io:format(
        "~nReports written to test/redbot/reports/. WARN / BAD findings"
        "~nare advisory — review each in context of your deployment.~n"
    ).
