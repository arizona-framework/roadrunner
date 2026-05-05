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
-define(LARGE_POST_BODY_SIZE, 1048576).

%% Servers known to the bench, in default-run order. Adding a new
%% server is two steps: append it here and add a clause for it in
%% `start_server/2` (plus any `scenario_*` config helpers below).
-define(KNOWN_SERVERS, [roadrunner, cowboy, elli]).

main(Args) ->
    Opts0 = parse_args(Args),
    ProjectDir = project_dir(),
    ok = setup_code_paths(ProjectDir),
    Opts1 = preflight_protocol(Opts0),
    Opts = preflight_scenario(Opts1),
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
preflight_scenario(#{scenario := post_4kb_form, servers := Servers} = Opts) ->
    filter_servers(post_4kb_form, [elli], Servers, Opts,
        ~"no native urlencoded body parser");
preflight_scenario(#{scenario := large_post_streaming, servers := Servers} = Opts) ->
    filter_servers(large_post_streaming, [elli], Servers, Opts,
        ~"auto-buffers full body, no manual-mode read API");
preflight_scenario(#{scenario := varied_paths_router, servers := Servers} = Opts) ->
    filter_servers(varied_paths_router, [elli], Servers, Opts,
        ~"no router; the test fixture only handles /, /echo, /large, /json");
preflight_scenario(#{scenario := gzip_response, servers := Servers} = Opts) ->
    filter_servers(gzip_response, [elli], Servers, Opts,
        ~"no built-in gzip middleware");
preflight_scenario(#{scenario := backpressure_sustained, servers := Servers} = Opts) ->
    filter_servers(backpressure_sustained, [elli], Servers, Opts,
        ~"no max_connections cap; comparison would not be apples-to-apples");
preflight_scenario(#{scenario := server_sent_events, servers := Servers} = Opts) ->
    filter_servers(server_sent_events, [elli], Servers, Opts,
        ~"no equivalent loop handler in our test fixture");
preflight_scenario(#{scenario := expect_100_continue, servers := Servers} = Opts) ->
    filter_servers(expect_100_continue, [elli], Servers, Opts,
        ~"no automatic 100-continue handling in our elli fixture");
preflight_scenario(#{scenario := websocket_msg_throughput, servers := Servers} = Opts) ->
    filter_servers(websocket_msg_throughput, [elli], Servers, Opts,
        ~"no WebSocket support in elli test fixture");
preflight_scenario(#{scenario := url_with_qs, servers := Servers} = Opts) ->
    filter_servers(url_with_qs, [elli], Servers, Opts,
        ~"no native query-string parser in elli test fixture");
preflight_scenario(#{scenario := head_method, servers := Servers} = Opts) ->
    filter_servers(head_method, [elli], Servers, Opts,
        ~"elli test fixture's handle/3 only matches 'GET' for /large; HEAD falls through to 404");
preflight_scenario(#{scenario := etag_304, servers := Servers} = Opts) ->
    filter_servers(etag_304, [elli], Servers, Opts,
        ~"no /etag handler in elli test fixture");
preflight_scenario(Opts) ->
    Opts.

filter_servers(Scenario, Drop, Servers, Opts, Reason) ->
    Filtered = [S || S <- Servers, not lists:member(S, Drop)],
    case Filtered =/= Servers of
        true ->
            io:format(
                "note: --scenario ~p — ~p filtered out (~s)~n",
                [Scenario, Drop, Reason]
            );
        false ->
            ok
    end,
    Opts#{servers => Filtered}.

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
                        streaming_response,
                        multi_stream_h2,
                        pipelined_h1,
                        slow_client,
                        connection_storm,
                        mixed_workload,
                        post_4kb_form,
                        large_post_streaming,
                        router_404_storm,
                        varied_paths_router,
                        gzip_response,
                        backpressure_sustained,
                        server_sent_events,
                        expect_100_continue,
                        large_keepalive_session,
                        websocket_msg_throughput,
                        url_with_qs,
                        small_chunked_response,
                        accept_storm_burst,
                        head_method,
                        etag_304
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
                    multi_stream_h2:
                                    h2-only. Bench client opens ONE TLS
                                    conn and drives 16 multiplexed
                                    streams in flight before reading
                                    any responses. The actual h2
                                    workload — exercises per-stream
                                    workers, conn-level flow control,
                                    and MAX_CONCURRENT_STREAMS dispatch.
                    pipelined_h1:   h1-only. 4 GET / requests sent in
                                    one TCP segment, then 4 responses
                                    drained. Exercises the parser's
                                    "more bytes left in buffer after
                                    one request completes" path
                                    (RFC 7230 §6.3.2 pipelining).
                    slow_client:    h1-only. Request is split into 5
                                    lines and drip-fed one line per
                                    millisecond. Exercises the
                                    parser's incremental-receive
                                    path (multiple `gen_tcp:recv` /
                                    `{tcp, _, Bytes}` cycles per
                                    request) and recv-deadline
                                    accounting.
                    connection_storm:
                                    h1-only. Open conn, do 1 GET /,
                                    close, repeat. Exercises accept
                                    / acceptor-pool dispatch / slot
                                    acquire-release / TCP handshake
                                    + teardown. Real-world target:
                                    health-check probes (k8s, ELB),
                                    short-lived CLI clients, HTTP-
                                    as-RPC patterns.
                    mixed_workload: Per-request random pick from
                                    {hello, json, large_response}
                                    on the same keep-alive conn.
                                    Closer to production traffic
                                    than uniform-path benches —
                                    surfaces router-cache effects
                                    and gives an honest "average
                                    request" number.
                    post_4kb_form:  POST /form with a 4 KB
                                    `application/x-www-form-urlen-
                                    coded` body. Exercises the
                                    form-decode path
                                    (`roadrunner_qs:parse/1` /
                                    cowboy's `read_urlencoded_body`)
                                    + body-read. elli filtered out
                                    (no native urlencoded parser).
                    large_post_streaming:
                                    h1-only. POST /drain with a 1 MB
                                    body, server reads via the
                                    manual-mode read_body API in
                                    64 KB chunks and discards.
                                    Exercises body_state machine +
                                    chunked-recv path + recv-rate
                                    bookkeeping under sustained
                                    inbound load. elli filtered
                                    out (auto-buffers full body).
                    router_404_storm:
                                    h1-only. Fresh conn per request
                                    (Connection: close), GET on a
                                    path no route matches. Tests
                                    the router's NEGATIVE match
                                    path — the trie/list walk that
                                    fails to match — plus 404
                                    response framing. Realistic
                                    for APIs hit by scanners,
                                    broken links, deprecated paths.
                    varied_paths_router:
                                    h1-only. Keep-alive conn cycles
                                    through 100 distinct routed
                                    paths (round-robin per request).
                                    Tests router warmth under
                                    realistic API surface area —
                                    `mixed_workload` hits 3 paths;
                                    this exercises a 100-route
                                    table, more representative of
                                    a real REST API. elli filtered
                                    out (no router).
                    gzip_response:  h1-only. GET /gzip with
                                    Accept-Encoding: gzip; server
                                    returns 16 KB JSON-shaped body
                                    compressed via roadrunner_compress
                                    middleware (cowboy: cowboy_compress_h
                                    stream handler). elli filtered
                                    out (no built-in compression).
                    backpressure_sustained:
                                    h1-only. Listener capped at 50
                                    concurrent slots; bench drives
                                    --clients > cap (default 200)
                                    so 150 conn-attempts fail at
                                    slot-acquire and the surviving
                                    50 do sustained keep-alive
                                    throughput. Cowboy uses ranch
                                    max_connections; elli has no
                                    cap so filtered out for
                                    apples-to-apples.
                    server_sent_events:
                                    h1-only. GET /sse opens a
                                    text/event-stream session; the
                                    server emits 100 small `tick`
                                    events as fast as possible then
                                    closes. One bench iteration =
                                    one SSE session. Tests the
                                    {loop, ...} response path,
                                    handle_info dispatch, and the
                                    drain group (loop handlers are
                                    the one feature pg:join enables).
                                    elli filtered out (different
                                    handler shape).
                    expect_100_continue:
                                    h1-only. POST /echo with
                                    `Expect: 100-continue`. Bench
                                    sends headers only, awaits a
                                    `HTTP/1.1 100 Continue` interim
                                    response, sends the body, then
                                    awaits the final 200. Tests
                                    `roadrunner_conn:maybe_send_continue/3`
                                    + the conn-state machine that
                                    ferries the interim response.
                                    elli filtered out (no
                                    100-continue support in fixture).
                    large_keepalive_session:
                                    h1-only. Listener capped at
                                    max_keep_alive_request => 1000;
                                    bench worker reconnects on conn
                                    close. Measures keep-alive
                                    throughput including the
                                    periodic reconnect tax. Tests
                                    the per-conn-life cycle
                                    completion path that single-
                                    request `connection_storm`
                                    can't reach.
                    websocket_msg_throughput:
                                    h1-only (upgrade to WS). Bench
                                    completes WS handshake then
                                    sends 1 KB masked text frames
                                    in a tight loop, reading the
                                    echoed reply each iteration.
                                    Tests the WebSocket frame-
                                    encode / parse hot path —
                                    distinct from any other
                                    scenario. elli filtered out
                                    (no WS in test fixture).
                    url_with_qs:    h1-only. GET /qs?<6 pairs>;
                                    server parses the URL query
                                    string via roadrunner_qs:parse
                                    (cowboy: cowboy_req:parse_qs).
                                    Distinct from `post_4kb_form`
                                    which exercises the body-side
                                    qs path. elli filtered out
                                    (no native qs parser).
                    small_chunked_response:
                                    h2-only. GET /small returns
                                    100 × 64-byte chunks via
                                    {stream, _, _, Fun}. Tests
                                    fragmentation overhead
                                    (per-chunk DATA frame headers)
                                    on small chunks — distinct
                                    cost shape from
                                    `streaming_response`'s
                                    4 × 4 KB.
                    accept_storm_burst:
                                    h1-only. ALL --clients connect
                                    simultaneously (a single peak
                                    burst), each does 1 GET / +
                                    Connection: close, then exits.
                                    Different from `connection_storm`
                                    which is sustained — this tests
                                    listener backlog + acceptor
                                    pool under peak instantaneous
                                    load. Run with --duration 1
                                    or short; throughput =
                                    clients / time-to-drain.
                    head_method:    HEAD /large — same handler as
                                    `large_response`; the conn-loop
                                    detects HEAD and emits the
                                    headers (incl. Content-Length:
                                    65536) but suppresses the
                                    64 KB body per RFC 9110 §9.3.2.
                                    Tests the body-suppression
                                    short-circuit. Distinct from
                                    GET on the wire.
                    etag_304:       GET /etag with
                                    If-None-Match: "v1". Server
                                    short-circuits with 304 Not
                                    Modified — no body, smallest
                                    possible response. Real path
                                    for CDN / browser cache hits.
                                    Tests conditional-response
                                    semantics + small-response
                                    write path.
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
                name => profile_tool,
                long => "-profile-tool",
                type => {atom, [eprof, fprof]},
                default => eprof,
                help =>
                    """
                    Profiler tool. `eprof` is fast but times out under high
                    request volume (connection_storm, multi_stream_h2,
                    websocket_msg_throughput); `fprof` handles those without
                    blocking but writes a richer call-tree analysis to
                    `/tmp/roadrunner_bench_fprof_<server>.log` which the
                    user reads directly. `--profile` must also be set.
                    """
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
maybe_start_profile(Peer, #{profile := true, profile_tool := fprof}) ->
    Trace = "/tmp/roadrunner_bench_fprof.trace",
    ok = peer:call(Peer, roadrunner_bench_profiler, start_fprof, [Trace]);
maybe_start_profile(Peer, #{profile := true}) ->
    ok = peer:call(Peer, roadrunner_bench_profiler, start, []).

maybe_stop_profile(_Peer, _Side, #{profile := false}) ->
    ok;
maybe_stop_profile(Peer, Side, #{profile := true, profile_tool := fprof}) ->
    Trace = "/tmp/roadrunner_bench_fprof.trace",
    Analysis =
        filename:join(["/tmp", "roadrunner_bench_fprof_" ++ atom_to_list(Side) ++ ".log"]),
    %% fprof's profile + analyse steps walk the trace file twice and
    %% can take 30+ seconds on a 100k-event trace; bump peer:call's
    %% default 5 s timeout.
    ok = peer:call(
        Peer, roadrunner_bench_profiler, stop_fprof_and_dump, [Trace, Analysis], 120000
    ),
    io:format("~nprofile (fprof, ~s) written to ~s~n", [Side, Analysis]);
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
    TransportOpts = scenario_cowboy_transport_opts(Scenario),
    ProtoOpts = scenario_cowboy_proto_opts(Scenario, Dispatch),
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
    BaseOpts#{routes => [{~"/streaming", roadrunner_bench_streaming_handler, undefined}]};
scenario_roadrunner_opts(multi_stream_h2, BaseOpts) ->
    %% Same handler as `hello` — the differentiator is the bench
    %% client driving N streams in flight per conn.
    BaseOpts#{handler => roadrunner_keepalive_handler};
scenario_roadrunner_opts(pipelined_h1, BaseOpts) ->
    %% Same handler as `hello` — pipelining is a wire-level
    %% client behavior; the server sees N requests in one buffer.
    BaseOpts#{handler => roadrunner_keepalive_handler};
scenario_roadrunner_opts(slow_client, BaseOpts) ->
    %% Same handler as `hello` — slow_client is a wire-level
    %% client behavior; the server sees a request arrive in
    %% multiple chunks with delays between them.
    BaseOpts#{handler => roadrunner_keepalive_handler};
scenario_roadrunner_opts(connection_storm, BaseOpts) ->
    %% Same handler as `hello` — connection_storm is a connection-
    %% lifecycle test; per-request work is identical to `hello`.
    BaseOpts#{handler => roadrunner_keepalive_handler};
scenario_roadrunner_opts(mixed_workload, BaseOpts) ->
    %% Three routes — bench client picks one uniformly per request.
    BaseOpts#{routes => [
        {~"/", roadrunner_keepalive_handler, undefined},
        {~"/json", roadrunner_bench_json_handler, undefined},
        {~"/large", roadrunner_bench_large_handler, undefined}
    ]};
scenario_roadrunner_opts(post_4kb_form, BaseOpts) ->
    BaseOpts#{routes => [{~"/form", roadrunner_bench_form_handler, undefined}]};
scenario_roadrunner_opts(large_post_streaming, BaseOpts) ->
    %% `body_buffering => manual` so the handler drains via
    %% `roadrunner_req:read_body/2` chunk-by-chunk rather than
    %% the conn pre-buffering 1 MB into the request map.
    BaseOpts#{
        body_buffering => manual,
        routes => [{~"/drain", roadrunner_bench_drain_handler, undefined}]
    };
scenario_roadrunner_opts(gzip_response, BaseOpts) ->
    %% Enable roadrunner_compress middleware at the listener level so
    %% all routes get gzip when the client asks for it.
    BaseOpts#{
        middlewares => [roadrunner_compress],
        routes => [{~"/gzip", roadrunner_bench_gzip_handler, undefined}]
    };
scenario_roadrunner_opts(backpressure_sustained, BaseOpts) ->
    %% Override the bench's default max_clients => 100K to a tight
    %% cap so the bench's 200-client wave saturates the listener.
    BaseOpts#{
        handler => roadrunner_keepalive_handler,
        max_clients => 50
    };
scenario_roadrunner_opts(server_sent_events, BaseOpts) ->
    BaseOpts#{routes => [{~"/sse", roadrunner_bench_sse_handler, undefined}]};
scenario_roadrunner_opts(expect_100_continue, BaseOpts) ->
    %% Reuse the existing echo handler — same body shape, the
    %% protocol-level interim 100 is handled automatically by
    %% `roadrunner_conn:maybe_send_continue/3`.
    BaseOpts#{routes => [{~"/echo", roadrunner_bench_echo_handler, undefined}]};
scenario_roadrunner_opts(large_keepalive_session, BaseOpts) ->
    %% Override the bench's default max_keep_alive_request => 1M
    %% with a tight cap so each conn closes after ~1000 requests,
    %% triggering reconnects within the bench duration.
    BaseOpts#{
        handler => roadrunner_keepalive_handler,
        max_keep_alive_request => 1000
    };
scenario_roadrunner_opts(websocket_msg_throughput, BaseOpts) ->
    BaseOpts#{routes => [{~"/ws", roadrunner_ws_upgrade_handler, undefined}]};
scenario_roadrunner_opts(url_with_qs, BaseOpts) ->
    BaseOpts#{routes => [{~"/qs", roadrunner_bench_url_qs_handler, undefined}]};
scenario_roadrunner_opts(small_chunked_response, BaseOpts) ->
    BaseOpts#{routes => [{~"/small", roadrunner_bench_small_chunks_handler, undefined}]};
scenario_roadrunner_opts(accept_storm_burst, BaseOpts) ->
    BaseOpts#{handler => roadrunner_keepalive_handler};
scenario_roadrunner_opts(head_method, BaseOpts) ->
    BaseOpts#{routes => [{~"/large", roadrunner_bench_large_handler, undefined}]};
scenario_roadrunner_opts(etag_304, BaseOpts) ->
    BaseOpts#{routes => [{~"/etag", roadrunner_bench_etag_handler, undefined}]};
scenario_roadrunner_opts(router_404_storm, BaseOpts) ->
    %% A real route table — even though the bench targets a
    %% non-matching path, populate /, /json, /large so the router
    %% has actual routes to walk past. Three is realistic for the
    %% smallest production router; bigger tables would amplify the
    %% router cost more.
    BaseOpts#{routes => [
        {~"/", roadrunner_keepalive_handler, undefined},
        {~"/json", roadrunner_bench_json_handler, undefined},
        {~"/large", roadrunner_bench_large_handler, undefined}
    ]};
scenario_roadrunner_opts(varied_paths_router, BaseOpts) ->
    BaseOpts#{routes => varied_paths_roadrunner_routes()}.

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
    [{'_', [{"/streaming", roadrunner_bench_cowboy_streaming_handler, []}]}];
scenario_cowboy_routes(multi_stream_h2) ->
    [{'_', [{"/", roadrunner_bench_cowboy_handler, []}]}];
scenario_cowboy_routes(pipelined_h1) ->
    [{'_', [{"/", roadrunner_bench_cowboy_handler, []}]}];
scenario_cowboy_routes(slow_client) ->
    [{'_', [{"/", roadrunner_bench_cowboy_handler, []}]}];
scenario_cowboy_routes(connection_storm) ->
    [{'_', [{"/", roadrunner_bench_cowboy_handler, []}]}];
scenario_cowboy_routes(mixed_workload) ->
    [
        {'_', [
            {"/", roadrunner_bench_cowboy_handler, []},
            {"/json", roadrunner_bench_cowboy_json_handler, []},
            {"/large", roadrunner_bench_cowboy_large_handler, []}
        ]}
    ];
scenario_cowboy_routes(post_4kb_form) ->
    [{'_', [{"/form", roadrunner_bench_cowboy_form_handler, []}]}];
scenario_cowboy_routes(large_post_streaming) ->
    [{'_', [{"/drain", roadrunner_bench_cowboy_drain_handler, []}]}];
scenario_cowboy_routes(router_404_storm) ->
    [
        {'_', [
            {"/", roadrunner_bench_cowboy_handler, []},
            {"/json", roadrunner_bench_cowboy_json_handler, []},
            {"/large", roadrunner_bench_cowboy_large_handler, []}
        ]}
    ];
scenario_cowboy_routes(varied_paths_router) ->
    [{'_', varied_paths_cowboy_routes()}];
scenario_cowboy_routes(gzip_response) ->
    [{'_', [{"/gzip", roadrunner_bench_cowboy_gzip_handler, []}]}];
scenario_cowboy_routes(backpressure_sustained) ->
    [{'_', [{"/", roadrunner_bench_cowboy_handler, []}]}];
scenario_cowboy_routes(server_sent_events) ->
    [{'_', [{"/sse", roadrunner_bench_cowboy_sse_handler, []}]}];
scenario_cowboy_routes(expect_100_continue) ->
    [{'_', [{"/echo", roadrunner_bench_cowboy_echo_handler, []}]}];
scenario_cowboy_routes(large_keepalive_session) ->
    [{'_', [{"/", roadrunner_bench_cowboy_handler, []}]}];
scenario_cowboy_routes(websocket_msg_throughput) ->
    [{'_', [{"/ws", roadrunner_bench_cowboy_ws_handler, []}]}];
scenario_cowboy_routes(url_with_qs) ->
    [{'_', [{"/qs", roadrunner_bench_cowboy_url_qs_handler, []}]}];
scenario_cowboy_routes(small_chunked_response) ->
    [{'_', [{"/small", roadrunner_bench_cowboy_small_chunks_handler, []}]}];
scenario_cowboy_routes(accept_storm_burst) ->
    [{'_', [{"/", roadrunner_bench_cowboy_handler, []}]}];
scenario_cowboy_routes(head_method) ->
    [{'_', [{"/large", roadrunner_bench_cowboy_large_handler, []}]}];
scenario_cowboy_routes(etag_304) ->
    [{'_', [{"/etag", roadrunner_bench_cowboy_etag_handler, []}]}].

%% Per-scenario cowboy TransportOpts. The default keeps the bench's
%% prior shape (`num_acceptors => 10`); `backpressure_sustained`
%% layers a 50-conn `max_connections` cap to mirror roadrunner's
%% `max_clients => 50` for that scenario.
scenario_cowboy_transport_opts(backpressure_sustained) ->
    #{
        num_acceptors => 10,
        socket_opts => [{port, 0}],
        max_connections => 50
    };
scenario_cowboy_transport_opts(_Scenario) ->
    #{num_acceptors => 10, socket_opts => [{port, 0}]}.

%% Per-scenario cowboy ProtoOpts. Default returns the base map; the
%% gzip_response scenario layers in `cowboy_compress_h` ahead of
%% the default stream handler so cowboy applies gzip per the
%% request's Accept-Encoding header (mirrors roadrunner_compress
%% middleware on the roadrunner side).
scenario_cowboy_proto_opts(gzip_response, Dispatch) ->
    #{
        env => #{dispatch => Dispatch},
        max_keepalive => 1000000,
        stream_handlers => [cowboy_compress_h, cowboy_stream_h]
    };
scenario_cowboy_proto_opts(large_keepalive_session, Dispatch) ->
    #{env => #{dispatch => Dispatch}, max_keepalive => 1000};
scenario_cowboy_proto_opts(_Scenario, Dispatch) ->
    #{env => #{dispatch => Dispatch}, max_keepalive => 1000000}.

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

run_phase_h1(
    Port, #{clients := C, host := Host, scenario := accept_storm_burst}, _DurationMs
) ->
    %% Burst — all clients connect at once, each does 1 conn, then
    %% exits. `--duration` is ignored; throughput is
    %% (successful conns) / (wall time to drain).
    Self = self(),
    StartUs = erlang:monotonic_time(microsecond),
    Workers = [
        spawn_link(fun() ->
            Self ! {self(), accept_storm_burst_one(Host, Port)}
        end)
     || _ <- lists:seq(1, C)
    ],
    Results = [collect_burst_one(W, 30000) || W <- Workers],
    EndUs = erlang:monotonic_time(microsecond),
    aggregate_burst(Results, EndUs - StartUs);
run_phase_h1(
    Port, #{clients := C, host := Host, scenario := websocket_msg_throughput}, DurationMs
) ->
    Deadline = erlang:monotonic_time(millisecond) + DurationMs,
    Self = self(),
    StartUs = erlang:monotonic_time(microsecond),
    Workers = [
        spawn_link(fun() ->
            Self ! {self(), ws_throughput_worker(Host, Port, Deadline, init_acc())}
        end)
     || _ <- lists:seq(1, C)
    ],
    PerWorker = [collect(W, DurationMs + 30000) || W <- Workers],
    EndUs = erlang:monotonic_time(microsecond),
    aggregate(PerWorker, EndUs - StartUs);
run_phase_h1(
    Port, #{clients := C, host := Host, scenario := large_keepalive_session}, DurationMs
) ->
    Deadline = erlang:monotonic_time(millisecond) + DurationMs,
    Req = build_request(large_keepalive_session),
    BodyLen = expected_body_len(large_keepalive_session),
    Self = self(),
    StartUs = erlang:monotonic_time(microsecond),
    Workers = [
        spawn_link(fun() ->
            Self !
                {self(),
                    large_keepalive_worker(Host, Port, Req, BodyLen, Deadline, init_acc())}
        end)
     || _ <- lists:seq(1, C)
    ],
    PerWorker = [collect(W, DurationMs + 30000) || W <- Workers],
    EndUs = erlang:monotonic_time(microsecond),
    aggregate(PerWorker, EndUs - StartUs);
run_phase_h1(
    Port, #{clients := C, host := Host, scenario := expect_100_continue}, DurationMs
) ->
    Deadline = erlang:monotonic_time(millisecond) + DurationMs,
    Self = self(),
    StartUs = erlang:monotonic_time(microsecond),
    Workers = [
        spawn_link(fun() ->
            Self ! {self(), expect_100_worker(Host, Port, Deadline, init_acc())}
        end)
     || _ <- lists:seq(1, C)
    ],
    PerWorker = [collect(W, DurationMs + 30000) || W <- Workers],
    EndUs = erlang:monotonic_time(microsecond),
    aggregate(PerWorker, EndUs - StartUs);
run_phase_h1(
    Port, #{clients := C, host := Host, scenario := server_sent_events}, DurationMs
) ->
    Deadline = erlang:monotonic_time(millisecond) + DurationMs,
    Self = self(),
    StartUs = erlang:monotonic_time(microsecond),
    Workers = [
        spawn_link(fun() ->
            Self ! {self(), sse_worker(Host, Port, Deadline, init_acc())}
        end)
     || _ <- lists:seq(1, C)
    ],
    PerWorker = [collect(W, DurationMs + 30000) || W <- Workers],
    EndUs = erlang:monotonic_time(microsecond),
    aggregate(PerWorker, EndUs - StartUs);
run_phase_h1(
    Port, #{clients := C, host := Host, scenario := varied_paths_router}, DurationMs
) ->
    Deadline = erlang:monotonic_time(millisecond) + DurationMs,
    Self = self(),
    StartUs = erlang:monotonic_time(microsecond),
    Workers = [
        spawn_link(fun() ->
            Self ! {self(), varied_paths_worker(Host, Port, Deadline, init_acc())}
        end)
     || _ <- lists:seq(1, C)
    ],
    PerWorker = [collect(W, DurationMs + 30000) || W <- Workers],
    EndUs = erlang:monotonic_time(microsecond),
    aggregate(PerWorker, EndUs - StartUs);
run_phase_h1(
    Port, #{clients := C, host := Host, scenario := router_404_storm}, DurationMs
) ->
    Deadline = erlang:monotonic_time(millisecond) + DurationMs,
    Self = self(),
    StartUs = erlang:monotonic_time(microsecond),
    Workers = [
        spawn_link(fun() ->
            Self ! {self(), router_404_storm_worker(Host, Port, Deadline, init_acc())}
        end)
     || _ <- lists:seq(1, C)
    ],
    PerWorker = [collect(W, DurationMs + 30000) || W <- Workers],
    EndUs = erlang:monotonic_time(microsecond),
    aggregate(PerWorker, EndUs - StartUs);
run_phase_h1(
    Port, #{clients := C, host := Host, scenario := mixed_workload}, DurationMs
) ->
    Deadline = erlang:monotonic_time(millisecond) + DurationMs,
    Self = self(),
    StartUs = erlang:monotonic_time(microsecond),
    Workers = [
        spawn_link(fun() ->
            Self ! {self(), mixed_workload_worker(Host, Port, Deadline, init_acc())}
        end)
     || _ <- lists:seq(1, C)
    ],
    PerWorker = [collect(W, DurationMs + 30000) || W <- Workers],
    EndUs = erlang:monotonic_time(microsecond),
    aggregate(PerWorker, EndUs - StartUs);
run_phase_h1(
    Port, #{clients := C, host := Host, scenario := connection_storm}, DurationMs
) ->
    Deadline = erlang:monotonic_time(millisecond) + DurationMs,
    Self = self(),
    StartUs = erlang:monotonic_time(microsecond),
    Workers = [
        spawn_link(fun() ->
            Self ! {self(), connection_storm_worker(Host, Port, Deadline, init_acc())}
        end)
     || _ <- lists:seq(1, C)
    ],
    PerWorker = [collect(W, DurationMs + 30000) || W <- Workers],
    EndUs = erlang:monotonic_time(microsecond),
    aggregate(PerWorker, EndUs - StartUs);
run_phase_h1(
    Port, #{clients := C, host := Host, scenario := slow_client}, DurationMs
) ->
    Deadline = erlang:monotonic_time(millisecond) + DurationMs,
    Self = self(),
    StartUs = erlang:monotonic_time(microsecond),
    Workers = [
        spawn_link(fun() ->
            Self ! {self(), slow_client_worker(Host, Port, Deadline, init_acc())}
        end)
     || _ <- lists:seq(1, C)
    ],
    PerWorker = [collect(W, DurationMs + 30000) || W <- Workers],
    EndUs = erlang:monotonic_time(microsecond),
    aggregate(PerWorker, EndUs - StartUs);
run_phase_h1(
    Port, #{clients := C, host := Host, scenario := pipelined_h1}, DurationMs
) ->
    Deadline = erlang:monotonic_time(millisecond) + DurationMs,
    Self = self(),
    StartUs = erlang:monotonic_time(microsecond),
    Workers = [
        spawn_link(fun() ->
            Self ! {self(), pipelined_h1_worker(Host, Port, Deadline, init_acc())}
        end)
     || _ <- lists:seq(1, C)
    ],
    PerWorker = [collect(W, DurationMs + 30000) || W <- Workers],
    EndUs = erlang:monotonic_time(microsecond),
    aggregate(PerWorker, EndUs - StartUs);
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

%% RFC 7230 §6.3.2 pipelining: client sends N requests back-to-back
%% and reads N responses in the same order. Real workloads are
%% browser-side dead but proxies (HAProxy, nginx) and health-check
%% probes still pipeline. The wire-distinct test target is the
%% server's parser handling "more bytes left in buffer after one
%% complete request" — a path single-request keep-alive doesn't
%% exercise.
-define(PIPELINE_DEPTH, 4).
-define(PIPELINED_H1_BODY_LEN, 7).

pipelined_h1_batch() ->
    %% 4 GET / requests joined into one binary so the server sees
    %% them in a single TCP segment (loopback MTU is 64 KB, well
    %% above 4 × ~24 bytes).
    binary:copy(~"GET / HTTP/1.1\r\nHost: x\r\n\r\n", ?PIPELINE_DEPTH).

pipelined_h1_worker(Host, Port, Deadline, Acc) ->
    Batch = pipelined_h1_batch(),
    case gen_tcp:connect(Host, Port, [binary, {active, false}], 5000) of
        {ok, Sock} ->
            Final = pipelined_h1_loop(Sock, Batch, Deadline, Acc),
            ok = gen_tcp:close(Sock),
            Final;
        {error, _} ->
            bump_err(Acc)
    end.

pipelined_h1_loop(Sock, Batch, Deadline, Acc) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true ->
            Acc;
        false ->
            T0 = erlang:monotonic_time(nanosecond),
            case gen_tcp:send(Sock, Batch) of
                ok ->
                    case recv_n_responses(
                        Sock, <<>>, ?PIPELINE_DEPTH, ?PIPELINED_H1_BODY_LEN, 5000, 0
                    ) of
                        {ok, Bytes} ->
                            T1 = erlang:monotonic_time(nanosecond),
                            PerReq = (T1 - T0) div ?PIPELINE_DEPTH,
                            PerBytes = Bytes div ?PIPELINE_DEPTH,
                            Acc1 = lists:foldl(
                                fun(_, A) -> bump_ok(A, PerReq, PerBytes) end,
                                Acc,
                                lists:seq(1, ?PIPELINE_DEPTH)
                            ),
                            pipelined_h1_loop(Sock, Batch, Deadline, Acc1);
                        {error, _} ->
                            bump_err(Acc)
                    end;
                {error, _} ->
                    bump_err(Acc)
            end
    end.

%% slow_client: a single h1 request is split into 5 lines and
%% drip-fed one line per millisecond. Each `gen_tcp:send/2` lands
%% in a separate TCP segment (loopback + small payload + `nodelay`
%% on both sides) so the server's parser sees the request arrive
%% incrementally — multiple recv cycles before the request is
%% complete. That's a code path uniform-fast-keep-alive doesn't
%% reach: most h1 servers buffer the whole request inside one recv
%% on a fast LAN.
-define(SLOW_CHUNK_DELAY_MS, 1).

slow_client_chunks() ->
    %% 5 chunks → 4 inter-chunk sleeps = 4 ms minimum send-time
    %% per request. Body is identical to `hello` so the wire
    %% comparison stays apples-to-apples.
    [
        ~"GET / HTTP/1.1\r\n",
        ~"Host: x\r\n",
        ~"User-Agent: roadrunner-bench-slow/1.0\r\n",
        ~"Accept: */*\r\n",
        ~"\r\n"
    ].

slow_client_worker(Host, Port, Deadline, Acc) ->
    Chunks = slow_client_chunks(),
    case gen_tcp:connect(Host, Port, [binary, {active, false}, {nodelay, true}], 5000) of
        {ok, Sock} ->
            Final = slow_client_loop(Sock, Chunks, Deadline, Acc),
            ok = gen_tcp:close(Sock),
            Final;
        {error, _} ->
            bump_err(Acc)
    end.

slow_client_loop(Sock, Chunks, Deadline, Acc) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true ->
            Acc;
        false ->
            T0 = erlang:monotonic_time(nanosecond),
            case slow_send(Sock, Chunks) of
                ok ->
                    case recv_response(Sock, <<>>, 7, 5000) of
                        {ok, Bytes} ->
                            T1 = erlang:monotonic_time(nanosecond),
                            slow_client_loop(
                                Sock, Chunks, Deadline,
                                bump_ok(Acc, T1 - T0, Bytes)
                            );
                        {error, _} ->
                            bump_err(Acc)
                    end;
                {error, _} ->
                    bump_err(Acc)
            end
    end.

slow_send(_Sock, []) ->
    ok;
slow_send(Sock, [Last]) ->
    %% No sleep after the last chunk — the request is complete and
    %% the server should respond immediately.
    gen_tcp:send(Sock, Last);
slow_send(Sock, [Chunk | Rest]) ->
    case gen_tcp:send(Sock, Chunk) of
        ok ->
            timer:sleep(?SLOW_CHUNK_DELAY_MS),
            slow_send(Sock, Rest);
        {error, _} = E ->
            E
    end.

%% connection_storm: per request, open a fresh TCP conn, send one
%% GET /, recv the 7-byte response, close. Tests the accept /
%% acceptor-pool dispatch / slot acquire-release / TCP teardown
%% path — the metric ops care about for health-check probes (k8s
%% readiness / ELB target-group), short-lived CLI clients, and
%% HTTP-as-RPC patterns where keep-alive isn't in use.
connection_storm_request() ->
    ~"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".

connection_storm_worker(Host, Port, Deadline, Acc) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true ->
            Acc;
        false ->
            T0 = erlang:monotonic_time(nanosecond),
            case connection_storm_one(Host, Port) of
                {ok, Bytes} ->
                    T1 = erlang:monotonic_time(nanosecond),
                    connection_storm_worker(
                        Host, Port, Deadline, bump_ok(Acc, T1 - T0, Bytes)
                    );
                {error, _} ->
                    connection_storm_worker(Host, Port, Deadline, bump_err(Acc))
            end
    end.

connection_storm_one(Host, Port) ->
    case gen_tcp:connect(Host, Port, [binary, {active, false}, {nodelay, true}], 5000) of
        {ok, Sock} ->
            case gen_tcp:send(Sock, connection_storm_request()) of
                ok ->
                    Result = recv_response(Sock, <<>>, 7, 5000),
                    _ = gen_tcp:close(Sock),
                    Result;
                {error, _} = E ->
                    _ = gen_tcp:close(Sock),
                    E
            end;
        {error, _} = E ->
            E
    end.

%% router_404_storm: roadrunner's 404 path returns
%% `Connection: close` (defensive — the conn might be in an
%% unexpected state after a router miss), so a keep-alive loop
%% can't reuse the conn. Use a fresh-conn-per-request shape and
%% send `Connection: close` from the client too — both servers
%% see identical conn lifecycle, the bench measures router-miss
%% throughput including the conn close cost.
router_404_storm_request() ->
    ~"GET /nope HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".

router_404_storm_worker(Host, Port, Deadline, Acc) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true ->
            Acc;
        false ->
            T0 = erlang:monotonic_time(nanosecond),
            case router_404_storm_one(Host, Port) of
                {ok, Bytes} ->
                    T1 = erlang:monotonic_time(nanosecond),
                    router_404_storm_worker(
                        Host, Port, Deadline, bump_ok(Acc, T1 - T0, Bytes)
                    );
                {error, _} ->
                    router_404_storm_worker(Host, Port, Deadline, bump_err(Acc))
            end
    end.

router_404_storm_one(Host, Port) ->
    case gen_tcp:connect(Host, Port, [binary, {active, false}, {nodelay, true}], 5000) of
        {ok, Sock} ->
            case gen_tcp:send(Sock, router_404_storm_request()) of
                ok ->
                    Result = recv_404_response(Sock, <<>>, 5000),
                    _ = gen_tcp:close(Sock),
                    Result;
                {error, _} = E ->
                    _ = gen_tcp:close(Sock),
                    E
            end;
        {error, _} = E ->
            E
    end.

%% websocket_msg_throughput: WS handshake then a tight echo loop
%% (1 KB masked text frame → 1 KB unmasked text frame back). Each
%% successful echo counts as one bench-OK; latency is per-echo.
-define(WS_PAYLOAD_SIZE, 1024).

ws_handshake_request() ->
    %% 16-byte random key, base64-encoded — RFC 6455 §4.2.1. The
    %% server's `Sec-WebSocket-Accept` is computed from this; we
    %% don't validate it here, just check for the 101 status.
    Key = base64:encode(crypto:strong_rand_bytes(16)),
    <<"GET /ws HTTP/1.1\r\n",
        "Host: x\r\n",
        "Upgrade: websocket\r\n",
        "Connection: Upgrade\r\n",
        "Sec-WebSocket-Key: ", Key/binary, "\r\n",
        "Sec-WebSocket-Version: 13\r\n",
        "\r\n">>.

ws_throughput_worker(Host, Port, Deadline, Acc) ->
    case gen_tcp:connect(Host, Port, [binary, {active, false}, {nodelay, true}], 5000) of
        {ok, Sock} ->
            case ws_complete_handshake(Sock) of
                {ok, Buf0} ->
                    Payload = binary:copy(~"x", ?WS_PAYLOAD_SIZE),
                    Final = ws_loop(Sock, Payload, Buf0, Deadline, Acc),
                    _ = gen_tcp:close(Sock),
                    Final;
                {error, _} ->
                    _ = gen_tcp:close(Sock),
                    bump_err(Acc)
            end;
        {error, _} ->
            bump_err(Acc)
    end.

%% Send the upgrade request, drain the 101 response headers,
%% return any leftover bytes (which are the start of the first
%% server-side WS frame, if the server already wrote one).
ws_complete_handshake(Sock) ->
    Req = ws_handshake_request(),
    case gen_tcp:send(Sock, Req) of
        ok -> ws_recv_handshake(Sock, <<>>);
        {error, _} = E -> E
    end.

ws_recv_handshake(Sock, Buf) ->
    case binary:split(Buf, ~"\r\n\r\n") of
        [_Head, Rest] ->
            case Buf of
                <<"HTTP/1.1 101", _/binary>> -> {ok, Rest};
                _ -> {error, bad_status}
            end;
        _ ->
            case gen_tcp:recv(Sock, 0, 5000) of
                {ok, Data} ->
                    ws_recv_handshake(Sock, <<Buf/binary, Data/binary>>);
                {error, _} = E ->
                    E
            end
    end.

ws_loop(Sock, Payload, Buf, Deadline, Acc) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true ->
            Acc;
        false ->
            T0 = erlang:monotonic_time(nanosecond),
            Frame = ws_encode_masked_text(Payload),
            case gen_tcp:send(Sock, Frame) of
                ok ->
                    case ws_recv_frame(Sock, Buf) of
                        {ok, _Bytes, Buf1} ->
                            T1 = erlang:monotonic_time(nanosecond),
                            ws_loop(
                                Sock, Payload, Buf1, Deadline,
                                bump_ok(Acc, T1 - T0, ?WS_PAYLOAD_SIZE)
                            );
                        {error, _} ->
                            bump_err(Acc)
                    end;
                {error, _} ->
                    bump_err(Acc)
            end
    end.

%% Encode a single FIN+text WS frame with a fresh 4-byte mask.
%% RFC 6455 §5.3 mandates client→server frames be masked.
ws_encode_masked_text(Payload) ->
    Len = byte_size(Payload),
    Mask = crypto:strong_rand_bytes(4),
    Masked = ws_apply_mask(Payload, Mask),
    Header =
        case Len of
            L when L =< 125 ->
                <<1:1, 0:3, 1:4, 1:1, L:7, Mask/binary>>;
            L when L =< 16#FFFF ->
                <<1:1, 0:3, 1:4, 1:1, 126:7, L:16, Mask/binary>>;
            L ->
                <<1:1, 0:3, 1:4, 1:1, 127:7, L:64, Mask/binary>>
        end,
    [Header, Masked].

ws_apply_mask(Payload, <<M0, M1, M2, M3>>) ->
    ws_apply_mask_bytes(Payload, M0, M1, M2, M3, 0, <<>>).

ws_apply_mask_bytes(<<>>, _, _, _, _, _, Acc) ->
    Acc;
ws_apply_mask_bytes(<<B, R/binary>>, M0, M1, M2, M3, I, Acc) ->
    M =
        case I rem 4 of
            0 -> M0;
            1 -> M1;
            2 -> M2;
            _ -> M3
        end,
    ws_apply_mask_bytes(R, M0, M1, M2, M3, I + 1, <<Acc/binary, (B bxor M)>>).

%% Read one server-side (unmasked) frame from the wire. Returns
%% the unconsumed buf so the next iteration's read picks up where
%% this left off. Only handles unfragmented text frames — that's
%% all the bench's echo handler ever emits.
ws_recv_frame(Sock, Buf) ->
    case ws_parse_frame(Buf) of
        {ok, Bytes, Rest} ->
            {ok, Bytes, Rest};
        more ->
            case gen_tcp:recv(Sock, 0, 5000) of
                {ok, Data} -> ws_recv_frame(Sock, <<Buf/binary, Data/binary>>);
                {error, _} = E -> E
            end
    end.

ws_parse_frame(<<_:1, _:3, _:4, 0:1, Len:7, Rest/binary>>) when
    Len =< 125, byte_size(Rest) >= Len
->
    <<Payload:Len/binary, Tail/binary>> = Rest,
    {ok, byte_size(Payload), Tail};
ws_parse_frame(<<_:1, _:3, _:4, 0:1, 126:7, Len:16, Rest/binary>>) when
    byte_size(Rest) >= Len
->
    <<Payload:Len/binary, Tail/binary>> = Rest,
    {ok, byte_size(Payload), Tail};
ws_parse_frame(<<_:1, _:3, _:4, 0:1, 127:7, Len:64, Rest/binary>>) when
    byte_size(Rest) >= Len
->
    <<Payload:Len/binary, Tail/binary>> = Rest,
    {ok, byte_size(Payload), Tail};
ws_parse_frame(_) ->
    more.

%% large_keepalive_session: like the default keep_alive_loop, but
%% on conn-close (the server hit its `max_keep_alive_request` cap)
%% the worker reconnects and continues. Measures sustained
%% throughput INCLUDING the periodic per-1000-req reconnect tax
%% — a path single-request `connection_storm` and the default
%% per-conn-fixed `keep_alive_loop` can't reach.
large_keepalive_worker(Host, Port, Req, BodyLen, Deadline, Acc) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true ->
            Acc;
        false ->
            case gen_tcp:connect(Host, Port, [binary, {active, false}], 5000) of
                {ok, Sock} ->
                    Acc1 = large_keepalive_inner(Sock, Req, BodyLen, Deadline, Acc),
                    ok = gen_tcp:close(Sock),
                    %% Loop: open a fresh conn and keep going until
                    %% the bench deadline. The ok-counter carries
                    %% across reconnects.
                    large_keepalive_worker(Host, Port, Req, BodyLen, Deadline, Acc1);
                {error, _} ->
                    bump_err(Acc)
            end
    end.

%% Run requests on `Sock` until either the deadline elapses or the
%% server closes (max_keep_alive_request). Conn-close mid-loop is
%% NOT an error here — it's the expected end-of-conn signal.
large_keepalive_inner(Sock, Req, BodyLen, Deadline, Acc) ->
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
                            large_keepalive_inner(
                                Sock, Req, BodyLen, Deadline,
                                bump_ok(Acc, T1 - T0, Bytes)
                            );
                        {error, _} ->
                            %% Conn closed by the server (max
                            %% reached) — return to the outer
                            %% loop which reconnects.
                            Acc
                    end;
                {error, _} ->
                    Acc
            end
    end.

%% expect_100_continue: keep-alive worker. Per iteration: send
%% request HEADERS WITH `Expect: 100-continue` (no body); read the
%% interim `HTTP/1.1 100 Continue` response; then send the body;
%% then read the final `HTTP/1.1 200 OK` response. Two recv-then-
%% send phases per request — distinct from any other scenario,
%% exercises `roadrunner_conn:maybe_send_continue/3`.
-define(EXPECT_100_BODY_SIZE, 256).

expect_100_headers() ->
    Body = binary:copy(~"x", ?EXPECT_100_BODY_SIZE),
    BodyLen = integer_to_binary(?EXPECT_100_BODY_SIZE),
    Headers = <<"POST /echo HTTP/1.1\r\n",
        "Host: x\r\n",
        "Content-Type: application/octet-stream\r\n",
        "Expect: 100-continue\r\n",
        "Content-Length: ", BodyLen/binary, "\r\n",
        "\r\n">>,
    {Headers, Body}.

expect_100_worker(Host, Port, Deadline, Acc) ->
    case gen_tcp:connect(Host, Port, [binary, {active, false}, {nodelay, true}], 5000) of
        {ok, Sock} ->
            {Headers, Body} = expect_100_headers(),
            Final = expect_100_loop(Sock, Headers, Body, Deadline, Acc),
            ok = gen_tcp:close(Sock),
            Final;
        {error, _} ->
            bump_err(Acc)
    end.

expect_100_loop(Sock, Headers, Body, Deadline, Acc) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true ->
            Acc;
        false ->
            T0 = erlang:monotonic_time(nanosecond),
            case expect_100_one(Sock, Headers, Body) of
                {ok, Bytes} ->
                    T1 = erlang:monotonic_time(nanosecond),
                    expect_100_loop(
                        Sock, Headers, Body, Deadline,
                        bump_ok(Acc, T1 - T0, Bytes)
                    );
                {error, _} ->
                    bump_err(Acc)
            end
    end.

%% One full 100-continue cycle on `Sock`: headers → 100 → body → 200.
%% Returns the leftover buf-size on success so the bench accumulator
%% has something concrete; `Buf` itself is discarded between
%% iterations (kernel buffer drained by the read).
expect_100_one(Sock, Headers, Body) ->
    case gen_tcp:send(Sock, Headers) of
        ok ->
            case recv_status_line(Sock, <<>>, ~"HTTP/1.1 100", 5000) of
                {ok, Buf1} ->
                    %% Buf1 contains the 100 status line + its
                    %% terminating CRLFs. Consume those, then send
                    %% the body and wait for 200.
                    case skip_status_line(Buf1) of
                        {ok, _Rest} ->
                            case gen_tcp:send(Sock, Body) of
                                ok -> recv_response(Sock, <<>>, ?EXPECT_100_BODY_SIZE, 5000);
                                {error, _} = E -> E
                            end;
                        {error, _} = E ->
                            E
                    end;
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

%% Read until `Buf` contains the expected status-line prefix at offset 0.
recv_status_line(Sock, Buf, Prefix, Timeout) ->
    case Buf of
        <<Prefix:(byte_size(Prefix))/binary, _/binary>> ->
            {ok, Buf};
        _ when byte_size(Buf) >= byte_size(Prefix) ->
            {error, bad_status};
        _ ->
            case gen_tcp:recv(Sock, 0, Timeout) of
                {ok, Data} ->
                    recv_status_line(Sock, <<Buf/binary, Data/binary>>, Prefix, Timeout);
                {error, _} = E ->
                    E
            end
    end.

%% Drop the first status-line + terminating `\r\n\r\n` from `Buf`.
%% The interim 100-continue response carries no body — the headers
%% block end is followed immediately by the final response's status
%% line on the wire, possibly already buffered.
skip_status_line(Buf) ->
    case binary:split(Buf, ~"\r\n\r\n") of
        [_Status, Rest] -> {ok, Rest};
        _ -> {error, bad_status}
    end.

%% accept_storm_burst: each worker does ONE conn (open, send, recv,
%% close) then exits. All workers spawn simultaneously so the
%% kernel's listen queue and the acceptor pool see a single peak
%% burst. Different bookkeeping from the loop-driven scenarios:
%% the worker reports a single result, not a deadline-bounded acc.
accept_storm_burst_one(Host, Port) ->
    T0 = erlang:monotonic_time(nanosecond),
    case
        gen_tcp:connect(
            Host, Port, [binary, {active, false}, {nodelay, true}], 5000
        )
    of
        {ok, Sock} ->
            Result =
                case
                    gen_tcp:send(Sock, ~"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
                of
                    ok ->
                        case recv_response(Sock, <<>>, 7, 5000) of
                            {ok, Bytes} ->
                                T1 = erlang:monotonic_time(nanosecond),
                                {ok, T1 - T0, Bytes};
                            {error, Reason} ->
                                {error, Reason}
                        end;
                    {error, Reason} ->
                        {error, Reason}
                end,
            _ = gen_tcp:close(Sock),
            Result;
        {error, Reason} ->
            {error, Reason}
    end.

collect_burst_one(Pid, TimeoutMs) ->
    receive
        {Pid, R} -> R
    after TimeoutMs ->
        io:format("error: burst worker ~p timed out~n", [Pid]),
        {error, worker_timeout}
    end.

%% Build a single accumulator from a list of per-worker burst
%% results. Same shape as the deadline-driven scenarios so the
%% existing `aggregate/2` and reporting paths work unchanged.
aggregate_burst(Results, ElapsedUs) ->
    OkLatencies = [Ns || {ok, Ns, _Bytes} <- Results],
    OkBytes = lists:sum([B || {ok, _, B} <- Results]),
    Acc = #{
        ok => length(OkLatencies),
        err => length(Results) - length(OkLatencies),
        bytes_in => OkBytes,
        latencies_ns => OkLatencies
    },
    aggregate([Acc], ElapsedUs).

%% server_sent_events: per iteration, open a fresh conn, send a
%% GET /sse, drain the chunked-encoded SSE stream until the server
%% closes (after 100 events), then loop. Each iteration counts as
%% one OK; the bench's "req/s" is therefore "SSE-sessions/s" — each
%% session encompasses 100 events, so total event throughput is
%% req/s × 100.
sse_request() ->
    ~"GET /sse HTTP/1.1\r\nHost: x\r\n\r\n".

sse_worker(Host, Port, Deadline, Acc) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true ->
            Acc;
        false ->
            T0 = erlang:monotonic_time(nanosecond),
            case sse_one(Host, Port) of
                {ok, Bytes} ->
                    T1 = erlang:monotonic_time(nanosecond),
                    sse_worker(
                        Host, Port, Deadline, bump_ok(Acc, T1 - T0, Bytes)
                    );
                {error, _} ->
                    sse_worker(Host, Port, Deadline, bump_err(Acc))
            end
    end.

sse_one(Host, Port) ->
    case gen_tcp:connect(Host, Port, [binary, {active, false}, {nodelay, true}], 5000) of
        {ok, Sock} ->
            case gen_tcp:send(Sock, sse_request()) of
                ok ->
                    Result = sse_drain(Sock, <<>>, 0),
                    _ = gen_tcp:close(Sock),
                    Result;
                {error, _} = E ->
                    _ = gen_tcp:close(Sock),
                    E
            end;
        {error, _} = E ->
            E
    end.

%% Drain until the peer closes — that's the terminating signal for
%% an SSE session in this fixture (server emits 100 events then
%% closes). Validate status 200 once headers are seen; total bytes
%% read is reported back to the bench's accumulator.
sse_drain(Sock, Buf, Bytes) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Data} ->
            NewBuf = <<Buf/binary, Data/binary>>,
            sse_drain(Sock, NewBuf, Bytes + byte_size(Data));
        {error, closed} ->
            case Buf of
                <<"HTTP/1.1 200", _/binary>> -> {ok, Bytes};
                _ -> {error, bad_status}
            end;
        {error, _} = E ->
            E
    end.

%% varied_paths_router: 100 distinct routed paths. Worker
%% maintains a counter and rotates round-robin per request on a
%% single keep-alive conn. Tests router warmth under realistic
%% API surface area — a 100-route table is closer to production
%% than the 3-route `mixed_workload`.
-define(VARIED_PATHS_COUNT, 100).

varied_paths_roadrunner_routes() ->
    [
        {varied_path(N), roadrunner_keepalive_handler, undefined}
     || N <- lists:seq(1, ?VARIED_PATHS_COUNT)
    ].

varied_paths_cowboy_routes() ->
    [
        {binary_to_list(varied_path(N)), roadrunner_bench_cowboy_handler, []}
     || N <- lists:seq(1, ?VARIED_PATHS_COUNT)
    ].

varied_path(N) ->
    %% `/api/v1/items/0001` shape — 4-digit zero-padded so all
    %% paths are the same length, removing path-length as a
    %% confound in the router walk.
    <<"/api/v1/items/", (pad4(N))/binary>>.

pad4(N) when N < 10 -> <<"000", (integer_to_binary(N))/binary>>;
pad4(N) when N < 100 -> <<"00", (integer_to_binary(N))/binary>>;
pad4(N) when N < 1000 -> <<"0", (integer_to_binary(N))/binary>>;
pad4(N) -> integer_to_binary(N).

varied_paths_requests() ->
    %% Build all N requests once per worker — tuple for O(1)
    %% indexing in the hot loop.
    list_to_tuple([
        <<"GET ", (varied_path(N))/binary, " HTTP/1.1\r\nHost: x\r\n\r\n">>
     || N <- lists:seq(1, ?VARIED_PATHS_COUNT)
    ]).

varied_paths_worker(Host, Port, Deadline, Acc) ->
    case gen_tcp:connect(Host, Port, [binary, {active, false}, {nodelay, true}], 5000) of
        {ok, Sock} ->
            Reqs = varied_paths_requests(),
            Final = varied_paths_loop(Sock, Reqs, 1, Deadline, Acc),
            ok = gen_tcp:close(Sock),
            Final;
        {error, _} ->
            bump_err(Acc)
    end.

varied_paths_loop(Sock, Reqs, Idx, Deadline, Acc) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true ->
            Acc;
        false ->
            Req = element(Idx, Reqs),
            T0 = erlang:monotonic_time(nanosecond),
            case gen_tcp:send(Sock, Req) of
                ok ->
                    case recv_response(Sock, <<>>, 7, 5000) of
                        {ok, Bytes} ->
                            T1 = erlang:monotonic_time(nanosecond),
                            NextIdx =
                                case Idx >= ?VARIED_PATHS_COUNT of
                                    true -> 1;
                                    false -> Idx + 1
                                end,
                            varied_paths_loop(
                                Sock, Reqs, NextIdx, Deadline,
                                bump_ok(Acc, T1 - T0, Bytes)
                            );
                        {error, _} ->
                            bump_err(Acc)
                    end;
                {error, _} ->
                    bump_err(Acc)
            end
    end.

%% Drain a 404 response. Body is zero bytes (server sets
%% Content-Length: 0); we just need to see the headers terminator
%% with the 404 status line.
recv_404_response(Sock, Buf, Timeout) ->
    case binary:split(Buf, ~"\r\n\r\n") of
        [_Headers, _Body] ->
            case Buf of
                <<"HTTP/1.1 404", _/binary>> -> {ok, byte_size(Buf)};
                _ -> {error, bad_status}
            end;
        _ ->
            case gen_tcp:recv(Sock, 0, Timeout) of
                {ok, Data} -> recv_404_response(Sock, <<Buf/binary, Data/binary>>, Timeout);
                {error, _} = E -> E
            end
    end.

%% mixed_workload: per request, randomly pick a path from
%% {hello, json, large_response} on the same keep-alive conn.
%% Closer-to-production traffic shape — surfaces router-cache
%% effects (a stable single path warms one router slot; a varied
%% path mix exercises real dispatch). Equal weights so each path
%% gets pressure; latency reported is the per-request mean across
%% the mix, not a per-path breakdown.
mixed_workload_requests() ->
    %% Triple of {RequestBytes, ExpectedBodyLen} so the recv loop
    %% can stop on Content-Length without re-parsing the request.
    {
        {build_request(hello), expected_body_len(hello)},
        {build_request(json), expected_body_len(json)},
        {build_request(large_response), expected_body_len(large_response)}
    }.

mixed_workload_worker(Host, Port, Deadline, Acc) ->
    case gen_tcp:connect(Host, Port, [binary, {active, false}, {nodelay, true}], 5000) of
        {ok, Sock} ->
            Reqs = mixed_workload_requests(),
            Final = mixed_workload_loop(Sock, Reqs, Deadline, Acc),
            ok = gen_tcp:close(Sock),
            Final;
        {error, _} ->
            bump_err(Acc)
    end.

mixed_workload_loop(Sock, Reqs, Deadline, Acc) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true ->
            Acc;
        false ->
            {Req, BodyLen} = element(rand:uniform(3), Reqs),
            T0 = erlang:monotonic_time(nanosecond),
            case gen_tcp:send(Sock, Req) of
                ok ->
                    case recv_response(Sock, <<>>, BodyLen, 5000) of
                        {ok, Bytes} ->
                            T1 = erlang:monotonic_time(nanosecond),
                            mixed_workload_loop(
                                Sock, Reqs, Deadline,
                                bump_ok(Acc, T1 - T0, Bytes)
                            );
                        {error, _} ->
                            bump_err(Acc)
                    end;
                {error, _} ->
                    bump_err(Acc)
            end
    end.

%% Drain N back-to-back HTTP/1.1 responses from `Buf`. Each response
%% has the same fixed Content-Length (`BodyLen`). After consuming a
%% complete response, the leftover bytes in `Buf` are the start of
%% the next response — no extra recv until the buffer is empty.
recv_n_responses(_Sock, _Buf, 0, _BodyLen, _Timeout, BytesAcc) ->
    {ok, BytesAcc};
recv_n_responses(Sock, Buf, N, BodyLen, Timeout, BytesAcc) ->
    case binary:split(Buf, ~"\r\n\r\n") of
        [Headers, Body] when byte_size(Body) >= BodyLen ->
            case Buf of
                <<"HTTP/1.1 200", _/binary>> ->
                    Consumed = byte_size(Headers) + 4 + BodyLen,
                    <<_:Consumed/binary, Rest/binary>> = Buf,
                    recv_n_responses(
                        Sock, Rest, N - 1, BodyLen, Timeout, BytesAcc + Consumed
                    );
                _ ->
                    {error, bad_status}
            end;
        _ ->
            case gen_tcp:recv(Sock, 0, Timeout) of
                {ok, Data} ->
                    recv_n_responses(
                        Sock, <<Buf/binary, Data/binary>>, N, BodyLen, Timeout, BytesAcc
                    );
                {error, _} = E ->
                    E
            end
    end.

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
build_request(multi_stream_h2) ->
    io:format(standard_error,
        "error: --scenario multi_stream_h2 is h2-only "
        "(use --protocol h2)~n", []),
    halt(2);
build_request(large_post_streaming) ->
    %% 1 MB body — `x` repeated. Cached at module load via
    %% `persistent_term` would be ideal but escripts don't
    %% have on_load; pay one allocation per worker spawn (which
    %% also caches the request once per worker).
    Body = binary:copy(~"x", ?LARGE_POST_BODY_SIZE),
    BodyLenBin = integer_to_binary(?LARGE_POST_BODY_SIZE),
    <<"POST /drain HTTP/1.1\r\n",
        "Host: x\r\n",
        "Content-Type: application/octet-stream\r\n",
        "Content-Length: ",
        BodyLenBin/binary,
        "\r\n\r\n",
        Body/binary>>;
build_request(gzip_response) ->
    ~"GET /gzip HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip\r\n\r\n";
build_request(backpressure_sustained) ->
    ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n";
build_request(large_keepalive_session) ->
    ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n";
build_request(url_with_qs) ->
    %% 6 simple key=value pairs in the URL — no `+` or `%`, so the
    %% qs:parse fast-path takes the no-op branch (matches typical
    %% REST API filter URLs).
    ~"GET /qs?filter=active&sort=name&limit=100&offset=200&fields=id,name,email&include=role HTTP/1.1\r\nHost: x\r\n\r\n";
build_request(small_chunked_response) ->
    %% Same h1 limitation as `streaming_response`: stream responses
    %% close the conn per-request, breaking the bench's keep-alive
    %% loop. h2-only.
    io:format(standard_error,
        "error: --scenario small_chunked_response is h2-only "
        "(use --protocol h2)~n", []),
    halt(2);
build_request(head_method) ->
    ~"HEAD /large HTTP/1.1\r\nHost: x\r\n\r\n";
build_request(etag_304) ->
    ~"GET /etag HTTP/1.1\r\nHost: x\r\nIf-None-Match: \"v1\"\r\n\r\n";
build_request(post_4kb_form) ->
    %% 4 KB urlencoded body — see `post_4kb_form_body/0` for shape.
    %% Predictable parse cost (ASCII letters/digits only, no
    %% percent-decoding) so the bench measures qs-tokenization and
    %% pair-split, not URL decoding.
    Body = post_4kb_form_body(),
    BodyLen = byte_size(Body),
    BodyLenBin = integer_to_binary(BodyLen),
    <<"POST /form HTTP/1.1\r\n",
        "Host: x\r\n",
        "Content-Type: application/x-www-form-urlencoded\r\n",
        "Content-Length: ",
        BodyLenBin/binary,
        "\r\n\r\n",
        Body/binary>>;
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
expected_body_len(streaming_response) -> 16384;
expected_body_len(post_4kb_form) ->
    %% Response is the integer pair-count rendered as decimal —
    %% computed from the body so the bench stays in sync if the
    %% body shape changes.
    Pairs = post_4kb_form_pair_count(),
    byte_size(integer_to_binary(Pairs));
expected_body_len(large_post_streaming) -> 2;
expected_body_len(gzip_response) ->
    %% 16 KB JSON body of repeating records compresses to ~180-200
    %% bytes via gzip (almost all dictionary references). Cowboy and
    %% roadrunner pick slightly different compression params; pin
    %% to the lower bound so recv returns as soon as either server's
    %% body bytes have arrived. Extra bytes stay in the kernel
    %% buffer and would be picked up by the next iteration's recv —
    %% but each iteration's response fits in one TCP segment on
    %% loopback so this is moot in practice.
    50;
expected_body_len(backpressure_sustained) -> 7;
expected_body_len(large_keepalive_session) -> 7;
expected_body_len(url_with_qs) -> 1;
expected_body_len(small_chunked_response) -> 6400;
expected_body_len(head_method) -> 0;
expected_body_len(etag_304) -> 0.

%% 128 pairs of `kNNN=` + 27-char value, joined by `&`. Each
%% pair = 32 bytes; 128 × 32 - 1 (trailing `&` dropped) = 4095
%% bytes. ASCII-only so qs:parse never enters percent-decode.
-define(POST_FORM_PAIRS, 128).
-define(POST_FORM_VALUE,
    ~"abcdefghijklmnopqrstuvwxyz0"
).

post_4kb_form_pair_count() -> ?POST_FORM_PAIRS.

post_4kb_form_body() ->
    Pairs = [
        <<"k", (pad3(N))/binary, "=", ?POST_FORM_VALUE/binary>>
     || N <- lists:seq(1, ?POST_FORM_PAIRS)
    ],
    iolist_to_binary(lists:join(~"&", Pairs)).

%% 3-digit zero-padded decimal: 1 → ~"001", 128 → ~"128".
pad3(N) when N < 10 -> <<"00", (integer_to_binary(N))/binary>>;
pad3(N) when N < 100 -> <<"0", (integer_to_binary(N))/binary>>;
pad3(N) -> integer_to_binary(N).

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
%% count. Most scenarios assume the response carries an accurate
%% `Content-Length` so we know when the body's complete. Accepts
%% `HTTP/1.1 200` (the typical case) and `HTTP/1.1 304` (etag_304
%% scenario where the server intentionally short-circuits with
%% Not Modified) — both are successful responses from the bench's
%% perspective.
recv_response(Sock, Buf, BodyLen, Timeout) ->
    case binary:split(Buf, ~"\r\n\r\n") of
        [_Headers, Body] when byte_size(Body) >= BodyLen ->
            case ok_status_prefix(Buf) of
                true -> {ok, byte_size(Buf)};
                false -> {error, bad_status}
            end;
        _ ->
            case gen_tcp:recv(Sock, 0, Timeout) of
                {ok, Data} -> recv_response(Sock, <<Buf/binary, Data/binary>>, BodyLen, Timeout);
                {error, _} = E -> E
            end
    end.

ok_status_prefix(<<"HTTP/1.1 200", _/binary>>) -> true;
ok_status_prefix(<<"HTTP/1.1 304", _/binary>>) -> true;
ok_status_prefix(_) -> false.

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

run_phase_h2(
    Port, #{clients := C, host := Host, scenario := multi_stream_h2}, DurationMs
) ->
    Deadline = erlang:monotonic_time(millisecond) + DurationMs,
    Self = self(),
    StartUs = erlang:monotonic_time(microsecond),
    Workers = [
        spawn_link(fun() ->
            Self ! {self(), h2_multi_stream_worker(Host, Port, Deadline, init_acc())}
        end)
     || _ <- lists:seq(1, C)
    ],
    PerWorker = [collect(W, DurationMs + 30000) || W <- Workers],
    EndUs = erlang:monotonic_time(microsecond),
    aggregate(PerWorker, EndUs - StartUs);
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

%% Number of concurrent streams in flight per `request_many/2`
%% batch. Roadrunner advertises MAX_CONCURRENT_STREAMS=100; cowboy
%% defaults to 100 too; pick a value comfortably below both that
%% still meaningfully exercises multiplexing.
-define(MULTI_STREAM_BATCH, 16).

h2_multi_stream_worker(Host, Port, Deadline, Acc) ->
    case roadrunner_bench_client:open(Host, Port, h2) of
        {ok, Conn} ->
            Final = h2_multi_stream_loop(Conn, Deadline, Acc),
            _ = roadrunner_bench_client:close(Conn),
            Final;
        {error, _} ->
            bump_err(Acc)
    end.

h2_multi_stream_loop(Conn, Deadline, Acc) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true ->
            Acc;
        false ->
            T0 = erlang:monotonic_time(nanosecond),
            case roadrunner_bench_client:request_many(Conn, ?MULTI_STREAM_BATCH) of
                {ok, Conn1} ->
                    T1 = erlang:monotonic_time(nanosecond),
                    %% Per-batch latency is divided across the
                    %% N streams so the bench's per-request mean /
                    %% percentiles are comparable to the
                    %% single-stream scenarios. Each stream gets
                    %% the same sample point — the batch's wall
                    %% time / N — which is fine for percentile
                    %% calculations on bursty workloads.
                    PerStream = (T1 - T0) div ?MULTI_STREAM_BATCH,
                    Acc1 = lists:foldl(
                        fun(_, A) -> bump_ok(A, PerStream, 0) end,
                        Acc,
                        lists:seq(1, ?MULTI_STREAM_BATCH)
                    ),
                    h2_multi_stream_loop(Conn1, Deadline, Acc1);
                {error, _} ->
                    bump_err(Acc)
            end
    end.

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
h2_request_shape(pipelined_h1) ->
    %% h2 already multiplexes — pipelining is an h1 wire concept
    %% with no analogue in h2 (use `multi_stream_h2` instead).
    io:format(standard_error,
        "error: --scenario pipelined_h1 is h1-only "
        "(use --protocol h1; for h2 multiplexing see multi_stream_h2)~n", []),
    halt(2);
h2_request_shape(slow_client) ->
    %% Drip-feed semantics target the h1 byte-stream parser; h2's
    %% framed wire format makes incremental delivery a different
    %% (and less interesting) test.
    io:format(standard_error,
        "error: --scenario slow_client is h1-only "
        "(use --protocol h1)~n", []),
    halt(2);
h2_request_shape(connection_storm) ->
    %% Per-request TLS handshake would dominate the measurement
    %% and obscure the connection-lifecycle question. h2's design
    %% point is keep-alive multiplexing — a "storm" of fresh h2
    %% conns is anti-h2 and not a real-world workload.
    io:format(standard_error,
        "error: --scenario connection_storm is h1-only "
        "(use --protocol h1)~n", []),
    halt(2);
h2_request_shape(mixed_workload) ->
    %% h2 mixed-path workload is a separate (and meaningful) test
    %% but needs varying per-request shapes through the bench
    %% client — out of scope for this scenario, which targets the
    %% h1 router under varied dispatch.
    io:format(standard_error,
        "error: --scenario mixed_workload is h1-only "
        "(use --protocol h1)~n", []),
    halt(2);
h2_request_shape(post_4kb_form) ->
    %% h2 form-decode is a meaningful follow-up but out of scope
    %% for this scenario, which targets the h1 body-read +
    %% qs:parse path under realistic body sizes.
    io:format(standard_error,
        "error: --scenario post_4kb_form is h1-only "
        "(use --protocol h1)~n", []),
    halt(2);
h2_request_shape(large_post_streaming) ->
    %% h2 has a different body-delivery model (DATA frames with
    %% per-stream WINDOW_UPDATE flow control); a 1 MB POST over
    %% h2 is a separate scenario worth adding later but the
    %% current focus is the h1 body-state machine.
    io:format(standard_error,
        "error: --scenario large_post_streaming is h1-only "
        "(use --protocol h1)~n", []),
    halt(2);
h2_request_shape(router_404_storm) ->
    %% Connection lifecycle is the dominant cost on this scenario;
    %% h2 conns + per-conn TLS handshake would obscure the
    %% router-miss cost we're trying to surface. h1-only.
    io:format(standard_error,
        "error: --scenario router_404_storm is h1-only "
        "(use --protocol h1)~n", []),
    halt(2);
h2_request_shape(varied_paths_router) ->
    %% h2 varied paths is meaningful but needs varying per-request
    %% shapes through the bench client — out of scope for this
    %% scenario.
    io:format(standard_error,
        "error: --scenario varied_paths_router is h1-only "
        "(use --protocol h1)~n", []),
    halt(2);
h2_request_shape(gzip_response) ->
    %% h2 has its own header compression (HPACK) and per-stream
    %% body compression is rarely combined with it. Out of scope
    %% for this scenario, which targets the h1 compress-middleware
    %% path specifically.
    io:format(standard_error,
        "error: --scenario gzip_response is h1-only "
        "(use --protocol h1)~n", []),
    halt(2);
h2_request_shape(backpressure_sustained) ->
    %% Connection limits over h2 are per-stream not per-conn; the
    %% h2 equivalent (multi_stream_h2 + low MAX_CONCURRENT_STREAMS)
    %% is a different scenario worth its own design. h1-only here.
    io:format(standard_error,
        "error: --scenario backpressure_sustained is h1-only "
        "(use --protocol h1)~n", []),
    halt(2);
h2_request_shape(server_sent_events) ->
    %% h2 SSE works (RFC 8441 + chunked-frame DATA) but the
    %% bench-client side hasn't been wired for streaming response
    %% reads. Out of scope for now.
    io:format(standard_error,
        "error: --scenario server_sent_events is h1-only "
        "(use --protocol h1)~n", []),
    halt(2);
h2_request_shape(expect_100_continue) ->
    %% h2 has no Expect: 100-continue equivalent (see RFC 9113 §8.5).
    %% h1-only scenario.
    io:format(standard_error,
        "error: --scenario expect_100_continue is h1-only "
        "(use --protocol h1)~n", []),
    halt(2);
h2_request_shape(large_keepalive_session) ->
    %% h2 has no per-conn-request count limit at the protocol layer
    %% (per-stream limits are different); h1-only scenario.
    io:format(standard_error,
        "error: --scenario large_keepalive_session is h1-only "
        "(use --protocol h1)~n", []),
    halt(2);
h2_request_shape(websocket_msg_throughput) ->
    %% RFC 8441 (h2 + WS) is out of scope for this scenario;
    %% bench-client side hasn't been wired for h2 WS frames.
    io:format(standard_error,
        "error: --scenario websocket_msg_throughput is h1-only "
        "(use --protocol h1)~n", []),
    halt(2);
h2_request_shape(url_with_qs) ->
    %% h2 path encodes the query string in the `:path` pseudo-
    %% header — same code-path on the server side. Worth a
    %% follow-up scenario but out of scope here, which targets
    %% the h1 URL-side qs:parse path specifically.
    io:format(standard_error,
        "error: --scenario url_with_qs is h1-only "
        "(use --protocol h1)~n", []),
    halt(2);
h2_request_shape(small_chunked_response) ->
    {~"GET", ~"/small", [], <<>>};
h2_request_shape(accept_storm_burst) ->
    %% h2 conns require TLS handshake which dominates burst cost;
    %% backlog under burst is an h1-flavored question.
    io:format(standard_error,
        "error: --scenario accept_storm_burst is h1-only "
        "(use --protocol h1)~n", []),
    halt(2);
h2_request_shape(head_method) ->
    {~"HEAD", ~"/large", [], <<>>};
h2_request_shape(etag_304) ->
    %% Bench's h2 client (`roadrunner_bench_client`) rejects non-200
    %% statuses on the request_many path — etag_304 returns 304
    %% intentionally. h2 support is a small follow-up but out of
    %% scope here.
    io:format(standard_error,
        "error: --scenario etag_304 is h1-only "
        "(use --protocol h1)~n", []),
    halt(2);
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
    "GET /streaming HTTP/1.1, 1 header, 4 × 4 KB chunks (router)";
scenario_request_summary(multi_stream_h2) ->
    "GET / over h2 with 16 multiplexed streams in flight per conn (handler)";
scenario_request_summary(pipelined_h1) ->
    "GET / HTTP/1.1, 4 requests pipelined per send, 7-byte response body (handler)";
scenario_request_summary(slow_client) ->
    "GET / HTTP/1.1, request drip-fed in 5 chunks @ 1 ms each, 7-byte response (handler)";
scenario_request_summary(connection_storm) ->
    "GET / HTTP/1.1 + Connection: close, fresh conn per request (handler)";
scenario_request_summary(mixed_workload) ->
    "Random pick per request from {GET /, GET /json, GET /large} on keep-alive (router)";
scenario_request_summary(post_4kb_form) ->
    "POST /form HTTP/1.1, 4 KB application/x-www-form-urlencoded body (router)";
scenario_request_summary(large_post_streaming) ->
    "POST /drain HTTP/1.1, 1 MB body, manual-mode 64 KB chunks (router)";
scenario_request_summary(router_404_storm) ->
    "GET /nope HTTP/1.1 + Connection: close, fresh conn per request, 404 expected (router)";
scenario_request_summary(varied_paths_router) ->
    "GET /api/v1/items/<NNNN> HTTP/1.1, round-robin across 100 routed paths (router)";
scenario_request_summary(gzip_response) ->
    "GET /gzip HTTP/1.1 + Accept-Encoding: gzip, 16 KB JSON in / ~200 B out (router + compress)";
scenario_request_summary(backpressure_sustained) ->
    "GET / HTTP/1.1, server capped at 50 concurrent slots, --clients exceeds cap (handler)";
scenario_request_summary(server_sent_events) ->
    "GET /sse HTTP/1.1, 100 SSE events per session then close (router; counts session, not events)";
scenario_request_summary(expect_100_continue) ->
    "POST /echo HTTP/1.1 + Expect: 100-continue, headers/100/body/200 cycle, 256-byte body (router)";
scenario_request_summary(large_keepalive_session) ->
    "GET / HTTP/1.1, server caps at 1000 reqs/conn, worker reconnects on close (handler)";
scenario_request_summary(websocket_msg_throughput) ->
    "WS upgrade then 1 KB masked text frame echoes in a tight loop (handler/router)";
scenario_request_summary(url_with_qs) ->
    "GET /qs?<6 pairs> HTTP/1.1, server parses URL query string, 1-byte response (router)";
scenario_request_summary(small_chunked_response) ->
    "GET /small over h2, 100 × 64-byte streamed chunks (router)";
scenario_request_summary(accept_storm_burst) ->
    "GET / HTTP/1.1 + Connection: close, --clients all connect at once, 1 req each (handler)";
scenario_request_summary(head_method) ->
    "HEAD /large HTTP/1.1, headers including Content-Length: 65536 but no body (router)";
scenario_request_summary(etag_304) ->
    "GET /etag HTTP/1.1 + If-None-Match: \"v1\", server returns 304 with no body (router)".

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
