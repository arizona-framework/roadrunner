#!/usr/bin/env escript
%%% Diagnostic probe for the h2-loadgen 41 ms artifact (Phase B1 of the
%%% bench-loadgen plan).
%%%
%%% Two modes:
%%%   --mode local  (default): listener + driver in the SAME BEAM.
%%%   --mode peer            : listener in a peer BEAM, driver in the
%%%                            parent (same shape as bench.escript).
%%%
%%% Both modes drive N sequential requests over a single TLS h2 connection
%%% using the in-tree codec (`roadrunner_http2_frame` +
%%% `roadrunner_http2_hpack`). Reports per-request latency in microseconds.
%%%
%%% Expected (from previous investigation):
%%%   --mode local : ~50 µs / req after warmup
%%%   --mode peer  : ~41 ms / req (the artifact this probe is here to
%%%                                isolate)
%%%
%%% Throwaway — delete after B1's root-cause analysis lands.

-mode(compile).

-define(REQS, 50).

main(Args) ->
    Mode = parse_mode(Args),
    setup_code_paths(),
    {Pid, Port} = start_listener(Mode),
    Latencies = run_probe(Port),
    teardown(Mode, Pid),
    print_summary(Mode, Latencies).

parse_mode(["--mode", "peer" | _]) -> peer;
parse_mode(["--mode", "local" | _]) -> local;
parse_mode([]) -> local;
parse_mode(_) ->
    io:format("usage: h2_probe.escript [--mode local|peer]~n"),
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
            [Found | _] -> Found;
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
    ok.

start_listener(local) ->
    application:ensure_all_started(ssl),
    application:ensure_all_started(roadrunner),
    CertDir = make_cert(),
    {ok, _} = roadrunner:start_listener(probe_listener, listener_opts(CertDir)),
    Port = roadrunner_listener:port(probe_listener),
    {undefined, Port};
start_listener(peer) ->
    {ok, Peer, _Node} = peer:start_link(#{
        name => peer:random_name(),
        connection => standard_io,
        args => pa_args_for_peer(),
        wait_boot => 10000
    }),
    {ok, _} = peer:call(Peer, application, ensure_all_started, [ssl]),
    {ok, _} = peer:call(Peer, application, ensure_all_started, [roadrunner]),
    CertDir = make_cert(),
    {ok, _} = peer:call(Peer, roadrunner, start_listener, [
        probe_listener, listener_opts(CertDir)
    ]),
    Port = peer:call(Peer, roadrunner_listener, port, [probe_listener]),
    {Peer, Port}.

teardown(local, _) ->
    catch roadrunner:stop_listener(probe_listener),
    ok;
teardown(peer, Peer) ->
    catch peer:stop(Peer),
    ok.

listener_opts(CertDir) ->
    #{
        port => 0,
        protocols => [http1, http2],
        tls => [
            {certfile, CertDir ++ "/cert.pem"},
            {keyfile, CertDir ++ "/key.pem"}
        ],
        routes => roadrunner_hello_handler,
        keep_alive_timeout => 60000,
        max_clients => 100000,
        max_keep_alive_requests => 1000000
    }.

make_cert() ->
    Dir = string:trim(os:cmd("mktemp -d")),
    Cmd = lists:flatten(io_lib:format(
        "openssl req -x509 -newkey rsa:2048 -nodes -days 1 "
        "-keyout ~s/key.pem -out ~s/cert.pem -subj /CN=localhost "
        "2>/dev/null",
        [Dir, Dir]
    )),
    [] = os:cmd(Cmd),
    Dir.

pa_args_for_peer() ->
    Paths = [P || P <- code:get_path(), filelib:is_dir(P)],
    lists:foldr(fun(P, Acc) -> ["-pa", P | Acc] end, [], Paths).

run_probe(Port) ->
    {ok, Sock} = ssl:connect("127.0.0.1", Port, [
        binary, {active, false}, {nodelay, true},
        {alpn_advertised_protocols, [~"h2"]},
        {verify, verify_none},
        {server_name_indication, disable}
    ], 5000),
    Preface = ~"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n",
    EmptySettings = <<0:24, 4, 0, 0:32>>,
    ok = ssl:send(Sock, [Preface, EmptySettings]),
    Buf = handshake(Sock, <<>>, false, false),
    Enc = roadrunner_http2_hpack:new_encoder(4096),
    {Block, _} = roadrunner_http2_hpack:encode(
        [
            {~":method", ~"GET"},
            {~":scheme", ~"https"},
            {~":authority", ~"localhost"},
            {~":path", ~"/"}
        ],
        Enc
    ),
    BlockBin = iolist_to_binary(Block),
    Latencies = loop(Sock, BlockBin, Buf, 1, ?REQS, []),
    catch ssl:close(Sock),
    Latencies.

handshake(_Sock, Buf, true, true) ->
    Buf;
handshake(Sock, Buf, GotS, GotA) ->
    case roadrunner_http2_frame:parse(Buf, 16384) of
        {ok, {settings, 1, _}, R} ->
            handshake(Sock, R, GotS, true);
        {ok, {settings, 0, _}, R} ->
            ok = ssl:send(Sock, <<0:24, 4, 1, 0:32>>),
            handshake(Sock, R, true, GotA);
        {ok, _, R} ->
            handshake(Sock, R, GotS, GotA);
        {more, _} ->
            {ok, More} = ssl:recv(Sock, 0, 5000),
            handshake(Sock, <<Buf/binary, More/binary>>, GotS, GotA)
    end.

loop(_Sock, _BlockBin, _Buf, _Sid, 0, Acc) ->
    Acc;
loop(Sock, BlockBin, Buf, Sid, N, Acc) ->
    Hf = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, Sid, 16#04 bor 16#01, undefined, BlockBin})
    ),
    T0 = erlang:monotonic_time(microsecond),
    ok = ssl:send(Sock, Hf),
    Buf1 = consume(Sock, Buf, Sid, false, false),
    T1 = erlang:monotonic_time(microsecond),
    loop(Sock, BlockBin, Buf1, Sid + 2, N - 1, [T1 - T0 | Acc]).

consume(_Sock, Buf, _Sid, true, true) ->
    Buf;
consume(Sock, Buf, Sid, GotH, GotF) ->
    case roadrunner_http2_frame:parse(Buf, 16384) of
        {ok, {headers, Sid, F, _, _}, R} ->
            EndStream = (F band 16#01) =/= 0,
            consume(Sock, R, Sid, true, GotF orelse EndStream);
        {ok, {data, Sid, F, _}, R} ->
            EndStream = (F band 16#01) =/= 0,
            consume(Sock, R, Sid, GotH, GotF orelse EndStream);
        {ok, _Other, R} ->
            consume(Sock, R, Sid, GotH, GotF);
        {more, _} ->
            {ok, More} = ssl:recv(Sock, 0, 5000),
            consume(Sock, <<Buf/binary, More/binary>>, Sid, GotH, GotF)
    end.

print_summary(Mode, Latencies) ->
    Sorted = lists:sort(Latencies),
    N = length(Sorted),
    [First | _] = Latencies,
    P50 = lists:nth(max(1, round(0.5 * N)), Sorted),
    P95 = lists:nth(max(1, round(0.95 * N)), Sorted),
    P99 = lists:nth(max(1, round(0.99 * N)), Sorted),
    Max = lists:last(Sorted),
    io:format("~nh2 probe — mode=~p, ~p sequential reqs over single conn~n", [Mode, N]),
    io:format(
        "  first: ~10s  p50: ~10s  p95: ~10s  p99: ~10s  max: ~10s~n",
        [fmt_us(First), fmt_us(P50), fmt_us(P95), fmt_us(P99), fmt_us(Max)]
    ).

fmt_us(N) when N < 1000 ->
    io_lib:format("~B us", [N]);
fmt_us(N) when N < 1000000 ->
    io_lib:format("~.1f ms", [N / 1000]);
fmt_us(N) ->
    io_lib:format("~.2f s", [N / 1000000]).
