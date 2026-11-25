-module(roadrunner_listen_sockets_SUITE).
-moduledoc """
Listeners that bind several listen sockets to one port
(`num_listen_sockets`): every socket is served, they share one port, a
second listener on the port still fails to start, a drain closes every
one, a start that fails part way holds none of them, TLS listeners bind
one by default, and the sockets share the port on the `socket` backend
too.
""".

-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_testcase/2, end_per_testcase/2]).
-export([
    every_socket_is_served/1,
    sockets_share_one_port/1,
    a_held_port_is_refused/1,
    a_fixed_port_restarts_over_time_wait/1,
    a_drain_closes_every_socket/1,
    tls_binds_one_socket_by_default/1,
    the_socket_backend_shares_the_port/1,
    a_failed_first_bind_fails_the_start/1,
    a_failed_bind_closes_the_bound_sockets/1
]).
%% Run inside the peer node of `a_failed_bind_closes_the_bound_sockets/1`.
-export([start_with_a_full_port_table/0]).

suite() ->
    [{timetrap, {seconds, 60}}].

%% The backend test switches the node's default `inet_backend`; the switch
%% is undone here, so a failure in it cannot leave the backend changed for
%% the cases and suites that run after it.
init_per_testcase(the_socket_backend_shares_the_port, Config) ->
    [
        {inet_backend, persistent_term:get({kernel, inet_backend}, inet)},
        {inet_backend_env, application:get_env(kernel, inet_backend)}
        | Config
    ];
init_per_testcase(_Case, Config) ->
    Config.

end_per_testcase(the_socket_backend_shares_the_port, Config) ->
    ok = persistent_term:put({kernel, inet_backend}, proplists:get_value(inet_backend, Config)),
    restore_env(proplists:get_value(inet_backend_env, Config));
end_per_testcase(_Case, _Config) ->
    ok.

all() ->
    [
        every_socket_is_served,
        sockets_share_one_port,
        a_held_port_is_refused,
        a_fixed_port_restarts_over_time_wait,
        a_drain_closes_every_socket,
        tls_binds_one_socket_by_default,
        the_socket_backend_shares_the_port,
        a_failed_first_bind_fails_the_start,
        a_failed_bind_closes_the_bound_sockets
    ].

every_socket_is_served(_Config) ->
    %% Three sockets, one acceptor asked for: each socket gets one, and the
    %% kernel hands each socket a share of the new connections, so a socket
    %% nobody accepts on would leave some of these requests unanswered.
    {ok, Pid} = roadrunner_listener:start_link(
        rr_sockets_a, opts(#{num_acceptors => 1, num_listen_sockets => 3})
    ),
    ?assertEqual(3, length(listen_sockets(Pid))),
    ?assertEqual(3, length(acceptors(Pid))),
    Port = roadrunner_listener:port(rr_sockets_a),
    _ = [?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, request(Port)) || _ <- lists:seq(1, 30)],
    ok = roadrunner_listener:stop(rr_sockets_a).

sockets_share_one_port(_Config) ->
    %% Port 0: the first socket gets a free port and the others bind that
    %% one, instead of each getting a port of its own.
    {ok, Pid} = roadrunner_listener:start_link(rr_sockets_a, opts(#{num_listen_sockets => 3})),
    Port = roadrunner_listener:port(rr_sockets_a),
    ?assertEqual(
        [{ok, Port}, {ok, Port}, {ok, Port}],
        [roadrunner_transport:port(S) || S <- listen_sockets(Pid)]
    ),
    ok = roadrunner_listener:stop(rr_sockets_a).

a_held_port_is_refused(_Config) ->
    %% Sockets that share a port with `SO_REUSEPORT` would let another
    %% socket that sets it join them. Another listener on the port fails to
    %% start instead, whatever its socket count, as it does against one.
    {ok, _} = roadrunner_listener:start_link(rr_sockets_a, opts(#{num_listen_sockets => 2})),
    Port = roadrunner_listener:port(rr_sockets_a),
    process_flag(trap_exit, true),
    _ = [
        ?assertEqual(
            {error, {listen_failed, eaddrinuse}},
            roadrunner_listener:start_link(
                rr_sockets_b, opts(#{port => Port, num_listen_sockets => Count})
            )
        )
     || Count <- [1, 2, auto]
    ],
    ok = roadrunner_listener:stop(rr_sockets_a).

a_fixed_port_restarts_over_time_wait(_Config) ->
    %% Connections the server closed first wait out TIME_WAIT on its side.
    %% They hold the port, but a listener starting again on it must not
    %% take them for another listener: the check, like the sockets, sets
    %% `SO_REUSEADDR`.
    Port = free_port(),
    {ok, _} = roadrunner_listener:start_link(
        rr_sockets_a, opts(#{port => Port, num_listen_sockets => 2})
    ),
    _ = [?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, request(Port)) || _ <- lists:seq(1, 5)],
    ok = roadrunner_listener:stop(rr_sockets_a),
    {ok, _} = roadrunner_listener:start_link(
        rr_sockets_a, opts(#{port => Port, num_listen_sockets => 2})
    ),
    ?assertEqual(Port, roadrunner_listener:port(rr_sockets_a)),
    ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, request(Port)),
    ok = roadrunner_listener:stop(rr_sockets_a).

a_drain_closes_every_socket(_Config) ->
    %% While a drain waits on a connection, every listen socket is closed:
    %% one left open would take some of these connections in. Each acceptor
    %% ends once its socket is closed, which says when to try.
    {ok, Pid} = roadrunner_listener:start_link(rr_sockets_a, #{
        port => 0,
        num_acceptors => 1,
        num_listen_sockets => 3,
        routes => [{~"/sleep", roadrunner_drain_ignore_handler, #{}}]
    }),
    Port = roadrunner_listener:port(rr_sockets_a),
    {ok, Held} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
    ok = gen_tcp:send(Held, ~"GET /sleep HTTP/1.1\r\nHost: x\r\n\r\n"),
    ok = wait_for(Held, ~"started", <<>>),
    Monitors = [monitor(process, A) || A <- acceptors(Pid)],
    ?assertEqual(3, length(Monitors)),
    Self = self(),
    Drainer = spawn_link(fun() ->
        Self ! {drained, roadrunner_listener:drain(rr_sockets_a, 2000)}
    end),
    %% The first acceptor to end says the drain has begun; the status call
    %% after it is answered once the drain has closed what it closes.
    First =
        receive
            {'DOWN', FirstRef, process, _, normal} -> FirstRef
        end,
    ?assertEqual(draining, roadrunner_listener:status(rr_sockets_a)),
    Results = [
        gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000)
     || _ <- lists:seq(1, 20)
    ],
    ?assertEqual([], [S || {ok, S} <- Results]),
    receive
        {drained, Drained} -> ?assertMatch({timeout, _}, Drained)
    end,
    _ = [
        receive
            {'DOWN', Ref, process, _, normal} -> ok
        end
     || Ref <- Monitors -- [First]
    ],
    true = unlink(Drainer),
    ok = gen_tcp:close(Held).

tls_binds_one_socket_by_default(_Config) ->
    %% OTP keeps a TLS listener's session cache and TLS 1.3 ticket keys per
    %% listen socket, so `auto` binds one; a count is still taken as given.
    Tls = #{tls => roadrunner_test_certs:server_opts()},
    {ok, One} = roadrunner_listener:start_link(rr_sockets_a, opts(Tls)),
    ?assertEqual(1, length(listen_sockets(One))),
    {ok, Two} = roadrunner_listener:start_link(rr_sockets_b, opts(Tls#{num_listen_sockets => 2})),
    ?assertEqual(2, length(listen_sockets(Two))),
    ok = roadrunner_listener:stop(rr_sockets_b),
    ok = roadrunner_listener:stop(rr_sockets_a).

the_socket_backend_shares_the_port(_Config) ->
    %% `SO_REUSEPORT` through `reuseport`, which the `socket` backend takes
    %% as the `inet` one does, so a node running `gen_tcp` on it still
    %% starts the listener and serves every socket.
    ok = persistent_term:put({kernel, inet_backend}, socket),
    ok = application:set_env(kernel, inet_backend, socket),
    process_flag(trap_exit, true),
    {ok, Pid} = roadrunner_listener:start_link(
        rr_sockets_a, opts(#{num_acceptors => 1, num_listen_sockets => 2})
    ),
    ?assertEqual(2, length(listen_sockets(Pid))),
    Port = roadrunner_listener:port(rr_sockets_a),
    _ = [?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, request(Port)) || _ <- lists:seq(1, 10)],
    ok = roadrunner_listener:stop(rr_sockets_a).

a_failed_first_bind_fails_the_start(_Config) ->
    %% A first socket that cannot bind fails the start with its reason, as
    %% one socket does. 192.0.2.1 is a documentation address (RFC 5737)
    %% that no host has.
    process_flag(trap_exit, true),
    ?assertEqual(
        {error, {listen_failed, eaddrnotavail}},
        roadrunner_listener:start_link(
            rr_sockets_a, opts(#{ip => {192, 0, 2, 1}, num_listen_sockets => 2})
        )
    ).

a_failed_bind_closes_the_bound_sockets(_Config) ->
    %% A node whose port table has room for one more port: the first socket
    %% binds, the second cannot. The start fails with that reason, as a
    %% single socket's would, and leaves neither the socket it bound nor
    %% its routes behind.
    PaArgs = lists:append([["-pa", Dir] || Dir <- code:get_path()]),
    {ok, Peer, _Node} = peer:start_link(#{
        connection => standard_io, args => ["+Q", "1024" | PaArgs]
    }),
    try
        ?assertEqual(
            {{error, {listen_failed, system_limit}}, ports_released, routes_erased},
            peer:call(Peer, ?MODULE, start_with_a_full_port_table, [])
        )
    after
        peer:stop(Peer)
    end.

start_with_a_full_port_table() ->
    {ok, _} = application:ensure_all_started(roadrunner),
    _ = process_flag(trap_exit, true),
    %% Inet driver ports that open no socket: a port slot each and no file
    %% descriptor.
    Free = erlang:system_info(port_limit) - erlang:system_info(port_count),
    _ = [erlang:open_port({spawn_driver, "udp_inet"}, [binary]) || _ <- lists:seq(1, Free - 1)],
    Before = erlang:system_info(port_count),
    Result = roadrunner_listener:start_link(
        rr_sockets_full, opts(#{num_acceptors => 1, num_listen_sockets => 3})
    ),
    Ports =
        case erlang:system_info(port_count) of
            Before -> ports_released;
            Other -> {ports_left, Other - Before}
        end,
    Routes =
        case persistent_term:get({roadrunner_routes, rr_sockets_full}, undefined) of
            undefined -> routes_erased;
            _ -> routes_left
        end,
    {Result, Ports, Routes}.

%% =============================================================================
%% Helpers
%% =============================================================================

opts(Extra) ->
    maps:merge(#{port => 0, routes => roadrunner_hello_handler}, Extra).

listen_sockets(Pid) ->
    element(2, sys:get_state(Pid)).

acceptors(Pid) ->
    {links, Links} = process_info(Pid, links),
    [A || A <- Links, is_pid(A), is_acceptor(proc_lib:get_label(A))].

is_acceptor({roadrunner_acceptor, _Listener, _Index}) -> true;
is_acceptor(_Label) -> false.

free_port() ->
    {ok, Probe} = gen_tcp:listen(0, []),
    {ok, Port} = inet:port(Probe),
    ok = gen_tcp:close(Probe),
    Port.

request(Port) ->
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
    ok = gen_tcp:send(Sock, ~"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"),
    {ok, Reply} = gen_tcp:recv(Sock, 0, 1000),
    ok = gen_tcp:close(Sock),
    Reply.

wait_for(Sock, Want, Acc) ->
    case binary:match(Acc, Want) of
        nomatch ->
            {ok, More} = gen_tcp:recv(Sock, 0, 2000),
            wait_for(Sock, Want, <<Acc/binary, More/binary>>);
        _ ->
            ok
    end.

restore_env({ok, Backend}) -> application:set_env(kernel, inet_backend, Backend);
restore_env(undefined) -> application:unset_env(kernel, inet_backend).
