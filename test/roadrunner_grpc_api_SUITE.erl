-module(roadrunner_grpc_api_SUITE).
-moduledoc """
What a gRPC method and the middlewares in front of it reach beyond the
stream: the call's HTTP request, over HTTP/2 with TLS and a client
certificate, and middlewares that `roadrunner_grpc:routes/1` puts on
every route, which answer a call with a gRPC status, and long streams
past the listener's body cap, over HTTP/2 and HTTP/3.
""".

-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_testcase/2, end_per_testcase/2]).
-export([
    request_tells_what_the_metadata_leaves_out/1,
    middleware_rejects_with_a_status/1,
    middleware_lets_a_call_through/1,
    middleware_guards_the_health_service/1,
    stream_runs_past_the_listener_cap/1,
    http3_stream_runs_past_the_listener_cap/1,
    auto_keeps_the_listener_cap/1
]).

-define(SVC, ~"/test.Echo/").

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        request_tells_what_the_metadata_leaves_out,
        middleware_rejects_with_a_status,
        middleware_lets_a_call_through,
        middleware_guards_the_health_service,
        stream_runs_past_the_listener_cap,
        http3_stream_runs_past_the_listener_cap,
        auto_keeps_the_listener_cap
    ].

init_per_testcase(request_tells_what_the_metadata_leaves_out, Config) ->
    start(Config, tls, #{
        middlewares => [
            fun(Req, Next, _State) ->
                Next(roadrunner_req:put_private(roadrunner_grpc_test, ~"from a middleware", Req))
            end
        ],
        routes => roadrunner_grpc:routes(#{services => [roadrunner_grpc_test_service]})
    });
init_per_testcase(stream_runs_past_the_listener_cap, Config) ->
    start(Config, tcp, capped(manual));
init_per_testcase(http3_stream_runs_past_the_listener_cap, Config) ->
    start(Config, tls, (capped(manual))#{protocols => [http3]});
init_per_testcase(auto_keeps_the_listener_cap, Config) ->
    start(Config, tcp, capped(auto));
init_per_testcase(_Case, Config) ->
    start(Config, tcp, #{
        routes => roadrunner_grpc:routes(#{
            services => [roadrunner_grpc_test_service],
            health => true,
            middlewares => [{fun api_key/3, ~"secret"}]
        })
    }).

%% A listener whose body cap is small, with routes that keep the default
%% `max_content_length`.
capped(Mode) ->
    #{
        body_buffering => Mode,
        max_content_length => 50_000,
        routes => roadrunner_grpc:routes(#{services => [roadrunner_grpc_test_service]})
    }.

%% A middleware that lets a call with the right `x-api-key` through and
%% rejects the others `UNAUTHENTICATED`.
api_key(Req, Next, Key) ->
    case roadrunner_req:header(~"x-api-key", Req) of
        Key -> Next(Req);
        _ -> roadrunner_grpc:reject(unauthenticated, ~"bad api key: café", Req)
    end.

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

%% The call is answered Trailers-Only, with the status and its message,
%% and the method never runs.
middleware_rejects_with_a_status(Config) ->
    {Headers, [], trailers_only, _} = call(Config, ~"Unary", [], [~"x"]),
    ?assertEqual(~"200", header(~":status", Headers)),
    ?assertEqual(~"application/grpc", header(~"content-type", Headers)),
    ?assertEqual(~"16", header(~"grpc-status", Headers)),
    ?assertEqual(
        ~"bad api key: café",
        roadrunner_grpc_status:decode_message(header(~"grpc-message", Headers))
    ).

middleware_lets_a_call_through(Config) ->
    {_, [~"x"], Trailers, _} = call(Config, ~"Unary", [{~"x-api-key", ~"secret"}], [~"x"]),
    ?assertEqual(~"0", header(~"grpc-status", Trailers)).

%% The health service's route carries the middlewares too.
middleware_guards_the_health_service(Config) ->
    {Headers, [], trailers_only, _} = roadrunner_grpc_test_client:call(
        open(Config), 1, ~"/grpc.health.v1.Health/Check", [], [<<>>]
    ),
    ?assertEqual(~"16", header(~"grpc-status", Headers)),
    {_, [_], Trailers, _} = roadrunner_grpc_test_client:call(
        open(Config), 1, ~"/grpc.health.v1.Health/Check", [{~"x-api-key", ~"secret"}], [<<>>]
    ),
    ?assertEqual(~"0", header(~"grpc-status", Trailers)).

%% A bidi stream carries 300 KB over its life past a listener capped at
%% 50 KB: a gRPC route has no total by default.
stream_runs_past_the_listener_cap(Config) ->
    Parts = [binary:copy(<<I>>, 10_000) || I <- lists:seq(1, 30)],
    {_, Echoed, Trailers, _} = call(Config, ~"Chat", [], Parts),
    ?assertEqual(Parts, Echoed),
    ?assertEqual(~"0", header(~"grpc-status", Trailers)).

http3_stream_runs_past_the_listener_cap(Config) ->
    Parts = [binary:copy(<<I>>, 10_000) || I <- lists:seq(1, 30)],
    {ok, Conn} = roadrunner_quic_test_h3:connect({127, 0, 0, 1}, ?config(port, Config)),
    {ok, StreamId} = roadrunner_quic_test_h3:open_request(
        Conn,
        [
            {~":method", ~"POST"},
            {~":scheme", ~"https"},
            {~":authority", ~"localhost"},
            {~":path", <<?SVC/binary, "Chat">>},
            {~"content-type", ~"application/grpc"},
            {~"te", ~"trailers"}
        ],
        false
    ),
    ok = roadrunner_quic_test_h3:send_data(
        Conn,
        StreamId,
        iolist_to_binary([roadrunner_grpc_frame:encode(false, P) || P <- Parts]),
        true
    ),
    {[_, Trailers], Body} = roadrunner_quic_test_h3:collect_all(Conn, StreamId),
    ?assertEqual(Parts, roadrunner_grpc_test_client:messages(Body)),
    ?assertEqual(~"0", header(~"grpc-status", Trailers)),
    _ = roadrunner_quic_test_h3:close(Conn),
    ok.

%% With `auto` the body is read whole before the call, so it keeps the
%% listener's cap: 80 KB is answered 413.
auto_keeps_the_listener_cap(Config) ->
    Part = binary:copy(~"x", 20_000),
    {Headers, _, _, _} = call(Config, ~"Sum", [], [Part, Part, Part, Part]),
    ?assertEqual(~"413", header(~":status", Headers)).

%% --- helpers ---

open(Config) ->
    roadrunner_grpc_test_client:open(?config(port, Config)).

call(Config, Method, Extra, Messages) ->
    roadrunner_grpc_test_client:call(
        open(Config), 1, <<?SVC/binary, Method/binary>>, Extra, Messages
    ).

start(Config, Transport, Opts) ->
    %% The health service's store runs under the application.
    {ok, _} = application:ensure_all_started(roadrunner),
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
