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

-define(LISTENER, cactus_stress_listener).

main(Args) ->
    Opts = parse_args(Args),
    ProjectDir = project_dir(),
    ok = setup_code_paths(ProjectDir),
    {Port, StopFn} = start_or_attach(Opts),
    Opts1 = Opts#{port => Port},
    print_header(Opts1),
    try
        run_warmup(Opts1),
        Result = with_optional_profile(Opts1, fun() -> run_measured(Opts1) end),
        print_report(Opts1, Result),
        maybe_print_profile(Opts1)
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
                type => {atom, [concurrent, keep_alive, pipeline]},
                default => ?DEFAULT_SCENARIO,
                help =>
                    "concurrent: fresh TCP conn per request (stresses accept).\n"
                    "keep_alive: persistent conn, sequential GETs.\n"
                    "pipeline:   K requests per send on one conn."
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
        "  latency    : mean ~s | p50 ~s | p95 ~s | p99 ~s | max ~s~n~n",
        [fmt_ns(Mean), fmt_ns(P50), fmt_ns(P95), fmt_ns(P99), fmt_ns(Max)]
    ).

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
        bytes_in => 0,
        bytes_out => 0,
        latencies_ns => [],
        elapsed_us => ElapsedUs
    },
    lists:foldl(
        fun(W, Acc) ->
            #{ok := Ok, err := Err, bytes_in := In, bytes_out := Out, latencies_ns := L} = W,
            #{
                total := T,
                errors := E,
                bytes_in := In0,
                bytes_out := Out0,
                latencies_ns := L0
            } = Acc,
            Acc#{
                total := T + Ok,
                errors := E + Err,
                bytes_in := In0 + In,
                bytes_out := Out0 + Out,
                latencies_ns := L ++ L0
            }
        end,
        Init,
        PerWorker
    ).

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
    #{ok => 0, err => 0, bytes_in => 0, bytes_out => 0, latencies_ns => []}.

%% --- concurrent: fresh conn per request -----------------------------------

worker_concurrent(Opts, Deadline, Acc) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true -> Acc;
        false -> worker_concurrent(Opts, Deadline, do_one_close(Opts, Acc))
    end.

do_one_close(#{host := Host, port := Port}, Acc) ->
    Req = ~"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    T0 = erlang:monotonic_time(nanosecond),
    case gen_tcp:connect(Host, Port, [binary, {active, false}], 1000) of
        {ok, Sock} ->
            case gen_tcp:send(Sock, Req) of
                ok ->
                    Reply = recv_until_closed(Sock, 5000, <<>>),
                    ok = gen_tcp:close(Sock),
                    T1 = erlang:monotonic_time(nanosecond),
                    case Reply of
                        <<"HTTP/1.1 200 OK", _/binary>> ->
                            bump_ok(Acc, T1 - T0, byte_size(Req), byte_size(Reply));
                        _ ->
                            bump_err(Acc)
                    end;
                {error, _} ->
                    _ = gen_tcp:close(Sock),
                    bump_err(Acc)
            end;
        {error, _} ->
            bump_err(Acc)
    end.

%% --- keep_alive: persistent conn, sequential requests ---------------------

worker_keep_alive(#{host := Host, port := Port} = Opts, Deadline) ->
    case gen_tcp:connect(Host, Port, [binary, {active, false}], 1000) of
        {ok, Sock} ->
            Acc = keep_alive_loop(Opts, Sock, Deadline, init_acc()),
            ok = gen_tcp:close(Sock),
            Acc;
        {error, _} ->
            bump_err(init_acc())
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
                        {error, _} ->
                            bump_err(Acc)
                    end;
                {error, _} ->
                    bump_err(Acc)
            end
    end.

%% --- pipeline: K requests per send, K responses per recv -------------------

worker_pipeline(#{host := Host, port := Port, pipeline := K} = Opts, Deadline) ->
    case gen_tcp:connect(Host, Port, [binary, {active, false}], 1000) of
        {ok, Sock} ->
            Burst = iolist_to_binary(
                lists:duplicate(K, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
            ),
            Acc = pipeline_loop(Opts, Sock, Deadline, K, Burst, init_acc()),
            ok = gen_tcp:close(Sock),
            Acc;
        {error, _} ->
            bump_err(init_acc())
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
                        {error, _} ->
                            bump_err(Acc)
                    end;
                {error, _} ->
                    bump_err(Acc)
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

bump_err(#{err := E} = Acc) -> Acc#{err := E + 1}.

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
