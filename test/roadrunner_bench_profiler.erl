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

`start/0` / `start_fprof/1` seed profiling with the roadrunner
supervisor tree (top sup + recursively-collected children) plus
`{set_on_spawn, true}` so acceptor-spawned connection processes get
auto-traced. This keeps the report focused on roadrunner internals and
excludes peer-control, code_server, application_controller, and other
framework processes whose `lists:foldl` / `gen:do_call` chatter would
otherwise dominate the totals.

`start_all/0` / `start_fprof_all/1` seed every process in the node
instead, so non-roadrunner libraries are traced too. Use them to
attribute time across roadrunner vs `crypto`, which the roadrunner-only
seed above cannot show.

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

-export([
    start/0, start_all/0, stop_and_dump/2, start_fprof/1, start_fprof_all/1, stop_fprof_and_dump/2
]).

-spec start() -> ok.
start() ->
    do_eprof_start(roadrunner_pids()).

-doc """
Like `start/0` but seeds *every* process in the node (`processes()`),
not just the `roadrunner_*`-named ones. The name-based `start/0` seed
omits non-roadrunner libraries, so use this to attribute time across
roadrunner vs `crypto` (and other library) modules.
""".
-spec start_all() -> ok.
start_all() ->
    do_eprof_start(processes()).

%% Shared eprof bring-up: filter the seed to alive pids and start a
%% total-time profiling session with `set_on_spawn` so children spawned
%% mid-run are traced too.
-spec do_eprof_start([pid()]) -> ok.
do_eprof_start(Seed) ->
    {ok, _} = eprof:start(),
    Pids = [P || P <- Seed, is_process_alive(P)],
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

-doc """
Start an `fprof` trace seeded with the same roadrunner-pid set as
`start/0`. fprof produces a richer call-tree (per-MFA OWN and ACC
time, callers/callees) than eprof and tolerates higher trace volumes
without blocking. Use it for the connection-lifecycle survey where
eprof times out (see `docs/conn_lifecycle_investigation.md`).

`TraceFile` is the binary trace output; pass it to
`stop_fprof_and_dump/2` along with the desired analysis output path.
""".
-spec start_fprof(file:filename()) -> ok.
start_fprof(TraceFile) ->
    do_fprof_start(TraceFile, roadrunner_pids()).

-doc """
Like `start_fprof/1` but seeds every process in the node, for the same
HTTP/3 / attribution reasons as `start_all/0`.
""".
-spec start_fprof_all(file:filename()) -> ok.
start_fprof_all(TraceFile) ->
    do_fprof_start(TraceFile, processes()).

%% Shared fprof bring-up: filter the seed to alive pids and start a
%% verbose trace to `TraceFile`.
-spec do_fprof_start(file:filename(), [pid()]) -> ok.
do_fprof_start(TraceFile, Seed) ->
    Pids = [P || P <- Seed, is_process_alive(P)],
    ok = fprof:trace([
        start,
        {procs, Pids},
        {file, TraceFile},
        verbose
    ]),
    ok.

-doc """
Stop the fprof trace, profile, and write the totals analysis to
`AnalysisPath`. Filters out MFAs with own-time below `MinMs`
milliseconds — same shape as `stop_and_dump/2`.

The analysis file groups results in two sections:
- `totals` — top-level summary
- per-MFA blocks with `OWN` (exclusive) and `ACC` (inclusive) time

`stop` is idempotent — safe to call after any fprof:trace error.
""".
-spec stop_fprof_and_dump(file:filename(), file:filename()) -> ok.
stop_fprof_and_dump(TraceFile, AnalysisPath) ->
    fprof:trace(stop),
    ok = fprof:profile([{file, TraceFile}]),
    ok = fprof:analyse([
        {dest, AnalysisPath},
        {cols, 120},
        {totals, true},
        {sort, own},
        no_callers,
        no_details
    ]),
    ok = fprof:stop(),
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
