-module(roadrunner_bench_profiler).
-moduledoc """
Run inside a server peer BEAM (called via `peer:call/4`) to wrap an
`eprof` profiling session around a load run.

Generic — not specific to `bench.escript`. Any script that runs a
server in a peer BEAM (current users: `bench.escript`; future:
`stress.escript --detach-server`) can call `start/0` before driving
load and `stop_and_dump/2` after, then read the dump path to print
the eprof totals.

## Profile scope

Seeds profiling with the roadrunner supervisor tree (top sup +
recursively-collected children) plus `{set_on_spawn, true}` so
acceptor-spawned connection processes get auto-traced. This keeps
the report focused on roadrunner internals and excludes
peer-control, code_server, application_controller, and other
framework processes whose `lists:foldl` / `gen:do_call` chatter
would otherwise dominate the totals.

If `roadrunner_sup` isn't registered (e.g. the app didn't start),
falls back to `processes()` so the profiler still works for
diagnosing startup failures.

## Calls

1. `start/0` — collects roadrunner supervisor tree, starts eprof
   with `set_on_spawn => true` so connections spawned mid-run are
   traced.
2. `stop_and_dump/2` — writes the analysis to the given path
   (filterable by minimum total ms) so the parent script can read
   and print it on its own stdout. Output goes to a tempfile because
   the peer's `standard_io` connection is owned by the peer-control
   protocol, not free for arbitrary writes.
""".

-export([start/0, stop_and_dump/2]).

-spec start() -> ok.
start() ->
    {ok, _} = eprof:start(),
    Pids = roadrunner_pids(),
    profiling = eprof:start_profiling(
        Pids, {'_', '_', '_'}, [{set_on_spawn, true}]
    ),
    ok.

-spec stop_and_dump(file:filename(), float()) -> ok.
stop_and_dump(Path, MinMs) ->
    profiling_stopped = eprof:stop_profiling(),
    ok = eprof:log(Path),
    MinUs = trunc(MinMs * 1000),
    _ = eprof:analyze(total, [{filter, [{time, MinUs}]}]),
    stopped = eprof:stop(),
    ok.

%% Walk the roadrunner supervisor tree, collecting every pid (sup
%% + workers). Acceptor-spawned connection processes are picked up
%% live via `set_on_spawn`.
-spec roadrunner_pids() -> [pid()].
roadrunner_pids() ->
    case whereis(roadrunner_sup) of
        undefined -> processes();
        Sup -> collect_tree(Sup)
    end.

-spec collect_tree(pid()) -> [pid()].
collect_tree(Pid) ->
    collect_tree([Pid], []).

collect_tree([], Acc) ->
    Acc;
collect_tree([Pid | Rest], Acc) ->
    Children = supervisor_children(Pid),
    collect_tree(Children ++ Rest, [Pid | Acc]).

%% Returns the alive child pids of `Pid` if it's a supervisor;
%% otherwise `[]` (workers terminate the recursion). `which_children`
%% can crash for non-supervisor pids — catch and return empty.
-spec supervisor_children(pid()) -> [pid()].
supervisor_children(Pid) ->
    try supervisor:which_children(Pid) of
        Children ->
            [
                ChildPid
             || {_Id, ChildPid, _Type, _Modules} <- Children, is_pid(ChildPid)
            ]
    catch
        _:_ -> []
    end.
