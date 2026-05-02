#!/usr/bin/env escript
%%% HTTP stress test for cactus.
%%%
%%% Drives concurrent traffic at a cactus listener and reports
%%% throughput + latency. Designed for human comparison (run
%%% before/after a change), not as a CI gate -- numbers vary with
%%% machine load.
%%%
%%% Usage:
%%%   ./scripts/stress.escript [opts]
%%%   ./scripts/stress.escript --help
%%%
%%% Run with `--help` for the full flag list. Three scenarios cover the
%%% interesting connection patterns:
%%%
%%%   concurrent  Each worker opens a fresh TCP conn, sends one GET with
%%%               `Connection: close`, reads the response, closes. Repeats
%%%               until the duration elapses. Stresses accept + setup/teardown.
%%%   keep_alive  Each worker opens one TCP conn at start, then loops
%%%               GET/recv/GET/recv on the same conn. Stresses the per-conn
%%%               state machine and the finishing -> reading_request loop-back.
%%%   pipeline    Same as keep_alive but every send packs K requests into one
%%%               gen_tcp:send and reads K responses back to back. Stresses the
%%%               buffered-leftover path.
%%%   sweep       Stepped load test — runs `keep_alive` at a sequence of
%%%               client counts and prints a comparison table. Use to find
%%%               the throughput knee and the connection ceiling in one
%%%               run. See --sweep-clients / --sweep-step-duration.
%%%
%%% Output: total requests, errors, RPS, latency percentiles (p50 / p95 /
%%% p99 / max), and bytes transferred. With `--profile`, an eprof hotspot
%%% table follows the report.

-mode(compile).

-define(DEFAULT_SCENARIO, concurrent).
-define(DEFAULT_CLIENTS, 50).
-define(DEFAULT_DURATION_S, 5).
-define(DEFAULT_PIPELINE, 16).
-define(DEFAULT_WARMUP_S, 1).
-define(DEFAULT_HOST, "127.0.0.1").
-define(DEFAULT_SWEEP_START, 10).
-define(DEFAULT_SWEEP_MAX, 100000).
-define(DEFAULT_SWEEP_STEP_DURATION, 2).
-define(DEFAULT_SWEEP_TOLERANCE, 5).

-define(LISTENER, cactus_stress_listener).

main(Args) ->
    Opts = parse_args(Args),
    ProjectDir = project_dir(),
    ok = setup_code_paths(ProjectDir),
    {Port, StopFn} = start_or_attach(Opts),
    Opts1 = Opts#{port => Port},
    print_header(Opts1),
    try
        case maps:get(scenario, Opts1) of
            sweep ->
                run_sweep(Opts1);
            _ ->
                run_warmup(Opts1),
                Result = with_optional_profile(Opts1, fun() -> run_measured(Opts1) end),
                print_report(Opts1, Result),
                maybe_print_profile(Opts1)
        end
    after
        StopFn()
    end.

with_optional_profile(#{profile := false}, Fun) ->
    Fun();
with_optional_profile(#{profile := true}, Fun) ->
    %% Trace every currently-alive process plus anything they spawn for
    %% the duration. set_on_spawn carries the trace flag through child
    %% spawns -- without it, gen_statem:start/3 (used by cactus_acceptor
    %% to launch each conn) produces an untraced child and we'd miss the
    %% hot path entirely. The matchspec `'_'` traces all calls.
    {ok, _} = eprof:start(),
    Roots = processes(),
    profiling = eprof:start_profiling(Roots, {'_', '_', '_'}, [{set_on_spawn, true}]),
    try
        Fun()
    after
        profiling_stopped = eprof:stop_profiling()
    end.

maybe_print_profile(#{profile := false}) ->
    ok;
maybe_print_profile(#{profile := true, profile_min_ms := MinMs}) ->
    io:format("profile (eprof, total time, rows >= ~.2f ms)~n", [MinMs]),
    %% eprof's analyze prints to whatever was set via log/1; pipe to a
    %% temp file so we can trim out the chatty per-process headers and
    %% keep only the totals table.
    LogFile = filename:join(["/tmp", "cactus_stress_eprof.log"]),
    ok = eprof:log(LogFile),
    MinUs = trunc(MinMs * 1000),
    %% Filter rows below the threshold; rows print time-ascending, so
    %% the hottest MFAs land at the bottom of the table -- right above
    %% the next shell prompt where they're easiest to spot.
    _ = eprof:analyze(total, [{filter, [{time, MinUs}]}]),
    stopped = eprof:stop(),
    case file:read_file(LogFile) of
        {ok, Bin} ->
            io:put_chars(Bin),
            io:nl();
        {error, Reason} ->
            io:format("error: could not read ~s: ~p~n", [LogFile, Reason])
    end.

%% ===========================================================================
%% Args
%% ===========================================================================

cli() ->
    #{
        help =>
            "HTTP stress test for cactus.\n\n"
            "Drives concurrent traffic at a cactus listener and reports "
            "throughput + latency.\nDesigned for human comparison "
            "(run before/after a change), not as a CI gate -- numbers vary "
            "with machine load.",
        arguments => [
            #{
                name => scenario,
                long => "-scenario",
                type => {atom, [concurrent, keep_alive, pipeline, sweep]},
                default => ?DEFAULT_SCENARIO,
                help =>
                    "concurrent: fresh TCP conn per request (stresses accept).\n"
                    "keep_alive: persistent conn, sequential GETs.\n"
                    "pipeline:   K requests per send on one conn.\n"
                    "sweep:      stepped load — runs keep_alive at increasing client\n"
                    "            counts (see --sweep-clients) and prints one table."
            },
            #{
                name => clients,
                long => "-clients",
                type => {integer, [{min, 1}]},
                default => ?DEFAULT_CLIENTS,
                help => "Number of worker processes."
            },
            #{
                name => duration_s,
                long => "-duration",
                type => {integer, [{min, 1}]},
                default => ?DEFAULT_DURATION_S,
                help => "Seconds to run the measured phase."
            },
            #{
                name => pipeline,
                long => "-pipeline",
                type => {integer, [{min, 1}]},
                default => ?DEFAULT_PIPELINE,
                help => "Requests per pipelined burst (pipeline scenario)."
            },
            #{
                name => warmup_s,
                long => "-warmup",
                type => {integer, [{min, 0}]},
                default => ?DEFAULT_WARMUP_S,
                help => "Seconds of pre-measurement traffic discarded from the report."
            },
            #{
                name => host,
                long => "-host",
                type => string,
                default => ?DEFAULT_HOST,
                help => "Target host (used with --port)."
            },
            #{
                name => port,
                long => "-port",
                type => {integer, [{min, 1}, {max, 65535}]},
                help =>
                    "Target an already-running listener on this port.\n"
                    "Without --port, the script boots cactus in-process on a free port."
            },
            #{
                name => profile,
                long => "-profile",
                type => boolean,
                default => false,
                help =>
                    "Run the measured phase under eprof and print a hotspot table.\n"
                    "Throughput numbers under --profile are NOT comparable to a normal run;\n"
                    "the report exists to point at MFAs worth optimizing."
            },
            #{
                name => profile_min_ms,
                long => "-profile-min-ms",
                type => float,
                default => 1.0,
                help => "Minimum total ms for a row to appear in the hotspot table."
            },
            #{
                name => sweep_start,
                long => "-sweep-start",
                type => {integer, [{min, 1}]},
                default => ?DEFAULT_SWEEP_START,
                help => "Initial client count for the sweep scenario."
            },
            #{
                name => sweep_max,
                long => "-sweep-max",
                type => {integer, [{min, 1}]},
                default => ?DEFAULT_SWEEP_MAX,
                help =>
                    "Hard cap on sweep client count. The sweep stops early\n"
                    "when throughput regresses or server-side errors appear."
            },
            #{
                name => sweep_step_duration,
                long => "-sweep-step-duration",
                type => {integer, [{min, 1}]},
                default => ?DEFAULT_SWEEP_STEP_DURATION,
                help => "Seconds to run each sweep step."
            },
            #{
                name => sweep_tolerance,
                long => "-sweep-tolerance",
                type => {integer, [{min, 1}]},
                default => ?DEFAULT_SWEEP_TOLERANCE,
                help =>
                    "Bisection precision — stop bisecting when the gap between\n"
                    "last-good and first-fail is below this many clients."
            }
        ]
    }.

parse_args(Argv) ->
    Cli = cli(),
    ProgOpts = #{progname => "stress.escript"},
    case argparse:parse(Argv, Cli, ProgOpts) of
        {ok, Parsed, _Path, _Cmd} ->
            Parsed;
        {error, Reason} ->
            io:format(standard_error, "~s~n~n", [argparse:format_error(Reason)]),
            io:format(standard_error, "~s~n", [argparse:help(Cli, ProgOpts)]),
            halt(2)
    end.

%% ===========================================================================
%% Listener lifecycle (in-process unless --port given)
%% ===========================================================================

start_or_attach(#{port := Port}) when is_integer(Port) ->
    {Port, fun() -> ok end};
start_or_attach(_Opts) ->
    {ok, _} = application:ensure_all_started(cactus),
    {ok, _} = cactus:start_listener(?LISTENER, #{
        port => 0,
        handler => cactus_keepalive_handler,
        keep_alive_timeout => 60000,
        max_clients => 10000,
        max_keep_alive_request => 1000000
    }),
    Port = cactus_listener:port(?LISTENER),
    {Port, fun() -> ok = cactus:stop_listener(?LISTENER) end}.

%% ===========================================================================
%% Header / report
%% ===========================================================================

print_header(#{scenario := sweep, host := H, port := P}) ->
    io:format("~ncactus stress~n"),
    io:format(
        "  scenario   : sweep~n"
        "  target     : ~s:~B~n",
        [H, P]
    ),
    %% Per-step params are printed by run_sweep itself.
    io:nl();
print_header(#{
    scenario := S,
    clients := C,
    duration_s := D,
    warmup_s := W,
    pipeline := K,
    host := H,
    port := P
}) ->
    io:format("~ncactus stress~n"),
    io:format(
        "  scenario   : ~s~n"
        "  target     : ~s:~B~n"
        "  clients    : ~B~n"
        "  warmup     : ~Bs~n"
        "  duration   : ~Bs~n",
        [S, H, P, C, W, D]
    ),
    case S of
        pipeline -> io:format("  pipeline K : ~B~n", [K]);
        _ -> ok
    end,
    io:format("~n").

print_report(_Opts, #{
    total := Total,
    errors := Errors,
    err_buckets := Buckets,
    bytes_in := BytesIn,
    bytes_out := BytesOut,
    elapsed_us := ElapsedUs,
    latencies_ns := Latencies
}) ->
    Sorted = lists:sort(Latencies),
    N = length(Sorted),
    Rps = case ElapsedUs of
        0 -> 0.0;
        _ -> Total * 1000000 / ElapsedUs
    end,
    P50 = pct(Sorted, N, 0.50),
    P95 = pct(Sorted, N, 0.95),
    P99 = pct(Sorted, N, 0.99),
    Max = case Sorted of
        [] -> 0;
        _ -> lists:last(Sorted)
    end,
    Mean = case N of
        0 -> 0;
        _ -> lists:sum(Sorted) div N
    end,
    io:format("results~n"),
    io:format(
        "  requests   : ~s ok / ~s err~n"
        "  duration   : ~.3f s~n"
        "  throughput : ~.1f req/s~n"
        "  bytes      : ~s out / ~s in~n",
        [
            fmt_int(Total),
            fmt_int(Errors),
            ElapsedUs / 1000000,
            Rps,
            fmt_bytes(BytesOut),
            fmt_bytes(BytesIn)
        ]
    ),
    io:format(
        "  latency    : mean ~s | p50 ~s | p95 ~s | p99 ~s | max ~s~n",
        [fmt_ns(Mean), fmt_ns(P50), fmt_ns(P95), fmt_ns(P99), fmt_ns(Max)]
    ),
    print_err_buckets(Buckets),
    io:nl().

print_err_buckets(Buckets) when map_size(Buckets) =:= 0 ->
    ok;
print_err_buckets(Buckets) ->
    %% Sort by descending count so the dominant cause shows first.
    Sorted = lists:sort(
        fun({_, A}, {_, B}) -> A >= B end, maps:to_list(Buckets)
    ),
    Lines = [io_lib:format("~s=~s", [fmt_reason(R), fmt_int(C)]) || {R, C} <- Sorted],
    io:format("  err causes : ~s~n", [lists:join(", ", Lines)]).

fmt_reason({Class, Sub}) -> io_lib:format("~p:~p", [Class, Sub]);
fmt_reason(R) -> io_lib:format("~p", [R]).

pct([], _N, _Q) -> 0;
pct(Sorted, N, Q) ->
    Idx = max(1, min(N, round(Q * N))),
    lists:nth(Idx, Sorted).

%% ===========================================================================
%% Workload
%% ===========================================================================

run_warmup(#{warmup_s := 0}) ->
    ok;
run_warmup(Opts) ->
    _ = run_phase(Opts, maps:get(warmup_s, Opts) * 1000),
    ok.

run_measured(Opts) ->
    DurationMs = maps:get(duration_s, Opts) * 1000,
    run_phase(Opts, DurationMs).

%% ===========================================================================
%% Sweep — push the server until it breaks, then bisect the boundary
%% ===========================================================================
%%
%% Two phases:
%%   1. **Doubling** — double the client count each step until throughput
%%      regresses ≥5% (saturation) or server-side errors appear (ceiling).
%%      Fast convergence to the ballpark.
%%   2. **Bisection** — between the last-good and first-fail counts from
%%      phase 1, halve the gap until it's smaller than --sweep-tolerance.
%%      Pinpoints the ceiling precisely.
%%
%% Harness-side errors (connect:timeout, EMFILE on the loadgen) are tracked
%% but NOT a stop condition — they tell us the loadgen ran out of sockets,
%% not that cactus broke. Raise `ulimit -n` to push further.

run_sweep(
    #{
        sweep_start := Start,
        sweep_max := Max,
        sweep_step_duration := StepS,
        sweep_tolerance := Tol
    } = Opts
) ->
    StepMs = StepS * 1000,
    BaseOpts = Opts#{scenario => keep_alive, warmup_s => 0},
    io:format(
        "running sweep: start=~B max=~B step=~Bs tolerance=~B~n~n"
        "phase 1 — doubling~n",
        [Start, Max, StepS, Tol]
    ),
    {Rows1, GoodFail} = doubling_loop(BaseOpts, Start, Max, StepMs, undefined, []),
    Rows2 =
        case GoodFail of
            {LastGood, FirstFail} when FirstFail - LastGood > Tol ->
                io:format("~nphase 2 — bisecting between ~B and ~B~n", [LastGood, FirstFail]),
                bisection_loop(BaseOpts, LastGood, FirstFail, StepMs, Tol, []);
            _ ->
                []
        end,
    print_sweep_table(lists:reverse(Rows1) ++ lists:reverse(Rows2), GoodFail).

doubling_loop(_Opts, N, Max, _StepMs, _Prev, Rows) when N > Max ->
    {Rows, undefined};
doubling_loop(Opts, N, Max, StepMs, PrevRps, Rows) ->
    Result = run_phase(Opts#{clients => N}, StepMs),
    Row = sweep_row(N, double, Result),
    io:format("  ~s~n", [fmt_sweep_row(Row)]),
    case stop_reason(Row, PrevRps) of
        continue ->
            doubling_loop(Opts, N * 2, Max, StepMs, maps:get(rps, Row), [Row | Rows]);
        {stop, Reason} ->
            io:format("~nphase 1 stop: ~ts~n", [Reason]),
            LastGood = last_good_clients(Rows),
            {[Row | Rows], {LastGood, N}}
    end.

last_good_clients([]) -> 0;
last_good_clients([#{clients := C} | _]) -> C.

bisection_loop(_Opts, Good, Fail, _StepMs, Tol, Rows) when Fail - Good =< Tol ->
    Rows;
bisection_loop(Opts, Good, Fail, StepMs, Tol, Rows) ->
    Mid = Good + (Fail - Good) div 2,
    Result = run_phase(Opts#{clients => Mid}, StepMs),
    Row = sweep_row(Mid, bisect, Result),
    io:format("  ~s~n", [fmt_sweep_row(Row)]),
    case maps:get(server_errs, Row) of
        0 ->
            bisection_loop(Opts, Mid, Fail, StepMs, Tol, [Row | Rows]);
        _ ->
            bisection_loop(Opts, Good, Mid, StepMs, Tol, [Row | Rows])
    end.

sweep_row(Clients, Phase, #{
    total := Total,
    err_buckets := Buckets,
    elapsed_us := ElapsedUs,
    latencies_ns := Latencies
}) ->
    Sorted = lists:sort(Latencies),
    N = length(Sorted),
    Rps =
        case ElapsedUs of
            0 -> 0.0;
            _ -> Total * 1000000 / ElapsedUs
        end,
    #{
        clients => Clients,
        phase => Phase,
        rps => Rps,
        total => Total,
        p50 => pct(Sorted, N, 0.50),
        p99 => pct(Sorted, N, 0.99),
        harness_errs => harness_errs(Buckets),
        server_errs => server_errs(Buckets),
        buckets => Buckets
    }.

%% Errors caused by the loadgen running out of resources (TIME_WAIT,
%% EMFILE) — not a server failure. Raise ulimit to push further.
harness_errs(Buckets) ->
    maps:fold(
        fun(K, V, Acc) ->
            case K of
                {connect, _} -> Acc + V;
                {send, eaddrnotavail} -> Acc + V;
                {send, eaddrinuse} -> Acc + V;
                {send, emfile} -> Acc + V;
                _ -> Acc
            end
        end,
        0,
        Buckets
    ).

%% Errors that mean cactus actually failed to serve the request — the
%% server closed the connection mid-flight, returned bad bytes, or the
%% recv timed out waiting for a response.
server_errs(Buckets) ->
    maps:fold(
        fun(K, V, Acc) ->
            case K of
                bad_reply -> Acc + V;
                empty_reply -> Acc + V;
                {recv, _} -> Acc + V;
                {send, closed} -> Acc + V;
                _ -> Acc
            end
        end,
        0,
        Buckets
    ).

stop_reason(#{server_errs := S, buckets := Buckets}, _Prev) when S > 0 ->
    {stop, format_server_err_stop(Buckets)};
stop_reason(#{rps := Rps}, undefined) when Rps > 0 ->
    continue;
stop_reason(#{rps := _}, undefined) ->
    {stop, "no successful requests in first step — abort"};
stop_reason(#{rps := Rps}, Prev) when Rps >= Prev * 0.95 ->
    continue;
stop_reason(_, _) ->
    {stop, "throughput regressed >5% from prior step — saturation"}.

format_server_err_stop(Buckets) ->
    %% Show the dominant server-side reason so the user knows whether the
    %% ceiling is "conn closed mid-stream" vs "bad reply" etc.
    Server = maps:filter(
        fun(K, _) ->
            case K of
                bad_reply -> true;
                empty_reply -> true;
                {recv, _} -> true;
                {send, closed} -> true;
                _ -> false
            end
        end,
        Buckets
    ),
    Sorted = lists:sort(fun({_, A}, {_, B}) -> A >= B end, maps:to_list(Server)),
    Pretty = lists:join(
        ", ",
        [io_lib:format("~ts=~B", [fmt_reason(R), C]) || {R, C} <- Sorted]
    ),
    io_lib:format(
        "server-side errors — cactus ceiling reached (~ts)",
        [Pretty]
    ).

print_sweep_table(Rows, GoodFail) ->
    io:format(
        "~n~-7s  ~-8s  ~10s  ~10s  ~10s  ~10s  ~10s~n",
        ["phase", "clients", "rps", "p50", "p99", "harness_e", "server_e"]
    ),
    io:format("~s~n", [string:copies("-", 75)]),
    lists:foreach(
        fun(R) -> io:format("  ~s~n", [fmt_sweep_row(R)]) end,
        Rows
    ),
    io:nl(),
    case Rows of
        [] ->
            ok;
        _ ->
            Best = lists:max([maps:get(rps, R) || R <- Rows]),
            BestRow = hd([R || R <- Rows, maps:get(rps, R) =:= Best]),
            io:format(
                "peak: ~s req/s at ~B clients~n",
                [fmt_int(round(Best)), maps:get(clients, BestRow)]
            ),
            print_ceiling(GoodFail, Rows)
    end.

print_ceiling(undefined, _Rows) ->
    %% Doubling never failed — we hit the cap before the ceiling.
    io:format("ceiling: not reached (raise --sweep-max to push further)~n");
print_ceiling({_DGood, _DFail}, Rows) ->
    %% Use the LOWEST client count with server errors as the first-fail
    %% boundary, and the highest count STRICTLY BELOW that with no server
    %% errors as the last-clean. Anything above the first-fail count may
    %% pass or fail by chance — don't include it in the bracket.
    Failing = [maps:get(clients, R) || R <- Rows, maps:get(server_errs, R) > 0],
    case Failing of
        [] ->
            io:format(
                "ceiling: no server errors observed — limit was throughput "
                "saturation, not failure~n"
            );
        _ ->
            LowestFail = lists:min(Failing),
            CleanBelow = [
                maps:get(clients, R)
             || R <- Rows,
                maps:get(server_errs, R) =:= 0,
                maps:get(clients, R) < LowestFail
            ],
            HighestOk =
                case CleanBelow of
                    [] -> 0;
                    _ -> lists:max(CleanBelow)
                end,
            io:format(
                "ceiling: server errors first observed at ~B clients "
                "(highest clean below: ~B)~n",
                [LowestFail, HighestOk]
            )
    end.

fmt_sweep_row(#{
    clients := C,
    phase := Phase,
    rps := Rps,
    p50 := P50,
    p99 := P99,
    harness_errs := HE,
    server_errs := SE
}) ->
    io_lib:format(
        "~-7s  ~-8B  ~10s  ~10s  ~10s  ~10B  ~10B",
        [phase_label(Phase), C, fmt_int(round(Rps)), fmt_ns(P50), fmt_ns(P99), HE, SE]
    ).

phase_label(double) -> "double";
phase_label(bisect) -> "bisect".

run_phase(#{clients := C} = Opts, DurationMs) ->
    Self = self(),
    Deadline = erlang:monotonic_time(millisecond) + DurationMs,
    StartUs = erlang:monotonic_time(microsecond),
    Workers = [
        spawn_link(fun() ->
            Result = worker_run(Opts, Deadline),
            Self ! {self(), Result}
        end)
     || _ <- lists:seq(1, C)
    ],
    PerWorker = [collect(W, DurationMs + 30000) || W <- Workers],
    EndUs = erlang:monotonic_time(microsecond),
    aggregate(PerWorker, EndUs - StartUs).

collect(Pid, TimeoutMs) ->
    receive
        {Pid, R} -> R
    after TimeoutMs ->
        io:format("error: worker ~p timed out~n", [Pid]),
        halt(1)
    end.

aggregate(PerWorker, ElapsedUs) ->
    Init = #{
        total => 0,
        errors => 0,
        err_buckets => #{},
        bytes_in => 0,
        bytes_out => 0,
        latencies_ns => [],
        elapsed_us => ElapsedUs
    },
    lists:foldl(
        fun(W, Acc) ->
            #{
                ok := Ok,
                err := Err,
                err_buckets := WB,
                bytes_in := In,
                bytes_out := Out,
                latencies_ns := L
            } = W,
            #{
                total := T,
                errors := E,
                err_buckets := AB,
                bytes_in := In0,
                bytes_out := Out0,
                latencies_ns := L0
            } = Acc,
            Acc#{
                total := T + Ok,
                errors := E + Err,
                err_buckets := merge_buckets(AB, WB),
                bytes_in := In0 + In,
                bytes_out := Out0 + Out,
                latencies_ns := L ++ L0
            }
        end,
        Init,
        PerWorker
    ).

merge_buckets(A, B) ->
    maps:fold(fun(K, V, Acc) -> maps:update_with(K, fun(X) -> X + V end, V, Acc) end, A, B).

%% ===========================================================================
%% Worker scenarios
%% ===========================================================================

worker_run(#{scenario := concurrent} = Opts, Deadline) ->
    worker_concurrent(Opts, Deadline, init_acc());
worker_run(#{scenario := keep_alive} = Opts, Deadline) ->
    worker_keep_alive(Opts, Deadline);
worker_run(#{scenario := pipeline} = Opts, Deadline) ->
    worker_pipeline(Opts, Deadline);
worker_run(#{scenario := S}, _Deadline) ->
    io:format("error: unknown scenario ~p~n", [S]),
    halt(1).

init_acc() ->
    #{ok => 0, err => 0, err_buckets => #{}, bytes_in => 0, bytes_out => 0, latencies_ns => []}.

%% --- concurrent: fresh conn per request -----------------------------------

worker_concurrent(Opts, Deadline, Acc) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true -> Acc;
        false -> worker_concurrent(Opts, Deadline, do_one_close(Opts, Acc))
    end.

do_one_close(#{host := Host, port := Port}, Acc) ->
    Req = ~"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    T0 = erlang:monotonic_time(nanosecond),
    case gen_tcp:connect(Host, Port, [binary, {active, false}], 5000) of
        {ok, Sock} ->
            case gen_tcp:send(Sock, Req) of
                ok ->
                    Reply = recv_until_closed(Sock, 5000, <<>>),
                    ok = gen_tcp:close(Sock),
                    T1 = erlang:monotonic_time(nanosecond),
                    case Reply of
                        <<"HTTP/1.1 200 OK", _/binary>> ->
                            bump_ok(Acc, T1 - T0, byte_size(Req), byte_size(Reply));
                        <<>> ->
                            bump_err(Acc, empty_reply);
                        _ ->
                            bump_err(Acc, bad_reply)
                    end;
                {error, Reason} ->
                    _ = gen_tcp:close(Sock),
                    bump_err(Acc, {send, Reason})
            end;
        {error, Reason} ->
            bump_err(Acc, {connect, Reason})
    end.

%% --- keep_alive: persistent conn, sequential requests ---------------------

worker_keep_alive(#{host := Host, port := Port} = Opts, Deadline) ->
    case gen_tcp:connect(Host, Port, [binary, {active, false}], 5000) of
        {ok, Sock} ->
            Acc = keep_alive_loop(Opts, Sock, Deadline, init_acc()),
            ok = gen_tcp:close(Sock),
            Acc;
        {error, Reason} ->
            bump_err(init_acc(), {connect, Reason})
    end.

keep_alive_loop(Opts, Sock, Deadline, Acc) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true ->
            Acc;
        false ->
            Req = ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n",
            T0 = erlang:monotonic_time(nanosecond),
            case gen_tcp:send(Sock, Req) of
                ok ->
                    case recv_keepalive_response(Sock, <<>>, 5000) of
                        {ok, Bytes} ->
                            T1 = erlang:monotonic_time(nanosecond),
                            keep_alive_loop(
                                Opts, Sock, Deadline,
                                bump_ok(Acc, T1 - T0, byte_size(Req), Bytes)
                            );
                        {error, Reason} ->
                            bump_err(Acc, {recv, Reason})
                    end;
                {error, Reason} ->
                    bump_err(Acc, {send, Reason})
            end
    end.

%% --- pipeline: K requests per send, K responses per recv -------------------

worker_pipeline(#{host := Host, port := Port, pipeline := K} = Opts, Deadline) ->
    case gen_tcp:connect(Host, Port, [binary, {active, false}], 5000) of
        {ok, Sock} ->
            Burst = iolist_to_binary(
                lists:duplicate(K, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
            ),
            Acc = pipeline_loop(Opts, Sock, Deadline, K, Burst, init_acc()),
            ok = gen_tcp:close(Sock),
            Acc;
        {error, Reason} ->
            bump_err(init_acc(), {connect, Reason})
    end.

pipeline_loop(Opts, Sock, Deadline, K, Burst, Acc) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true ->
            Acc;
        false ->
            T0 = erlang:monotonic_time(nanosecond),
            case gen_tcp:send(Sock, Burst) of
                ok ->
                    case recv_pipelined_responses(Sock, <<>>, K, 10000) of
                        {ok, BytesIn} ->
                            T1 = erlang:monotonic_time(nanosecond),
                            %% Per-request latency = burst latency / K. The
                            %% percentile report consumes per-request samples
                            %% so it lines up with the other scenarios.
                            PerReq = (T1 - T0) div max(1, K),
                            #{
                                ok := O,
                                bytes_in := In,
                                bytes_out := Out,
                                latencies_ns := L
                            } = Acc,
                            Acc1 = Acc#{
                                ok := O + K,
                                bytes_in := In + BytesIn,
                                bytes_out := Out + byte_size(Burst),
                                latencies_ns := lists:duplicate(K, PerReq) ++ L
                            },
                            pipeline_loop(Opts, Sock, Deadline, K, Burst, Acc1);
                        {error, Reason} ->
                            bump_err(Acc, {recv, Reason})
                    end;
                {error, Reason} ->
                    bump_err(Acc, {send, Reason})
            end
    end.

%% ===========================================================================
%% Response parsing
%% ===========================================================================

recv_until_closed(Sock, TimeoutMs, Acc) ->
    case gen_tcp:recv(Sock, 0, TimeoutMs) of
        {ok, D} -> recv_until_closed(Sock, TimeoutMs, <<Acc/binary, D/binary>>);
        {error, _} -> Acc
    end.

%% Read one keepalive response (status + headers + 7-byte body from
%% cactus_keepalive_handler). Returns {ok, BytesRead} or {error, _}.
recv_keepalive_response(Sock, Buf, TimeoutMs) ->
    case binary:split(Buf, ~"\r\n\r\n") of
        [_Headers, Body] when byte_size(Body) >= 7 ->
            case Buf of
                <<"HTTP/1.1 200 OK", _/binary>> -> {ok, byte_size(Buf)};
                _ -> {error, bad_status}
            end;
        _ ->
            case gen_tcp:recv(Sock, 0, TimeoutMs) of
                {ok, D} -> recv_keepalive_response(Sock, <<Buf/binary, D/binary>>, TimeoutMs);
                {error, _} = E -> E
            end
    end.

%% Read K back-to-back keepalive responses, returning the running
%% recv'd byte count (not the leftover buffer size, which is ~0 after
%% consuming K responses).
recv_pipelined_responses(Sock, Buf, K, TimeoutMs) ->
    recv_pipelined_responses(Sock, Buf, K, 0, byte_size(Buf), TimeoutMs).

recv_pipelined_responses(_Sock, _Buf, K, K, BytesIn, _TimeoutMs) ->
    {ok, BytesIn};
recv_pipelined_responses(Sock, Buf, K, Got, BytesIn, TimeoutMs) when Got < K ->
    case consume_one(Buf) of
        {ok, Rest} ->
            recv_pipelined_responses(Sock, Rest, K, Got + 1, BytesIn, TimeoutMs);
        more ->
            case gen_tcp:recv(Sock, 0, TimeoutMs) of
                {ok, D} ->
                    recv_pipelined_responses(
                        Sock,
                        <<Buf/binary, D/binary>>,
                        K,
                        Got,
                        BytesIn + byte_size(D),
                        TimeoutMs
                    );
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

consume_one(Buf) ->
    case binary:split(Buf, ~"\r\n\r\n") of
        [_Headers, Tail] ->
            case Buf of
                <<"HTTP/1.1 200 OK", _/binary>> ->
                    %% cactus_keepalive_handler writes Content-Length: 7.
                    case Tail of
                        <<_:7/binary, Rest/binary>> -> {ok, Rest};
                        _ -> more
                    end;
                _ ->
                    {error, bad_status}
            end;
        _ ->
            more
    end.

%% ===========================================================================
%% Acc helpers
%% ===========================================================================

bump_ok(#{ok := O, bytes_in := In, bytes_out := Out, latencies_ns := L} = Acc,
        Ns, ReqBytes, RespBytes) ->
    Acc#{
        ok := O + 1,
        bytes_in := In + RespBytes,
        bytes_out := Out + ReqBytes,
        latencies_ns := [Ns | L]
    }.

bump_err(#{err := E, err_buckets := B} = Acc, Reason) ->
    Acc#{
        err := E + 1,
        err_buckets := maps:update_with(Reason, fun(N) -> N + 1 end, 1, B)
    }.

%% ===========================================================================
%% Format helpers
%% ===========================================================================

fmt_int(N) when is_integer(N) ->
    fmt_int_str(integer_to_list(N)).

fmt_int_str(Str) when length(Str) =< 3 ->
    Str;
fmt_int_str(Str) ->
    {Head, Tail} = lists:split(length(Str) - 3, Str),
    fmt_int_str(Head) ++ "," ++ Tail.

fmt_bytes(N) when N < 1024 -> io_lib:format("~B B", [N]);
fmt_bytes(N) when N < 1024 * 1024 -> io_lib:format("~.1f KB", [N / 1024]);
fmt_bytes(N) when N < 1024 * 1024 * 1024 -> io_lib:format("~.1f MB", [N / (1024 * 1024)]);
fmt_bytes(N) -> io_lib:format("~.2f GB", [N / (1024 * 1024 * 1024)]).

fmt_ns(N) when N < 1000 -> io_lib:format("~B ns", [N]);
fmt_ns(N) when N < 1000000 -> io_lib:format("~.1f µs", [N / 1000]);
fmt_ns(N) when N < 1000000000 -> io_lib:format("~.2f ms", [N / 1000000]);
fmt_ns(N) -> io_lib:format("~.2f s", [N / 1000000000]).

%% ===========================================================================
%% Code paths
%% ===========================================================================

setup_code_paths(BaseDir) ->
    Candidates = [
        filename:join([BaseDir, "_build", "test", "lib"]),
        filename:join([BaseDir, "_build", "default", "lib"])
    ],
    LibDir =
        case lists:filter(fun filelib:is_dir/1, Candidates) of
            [Found | _] ->
                Found;
            [] ->
                io:format(
                    "error: no compiled libs found; run 'rebar3 as test compile' first~n"
                ),
                halt(1)
        end,
    {ok, Libs} = file:list_dir(LibDir),
    lists:foreach(
        fun(Lib) ->
            EbinDir = filename:join([LibDir, Lib, "ebin"]),
            case filelib:is_dir(EbinDir) of
                true -> code:add_pathz(EbinDir);
                false -> ok
            end,
            TestDir = filename:join([LibDir, Lib, "test"]),
            case filelib:is_dir(TestDir) of
                true -> code:add_pathz(TestDir);
                false -> ok
            end
        end,
        Libs
    ),
    ok.

project_dir() ->
    filename:dirname(filename:absname(filename:dirname(escript:script_name()))).
