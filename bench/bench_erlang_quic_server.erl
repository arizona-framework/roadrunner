-module(bench_erlang_quic_server).
-moduledoc false.

%% Bench-only: stands up the `quic` dependency's turnkey HTTP/3 server as the
%% `erlang_quic` comparison target for roadrunner's native h3 server. Compiled
%% only under the `bench` rebar3 profile (the dep is bench-profile-only), so it
%% never touches the dep-free `test` profile.
%%
%% It serves the bench's protocol-agnostic GET-side scenarios (hello, json,
%% large_response, headers_heavy, head_method, cookies_heavy) with the same
%% response shape roadrunner's fixtures produce, so the loadgen's status check
%% passes identically for both servers under the same client. The POST-body
%% scenarios (echo, multi_request_body) are not covered: the dep delivers
%% request bodies only through a late `set_stream_handler`, which races body
%% arrival against the spawned handler.

-export([start/2]).

%% The dep registers a server under a name; we read the bound port back from it.
-define(SERVER_NAME, bench_erlang_quic_h3).

%% Start the dep h3 server for `Scenario` on an ephemeral UDP port, reading the
%% PEM cert/key the bench generated under `CertDir`. Returns the bound port.
-spec start(file:filename(), atom()) -> {ok, inet:port_number()} | {error, term()}.
start(CertDir, Scenario) ->
    {ok, _} = application:ensure_all_started(quic),
    {Cert, Key} = load_keypair(CertDir),
    Handler = handler(Scenario),
    {ok, _Pid} = quic_h3:start_server(?SERVER_NAME, 0, #{
        cert => Cert,
        key => Key,
        handler => Handler
    }),
    quic:get_server_port(?SERVER_NAME).

%% The leaf cert as DER and the private key as the decoded term the dep wants
%% (mirrors the dep's own `quic_h3_server` PEM loading).
-spec load_keypair(file:filename()) -> {binary(), term()}.
load_keypair(CertDir) ->
    {ok, CertPem} = file:read_file(filename:join(CertDir, "cert.pem")),
    [{_CertType, CertDer, _} | _] = public_key:pem_decode(CertPem),
    {ok, KeyPem} = file:read_file(filename:join(CertDir, "key.pem")),
    [{KeyType, KeyDer, _} | _] = public_key:pem_decode(KeyPem),
    {CertDer, public_key:der_decode(KeyType, KeyDer)}.

%% A per-scenario handler fun (RFC 9114 request callback shape the dep expects:
%% `fun(Conn, StreamId, Method, Path, Headers)`). Each clause mirrors the
%% response of the matching roadrunner bench fixture so the work the dep does is
%% the same the loadgen drives against roadrunner. `hello` and `headers_heavy`
%% answer every request with 200 + `alive\r\n` (7 bytes), the same as
%% roadrunner's keepalive fixture.
-spec handler(atom()) -> fun().
handler(hello) ->
    Body = ~"alive\r\n",
    fun(Conn, StreamId, _Method, _Path, _Headers) ->
        ok = quic_h3:send_response(Conn, StreamId, 200, [{~"content-type", ~"text/plain"}]),
        ok = quic_h3:send_data(Conn, StreamId, Body, true)
    end;
handler(headers_heavy) ->
    handler(hello);
%% `large_response` answers every request with a 64 KB octet-stream body, the
%% same shape as roadrunner_bench_large_handler; the body is built once here and
%% captured, so the per-request cost is response framing + send, not body build.
handler(large_response) ->
    Body = binary:copy(~"x", 65536),
    Headers = [
        {~"content-type", ~"application/octet-stream"},
        {~"content-length", integer_to_binary(byte_size(Body))}
    ],
    fun(Conn, StreamId, _Method, _Path, _Headers) ->
        ok = quic_h3:send_response(Conn, StreamId, 200, Headers),
        ok = quic_h3:send_data(Conn, StreamId, Body, true)
    end;
%% `json` answers with the same fixed ~115-byte object roadrunner_bench_json_handler
%% returns, so both servers frame an identical small response.
handler(json) ->
    Body =
        ~"""
        {"id":"01J8X9Z3K7QFRBQ4PCVE5K8RNH","status":"ok","data":{"name":"roadrunner","version":2,"flags":["alpha","beta"]}}
        """,
    Headers = [
        {~"content-type", ~"application/json"},
        {~"content-length", integer_to_binary(byte_size(Body))}
    ],
    fun(Conn, StreamId, _Method, _Path, _Headers) ->
        ok = quic_h3:send_response(Conn, StreamId, 200, Headers),
        ok = quic_h3:send_data(Conn, StreamId, Body, true)
    end;
%% `head_method` is a HEAD against the same /large resource: 200 with the 64 KB
%% `content-length` advertised but an empty body, mirroring roadrunner stripping
%% the body on HEAD while keeping the headers.
handler(head_method) ->
    Headers = [
        {~"content-type", ~"application/octet-stream"},
        {~"content-length", integer_to_binary(65536)}
    ],
    fun(Conn, StreamId, _Method, _Path, _Headers) ->
        ok = quic_h3:send_response(Conn, StreamId, 200, Headers),
        ok = quic_h3:send_data(Conn, StreamId, <<>>, true)
    end;
%% `cookies_heavy` parses the request's Cookie header the way
%% roadrunner_req:parse_cookies/1 does (`; `-separated pairs) and answers with
%% the pair count, so the dep does the same parse work per request.
handler(cookies_heavy) ->
    fun(Conn, StreamId, _Method, _Path, Headers) ->
        Body = integer_to_binary(count_cookies(Headers)),
        ok = quic_h3:send_response(Conn, StreamId, 200, [
            {~"content-type", ~"text/plain"},
            {~"content-length", integer_to_binary(byte_size(Body))}
        ]),
        ok = quic_h3:send_data(Conn, StreamId, Body, true)
    end.

%% Count the `; `-separated pairs in the request's Cookie header, matching
%% roadrunner_req:parse_cookies/1 so the per-request work compares like for like.
-spec count_cookies(list()) -> non_neg_integer().
count_cookies(Headers) ->
    case lists:keyfind(~"cookie", 1, Headers) of
        {_, Value} -> length(binary:split(Value, ~"; ", [global]));
        false -> 0
    end.
