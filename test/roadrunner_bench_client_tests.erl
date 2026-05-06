-module(roadrunner_bench_client_tests).

-include_lib("eunit/include/eunit.hrl").

%% Per `feedback_eunit_spawn_isolation`: each test runs in its own
%% spawned process so any in-flight `roadrunner_fake_*` mailbox
%% messages from killed conns can't leak into the next test. The
%% bench client opens REAL TCP/TLS sockets (not the fake transport)
%% so the leak vector is narrower here, but the discipline is
%% project-wide.
all_test_() ->
    Tests = [
        fun h1_get_returns_200/0,
        fun h1_post_echoes_body/0,
        fun h1_keepalive_n_requests/0,
        fun h2_get_returns_200/0,
        fun h2_post_echoes_body/0,
        fun h2_keepalive_n_requests/0,
        fun h3_returns_not_implemented/0,
        fun open_h1_to_dead_port_errors/0
    ],
    [{spawn, F} || F <- Tests].

h1_get_returns_200() ->
    Port = start_h1_listener(client_h1_get, roadrunner_hello_handler),
    try
        {ok, Conn0} = roadrunner_bench_client:open(~"127.0.0.1", Port, h1),
        {ok, 200, Headers, Body, Conn1} =
            roadrunner_bench_client:request(Conn0, ~"GET", ~"/", [], <<>>),
        ?assertEqual(~"Hello, roadrunner!\r\n", Body),
        ?assertEqual(~"text/plain", proplists:get_value(~"content-type", Headers)),
        ok = roadrunner_bench_client:close(Conn1)
    after
        stop_listener(client_h1_get)
    end.

h1_post_echoes_body() ->
    Port = start_h1_listener(client_h1_post, roadrunner_bench_echo_handler),
    try
        {ok, Conn0} = roadrunner_bench_client:open(~"127.0.0.1", Port, h1),
        Body = <<"abc123">>,
        {ok, 200, _Headers, RespBody, Conn1} =
            roadrunner_bench_client:request(Conn0, ~"POST", ~"/echo", [], Body),
        ?assertEqual(Body, RespBody),
        ok = roadrunner_bench_client:close(Conn1)
    after
        stop_listener(client_h1_post)
    end.

h1_keepalive_n_requests() ->
    %% `roadrunner_hello_handler` sets `Connection: close` so it
    %% can't be reused — keep-alive needs a handler that omits it.
    %% `roadrunner_keepalive_handler` is the bench/stress fixture.
    Port = start_h1_listener(client_h1_ka, roadrunner_keepalive_handler),
    try
        {ok, Conn0} = roadrunner_bench_client:open(~"127.0.0.1", Port, h1),
        Conn3 = drive_n_alive(3, Conn0),
        ok = roadrunner_bench_client:close(Conn3)
    after
        stop_listener(client_h1_ka)
    end.

h2_get_returns_200() ->
    Port = start_h2_listener(client_h2_get, roadrunner_hello_handler),
    try
        {ok, Conn0} = roadrunner_bench_client:open(~"127.0.0.1", Port, h2),
        {ok, 200, _Headers, Body, Conn1} =
            roadrunner_bench_client:request(Conn0, ~"GET", ~"/", [], <<>>),
        ?assertEqual(~"Hello, roadrunner!\r\n", Body),
        ok = roadrunner_bench_client:close(Conn1)
    after
        stop_listener(client_h2_get)
    end.

h2_post_echoes_body() ->
    Port = start_h2_listener(client_h2_post, roadrunner_bench_echo_handler),
    try
        {ok, Conn0} = roadrunner_bench_client:open(~"127.0.0.1", Port, h2),
        Body = <<"echo-this-payload">>,
        {ok, 200, _Headers, RespBody, Conn1} =
            roadrunner_bench_client:request(Conn0, ~"POST", ~"/echo", [], Body),
        ?assertEqual(Body, RespBody),
        ok = roadrunner_bench_client:close(Conn1)
    after
        stop_listener(client_h2_post)
    end.

h2_keepalive_n_requests() ->
    Port = start_h2_listener(client_h2_ka, roadrunner_keepalive_handler),
    try
        {ok, Conn0} = roadrunner_bench_client:open(~"127.0.0.1", Port, h2),
        Conn5 = drive_n_alive(5, Conn0),
        ok = roadrunner_bench_client:close(Conn5)
    after
        stop_listener(client_h2_ka)
    end.

h3_returns_not_implemented() ->
    ?assertEqual(
        {error, not_implemented},
        roadrunner_bench_client:open(~"127.0.0.1", 1, h3)
    ).

open_h1_to_dead_port_errors() ->
    %% Port 1 is privileged — open returns {error, _} without crashing.
    ?assertMatch(
        {error, _},
        roadrunner_bench_client:open(~"127.0.0.1", 1, h1)
    ).

drive_n_alive(0, Conn) ->
    Conn;
drive_n_alive(N, Conn0) ->
    {ok, 200, _, ~"alive\r\n", Conn1} =
        roadrunner_bench_client:request(Conn0, ~"GET", ~"/", [], <<>>),
    drive_n_alive(N - 1, Conn1).

%% --- listener helpers ---
%%
%% Other test modules in this project (`roadrunner_listener_tests`,
%% `roadrunner_telemetry_tests`, …) bypass `application:start(roadrunner)`
%% because `roadrunner_tests` calls `application:stop(roadrunner)` in
%% its `{setup, ...}` teardown and pg is left running by other
%% tests' direct `pg:start_link/0` calls — so a fresh
%% `application:ensure_all_started(roadrunner)` after that fails
%% with `{failed_to_start_child, pg, {already_started, _}}`.
%% Match the project pattern: ensure pg, start the listener directly.

ensure_pg() ->
    case whereis(pg) of
        undefined ->
            {ok, _} = pg:start_link(),
            ok;
        _ ->
            ok
    end.

stop_listener(Name) ->
    case whereis(Name) of
        undefined ->
            ok;
        Pid ->
            Ref = monitor(process, Pid),
            unlink(Pid),
            exit(Pid, shutdown),
            receive
                {'DOWN', Ref, process, Pid, _} -> ok
            after 1000 -> ok
            end
    end.

start_h1_listener(Name, Handler) ->
    ensure_pg(),
    {ok, _} = roadrunner_listener:start_link(Name, #{port => 0, handler => Handler}),
    roadrunner_listener:port(Name).

start_h2_listener(Name, Handler) ->
    {ok, _} = application:ensure_all_started(ssl),
    ensure_pg(),
    AlpnH2 = {alpn_preferred_protocols, [~"h2", ~"http/1.1"]},
    {ok, _} = roadrunner_listener:start_link(Name, #{
        port => 0,
        tls => [AlpnH2 | roadrunner_test_certs:server_opts()],
        handler => Handler
    }),
    roadrunner_listener:port(Name).
