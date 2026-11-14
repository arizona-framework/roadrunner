-module(roadrunner_grpc_SUITE).
-moduledoc """
gRPC calls over HTTP/2 against `roadrunner_grpc`, with a hand-written
client (`roadrunner_grpc_test_client`) and the `roadrunner_grpc_test_service`
fixture, under both body buffering modes.
""".

-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, groups/0, init_per_group/2, end_per_group/2]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([
    unary/1,
    server_stream/1,
    client_stream/1,
    bidi_stream/1,
    bidi_interleaves/1,
    error_status_is_trailers_only/1,
    crash_is_internal/1,
    crash_after_a_response_is_internal_in_trailers/1,
    bad_return_is_internal/1,
    unknown_method_is_unimplemented/1,
    unknown_service_is_404/1,
    get_is_405/1,
    other_content_type_is_415/1,
    content_type_picks_the_codec/1,
    unsupported_encoding_is_unimplemented/1,
    compressed_message_is_internal/1,
    message_too_large_is_resource_exhausted/1,
    unary_needs_exactly_one_message/1,
    message_cut_short_is_internal/1,
    malformed_timeout_is_internal/1,
    timeout_sets_the_deadline/1,
    timeout_ends_a_waiting_read/1,
    metadata_round_trips/1,
    http1_is_505/1,
    http3_calls/1,
    content_type_parameters/1,
    shutdown_exit_stops_the_call/1,
    refused_trailer_stops_the_call/1,
    headers_after_a_response_are_internal/1,
    undecodable_message_is_internal/1,
    client_reset_stops_the_read/1,
    body_over_the_cap_is_resource_exhausted/1,
    stale_stream_sends_once/1,
    binary_metadata_splits_and_checks/1,
    content_type_ignores_case/1,
    reserved_or_uppercase_metadata_is_internal/1,
    large_message_across_frames/1,
    client_reset_stops_the_writes/1,
    route_cap_lets_a_stream_past_the_listener_cap/1,
    missing_content_type_is_415/1,
    space_before_content_type_parameters/1,
    unsendable_header_stops_the_call/1,
    deadline_cancels_a_running_call/1,
    compressed_requests_are_read/1,
    malformed_compressed_message_is_internal/1,
    compressed_bomb_is_resource_exhausted/1,
    response_compressed_when_the_client_reads_it/1,
    compression_after_a_response_is_internal/1,
    messages_follow_the_announced_encoding/1,
    route_compression_applies/1,
    body_past_the_window_waits_for_the_reader/1,
    recv_tells_a_compressed_message/1,
    descriptor_service_calls/1
]).

-define(RUNTIME, ~"/test.Runtime/").

-define(SVC, ~"/test.Echo/").

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [{group, auto}, {group, manual}, http1_is_505, http3_calls].

groups() ->
    Common = [
        unary,
        server_stream,
        client_stream,
        bidi_stream,
        error_status_is_trailers_only,
        crash_is_internal,
        crash_after_a_response_is_internal_in_trailers,
        bad_return_is_internal,
        unknown_method_is_unimplemented,
        unknown_service_is_404,
        get_is_405,
        other_content_type_is_415,
        content_type_picks_the_codec,
        unsupported_encoding_is_unimplemented,
        compressed_message_is_internal,
        message_too_large_is_resource_exhausted,
        unary_needs_exactly_one_message,
        message_cut_short_is_internal,
        malformed_timeout_is_internal,
        timeout_sets_the_deadline,
        metadata_round_trips,
        content_type_parameters,
        shutdown_exit_stops_the_call,
        refused_trailer_stops_the_call,
        headers_after_a_response_are_internal,
        undecodable_message_is_internal,
        stale_stream_sends_once,
        binary_metadata_splits_and_checks,
        content_type_ignores_case,
        reserved_or_uppercase_metadata_is_internal,
        route_cap_lets_a_stream_past_the_listener_cap,
        missing_content_type_is_415,
        space_before_content_type_parameters,
        unsendable_header_stops_the_call,
        deadline_cancels_a_running_call,
        compressed_requests_are_read,
        malformed_compressed_message_is_internal,
        compressed_bomb_is_resource_exhausted,
        response_compressed_when_the_client_reads_it,
        compression_after_a_response_is_internal,
        messages_follow_the_announced_encoding,
        route_compression_applies,
        recv_tells_a_compressed_message,
        descriptor_service_calls
    ],
    [
        {auto, [], Common},
        {manual, [],
            Common ++
                [
                    bidi_interleaves,
                    timeout_ends_a_waiting_read,
                    client_reset_stops_the_read,
                    body_over_the_cap_is_resource_exhausted,
                    large_message_across_frames,
                    client_reset_stops_the_writes,
                    body_past_the_window_waits_for_the_reader
                ]}
    ].

init_per_group(Mode, Config) ->
    [{mode, Mode} | Config].

end_per_group(_Mode, _Config) ->
    ok.

init_per_testcase(http1_is_505, Config) ->
    start(Config, [http1], auto);
init_per_testcase(http3_calls, Config) ->
    start(Config, [http3], manual);
init_per_testcase(_Case, Config) ->
    start(Config, [http2], ?config(mode, Config)).

start(Config, Protocols, Mode) ->
    {ok, _} = roadrunner_listener:start_link(?MODULE, (tls(Protocols))#{
        port => 0,
        protocols => Protocols,
        body_buffering => Mode,
        max_content_length => 50_000,
        routes => roadrunner_grpc:routes(#{
            services => [
                roadrunner_grpc_test_service,
                #{
                    name => ~"test.Runtime",
                    module => roadrunner_grpc_test_service,
                    rpcs => #{
                        ~"Echo" => #{
                            function => unary, kind => unary, input => in, output => out
                        }
                    }
                }
            ],
            codecs => [roadrunner_grpc_codec_raw, roadrunner_grpc_test_codec],
            max_message_size => 100_000,
            send_compression => gzip,
            max_content_length => 300_000
        })
    }),
    [{port, roadrunner_listener:port(?MODULE)} | Config].

%% HTTP/3 runs over QUIC, which needs a certificate.
tls([http3]) -> #{tls => roadrunner_test_certs:server_opts()};
tls(_Protocols) -> #{}.

end_per_testcase(_Case, _Config) ->
    ok = roadrunner_listener:stop(?MODULE).

unary(Config) ->
    {Headers, [~"hi"], Trailers, _} = call(Config, ~"Unary", [~"hi"]),
    ?assertEqual(~"200", header(~":status", Headers)),
    ?assertEqual(~"application/grpc", header(~"content-type", Headers)),
    ?assertEqual(~"0", header(~"grpc-status", Trailers)).

server_stream(Config) ->
    {_, Messages, Trailers, _} = call(Config, ~"Count", [~"3"]),
    ?assertEqual([~"1", ~"2", ~"3"], Messages),
    ?assertEqual(~"0", header(~"grpc-status", Trailers)).

client_stream(Config) ->
    {_, [~"abc"], Trailers, _} = call(Config, ~"Sum", [~"a", ~"b", ~"c"]),
    ?assertEqual(~"0", header(~"grpc-status", Trailers)).

bidi_stream(Config) ->
    {_, [~"a", ~"b"], Trailers, _} = call(Config, ~"Chat", [~"a", ~"b"]),
    ?assertEqual(~"0", header(~"grpc-status", Trailers)).

%% With manual buffering each request is answered before the next is sent.
bidi_interleaves(Config) ->
    C0 = roadrunner_grpc_test_client:start(open(Config), 1, <<?SVC/binary, "Chat">>, []),
    C1 = roadrunner_grpc_test_client:send(C0, 1, frame(~"ping")),
    {Echo, C2} = next_message(C1),
    ?assertEqual(~"ping", Echo),
    C3 = roadrunner_grpc_test_client:send(C2, 1, frame(~"pong")),
    {Echo2, C4} = next_message(C3),
    ?assertEqual(~"pong", Echo2),
    {Trailers, _} = roadrunner_grpc_test_client:trailers(
        roadrunner_grpc_test_client:finish(C4, 1), 1
    ),
    ?assertEqual(~"0", header(~"grpc-status", Trailers)).

error_status_is_trailers_only(Config) ->
    {Headers, [], trailers_only, _} = call(Config, ~"Fail", [~"x"]),
    ?assertEqual(~"200", header(~":status", Headers)),
    ?assertEqual(~"5", header(~"grpc-status", Headers)),
    ?assertEqual(~"application/grpc", header(~"content-type", Headers)),
    ?assertEqual(~"no such thing: caf%C3%A9 100%25", header(~"grpc-message", Headers)).

crash_is_internal(Config) ->
    {Headers, [], trailers_only, _} = call(Config, ~"Crash", [~"x"]),
    ?assertEqual(~"13", header(~"grpc-status", Headers)).

crash_after_a_response_is_internal_in_trailers(Config) ->
    {_, [~"first"], Trailers, _} = call(Config, ~"CrashAfter", [~"x"]),
    ?assertEqual(~"13", header(~"grpc-status", Trailers)).

bad_return_is_internal(Config) ->
    {Headers, [], trailers_only, _} = call(Config, ~"Bad", [~"x"]),
    ?assertEqual(~"13", header(~"grpc-status", Headers)).

unknown_method_is_unimplemented(Config) ->
    {Headers, [], trailers_only, _} = call(Config, ~"Nope", [~"x"]),
    ?assertEqual(~"12", header(~"grpc-status", Headers)).

unknown_service_is_404(Config) ->
    {Headers, _, _, _} = roadrunner_grpc_test_client:call(open(Config), 1, ~"/no.Such/Thing", [~"x"]),
    ?assertEqual(~"404", header(~":status", Headers)).

get_is_405(Config) ->
    {Headers, _, _, _} = call(Config, ~"Unary", [{~":method", ~"GET"}], [~"x"]),
    ?assertEqual(~"405", header(~":status", Headers)),
    ?assertEqual(~"POST", header(~"allow", Headers)).

other_content_type_is_415(Config) ->
    lists:foreach(
        fun(ContentType) ->
            {Headers, _, _, _} = call(Config, ~"Unary", [{~"content-type", ContentType}], [~"x"]),
            ?assertEqual(~"415", header(~":status", Headers))
        end,
        [~"application/json", ~"application/grpc+json", ~"application/grpcx"]
    ).

content_type_picks_the_codec(Config) ->
    CT = ~"application/grpc+test; charset=x",
    {Headers, [Reply], Trailers, _} =
        call(Config, ~"Unary", [{~"content-type", CT}], [term_to_binary({a, 1})]),
    ?assertEqual(~"application/grpc+test", header(~"content-type", Headers)),
    ?assertEqual({a, 1}, binary_to_term(Reply)),
    ?assertEqual(~"0", header(~"grpc-status", Trailers)),
    {Proto, [~"y"], _, _} = call(
        Config, ~"Unary", [{~"content-type", ~"application/grpc+proto"}], [~"y"]
    ),
    ?assertEqual(~"application/grpc+proto", header(~"content-type", Proto)).

unsupported_encoding_is_unimplemented(Config) ->
    {Headers, [], trailers_only, _} = call(Config, ~"Unary", [{~"grpc-encoding", ~"snappy"}], [~"x"]),
    ?assertEqual(~"12", header(~"grpc-status", Headers)),
    ?assertEqual(~"identity,gzip,deflate", header(~"grpc-accept-encoding", Headers)),
    ?assertMatch({match, _}, re:run(header(~"grpc-message", Headers), "supported")),
    {_, [~"x"], _, _} = call(Config, ~"Unary", [{~"grpc-encoding", ~"identity"}], [~"x"]).

compressed_message_is_internal(Config) ->
    {Headers, [], trailers_only, _} = raw_call(
        Config, ~"Unary", iolist_to_binary(roadrunner_grpc_frame:encode(true, ~"x"))
    ),
    ?assertEqual(~"13", header(~"grpc-status", Headers)).

message_too_large_is_resource_exhausted(Config) ->
    {Headers, [], trailers_only, _} = call(Config, ~"Unary", [binary:copy(~"x", 100_001)]),
    ?assertEqual(~"8", header(~"grpc-status", Headers)).

unary_needs_exactly_one_message(Config) ->
    {Two, [], trailers_only, _} = call(Config, ~"Unary", [~"a", ~"b"]),
    ?assertEqual(~"13", header(~"grpc-status", Two)),
    {None, [], trailers_only, _} = call(Config, ~"Unary", []),
    ?assertEqual(~"13", header(~"grpc-status", None)).

message_cut_short_is_internal(Config) ->
    {Headers, [], trailers_only, _} = raw_call(Config, ~"Unary", <<0, 0, 0, 0, 9, "abc">>),
    ?assertEqual(~"13", header(~"grpc-status", Headers)),
    {Bad, [], trailers_only, _} = raw_call(Config, ~"Unary", <<7, 0, 0, 0, 1, "a">>),
    ?assertEqual(~"13", header(~"grpc-status", Bad)).

malformed_timeout_is_internal(Config) ->
    {Headers, [], trailers_only, _} = call(Config, ~"Unary", [{~"grpc-timeout", ~"soon"}], [~"x"]),
    ?assertEqual(~"13", header(~"grpc-status", Headers)).

timeout_sets_the_deadline(Config) ->
    Before = erlang:monotonic_time(millisecond),
    {_, [With], _, _} = call(Config, ~"Deadline", [{~"grpc-timeout", ~"10S"}], [~"x"]),
    Deadline = binary_to_term(With),
    ?assert(
        Deadline >= Before + 10000 andalso Deadline =< erlang:monotonic_time(millisecond) + 10000
    ),
    {_, [Without], _, _} = call(Config, ~"Deadline", [~"x"]),
    ?assertEqual(infinity, binary_to_term(Without)).

%% A read waiting on a client that sends nothing ends when the call's
%% timeout runs out.
timeout_ends_a_waiting_read(Config) ->
    C = roadrunner_grpc_test_client:start(open(Config), 1, <<?SVC/binary, "Chat">>, [
        {~"grpc-timeout", ~"100m"}
    ]),
    {Headers, [], trailers_only, _} = roadrunner_grpc_test_client:response(C, 1),
    ?assertEqual(~"4", header(~"grpc-status", Headers)).

metadata_round_trips(Config) ->
    Extra = [
        {~"x-plain", ~"v"},
        {~"x-data-bin", base64:encode(<<255, 0>>, #{padding => false})},
        {~"grpc-timeout", ~"5S"}
    ],
    {Headers, [Reply], Trailers, _} = call(Config, ~"Meta", Extra, [~"x"]),
    {Metadata, {{127, 0, 0, 1}, Port}} = binary_to_term(Reply),
    ?assert(is_integer(Port)),
    ?assertNot(lists:keymember(~"grpc-timeout", 1, Metadata)),
    ?assertEqual(~"v", header(~"x-plain", Metadata)),
    ?assertEqual(<<255, 0>>, header(~"x-data-bin", Metadata)),
    ?assertNot(lists:keymember(~"te", 1, Metadata)),
    ?assertNot(lists:keymember(~"content-type", 1, Metadata)),
    ?assertEqual(~"h", header(~"x-head", Headers)),
    ?assertEqual(<<0, 1, 2>>, base64:decode(header(~"x-raw-bin", Headers), #{padding => false})),
    ?assertEqual(~"t", header(~"x-tail", Trailers)),
    ?assertEqual(~"0", header(~"grpc-status", Trailers)).

http1_is_505(Config) ->
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, ?config(port, Config), [binary, {active, false}]),
    ok = gen_tcp:send(Sock, [
        ~"POST /test.Echo/Unary HTTP/1.1\r\nhost: x\r\ncontent-type: application/grpc\r\n",
        ~"content-length: 0\r\n\r\n"
    ]),
    {ok, <<"HTTP/1.1 505", _/binary>>} = gen_tcp:recv(Sock, 0, 5000),
    ok = gen_tcp:close(Sock).

%% The same calls over HTTP/3: a unary and a server-streaming one end with
%% trailers, a failing one is Trailers-Only.
http3_calls(Config) ->
    {ok, Conn} = roadrunner_quic_test_h3:connect({127, 0, 0, 1}, ?config(port, Config)),
    {[Headers, Trailers], Body} = h3_call(Conn, ~"Unary", [{~"grpc-timeout", ~"10S"}], [~"hi"]),
    ?assertEqual(~"200", header(~":status", Headers)),
    ?assertEqual([~"hi"], roadrunner_grpc_test_client:messages(Body)),
    ?assertEqual(~"0", header(~"grpc-status", Trailers)),
    {[_, CountTrailers], CountBody} = h3_call(Conn, ~"Count", [~"2"]),
    ?assertEqual([~"1", ~"2"], roadrunner_grpc_test_client:messages(CountBody)),
    ?assertEqual(~"0", header(~"grpc-status", CountTrailers)),
    {[Only], <<>>} = h3_call(Conn, ~"Fail", [~"x"]),
    ?assertEqual(~"5", header(~"grpc-status", Only)),
    %% A call still running at its deadline is cancelled (H3_REQUEST_CANCELLED).
    ?assertEqual(
        {error, {stream_reset, 16#010C}},
        h3_call(Conn, ~"Busy", [{~"grpc-timeout", ~"100m"}], [~"x"])
    ),
    _ = roadrunner_quic_test_h3:close(Conn),
    ok.

h3_call(Conn, Method, Messages) ->
    h3_call(Conn, Method, [], Messages).

h3_call(Conn, Method, Extra, Messages) ->
    Fields = [
        {~":method", ~"POST"},
        {~":scheme", ~"https"},
        {~":authority", ~"localhost"},
        {~":path", <<?SVC/binary, Method/binary>>},
        {~"content-type", ~"application/grpc"},
        {~"te", ~"trailers"}
        | Extra
    ],
    {ok, StreamId} = roadrunner_quic_test_h3:open_request(Conn, Fields, false),
    ok = roadrunner_quic_test_h3:send_data(
        Conn,
        StreamId,
        iolist_to_binary([roadrunner_grpc_frame:encode(false, M) || M <- Messages]),
        true
    ),
    roadrunner_quic_test_h3:collect_all(Conn, StreamId).

content_type_parameters(Config) ->
    {Headers, [~"x"], _, _} = call(
        Config, ~"Unary", [{~"content-type", ~"application/grpc; v=1"}], [~"x"]
    ),
    ?assertEqual(~"application/grpc", header(~"content-type", Headers)).

%% A method that stops the call on purpose (`exit({shutdown, _})`) gets no
%% gRPC status: the request just ends, here before any response, as a 500.
shutdown_exit_stops_the_call(Config) ->
    {Headers, _, _, _} = call(Config, ~"Stop", [~"x"]),
    ?assertEqual(~"500", header(~":status", Headers)).

%% A trailer the connection will not send (a CR LF in its value) stops the
%% call: the response ends without a status.
refused_trailer_stops_the_call(Config) ->
    {Headers, _, Trailers, _} = call(Config, ~"BadTrailer", [~"x"]),
    ?assertEqual(~"200", header(~":status", Headers)),
    ?assertNotMatch([_ | _], Trailers).

headers_after_a_response_are_internal(Config) ->
    {_, [~"one"], Trailers, _} = call(Config, ~"LateHeaders", [~"x"]),
    ?assertEqual(~"13", header(~"grpc-status", Trailers)).

undecodable_message_is_internal(Config) ->
    {Headers, [], trailers_only, _} =
        call(Config, ~"Unary", [{~"content-type", ~"application/grpc+test"}], [~"not a term"]),
    ?assertEqual(~"13", header(~"grpc-status", Headers)).

%% A client that resets its call while the method reads stops the call, and
%% the connection goes on serving.
client_reset_stops_the_read(Config) ->
    C0 = roadrunner_grpc_test_client:start(open(Config), 1, <<?SVC/binary, "Sum">>, []),
    C1 = roadrunner_grpc_test_client:send(C0, 1, frame(~"a")),
    C2 = roadrunner_grpc_test_client:reset(C1, 1),
    {_, [~"y"], Trailers, _} = roadrunner_grpc_test_client:call(
        C2, 3, <<?SVC/binary, "Unary">>, [], [~"y"]
    ),
    ?assertEqual(~"0", header(~"grpc-status", Trailers)).

body_over_the_cap_is_resource_exhausted(Config) ->
    Big = binary:copy(~"x", 90_000),
    {Headers, [], trailers_only, _} = call(Config, ~"Sum", [Big, Big, Big, Big]),
    ?assertEqual(~"8", header(~"grpc-status", Headers)).

stale_stream_sends_once(Config) ->
    {_, [~"a", ~"b"], Trailers, _} = call(Config, ~"StaleSend", [~"x"]),
    ?assertEqual(~"0", header(~"grpc-status", Trailers)).

binary_metadata_splits_and_checks(Config) ->
    Joined = <<
        (base64:encode(<<1>>))/binary, ", ", (base64:encode(<<2, 3>>, #{padding => false}))/binary
    >>,
    {_, [Reply], _, _} = call(Config, ~"Meta", [{~"x-two-bin", Joined}], [~"x"]),
    {Metadata, _} = binary_to_term(Reply),
    ?assertEqual([<<1>>, <<2, 3>>], proplists:get_all_values(~"x-two-bin", Metadata)),
    {Headers, [], trailers_only, _} = call(Config, ~"Meta", [{~"x-bad-bin", ~"!!"}], [~"x"]),
    ?assertEqual(~"13", header(~"grpc-status", Headers)).

content_type_ignores_case(Config) ->
    {_, [Reply], _, _} =
        call(Config, ~"Unary", [{~"content-type", ~"Application/GRPC+Test ;x=1"}], [
            term_to_binary(ok)
        ]),
    ?assertEqual(ok, binary_to_term(Reply)).

reserved_or_uppercase_metadata_is_internal(Config) ->
    lists:foreach(
        fun(Which) ->
            {Headers, [], trailers_only, _} = call(Config, ~"BadName", [Which]),
            ?assertEqual(~"13", header(~"grpc-status", Headers))
        end,
        [~"upper", ~"reserved", ~"pseudo", ~"trailer"]
    ).

%% A message over one DATA frame's 16 KB arrives in pieces and reads whole.
large_message_across_frames(Config) ->
    Big = binary:copy(~"0123456789", 5000),
    {_, [Echo], Trailers, _} = call(Config, ~"Unary", [Big]),
    ?assertEqual(Big, Echo),
    ?assertEqual(~"0", header(~"grpc-status", Trailers)).

%% A client that resets its call while the method writes stops the method
%% on its next write, and the connection goes on serving.
client_reset_stops_the_writes(Config) ->
    C0 = roadrunner_grpc_test_client:start(open(Config), 1, <<?SVC/binary, "Count">>, []),
    C1 = roadrunner_grpc_test_client:finish(
        roadrunner_grpc_test_client:send(C0, 1, frame(~"100000")), 1
    ),
    {_, C2} = skip_to_data(C1),
    C3 = roadrunner_grpc_test_client:reset(C2, 1),
    {_, [~"y"], Trailers, _} = roadrunner_grpc_test_client:call(
        C3, 3, <<?SVC/binary, "Unary">>, [], [~"y"]
    ),
    ?assertEqual(~"0", header(~"grpc-status", Trailers)).

%% The route's own cap stands in for the listener's: 80 KB passes a
%% listener capped at 50 KB.
route_cap_lets_a_stream_past_the_listener_cap(Config) ->
    Part = binary:copy(~"x", 20_000),
    {_, [Sum], Trailers, _} = call(Config, ~"Sum", [Part, Part, Part, Part]),
    ?assertEqual(80_000, byte_size(Sum)),
    ?assertEqual(~"0", header(~"grpc-status", Trailers)).

missing_content_type_is_415(Config) ->
    {Headers, _, _, _} = call(Config, ~"Unary", [{~"content-type", omit}], [~"x"]),
    ?assertEqual(~"415", header(~":status", Headers)).

space_before_content_type_parameters(Config) ->
    {Headers, [~"x"], _, _} = call(
        Config, ~"Unary", [{~"content-type", ~"application/grpc ;v=1"}], [~"x"]
    ),
    ?assertEqual(~"application/grpc", header(~"content-type", Headers)),
    {Tab, [~"x"], _, _} = call(Config, ~"Unary", [{~"content-type", ~"application/grpc\t;v=1"}], [
        ~"x"
    ]),
    ?assertEqual(~"application/grpc", header(~"content-type", Tab)).

%% A response header the connection will not send stops the call, ahead of
%% a response or of an error status alike: it is answered 500.
unsendable_header_stops_the_call(Config) ->
    {Stream, _, _, _} = call(Config, ~"UnsafeHeader", [~"x"]),
    ?assertEqual(~"500", header(~":status", Stream)),
    {Fail, _, _, _} = call(Config, ~"UnsafeFail", [~"x"]),
    ?assertEqual(~"500", header(~":status", Fail)).

%% A call still running at its deadline has its stream reset (CANCEL), as
%% grpc-java does; the method is not waited for.
deadline_cancels_a_running_call(Config) ->
    {_, [], {rst, cancel}, _} = call(Config, ~"Busy", [{~"grpc-timeout", ~"100m"}], [~"x"]).

%% gzip and deflate (the zlib structure) messages are read; an uncompressed
%% one in a compressed call too, its flag saying so.
compressed_requests_are_read(Config) ->
    Payload = binary:copy(~"hello ", 50),
    lists:foreach(
        fun({Encoding, Compressed}) ->
            Body = iolist_to_binary(roadrunner_grpc_frame:encode(true, Compressed)),
            {_, [Echo], Trailers, _} = raw_call(
                Config, ~"Unary", [{~"grpc-encoding", Encoding}], Body
            ),
            ?assertEqual(Payload, Echo),
            ?assertEqual(~"0", header(~"grpc-status", Trailers))
        end,
        [{~"gzip", zlib:gzip(Payload)}, {~"deflate", zlib:compress(Payload)}]
    ),
    {_, [~"plain"], _, _} = call(Config, ~"Unary", [{~"grpc-encoding", ~"gzip"}], [~"plain"]).

%% Bytes that do not inflate, raw deflate included (gRPC's deflate is the
%% zlib structure), end the call INTERNAL.
malformed_compressed_message_is_internal(Config) ->
    lists:foreach(
        fun({Encoding, Bytes}) ->
            Body = iolist_to_binary(roadrunner_grpc_frame:encode(true, Bytes)),
            {Headers, [], trailers_only, _} =
                raw_call(Config, ~"Unary", [{~"grpc-encoding", Encoding}], Body),
            ?assertEqual(~"13", header(~"grpc-status", Headers))
        end,
        [{~"gzip", ~"not gzip"}, {~"deflate", zlib:zip(~"raw deflate")}]
    ).

%% A small message that inflates past max_message_size is refused as it
%% inflates.
compressed_bomb_is_resource_exhausted(Config) ->
    Bomb = zlib:gzip(binary:copy(<<0>>, 200_000)),
    Body = iolist_to_binary(roadrunner_grpc_frame:encode(true, Bomb)),
    {Headers, [], trailers_only, _} = raw_call(
        Config, ~"Unary", [{~"grpc-encoding", ~"gzip"}], Body
    ),
    ?assertEqual(~"8", header(~"grpc-status", Headers)).

%% The answer is compressed when the client reads the encoding, a message
%% sent with `compress => false` excepted, and sent as it is when not.
response_compressed_when_the_client_reads_it(Config) ->
    Payload = binary:copy(~"squeeze me ", 20),
    {Headers, [{compressed, Gz}, Payload], _, _} =
        call(Config, ~"Squeezed", [{~"grpc-accept-encoding", ~"identity, gzip"}], [~"gzip"]),
    ?assertEqual(~"gzip", header(~"grpc-encoding", Headers)),
    ?assertEqual(Payload, zlib:gunzip(Gz)),
    {_, [{compressed, Z}, Payload], _, _} =
        call(Config, ~"Squeezed", [{~"grpc-accept-encoding", ~"deflate"}], [~"deflate"]),
    ?assertEqual(Payload, zlib:uncompress(Z)),
    {Plain, [Payload, Payload], _, _} = call(Config, ~"Squeezed", [~"gzip"]),
    ?assertEqual(undefined, header(~"grpc-encoding", Plain)).

compression_after_a_response_is_internal(Config) ->
    {_, [~"one"], Trailers, _} = call(Config, ~"LateCompression", [~"x"]),
    ?assertEqual(~"13", header(~"grpc-status", Trailers)).

%% A message sent from a copy of the stream set to compress, after the
%% headers went out uncompressed, goes out uncompressed: it follows what the
%% headers announced.
messages_follow_the_announced_encoding(Config) ->
    {Headers, [~"one", ~"two"], _, _} =
        call(Config, ~"StaleCompression", [{~"grpc-accept-encoding", ~"gzip"}], [~"x"]),
    ?assertEqual(undefined, header(~"grpc-encoding", Headers)).

%% The route's `send_compression` (gzip here) applies when the client reads
%% it, and every response advertises what it reads.
route_compression_applies(Config) ->
    {Headers, [{compressed, Gz}], _, _} =
        call(Config, ~"Unary", [{~"grpc-accept-encoding", ~"gzip"}], [~"hi"]),
    ?assertEqual(~"gzip", header(~"grpc-encoding", Headers)),
    ?assertEqual(~"identity,gzip,deflate", header(~"grpc-accept-encoding", Headers)),
    ?assertEqual(~"hi", zlib:gunzip(Gz)),
    {Plain, [~"hi"], _, _} = call(Config, ~"Unary", [~"hi"]),
    ?assertEqual(undefined, header(~"grpc-encoding", Plain)).

%% A body past the stream's first window (65535 bytes) waits for the
%% method to read before the rest goes out (RFC 9113 §6.9): the method
%% reads nothing until the connection has taken a whole window of its
%% DATA, so a client that sent on regardless would overrun the window and
%% have the stream reset (FLOW_CONTROL_ERROR).
body_past_the_window_waits_for_the_reader(Config) ->
    Client = self(),
    Gate = spawn_link(fun() -> gate(Client, 0, undefined) end),
    true = register(roadrunner_grpc_held, Gate),
    Parse = {roadrunner_http2_frame, parse, 2},
    1 = erlang:trace_pattern(Parse, [{'_', [], [{return_trace}]}], [global]),
    _ = erlang:trace(all, true, [call, {tracer, Gate}]),
    Part = binary:copy(~"x", 50_000),
    try
        {_, [Sum], Trailers, _} = call(Config, ~"Held", [Part, Part, Part, Part]),
        ?assertEqual(200_000, byte_size(Sum)),
        ?assertEqual(~"0", header(~"grpc-status", Trailers))
    after
        _ = erlang:trace(all, false, [call]),
        _ = erlang:trace_pattern(Parse, false, [global])
    end.

%% Lets the `Held` method read once the server has parsed a whole window
%% of DATA on stream 1, counted from the frames its connection parses.
gate(_Client, Taken, Worker) when Taken >= 65535, is_pid(Worker) ->
    Worker ! go,
    ok;
gate(Client, Taken, Worker) ->
    receive
        {held, Pid} ->
            gate(Client, Taken, Pid);
        {trace, Pid, return_from, _, {ok, {data, 1, _, _, FlowLen}, _}} when Pid =/= Client ->
            gate(Client, Taken + FlowLen, Worker);
        _Other ->
            gate(Client, Taken, Worker)
    end.

%% `recv_compressed/1` says how the message read last came: flagged
%% compressed or not, the call's grpc-encoding aside.
recv_tells_a_compressed_message(Config) ->
    Gzip = [{~"grpc-encoding", ~"gzip"}],
    Body = iolist_to_binary(roadrunner_grpc_frame:encode(true, zlib:gzip(~"x"))),
    {_, [~"true"], _, _} = raw_call(Config, ~"WasCompressed", Gzip, Body),
    {_, [~"false"], _, _} = call(Config, ~"WasCompressed", Gzip, [~"x"]).

%% A service given as a descriptor map is routed and called like a module.
descriptor_service_calls(Config) ->
    {_, [~"hi"], Trailers, _} = roadrunner_grpc_test_client:call(
        open(Config), 1, <<?RUNTIME/binary, "Echo">>, [], [~"hi"]
    ),
    ?assertEqual(~"0", header(~"grpc-status", Trailers)).

%% --- helpers ---

open(Config) ->
    roadrunner_grpc_test_client:open(?config(port, Config)).

call(Config, Method, Messages) ->
    call(Config, Method, [], Messages).

call(Config, Method, Extra, Messages) ->
    roadrunner_grpc_test_client:call(
        open(Config), 1, <<?SVC/binary, Method/binary>>, Extra, Messages
    ).

raw_call(Config, Method, Bytes) ->
    raw_call(Config, Method, [], Bytes).

raw_call(Config, Method, Extra, Bytes) ->
    C0 = roadrunner_grpc_test_client:start(open(Config), 1, <<?SVC/binary, Method/binary>>, Extra),
    C1 = roadrunner_grpc_test_client:send(C0, 1, Bytes),
    roadrunner_grpc_test_client:response(roadrunner_grpc_test_client:finish(C1, 1), 1).

frame(Message) ->
    iolist_to_binary(roadrunner_grpc_frame:encode(false, Message)).

next_message(C) ->
    {{data, 1, _, Data, _}, C1} = skip_to_data(C),
    {ok, false, Message, <<>>} = roadrunner_grpc_frame:decode(Data, 1024),
    {Message, C1}.

skip_to_data(C) ->
    case roadrunner_grpc_test_client:next_frame(C) of
        {{data, 1, _, _, _}, _} = Data -> Data;
        {_Other, C1} -> skip_to_data(C1)
    end.

header(Name, Fields) ->
    proplists:get_value(Name, Fields).
