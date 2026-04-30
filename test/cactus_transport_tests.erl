-module(cactus_transport_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Negative ssl-side coverage. Happy paths are exercised by the gen_tcp
%% conn tests and the cactus_tls_tests integration test.
%% =============================================================================

listen_tls_with_no_cert_returns_error_test() ->
    {ok, _} = application:ensure_all_started(ssl),
    %% No cert/key in opts — ssl:listen rejects before binding.
    ?assertMatch({error, _}, cactus_transport:listen_tls(0, [])).

accept_handshake_failure_returns_error_test() ->
    %% Set up a TLS listener, connect to it via plain TCP, send non-TLS
    %% bytes — the server's ssl:handshake fails, propagating an error.
    {ok, _} = application:ensure_all_started(ssl),
    ServerOpts = cactus_test_certs:server_opts(),
    {ok, LSocket} = cactus_transport:listen_tls(
        0, ServerOpts ++ [binary, {active, false}, {reuseaddr, true}]
    ),
    {ok, Port} = cactus_transport:port(LSocket),
    Self = self(),
    spawn(fun() ->
        Self ! {accept_result, cactus_transport:accept(LSocket)}
    end),
    %% Give the server time to enter accept.
    timer:sleep(50),
    {ok, Client} = gen_tcp:connect(
        {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
    ),
    %% Plain HTTP bytes can't form a TLS hello.
    ok = gen_tcp:send(Client, ~"GET / HTTP/1.1\r\n\r\n"),
    Result =
        receive
            {accept_result, R} -> R
        after 5000 -> error(accept_timeout)
        end,
    ?assertMatch({error, _}, Result),
    cactus_transport:close(LSocket),
    gen_tcp:close(Client).

port_on_closed_ssl_socket_returns_error_test() ->
    {ok, _} = application:ensure_all_started(ssl),
    ServerOpts = cactus_test_certs:server_opts(),
    {ok, S} = cactus_transport:listen_tls(
        0, ServerOpts ++ [binary, {active, false}, {reuseaddr, true}]
    ),
    cactus_transport:close(S),
    ?assertMatch({error, _}, cactus_transport:port(S)).
