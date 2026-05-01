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

%% =============================================================================
%% setopts/2 + messages/1 — active-mode foundation. Real gen_tcp / ssl
%% paths are exercised via the listener integration tests; the fake-
%% transport coverage and the static atom triples are unit-tested here.
%% =============================================================================

fake_setopts_forwards_to_owner_test() ->
    Sock = {fake, self()},
    ok = cactus_transport:setopts(Sock, [{active, once}]),
    receive
        {cactus_fake_setopts, ConnPid, Opts} ->
            ?assertEqual(self(), ConnPid),
            ?assertEqual([{active, once}], Opts)
    after 1000 -> error(no_setopts_message)
    end.

setopts_on_real_gen_tcp_socket_test() ->
    %% Loopback listen + connect so we have a real gen_tcp socket pair
    %% to exercise the inet:setopts path. Validates the wrapper actually
    %% reaches inet, not just that it compiles.
    {ok, LSock} = gen_tcp:listen(0, [binary, {active, false}]),
    {ok, Port} = inet:port(LSock),
    {ok, Client} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}]),
    {ok, Accepted} = gen_tcp:accept(LSock),
    Sock = {gen_tcp, Accepted},
    ?assertEqual(ok, cactus_transport:setopts(Sock, [{active, once}])),
    %% Round-trip: send from client, recv as info event because we just
    %% armed once-mode.
    ok = gen_tcp:send(Client, ~"x"),
    receive
        {tcp, Accepted, ~"x"} -> ok
    after 1000 -> error(no_active_data_event)
    end,
    ok = gen_tcp:close(Client),
    ok = gen_tcp:close(Accepted),
    ok = gen_tcp:close(LSock).

messages_returns_per_transport_atom_triples_test() ->
    ?assertEqual({tcp, tcp_closed, tcp_error}, cactus_transport:messages({gen_tcp, dummy})),
    ?assertEqual({ssl, ssl_closed, ssl_error}, cactus_transport:messages({ssl, dummy})),
    ?assertEqual(
        {cactus_fake_data, cactus_fake_closed, cactus_fake_error},
        cactus_transport:messages({fake, self()})
    ).

setopts_on_real_ssl_socket_test() ->
    %% Drive the `ssl:setopts` branch through a real handshake so the
    %% wrapper is exercised end-to-end, not just typechecked.
    {ok, _} = application:ensure_all_started(ssl),
    ServerOpts =
        cactus_test_certs:server_opts() ++
            [binary, {active, false}, {reuseaddr, true}],
    {ok, LSock} = ssl:listen(0, ServerOpts),
    {ok, {_, Port}} = ssl:sockname(LSock),
    Self = self(),
    Acceptor = spawn_link(fun() ->
        {ok, Pre} = ssl:transport_accept(LSock),
        {ok, ServerSock} = ssl:handshake(Pre),
        %% Hand the server socket's controller over to the test process
        %% so active-mode messages land in our mailbox.
        ok = ssl:controlling_process(ServerSock, Self),
        Self ! {server_sock, ServerSock},
        receive
            stop -> ssl:close(ServerSock)
        end
    end),
    ClientOpts =
        [{verify, verify_none} | cactus_test_certs:client_opts()] ++
            [binary, {active, false}],
    {ok, ClientSock} = ssl:connect({127, 0, 0, 1}, Port, ClientOpts, 5000),
    ServerSock =
        receive
            {server_sock, S} -> S
        after 5000 -> error(no_handshake)
        end,
    try
        ?assertEqual(
            ok,
            cactus_transport:setopts({ssl, ServerSock}, [{active, once}])
        ),
        ok = ssl:send(ClientSock, ~"y"),
        receive
            {ssl, ServerSock, ~"y"} -> ok
        after 1000 -> error(no_active_data_event)
        end
    after
        Acceptor ! stop,
        ssl:close(ClientSock),
        ssl:close(LSock)
    end.

%% =============================================================================
%% sendfile/4 — gen_tcp covered via cactus_static integration tests; the
%% remaining variants (fake, ssl) and error branches need direct coverage.
%% =============================================================================

sendfile_via_fake_forwards_slice_test() ->
    Path = tmp_path(?FUNCTION_NAME),
    ok = file:write_file(Path, ~"abcdefghij"),
    try
        ok = cactus_transport:sendfile({fake, self()}, Path, 2, 5),
        receive
            {cactus_fake_send, From, Data} ->
                ?assertEqual(self(), From),
                ?assertEqual(~"cdefg", iolist_to_binary(Data))
        after 1000 -> error(no_send_message)
        end
    after
        file:delete(Path)
    end.

sendfile_missing_file_returns_error_test() ->
    ?assertMatch(
        {error, _},
        cactus_transport:sendfile({fake, self()}, "/no/such/path/cactus_xx", 0, 1)
    ).

sendfile_via_ssl_streams_through_chunked_fallback_test() ->
    %% TLS hides the kernel sendfile path, so cactus_transport falls
    %% back to a positioned read + ssl:send loop. Drive a >64 KiB file
    %% so the loop iterates more than once.
    {ok, _} = application:ensure_all_started(ssl),
    Path = tmp_path(?FUNCTION_NAME),
    Payload = binary:copy(<<"x">>, 96 * 1024),
    ok = file:write_file(Path, Payload),
    try
        ServerOpts =
            cactus_test_certs:server_opts() ++
                [binary, {active, false}, {reuseaddr, true}],
        {ok, LSock} = ssl:listen(0, ServerOpts),
        {ok, {_, Port}} = ssl:sockname(LSock),
        Self = self(),
        spawn_link(fun() ->
            {ok, Pre} = ssl:transport_accept(LSock),
            {ok, ServerSock} = ssl:handshake(Pre),
            Got = read_all_ssl(ServerSock, <<>>),
            Self ! {got, Got},
            ssl:close(ServerSock)
        end),
        ClientOpts =
            [{verify, verify_none} | cactus_test_certs:client_opts()] ++
                [binary, {active, false}],
        {ok, ClientSock} = ssl:connect({127, 0, 0, 1}, Port, ClientOpts, 5000),
        try
            ok = cactus_transport:sendfile(
                {ssl, ClientSock}, Path, 0, byte_size(Payload)
            )
        after
            ssl:close(ClientSock),
            ssl:close(LSock)
        end,
        receive
            {got, Received} -> ?assertEqual(Payload, Received)
        after 5000 -> error(no_payload)
        end
    after
        file:delete(Path)
    end.

sendfile_via_closed_gen_tcp_returns_error_test() ->
    %% Covers the `{error, _}` branch of `do_sendfile/4` for gen_tcp:
    %% file:sendfile/5 against a closed socket returns `{error, _}`.
    Path = tmp_path(?FUNCTION_NAME),
    ok = file:write_file(Path, ~"hello"),
    try
        {ok, LSock} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
        {ok, Port} = inet:port(LSock),
        spawn(fun() -> _ = gen_tcp:accept(LSock) end),
        timer:sleep(50),
        {ok, Sock} = gen_tcp:connect(
            {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
        ),
        ok = gen_tcp:close(Sock),
        ?assertMatch({error, _}, cactus_transport:sendfile({gen_tcp, Sock}, Path, 0, 5)),
        gen_tcp:close(LSock)
    after
        file:delete(Path)
    end.

sendfile_via_ssl_send_error_returns_error_test() ->
    %% Covers the SendFun-error branch in `sendfile_chunked_loop`: the
    %% client closes the SSL socket before `cactus_transport:sendfile`
    %% runs, so `ssl:send` inside the loop returns `{error, closed}`.
    {ok, _} = application:ensure_all_started(ssl),
    Path = tmp_path(?FUNCTION_NAME),
    ok = file:write_file(Path, binary:copy(<<"x">>, 96 * 1024)),
    try
        ServerOpts =
            cactus_test_certs:server_opts() ++
                [binary, {active, false}, {reuseaddr, true}],
        {ok, LSock} = ssl:listen(0, ServerOpts),
        {ok, {_, Port}} = ssl:sockname(LSock),
        spawn_link(fun() ->
            case ssl:transport_accept(LSock) of
                {ok, Pre} ->
                    case ssl:handshake(Pre) of
                        {ok, ServerSock} -> ssl:close(ServerSock);
                        _ -> ok
                    end;
                _ ->
                    ok
            end
        end),
        ClientOpts =
            [{verify, verify_none} | cactus_test_certs:client_opts()] ++
                [binary, {active, false}],
        {ok, ClientSock} = ssl:connect({127, 0, 0, 1}, Port, ClientOpts, 5000),
        ok = ssl:close(ClientSock),
        ?assertMatch(
            {error, _},
            cactus_transport:sendfile({ssl, ClientSock}, Path, 0, 96 * 1024)
        ),
        ssl:close(LSock)
    after
        file:delete(Path)
    end.

sendfile_via_ssl_with_length_past_eof_stops_at_eof_test() ->
    %% Covers the `eof` branch in `sendfile_chunked_loop`: caller asks
    %% for more bytes than the file holds, so the loop reads what's
    %% available and stops.
    {ok, _} = application:ensure_all_started(ssl),
    Path = tmp_path(?FUNCTION_NAME),
    Payload = ~"only-three-and-some-bytes",
    ok = file:write_file(Path, Payload),
    try
        ServerOpts =
            cactus_test_certs:server_opts() ++
                [binary, {active, false}, {reuseaddr, true}],
        {ok, LSock} = ssl:listen(0, ServerOpts),
        {ok, {_, Port}} = ssl:sockname(LSock),
        Self = self(),
        spawn_link(fun() ->
            {ok, Pre} = ssl:transport_accept(LSock),
            {ok, ServerSock} = ssl:handshake(Pre),
            Got = read_all_ssl(ServerSock, <<>>),
            Self ! {got, Got},
            ssl:close(ServerSock)
        end),
        ClientOpts =
            [{verify, verify_none} | cactus_test_certs:client_opts()] ++
                [binary, {active, false}],
        {ok, ClientSock} = ssl:connect({127, 0, 0, 1}, Port, ClientOpts, 5000),
        try
            ok = cactus_transport:sendfile(
                {ssl, ClientSock}, Path, 0, byte_size(Payload) + 1024
            )
        after
            ssl:close(ClientSock),
            ssl:close(LSock)
        end,
        receive
            {got, Received} -> ?assertEqual(Payload, Received)
        after 5000 -> error(no_payload)
        end
    after
        file:delete(Path)
    end.

tmp_path(Suffix) ->
    filename:join(
        "/tmp",
        "cactus_sendfile_test_" ++ atom_to_list(Suffix) ++ "_" ++
            integer_to_list(erlang:unique_integer([positive]))
    ).

read_all_ssl(Sock, Acc) ->
    case ssl:recv(Sock, 0, 2000) of
        {ok, Data} -> read_all_ssl(Sock, <<Acc/binary, Data/binary>>);
        {error, _} -> Acc
    end.

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
