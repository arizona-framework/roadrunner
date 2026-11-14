-module(roadrunner_grpc_protobuf_interop_SUITE).
-moduledoc """
gRPC's interop TestService (`roadrunner_grpc_protobuf_interop`) over
HTTP/2, its messages encoded by `roadrunner_grpc_protobuf` with the gpb
module generated from gRPC's `src/proto/grpc/testing` protos.

The `interop` group plays the server cases of gRPC's
doc/interop-test-descriptions.md with the hand-written client
(`roadrunner_grpc_test_client`); `official_client` runs gRPC's own interop
client over them when one is found, `GRPC_INTEROP_CLIENT` or an
`interop_client` on the PATH (grpc-go's, `go install
google.golang.org/grpc/interop/client@latest`, renamed), and is skipped
otherwise.
""".

-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([
    empty_unary/1,
    large_unary/1,
    client_compressed_unary/1,
    server_compressed_unary/1,
    client_streaming/1,
    client_compressed_streaming/1,
    server_streaming/1,
    server_compressed_streaming/1,
    ping_pong/1,
    empty_stream/1,
    half_duplex/1,
    cacheable_unary/1,
    custom_metadata/1,
    status_code_and_message/1,
    special_status_message/1,
    unimplemented_method/1,
    unimplemented_service/1,
    unsupported_response_type/1,
    cancel_after_begin/1,
    timeout_on_sleeping_server/1,
    official_client/1,
    adapter_eunit/1
]).

-define(PB, test_pb).
-define(SVC, ~"/grpc.testing.TestService/").

%% The server cases gRPC's interop clients run against a server.
-define(OFFICIAL_CASES, [
    "empty_unary",
    "large_unary",
    "client_streaming",
    "server_streaming",
    "ping_pong",
    "empty_stream",
    "custom_metadata",
    "status_code_and_message",
    "special_status_message",
    "unimplemented_method",
    "unimplemented_service",
    "cancel_after_begin",
    "cancel_after_first_response",
    "timeout_on_sleeping_server",
    "client_compressed_unary",
    "client_compressed_streaming",
    "server_compressed_unary",
    "server_compressed_streaming"
]).

suite() ->
    [{timetrap, {seconds, 60}}].

all() ->
    [{group, interop}, official_client, adapter_eunit].

groups() ->
    [
        {interop, [parallel], [
            empty_unary,
            large_unary,
            client_compressed_unary,
            server_compressed_unary,
            client_streaming,
            client_compressed_streaming,
            server_streaming,
            server_compressed_streaming,
            ping_pong,
            empty_stream,
            half_duplex,
            cacheable_unary,
            custom_metadata,
            status_code_and_message,
            special_status_message,
            unimplemented_method,
            unimplemented_service,
            unsupported_response_type,
            cancel_after_begin,
            timeout_on_sleeping_server
        ]}
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(roadrunner),
    {ok, Pid} = roadrunner_listener:start_link(?MODULE, #{
        port => 0,
        protocols => [http2],
        body_buffering => manual,
        routes => roadrunner_grpc_protobuf_interop:routes()
    }),
    %% The suite's processes come and go per case; the listener stays.
    true = unlink(Pid),
    [{port, roadrunner_listener:port(?MODULE)} | Config].

end_per_suite(_Config) ->
    ok = roadrunner_listener:stop(?MODULE).

empty_unary(Config) ->
    {_, [Response], Trailers} = unary(Config, ~"EmptyCall", 'grpc.testing.Empty', #{}),
    ?assertEqual(#{}, decode('grpc.testing.Empty', Response)),
    ?assertEqual(~"0", header(~"grpc-status", Trailers)).

large_unary(Config) ->
    {_, [Response], Trailers} = unary(Config, ~"UnaryCall", large_request(#{})),
    ?assertMatch(
        #{payload := #{type := 'COMPRESSABLE', body := <<0:(314159 * 8)>>}},
        decode('grpc.testing.SimpleResponse', Response)
    ),
    ?assertEqual(~"0", header(~"grpc-status", Trailers)).

%% The probe, uncompressed though it expects to be compressed, fails with
%% INVALID_ARGUMENT; a compressed one and one that expects none pass.
client_compressed_unary(Config) ->
    Expecting = encode(large_request(#{expect_compressed => #{value => true}})),
    Gzip = [{~"grpc-encoding", ~"gzip"}],
    {_, _, Probe} = call(Config, ~"UnaryCall", Gzip, [{plain, Expecting}]),
    ?assertEqual(~"3", header(~"grpc-status", Probe)),
    {_, [Response], Trailers} = call(Config, ~"UnaryCall", Gzip, [{gzip, Expecting}]),
    ?assertEqual(~"0", header(~"grpc-status", Trailers)),
    ?assertMatch(
        #{payload := #{body := <<0:(314159 * 8)>>}},
        decode('grpc.testing.SimpleResponse', Response)
    ),
    NotExpecting = encode(large_request(#{expect_compressed => #{value => false}})),
    {_, [_], Plain} = call(Config, ~"UnaryCall", [{plain, NotExpecting}]),
    ?assertEqual(~"0", header(~"grpc-status", Plain)).

%% response_compressed asks for a compressed response, which a client that
%% reads gzip gets.
server_compressed_unary(Config) ->
    Accept = [{~"grpc-accept-encoding", ~"gzip"}],
    Compressed = encode(large_request(#{response_compressed => #{value => true}})),
    {Headers, [{compressed, Gz}], _} = call(Config, ~"UnaryCall", Accept, [{plain, Compressed}]),
    ?assertEqual(~"gzip", header(~"grpc-encoding", Headers)),
    ?assertMatch(
        #{payload := #{body := <<0:(314159 * 8)>>}},
        decode('grpc.testing.SimpleResponse', zlib:gunzip(Gz))
    ),
    Plain = encode(large_request(#{response_compressed => #{value => false}})),
    {_, [Response], _} = call(Config, ~"UnaryCall", Accept, [{plain, Plain}]),
    ?assertMatch(#{payload := #{body := <<0:(314159 * 8)>>}}, decode(Response)).

client_streaming(Config) ->
    Requests = [{plain, input_request(Size, #{})} || Size <- [27182, 8, 1828, 45904]],
    {_, [Response], Trailers} = call(Config, ~"StreamingInputCall", Requests),
    ?assertEqual(
        #{aggregated_payload_size => 74922},
        decode('grpc.testing.StreamingInputCallResponse', Response)
    ),
    ?assertEqual(~"0", header(~"grpc-status", Trailers)).

client_compressed_streaming(Config) ->
    Gzip = [{~"grpc-encoding", ~"gzip"}],
    Expecting = input_request(27182, #{expect_compressed => #{value => true}}),
    {_, _, Probe} = call(Config, ~"StreamingInputCall", Gzip, [{plain, Expecting}]),
    ?assertEqual(~"3", header(~"grpc-status", Probe)),
    NotExpecting = input_request(45904, #{expect_compressed => #{value => false}}),
    {_, [Response], Trailers} = call(
        Config, ~"StreamingInputCall", Gzip, [{gzip, Expecting}, {plain, NotExpecting}]
    ),
    ?assertEqual(
        #{aggregated_payload_size => 73086},
        decode('grpc.testing.StreamingInputCallResponse', Response)
    ),
    ?assertEqual(~"0", header(~"grpc-status", Trailers)).

server_streaming(Config) ->
    Sizes = [31415, 9, 2653, 58979],
    Request = output_request([#{size => Size} || Size <- Sizes]),
    {_, Responses, Trailers} = call(Config, ~"StreamingOutputCall", [{plain, Request}]),
    ?assertEqual(Sizes, [body_size(R) || R <- Responses]),
    ?assertEqual(~"0", header(~"grpc-status", Trailers)).

%% Each response is compressed as its ResponseParameters ask.
server_compressed_streaming(Config) ->
    Request = output_request([
        #{size => 31415, compressed => #{value => true}},
        #{size => 92653, compressed => #{value => false}}
    ]),
    {Headers, [{compressed, Gz}, Plain], _} = call(
        Config, ~"StreamingOutputCall", [{~"grpc-accept-encoding", ~"gzip"}], [{plain, Request}]
    ),
    ?assertEqual(~"gzip", header(~"grpc-encoding", Headers)),
    ?assertEqual([31415, 92653], [body_size(zlib:gunzip(Gz)), body_size(Plain)]).

%% Each request is answered before the next goes out.
ping_pong(Config) ->
    C0 = roadrunner_grpc_test_client:start(open(Config), 1, <<?SVC/binary, "FullDuplexCall">>, []),
    C = lists:foldl(
        fun({RequestSize, ResponseSize}, C1) ->
            Request = output_request([#{size => ResponseSize}], #{payload => payload(RequestSize)}),
            C2 = roadrunner_grpc_test_client:send(C1, 1, frame(Request)),
            {Response, C3} = next_message(C2),
            ?assertEqual(ResponseSize, body_size(Response)),
            C3
        end,
        C0,
        [{27182, 31415}, {8, 9}, {1828, 2653}, {45904, 58979}]
    ),
    {Trailers, _} = roadrunner_grpc_test_client:trailers(
        roadrunner_grpc_test_client:finish(C, 1), 1
    ),
    ?assertEqual(~"0", header(~"grpc-status", Trailers)).

empty_stream(Config) ->
    {_, [], Trailers} = call(Config, ~"FullDuplexCall", []),
    ?assertEqual(~"0", header(~"grpc-status", Trailers)).

%% The responses come once the requests have ended.
half_duplex(Config) ->
    Requests = [{plain, output_request([#{size => Size}])} || Size <- [3, 5]],
    {_, Responses, Trailers} = call(Config, ~"HalfDuplexCall", Requests),
    ?assertEqual([3, 5], [body_size(R) || R <- Responses]),
    ?assertEqual(~"0", header(~"grpc-status", Trailers)).

cacheable_unary(Config) ->
    {Headers, [Response], _} = unary(Config, ~"CacheableUnaryCall", large_request(#{})),
    ?assertEqual(~"max-age=60", header(~"cache-control", Headers)),
    ?assertMatch(#{payload := #{body := <<_, _/binary>>}}, decode(Response)).

%% The echo metadata comes back, the initial in the headers and the
%% trailing (binary, base64 on the wire) in the trailers.
custom_metadata(Config) ->
    Metadata = [
        {~"x-grpc-test-echo-initial", ~"test_initial_metadata_value"},
        {~"x-grpc-test-echo-trailing-bin", base64:encode(<<16#ababab:24>>)}
    ],
    Unary = encode(large_request(#{})),
    Duplex = output_request([#{size => 314159}], #{payload => payload(271828)}),
    lists:foreach(
        fun({Method, Request}) ->
            {Headers, [_], Trailers} = call(Config, Method, Metadata, [{plain, Request}]),
            ?assertEqual(
                ~"test_initial_metadata_value", header(~"x-grpc-test-echo-initial", Headers)
            ),
            ?assertEqual(
                <<16#ababab:24>>,
                base64:decode(header(~"x-grpc-test-echo-trailing-bin", Trailers), #{
                    padding => false
                })
            )
        end,
        [{~"UnaryCall", Unary}, {~"FullDuplexCall", Duplex}]
    ).

status_code_and_message(Config) ->
    Status = #{code => 2, message => ~"test status message"},
    Unary = encode(#{response_status => Status}, 'grpc.testing.SimpleRequest'),
    Duplex = encode(#{response_status => Status}, 'grpc.testing.StreamingOutputCallRequest'),
    lists:foreach(
        fun({Method, Request}) ->
            {_, _, Trailers} = call(Config, Method, [{plain, Request}]),
            ?assertEqual(~"2", header(~"grpc-status", Trailers)),
            ?assertEqual(~"test status message", message(Trailers))
        end,
        [{~"UnaryCall", Unary}, {~"FullDuplexCall", Duplex}]
    ).

special_status_message(Config) ->
    Message = unicode:characters_to_binary(
        "\t\ntest with whitespace\r\nand Unicode BMP ☺ and non-BMP 😈\t\n"
    ),
    Request = encode(
        #{response_status => #{code => 2, message => Message}}, 'grpc.testing.SimpleRequest'
    ),
    {_, _, Trailers} = call(Config, ~"UnaryCall", [{plain, Request}]),
    ?assertEqual(~"2", header(~"grpc-status", Trailers)),
    ?assertEqual(Message, message(Trailers)).

unimplemented_method(Config) ->
    {_, [], Trailers} = unary(Config, ~"UnimplementedCall", 'grpc.testing.Empty', #{}),
    ?assertEqual(~"12", header(~"grpc-status", Trailers)).

%% A service the server does not have is the router's 404, which gRPC's
%% clients read as UNIMPLEMENTED (gRPC's http-grpc-status-mapping.md).
unimplemented_service(Config) ->
    {Headers, _, _, _} = roadrunner_grpc_test_client:call(
        open(Config), 1, ~"/grpc.testing.UnimplementedService/UnimplementedCall", [], [<<>>]
    ),
    ?assertEqual(~"404", header(~":status", Headers)).

unsupported_response_type(Config) ->
    {_, [], Trailers} = unary(Config, ~"UnaryCall", large_request(#{response_type => 1})),
    ?assertEqual(~"3", header(~"grpc-status", Trailers)).

%% A call cancelled before its requests end leaves the server answering
%% the next.
cancel_after_begin(Config) ->
    C0 = roadrunner_grpc_test_client:start(
        open(Config), 1, <<?SVC/binary, "StreamingInputCall">>, []
    ),
    C1 = roadrunner_grpc_test_client:send(C0, 1, frame(input_request(27182, #{}))),
    _ = roadrunner_grpc_test_client:reset(C1, 1),
    empty_unary(Config).

%% A full duplex call whose deadline runs out while it waits for the next
%% request ends with DEADLINE_EXCEEDED.
timeout_on_sleeping_server(Config) ->
    C0 = roadrunner_grpc_test_client:start(
        open(Config), 1, <<?SVC/binary, "FullDuplexCall">>, [{~"grpc-timeout", ~"1m"}]
    ),
    C1 = roadrunner_grpc_test_client:send(
        C0,
        1,
        frame(encode(#{payload => payload(27182)}, 'grpc.testing.StreamingOutputCallRequest'))
    ),
    {Headers, _, Trailers, _} = roadrunner_grpc_test_client:response(C1, 1),
    ?assertEqual(~"4", header(~"grpc-status", status_fields(Headers, Trailers))).

%% gRPC's own interop client, each server case in a run of its own. A case
%% the client does not have is noted, not failed (grpc-go has no
%% client_compressed_* or server_compressed_* cases), but a client that has
%% none of them fails.
official_client(Config) ->
    case interop_client() of
        false ->
            {skip, "no gRPC interop client (GRPC_INTEROP_CLIENT or interop_client on PATH)"};
        Client ->
            Port = integer_to_list(?config(port, Config)),
            Results = [{Case, run_client(Client, Port, Case)} || Case <- ?OFFICIAL_CASES],
            ct:log("~p", [Results]),
            Failed = [{Case, Output} || {Case, {failed, Output}} <- Results],
            Unsupported = [Case || {Case, unsupported} <- Results],
            ?assertEqual([], Failed),
            case length(Unsupported) of
                Count when Count =:= length(Results) ->
                    ct:fail(no_interop_case_ran);
                _ ->
                    {comment,
                        lists:flatten(
                            io_lib:format("unsupported by the client: ~p", [Unsupported])
                        )}
            end
    end.

interop_client() ->
    case os:getenv("GRPC_INTEROP_CLIENT") of
        false -> os:find_executable("interop_client");
        Path -> Path
    end.

run_client(Client, Port, Case) ->
    Port1 = open_port({spawn_executable, Client}, [
        {args, [
            "--server_host=127.0.0.1",
            "--server_port=" ++ Port,
            "--use_tls=false",
            "--test_case=" ++ Case
        ]},
        exit_status,
        stderr_to_stdout,
        binary
    ]),
    client_result(Port1, <<>>).

client_result(Port, Output) ->
    receive
        {Port, {data, Data}} ->
            client_result(Port, <<Output/binary, Data/binary>>);
        {Port, {exit_status, 0}} ->
            ok;
        {Port, {exit_status, _}} ->
            case binary:match(Output, [~"Unsupported test case", ~"unsupported test case"]) of
                nomatch -> {failed, Output};
                _ -> unsupported
            end
    end.

%% The adapter's eunit tests: `rebar3 eunit` runs `src/` and `test/` only,
%% and `--dir grpc_protobuf/test` would run the core's twice.
adapter_eunit(_Config) ->
    ok = eunit:test(roadrunner_grpc_protobuf_tests, []).

%% --- helpers ---

open(Config) ->
    roadrunner_grpc_test_client:open(?config(port, Config)).

unary(Config, Method, Request) ->
    unary(Config, Method, 'grpc.testing.SimpleRequest', Request).

unary(Config, Method, Type, Request) ->
    call(Config, Method, [{plain, encode(Request, Type)}]).

call(Config, Method, Messages) ->
    call(Config, Method, [], Messages).

%% A call of `Messages`, each `{plain | gzip, Bytes}`: `{Headers,
%% Responses, Trailers}`, the status fields being the headers of a
%% Trailers-Only answer.
call(Config, Method, Extra, Messages) ->
    C0 = roadrunner_grpc_test_client:start(open(Config), 1, <<?SVC/binary, Method/binary>>, Extra),
    C1 = roadrunner_grpc_test_client:send(C0, 1, iolist_to_binary([framed(M) || M <- Messages])),
    {Headers, Responses, Trailers, _} = roadrunner_grpc_test_client:response(
        roadrunner_grpc_test_client:finish(C1, 1), 1
    ),
    {Headers, Responses, status_fields(Headers, Trailers)}.

status_fields(Headers, trailers_only) -> Headers;
status_fields(_Headers, Trailers) -> Trailers.

framed({plain, Bytes}) -> roadrunner_grpc_frame:encode(false, Bytes);
framed({gzip, Bytes}) -> roadrunner_grpc_frame:encode(true, zlib:gzip(Bytes)).

frame(Bytes) ->
    iolist_to_binary(framed({plain, Bytes})).

%% The next response message, its DATA frames read until it is whole.
next_message(C) ->
    next_message(C, <<>>).

next_message(C0, Buffer) ->
    case roadrunner_grpc_test_client:next_frame(C0) of
        {{data, 1, _, Data, _}, C} ->
            Bytes = <<Buffer/binary, Data/binary>>,
            case roadrunner_grpc_frame:decode(Bytes, 16#FFFFFFFF) of
                {ok, false, Message, <<>>} -> {Message, C};
                more -> next_message(C, Bytes)
            end;
        {_Other, C} ->
            next_message(C, Buffer)
    end.

large_request(Fields) ->
    maps:merge(
        #{response_type => 'COMPRESSABLE', response_size => 314159, payload => payload(271828)},
        Fields
    ).

input_request(Size, Fields) ->
    encode(Fields#{payload => payload(Size)}, 'grpc.testing.StreamingInputCallRequest').

output_request(Parameters) ->
    output_request(Parameters, #{}).

output_request(Parameters, Fields) ->
    encode(Fields#{response_parameters => Parameters}, 'grpc.testing.StreamingOutputCallRequest').

payload(Size) ->
    #{type => 'COMPRESSABLE', body => <<0:(Size * 8)>>}.

body_size(Response) ->
    case decode('grpc.testing.StreamingOutputCallResponse', Response) of
        #{payload := #{body := Body}} -> byte_size(Body)
    end.

encode(Request) ->
    encode(Request, 'grpc.testing.SimpleRequest').

encode(Message, Type) ->
    iolist_to_binary(?PB:encode_msg(Message, Type)).

decode(Bytes) ->
    decode('grpc.testing.SimpleResponse', Bytes).

decode(Type, Bytes) ->
    ?PB:decode_msg(Bytes, Type).

message(Fields) ->
    roadrunner_grpc_status:decode_message(header(~"grpc-message", Fields)).

header(Name, Fields) ->
    proplists:get_value(Name, Fields).
