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
    Pids = [P || P <- roadrunner_pids(), is_process_alive(P)],
    case eprof:start_profiling(Pids, {'_', '_', '_'}, [{set_on_spawn, true}]) of
        profiling ->
            ok;
        {error, {set_process_trace_failed, _}} ->
            %% A seed pid died between the alive check and eprof's
            %% per-pid trace-set call (e.g. pg's scope publisher
            %% restarting). Fall back to the wider `processes()` seed
            %% — the report will include some framework noise but
            %% the run completes.
            profiling = eprof:start_profiling(
                processes(), {'_', '_', '_'}, [{set_on_spawn, true}]
            ),
            ok
    end.

-spec stop_and_dump(file:filename(), float()) -> ok.
stop_and_dump(Path, MinMs) ->
    profiling_stopped = eprof:stop_profiling(),
    ok = eprof:log(Path),
    MinUs = trunc(MinMs * 1000),
    _ = eprof:analyze(total, [{filter, [{time, MinUs}]}]),
    stopped = eprof:stop(),
    ok.

%% Seed: every alive process whose `proc_lib:initial_call/1` is in a
%% `roadrunner_*` module. This catches the listener gen_servers
%% AND the already-spawned acceptors (which are linked, not
%% supervisor children, so a tree walk would miss them). Connections
%% spawned by acceptors during the run are picked up live via
%% `set_on_spawn => true`.
%%
%% Skipping `pg` and `pg_*`: the OTP `pg` worker and its scope
%% publisher race with eprof's per-pid trace-set during startup and
%% return `{error, {set_process_trace_failed, _}}`. pg is shared
%% drain-notification infrastructure, not on the request hot path.
-spec roadrunner_pids() -> [pid()].
roadrunner_pids() ->
    case whereis(roadrunner_sup) of
        undefined -> processes();
        _Sup -> [P || P <- processes(), is_roadrunner_proc(P)]
    end.

-spec is_roadrunner_proc(pid()) -> boolean().
is_roadrunner_proc(Pid) ->
    case proc_lib:initial_call(Pid) of
        {Mod, _F, _A} ->
            ModStr = atom_to_list(Mod),
            lists:prefix("roadrunner_", ModStr);
        false ->
            false
    end.
