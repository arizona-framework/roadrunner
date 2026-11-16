-module(roadrunner_h2c_shared_port_SUITE).
-moduledoc """
HTTP/1.1 and prior-knowledge HTTP/2 on one plain-TCP port
(`protocols => [http1, http2]`): each connection is HTTP/2 when it opens
with the connection preface (RFC 9113 §3.4) and HTTP/1.1 otherwise.
Runs against both orders of the list, then checks that `[http1]` and
`[http2]` listeners keep to their one protocol.
""".

-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_group/2, end_per_group/2, init_per_testcase/2, end_per_testcase/2]).
-export([forward/4]).
-export([
    h1_keep_alive/1,
    h1_methods_starting_with_p/1,
    h1_pri_method/1,
    h1_split_after_p/1,
    h1_upgrade_h2c_is_ignored/1,
    h1_active_n/1,
    h2_grpc_call/1,
    h2_preface_byte_by_byte/1,
    garbage_is_h1/1,
    preface_lookalike_is_h1/1,
    timeout_before_any_byte/1,
    timeout_inside_the_preface/1,
    peer_close_before_any_byte/1,
    transport_error_before_any_byte/1,
    drain_before_any_byte/1,
    stray_message_before_any_byte/1,
    hibernates_then_serves/1,
    hibernates_then_times_out/1,
    h1_only_listener_answers_the_preface_in_h1/1,
    h2_only_listener_refuses_h1/1,
    h2_only_listener_calls/1
]).

-define(PREFACE, ~"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n").
-define(UNARY, ~"/test.Echo/Unary").

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        {group, h1_first},
        {group, h2_first},
        h1_only_listener_answers_the_preface_in_h1,
        h2_only_listener_refuses_h1,
        h2_only_listener_calls
    ].

groups() ->
    Shared = [
        h1_keep_alive,
        h1_methods_starting_with_p,
        h1_pri_method,
        h1_split_after_p,
        h1_upgrade_h2c_is_ignored,
        h1_active_n,
        h2_grpc_call,
        h2_preface_byte_by_byte,
        garbage_is_h1,
        preface_lookalike_is_h1,
        timeout_before_any_byte,
        timeout_inside_the_preface,
        peer_close_before_any_byte,
        transport_error_before_any_byte,
        drain_before_any_byte,
        stray_message_before_any_byte,
        hibernates_then_serves,
        hibernates_then_times_out
    ],
    [{h1_first, [], Shared}, {h2_first, [], Shared}].

init_per_suite(Config) ->
    {ok, _} = roadrunner_test_event_handler:start(),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(h1_first, Config) ->
    [{protocols, [http1, http2]} | Config];
init_per_group(h2_first, Config) ->
    [{protocols, [http2, http1]} | Config].

end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(Case, Config) ->
    Protocols =
        case Case of
            h1_only_listener_answers_the_preface_in_h1 -> [http1];
            h2_only_listener_refuses_h1 -> [http2];
            h2_only_listener_calls -> [http2];
            h1_active_n -> [active_n(P) || P <- ?config(protocols, Config)];
            _ -> ?config(protocols, Config)
        end,
    Opts = maps:merge(
        #{
            port => 0,
            protocols => Protocols,
            routes => [
                {~"/ka", roadrunner_keepalive_handler, undefined}
                | roadrunner_grpc:routes(#{services => [roadrunner_grpc_test_service]})
            ]
        },
        opts(Case)
    ),
    {ok, _} = roadrunner_listener:start_link(?MODULE, Opts),
    %% Every connection reports its process and how it closed, from the
    %% connection process itself.
    ok = telemetry:attach_many(
        ?MODULE,
        [[roadrunner, listener, accept], [roadrunner, listener, conn_close]],
        fun ?MODULE:forward/4,
        self()
    ),
    [{port, roadrunner_listener:port(?MODULE)} | Config].

end_per_testcase(_Case, _Config) ->
    ok = telemetry:detach(?MODULE),
    ok = roadrunner_listener:stop(?MODULE).

opts(Case) when Case =:= timeout_before_any_byte; Case =:= timeout_inside_the_preface ->
    #{request_timeout => 200};
opts(hibernates_then_serves) ->
    #{hibernate_after => 50};
opts(hibernates_then_times_out) ->
    #{hibernate_after => 50, request_timeout => 300};
opts(_Case) ->
    #{}.

active_n(http1) -> {http1, #{active => 2}};
active_n(Protocol) -> Protocol.

forward(Event, _Measurements, Metadata, Pid) ->
    Pid ! {Event, self(), Metadata},
    ok.

%% =============================================================================
%% Shared port
%% =============================================================================

%% A plain HTTP/1.1 connection, kept alive past the first request.
h1_keep_alive(Config) ->
    Sock = connect(Config),
    ?assertEqual({200, ~"alive\r\n"}, request(Sock, ~"GET")),
    ?assertEqual({200, ~"alive\r\n"}, request(Sock, ~"GET")),
    ok = gen_tcp:close(Sock),
    ?assertMatch(#{requests_served := 2, reason := peer_closed}, conn_close()).

%% `POST`, `PUT` and `PATCH` share the preface's first byte and leave it at
%% the second.
h1_methods_starting_with_p(Config) ->
    lists:foreach(
        fun(Method) ->
            Sock = connect(Config),
            ?assertEqual({200, ~"alive\r\n"}, request(Sock, Method)),
            ?assertEqual({200, ~"alive\r\n"}, request(Sock, ~"GET")),
            ok = gen_tcp:close(Sock)
        end,
        [~"POST", ~"PUT", ~"PATCH"]
    ).

%% Even the `PRI` method is HTTP/1.1 when the rest is not the preface.
h1_pri_method(Config) ->
    Sock = connect(Config),
    ?assertEqual({200, ~"alive\r\n"}, request(Sock, ~"PRI")),
    ok = gen_tcp:close(Sock).

%% A request whose first byte comes alone, then the rest in two pieces.
h1_split_after_p(Config) ->
    Sock = connect(Config),
    Conn = accepted(),
    1 = erlang:trace(Conn, true, ['receive']),
    ok = gen_tcp:send(Sock, ~"P"),
    ok = await_bytes(Conn, ~"P"),
    ok = gen_tcp:send(Sock, ~"OST /ka HTTP/1.1\r\n"),
    ok = await_bytes(Conn, ~"OST /ka HTTP/1.1\r\n"),
    _ = erlang:trace(Conn, false, ['receive']),
    ok = gen_tcp:send(Sock, ~"Host: x\r\nContent-Length: 0\r\n\r\n"),
    ?assertEqual({200, ~"alive\r\n"}, response(Sock)),
    ok = gen_tcp:close(Sock).

%% `Upgrade: h2c` is not offered: the request is served as HTTP/1.1.
h1_upgrade_h2c_is_ignored(Config) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, [
        ~"GET /ka HTTP/1.1\r\nHost: x\r\nConnection: Upgrade, HTTP2-Settings\r\n",
        ~"Upgrade: h2c\r\nHTTP2-Settings: AAMAAABkAAQAAP__\r\n\r\n"
    ]),
    ?assertEqual({200, ~"alive\r\n"}, response(Sock)),
    ?assertEqual({200, ~"alive\r\n"}, request(Sock, ~"GET")),
    ok = gen_tcp:close(Sock).

%% An `{active, N}` HTTP/1.1 connection arms its count once told apart, and
%% re-arms it as before.
h1_active_n(Config) ->
    Sock = connect(Config),
    Conn = accepted(),
    1 = erlang:trace(Conn, true, ['receive']),
    ok = gen_tcp:send(Sock, ~"P"),
    ok = await_bytes(Conn, ~"P"),
    _ = erlang:trace(Conn, false, ['receive']),
    ok = gen_tcp:send(Sock, ~"UT /ka HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n"),
    ?assertEqual({200, ~"alive\r\n"}, response(Sock)),
    lists:foreach(
        fun(_) -> ?assertEqual({200, ~"alive\r\n"}, request(Sock, ~"GET")) end,
        lists:seq(1, 4)
    ),
    ok = gen_tcp:close(Sock).

%% A prior-knowledge HTTP/2 connection: a gRPC call, then a plain request
%% on the same connection.
h2_grpc_call(Config) ->
    C0 = roadrunner_grpc_test_client:open(?config(port, Config)),
    ok = h2_calls(C0).

%% The preface one byte per read, then the rest of the connection.
h2_preface_byte_by_byte(Config) ->
    Sock = connect(Config),
    Conn = accepted(),
    1 = erlang:trace(Conn, true, ['receive']),
    lists:foreach(
        fun(Byte) ->
            ok = gen_tcp:send(Sock, <<Byte>>),
            ok = await_bytes(Conn, <<Byte>>)
        end,
        binary_to_list(?PREFACE)
    ),
    _ = erlang:trace(Conn, false, ['receive']),
    ok = h2_calls(roadrunner_grpc_test_client:after_preface(Sock, [])).

%% Bytes that leave the preface at once and are no request: a 400.
garbage_is_h1(Config) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, ~"\x00\x01\r\n\r\n"),
    ?assertMatch({400, _}, response(Sock)),
    ?assertEqual({error, closed}, gen_tcp:recv(Sock, 0, 5000)).

%% 24 bytes that start like the preface and leave it near the end go to
%% HTTP/1.1, which turns the `HTTP/2.0` request line down.
preface_lookalike_is_h1(Config) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, ~"PRI * HTTP/2.0\r\n\r\nXX\r\n\r\n"),
    {Status, _} = response(Sock),
    ?assert(Status >= 400),
    ?assertEqual({error, closed}, gen_tcp:recv(Sock, 0, 5000)).

%% A client that sends nothing gets the 408 of a first request.
timeout_before_any_byte(Config) ->
    Sock = connect(Config),
    ?assertMatch({408, _}, response(Sock)),
    ?assertMatch(#{reason := request_timeout}, conn_close()).

%% A client that stops part way into the preface does too.
timeout_inside_the_preface(Config) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, ~"PRI * HTTP/2.0\r\n"),
    ?assertMatch({408, _}, response(Sock)),
    ?assertMatch(#{reason := request_timeout}, conn_close()).

peer_close_before_any_byte(Config) ->
    Sock = connect(Config),
    _ = accepted(),
    ok = gen_tcp:close(Sock),
    ?assertMatch(#{requests_served := 0, reason := peer_closed}, conn_close()).

transport_error_before_any_byte(Config) ->
    Sock = connect(Config),
    Conn = accepted(),
    Conn ! {tcp_error, Sock, econnreset},
    ?assertMatch(#{reason := {transport, econnreset}}, conn_close()),
    ok = gen_tcp:close(Sock).

drain_before_any_byte(Config) ->
    Sock = connect(Config),
    _ = accepted(),
    ok = roadrunner_listener:notify_drain(?MODULE, erlang:monotonic_time(millisecond) + 5000),
    ?assertMatch(#{reason := drained}, conn_close()),
    ?assertEqual({error, closed}, gen_tcp:recv(Sock, 0, 5000)).

stray_message_before_any_byte(Config) ->
    Sock = connect(Config),
    Conn = accepted(),
    Conn ! stray,
    ?assertEqual({200, ~"alive\r\n"}, request(Sock, ~"GET")),
    ok = gen_tcp:close(Sock).

%% With `hibernate_after`, a connection waiting for its first bytes
%% hibernates, and wakes to serve them.
hibernates_then_serves(Config) ->
    Sock = connect(Config),
    Conn = accepted(),
    ok = await_hibernate(Conn),
    ?assertEqual({200, ~"alive\r\n"}, request(Sock, ~"GET")),
    ok = gen_tcp:close(Sock).

%% ... and wakes at the deadline to time out.
hibernates_then_times_out(Config) ->
    Sock = connect(Config),
    Conn = accepted(),
    ok = await_hibernate(Conn),
    ?assertMatch({408, _}, response(Sock)),
    ?assertMatch(#{reason := request_timeout}, conn_close()).

%% =============================================================================
%% One protocol per listener, as before
%% =============================================================================

%% `[http1]` reads the preface as an HTTP/1.1 request and turns it down.
h1_only_listener_answers_the_preface_in_h1(Config) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, ?PREFACE),
    {Status, _} = response(Sock),
    ?assert(Status >= 400),
    Sock2 = connect(Config),
    ?assertEqual({200, ~"alive\r\n"}, request(Sock2, ~"GET")),
    ok = gen_tcp:close(Sock2).

%% `[http2]` speaks HTTP/2 from its first byte: an HTTP/1.1 request gets the
%% server's SETTINGS frame, then a close.
h2_only_listener_refuses_h1(Config) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, ~"GET /ka HTTP/1.1\r\nHost: x\r\n\r\n"),
    Bytes = recv_until_closed(Sock, <<>>),
    ?assertMatch({ok, {settings, 0, _}, _}, roadrunner_http2_frame:parse(Bytes, 16384)),
    ?assertMatch(#{reason := {protocol_error, protocol_error}}, conn_close()).

h2_only_listener_calls(Config) ->
    ok = h2_calls(roadrunner_grpc_test_client:open(?config(port, Config))).

%% =============================================================================
%% Helpers
%% =============================================================================

h2_calls(C0) ->
    {Headers, [~"hi"], Trailers, C1} = roadrunner_grpc_test_client:call(C0, 1, ?UNARY, [~"hi"]),
    ?assertEqual(~"200", header(~":status", Headers)),
    ?assertEqual(~"0", header(~"grpc-status", Trailers)),
    C2 = roadrunner_grpc_test_client:start(C1, 3, ~"/ka", [{~":method", ~"GET"}]),
    {Headers2, {body, Body}, no_trailers, _} = roadrunner_grpc_test_client:response(
        roadrunner_grpc_test_client:finish(C2, 3), 3
    ),
    ?assertEqual(~"200", header(~":status", Headers2)),
    ?assertEqual(~"alive\r\n", Body),
    ok.

header(Name, Fields) ->
    proplists:get_value(Name, Fields).

connect(Config) ->
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, ?config(port, Config), [binary, {active, false}, {nodelay, true}], 5000
    ),
    Sock.

%% The process of the connection just accepted.
accepted() ->
    receive
        {[roadrunner, listener, accept], Conn, _} -> Conn
    after 5000 -> ct:fail(not_accepted)
    end.

%% How the connection closed.
conn_close() ->
    receive
        {[roadrunner, listener, conn_close], _Conn, Metadata} -> Metadata
    after 5000 -> ct:fail(no_conn_close)
    end.

%% Wait until the traced connection has taken `Bytes` off its socket.
await_bytes(Conn, Bytes) ->
    receive
        {trace, Conn, 'receive', {tcp, _, Bytes}} -> ok
    after 5000 -> ct:fail({not_received, Bytes})
    end.

await_hibernate(Conn) ->
    1 = erlang:trace(Conn, true, [running]),
    receive
        {trace, Conn, out, {erlang, hibernate, 3}} -> ok
    after 5000 -> ct:fail(not_hibernated)
    end,
    _ = erlang:trace(Conn, false, [running]),
    ok.

request(Sock, Method) ->
    ok = gen_tcp:send(Sock, [Method, ~" /ka HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n"]),
    response(Sock).

%% `{Status, Body}` of one response with a `Content-Length` (or none).
response(Sock) ->
    response(Sock, <<>>).

response(Sock, Acc) ->
    case binary:split(Acc, ~"\r\n\r\n") of
        [Head, Rest] ->
            <<"HTTP/1.1 ", Code:3/binary, _/binary>> = Head,
            {binary_to_integer(Code), body(Sock, Rest, content_length(Head))};
        [_] ->
            {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
            response(Sock, <<Acc/binary, Data/binary>>)
    end.

body(_Sock, Body, Len) when byte_size(Body) >= Len ->
    Body;
body(Sock, Body, Len) ->
    {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
    body(Sock, <<Body/binary, Data/binary>>, Len).

content_length(Head) ->
    case re:run(Head, ~"(?i)\r\ncontent-length: *([0-9]+)", [{capture, all_but_first, binary}]) of
        {match, [Len]} -> binary_to_integer(Len);
        nomatch -> 0
    end.

recv_until_closed(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Data} -> recv_until_closed(Sock, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc
    end.
