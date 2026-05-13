-module(roadrunner_conn_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% parse_loop/2 — pure unit tests with a mock recv fun
%% =============================================================================

parse_loop_full_buffer_test() ->
    Buf = ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n",
    NoRecv = fun() -> error(should_not_be_called) end,
    {ok, Req, Rest} = roadrunner_conn:parse_loop(Buf, NoRecv),
    ?assertEqual(~"GET", maps:get(method, Req)),
    ?assertEqual(~"", Rest).

parse_loop_more_then_done_test() ->
    Buf = ~"GET / HTTP/1.1\r\n",
    Recv = fun() -> {ok, ~"Host: x\r\n\r\n"} end,
    {ok, Req, _Rest} = roadrunner_conn:parse_loop(Buf, Recv),
    ?assertEqual(~"GET", maps:get(method, Req)).

parse_loop_recv_error_test() ->
    Buf = ~"GET / HTTP/1.1\r\n",
    Recv = fun() -> {error, closed} end,
    ?assertEqual({error, closed}, roadrunner_conn:parse_loop(Buf, Recv)).

parse_loop_parse_error_test() ->
    NoRecv = fun() -> error(should_not_be_called) end,
    ?assertEqual(
        {error, bad_request_line},
        roadrunner_conn:parse_loop(~"BAD\r\n\r\n", NoRecv)
    ).

%% =============================================================================
%% read_body/4 — pure unit tests with a mock recv fun
%% =============================================================================

read_body_no_content_length_test() ->
    %% Per RFC 7230 §3.3.3: a request without Content-Length or
    %% Transfer-Encoding has zero body length. The bytes in `Buffered`
    %% are returned as `Leftover` (not as body — they belong to the
    %% pipelined next request) so the conn can thread them into the
    %% next `reading_request` parse.
    Req = req_with_headers([]),
    NoRecv = fun() -> error(should_not_be_called) end,
    ?assertEqual(
        {ok, <<>>, ~"leftover bytes"},
        roadrunner_conn:read_body(Req, ~"leftover bytes", NoRecv, 1000)
    ).

read_body_cl_within_buffer_test() ->
    Req = req_with_headers([{~"content-length", ~"5"}]),
    NoRecv = fun() -> error(should_not_be_called) end,
    ?assertEqual(
        {ok, ~"hello", ~" world"},
        roadrunner_conn:read_body(Req, ~"hello world", NoRecv, 1000)
    ).

read_body_cl_needs_more_recv_test() ->
    Req = req_with_headers([{~"content-length", ~"11"}]),
    Recv = fun() -> {ok, ~" world"} end,
    {ok, Body, Leftover} = roadrunner_conn:read_body(Req, ~"hello", Recv, 1000),
    ?assertEqual(~"hello world", iolist_to_binary(Body)),
    ?assertEqual(<<>>, Leftover).

read_body_cl_multi_chunk_recv_test() ->
    %% Body arrives in three separate recv chunks, none individually
    %% enough to satisfy Content-Length. Exercises the body-recursive
    %% iolist accumulator in `read_body_until_io/2`.
    Req = req_with_headers([{~"content-length", ~"15"}]),
    Recv = chunked_recv([~"abc", ~"defgh", ~"ijklmnop"]),
    {ok, Body, Leftover} = roadrunner_conn:read_body(Req, <<>>, Recv, 1000),
    ?assertEqual(~"abcdefghijklmno", iolist_to_binary(Body)),
    ?assertEqual(~"p", Leftover).

read_body_cl_recv_error_test() ->
    %% First recv returns an error before any body bytes arrive.
    Req = req_with_headers([{~"content-length", ~"5"}]),
    Recv = fun() -> {error, closed} end,
    ?assertEqual(
        {error, closed},
        roadrunner_conn:read_body(Req, <<>>, Recv, 1000)
    ).

read_body_cl_too_large_test() ->
    Req = req_with_headers([{~"content-length", ~"99999999"}]),
    NoRecv = fun() -> error(should_not_be_called) end,
    ?assertEqual(
        {error, content_length_too_large},
        roadrunner_conn:read_body(Req, ~"", NoRecv, 1000)
    ).

drain_oversized_body_caps_at_2x_max_test() ->
    %% A `{fake, Pid}` socket whose recv replies a 30-byte chunk. Drain
    %% must read AT MOST 2 * MaxCL bytes — bounded against memory
    %% exhaustion.
    Self = self(),
    Sink = spawn(fun() -> drain_sink_loop(Self, [{recv, binary:copy(<<"a">>, 30)}]) end),
    ok = roadrunner_conn:drain_oversized_body(<<>>, {fake, Sink}, 10),
    %% MaxCL=10 → cap=20. First recv returns 30 bytes (Read=30 >= 20)
    %% so the loop exits after exactly one call.
    Sink ! stop,
    ?assertEqual(1, drain_recv_calls(0)).

drain_oversized_body_stops_on_recv_error_test() ->
    %% Closed peer mid-drain → loop returns ok cleanly without
    %% propagating the error.
    Sink = spawn(fun() -> drain_sink_loop(undefined, [{error, closed}]) end),
    ?assertEqual(ok, roadrunner_conn:drain_oversized_body(<<>>, {fake, Sink}, 10)),
    Sink ! stop.

drain_oversized_body_counts_buffered_bytes_test() ->
    %% Already-buffered bytes count toward the cap — if the buffered
    %% body alone exceeds 2 * MaxCL, no recv call is needed.
    Self = self(),
    Sink = spawn(fun() -> drain_sink_loop(Self, []) end),
    ok = roadrunner_conn:drain_oversized_body(binary:copy(<<"a">>, 50), {fake, Sink}, 10),
    Sink ! stop,
    ?assertEqual(0, drain_recv_calls(0)).

drain_sink_loop(Reporter, Script) ->
    receive
        stop ->
            ok;
        {roadrunner_fake_recv, ConnPid, _Len, _Timeout} ->
            case Reporter of
                undefined -> ok;
                _ -> Reporter ! recv_called
            end,
            case Script of
                [] ->
                    ConnPid ! {roadrunner_fake_recv_reply, {error, closed}},
                    drain_sink_loop(Reporter, []);
                [{error, _} = Err | Rest] ->
                    ConnPid ! {roadrunner_fake_recv_reply, Err},
                    drain_sink_loop(Reporter, Rest);
                [{recv, Bytes} | Rest] ->
                    ConnPid ! {roadrunner_fake_recv_reply, {ok, Bytes}},
                    drain_sink_loop(Reporter, Rest)
            end;
        _ ->
            drain_sink_loop(Reporter, Script)
    end.

drain_recv_calls(Acc) ->
    receive
        recv_called -> drain_recv_calls(Acc + 1)
    after 0 -> Acc
    end.

read_body_bad_cl_test() ->
    Req = req_with_headers([{~"content-length", ~"abc"}]),
    NoRecv = fun() -> error(should_not_be_called) end,
    ?assertEqual(
        {error, bad_content_length},
        roadrunner_conn:read_body(Req, ~"", NoRecv, 1000)
    ).

read_body_negative_cl_test() ->
    Req = req_with_headers([{~"content-length", ~"-5"}]),
    NoRecv = fun() -> error(should_not_be_called) end,
    ?assertEqual(
        {error, bad_content_length},
        roadrunner_conn:read_body(Req, ~"", NoRecv, 1000)
    ).

read_body_recv_error_test() ->
    Req = req_with_headers([{~"content-length", ~"100"}]),
    Recv = fun() -> {error, closed} end,
    ?assertEqual(
        {error, closed},
        roadrunner_conn:read_body(Req, ~"hi", Recv, 1000)
    ).

%% --- chunked transfer-encoding ---

read_body_chunked_single_in_buffer_test() ->
    Req = req_with_headers([{~"transfer-encoding", ~"chunked"}]),
    NoRecv = fun() -> error(should_not_be_called) end,
    ?assertEqual(
        {ok, ~"hello", <<>>},
        roadrunner_conn:read_body(Req, ~"5\r\nhello\r\n0\r\n\r\n", NoRecv, 1000)
    ).

read_body_chunked_multiple_in_buffer_test() ->
    Req = req_with_headers([{~"transfer-encoding", ~"chunked"}]),
    NoRecv = fun() -> error(should_not_be_called) end,
    ?assertEqual(
        {ok, ~"hellofoo", <<>>},
        roadrunner_conn:read_body(Req, ~"5\r\nhello\r\n3\r\nfoo\r\n0\r\n\r\n", NoRecv, 1000)
    ).

read_body_chunked_needs_more_recv_test() ->
    Req = req_with_headers([{~"transfer-encoding", ~"chunked"}]),
    %% First chunk in buffer, terminator chunk arrives via recv.
    Recv = fun() -> {ok, ~"0\r\n\r\n"} end,
    ?assertEqual(
        {ok, ~"hi", <<>>},
        roadrunner_conn:read_body(Req, ~"2\r\nhi\r\n", Recv, 1000)
    ).

read_body_chunked_exceeds_max_test() ->
    Req = req_with_headers([{~"transfer-encoding", ~"chunked"}]),
    NoRecv = fun() -> error(should_not_be_called) end,
    %% MaxCL=3 but the single chunk is 5 bytes.
    ?assertEqual(
        {error, content_length_too_large},
        roadrunner_conn:read_body(Req, ~"5\r\nhello\r\n0\r\n\r\n", NoRecv, 3)
    ).

read_body_chunked_second_chunk_exceeds_max_test() ->
    Req = req_with_headers([{~"transfer-encoding", ~"chunked"}]),
    NoRecv = fun() -> error(should_not_be_called) end,
    %% First chunk fits (3 <= 4), second chunk pushes total to 6 > 4 —
    %% the error must propagate out of the recursive read_chunked call.
    ?assertEqual(
        {error, content_length_too_large},
        roadrunner_conn:read_body(Req, ~"3\r\nfoo\r\n3\r\nbar\r\n0\r\n\r\n", NoRecv, 4)
    ).

read_body_chunked_bad_chunk_size_test() ->
    Req = req_with_headers([{~"transfer-encoding", ~"chunked"}]),
    NoRecv = fun() -> error(should_not_be_called) end,
    ?assertEqual(
        {error, bad_chunk_size},
        roadrunner_conn:read_body(Req, ~"xyz\r\nhello\r\n", NoRecv, 1000)
    ).

read_body_chunked_recv_error_test() ->
    Req = req_with_headers([{~"transfer-encoding", ~"chunked"}]),
    Recv = fun() -> {error, closed} end,
    ?assertEqual(
        {error, closed},
        roadrunner_conn:read_body(Req, ~"5\r\nhel", Recv, 1000)
    ).

read_body_unknown_transfer_encoding_rejected_test() ->
    Req = req_with_headers([{~"transfer-encoding", ~"gzip"}]),
    NoRecv = fun() -> error(should_not_be_called) end,
    ?assertEqual(
        {error, bad_transfer_encoding},
        roadrunner_conn:read_body(Req, ~"", NoRecv, 1000)
    ).

read_body_chunked_case_insensitive_test() ->
    %% RFC 9110 §10.1.4: transfer-coding names are case-insensitive.
    %% `Chunked`, `CHUNKED`, `chunked` all mean the same thing.
    NoRecv = fun() -> error(should_not_be_called) end,
    [
        ?assertEqual(
            {ok, ~"hi", <<>>},
            roadrunner_conn:read_body(
                req_with_headers([{~"transfer-encoding", V}]),
                ~"2\r\nhi\r\n0\r\n\r\n",
                NoRecv,
                1000
            )
        )
     || V <- [~"chunked", ~"Chunked", ~"CHUNKED", ~"ChUnKeD"]
    ].

%% --- has_continue_expectation / keep_alive_decision fallbacks ---

%% These two helpers have a fast path for parser-built request maps
%% (which carry `cached_decisions`) and a fallback for manually-built
%% maps (which don't). Cover the fallback explicitly.

maybe_send_continue_without_cached_decisions_uses_header_test() ->
    %% Manually-built Req, no `cached_decisions`. With Expect: 100-Continue
    %% present, the helper must send the 100. Use a fake socket that
    %% records send calls.
    Self = self(),
    Sink = spawn(fun() -> continue_sink_loop(Self) end),
    Req = req_with_headers([{~"expect", ~"100-Continue"}]),
    ok = roadrunner_conn:maybe_send_continue({fake, Sink}, Req, ~""),
    Sink ! stop,
    receive
        {sent, Bytes} ->
            ?assertMatch(<<"HTTP/1.1 100 Continue\r\n\r\n">>, iolist_to_binary(Bytes))
    after 1000 ->
        ?assert(false)
    end.

maybe_send_continue_without_cached_decisions_no_expect_skips_test() ->
    %% Same path but no Expect header → no 100 sent.
    Sink = spawn(fun() -> continue_sink_loop(undefined) end),
    Req = req_with_headers([]),
    ok = roadrunner_conn:maybe_send_continue({fake, Sink}, Req, ~""),
    Sink ! stop,
    receive
        {sent, _} -> ?assert(false)
    after 50 -> ok
    end.

continue_sink_loop(Reporter) ->
    receive
        stop ->
            ok;
        {roadrunner_fake_send, ConnPid, Data} ->
            case Reporter of
                undefined -> ok;
                _ -> Reporter ! {sent, Data}
            end,
            ConnPid ! {roadrunner_fake_send_reply, ok},
            continue_sink_loop(Reporter);
        _ ->
            continue_sink_loop(Reporter)
    end.

keep_alive_decision_without_cached_decisions_uses_header_test() ->
    %% Manually-built Req with HTTP/1.1 + Connection: close → close.
    Req = req_with_headers([{~"connection", ~"Close"}]),
    ?assertEqual(close, roadrunner_conn:keep_alive_decision(Req, [])).

keep_alive_decision_without_cached_decisions_no_connection_header_keeps_alive_test() ->
    %% HTTP/1.1 default is keep-alive when neither side requests close.
    Req = req_with_headers([]),
    ?assertEqual(keep_alive, roadrunner_conn:keep_alive_decision(Req, [])).

%% --- peer/1 ---

peer_on_closed_socket_returns_undefined_test() ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(Listen),
    {ok, Client} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
    {ok, Server} = gen_tcp:accept(Listen, 1000),
    ok = gen_tcp:close(Server),
    ?assertEqual(undefined, roadrunner_conn:peer({gen_tcp, Server})),
    ok = gen_tcp:close(Client),
    ok = gen_tcp:close(Listen).

req_with_headers(Headers) ->
    #{
        method => ~"POST",
        target => ~"/",
        version => {1, 1},
        headers => Headers
    }.

%% Recv closure that yields the given chunks one per call, then
%% `{error, closed}` once exhausted. Backed by the process dictionary
%% so the same fun can drive multiple recv invocations.
chunked_recv(Chunks) ->
    Key = {?MODULE, chunked_recv, make_ref()},
    erlang:put(Key, Chunks),
    fun() ->
        case erlang:get(Key) of
            [Chunk | Rest] ->
                erlang:put(Key, Rest),
                {ok, Chunk};
            _ ->
                {error, closed}
        end
    end.

%% =============================================================================
%% End-to-end integration over a real TCP socket
%% =============================================================================

conn_serves_200_on_get_test_() ->
    {setup,
        fun() ->
            {ok, _} = roadrunner_listener:start_link(conn_test_get, #{
                port => 0, handler => roadrunner_hello_handler
            }),
            roadrunner_listener:port(conn_test_get)
        end,
        fun(_) -> ok = roadrunner_listener:stop(conn_test_get) end, fun(Port) ->
            [
                {"GET request gets a 200 with the hello body", fun() ->
                    {ok, Sock} = gen_tcp:connect(
                        {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                    ),
                    ok = gen_tcp:send(Sock, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"),
                    Reply = recv_until_closed(Sock),
                    ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
                    {match, _} = re:run(Reply, ~"Hello, roadrunner!"),
                    ok = gen_tcp:close(Sock)
                end},
                {"response auto-injects Date header per RFC 9110 §6.6.1", fun() ->
                    {ok, Sock} = gen_tcp:connect(
                        {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                    ),
                    ok = gen_tcp:send(Sock, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"),
                    Reply = recv_until_closed(Sock),
                    {match, _} = re:run(
                        Reply,
                        %% IMF-fixdate: e.g. "date: Sun, 06 Nov 1994 08:49:37 GMT"
                        "date: [A-Z][a-z]{2}, \\d{2} [A-Z][a-z]{2} \\d{4} "
                        "\\d{2}:\\d{2}:\\d{2} GMT",
                        []
                    ),
                    ok = gen_tcp:close(Sock)
                end}
            ]
        end}.

conn_handler_emitted_date_is_preserved_test_() ->
    %% When a handler explicitly sets `Date` (e.g. for replay or
    %% pre-recorded fixtures), the framework's auto-injection MUST
    %% NOT override it.
    {setup,
        fun() ->
            {ok, _} = roadrunner_listener:start_link(conn_test_date, #{
                port => 0,
                handler => roadrunner_explicit_date_handler
            }),
            roadrunner_listener:port(conn_test_date)
        end,
        fun(_) -> ok = roadrunner_listener:stop(conn_test_date) end, fun(Port) ->
            {"handler's explicit Date wins over auto-injection", fun() ->
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                ok = gen_tcp:send(Sock, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"),
                Reply = recv_until_closed(Sock),
                {match, _} = re:run(
                    Reply,
                    "date: Sun, 06 Nov 1994 08:49:37 GMT",
                    []
                ),
                %% No second Date header — the auto-inject should have
                %% deferred to the handler's value.
                Lines = binary:split(Reply, ~"\r\n", [global]),
                DateCount = length([
                    L
                 || L <- Lines,
                    binary:match(L, ~"date:") =:= {0, 5} orelse
                        binary:match(L, ~"Date:") =:= {0, 5}
                ]),
                ?assertEqual(1, DateCount),
                ok = gen_tcp:close(Sock)
            end}
        end}.

conn_serves_400_on_bad_request_test_() ->
    {setup,
        fun() ->
            {ok, _} = roadrunner_listener:start_link(conn_test_bad, #{
                port => 0, handler => roadrunner_hello_handler
            }),
            roadrunner_listener:port(conn_test_bad)
        end,
        fun(_) -> ok = roadrunner_listener:stop(conn_test_bad) end, fun(Port) ->
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
            {ok, _} = roadrunner_listener:start_link(conn_test_custom, #{
                port => 0, handler => roadrunner_test_handler
            }),
            roadrunner_listener:port(conn_test_custom)
        end,
        fun(_) -> ok = roadrunner_listener:stop(conn_test_custom) end, fun(Port) ->
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
            {ok, _} = roadrunner_listener:start_link(conn_test_body, #{
                port => 0, handler => roadrunner_echo_body_handler
            }),
            roadrunner_listener:port(conn_test_body)
        end,
        fun(_) -> ok = roadrunner_listener:stop(conn_test_body) end, fun(Port) ->
            {"handler reads request body via roadrunner_req:body/1", fun() ->
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
            {ok, _} = roadrunner_listener:start_link(conn_test_413, #{
                port => 0,
                max_content_length => 100,
                handler => roadrunner_hello_handler
            }),
            roadrunner_listener:port(conn_test_413)
        end,
        fun(_) -> ok = roadrunner_listener:stop(conn_test_413) end, fun(Port) ->
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
            {ok, _} = roadrunner_listener:start_link(conn_test_bad_cl, #{
                port => 0, handler => roadrunner_hello_handler
            }),
            roadrunner_listener:port(conn_test_bad_cl)
        end,
        fun(_) -> ok = roadrunner_listener:stop(conn_test_bad_cl) end, fun(Port) ->
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
            {ok, _} = roadrunner_listener:start_link(conn_test_chunked, #{
                port => 0, handler => roadrunner_echo_body_handler
            }),
            roadrunner_listener:port(conn_test_chunked)
        end,
        fun(_) -> ok = roadrunner_listener:stop(conn_test_chunked) end, fun(Port) ->
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
            {ok, _} = roadrunner_listener:start_link(conn_test_routes, #{
                port => 0,
                routes => [
                    {~"/", roadrunner_hello_handler, undefined},
                    {~"/created", roadrunner_test_handler, undefined}
                ]
            }),
            roadrunner_listener:port(conn_test_routes)
        end,
        fun(_) -> ok = roadrunner_listener:stop(conn_test_routes) end, fun(Port) ->
            [
                {"path / dispatches to roadrunner_hello_handler", fun() ->
                    assert_status(Port, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n", 200)
                end},
                {"path /created dispatches to roadrunner_test_handler", fun() ->
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
            {ok, _} = roadrunner_listener:start_link(conn_test_bindings, #{
                port => 0,
                routes => [{~"/users/:id", roadrunner_bindings_handler, undefined}]
            }),
            roadrunner_listener:port(conn_test_bindings)
        end,
        fun(_) -> ok = roadrunner_listener:stop(conn_test_bindings) end, fun(Port) ->
            {"handler reads :id from roadrunner_req:bindings/1", fun() ->
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
            {ok, _} = roadrunner_listener:start_link(conn_test_timeout, #{
                port => 0,
                request_timeout => 100,
                handler => roadrunner_hello_handler
            }),
            roadrunner_listener:port(conn_test_timeout)
        end,
        fun(_) -> ok = roadrunner_listener:stop(conn_test_timeout) end, fun(Port) ->
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
            {ok, _} = roadrunner_listener:start_link(conn_test_timeout_body, #{
                port => 0,
                request_timeout => 200,
                handler => roadrunner_hello_handler
            }),
            roadrunner_listener:port(conn_test_timeout_body)
        end,
        fun(_) -> ok = roadrunner_listener:stop(conn_test_timeout_body) end, fun(Port) ->
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

conn_websocket_unmasked_frame_closes_test_() ->
    {setup, fun ws_setup/0, fun ws_cleanup/1, fun(Port) ->
        {"RFC 6455 §5.1: client MUST mask frames; server closes on unmasked", fun() ->
            Sock = ws_handshake(Port),
            %% byte1 = 0x81 (FIN+text), byte2 = 0x05 (mask=0, len=5), then
            %% raw payload. Server must reject and close.
            ok = gen_tcp:send(Sock, <<16#81, 16#05, "hello">>),
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
    {ok, _} = roadrunner_listener:start_link(conn_test_ws, #{
        port => 0, handler => roadrunner_ws_upgrade_handler
    }),
    roadrunner_listener:port(conn_test_ws).

ws_cleanup(_) ->
    ok = roadrunner_listener:stop(conn_test_ws).

ws_handshake(Port) ->
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
    ok = gen_tcp:send(
        Sock,
        ~"GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
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

%% --- chunked-stream empty-data special case ---

conn_streams_empty_send_nofin_emits_nothing_test_() ->
    {setup,
        fun() ->
            {ok, _} = roadrunner_listener:start_link(conn_test_empty_send, #{
                port => 0, handler => roadrunner_empty_send_handler
            }),
            roadrunner_listener:port(conn_test_empty_send)
        end,
        fun(_) -> ok = roadrunner_listener:stop(conn_test_empty_send) end, fun(Port) ->
            [
                {"empty Send(_, nofin) does not emit a stray 0-chunk terminator", fun() ->
                    %% Handler does Send(<<>>, nofin) then Send(<<"hi">>, fin).
                    {ok, Sock} = gen_tcp:connect(
                        {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                    ),
                    ok = gen_tcp:send(Sock, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"),
                    Reply = recv_until_closed(Sock),
                    ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
                    [_Headers, Body] = binary:split(Reply, ~"\r\n\r\n"),
                    ?assertEqual(~"2\r\nhi\r\n0\r\n\r\n", Body),
                    ok = gen_tcp:close(Sock)
                end},
                {"empty Send(_, fin) emits just the terminator (no leading chunk)", fun() ->
                    {ok, Sock} = gen_tcp:connect(
                        {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                    ),
                    ok = gen_tcp:send(Sock, ~"GET /fin-empty HTTP/1.1\r\nHost: x\r\n\r\n"),
                    Reply = recv_until_closed(Sock),
                    ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
                    [_Headers, Body] = binary:split(Reply, ~"\r\n\r\n"),
                    %% Body: "2\r\nhi\r\n0\r\n\r\n" — chunk for "hi"
                    %% then terminator with no extra empty chunk.
                    ?assertEqual(~"2\r\nhi\r\n0\r\n\r\n", Body),
                    ok = gen_tcp:close(Sock)
                end}
            ]
        end}.

conn_pipelined_get_does_not_leak_next_request_as_body_test_() ->
    {setup,
        fun() ->
            {ok, _} = roadrunner_listener:start_link(conn_test_pipe, #{
                port => 0, handler => roadrunner_echo_body_handler
            }),
            roadrunner_listener:port(conn_test_pipe)
        end,
        fun(_) -> ok = roadrunner_listener:stop(conn_test_pipe) end, fun(Port) ->
            {"GET with no framing must not see the next pipelined request as body", fun() ->
                %% Two GETs back-to-back. The first has no Content-Length
                %% / Transfer-Encoding so its body is zero per RFC 7230
                %% §3.3.3. Previously the conn returned the buffered
                %% bytes (which were the second request) as body, and
                %% the echo handler would echo those bytes — leaking
                %% one request's bytes into another's response.
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                ok = gen_tcp:send(
                    Sock,
                    <<
                        "POST /echo HTTP/1.1\r\nHost: x\r\n\r\n",
                        "GET /next HTTP/1.1\r\nHost: x\r\n\r\n"
                    >>
                ),
                Reply = recv_until_closed(Sock),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
                [_Headers, Body] = binary:split(Reply, ~"\r\n\r\n"),
                %% Body must be empty — the second request's bytes must
                %% not leak into the response.
                ?assertEqual(<<>>, Body),
                ok = gen_tcp:close(Sock)
            end}
        end}.

conn_loop_empty_push_emits_nothing_test_() ->
    {setup,
        fun() ->
            {ok, _} = roadrunner_listener:start_link(conn_test_empty_push, #{
                port => 0, handler => roadrunner_empty_push_handler
            }),
            roadrunner_listener:port(conn_test_empty_push)
        end,
        fun(_) -> ok = roadrunner_listener:stop(conn_test_empty_push) end, fun(Port) ->
            {"empty Push(<<>>) is a no-op — does not emit the chunk terminator", fun() ->
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                ok = gen_tcp:send(Sock, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"),
                wait_registered(roadrunner_empty_push_test_conn),
                roadrunner_empty_push_test_conn ! empty_push,
                roadrunner_empty_push_test_conn ! {push, ~"hello"},
                roadrunner_empty_push_test_conn ! stop,
                Reply = recv_until_closed(Sock),
                [_Headers, Body] = binary:split(Reply, ~"\r\n\r\n"),
                %% Empty push is no-op; only "hello" chunk + terminator.
                ?assertEqual(~"5\r\nhello\r\n0\r\n\r\n", Body),
                ok = gen_tcp:close(Sock)
            end}
        end}.

conn_trailer_with_crlf_in_value_crashes_test_() ->
    {setup,
        fun() ->
            ok = logger:set_primary_config(level, none),
            {ok, _} = roadrunner_listener:start_link(conn_test_trailer_inject, #{
                port => 0, handler => roadrunner_evil_trailers_handler
            }),
            roadrunner_listener:port(conn_test_trailer_inject)
        end,
        fun(_) ->
            ok = roadrunner_listener:stop(conn_test_trailer_inject),
            ok = logger:set_primary_config(level, notice)
        end,
        fun(Port) ->
            {"trailer with CRLF in value triggers header_injection crash → 500", fun() ->
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                ok = gen_tcp:send(Sock, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"),
                Reply = recv_until_closed(Sock),
                %% The handler started streaming (so headers are already
                %% on the wire as 200). The trailer crash happens during
                %% the size-0 chunk write — the wire output gets cut off
                %% before the malicious bytes reach the client.
                Lower = string:lowercase(Reply),
                ?assertEqual(
                    nomatch,
                    binary:match(Lower, ~"injected: yes")
                ),
                ok = gen_tcp:close(Sock)
            end}
        end}.

conn_streams_chunked_with_trailers_test_() ->
    {setup,
        fun() ->
            {ok, _} = roadrunner_listener:start_link(conn_test_trailers, #{
                port => 0, handler => roadrunner_trailers_handler
            }),
            roadrunner_listener:port(conn_test_trailers)
        end,
        fun(_) -> ok = roadrunner_listener:stop(conn_test_trailers) end, fun(Port) ->
            {"chunked response emits trailer headers after the 0-chunk", fun() ->
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                ok = gen_tcp:send(Sock, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"),
                Reply = recv_until_closed(Sock),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
                {match, _} = re:run(Reply, ~"transfer-encoding: chunked", [caseless]),
                {match, _} = re:run(Reply, ~"trailer: x-trailer-one", [caseless]),
                %% After the size-0 chunk we expect the trailer headers
                %% before the final blank line.
                {match, _} = re:run(Reply, ~"\r\n0\r\nx-trailer-one: alpha\r\n"),
                {match, _} = re:run(Reply, ~"x-trailer-two: beta\r\n\r\n"),
                ok = gen_tcp:close(Sock)
            end}
        end}.

conn_streams_chunked_response_test_() ->
    {setup,
        fun() ->
            {ok, _} = roadrunner_listener:start_link(conn_test_stream, #{
                port => 0, handler => roadrunner_stream_handler
            }),
            roadrunner_listener:port(conn_test_stream)
        end,
        fun(_) -> ok = roadrunner_listener:stop(conn_test_stream) end, fun(Port) ->
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
            {ok, _} = roadrunner_listener:start_link(conn_test_ka, #{
                port => 0, handler => roadrunner_keepalive_handler
            }),
            roadrunner_listener:port(conn_test_ka)
        end,
        fun(_) -> ok = roadrunner_listener:stop(conn_test_ka) end, fun(Port) ->
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
            {ok, _} = roadrunner_listener:start_link(conn_test_ka_max, #{
                port => 0,
                handler => roadrunner_keepalive_handler,
                max_keep_alive_requests => 1
            }),
            roadrunner_listener:port(conn_test_ka_max)
        end,
        fun(_) -> ok = roadrunner_listener:stop(conn_test_ka_max) end, fun(Port) ->
            {"max_keep_alive_requests=1 closes after first response", fun() ->
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
            {ok, _} = roadrunner_listener:start_link(conn_test_ka_10, #{
                port => 0, handler => roadrunner_keepalive_handler
            }),
            roadrunner_listener:port(conn_test_ka_10)
        end,
        fun(_) -> ok = roadrunner_listener:stop(conn_test_ka_10) end, fun(Port) ->
            [
                {"HTTP/1.0 default-closes even when handler omits Connection: close", fun() ->
                    {ok, Sock} = gen_tcp:connect(
                        {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                    ),
                    ok = gen_tcp:send(Sock, ~"GET / HTTP/1.0\r\nHost: x\r\n\r\n"),
                    Reply = recv_until_closed(Sock),
                    ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
                    ok = gen_tcp:close(Sock)
                end},
                {"HTTP/1.0 with Connection: keep-alive serves two requests on one conn", fun() ->
                    %% RFC 7230 §6.1: HTTP/1.0 default is close, but
                    %% `Connection: keep-alive` from the client opts in.
                    {ok, Sock} = gen_tcp:connect(
                        {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                    ),
                    ok = gen_tcp:send(
                        Sock,
                        ~"GET / HTTP/1.0\r\nHost: x\r\nConnection: keep-alive\r\n\r\n"
                    ),
                    First = recv_response_with_body(Sock, 7),
                    ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, First),
                    %% Conn must still be alive — send a second request.
                    ok = gen_tcp:send(
                        Sock,
                        ~"GET / HTTP/1.0\r\nHost: x\r\nConnection: close\r\n\r\n"
                    ),
                    Second = recv_until_closed(Sock),
                    ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Second),
                    ok = gen_tcp:close(Sock)
                end}
            ]
        end}.

conn_http11_explicit_close_test_() ->
    {setup,
        fun() ->
            {ok, _} = roadrunner_listener:start_link(conn_test_ka_close, #{
                port => 0, handler => roadrunner_keepalive_handler
            }),
            roadrunner_listener:port(conn_test_ka_close)
        end,
        fun(_) -> ok = roadrunner_listener:stop(conn_test_ka_close) end, fun(Port) ->
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
            {ok, _} = roadrunner_listener:start_link(conn_test_crash, #{
                port => 0, handler => roadrunner_crashing_handler
            }),
            roadrunner_listener:port(conn_test_crash)
        end,
        fun(_) ->
            ok = roadrunner_listener:stop(conn_test_crash),
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

%% --- consume_body_state/2 — pure unit tests ---

consume_state_no_framing_returns_empty_test() ->
    %% No framing → zero-length body per RFC 7230 §3.3.3. The
    %% `buffered` bytes are pipelined-leftover, not body — preserved
    %% in the body_state so `roadrunner_conn_loop`'s finishing phase can
    %% thread them into the next reading_request parse.
    State = #{
        framing => none,
        buffered => ~"hi",
        bytes_read => 0,
        recv => fun() -> error(unused) end,
        max => 1000
    },
    ?assertMatch({ok, <<>>, #{buffered := ~"hi"}}, roadrunner_conn:consume_body_state(State, all)).

consume_state_already_drained_returns_empty_test() ->
    State = #{
        framing => {content_length, 5},
        buffered => <<>>,
        bytes_read => 5,
        recv => fun() -> error(unused) end,
        max => 1000
    },
    ?assertMatch({ok, <<>>, _}, roadrunner_conn:consume_body_state(State, all)).

consume_state_length_returns_more_then_ok_test() ->
    State0 = #{
        framing => {content_length, 6},
        buffered => ~"abcdef",
        bytes_read => 0,
        recv => fun() -> error(unused) end,
        max => 1000
    },
    {more, First, State1} = roadrunner_conn:consume_body_state(State0, {length, 4}),
    ?assertEqual(~"abcd", First),
    {ok, Last, _State2} = roadrunner_conn:consume_body_state(State1, {length, 4}),
    ?assertEqual(~"ef", Last).

consume_state_length_recv_error_propagates_test() ->
    State = #{
        framing => {content_length, 100},
        buffered => <<>>,
        bytes_read => 0,
        recv => fun() -> {error, closed} end,
        max => 1000
    },
    ?assertEqual({error, closed}, roadrunner_conn:consume_body_state(State, all)).

%% Exercise `fill_n` / `fill_iolist`'s recursive branch where one
%% recv returns less than `Need` and a SECOND recv has to land
%% before the request is satisfied. Ensures the iolist accumulator
%% / leftover threading work correctly across multiple chunks.
consume_state_length_multi_recv_test() ->
    %% First recv returns 4 bytes ("abcd"); second returns 6 bytes
    %% ("efghij"). The handler asks for 8 — should consume the
    %% first chunk plus 4 bytes of the second, leave "ij" buffered.
    Counter = counters:new(1, []),
    Recv = fun() ->
        N = counters:get(Counter, 1),
        counters:add(Counter, 1, 1),
        case N of
            0 -> {ok, ~"abcd"};
            1 -> {ok, ~"efghij"};
            _ -> error(unused)
        end
    end,
    State0 = #{
        framing => {content_length, 100},
        buffered => <<>>,
        bytes_read => 0,
        recv => Recv,
        max => 1000
    },
    {more, Bytes, State1} = roadrunner_conn:consume_body_state(State0, {length, 8}),
    ?assertEqual(~"abcdefgh", iolist_to_binary(Bytes)),
    %% State1's buffered should now hold the leftover "ij".
    ?assertMatch(#{buffered := ~"ij"}, State1).

%% Exercise `fill_iolist`'s recursive error branch — first recv
%% delivers SOME bytes, the second recv fails. The error should
%% propagate back up the recursion to the caller.
consume_state_length_multi_recv_error_test() ->
    Counter = counters:new(1, []),
    Recv = fun() ->
        N = counters:get(Counter, 1),
        counters:add(Counter, 1, 1),
        case N of
            0 -> {ok, ~"abcd"};
            _ -> {error, closed}
        end
    end,
    State = #{
        framing => {content_length, 100},
        buffered => <<>>,
        bytes_read => 0,
        recv => Recv,
        max => 1000
    },
    ?assertEqual(
        {error, closed},
        roadrunner_conn:consume_body_state(State, {length, 8})
    ).

consume_state_request_too_large_test() ->
    State = #{
        framing => {content_length, 100},
        buffered => <<>>,
        bytes_read => 0,
        recv => fun() -> error(unused) end,
        max => 10
    },
    ?assertEqual(
        {error, content_length_too_large},
        roadrunner_conn:consume_body_state(State, all)
    ).

consume_state_chunked_full_drain_test() ->
    State = chunked_state(~"5\r\nhello\r\n0\r\n\r\n", fun() -> error(unused) end),
    {ok, Bytes, _} = roadrunner_conn:consume_body_state(State, all),
    ?assertEqual(~"hello", iolist_to_binary(Bytes)).

consume_state_chunked_error_propagates_test() ->
    State = chunked_state(~"xyz\r\nhello\r\n", fun() -> error(unused) end),
    ?assertEqual({error, bad_chunk_size}, roadrunner_conn:consume_body_state(State, all)).

consume_state_chunked_length_streams_within_chunk_test() ->
    %% Chunk decodes to "hello"; reading with length=2 yields he/ll/o.
    State = chunked_state(~"5\r\nhello\r\n0\r\n\r\n", fun() -> error(unused) end),
    {more, B1, S1} = roadrunner_conn:consume_body_state(State, {length, 2}),
    ?assertEqual(~"he", iolist_to_binary(B1)),
    {more, B2, S2} = roadrunner_conn:consume_body_state(S1, {length, 2}),
    ?assertEqual(~"ll", iolist_to_binary(B2)),
    {ok, B3, _S3} = roadrunner_conn:consume_body_state(S2, {length, 2}),
    ?assertEqual(~"o", iolist_to_binary(B3)).

consume_state_chunked_length_crosses_chunk_boundary_test() ->
    %% Two chunks "hel" + "lo world"; read length=4 yields "hell", "o wo", "rld".
    State = chunked_state(
        ~"3\r\nhel\r\n8\r\nlo world\r\n0\r\n\r\n",
        fun() -> error(unused) end
    ),
    {more, B1, S1} = roadrunner_conn:consume_body_state(State, {length, 4}),
    ?assertEqual(~"hell", iolist_to_binary(B1)),
    {more, B2, S2} = roadrunner_conn:consume_body_state(S1, {length, 4}),
    ?assertEqual(~"o wo", iolist_to_binary(B2)),
    {ok, B3, _S3} = roadrunner_conn:consume_body_state(S2, {length, 4}),
    ?assertEqual(~"rld", iolist_to_binary(B3)).

consume_state_chunked_length_recvs_more_test() ->
    %% Buffer has the size line but the chunk body arrives via recv.
    Self = self(),
    State = chunked_state(~"5\r\nhe", fun() ->
        Self ! recv_called,
        {ok, ~"llo\r\n0\r\n\r\n"}
    end),
    {ok, Bytes, _S2} = roadrunner_conn:consume_body_state(State, {length, 100}),
    ?assertEqual(~"hello", iolist_to_binary(Bytes)),
    receive
        recv_called -> ok
    after 100 -> error(recv_was_not_called)
    end.

consume_state_chunked_length_recv_error_test() ->
    State = chunked_state(~"5\r\nhe", fun() -> {error, closed} end),
    ?assertEqual({error, closed}, roadrunner_conn:consume_body_state(State, {length, 4})).

consume_state_chunked_length_after_done_returns_empty_test() ->
    %% Drain the body fully via the all path, then try to read more.
    State0 = chunked_state(~"3\r\nhel\r\n0\r\n\r\n", fun() -> error(unused) end),
    {ok, Drained, State1} = roadrunner_conn:consume_body_state(State0, all),
    ?assertEqual(~"hel", iolist_to_binary(Drained)),
    {ok, MoreBytes, _} = roadrunner_conn:consume_body_state(State1, {length, 4}),
    ?assertEqual(<<>>, iolist_to_binary(MoreBytes)).

consume_state_next_chunk_returns_one_chunk_test() ->
    %% Two chunks "hel" and "lo"; next_chunk yields each one in turn.
    State0 = chunked_state(~"3\r\nhel\r\n2\r\nlo\r\n0\r\n\r\n", fun() -> error(unused) end),
    {more, B1, S1} = roadrunner_conn:consume_body_state(State0, next_chunk),
    ?assertEqual(~"hel", B1),
    {more, B2, S2} = roadrunner_conn:consume_body_state(S1, next_chunk),
    ?assertEqual(~"lo", B2),
    {ok, B3, _S3} = roadrunner_conn:consume_body_state(S2, next_chunk),
    ?assertEqual(<<>>, B3).

consume_state_next_chunk_drains_pending_first_test() ->
    %% Pending non-empty (e.g. left over from a length-bounded read) is
    %% returned as the next "chunk" before another wire chunk is parsed.
    State = (chunked_state(~"3\r\nfoo\r\n0\r\n\r\n", fun() -> error(unused) end))#{
        pending := ~"leftover"
    },
    {more, B, _S} = roadrunner_conn:consume_body_state(State, next_chunk),
    ?assertEqual(~"leftover", B).

consume_state_next_chunk_recvs_more_test() ->
    Self = self(),
    State = chunked_state(~"5\r\nhe", fun() ->
        Self ! recv_called,
        {ok, ~"llo\r\n0\r\n\r\n"}
    end),
    {more, B, _S} = roadrunner_conn:consume_body_state(State, next_chunk),
    ?assertEqual(~"hello", B),
    receive
        recv_called -> ok
    after 100 -> error(recv_was_not_called)
    end.

consume_state_next_chunk_recv_error_test() ->
    State = chunked_state(~"5\r\nhe", fun() -> {error, closed} end),
    ?assertEqual({error, closed}, roadrunner_conn:consume_body_state(State, next_chunk)).

consume_state_next_chunk_exceeds_max_test() ->
    State = (chunked_state(~"5\r\nhello\r\n0\r\n\r\n", fun() -> error(unused) end))#{
        max := 2
    },
    ?assertEqual(
        {error, content_length_too_large},
        roadrunner_conn:consume_body_state(State, next_chunk)
    ).

consume_state_next_chunk_bad_chunk_test() ->
    State = chunked_state(~"xyz\r\nhello\r\n", fun() -> error(unused) end),
    ?assertEqual(
        {error, bad_chunk_size},
        roadrunner_conn:consume_body_state(State, next_chunk)
    ).

join_drain_group_undefined_listener_test() ->
    ?assertEqual(ok, roadrunner_conn:join_drain_group(undefined, enabled)),
    ?assertEqual(ok, roadrunner_conn:join_drain_group(undefined, disabled)).

join_drain_group_disabled_skips_pg_test() ->
    %% `disabled` short-circuits without touching pg, even when a
    %% real listener name is supplied. Verifies the opt-out path
    %% callers use to skip per-conn pg overhead on short-lived
    %% workloads.
    ?assertEqual(ok, roadrunner_conn:join_drain_group(some_listener, disabled)).

consume_state_next_chunk_for_content_length_drains_fully_test() ->
    %% Non-chunked framing: `next_chunk` drains the full body in one
    %% shot — there are no chunk boundaries to honor.
    State = #{
        framing => {content_length, 5},
        buffered => ~"hello",
        bytes_read => 0,
        pending => <<>>,
        done => false,
        recv => fun() -> error(unused) end,
        max => 1000
    },
    ?assertMatch({ok, ~"hello", _}, roadrunner_conn:consume_body_state(State, next_chunk)).

consume_state_next_chunk_after_done_returns_empty_test() ->
    %% Calling next_chunk on a state where the size-0 last chunk has
    %% already been seen returns `{ok, <<>>, _}` without parsing more.
    State = (chunked_state(<<>>, fun() -> error(unused) end))#{done := true},
    ?assertMatch({ok, <<>>, _}, roadrunner_conn:consume_body_state(State, next_chunk)).

consume_state_chunked_exceeds_max_test() ->
    %% Single chunk of 5 bytes, max=2 — must reject before pending swells.
    State = (chunked_state(~"5\r\nhello\r\n0\r\n\r\n", fun() -> error(unused) end))#{
        max := 2
    },
    ?assertEqual(
        {error, content_length_too_large},
        roadrunner_conn:consume_body_state(State, all)
    ).

chunked_state(Buf, Recv) ->
    #{
        framing => chunked,
        buffered => Buf,
        bytes_read => 0,
        pending => <<>>,
        done => false,
        recv => Recv,
        max => 1000
    }.

consume_state_recvs_more_when_buffer_short_test() ->
    %% Buffer has only 2 bytes, content-length is 5 — fill_n must recv
    %% more. Exercises the success path of the recv loop.
    Self = self(),
    State = #{
        framing => {content_length, 5},
        buffered => ~"he",
        bytes_read => 0,
        recv => fun() ->
            Self ! recv_called,
            {ok, ~"llo"}
        end,
        max => 1000
    },
    {ok, Bytes, _} = roadrunner_conn:consume_body_state(State, all),
    ?assertEqual(~"hello", iolist_to_binary(Bytes)),
    receive
        recv_called -> ok
    after 100 -> error(recv_was_not_called)
    end.

%% --- end-to-end manual mode error cases ---

conn_manual_body_buffering_bad_transfer_encoding_test_() ->
    {setup,
        fun() ->
            {ok, _} = roadrunner_listener:start_link(conn_test_manual_te, #{
                port => 0,
                handler => roadrunner_stream_body_handler,
                body_buffering => manual
            }),
            roadrunner_listener:port(conn_test_manual_te)
        end,
        fun(_) -> ok = roadrunner_listener:stop(conn_test_manual_te) end, fun(Port) ->
            {"manual mode rejects unknown Transfer-Encoding with 400", fun() ->
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                ok = gen_tcp:send(
                    Sock,
                    ~"POST /full HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip\r\n\r\n"
                ),
                Reply = recv_until_closed(Sock),
                ?assertMatch(<<"HTTP/1.1 400 ", _/binary>>, Reply),
                ok = gen_tcp:close(Sock)
            end}
        end}.

conn_manual_body_buffering_keep_alive_after_full_read_test_() ->
    {setup,
        fun() ->
            {ok, _} = roadrunner_listener:start_link(conn_test_manual_ka_full, #{
                port => 0,
                handler => roadrunner_stream_body_handler,
                body_buffering => manual
            }),
            roadrunner_listener:port(conn_test_manual_ka_full)
        end,
        fun(_) -> ok = roadrunner_listener:stop(conn_test_manual_ka_full) end, fun(Port) ->
            {"manual mode keep-alive: two POSTs on the same conn after full read", fun() ->
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                ok = gen_tcp:send(
                    Sock,
                    ~"POST /echo-keepalive HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello"
                ),
                {ok, R1} = gen_tcp:recv(Sock, 0, 1000),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, R1),
                {match, _} = re:run(R1, ~"hello"),
                ok = gen_tcp:send(
                    Sock,
                    ~"POST /echo-keepalive HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nworld"
                ),
                {ok, R2} = gen_tcp:recv(Sock, 0, 1000),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, R2),
                {match, _} = re:run(R2, ~"world"),
                ok = gen_tcp:close(Sock)
            end}
        end}.

conn_manual_body_buffering_drain_error_forces_close_test_() ->
    {setup,
        fun() ->
            {ok, _} = roadrunner_listener:start_link(conn_test_drain_err, #{
                port => 0,
                handler => roadrunner_stream_body_handler,
                body_buffering => manual
            }),
            roadrunner_listener:port(conn_test_drain_err)
        end,
        fun(_) -> ok = roadrunner_listener:stop(conn_test_drain_err) end, fun(Port) ->
            {"manual-mode drain error on malformed chunked body forces close", fun() ->
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                %% Handler skips body, conn drains. The chunk size `xyz` is
                %% non-hex — `consume_body_state` returns `{error, ...}`
                %% and `drain_body` collapses the keep_alive into a close.
                ok = gen_tcp:send(
                    Sock,
                    <<
                        "POST /skip-keepalive HTTP/1.1\r\n",
                        "Host: x\r\n",
                        "Transfer-Encoding: chunked\r\n\r\n",
                        "xyz\r\nbroken\r\n"
                    >>
                ),
                Reply = recv_until_closed(Sock),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
                ok = gen_tcp:close(Sock)
            end}
        end}.

conn_manual_body_buffering_drains_unread_body_test_() ->
    {setup,
        fun() ->
            {ok, _} = roadrunner_listener:start_link(conn_test_manual_drain, #{
                port => 0,
                handler => roadrunner_stream_body_handler,
                body_buffering => manual
            }),
            roadrunner_listener:port(conn_test_manual_drain)
        end,
        fun(_) -> ok = roadrunner_listener:stop(conn_test_manual_drain) end, fun(Port) ->
            {"manual mode drains a body the handler ignored, then serves next request", fun() ->
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                %% Handler /skip-keepalive doesn't call read_body. The conn
                %% has to drain the 5-byte body itself, otherwise the next
                %% request would parse "hello" as a request line.
                ok = gen_tcp:send(
                    Sock,
                    ~"POST /skip-keepalive HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello"
                ),
                {ok, R1} = gen_tcp:recv(Sock, 0, 1000),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, R1),
                {match, _} = re:run(R1, ~"skipped"),
                ok = gen_tcp:send(
                    Sock,
                    ~"POST /echo-keepalive HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nbye"
                ),
                {ok, R2} = gen_tcp:recv(Sock, 0, 1000),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, R2),
                {match, _} = re:run(R2, ~"bye"),
                ok = gen_tcp:close(Sock)
            end}
        end}.

conn_manual_body_buffering_per_chunk_read_test_() ->
    {setup,
        fun() ->
            {ok, _} = roadrunner_listener:start_link(conn_test_per_chunk, #{
                port => 0,
                handler => roadrunner_stream_body_handler,
                body_buffering => manual
            }),
            roadrunner_listener:port(conn_test_per_chunk)
        end,
        fun(_) -> ok = roadrunner_listener:stop(conn_test_per_chunk) end, fun(Port) ->
            {"manual mode + read_body_chunked/1 yields one chunk per call", fun() ->
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                ok = gen_tcp:send(
                    Sock,
                    <<
                        "POST /per-chunk HTTP/1.1\r\nHost: x\r\n",
                        "Transfer-Encoding: chunked\r\n\r\n",
                        "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
                    >>
                ),
                Reply = recv_until_closed(Sock),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
                {match, _} = re:run(Reply, ~"n=2 body=hello world"),
                ok = gen_tcp:close(Sock)
            end}
        end}.

conn_manual_body_buffering_chunked_request_test_() ->
    {setup,
        fun() ->
            {ok, _} = roadrunner_listener:start_link(conn_test_manual_chunked, #{
                port => 0,
                handler => roadrunner_stream_body_handler,
                body_buffering => manual
            }),
            roadrunner_listener:port(conn_test_manual_chunked)
        end,
        fun(_) -> ok = roadrunner_listener:stop(conn_test_manual_chunked) end, fun(Port) ->
            {"manual mode decodes chunked request bodies on demand", fun() ->
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                Body = ~"5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n",
                ok = gen_tcp:send(
                    Sock,
                    <<
                        "POST /full HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n",
                        Body/binary
                    >>
                ),
                Reply = recv_until_closed(Sock),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
                {match, _} = re:run(Reply, ~"hello world"),
                ok = gen_tcp:close(Sock)
            end}
        end}.

conn_manual_body_buffering_full_read_test_() ->
    {setup,
        fun() ->
            {ok, _} = roadrunner_listener:start_link(conn_test_manual_full, #{
                port => 0,
                handler => roadrunner_stream_body_handler,
                body_buffering => manual
            }),
            roadrunner_listener:port(conn_test_manual_full)
        end,
        fun(_) -> ok = roadrunner_listener:stop(conn_test_manual_full) end, fun(Port) ->
            {"manual mode: read_body/1 returns the full body", fun() ->
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                ok = gen_tcp:send(
                    Sock,
                    ~"POST /full HTTP/1.1\r\nHost: x\r\nContent-Length: 11\r\n\r\nhello world"
                ),
                Reply = recv_until_closed(Sock),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
                {match, _} = re:run(Reply, ~"hello world"),
                ok = gen_tcp:close(Sock)
            end}
        end}.

conn_manual_body_buffering_chunked_reads_test_() ->
    {setup,
        fun() ->
            {ok, _} = roadrunner_listener:start_link(conn_test_manual_chunks, #{
                port => 0,
                handler => roadrunner_stream_body_handler,
                body_buffering => manual
            }),
            roadrunner_listener:port(conn_test_manual_chunks)
        end,
        fun(_) -> ok = roadrunner_listener:stop(conn_test_manual_chunks) end, fun(Port) ->
            {"manual mode: read_body/2 with length yields multiple chunks", fun() ->
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                %% 11-byte body, length=4 → 3 reads (4, 4, 3).
                ok = gen_tcp:send(
                    Sock,
                    ~"POST /chunks HTTP/1.1\r\nHost: x\r\nContent-Length: 11\r\n\r\nhello world"
                ),
                Reply = recv_until_closed(Sock),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Reply),
                {match, _} = re:run(Reply, ~"chunks=3 body=hello world"),
                ok = gen_tcp:close(Sock)
            end}
        end}.

conn_minimum_bytes_per_second_drops_slow_client_test_() ->
    {setup,
        fun() ->
            {ok, _} = roadrunner_listener:start_link(conn_test_slow, #{
                port => 0,
                handler => roadrunner_keepalive_handler,
                %% Require 1 MB/s — any trickle below that after grace closes.
                minimum_bytes_per_second => 1000000,
                request_timeout => 5000
            }),
            roadrunner_listener:port(conn_test_slow)
        end,
        fun(_) -> ok = roadrunner_listener:stop(conn_test_slow) end, fun(Port) ->
            [
                {"trickle during request line / headers is dropped after grace", fun() ->
                    {ok, Sock} = gen_tcp:connect(
                        {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                    ),
                    ok = gen_tcp:send(Sock, ~"GET"),
                    trickle_bytes(Sock, ~" / HTTP/1.1\r\nHost: x\r\n\r\n", 200),
                    ?assertEqual({error, closed}, gen_tcp:recv(Sock, 0, 2000)),
                    ok = gen_tcp:close(Sock)
                end},
                {"trickle during body (after headers parse) is dropped too", fun() ->
                    {ok, Sock} = gen_tcp:connect(
                        {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                    ),
                    %% Headers complete instantly — Content-Length promises
                    %% 50 bytes but we send them one-per-200ms, well under
                    %% the 1 MB/s minimum.
                    ok = gen_tcp:send(
                        Sock,
                        ~"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 50\r\n\r\n"
                    ),
                    Body = binary:copy(~"a", 50),
                    trickle_bytes(Sock, Body, 200),
                    ?assertEqual({error, closed}, gen_tcp:recv(Sock, 0, 2000)),
                    ok = gen_tcp:close(Sock)
                end}
            ]
        end}.

trickle_bytes(_Sock, <<>>, _Delay) ->
    ok;
trickle_bytes(Sock, <<B, Rest/binary>>, Delay) ->
    case gen_tcp:send(Sock, <<B>>) of
        ok ->
            timer:sleep(Delay),
            trickle_bytes(Sock, Rest, Delay);
        {error, _} ->
            ok
    end.

conn_loop_handler_pushes_messages_as_chunks_test_() ->
    {setup,
        fun() ->
            {ok, _} = roadrunner_listener:start_link(conn_test_loop, #{
                port => 0, handler => roadrunner_loop_handler
            }),
            roadrunner_listener:port(conn_test_loop)
        end,
        fun(_) -> ok = roadrunner_listener:stop(conn_test_loop) end, fun(Port) ->
            {"loop handler streams chunks driven by Erlang messages", fun() ->
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                ok = gen_tcp:send(Sock, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"),
                Headers = recv_until(Sock, ~"\r\n\r\n"),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Headers),
                {match, _} = re:run(Headers, ~"transfer-encoding: chunked", [caseless]),
                wait_registered(roadrunner_loop_test_conn),
                roadrunner_loop_test_conn ! {push, ~"hello"},
                roadrunner_loop_test_conn ! {push, ~"world"},
                roadrunner_loop_test_conn ! stop,
                Body = recv_until_closed(Sock),
                {match, _} = re:run(Body, ~"data: hello"),
                {match, _} = re:run(Body, ~"data: world"),
                {match, _} = re:run(Body, ~"data: bye\\(2\\)"),
                %% Final size-0 terminator chunk.
                {match, _} = re:run(Body, ~"\r\n0\r\n\r\n"),
                ok = gen_tcp:close(Sock)
            end}
        end}.

wait_registered(Name) ->
    case whereis(Name) of
        undefined ->
            timer:sleep(10),
            wait_registered(Name);
        _ ->
            ok
    end.

conn_max_clients_rejects_excess_connections_test_() ->
    {setup,
        fun() ->
            {ok, _} = roadrunner_listener:start_link(conn_test_max_clients, #{
                port => 0,
                handler => roadrunner_keepalive_handler,
                max_clients => 1
            }),
            roadrunner_listener:port(conn_test_max_clients)
        end,
        fun(_) -> ok = roadrunner_listener:stop(conn_test_max_clients) end, fun(Port) ->
            {"second connection past max_clients=1 is closed before any response", fun() ->
                {ok, Sock1} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                ok = gen_tcp:send(Sock1, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"),
                {ok, Resp1} = gen_tcp:recv(Sock1, 0, 1000),
                ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, Resp1),
                %% Sock1 is now in keep-alive — the cap is held.
                {ok, Sock2} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                %% The acceptor closes Sock2 immediately — recv sees EOF.
                ?assertEqual({error, closed}, gen_tcp:recv(Sock2, 0, 1000)),
                ok = gen_tcp:close(Sock1),
                ok = gen_tcp:close(Sock2)
            end}
        end}.

conn_keep_alive_timeout_closes_idle_connection_test_() ->
    {setup,
        fun() ->
            {ok, _} = roadrunner_listener:start_link(conn_test_ka_idle, #{
                port => 0,
                handler => roadrunner_keepalive_handler,
                keep_alive_timeout => 150
            }),
            roadrunner_listener:port(conn_test_ka_idle)
        end,
        fun(_) -> ok = roadrunner_listener:stop(conn_test_ka_idle) end, fun(Port) ->
            {"server closes a connection that sits idle past keep_alive_timeout", fun() ->
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                ok = gen_tcp:send(Sock, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"),
                {ok, _Resp} = gen_tcp:recv(Sock, 0, 1000),
                %% Sit idle past the configured keep_alive_timeout. Server
                %% should close; recv on the closed half returns {error, closed}.
                ?assertEqual({error, closed}, gen_tcp:recv(Sock, 0, 1000)),
                ok = gen_tcp:close(Sock)
            end}
        end}.

conn_sends_100_continue_before_reading_body_test_() ->
    {setup,
        fun() ->
            {ok, _} = roadrunner_listener:start_link(conn_test_100, #{
                port => 0, handler => roadrunner_echo_body_handler
            }),
            roadrunner_listener:port(conn_test_100)
        end,
        fun(_) -> ok = roadrunner_listener:stop(conn_test_100) end, fun(Port) ->
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
            {ok, _} = roadrunner_listener:start_link(conn_test_head, #{
                port => 0, handler => roadrunner_test_handler
            }),
            roadrunner_listener:port(conn_test_head)
        end,
        fun(_) -> ok = roadrunner_listener:stop(conn_test_head) end, fun(Port) ->
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
            {ok, _} = roadrunner_listener:start_link(conn_test_peer, #{
                port => 0, handler => roadrunner_peer_handler
            }),
            roadrunner_listener:port(conn_test_peer)
        end,
        fun(_) -> ok = roadrunner_listener:stop(conn_test_peer) end, fun(Port) ->
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

%% Read response head + exactly `BodyLen` bytes from a keep-alive
%% conn. recv_until_closed/1 would block waiting for the peer to
%% close, which never happens on a keep-alive request. `recv_until`
%% may already have buffered the body alongside the head — top up
%% only what's missing.
recv_response_with_body(Sock, BodyLen) ->
    Buf = recv_until(Sock, ~"\r\n\r\n"),
    [Head, BodySoFar] = binary:split(Buf, ~"\r\n\r\n"),
    Need = BodyLen - byte_size(BodySoFar),
    Body =
        case Need of
            0 ->
                BodySoFar;
            N when N > 0 ->
                {ok, More} = gen_tcp:recv(Sock, N, 2000),
                <<BodySoFar/binary, More/binary>>
        end,
    <<Head/binary, "\r\n\r\n", Body/binary>>.
