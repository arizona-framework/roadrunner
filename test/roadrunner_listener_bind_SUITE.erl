-module(roadrunner_listener_bind_SUITE).
-moduledoc """
The forms the `ip` listener option takes, as `gen_tcp`'s does: an address,
`any`, `loopback` and `{local, Path}` for a Unix domain socket. HTTP/3,
over UDP, needs an address.
""".

-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1]).
-export([
    any_serves/1,
    loopback_serves/1,
    unix_socket_serves_http1/1,
    unix_socket_needs_port_0/1,
    unix_socket_port_is_0/1,
    unix_socket_client_ip/1,
    unix_socket_client_ip_over_h2/1,
    unix_socket_rate_limit/1,
    unix_socket_rate_limit_over_h2/1,
    unix_socket_route_rate_limit/1,
    unix_socket_route_rate_limit_over_h2/1,
    unix_socket_restarts_on_its_path/1,
    unix_socket_leaves_a_file_another_server_took/1,
    abstract_unix_socket/1,
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
        unix_socket_client_ip,
        unix_socket_client_ip_over_h2,
        unix_socket_rate_limit,
        unix_socket_rate_limit_over_h2,
        unix_socket_route_rate_limit,
        unix_socket_route_rate_limit_over_h2,
        unix_socket_restarts_on_its_path,
        unix_socket_leaves_a_file_another_server_took,
        abstract_unix_socket,
        http3_needs_an_ip_address
    ].

%% The sockets go in a directory of this run's own, with a short path: a
%% Unix socket path is limited to about 100 bytes, which CT's `priv_dir`
%% can pass.
init_per_suite(Config) ->
    Dir = filename:join(
        filename:basedir(user_cache, "roadrunner-bind"),
        integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = filelib:ensure_path(Dir),
    [{sock_dir, Dir} | Config].

end_per_suite(Config) ->
    ok = file:del_dir_r(?config(sock_dir, Config)).

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

unix_socket_serves_http1(Config) ->
    Path = unix_path(Config),
    {ok, _} = roadrunner_listener:start_link(bind_unix, opts(#{port => 0, ip => {local, Path}})),
    try
        ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, get({local, Path}, 0))
    after
        ok = roadrunner_listener:stop(bind_unix)
    end.

%% A Unix domain socket has no port: one set is refused, not ignored.
unix_socket_needs_port_0(Config) ->
    process_flag(trap_exit, true),
    ?assertMatch(
        {error, {{listener_opt_conflict, port, 8080, unix_socket_needs_port_0}, _Stack}},
        roadrunner_listener:start_link(
            bind_unix_port, opts(#{port => 8080, ip => {local, unix_path(Config)}})
        )
    ).

%% A Unix domain socket has no port, on plain TCP and on TLS alike.
unix_socket_port_is_0(Config) ->
    lists:foreach(
        fun(Extra) ->
            Path = unix_path(Config),
            {ok, _} = roadrunner_listener:start_link(
                bind_unix_port0, opts(Extra#{port => 0, ip => {local, Path}})
            ),
            try
                ?assertEqual(0, roadrunner_listener:port(bind_unix_port0))
            after
                ok = roadrunner_listener:stop(bind_unix_port0)
            end
        end,
        [#{}, #{tls => roadrunner_test_certs:server_opts()}]
    ).

%% A Unix domain socket's client has no address, so no peer. Behind a
%% reverse proxy it is the nearest hop: `real_ip` trusts it with
%% `trusted_hops`, and with `trusted_proxies` only through a `~"unix:"`
%% entry, and the client is the one the header names, if any.
unix_socket_client_ip(Config) ->
    client_ip_cases(Config, fun h1_request/2),
    %% The local address is the socket's path.
    Path = unix_path(Config),
    {ok, _} = roadrunner_listener:start_link(bind_unix_name, addr_opts(Path, #{})),
    try
        {200, Body} = h1_request(Path, []),
        ?assertMatch({_, _, {ok, {local, _}}}, binary_to_term(Body)),
        {_, _, {ok, {local, Local}}} = binary_to_term(Body),
        ?assertEqual(list_to_binary(Path), Local)
    after
        ok = roadrunner_listener:stop(bind_unix_name)
    end.

%% The same over HTTP/2 with prior knowledge.
unix_socket_client_ip_over_h2(Config) ->
    client_ip_cases(Config, fun h2_request/2).

client_ip_cases(Config, Request) ->
    Xff = [{~"x-forwarded-for", ~"1.2.3.4"}],
    lists:foreach(
        fun({RealIp, Headers, ClientIp}) ->
            Path = unix_path(Config),
            {ok, _} = roadrunner_listener:start_link(bind_unix_addr, addr_opts(Path, RealIp)),
            try
                {200, Body} = Request(Path, Headers),
                ?assertMatch({undefined, ClientIp, _}, binary_to_term(Body), {RealIp, Headers})
            after
                ok = roadrunner_listener:stop(bind_unix_addr)
            end
        end,
        [
            {#{real_ip => #{trusted_hops => 1}}, Xff, {1, 2, 3, 4}},
            {#{real_ip => #{trusted_proxies => [~"unix:"]}}, Xff, {1, 2, 3, 4}},
            {
                #{real_ip => #{trusted_hops => 1, header => forwarded}},
                [{~"forwarded", ~"for=1.2.3.4"}],
                {1, 2, 3, 4}
            },
            {#{real_ip => #{trusted_hops => 1}}, [], undefined},
            {#{real_ip => #{trusted_hops => 1}}, [{~"x-forwarded-for", ~"junk"}], undefined},
            {#{real_ip => #{trusted_proxies => [~"127.0.0.1/32"]}}, Xff, undefined},
            {#{real_ip => #{trusted_proxies => [~"::1/128"]}}, Xff, undefined},
            {#{}, Xff, undefined}
        ]
    ).

%% The listener's `rate_limit` keys on the client `real_ip` resolves, and
%% the requests with none share one bucket.
unix_socket_rate_limit(Config) ->
    rate_limit_cases(Config, fun h1_request/2).

unix_socket_rate_limit_over_h2(Config) ->
    rate_limit_cases(Config, fun h2_request/2).

rate_limit_cases(Config, Request) ->
    RateLimit = #{rate => 1, burst => 1, period => 3600},
    A = [{~"x-forwarded-for", ~"1.2.3.4"}],
    B = [{~"x-forwarded-for", ~"5.6.7.8"}],
    lists:foreach(
        fun({Extra, Requests}) ->
            Path = unix_path(Config),
            {ok, _} = roadrunner_listener:start_link(
                bind_unix_rate, addr_opts(Path, Extra#{rate_limit => RateLimit})
            ),
            try
                ?assertEqual(
                    [Status || {_Headers, Status} <- Requests],
                    [element(1, Request(Path, Headers)) || {Headers, _Status} <- Requests]
                )
            after
                ok = roadrunner_listener:stop(bind_unix_rate)
            end
        end,
        [
            {#{real_ip => #{trusted_hops => 1}}, [{A, 200}, {B, 200}, {A, 429}]},
            {#{real_ip => #{trusted_hops => 1}}, [{[], 200}, {[], 429}]},
            {#{}, [{A, 200}, {B, 429}]}
        ]
    ).

%% Stopping removes the socket's file, so a listener starts on the same
%% path again.
unix_socket_restarts_on_its_path(Config) ->
    Path = unix_path(Config),
    Opts = opts(#{port => 0, ip => {local, Path}}),
    {ok, _} = roadrunner_listener:start_link(bind_unix_again, Opts),
    ok = roadrunner_listener:stop(bind_unix_again),
    ?assertEqual({error, enoent}, file:read_file_info(Path)),
    {ok, _} = roadrunner_listener:start_link(bind_unix_again, Opts),
    try
        ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, get({local, Path}, 0))
    after
        ok = roadrunner_listener:stop(bind_unix_again)
    end,
    ?assertEqual({error, enoent}, file:read_file_info(Path)).

%% So does a route's own `rate_limit`: the requests with no client share
%% one bucket of the route's.
unix_socket_route_rate_limit(Config) ->
    route_rate_limit_cases(Config, fun h1_request/2).

unix_socket_route_rate_limit_over_h2(Config) ->
    route_rate_limit_cases(Config, fun h2_request/2).

route_rate_limit_cases(Config, Request) ->
    Path = unix_path(Config),
    Route = #{
        path => ~"/",
        handler => roadrunner_addr_handler,
        rate_limit => #{rate => 1, period => 3600}
    },
    {ok, _} = roadrunner_listener:start_link(
        bind_unix_route_rate, (addr_opts(Path, #{}))#{routes => [Route]}
    ),
    try
        ?assertEqual([200, 429], [element(1, Request(Path, [])) || _ <- [1, 2]])
    after
        ok = roadrunner_listener:stop(bind_unix_route_rate)
    end.

%% A server that took the path over (removed the file and bound again, as
%% a redeploy can) keeps its file when the old listener stops.
unix_socket_leaves_a_file_another_server_took(Config) ->
    Path = unix_path(Config),
    {ok, _} = roadrunner_listener:start_link(
        bind_unix_old, opts(#{port => 0, ip => {local, Path}})
    ),
    ok = file:delete(Path),
    {ok, _} = roadrunner_listener:start_link(
        bind_unix_new, opts(#{port => 0, ip => {local, Path}})
    ),
    try
        ok = roadrunner_listener:stop(bind_unix_old),
        ?assertMatch({ok, _}, file:read_link_info(Path)),
        ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, get({local, Path}, 0))
    after
        ok = roadrunner_listener:stop(bind_unix_new)
    end,
    ?assertEqual({error, enoent}, file:read_link_info(Path)).

%% An abstract socket (Linux: a path that starts with a zero byte) has no
%% file to remove, given as a binary or as a string.
abstract_unix_socket(_Config) ->
    lists:foreach(
        fun(Name) ->
            {ok, _} = roadrunner_listener:start_link(
                bind_unix_abstract, opts(#{port => 0, ip => {local, Name}})
            ),
            try
                ?assertMatch(<<"HTTP/1.1 200 ", _/binary>>, get({local, Name}, 0))
            after
                ok = roadrunner_listener:stop(bind_unix_abstract)
            end
        end,
        [
            <<0, "roadrunner-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
            [0 | "roadrunner-" ++ integer_to_list(erlang:unique_integer([positive]))]
        ]
    ).

http3_needs_an_ip_address(Config) ->
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
        [any, loopback, {local, unix_path(Config)}]
    ).

%% =============================================================================
%% Helpers
%% =============================================================================

unix_path(Config) ->
    filename:join(
        ?config(sock_dir, Config), integer_to_list(erlang:unique_integer([positive])) ++ ".sock"
    ).

addr_opts(Path, Extra) ->
    Extra#{
        port => 0,
        ip => {local, Path},
        protocols => [http1, http2],
        routes => roadrunner_addr_handler
    }.

%% One HTTP/1.1 request with `Headers` on a new connection: its status and
%% body.
h1_request(Path, Headers) ->
    Reply = request(
        {local, Path},
        0,
        [
            ~"GET / HTTP/1.1\r\nHost: x\r\n",
            [[Name, ~": ", Value, ~"\r\n"] || {Name, Value} <- Headers],
            ~"Connection: close\r\n\r\n"
        ]
    ),
    <<"HTTP/1.1 ", Status:3/binary, _/binary>> = Reply,
    [_Head, Body] = binary:split(Reply, ~"\r\n\r\n"),
    {binary_to_integer(Status), Body}.

%% The same over HTTP/2 with prior knowledge.
h2_request(Path, Headers) ->
    {ok, Sock} = gen_tcp:connect({local, Path}, 0, [binary, {active, false}], 1000),
    ok = gen_tcp:send(Sock, ~"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"),
    C0 = roadrunner_grpc_test_client:after_preface(Sock, []),
    Extra = [{~":method", ~"GET"}, {~"content-type", omit}, {~"te", omit} | Headers],
    C1 = roadrunner_grpc_test_client:start(C0, 1, ~"/", Extra),
    C2 = roadrunner_grpc_test_client:finish(C1, 1),
    Body =
        case roadrunner_grpc_test_client:response(C2, 1) of
            {Fields, {body, Data}, no_trailers, _C} -> {Fields, Data};
            {Fields, [], trailers_only, _C} -> {Fields, <<>>}
        end,
    ok = gen_tcp:close(Sock),
    {ResponseFields, ResponseBody} = Body,
    {binary_to_integer(proplists:get_value(~":status", ResponseFields)), ResponseBody}.

opts(Extra) ->
    Extra#{routes => roadrunner_hello_handler}.

%% The whole reply to `Request` on a connection the server closes.
request(Address, Port, Request) ->
    {ok, Sock} = gen_tcp:connect(Address, Port, [binary, {active, false}], 1000),
    ok = gen_tcp:send(Sock, Request),
    recv_all(Sock, <<>>).

recv_all(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 1000) of
        {ok, Data} -> recv_all(Sock, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc
    end.

get(Address, Port) ->
    {ok, Sock} = gen_tcp:connect(Address, Port, [binary, {active, false}], 1000),
    ok = gen_tcp:send(Sock, ~"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"),
    {ok, Reply} = gen_tcp:recv(Sock, 0, 1000),
    ok = gen_tcp:close(Sock),
    Reply.
