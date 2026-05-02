-module(roadrunner_bench_profiler).
-moduledoc """
Run inside a server peer BEAM (called via `peer:call/4`) to wrap an
`eprof` profiling session around a load run.

Generic — not specific to `bench.escript`. Any script that runs a
server in a peer BEAM (current users: `bench.escript`; future:
`stress.escript --detach-server`) can call `start/0` before driving
load and `stop_and_dump/2` after, then read the dump path to print
the eprof totals.

Calls:
1. `start/0` — captures every currently-alive process plus
   everything they spawn (`set_on_spawn => true`) so request-handler
   procs spawned mid-measurement are traced.
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
    profiling = eprof:start_profiling(
        processes(), {'_', '_', '_'}, [{set_on_spawn, true}]
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
