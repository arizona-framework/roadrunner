-module(roadrunner_listener_bind_SUITE).
-moduledoc """
The forms the `ip` listener option takes, as `gen_tcp`'s does: an address,
`any`, `loopback` and `{local, Path}` for a Unix domain socket. HTTP/3,
over UDP, needs an address.
""".

-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0]).
-export([
    any_serves/1,
    loopback_serves/1,
    unix_socket_serves_http1/1,
    unix_socket_needs_port_0/1,
    unix_socket_port_is_0/1,
    http3_needs_an_ip_address/1
]).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        any_serves,
        loopback_serves,
        unix_socket_serves_http1,
        unix_socket_needs_port_0,
        unix_socket_port_is_0,
        http3_needs_an_ip_address
    ].

any_serves(_Config) ->
    serves_on_loopback(bind_any, any).

loopback_serves(_Config) ->
    serves_on_loopback(bind_loopback, loopback).

serves_on_loopback(Name, Ip) ->
    {ok, _} = roadrunner_listener:start_link(Name, opts(#{port => 0, ip => Ip})),
    try
        Port = roadrunner_listener:port(Name),
        ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, get({127, 0, 0, 1}, Port))
    after
        ok = roadrunner_listener:stop(Name)
    end.

unix_socket_serves_http1(_Config) ->
    Path = unix_path(),
    {ok, _} = roadrunner_listener:start_link(bind_unix, opts(#{port => 0, ip => {local, Path}})),
    try
        ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, get({local, Path}, 0))
    after
        ok = roadrunner_listener:stop(bind_unix),
        _ = file:delete(Path)
    end.

%% A Unix domain socket has no port: one set is refused, not ignored.
unix_socket_needs_port_0(_Config) ->
    process_flag(trap_exit, true),
    ?assertMatch(
        {error, {{listener_opt_conflict, port, 8080, unix_socket_needs_port_0}, _Stack}},
        roadrunner_listener:start_link(
            bind_unix_port, opts(#{port => 8080, ip => {local, "/tmp/roadrunner-port.sock"}})
        )
    ).

%% A Unix domain socket has no port, on plain TCP and on TLS alike.
unix_socket_port_is_0(_Config) ->
    lists:foreach(
        fun(Extra) ->
            Path = unix_path(),
            {ok, _} = roadrunner_listener:start_link(
                bind_unix_port0, opts(Extra#{port => 0, ip => {local, Path}})
            ),
            try
                ?assertEqual(0, roadrunner_listener:port(bind_unix_port0))
            after
                ok = roadrunner_listener:stop(bind_unix_port0),
                _ = file:delete(Path)
            end
        end,
        [#{}, #{tls => roadrunner_test_certs:server_opts()}]
    ).

http3_needs_an_ip_address(_Config) ->
    process_flag(trap_exit, true),
    lists:foreach(
        fun(Ip) ->
            ?assertMatch(
                {error, {{listener_opt_conflict, ip, Ip, http3_needs_an_ip_address}, _Stack}},
                roadrunner_listener:start_link(bind_h3, #{
                    port => 0,
                    ip => Ip,
                    protocols => [http1, http3],
                    tls => roadrunner_test_certs:server_opts(),
                    routes => roadrunner_hello_handler
                })
            )
        end,
        [any, loopback, {local, "/tmp/roadrunner-h3.sock"}]
    ).

%% =============================================================================
%% Helpers
%% =============================================================================

%% A short path: a Unix socket path is limited to about 100 bytes.
unix_path() ->
    "/tmp/roadrunner-" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".sock".

opts(Extra) ->
    Extra#{routes => roadrunner_hello_handler}.

get(Address, Port) ->
    {ok, Sock} = gen_tcp:connect(Address, Port, [binary, {active, false}], 1000),
    ok = gen_tcp:send(Sock, ~"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"),
    {ok, Reply} = gen_tcp:recv(Sock, 0, 1000),
    ok = gen_tcp:close(Sock),
    Reply.
