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

%% =============================================================================
%% Fake transport — message-driven test backend.
%% =============================================================================

fake_send_forwards_to_owner_test() ->
    Sock = {fake, self()},
    ok = cactus_transport:send(Sock, [~"hello ", ~"world"]),
    receive
        {cactus_fake_send, From, Data} ->
            ?assertEqual(self(), From),
            ?assertEqual(~"hello world", iolist_to_binary(Data))
    after 1000 -> error(no_send_message)
    end.

fake_recv_blocks_for_reply_test() ->
    Sock = {fake, self()},
    Self = self(),
    spawn(fun() ->
        Result = cactus_transport:recv(Sock, 0, 100),
        Self ! {recv_returned, Result}
    end),
    receive
        {cactus_fake_recv, ConnPid, _Len, _Timeout} ->
            ConnPid ! {cactus_fake_recv_reply, {ok, ~"data"}}
    after 1000 -> error(no_recv_message)
    end,
    receive
        {recv_returned, R} -> ?assertEqual({ok, ~"data"}, R)
    after 1000 -> error(no_recv_return)
    end.

fake_close_forwards_to_owner_test() ->
    Sock = {fake, self()},
    ok = cactus_transport:close(Sock),
    receive
        {cactus_fake_close, From} -> ?assertEqual(self(), From)
    after 1000 -> error(no_close_message)
    end.

fake_peername_returns_stub_test() ->
    ?assertEqual({ok, {{127, 0, 0, 1}, 0}}, cactus_transport:peername({fake, self()})).

fake_controlling_process_is_noop_test() ->
    ?assertEqual(ok, cactus_transport:controlling_process({fake, self()}, self())).

%% End-to-end: drive cactus_conn with a fake socket and assert the
%% wire response, no listener / acceptor / port involved.
fake_conn_drives_handler_without_sockets_test() ->
    Self = self(),
    {ok, ConnPid} = cactus_conn:start({fake, Self}, fake_proto_opts(cactus_test_handler)),
    ConnPid ! shoot,
    %% Conn enters its parse loop and asks for bytes.
    receive
        {cactus_fake_recv, ConnPid, _Len, _Timeout} ->
            ConnPid ! {cactus_fake_recv_reply, {ok, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"}}
    after 1000 -> error(no_recv_request)
    end,
    %% Handler runs and conn writes the response.
    Reply =
        receive
            {cactus_fake_send, ConnPid, Data} -> iolist_to_binary(Data)
        after 1000 -> error(no_send)
        end,
    ?assertMatch(<<"HTTP/1.1 201 Created", _/binary>>, Reply),
    %% cactus_test_handler sets `Connection: close`, so the conn closes.
    receive
        {cactus_fake_close, ConnPid} -> ok
    after 1000 -> error(no_close)
    end.

fake_proto_opts(Handler) ->
    #{
        dispatch => {handler, Handler},
        max_content_length => 10485760,
        request_timeout => 5000,
        keep_alive_timeout => 5000,
        max_keep_alive_request => 100,
        max_clients => 10,
        client_counter => atomics:new(1, [{signed, false}]),
        minimum_bytes_per_second => 0
    }.
