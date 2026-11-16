-module(roadrunner_grpc_events_SUITE).
-moduledoc """
The events a gRPC call emits (`grpc_call_start`, then one
`grpc_call_stop` or `grpc_call_exception`), over HTTP/2 and HTTP/3,
for each call kind and each way a call ends. Each case watches the
process running the call until it exits, so it sees every event the
call emitted.
""".

-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, groups/0]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([forward/4]).
-export([
    unary/1,
    server_stream/1,
    client_stream/1,
    bidi_stream/1,
    error_status/1,
    unknown_method/1,
    answered_by_roadrunner/1,
    crash/1,
    crash_after_a_response/1,
    bad_return/1,
    stopped/1,
    head_over_the_client_limit/1,
    trailers_over_the_client_limit/1,
    client_cancels_a_write/1,
    client_cancels_a_read/1,
    connection_gone/1,
    deadline_cancels/1,
    deadline_ends_a_read/1,
    compressed/1,
    cancelled_before_trailers_only/1,
    gone_before_trailers_only/1,
    cancelled_told_to_the_method/1,
    gone_told_to_the_method/1,
    client_resets_just_before_the_deadline/1,
    client_resets_well_before_the_deadline/1,
    cancelled_long_before_a_late_return/1,
    stopped_after_a_response/1,
    encoding_of_a_call_refused_early/1,
    active_reads/1,
    active_read_cancelled/1,
    active_read_drained/1,
    h3_cancelled_before_trailers_only/1,
    h3_unary/1,
    h3_streams/1,
    h3_error_status/1,
    h3_stopped/1,
    h3_crash/1,
    h3_deadline_cancels/1,
    h3_client_cancels/1,
    h3_connection_gone/1,
    keys_of_a_reported_call/1,
    no_handler_same_answers/1,
    no_handler_keeps_nothing/1,
    no_handler_cancelled_before_trailers_only/1
]).

-define(SVC, ~"/test.Echo/").
-define(EVENTS, [
    [roadrunner, grpc, start],
    [roadrunner, grpc, stop],
    [roadrunner, grpc, exception]
]).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [{group, no_handler}, {group, http2}, {group, http3}].

groups() ->
    [
        {no_handler, [], [
            no_handler_same_answers,
            no_handler_keeps_nothing,
            no_handler_cancelled_before_trailers_only
        ]},
        {http2, [], [
            unary,
            server_stream,
            client_stream,
            bidi_stream,
            error_status,
            unknown_method,
            answered_by_roadrunner,
            crash,
            crash_after_a_response,
            bad_return,
            stopped,
            head_over_the_client_limit,
            trailers_over_the_client_limit,
            client_cancels_a_write,
            client_cancels_a_read,
            connection_gone,
            deadline_cancels,
            deadline_ends_a_read,
            compressed,
            cancelled_before_trailers_only,
            gone_before_trailers_only,
            cancelled_told_to_the_method,
            gone_told_to_the_method,
            client_resets_just_before_the_deadline,
            client_resets_well_before_the_deadline,
            cancelled_long_before_a_late_return,
            stopped_after_a_response,
            encoding_of_a_call_refused_early,
            keys_of_a_reported_call,
            active_reads,
            active_read_cancelled,
            active_read_drained
        ]},
        {http3, [], [
            h3_unary,
            h3_streams,
            h3_error_status,
            h3_stopped,
            h3_crash,
            h3_deadline_cancels,
            h3_client_cancels,
            h3_connection_gone,
            h3_cancelled_before_trailers_only
        ]}
    ].

init_per_testcase(Case, Config) ->
    {ok, _} = roadrunner_test_event_handler:start(),
    ok =
        case atom_to_list(Case) of
            "no_handler_" ++ _ -> roadrunner_event:put_handler(roadrunner_event_noop);
            _ -> ok
        end,
    Id = {?MODULE, Case},
    ok = telemetry:attach_many(Id, ?EVENTS, fun ?MODULE:forward/4, self()),
    Protocols =
        case atom_to_list(Case) of
            "h3_" ++ _ -> [http3];
            _ -> [http2]
        end,
    {ok, _} = roadrunner_listener:start_link(?MODULE, (tls(Protocols))#{
        port => 0,
        protocols => Protocols,
        body_buffering => manual,
        routes => roadrunner_grpc:routes(#{
            services => [roadrunner_grpc_test_service],
            send_compression => gzip
        })
    }),
    [{port, roadrunner_listener:port(?MODULE)}, {handler_id, Id} | Config].

tls([http3]) -> #{tls => roadrunner_test_certs:server_opts()};
tls(_Protocols) -> #{}.

end_per_testcase(_Case, Config) ->
    ok = telemetry:detach(?config(handler_id, Config)),
    %% A listener that drained has stopped.
    case whereis(?MODULE) of
        undefined -> ok;
        _Listener -> ok = roadrunner_listener:stop(?MODULE)
    end.

%% Runs in the process emitting the event: the call's own.
forward(Event, Measurements, Metadata, Test) ->
    Test ! {grpc_event, self(), Event, Measurements, Metadata}.

%% --- HTTP/2 ---

unary(Config) ->
    {_, [~"hi"], _, _} = call(Config, ~"Unary", [~"hi"]),
    {Start, {stop, M, Md}} = ended(),
    ?assertMatch(
        #{
            service := ~"test.Echo",
            method := ~"Unary",
            call_kind := unary,
            listener_name := ?MODULE
        },
        Start
    ),
    ?assertMatch(<<_:16/binary>>, maps:get(request_id, Start)),
    ?assertMatch(
        #{
            status := ok,
            message := <<>>,
            reason := normal,
            recv_encoding := identity,
            send_encoding := identity
        },
        Md
    ),
    ?assertMatch(
        #{messages_received := 1, bytes_received := 2, messages_sent := 1, bytes_sent := 2}, M
    ),
    ?assert(maps:get(duration, M) > 0).

server_stream(Config) ->
    {_, [_, _, _], _, _} = call(Config, ~"Count", [~"3"]),
    {#{call_kind := server_stream}, {stop, M, #{status := ok, reason := normal}}} = ended(),
    ?assertMatch(
        #{messages_received := 1, bytes_received := 1, messages_sent := 3, bytes_sent := 3}, M
    ).

client_stream(Config) ->
    {_, [~"abc"], _, _} = call(Config, ~"Sum", [~"a", ~"b", ~"c"]),
    {#{call_kind := client_stream}, {stop, M, #{status := ok}}} = ended(),
    ?assertMatch(
        #{messages_received := 3, bytes_received := 3, messages_sent := 1, bytes_sent := 3}, M
    ).

bidi_stream(Config) ->
    {_, [~"a", ~"bc"], _, _} = call(Config, ~"Chat", [~"a", ~"bc"]),
    {#{call_kind := bidi_stream}, {stop, M, #{status := ok}}} = ended(),
    ?assertMatch(
        #{messages_received := 2, bytes_received := 3, messages_sent := 2, bytes_sent := 3}, M
    ).

error_status(Config) ->
    {_, [], trailers_only, _} = call(Config, ~"Fail", [~"x"]),
    {_, {stop, M, Md}} = ended(),
    ?assertMatch(
        #{status := not_found, message := ~"no such thing: café 100%", reason := error}, Md
    ),
    ?assertMatch(#{messages_received := 1, messages_sent := 0}, M).

%% A method the service does not have starts with no kind.
unknown_method(Config) ->
    {_, [], trailers_only, _} = call(Config, ~"Nope", [~"x"]),
    {Start, {stop, M, Md}} = ended(),
    ?assertMatch(#{method := ~"Nope", call_kind := undefined}, Start),
    ?assertMatch(#{status := unimplemented, reason := error}, Md),
    ?assertMatch(#{messages_received := 0, messages_sent := 0}, M).

%% A status roadrunner answers ends the call as the method's would.
answered_by_roadrunner(Config) ->
    {_, [], trailers_only, _} = call(Config, ~"Unary", [~"a", ~"b"]),
    {_, {stop, _, Md}} = ended(),
    ?assertMatch(
        #{status := internal, message := ~"more than one request message", reason := error}, Md
    ).

crash(Config) ->
    {Headers, [], trailers_only, _} = call(Config, ~"Crash", [~"x"]),
    ?assertEqual(~"13", proplists:get_value(~"grpc-status", Headers)),
    {#{call_kind := unary}, {exception, M, Md}} = ended(),
    ?assertMatch(#{kind := error, reason := boom, stacktrace := [_ | _]}, Md),
    ?assertMatch(#{messages_received := 1, messages_sent := 0}, M).

crash_after_a_response(Config) ->
    {_, [~"first"], _, _} = call(Config, ~"CrashAfter", [~"x"]),
    {_, {exception, M, #{reason := boom}}} = ended(),
    ?assertMatch(#{messages_sent := 1, bytes_sent := 5}, M).

bad_return(Config) ->
    {_, [], trailers_only, _} = call(Config, ~"Bad", [~"x"]),
    {_, {exception, _, Md}} = ended(),
    ?assertMatch(#{kind := error, reason := {bad_return, {wat, _}}}, Md).

%% `exit({shutdown, _})` stops the call with no gRPC status.
stopped(Config) ->
    {_, _, _, _} = call(Config, ~"Stop", [~"x"]),
    {_, {stop, _, Md}} = ended(),
    ?assertMatch(#{status := unknown, message := <<>>, reason := stopped}, Md).

%% Response headers over the client's SETTINGS_MAX_HEADER_LIST_SIZE are
%% answered 500: no gRPC status either.
head_over_the_client_limit(Config) ->
    C = roadrunner_grpc_test_client:open(?config(port, Config), [{6, 200}]),
    {_, _, _, _} = roadrunner_grpc_test_client:call(C, 1, <<?SVC/binary, "BigHeader">>, [], [~"x"]),
    {_, {stop, _, Md}} = ended(),
    ?assertMatch(#{status := unknown, reason := stopped}, Md).

%% Trailers over the client's limit cannot become a status: the call
%% raises as it ends, and its stream is reset.
trailers_over_the_client_limit(Config) ->
    C = roadrunner_grpc_test_client:open(?config(port, Config), [{6, 300}]),
    {_, [<<>>], {rst, _}, _} = roadrunner_grpc_test_client:call(
        C, 1, <<?SVC/binary, "BigTrailer">>, [], [~"x"]
    ),
    {_, {exception, M, Md}} = ended(),
    ?assertMatch(#{kind := error, reason := header_list_too_large}, Md),
    ?assertMatch(#{messages_received := 1, messages_sent := 1}, M).

%% The client resets the call while the method writes, before its
%% deadline: its next write stops it.
client_cancels_a_write(Config) ->
    C = data(flood(Config, [{~"grpc-timeout", ~"10S"}])),
    {Pid, _Start} = started(),
    _ = roadrunner_grpc_test_client:reset(C, 1),
    {stop, M, Md} = ending(Pid),
    ?assertMatch(#{status := cancelled, message := <<>>, reason := cancelled}, Md),
    ?assert(maps:get(messages_sent, M) > 0).

%% Messages read with `recv_async/1` and `info/2` count as `recv/1`'s do.
active_reads(Config) ->
    {_, [~"abc"], _, _} = call(Config, ~"ActiveSum", [~"a", ~"bc"]),
    {_, {stop, M, #{status := ok}}} = ended(),
    ?assertMatch(
        #{messages_received := 2, bytes_received := 3, messages_sent := 1, bytes_sent := 3}, M
    ).

%% A client that resets the call while a read waits ends it `cancelled`.
active_read_cancelled(Config) ->
    C0 = active_chat(Config),
    {Pid, _Start} = started(),
    C1 = roadrunner_grpc_test_client:send(C0, 1, frame(~"a")),
    C2 = to_data(C1),
    _ = roadrunner_grpc_test_client:reset(C2, 1),
    {stop, M, Md} = ending(Pid),
    ?assertMatch(#{status := cancelled, reason := cancelled}, Md),
    ?assertMatch(#{messages_received := 1, messages_sent := 1}, M).

%% A call its method ends on a drain is reported with the status it ended
%% with.
active_read_drained(Config) ->
    _ = active_chat(Config),
    {Pid, _Start} = started(),
    _ = spawn(fun() -> roadrunner_listener:drain(?MODULE, 10_000) end),
    {stop, _, Md} = ending(Pid),
    ?assertMatch(
        #{status := unavailable, message := ~"server shutting down", reason := error}, Md
    ).

%% The client resets the call while the method reads.
client_cancels_a_read(Config) ->
    C0 = roadrunner_grpc_test_client:start(open(Config), 1, <<?SVC/binary, "Sum">>, []),
    C1 = roadrunner_grpc_test_client:send(C0, 1, frame(~"a")),
    {Pid, _Start} = started(),
    _ = roadrunner_grpc_test_client:reset(C1, 1),
    {stop, M, Md} = ending(Pid),
    ?assertMatch(#{status := cancelled, reason := cancelled}, Md),
    ?assertMatch(#{messages_received := 1}, M).

connection_gone(Config) ->
    #{sock := Sock} = flood(Config, []),
    {Pid, _Start} = started(),
    ok = gen_tcp:close(Sock),
    {stop, _, Md} = ending(Pid),
    ?assertMatch(#{status := cancelled, reason := cancelled}, Md).

%% A call still writing past its deadline is cancelled.
deadline_cancels(Config) ->
    _ = flood(Config, [{~"grpc-timeout", ~"100m"}]),
    {Pid, _Start} = started(),
    {stop, _, Md} = ending(Pid),
    ?assertMatch(#{status := deadline_exceeded, message := <<>>, reason := deadline}, Md).

%% A read still waiting at the deadline ends the call with its status.
deadline_ends_a_read(Config) ->
    C = roadrunner_grpc_test_client:start(open(Config), 1, <<?SVC/binary, "Chat">>, [
        {~"grpc-timeout", ~"100m"}
    ]),
    {_, [], trailers_only, _} = roadrunner_grpc_test_client:response(C, 1),
    {_, {stop, _, Md}} = ended(),
    ?assertMatch(#{status := deadline_exceeded, reason := error}, Md).

%% Bytes are counted as they crossed the wire, compressed.
compressed(Config) ->
    Payload = binary:copy(~"hello ", 50),
    Gzipped = zlib:gzip(Payload),
    C0 = roadrunner_grpc_test_client:start(open(Config), 1, <<?SVC/binary, "Unary">>, [
        {~"grpc-encoding", ~"gzip"}, {~"grpc-accept-encoding", ~"gzip"}
    ]),
    C1 = roadrunner_grpc_test_client:send(
        C0, 1, iolist_to_binary(roadrunner_grpc_frame:encode(true, Gzipped))
    ),
    {_, [{compressed, Reply}], _, _} = roadrunner_grpc_test_client:response(
        roadrunner_grpc_test_client:finish(C1, 1), 1
    ),
    {_, {stop, M, Md}} = ended(),
    ?assertMatch(#{recv_encoding := gzip, send_encoding := gzip}, Md),
    ReceivedBytes = byte_size(Gzipped),
    SentBytes = byte_size(Reply),
    ?assertMatch(#{bytes_received := ReceivedBytes, bytes_sent := SentBytes}, M).

%% A Trailers-Only status goes out without waiting on the connection: a
%% reset already in, which the client sent before it could read the
%% status, makes the call `cancelled`, whatever the method returned.
cancelled_before_trailers_only(Config) ->
    C = hold_call(Config),
    Pid = held(),
    _ = roadrunner_grpc_test_client:reset(C, 1),
    ok = let_go(Pid, fun
        ({h2_stream_reset, _}) -> true;
        (_) -> false
    end),
    {stop, _, Md} = ending(Pid),
    ?assertMatch(#{status := cancelled, reason := cancelled}, Md).

%% The connection gone before a Trailers-Only status, likewise.
gone_before_trailers_only(Config) ->
    #{sock := Sock} = hold_call(Config),
    Pid = held(),
    ok = gen_tcp:close(Sock),
    ok = let_go(Pid, fun
        ({'DOWN', _, process, _, _}) -> true;
        (_) -> false
    end),
    {stop, _, Md} = ending(Pid),
    ?assertMatch(#{status := cancelled, reason := cancelled}, Md).

%% A method that learns of the reset from `cancelled/2` and returns `ok`
%% had its call cancelled, not ended OK.
cancelled_told_to_the_method(Config) ->
    C0 = roadrunner_grpc_test_client:start(open(Config), 1, <<?SVC/binary, "Watch">>, []),
    C1 = roadrunner_grpc_test_client:finish(
        roadrunner_grpc_test_client:send(C0, 1, frame(~"x")), 1
    ),
    {Pid, _Start} = started(),
    _ = roadrunner_grpc_test_client:reset(C1, 1),
    {stop, _, Md} = ending(Pid),
    ?assertMatch(#{status := cancelled, reason := cancelled}, Md).

gone_told_to_the_method(Config) ->
    C0 = roadrunner_grpc_test_client:start(open(Config), 1, <<?SVC/binary, "Watch">>, []),
    #{sock := Sock} = roadrunner_grpc_test_client:finish(
        roadrunner_grpc_test_client:send(C0, 1, frame(~"x")), 1
    ),
    {Pid, _Start} = started(),
    ok = gen_tcp:close(Sock),
    {stop, _, Md} = ending(Pid),
    ?assertMatch(#{status := cancelled, reason := cancelled}, Md).

%% A client resets as its own deadline passes, which comes a little before
%% the server's: within the slack (50 ms), the reset is the deadline's.
%% Here it is found 20 ms before the server's deadline.
client_resets_just_before_the_deadline(Config) ->
    {stop, _, Md} = reset_before_the_deadline(Config, ~"20"),
    ?assertMatch(#{status := deadline_exceeded, reason := deadline}, Md).

%% Found 900 ms before it, it stays the client's cancel.
client_resets_well_before_the_deadline(Config) ->
    {stop, _, Md} = reset_before_the_deadline(Config, ~"900"),
    ?assertMatch(#{status := cancelled, reason := cancelled}, Md).

reset_before_the_deadline(Config, Before) ->
    true = register(roadrunner_grpc_held, self()),
    C0 = roadrunner_grpc_test_client:start(open(Config), 1, <<?SVC/binary, "ResetAt">>, [
        {~"grpc-timeout", ~"1S"}
    ]),
    C = roadrunner_grpc_test_client:finish(
        roadrunner_grpc_test_client:send(C0, 1, frame(Before)), 1
    ),
    Pid = held(),
    _ = roadrunner_grpc_test_client:reset(C, 1),
    ok = let_go(Pid, fun
        ({h2_stream_reset, _}) -> true;
        (_) -> false
    end),
    ending(Pid).

%% A method told by `cancelled/2` long before the deadline, that returns
%% only at it: the call was cancelled when it was told.
cancelled_long_before_a_late_return(Config) ->
    C0 = roadrunner_grpc_test_client:start(open(Config), 1, <<?SVC/binary, "WatchLate">>, [
        {~"grpc-timeout", ~"1S"}
    ]),
    C1 = roadrunner_grpc_test_client:finish(
        roadrunner_grpc_test_client:send(C0, 1, frame(~"x")), 1
    ),
    {Pid, _Start} = started(),
    _ = roadrunner_grpc_test_client:reset(C1, 1),
    {stop, _, Md} = ending(Pid),
    ?assertMatch(#{status := cancelled, reason := cancelled}, Md).

%% A stop on purpose after a response started ends the stream with no
%% trailers, which a gRPC client reads as INTERNAL.
stopped_after_a_response(Config) ->
    {_, {body, _}, no_trailers, _} = call(Config, ~"StopAfter", [~"x"]),
    {_, {stop, M, Md}} = ended(),
    ?assertMatch(#{status := internal, message := <<>>, reason := stopped}, Md),
    ?assertMatch(#{messages_sent := 1}, M).

%% The client's grpc-encoding is reported for a call refused before its
%% method runs, and as sent when roadrunner does not read it.
encoding_of_a_call_refused_early(Config) ->
    {_, [], trailers_only, _} = roadrunner_grpc_test_client:call(
        open(Config), 1, <<?SVC/binary, "Nope">>, [{~"grpc-encoding", ~"gzip"}], [~"x"]
    ),
    {_, {stop, _, Gzip}} = ended(),
    ?assertMatch(#{status := unimplemented, recv_encoding := gzip}, Gzip),
    {_, [], trailers_only, _} = roadrunner_grpc_test_client:call(
        open(Config), 1, <<?SVC/binary, "Unary">>, [{~"grpc-encoding", ~"br"}], [~"x"]
    ),
    {_, {stop, _, Br}} = ended(),
    ?assertMatch(#{status := unimplemented, recv_encoding := ~"br"}, Br).

%% A call that reports events keeps its counts, and when `cancelled/2` told
%% the method the call is over, in its process dictionary.
keys_of_a_reported_call(Config) ->
    {_, [Kept], _, _} = call(Config, ~"Keys", [~"x"]),
    ?assertEqual([call, connection], binary_to_term(Kept)),
    {_, {stop, _, _}} = ended(),
    {_, [Told], _, _} = call(Config, ~"Keys", [~"cancelled"]),
    ?assertEqual([call, connection, gone], binary_to_term(Told)),
    {_, {stop, _, _}} = ended().

%% --- No handler ---

%% With the no-op handler, calls answer as they do with one.
no_handler_same_answers(Config) ->
    {_, [~"hi"], Trailers, _} = call(Config, ~"Unary", [~"hi"]),
    ?assertEqual(~"0", proplists:get_value(~"grpc-status", Trailers)),
    {_, [~"1", ~"2", ~"3"], _, _} = call(Config, ~"Count", [~"3"]),
    {_, [~"abc"], _, _} = call(Config, ~"Sum", [~"a", ~"b", ~"c"]),
    {Headers, [], trailers_only, _} = call(Config, ~"Fail", [~"x"]),
    ?assertEqual(~"5", proplists:get_value(~"grpc-status", Headers)),
    {Crashed, [], trailers_only, _} = call(Config, ~"Crash", [~"x"]),
    ?assertEqual(~"13", proplists:get_value(~"grpc-status", Crashed)),
    {Unknown, [], trailers_only, _} = call(Config, ~"Nope", [~"x"]),
    ?assertEqual(~"12", proplists:get_value(~"grpc-status", Unknown)),
    ?assertEqual([], drain()).

%% With the no-op handler, a call keeps no counts, nor that `cancelled/2`
%% told the method the call is over.
no_handler_keeps_nothing(Config) ->
    {_, [Kept], _, _} = call(Config, ~"Keys", [~"x"]),
    ?assertEqual([connection], binary_to_term(Kept)),
    {_, [Told], _, _} = call(Config, ~"Keys", [~"cancelled"]),
    ?assertEqual([connection], binary_to_term(Told)).

%% With the no-op handler, a call whose client reset it ends with its
%% status all the same, and reports nothing.
no_handler_cancelled_before_trailers_only(Config) ->
    C = hold_call(Config),
    Pid =
        receive
            {held, Held} -> Held
        after 5000 -> ct:fail(not_held)
        end,
    true = unregister(roadrunner_grpc_held),
    1 = erlang:trace(Pid, true, ['receive']),
    MRef = monitor(process, Pid),
    _ = roadrunner_grpc_test_client:reset(C, 1),
    ok = let_go(Pid, fun
        ({h2_stream_reset, _}) -> true;
        (_) -> false
    end),
    receive
        {'DOWN', MRef, process, Pid, Reason} -> ?assertEqual(normal, Reason)
    after 5000 -> ct:fail(call_still_running)
    end,
    ?assertEqual([], drain()).

%% --- HTTP/3 ---

h3_cancelled_before_trailers_only(Config) ->
    true = register(roadrunner_grpc_held, self()),
    Conn = h3_connect(Config),
    StreamId = h3_start(Conn, ~"Hold", [], [~"x"]),
    Pid = held(),
    _ = roadrunner_quic_test_h3:cancel(Conn, StreamId),
    ok = let_go(Pid, fun
        ({roadrunner_stream_reset, _}) -> true;
        (_) -> false
    end),
    {stop, _, Md} = ending(Pid),
    ?assertMatch(#{status := cancelled, reason := cancelled}, Md),
    _ = roadrunner_quic_test_h3:close(Conn).

h3_unary(Config) ->
    Conn = h3_connect(Config),
    {[_, _], _} = h3_call(Conn, ~"Unary", [], [~"hi"]),
    {#{call_kind := unary}, {stop, M, Md}} = ended(),
    ?assertMatch(#{status := ok, reason := normal}, Md),
    ?assertMatch(
        #{messages_received := 1, bytes_received := 2, messages_sent := 1, bytes_sent := 2}, M
    ),
    _ = roadrunner_quic_test_h3:close(Conn).

%% The streaming kinds, one call after another on one connection.
h3_streams(Config) ->
    Conn = h3_connect(Config),
    lists:foreach(
        fun({Method, Messages, Kind, Counts}) ->
            {[_, _], _} = h3_call(Conn, Method, [], Messages),
            {#{call_kind := Kind}, {stop, M, #{status := ok, reason := normal}}} = ended(),
            ?assertEqual(
                Counts,
                {
                    maps:get(messages_received, M),
                    maps:get(bytes_received, M),
                    maps:get(messages_sent, M),
                    maps:get(bytes_sent, M)
                }
            )
        end,
        [
            {~"Count", [~"3"], server_stream, {1, 1, 3, 3}},
            {~"Sum", [~"a", ~"b", ~"c"], client_stream, {3, 3, 1, 3}},
            {~"Chat", [~"a", ~"bc"], bidi_stream, {2, 3, 2, 3}}
        ]
    ),
    _ = roadrunner_quic_test_h3:close(Conn).

h3_stopped(Config) ->
    Conn = h3_connect(Config),
    _ = h3_call(Conn, ~"Stop", [], [~"x"]),
    {_, {stop, _, Md}} = ended(),
    ?assertMatch(#{status := unknown, reason := stopped}, Md),
    _ = roadrunner_quic_test_h3:close(Conn).

h3_error_status(Config) ->
    Conn = h3_connect(Config),
    {[_], <<>>} = h3_call(Conn, ~"Fail", [], [~"x"]),
    {_, {stop, _, Md}} = ended(),
    ?assertMatch(#{status := not_found, reason := error}, Md),
    _ = roadrunner_quic_test_h3:close(Conn).

h3_crash(Config) ->
    Conn = h3_connect(Config),
    {[_], <<>>} = h3_call(Conn, ~"Crash", [], [~"x"]),
    {_, {exception, _, Md}} = ended(),
    ?assertMatch(#{kind := error, reason := boom}, Md),
    _ = roadrunner_quic_test_h3:close(Conn).

h3_deadline_cancels(Config) ->
    Conn = h3_connect(Config),
    _ = h3_flood(Conn, [{~"grpc-timeout", ~"100m"}]),
    {Pid, _Start} = started(),
    {stop, _, Md} = ending(Pid),
    ?assertMatch(#{status := deadline_exceeded, reason := deadline}, Md),
    _ = roadrunner_quic_test_h3:close(Conn).

h3_client_cancels(Config) ->
    Conn = h3_connect(Config),
    StreamId = h3_flood(Conn, []),
    {Pid, _Start} = started(),
    _ = roadrunner_quic_test_h3:cancel(Conn, StreamId),
    {stop, _, Md} = ending(Pid),
    ?assertMatch(#{status := cancelled, reason := cancelled}, Md),
    _ = roadrunner_quic_test_h3:close(Conn).

h3_connection_gone(Config) ->
    Conn = h3_connect(Config),
    _ = h3_flood(Conn, []),
    {Pid, _Start} = started(),
    _ = roadrunner_quic_test_h3:close(Conn),
    {stop, _, Md} = ending(Pid),
    ?assertMatch(#{status := cancelled, reason := cancelled}, Md).

%% --- helpers ---

%% The call's start metadata and how it ended, once its process exited:
%% exactly one `stop` or `exception` after the `start`.
ended() ->
    {Pid, Start} = started(),
    {Start, ending(Pid)}.

started() ->
    receive
        {grpc_event, Pid, [roadrunner, grpc, start], _M, Md} -> {Pid, Md}
    after 5000 -> ct:fail(no_start)
    end.

%% The one event that ended the call in `Pid`, checked to be the only one
%% once `Pid` exited (the events it sent arrive before its 'DOWN').
ending(Pid) ->
    MRef = monitor(process, Pid),
    receive
        {'DOWN', MRef, process, Pid, _} -> ok
    after 10000 -> ct:fail(call_still_running)
    end,
    case
        [
            {Which, M, Md}
         || {grpc_event, From, [roadrunner, grpc, Which], M, Md} <- drain(), From =:= Pid
        ]
    of
        [Ending] -> Ending;
        Endings -> ct:fail({not_one_ending, Endings})
    end.

drain() ->
    receive
        {grpc_event, _, _, _, _} = Event -> [Event | drain()]
    after 0 -> []
    end.

open(Config) ->
    roadrunner_grpc_test_client:open(?config(port, Config)).

call(Config, Method, Messages) ->
    roadrunner_grpc_test_client:call(open(Config), 1, <<?SVC/binary, Method/binary>>, [], Messages).

frame(Message) ->
    iolist_to_binary(roadrunner_grpc_frame:encode(false, Message)).

%% A `Flood` call on a client whose stream window (SETTINGS id 4) holds the
%% method's writes after 1 KB, so it waits on the client.
flood(Config, Extra) ->
    C0 = roadrunner_grpc_test_client:open(?config(port, Config), [{4, 1024}]),
    C1 = roadrunner_grpc_test_client:start(C0, 1, <<?SVC/binary, "Flood">>, Extra),
    roadrunner_grpc_test_client:finish(roadrunner_grpc_test_client:send(C1, 1, frame(~"x")), 1).

%% Past the first DATA frame of the call on stream 1.
to_data(C) ->
    case roadrunner_grpc_test_client:next_frame(C) of
        {{data, 1, _, _, _}, C1} -> C1;
        {_Other, C1} -> to_data(C1)
    end.

%% An `ActiveChat` call, its method waiting on the client and on its own
%% messages.
active_chat(Config) ->
    true = register(roadrunner_grpc_held, self()),
    C = roadrunner_grpc_test_client:start(open(Config), 1, <<?SVC/binary, "ActiveChat">>, []),
    receive
        {held, _Pid} -> C
    end.

%% A `Hold` call, its method waiting for this process to let it go.
hold_call(Config) ->
    true = register(roadrunner_grpc_held, self()),
    C0 = roadrunner_grpc_test_client:start(open(Config), 1, <<?SVC/binary, "Hold">>, []),
    roadrunner_grpc_test_client:finish(roadrunner_grpc_test_client:send(C0, 1, frame(~"x")), 1).

%% The holding method's process, traced from here on for what it receives.
held() ->
    receive
        {held, Pid} ->
            {Pid, _Start} = started(),
            true = unregister(roadrunner_grpc_held),
            1 = erlang:trace(Pid, true, ['receive']),
            Pid
    end.

%% Let the method go once a message `Arrived` accepts is in its mailbox.
let_go(Pid, Arrived) ->
    receive
        {trace, Pid, 'receive', Message} ->
            case Arrived(Message) of
                true ->
                    _ = erlang:trace(Pid, false, ['receive']),
                    Pid ! go,
                    ok;
                false ->
                    let_go(Pid, Arrived)
            end
    after 5000 -> ct:fail(nothing_arrived)
    end.

%% Read on until the first response DATA.
data(C) ->
    case roadrunner_grpc_test_client:next_frame(C) of
        {{data, 1, _, _, _}, C1} -> C1;
        {_Other, C1} -> data(C1)
    end.

h3_connect(Config) ->
    {ok, Conn} = roadrunner_quic_test_h3:connect({127, 0, 0, 1}, ?config(port, Config)),
    Conn.

h3_call(Conn, Method, Extra, Messages) ->
    StreamId = h3_start(Conn, Method, Extra, Messages),
    roadrunner_quic_test_h3:collect_all(Conn, StreamId).

h3_flood(Conn, Extra) ->
    h3_start(Conn, ~"Flood", Extra, [~"x"]).

h3_start(Conn, Method, Extra, Messages) ->
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
    StreamId.
