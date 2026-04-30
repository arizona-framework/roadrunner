-module(cactus_tls_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% End-to-end TLS over a real ssl:connect using a test PKI generated at
%% setup time via public_key:pkix_test_data/1.
%% =============================================================================

tls_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun({Port, ClientOpts}) ->
        {"TLS GET / returns 200 Hello", fun() ->
            {ok, Sock} = ssl:connect(
                {127, 0, 0, 1}, Port, ClientOpts ++ [binary, {active, false}], 5000
            ),
            ok = ssl:send(Sock, ~"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"),
            Reply = recv_until_closed(Sock),
            ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
            {match, _} = re:run(Reply, ~"Hello, cactus!"),
            ok = ssl:close(Sock)
        end}
    end}.

%% --- helpers ---

setup() ->
    {ok, _} = application:ensure_all_started(ssl),
    %% Loosen client verification — the test cert isn't in any system root.
    ClientOpts = [{verify, verify_none} | cactus_test_certs:client_opts()],
    {ok, _} = cactus_listener:start_link(tls_test_listener, #{
        port => 0, tls => cactus_test_certs:server_opts()
    }),
    Port = cactus_listener:port(tls_test_listener),
    {Port, ClientOpts}.

cleanup(_) ->
    ok = cactus_listener:stop(tls_test_listener).

recv_until_closed(Sock) ->
    recv_until_closed(Sock, <<>>).

recv_until_closed(Sock, Acc) ->
    case ssl:recv(Sock, 0, 2000) of
        {ok, Data} -> recv_until_closed(Sock, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc;
        {error, _} -> Acc
    end.
