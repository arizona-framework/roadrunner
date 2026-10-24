-module(roadrunner_http3_SUITE).
-moduledoc """
End-to-end HTTP/3 tests. Each testcase starts a roadrunner h3 listener
(`protocols => [http3]` over QUIC) and drives it with the native test
client (`roadrunner_quic_test_h3` / `roadrunner_quic_test_conn`).

Lives as a CT suite (not eunit) so each testcase runs in its own
process with its own listener, mirroring `roadrunner_http2_*_SUITE`.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    get_default/1,
    response_has_date/1,
    get_method/1,
    post_echo/1,
    empty_204/1,
    large_body/1,
    nat_rebinding_follows_client/1,
    active_migration_follows_client/1,
    head_request/1,
    large_post/1,
    not_found/1,
    method_not_allowed/1,
    crash_500/1,
    interim_response_500/1,
    rate_limited/1,
    forbidden_response_header_stripped/1,
    unsafe_response_header_500/1,
    unsupported_shapes_501/1,
    loop_response/1,
    loop_filters_otp/1,
    loop_conn_close_stops_worker/1,
    loop_stream_reset_delivers_disconnect/1,
    loop_push_flushes_per_event/1,
    loop_backpressure_reset_while_parked/1,
    stream_response/1,
    stream_trailers/1,
    stream_autoclose/1,
    stream_forbidden_header_stripped/1,
    stream_forbidden_trailer_stripped/1,
    stream_unsafe_header_500/1,
    stream_trailer_injection_aborts/1,
    unfinished_stream_on_normal_exit_resets/1,
    sendfile_empty/1,
    sendfile_small/1,
    sendfile_large/1,
    head_sendfile/1,
    oversized_413/1,
    real_ip_resolves_client_behind_trusted_proxy/1,
    expect_continue_gets_interim_100/1,
    expect_continue_without_length_gets_interim_100/1,
    expect_continue_over_the_cap_gets_413/1,
    expect_continue_unrepresentable_length_resets/1,
    route_body_cap_raises/1,
    route_body_cap_lowers/1,
    route_body_cap_expect_continue/1,
    route_rate_limit_refuses/1,
    other_expectation_gets_no_interim/1,
    oversized_headers_431/1,
    advertises_max_field_section_size/1,
    advertises_grease_setting/1,
    field_section_too_large_431/1,
    protocols_tuple_form/1,
    certfile_keyfile/1,
    certs_keys_form/1,
    cert_chain/1,
    quic_start_failure_releases_tcp/1,
    co_listen/1,
    ip_binds_loopback/1,
    rejects_http3_without_tls/1,
    max_clients_refuse/1,
    single_listener_ephemeral_port/1,
    max_concurrent_requests_refuse/1,
    max_concurrent_requests_shed/1,
    max_concurrent_requests_queue/1,
    max_concurrent_requests_queue_expires/1,
    max_concurrent_requests_queue_stale_grant/1,
    max_concurrent_requests_queue_survives_drain/1,
    stream_cancel/1,
    response_to_cancelled_stream/1,
    badheaders_reset/1,
    fin_without_headers/1,
    malformed_request/1,
    connect_not_implemented/1,
    unknown_expectation_417/1,
    data_before_headers/1,
    request_with_trailers/1,
    malformed_frame/1,
    oversized_frame/1,
    qpack_decompression_failed/1,
    qpack_decompression_failed_before_body/1,
    extra_data_after_413/1,
    refused_request_with_fin_is_dropped/1,
    stop_sending_ignored/1,
    peer_push_stream_closes_conn/1,
    peer_allows_no_uni_stream_closes_conn/1,
    peer_control_stream_closed/1,
    unknown_uni_stream_ignored/1,
    peer_control_stream_reset/1,
    noncritical_uni_stream_reset/1,
    drain/1,
    refuse_request_during_drain/1,
    drain_refuses_new_connections/1,
    drain_closes_a_mid_handshake_connection/1
]).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        get_default,
        response_has_date,
        get_method,
        post_echo,
        empty_204,
        large_body,
        nat_rebinding_follows_client,
        active_migration_follows_client,
        head_request,
        large_post,
        not_found,
        method_not_allowed,
        crash_500,
        interim_response_500,
        rate_limited,
        forbidden_response_header_stripped,
        unsafe_response_header_500,
        unsupported_shapes_501,
        loop_response,
        loop_filters_otp,
        loop_conn_close_stops_worker,
        loop_stream_reset_delivers_disconnect,
        loop_push_flushes_per_event,
        loop_backpressure_reset_while_parked,
        stream_response,
        stream_trailers,
        stream_autoclose,
        stream_forbidden_header_stripped,
        stream_forbidden_trailer_stripped,
        stream_unsafe_header_500,
        stream_trailer_injection_aborts,
        unfinished_stream_on_normal_exit_resets,
        sendfile_empty,
        sendfile_small,
        sendfile_large,
        head_sendfile,
        oversized_413,
        real_ip_resolves_client_behind_trusted_proxy,
        expect_continue_gets_interim_100,
        expect_continue_without_length_gets_interim_100,
        expect_continue_over_the_cap_gets_413,
        expect_continue_unrepresentable_length_resets,
        route_body_cap_raises,
        route_body_cap_lowers,
        route_body_cap_expect_continue,
        route_rate_limit_refuses,
        other_expectation_gets_no_interim,
        oversized_headers_431,
        advertises_max_field_section_size,
        advertises_grease_setting,
        field_section_too_large_431,
        protocols_tuple_form,
        certfile_keyfile,
        certs_keys_form,
        cert_chain,
        quic_start_failure_releases_tcp,
        co_listen,
        ip_binds_loopback,
        rejects_http3_without_tls,
        max_clients_refuse,
        single_listener_ephemeral_port,
        max_concurrent_requests_refuse,
        max_concurrent_requests_shed,
        max_concurrent_requests_queue,
        max_concurrent_requests_queue_expires,
        max_concurrent_requests_queue_stale_grant,
        max_concurrent_requests_queue_survives_drain,
        stream_cancel,
        response_to_cancelled_stream,
        badheaders_reset,
        fin_without_headers,
        malformed_request,
        connect_not_implemented,
        unknown_expectation_417,
        data_before_headers,
        request_with_trailers,
        malformed_frame,
        oversized_frame,
        qpack_decompression_failed,
        qpack_decompression_failed_before_body,
        extra_data_after_413,
        refused_request_with_fin_is_dropped,
        stop_sending_ignored,
        peer_push_stream_closes_conn,
        peer_allows_no_uni_stream_closes_conn,
        peer_control_stream_closed,
        unknown_uni_stream_ignored,
        peer_control_stream_reset,
        noncritical_uni_stream_reset,
        drain,
        refuse_request_during_drain,
        drain_refuses_new_connections,
        drain_closes_a_mid_handshake_connection
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(crypto),
    {ok, _} = application:ensure_all_started(ssl),
    Config.

end_per_suite(_Config) ->
    ok.

%% Most testcases share a default single-handler h3 listener; the few
%% that need a bespoke config (router, small body cap, co-listen,
%% max_clients, no TLS) start their own and skip this one.
init_per_testcase(Case, Config) when
    Case =:= not_found;
    Case =:= method_not_allowed;
    Case =:= rate_limited;
    Case =:= oversized_413;
    Case =:= real_ip_resolves_client_behind_trusted_proxy;
    Case =:= expect_continue_over_the_cap_gets_413;
    Case =:= route_body_cap_raises;
    Case =:= route_body_cap_lowers;
    Case =:= route_body_cap_expect_continue;
    Case =:= route_rate_limit_refuses;
    Case =:= protocols_tuple_form;
    Case =:= certfile_keyfile;
    Case =:= certs_keys_form;
    Case =:= cert_chain;
    Case =:= quic_start_failure_releases_tcp;
    Case =:= co_listen;
    Case =:= ip_binds_loopback;
    Case =:= rejects_http3_without_tls;
    Case =:= max_clients_refuse;
    Case =:= single_listener_ephemeral_port;
    Case =:= max_concurrent_requests_refuse;
    Case =:= max_concurrent_requests_shed;
    Case =:= max_concurrent_requests_queue;
    Case =:= max_concurrent_requests_queue_expires;
    Case =:= max_concurrent_requests_queue_stale_grant;
    Case =:= max_concurrent_requests_queue_survives_drain;
    Case =:= extra_data_after_413;
    Case =:= refused_request_with_fin_is_dropped;
    Case =:= oversized_headers_431;
    Case =:= advertises_max_field_section_size;
    Case =:= field_section_too_large_431
->
    Config;
init_per_testcase(Case, Config) ->
    Name = listener_name(Case),
    {ok, _} = start_h3(Name, #{}),
    [{listener, Name}, {port, roadrunner_listener:port(Name)} | Config].

end_per_testcase(_Case, Config) ->
    case ?config(listener, Config) of
        undefined ->
            ok;
        Name ->
            %% A failing testcase exits and takes its linked listener
            %% with it, so tolerate an already-gone listener on cleanup.
            try
                roadrunner_listener:stop(Name)
            catch
                _:_ -> ok
            end
    end.

%% --- testcases ---

get_default(Config) ->
    Conn = connect(?config(port, Config)),
    ?assertEqual({200, ~"ok"}, status_body(get(Conn, ~"/"))),
    close(Conn).

response_has_date(Config) ->
    %% RFC 9110 §6.6.1: every HTTP/3 response carries a `date` header.
    Conn = connect(?config(port, Config)),
    {200, Headers, _Body} = get(Conn, ~"/"),
    ?assert(is_binary(proplists:get_value(~"date", Headers))),
    close(Conn).

get_method(Config) ->
    Conn = connect(?config(port, Config)),
    ?assertEqual({200, ~"GET"}, status_body(get(Conn, ~"/method"))),
    close(Conn).

post_echo(Config) ->
    Conn = connect(?config(port, Config)),
    ?assertEqual({200, ~"hello h3 body"}, status_body(post(Conn, ~"/echo", ~"hello h3 body"))),
    close(Conn).

empty_204(Config) ->
    Conn = connect(?config(port, Config)),
    ?assertEqual({204, ~""}, status_body(get(Conn, ~"/empty"))),
    close(Conn).

large_body(Config) ->
    Conn = connect(?config(port, Config)),
    {200, _Headers, Body} = get(Conn, ~"/big"),
    ?assertEqual(100_000, byte_size(Body)),
    close(Conn).

nat_rebinding_follows_client(Config) ->
    %% RFC 9000 §9.3: the client's port changes mid-connection while it keeps
    %% its connection ids, as in a NAT rebinding. The server validates the
    %% new address with a PATH_CHALLENGE the client answers there, and keeps
    %% serving on it, past the anti-amplification limit once validated.
    %% Requests after the move report the new address as their peer.
    Conn = connect(?config(port, Config)),
    ?assertEqual({200, client_port(Conn)}, status_body(get(Conn, ~"/peer"))),
    ok = roadrunner_quic_test_conn:rebind(Conn),
    {200, _Headers, Body} = get(Conn, ~"/big"),
    ?assertEqual(100_000, byte_size(Body)),
    ?assertEqual({200, client_port(Conn)}, status_body(get(Conn, ~"/peer"))),
    close(Conn).

active_migration_follows_client(Config) ->
    %% RFC 9000 §9.2 / §9.5: the client gives the server a spare id of its
    %% own, then moves to a spare id of the server's and to a new port at
    %% once. The server follows it there, addressing the client's fresh id.
    %% The request after NEW_CONNECTION_ID makes sure the server holds the
    %% spare before the move.
    Conn = connect(?config(port, Config)),
    ok = roadrunner_quic_test_conn:new_connection_id(Conn),
    ?assertEqual({200, ~"ok"}, status_body(get(Conn, ~"/"))),
    #{1 := Spare} = roadrunner_quic_test_conn:server_cids(Conn),
    ok = roadrunner_quic_test_conn:use_server_cid(Conn, Spare),
    ok = roadrunner_quic_test_conn:rebind(Conn),
    {200, _Headers, Body} = get(Conn, ~"/big"),
    ?assertEqual(100_000, byte_size(Body)),
    ?assertEqual({200, client_port(Conn)}, status_body(get(Conn, ~"/peer"))),
    close(Conn).

head_request(Config) ->
    %% RFC 9110 §9.3.2: a HEAD response carries the GET headers but no
    %% body — `/big` would be 100 KB on GET, empty on HEAD.
    Conn = connect(?config(port, Config)),
    {ok, StreamId} = roadrunner_quic_test_h3:open_request(Conn, headers(~"HEAD", ~"/big")),
    ?assertEqual({200, ~""}, status_body(collect(Conn, StreamId))),
    close(Conn).

large_post(Config) ->
    Conn = connect(?config(port, Config)),
    Payload = binary:copy(<<"abcdefgh">>, 12_500),
    {200, _Headers, Body} = post(Conn, ~"/echo", Payload),
    ?assertEqual(Payload, Body),
    close(Conn).

not_found(_Config) ->
    Name = listener_name(not_found),
    {ok, _} = start_h3(Name, #{routes => [{~"/known", roadrunner_h3_test_handler}]}),
    Conn = connect(roadrunner_listener:port(Name)),
    try
        ?assertMatch({404, _}, status_body(get(Conn, ~"/missing")))
    after
        close(Conn),
        roadrunner_listener:stop(Name)
    end.

method_not_allowed(_Config) ->
    %% The path matches but the route's `methods` allowlist does not answer
    %% POST, so routing decides a 405 and carries the accepted methods in
    %% `Allow` rather than reaching the handler.
    Name = listener_name(method_not_allowed),
    {ok, _} = start_h3(Name, #{
        routes => [
            #{path => ~"/only-get", handler => roadrunner_h3_test_handler, methods => [~"GET"]}
        ]
    }),
    Conn = connect(roadrunner_listener:port(Name)),
    try
        {Status, Headers, _Body} = post(Conn, ~"/only-get", ~""),
        ?assertEqual(405, Status),
        ?assertEqual(~"GET", proplists:get_value(~"allow", Headers)),
        ?assertMatch({200, _}, status_body(get(Conn, ~"/only-get")))
    after
        close(Conn),
        roadrunner_listener:stop(Name)
    end.

crash_500(Config) ->
    Conn = connect(?config(port, Config)),
    ?assertMatch({500, _}, status_body(get(Conn, ~"/crash"))),
    close(Conn).

interim_response_500(Config) ->
    %% A handler returning a buffered 1xx status is a misuse (RFC 9110
    %% §15.2): the worker rejects it with 500 rather than send an invalid
    %% interim status as the final response.
    Conn = connect(?config(port, Config)),
    ?assertMatch({500, _}, status_body(get(Conn, ~"/interim"))),
    %% The stream shape too.
    ?assertMatch({500, _}, status_body(get(Conn, ~"/interim-stream"))),
    close(Conn).

rate_limited(_Config) ->
    %% Per-peer rate guard over h3: the first request (full bucket) reaches the
    %% handler; the second from the same peer is refused with 429 + Retry-After
    %% (a real response, not H3_REQUEST_REJECTED).
    Name = listener_name(rate_limited),
    {ok, _} = start_h3(Name, #{rate_limit => #{rate => 1, burst => 1}}),
    Conn = connect(roadrunner_listener:port(Name)),
    try
        ?assertMatch({200, _}, status_body(get(Conn, ~"/"))),
        {429, Headers, _} = get(Conn, ~"/"),
        ?assertEqual(~"1", proplists:get_value(~"retry-after", Headers))
    after
        close(Conn),
        roadrunner_listener:stop(Name)
    end.

forbidden_response_header_stripped(Config) ->
    %% A handler returning any connection-specific header has it stripped
    %% (RFC 9114 §4.2): the client sees a clean 200 without the field.
    Conn = connect(?config(port, Config)),
    lists:foreach(
        fun(Name) ->
            {200, Headers, ~"x"} = get(Conn, <<"/forbidden/", Name/binary>>),
            ?assertEqual(false, lists:keymember(Name, 1, Headers))
        end,
        [~"connection", ~"keep-alive", ~"proxy-connection", ~"transfer-encoding", ~"upgrade"]
    ),
    close(Conn).

unsafe_response_header_500(Config) ->
    %% A handler returning a response header with CR/LF/NUL in the name or
    %% value is rejected (RFC 9110 §5.5): 500, and the connection survives.
    Conn = connect(?config(port, Config)),
    ?assertMatch({500, _}, status_body(get(Conn, ~"/inject-value"))),
    ?assertMatch({500, _}, status_body(get(Conn, ~"/inject-name"))),
    close(Conn).

unsupported_shapes_501(Config) ->
    Conn = connect(?config(port, Config)),
    lists:foreach(
        fun(Path) ->
            ?assertMatch({501, _}, status_body(get(Conn, Path)))
        end,
        [~"/websocket", ~"/websocket-headers"]
    ),
    close(Conn).

loop_response(Config) ->
    %% A `{loop, ...}` response: HEADERS, then DATA chunks pushed from
    %% the handler's `handle_info/3`, FIN on `{stop, _}`.
    Conn = connect(?config(port, Config)),
    {ok, StreamId} = roadrunner_quic_test_h3:open_request(Conn, headers(~"GET", ~"/loop")),
    Worker = wait_for_register(roadrunner_h3_loop_test, 1000),
    Worker ! {push, ~"hi"},
    Worker ! push_empty,
    Worker ! stop,
    {200, _Headers, Body} = collect(Conn, StreamId),
    ?assertEqual(~"data: hi\n\ndata: bye(1)\n\n", Body),
    close(Conn).

loop_filters_otp(Config) ->
    %% OTP message shapes are answered by `roadrunner_loop_sys` (not
    %% delivered to `handle_info/3`), so only the real push advances the
    %% counter: `sys:get_state/1` returns the loop counter, a gen-call
    %% gets `{error, not_supported}`, and a gen-cast is a no-op.
    Conn = connect(?config(port, Config)),
    {ok, StreamId} = roadrunner_quic_test_h3:open_request(Conn, headers(~"GET", ~"/loop")),
    Worker = wait_for_register(roadrunner_h3_loop_test, 1000),
    ?assertEqual(0, sys:get_state(Worker)),
    ?assertEqual({error, not_supported}, gen_server:call(Worker, ping)),
    ok = gen_server:cast(Worker, noop),
    Worker ! {push, ~"x"},
    Worker ! stop,
    {200, _Headers, Body} = collect(Conn, StreamId),
    ?assertEqual(~"data: x\n\ndata: bye(1)\n\n", Body),
    close(Conn).

loop_conn_close_stops_worker(Config) ->
    %% An idle `{loop, _}` worker stops when its connection dies, rather
    %% than blocking forever in `receive`. Stopping the listener kills
    %% the QUIC connection, which fires the worker's monitor.
    Name = ?config(listener, Config),
    Conn = connect(?config(port, Config)),
    {ok, _StreamId} = roadrunner_quic_test_h3:open_request(Conn, headers(~"GET", ~"/loop")),
    Worker = wait_for_register(roadrunner_h3_loop_test, 1000),
    WorkerRef = monitor(process, Worker),
    ok = roadrunner_listener:stop(Name),
    receive
        {'DOWN', WorkerRef, process, Worker, _} -> ok
    after 5000 ->
        ct:fail(loop_worker_did_not_exit)
    end,
    close(Conn).

loop_stream_reset_delivers_disconnect(Config) ->
    %% A peer cancelling a live `{loop, _}` stream (RESET_STREAM) is routed
    %% by the conn loop to the worker, which hands the handler
    %% `{roadrunner_disconnect, reset}` and stops — rather than leaking
    %% until the whole connection dies.
    Conn = connect(?config(port, Config)),
    {ok, StreamId} = roadrunner_quic_test_h3:open_request(Conn, headers(~"GET", ~"/loop")),
    Worker = wait_for_register(roadrunner_h3_loop_test, 1000),
    true = register(roadrunner_h3_loop_observer, self()),
    WorkerRef = monitor(process, Worker),
    ok = roadrunner_quic_test_h3:cancel(Conn, StreamId),
    receive
        {handler_disconnect, Reason} -> ?assertEqual(reset, Reason)
    after 5000 ->
        ct:fail(disconnect_not_delivered)
    end,
    receive
        {'DOWN', WorkerRef, process, Worker, _} -> ok
    after 5000 ->
        ct:fail(loop_worker_did_not_exit)
    end,
    true = unregister(roadrunner_h3_loop_observer),
    close(Conn).

loop_push_flushes_per_event(Config) ->
    %% Each Push on a `{loop, _}` stream reaches the wire at emit time: the
    %% client receives event 1 *before* event 2 is pushed, so there is no
    %% coalescing that would batch SSE notifications behind a later flush
    %% boundary (the QUIC send path emits a STREAM frame per push).
    Conn = connect(?config(port, Config)),
    {ok, StreamId} = roadrunner_quic_test_h3:open_request(Conn, headers(~"GET", ~"/loop")),
    Worker = wait_for_register(roadrunner_h3_loop_test, 1000),
    Worker ! {push, ~"e1"},
    Acc1 = await_stream_bytes(Conn, StreamId, ~"data: e1\n\n", <<>>),
    Worker ! {push, ~"e2"},
    _Acc2 = await_stream_bytes(Conn, StreamId, ~"data: e2\n\n", Acc1),
    Worker ! stop,
    close(Conn).

loop_backpressure_reset_while_parked(Config) ->
    %% A loop worker blocked on a Push under a stalled per-stream send window
    %% (the deferred-ack backpressure) is released and disconnected when the
    %% client resets the stream — it does not hang in send_data forever.
    Conn = connect(?config(port, Config), #{stream_window => 2000}),
    {ok, StreamId} = roadrunner_quic_test_h3:open_request(Conn, headers(~"GET", ~"/loop")),
    Worker = wait_for_register(roadrunner_h3_loop_test, 1000),
    true = register(roadrunner_h3_loop_observer, self()),
    WorkerRef = monitor(process, Worker),
    %% A push far larger than the 2000-byte per-stream window parks the worker
    %% (the client withholds MAX_STREAM_DATA, so it cannot drain).
    Worker ! {push, binary:copy(~"x", 16000)},
    ok = roadrunner_quic_test_h3:cancel(Conn, StreamId),
    receive
        {handler_disconnect, Reason} -> ?assertEqual(reset, Reason)
    after 5000 ->
        ct:fail(disconnect_not_delivered)
    end,
    receive
        {'DOWN', WorkerRef, process, Worker, _} -> ok
    after 5000 ->
        ct:fail(loop_worker_did_not_exit)
    end,
    true = unregister(roadrunner_h3_loop_observer),
    close(Conn).

%% Accumulate the stream's raw bytes until they contain `Needle` (the SSE
%% payload appears verbatim in the DATA frame), failing if it doesn't
%% arrive — proving the bytes were flushed without waiting for a later
%% push or the FIN. `Acc` threads bytes already pulled from the mailbox.
await_stream_bytes(Conn, StreamId, Needle, Acc) ->
    case binary:match(Acc, Needle) of
        nomatch ->
            receive
                {quic_test_stream, Conn, StreamId, Data, _Fin} ->
                    await_stream_bytes(Conn, StreamId, Needle, <<Acc/binary, Data/binary>>)
            after 2000 ->
                ct:fail({event_not_flushed, Needle})
            end;
        _ ->
            Acc
    end.

sendfile_empty(Config) ->
    %% A zero-length sendfile range is a header-only response.
    Conn = connect(?config(port, Config)),
    ?assertEqual({200, ~""}, status_body(get(Conn, ~"/sendfile"))),
    close(Conn).

sendfile_small(Config) ->
    %% 100 bytes from /dev/zero, sent in a single DATA frame.
    Conn = connect(?config(port, Config)),
    {200, _Headers, Body} = get(Conn, ~"/sendfile-small"),
    ?assertEqual(binary:copy(<<0>>, 100), Body),
    close(Conn).

sendfile_large(Config) ->
    %% 100 KB from /dev/zero — exceeds the read chunk, so multiple DATA
    %% frames are streamed and reassembled by the client.
    Conn = connect(?config(port, Config)),
    {200, _Headers, Body} = get(Conn, ~"/sendfile-large"),
    ?assertEqual(binary:copy(<<0>>, 100_000), Body),
    close(Conn).

head_sendfile(Config) ->
    %% RFC 9110 §9.3.2: HEAD on a sendfile route returns the headers but
    %% no body (and never reads the file).
    Conn = connect(?config(port, Config)),
    {ok, StreamId} = roadrunner_quic_test_h3:open_request(
        Conn, headers(~"HEAD", ~"/sendfile-small")
    ),
    ?assertEqual({200, ~""}, status_body(collect(Conn, StreamId))),
    close(Conn).

stream_response(Config) ->
    %% A `{stream, ...}` response: HEADERS then DATA chunks then FIN.
    Conn = connect(?config(port, Config)),
    ?assertEqual({200, ~"chunk1-chunk2"}, status_body(get(Conn, ~"/stream"))),
    close(Conn).

stream_trailers(Config) ->
    %% `Send(Data, {fin, Trailers})` ends with a trailing HEADERS frame.
    Conn = connect(?config(port, Config)),
    ?assertEqual({200, ~"body"}, status_body(get(Conn, ~"/stream-trailers"))),
    close(Conn).

stream_autoclose(Config) ->
    %% A stream fun that returns without `fin` is auto-closed.
    Conn = connect(?config(port, Config)),
    ?assertEqual({200, ~"data"}, status_body(get(Conn, ~"/stream-noend"))),
    close(Conn).

stream_forbidden_header_stripped(Config) ->
    %% A streaming response carrying a connection-specific header has it
    %% stripped (RFC 9114 §4.2), same as the buffered path.
    Conn = connect(?config(port, Config)),
    {200, Headers, ~"x"} = get(Conn, ~"/stream-forbidden"),
    ?assertEqual(false, lists:keymember(~"connection", 1, Headers)),
    close(Conn).

stream_forbidden_trailer_stripped(Config) ->
    %% A connection-specific field in a response trailer is stripped
    %% (RFC 9114 §4.2); a legitimate trailer rides through.
    Conn = connect(?config(port, Config)),
    {200, _Headers, ~"body"} = get(Conn, ~"/stream-forbidden-trailers"),
    close(Conn).

stream_unsafe_header_500(Config) ->
    %% A streaming response carrying a header with CR/LF/NUL is rejected
    %% with 500 (RFC 9110 §5.5), same as the buffered path.
    Conn = connect(?config(port, Config)),
    ?assertMatch({500, _}, status_body(get(Conn, ~"/stream-inject"))),
    close(Conn).

stream_trailer_injection_aborts(Config) ->
    %% Wire-level proof that a CR/LF in a response trailer never reaches the
    %% wire. A raw client reads the server's actual stream bytes: with the
    %% check the server sends the 200 HEADERS then RESETS the stream, so the
    %% malformed value ("a\r\nb" = <<97,13,10,98>>) is never emitted; without
    %% it, QPACK encodes those bytes into a trailer frame and the stream
    %% finishes cleanly. A conformant h3 client cannot show this -- it
    %% rejects the bad field either way -- so this drives a raw client.
    Conn = ll_connect(?config(port, Config)),
    try
        StreamId = roadrunner_quic_test_conn:open_bidi(Conn),
        Block = roadrunner_qpack:encode(headers(~"GET", ~"/stream-bad-trailers")),
        ok = roadrunner_quic_test_conn:send(
            Conn, StreamId, roadrunner_quic_h3_frame:encode_headers(Block), true
        ),
        Result = ll_collect_until_end(Conn, StreamId, <<>>),
        %% The server aborts the stream rather than completing it normally,
        ?assertMatch({reset, _, _}, Result),
        {reset, _ErrorCode, Bytes} = Result,
        %% and the malformed trailer value never appears on the wire.
        ?assertEqual(nomatch, binary:match(Bytes, <<$a, $\r, $\n, $b>>))
    after
        ll_close(Conn)
    end.

unfinished_stream_on_normal_exit_resets(Config) ->
    %% A stream fun that ends its worker with `exit(normal)` before the FIN
    %% gets the stream reset (H3_INTERNAL_ERROR), not left open; after the
    %% FIN the same exit leaves the complete response alone.
    Conn = ll_connect(?config(port, Config)),
    try
        Unfinished = roadrunner_quic_test_conn:open_bidi(Conn),
        ok = roadrunner_quic_test_conn:send(
            Conn,
            Unfinished,
            roadrunner_quic_h3_frame:encode_headers(
                roadrunner_qpack:encode(headers(~"GET", ~"/stream-exit-normal"))
            ),
            true
        ),
        ?assertMatch({reset, 16#0102, _}, ll_collect_until_end(Conn, Unfinished, <<>>)),
        Finished = roadrunner_quic_test_conn:open_bidi(Conn),
        ok = roadrunner_quic_test_conn:send(
            Conn,
            Finished,
            roadrunner_quic_h3_frame:encode_headers(
                roadrunner_qpack:encode(headers(~"GET", ~"/stream-fin-exit-normal"))
            ),
            true
        ),
        ?assertMatch({fin, _}, ll_collect_until_end(Conn, Finished, <<>>))
    after
        ll_close(Conn)
    end.

expect_continue_gets_interim_100(Config) ->
    %% RFC 9110 §10.1.1: a request expecting `100-continue` with a body to
    %% follow gets the interim 100 right away (a HEADERS frame with
    %% `:status` alone, no FIN), then its final response once the body is in.
    Conn = ll_connect(?config(port, Config)),
    try
        StreamId = roadrunner_quic_test_conn:open_bidi(Conn),
        ok = roadrunner_quic_test_conn:send(
            Conn, StreamId, expect_headers(~"3", ~"100-continue"), false
        ),
        receive
            {quic_test_stream, Conn, StreamId, Interim, false} ->
                {ok, {headers, Block}, <<>>} = roadrunner_quic_h3_frame:decode(Interim),
                ?assertEqual({ok, [{~":status", ~"100"}]}, roadrunner_qpack:decode(Block))
        after 5000 -> ct:fail(no_interim_response)
        end,
        ok = roadrunner_quic_test_conn:send(
            Conn, StreamId, roadrunner_quic_h3_frame:encode_data(~"abc", 3), true
        ),
        {fin, Bytes} = ll_collect_until_end(Conn, StreamId, <<>>),
        {ok, {headers, Final}, _} = roadrunner_quic_h3_frame:decode(Bytes),
        ?assertMatch({ok, [{~":status", ~"200"} | _]}, roadrunner_qpack:decode(Final))
    after
        ll_close(Conn)
    end.

expect_continue_without_length_gets_interim_100(Config) ->
    %% No declared length to hold against the cap: the client is asked for
    %% its body, and the cap applies as it arrives.
    Conn = ll_connect(?config(port, Config)),
    try
        StreamId = roadrunner_quic_test_conn:open_bidi(Conn),
        ok = roadrunner_quic_test_conn:send(
            Conn,
            StreamId,
            roadrunner_quic_h3_frame:encode_headers(
                roadrunner_qpack:encode(
                    headers(~"POST", ~"/echo") ++ [{~"expect", ~"100-continue"}]
                )
            ),
            false
        ),
        receive
            {quic_test_stream, Conn, StreamId, Interim, false} ->
                {ok, {headers, Block}, <<>>} = roadrunner_quic_h3_frame:decode(Interim),
                ?assertEqual({ok, [{~":status", ~"100"}]}, roadrunner_qpack:decode(Block))
        after 5000 -> ct:fail(no_interim_response)
        end,
        ok = roadrunner_quic_test_conn:send(
            Conn, StreamId, roadrunner_quic_h3_frame:encode_data(~"abc", 3), true
        ),
        {fin, Bytes} = ll_collect_until_end(Conn, StreamId, <<>>),
        {ok, {headers, Final}, _} = roadrunner_quic_h3_frame:decode(Bytes),
        ?assertMatch({ok, [{~":status", ~"200"} | _]}, roadrunner_qpack:decode(Final))
    after
        ll_close(Conn)
    end.

expect_continue_over_the_cap_gets_413(_Config) ->
    %% A declared `content-length` already over `max_content_length` is the
    %% final status the headers settle: 413 at once, not a 100 that would
    %% have the client send a body we refuse.
    Name = listener_name(expect_continue_over_the_cap_gets_413),
    {ok, _} = start_h3(Name, #{max_content_length => 2}),
    Conn = connect(roadrunner_listener:port(Name)),
    try
        {ok, StreamId} = roadrunner_quic_test_h3:open_request(
            Conn,
            headers(~"POST", ~"/echo") ++
                [{~"content-length", ~"3"}, {~"expect", ~"100-Continue"}],
            false
        ),
        ?assertMatch({413, _, _}, collect(Conn, StreamId))
    after
        close(Conn),
        roadrunner_listener:stop(Name)
    end.

expect_continue_unrepresentable_length_resets(Config) ->
    %% A `content-length` past 2^63 - 1 is malformed (RFC 9114 §4.1.2): the
    %% stream is reset with H3_MESSAGE_ERROR, and no 100 asks for its body.
    Conn = connect(?config(port, Config)),
    {ok, StreamId} = roadrunner_quic_test_h3:open_request(
        Conn,
        headers(~"POST", ~"/echo") ++
            [{~"content-length", ~"99999999999999999999"}, {~"expect", ~"100-continue"}],
        false
    ),
    ?assertEqual({error, {stream_reset, 16#10e}}, collect(Conn, StreamId)),
    ?assertMatch({200, _, _}, get(Conn, ~"/")),
    close(Conn).

route_body_cap_raises(_Config) ->
    %% `/up` raises the 8-byte listener cap to 64: a body past the listener's
    %% cap asks its route once, and is then held to the route's.
    Name = listener_name(route_body_cap_raises),
    {ok, _} = start_h3(Name, route_cap_opts()),
    Port = roadrunner_listener:port(Name),
    Conn = connect(Port),
    try
        ?assertEqual({200, ~"20"}, status_body(post(Conn, ~"/up", binary:copy(~"x", 20)))),
        ?assertMatch({413, _, _}, post(Conn, ~"/up", binary:copy(~"x", 65))),
        ?assertMatch({413, _, _}, post(Conn, ~"/plain", binary:copy(~"x", 9))),
        %% HEADERS and an over-cap DATA frame in one chunk: the field section
        %% is decoded to route the body, and kept for dispatch.
        Raw = ll_connect(Port),
        try
            StreamId = roadrunner_quic_test_conn:open_bidi(Raw),
            ok = roadrunner_quic_test_conn:send(
                Raw,
                StreamId,
                [
                    roadrunner_quic_h3_frame:encode_headers(
                        roadrunner_qpack:encode(headers(~"POST", ~"/up"))
                    ),
                    roadrunner_quic_h3_frame:encode_data(binary:copy(~"x", 20), 20)
                ],
                false
            ),
            ok = roadrunner_quic_test_conn:send(
                Raw, StreamId, roadrunner_quic_h3_frame:encode_data(~"12345", 5), true
            ),
            {fin, Bytes} = ll_collect_until_end(Raw, StreamId, <<>>),
            {ok, {headers, Final}, Rest} = roadrunner_quic_h3_frame:decode(Bytes),
            ?assertMatch({ok, [{~":status", ~"200"} | _]}, roadrunner_qpack:decode(Final)),
            ?assertMatch({ok, {data, ~"25"}, _}, roadrunner_quic_h3_frame:decode(Rest))
        after
            ll_close(Raw)
        end
    after
        close(Conn),
        roadrunner_listener:stop(Name)
    end.

route_body_cap_lowers(_Config) ->
    %% `/small` lowers the cap to 2: the connection holds the body to the
    %% listener's cap, and the route's smaller one applies once routed.
    Name = listener_name(route_body_cap_lowers),
    {ok, _} = start_h3(Name, route_cap_opts()),
    Conn = connect(roadrunner_listener:port(Name)),
    try
        ?assertMatch({413, _, _}, post(Conn, ~"/small", ~"abc")),
        ?assertEqual({200, ~"2"}, status_body(post(Conn, ~"/small", ~"ab")))
    after
        close(Conn),
        roadrunner_listener:stop(Name)
    end.

route_body_cap_expect_continue(_Config) ->
    %% The interim 100 and the early 413 follow the route's cap.
    Name = listener_name(route_body_cap_expect_continue),
    {ok, _} = start_h3(Name, route_cap_opts()),
    Conn = ll_connect(roadrunner_listener:port(Name)),
    try
        Within = roadrunner_quic_test_conn:open_bidi(Conn),
        ok = roadrunner_quic_test_conn:send(
            Conn, Within, route_expect_headers(~"/up", ~"20"), false
        ),
        receive
            {quic_test_stream, Conn, Within, Interim, false} ->
                {ok, {headers, Block}, <<>>} = roadrunner_quic_h3_frame:decode(Interim),
                ?assertEqual({ok, [{~":status", ~"100"}]}, roadrunner_qpack:decode(Block))
        after 5000 -> ct:fail(no_interim_response)
        end,
        ok = roadrunner_quic_test_conn:send(
            Conn, Within, roadrunner_quic_h3_frame:encode_data(binary:copy(~"x", 20), 20), true
        ),
        {fin, Bytes} = ll_collect_until_end(Conn, Within, <<>>),
        {ok, {headers, Final}, _} = roadrunner_quic_h3_frame:decode(Bytes),
        ?assertMatch({ok, [{~":status", ~"200"} | _]}, roadrunner_qpack:decode(Final)),
        Over = roadrunner_quic_test_conn:open_bidi(Conn),
        ok = roadrunner_quic_test_conn:send(
            Conn, Over, route_expect_headers(~"/small", ~"3"), false
        ),
        {fin, Refused} = ll_collect_until_end(Conn, Over, <<>>),
        {ok, {headers, Refusal}, _} = roadrunner_quic_h3_frame:decode(Refused),
        ?assertMatch({ok, [{~":status", ~"413"} | _]}, roadrunner_qpack:decode(Refusal))
    after
        ll_close(Conn),
        roadrunner_listener:stop(Name)
    end.

route_rate_limit_refuses(_Config) ->
    %% `/login` allows one request a minute per client, checked by the stream
    %% worker once the request is routed; `/open` sets no limit.
    Name = listener_name(route_rate_limit_refuses),
    {ok, _} = start_h3(Name, #{
        routes => [
            #{
                path => ~"/login",
                handler => roadrunner_client_ip_handler,
                rate_limit => #{rate => 1, period => 60}
            },
            {~"/open", roadrunner_client_ip_handler}
        ]
    }),
    Conn = connect(roadrunner_listener:port(Name)),
    try
        ?assertMatch({200, _, _}, get(Conn, ~"/login")),
        {429, Headers, _} = get(Conn, ~"/login"),
        ?assertEqual({~"retry-after", ~"60"}, lists:keyfind(~"retry-after", 1, Headers)),
        ?assertMatch({200, _, _}, get(Conn, ~"/open"))
    after
        close(Conn),
        roadrunner_listener:stop(Name)
    end.

%% An 8-byte listener cap and routes that raise it (`/up`), lower it
%% (`/small`) or keep it (`/plain`).
route_cap_opts() ->
    #{
        max_content_length => 8,
        routes => [
            #{path => ~"/up", handler => roadrunner_body_size_handler, max_content_length => 64},
            #{path => ~"/small", handler => roadrunner_body_size_handler, max_content_length => 2},
            {~"/plain", roadrunner_body_size_handler}
        ]
    }.

%% A POST HEADERS frame to `Path`, its body to follow, with a declared
%% `content-length` and `expect: 100-continue`.
route_expect_headers(Path, ContentLength) ->
    roadrunner_quic_h3_frame:encode_headers(
        roadrunner_qpack:encode(
            headers(~"POST", Path) ++
                [{~"content-length", ContentLength}, {~"expect", ~"100-continue"}]
        )
    ).

other_expectation_gets_no_interim(Config) ->
    %% Only `100-continue` asks for the interim response.
    Conn = ll_connect(?config(port, Config)),
    try
        StreamId = roadrunner_quic_test_conn:open_bidi(Conn),
        ok = roadrunner_quic_test_conn:send(
            Conn, StreamId, expect_headers(~"3", ~"something-else"), false
        ),
        receive
            {quic_test_stream, Conn, StreamId, _, _} -> ct:fail(unexpected_interim)
        after 300 -> ok
        end,
        ok = roadrunner_quic_test_conn:send(
            Conn, StreamId, roadrunner_quic_h3_frame:encode_data(~"abc", 3), true
        ),
        ?assertMatch({fin, _}, ll_collect_until_end(Conn, StreamId, <<>>))
    after
        ll_close(Conn)
    end.

%% A POST HEADERS frame, its body to follow, with a declared
%% `content-length` and an `expect` field.
expect_headers(ContentLength, Expect) ->
    roadrunner_quic_h3_frame:encode_headers(
        roadrunner_qpack:encode(
            headers(~"POST", ~"/echo") ++
                [{~"content-length", ContentLength}, {~"expect", Expect}]
        )
    ).

real_ip_resolves_client_behind_trusted_proxy(_Config) ->
    %% The loopback peer is a trusted proxy here, so the client address
    %% comes from its `X-Forwarded-For`.
    Name = listener_name(real_ip_resolves_client_behind_trusted_proxy),
    {ok, _} = start_h3(Name, #{
        real_ip => #{trusted_proxies => [~"127.0.0.1"]},
        routes => roadrunner_client_ip_handler
    }),
    Conn = connect(roadrunner_listener:port(Name)),
    try
        {ok, StreamId} = roadrunner_quic_test_h3:open_request(
            Conn, headers(~"GET", ~"/") ++ [{~"x-forwarded-for", ~"203.0.113.7, 127.0.0.1"}]
        ),
        ?assertEqual({200, ~"203.0.113.7"}, status_body(collect(Conn, StreamId)))
    after
        close(Conn),
        roadrunner_listener:stop(Name)
    end.

oversized_413(_Config) ->
    Name = listener_name(oversized_413),
    {ok, _} = start_h3(Name, #{max_content_length => 8}),
    Conn = connect(roadrunner_listener:port(Name)),
    try
        {ok, StreamId} = roadrunner_quic_test_h3:open_request(
            Conn, headers(~"POST", ~"/echo"), false
        ),
        %% First chunk already exceeds the 8-byte cap → 413.
        ok = roadrunner_quic_test_h3:send_data(Conn, StreamId, binary:copy(<<"x">>, 32), false),
        ?assertMatch({413, _, _}, collect(Conn, StreamId)),
        %% A trailing chunk on the already-answered stream is ignored.
        _ = roadrunner_quic_test_h3:send_data(Conn, StreamId, ~"more", true),
        ok
    after
        close(Conn),
        roadrunner_listener:stop(Name)
    end.

oversized_headers_431(_Config) ->
    %% A request whose encoded field section exceeds `max_header_block` is
    %% answered 431, rejected by the conn loop before dispatch (parity with
    %% the body 413). A small cap keeps the over-cap header inside one packet,
    %% so the server rejects it on the first frame rather than mid-flood.
    Name = listener_name(oversized_headers_431),
    {ok, _} = start_h3(Name, #{
        protocols => [{http3, #{max_header_block => 100}}]
    }),
    Conn = connect(roadrunner_listener:port(Name)),
    try
        Headers = headers(~"GET", ~"/") ++ [{~"x-big", binary:copy(<<"v">>, 300)}],
        {ok, StreamId} = roadrunner_quic_test_h3:open_request(Conn, Headers, false),
        ?assertMatch({431, _, _}, collect(Conn, StreamId)),
        %% The connection survives the rejection and serves a fresh request.
        ?assertEqual({200, ~"ok"}, status_body(get(Conn, ~"/")))
    after
        close(Conn),
        roadrunner_listener:stop(Name)
    end.

advertises_max_field_section_size(_Config) ->
    %% RFC 9114 §7.2.4.1: the server advertises SETTINGS_MAX_FIELD_SECTION_SIZE
    %% on its control stream so conformant clients self-limit (§4.2.2). A
    %% connected client reads it back via get_peer_settings.
    Name = listener_name(advertises_max_field_section_size),
    {ok, _} = start_h3(Name, #{
        protocols => [{http3, #{max_field_section_size => 54321}}]
    }),
    Conn = connect(roadrunner_listener:port(Name)),
    try
        Settings = roadrunner_quic_test_h3:get_peer_settings(Conn),
        ?assertEqual(54321, maps:get(max_field_section_size, Settings))
    after
        close(Conn),
        roadrunner_listener:stop(Name)
    end.

advertises_grease_setting(Config) ->
    %% RFC 9114 §7.2.4.1: the server includes a reserved "GREASE" setting
    %% (id 0x1f*N+0x21) in its control-stream SETTINGS so peers that
    %% mishandle unknown settings are caught early. A conformant client
    %% keeps the unknown id under its integer key and otherwise ignores it.
    Conn = connect(?config(port, Config)),
    Settings = roadrunner_quic_test_h3:get_peer_settings(Conn),
    ?assertMatch(#{16#1f21 := 0}, Settings),
    close(Conn).

field_section_too_large_431(_Config) ->
    %% RFC 9114 §4.2.2: a request whose DECODED field section exceeds the
    %% advertised MAX_FIELD_SECTION_SIZE is answered 431. A conformant h3
    %% client self-limits to the advertised value, so this drives a raw,
    %% non-conformant client (the same codecs roadrunner's server uses)
    %% over a plain QUIC stream. A 300-byte header stays well under
    %% the 16384 encoded cap but blows the tiny 200-byte decoded limit.
    Name = listener_name(field_section_too_large_431),
    {ok, _} = start_h3(Name, #{
        protocols => [{http3, #{max_field_section_size => 200}}]
    }),
    Conn = ll_connect(roadrunner_listener:port(Name)),
    try
        StreamId = roadrunner_quic_test_conn:open_bidi(Conn),
        Headers = headers(~"GET", ~"/") ++ [{~"x-pad", binary:copy(<<"v">>, 300)}],
        Block = iolist_to_binary(roadrunner_qpack:encode(Headers)),
        %% Stay under the 16384 encoded cap so the ENCODED gate can't fire;
        %% the decoded size (well over the 200 cap) is what triggers the 431.
        ?assert(byte_size(Block) < 16384),
        ok = roadrunner_quic_test_conn:send(
            Conn, StreamId, roadrunner_quic_h3_frame:encode_headers(Block), true
        ),
        ?assertEqual(431, raw_h3_response_status(Conn, StreamId, <<>>))
    after
        ll_close(Conn),
        roadrunner_listener:stop(Name)
    end.

%% Accumulate raw QUIC stream data on `StreamId` until the leading h3
%% HEADERS frame is complete, then QPACK-decode it and return `:status`
%% as an integer. Ignores frames on the server's control / QPACK streams.
raw_h3_response_status(Conn, StreamId, Acc) ->
    receive
        {quic_test_stream, Conn, StreamId, Bin, _Fin} ->
            Buf = <<Acc/binary, Bin/binary>>,
            case roadrunner_quic_h3_frame:decode(Buf) of
                {ok, {headers, Block}, _Rest} ->
                    {ok, Hdrs} = roadrunner_qpack:decode(Block),
                    binary_to_integer(proplists:get_value(~":status", Hdrs));
                {more, _} ->
                    raw_h3_response_status(Conn, StreamId, Buf);
                {error, Reason} ->
                    ct:fail({h3_frame_decode_error, Reason})
            end
    after 5000 ->
        ct:fail(no_h3_response)
    end.

protocols_tuple_form(_Config) ->
    Name = listener_name(protocols_tuple_form),
    {ok, _} = roadrunner_listener:start_link(Name, #{
        port => 0,
        protocols => [{http3, #{}}],
        tls => roadrunner_test_certs:server_opts(),
        routes => roadrunner_h3_test_handler
    }),
    Conn = connect(roadrunner_listener:port(Name)),
    try
        ?assertEqual({200, ~"ok"}, status_body(get(Conn, ~"/")))
    after
        close(Conn),
        roadrunner_listener:stop(Name)
    end.

%% `ip` restricts the whole listener, including the HTTP/3 UDP socket, to a
%% single interface: an h3 listener bound to loopback still serves a request
%% over loopback, proving `ip` threads through to the QUIC bind, not just TCP.
ip_binds_loopback(_Config) ->
    Name = listener_name(ip_binds_loopback),
    {ok, _} = start_h3(Name, #{ip => {127, 0, 0, 1}}),
    Conn = connect(roadrunner_listener:port(Name)),
    try
        ?assertEqual({200, ~"ok"}, status_body(get(Conn, ~"/")))
    after
        close(Conn),
        roadrunner_listener:stop(Name)
    end.

certfile_keyfile(Config) ->
    %% Drive the listener through `certfile` / `keyfile` PEM paths
    %% (the production form) rather than inline DER, by writing the
    %% test PKI out to disk first.
    Server = roadrunner_test_certs:server_opts(),
    {cert, CertDer} = lists:keyfind(cert, 1, Server),
    {key, {KeyType, KeyDer}} = lists:keyfind(key, 1, Server),
    Dir = ?config(priv_dir, Config),
    CertFile = filename:join(Dir, "h3_cert.pem"),
    KeyFile = filename:join(Dir, "h3_key.pem"),
    ok = file:write_file(
        CertFile, public_key:pem_encode([{'Certificate', CertDer, not_encrypted}])
    ),
    ok = file:write_file(KeyFile, public_key:pem_encode([{KeyType, KeyDer, not_encrypted}])),
    Name = listener_name(certfile_keyfile),
    {ok, _} = roadrunner_listener:start_link(Name, #{
        port => 0,
        %% Exercise the `{http3, #{...}}` tuple form + the
        %% `max_header_block` flatten path through a real boot.
        protocols => [{http3, #{max_header_block => 32768}}],
        tls => [{certfile, CertFile}, {keyfile, KeyFile}],
        routes => roadrunner_h3_test_handler
    }),
    Conn = connect(roadrunner_listener:port(Name)),
    try
        ?assertEqual({200, ~"ok"}, status_body(get(Conn, ~"/")))
    after
        close(Conn),
        roadrunner_listener:stop(Name)
    end.

certs_keys_form(_Config) ->
    %% OTP's modern `certs_keys` form (a list of cert/key config maps)
    %% works for h3, the same as on the TCP listener.
    Server = roadrunner_test_certs:server_opts(),
    {cert, CertDer} = lists:keyfind(cert, 1, Server),
    {key, Key} = lists:keyfind(key, 1, Server),
    Name = listener_name(certs_keys_form),
    {ok, _} = roadrunner_listener:start_link(Name, #{
        port => 0,
        protocols => [http3],
        tls => [{certs_keys, [#{cert => CertDer, key => Key}]}],
        routes => roadrunner_h3_test_handler
    }),
    Conn = connect(roadrunner_listener:port(Name)),
    try
        ?assertEqual({200, ~"ok"}, status_body(get(Conn, ~"/")))
    after
        close(Conn),
        roadrunner_listener:stop(Name)
    end.

cert_chain(Config) ->
    %% A `certfile` bundling the leaf cert and an intermediate (a
    %% Let's Encrypt style `fullchain.pem`) is split into the leaf and
    %% its chain; the listener starts and serves with the chain set.
    Server = roadrunner_test_certs:server_opts(),
    {cert, LeafDer} = lists:keyfind(cert, 1, Server),
    {key, {KeyType, KeyDer}} = lists:keyfind(key, 1, Server),
    {cacerts, [CaDer | _]} = lists:keyfind(cacerts, 1, Server),
    Dir = ?config(priv_dir, Config),
    FullChain = filename:join(Dir, "h3_fullchain.pem"),
    KeyFile = filename:join(Dir, "h3_chain_key.pem"),
    ok = file:write_file(
        FullChain,
        public_key:pem_encode([
            {'Certificate', LeafDer, not_encrypted},
            {'Certificate', CaDer, not_encrypted}
        ])
    ),
    ok = file:write_file(KeyFile, public_key:pem_encode([{KeyType, KeyDer, not_encrypted}])),
    Name = listener_name(cert_chain),
    {ok, _} = roadrunner_listener:start_link(Name, #{
        port => 0,
        protocols => [http3],
        tls => [{certfile, FullChain}, {keyfile, KeyFile}],
        routes => roadrunner_h3_test_handler
    }),
    Conn = connect(roadrunner_listener:port(Name)),
    try
        ?assertEqual({200, ~"ok"}, status_body(get(Conn, ~"/")))
    after
        close(Conn),
        roadrunner_listener:stop(Name)
    end.

quic_start_failure_releases_tcp(_Config) ->
    %% TCP binds but the QUIC listener can't (its UDP port is taken), so
    %% `init/1` closes the TCP socket it already opened and fails to start.
    process_flag(trap_exit, true),
    %% Pin a port that is free for TCP but occupied for UDP, so the TCP
    %% listen reliably succeeds and only the QUIC (UDP) bind fails. Using
    %% a bare UDP-ephemeral port let the TCP listen occasionally fail
    %% first (when that port happened to be TCP-taken), which dodged the
    %% "release TCP after QUIC fails" branch this test is meant to cover.
    {Occupier, Port} = udp_occupied_tcp_free_port(),
    try
        Result = roadrunner_listener:start_link(listener_name(quic_start_failure_releases_tcp), #{
            port => Port,
            protocols => [http1, http3],
            tls => roadrunner_test_certs:server_opts(),
            routes => roadrunner_h3_test_handler
        }),
        ?assertMatch({error, {listen_failed, _}}, Result)
    after
        ok = gen_udp:close(Occupier)
    end.

co_listen(_Config) ->
    Name = listener_name(co_listen),
    Port = free_tcp_and_udp_port(),
    {ok, _} = roadrunner_listener:start_link(Name, #{
        port => Port,
        protocols => [http1, http3],
        tls => roadrunner_test_certs:server_opts(),
        routes => roadrunner_h3_test_handler
    }),
    try
        ?assertEqual(Port, roadrunner_listener:port(Name)),
        %% h1 over TCP+TLS on the same port.
        {ok, Sock} = ssl:connect(
            {127, 0, 0, 1},
            Port,
            [
                {verify, verify_none},
                binary,
                {active, false},
                {alpn_advertised_protocols, [~"http/1.1"]}
            ],
            5000
        ),
        ok = ssl:send(Sock, ~"GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"),
        {ok, Reply} = ssl:recv(Sock, 0, 5000),
        ReplyBin = iolist_to_binary(Reply),
        ?assertMatch(<<"HTTP/1.1 200", _/binary>>, ReplyBin),
        %% RFC 7838: the h1 response advertises the co-served h3 endpoint.
        AltSvc = <<"h3=\":", (integer_to_binary(Port))/binary, "\"">>,
        ?assertNotEqual(nomatch, binary:match(ReplyBin, AltSvc)),
        ok = ssl:close(Sock),
        %% h3 over UDP on the same port.
        Conn = connect(Port),
        ?assertEqual({200, ~"ok"}, status_body(get(Conn, ~"/"))),
        close(Conn)
    after
        roadrunner_listener:stop(Name)
    end.

rejects_http3_without_tls(_Config) ->
    process_flag(trap_exit, true),
    Result = roadrunner_listener:start_link(listener_name(rejects_http3_without_tls), #{
        port => 0,
        protocols => [http3],
        routes => roadrunner_h3_test_handler
    }),
    ?assertMatch(
        {error, {{listener_opt_conflict, protocols, [http3], http3_requires_tls}, _Stack}},
        Result
    ).

max_clients_refuse(_Config) ->
    Name = listener_name(max_clients_refuse),
    {ok, _} = start_h3(Name, #{max_clients => 1}),
    Port = roadrunner_listener:port(Name),
    Conn1 = connect(Port),
    try
        %% Conn1 holds the only slot and stays open.
        ?assertEqual({200, ~"ok"}, status_body(get(Conn1, ~"/"))),
        %% Conn2 is refused: either the handshake never completes, or it
        %% connects but no request gets a response before the close.
        case try_connect(Port) of
            {ok, Conn2} ->
                ?assertEqual(error, try_get(Conn2, ~"/")),
                close(Conn2);
            {error, _} ->
                ok
        end
    after
        close(Conn1),
        roadrunner_listener:stop(Name)
    end.

single_listener_ephemeral_port(_Config) ->
    %% A pool of one binds without reuseport, so it takes the ephemeral port
    %% itself rather than one a reuseport probe holds.
    Name = listener_name(single_listener_ephemeral_port),
    {ok, _} = start_h3(Name, #{protocols => [{http3, #{listeners => 1}}]}),
    Conn = connect(roadrunner_listener:port(Name)),
    try
        ?assertEqual({200, ~"ok"}, status_body(get(Conn, ~"/")))
    after
        close(Conn),
        roadrunner_listener:stop(Name)
    end.

max_concurrent_requests_refuse(_Config) ->
    %% A listener with an in-flight ceiling of 1. A `/loop` request parks a
    %% long-lived worker holding the only slot; a second request on the same
    %% connection is refused (H3_REQUEST_REJECTED) and bumps the `throttled`
    %% count from `info/1`. Stopping the loop worker frees the slot.
    Name = listener_name(max_concurrent_requests_refuse),
    {ok, _} = start_h3(Name, #{max_concurrent_requests => 1}),
    Port = roadrunner_listener:port(Name),
    Conn = connect(Port),
    try
        {ok, _StreamId} = roadrunner_quic_test_h3:open_request(Conn, headers(~"GET", ~"/loop")),
        Worker = wait_for_register(roadrunner_h3_loop_test, 1000),
        %% The parked worker holds the single in-flight slot, so the next
        %% request is over the ceiling and gets no response.
        ?assertEqual(error, try_get(Conn, ~"/")),
        ?assert(maps:get(throttled, roadrunner_listener:info(Name)) >= 1),
        %% Releasing the worker frees the slot; a fresh request succeeds once
        %% the worker's `DOWN` has run (the slot release is async, so retry).
        WorkerRef = monitor(process, Worker),
        Worker ! stop,
        receive
            {'DOWN', WorkerRef, process, Worker, _} -> ok
        after 5000 -> ct:fail(loop_worker_did_not_exit)
        end,
        ?assertEqual({200, ~"ok"}, status_body(retry_get(Conn, ~"/", 50)))
    after
        close(Conn),
        roadrunner_listener:stop(Name)
    end.

max_concurrent_requests_shed(_Config) ->
    %% The same ceiling of 1 on a shed listener: the request over it is
    %% answered 503 with the configured Retry-After instead of being reset
    %% with H3_REQUEST_REJECTED, no handler runs for it, and it is counted
    %% as throttled. The connection carries on once the slot frees.
    Name = listener_name(max_concurrent_requests_shed),
    {ok, _} = start_h3(Name, #{
        max_concurrent_requests => 1, overload_mode => {shed, #{retry_after => 7}}
    }),
    Conn = connect(roadrunner_listener:port(Name)),
    try
        ok = wait_for_unregister(roadrunner_h3_loop_test, 5000),
        {ok, _StreamId} = roadrunner_quic_test_h3:open_request(Conn, headers(~"GET", ~"/loop")),
        Worker = wait_for_register(roadrunner_h3_loop_test, 1000),
        {503, Headers, Body} = get(Conn, ~"/loop"),
        ?assertEqual(~"7", proplists:get_value(~"retry-after", Headers)),
        ?assertEqual(~"", iolist_to_binary(Body)),
        %% A handler run for the shed request would have re-registered
        %% the name.
        ?assertEqual(Worker, whereis(roadrunner_h3_loop_test)),
        ?assertMatch(#{throttled := 1}, roadrunner_listener:info(Name)),
        WorkerRef = monitor(process, Worker),
        Worker ! stop,
        receive
            {'DOWN', WorkerRef, process, Worker, _} -> ok
        after 5000 -> ct:fail(loop_worker_did_not_exit)
        end,
        ?assertEqual({200, ~"ok"}, status_body(retry_get(Conn, ~"/", 50)))
    after
        close(Conn),
        roadrunner_listener:stop(Name)
    end.

max_concurrent_requests_queue(_Config) ->
    %% Same ceiling of 1, but the listener queues instead of refusing. The
    %% second request parks until the loop worker lets go of the slot, and
    %% is then served rather than rejected. `open_request/2` and
    %% `collect/2` are separate calls, so the request can be in flight
    %% while the slot is freed.
    Name = listener_name(max_concurrent_requests_queue),
    {ok, _} = start_h3(Name, #{
        max_concurrent_requests => 1,
        overload_mode => {queue, #{max_queued => 4, timeout => 5000}}
    }),
    Conn = connect(roadrunner_listener:port(Name)),
    try
        %% An earlier case uses the same registered name, so wait for it to
        %% be free before claiming it.
        ok = wait_for_unregister(roadrunner_h3_loop_test, 5000),
        {ok, _} = roadrunner_quic_test_h3:open_request(Conn, headers(~"GET", ~"/loop")),
        First = wait_for_register(roadrunner_h3_loop_test, 1000),
        %% Both requests go to `/loop`, whose handler re-registers the
        %% name. That makes dispatch observable: while the second is
        %% parked the name still points at the first worker, and it only
        %% moves once the parked request is granted a slot. Asserting that
        %% is what stops this passing without ever exercising the queue.
        {ok, _} = roadrunner_quic_test_h3:open_request(Conn, headers(~"GET", ~"/loop")),
        timer:sleep(200),
        ?assertEqual(First, whereis(roadrunner_h3_loop_test)),
        FirstRef = monitor(process, First),
        First ! stop,
        receive
            {'DOWN', FirstRef, process, First, _} -> ok
        after 5000 -> ct:fail(loop_worker_did_not_exit)
        end,
        Second = wait_for_new_register(roadrunner_h3_loop_test, First, 5000),
        ?assertNotEqual(First, Second),
        Second ! stop
    after
        close(Conn),
        roadrunner_listener:stop(Name)
    end.

max_concurrent_requests_queue_expires(_Config) ->
    %% Nothing frees a slot before the deadline, so a parked request falls
    %% back to exactly the refusal `refuse` mode would have produced.
    Name = listener_name(max_concurrent_requests_queue_expires),
    {ok, _} = start_h3(Name, #{
        max_concurrent_requests => 1,
        overload_mode => {queue, #{max_queued => 4, timeout => 50}}
    }),
    Conn = connect(roadrunner_listener:port(Name)),
    try
        %% An earlier case uses the same route and registered name, so wait
        %% for it to be free: a stale pid here would mean the slot was
        %% never actually held and nothing ever parked.
        ok = wait_for_unregister(roadrunner_h3_loop_test, 5000),
        {ok, _} = roadrunner_quic_test_h3:open_request(Conn, headers(~"GET", ~"/loop")),
        Worker = wait_for_register(roadrunner_h3_loop_test, 1000),
        ?assertEqual(error, try_get(Conn, ~"/")),
        ?assert(maps:get(throttled, roadrunner_listener:info(Name)) >= 1),
        Worker ! stop
    after
        close(Conn),
        roadrunner_listener:stop(Name)
    end.

max_concurrent_requests_queue_stale_grant(_Config) ->
    %% A grant for a request the loop no longer has is the one leak the
    %% design must handle: the queue took that slot on our behalf, so it
    %% has to be given back. Injected directly, because the window it
    %% happens in is a race by nature.
    Name = listener_name(max_concurrent_requests_queue_stale_grant),
    {ok, _} = start_h3(Name, #{
        max_concurrent_requests => 4,
        overload_mode => {queue, #{max_queued => 4, timeout => 5000}}
    }),
    Conn = connect(roadrunner_listener:port(Name)),
    try
        ?assertEqual({200, ~"ok"}, status_body(get(Conn, ~"/"))),
        [ConnPid] = drain_members(Name),
        ConnPid ! {roadrunner_slot, 999, granted},
        ConnPid ! {roadrunner_slot, 999, timeout},
        %% The connection carries on serving as if nothing happened.
        ?assertEqual({200, ~"ok"}, status_body(get(Conn, ~"/"))),
        ?assert(is_process_alive(ConnPid))
    after
        close(Conn),
        roadrunner_listener:stop(Name)
    end.

max_concurrent_requests_queue_survives_drain(_Config) ->
    %% A parked request is in neither `streams` nor `worker_refs`, so a
    %% drain-complete check that looks only at those closes the connection
    %% under it and drops a request the peer already sent. The slot is
    %% deliberately held by a DIFFERENT connection, so the parked one has
    %% nothing else keeping it alive.
    Name = listener_name(max_concurrent_requests_queue_survives_drain),
    {ok, _} = start_h3(Name, #{
        max_concurrent_requests => 1,
        overload_mode => {queue, #{max_queued => 4, timeout => 5000}}
    }),
    Port = roadrunner_listener:port(Name),
    Holder = connect(Port),
    Parked = connect(Port),
    try
        ok = wait_for_unregister(roadrunner_h3_loop_test, 5000),
        {ok, _} = roadrunner_quic_test_h3:open_request(Holder, headers(~"GET", ~"/loop")),
        First = wait_for_register(roadrunner_h3_loop_test, 1000),
        %% Parks: the only slot is held by the other connection.
        {ok, _} = roadrunner_quic_test_h3:open_request(Parked, headers(~"GET", ~"/loop")),
        timer:sleep(200),
        ?assertEqual(First, whereis(roadrunner_h3_loop_test)),
        %% Drain, then free the slot. The parked request must still be
        %% dispatched rather than dropped with the connection.
        Self = self(),
        _ = spawn(fun() -> Self ! {drained, roadrunner_listener:drain(Name, 5000)} end),
        timer:sleep(200),
        First ! stop,
        Second = wait_for_new_register(roadrunner_h3_loop_test, First, 5000),
        ?assertNotEqual(First, Second),
        Second ! stop,
        receive
            {drained, _} -> ok
        after 10000 -> ct:fail(drain_never_returned)
        end
    after
        close(Holder),
        close(Parked)
    end.

%% Retry a GET until it succeeds: the in-flight slot is released on the
%% worker's `DOWN`, which is processed by the conn loop slightly after the
%% monitor fires here, so the first follow-up request can still race it.
retry_get(_Conn, _Path, 0) ->
    error(retry_get_exhausted);
retry_get(Conn, Path, Tries) ->
    case get(Conn, Path) of
        {error, _} ->
            timer:sleep(20),
            retry_get(Conn, Path, Tries - 1);
        timeout ->
            timer:sleep(20),
            retry_get(Conn, Path, Tries - 1);
        Response ->
            Response
    end.

stream_cancel(Config) ->
    Conn = connect(?config(port, Config)),
    {ok, StreamId} = roadrunner_quic_test_h3:open_request(Conn, headers(~"POST", ~"/echo"), false),
    _ = roadrunner_quic_test_h3:cancel(Conn, StreamId),
    %% The connection survives a peer stream cancel — a fresh request works.
    ?assertEqual({200, ~"ok"}, status_body(get(Conn, ~"/"))),
    close(Conn).

response_to_cancelled_stream(Config) ->
    %% The client STOP_SENDINGs a request stream while the (slow) handler
    %% is still running, so the worker's later send onto the stopped
    %% stream fails — that must be tolerated, not crash the connection.
    Conn = ll_connect(?config(port, Config)),
    Frame = roadrunner_quic_h3_frame:encode_headers(
        roadrunner_qpack:encode(headers(~"GET", ~"/slow"))
    ),
    StreamId = roadrunner_quic_test_conn:open_bidi(Conn),
    ok = roadrunner_quic_test_conn:send(Conn, StreamId, Frame, true),
    _ = roadrunner_quic_test_conn:stop_sending(Conn, StreamId, 0),
    timer:sleep(300),
    ?assertEqual({200, ~"ok"}, ll_get(Conn, ~"/")),
    ll_close(Conn).

badheaders_reset(Config) ->
    Conn = connect(?config(port, Config)),
    %% The handler returns a malformed response, crashing the worker; the
    %% conn resets that stream but stays up for later requests.
    ?assertEqual(error, try_get(Conn, ~"/badheaders")),
    ?assertEqual({200, ~"ok"}, status_body(get(Conn, ~"/"))),
    close(Conn).

fin_without_headers(Config) ->
    %% A request stream that ends with no HEADERS frame is malformed; the
    %% conn resets it but stays up. Driven over a raw QUIC stream so the
    %% bytes reach the conn loop verbatim.
    Conn = ll_connect(?config(port, Config)),
    _ = ll_send(Conn, <<>>, true),
    ?assertEqual({200, ~"ok"}, ll_get(Conn, ~"/")),
    ll_close(Conn).

malformed_request(Config) ->
    %% A syntactically valid HEADERS block that's missing a required
    %% pseudo-header (`:path`) is a malformed message (RFC 9114 §4.1.2):
    %% the stream is reset with H3_MESSAGE_ERROR, the connection lives.
    Conn = ll_connect(?config(port, Config)),
    Block = roadrunner_qpack:encode([{~":method", ~"GET"}, {~":scheme", ~"https"}]),
    StreamId = roadrunner_quic_test_conn:open_bidi(Conn),
    ok = roadrunner_quic_test_conn:send(
        Conn, StreamId, roadrunner_quic_h3_frame:encode_headers(Block), true
    ),
    timer:sleep(100),
    ?assertEqual({200, ~"ok"}, ll_get(Conn, ~"/")),
    ll_close(Conn).

connect_not_implemented(Config) ->
    %% A well-formed CONNECT (RFC 9114 §4.4): roadrunner opens no tunnels,
    %% so the stream gets a 501, as on HTTP/1.1, and the connection lives.
    Conn = connect(?config(port, Config)),
    {ok, StreamId} = roadrunner_quic_test_h3:open_request(
        Conn, [{~":method", ~"CONNECT"}, {~":authority", ~"localhost:443"}]
    ),
    ?assertMatch({501, _, _}, collect(Conn, StreamId)),
    ?assertMatch({200, _, _}, get(Conn, ~"/")),
    close(Conn).

unknown_expectation_417(Config) ->
    %% RFC 9110 §10.1.1: an expectation other than `100-continue` gets a
    %% 417, as on HTTP/1.1, and the connection lives.
    Conn = connect(?config(port, Config)),
    {ok, StreamId} = roadrunner_quic_test_h3:open_request(
        Conn,
        [
            {~":method", ~"GET"},
            {~":scheme", ~"https"},
            {~":authority", ~"localhost"},
            {~":path", ~"/"},
            {~"expect", ~"200-ok"}
        ]
    ),
    ?assertMatch({417, _, _}, collect(Conn, StreamId)),
    ?assertMatch({200, _, _}, get(Conn, ~"/")),
    close(Conn).

data_before_headers(Config) ->
    %% A DATA frame before any HEADERS is an invalid frame sequence
    %% (RFC 9114 §4.1) → H3_FRAME_UNEXPECTED connection error.
    Conn = ll_connect(?config(port, Config)),
    StreamId = roadrunner_quic_test_conn:open_bidi(Conn),
    ok = roadrunner_quic_test_conn:send(
        Conn, StreamId, roadrunner_quic_h3_frame:encode_data(~"x"), false
    ),
    ll_await_closed(Conn).

request_with_trailers(Config) ->
    %% A request with trailing HEADERS (trailers) after the body is valid
    %% (RFC 9114 §4.1); the trailers are ignored and the request is served.
    Conn = ll_connect(?config(port, Config)),
    ReqHeaders = roadrunner_quic_h3_frame:encode_headers(
        roadrunner_qpack:encode(headers(~"POST", ~"/echo"))
    ),
    Data = roadrunner_quic_h3_frame:encode_data(~"body"),
    Trailers = roadrunner_quic_h3_frame:encode_headers(
        roadrunner_qpack:encode([{~"x-checksum", ~"abc"}])
    ),
    StreamId = roadrunner_quic_test_conn:open_bidi(Conn),
    ok = roadrunner_quic_test_conn:send(
        Conn, StreamId, [ReqHeaders, Data, Trailers], true
    ),
    ?assertEqual({200, ~"body"}, ll_collect(Conn, StreamId, <<>>)),
    ll_close(Conn).

malformed_frame(Config) ->
    %% Frame type 0x02 is reserved for HTTP/2 — a connection error of
    %% type H3_FRAME_UNEXPECTED (RFC 9114 §7.2.8): the whole connection
    %% closes.
    Conn = ll_connect(?config(port, Config)),
    _ = ll_send(Conn, <<2, 0>>, true),
    ll_await_closed(Conn).

oversized_frame(Config) ->
    %% A frame declaring a length above the size we buffer is a connection
    %% error (RFC 9114 §10.5, H3_EXCESSIVE_LOAD).
    Conn = ll_connect(?config(port, Config)),
    Oversized = iolist_to_binary([
        roadrunner_quic_varint:encode(0), roadrunner_quic_varint:encode(16#FFFFFFFF)
    ]),
    StreamId = roadrunner_quic_test_conn:open_bidi(Conn),
    ok = roadrunner_quic_test_conn:send(Conn, StreamId, Oversized, false),
    ll_await_closed(Conn).

qpack_decompression_failed(Config) ->
    %% A HEADERS frame whose field block can't be QPACK-decoded is a
    %% connection error (RFC 9204 §2.2): the connection closes.
    Conn = ll_connect(?config(port, Config)),
    StreamId = roadrunner_quic_test_conn:open_bidi(Conn),
    ok = roadrunner_quic_test_conn:send(
        Conn, StreamId, roadrunner_quic_h3_frame:encode_headers(<<>>), true
    ),
    ll_await_closed(Conn).

qpack_decompression_failed_before_body(Config) ->
    %% The same when the field block arrives ahead of a body still to
    %% come, where it is decoded as it arrives rather than at dispatch.
    Conn = ll_connect(?config(port, Config)),
    StreamId = roadrunner_quic_test_conn:open_bidi(Conn),
    ok = roadrunner_quic_test_conn:send(
        Conn, StreamId, roadrunner_quic_h3_frame:encode_headers(<<>>), false
    ),
    ll_await_closed(Conn).

extra_data_after_413(_Config) ->
    %% A body over the cap is answered with 413 and the stream enters
    %% `discarding`. Residual in-flight body (further DATA frames, with
    %% and without FIN) must be ignored — neither leaking, re-triggering
    %% a 413, nor tripping the DATA-before-HEADERS check — and the
    %% connection keeps serving.
    Name = listener_name(extra_data_after_413),
    {ok, _} = start_h3(Name, #{max_content_length => 8}),
    Conn = ll_connect(roadrunner_listener:port(Name)),
    try
        StreamId = roadrunner_quic_test_conn:open_bidi(Conn),
        ReqHeaders = roadrunner_quic_h3_frame:encode_headers(
            roadrunner_qpack:encode(headers(~"POST", ~"/echo"))
        ),
        Over = roadrunner_quic_h3_frame:encode_data(binary:copy(<<"x">>, 32)),
        ok = roadrunner_quic_test_conn:send(
            Conn, StreamId, [ReqHeaders, Over], false
        ),
        timer:sleep(100),
        %% residual DATA without FIN — ignored
        ok = roadrunner_quic_test_conn:send(
            Conn, StreamId, roadrunner_quic_h3_frame:encode_data(~"more"), false
        ),
        timer:sleep(50),
        %% final residual DATA with FIN — drops the discarding marker
        ok = roadrunner_quic_test_conn:send(
            Conn, StreamId, roadrunner_quic_h3_frame:encode_data(~"end"), true
        ),
        timer:sleep(50),
        ?assertEqual({200, ~"ok"}, ll_get(Conn, ~"/"))
    after
        ll_close(Conn),
        roadrunner_listener:stop(Name)
    end.

refused_request_with_fin_is_dropped(_Config) ->
    %% A request refused (413, 431) in the chunk that also carries its FIN
    %% leaves nothing behind: no more data or reset comes for that stream, so
    %% an entry kept for it would never be freed and would hold a graceful
    %% drain open until its deadline.
    Name = listener_name(refused_request_with_fin_is_dropped),
    {ok, _} = start_h3(Name, #{
        max_content_length => 8, protocols => [{http3, #{max_header_block => 100}}]
    }),
    Conn = ll_connect(roadrunner_listener:port(Name)),
    try
        TooLarge = roadrunner_quic_test_conn:open_bidi(Conn),
        ok = roadrunner_quic_test_conn:send(
            Conn,
            TooLarge,
            [
                roadrunner_quic_h3_frame:encode_headers(
                    roadrunner_qpack:encode(headers(~"POST", ~"/echo"))
                ),
                roadrunner_quic_h3_frame:encode_data(binary:copy(~"x", 32))
            ],
            true
        ),
        ?assertMatch({fin, _}, ll_collect_until_end(Conn, TooLarge, <<>>)),
        BigHeaders = roadrunner_quic_test_conn:open_bidi(Conn),
        ok = roadrunner_quic_test_conn:send(
            Conn,
            BigHeaders,
            roadrunner_quic_h3_frame:encode_headers(
                roadrunner_qpack:encode(
                    headers(~"GET", ~"/") ++ [{~"x-big", binary:copy(~"v", 300)}]
                )
            ),
            true
        ),
        ?assertMatch({fin, _}, ll_collect_until_end(Conn, BigHeaders, <<>>)),
        ?assertEqual({ok, drained}, roadrunner_listener:drain(Name, 2000))
    after
        ll_close(Conn)
    end.

stop_sending_ignored(Config) ->
    %% A peer STOP_SENDING surfaces as an event the conn loop doesn't act
    %% on; it is ignored and the connection keeps serving.
    Conn = ll_connect(?config(port, Config)),
    StreamId = roadrunner_quic_test_conn:open_bidi(Conn),
    ok = roadrunner_quic_test_conn:send(Conn, StreamId, <<>>, false),
    _ = roadrunner_quic_test_conn:stop_sending(Conn, StreamId, 0),
    timer:sleep(100),
    ?assertEqual({200, ~"ok"}, ll_get(Conn, ~"/")),
    ll_close(Conn).

peer_push_stream_closes_conn(Config) ->
    %% RFC 9114 §6.2.2 / §7.2.5: only servers open push streams, so a
    %% client-initiated one is a connection error
    %% (H3_STREAM_CREATION_ERROR) — the connection closes.
    Conn = ll_connect(?config(port, Config)),
    _ = ll_open_uni(Conn, roadrunner_quic_h3_frame:encode_stream_type(push), false),
    ll_await_closed(Conn).

peer_allows_no_uni_stream_closes_conn(Config) ->
    %% RFC 9114 §6.2: a client MUST allow the server at least three
    %% unidirectional streams. One allowing none leaves no room for the
    %% server's control stream (RFC 9000 §4.6), so the server closes the
    %% connection with H3_GENERAL_PROTOCOL_ERROR.
    {ok, Conn} = roadrunner_quic_test_conn:connect(
        {127, 0, 0, 1}, ?config(port, Config), #{max_streams_uni => 0}
    ),
    receive
        {quic_test_closed, Conn, ErrorCode} -> ?assertEqual(16#0101, ErrorCode)
    after 5000 ->
        ct:fail(connection_not_closed)
    end.

peer_control_stream_closed(Config) ->
    %% RFC 9114 §6.2.1: the control stream is critical; the peer closing
    %% it (FIN) is a connection error of type H3_CLOSED_CRITICAL_STREAM.
    Conn = ll_connect(?config(port, Config)),
    _ = ll_open_uni(Conn, control_with_settings(), true),
    ll_await_closed(Conn).

unknown_uni_stream_ignored(Config) ->
    %% RFC 9114 §6.2.3: an unknown unidirectional stream type is ignored
    %% (read and discarded); the connection keeps serving.
    Conn = ll_connect(?config(port, Config)),
    _ = ll_open_uni(Conn, roadrunner_quic_h3_frame:encode_stream_type(16#21), true),
    timer:sleep(50),
    ?assertEqual({200, ~"ok"}, ll_get(Conn, ~"/")),
    ll_close(Conn).

peer_control_stream_reset(Config) ->
    %% RESET_STREAM on the control stream aborts a critical stream →
    %% H3_CLOSED_CRITICAL_STREAM connection error.
    Conn = ll_connect(?config(port, Config)),
    StreamId = ll_open_uni(Conn, control_with_settings(), false),
    %% Round-trip a request so the server has surely classified the
    %% control stream (processed its SETTINGS, sent before this request)
    %% before we reset it — a fixed sleep races under load, leaving the
    %% reset to hit an unclassified stream that is silently dropped.
    ?assertEqual({200, ~"ok"}, ll_get(Conn, ~"/")),
    _ = roadrunner_quic_test_conn:reset_stream(Conn, StreamId, 0),
    ll_await_closed(Conn).

noncritical_uni_stream_reset(Config) ->
    %% RESET_STREAM on a non-critical uni stream just drops its state;
    %% the connection keeps serving.
    Conn = ll_connect(?config(port, Config)),
    StreamId = ll_open_uni(Conn, roadrunner_quic_h3_frame:encode_stream_type(16#21), false),
    timer:sleep(50),
    _ = roadrunner_quic_test_conn:reset_stream(Conn, StreamId, 0),
    timer:sleep(50),
    ?assertEqual({200, ~"ok"}, ll_get(Conn, ~"/")),
    ll_close(Conn).

drain(Config) ->
    Name = ?config(listener, Config),
    Conn = connect(?config(port, Config)),
    ?assertEqual({200, ~"ok"}, status_body(get(Conn, ~"/"))),
    %% The h3 conn loop registered in the listener's drain registry.
    ?assertMatch([_ | _], drain_members(Name)),
    %% With no request in flight, draining sends a GOAWAY and closes the
    %% idle connection cleanly, so the listener drains before the
    %% deadline (exercises the conn-loop drain branch + clean close).
    ?assertEqual({ok, drained}, roadrunner_listener:drain(Name, 2000)),
    close(Conn).

refuse_request_during_drain(Config) ->
    %% RFC 9114 §5.2: after GOAWAY, a request stream opened at or beyond
    %% the GOAWAY id is rejected with H3_REQUEST_REJECTED, while an
    %% in-flight request still completes.
    Name = ?config(listener, Config),
    Conn = ll_connect(?config(port, Config)),
    %% A slow request keeps a worker in flight across the drain.
    SlowFrame = roadrunner_quic_h3_frame:encode_headers(
        roadrunner_qpack:encode(headers(~"GET", ~"/slow"))
    ),
    SlowId = roadrunner_quic_test_conn:open_bidi(Conn),
    ok = roadrunner_quic_test_conn:send(Conn, SlowId, SlowFrame, true),
    timer:sleep(20),
    %% Drive the conn loop's drain directly — the same message the
    %% listener broadcasts (its synchronous `drain/2` would block here).
    [LoopPid] = drain_members(Name),
    LoopPid ! {roadrunner_drain, erlang:monotonic_time(millisecond) + 5000},
    timer:sleep(20),
    %% A request opened after the GOAWAY is rejected.
    NewFrame = roadrunner_quic_h3_frame:encode_headers(
        roadrunner_qpack:encode(headers(~"GET", ~"/"))
    ),
    NewId = roadrunner_quic_test_conn:open_bidi(Conn),
    ok = roadrunner_quic_test_conn:send(Conn, NewId, NewFrame, true),
    ?assertEqual(16#10b, ll_await_reset(Conn, NewId)),
    %% The in-flight slow request still completes.
    ?assertEqual({200, ~"slow"}, ll_collect(Conn, SlowId, <<>>)),
    ll_close(Conn).

drain_refuses_new_connections(Config) ->
    %% Once draining, the listener drops a new client's Initial, so no
    %% connection starts that would miss the drain broadcast and hold the
    %% drain to its deadline. The open connection still finishes its
    %% in-flight request.
    Name = ?config(listener, Config),
    Port = ?config(port, Config),
    Conn = connect(Port),
    try
        ok = wait_for_unregister(roadrunner_h3_loop_test, 5000),
        {ok, LoopId} = roadrunner_quic_test_h3:open_request(Conn, headers(~"GET", ~"/loop")),
        Worker = wait_for_register(roadrunner_h3_loop_test, 1000),
        Self = self(),
        _ = spawn(fun() -> Self ! {drained, roadrunner_listener:drain(Name, 10000)} end),
        %% The GOAWAY goes out after the accept gate closed, so the new
        %% connection below is attempted while draining.
        ?assertEqual({goaway, LoopId + 4}, await_goaway(Conn)),
        ?assertMatch({error, _}, try_connect(Port)),
        Worker ! stop,
        ?assertMatch({200, _, _}, roadrunner_quic_test_h3:collect(Conn, LoopId)),
        receive
            {drained, Drained} -> ?assertEqual({ok, drained}, Drained)
        after 10000 -> ct:fail(drain_never_returned)
        end
    after
        close(Conn)
    end.

drain_closes_a_mid_handshake_connection(Config) ->
    %% A connection still handshaking when the drain arrives has no control
    %% stream for a GOAWAY, so it is closed outright and frees its slot,
    %% and the drain finishes well before its deadline. A relay forwards
    %% the client's packets to the listener but drops the replies, so the
    %% server's handshake can never complete.
    Name = ?config(listener, Config),
    Port = ?config(port, Config),
    {ok, Relay} = gen_udp:open(0, [binary, {ip, {127, 0, 0, 1}}, {active, true}]),
    {ok, RelayPort} = inet:port(Relay),
    Self = self(),
    Client = spawn(fun() -> Self ! {client, try_connect(RelayPort)} end),
    try
        receive
            {udp, Relay, _, ClientPort, Initial} when ClientPort =/= Port ->
                ok = gen_udp:send(Relay, {127, 0, 0, 1}, Port, Initial)
        after 5000 -> ct:fail(no_client_initial)
        end,
        %% The server answers once it holds a connection for the Initial.
        receive
            {udp, Relay, _, Port, _ServerReply} -> ok
        after 5000 -> ct:fail(no_server_reply)
        end,
        ?assertMatch([_], drain_members(Name)),
        ?assertEqual({ok, drained}, roadrunner_listener:drain(Name, 5000))
    after
        exit(Client, kill),
        ok = gen_udp:close(Relay)
    end.

%% --- listener helpers ---

listener_name(Case) ->
    list_to_atom("rr_h3_" ++ atom_to_list(Case)).

start_h3(Name, Extra) ->
    roadrunner_listener:start_link(
        Name,
        maps:merge(
            #{
                port => 0,
                protocols => [http3],
                tls => roadrunner_test_certs:server_opts(),
                routes => roadrunner_h3_test_handler
            },
            Extra
        )
    ).

%% A port free for both UDP and TCP, for a listener that co-serves h1 and
%% h3 on it. A port checked only for UDP can still be taken for TCP, and the
%% listener binds TCP first, so it would fail with `eaddrinuse`.
free_tcp_and_udp_port() ->
    {Occupier, Port} = udp_occupied_tcp_free_port(),
    ok = gen_udp:close(Occupier),
    Port.

%% Return an open UDP socket plus its port, having confirmed that port is
%% also free for TCP. The caller occupies UDP while leaving TCP free, so
%% a co-listening h1+h3 listener binds TCP fine and only its QUIC bind
%% fails. Retries until it finds a port free for both protocols.
udp_occupied_tcp_free_port() ->
    {ok, Occupier} = gen_udp:open(0, []),
    {ok, Port} = inet:port(Occupier),
    case gen_tcp:listen(Port, []) of
        {ok, Probe} ->
            ok = gen_tcp:close(Probe),
            {Occupier, Port};
        {error, _} ->
            ok = gen_udp:close(Occupier),
            udp_occupied_tcp_free_port()
    end.

%% --- h3 client helpers ---

connect(Port) ->
    {ok, Conn} = roadrunner_quic_test_h3:connect({127, 0, 0, 1}, Port),
    Conn.

connect(Port, Opts) ->
    {ok, Conn} = roadrunner_quic_test_h3:connect({127, 0, 0, 1}, Port, Opts),
    Conn.

try_connect(Port) ->
    roadrunner_quic_test_h3:connect({127, 0, 0, 1}, Port).

close(Conn) ->
    _ = roadrunner_quic_test_h3:close(Conn),
    ok.

get(Conn, Path) ->
    {ok, StreamId} = roadrunner_quic_test_h3:open_request(Conn, headers(~"GET", Path)),
    collect(Conn, StreamId).

post(Conn, Path, Body) ->
    {ok, StreamId} = roadrunner_quic_test_h3:open_request(Conn, headers(~"POST", Path), false),
    ok = roadrunner_quic_test_h3:send_data(Conn, StreamId, Body, true),
    collect(Conn, StreamId).

%% A request expected to fail (reset / no response) — returns `error`.
try_get(Conn, Path) ->
    {ok, StreamId} = roadrunner_quic_test_h3:open_request(Conn, headers(~"GET", Path)),
    case collect(Conn, StreamId) of
        {error, _} -> error;
        timeout -> error;
        _Response -> ok
    end.

headers(Method, Path) ->
    [
        {~":method", Method},
        {~":scheme", ~"https"},
        {~":authority", ~"localhost"},
        {~":path", Path}
    ].

status_body({Status, _Headers, Body}) -> {Status, Body};
status_body(Other) -> Other.

%% The client's local port as text, as the `/peer` route answers it.
client_port(Conn) ->
    {ok, {_Ip, Port}} = roadrunner_quic_test_conn:sockname(Conn),
    integer_to_binary(Port).

collect(Conn, StreamId) ->
    roadrunner_quic_test_h3:collect(Conn, StreamId).

%% --- low-level QUIC client (raw h3 framing under our control) ---
%%
%% Drives the server over a raw QUIC connection (`roadrunner_quic_test_conn`)
%% so a testcase can put exact bytes on a request stream — malformed frames, a
%% FIN with no HEADERS, trailing DATA — that a conformant h3 client would never
%% emit. We own the HEADERS/QPACK framing here.

ll_connect(Port) ->
    {ok, Conn} = roadrunner_quic_test_conn:connect({127, 0, 0, 1}, Port),
    Conn.

ll_close(Conn) ->
    _ = roadrunner_quic_test_conn:close(Conn),
    ok.

ll_await_closed(Conn) ->
    receive
        {quic_test_closed, Conn, _} -> ok
    after 5000 ->
        ct:fail(connection_not_closed)
    end.

%% Wait for the server to reset `StreamId`, returning the error code.
ll_await_reset(Conn, StreamId) ->
    receive
        {quic_test_stream_reset, Conn, StreamId, ErrorCode} -> ErrorCode
    after 5000 ->
        ct:fail(no_stream_reset)
    end.

%% Read every byte the server writes on `StreamId` until it finishes the
%% stream (`{fin, Bytes}`) or resets it (`{reset, ErrorCode, Bytes}`), so a
%% test can inspect exactly what reached the wire.
ll_collect_until_end(Conn, StreamId, Acc) ->
    receive
        {quic_test_stream, Conn, StreamId, Bin, true} ->
            {fin, <<Acc/binary, Bin/binary>>};
        {quic_test_stream, Conn, StreamId, Bin, false} ->
            ll_collect_until_end(Conn, StreamId, <<Acc/binary, Bin/binary>>);
        {quic_test_stream_reset, Conn, StreamId, ErrorCode} ->
            {reset, ErrorCode, Acc}
    after 5000 ->
        ct:fail(no_stream_end)
    end.

%% Spin until a `{loop, _}` handler registers `Name` (it does so from
%% `handle/1`), so the test can address the worker from outside.
wait_for_new_register(_Name, _Old, RemainingMs) when RemainingMs =< 0 ->
    ct:fail(parked_request_never_dispatched);
wait_for_new_register(Name, Old, RemainingMs) ->
    case whereis(Name) of
        undefined ->
            timer:sleep(10),
            wait_for_new_register(Name, Old, RemainingMs - 10);
        Old ->
            timer:sleep(10),
            wait_for_new_register(Name, Old, RemainingMs - 10);
        New ->
            New
    end.

wait_for_unregister(_Name, RemainingMs) when RemainingMs =< 0 ->
    ct:fail(worker_still_registered);
wait_for_unregister(Name, RemainingMs) ->
    case whereis(Name) of
        undefined ->
            ok;
        _ ->
            timer:sleep(10),
            wait_for_unregister(Name, RemainingMs - 10)
    end.

wait_for_register(_Name, RemainingMs) when RemainingMs =< 0 ->
    ct:fail(worker_not_registered);
wait_for_register(Name, RemainingMs) ->
    case whereis(Name) of
        undefined ->
            timer:sleep(10),
            wait_for_register(Name, RemainingMs - 10);
        Pid ->
            Pid
    end.

ll_send(Conn, Bytes, Fin) ->
    StreamId = roadrunner_quic_test_conn:open_bidi(Conn),
    ok = roadrunner_quic_test_conn:send(Conn, StreamId, Bytes, Fin),
    StreamId.

%% Open a client-initiated unidirectional stream and write `Bytes` (the
%% stream-type prefix + any frames) onto it.
ll_open_uni(Conn, Bytes, Fin) ->
    StreamId = roadrunner_quic_test_conn:open_uni(Conn),
    ok = roadrunner_quic_test_conn:send(Conn, StreamId, Bytes, Fin),
    StreamId.

%% A valid control stream payload: the control stream-type prefix
%% followed by a SETTINGS frame.
control_with_settings() ->
    iolist_to_binary([
        roadrunner_quic_h3_frame:encode_stream_type(control),
        roadrunner_quic_h3_frame:encode_settings(#{qpack_max_table_capacity => 0})
    ]).

ll_get(Conn, Path) ->
    Frame = roadrunner_quic_h3_frame:encode_headers(roadrunner_qpack:encode(headers(~"GET", Path))),
    StreamId = roadrunner_quic_test_conn:open_bidi(Conn),
    ok = roadrunner_quic_test_conn:send(Conn, StreamId, Frame, true),
    ll_collect(Conn, StreamId, <<>>).

ll_collect(Conn, StreamId, Acc) ->
    receive
        {quic_test_stream, Conn, StreamId, Data, true} ->
            ll_decode(<<Acc/binary, Data/binary>>);
        {quic_test_stream, Conn, StreamId, Data, false} ->
            ll_collect(Conn, StreamId, <<Acc/binary, Data/binary>>)
    after 5000 ->
        ct:fail(ll_no_response)
    end.

ll_decode(Bytes) ->
    {ok, {headers, Block}, Rest} = roadrunner_quic_h3_frame:decode(Bytes),
    {ok, RespHeaders} = roadrunner_qpack:decode(Block),
    Status = binary_to_integer(proplists:get_value(~":status", RespHeaders)),
    Body =
        case roadrunner_quic_h3_frame:decode(Rest) of
            {ok, {data, Data}, _} -> Data;
            _ -> <<>>
        end,
    {Status, Body}.

%% Read the server's control stream until its GOAWAY frame, skipping the
%% SETTINGS that precede it. Frames may arrive split across messages.
await_goaway(Conn) ->
    await_goaway(Conn, <<>>).

await_goaway(Conn, Acc) ->
    receive
        {quic_test_stream, Conn, StreamId, Data, _Fin} when StreamId rem 4 =:= 3 ->
            Buf = <<Acc/binary, Data/binary>>,
            {ok, control, Frames} = roadrunner_quic_h3_frame:decode_stream_type(Buf),
            case find_goaway(Frames) of
                {ok, Id} -> {goaway, Id};
                more -> await_goaway(Conn, Buf)
            end
    after 5000 -> ct:fail(no_goaway)
    end.

find_goaway(Frames) ->
    case roadrunner_quic_h3_frame:decode(Frames) of
        {ok, {goaway, Id}, _Rest} -> {ok, Id};
        {ok, _Frame, Rest} -> find_goaway(Rest);
        {more, _Need} -> more
    end.

%% Pids registered in the listener's drain registry, read straight out of
%% the listener state (`#state{proto_opts = #{drain_table := Table}}`).
drain_members(Name) ->
    ProtoOpts = element(4, sys:get_state(whereis(Name))),
    [Pid || {Pid} <- ets:tab2list(maps:get(drain_table, ProtoOpts))].
