-module(bench_erlang_quic_server).
-moduledoc false.

%% Bench-only: stands up the `quic` dependency's turnkey HTTP/3 server as the
%% `erlang_quic` comparison target for roadrunner's native h3 server. Compiled
%% only under the `bench` rebar3 profile (the dep is bench-profile-only), so it
%% never touches the dep-free `test` profile.
%%
%% It serves the bench's `hello` scenario response: 200 + a 7-byte body,
%% matching `roadrunner_keepalive_handler` so the loadgen's status + body-length
%% checks pass identically for both servers under the same client.

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

%% A handler fun (RFC 9114 request callback shape the dep expects:
%% `fun(Conn, StreamId, Method, Path, Headers)`). The `hello` scenario answers
%% every request with 200 + `alive\r\n` (7 bytes), the same as roadrunner's
%% keepalive fixture.
-spec handler(atom()) -> fun().
handler(hello) ->
    Body = ~"alive\r\n",
    fun(Conn, StreamId, _Method, _Path, _Headers) ->
        ok = quic_h3:send_response(Conn, StreamId, 200, [{~"content-type", ~"text/plain"}]),
        ok = quic_h3:send_data(Conn, StreamId, Body, true)
    end.
