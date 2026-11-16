-module(roadrunner_grpc_api_SUITE).
-moduledoc """
What a gRPC method and the middlewares in front of it reach beyond the
stream: the call's HTTP request, over HTTP/2 with TLS and a client
certificate.
""".

-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_testcase/2, end_per_testcase/2]).
-export([request_tells_what_the_metadata_leaves_out/1]).

-define(SVC, ~"/test.Echo/").

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [request_tells_what_the_metadata_leaves_out].

init_per_testcase(request_tells_what_the_metadata_leaves_out, Config) ->
    start(Config, tls, #{
        middlewares => [
            fun(Req, Next, _State) ->
                Next(roadrunner_req:put_private(roadrunner_grpc_test, ~"from a middleware", Req))
            end
        ],
        routes => roadrunner_grpc:routes(#{services => [roadrunner_grpc_test_service]})
    }).

end_per_testcase(_Case, _Config) ->
    ok = roadrunner_listener:stop(?MODULE).

%% The listener asks for a certificate (`verify_peer`); the method reads
%% the one the client presents, a middleware's value, the request id and
%% a `grpc-*` header from the request.
request_tells_what_the_metadata_leaves_out(Config) ->
    ClientOpts = roadrunner_test_certs:client_opts(),
    {cert, ClientCert} = lists:keyfind(cert, 1, ClientOpts),
    C = roadrunner_grpc_test_client:open_tls(?config(port, Config), ClientOpts),
    {_, [Reply], Trailers, _} = roadrunner_grpc_test_client:call(
        C, 1, <<?SVC/binary, "Request">>, [{~"grpc-timeout", ~"5S"}, {~"x-a", ~"b"}], [~"x"]
    ),
    ?assertEqual(~"0", header(~"grpc-status", Trailers)),
    #{
        peercert := Peercert,
        private := Private,
        request_id := RequestId,
        timeout := Timeout,
        metadata := Metadata
    } = binary_to_term(Reply),
    ?assertEqual({ok, ClientCert}, Peercert),
    ?assertEqual(~"from a middleware", Private),
    ?assert(is_binary(RequestId)),
    ?assertEqual(~"5S", Timeout),
    ?assertEqual([{~"x-a", ~"b"}], Metadata).

%% --- helpers ---

start(Config, Transport, Opts) ->
    Defaults = #{port => 0, protocols => [http2], body_buffering => manual},
    {ok, _} = roadrunner_listener:start_link(
        ?MODULE, maps:merge(maps:merge(Defaults, transport(Transport)), Opts)
    ),
    [{port, roadrunner_listener:port(?MODULE)} | Config].

transport(tls) ->
    #{tls => [{verify, verify_peer} | roadrunner_test_certs:server_opts()]};
transport(tcp) ->
    #{}.

header(Name, Fields) ->
    proplists:get_value(Name, Fields).
