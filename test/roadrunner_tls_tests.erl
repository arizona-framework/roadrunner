-module(roadrunner_tls_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% End-to-end TLS over a real ssl:connect using a test PKI generated at
%% setup time via public_key:pkix_test_data/1.
%% =============================================================================

tls_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun({Port, ClientOpts}) ->
        [
            {"TLS GET / returns 200 Hello", fun() ->
                {ok, Sock} = ssl:connect(
                    {127, 0, 0, 1}, Port, ClientOpts ++ [binary, {active, false}], 5000
                ),
                ok = ssl:send(Sock, ~"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"),
                Reply = recv_until_closed(Sock),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
                {match, _} = re:run(Reply, ~"Hello, roadrunner!"),
                ok = ssl:close(Sock)
            end},
            {"TLS POST with body exercises ssl:recv body-read path", fun() ->
                {ok, Sock} = ssl:connect(
                    {127, 0, 0, 1}, Port, ClientOpts ++ [binary, {active, false}], 5000
                ),
                %% Send headers, sleep so the conn moves to reading_body
                %% and blocks in `roadrunner_transport:recv` (which dispatches
                %% to `ssl:recv` for the {ssl, _} variant), then deliver
                %% the body. Without the sleep, the kernel may deliver
                %% headers + body in one chunk and the body bytes are
                %% already in the active-mode buffer when reading_body
                %% runs — bypassing the recv path we want to cover.
                ok = ssl:send(
                    Sock,
                    ~"POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4\r\n\r\n"
                ),
                timer:sleep(50),
                ok = ssl:send(Sock, ~"body"),
                Reply = recv_until_closed(Sock),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
                ok = ssl:close(Sock)
            end}
        ]
    end}.

%% --- helpers ---

setup() ->
    {ok, _} = application:ensure_all_started(ssl),
    %% Loosen client verification — the test cert isn't in any system root.
    ClientOpts = [{verify, verify_none} | roadrunner_test_certs:client_opts()],
    {ok, _} = roadrunner_listener:start_link(tls_test_listener, #{
        port => 0, tls => roadrunner_test_certs:server_opts()
    }),
    Port = roadrunner_listener:port(tls_test_listener),
    {Port, ClientOpts}.

cleanup(_) ->
    ok = roadrunner_listener:stop(tls_test_listener).

%% =============================================================================
%% HTTP/2 ALPN dispatch — `http2_enabled => true` advertises `h2`,
%% h2-capable clients reach `roadrunner_conn_loop_h2` (Phase H1 stub
%% sends empty SETTINGS + GOAWAY and closes). h1 clients on the same
%% listener still get the HTTP/1.1 path.
%% =============================================================================

h2_alpn_dispatch_test_() ->
    {setup, fun setup_h2/0, fun cleanup_h2/1, fun({Port, ClientOpts}) ->
        [
            {"h2 ALPN reaches the conn_loop_h2 stub (SETTINGS + GOAWAY)", fun() ->
                {ok, Sock} = ssl:connect(
                    {127, 0, 0, 1},
                    Port,
                    ClientOpts ++ [binary, {active, false}, {alpn_advertised_protocols, [~"h2"]}],
                    5000
                ),
                ?assertEqual({ok, ~"h2"}, ssl:negotiated_protocol(Sock)),
                Reply = recv_until_closed(Sock),
                %% Empty SETTINGS frame: 9-byte header (length=0, type=4,
                %% flags=0, stream id=0).
                ?assertMatch(<<0, 0, 0, 4, 0, 0, 0, 0, 0, _/binary>>, Reply),
                %% GOAWAY follows: type 7, payload = last_stream_id 0 + error_code 0.
                ?assertMatch(
                    <<_:9/binary, 0, 0, 8, 7, 0, 0, 0, 0, 0, 0:32, 0:32>>,
                    Reply
                ),
                ok = ssl:close(Sock)
            end},
            {"http/1.1 ALPN on the same listener still serves HTTP/1.1", fun() ->
                {ok, Sock} = ssl:connect(
                    {127, 0, 0, 1},
                    Port,
                    ClientOpts ++
                        [binary, {active, false}, {alpn_advertised_protocols, [~"http/1.1"]}],
                    5000
                ),
                ?assertEqual({ok, ~"http/1.1"}, ssl:negotiated_protocol(Sock)),
                ok = ssl:send(Sock, ~"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"),
                Reply = recv_until_closed(Sock),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
                ok = ssl:close(Sock)
            end},
            {"client offering NO ALPN falls through to HTTP/1.1", fun() ->
                %% Reaches the `{error, protocol_not_negotiated} -> undefined`
                %% branch of `roadrunner_transport:negotiated_alpn/1` —
                %% server has h2 in its preferred list but the client
                %% didn't offer ALPN at all, so `ssl:negotiated_protocol/1`
                %% returns an error and the dispatch defaults to h1.
                {ok, Sock} = ssl:connect(
                    {127, 0, 0, 1}, Port, ClientOpts ++ [binary, {active, false}], 5000
                ),
                ?assertMatch({error, _}, ssl:negotiated_protocol(Sock)),
                ok = ssl:send(Sock, ~"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"),
                Reply = recv_until_closed(Sock),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
                ok = ssl:close(Sock)
            end}
        ]
    end}.

setup_h2() ->
    {ok, _} = application:ensure_all_started(ssl),
    ClientOpts = [{verify, verify_none} | roadrunner_test_certs:client_opts()],
    {ok, _} = roadrunner_listener:start_link(tls_h2_test_listener, #{
        port => 0,
        tls => roadrunner_test_certs:server_opts(),
        http2_enabled => true
    }),
    Port = roadrunner_listener:port(tls_h2_test_listener),
    {Port, ClientOpts}.

cleanup_h2(_) ->
    ok = roadrunner_listener:stop(tls_h2_test_listener).

%% User-supplied `alpn_preferred_protocols` always wins, even if
%% `http2_enabled => true`. Verifies the listener doesn't blindly
%% prepend `h2` when the user has explicit ALPN intent.
h2_user_alpn_overrides_test_() ->
    {setup,
        fun() ->
            {ok, _} = application:ensure_all_started(ssl),
            ClientOpts = [{verify, verify_none} | roadrunner_test_certs:client_opts()],
            UserAlpn = {alpn_preferred_protocols, [~"http/1.1"]},
            UserTls = [UserAlpn | roadrunner_test_certs:server_opts()],
            {ok, _} = roadrunner_listener:start_link(tls_h2_user_alpn_listener, #{
                port => 0,
                tls => UserTls,
                http2_enabled => true
            }),
            Port = roadrunner_listener:port(tls_h2_user_alpn_listener),
            {Port, ClientOpts}
        end,
        fun(_) ->
            ok = roadrunner_listener:stop(tls_h2_user_alpn_listener)
        end,
        fun({Port, ClientOpts}) ->
            [
                {"client offering h2 still gets http/1.1 because user opts pinned ALPN", fun() ->
                    {ok, Sock} = ssl:connect(
                        {127, 0, 0, 1},
                        Port,
                        ClientOpts ++
                            [
                                binary,
                                {active, false},
                                {alpn_advertised_protocols, [~"h2", ~"http/1.1"]}
                            ],
                        5000
                    ),
                    ?assertEqual({ok, ~"http/1.1"}, ssl:negotiated_protocol(Sock)),
                    ok = ssl:close(Sock)
                end}
            ]
        end}.

recv_until_closed(Sock) ->
    recv_until_closed(Sock, <<>>).

recv_until_closed(Sock, Acc) ->
    case ssl:recv(Sock, 0, 2000) of
        {ok, Data} -> recv_until_closed(Sock, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc;
        {error, _} -> Acc
    end.
