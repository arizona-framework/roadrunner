-module(roadrunner_preload_SUITE).
-moduledoc """
A listener loads its request path in the background once it is up, so the
first requests on a fresh node don't load modules one at a time.

Each case starts a fresh node, where nothing an earlier test ran is loaded,
starts a listener there, waits for the preload, serves one request, and
checks that the request loaded no roadrunner module the preload missed.
""".

-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0]).
-export([http1/1, http2_cleartext/1, http2_tls/1, http3/1]).
-export([wait_for_preload/1]).

suite() ->
    [{timetrap, {seconds, 60}}].

all() ->
    [http1, http2_cleartext, http2_tls, http3].

http1(_Config) ->
    check(#{}, h1).

http2_cleartext(_Config) ->
    check(#{protocols => [http2]}, h2c).

http2_tls(_Config) ->
    check(#{protocols => [http1, http2], tls => roadrunner_test_certs:server_opts()}, h2).

http3(_Config) ->
    check(#{protocols => [http3], tls => roadrunner_test_certs:server_opts()}, h3).

%% --- helpers ---

check(Opts, Wire) ->
    {ok, Peer, _Node} = peer:start_link(#{
        connection => standard_io,
        args => lists:append([["-pa", Dir] || Dir <- code:get_path()])
    }),
    {ok, _} = peer:call(Peer, application, ensure_all_started, [roadrunner]),
    {ok, _} = peer:call(Peer, roadrunner, start_listener, [
        preload, Opts#{port => 0, routes => [{~"/", roadrunner_hello_handler}]}
    ]),
    ok = peer:call(Peer, ?MODULE, wait_for_preload, [preload]),
    Port = peer:call(Peer, roadrunner_listener, port, [preload]),
    Before = loaded(Peer),
    {ok, Conn} = roadrunner_bench_client:open(~"127.0.0.1", Port, Wire),
    {ok, 200, _Headers, _Body, Conn1} =
        roadrunner_bench_client:request(Conn, ~"GET", ~"/", [], <<>>),
    Lazy = [M || M <- ordsets:subtract(loaded(Peer), Before), preloadable(M)],
    _ = roadrunner_bench_client:close(Conn1),
    ok = peer:stop(Peer),
    ?assertEqual([], Lazy).

%% Runs on the peer: the preload process exits once it has loaded everything.
wait_for_preload(Name) ->
    case [P || P <- processes(), proc_lib:get_label(P) =:= {roadrunner_preload, Name}] of
        [] ->
            ok;
        [Pid] ->
            Ref = monitor(process, Pid),
            receive
                {'DOWN', Ref, process, Pid, _Reason} -> ok
            end
    end.

loaded(Peer) ->
    ordsets:from_list([M || {M, _File} <- peer:call(Peer, code, all_loaded, [])]).

%% roadrunner's own modules, the route's handler, and `crypto` (request ids).
preloadable(crypto) ->
    true;
preloadable(Module) ->
    lists:prefix("roadrunner", atom_to_list(Module)).
