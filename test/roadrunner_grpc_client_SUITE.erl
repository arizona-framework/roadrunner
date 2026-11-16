-module(roadrunner_grpc_client_SUITE).
-moduledoc """
`roadrunner_grpc_client` against a real roadrunner gRPC listener (cleartext
h2c and TLS), and against a scripted HTTP/2 server for the protocol's edge
cases a real server does not produce.

The suite is also the service the listener serves (a descriptor map whose
module is this one) and a client-side codec (`proto` subtype) whose
`decode/2` raises on `~"bad"`.
""".

-behaviour(ct_suite).
-behaviour(roadrunner_grpc_codec).

-include_lib("stdlib/include/assert.hrl").
-include("../include/roadrunner_grpc_client.hrl").

-export([suite/0, all/0, groups/0]).
-export([init_per_group/2, end_per_group/2, init_per_testcase/2, end_per_testcase/2]).
%% The service.
-export([echo/2, fail/2, fail_after/2, meta/2, count/2, sum/1, chat/1, squeeze/2]).
-export([compressed/1, watch/2, hold/2, stop/2]).
%% The client codec.
-export([subtype/0, encode/2, decode/2]).
%% Cases.
-export([
    unary_ok/1,
    unary_error_is_trailers_only/1,
    error_after_messages/1,
    metadata_both_ways/1,
    invalid_metadata_raises/1,
    server_stream/1,
    client_stream/1,
    bidi_stream/1,
    large_messages_both_ways/1,
    slow_reader/1,
    compression_both_ways/1,
    message_size_limits/1,
    codecs/1,
    deadline_exceeded/1,
    cancel/1,
    not_grpc_status_maps/1,
    unimplemented/1,
    concurrent_calls/1,
    big_metadata_uses_continuation/1,
    recv_timeout_leaves_the_call/1,
    answer_racing_a_withdraw/1,
    caller_death_cancels/1,
    owner_death_closes/1,
    close_ends_calls/1,
    sys_and_stray_messages/1,
    max_concurrent_streams_queue/1,
    tls_alpn/1,
    tls_without_h2/1,
    options_are_checked/1,
    connect_failures/1,
    hosts/1,
    ping/1,
    settings_and_flow_control/1,
    responses_gRPC_rejects/1,
    frames_on_closed_streams/1,
    stream_window_overrun/1,
    goaway/1,
    connection_errors/1,
    server_closes_mid_call/1,
    header_list_cap/1,
    interim_and_status_precedence/1,
    request_header_order/1,
    deadline_timer_stops/1,
    concurrent_reads_are_busy/1,
    stream_ids_run_out/1
]).

-define(LISTENER, roadrunner_grpc_client_SUITE_listener).
-define(WATCHER, roadrunner_grpc_client_SUITE_watcher).
-define(SVC, "/test.Client/").
-define(PREFACE, ~"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n").
-define(MAX_WINDOW, 16#7FFFFFFF).

suite() ->
    [{timetrap, {seconds, 60}}].

all() ->
    [{group, h2c}, {group, limits}, {group, tls}, {group, fake}, {group, misc}].

groups() ->
    [
        {h2c, [], [
            unary_ok,
            unary_error_is_trailers_only,
            error_after_messages,
            metadata_both_ways,
            invalid_metadata_raises,
            server_stream,
            client_stream,
            bidi_stream,
            large_messages_both_ways,
            slow_reader,
            compression_both_ways,
            message_size_limits,
            codecs,
            deadline_exceeded,
            cancel,
            not_grpc_status_maps,
            unimplemented,
            concurrent_calls,
            big_metadata_uses_continuation,
            recv_timeout_leaves_the_call,
            answer_racing_a_withdraw,
            caller_death_cancels,
            owner_death_closes,
            close_ends_calls,
            sys_and_stray_messages,
            deadline_timer_stops,
            concurrent_reads_are_busy
        ]},
        {limits, [], [max_concurrent_streams_queue, stream_ids_run_out]},
        {tls, [], [tls_alpn, tls_without_h2]},
        {fake, [], [
            ping,
            settings_and_flow_control,
            responses_gRPC_rejects,
            frames_on_closed_streams,
            stream_window_overrun,
            goaway,
            connection_errors,
            server_closes_mid_call,
            header_list_cap,
            interim_and_status_precedence,
            request_header_order
        ]},
        {misc, [], [options_are_checked, connect_failures, hosts]}
    ].

init_per_group(Group, Config) ->
    [{group, Group} | Config].

end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(tls_without_h2, Config) ->
    start(Config, #{protocols => [http1], tls => roadrunner_test_certs:server_opts()});
init_per_testcase(_Case, Config) ->
    case proplists:get_value(group, Config) of
        h2c ->
            start(Config, #{protocols => [{http2, #{max_header_block => 200_000}}]});
        limits ->
            start(Config, #{protocols => [{http2, #{max_concurrent_streams => 1}}]});
        tls ->
            start(Config, #{protocols => [http2], tls => roadrunner_test_certs:server_opts()});
        _ ->
            Config
    end.

end_per_testcase(_Case, _Config) ->
    case whereis(?LISTENER) of
        undefined -> ok;
        _ -> ok = roadrunner_listener:stop(?LISTENER)
    end.

start(Config, Opts) ->
    {ok, _} = roadrunner_listener:start_link(?LISTENER, Opts#{
        port => 0,
        body_buffering => manual,
        routes => roadrunner_grpc:routes(#{
            services => [service()],
            codecs => [roadrunner_grpc_codec_raw, roadrunner_grpc_test_codec],
            max_message_size => 8_000_000,
            max_content_length => 100_000_000
        })
    }),
    [{port, roadrunner_listener:port(?LISTENER)} | Config].

connect(Config) ->
    connect(Config, #{}).

connect(Config, Opts) ->
    {ok, Conn} = roadrunner_grpc_client:connect(
        {127, 0, 0, 1}, proplists:get_value(port, Config), Opts
    ),
    Conn.

path(Method) ->
    <<?SVC, Method/binary>>.

conn_pid(Conn) ->
    element(2, Conn).

%% A call's error without the `date` header roadrunner adds to a
%% Trailers-Only response.
undated({error, {grpc, Status, Message, Trailers}}) ->
    {error, {grpc, Status, Message, lists:keydelete(~"date", 1, Trailers)}}.

%% =============================================================================
%% The service
%% =============================================================================

service() ->
    #{
        name => ~"test.Client",
        module => ?MODULE,
        rpcs => #{
            ~"Echo" => rpc(echo, unary),
            ~"Fail" => rpc(fail, unary),
            ~"FailAfter" => rpc(fail_after, server_stream),
            ~"Meta" => rpc(meta, unary),
            ~"Count" => rpc(count, server_stream),
            ~"Sum" => rpc(sum, client_stream),
            ~"Chat" => rpc(chat, bidi_stream),
            ~"Squeeze" => rpc(squeeze, unary),
            ~"Compressed" => rpc(compressed, client_stream),
            ~"Watch" => rpc(watch, server_stream),
            ~"Hold" => rpc(hold, unary),
            ~"Stop" => rpc(stop, unary)
        }
    }.

rpc(Function, Kind) ->
    #{function => Function, kind => Kind, input => in, output => out}.

echo(Request, Stream) ->
    {reply, Request, Stream}.

fail(_Request, Stream) ->
    Stream1 = roadrunner_grpc:set_trailers([{~"x-tail", ~"t"}, {~"x-tail-bin", <<0, 1>>}], Stream),
    {error, not_found, ~"no such thing: café 100%", Stream1}.

fail_after(_Request, Stream) ->
    Stream1 = roadrunner_grpc:send(~"first", Stream),
    {error, aborted, ~"stopped", roadrunner_grpc:set_trailers([{~"x-tail", ~"t"}], Stream1)}.

meta(_Request, Stream) ->
    Stream1 = roadrunner_grpc:set_headers([{~"x-head", ~"h"}, {~"x-head-bin", <<0, 255>>}], Stream),
    Stream2 = roadrunner_grpc:set_trailers([{~"x-tail", ~"t"}], Stream1),
    {reply, term_to_binary(roadrunner_grpc:metadata(Stream)), Stream2}.

%% `<<N:32, Size:32>>`: N messages of Size bytes.
count(<<N:32, Size:32>>, Stream) ->
    {ok,
        lists:foldl(
            fun(I, S) -> roadrunner_grpc:send(binary:copy(<<I>>, Size), S) end,
            Stream,
            lists:seq(1, N)
        )}.

%% The size and CRC of all the requests together.
sum(Stream) ->
    sum(Stream, []).

sum(Stream, Acc) ->
    case roadrunner_grpc:recv(Stream) of
        {ok, M, Stream1} ->
            sum(Stream1, [Acc, M]);
        {eof, Stream1} ->
            All = iolist_to_binary(Acc),
            {reply, <<(byte_size(All)):64, (erlang:crc32(All)):32>>, Stream1}
    end.

chat(Stream) ->
    case roadrunner_grpc:recv(Stream) of
        {ok, M, Stream1} -> chat(roadrunner_grpc:send(M, Stream1));
        {eof, Stream1} -> {ok, Stream1}
    end.

%% The request back, compressed as the `x-encoding` metadata says.
squeeze(Request, Stream) ->
    {_, Name} = lists:keyfind(~"x-encoding", 1, roadrunner_grpc:metadata(Stream)),
    {reply, Request, roadrunner_grpc:set_send_compression(binary_to_atom(Name), Stream)}.

%% Whether each request came compressed.
compressed(Stream) ->
    compressed(Stream, []).

compressed(Stream, Acc) ->
    case roadrunner_grpc:recv(Stream) of
        {ok, _M, Stream1} ->
            compressed(Stream1, [Acc, atom_to_binary(roadrunner_grpc:recv_compressed(Stream1)), $,]);
        {eof, Stream1} ->
            {reply, iolist_to_binary(Acc), Stream1}
    end.

%% Tells the watcher it runs, then waits until the call is cancelled and
%% tells that too.
watch(_Request, Stream) ->
    ?WATCHER ! {watching, self()},
    watching(Stream).

watching(Stream) ->
    receive
        Message ->
            case roadrunner_grpc:cancelled(Message, Stream) of
                true ->
                    ?WATCHER ! {cancelled, self()},
                    {ok, Stream};
                false ->
                    watching(Stream)
            end
    end.

%% Waits for `go` before it answers.
hold(Request, Stream) ->
    ?WATCHER ! {held, self()},
    receive
        go -> {reply, Request, Stream}
    end.

stop(_Request, _Stream) ->
    exit({shutdown, stopped}).

%% =============================================================================
%% The client codec
%% =============================================================================

subtype() -> ~"proto".
encode(_Type, Message) -> Message.
decode(_Type, ~"bad") -> error(bad);
decode(_Type, Bytes) -> Bytes.

%% =============================================================================
%% h2c against roadrunner
%% =============================================================================

unary_ok(Config) ->
    Conn = connect(Config),
    {ok, ~"hi", #{headers := Headers, trailers := Trailers}} =
        roadrunner_grpc_client:unary(Conn, path(~"Echo"), ~"hi"),
    ?assertNot(lists:keymember(~"content-type", 1, Headers)),
    ?assertNot(lists:keymember(~"grpc-status", 1, Trailers)),
    ok = roadrunner_grpc_client:close(Conn).

unary_error_is_trailers_only(Config) ->
    Conn = connect(Config),
    Expected =
        {error,
            {grpc, not_found, ~"no such thing: café 100%", [
                {~"x-tail", ~"t"}, {~"x-tail-bin", <<0, 1>>}
            ]}},
    ?assertEqual(Expected, undated(roadrunner_grpc_client:unary(Conn, path(~"Fail"), ~"x"))),
    {ok, S} = roadrunner_grpc_client:stream(Conn, path(~"Fail")),
    ok = roadrunner_grpc_client:send(S, ~"x"),
    ok = roadrunner_grpc_client:close_send(S),
    ?assertEqual({ok, []}, roadrunner_grpc_client:headers(S)),
    ?assertEqual(Expected, undated(roadrunner_grpc_client:recv(S))),
    ?assertEqual({error, closed}, roadrunner_grpc_client:recv(S)),
    ?assertEqual({error, closed}, roadrunner_grpc_client:send(S, ~"late")).

error_after_messages(Config) ->
    Conn = connect(Config),
    {ok, S} = roadrunner_grpc_client:stream(Conn, path(~"FailAfter"), #{}),
    ok = roadrunner_grpc_client:send(S, ~"x"),
    ok = roadrunner_grpc_client:close_send(S),
    ?assertEqual({error, closed}, roadrunner_grpc_client:close_send(S)),
    ?assertEqual({ok, ~"first"}, roadrunner_grpc_client:recv(S)),
    ?assertEqual(
        {error, {grpc, aborted, ~"stopped", [{~"x-tail", ~"t"}]}},
        undated(roadrunner_grpc_client:recv(S))
    ).

metadata_both_ways(Config) ->
    Conn = connect(Config),
    {ok, Reply, #{headers := Headers, trailers := Trailers}} = roadrunner_grpc_client:unary(
        Conn,
        path(~"Meta"),
        ~"",
        #{
            metadata => [
                {~"x-plain", ~"a b, c"},
                {~"x-raw-bin", <<0, 1, 2, $,>>},
                {~"x.ok_9-z", ~""}
            ]
        }
    ),
    Seen = binary_to_term(Reply),
    ?assertEqual(~"a b, c", proplists:get_value(~"x-plain", Seen)),
    ?assertEqual(<<0, 1, 2, $,>>, proplists:get_value(~"x-raw-bin", Seen)),
    ?assertEqual(~"", proplists:get_value(~"x.ok_9-z", Seen)),
    ?assertEqual(~"h", proplists:get_value(~"x-head", Headers)),
    ?assertEqual(<<0, 255>>, proplists:get_value(~"x-head-bin", Headers)),
    ?assertEqual([{~"x-tail", ~"t"}], Trailers).

invalid_metadata_raises(Config) ->
    Conn = connect(Config),
    lists:foreach(
        fun({Name, Value}) ->
            ?assertError(
                {invalid_metadata, Name},
                roadrunner_grpc_client:unary(Conn, path(~"Echo"), ~"", #{
                    metadata => [{Name, Value}]
                })
            )
        end,
        [
            {~"X-Up", ~"v"},
            {~"", ~"v"},
            {~"x a", ~"v"},
            {~"grpc-status", ~"0"},
            {~"user-agent", ~"me"},
            {~"x-a", ~" v"},
            {~"x-a", ~"v "},
            {~"x-a", ~"a\r\nb"},
            {~"connection", ~"close"},
            {~"keep-alive", ~"1"},
            {~"proxy-connection", ~"x"},
            {~"transfer-encoding", ~"chunked"},
            {~"upgrade", ~"h2c"},
            {~"x-a", <<"caf", 16#C3, 16#A9>>}
        ]
    ).

server_stream(Config) ->
    Conn = connect(Config),
    {ok, S} = roadrunner_grpc_client:stream(Conn, path(~"Count")),
    ok = roadrunner_grpc_client:send(S, <<3:32, 2:32>>),
    ok = roadrunner_grpc_client:close_send(S),
    ?assertEqual({ok, <<1, 1>>}, roadrunner_grpc_client:recv(S)),
    ?assertEqual({ok, <<2, 2>>}, roadrunner_grpc_client:recv(S, 5000)),
    ?assertEqual({ok, <<3, 3>>}, roadrunner_grpc_client:recv(S)),
    ?assertEqual({eof, []}, roadrunner_grpc_client:recv(S)).

client_stream(Config) ->
    Conn = connect(Config),
    {ok, S} = roadrunner_grpc_client:stream(Conn, path(~"Sum")),
    Parts = [~"a", ~"bc", ~"def"],
    lists:foreach(fun(P) -> ok = roadrunner_grpc_client:send(S, P) end, Parts),
    ok = roadrunner_grpc_client:close_send(S),
    All = iolist_to_binary(Parts),
    ?assertEqual({ok, <<6:64, (erlang:crc32(All)):32>>}, roadrunner_grpc_client:recv(S)),
    ?assertEqual({eof, []}, roadrunner_grpc_client:recv(S)).

%% Each request is answered before the next one goes out.
bidi_stream(Config) ->
    Conn = connect(Config),
    {ok, S} = roadrunner_grpc_client:stream(Conn, path(~"Chat"), #{timeout => 10_000}),
    lists:foreach(
        fun(M) ->
            ok = roadrunner_grpc_client:send(S, M),
            ?assertEqual({ok, M}, roadrunner_grpc_client:recv(S, 5000))
        end,
        [~"ping", ~"pong", ~"again"]
    ),
    {ok, [{~"date", _}]} = roadrunner_grpc_client:headers(S, 1000),
    ok = roadrunner_grpc_client:close_send(S),
    ?assertEqual({eof, []}, roadrunner_grpc_client:recv(S)).

%% Messages much larger than the HTTP/2 windows (64 KiB by default, 1 MiB
%% for the client's streams) go out and come back over many DATA frames.
large_messages_both_ways(Config) ->
    Conn = connect(Config),
    Big = crypto:strong_rand_bytes(3_000_000),
    ?assertMatch({ok, Big, _}, roadrunner_grpc_client:unary(Conn, path(~"Echo"), Big)),
    {ok, S} = roadrunner_grpc_client:stream(Conn, path(~"Sum")),
    ok = roadrunner_grpc_client:send(S, Big),
    ok = roadrunner_grpc_client:send(S, Big),
    ok = roadrunner_grpc_client:close_send(S),
    Both = <<Big/binary, Big/binary>>,
    ?assertEqual({ok, <<6_000_000:64, (erlang:crc32(Both)):32>>}, roadrunner_grpc_client:recv(S)).

%% The server sends far more than the client's stream window while the
%% client reads one message at a time: the server waits for the window the
%% client gives back as it reads, and every message arrives whole.
slow_reader(Config) ->
    Conn = connect(Config),
    {ok, S} = roadrunner_grpc_client:stream(Conn, path(~"Count")),
    ok = roadrunner_grpc_client:send(S, <<40:32, 200_000:32>>),
    ok = roadrunner_grpc_client:close_send(S),
    lists:foreach(
        fun(I) ->
            ?assertEqual({ok, binary:copy(<<I>>, 200_000)}, roadrunner_grpc_client:recv(S))
        end,
        lists:seq(1, 40)
    ),
    ?assertEqual({eof, []}, roadrunner_grpc_client:recv(S)).

compression_both_ways(Config) ->
    Conn = connect(Config, #{compression => gzip}),
    Payload = binary:copy(~"squeeze me ", 100),
    %% Requests go compressed as the connection, or the call, says, and one
    %% message can opt out.
    {ok, S} = roadrunner_grpc_client:stream(Conn, path(~"Compressed")),
    ok = roadrunner_grpc_client:send(S, Payload),
    ok = roadrunner_grpc_client:send(S, Payload, #{compress => false}),
    ok = roadrunner_grpc_client:close_send(S),
    ?assertEqual({ok, ~"true,false,"}, roadrunner_grpc_client:recv(S)),
    {ok, S2} = roadrunner_grpc_client:stream(Conn, path(~"Compressed"), #{compression => identity}),
    ok = roadrunner_grpc_client:send(S2, Payload),
    ok = roadrunner_grpc_client:close_send(S2),
    ?assertEqual({ok, ~"false,"}, roadrunner_grpc_client:recv(S2)),
    {ok, S3} = roadrunner_grpc_client:stream(Conn, path(~"Compressed"), #{compression => deflate}),
    ok = roadrunner_grpc_client:send(S3, Payload),
    ok = roadrunner_grpc_client:close_send(S3),
    ?assertEqual({ok, ~"true,"}, roadrunner_grpc_client:recv(S3)),
    %% Responses the server compresses are read, either encoding.
    lists:foreach(
        fun(Encoding) ->
            ?assertMatch(
                {ok, Payload, _},
                roadrunner_grpc_client:unary(Conn, path(~"Squeeze"), Payload, #{
                    metadata => [{~"x-encoding", Encoding}]
                })
            )
        end,
        [~"gzip", ~"deflate"]
    ).

%% `max_message_size` bounds a response message as it arrives and after it
%% is decompressed.
message_size_limits(Config) ->
    Conn = connect(Config, #{max_message_size => 100}),
    Payload = binary:copy(~"a", 1000),
    ?assertMatch(
        {error, {grpc, resource_exhausted, _, []}},
        roadrunner_grpc_client:unary(Conn, path(~"Echo"), Payload)
    ),
    ?assertMatch(
        {error, {grpc, resource_exhausted, _, []}},
        roadrunner_grpc_client:unary(Conn, path(~"Squeeze"), Payload, #{
            metadata => [{~"x-encoding", ~"gzip"}]
        })
    ),
    ?assertMatch({ok, ~"small", _}, roadrunner_grpc_client:unary(Conn, path(~"Echo"), ~"small")).

%% The codec picks the content type and turns messages into bytes and back;
%% a reply it cannot decode ends the call INTERNAL.
codecs(Config) ->
    Conn = connect(Config, #{codec => roadrunner_grpc_test_codec}),
    ?assertMatch({ok, {a, 1}, _}, roadrunner_grpc_client:unary(Conn, path(~"Echo"), {a, 1})),
    ?assertMatch(
        {ok, ~"raw", _},
        roadrunner_grpc_client:unary(Conn, path(~"Echo"), ~"raw", #{
            codec => roadrunner_grpc_codec_raw, input => in, output => out
        })
    ),
    ?assertEqual(
        {error, {grpc, internal, ~"message does not decode", []}},
        roadrunner_grpc_client:unary(Conn, path(~"Echo"), ~"bad", #{codec => ?MODULE})
    ).

deadline_exceeded(Config) ->
    true = register(?WATCHER, self()),
    Conn = connect(Config),
    %% A deadline that passes after its call ended does nothing; one too
    %% long for milliseconds goes out in seconds.
    {ok, Done} = roadrunner_grpc_client:stream(Conn, path(~"Echo"), #{timeout => 20}),
    ok = roadrunner_grpc_client:send(Done, ~"x"),
    ok = roadrunner_grpc_client:close_send(Done),
    {ok, ~"x"} = roadrunner_grpc_client:recv(Done),
    ?assertMatch(
        {ok, ~"y", _},
        roadrunner_grpc_client:unary(Conn, path(~"Echo"), ~"y", #{timeout => 200_000_000})
    ),
    %% The call's deadline ends it on the client, and the server learns the
    %% call is over.
    ?assertMatch(
        {error, {grpc, deadline_exceeded, _, []}},
        roadrunner_grpc_client:unary(Conn, path(~"Watch"), ~"", #{timeout => 100})
    ),
    receive
        {cancelled, _} -> ok
    end,
    %% The first call ended before its deadline, which then did nothing.
    {eof, []} = roadrunner_grpc_client:recv(Done).

cancel(Config) ->
    true = register(?WATCHER, self()),
    Conn = connect(Config),
    {ok, S} = roadrunner_grpc_client:stream(Conn, path(~"Watch")),
    ok = roadrunner_grpc_client:send(S, ~""),
    ok = roadrunner_grpc_client:close_send(S),
    receive
        {watching, _} -> ok
    end,
    ok = roadrunner_grpc_client:cancel(S),
    receive
        {cancelled, _} -> ok
    end,
    ?assertEqual({error, closed}, roadrunner_grpc_client:recv(S)),
    ok = roadrunner_grpc_client:cancel(S),
    %% A call ended but not read to its end is cancelled too.
    {ok, S2} = roadrunner_grpc_client:stream(Conn, path(~"Count")),
    ok = roadrunner_grpc_client:send(S2, <<2:32, 1:32>>),
    ok = roadrunner_grpc_client:close_send(S2),
    {ok, <<1>>} = roadrunner_grpc_client:recv(S2),
    {ok, <<2>>} = roadrunner_grpc_client:recv(S2),
    ok = roadrunner_grpc_client:cancel(S2),
    ?assertEqual({error, closed}, roadrunner_grpc_client:recv(S2)).

%% A method that stops on purpose: roadrunner answers 500, which gRPC
%% reads as UNKNOWN.
not_grpc_status_maps(Config) ->
    Conn = connect(Config),
    ?assertEqual(
        {error, {grpc, unknown, ~"HTTP status 500", []}},
        roadrunner_grpc_client:unary(Conn, path(~"Stop"), ~"")
    ).

unimplemented(Config) ->
    Conn = connect(Config),
    ?assertMatch(
        {error, {grpc, unimplemented, _, _}},
        roadrunner_grpc_client:unary(Conn, path(~"Nope"), ~"")
    ),
    ?assertMatch(
        {error, {grpc, unimplemented, ~"HTTP status 404", []}},
        roadrunner_grpc_client:unary(Conn, ~"/no.Such/Thing", ~"")
    ).

concurrent_calls(Config) ->
    Conn = connect(Config),
    Self = self(),
    Pids = [
        spawn_link(fun() ->
            Message = integer_to_binary(I),
            Self ! {self(), roadrunner_grpc_client:unary(Conn, path(~"Echo"), Message)}
        end)
     || I <- lists:seq(1, 30)
    ],
    lists:foreach(
        fun({I, Pid}) ->
            Message = integer_to_binary(I),
            receive
                {Pid, Result} -> ?assertMatch({ok, Message, _}, Result)
            end
        end,
        lists:zip(lists:seq(1, 30), Pids)
    ).

%% A header block larger than the server's SETTINGS_MAX_FRAME_SIZE goes
%% out as HEADERS and CONTINUATION frames.
big_metadata_uses_continuation(Config) ->
    Conn = connect(Config),
    Value = binary:copy(~"v", 40_000),
    {ok, Reply, _} = roadrunner_grpc_client:unary(Conn, path(~"Meta"), ~"", #{
        metadata => [{~"x-big", Value}]
    }),
    ?assertEqual(Value, proplists:get_value(~"x-big", binary_to_term(Reply))).

%% A read that times out leaves the call running.
recv_timeout_leaves_the_call(Config) ->
    true = register(?WATCHER, self()),
    Conn = connect(Config),
    {ok, S} = roadrunner_grpc_client:stream(Conn, path(~"Chat")),
    ?assertEqual({error, timeout}, roadrunner_grpc_client:recv(S, 10)),
    ?assertEqual({error, timeout}, roadrunner_grpc_client:headers(S, 0)),
    ok = roadrunner_grpc_client:send(S, ~"late"),
    ?assertEqual({ok, ~"late"}, roadrunner_grpc_client:recv(S, 5000)),
    ok = roadrunner_grpc_client:close_send(S),
    ?assertEqual({eof, []}, roadrunner_grpc_client:recv(S)).

%% A read whose answer goes out before its wait is withdrawn still gets
%% the answer: the connection is held while the read asks and gives up.
answer_racing_a_withdraw(Config) ->
    Conn = connect(Config),
    {ok, S} = roadrunner_grpc_client:stream(Conn, path(~"Chat")),
    ok = roadrunner_grpc_client:send(S, ~"one"),
    Pid = conn_pid(Conn),
    ok = until(fun() -> holding(Pid) end),
    true = erlang:suspend_process(Pid),
    Self = self(),
    _ = spawn_link(fun() -> Self ! {read, roadrunner_grpc_client:recv(S, 0)} end),
    ok = until(fun() -> process_info(Pid, message_queue_len) =:= {message_queue_len, 2} end),
    true = erlang:resume_process(Pid),
    receive
        {read, Read} -> ?assertEqual({ok, ~"one"}, Read)
    end,
    ok = roadrunner_grpc_client:close_send(S),
    ?assertEqual({eof, []}, roadrunner_grpc_client:recv(S)).

%% The calls of a process that exits are cancelled.
caller_death_cancels(Config) ->
    true = register(?WATCHER, self()),
    Conn = connect(Config),
    {Caller, Mon} = spawn_monitor(fun() ->
        {ok, S} = roadrunner_grpc_client:stream(Conn, path(~"Watch")),
        {ok, S2} = roadrunner_grpc_client:stream(Conn, path(~"Watch")),
        lists:foreach(
            fun(Stream) ->
                ok = roadrunner_grpc_client:send(Stream, ~""),
                ok = roadrunner_grpc_client:close_send(Stream)
            end,
            [S, S2]
        ),
        receive
            stop -> ok
        end
    end),
    [
        receive
            {watching, _} -> ok
        end
     || _ <- [1, 2]
    ],
    Caller ! stop,
    receive
        {'DOWN', Mon, process, Caller, normal} -> ok
    end,
    [
        receive
            {cancelled, _} -> ok
        end
     || _ <- [1, 2]
    ],
    ?assertMatch({ok, ~"alive", _}, roadrunner_grpc_client:unary(Conn, path(~"Echo"), ~"alive")).

%% The connection belongs to the process that opened it.
owner_death_closes(Config) ->
    Self = self(),
    {Owner, OwnerMon} = spawn_monitor(fun() ->
        Self ! {conn, connect(Config)},
        receive
            stop -> ok
        end
    end),
    Conn =
        receive
            {conn, C} -> C
        end,
    Mon = monitor(process, conn_pid(Conn)),
    Owner ! stop,
    receive
        {'DOWN', OwnerMon, process, Owner, normal} -> ok
    end,
    receive
        {'DOWN', Mon, process, _, normal} -> ok
    end,
    ?assertEqual({error, closed}, roadrunner_grpc_client:unary(Conn, path(~"Echo"), ~"x")).

close_ends_calls(Config) ->
    Conn = connect(Config),
    {ok, S} = roadrunner_grpc_client:stream(Conn, path(~"Chat")),
    ok = roadrunner_grpc_client:send(S, ~"x"),
    {ok, ~"x"} = roadrunner_grpc_client:recv(S),
    Self = self(),
    _ = spawn_link(fun() -> Self ! {read, roadrunner_grpc_client:recv(S)} end),
    ok = until(fun() -> reading(conn_pid(Conn)) end),
    ok = roadrunner_grpc_client:close(Conn),
    receive
        {read, Read} -> ?assertEqual({error, closed}, Read)
    end,
    ok = roadrunner_grpc_client:close(Conn),
    ?assertEqual({error, closed}, roadrunner_grpc_client:stream(Conn, path(~"Echo"))).

%% Whether the connection holds a waiting read.
reading(Pid) ->
    lists:any(fun(#stream{waiter = Waiter}) -> Waiter =/= undefined end, streams(Pid)).

%% The connection's calls, from its state.
streams(Pid) ->
    #state{streams = Streams} = sys:get_state(Pid),
    maps:values(Streams).

sys_and_stray_messages(Config) ->
    Conn = connect(Config),
    Pid = conn_pid(Conn),
    ?assertMatch(State when is_tuple(State), sys:get_state(Pid)),
    ?assertEqual({error, not_supported}, gen_server:call(Pid, hello)),
    Pid ! stray,
    Pid ! {tcp_error, self(), econnreset},
    ?assertEqual({error, closed}, roadrunner_grpc_client:unary(Conn, path(~"Echo"), ~"x")).

%% =============================================================================
%% Limits
%% =============================================================================

%% With the server's SETTINGS_MAX_CONCURRENT_STREAMS at 1, a second call
%% waits for the first to end rather than open a stream the server
%% refuses; a waiting call can time out or be cancelled.
max_concurrent_streams_queue(Config) ->
    true = register(?WATCHER, self()),
    Conn = connect(Config),
    Self = self(),
    _ = spawn_link(fun() ->
        Self ! {first, roadrunner_grpc_client:unary(Conn, path(~"Hold"), ~"first")}
    end),
    Method =
        receive
            {held, M} -> M
        end,
    {ok, Waiting} = roadrunner_grpc_client:stream(Conn, path(~"Echo")),
    {ok, Expiring} = roadrunner_grpc_client:stream(Conn, path(~"Echo"), #{timeout => 50}),
    {ok, Cancelled} = roadrunner_grpc_client:stream(Conn, path(~"Echo")),
    ?assertMatch({error, {grpc, deadline_exceeded, _, _}}, roadrunner_grpc_client:recv(Expiring)),
    ok = roadrunner_grpc_client:cancel(Cancelled),
    %% A send on a call still waiting goes out once the call opens.
    _ = spawn_link(fun() ->
        Self ! {sent, roadrunner_grpc_client:send(Waiting, ~"second")}
    end),
    ok = until(fun() -> sending(conn_pid(Conn)) end),
    Method ! go,
    receive
        {first, First} -> ?assertMatch({ok, ~"first", _}, First)
    end,
    receive
        {sent, Sent} -> ?assertEqual(ok, Sent)
    end,
    ok = roadrunner_grpc_client:close_send(Waiting),
    ?assertEqual({ok, ~"second"}, roadrunner_grpc_client:recv(Waiting)).

%% Whether a call holds a message to send.
sending(Pid) ->
    lists:any(fun(#stream{out = Out}) -> not queue:is_empty(Out) end, streams(Pid)).

%% Whether a call holds a message read.
holding(Pid) ->
    lists:any(fun(#stream{msgs = Msgs}) -> not queue:is_empty(Msgs) end, streams(Pid)).

%% Whether a call has ended.
ended(Pid) ->
    lists:any(fun(#stream{final = Final}) -> Final =/= undefined end, streams(Pid)).

%% =============================================================================
%% TLS
%% =============================================================================

tls_alpn(Config) ->
    Conn = connect(Config, #{
        tls => [{verify, verify_none}, {alpn_advertised_protocols, [~"http/1.1"]}]
    }),
    ?assertMatch({ok, ~"secure", _}, roadrunner_grpc_client:unary(Conn, path(~"Echo"), ~"secure")).

%% A TLS server that agrees on no protocol; roadrunner's own answers an
%% ALPN list without `h2` with an alert.
tls_without_h2(Config) ->
    {ok, Listen} = ssl:listen(0, [binary, {active, false} | roadrunner_test_certs:server_opts()]),
    {ok, {_, Port}} = ssl:sockname(Listen),
    _ = spawn_link(fun() ->
        {ok, Tcp} = ssl:transport_accept(Listen),
        {ok, Tls} = ssl:handshake(Tcp),
        {error, closed} = ssl:recv(Tls, 0)
    end),
    ?assertEqual(
        {error, h2_not_negotiated},
        roadrunner_grpc_client:connect({127, 0, 0, 1}, Port, #{tls => [{verify, verify_none}]})
    ),
    ?assertMatch(
        {error, {tls_alert, {no_application_protocol, _}}},
        roadrunner_grpc_client:connect({127, 0, 0, 1}, proplists:get_value(port, Config), #{
            tls => [{verify, verify_none}]
        })
    ).

%% =============================================================================
%% Options, connecting, hosts
%% =============================================================================

options_are_checked(_Config) ->
    lists:foreach(
        fun({Opts, Error}) ->
            ?assertError(Error, roadrunner_grpc_client:connect("localhost", 1, Opts))
        end,
        [
            {#{nope => 1}, {unknown_grpc_opt, nope}},
            {#{tls => x}, {invalid_grpc_opt, tls, x}},
            {#{codec => "x"}, {invalid_grpc_opt, codec, "x"}},
            {#{compression => zstd}, {invalid_grpc_opt, compression, zstd}},
            {#{max_message_size => -1}, {invalid_grpc_opt, max_message_size, -1}},
            {#{connect_timeout => -1}, {invalid_grpc_opt, connect_timeout, -1}},
            {#{authority => "x"}, {invalid_grpc_opt, authority, "x"}}
        ]
    ),
    Port = fake(fun serve/1),
    {ok, Conn} = roadrunner_grpc_client:connect({127, 0, 0, 1}, Port, #{}),
    lists:foreach(
        fun({Opts, Error}) ->
            ?assertError(Error, roadrunner_grpc_client:unary(Conn, ~"/t/Ok", ~"", Opts))
        end,
        [
            {#{nope => 1}, {unknown_grpc_opt, nope}},
            {#{metadata => x}, {invalid_grpc_opt, metadata, x}},
            {#{timeout => 16#100000000}, {invalid_grpc_opt, timeout, 16#100000000}},
            {#{compression => x}, {invalid_grpc_opt, compression, x}},
            {#{codec => 1}, {invalid_grpc_opt, codec, 1}}
        ]
    ),
    {ok, S} = roadrunner_grpc_client:stream(Conn, ~"/t/Ok", #{}),
    ?assertError({unknown_grpc_opt, nope}, roadrunner_grpc_client:send(S, ~"", #{nope => 1})),
    ?assertError(
        {invalid_grpc_opt, compress, 1}, roadrunner_grpc_client:send(S, ~"", #{compress => 1})
    ).

connect_failures(_Config) ->
    {ok, Closed} = gen_tcp:listen(0, [binary, {active, false}]),
    {ok, ClosedPort} = inet:port(Closed),
    ok = gen_tcp:close(Closed),
    ?assertEqual(
        {error, econnrefused}, roadrunner_grpc_client:connect({127, 0, 0, 1}, ClosedPort, #{})
    ),
    ?assertMatch(
        {error, _},
        roadrunner_grpc_client:connect({127, 0, 0, 1}, ClosedPort, #{tls => [{verify, verify_none}]})
    ),
    %% No SETTINGS in time.
    Silent = fake(fun(P) -> drain(P) end, none),
    ?assertEqual(
        {error, timeout},
        roadrunner_grpc_client:connect({127, 0, 0, 1}, Silent, #{connect_timeout => 100})
    ),
    %% The server goes away before its SETTINGS.
    Gone = fake(fun(#{sock := Sock}) -> ok = gen_tcp:close(Sock) end, none),
    ?assertEqual({error, closed}, roadrunner_grpc_client:connect({127, 0, 0, 1}, Gone, #{})),
    %% Something other than SETTINGS first.
    Self = self(),
    Pinged = fake(
        fun(P) ->
            ok = send(P, {ping, 0, ~"12345678"}),
            {{goaway, 0, Code, _}, _} = until_frame(P, goaway),
            Self ! {goaway, Code}
        end,
        none
    ),
    ?assertEqual(
        {error, {connection_error, protocol_error}},
        roadrunner_grpc_client:connect({127, 0, 0, 1}, Pinged, #{})
    ),
    receive
        {goaway, protocol_error} -> ok
    end.

%% The `:authority` names the host as given, an IPv6 address in brackets,
%% unless the `authority` option names another.
hosts(_Config) ->
    lists:foreach(
        fun({Host, Expected}) ->
            Port = fake(fun serve/1),
            {ok, Conn} = roadrunner_grpc_client:connect(Host, Port, #{}),
            Authority = <<Expected/binary, ":", (integer_to_binary(Port))/binary>>,
            ?assertMatch(
                {ok, Authority, _}, roadrunner_grpc_client:unary(Conn, ~"/t/Authority", ~"")
            )
        end,
        [
            {~"localhost", ~"localhost"},
            {"localhost", ~"localhost"},
            {localhost, ~"localhost"},
            {{127, 0, 0, 1}, ~"127.0.0.1"}
        ]
    ),
    Port = fake(fun serve/1),
    {ok, Conn} = roadrunner_grpc_client:connect({127, 0, 0, 1}, Port, #{
        authority => ~"api.example:1"
    }),
    ?assertMatch(
        {ok, ~"api.example:1", _}, roadrunner_grpc_client:unary(Conn, ~"/t/Authority", ~"")
    ),
    ?assertMatch({error, _}, roadrunner_grpc_client:connect({0, 0, 0, 0, 0, 0, 0, 1}, 1, #{})).

%% =============================================================================
%% A scripted HTTP/2 server
%% =============================================================================

ping(_Config) ->
    Self = self(),
    Port = fake(fun(P) ->
        ok = send(P, {ping, 0, ~"12345678"}),
        {{ping, 1, Data}, P1} = until_frame(P, ping),
        Self ! {pong, Data},
        %% The answer to a PING of the client's own is ignored.
        ok = send(P1, {ping, 1, ~"87654321"}),
        serve(P1)
    end),
    {ok, Conn} = roadrunner_grpc_client:connect({127, 0, 0, 1}, Port, #{}),
    receive
        {pong, Data} -> ?assertEqual(~"12345678", Data)
    end,
    ?assertMatch({ok, ~"pong", _}, roadrunner_grpc_client:unary(Conn, ~"/t/Ok", ~"ping")).

%% The server's settings shape what the client sends: a 10-byte initial
%% window, raised by a later SETTINGS and by WINDOW_UPDATE frames, holds
%% the request back until there is room; a dynamic table the server shrank
%% is announced; and a send held back fails when its call ends.
settings_and_flow_control(_Config) ->
    Self = self(),
    Settings = [{1, 4096}, {1, 0}, {3, 10}, {4, 10}, {5, 16_384}, {16#99, 1}],
    Port = fake(
        fun(P) ->
            {{settings, 0, _}, P0} = until_frame(P, settings),
            {{settings, 1, []}, P1} = until_frame(P0, settings),
            Self ! acked,
            {{headers, Id, _, Fields}, P2} = until_frame(P1, headers),
            ~"/t/Ok" = proplists:get_value(~":path", Fields),
            {{data, Id, 0, First, _}, P3} = until_frame(P2, data),
            10 = byte_size(First),
            ok = send(P3, {settings, 0, [{4, 20}]}),
            {{data, Id, 0, Second, _}, P4} = until_frame(P3, data),
            10 = byte_size(Second),
            ok = send(P4, {window_update, 0, 1000}),
            ok = send(P4, {window_update, Id, 1000}),
            {{data, Id, 1, Last, _}, P5} = until_frame(P4, data),
            Request = <<First/binary, Second/binary, Last/binary>>,
            {ok, false, ~"twenty-bytes-request", <<>>} = roadrunner_grpc_frame:decode(Request, 100),
            P6 = respond(P5, Id, ~"done"),
            %% A second call: its send waits for window, then the server
            %% resets it.
            {{headers, Id2, _, _}, P7} = until_frame(P6, headers),
            {{data, Id2, 0, _, _}, P8} = until_frame(P7, data),
            Self ! {held, Id2},
            receive
                reset -> ok
            end,
            ok = send(P8, {rst_stream, Id2, cancel}),
            drain(P8)
        end,
        Settings
    ),
    {ok, Conn} = roadrunner_grpc_client:connect({127, 0, 0, 1}, Port, #{}),
    receive
        acked -> ok
    end,
    ?assertMatch(
        {ok, ~"done", _}, roadrunner_grpc_client:unary(Conn, ~"/t/Ok", ~"twenty-bytes-request")
    ),
    {ok, S} = roadrunner_grpc_client:stream(Conn, ~"/t/Hang"),
    _ = spawn_link(fun() ->
        Self ! {sent, roadrunner_grpc_client:send(S, binary:copy(~"x", 100))}
    end),
    receive
        {held, _} -> ok
    end,
    ok = until(fun() -> sending(conn_pid(Conn)) end),
    whereis_fake() ! reset,
    receive
        {sent, Sent} -> ?assertEqual({error, closed}, Sent)
    end,
    ?assertEqual({error, {reset, cancel}}, roadrunner_grpc_client:recv(S)).

%% Responses that are not proper gRPC end their calls with the status gRPC
%% gives them.
responses_gRPC_rejects(_Config) ->
    Port = fake(fun serve/1),
    {ok, Conn} = roadrunner_grpc_client:connect({127, 0, 0, 1}, Port, #{}),
    Unary = fun(Path) -> roadrunner_grpc_client:unary(Conn, Path, ~"") end,
    lists:foreach(
        fun({Code, Status}) ->
            ?assertEqual(
                {error, {grpc, Status, <<"HTTP status ", Code/binary>>, []}},
                Unary(<<"/t/Http/", Code/binary>>)
            )
        end,
        [
            {~"400", internal},
            {~"401", unauthenticated},
            {~"403", permission_denied},
            {~"404", unimplemented},
            {~"429", unavailable},
            {~"502", unavailable},
            {~"503", unavailable},
            {~"504", unavailable},
            {~"500", unknown}
        ]
    ),
    ?assertEqual({error, {grpc, unavailable, ~"HTTP status 503", []}}, Unary(~"/t/HttpOpen")),
    ?assertEqual({error, {grpc, unknown, ~"HTTP status ", []}}, Unary(~"/t/NoStatus")),
    ?assertEqual({error, {grpc, unknown, ~"response is not gRPC", []}}, Unary(~"/t/NotGrpc")),
    ?assertEqual({error, {grpc, unknown, ~"response is not gRPC", []}}, Unary(~"/t/NotGrpcOpen")),
    ?assertEqual({error, {grpc, unknown, ~"", []}}, Unary(~"/t/NoGrpcStatus")),
    lists:foreach(
        fun({Code, Status}) ->
            ?assertEqual({error, {grpc, Status, ~"a b", []}}, Unary(<<"/t/Status/", Code/binary>>))
        end,
        [{~"1", cancelled}, {~"16", unauthenticated}, {~"17", unknown}, {~"x", unknown}]
    ),
    Internal = fun(Message) -> {error, {grpc, internal, Message, []}} end,
    ?assertEqual(Internal(~"malformed binary metadata x-bin"), Unary(~"/t/BadBin")),
    ?assertEqual(Internal(~"malformed binary metadata x-bin"), Unary(~"/t/BadBinTrailer")),
    ?assertEqual(Internal(~"DATA before the response headers"), Unary(~"/t/DataFirst")),
    ?assertEqual(Internal(~"trailers that do not end the stream"), Unary(~"/t/OpenTrailers")),
    ?assertEqual(Internal(~"stream ended without a status"), Unary(~"/t/NoTrailers")),
    ?assertEqual(Internal(~"stream ended in the middle of a message"), Unary(~"/t/CutShort")),
    ?assertEqual(Internal(~"bad Compressed-Flag"), Unary(~"/t/BadFlag")),
    ?assertEqual(
        Internal(~"compressed message without a supported grpc-encoding"), Unary(~"/t/NoEncoding")
    ),
    ?assertEqual(Internal(~"message does not decompress"), Unary(~"/t/BadGzip")),
    ?assertEqual(
        Internal(~"more than one response message for a unary call"), Unary(~"/t/Two")
    ),
    ?assertEqual(
        {error, {grpc, internal, ~"no response message for a unary call", [{~"x-t", ~"t"}]}},
        Unary(~"/t/None")
    ),
    ?assertEqual(Internal(~"stream send window past its limit"), Unary(~"/t/WindowOverflow")),
    ?assertEqual({error, {reset, refused_stream}}, Unary(~"/t/Reset")),
    %% Header blocks over CONTINUATION frames; and a server that ends the
    %% call while the client still sends.
    {ok, S} = roadrunner_grpc_client:stream(Conn, ~"/t/Continuation"),
    ?assertEqual({ok, [{~"x-h", ~"h"}]}, roadrunner_grpc_client:headers(S)),
    ?assertEqual({ok, ~"pong"}, roadrunner_grpc_client:recv(S)),
    ?assertEqual({eof, [{~"x-t", ~"t"}]}, roadrunner_grpc_client:recv(S)),
    %% Trailers-Only with OK.
    {ok, Empty} = roadrunner_grpc_client:stream(Conn, ~"/t/Empty"),
    ?assertEqual({ok, []}, roadrunner_grpc_client:headers(Empty)),
    ?assertEqual({eof, []}, roadrunner_grpc_client:recv(Empty)).

%% Frames on a stream that ended, a PRIORITY frame and a frame of an unknown
%% type are ignored; the connection goes on.
frames_on_closed_streams(_Config) ->
    Port = fake(fun serve/1),
    {ok, Conn} = roadrunner_grpc_client:connect({127, 0, 0, 1}, Port, #{}),
    ?assertMatch({ok, ~"pong", _}, roadrunner_grpc_client:unary(Conn, ~"/t/Closed", ~"")),
    ?assertMatch({ok, ~"pong", _}, roadrunner_grpc_client:unary(Conn, ~"/t/Ok", ~"")).

%% A server that sends past the stream window the client gave it.
stream_window_overrun(_Config) ->
    Port = fake(fun serve/1),
    {ok, Conn} = roadrunner_grpc_client:connect({127, 0, 0, 1}, Port, #{}),
    {ok, S} = roadrunner_grpc_client:stream(Conn, ~"/t/Flood"),
    ok = roadrunner_grpc_client:close_send(S),
    %% Nothing is read until the server overran the window.
    ok = until(fun() -> ended(conn_pid(Conn)) end),
    Messages = read_all(S),
    ?assertEqual(64, length([M || {ok, M} <- Messages])),
    ?assertEqual(
        {error, {grpc, internal, ~"DATA past the stream window", []}}, lists:last(Messages)
    ).

read_all(S) ->
    case roadrunner_grpc_client:recv(S) of
        {ok, _} = Message -> [Message | read_all(S)];
        End -> [End]
    end.

%% GOAWAY: the calls above the last stream the server took, and the ones
%% waiting for a slot, end with `{goaway, Code}`; the others run to their
%% end, then the client closes the connection.
goaway(_Config) ->
    Self = self(),
    Port = fake(
        fun(P0) ->
            {{headers, 1, _, _}, P1} = until_frame(P0, headers),
            {{headers, 3, _, _}, P2} = until_frame(P1, headers),
            ok = send(P2, {goaway, 1, no_error, <<>>}),
            receive
                answer -> ok
            end,
            P3 = respond(P2, 1, ~"pong"),
            closed = drain(P3),
            Self ! fake_closed
        end,
        [{3, 2}]
    ),
    {ok, Conn} = roadrunner_grpc_client:connect({127, 0, 0, 1}, Port, #{}),
    Mon = monitor(process, conn_pid(Conn)),
    {ok, S1} = roadrunner_grpc_client:stream(Conn, ~"/t/Hang"),
    {ok, S3} = roadrunner_grpc_client:stream(Conn, ~"/t/Hang"),
    {ok, S5} = roadrunner_grpc_client:stream(Conn, ~"/t/Hang"),
    ?assertEqual({error, {goaway, no_error}}, roadrunner_grpc_client:recv(S3)),
    ?assertEqual({error, {goaway, no_error}}, roadrunner_grpc_client:headers(S5)),
    ?assertEqual({error, {goaway, no_error}}, roadrunner_grpc_client:recv(S5)),
    ?assertEqual({error, {goaway, no_error}}, roadrunner_grpc_client:stream(Conn, ~"/t/Ok")),
    whereis_fake() ! answer,
    ?assertEqual({ok, ~"pong"}, roadrunner_grpc_client:recv(S1)),
    receive
        fake_closed -> ok
    end,
    ?assertEqual({eof, [{~"x-t", ~"t"}]}, roadrunner_grpc_client:recv(S1)),
    receive
        {'DOWN', Mon, process, _, normal} -> ok
    end.

%% A server that breaks the protocol: the client closes the connection with
%% a GOAWAY that says why, and the calls on it end.
connection_errors(_Config) ->
    Ping = <<7:24, 6, 0, 0:32, "1234567">>,
    BigData = <<20_000:24, 0, 0, 1:32>>,
    Block = fun(Size) -> binary:copy(<<0>>, Size) end,
    Cases = [
        {fun(_Id) -> [BigData] end, frame_size_error},
        {fun(_Id) -> [Ping] end, protocol_error},
        {fun(_Id) -> [{settings, 0, [{2, 1}]}] end, protocol_error},
        {fun(_Id) -> [{settings, 0, [{4, ?MAX_WINDOW + 1}]}] end, flow_control_error},
        {fun(_Id) -> [{settings, 0, [{5, 100}]}] end, protocol_error},
        %% The stream's window is 65,530 once its 5-byte request went out:
        %% raised to the most a window holds, then once more by a larger
        %% initial window.
        {
            fun(Id) ->
                [{window_update, Id, ?MAX_WINDOW - 65_530}, {settings, 0, [{4, 65_536}]}]
            end,
            flow_control_error
        },
        {fun(_Id) -> [{window_update, 0, ?MAX_WINDOW}] end, flow_control_error},
        {fun(Id) -> [{push_promise, Id, 4, 2, <<>>}] end, protocol_error},
        {fun(Id) -> [{continuation, Id, 4, <<>>}] end, protocol_error},
        {
            fun(Id) -> [{headers, Id, 0, undefined, <<>>}, {ping, 0, ~"12345678"}] end,
            protocol_error
        },
        {
            fun(Id) ->
                [
                    {headers, Id, 0, undefined, Block(16_000)}
                    | [{continuation, Id, 0, Block(16_000)} || _ <- lists:seq(1, 8)]
                ]
            end,
            enhance_your_calm
        },
        {
            fun(Id) -> [{headers, Id, 4, undefined, <<16#FF, 16#FF, 16#FF, 16#FF>>}] end,
            compression_error
        },
        {fun(_Id) -> [{headers, 99, 4, undefined, <<16#88>>}] end, protocol_error},
        {fun(_Id) -> [{data, 101, 0, <<>>}] end, protocol_error},
        {fun(_Id) -> [{rst_stream, 103, cancel}] end, protocol_error},
        {fun(_Id) -> [{window_update, 105, 1}] end, protocol_error}
    ],
    lists:foreach(
        fun({N, {Frames, Code}}) -> {N, ok} = {N, connection_error(Frames, Code)} end,
        lists:enumerate(Cases)
    ).

connection_error(Frames, Code) ->
    Self = self(),
    Port = fake(fun(P0) ->
        {{headers, Id, _, _}, P1} = until_frame(P0, headers),
        %% The client may close before the last frames go out.
        lists:foreach(fun(Frame) -> _ = send(P1, Frame) end, Frames(Id)),
        {{goaway, 0, Sent, _}, _} = until_frame(P1, goaway),
        Self ! {goaway, Sent}
    end),
    {ok, Conn} = roadrunner_grpc_client:connect({127, 0, 0, 1}, Port, #{}),
    ?assertEqual(
        {error, {connection_error, Code}}, roadrunner_grpc_client:unary(Conn, ~"/t/Hang", ~"")
    ),
    receive
        {goaway, Sent} -> ?assertEqual(Code, Sent)
    end,
    ok.

%% The server closes the connection: the calls still running end with
%% `closed`, and the ones that ended can still be read to their end.
server_closes_mid_call(_Config) ->
    Self = self(),
    Port = fake(fun(P0) ->
        {{headers, 1, _, _}, P1} = until_frame(P0, headers),
        {{headers, 3, _, _}, P2} = until_frame(P1, headers),
        P3 = respond(P2, 1, ~"pong"),
        receive
            close -> ok
        end,
        ok = gen_tcp:close(maps:get(sock, P3)),
        Self ! fake_closed
    end),
    {ok, Conn} = roadrunner_grpc_client:connect({127, 0, 0, 1}, Port, #{}),
    {ok, Done} = roadrunner_grpc_client:stream(Conn, ~"/t/Hang"),
    {ok, Running} = roadrunner_grpc_client:stream(Conn, ~"/t/Hang"),
    {ok, []} = roadrunner_grpc_client:headers(Done),
    whereis_fake() ! close,
    ?assertEqual({error, closed}, roadrunner_grpc_client:recv(Running)),
    ?assertEqual({error, closed}, roadrunner_grpc_client:stream(Conn, ~"/t/Ok")),
    %% A socket message left over once the socket closed is dropped.
    conn_pid(Conn) ! {tcp_closed, self()},
    ?assertEqual({ok, ~"pong"}, roadrunner_grpc_client:recv(Done)),
    Mon = monitor(process, conn_pid(Conn)),
    ok = roadrunner_grpc_client:close(Conn),
    receive
        {'DOWN', Mon, process, _, _} -> ok
    end.

%% =============================================================================
%% Fake server helpers
%% =============================================================================

fake(Script) ->
    fake(Script, []).

%% Accept one connection on a new port and run `Script` on it in a process
%% registered as the fake, once the client's preface arrived and the
%% server's SETTINGS (`none`: no SETTINGS) went out.
fake(Script, Settings) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(Listen),
    Pid = spawn_link(fun() ->
        {ok, Sock} = gen_tcp:accept(Listen),
        {ok, ?PREFACE} = gen_tcp:recv(Sock, 24),
        P = #{
            sock => Sock,
            buf => <<>>,
            enc => roadrunner_http2_hpack:new_encoder(4096),
            dec => roadrunner_http2_hpack:new_decoder(4096)
        },
        case Settings of
            none -> ok;
            _ -> ok = send(P, {settings, 0, Settings})
        end,
        Script(P)
    end),
    case whereis(roadrunner_grpc_client_SUITE_fake) of
        undefined -> ok;
        _ -> true = unregister(roadrunner_grpc_client_SUITE_fake)
    end,
    true = register(roadrunner_grpc_client_SUITE_fake, Pid),
    Port.

whereis_fake() ->
    whereis(roadrunner_grpc_client_SUITE_fake).

send(#{sock := Sock}, Frame) when is_tuple(Frame) ->
    gen_tcp:send(Sock, roadrunner_http2_frame:encode(Frame));
send(#{sock := Sock}, Bytes) ->
    gen_tcp:send(Sock, Bytes).

%% The next frame from the client, its header block decoded when whole.
next_frame(#{sock := Sock, buf := Buf, dec := Dec} = P) ->
    case roadrunner_http2_frame:parse(Buf, 16_384) of
        {ok, {headers, Id, Flags, _, Block}, Rest} when Flags band 4 =/= 0 ->
            {ok, Fields, Dec1} = roadrunner_http2_hpack:decode(Block, Dec),
            {ok, {headers, Id, Flags, Fields}, P#{buf := Rest, dec := Dec1}};
        {ok, {headers, Id, Flags, _, Block}, Rest} ->
            %% A header block over CONTINUATION frames.
            continued(Id, Flags, Block, P#{buf := Rest});
        {ok, Frame, Rest} ->
            {ok, Frame, P#{buf := Rest}};
        {more, _} ->
            case gen_tcp:recv(Sock, 0, 10_000) of
                {ok, Data} -> next_frame(P#{buf := <<Buf/binary, Data/binary>>});
                {error, _} -> closed
            end
    end.

continued(Id, Flags, Block, P) ->
    {ok, {continuation, Id, More, Fragment}, P1} = next_frame(P),
    case More band 4 of
        0 ->
            continued(Id, Flags, <<Block/binary, Fragment/binary>>, P1);
        _ ->
            #{dec := Dec} = P1,
            {ok, Fields, Dec1} = roadrunner_http2_hpack:decode(
                <<Block/binary, Fragment/binary>>, Dec
            ),
            {ok, {headers, Id, Flags, Fields}, P1#{dec := Dec1}}
    end.

until_frame(P, Type) ->
    {ok, Frame, P1} = next_frame(P),
    case element(1, Frame) of
        Type -> {Frame, P1};
        _ -> until_frame(P1, Type)
    end.

%% Read until the client closes the connection.
drain(P) ->
    case next_frame(P) of
        {ok, _Frame, P1} -> drain(P1);
        closed -> closed
    end.

headers(#{enc := Enc} = P, Id, Fields, Flags) ->
    {Block, Enc1} = roadrunner_http2_hpack:encode(Fields, Enc),
    ok = send(P, {headers, Id, Flags bor 4, undefined, Block}),
    P#{enc := Enc1}.

grpc_headers() ->
    [{~":status", ~"200"}, {~"content-type", ~"application/grpc"}].

message(Message) ->
    iolist_to_binary(roadrunner_grpc_frame:encode(false, Message)).

%% A whole OK answer: headers, one message, trailers.
respond(P, Id, Message) ->
    P1 = headers(P, Id, grpc_headers(), 0),
    ok = send(P1, {data, Id, 0, message(Message)}),
    headers(P1, Id, [{~"grpc-status", ~"0"}, {~"x-t", ~"t"}], 1).

%% Answer each call by its path, until the client closes the connection.
serve(P) ->
    case next_frame(P) of
        {ok, {headers, Id, _, Fields}, P1} ->
            serve(answer(proplists:get_value(~":path", Fields), Id, Fields, P1));
        {ok, _Frame, P1} ->
            serve(P1);
        closed ->
            closed
    end.

answer(~"/t/Ok", Id, _Fields, P) ->
    respond(P, Id, ~"pong");
answer(~"/t/Authority", Id, Fields, P) ->
    respond(P, Id, proplists:get_value(~":authority", Fields));
answer(<<"/t/Http/", Code/binary>>, Id, _Fields, P) ->
    headers(P, Id, [{~":status", Code}], 1);
answer(~"/t/HttpOpen", Id, _Fields, P) ->
    headers(P, Id, [{~":status", ~"503"}], 0);
answer(~"/t/NoStatus", Id, _Fields, P) ->
    headers(P, Id, [{~"content-type", ~"application/grpc"}], 1);
answer(~"/t/NotGrpc", Id, _Fields, P) ->
    headers(P, Id, [{~":status", ~"200"}, {~"content-type", ~"text/html"}], 1);
answer(~"/t/NotGrpcOpen", Id, _Fields, P) ->
    headers(P, Id, [{~":status", ~"200"}], 0);
answer(~"/t/NoGrpcStatus", Id, _Fields, P) ->
    headers(P, Id, grpc_headers(), 1);
answer(<<"/t/Status/", Code/binary>>, Id, _Fields, P) ->
    headers(P, Id, grpc_headers() ++ [{~"grpc-status", Code}, {~"grpc-message", ~"a%20b"}], 1);
answer(~"/t/BadBin", Id, _Fields, P) ->
    headers(P, Id, grpc_headers() ++ [{~"x-bin", ~"!!!"}], 0);
answer(~"/t/BadBinTrailer", Id, _Fields, P) ->
    P1 = headers(P, Id, grpc_headers(), 0),
    headers(P1, Id, [{~"grpc-status", ~"0"}, {~"x-bin", ~"!!!"}], 1);
answer(~"/t/DataFirst", Id, _Fields, P) ->
    ok = send(P, {data, Id, 0, message(~"x")}),
    P;
answer(~"/t/OpenTrailers", Id, _Fields, P) ->
    P1 = headers(P, Id, grpc_headers(), 0),
    headers(P1, Id, [{~"grpc-status", ~"0"}], 0);
answer(~"/t/NoTrailers", Id, _Fields, P) ->
    P1 = headers(P, Id, grpc_headers(), 0),
    ok = send(P1, {data, Id, 1, message(~"x")}),
    P1;
answer(~"/t/CutShort", Id, _Fields, P) ->
    P1 = headers(P, Id, grpc_headers(), 0),
    ok = send(P1, {data, Id, 0, <<0, 10:32, "abc">>}),
    headers(P1, Id, [{~"grpc-status", ~"0"}], 1);
answer(~"/t/BadFlag", Id, _Fields, P) ->
    P1 = headers(P, Id, grpc_headers(), 0),
    ok = send(P1, {data, Id, 0, <<2, 0:32>>}),
    P1;
answer(~"/t/NoEncoding", Id, _Fields, P) ->
    P1 = headers(P, Id, grpc_headers(), 0),
    ok = send(P1, {data, Id, 0, <<1, 1:32, "x">>}),
    headers(P1, Id, [{~"grpc-status", ~"0"}], 1);
answer(~"/t/BadGzip", Id, _Fields, P) ->
    P1 = headers(P, Id, grpc_headers() ++ [{~"grpc-encoding", ~"gzip"}], 0),
    ok = send(P1, {data, Id, 0, <<1, 3:32, "abc">>}),
    headers(P1, Id, [{~"grpc-status", ~"0"}], 1);
answer(~"/t/Two", Id, _Fields, P) ->
    P1 = headers(P, Id, grpc_headers(), 0),
    ok = send(P1, {data, Id, 0, <<(message(~"a"))/binary, (message(~"b"))/binary>>}),
    headers(P1, Id, [{~"grpc-status", ~"0"}], 1);
answer(~"/t/None", Id, _Fields, P) ->
    P1 = headers(P, Id, grpc_headers(), 0),
    headers(P1, Id, [{~"grpc-status", ~"0"}, {~"x-t", ~"t"}], 1);
answer(~"/t/Empty", Id, _Fields, P) ->
    headers(P, Id, grpc_headers() ++ [{~"grpc-status", ~"0"}], 1);
answer(~"/t/Reset", Id, _Fields, P) ->
    ok = send(P, {rst_stream, Id, refused_stream}),
    P;
answer(~"/t/WindowOverflow", Id, _Fields, P) ->
    P1 = headers(P, Id, grpc_headers(), 0),
    ok = send(P1, {window_update, Id, ?MAX_WINDOW}),
    P1;
answer(~"/t/Flood", Id, _Fields, P) ->
    P1 = headers(P, Id, grpc_headers(), 0),
    Chunk = message(binary:copy(~"f", 16_379)),
    lists:foreach(fun(_) -> ok = send(P1, {data, Id, 0, Chunk}) end, lists:seq(1, 64)),
    ok = send(P1, {data, Id, 0, <<0>>}),
    P1;
answer(~"/t/Continuation", Id, _Fields, #{enc := Enc} = P) ->
    {Head, Enc1} = roadrunner_http2_hpack:encode(grpc_headers() ++ [{~"x-h", ~"h"}], Enc),
    <<H1:2/binary, H2:2/binary, H3/binary>> = iolist_to_binary(Head),
    ok = send(P, {headers, Id, 0, undefined, H1}),
    ok = send(P, {continuation, Id, 0, H2}),
    ok = send(P, {continuation, Id, 4, H3}),
    ok = send(P, {data, Id, 0, message(~"pong")}),
    {Tail, Enc2} = roadrunner_http2_hpack:encode([{~"grpc-status", ~"0"}, {~"x-t", ~"t"}], Enc1),
    <<T1:2/binary, T2/binary>> = iolist_to_binary(Tail),
    ok = send(P, {headers, Id, 1, undefined, T1}),
    ok = send(P, {continuation, Id, 4, T2}),
    P#{enc := Enc2};
answer(~"/t/Closed", Id, _Fields, P) ->
    P1 = respond(P, Id, ~"pong"),
    ok = send(P1, {rst_stream, Id, cancel}),
    ok = send(P1, {window_update, Id, 1}),
    ok = send(P1, {data, Id, 0, message(~"late")}),
    P2 = headers(P1, Id, [{~"x-late", ~"1"}], 1),
    ok = send(P2, {priority, Id, #{exclusive => false, stream_dependency => 0, weight => 1}}),
    ok = send(P2, <<0:24, 16#FA, 0, Id:32>>),
    P2;
answer(~"/t/BigHeaders", Id, _Fields, P) ->
    headers(P, Id, grpc_headers() ++ [{~"x-big", binary:copy(~"b", 300)}], 0);
answer(~"/t/BigTrailers", Id, _Fields, P) ->
    P1 = headers(P, Id, grpc_headers(), 0),
    headers(P1, Id, [{~"grpc-status", ~"0"}, {~"x-big", binary:copy(~"b", 300)}], 1);
answer(~"/t/Interim", Id, _Fields, P) ->
    respond(headers(P, Id, [{~":status", ~"100"}], 0), Id, ~"pong");
answer(~"/t/InterimEnd", Id, _Fields, P) ->
    headers(P, Id, [{~":status", ~"103"}], 1);
answer(~"/t/HttpGrpcStatus", Id, _Fields, P) ->
    headers(P, Id, [{~":status", ~"429"}, {~"grpc-status", ~"8"}, {~"grpc-message", ~"slow"}], 1);
answer(~"/t/HttpGrpcStatusOpen", Id, _Fields, P) ->
    headers(P, Id, [{~":status", ~"429"}, {~"grpc-status", ~"8"}, {~"grpc-message", ~"slow"}], 0);
answer(~"/t/HttpGrpcOk", Id, _Fields, P) ->
    headers(P, Id, [{~":status", ~"503"}, {~"grpc-status", ~"0"}], 1);
answer(~"/t/HttpGrpcOkOpen", Id, _Fields, P) ->
    headers(P, Id, [{~":status", ~"503"}, {~"grpc-status", ~"0"}], 0);
answer(~"/t/Headers", Id, Fields, P) ->
    respond(P, Id, term_to_binary(Fields));
answer(~"/t/Hang", _Id, _Fields, P) ->
    P.

%% Poll a condition, up to a deadline.
until(Fun) ->
    until(Fun, erlang:monotonic_time(millisecond) + 5000).

until(Fun, Deadline) ->
    case Fun() of
        true ->
            ok;
        false ->
            true = erlang:monotonic_time(millisecond) < Deadline,
            receive
            after 1 -> until(Fun, Deadline)
            end
    end.

%% =============================================================================
%% Header limits, interim responses, request headers
%% =============================================================================

%% The client advertises its header list limit and holds the server to it:
%% a larger list ends the call RESOURCE_EXHAUSTED, the stream reset.
header_list_cap(_Config) ->
    Self = self(),
    Port = fake(fun(P) ->
        {{settings, 0, Params}, P1} = until_frame(P, settings),
        Self ! {client_settings, Params},
        serve(P1)
    end),
    {ok, Conn} = roadrunner_grpc_client:connect({127, 0, 0, 1}, Port, #{
        max_header_list_size => 300
    }),
    receive
        {client_settings, Advertised} -> ?assertEqual(300, proplists:get_value(6, Advertised))
    end,
    Exhausted =
        {error, {grpc, resource_exhausted, ~"response header list larger than its limit", []}},
    ?assertEqual(Exhausted, roadrunner_grpc_client:unary(Conn, ~"/t/BigHeaders", ~"")),
    ?assertEqual(Exhausted, roadrunner_grpc_client:unary(Conn, ~"/t/BigTrailers", ~"")),
    ?assertMatch({ok, ~"pong", _}, roadrunner_grpc_client:unary(Conn, ~"/t/Ok", ~"")),
    ?assertError(
        {invalid_grpc_opt, max_header_list_size, 0},
        roadrunner_grpc_client:connect({127, 0, 0, 1}, Port, #{max_header_list_size => 0})
    ),
    %% 64 KiB by default.
    Default = fake(fun(P) ->
        {{settings, 0, Params}, P1} = until_frame(P, settings),
        Self ! {client_settings, Params},
        serve(P1)
    end),
    {ok, _} = roadrunner_grpc_client:connect({127, 0, 0, 1}, Default, #{}),
    receive
        {client_settings, DefaultParams} ->
            ?assertEqual(65_536, proplists:get_value(6, DefaultParams))
    end.

%% A 1xx response is skipped for the final one; one that ends the stream
%% is malformed. A non-200 response's `grpc-status` wins over the HTTP
%% status mapping.
interim_and_status_precedence(_Config) ->
    Port = fake(fun serve/1),
    {ok, Conn} = roadrunner_grpc_client:connect({127, 0, 0, 1}, Port, #{}),
    ?assertMatch({ok, ~"pong", _}, roadrunner_grpc_client:unary(Conn, ~"/t/Interim", ~"")),
    ?assertEqual(
        {error, {grpc, internal, ~"interim response that ends the stream", []}},
        roadrunner_grpc_client:unary(Conn, ~"/t/InterimEnd", ~"")
    ),
    Slow = {error, {grpc, resource_exhausted, ~"slow", []}},
    ?assertEqual(Slow, roadrunner_grpc_client:unary(Conn, ~"/t/HttpGrpcStatus", ~"")),
    ?assertEqual(Slow, roadrunner_grpc_client:unary(Conn, ~"/t/HttpGrpcStatusOpen", ~"")),
    %% A non-200 answer with `grpc-status` 0 ends the call OK, with no
    %% headers kept: a unary call then has no reply.
    NoReply = {error, {grpc, internal, ~"no response message for a unary call", []}},
    ?assertEqual(NoReply, roadrunner_grpc_client:unary(Conn, ~"/t/HttpGrpcOk", ~"")),
    ?assertEqual(NoReply, roadrunner_grpc_client:unary(Conn, ~"/t/HttpGrpcOkOpen", ~"")),
    lists:foreach(
        fun(Path) ->
            {ok, S} = roadrunner_grpc_client:stream(Conn, Path),
            ?assertEqual({ok, []}, roadrunner_grpc_client:headers(S, 5000)),
            ?assertEqual({eof, []}, roadrunner_grpc_client:recv(S, 5000))
        end,
        [~"/t/HttpGrpcOk", ~"/t/HttpGrpcOkOpen"]
    ).

%% The request headers in gRPC's order: the call's definition with
%% `grpc-timeout`, then the content type, encodings and user agent, then
%% custom metadata.
request_header_order(_Config) ->
    Port = fake(fun serve/1),
    {ok, Conn} = roadrunner_grpc_client:connect({127, 0, 0, 1}, Port, #{}),
    {ok, Reply, _} = roadrunner_grpc_client:unary(Conn, ~"/t/Headers", ~"", #{
        timeout => 5000, compression => gzip, metadata => [{~"x-custom", ~"1"}]
    }),
    Fields = binary_to_term(Reply),
    ?assertEqual(
        [
            ~":method",
            ~":scheme",
            ~":path",
            ~":authority",
            ~"te",
            ~"grpc-timeout",
            ~"content-type",
            ~"grpc-encoding",
            ~"grpc-accept-encoding",
            ~"user-agent",
            ~"x-custom"
        ],
        [Name || {Name, _} <- Fields]
    ),
    {ok, Vsn} = application:get_key(roadrunner, vsn),
    ?assertEqual(
        iolist_to_binary(["grpc-erlang-roadrunner/", Vsn]),
        proplists:get_value(~"user-agent", Fields)
    ).

%% A call that ends stops its deadline's timer; a deadline that fires after
%% its call ended is dropped.
deadline_timer_stops(Config) ->
    Conn = connect(Config),
    Pid = conn_pid(Conn),
    {ok, S} = roadrunner_grpc_client:stream(Conn, path(~"Chat"), #{timeout => 60_000}),
    [#stream{timer = Timer}] = streams(Pid),
    ?assert(is_integer(erlang:read_timer(Timer))),
    ok = roadrunner_grpc_client:close_send(S),
    {eof, _} = roadrunner_grpc_client:recv(S),
    ?assertEqual(false, erlang:read_timer(Timer)),
    %% A deadline whose message comes once its call is gone (the timer
    %% fired as the call ended) is dropped.
    Pid ! {timeout, Timer, {deadline, make_ref()}},
    ?assertMatch({ok, ~"x", _}, roadrunner_grpc_client:unary(Conn, path(~"Echo"), ~"x")).

%% One reader at a time: a second read of a stream that has one waiting is
%% refused.
concurrent_reads_are_busy(Config) ->
    Conn = connect(Config),
    {ok, S} = roadrunner_grpc_client:stream(Conn, path(~"Chat")),
    Self = self(),
    _ = spawn_link(fun() -> Self ! {read, roadrunner_grpc_client:recv(S)} end),
    ok = until(fun() -> reading(conn_pid(Conn)) end),
    ?assertEqual({error, busy}, roadrunner_grpc_client:recv(S, 1000)),
    ?assertEqual({error, busy}, roadrunner_grpc_client:headers(S)),
    ok = roadrunner_grpc_client:send(S, ~"hi"),
    receive
        {read, Read} -> ?assertEqual({ok, ~"hi"}, Read)
    end,
    ok = roadrunner_grpc_client:close_send(S),
    ?assertMatch({eof, _}, roadrunner_grpc_client:recv(S)).

%% Once the stream ids run out, the call that took the last one runs, the
%% calls waiting for a slot end `closed`, new calls are refused, and the
%% connection closes once its calls end.
stream_ids_run_out(Config) ->
    true = register(?WATCHER, self()),
    Conn = connect(Config),
    Pid = conn_pid(Conn),
    Self = self(),
    _ = spawn_link(fun() ->
        Self ! {first, roadrunner_grpc_client:unary(Conn, path(~"Hold"), ~"first")}
    end),
    Method =
        receive
            {held, M} -> M
        end,
    {ok, Last} = roadrunner_grpc_client:stream(Conn, path(~"Echo")),
    {ok, Refused} = roadrunner_grpc_client:stream(Conn, path(~"Echo")),
    _ = sys:replace_state(Pid, fun(State) -> State#state{next_id = 16#7FFFFFFF} end),
    Method ! go,
    receive
        {first, First} -> ?assertMatch({ok, ~"first", _}, First)
    end,
    ?assertEqual({error, closed}, roadrunner_grpc_client:recv(Refused)),
    ?assertEqual({error, closed}, roadrunner_grpc_client:stream(Conn, path(~"Echo"))),
    Mon = monitor(process, Pid),
    ok = roadrunner_grpc_client:send(Last, ~"last"),
    ok = roadrunner_grpc_client:close_send(Last),
    ?assertEqual({ok, ~"last"}, roadrunner_grpc_client:recv(Last)),
    ?assertMatch({eof, _}, roadrunner_grpc_client:recv(Last)),
    receive
        {'DOWN', Mon, process, Pid, normal} -> ok
    end.
