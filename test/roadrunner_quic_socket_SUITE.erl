-module(roadrunner_quic_socket_SUITE).
-moduledoc """
Loopback I/O tests for `roadrunner_quic_socket`.

A CT suite rather than eunit so each datagram round-trip runs in its
own process with the suite timetrap as an outer guard. Covers the
socket's I/O surface (open/send/recv/close/sockname and valid-opt
acceptance) against real loopback UDP; the option-validation reject
clause is unit-tested in `roadrunner_quic_socket_tests`.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0]).
-export([
    loopback_echo/1,
    recv_timeout/1,
    open_in_use_errors/1,
    open_with_custom_buffers/1,
    open_binds_to_ip/1,
    reuseport_allows_shared_bind/1,
    active_once_delivers_messages/1,
    active_n_batches_then_passive/1,
    send_batch_delivers_each_datagram/1,
    send_batch_splits_runs_at_short_datagrams/1,
    send_batch_past_segment_cap/1,
    send_batch_without_gso/1,
    send_batch_failed_run_falls_back/1
]).

-define(LOOPBACK, {127, 0, 0, 1}).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        loopback_echo,
        recv_timeout,
        open_in_use_errors,
        open_with_custom_buffers,
        open_binds_to_ip,
        reuseport_allows_shared_bind,
        active_once_delivers_messages,
        active_n_batches_then_passive,
        send_batch_delivers_each_datagram,
        send_batch_splits_runs_at_short_datagrams,
        send_batch_past_segment_cap,
        send_batch_without_gso,
        send_batch_failed_run_falls_back
    ].

%% An `active => once` socket delivers each datagram as one mailbox message,
%% parsed with from_message/2 and re-armed with activate/1; before re-arming
%% no further message arrives (one-at-a-time back-pressure).
active_once_delivers_messages(_Config) ->
    {ok, Server} = roadrunner_quic_socket:open(0, #{active => once}),
    {ok, Client} = roadrunner_quic_socket:open(0),
    {ok, {_, ServerPort}} = roadrunner_quic_socket:sockname(Server),
    {ok, {_, ClientPort}} = roadrunner_quic_socket:sockname(Client),

    ok = roadrunner_quic_socket:send(Client, ?LOOPBACK, ServerPort, ~"one"),
    Msg1 =
        receive
            M1 -> M1
        after 1000 -> ct:fail(no_active_message)
        end,
    ?assertEqual(
        {ok, {?LOOPBACK, ClientPort}, ~"one"}, roadrunner_quic_socket:from_message(Server, Msg1)
    ),

    %% Not re-armed yet: a second datagram buffers but is not delivered.
    ok = roadrunner_quic_socket:send(Client, ?LOOPBACK, ServerPort, ~"two"),
    receive
        Premature -> ct:fail({delivered_before_rearm, Premature})
    after 200 -> ok
    end,

    ok = roadrunner_quic_socket:activate(Server),
    Msg2 =
        receive
            M2 -> M2
        after 1000 -> ct:fail(no_message_after_rearm)
        end,
    ?assertEqual(
        {ok, {?LOOPBACK, ClientPort}, ~"two"}, roadrunner_quic_socket:from_message(Server, Msg2)
    ),

    ok = roadrunner_quic_socket:close(Server),
    ok = roadrunner_quic_socket:close(Client).

%% An `active => N` socket delivers up to N datagrams, then a `passive` notice
%% (from_message/2's udp_passive clause); the (N+1)th buffers until re-armed
%% with activate/2.
active_n_batches_then_passive(_Config) ->
    N = 2,
    {ok, Server} = roadrunner_quic_socket:open(0, #{active => N}),
    {ok, Client} = roadrunner_quic_socket:open(0),
    {ok, {_, ServerPort}} = roadrunner_quic_socket:sockname(Server),
    ok = roadrunner_quic_socket:send(Client, ?LOOPBACK, ServerPort, ~"a"),
    ok = roadrunner_quic_socket:send(Client, ?LOOPBACK, ServerPort, ~"b"),
    ok = roadrunner_quic_socket:send(Client, ?LOOPBACK, ServerPort, ~"c"),
    ?assertMatch({ok, _, _}, next_parsed(Server)),
    ?assertMatch({ok, _, _}, next_parsed(Server)),
    ?assertEqual(passive, next_parsed(Server)),
    ok = roadrunner_quic_socket:activate(Server, N),
    ?assertMatch({ok, _, _}, next_parsed(Server)),
    ok = roadrunner_quic_socket:close(Server),
    ok = roadrunner_quic_socket:close(Client).

next_parsed(Socket) ->
    receive
        Msg -> roadrunner_quic_socket:from_message(Socket, Msg)
    after 1000 -> ct:fail(no_active_message)
    end.

%% A datagram travels client -> server with its source address, then the
%% server echoes back to that address. Exercises open/1 (default opts),
%% sockname/1, send/4, recv/2's success clause, and close/1.
loopback_echo(_Config) ->
    {ok, Server} = roadrunner_quic_socket:open(0),
    {ok, Client} = roadrunner_quic_socket:open(0),
    %% Opened on port 0 -> bound to the wildcard address, so sockname
    %% reports {0,0,0,0}; only the ephemeral port matters here. The
    %% datagram source below is genuine loopback (traffic crosses lo).
    {ok, {_ServerIp, ServerPort}} = roadrunner_quic_socket:sockname(Server),
    {ok, {_ClientIp, ClientPort}} = roadrunner_quic_socket:sockname(Client),

    ok = roadrunner_quic_socket:send(Client, ?LOOPBACK, ServerPort, ~"ping"),
    ?assertEqual(
        {ok, {?LOOPBACK, ClientPort}, ~"ping"},
        roadrunner_quic_socket:recv(Server, 1000)
    ),

    ok = roadrunner_quic_socket:send(Server, ?LOOPBACK, ClientPort, ~"pong"),
    ?assertEqual(
        {ok, {?LOOPBACK, ServerPort}, ~"pong"},
        roadrunner_quic_socket:recv(Client, 1000)
    ),

    ok = roadrunner_quic_socket:close(Server),
    ok = roadrunner_quic_socket:close(Client).

%% An idle socket returns {error, timeout} once the deadline elapses
%% (recv/2's error clause).
recv_timeout(_Config) ->
    {ok, Socket} = roadrunner_quic_socket:open(0),
    ?assertEqual({error, timeout}, roadrunner_quic_socket:recv(Socket, 50)),
    ok = roadrunner_quic_socket:close(Socket).

%% Binding a port already held by a socket without reuseaddr fails
%% (open/2's error clause). A reuseaddr blocker would let the second
%% bind through, so the blocker is a plain gen_udp socket.
open_in_use_errors(_Config) ->
    {ok, Blocker} = gen_udp:open(0, [binary, {active, false}]),
    {ok, {_Ip, Port}} = inet:sockname(Blocker),
    ?assertEqual({error, eaddrinuse}, roadrunner_quic_socket:open(Port)),
    ok = gen_udp:close(Blocker).

%% Custom recbuf/sndbuf are accepted (validate_opt's recbuf/sndbuf
%% success clauses); gen_udp owns whether they reach the kernel.
open_with_custom_buffers(_Config) ->
    {ok, Socket} = roadrunner_quic_socket:open(0, #{recbuf => 131072, sndbuf => 131072}),
    {ok, {_Ip, _Port}} = roadrunner_quic_socket:sockname(Socket),
    ok = roadrunner_quic_socket:close(Socket).

%% `ip` binds a single interface: the socket's local address is the one
%% requested (loopback), not the all-interfaces `0.0.0.0`.
open_binds_to_ip(_Config) ->
    {ok, Socket} = roadrunner_quic_socket:open(0, #{ip => ?LOOPBACK}),
    ?assertMatch({ok, {?LOOPBACK, _Port}}, roadrunner_quic_socket:sockname(Socket)),
    ok = roadrunner_quic_socket:close(Socket).

%% Two sockets share one concrete port when both set reuseport, the
%% kernel-fan-out shape the listener pool relies on (validate_opt's
%% reuseport clause + the {reuseport, true} bind).
reuseport_allows_shared_bind(_Config) ->
    {ok, First} = roadrunner_quic_socket:open(0, #{reuseport => true}),
    {ok, {_Ip, Port}} = roadrunner_quic_socket:sockname(First),
    {ok, Second} = roadrunner_quic_socket:open(Port, #{reuseport => true}),
    ok = roadrunner_quic_socket:close(First),
    ok = roadrunner_quic_socket:close(Second).

%% =============================================================================
%% send_batch/4: with GSO a run of full-size datagrams goes to the kernel in
%% one call and must still arrive as the same separate datagrams.
%% =============================================================================

send_batch_delivers_each_datagram(_Config) ->
    %% Three full 1200-byte datagrams and a shorter last one: one GSO run.
    assert_batch_delivered(#{}, [
        datagram(1, 1200), datagram(2, 1200), datagram(3, 1200), datagram(4, 100)
    ]).

send_batch_splits_runs_at_short_datagrams(_Config) ->
    %% A short datagram mid-batch ends a run (only a run's last segment may
    %% be shorter), and a lone datagram goes out by itself.
    assert_batch_delivered(#{}, [
        datagram(1, 1200), datagram(2, 40), datagram(3, 1200), datagram(4, 1200), datagram(5, 1200)
    ]).

send_batch_past_segment_cap(_Config) ->
    %% More full datagrams than one GSO send may carry go out as several runs.
    assert_batch_delivered(#{}, [datagram(N, 1200) || N <- lists:seq(1, 60)]).

send_batch_without_gso(_Config) ->
    %% A socket opened without GSO sends the batch one datagram at a time.
    assert_batch_delivered(#{gso => false}, [datagram(1, 1200), datagram(2, 1200), datagram(3, 7)]).

send_batch_failed_run_falls_back(_Config) ->
    %% A run the kernel refuses (here every send fails: port 0 is not a
    %% destination) is retried a datagram at a time; errors are not raised.
    {ok, Client} = roadrunner_quic_socket:open(0),
    ok = roadrunner_quic_socket:send_batch(Client, ?LOOPBACK, 0, [
        datagram(1, 1200), datagram(2, 1200), datagram(3, 10)
    ]),
    ok = roadrunner_quic_socket:close(Client).

assert_batch_delivered(ClientOpts, Datagrams) ->
    {ok, Server} = roadrunner_quic_socket:open(0, #{recbuf => 4194304}),
    {ok, Client} = roadrunner_quic_socket:open(0, ClientOpts),
    {ok, {_, ServerPort}} = roadrunner_quic_socket:sockname(Server),
    ok = roadrunner_quic_socket:send_batch(Client, ?LOOPBACK, ServerPort, Datagrams),
    Received = [
        begin
            {ok, _From, Data} = roadrunner_quic_socket:recv(Server, 1000),
            Data
        end
     || _ <- Datagrams
    ],
    ?assertEqual(Datagrams, Received),
    ?assertEqual({error, timeout}, roadrunner_quic_socket:recv(Server, 50)),
    ok = roadrunner_quic_socket:close(Server),
    ok = roadrunner_quic_socket:close(Client).

%% A datagram of `Size` bytes whose first byte tags it, so a reordered or
%% merged delivery fails the comparison.
datagram(Tag, Size) ->
    <<Tag, (binary:copy(<<"x">>, Size - 1))/binary>>.
