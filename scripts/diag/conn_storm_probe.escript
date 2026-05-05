#!/usr/bin/env escript
%%% Diagnostic probe for the conn-lifecycle gap (Phase P1 of the
%%% profile-driven conn-lifecycle investigation plan).
%%%
%%% Drives N SEQUENTIAL connections — one at a time, not concurrent —
%%% against a roadrunner / cowboy / elli listener. Each iteration:
%%%
%%%   gen_tcp:connect → send GET / HTTP/1.1 + Connection: close →
%%%   recv 200 → close socket → record latency.
%%%
%%% Why sequential: bench.escript's `connection_storm` scenario uses
%%% 50 concurrent workers, which hides per-conn cost behind scheduler
%%% dispatch noise. Sequential gives a clean "what does ONE conn cost?"
%%% number — the right shape for fprof / per-phase A/B work.
%%%
%%% Usage:
%%%   ./scripts/diag/conn_storm_probe.escript --server roadrunner [--mode local|peer] [--reqs N]
%%%
%%% Two modes:
%%%   --mode local  (default): listener + driver in the SAME BEAM.
%%%   --mode peer            : listener in a peer BEAM (mirrors bench.escript).
%%%
%%% Stays in tree as a permanent diagnostic, like h2_probe.escript.
%%%
%%% First run requires `mise exec -- rebar3 as test compile` so the
%%% non-roadrunner deps (cowboy, elli) and bench fixtures land in
%%% `_build/test/lib/`.

-mode(compile).

-define(DEFAULT_REQS, 1000).
-define(WARMUP_REQS, 50).

main(Args) ->
    Opts = parse_args(Args),
    setup_code_paths(),
    {Peer, Port} = start_server(Opts),
    %% Warmup: warm the JIT, fill any caches, before measuring.
    _ = run_n(Port, ?WARMUP_REQS),
    ProfileHandle = maybe_start_profile(Opts),
    Latencies = run_n(Port, maps:get(reqs, Opts)),
    maybe_stop_profile(Opts, ProfileHandle),
    teardown(Opts, Peer),
    print_summary(Opts, Latencies).

%% Profiling — `--profile fprof` only meaningful in `--mode local`
%% (fprof traces this BEAM's processes; in peer mode the server
%% lives in a different BEAM and would need a peer:call boundary).
%% Survey-grade output written to /tmp; analysis path is printed at
%% the end so the user can grep it.
maybe_start_profile(#{profile := none}) ->
    none;
maybe_start_profile(#{profile := fprof, mode := local, server := roadrunner}) ->
    TraceFile = "/tmp/roadrunner_conn_storm_fprof.trace",
    ok = roadrunner_bench_profiler:start_fprof(TraceFile),
    TraceFile;
maybe_start_profile(#{profile := fprof, mode := local, server := Server}) ->
    %% Profiling cowboy/elli is interesting for cross-server comparison
    %% but their per-pid seed isn't trivially available — punt for now.
    %% Survey is roadrunner-focused.
    io:format(
        "note: --profile fprof only supported for --server roadrunner "
        "(asked for ~p)~n",
        [Server]
    ),
    none;
maybe_start_profile(#{profile := fprof, mode := peer}) ->
    io:format("note: --profile fprof requires --mode local~n"),
    none.

maybe_stop_profile(_, none) ->
    ok;
maybe_stop_profile(_, TraceFile) ->
    AnalysisPath = "/tmp/roadrunner_conn_storm_fprof.analysis",
    ok = roadrunner_bench_profiler:stop_fprof_and_dump(TraceFile, AnalysisPath),
    io:format("~nfprof analysis written to ~s~n", [AnalysisPath]),
    io:format("  trace: ~s~n", [TraceFile]).

parse_args(Args) -> parse_args(Args, #{mode => local, reqs => ?DEFAULT_REQS, profile => none}).

parse_args([], #{server := _} = Opts) ->
    Opts;
parse_args([], _) ->
    usage();
parse_args(["--server", S | T], Opts) ->
    parse_args(T, Opts#{server => list_to_atom(S)});
parse_args(["--mode", M | T], Opts) ->
    parse_args(T, Opts#{mode => list_to_atom(M)});
parse_args(["--reqs", N | T], Opts) ->
    parse_args(T, Opts#{reqs => list_to_integer(N)});
parse_args(["--profile", "fprof" | T], Opts) ->
    parse_args(T, Opts#{profile => fprof});
parse_args(_, _) ->
    usage().

usage() ->
    io:format(
        "usage: conn_storm_probe.escript --server roadrunner|cowboy|elli "
        "[--mode local|peer] [--reqs N] [--profile fprof]~n"
    ),
    halt(2).

setup_code_paths() ->
    BaseDir = filename:dirname(filename:absname(filename:dirname(escript:script_name()))),
    BaseDir1 = filename:dirname(BaseDir),
    Candidates = [
        filename:join([BaseDir1, "_build", "test", "lib"]),
        filename:join([BaseDir1, "_build", "default", "lib"])
    ],
    LibDir =
        case lists:filter(fun filelib:is_dir/1, Candidates) of
            [Found | _] ->
                Found;
            [] ->
                io:format("error: run 'mise exec -- rebar3 as test compile' first~n"),
                halt(1)
        end,
    {ok, Libs} = file:list_dir(LibDir),
    lists:foreach(
        fun(Lib) ->
            EbinDir = filename:join([LibDir, Lib, "ebin"]),
            case filelib:is_dir(EbinDir) of
                true -> code:add_pathz(EbinDir);
                false -> ok
            end
        end,
        Libs
    ),
    %% Bench fixtures (roadrunner_keepalive_handler,
    %% roadrunner_bench_cowboy_handler, etc.) live in
    %% `_build/test/lib/roadrunner/test/`, not `ebin/`. The roadrunner
    %% test profile compiles them but rebar3 doesn't add this dir to
    %% the runtime code path. Add it manually so the probe can find
    %% the fixtures referenced in start_server/1.
    TestDir = filename:join([LibDir, "roadrunner", "test"]),
    case filelib:is_dir(TestDir) of
        true -> code:add_pathz(TestDir);
        false -> ok
    end,
    ok.

start_server(#{server := roadrunner, mode := local}) ->
    {ok, _} = application:ensure_all_started(roadrunner),
    {ok, _} = roadrunner:start_listener(probe_rr, rr_listener_opts()),
    {undefined, roadrunner_listener:port(probe_rr)};
start_server(#{server := roadrunner, mode := peer}) ->
    {ok, Peer} = peer_start(),
    {ok, _} = peer:call(Peer, application, ensure_all_started, [roadrunner]),
    {ok, _} = peer:call(Peer, roadrunner, start_listener, [probe_rr, rr_listener_opts()]),
    {Peer, peer:call(Peer, roadrunner_listener, port, [probe_rr])};
start_server(#{server := cowboy, mode := local}) ->
    {ok, _} = application:ensure_all_started(cowboy),
    Dispatch = cowboy_router:compile([
        {'_', [{"/", roadrunner_bench_cowboy_handler, []}]}
    ]),
    {ok, _} = cowboy:start_clear(
        probe_cb,
        #{num_acceptors => 10, socket_opts => [{port, 0}]},
        #{env => #{dispatch => Dispatch}, max_keepalive => 1000000}
    ),
    {undefined, ranch:get_port(probe_cb)};
start_server(#{server := cowboy, mode := peer}) ->
    {ok, Peer} = peer_start(),
    {ok, _} = peer:call(Peer, application, ensure_all_started, [cowboy]),
    Dispatch = peer:call(Peer, cowboy_router, compile, [
        [{'_', [{"/", roadrunner_bench_cowboy_handler, []}]}]
    ]),
    {ok, _} = peer:call(Peer, cowboy, start_clear, [
        probe_cb,
        #{num_acceptors => 10, socket_opts => [{port, 0}]},
        #{env => #{dispatch => Dispatch}, max_keepalive => 1000000}
    ]),
    {Peer, peer:call(Peer, ranch, get_port, [probe_cb])};
start_server(#{server := elli, mode := local}) ->
    {ok, _} = application:ensure_all_started(elli),
    {ok, Port} = roadrunner_bench_elli_launcher:start(roadrunner_bench_elli_handler),
    {undefined, Port};
start_server(#{server := elli, mode := peer}) ->
    {ok, Peer} = peer_start(),
    {ok, _} = peer:call(Peer, application, ensure_all_started, [elli]),
    {ok, Port} = peer:call(Peer, roadrunner_bench_elli_launcher, start, [
        roadrunner_bench_elli_handler
    ]),
    {Peer, Port};
start_server(_) ->
    io:format("error: --server must be one of roadrunner|cowboy|elli~n"),
    halt(2).

peer_start() ->
    {ok, Peer, _Node} = peer:start_link(#{
        name => peer:random_name(),
        connection => standard_io,
        args => pa_args_for_peer(),
        wait_boot => 10000
    }),
    {ok, Peer}.

pa_args_for_peer() ->
    Paths = [P || P <- code:get_path(), filelib:is_dir(P)],
    lists:foldr(fun(P, Acc) -> ["-pa", P | Acc] end, [], Paths).

teardown(#{server := roadrunner, mode := local}, _) ->
    try roadrunner:stop_listener(probe_rr) of _ -> ok catch _:_ -> ok end;
teardown(#{server := cowboy, mode := local}, _) ->
    try cowboy:stop_listener(probe_cb) of _ -> ok catch _:_ -> ok end;
teardown(#{server := elli, mode := local}, _) ->
    %% Elli has no graceful stop in this fixture — application:stop
    %% would suffice but is heavy; rely on script exit to clean up.
    ok;
teardown(#{mode := peer}, Peer) ->
    try peer:stop(Peer) of _ -> ok catch _:_ -> ok end.

rr_listener_opts() ->
    #{
        port => 0,
        handler => roadrunner_keepalive_handler,
        keep_alive_timeout => 60000,
        max_clients => 100000,
        max_keep_alive_request => 1000000
    }.

%% N sequential connections, each: connect → send → recv → close.
%% Returns latencies in microseconds.
run_n(Port, N) ->
    Req = ~"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    run_loop(Port, Req, N, []).

run_loop(_Port, _Req, 0, Acc) ->
    Acc;
run_loop(Port, Req, N, Acc) ->
    T0 = erlang:monotonic_time(microsecond),
    {ok, Sock} = gen_tcp:connect(
        "127.0.0.1", Port,
        [binary, {active, false}, {nodelay, true}],
        5000
    ),
    ok = gen_tcp:send(Sock, Req),
    Bytes = recv_until_close(Sock, <<>>),
    %% Connection: close means the server closed; gen_tcp:close is a
    %% best-effort cleanup here. Time the FULL lifecycle including
    %% the local close.
    _ = gen_tcp:close(Sock),
    T1 = erlang:monotonic_time(microsecond),
    case Bytes of
        <<"HTTP/1.1 200", _/binary>> ->
            run_loop(Port, Req, N - 1, [T1 - T0 | Acc]);
        Other ->
            io:format("error: bad response: ~p~n", [Other]),
            halt(1)
    end.

%% Server sets Content-Length and Connection: close — read until EOF.
recv_until_close(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Data} ->
            recv_until_close(Sock, <<Acc/binary, Data/binary>>);
        {error, closed} ->
            Acc;
        {error, Other} ->
            io:format("error: recv: ~p~n", [Other]),
            halt(1)
    end.

print_summary(#{server := Server, mode := Mode, reqs := N}, Latencies) ->
    Sorted = lists:sort(Latencies),
    Min = hd(Sorted),
    Max = lists:last(Sorted),
    P50 = lists:nth(max(1, round(0.5 * N)), Sorted),
    P95 = lists:nth(max(1, round(0.95 * N)), Sorted),
    P99 = lists:nth(max(1, round(0.99 * N)), Sorted),
    Mean = lists:sum(Latencies) div N,
    io:format(
        "~nconn_storm probe — server=~p mode=~p, ~p sequential reqs (after warmup)~n",
        [Server, Mode, N]
    ),
    io:format(
        "  min: ~10s  mean: ~10s  p50: ~10s  p95: ~10s  p99: ~10s  max: ~10s~n",
        [
            fmt_us(Min), fmt_us(Mean), fmt_us(P50),
            fmt_us(P95), fmt_us(P99), fmt_us(Max)
        ]
    ),
    %% Throughput, computed as 1/p50 — "if every request took p50,
    %% how many per second could one sequential client drive."
    %% Comparison anchor for the bench's concurrent connection_storm.
    Throughput = 1000000 div max(1, P50),
    io:format("  ~p req/s (1 / p50)~n", [Throughput]).

fmt_us(N) when N < 1000 -> io_lib:format("~B us", [N]);
fmt_us(N) when N < 1000000 -> io_lib:format("~.1f ms", [N / 1000]);
fmt_us(N) -> io_lib:format("~.2f s", [N / 1000000]).
