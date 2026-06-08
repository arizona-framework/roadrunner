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
    reuseport_allows_shared_bind/1,
    active_once_delivers_messages/1
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
        reuseport_allows_shared_bind,
        active_once_delivers_messages
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

%% Two sockets share one concrete port when both set reuseport, the
%% kernel-fan-out shape the listener pool relies on (validate_opt's
%% reuseport clause + the {reuseport, true} bind).
reuseport_allows_shared_bind(_Config) ->
    {ok, First} = roadrunner_quic_socket:open(0, #{reuseport => true}),
    {ok, {_Ip, Port}} = roadrunner_quic_socket:sockname(First),
    {ok, Second} = roadrunner_quic_socket:open(Port, #{reuseport => true}),
    ok = roadrunner_quic_socket:close(First),
    ok = roadrunner_quic_socket:close(Second).
