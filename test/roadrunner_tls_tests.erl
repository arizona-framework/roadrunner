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
        port => 0,
        tls => roadrunner_test_certs:server_opts(),
        routes => roadrunner_hello_handler
    }),
    Port = roadrunner_listener:port(tls_test_listener),
    {Port, ClientOpts}.

cleanup(_) ->
    ok = roadrunner_listener:stop(tls_test_listener).

%% =============================================================================
%% HTTP/2 ALPN dispatch — listing `~"h2"` in `alpn_preferred_protocols`
%% advertises h2 to clients; h2-capable clients reach
%% `roadrunner_conn_loop_http2`. Phase H2 performs the connection-level
%% handshake (preface + SETTINGS exchange + ACK) then GOAWAYs because
%% streams aren't accepted yet. h1 clients on the same listener still
%% get the HTTP/1.1 path.
%% =============================================================================

h2_alpn_dispatch_test_() ->
    {setup, fun setup_h2/0, fun cleanup_h2/1, fun({Port, ClientOpts}) ->
        [
            {"h2 GET / completes through the handler pipeline", fun() ->
                {ok, Sock} = ssl:connect(
                    {127, 0, 0, 1},
                    Port,
                    ClientOpts ++ [binary, {active, false}, {alpn_advertised_protocols, [~"h2"]}],
                    5000
                ),
                ?assertEqual({ok, ~"h2"}, ssl:negotiated_protocol(Sock)),
                %% Phase H5 end-to-end: preface + SETTINGS + HEADERS,
                %% then read the server's response frames.
                Preface = ~"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n",
                EmptySettings = <<0:24, 4, 0, 0:32>>,
                %% HEADERS frame, stream id 1, END_HEADERS|END_STREAM,
                %% HPACK-encoding ":method GET / :scheme https :authority localhost".
                Enc = roadrunner_http2_hpack:new_encoder(4096),
                {HpackBlock, _} = roadrunner_http2_hpack:encode(
                    [
                        {~":method", ~"GET"},
                        {~":scheme", ~"https"},
                        {~":authority", ~"localhost"},
                        {~":path", ~"/"}
                    ],
                    Enc
                ),
                HpackBin = iolist_to_binary(HpackBlock),
                Headers =
                    iolist_to_binary(
                        roadrunner_http2_frame:encode(
                            {headers, 1, 16#04 bor 16#01, undefined, HpackBin}
                        )
                    ),
                ok = ssl:send(Sock, [Preface, EmptySettings, Headers]),
                Reply = recv_until_closed(Sock),
                %% Server response should include a HEADERS frame
                %% (type 1) for stream id 1 followed by a DATA frame
                %% (type 0). Decode the HEADERS to verify :status.
                Dec0 = roadrunner_http2_hpack:new_decoder(4096),
                Dec1 = take_pending_settings(Reply, Dec0),
                {ok, RespHeaders} = find_response_headers(Reply, Dec1),
                ?assertEqual(
                    ~"200",
                    proplists:get_value(~":status", RespHeaders)
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
    AlpnH2 = {alpn_preferred_protocols, [~"h2", ~"http/1.1"]},
    {ok, _} = roadrunner_listener:start_link(tls_http2_test_listener, #{
        port => 0,
        tls => [AlpnH2 | roadrunner_test_certs:server_opts()],
        routes => roadrunner_hello_handler
    }),
    Port = roadrunner_listener:port(tls_http2_test_listener),
    {Port, ClientOpts}.

cleanup_h2(_) ->
    ok = roadrunner_listener:stop(tls_http2_test_listener).

%% Listener's `alpn_preferred_protocols` is the source of truth: an
%% h1-only ALPN list forces h1 even when the client offers h2.
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
                routes => roadrunner_hello_handler
            }),
            Port = roadrunner_listener:port(tls_h2_user_alpn_listener),
            {Port, ClientOpts}
        end,
        fun(_) ->
            ok = roadrunner_listener:stop(tls_h2_user_alpn_listener)
        end,
        fun({Port, ClientOpts}) ->
            [
                {"client offering h2 still gets http/1.1 because listener ALPN is h1-only", fun() ->
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

%% Walk the server's reply, draining SETTINGS / SETTINGS-ACK / etc
%% to seed the decoder context with any HPACK state-changes
%% (none for our outbound SETTINGS, but a no-op preserves
%% generality). Returns the decoder for use on the response
%% HEADERS.
take_pending_settings(_Reply, Dec) -> Dec.

%% Walk the server's reply binary frame-by-frame, returning the
%% decoded header list for the first HEADERS frame.
find_response_headers(<<>>, _Dec) ->
    {error, no_headers_frame};
find_response_headers(Reply, Dec) ->
    case roadrunner_http2_frame:parse(Reply, 16384) of
        {ok, {headers, _Stream, _Flags, _Priority, Hpack}, _Rest} ->
            case roadrunner_http2_hpack:decode(Hpack, Dec) of
                {ok, Headers, _NewDec} -> {ok, Headers};
                {error, _} = E -> E
            end;
        {ok, _OtherFrame, Rest} ->
            find_response_headers(Rest, Dec);
        _ ->
            {error, parse}
    end.
