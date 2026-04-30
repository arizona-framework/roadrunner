-module(cactus_conn_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% parse_loop/2 — pure unit tests with a mock recv fun
%% =============================================================================

parse_loop_full_buffer_test() ->
    Buf = ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n",
    NoRecv = fun() -> error(should_not_be_called) end,
    {ok, Req, Rest} = cactus_conn:parse_loop(Buf, NoRecv),
    ?assertEqual(~"GET", maps:get(method, Req)),
    ?assertEqual(~"", Rest).

parse_loop_more_then_done_test() ->
    Buf = ~"GET / HTTP/1.1\r\n",
    Recv = fun() -> {ok, ~"Host: x\r\n\r\n"} end,
    {ok, Req, _Rest} = cactus_conn:parse_loop(Buf, Recv),
    ?assertEqual(~"GET", maps:get(method, Req)).

parse_loop_recv_error_test() ->
    Buf = ~"GET / HTTP/1.1\r\n",
    Recv = fun() -> {error, closed} end,
    ?assertEqual({error, closed}, cactus_conn:parse_loop(Buf, Recv)).

parse_loop_parse_error_test() ->
    NoRecv = fun() -> error(should_not_be_called) end,
    ?assertEqual(
        {error, bad_request_line},
        cactus_conn:parse_loop(~"BAD\r\n\r\n", NoRecv)
    ).

%% =============================================================================
%% End-to-end integration over a real TCP socket
%% =============================================================================

conn_serves_200_on_get_test_() ->
    {setup,
        fun() ->
            {ok, _} = cactus_listener:start_link(conn_test_get, #{port => 0}),
            cactus_listener:port(conn_test_get)
        end,
        fun(_) -> ok = cactus_listener:stop(conn_test_get) end, fun(Port) ->
            {"GET request gets a 200 with the hello body", fun() ->
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                ok = gen_tcp:send(Sock, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"),
                Reply = recv_until_closed(Sock),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
                {match, _} = re:run(Reply, ~"Hello, cactus!"),
                ok = gen_tcp:close(Sock)
            end}
        end}.

conn_serves_400_on_bad_request_test_() ->
    {setup,
        fun() ->
            {ok, _} = cactus_listener:start_link(conn_test_bad, #{port => 0}),
            cactus_listener:port(conn_test_bad)
        end,
        fun(_) -> ok = cactus_listener:stop(conn_test_bad) end, fun(Port) ->
            {"malformed request gets a 400", fun() ->
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                %% Lowercase method violates our token grammar (uppercase only).
                ok = gen_tcp:send(Sock, ~"get / HTTP/1.1\r\nHost: x\r\n\r\n"),
                Reply = recv_until_closed(Sock),
                ?assertMatch(<<"HTTP/1.1 400 Bad Request", _/binary>>, Reply),
                ok = gen_tcp:close(Sock)
            end}
        end}.

conn_dispatches_to_custom_handler_test_() ->
    {setup,
        fun() ->
            {ok, _} = cactus_listener:start_link(conn_test_custom, #{
                port => 0, handler => cactus_test_handler
            }),
            cactus_listener:port(conn_test_custom)
        end,
        fun(_) -> ok = cactus_listener:stop(conn_test_custom) end, fun(Port) ->
            {"custom handler's response is sent on the wire", fun() ->
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                ok = gen_tcp:send(Sock, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"),
                Reply = recv_until_closed(Sock),
                ?assertMatch(<<"HTTP/1.1 201 Created", _/binary>>, Reply),
                {match, _} = re:run(Reply, ~"custom handler response"),
                ok = gen_tcp:close(Sock)
            end}
        end}.

%% --- helpers ---

recv_until_closed(Sock) ->
    recv_until_closed(Sock, <<>>).

recv_until_closed(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 2000) of
        {ok, Data} -> recv_until_closed(Sock, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc;
        {error, _} -> Acc
    end.
