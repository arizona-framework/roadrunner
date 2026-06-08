-module(roadrunner_quic_listener_sup_SUITE).
-moduledoc """
Integration tests for the native QUIC listener pool.

A CT suite: the load-bearing case drives the native QUIC client through a real
handshake against a multi-listener SO_REUSEPORT pool, and the lifecycle cases
(get_listeners, get_port, stop, bind failure) need live supervisor + listener
processes. The pure pool-options translation is unit-tested in
`roadrunner_quic_listener_sup_tests`.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1]).
-export([
    native_client_handshakes_through_pool/1,
    single_listener_pool_serves/1,
    every_listener_answers_get_port/1,
    bind_failure_is_reported/1,
    stop_brings_the_pool_down/1
]).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        native_client_handshakes_through_pool,
        single_listener_pool_serves,
        every_listener_answers_get_port,
        bind_failure_is_reported,
        stop_brings_the_pool_down
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(crypto),
    {ok, _} = application:ensure_all_started(ssl),
    %% The default `pg` scope hosts a connection owner's drain group; start it
    %% unlinked so it outlives this transient process.
    ok = ensure_pg_started(),
    Config.

end_per_suite(_Config) ->
    ok.

%% The native client completes a real handshake through a multi-listener
%% reuseport pool (pool_size 2 -> 3 listeners sharing one registry). The
%% handler's owner is reported so it can be torn down with the case.
native_client_handshakes_through_pool(_Config) ->
    Test = self(),
    Handler = fun(_ConnPid) ->
        Owner = spawn(fun drain/0),
        Test ! {owner, Owner},
        {ok, Owner}
    end,
    {Sup, Port} = start_pool(2, Handler),
    ?assertEqual(3, length(roadrunner_quic_listener_sup:get_listeners(Sup))),
    Result =
        case roadrunner_quic_test_conn:connect({127, 0, 0, 1}, Port) of
            {ok, Conn} ->
                ok = roadrunner_quic_test_conn:close(Conn),
                ok;
            {error, Reason} ->
                {error, Reason}
        end,
    receive
        {owner, Owner} -> exit(Owner, kill)
    after 0 -> ok
    end,
    stop_pool(Sup),
    ?assertEqual(ok, Result).

%% A single-listener pool (pool_size 0, no reuseport) binds an ephemeral port
%% and answers get_port via its one listener.
single_listener_pool_serves(_Config) ->
    {Sup, Port} = start_single_pool(),
    ?assertEqual(1, length(roadrunner_quic_listener_sup:get_listeners(Sup))),
    [Listener] = roadrunner_quic_listener_sup:get_listeners(Sup),
    ?assertEqual(Port, roadrunner_quic_listener:get_port(Listener)),
    stop_pool(Sup).

%% Every listener in the pool answers the same bound port (reuseport shares it),
%% so taking the head of get_listeners for get_port is safe.
every_listener_answers_get_port(_Config) ->
    {Sup, Port} = start_pool(2, drain_handler()),
    Listeners = roadrunner_quic_listener_sup:get_listeners(Sup),
    [?assertEqual(Port, roadrunner_quic_listener:get_port(L)) || L <- Listeners],
    stop_pool(Sup).

%% A bind onto a port already held surfaces synchronously as {error, _} from
%% start_link (a child's bind failure fails the supervisor start). start_link
%% links the supervisor to the caller, so the failed-start exit must be trapped
%% to surface as a return rather than felling the caller, exactly as
%% roadrunner_listener:start_quic_pool does.
bind_failure_is_reported(_Config) ->
    {ok, Blocker} = gen_udp:open(0, [binary, {active, false}]),
    {ok, {_Ip, Port}} = inet:sockname(Blocker),
    Old = process_flag(trap_exit, true),
    Result = roadrunner_quic_listener_sup:start_link(Port, pool_opts(0, drain_handler())),
    receive
        {'EXIT', _, _} -> ok
    after 200 -> ok
    end,
    _ = process_flag(trap_exit, Old),
    ?assertMatch({error, _}, Result),
    ok = gen_udp:close(Blocker).

%% stop/1 brings the (multi-listener) pool down synchronously, closing every
%% reuseport socket: it returns with the supervisor gone, and a fresh plain
%% (non-reuseport) bind on the shared port then succeeds, proving all of the
%% pool's sockets were closed, not just one.
stop_brings_the_pool_down(_Config) ->
    {Sup, Port} = start_pool(2, drain_handler()),
    ok = roadrunner_quic_listener_sup:stop(Sup),
    ?assertNot(is_process_alive(Sup)),
    {ok, Reclaim} = gen_udp:open(Port, [binary, {active, false}]),
    ok = gen_udp:close(Reclaim).

%% =============================================================================
%% Helpers
%% =============================================================================

%% A multi-listener pool needs a concrete shared port: pin a free one with a
%% reuseport probe, start the pool on it, then drop the probe (the listeners
%% keep the port via reuseport).
start_pool(PoolSize, Handler) ->
    {ok, Probe} = gen_udp:open(0, [{reuseport, true}]),
    {ok, Port} = inet:port(Probe),
    {ok, Sup} = roadrunner_quic_listener_sup:start_link(Port, pool_opts(PoolSize, Handler)),
    ok = gen_udp:close(Probe),
    {Sup, Port}.

%% A single-listener pool binds an ephemeral port directly (no reuseport).
start_single_pool() ->
    {ok, Sup} = roadrunner_quic_listener_sup:start_link(0, pool_opts(0, drain_handler())),
    [Listener] = roadrunner_quic_listener_sup:get_listeners(Sup),
    {Sup, roadrunner_quic_listener:get_port(Listener)}.

%% stop/1 unlinks internally, so the owner just calls it.
stop_pool(Sup) ->
    ok = roadrunner_quic_listener_sup:stop(Sup).

pool_opts(PoolSize, Handler) ->
    {Cert, Chain, Key} = cert_key(),
    #{
        cert => Cert,
        key => Key,
        cert_chain => Chain,
        alpn => [~"h3"],
        max_streams_bidi => 100,
        connection_handler => Handler,
        pool_size => PoolSize
    }.

drain_handler() ->
    fun(_ConnPid) -> {ok, spawn(fun drain/0)} end.

drain() ->
    receive
        _ -> drain()
    end.

cert_key() ->
    Opts = roadrunner_test_certs:server_opts(),
    {cert, CertDer} = lists:keyfind(cert, 1, Opts),
    {key, {KeyType, KeyDer}} = lists:keyfind(key, 1, Opts),
    {CertDer, [], public_key:der_decode(KeyType, KeyDer)}.

ensure_pg_started() ->
    case whereis(pg) of
        undefined ->
            case pg:start_link() of
                {ok, Pid} ->
                    _ = unlink(Pid),
                    ok;
                {error, {already_started, _}} ->
                    ok
            end;
        _ ->
            ok
    end.
