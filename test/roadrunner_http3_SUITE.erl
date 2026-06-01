-module(roadrunner_http3_SUITE).
-moduledoc """
End-to-end HTTP/3 tests. Each testcase starts a roadrunner h3 listener
(`protocols => [http3]` over QUIC) and drives it with the `quic`
dependency's HTTP/3 *client* (`quic_h3:connect`) — only the turnkey
*server* is avoided; the client is fine as a test driver.

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
    head_request/1,
    large_post/1,
    not_found/1,
    crash_500/1,
    forbidden_response_header_500/1,
    unsupported_shapes_501/1,
    loop_response/1,
    loop_filters_otp/1,
    loop_conn_close_stops_worker/1,
    stream_response/1,
    stream_trailers/1,
    stream_autoclose/1,
    stream_forbidden_header_500/1,
    sendfile_empty/1,
    sendfile_small/1,
    sendfile_large/1,
    head_sendfile/1,
    oversized_413/1,
    oversized_headers_431/1,
    protocols_tuple_form/1,
    certfile_keyfile/1,
    certs_keys_form/1,
    cert_chain/1,
    quic_start_failure_releases_tcp/1,
    co_listen/1,
    rejects_http3_without_tls/1,
    max_clients_refuse/1,
    max_concurrent_requests_refuse/1,
    stream_cancel/1,
    response_to_cancelled_stream/1,
    badheaders_reset/1,
    fin_without_headers/1,
    malformed_request/1,
    data_before_headers/1,
    request_with_trailers/1,
    malformed_frame/1,
    oversized_frame/1,
    qpack_decompression_failed/1,
    extra_data_after_413/1,
    stop_sending_ignored/1,
    peer_push_stream_closes_conn/1,
    peer_control_stream_closed/1,
    unknown_uni_stream_ignored/1,
    peer_control_stream_reset/1,
    noncritical_uni_stream_reset/1,
    drain/1,
    refuse_request_during_drain/1
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
        head_request,
        large_post,
        not_found,
        crash_500,
        forbidden_response_header_500,
        unsupported_shapes_501,
        loop_response,
        loop_filters_otp,
        loop_conn_close_stops_worker,
        stream_response,
        stream_trailers,
        stream_autoclose,
        stream_forbidden_header_500,
        sendfile_empty,
        sendfile_small,
        sendfile_large,
        head_sendfile,
        oversized_413,
        oversized_headers_431,
        protocols_tuple_form,
        certfile_keyfile,
        certs_keys_form,
        cert_chain,
        quic_start_failure_releases_tcp,
        co_listen,
        rejects_http3_without_tls,
        max_clients_refuse,
        max_concurrent_requests_refuse,
        stream_cancel,
        response_to_cancelled_stream,
        badheaders_reset,
        fin_without_headers,
        malformed_request,
        data_before_headers,
        request_with_trailers,
        malformed_frame,
        oversized_frame,
        qpack_decompression_failed,
        extra_data_after_413,
        stop_sending_ignored,
        peer_push_stream_closes_conn,
        peer_control_stream_closed,
        unknown_uni_stream_ignored,
        peer_control_stream_reset,
        noncritical_uni_stream_reset,
        drain,
        refuse_request_during_drain
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(crypto),
    {ok, _} = application:ensure_all_started(ssl),
    %% roadrunner's h3 listener is self-contained and does NOT start the
    %% `quic` app (see `roadrunner_listener:start_quic/4`); the test CLIENT
    %% below is what needs it, so bring it up once for the whole suite.
    %% Consequence: these cases run with `quic` already up, so they don't
    %% exercise the server's standalone (no-app) path — that's covered
    %% separately by `bench.escript --protocols h3`, where the server peer
    %% serves h3 with no `quic` app running.
    {ok, _} = application:ensure_all_started(quic),
    %% Start the default `pg` scope standalone (the drain group lives
    %% there) rather than the whole roadrunner app, so this suite
    %% coexists with others that started pg in the shared CT node.
    ok = ensure_pg_started(),
    Config.

ensure_pg_started() ->
    %% Start the default `pg` scope unlinked so it survives this
    %% transient `init_per_suite` process (a plain `pg:start_link/0`
    %% would link it here and it would die before the testcases run,
    %% leaving the drain group empty).
    case whereis(pg) of
        undefined ->
            case pg:start_link() of
                {ok, Pid} ->
                    _ = unlink(Pid),
                    ok;
                {error, {already_started, _}} ->
                    ok
            end;
        _ ->
            ok
    end.

end_per_suite(_Config) ->
    ok.

%% Most testcases share a default single-handler h3 listener; the few
%% that need a bespoke config (router, small body cap, co-listen,
%% max_clients, no TLS) start their own and skip this one.
init_per_testcase(Case, Config) when
    Case =:= not_found;
    Case =:= oversized_413;
    Case =:= protocols_tuple_form;
    Case =:= certfile_keyfile;
    Case =:= certs_keys_form;
    Case =:= cert_chain;
    Case =:= quic_start_failure_releases_tcp;
    Case =:= co_listen;
    Case =:= rejects_http3_without_tls;
    Case =:= max_clients_refuse;
    Case =:= max_concurrent_requests_refuse;
    Case =:= extra_data_after_413
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

head_request(Config) ->
    %% RFC 9110 §9.3.2: a HEAD response carries the GET headers but no
    %% body — `/big` would be 100 KB on GET, empty on HEAD.
    Conn = connect(?config(port, Config)),
    {ok, StreamId} = quic_h3:request(Conn, headers(~"HEAD", ~"/big")),
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

crash_500(Config) ->
    Conn = connect(?config(port, Config)),
    ?assertMatch({500, _}, status_body(get(Conn, ~"/crash"))),
    close(Conn).

forbidden_response_header_500(Config) ->
    %% A handler returning any connection-specific header is rejected
    %% (RFC 9114 §4.2): the client sees 500 and the connection survives.
    Conn = connect(?config(port, Config)),
    lists:foreach(
        fun(Name) ->
            ?assertMatch({500, _}, status_body(get(Conn, <<"/forbidden/", Name/binary>>)))
        end,
        [~"connection", ~"keep-alive", ~"proxy-connection", ~"transfer-encoding", ~"upgrade"]
    ),
    close(Conn).

unsupported_shapes_501(Config) ->
    Conn = connect(?config(port, Config)),
    lists:foreach(
        fun(Path) ->
            ?assertMatch({501, _}, status_body(get(Conn, Path)))
        end,
        [~"/websocket"]
    ),
    close(Conn).

loop_response(Config) ->
    %% A `{loop, ...}` response: HEADERS, then DATA chunks pushed from
    %% the handler's `handle_info/3`, FIN on `{stop, _}`.
    Conn = connect(?config(port, Config)),
    {ok, StreamId} = quic_h3:request(Conn, headers(~"GET", ~"/loop")),
    Worker = wait_for_register(roadrunner_h3_loop_test, 1000),
    Worker ! {push, ~"hi"},
    Worker ! push_empty,
    Worker ! stop,
    {200, _Headers, Body} = collect(Conn, StreamId),
    ?assertEqual(~"data: hi\n\ndata: bye(1)\n\n", Body),
    close(Conn).

loop_filters_otp(Config) ->
    %% OTP message shapes are dropped (never reach `handle_info/3`), so
    %% only the real push advances the counter.
    Conn = connect(?config(port, Config)),
    {ok, StreamId} = quic_h3:request(Conn, headers(~"GET", ~"/loop")),
    Worker = wait_for_register(roadrunner_h3_loop_test, 1000),
    Worker ! {system, self(), get_state},
    Worker ! {'$gen_call', {self(), make_ref()}, ping},
    Worker ! {'$gen_cast', noop},
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
    {ok, _StreamId} = quic_h3:request(Conn, headers(~"GET", ~"/loop")),
    Worker = wait_for_register(roadrunner_h3_loop_test, 1000),
    WorkerRef = monitor(process, Worker),
    ok = roadrunner_listener:stop(Name),
    receive
        {'DOWN', WorkerRef, process, Worker, _} -> ok
    after 5000 ->
        ct:fail(loop_worker_did_not_exit)
    end,
    close(Conn).

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
    {ok, StreamId} = quic_h3:request(Conn, headers(~"HEAD", ~"/sendfile-small")),
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

stream_forbidden_header_500(Config) ->
    %% A streaming response carrying a connection-specific header is
    %% rejected with 500 (RFC 9114 §4.2), same as the buffered path.
    Conn = connect(?config(port, Config)),
    ?assertMatch({500, _}, status_body(get(Conn, ~"/stream-forbidden"))),
    close(Conn).

oversized_413(_Config) ->
    Name = listener_name(oversized_413),
    {ok, _} = start_h3(Name, #{max_content_length => 8}),
    Conn = connect(roadrunner_listener:port(Name)),
    try
        {ok, StreamId} = quic_h3:request(Conn, headers(~"POST", ~"/echo"), #{end_stream => false}),
        %% First chunk already exceeds the 8-byte cap → 413.
        ok = quic_h3:send_data(Conn, StreamId, binary:copy(<<"x">>, 32), false),
        ?assertMatch({413, _, _}, collect(Conn, StreamId)),
        %% A trailing chunk on the already-answered stream is ignored.
        _ = quic_h3:send_data(Conn, StreamId, ~"more", true),
        ok
    after
        close(Conn),
        roadrunner_listener:stop(Name)
    end.

oversized_headers_431(Config) ->
    %% A request whose encoded field section exceeds MAX_HEADER_BLOCK
    %% (16384) is answered 431, rejected by the conn loop before dispatch
    %% (parity with the body 413). Uses the shared default listener.
    Conn = connect(?config(port, Config)),
    Big = binary:copy(<<"x">>, 50000),
    {ok, StreamId} = quic_h3:request(Conn, headers(~"GET", ~"/") ++ [{~"x-big", Big}]),
    ?assertMatch({431, _, _}, collect(Conn, StreamId)),
    close(Conn).

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
    Port = free_udp_port(),
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
        {ok, _StreamId} = quic_h3:request(Conn, headers(~"GET", ~"/loop")),
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
    {ok, StreamId} = quic_h3:request(Conn, headers(~"POST", ~"/echo"), #{end_stream => false}),
    _ = quic_h3:cancel(Conn, StreamId),
    %% The connection survives a peer stream cancel — a fresh request works.
    ?assertEqual({200, ~"ok"}, status_body(get(Conn, ~"/"))),
    close(Conn).

response_to_cancelled_stream(Config) ->
    %% The client STOP_SENDINGs a request stream while the (slow) handler
    %% is still running, so the worker's later send onto the stopped
    %% stream fails — that must be tolerated, not crash the connection.
    Conn = ll_connect(?config(port, Config)),
    Frame = quic_h3_frame:encode_headers(quic_qpack:encode(headers(~"GET", ~"/slow"))),
    {ok, StreamId} = quic:open_stream(Conn),
    ok = quic:send_data(Conn, StreamId, Frame, true),
    _ = quic:stop_sending(Conn, StreamId, 0),
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
    Block = quic_qpack:encode([{~":method", ~"GET"}, {~":scheme", ~"https"}]),
    {ok, StreamId} = quic:open_stream(Conn),
    ok = quic:send_data(Conn, StreamId, quic_h3_frame:encode_headers(Block), true),
    timer:sleep(100),
    ?assertEqual({200, ~"ok"}, ll_get(Conn, ~"/")),
    ll_close(Conn).

data_before_headers(Config) ->
    %% A DATA frame before any HEADERS is an invalid frame sequence
    %% (RFC 9114 §4.1) → H3_FRAME_UNEXPECTED connection error.
    Conn = ll_connect(?config(port, Config)),
    {ok, StreamId} = quic:open_stream(Conn),
    ok = quic:send_data(Conn, StreamId, quic_h3_frame:encode_data(~"x"), false),
    ll_await_closed(Conn).

request_with_trailers(Config) ->
    %% A request with trailing HEADERS (trailers) after the body is valid
    %% (RFC 9114 §4.1); the trailers are ignored and the request is served.
    Conn = ll_connect(?config(port, Config)),
    ReqHeaders = quic_h3_frame:encode_headers(quic_qpack:encode(headers(~"POST", ~"/echo"))),
    Data = quic_h3_frame:encode_data(~"body"),
    Trailers = quic_h3_frame:encode_headers(quic_qpack:encode([{~"x-checksum", ~"abc"}])),
    {ok, StreamId} = quic:open_stream(Conn),
    ok = quic:send_data(Conn, StreamId, <<ReqHeaders/binary, Data/binary, Trailers/binary>>, true),
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
    %% A frame declaring a length above the max is a frame error
    %% (RFC 9114 §7.1, H3_FRAME_ERROR) — a connection error.
    Conn = ll_connect(?config(port, Config)),
    Oversized = iolist_to_binary([quic_varint:encode(0), quic_varint:encode(16#FFFFFFFF)]),
    {ok, StreamId} = quic:open_stream(Conn),
    ok = quic:send_data(Conn, StreamId, Oversized, false),
    ll_await_closed(Conn).

qpack_decompression_failed(Config) ->
    %% A HEADERS frame whose field block can't be QPACK-decoded is a
    %% connection error (RFC 9204 §2.2): the connection closes.
    Conn = ll_connect(?config(port, Config)),
    {ok, StreamId} = quic:open_stream(Conn),
    ok = quic:send_data(Conn, StreamId, quic_h3_frame:encode_headers(<<>>), true),
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
        {ok, StreamId} = quic:open_stream(Conn),
        ReqHeaders = quic_h3_frame:encode_headers(quic_qpack:encode(headers(~"POST", ~"/echo"))),
        Over = quic_h3_frame:encode_data(binary:copy(<<"x">>, 32)),
        ok = quic:send_data(Conn, StreamId, <<ReqHeaders/binary, Over/binary>>, false),
        timer:sleep(100),
        %% residual DATA without FIN — ignored
        ok = quic:send_data(Conn, StreamId, quic_h3_frame:encode_data(~"more"), false),
        timer:sleep(50),
        %% final residual DATA with FIN — drops the discarding marker
        ok = quic:send_data(Conn, StreamId, quic_h3_frame:encode_data(~"end"), true),
        timer:sleep(50),
        ?assertEqual({200, ~"ok"}, ll_get(Conn, ~"/"))
    after
        ll_close(Conn),
        roadrunner_listener:stop(Name)
    end.

stop_sending_ignored(Config) ->
    %% A peer STOP_SENDING surfaces as an event the conn loop doesn't act
    %% on; it is ignored and the connection keeps serving.
    Conn = ll_connect(?config(port, Config)),
    {ok, StreamId} = quic:open_stream(Conn),
    ok = quic:send_data(Conn, StreamId, <<>>, false),
    _ = quic:stop_sending(Conn, StreamId, 0),
    timer:sleep(100),
    ?assertEqual({200, ~"ok"}, ll_get(Conn, ~"/")),
    ll_close(Conn).

peer_push_stream_closes_conn(Config) ->
    %% RFC 9114 §6.2.2 / §7.2.5: only servers open push streams, so a
    %% client-initiated one is a connection error
    %% (H3_STREAM_CREATION_ERROR) — the connection closes.
    Conn = ll_connect(?config(port, Config)),
    _ = ll_open_uni(Conn, quic_h3_frame:encode_stream_type(push), false),
    ll_await_closed(Conn).

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
    _ = ll_open_uni(Conn, quic_h3_frame:encode_stream_type(16#21), true),
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
    _ = quic:reset_stream(Conn, StreamId, 0),
    ll_await_closed(Conn).

noncritical_uni_stream_reset(Config) ->
    %% RESET_STREAM on a non-critical uni stream just drops its state;
    %% the connection keeps serving.
    Conn = ll_connect(?config(port, Config)),
    StreamId = ll_open_uni(Conn, quic_h3_frame:encode_stream_type(16#21), false),
    timer:sleep(50),
    _ = quic:reset_stream(Conn, StreamId, 0),
    timer:sleep(50),
    ?assertEqual({200, ~"ok"}, ll_get(Conn, ~"/")),
    ll_close(Conn).

drain(Config) ->
    Name = ?config(listener, Config),
    Conn = connect(?config(port, Config)),
    ?assertEqual({200, ~"ok"}, status_body(get(Conn, ~"/"))),
    %% The h3 conn loop joined the listener's drain group.
    ?assertMatch([_ | _], pg:get_members({roadrunner_drain, Name})),
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
    SlowFrame = quic_h3_frame:encode_headers(quic_qpack:encode(headers(~"GET", ~"/slow"))),
    {ok, SlowId} = quic:open_stream(Conn),
    ok = quic:send_data(Conn, SlowId, SlowFrame, true),
    timer:sleep(20),
    %% Drive the conn loop's drain directly — the same message the
    %% listener broadcasts (its synchronous `drain/2` would block here).
    [LoopPid] = pg:get_members({roadrunner_drain, Name}),
    LoopPid ! {roadrunner_drain, erlang:monotonic_time(millisecond) + 5000},
    timer:sleep(20),
    %% A request opened after the GOAWAY is rejected.
    NewFrame = quic_h3_frame:encode_headers(quic_qpack:encode(headers(~"GET", ~"/"))),
    {ok, NewId} = quic:open_stream(Conn),
    ok = quic:send_data(Conn, NewId, NewFrame, true),
    ?assertEqual(16#10b, ll_await_reset(Conn, NewId)),
    %% The in-flight slow request still completes.
    ?assertEqual({200, ~"slow"}, ll_collect(Conn, SlowId, <<>>)),
    ll_close(Conn).

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

free_udp_port() ->
    {ok, S} = gen_udp:open(0, [{reuseaddr, true}]),
    {ok, Port} = inet:port(S),
    ok = gen_udp:close(S),
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
    {ok, Conn} = quic_h3:connect(~"127.0.0.1", Port, #{verify => verify_none}),
    ok = quic_h3:wait_connected(Conn, 5000),
    Conn.

try_connect(Port) ->
    case quic_h3:connect(~"127.0.0.1", Port, #{verify => verify_none}) of
        {ok, Conn} ->
            case quic_h3:wait_connected(Conn, 2000) of
                ok -> {ok, Conn};
                {error, _} = E -> E
            end;
        {error, _} = E ->
            E
    end.

close(Conn) ->
    _ = quic_h3:close(Conn),
    ok.

get(Conn, Path) ->
    {ok, StreamId} = quic_h3:request(Conn, headers(~"GET", Path)),
    collect(Conn, StreamId).

post(Conn, Path, Body) ->
    {ok, StreamId} = quic_h3:request(Conn, headers(~"POST", Path), #{end_stream => false}),
    ok = quic_h3:send_data(Conn, StreamId, Body, true),
    collect(Conn, StreamId).

%% A request expected to fail (reset / no response) — returns `error`.
try_get(Conn, Path) ->
    {ok, StreamId} = quic_h3:request(Conn, headers(~"GET", Path)),
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

collect(Conn, StreamId) ->
    receive
        {quic_h3, Conn, {response, StreamId, Status, Headers}} ->
            collect_body(Conn, StreamId, Status, Headers, <<>>);
        {quic_h3, Conn, {stream_reset, StreamId, ErrorCode}} ->
            {error, {stream_reset, ErrorCode}};
        {quic_h3, Conn, {error, ErrorCode, _Reason}} ->
            {error, {conn_error, ErrorCode}};
        {quic_h3, Conn, closed} ->
            {error, closed}
    after 5000 ->
        timeout
    end.

collect_body(Conn, StreamId, Status, Headers, Acc) ->
    receive
        {quic_h3, Conn, {data, StreamId, Data, true}} ->
            {Status, Headers, <<Acc/binary, Data/binary>>};
        {quic_h3, Conn, {data, StreamId, Data, false}} ->
            collect_body(Conn, StreamId, Status, Headers, <<Acc/binary, Data/binary>>);
        %% Trailing HEADERS (trailers) end the stream with no fin DATA.
        {quic_h3, Conn, {trailers, StreamId, _Trailers}} ->
            {Status, Headers, Acc}
    after 5000 ->
        timeout
    end.

%% --- low-level QUIC client (raw h3 framing under our control) ---
%%
%% Drives the server over the bare `quic` transport so a testcase can
%% put exact bytes on a request stream — malformed frames, a FIN with
%% no HEADERS, trailing DATA — that the turnkey `quic_h3` client would
%% never emit. We own the HEADERS/QPACK framing here.

ll_connect(Port) ->
    {ok, Conn} = quic:connect(
        ~"127.0.0.1", Port, #{alpn => [~"h3"], verify => verify_none}, self()
    ),
    receive
        {quic, Conn, {connected, _}} -> ok
    after 5000 ->
        ct:fail(ll_not_connected)
    end,
    Conn.

ll_close(Conn) ->
    _ = quic:close(Conn),
    ok.

ll_await_closed(Conn) ->
    receive
        {quic, Conn, {closed, _}} -> ok
    after 5000 ->
        ct:fail(connection_not_closed)
    end.

%% Wait for the server to reset `StreamId`, returning the error code.
ll_await_reset(Conn, StreamId) ->
    receive
        {quic, Conn, {stream_reset, StreamId, ErrorCode}} -> ErrorCode
    after 5000 ->
        ct:fail(no_stream_reset)
    end.

%% Spin until a `{loop, _}` handler registers `Name` (it does so from
%% `handle/1`), so the test can address the worker from outside.
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
    {ok, StreamId} = quic:open_stream(Conn),
    ok = quic:send_data(Conn, StreamId, Bytes, Fin),
    StreamId.

%% Open a client-initiated unidirectional stream and write `Bytes` (the
%% stream-type prefix + any frames) onto it.
ll_open_uni(Conn, Bytes, Fin) ->
    {ok, StreamId} = quic:open_unidirectional_stream(Conn),
    ok = quic:send_data(Conn, StreamId, Bytes, Fin),
    StreamId.

%% A valid control stream payload: the control stream-type prefix
%% followed by a SETTINGS frame.
control_with_settings() ->
    <<
        (quic_h3_frame:encode_stream_type(control))/binary,
        (quic_h3_frame:encode_settings(#{qpack_max_table_capacity => 0}))/binary
    >>.

ll_get(Conn, Path) ->
    Frame = quic_h3_frame:encode_headers(quic_qpack:encode(headers(~"GET", Path))),
    {ok, StreamId} = quic:open_stream(Conn),
    ok = quic:send_data(Conn, StreamId, Frame, true),
    ll_collect(Conn, StreamId, <<>>).

ll_collect(Conn, StreamId, Acc) ->
    receive
        {quic, Conn, {stream_data, StreamId, Data, true}} ->
            ll_decode(<<Acc/binary, Data/binary>>);
        {quic, Conn, {stream_data, StreamId, Data, false}} ->
            ll_collect(Conn, StreamId, <<Acc/binary, Data/binary>>)
    after 5000 ->
        ct:fail(ll_no_response)
    end.

ll_decode(Bytes) ->
    {ok, {headers, Block}, Rest} = quic_h3_frame:decode(Bytes),
    {ok, RespHeaders} = quic_qpack:decode(Block),
    Status = binary_to_integer(proplists:get_value(~":status", RespHeaders)),
    Body =
        case quic_h3_frame:decode(Rest) of
            {ok, {data, Data}, _} -> Data;
            _ -> <<>>
        end,
    {Status, Body}.
