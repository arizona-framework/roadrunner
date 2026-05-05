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
%%% Two protocols are supported, both via the same pure-Erlang
%%% `roadrunner_bench_client` worker pool:
%%%   --protocol h1 (default): plain TCP, one keep-alive connection
%%%       per worker.
%%%   --protocol h2: TLS + ALPN h2, one keep-alive connection per
%%%       worker, in-tree codec via `roadrunner_http2_frame` +
%%%       `roadrunner_http2_hpack`. elli is filtered automatically
%%%       — no h2 support there.
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
-define(LARGE_BODY_SIZE, 65536).

%% Servers known to the bench, in default-run order. Adding a new
%% server is two steps: append it here and add a clause for it in
%% `start_server/2` (plus any `scenario_*` config helpers below).
-define(KNOWN_SERVERS, [roadrunner, cowboy, elli]).

main(Args) ->
    Opts0 = parse_args(Args),
    ProjectDir = project_dir(),
    ok = setup_code_paths(ProjectDir),
    Opts = preflight_protocol(Opts0),
    print_header(Opts),
    %% Each side runs in isolation: bring the server up, drive load,
    %% bring it down, then do the next. Order matches the user's
    %% --servers list (default: all known servers).
    Servers = maps:get(servers, Opts),
    Results = [{S, element(2, run_side(S, Opts))} || S <- Servers],
    print_summary(Results).

%% Validate environment for the chosen protocol and drop
%% incompatible servers. The h2 path needs a TLS cert (auto-
%% generated) and elli filtered out (no h2 support).
%%
%% h2 loadgen is `roadrunner_bench_client` — the same in-tree
%% client the eunit suite covers — so we don't take an external
%% dep, and the latency model matches the h1 path (per-request
%% nanosecond timing → real p50/p95/p99). The earlier 40 ms-per-
%% request artifact that pushed us toward h2load was a server-side
%% Nagle interaction; that's now fixed at the listener layer
%% (`roadrunner_listener:base_listen_opts/0`).
preflight_protocol(#{protocol := h1} = Opts) ->
    Opts;
preflight_protocol(#{protocol := h2, servers := Servers} = Opts) ->
    CertDir = generate_test_cert(),
    Filtered = [S || S <- Servers, S =/= elli],
    case Filtered =/= Servers of
        true ->
            io:format(
                "note: --protocol h2 — elli filtered out (no HTTP/2 support)~n",
                []
            );
        false ->
            ok
    end,
    {ok, _} = application:ensure_all_started(ssl),
    Opts#{servers => Filtered, cert_dir => CertDir}.

generate_test_cert() ->
    Dir = string:trim(os:cmd("mktemp -d")),
    Cmd = lists:flatten(io_lib:format(
        "openssl req -x509 -newkey rsa:2048 -nodes -days 1 "
        "-keyout ~s/key.pem -out ~s/cert.pem -subj /CN=localhost "
        "2>/dev/null",
        [Dir, Dir]
    )),
    [] = os:cmd(Cmd),
    case
        filelib:is_regular(Dir ++ "/cert.pem") andalso
            filelib:is_regular(Dir ++ "/key.pem")
    of
        true ->
            Dir;
        false ->
            io:format(standard_error, "error: openssl failed to generate test cert~n", []),
            halt(2)
    end.

%% ===========================================================================
%% Args
%% ===========================================================================

cli() ->
    #{
        help =>
            """
            roadrunner vs cowboy vs elli throughput bench.

            Spawns each server in its own peer BEAM, runs the same load against
            each, and prints a side-by-side comparison.
            """,
        arguments => [
            #{
                name => scenario,
                long => "-scenario",
                type =>
                    {atom, [
                        hello,
                        echo,
                        large_response,
                        json,
                        headers_heavy,
                        streaming_response
                    ]},
                default => ?DEFAULT_SCENARIO,
                help =>
                    """
                    hello:          GET / with 1 header, 7-byte body. Bare-minimum
                                    HTTP cost.
                    echo:           POST /echo with 256-byte body and 5 request
                                    headers. Exercises body read + multi-header
                                    parsing + dispatch.
                    large_response: GET /large with a 64 KB response body.
                                    Exercises Content-Length encoding cost and
                                    kernel-side send batching for big writes.
                    json:           GET /json returning a ~120-byte
                                    application/json body. Realistic single-
                                    item REST shape.
                    headers_heavy:  GET / with 16 extra request headers.
                                    Stresses the request-header parser
                                    (h1) / HPACK encoder + literal-with-
                                    incremental-indexing path (h2).
                    streaming_response:
                                    GET /streaming returns 4 × 4 KB
                                    chunks via the framework's stream-
                                    body API. Exercises the streaming
                                    worker path + per-chunk fragmentation.
                    """
            },
            #{
                name => servers,
                long => "-servers",
                type => string,
                default => "roadrunner,cowboy,elli",
                help =>
                    """
                    Comma-separated list of servers to run (run order is
                    preserved). Known: roadrunner, cowboy, elli. Use to
                    compare a subset (e.g. `--servers roadrunner,elli`)
                    or to drive load against a single server in
                    isolation (`--servers roadrunner`).
                    """
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
            },
            #{
                name => profile,
                long => "-profile",
                type => boolean,
                default => false,
                help =>
                    """
                    Arm `eprof` inside each server's peer BEAM before driving
                    load, then dump the hotspot table after the measured
                    phase. Useful with `--servers <name>` to profile a
                    single server in isolation. Throughput numbers under
                    --profile are NOT comparable to a normal run; use it
                    only to identify MFAs worth optimizing.
                    """
            },
            #{
                name => profile_min_ms,
                long => "-profile-min-ms",
                type => float,
                default => 1.0,
                help => "Minimum total ms for a row to appear in the hotspot table."
            },
            #{
                name => protocol,
                long => "-protocol",
                type => {atom, [h1, h2]},
                default => h1,
                help =>
                    """
                    Wire protocol to drive the load over. Both paths
                    use the in-tree pure-Erlang `roadrunner_bench_client`
                    — no external loadgen tool required.
                      h1: plain TCP, one keep-alive connection per worker.
                      h2: TLS + ALPN h2. elli is filtered automatically
                          (no h2 support); only roadrunner + cowboy run.
                    """
            }
        ]
    }.

parse_args(Argv) ->
    Cli = cli(),
    ProgOpts = #{progname => "bench.escript"},
    case argparse:parse(Argv, Cli, ProgOpts) of
        {ok, Parsed, _Path, _Cmd} ->
            Parsed#{servers => parse_servers(maps:get(servers, Parsed))};
        {error, Reason} ->
            io:format(standard_error, "~s~n~n", [argparse:format_error(Reason)]),
            io:format(standard_error, "~s~n", [argparse:help(Cli, ProgOpts)]),
            halt(2)
    end.

%% Parse `--servers` (comma-separated) into a list of atoms, validating
%% each against `?KNOWN_SERVERS`. Preserves the user's order so the
%% bench runs in the order they typed (e.g. `--servers elli,roadrunner`
%% runs elli first).
parse_servers(Str) ->
    Names = [string:trim(P) || P <- string:split(Str, ",", all), P =/= ""],
    %% `list_to_existing_atom` blows up on names that aren't already
    %% atoms — convert via the safe membership check instead so a
    %% typo produces a clean error message, not a crash.
    Known = ?KNOWN_SERVERS,
    KnownStrs = [atom_to_list(A) || A <- Known],
    Lookup = lists:zip(KnownStrs, Known),
    {Resolved, Unknown} = lists:foldr(
        fun(N, {Ok, Bad}) ->
            case lists:keyfind(N, 1, Lookup) of
                {_, Atom} -> {[Atom | Ok], Bad};
                false -> {Ok, [N | Bad]}
            end
        end,
        {[], []},
        Names
    ),
    case Unknown of
        [] ->
            Resolved;
        _ ->
            io:format(
                standard_error,
                "error: unknown servers: ~p (known: ~p)~n",
                [Unknown, Known]
            ),
            halt(2)
    end.

%% ===========================================================================
%% Per-side runner — spawn peer, bring server up, run loadgen, tear down.
%% ===========================================================================

run_side(Side, Opts) ->
    io:format("~n~s~n", [Side]),
    {Peer, Port} = start_server(Side, Opts),
    try
        run_warmup(Port, Opts),
        ok = maybe_start_profile(Peer, Opts),
        Result = run_measured(Port, Opts),
        ok = maybe_stop_profile(Peer, Side, Opts),
        Row = result_to_row(Side, Result),
        io:format("  ~s~n", [fmt_row(Row)]),
        {[Row], Result}
    after
        peer:stop(Peer)
    end.

maybe_start_profile(_Peer, #{profile := false}) ->
    ok;
maybe_start_profile(Peer, #{profile := true}) ->
    ok = peer:call(Peer, roadrunner_bench_profiler, start, []).

maybe_stop_profile(_Peer, _Side, #{profile := false}) ->
    ok;
maybe_stop_profile(Peer, Side, #{profile := true, profile_min_ms := MinMs}) ->
    Path = filename:join(["/tmp", "roadrunner_bench_eprof_" ++ atom_to_list(Side) ++ ".log"]),
    ok = peer:call(Peer, roadrunner_bench_profiler, stop_and_dump, [Path, MinMs]),
    %% Read the log written inside the peer's BEAM and print to the
    %% bench's own stdout. Files are visible to both because they
    %% share the host filesystem.
    io:format("~nprofile (eprof, ~s, total time, rows >= ~.2f ms)~n", [Side, MinMs]),
    case file:read_file(Path) of
        {ok, Bin} -> io:put_chars(Bin), io:nl();
        {error, Reason} -> io:format("  could not read ~s: ~p~n", [Path, Reason])
    end,
    ok.

start_server(roadrunner, #{protocol := h1, scenario := Scenario}) ->
    start_roadrunner(Scenario);
start_server(roadrunner, #{protocol := h2, scenario := Scenario, cert_dir := CertDir}) ->
    start_roadrunner_h2(Scenario, CertDir);
start_server(cowboy, #{protocol := h1, scenario := Scenario}) ->
    start_cowboy_h1(Scenario);
start_server(cowboy, #{protocol := h2, scenario := Scenario, cert_dir := CertDir}) ->
    start_cowboy_h2(Scenario, CertDir);
start_server(elli, #{scenario := Scenario}) ->
    start_elli(Scenario).

start_cowboy_h1(Scenario) ->
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
    TransportOpts = #{num_acceptors => 10, socket_opts => [{port, 0}]},
    ProtoOpts = #{env => #{dispatch => Dispatch}, max_keepalive => 1000000},
    {ok, _} = peer:call(Peer, cowboy, start_clear, [bench_cb, TransportOpts, ProtoOpts]),
    Port = peer:call(Peer, ranch, get_port, [bench_cb]),
    print_listener_config([
        {"transport_opts", TransportOpts},
        {"protocol_opts", ProtoOpts},
        {"routes", scenario_cowboy_routes(Scenario)}
    ]),
    {Peer, Port}.

start_elli(_Scenario) ->
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
            print_listener_config([
                {"callback", roadrunner_bench_elli_handler},
                {"min_acceptors", 10}
            ]),
            {Peer, Port};
        {error, Reason} ->
            io:format("error: elli failed to launch: ~p~n", [Reason]),
            peer:stop(Peer),
            halt(1)
    end.

start_roadrunner(Scenario) ->
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
    print_listener_config([{"listener_opts", ListenerOpts}]),
    {Peer, Port}.

start_roadrunner_h2(Scenario, CertDir) ->
    {ok, Peer, _Node} = peer:start_link(#{
        name => peer:random_name(),
        connection => standard_io,
        args => pa_args_for_peer(),
        wait_boot => 10000
    }),
    {ok, _} = peer:call(Peer, application, ensure_all_started, [ssl]),
    {ok, _} = peer:call(Peer, application, ensure_all_started, [roadrunner]),
    BaseOpts = #{
        port => 0,
        tls => [
            {certfile, CertDir ++ "/cert.pem"},
            {keyfile, CertDir ++ "/key.pem"}
        ],
        http2_enabled => true,
        keep_alive_timeout => 60000,
        max_clients => 100000,
        max_keep_alive_request => 1000000
    },
    ListenerOpts = scenario_roadrunner_opts(Scenario, BaseOpts),
    {ok, _} = peer:call(Peer, roadrunner, start_listener, [bench_rr_h2, ListenerOpts]),
    Port = peer:call(Peer, roadrunner_listener, port, [bench_rr_h2]),
    print_listener_config([{"listener_opts", ListenerOpts}]),
    {Peer, Port}.

start_cowboy_h2(Scenario, CertDir) ->
    {ok, Peer, _Node} = peer:start_link(#{
        name => peer:random_name(),
        connection => standard_io,
        args => pa_args_for_peer(),
        wait_boot => 10000
    }),
    {ok, _} = peer:call(Peer, application, ensure_all_started, [ssl]),
    {ok, _} = peer:call(Peer, application, ensure_all_started, [cowboy]),
    Dispatch = peer:call(Peer, cowboy_router, compile, [scenario_cowboy_routes(Scenario)]),
    %% cowboy_tls advertises `h2` + `http/1.1` via ALPN by default.
    TransportOpts = #{
        num_acceptors => 10,
        socket_opts => [
            {port, 0},
            {certfile, CertDir ++ "/cert.pem"},
            {keyfile, CertDir ++ "/key.pem"}
        ]
    },
    ProtoOpts = #{env => #{dispatch => Dispatch}, max_keepalive => 1000000},
    {ok, _} = peer:call(Peer, cowboy, start_tls, [bench_cb_h2, TransportOpts, ProtoOpts]),
    Port = peer:call(Peer, ranch, get_port, [bench_cb_h2]),
    print_listener_config([
        {"transport_opts", TransportOpts},
        {"protocol_opts", ProtoOpts},
        {"routes", scenario_cowboy_routes(Scenario)}
    ]),
    {Peer, Port}.

%% Print the per-server listener configuration, indented under the
%% side header. `~tp` prints with the printable-charlist heuristic
%% on, so binaries-of-printable-bytes appear as text rather than
%% byte lists. Wraps onto multiple lines for big maps.
print_listener_config(Pairs) ->
    [io:format("  ~-13s: ~tp~n", [Label, Value]) || {Label, Value} <- Pairs],
    ok.

%% Per-scenario server config — same routes/handlers in shape across
%% all three servers so the comparison stays apples-to-apples.
scenario_roadrunner_opts(hello, BaseOpts) ->
    BaseOpts#{handler => roadrunner_keepalive_handler};
scenario_roadrunner_opts(headers_heavy, BaseOpts) ->
    %% Same handler as `hello` — the difference is request-side
    %% headers, server work is identical.
    BaseOpts#{handler => roadrunner_keepalive_handler};
scenario_roadrunner_opts(echo, BaseOpts) ->
    BaseOpts#{routes => [{~"/echo", roadrunner_bench_echo_handler, undefined}]};
scenario_roadrunner_opts(large_response, BaseOpts) ->
    BaseOpts#{routes => [{~"/large", roadrunner_bench_large_handler, undefined}]};
scenario_roadrunner_opts(json, BaseOpts) ->
    BaseOpts#{routes => [{~"/json", roadrunner_bench_json_handler, undefined}]};
scenario_roadrunner_opts(streaming_response, BaseOpts) ->
    BaseOpts#{routes => [{~"/streaming", roadrunner_bench_streaming_handler, undefined}]}.

scenario_cowboy_routes(hello) ->
    [{'_', [{"/", roadrunner_bench_cowboy_handler, []}]}];
scenario_cowboy_routes(headers_heavy) ->
    [{'_', [{"/", roadrunner_bench_cowboy_handler, []}]}];
scenario_cowboy_routes(echo) ->
    [{'_', [{"/echo", roadrunner_bench_cowboy_echo_handler, []}]}];
scenario_cowboy_routes(large_response) ->
    [{'_', [{"/large", roadrunner_bench_cowboy_large_handler, []}]}];
scenario_cowboy_routes(json) ->
    [{'_', [{"/json", roadrunner_bench_cowboy_json_handler, []}]}];
scenario_cowboy_routes(streaming_response) ->
    [{'_', [{"/streaming", roadrunner_bench_cowboy_streaming_handler, []}]}].

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

run_phase(Port, #{protocol := h1} = Opts, DurationMs) ->
    run_phase_h1(Port, Opts, DurationMs);
run_phase(Port, #{protocol := h2} = Opts, DurationMs) ->
    run_phase_h2(Port, Opts, DurationMs).

run_phase_h1(Port, #{clients := C, host := Host, scenario := Scenario}, DurationMs) ->
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
        Body/binary>>;
build_request(large_response) ->
    ~"GET /large HTTP/1.1\r\nHost: x\r\n\r\n";
build_request(json) ->
    ~"GET /json HTTP/1.1\r\nHost: x\r\nAccept: application/json\r\n\r\n";
build_request(streaming_response) ->
    %% h1 streaming responses close the connection per request (the
    %% server's chunked-stream emitter returns `close` from the
    %% keep-alive decision), which the bench's keep-alive loop
    %% can't reuse — limit this scenario to h2.
    io:format(standard_error,
        "error: --scenario streaming_response is h2-only "
        "(use --protocol h2)~n", []),
    halt(2);
build_request(headers_heavy) ->
    %% 16 small request headers + the Host. Names are valid h1
    %% tokens (lowercase ASCII); values are short. Same path as
    %% `hello` so the server-side handler cost is identical and the
    %% bench surfaces request-header parsing overhead.
    <<
        "GET / HTTP/1.1\r\n"
        "Host: x\r\n"
        "x-bench-1: 1\r\n"
        "x-bench-2: 22\r\n"
        "x-bench-3: 333\r\n"
        "x-bench-4: 4444\r\n"
        "x-bench-5: 55555\r\n"
        "x-bench-6: 666666\r\n"
        "x-bench-7: 7777777\r\n"
        "x-bench-8: 88888888\r\n"
        "x-bench-9: 999999999\r\n"
        "x-bench-10: aaaaaaaaaa\r\n"
        "x-bench-11: bbbbbbbbbbb\r\n"
        "x-bench-12: cccccccccccc\r\n"
        "x-bench-13: ddddddddddddd\r\n"
        "x-bench-14: eeeeeeeeeeeeee\r\n"
        "x-bench-15: fffffffffffffff\r\n"
        "x-bench-16: gggggggggggggggg\r\n"
        "\r\n"
    >>.

%% Body byte count the recv loop should wait for before claiming the
%% response is complete.
expected_body_len(hello) -> 7;
expected_body_len(echo) -> ?ECHO_BODY_SIZE;
expected_body_len(large_response) -> ?LARGE_BODY_SIZE;
expected_body_len(json) -> 115;
expected_body_len(headers_heavy) -> 7;
expected_body_len(streaming_response) -> 16384.

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
                {ok, Data} -> recv_response(Sock, <<Buf/binary, Data/binary>>, BodyLen, Timeout);
                {error, _} = E -> E
            end
    end.

bump_ok(#{ok := O, bytes_in := In, latencies_ns := L} = Acc, Ns, Bytes) ->
    Acc#{ok := O + 1, bytes_in := In + Bytes, latencies_ns := [Ns | L]}.

bump_err(#{err := E} = Acc) ->
    Acc#{err := E + 1}.

%% ===========================================================================
%% h2 loadgen — pure-Erlang worker pool driving `roadrunner_bench_client`.
%% Same shape as the h1 path: each worker holds one TLS+ALPN-h2
%% connection, loops requests until the deadline, samples per-
%% request nanoseconds. `clients` matches h1's parallel-request
%% count for an apples-to-apples comparison; we don't multiplex
%% N streams per connection so an h2 worker measures protocol
%% framing overhead, not h2 multiplexing benefit.
%% ===========================================================================

run_phase_h2(Port, #{clients := C, host := Host, scenario := Scenario}, DurationMs) ->
    Deadline = erlang:monotonic_time(millisecond) + DurationMs,
    {Method, Path, ReqHeaders, ReqBody} = h2_request_shape(Scenario),
    Self = self(),
    StartUs = erlang:monotonic_time(microsecond),
    Workers = [
        spawn_link(fun() ->
            Self !
                {self(),
                    h2_worker_loop(
                        Host, Port, Method, Path, ReqHeaders, ReqBody, Deadline, init_acc()
                    )}
        end)
     || _ <- lists:seq(1, C)
    ],
    PerWorker = [collect(W, DurationMs + 30000) || W <- Workers],
    EndUs = erlang:monotonic_time(microsecond),
    aggregate(PerWorker, EndUs - StartUs).

h2_request_shape(hello) ->
    {~"GET", ~"/", [], <<>>};
h2_request_shape(echo) ->
    {~"POST", ~"/echo", [{~"content-type", ~"application/octet-stream"}],
        binary:copy(~"x", ?ECHO_BODY_SIZE)};
h2_request_shape(large_response) ->
    {~"GET", ~"/large", [], <<>>};
h2_request_shape(json) ->
    {~"GET", ~"/json", [{~"accept", ~"application/json"}], <<>>};
h2_request_shape(streaming_response) ->
    {~"GET", ~"/streaming", [], <<>>};
h2_request_shape(headers_heavy) ->
    %% 16 small custom headers — exercises HPACK encode's
    %% literal-with-incremental-indexing path. After warmup these
    %% land in the dynamic table and subsequent requests reference
    %% them by index, mirroring real-world h2 client behaviour.
    Hdrs = [
        {<<"x-bench-", (integer_to_binary(N))/binary>>, binary:copy(~"a", N)}
     || N <- lists:seq(1, 16)
    ],
    {~"GET", ~"/", Hdrs, <<>>}.

h2_worker_loop(Host, Port, Method, Path, ReqHeaders, ReqBody, Deadline, Acc) ->
    case roadrunner_bench_client:open(Host, Port, h2) of
        {ok, Conn} ->
            h2_keep_alive_loop(Conn, Method, Path, ReqHeaders, ReqBody, Deadline, Acc);
        {error, _} ->
            bump_err(Acc)
    end.

h2_keep_alive_loop(Conn, Method, Path, ReqHeaders, ReqBody, Deadline, Acc) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true ->
            _ = roadrunner_bench_client:close(Conn),
            Acc;
        false ->
            T0 = erlang:monotonic_time(nanosecond),
            case roadrunner_bench_client:request(Conn, Method, Path, ReqHeaders, ReqBody) of
                {ok, 200, _RespHeaders, RespBody, Conn1} ->
                    T1 = erlang:monotonic_time(nanosecond),
                    h2_keep_alive_loop(
                        Conn1, Method, Path, ReqHeaders, ReqBody, Deadline,
                        bump_ok(Acc, T1 - T0, byte_size(RespBody))
                    );
                _Other ->
                    _ = roadrunner_bench_client:close(Conn),
                    bump_err(Acc)
            end
    end.

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

print_header(#{
    scenario := S,
    servers := Servers,
    clients := C,
    duration_s := D,
    warmup_s := W,
    host := H,
    protocol := P
}) ->
    print_environment(),
    io:format("~nhttp server bench~n"),
    io:format(
        "  protocol : ~s~n"
        "  servers  : ~s~n"
        "  scenario : ~s~n"
        "  clients  : ~B~n"
        "  warmup   : ~Bs~n"
        "  duration : ~Bs~n"
        "  host     : ~s~n",
        [P, string:join([atom_to_list(A) || A <- Servers], ", "), S, C, W, D, H]
    ),
    io:format("  request  : ~s~n", [scenario_request_summary(S)]).

%% Environment block — printed once per run so the user can read the
%% bench output later and know exactly what produced the numbers
%% (OTP/ERTS version + emulator flavor, scheduler count, kernel/arch,
%% rough CPU model + memory). Numbers are NOT comparable across
%% machines; this block makes the per-machine context explicit.
print_environment() ->
    io:format("~nenvironment~n"),
    io:format("  otp        : ~s (erts ~s)~n", [
        erlang:system_info(otp_release), erlang:system_info(version)
    ]),
    io:format("  emulator   : ~s~n", [emulator_flavor()]),
    io:format("  schedulers : ~B online / ~B total~n", [
        erlang:system_info(schedulers_online), erlang:system_info(schedulers)
    ]),
    io:format("  os         : ~s~n", [os_release()]),
    io:format("  cpu        : ~s~n", [cpu_model()]),
    io:format("  memory     : ~s~n", [memory_total()]).

emulator_flavor() ->
    case erlang:system_info(emu_flavor) of
        jit -> "JIT";
        Other -> io_lib:format("~p", [Other])
    end.

os_release() ->
    %% `uname -srm` is portable across Linux/macOS/BSD and gives kernel
    %% name + release + machine in one line.
    string:trim(os:cmd("uname -srm")).

cpu_model() ->
    %% Try `/proc/cpuinfo` first (Linux), then `sysctl` (macOS/BSD).
    %% Falls back to the Erlang-reported architecture if neither
    %% exposes a model name.
    case file:read_file("/proc/cpuinfo") of
        {ok, Cpuinfo} ->
            case re:run(Cpuinfo, ~"model name\\s*:\\s*([^\n]+)", [{capture, [1], binary}]) of
                {match, [Model]} -> binary_to_list(string:trim(Model));
                _ -> erlang:system_info(system_architecture)
            end;
        _ ->
            case string:trim(os:cmd("sysctl -n machdep.cpu.brand_string 2>/dev/null")) of
                "" -> erlang:system_info(system_architecture);
                Brand -> Brand
            end
    end.

memory_total() ->
    case file:read_file("/proc/meminfo") of
        {ok, Meminfo} ->
            case re:run(Meminfo, ~"MemTotal:\\s*(\\d+)\\s*kB", [{capture, [1], binary}]) of
                {match, [KbBin]} ->
                    Kb = binary_to_integer(KbBin),
                    io_lib:format("~.1f GiB total", [Kb / 1024 / 1024]);
                _ ->
                    "unknown"
            end;
        _ ->
            "unknown"
    end.

scenario_request_summary(hello) ->
    "GET / HTTP/1.1, 1 header, 7-byte response body";
scenario_request_summary(echo) ->
    "POST /echo HTTP/1.1, 5 headers, 256-byte body, server echoes (router)";
scenario_request_summary(large_response) ->
    "GET /large HTTP/1.1, 1 header, 64 KB response body (router)";
scenario_request_summary(json) ->
    "GET /json HTTP/1.1, 2 headers, ~115-byte JSON response body (router)";
scenario_request_summary(headers_heavy) ->
    "GET / HTTP/1.1, 17 headers, 7-byte response body (handler)";
scenario_request_summary(streaming_response) ->
    "GET /streaming HTTP/1.1, 1 header, 4 × 4 KB chunks (router)".

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
        "~-16s  ~10s req/s  total=~s err=~B  mean=~s p50=~s p95=~s p99=~s",
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
    io:format("~-16s  ~10s req/s   ~10s p50   ~10s p99~n", ["server", "", "", ""]),
    io:format("~s~n", [string:copies("-", 65)]),
    lists:foreach(
        fun({Side, Row}) ->
            io:format(
                "~-16s  ~10s req/s   ~10s p50   ~10s p99~n",
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
