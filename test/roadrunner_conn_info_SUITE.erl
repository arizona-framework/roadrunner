-module(roadrunner_conn_info_SUITE).
-moduledoc """
`roadrunner_req:sockname/1`, `peercert/1` and `tls_info/1` over HTTP/1.1
(plain and TLS, with and without a client certificate), HTTP/2 (h2c) and
HTTP/3. The handler is `roadrunner_conn_info_handler`, which answers with
what the three return.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([
    plain_http1/1,
    tls_http1_without_client_cert/1,
    tls_http1_with_client_cert/1,
    plain_http2/1,
    http3/1,
    http3_aes_256_gcm/1
]).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        plain_http1,
        tls_http1_without_client_cert,
        tls_http1_with_client_cert,
        plain_http2,
        http3,
        http3_aes_256_gcm
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(crypto),
    {ok, _} = application:ensure_all_started(ssl),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(Case, Config) ->
    {ok, _} = roadrunner_listener:start_link(
        ?MODULE, maps:merge(#{port => 0, routes => roadrunner_conn_info_handler}, opts(Case))
    ),
    [{port, roadrunner_listener:port(?MODULE)} | Config].

end_per_testcase(_Case, _Config) ->
    ok = roadrunner_listener:stop(?MODULE).

opts(plain_http1) ->
    #{};
opts(tls_http1_without_client_cert) ->
    #{tls => roadrunner_test_certs:server_opts()};
opts(tls_http1_with_client_cert) ->
    #{tls => [{verify, verify_peer} | roadrunner_test_certs:server_opts()]};
opts(plain_http2) ->
    #{protocols => [http2]};
opts(Case) when Case =:= http3; Case =:= http3_aes_256_gcm ->
    #{protocols => [http3], tls => roadrunner_test_certs:server_opts()}.

plain_http1(Config) ->
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, port(Config), [binary, {active, false}]),
    ok = gen_tcp:send(Sock, request()),
    Info = h1_info(recv_all(fun(T) -> gen_tcp:recv(Sock, 0, T) end)),
    ?assertEqual({ok, {{127, 0, 0, 1}, port(Config)}}, maps:get(sockname, Info)),
    ?assertEqual({error, not_tls}, maps:get(peercert, Info)),
    ?assertEqual({error, not_tls}, maps:get(tls_info, Info)).

tls_http1_without_client_cert(Config) ->
    Info = tls_info_with(Config, []),
    ?assertEqual({ok, {{127, 0, 0, 1}, port(Config)}}, maps:get(sockname, Info)),
    ?assertEqual({error, no_peercert}, maps:get(peercert, Info)),
    {ok, Tls} = maps:get(tls_info, Info),
    ?assertMatch(#{protocol := _, selected_cipher_suite := #{cipher := _}}, Tls).

tls_http1_with_client_cert(Config) ->
    %% The listener asks for a certificate (`verify_peer`); the one the
    %% client presents comes back as DER.
    ClientOpts = roadrunner_test_certs:client_opts(),
    {cert, ClientCert} = lists:keyfind(cert, 1, ClientOpts),
    Info = tls_info_with(Config, ClientOpts),
    ?assertEqual({ok, ClientCert}, maps:get(peercert, Info)).

plain_http2(Config) ->
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, port(Config), [binary, {active, false}]),
    {Block, _} = roadrunner_http2_hpack:encode(
        [{~":method", ~"GET"}, {~":scheme", ~"http"}, {~":authority", ~"x"}, {~":path", ~"/"}],
        roadrunner_http2_hpack:new_encoder(4096)
    ),
    ok = gen_tcp:send(Sock, [
        ~"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n",
        roadrunner_http2_frame:encode({settings, 0, []}),
        roadrunner_http2_frame:encode({headers, 1, 16#05, undefined, Block})
    ]),
    Info = binary_to_term(h2_body(Sock, <<>>, <<>>)),
    ?assertEqual({ok, {{127, 0, 0, 1}, port(Config)}}, maps:get(sockname, Info)),
    ?assertEqual({error, not_tls}, maps:get(tls_info, Info)).

http3(Config) ->
    Info = h3_info(Config, #{}),
    {ok, {_Ip, Port}} = maps:get(sockname, Info),
    ?assertEqual(port(Config), Port),
    ?assertEqual({error, no_peercert}, maps:get(peercert, Info)),
    ?assertEqual(
        {ok, #{
            protocol => 'tlsv1.3',
            selected_cipher_suite => #{
                cipher => aes_128_gcm, mac => aead, prf => sha256, key_exchange => any
            }
        }},
        maps:get(tls_info, Info)
    ).

%% A SHA-384 suite reports its hash as the PRF (RFC 8446 §B.4).
http3_aes_256_gcm(Config) ->
    Info = h3_info(Config, #{cipher_suites => [16#1302]}),
    ?assertMatch(
        {ok, #{selected_cipher_suite := #{cipher := aes_256_gcm, prf := sha384}}},
        maps:get(tls_info, Info)
    ).

h3_info(Config, Opts) ->
    {ok, Conn} = roadrunner_quic_test_h3:connect({127, 0, 0, 1}, port(Config), Opts),
    try
        {200, _, Body} = roadrunner_quic_test_h3:request(
            Conn,
            [
                {~":method", ~"GET"},
                {~":scheme", ~"https"},
                {~":authority", ~"localhost"},
                {~":path", ~"/"}
            ],
            <<>>
        ),
        binary_to_term(Body)
    after
        roadrunner_quic_test_h3:close(Conn)
    end.

%% =============================================================================
%% Helpers
%% =============================================================================

port(Config) ->
    ?config(port, Config).

request() ->
    ~"GET / HTTP/1.1\r\nhost: x\r\nconnection: close\r\n\r\n".

tls_info_with(Config, ClientOpts) ->
    Opts = [
        binary, {active, false}, {verify, verify_none} | lists:keydelete(verify, 1, ClientOpts)
    ],
    {ok, Sock} = ssl:connect({127, 0, 0, 1}, port(Config), Opts, 5000),
    ok = ssl:send(Sock, request()),
    h1_info(recv_all(fun(T) -> ssl:recv(Sock, 0, T) end)).

recv_all(Recv) ->
    recv_all(Recv, <<>>).

recv_all(Recv, Acc) ->
    case Recv(5000) of
        {ok, Data} -> recv_all(Recv, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc
    end.

h1_info(Response) ->
    [<<"HTTP/1.1 200", _/binary>>, Body] = binary:split(Response, ~"\r\n\r\n"),
    binary_to_term(Body).

%% The DATA of stream 1 until END_STREAM.
h2_body(Sock, Buf, Body) ->
    case roadrunner_http2_frame:parse(Buf, 16384) of
        {ok, {data, 1, Flags, Data, _}, _Rest} when Flags band 16#01 =/= 0 ->
            <<Body/binary, Data/binary>>;
        {ok, {data, 1, _Flags, Data, _}, Rest} ->
            h2_body(Sock, Rest, <<Body/binary, Data/binary>>);
        {ok, _Frame, Rest} ->
            h2_body(Sock, Rest, Body);
        _More ->
            {ok, More} = gen_tcp:recv(Sock, 0, 5000),
            h2_body(Sock, <<Buf/binary, More/binary>>, Body)
    end.
