#!/usr/bin/env escript
%%% Side-by-side throughput bench: roadrunner vs cowboy vs elli.
%%%
%%% Spawns each server in its OWN peer BEAM (stdio-connected, no
%%% epmd) so the loadgen running in this escript's BEAM doesn't share
%%% schedulers with the server. All three servers respond identically:
%%% 200 OK / text/plain / "alive\r\n" / keep-alive engaged for the
%%% `hello` scenario, or POST /echo with 256-byte body echoed for the
%%% `echo` scenario.
%%%
%%% Honest comparison conditions:
%%%   - Same handler shape (no per-server bonus telemetry, gzip, etc).
%%%   - Same peer BEAM startup (inherited code path).
%%%   - Same loadgen worker pool, same client count, same duration.
%%%   - Servers run sequentially (one at a time) so they don't compete
%%%     for cores during their measured phase.
%%%
%%% First-run: `mise exec -- rebar3 as test compile` once so the
%%% non-roadrunner deps (cowboy, elli) and the bench fixtures land in
%%% `_build/test/lib/`. After that the escript inherits the parent's
%%% code path automatically.
%%%
%%% Usage:
%%%   ./scripts/bench.escript [opts]
%%%   ./scripts/bench.escript --help
%%%
%%% Output: a side-by-side table with throughput, mean / p50 / p95 / p99
%%% latency, errors per side, and a delta column showing roadrunner's
%%% relative position. Numbers are noisy (~15% run-to-run variance on a
%%% loaded dev box) — for honest comparison run twice and pick the
%%% median. Single runs only mean something if the gap is bigger than
%%% the variance.

-mode(compile).

-define(DEFAULT_SCENARIO, hello).
-define(DEFAULT_CLIENTS, 50).
-define(DEFAULT_DURATION_S, 5).
-define(DEFAULT_WARMUP_S, 1).
-define(DEFAULT_HOST, "127.0.0.1").
-define(ECHO_BODY_SIZE, 256).

main(Args) ->
    Opts = parse_args(Args),
    ProjectDir = project_dir(),
    ok = setup_code_paths(ProjectDir),
    print_header(Opts),
    %% Each side runs in isolation: bring the server up, drive load,
    %% bring it down, then do the next.
    {_RrRows, RrLast} = run_side(roadrunner, Opts),
    {_CowboyRows, CowboyLast} = run_side(cowboy, Opts),
    {_ElliRows, ElliLast} = run_side(elli, Opts),
    print_summary([
        {roadrunner, RrLast},
        {cowboy, CowboyLast},
        {elli, ElliLast}
    ]).

%% ===========================================================================
%% Args
%% ===========================================================================

cli() ->
    #{
        help =>
            "roadrunner vs cowboy vs elli throughput bench.\n\n"
            "Spawns each server in its own peer BEAM, runs the same load "
            "against\neach, and prints a side-by-side comparison.",
        arguments => [
            #{
                name => scenario,
                long => "-scenario",
                type => {atom, [hello, echo]},
                default => ?DEFAULT_SCENARIO,
                help =>
                    "hello: GET / with 1 header, 7-byte body. Bare-minimum HTTP cost.\n"
                    "echo:  POST /echo with 256-byte body and 5 request headers.\n"
                    "       Both servers are configured with a router so the\n"
                    "       bench exercises body read + multi-header parsing +\n"
                    "       dispatch."
            },
            #{
                name => clients,
                long => "-clients",
                type => {integer, [{min, 1}]},
                default => ?DEFAULT_CLIENTS,
                help => "Number of concurrent loadgen workers."
            },
            #{
                name => duration_s,
                long => "-duration",
                type => {integer, [{min, 1}]},
                default => ?DEFAULT_DURATION_S,
                help => "Seconds of measured load per side."
            },
            #{
                name => warmup_s,
                long => "-warmup",
                type => {integer, [{min, 0}]},
                default => ?DEFAULT_WARMUP_S,
                help => "Seconds of warmup traffic per side, discarded from the report."
            },
            #{
                name => host,
                long => "-host",
                type => string,
                default => ?DEFAULT_HOST,
                help => "Loopback host the loadgen targets."
            }
        ]
    }.

parse_args(Argv) ->
    Cli = cli(),
    ProgOpts = #{progname => "bench_vs_cowboy.escript"},
    case argparse:parse(Argv, Cli, ProgOpts) of
        {ok, Parsed, _Path, _Cmd} ->
            Parsed;
        {error, Reason} ->
            io:format(standard_error, "~s~n~n", [argparse:format_error(Reason)]),
            io:format(standard_error, "~s~n", [argparse:help(Cli, ProgOpts)]),
            halt(2)
    end.

%% ===========================================================================
%% Per-side runner — spawn peer, bring server up, run loadgen, tear down.
%% ===========================================================================

run_side(Side, Opts) ->
    io:format("~n~s~n", [Side]),
    {Peer, Port} = start_server(Side, maps:get(scenario, Opts)),
    try
        run_warmup(Port, Opts),
        Result = run_measured(Port, Opts),
        Row = result_to_row(Side, Result),
        io:format("  ~s~n", [fmt_row(Row)]),
        {[Row], Result}
    after
        peer:stop(Peer)
    end.

start_server(roadrunner, Scenario) ->
    {ok, Peer, _Node} = peer:start_link(#{
        name => peer:random_name(),
        connection => standard_io,
        args => pa_args_for_peer(),
        wait_boot => 10000
    }),
    {ok, _} = peer:call(Peer, application, ensure_all_started, [roadrunner]),
    BaseOpts = #{
        port => 0,
        keep_alive_timeout => 60000,
        max_clients => 100000,
        max_keep_alive_request => 1000000
    },
    ListenerOpts = scenario_roadrunner_opts(Scenario, BaseOpts),
    {ok, _} = peer:call(Peer, roadrunner, start_listener, [bench_rr, ListenerOpts]),
    Port = peer:call(Peer, roadrunner_listener, port, [bench_rr]),
    {Peer, Port};
start_server(cowboy, Scenario) ->
    {ok, Peer, _Node} = peer:start_link(#{
        name => peer:random_name(),
        connection => standard_io,
        args => pa_args_for_peer(),
        wait_boot => 10000
    }),
    {ok, _} = peer:call(Peer, application, ensure_all_started, [cowboy]),
    Dispatch = peer:call(Peer, cowboy_router, compile, [scenario_cowboy_routes(Scenario)]),
    %% `max_keepalive` capped to a million so cowboy's per-conn request
    %% counter doesn't trip during the bench (mirrors roadrunner's
    %% `max_keep_alive_request` setting). Cowboy 2.x's TransportOpts is
    %% a `ranch:opts()` map — passing a flat list interprets every tuple
    %% as a `socket_opt` and `num_acceptors` ends up at `inet_tcp:listen`
    %% which crashes with `badarg`.
    {ok, _} = peer:call(Peer, cowboy, start_clear, [
        bench_cb,
        #{num_acceptors => 10, socket_opts => [{port, 0}]},
        #{env => #{dispatch => Dispatch}, max_keepalive => 1000000}
    ]),
    Port = peer:call(Peer, ranch, get_port, [bench_cb]),
    {Peer, Port};
start_server(elli, _Scenario) ->
    {ok, Peer, _Node} = peer:start_link(#{
        name => peer:random_name(),
        connection => standard_io,
        args => pa_args_for_peer(),
        wait_boot => 10000
    }),
    {ok, _} = peer:call(Peer, application, ensure_all_started, [elli]),
    %% Elli routes via callback pattern-matching, so the same callback
    %% module serves both scenarios. The handler chooses based on
    %% method+path. `min_acceptors` matches cowboy/roadrunner's
    %% 10-acceptor pool.
    %% Elli doesn't expose `get_port/1` and inspecting the gen_server
    %% state across the stdio-peer boundary is awkward (remote pid
    %% representation isn't shared). Easiest robust approach: pick a
    %% free port locally by binding+closing a probe socket, then
    %% point elli at it. There's a tiny race (another process could
    %% grab the port between probe and elli's listen), but for a
    %% bench harness on a quiet machine that's fine.
    %% Run elli's start AND port discovery inside the peer in one
    %% `peer:call` so we never need to ship pids back across the
    %% stdio boundary. The launcher (a regular .erl module under
    %% test/) spawns the gen_server, reads its state, and returns
    %% the bound port — all from inside the peer's BEAM.
    case peer:call(Peer, roadrunner_bench_elli_launcher, start, [
        roadrunner_bench_elli_handler
    ]) of
        {ok, Port} ->
            {Peer, Port};
        {error, Reason} ->
            io:format("error: elli failed to launch: ~p~n", [Reason]),
            peer:stop(Peer),
            halt(1)
    end.

%% Per-scenario server config — same routes/handlers in shape across
%% all three servers so the comparison stays apples-to-apples.
scenario_roadrunner_opts(hello, BaseOpts) ->
    BaseOpts#{handler => roadrunner_keepalive_handler};
scenario_roadrunner_opts(echo, BaseOpts) ->
    BaseOpts#{routes => [{~"/echo", roadrunner_bench_echo_handler, undefined}]}.

scenario_cowboy_routes(hello) ->
    [{'_', [{"/", roadrunner_bench_cowboy_handler, []}]}];
scenario_cowboy_routes(echo) ->
    [{'_', [{"/echo", roadrunner_bench_cowboy_echo_handler, []}]}].

%% Inherit the parent's code path so the peer sees both default- and
%% test-profile artifacts (cowboy lives under test).
pa_args_for_peer() ->
    Paths = [P || P <- code:get_path(), filelib:is_dir(P)],
    lists:foldr(fun(P, Acc) -> ["-pa", P | Acc] end, [], Paths).

%% ===========================================================================
%% Loadgen — closed-loop keep-alive workers (mirrors stress.escript).
%% ===========================================================================

run_warmup(_Port, #{warmup_s := 0}) ->
    ok;
run_warmup(Port, #{warmup_s := W} = Opts) ->
    _ = run_phase(Port, Opts, W * 1000),
    ok.

run_measured(Port, #{duration_s := D} = Opts) ->
    run_phase(Port, Opts, D * 1000).

run_phase(Port, #{clients := C, host := Host, scenario := Scenario}, DurationMs) ->
    Deadline = erlang:monotonic_time(millisecond) + DurationMs,
    Req = build_request(Scenario),
    BodyLen = expected_body_len(Scenario),
    Self = self(),
    StartUs = erlang:monotonic_time(microsecond),
    Workers = [
        spawn_link(fun() ->
            Self ! {self(), worker_loop(Host, Port, Req, BodyLen, Deadline, init_acc())}
        end)
     || _ <- lists:seq(1, C)
    ],
    PerWorker = [collect(W, DurationMs + 30000) || W <- Workers],
    EndUs = erlang:monotonic_time(microsecond),
    aggregate(PerWorker, EndUs - StartUs).

%% Pre-built per-iteration request bytes so the worker hot loop doesn't
%% allocate. Both scenarios assume the same handler returns
%% `Content-Length: <BodyLen>` so the recv side can stop deterministically.
build_request(hello) ->
    ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n";
build_request(echo) ->
    Body = binary:copy(~"x", ?ECHO_BODY_SIZE),
    BodyLenBin = integer_to_binary(?ECHO_BODY_SIZE),
    <<"POST /echo HTTP/1.1\r\n",
        "Host: x\r\n",
        "User-Agent: roadrunner-bench/1.0\r\n",
        "Accept: */*\r\n",
        "Content-Type: application/octet-stream\r\n",
        "Content-Length: ",
        BodyLenBin/binary,
        "\r\n\r\n",
        Body/binary>>.

%% Body byte count the recv loop should wait for before claiming the
%% response is complete.
expected_body_len(hello) -> 7;
expected_body_len(echo) -> ?ECHO_BODY_SIZE.

collect(Pid, TimeoutMs) ->
    receive
        {Pid, R} -> R
    after TimeoutMs ->
        io:format("error: worker ~p timed out~n", [Pid]),
        halt(1)
    end.

init_acc() ->
    #{ok => 0, err => 0, bytes_in => 0, latencies_ns => []}.

worker_loop(Host, Port, Req, BodyLen, Deadline, Acc) ->
    case gen_tcp:connect(Host, Port, [binary, {active, false}], 5000) of
        {ok, Sock} ->
            Final = keep_alive_loop(Sock, Req, BodyLen, Deadline, Acc),
            ok = gen_tcp:close(Sock),
            Final;
        {error, _} ->
            bump_err(Acc)
    end.

keep_alive_loop(Sock, Req, BodyLen, Deadline, Acc) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true ->
            Acc;
        false ->
            T0 = erlang:monotonic_time(nanosecond),
            case gen_tcp:send(Sock, Req) of
                ok ->
                    case recv_response(Sock, <<>>, BodyLen, 5000) of
                        {ok, Bytes} ->
                            T1 = erlang:monotonic_time(nanosecond),
                            keep_alive_loop(
                                Sock, Req, BodyLen, Deadline, bump_ok(Acc, T1 - T0, Bytes)
                            );
                        {error, _} ->
                            bump_err(Acc)
                    end;
                {error, _} ->
                    bump_err(Acc)
            end
    end.

%% Read until we have status line + headers + the expected body-byte
%% count. Both scenarios assume the response carries an accurate
%% `Content-Length` so we know when the body's complete.
recv_response(Sock, Buf, BodyLen, Timeout) ->
    case binary:split(Buf, ~"\r\n\r\n") of
        [_Headers, Body] when byte_size(Body) >= BodyLen ->
            case Buf of
                <<"HTTP/1.1 200", _/binary>> -> {ok, byte_size(Buf)};
                _ -> {error, bad_status}
            end;
        _ ->
            case gen_tcp:recv(Sock, 0, Timeout) of
                {ok, D} -> recv_response(Sock, <<Buf/binary, D/binary>>, BodyLen, Timeout);
                {error, _} = E -> E
            end
    end.

bump_ok(#{ok := O, bytes_in := In, latencies_ns := L} = Acc, Ns, Bytes) ->
    Acc#{ok := O + 1, bytes_in := In + Bytes, latencies_ns := [Ns | L]}.

bump_err(#{err := E} = Acc) ->
    Acc#{err := E + 1}.

aggregate(PerWorker, ElapsedUs) ->
    Init = #{
        total => 0,
        errors => 0,
        bytes_in => 0,
        latencies_ns => [],
        elapsed_us => ElapsedUs
    },
    lists:foldl(
        fun(W, Acc) ->
            #{ok := Ok, err := Err, bytes_in := In, latencies_ns := L} = W,
            #{
                total := T,
                errors := E,
                bytes_in := In0,
                latencies_ns := L0
            } = Acc,
            Acc#{
                total := T + Ok,
                errors := E + Err,
                bytes_in := In0 + In,
                latencies_ns := L ++ L0
            }
        end,
        Init,
        PerWorker
    ).

%% ===========================================================================
%% Reporting
%% ===========================================================================

print_header(#{scenario := S, clients := C, duration_s := D, warmup_s := W, host := H}) ->
    io:format("~nroadrunner vs cowboy vs elli~n"),
    io:format(
        "  scenario : ~s~n"
        "  clients  : ~B~n"
        "  warmup   : ~Bs~n"
        "  duration : ~Bs~n"
        "  host     : ~s~n",
        [S, C, W, D, H]
    ),
    io:format("  request  : ~s~n", [scenario_request_summary(S)]).

scenario_request_summary(hello) ->
    "GET / HTTP/1.1, 1 header, 7-byte response body";
scenario_request_summary(echo) ->
    "POST /echo HTTP/1.1, 5 headers, 256-byte body, server echoes (router)".

result_to_row(Side, #{
    total := Total,
    errors := Errors,
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
    Mean =
        case N of
            0 -> 0;
            _ -> lists:sum(Sorted) div N
        end,
    #{
        side => Side,
        rps => Rps,
        total => Total,
        errors => Errors,
        mean => Mean,
        p50 => pct(Sorted, N, 0.50),
        p95 => pct(Sorted, N, 0.95),
        p99 => pct(Sorted, N, 0.99)
    }.

pct([], _N, _Q) -> 0;
pct(Sorted, N, Q) ->
    Idx = max(1, min(N, round(Q * N))),
    lists:nth(Idx, Sorted).

fmt_row(#{
    side := Side,
    rps := Rps,
    total := Total,
    errors := Err,
    mean := Mean,
    p50 := P50,
    p95 := P95,
    p99 := P99
}) ->
    io_lib:format(
        "~-12s  ~10s req/s  total=~s err=~B  mean=~s p50=~s p95=~s p99=~s",
        [
            atom_to_list(Side),
            fmt_int(round(Rps)),
            fmt_int(Total),
            Err,
            fmt_ns(Mean),
            fmt_ns(P50),
            fmt_ns(P95),
            fmt_ns(P99)
        ]
    ).

print_summary(SidesAndResults) ->
    Rows = [{Side, result_to_row(Side, R)} || {Side, R} <- SidesAndResults],
    Sorted = lists:sort(
        fun({_, A}, {_, B}) -> maps:get(rps, A) >= maps:get(rps, B) end,
        Rows
    ),
    io:format("~nsummary (sorted by throughput, fastest first)~n"),
    io:format("~-12s  ~10s req/s   ~10s p50   ~10s p99~n", ["server", "", "", ""]),
    io:format("~s~n", [string:copies("-", 65)]),
    lists:foreach(
        fun({Side, Row}) ->
            io:format(
                "~-12s  ~10s req/s   ~10s p50   ~10s p99~n",
                [
                    atom_to_list(Side),
                    fmt_int(round(maps:get(rps, Row))),
                    fmt_ns(maps:get(p50, Row)),
                    fmt_ns(maps:get(p99, Row))
                ]
            )
        end,
        Sorted
    ),
    io:format(
        "~n  NOTE: throughput deltas under ~~15% are inside run-to-run~n"
        "        variance — re-run several times before drawing conclusions.~n"
        "        Latency deltas (p50/p99) tend to be more stable.~n",
        []
    ).

%% ===========================================================================
%% Format helpers
%% ===========================================================================

fmt_int(N) when is_integer(N) -> fmt_int_str(integer_to_list(N)).
fmt_int_str(Str) when length(Str) =< 3 ->
    Str;
fmt_int_str(Str) ->
    {Head, Tail} = lists:split(length(Str) - 3, Str),
    fmt_int_str(Head) ++ "," ++ Tail.

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
