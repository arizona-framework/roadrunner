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
%% read_body/4 — pure unit tests with a mock recv fun
%% =============================================================================

read_body_no_content_length_test() ->
    Req = req_with_headers([]),
    NoRecv = fun() -> error(should_not_be_called) end,
    ?assertEqual(
        {ok, ~"leftover bytes"},
        cactus_conn:read_body(Req, ~"leftover bytes", NoRecv, 1000)
    ).

read_body_cl_within_buffer_test() ->
    Req = req_with_headers([{~"content-length", ~"5"}]),
    NoRecv = fun() -> error(should_not_be_called) end,
    ?assertEqual(
        {ok, ~"hello"},
        cactus_conn:read_body(Req, ~"hello world", NoRecv, 1000)
    ).

read_body_cl_needs_more_recv_test() ->
    Req = req_with_headers([{~"content-length", ~"11"}]),
    Recv = fun() -> {ok, ~" world"} end,
    ?assertEqual(
        {ok, ~"hello world"},
        cactus_conn:read_body(Req, ~"hello", Recv, 1000)
    ).

read_body_cl_too_large_test() ->
    Req = req_with_headers([{~"content-length", ~"99999999"}]),
    NoRecv = fun() -> error(should_not_be_called) end,
    ?assertEqual(
        {error, content_length_too_large},
        cactus_conn:read_body(Req, ~"", NoRecv, 1000)
    ).

read_body_bad_cl_test() ->
    Req = req_with_headers([{~"content-length", ~"abc"}]),
    NoRecv = fun() -> error(should_not_be_called) end,
    ?assertEqual(
        {error, bad_content_length},
        cactus_conn:read_body(Req, ~"", NoRecv, 1000)
    ).

read_body_negative_cl_test() ->
    Req = req_with_headers([{~"content-length", ~"-5"}]),
    NoRecv = fun() -> error(should_not_be_called) end,
    ?assertEqual(
        {error, bad_content_length},
        cactus_conn:read_body(Req, ~"", NoRecv, 1000)
    ).

read_body_recv_error_test() ->
    Req = req_with_headers([{~"content-length", ~"100"}]),
    Recv = fun() -> {error, closed} end,
    ?assertEqual(
        {error, closed},
        cactus_conn:read_body(Req, ~"hi", Recv, 1000)
    ).

%% --- chunked transfer-encoding ---

read_body_chunked_single_in_buffer_test() ->
    Req = req_with_headers([{~"transfer-encoding", ~"chunked"}]),
    NoRecv = fun() -> error(should_not_be_called) end,
    ?assertEqual(
        {ok, ~"hello"},
        cactus_conn:read_body(Req, ~"5\r\nhello\r\n0\r\n\r\n", NoRecv, 1000)
    ).

read_body_chunked_multiple_in_buffer_test() ->
    Req = req_with_headers([{~"transfer-encoding", ~"chunked"}]),
    NoRecv = fun() -> error(should_not_be_called) end,
    ?assertEqual(
        {ok, ~"hellofoo"},
        cactus_conn:read_body(Req, ~"5\r\nhello\r\n3\r\nfoo\r\n0\r\n\r\n", NoRecv, 1000)
    ).

read_body_chunked_needs_more_recv_test() ->
    Req = req_with_headers([{~"transfer-encoding", ~"chunked"}]),
    %% First chunk in buffer, terminator chunk arrives via recv.
    Recv = fun() -> {ok, ~"0\r\n\r\n"} end,
    ?assertEqual(
        {ok, ~"hi"},
        cactus_conn:read_body(Req, ~"2\r\nhi\r\n", Recv, 1000)
    ).

read_body_chunked_exceeds_max_test() ->
    Req = req_with_headers([{~"transfer-encoding", ~"chunked"}]),
    NoRecv = fun() -> error(should_not_be_called) end,
    %% MaxCL=3 but the single chunk is 5 bytes.
    ?assertEqual(
        {error, content_length_too_large},
        cactus_conn:read_body(Req, ~"5\r\nhello\r\n0\r\n\r\n", NoRecv, 3)
    ).

read_body_chunked_second_chunk_exceeds_max_test() ->
    Req = req_with_headers([{~"transfer-encoding", ~"chunked"}]),
    NoRecv = fun() -> error(should_not_be_called) end,
    %% First chunk fits (3 <= 4), second chunk pushes total to 6 > 4 —
    %% the error must propagate out of the recursive read_chunked call.
    ?assertEqual(
        {error, content_length_too_large},
        cactus_conn:read_body(Req, ~"3\r\nfoo\r\n3\r\nbar\r\n0\r\n\r\n", NoRecv, 4)
    ).

read_body_chunked_bad_chunk_size_test() ->
    Req = req_with_headers([{~"transfer-encoding", ~"chunked"}]),
    NoRecv = fun() -> error(should_not_be_called) end,
    ?assertEqual(
        {error, bad_chunk_size},
        cactus_conn:read_body(Req, ~"xyz\r\nhello\r\n", NoRecv, 1000)
    ).

read_body_chunked_recv_error_test() ->
    Req = req_with_headers([{~"transfer-encoding", ~"chunked"}]),
    Recv = fun() -> {error, closed} end,
    ?assertEqual(
        {error, closed},
        cactus_conn:read_body(Req, ~"5\r\nhel", Recv, 1000)
    ).

read_body_unknown_transfer_encoding_rejected_test() ->
    Req = req_with_headers([{~"transfer-encoding", ~"gzip"}]),
    NoRecv = fun() -> error(should_not_be_called) end,
    ?assertEqual(
        {error, bad_transfer_encoding},
        cactus_conn:read_body(Req, ~"", NoRecv, 1000)
    ).

%% --- peer/1 ---

peer_on_closed_socket_returns_undefined_test() ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(Listen),
    {ok, Client} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
    {ok, Server} = gen_tcp:accept(Listen, 1000),
    ok = gen_tcp:close(Server),
    ?assertEqual(undefined, cactus_conn:peer({gen_tcp, Server})),
    ok = gen_tcp:close(Client),
    ok = gen_tcp:close(Listen).

req_with_headers(Headers) ->
    #{
        method => ~"POST",
        target => ~"/",
        version => {1, 1},
        headers => Headers
    }.

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

conn_handler_can_read_body_test_() ->
    {setup,
        fun() ->
            {ok, _} = cactus_listener:start_link(conn_test_body, #{
                port => 0, handler => cactus_echo_body_handler
            }),
            cactus_listener:port(conn_test_body)
        end,
        fun(_) -> ok = cactus_listener:stop(conn_test_body) end, fun(Port) ->
            {"handler reads request body via cactus_req:body/1", fun() ->
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                ok = gen_tcp:send(
                    Sock,
                    ~"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 11\r\n\r\nhello world"
                ),
                Reply = recv_until_closed(Sock),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
                {match, _} = re:run(Reply, ~"hello world"),
                ok = gen_tcp:close(Sock)
            end}
        end}.

conn_rejects_excessive_content_length_test_() ->
    {setup,
        fun() ->
            %% Configure a small max so the test is fast.
            {ok, _} = cactus_listener:start_link(conn_test_413, #{
                port => 0, max_content_length => 100
            }),
            cactus_listener:port(conn_test_413)
        end,
        fun(_) -> ok = cactus_listener:stop(conn_test_413) end, fun(Port) ->
            {"Content-Length above the configured max returns 413", fun() ->
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                %% Claim a body 10x the limit; we never have to actually send it.
                ok = gen_tcp:send(
                    Sock,
                    ~"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 1000\r\n\r\n"
                ),
                Reply = recv_until_closed(Sock),
                ?assertMatch(<<"HTTP/1.1 413 ", _/binary>>, Reply),
                ok = gen_tcp:close(Sock)
            end}
        end}.

conn_rejects_malformed_content_length_test_() ->
    {setup,
        fun() ->
            {ok, _} = cactus_listener:start_link(conn_test_bad_cl, #{port => 0}),
            cactus_listener:port(conn_test_bad_cl)
        end,
        fun(_) -> ok = cactus_listener:stop(conn_test_bad_cl) end, fun(Port) ->
            {"non-integer Content-Length returns 400", fun() ->
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                ok = gen_tcp:send(
                    Sock,
                    ~"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: abc\r\n\r\n"
                ),
                Reply = recv_until_closed(Sock),
                ?assertMatch(<<"HTTP/1.1 400 ", _/binary>>, Reply),
                ok = gen_tcp:close(Sock)
            end}
        end}.

conn_decodes_chunked_body_test_() ->
    {setup,
        fun() ->
            {ok, _} = cactus_listener:start_link(conn_test_chunked, #{
                port => 0, handler => cactus_echo_body_handler
            }),
            cactus_listener:port(conn_test_chunked)
        end,
        fun(_) -> ok = cactus_listener:stop(conn_test_chunked) end, fun(Port) ->
            {"chunked body is decoded before reaching the handler", fun() ->
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                ChunkedBody = ~"5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n",
                ok = gen_tcp:send(
                    Sock,
                    <<"POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n",
                        ChunkedBody/binary>>
                ),
                Reply = recv_until_closed(Sock),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
                {match, _} = re:run(Reply, ~"hello world"),
                ok = gen_tcp:close(Sock)
            end}
        end}.

conn_dispatches_via_router_test_() ->
    {setup,
        fun() ->
            {ok, _} = cactus_listener:start_link(conn_test_routes, #{
                port => 0,
                routes => [
                    {~"/", cactus_hello_handler, undefined},
                    {~"/created", cactus_test_handler, undefined}
                ]
            }),
            cactus_listener:port(conn_test_routes)
        end,
        fun(_) -> ok = cactus_listener:stop(conn_test_routes) end, fun(Port) ->
            [
                {"path / dispatches to cactus_hello_handler", fun() ->
                    assert_status(Port, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n", 200)
                end},
                {"path /created dispatches to cactus_test_handler", fun() ->
                    assert_status(Port, ~"GET /created HTTP/1.1\r\nHost: x\r\n\r\n", 201)
                end},
                {"unknown path returns 404", fun() ->
                    assert_status(Port, ~"GET /missing HTTP/1.1\r\nHost: x\r\n\r\n", 404)
                end}
            ]
        end}.

conn_passes_bindings_to_handler_test_() ->
    {setup,
        fun() ->
            {ok, _} = cactus_listener:start_link(conn_test_bindings, #{
                port => 0,
                routes => [{~"/users/:id", cactus_bindings_handler, undefined}]
            }),
            cactus_listener:port(conn_test_bindings)
        end,
        fun(_) -> ok = cactus_listener:stop(conn_test_bindings) end, fun(Port) ->
            {"handler reads :id from cactus_req:bindings/1", fun() ->
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                ok = gen_tcp:send(Sock, ~"GET /users/42 HTTP/1.1\r\nHost: x\r\n\r\n"),
                Reply = recv_until_closed(Sock),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
                {match, _} = re:run(Reply, ~"id=42"),
                ok = gen_tcp:close(Sock)
            end}
        end}.

conn_request_timeout_returns_408_test_() ->
    {setup,
        fun() ->
            {ok, _} = cactus_listener:start_link(conn_test_timeout, #{
                port => 0, request_timeout => 100
            }),
            cactus_listener:port(conn_test_timeout)
        end,
        fun(_) -> ok = cactus_listener:stop(conn_test_timeout) end, fun(Port) ->
            {"silent client gets 408 after request_timeout", fun() ->
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                %% Send nothing; wait for the server's deadline.
                Reply = recv_until_closed(Sock),
                ?assertMatch(<<"HTTP/1.1 408 ", _/binary>>, Reply),
                ok = gen_tcp:close(Sock)
            end}
        end}.

conn_request_timeout_during_body_returns_408_test_() ->
    {setup,
        fun() ->
            {ok, _} = cactus_listener:start_link(conn_test_timeout_body, #{
                port => 0, request_timeout => 200
            }),
            cactus_listener:port(conn_test_timeout_body)
        end,
        fun(_) -> ok = cactus_listener:stop(conn_test_timeout_body) end, fun(Port) ->
            {"client that stops mid-body gets 408", fun() ->
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                %% Full headers, no body — server reads body up to
                %% Content-Length and times out waiting.
                ok = gen_tcp:send(
                    Sock,
                    ~"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\n"
                ),
                Reply = recv_until_closed(Sock),
                ?assertMatch(<<"HTTP/1.1 408 ", _/binary>>, Reply),
                ok = gen_tcp:close(Sock)
            end}
        end}.

conn_websocket_echo_test_() ->
    {setup, fun ws_setup/0, fun ws_cleanup/1, fun(Port) ->
        {"WebSocket upgrade + text echo + clean close", fun() ->
            Sock = ws_handshake(Port),
            send_text_frame(Sock, ~"Hi"),
            {ok, Echo} = gen_tcp:recv(Sock, 4, 1000),
            ?assertEqual(<<16#81, 16#02, "Hi">>, Echo),
            send_close_frame(Sock),
            {ok, CloseEcho} = gen_tcp:recv(Sock, 2, 1000),
            ?assertEqual(<<16#88, 16#00>>, CloseEcho),
            ok = gen_tcp:close(Sock)
        end}
    end}.

conn_websocket_ping_pong_test_() ->
    {setup, fun ws_setup/0, fun ws_cleanup/1, fun(Port) ->
        {"server replies pong with same payload as the client ping", fun() ->
            Sock = ws_handshake(Port),
            Mask = <<9, 8, 7, 6>>,
            Masked = mask_test_payload(~"abc", Mask),
            ok = gen_tcp:send(Sock, <<16#89, 16#83, Mask/binary, Masked/binary>>),
            {ok, Pong} = gen_tcp:recv(Sock, 5, 1000),
            ?assertEqual(<<16#8a, 16#03, "abc">>, Pong),
            ok = gen_tcp:close(Sock)
        end}
    end}.

conn_websocket_binary_no_reply_test_() ->
    {setup, fun ws_setup/0, fun ws_cleanup/1, fun(Port) ->
        {"binary frame yields no reply ({ok, _}); next text still echoes", fun() ->
            Sock = ws_handshake(Port),
            Mask = <<1, 2, 3, 4>>,
            BinMasked = mask_test_payload(<<7, 8>>, Mask),
            ok = gen_tcp:send(Sock, <<16#82, 16#82, Mask/binary, BinMasked/binary>>),
            send_text_frame(Sock, ~"hi"),
            {ok, Echo} = gen_tcp:recv(Sock, 4, 1000),
            ?assertEqual(<<16#81, 16#02, "hi">>, Echo),
            ok = gen_tcp:close(Sock)
        end}
    end}.

conn_websocket_handler_close_test_() ->
    {setup, fun ws_setup/0, fun ws_cleanup/1, fun(Port) ->
        {"handler returning {close, _} closes the connection", fun() ->
            Sock = ws_handshake(Port),
            send_text_frame(Sock, ~"stop"),
            {ok, CloseEcho} = gen_tcp:recv(Sock, 2, 1000),
            ?assertEqual(<<16#88, 16#00>>, CloseEcho),
            ok = gen_tcp:close(Sock)
        end}
    end}.

conn_websocket_pong_silently_handled_test_() ->
    {setup, fun ws_setup/0, fun ws_cleanup/1, fun(Port) ->
        {"client pong is silently dropped; subsequent text still echoes", fun() ->
            Sock = ws_handshake(Port),
            Mask = <<5, 6, 7, 8>>,
            PongMasked = mask_test_payload(~"x", Mask),
            %% pong frame from client (opcode 0xA = 10)
            ok = gen_tcp:send(Sock, <<16#8a, 16#81, Mask/binary, PongMasked/binary>>),
            send_text_frame(Sock, ~"hi"),
            {ok, Echo} = gen_tcp:recv(Sock, 4, 1000),
            ?assertEqual(<<16#81, 16#02, "hi">>, Echo),
            ok = gen_tcp:close(Sock)
        end}
    end}.

conn_websocket_bad_frame_closes_test_() ->
    {setup, fun ws_setup/0, fun ws_cleanup/1, fun(Port) ->
        {"frame with RSV bit set causes the server to close silently", fun() ->
            Sock = ws_handshake(Port),
            %% byte1 = 0xc1: FIN=1, RSV1=1, opcode=text — RSV1 forbidden.
            ok = gen_tcp:send(Sock, <<16#c1, 16#80, 1, 2, 3, 4>>),
            ?assertEqual({error, closed}, gen_tcp:recv(Sock, 0, 1000)),
            ok = gen_tcp:close(Sock)
        end}
    end}.

conn_websocket_client_disconnect_test_() ->
    {setup, fun ws_setup/0, fun ws_cleanup/1, fun(Port) ->
        {"client closing the TCP socket exits the ws loop cleanly", fun() ->
            %% Connect, handshake, then disconnect without sending a frame —
            %% the server's recv returns {error, closed} and ws_loop ends.
            Sock = ws_handshake(Port),
            ok = gen_tcp:close(Sock),
            %% Give the server a beat to process the FIN.
            timer:sleep(50)
        end}
    end}.

conn_websocket_bad_handshake_returns_400_test_() ->
    {setup, fun ws_setup/0, fun ws_cleanup/1, fun(Port) ->
        {"upgrade missing Sec-WebSocket-Key falls back to 400", fun() ->
            {ok, Sock} = gen_tcp:connect(
                {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
            ),
            ok = gen_tcp:send(
                Sock,
                ~"GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
            ),
            Reply = recv_until_closed(Sock),
            ?assertMatch(<<"HTTP/1.1 400 ", _/binary>>, Reply),
            ok = gen_tcp:close(Sock)
        end}
    end}.

%% --- WebSocket helpers ---

ws_setup() ->
    {ok, _} = cactus_listener:start_link(conn_test_ws, #{
        port => 0, handler => cactus_ws_upgrade_handler
    }),
    cactus_listener:port(conn_test_ws).

ws_cleanup(_) ->
    ok = cactus_listener:stop(conn_test_ws).

ws_handshake(Port) ->
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
    ok = gen_tcp:send(
        Sock,
        ~"GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
    ),
    _ = recv_until(Sock, ~"\r\n\r\n"),
    Sock.

send_text_frame(Sock, Payload) ->
    Mask = <<1, 2, 3, 4>>,
    Masked = mask_test_payload(Payload, Mask),
    Len = byte_size(Payload),
    ok = gen_tcp:send(Sock, <<16#81, 1:1, Len:7, Mask/binary, Masked/binary>>).

send_close_frame(Sock) ->
    ok = gen_tcp:send(Sock, <<16#88, 16#80, 1, 2, 3, 4>>).

mask_test_payload(Payload, MaskKey) ->
    list_to_binary([
        B bxor binary:at(MaskKey, I rem 4)
     || {I, B} <- lists:enumerate(0, binary_to_list(Payload))
    ]).

recv_until(Sock, Marker) ->
    recv_until(Sock, Marker, <<>>).

recv_until(Sock, Marker, Acc) ->
    case binary:match(Acc, Marker) of
        nomatch ->
            {ok, Data} = gen_tcp:recv(Sock, 0, 1000),
            recv_until(Sock, Marker, <<Acc/binary, Data/binary>>);
        _ ->
            Acc
    end.

conn_streams_chunked_response_test_() ->
    {setup,
        fun() ->
            {ok, _} = cactus_listener:start_link(conn_test_stream, #{
                port => 0, handler => cactus_stream_handler
            }),
            cactus_listener:port(conn_test_stream)
        end,
        fun(_) -> ok = cactus_listener:stop(conn_test_stream) end, fun(Port) ->
            {"streaming handler delivers a chunked 200 response", fun() ->
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                ok = gen_tcp:send(Sock, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"),
                Reply = recv_until_closed(Sock),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
                {match, _} = re:run(Reply, ~"transfer-encoding: chunked", [caseless]),
                %% The chunk framing should land "hello world" in the body.
                {match, _} = re:run(Reply, ~"hello"),
                {match, _} = re:run(Reply, ~"world"),
                %% Final size-0 terminator chunk.
                {match, _} = re:run(Reply, ~"\r\n0\r\n\r\n"),
                ok = gen_tcp:close(Sock)
            end}
        end}.

conn_keep_alive_serves_two_requests_test_() ->
    {setup,
        fun() ->
            {ok, _} = cactus_listener:start_link(conn_test_ka, #{
                port => 0, handler => cactus_keepalive_handler
            }),
            cactus_listener:port(conn_test_ka)
        end,
        fun(_) -> ok = cactus_listener:stop(conn_test_ka) end, fun(Port) ->
            {"two HTTP/1.1 requests on the same connection both get served", fun() ->
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                Reply1 = send_and_recv(Sock, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply1),
                Reply2 = send_and_recv(Sock, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply2),
                ok = gen_tcp:close(Sock)
            end}
        end}.

conn_keep_alive_count_limit_test_() ->
    {setup,
        fun() ->
            {ok, _} = cactus_listener:start_link(conn_test_ka_max, #{
                port => 0,
                handler => cactus_keepalive_handler,
                max_keep_alive_request => 1
            }),
            cactus_listener:port(conn_test_ka_max)
        end,
        fun(_) -> ok = cactus_listener:stop(conn_test_ka_max) end, fun(Port) ->
            {"max_keep_alive_request=1 closes after first response", fun() ->
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                ok = gen_tcp:send(Sock, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"),
                Reply = recv_until_closed(Sock),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
                ok = gen_tcp:close(Sock)
            end}
        end}.

conn_http10_default_close_test_() ->
    {setup,
        fun() ->
            {ok, _} = cactus_listener:start_link(conn_test_ka_10, #{
                port => 0, handler => cactus_keepalive_handler
            }),
            cactus_listener:port(conn_test_ka_10)
        end,
        fun(_) -> ok = cactus_listener:stop(conn_test_ka_10) end, fun(Port) ->
            {"HTTP/1.0 default-closes even when handler omits Connection: close", fun() ->
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                ok = gen_tcp:send(Sock, ~"GET / HTTP/1.0\r\nHost: x\r\n\r\n"),
                Reply = recv_until_closed(Sock),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
                ok = gen_tcp:close(Sock)
            end}
        end}.

conn_http11_explicit_close_test_() ->
    {setup,
        fun() ->
            {ok, _} = cactus_listener:start_link(conn_test_ka_close, #{
                port => 0, handler => cactus_keepalive_handler
            }),
            cactus_listener:port(conn_test_ka_close)
        end,
        fun(_) -> ok = cactus_listener:stop(conn_test_ka_close) end, fun(Port) ->
            {"HTTP/1.1 with Connection: close in request closes after response", fun() ->
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                ok = gen_tcp:send(
                    Sock,
                    ~"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
                ),
                Reply = recv_until_closed(Sock),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
                ok = gen_tcp:close(Sock)
            end}
        end}.

send_and_recv(Sock, Request) ->
    ok = gen_tcp:send(Sock, Request),
    {ok, Data} = gen_tcp:recv(Sock, 0, 1000),
    Data.

conn_handler_crash_returns_500_test_() ->
    {setup,
        fun() ->
            %% Silence the expected logger:error/1 call so the test output
            %% stays clean.
            ok = logger:set_primary_config(level, none),
            {ok, _} = cactus_listener:start_link(conn_test_crash, #{
                port => 0, handler => cactus_crashing_handler
            }),
            cactus_listener:port(conn_test_crash)
        end,
        fun(_) ->
            ok = cactus_listener:stop(conn_test_crash),
            ok = logger:set_primary_config(level, notice)
        end,
        fun(Port) ->
            {"crashing handler returns 500 instead of dropping the connection", fun() ->
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                ok = gen_tcp:send(Sock, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"),
                Reply = recv_until_closed(Sock),
                ?assertMatch(<<"HTTP/1.1 500 ", _/binary>>, Reply),
                ok = gen_tcp:close(Sock)
            end}
        end}.

conn_sends_100_continue_before_reading_body_test_() ->
    {setup,
        fun() ->
            {ok, _} = cactus_listener:start_link(conn_test_100, #{
                port => 0, handler => cactus_echo_body_handler
            }),
            cactus_listener:port(conn_test_100)
        end,
        fun(_) -> ok = cactus_listener:stop(conn_test_100) end, fun(Port) ->
            [
                {"Expect: 100-continue gets a 100 line before the body is read", fun() ->
                    {ok, Sock} = gen_tcp:connect(
                        {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                    ),
                    %% Send headers only, then wait for 100 before sending body.
                    ok = gen_tcp:send(
                        Sock,
                        <<
                            "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n"
                            "Expect: 100-continue\r\n\r\n"
                        >>
                    ),
                    {ok, Continue} = gen_tcp:recv(Sock, 25, 1000),
                    ?assertEqual(~"HTTP/1.1 100 Continue\r\n\r\n", Continue),
                    %% Now ship the body and read the final response.
                    ok = gen_tcp:send(Sock, ~"hello"),
                    Reply = recv_until_closed(Sock),
                    ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
                    {match, _} = re:run(Reply, ~"hello"),
                    ok = gen_tcp:close(Sock)
                end},
                {"no Expect header → no 100 line precedes the response", fun() ->
                    {ok, Sock} = gen_tcp:connect(
                        {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                    ),
                    ok = gen_tcp:send(
                        Sock,
                        ~"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello"
                    ),
                    Reply = recv_until_closed(Sock),
                    %% First bytes are the 200 line, not a 100 line.
                    ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
                    ok = gen_tcp:close(Sock)
                end}
            ]
        end}.

conn_head_drops_response_body_test_() ->
    {setup,
        fun() ->
            {ok, _} = cactus_listener:start_link(conn_test_head, #{
                port => 0, handler => cactus_test_handler
            }),
            cactus_listener:port(conn_test_head)
        end,
        fun(_) -> ok = cactus_listener:stop(conn_test_head) end, fun(Port) ->
            {"HEAD response keeps headers (incl. Content-Length) but drops body", fun() ->
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                ok = gen_tcp:send(Sock, ~"HEAD / HTTP/1.1\r\nHost: x\r\n\r\n"),
                Reply = recv_until_closed(Sock),
                ?assertMatch(<<"HTTP/1.1 201 Created", _/binary>>, Reply),
                %% Content-Length still reflects what GET would return.
                {match, _} = re:run(Reply, ~"content-length: 23", [caseless]),
                %% No body bytes after the header terminator.
                [_Headers, Body] = binary:split(Reply, ~"\r\n\r\n"),
                ?assertEqual(~"", Body),
                ok = gen_tcp:close(Sock)
            end}
        end}.

conn_populates_peer_in_request_test_() ->
    {setup,
        fun() ->
            {ok, _} = cactus_listener:start_link(conn_test_peer, #{
                port => 0, handler => cactus_peer_handler
            }),
            cactus_listener:port(conn_test_peer)
        end,
        fun(_) -> ok = cactus_listener:stop(conn_test_peer) end, fun(Port) ->
            {"handler sees a peer tuple from inet:peername/1", fun() ->
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                ok = gen_tcp:send(Sock, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"),
                Reply = recv_until_closed(Sock),
                {match, _} = re:run(Reply, ~"peer=ok"),
                ok = gen_tcp:close(Sock)
            end}
        end}.

%% --- helpers ---

assert_status(Port, Request, ExpectedCode) ->
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
    ok = gen_tcp:send(Sock, Request),
    Reply = recv_until_closed(Sock),
    Prefix = iolist_to_binary([
        ~"HTTP/1.1 ", integer_to_binary(ExpectedCode), ~" "
    ]),
    Size = byte_size(Prefix),
    ?assertEqual(Prefix, binary:part(Reply, 0, Size)),
    ok = gen_tcp:close(Sock).

recv_until_closed(Sock) ->
    recv_until_closed(Sock, <<>>).

recv_until_closed(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 2000) of
        {ok, Data} -> recv_until_closed(Sock, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc;
        {error, _} -> Acc
    end.
