#!/usr/bin/env escript
%%% Idle-pool memory harness for roadrunner.
%%%
%%% Usage:
%%%   ./scripts/idle_pool.escript [opts]
%%%   ./scripts/idle_pool.escript --help
%%%
%%% Opens `--conns` keep-alive connections, has every one of them serve a
%%% burst of `--burst` allocation-heavy requests, then holds them all open
%%% while only `--active` of them keep serving. Samples the server's
%%% resident set, `erlang:memory(total)` and `erlang:memory(processes)`
%%% across that window.
%%%
%%% This is the connection shape a closed-loop benchmark cannot produce.
%%% `bench.escript` and `stress.escript` keep every connection busy, so a
%%% connection process never sits on a heap it grew and stopped using,
%%% which is exactly where a GC policy decides how much memory a server
%%% holds. Pass `--spawn-opts` / `--hibernate-after` to compare policies
%%% and `--alloc` to split live blocks from carriers the allocator is
%%% holding but not using.
%%%
%%% With `--gap`, the active connections wait that long between requests
%%% instead of looping flat out, and the report adds request latency. Set
%%% it just above `--hibernate-after` to price what waking a hibernated
%%% connection costs the request that wakes it.
%%%
%%% The server runs in its own BEAM (OTP `peer`) so the memory numbers are
%%% the server's alone, read from /proc on Linux.

-mode(compile).

-define(LISTENER, roadrunner_idle_pool_listener).
-define(DEFAULT_CONNS, 2000).
-define(DEFAULT_ACTIVE, 50).
-define(DEFAULT_BURST, 10).
-define(DEFAULT_IDLE_S, 20).
-define(SAMPLE_INTERVAL_MS, 250).
%% Response length of `roadrunner_bench_alloc_handler`, which lets a
%% response be read without parsing headers. Keep in step with that module.
-define(BODY_LEN, 115).

%% Allocators worth naming in the breakdown; the rest are rounding error
%% for a server holding connection heaps and socket buffers.
-define(ALLOCATORS, [
    eheap_alloc,
    binary_alloc,
    ets_alloc,
    driver_alloc,
    sl_alloc,
    std_alloc,
    ll_alloc,
    fix_alloc,
    literal_alloc,
    temp_alloc
]).

main(Args) ->
    #{idle_s := IdleS} = Opts = parse_args(Args),
    ProjectDir = project_dir(),
    ok = setup_code_paths(ProjectDir),
    {Peer, Port, OsPid} = start_server(Opts),
    try
        print_header(Opts),
        Workers = open_pool(Port, Opts),
        AfterBurst = snapshot(Peer, OsPid),
        _ = [W ! go || W <- Workers],
        Samples = sample(Peer, OsPid, IdleS),
        %% Read the allocator while the pool is still open: once the
        %% workers stop, every conn process exits and takes its heap with
        %% it, so a breakdown taken after that describes an empty server.
        Alloc = collect_alloc(Peer, Opts),
        Results = [stop_worker(W) || W <- Workers],
        print_report(Opts, AfterBurst, Samples, Results),
        print_alloc(Alloc)
    after
        peer:stop(Peer)
    end.

%% ===========================================================================
%% Server
%% ===========================================================================

start_server(Opts) ->
    {ok, Peer, _Node} = peer:start_link(#{
        name => peer:random_name(),
        connection => standard_io,
        args => pa_args_for_peer() ++ vm_args(Opts),
        wait_boot => 10000
    }),
    {ok, _} = peer:call(Peer, application, ensure_all_started, [roadrunner]),
    {ok, _} = peer:call(Peer, roadrunner, start_listener, [?LISTENER, listener_opts(Opts)]),
    Port = peer:call(Peer, roadrunner_listener, port, [?LISTENER]),
    OsPid = peer:call(Peer, os, getpid, []),
    {Peer, Port, OsPid}.

listener_opts(Opts) ->
    Base = #{
        port => 0,
        routes => [{~"/alloc", roadrunner_bench_alloc_handler, undefined}],
        %% Long enough that the idle pool is never reaped mid-measurement.
        keep_alive_timeout => 600000,
        max_clients => 100000,
        max_keep_alive_requests => 100000000
    },
    with_hibernate(with_spawn_opts(Base, Opts), Opts).

with_spawn_opts(Base, #{spawn_opts := ""}) ->
    Base;
with_spawn_opts(Base, #{spawn_opts := Str}) ->
    Base#{handler_spawn => #{opts => parse_term(Str)}}.

with_hibernate(Base, #{hibernate_after := 0}) ->
    Base;
with_hibernate(Base, #{hibernate_after := Ms}) ->
    Base#{hibernate_after => Ms}.

vm_args(#{vm_args := ""}) ->
    [];
vm_args(#{vm_args := Str}) ->
    string:lexemes(Str, " ").

%% ===========================================================================
%% Connection pool
%% ===========================================================================

%% Every connection serves its burst before any of them go idle, so the
%% snapshot taken after this returns is the pool at its fullest.
open_pool(Port, #{conns := N, active := M, burst := K, gap_ms := Gap}) ->
    Parent = self(),
    Workers = [
        spawn_link(fun() -> worker(Parent, Port, I =< M, K, Gap) end)
     || I <- lists:seq(1, N)
    ],
    ok = await_ready(N),
    Workers.

worker(Parent, Port, Active, Burst, Gap) ->
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [
        binary, {active, false}, {packet, raw}, {nodelay, true}
    ]),
    ok = burst(Sock, Burst),
    Parent ! {ready, self()},
    receive
        go -> ok
    end,
    case Active of
        true -> active_loop(Sock, 0, [], Gap);
        false -> idle_loop(Sock)
    end.

burst(_Sock, 0) ->
    ok;
burst(Sock, K) ->
    ok = request(Sock),
    burst(Sock, K - 1).

%% Holds the socket open and does nothing else, which is the whole point:
%% the conn process keeps whatever heap its burst grew.
idle_loop(Sock) ->
    receive
        {stop, From} ->
            ok = gen_tcp:close(Sock),
            From ! {result, self(), 0, []}
    end.

%% Latencies are only collected in gap mode, where the request rate is low
%% enough for the full list to be cheap and the wake cost is what is being
%% measured. Flat out, the counter alone keeps the loop honest.
active_loop(Sock, Count, Lats, Gap) ->
    receive
        {stop, From} ->
            ok = gen_tcp:close(Sock),
            From ! {result, self(), Count, Lats}
    after Gap ->
        Started = erlang:monotonic_time(microsecond),
        ok = request(Sock),
        case Gap of
            0 ->
                active_loop(Sock, Count + 1, Lats, Gap);
            _ ->
                Elapsed = erlang:monotonic_time(microsecond) - Started,
                active_loop(Sock, Count + 1, [Elapsed | Lats], Gap)
        end
    end.

request(Sock) ->
    ok = gen_tcp:send(Sock, ~"GET /alloc HTTP/1.1\r\nHost: idle-pool\r\n\r\n"),
    recv_response(Sock, <<>>).

%% The handler's response length is fixed, so a response is complete once
%% the header terminator plus that many body bytes have arrived.
recv_response(Sock, Buf) ->
    case binary:match(Buf, ~"\r\n\r\n") of
        {Pos, 4} when byte_size(Buf) >= Pos + 4 + ?BODY_LEN ->
            ok;
        _ ->
            case gen_tcp:recv(Sock, 0, 30000) of
                {ok, More} ->
                    recv_response(Sock, <<Buf/binary, More/binary>>);
                {error, Reason} ->
                    io:format("error: connection failed mid-request: ~p~n", [Reason]),
                    halt(1)
            end
    end.

await_ready(0) ->
    ok;
await_ready(N) ->
    receive
        {ready, _} -> await_ready(N - 1)
    after 120000 ->
        io:format("error: ~p connections never finished their burst~n", [N]),
        halt(1)
    end.

stop_worker(W) ->
    W ! {stop, self()},
    receive
        {result, W, Count, Lats} -> {Count, Lats}
    after 30000 ->
        {0, []}
    end.

%% ===========================================================================
%% Sampling
%% ===========================================================================

sample(Peer, OsPid, Secs) ->
    Deadline = erlang:monotonic_time(millisecond) + Secs * 1000,
    sample_loop(Peer, OsPid, Deadline, []).

sample_loop(Peer, OsPid, Deadline, Acc) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true ->
            lists:reverse(Acc);
        false ->
            timer:sleep(?SAMPLE_INTERVAL_MS),
            sample_loop(Peer, OsPid, Deadline, [snapshot(Peer, OsPid) | Acc])
    end.

snapshot(Peer, OsPid) ->
    Mem = peer:call(Peer, erlang, memory, [], 10000),
    #{
        rss => rss_bytes(OsPid),
        beam => proplists:get_value(total, Mem, 0),
        procs => proplists:get_value(processes, Mem, 0)
    }.

rss_bytes(OsPid) ->
    case file:read_file("/proc/" ++ OsPid ++ "/status") of
        {ok, Bin} ->
            case re:run(Bin, ~"VmRSS:\\s+([0-9]+)\\s+kB", [{capture, [1], list}]) of
                {match, [Kb]} -> list_to_integer(Kb) * 1024;
                _ -> 0
            end;
        _ ->
            0
    end.

%% ===========================================================================
%% Allocator breakdown
%% ===========================================================================

%% `erlang:memory/0` reports blocks the emulator is using. The resident set
%% also covers carriers the allocator took from the OS and has not given
%% back, so a policy can look like it freed memory while RSS stays put.
%% This splits the two per allocator.
collect_alloc(_Peer, #{alloc := false}) ->
    undefined;
collect_alloc(Peer, #{alloc := true}) ->
    Rows = [{A, alloc_sizes(Peer, A)} || A <- ?ALLOCATORS],
    %% Carriers first in the tuple so the sort ranks by what the OS sees,
    %% biggest holder at the top.
    lists:reverse(lists:keysort(2, [{A, {Carriers, Blocks}} || {A, {Blocks, Carriers}} <- Rows])).

print_alloc(undefined) ->
    ok;
print_alloc(Sorted) ->
    io:format("~nallocator carriers (held from the OS) vs blocks (in use)~n"),
    io:format("  ~-16s ~12s ~12s ~12s~n", ["allocator", "carriers", "blocks", "retained"]),
    _ = [
        io:format("  ~-16s ~9w MB ~9w MB ~9w MB~n", [A, mb(C), mb(B), mb(C - B)])
     || {A, {C, B}} <- Sorted, C > 0
    ],
    {TotalC, TotalB} = lists:foldl(
        fun({_, {C, B}}, {AccC, AccB}) -> {AccC + C, AccB + B} end, {0, 0}, Sorted
    ),
    io:format(
        "  ~-16s ~9w MB ~9w MB ~9w MB~n",
        [total, mb(TotalC), mb(TotalB), mb(TotalC - TotalB)]
    ).

alloc_sizes(Peer, Alloc) ->
    case peer:call(Peer, erlang, system_info, [{allocator_sizes, Alloc}], 10000) of
        Instances when is_list(Instances) ->
            lists:foldl(fun sum_instance/2, {0, 0}, Instances);
        _ ->
            {0, 0}
    end.

sum_instance({instance, _N, Props}, Acc) ->
    lists:foldl(fun sum_carrier_set/2, Acc, Props);
sum_instance(_, Acc) ->
    Acc.

%% Any key carrying a `carriers_size` is a carrier set (mbcs, sbcs, and
%% the carrier pool on allocators that have one).
sum_carrier_set({_Kind, Props}, {Blocks, Carriers} = Acc) when is_list(Props) ->
    case lists:keyfind(carriers_size, 1, Props) of
        {carriers_size, Curr, _, _} ->
            {Blocks + blocks_size(Props), Carriers + Curr};
        _ ->
            Acc
    end;
sum_carrier_set(_, Acc) ->
    Acc.

blocks_size(Props) ->
    case lists:keyfind(blocks, 1, Props) of
        {blocks, Types} when is_list(Types) ->
            lists:foldl(
                fun({_Type, TypeProps}, Sum) ->
                    case lists:keyfind(size, 1, TypeProps) of
                        {size, Curr, _, _} -> Sum + Curr;
                        _ -> Sum
                    end
                end,
                0,
                Types
            );
        _ ->
            0
    end.

%% ===========================================================================
%% Report
%% ===========================================================================

print_header(Opts) ->
    #{
        conns := N,
        active := M,
        burst := K,
        idle_s := IdleS,
        gap_ms := Gap,
        spawn_opts := SpawnOpts,
        hibernate_after := Hib
    } = Opts,
    io:format("idle pool~n"),
    io:format("  conns      : ~w (~w active, ~w idle)~n", [N, M, N - M]),
    io:format("  burst      : ~w requests per conn before the idle window~n", [K]),
    io:format("  idle window: ~ws~n", [IdleS]),
    io:format("  active gap : ~w ms~n", [Gap]),
    io:format("  spawn opts : ~s~n", [
        case SpawnOpts of
            "" -> "listener default";
            S -> S
        end
    ]),
    io:format("  hibernate  : ~s~n", [
        case Hib of
            0 -> "off";
            Ms -> integer_to_list(Ms) ++ " ms"
        end
    ]).

print_report(#{idle_s := IdleS, gap_ms := Gap}, AfterBurst, Samples, Results) ->
    #{rss := Rss0, beam := Beam0, procs := Procs0} = AfterBurst,
    Rss = [R || #{rss := R} <- Samples],
    Beam = [B || #{beam := B} <- Samples],
    Procs = [P || #{procs := P} <- Samples],
    Count = lists:sum([C || {C, _} <- Results]),
    io:format("~nmemory~n"),
    io:format("  after burst: rss ~w MB  beam ~w MB  procs ~w MB~n", [
        mb(Rss0), mb(Beam0), mb(Procs0)
    ]),
    io:format("  idle window (min/median/max over ~w samples)~n", [length(Samples)]),
    print_axis("rss", Rss),
    print_axis("beam", Beam),
    print_axis("procs", Procs),
    io:format("~nactive set~n"),
    io:format("  ~w requests, ~w req/s over the idle window~n", [Count, Count div max(IdleS, 1)]),
    case Gap of
        0 ->
            ok;
        _ ->
            Lats = lists:append([L || {_, L} <- Results]),
            print_latency(Lats)
    end.

print_axis(Label, Values) ->
    io:format("    ~-6s ~w / ~w / ~w MB~n", [
        Label, mb(lists:min(Values)), mb(median(Values)), mb(lists:max(Values))
    ]).

print_latency([]) ->
    ok;
print_latency(Lats) ->
    Sorted = lists:sort(Lats),
    io:format("  latency: mean ~s  p50 ~s  p99 ~s  max ~s~n", [
        us(lists:sum(Sorted) div length(Sorted)),
        us(percentile(Sorted, 50)),
        us(percentile(Sorted, 99)),
        us(lists:last(Sorted))
    ]).

percentile(Sorted, P) ->
    Idx = max(1, round(length(Sorted) * P / 100)),
    lists:nth(min(Idx, length(Sorted)), Sorted).

median(Values) ->
    percentile(lists:sort(Values), 50).

us(Us) when Us < 1000 ->
    integer_to_list(Us) ++ " us";
us(Us) ->
    io_lib:format("~.2f ms", [Us / 1000]).

mb(Bytes) ->
    Bytes div (1024 * 1024).

%% ===========================================================================
%% CLI
%% ===========================================================================

parse_args(Argv) ->
    Cli = cli(),
    ProgOpts = #{progname => "idle_pool.escript"},
    case argparse:parse(Argv, Cli, ProgOpts) of
        {ok, Parsed, _Path, _Cmd} ->
            Parsed;
        {error, Reason} ->
            io:format(standard_error, "~s~n~n", [argparse:format_error(Reason)]),
            io:format(standard_error, "~s~n", [argparse:help(Cli, ProgOpts)]),
            halt(2)
    end.

cli() ->
    #{
        help => "Memory held by a pool of mostly-idle keep-alive connections.",
        arguments => [
            #{
                name => conns,
                long => "-conns",
                type => {integer, [{min, 1}]},
                default => ?DEFAULT_CONNS,
                help => "Connections to open and hold for the whole run."
            },
            #{
                name => active,
                long => "-active",
                type => {integer, [{min, 0}]},
                default => ?DEFAULT_ACTIVE,
                help => "How many of them keep serving during the idle window."
            },
            #{
                name => burst,
                long => "-burst",
                type => {integer, [{min, 0}]},
                default => ?DEFAULT_BURST,
                help =>
                    "Requests every connection serves before the window, so each "
                    "conn process has grown a heap."
            },
            #{
                name => idle_s,
                long => "-idle",
                type => {integer, [{min, 1}]},
                default => ?DEFAULT_IDLE_S,
                help => "Seconds to hold the pool open and sample memory."
            },
            #{
                name => gap_ms,
                long => "-gap",
                type => {integer, [{min, 0}]},
                default => 0,
                help =>
                    """
                    Milliseconds the active connections wait between requests.
                    0 runs them flat out. Above `--hibernate-after` it prices
                    what waking a hibernated conn costs, and the report then
                    carries request latency.
                    """
            },
            #{
                name => spawn_opts,
                long => "-spawn-opts",
                type => string,
                default => "",
                help =>
                    """
                    `handler_spawn` opts as an Erlang term, e.g.
                    "[{fullsweep_after, 65535}]" for the emulator's
                    generational policy. Empty keeps the listener default.
                    """
            },
            #{
                name => hibernate_after,
                long => "-hibernate-after",
                type => {integer, [{min, 0}]},
                default => 0,
                help => "Listener `hibernate_after` in ms. 0 leaves it off."
            },
            #{
                name => alloc,
                long => "-alloc",
                type => boolean,
                default => false,
                help =>
                    "Print per-allocator carriers vs blocks, which splits memory "
                    "the emulator is using from memory the allocator is holding."
            },
            #{
                name => vm_args,
                long => "-vm-args",
                type => string,
                default => "",
                help => "Extra emulator flags for the server BEAM, space separated."
            }
        ]
    }.

parse_term(Str) ->
    {ok, Tokens, _} = erl_scan:string(Str ++ "."),
    {ok, Term} = erl_parse:parse_term(Tokens),
    Term.

%% ===========================================================================
%% Paths
%% ===========================================================================

pa_args_for_peer() ->
    Paths = [P || P <- code:get_path(), filelib:is_dir(P)],
    lists:foldr(fun(P, Acc) -> ["-pa", P | Acc] end, [], Paths).

setup_code_paths(BaseDir) ->
    LibDir = filename:join([BaseDir, "_build", "test", "lib"]),
    case filelib:is_dir(LibDir) of
        false ->
            io:format("error: no compiled libs found; run 'rebar3 as test compile' first~n"),
            halt(1);
        true ->
            {ok, Libs} = file:list_dir(LibDir),
            _ = [
                code:add_pathz(Dir)
             || Lib <- Libs,
                Sub <- ["ebin", "test"],
                Dir <- [filename:join([LibDir, Lib, Sub])],
                filelib:is_dir(Dir)
            ],
            ok
    end.

project_dir() ->
    filename:dirname(filename:absname(filename:dirname(escript:script_name()))).
