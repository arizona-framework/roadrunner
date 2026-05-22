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
    get_method/1,
    post_echo/1,
    empty_204/1,
    large_body/1,
    large_post/1,
    not_found/1,
    crash_500/1,
    unsupported_shapes_501/1,
    oversized_413/1,
    protocols_tuple_form/1,
    certfile_keyfile/1,
    quic_start_failure_releases_tcp/1,
    co_listen/1,
    rejects_http3_without_tls/1,
    max_clients_refuse/1,
    stream_cancel/1,
    badheaders_reset/1,
    fin_without_headers/1,
    malformed_frame/1,
    extra_data_after_413/1,
    stop_sending_ignored/1,
    drain/1
]).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        get_default,
        get_method,
        post_echo,
        empty_204,
        large_body,
        large_post,
        not_found,
        crash_500,
        unsupported_shapes_501,
        oversized_413,
        protocols_tuple_form,
        certfile_keyfile,
        quic_start_failure_releases_tcp,
        co_listen,
        rejects_http3_without_tls,
        max_clients_refuse,
        stream_cancel,
        badheaders_reset,
        fin_without_headers,
        malformed_frame,
        extra_data_after_413,
        stop_sending_ignored,
        drain
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(crypto),
    {ok, _} = application:ensure_all_started(ssl),
    %% The h3 listener starts `quic` on demand, but the client needs it
    %% too — bring it up once here for the whole suite.
    {ok, _} = application:ensure_all_started(quic),
    %% Start the default `pg` scope standalone (the drain group lives
    %% there) rather than the whole roadrunner app, so this suite
    %% coexists with others that started pg in the shared CT node.
    ok = ensure_pg_started(),
    Config.

ensure_pg_started() ->
    case whereis(pg) of
        undefined ->
            {ok, _} = pg:start_link(),
            ok;
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
    Case =:= quic_start_failure_releases_tcp;
    Case =:= co_listen;
    Case =:= rejects_http3_without_tls;
    Case =:= max_clients_refuse;
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

unsupported_shapes_501(Config) ->
    Conn = connect(?config(port, Config)),
    lists:foreach(
        fun(Path) ->
            ?assertMatch({501, _}, status_body(get(Conn, Path)))
        end,
        [~"/stream", ~"/loop", ~"/sendfile", ~"/websocket"]
    ),
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
        protocols => [http3],
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

quic_start_failure_releases_tcp(_Config) ->
    %% TCP binds but the QUIC listener can't (its UDP port is taken), so
    %% `init/1` closes the TCP socket it already opened and fails to start.
    process_flag(trap_exit, true),
    {ok, Occupier} = gen_udp:open(0, []),
    {ok, Port} = inet:port(Occupier),
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
        ?assertMatch(<<"HTTP/1.1 200", _/binary>>, iolist_to_binary(Reply)),
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

stream_cancel(Config) ->
    Conn = connect(?config(port, Config)),
    {ok, StreamId} = quic_h3:request(Conn, headers(~"POST", ~"/echo"), #{end_stream => false}),
    _ = quic_h3:cancel(Conn, StreamId),
    %% The connection survives a peer stream cancel — a fresh request works.
    ?assertEqual({200, ~"ok"}, status_body(get(Conn, ~"/"))),
    close(Conn).

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

malformed_frame(Config) ->
    %% Frame type 0x02 is reserved for HTTP/2 — a frame error that resets
    %% the stream. The connection survives for later requests.
    Conn = ll_connect(?config(port, Config)),
    _ = ll_send(Conn, <<2, 0>>, true),
    ?assertEqual({200, ~"ok"}, ll_get(Conn, ~"/")),
    ll_close(Conn).

extra_data_after_413(_Config) ->
    %% After a body exceeds the cap and the stream is answered with 413,
    %% trailing DATA on the same stream is ignored (not reprocessed).
    Name = listener_name(extra_data_after_413),
    {ok, _} = start_h3(Name, #{max_content_length => 8}),
    Conn = ll_connect(roadrunner_listener:port(Name)),
    try
        {ok, StreamId} = quic:open_stream(Conn),
        Over = quic_h3_frame:encode_data(binary:copy(<<"x">>, 32)),
        ok = quic:send_data(Conn, StreamId, Over, false),
        timer:sleep(100),
        More = quic_h3_frame:encode_data(~"more"),
        ok = quic:send_data(Conn, StreamId, More, false),
        timer:sleep(100),
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

drain(Config) ->
    Name = ?config(listener, Config),
    Conn = connect(?config(port, Config)),
    ?assertEqual({200, ~"ok"}, status_body(get(Conn, ~"/"))),
    %% Conn stays open, so drain notifies it and then times out forcing
    %% the deadline — exercises the h3 conn loop's drain branch and the
    %% listener stopping the QUIC listener.
    ?assertMatch({timeout, _}, roadrunner_listener:drain(Name, 300)),
    close(Conn).

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
            collect_body(Conn, StreamId, Status, Headers, <<Acc/binary, Data/binary>>)
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

ll_send(Conn, Bytes, Fin) ->
    {ok, StreamId} = quic:open_stream(Conn),
    ok = quic:send_data(Conn, StreamId, Bytes, Fin),
    StreamId.

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
