-module(cactus_transport_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% TLS hardened defaults — see cactus_transport:default_tls_opts/0 and the
%% OTP ssl_hardening guide.
%% =============================================================================

default_tls_opts_pins_security_keys_test() ->
    {ok, _} = application:ensure_all_started(ssl),
    Opts = cactus_transport:default_tls_opts(),
    ?assertEqual(
        {versions, ['tlsv1.3', 'tlsv1.2']}, lists:keyfind(versions, 1, Opts)
    ),
    ?assertEqual(
        {honor_cipher_order, true}, lists:keyfind(honor_cipher_order, 1, Opts)
    ),
    ?assertEqual(
        {client_renegotiation, false}, lists:keyfind(client_renegotiation, 1, Opts)
    ),
    ?assertEqual(
        {secure_renegotiate, true}, lists:keyfind(secure_renegotiate, 1, Opts)
    ),
    ?assertEqual({early_data, disabled}, lists:keyfind(early_data, 1, Opts)),
    ?assertEqual({reuse_sessions, true}, lists:keyfind(reuse_sessions, 1, Opts)),
    ?assertEqual(
        {alpn_preferred_protocols, [~"http/1.1"]},
        lists:keyfind(alpn_preferred_protocols, 1, Opts)
    ).

default_tls_opts_ciphers_are_aead_pfs_only_test() ->
    {ok, _} = application:ensure_all_started(ssl),
    {ciphers, Ciphers} = lists:keyfind(ciphers, 1, cactus_transport:default_tls_opts()),
    ?assertNotEqual([], Ciphers),
    %% Every cipher uses AEAD MAC.
    [?assertMatch(#{mac := aead}, C) || C <- Ciphers],
    %% Key exchange is either TLS 1.3 ('any') or TLS 1.2 ECDHE — no
    %% static-RSA, no DH-DSS, no ECDH (non-ephemeral).
    [
        ?assert(lists:member(KX, [any, ecdhe_ecdsa, ecdhe_rsa]))
     || #{key_exchange := KX} <- Ciphers
    ],
    %% List passes ssl:filter_cipher_suites/2 round-trip — guards
    %% against typos that silently drop suites at handshake time.
    ?assertEqual(Ciphers, ssl:filter_cipher_suites(Ciphers, [])).

default_tls_opts_signature_algs_excludes_sha1_test() ->
    {ok, _} = application:ensure_all_started(ssl),
    {signature_algs, Algs} = lists:keyfind(
        signature_algs, 1, cactus_transport:default_tls_opts()
    ),
    ?assertNotEqual([], Algs),
    %% No legacy {sha, _} entries. (OTP defaults already exclude
    %% them; this test guards against future drift.)
    [
        ?assertNot(element(1, A) =:= sha)
     || A <- Algs, is_tuple(A)
    ].

default_tls_opts_supported_groups_starts_with_pq_hybrid_test() ->
    {ok, _} = application:ensure_all_started(ssl),
    {supported_groups, [First | _] = Groups} =
        lists:keyfind(supported_groups, 1, cactus_transport:default_tls_opts()),
    %% PQ-hybrid first per OTP default.
    ?assertEqual(x25519mlkem768, First),
    ?assert(lists:member(x25519, Groups)).

apply_tls_defaults_with_empty_user_opts_returns_all_defaults_test() ->
    {ok, _} = application:ensure_all_started(ssl),
    ?assertEqual(
        cactus_transport:default_tls_opts(), cactus_transport:apply_tls_defaults([])
    ).

apply_tls_defaults_user_opt_overrides_default_test() ->
    {ok, _} = application:ensure_all_started(ssl),
    Result = cactus_transport:apply_tls_defaults([{versions, ['tlsv1.3']}]),
    %% User's versions wins; no second {versions, _} entry.
    ?assertEqual({versions, ['tlsv1.3']}, lists:keyfind(versions, 1, Result)),
    OnlyOne = [Opt || {versions, _} = Opt <- Result],
    ?assertEqual(1, length(OnlyOne)),
    %% Other defaults still present.
    ?assertMatch({honor_cipher_order, true}, lists:keyfind(honor_cipher_order, 1, Result)).

apply_tls_defaults_preserves_user_cert_opts_test() ->
    {ok, _} = application:ensure_all_started(ssl),
    UserOpts = [{cert, ~"DER-bytes"}, {key, {rsa, ~"key-bytes"}}],
    Result = cactus_transport:apply_tls_defaults(UserOpts),
    ?assertEqual({cert, ~"DER-bytes"}, lists:keyfind(cert, 1, Result)),
    ?assertEqual({key, {rsa, ~"key-bytes"}}, lists:keyfind(key, 1, Result)),
    ?assertMatch({versions, _}, lists:keyfind(versions, 1, Result)).

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
        middlewares => [],
        max_content_length => 10485760,
        request_timeout => 5000,
        keep_alive_timeout => 5000,
        max_keep_alive_request => 100,
        max_clients => 10,
        client_counter => atomics:new(1, [{signed, false}]),
        requests_counter => atomics:new(1, [{signed, false}]),
        minimum_bytes_per_second => 0,
        body_buffering => auto
    }.
