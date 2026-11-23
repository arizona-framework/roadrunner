-module(roadrunner_kernel_recv_buffer_SUITE).
-moduledoc """
The `kernel_recv_buffer` listener option sets the kernel receive buffer
(`SO_RCVBUF`) of every accepted socket, which inherits it from the listen
socket. Unset, the operating system sizes it.
""".
-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1]).
-export([
    accepted_socket_takes_the_kernel_recv_buffer/1,
    accepted_tls_socket_takes_the_kernel_recv_buffer/1,
    invalid_kernel_recv_buffer_fails_the_start/1
]).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        accepted_socket_takes_the_kernel_recv_buffer,
        accepted_tls_socket_takes_the_kernel_recv_buffer,
        invalid_kernel_recv_buffer_fails_the_start
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started([roadrunner, ssl]),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(roadrunner).

accepted_socket_takes_the_kernel_recv_buffer(_Config) ->
    {ok, _} = roadrunner:start_listener(?FUNCTION_NAME, #{
        port => 0, routes => roadrunner_keepalive_handler, kernel_recv_buffer => 16384
    }),
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, roadrunner_listener:port(?FUNCTION_NAME), [binary, {active, false}]
    ),
    %% A response means the connection was accepted.
    ok = gen_tcp:send(Sock, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"),
    {ok, <<"HTTP/1.1 200 ", _/binary>>} = gen_tcp:recv(Sock, 0, 5000),
    {ok, ClientAddr} = inet:sockname(Sock),
    %% Linux doubles the size it is asked for, for its own bookkeeping.
    ?assertEqual({ok, [{recbuf, 32768}]}, inet:getopts(accepted(ClientAddr), [recbuf])),
    ok = gen_tcp:close(Sock),
    ok = roadrunner:stop_listener(?FUNCTION_NAME).

accepted_tls_socket_takes_the_kernel_recv_buffer(_Config) ->
    {ok, _} = roadrunner:start_listener(?FUNCTION_NAME, #{
        port => 0,
        routes => roadrunner_keepalive_handler,
        kernel_recv_buffer => 16384,
        tls => roadrunner_test_certs:server_opts()
    }),
    {ok, Sock} = ssl:connect(
        {127, 0, 0, 1},
        roadrunner_listener:port(?FUNCTION_NAME),
        [binary, {active, false}, {verify, verify_none} | roadrunner_test_certs:client_opts()],
        5000
    ),
    ok = ssl:send(Sock, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"),
    {ok, <<"HTTP/1.1 200 ", _/binary>>} = ssl:recv(Sock, 0, 5000),
    {ok, ClientAddr} = ssl:sockname(Sock),
    ?assertEqual({ok, [{recbuf, 32768}]}, inet:getopts(accepted(ClientAddr), [recbuf])),
    ok = ssl:close(Sock),
    ok = roadrunner:stop_listener(?FUNCTION_NAME).

invalid_kernel_recv_buffer_fails_the_start(_Config) ->
    process_flag(trap_exit, true),
    lists:foreach(
        fun(Bad) ->
            ?assertMatch(
                {error, {{invalid_listener_opt, kernel_recv_buffer, Bad}, _}},
                roadrunner_listener:start_link(?FUNCTION_NAME, #{
                    port => 0, routes => roadrunner_keepalive_handler, kernel_recv_buffer => Bad
                })
            )
        end,
        [0, 16#80000000, auto]
    ).

%% The server's end of the connection from `ClientAddr`: the socket in this
%% node whose peer is the client.
accepted(ClientAddr) ->
    [Port] = [
        P
     || P <- erlang:ports(),
        erlang:port_info(P, name) =:= {name, "tcp_inet"},
        inet:peername(P) =:= {ok, ClientAddr}
    ],
    Port.
