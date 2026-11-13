-module(roadrunner_listener_ipv6_SUITE).
-moduledoc """
Listeners bound to IPv6 addresses, and the `ipv6_v6only` option that sets
whether such a listener also serves IPv4 clients. With `true`, an IPv4
listener and an IPv6 listener share one port, on TCP and on the HTTP/3 UDP
socket alike.
""".

-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0]).
-export([
    ipv4_and_ipv6_listeners_share_a_port/1,
    dual_stack_listener_serves_ipv4/1,
    ipv6_v6only_needs_an_ipv6_ip/1,
    ipv6_v6only_must_be_a_boolean/1,
    http3_listener_binds_ipv6_only/1
]).

-define(ANY6, {0, 0, 0, 0, 0, 0, 0, 0}).
-define(LOOPBACK4, {127, 0, 0, 1}).
-define(LOOPBACK6, {0, 0, 0, 0, 0, 0, 0, 1}).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        ipv4_and_ipv6_listeners_share_a_port,
        dual_stack_listener_serves_ipv4,
        ipv6_v6only_needs_an_ipv6_ip,
        ipv6_v6only_must_be_a_boolean,
        http3_listener_binds_ipv6_only
    ].

ipv4_and_ipv6_listeners_share_a_port(_Config) ->
    {ok, _} = roadrunner_listener:start_link(ipv6_share_v4, opts(#{port => 0})),
    Port = roadrunner_listener:port(ipv6_share_v4),
    {ok, _} = roadrunner_listener:start_link(
        ipv6_share_v6, opts(#{port => Port, ip => ?ANY6, ipv6_v6only => true})
    ),
    try
        ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, get(?LOOPBACK4, Port)),
        ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, get(?LOOPBACK6, Port))
    after
        ok = roadrunner_listener:stop(ipv6_share_v6),
        ok = roadrunner_listener:stop(ipv6_share_v4)
    end.

dual_stack_listener_serves_ipv4(_Config) ->
    %% With `false`, the IPv6 listener takes IPv4 clients too.
    {ok, _} = roadrunner_listener:start_link(
        ipv6_dual, opts(#{port => 0, ip => ?ANY6, ipv6_v6only => false})
    ),
    Port = roadrunner_listener:port(ipv6_dual),
    try
        ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, get(?LOOPBACK4, Port)),
        ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, get(?LOOPBACK6, Port))
    after
        ok = roadrunner_listener:stop(ipv6_dual)
    end.

ipv6_v6only_needs_an_ipv6_ip(_Config) ->
    process_flag(trap_exit, true),
    ?assertMatch(
        {error, {{listener_opt_conflict, ipv6_v6only, true, no_ipv6_ip}, _Stack}},
        roadrunner_listener:start_link(ipv6_no_ip, opts(#{port => 0, ipv6_v6only => true}))
    ),
    ?assertMatch(
        {error, {{listener_opt_conflict, ipv6_v6only, false, no_ipv6_ip}, _Stack}},
        roadrunner_listener:start_link(
            ipv6_v4_ip, opts(#{port => 0, ip => ?LOOPBACK4, ipv6_v6only => false})
        )
    ).

ipv6_v6only_must_be_a_boolean(_Config) ->
    process_flag(trap_exit, true),
    ?assertMatch(
        {error, {{invalid_listener_opt, ipv6_v6only, yes}, _Stack}},
        roadrunner_listener:start_link(
            ipv6_not_bool, opts(#{port => 0, ip => ?ANY6, ipv6_v6only => yes})
        )
    ).

http3_listener_binds_ipv6_only(_Config) ->
    %% An IPv4 UDP socket holds the port. An IPv6-only HTTP/3 listener binds
    %% it anyway, which it can only do when `ipv6_v6only` reaches its sockets:
    %% a dual-stack one would also claim the port for IPv4.
    {ok, Holder} = gen_udp:open(0, [{ip, {0, 0, 0, 0}}]),
    {ok, Port} = inet:port(Holder),
    try
        {ok, _} = roadrunner_listener:start_link(ipv6_h3, h3_opts(Port, #{ipv6_v6only => true})),
        ok = roadrunner_listener:stop(ipv6_h3),
        process_flag(trap_exit, true),
        ?assertMatch(
            {error, {listen_failed, {shutdown, {failed_to_start_child, _, eaddrinuse}}}},
            roadrunner_listener:start_link(ipv6_h3_dual, h3_opts(Port, #{ipv6_v6only => false}))
        )
    after
        ok = gen_udp:close(Holder)
    end.

%% =============================================================================
%% Helpers
%% =============================================================================

opts(Extra) ->
    Extra#{routes => roadrunner_hello_handler}.

h3_opts(Port, Extra) ->
    Extra#{
        port => Port,
        ip => ?ANY6,
        protocols => [http3],
        tls => roadrunner_test_certs:server_opts(),
        routes => roadrunner_hello_handler
    }.

get(Ip, Port) ->
    {ok, Sock} = gen_tcp:connect(Ip, Port, [binary, {active, false}], 1000),
    ok = gen_tcp:send(Sock, ~"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"),
    {ok, Reply} = gen_tcp:recv(Sock, 0, 1000),
    ok = gen_tcp:close(Sock),
    Reply.
