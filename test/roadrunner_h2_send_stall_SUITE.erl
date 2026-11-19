-module(roadrunner_h2_send_stall_SUITE).
-moduledoc """
HTTP/2 `send_stall_timeout` tests: a stream whose response has DATA held
back for the client's flow-control window, with nothing sent for the
whole timeout, is reset with RST_STREAM(CANCEL), while a client that
keeps reading, however slowly, and a stream with nothing to send are
left alone.

Drives the conn through the `{fake, Pid}` transport, as
`roadrunner_http2_flow_control_SUITE` does, with the timeout set small.
""".
-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").

-export([suite/0, all/0, init_per_testcase/2, end_per_testcase/2]).
-export([
    stalled_buffered_body_is_reset/1,
    zero_initial_window_streams_are_reset/1,
    conn_window_stall_resets_every_waiting_stream/1,
    stalled_stream_response_resets_its_worker/1,
    stalled_loop_push_resets_its_worker/1,
    progressing_reader_is_not_reset/1,
    conn_window_reader_keeps_other_streams/1,
    settings_shrink_moves_wait_to_stream_window/1,
    idle_loop_stream_is_not_reset/1,
    window_opened_in_time_completes/1
]).

-define(PREFACE, ~"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n").
%% SETTINGS_INITIAL_WINDOW_SIZE (RFC 9113 §6.5.2).
-define(INITIAL_WINDOW_SIZE, 4).
-define(RST_STREAM, 3).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        stalled_buffered_body_is_reset,
        zero_initial_window_streams_are_reset,
        conn_window_stall_resets_every_waiting_stream,
        stalled_stream_response_resets_its_worker,
        stalled_loop_push_resets_its_worker,
        progressing_reader_is_not_reset,
        conn_window_reader_keeps_other_streams,
        settings_shrink_moves_wait_to_stream_window,
        idle_loop_stream_is_not_reset,
        window_opened_in_time_completes
    ].

init_per_testcase(_Case, Config) ->
    {ok, _} = roadrunner_test_event_handler:start(),
    Config.

end_per_testcase(_Case, _Config) ->
    ok.

%% =============================================================================
%% Cases
%% =============================================================================

stalled_buffered_body_is_reset(_Config) ->
    %% A buffered 100 KB body: the first 65535 bytes spend the client's
    %% window and the rest waits. The client never opens it, so once the
    %% timeout passes the stream is reset with CANCEL and its body dropped;
    %% the conn serves on. An event stream open beside it, with nothing to
    %% send, holds nothing back and is left alone.
    Inflight = counters:new(1, []),
    {Pid, Ref, ConnPid} = start_conn(#{
        http2_send_stall_timeout => 100,
        max_concurrent_requests => 10,
        inflight_counter => Inflight
    }),
    handshake(ConnPid, []),
    request(ConnPid, 1, ~"/large100k"),
    {65535, false} = data_bytes(1, 65535),
    request(ConnPid, 3, ~"/loop"),
    3 = headers_stream(expect_send_type(1)),
    Loop = wait_for_register(roadrunner_h2_loop_test),
    {1, cancel} = expect_rst(),
    ping_pong(ConnPid),
    %% Only the event stream's worker holds a slot now.
    ok = wait_inflight(Inflight, 1),
    true = is_process_alive(Loop),
    %% The window the client opens now finds nothing to send.
    serve_recv(ConnPid, encode_frame({window_update, 1, 100_000})),
    ping_pong(ConnPid),
    cleanup(Pid, Ref).

zero_initial_window_streams_are_reset(_Config) ->
    %% SETTINGS_INITIAL_WINDOW_SIZE = 0 and never a WINDOW_UPDATE: each
    %% response gets its HEADERS out and no byte of its body. Every stream
    %% is reset once the timeout passes.
    {Pid, Ref, ConnPid} = start_conn(#{http2_send_stall_timeout => 100}),
    handshake(ConnPid, [{?INITIAL_WINDOW_SIZE, 0}]),
    [request(ConnPid, Id, ~"/large100k") || Id <- [1, 3, 5]],
    [1, 3, 5] = lists:sort([headers_stream(expect_send_type(1)) || _ <- [1, 3, 5]]),
    [{1, cancel}, {3, cancel}, {5, cancel}] = lists:sort([expect_rst() || _ <- [1, 3, 5]]),
    ping_pong(ConnPid),
    cleanup(Pid, Ref).

conn_window_stall_resets_every_waiting_stream(_Config) ->
    %% The streams' windows are open but the connection's is spent: the
    %% first stream takes all 65535 bytes of it and the second gets none.
    %% Both wait on the connection window, and both are reset.
    {Pid, Ref, ConnPid} = start_conn(#{http2_send_stall_timeout => 100}),
    handshake(ConnPid, [{?INITIAL_WINDOW_SIZE, 1_000_000}]),
    request(ConnPid, 1, ~"/large100k"),
    {65535, false} = data_bytes(1, 65535),
    request(ConnPid, 3, ~"/large100k"),
    3 = headers_stream(expect_send_type(1)),
    [{1, cancel}, {3, cancel}] = lists:sort([expect_rst(), expect_rst()]),
    ping_pong(ConnPid),
    cleanup(Pid, Ref).

stalled_stream_response_resets_its_worker(_Config) ->
    %% A stream response's worker waits for the ack of a send flow control
    %% holds back. The reset tells it the stream is gone, so it exits, and
    %% its in-flight slot comes back only then.
    Inflight = counters:new(1, []),
    {Pid, Ref, ConnPid} = start_conn(#{
        http2_send_stall_timeout => 100,
        max_concurrent_requests => 10,
        inflight_counter => Inflight
    }),
    handshake(ConnPid, []),
    request(ConnPid, 1, ~"/stream/large"),
    {65535, false} = data_bytes(1, 65535),
    Worker = stream_worker(ConnPid),
    WorkerRef = monitor(process, Worker),
    {1, cancel} = expect_rst(),
    receive
        {'DOWN', WorkerRef, process, Worker, stream_reset} -> ok
    after 1000 -> ct:fail(worker_not_reset)
    end,
    ok = wait_inflight(Inflight, 0),
    ping_pong(ConnPid),
    cleanup(Pid, Ref).

stalled_loop_push_resets_its_worker(_Config) ->
    %% An event stream whose client opened no window for it: the first push
    %% waits, and its worker with it, until the stream is reset.
    {Pid, Ref, ConnPid} = start_conn(#{http2_send_stall_timeout => 100}),
    handshake(ConnPid, [{?INITIAL_WINDOW_SIZE, 0}]),
    request(ConnPid, 1, ~"/loop"),
    1 = headers_stream(expect_send_type(1)),
    Worker = wait_for_register(roadrunner_h2_loop_test),
    WorkerRef = monitor(process, Worker),
    Worker ! {push, ~"hello"},
    {1, cancel} = expect_rst(),
    receive
        {'DOWN', WorkerRef, process, Worker, _} -> ok
    after 1000 -> ct:fail(worker_not_reset)
    end,
    ping_pong(ConnPid),
    cleanup(Pid, Ref).

progressing_reader_is_not_reset(_Config) ->
    %% A client that opens its window a little at a time is reading: every
    %% byte sent starts the wait over. The stream stalls, the client opens
    %% 1000 bytes a sixth of a timeout later, and the timer that fires at
    %% the first stall's timeout finds the stream waiting only since then.
    {Pid, Ref, ConnPid} = start_conn(#{http2_send_stall_timeout => 600}),
    handshake(ConnPid, []),
    request(ConnPid, 1, ~"/large100k"),
    {65535, false} = data_bytes(1, 65535),
    1 = erlang:trace(ConnPid, true, ['receive']),
    ping_pong(ConnPid),
    ok = spin_past(erlang:monotonic_time(millisecond) + 100),
    serve_recv(ConnPid, [
        encode_frame({window_update, 0, 1000}), encode_frame({window_update, 1, 1000})
    ]),
    {1000, false} = data_bytes(1, 1000),
    ok = stall_timer_fired(ConnPid),
    ping_pong(ConnPid),
    cleanup(Pid, Ref).

conn_window_reader_keeps_other_streams(_Config) ->
    %% The connection window is what holds both streams back, and the
    %% client opens it as it reads. Stream 1, first in line, takes what it
    %% opens; stream 3 gets none of it, but DATA goes out on the
    %% connection, so the client is reading and stream 3 is not reset at
    %% the timeout its wait began with.
    {Pid, Ref, ConnPid} = start_conn(#{http2_send_stall_timeout => 1000}),
    handshake(ConnPid, [{?INITIAL_WINDOW_SIZE, 1_000_000}]),
    request(ConnPid, 1, ~"/large100k"),
    {65535, false} = data_bytes(1, 65535),
    1 = erlang:trace(ConnPid, true, ['receive']),
    request(ConnPid, 3, ~"/large100k"),
    3 = headers_stream(expect_send_type(1)),
    ping_pong(ConnPid),
    ok = spin_past(erlang:monotonic_time(millisecond) + 300),
    serve_recv(ConnPid, encode_frame({window_update, 0, 1000})),
    {1000, false} = data_bytes(1, 1000),
    ok = stall_timer_fired(ConnPid),
    ping_pong(ConnPid),
    cleanup(Pid, Ref).

settings_shrink_moves_wait_to_stream_window(_Config) ->
    %% Stream 3 waits for the connection window until a SETTINGS frame
    %% closes its own: from then it waits on that, so the DATA stream 1
    %% sends later on the connection does not start its wait over. Stream
    %% 3 is reset at its timeout while stream 1, which made progress since,
    %% is reset only at its own, later.
    {Pid, Ref, ConnPid} = start_conn(#{http2_send_stall_timeout => 300}),
    handshake(ConnPid, [{?INITIAL_WINDOW_SIZE, 1_000_000}]),
    request(ConnPid, 1, ~"/large100k"),
    {65535, false} = data_bytes(1, 65535),
    request(ConnPid, 3, ~"/large100k"),
    3 = headers_stream(expect_send_type(1)),
    serve_recv(ConnPid, encode_frame({settings, 0, [{?INITIAL_WINDOW_SIZE, 0}]})),
    <<_:24, 4, 1, _/binary>> = expect_send(),
    ping_pong(ConnPid),
    ok = spin_past(erlang:monotonic_time(millisecond) + 150),
    %% Stream 1's window is now -65535: open 1000 bytes of it, and of the
    %% connection's.
    serve_recv(ConnPid, [
        encode_frame({window_update, 1, 65535 + 1000}), encode_frame({window_update, 0, 1000})
    ]),
    {1000, false} = data_bytes(1, 1000),
    {3, cancel} = expect_rst(),
    ping_pong(ConnPid),
    {1, cancel} = expect_rst(),
    ping_pong(ConnPid),
    cleanup(Pid, Ref).

idle_loop_stream_is_not_reset(_Config) ->
    %% An event stream with nothing to send holds nothing back, however
    %% long it waits for its next event: it is not stalled. A stall check
    %% past its timeout resets nothing, and a push after it goes out.
    {Pid, Ref, ConnPid} = start_conn(#{http2_send_stall_timeout => 1}),
    handshake(ConnPid, []),
    request(ConnPid, 1, ~"/loop"),
    1 = headers_stream(expect_send_type(1)),
    Worker = wait_for_register(roadrunner_h2_loop_test),
    ok = spin_past(erlang:monotonic_time(millisecond) + 1),
    ConnPid ! {timeout, make_ref(), {roadrunner_conn_loop_http2, send_stall}},
    ping_pong(ConnPid),
    Worker ! {push, ~"hello"},
    {13, false} = data_bytes(1, 13),
    cleanup(Pid, Ref).

window_opened_in_time_completes(_Config) ->
    %% A body that waits less than the timeout for its window goes out
    %% whole, and the timer that fires later finds nothing to reset.
    {Pid, Ref, ConnPid} = start_conn(#{http2_send_stall_timeout => 200}),
    handshake(ConnPid, []),
    1 = erlang:trace(ConnPid, true, ['receive']),
    request(ConnPid, 1, ~"/large100k"),
    {65535, false} = data_bytes(1, 65535),
    serve_recv(ConnPid, [
        encode_frame({window_update, 0, 100_000}), encode_frame({window_update, 1, 100_000})
    ]),
    {34465, true} = data_bytes(1, 34465),
    ok = stall_timer_fired(ConnPid),
    ping_pong(ConnPid),
    cleanup(Pid, Ref).

%% =============================================================================
%% Helpers
%% =============================================================================

start_conn(Extra0) ->
    Self = self(),
    Extra = roadrunner_test_proto_opts:with_slot_keeper(Extra0),
    Counter = counters:new(1, [write_concurrency]),
    ok = counters:add(Counter, 1, 1),
    Handler = roadrunner_h2_test_handler,
    ProtoOpts = roadrunner_test_proto_opts:new(
        maps:merge(
            #{
                max_concurrent_requests => infinity,
                client_counter => Counter,
                listener_name => h2_send_stall_test,
                dispatch => {handler, Handler, fun Handler:handle/1, undefined},
                middlewares => [],
                handler_spawn_opts => [{fullsweep_after, 0}],
                tls_handshake_timeout => 5000,
                %% The RFC 9113 §6.9.2 baseline windows these cases count from.
                http2_conn_window => 65535,
                http2_stream_window => 65535,
                http2_window_refill_threshold => 32768
            },
            Extra
        )
    ),
    Pid = spawn(fun() ->
        receive
            ready -> ok
        end,
        roadrunner_conn_loop_http2:enter(
            {fake, Self},
            ProtoOpts,
            h2_send_stall_test,
            undefined,
            {erlang:monotonic_time(), h2_send_stall_test, undefined},
            <<>>
        )
    end),
    Ref = monitor(process, Pid),
    Pid ! ready,
    {Pid, Ref, Pid}.

%% The preface and a SETTINGS frame with `Params`, then the server's
%% SETTINGS and the ACK of ours.
handshake(ConnPid, Params) ->
    _ = expect_send(),
    serve_recv(ConnPid, [?PREFACE, encode_frame({settings, 0, Params})]),
    _ = expect_send(),
    ok.

request(ConnPid, StreamId, Path) ->
    Enc = roadrunner_http2_hpack:new_encoder(4096),
    {Hpack, _} = roadrunner_http2_hpack:encode(
        [
            {~":method", ~"GET"},
            {~":scheme", ~"https"},
            {~":authority", ~"localhost"},
            {~":path", Path}
        ],
        Enc
    ),
    serve_recv(ConnPid, encode_frame({headers, StreamId, 16#04 bor 16#01, undefined, Hpack})).

encode_frame(Frame) ->
    iolist_to_binary(roadrunner_http2_frame:encode(Frame)).

serve_recv(ConnPid, Data) ->
    drain_setopts(),
    ConnPid ! {roadrunner_fake_data, {fake, self()}, iolist_to_binary([Data])},
    ok.

drain_setopts() ->
    receive
        {roadrunner_fake_setopts, _, _} -> drain_setopts()
    after 0 -> ok
    end.

%% A PING answered with its ACK: the conn is alive and has handled
%% everything sent before it.
ping_pong(ConnPid) ->
    serve_recv(ConnPid, encode_frame({ping, 0, <<1:64>>})),
    <<_:24, 6, 1, _/binary>> = expect_send(),
    ok.

expect_send() ->
    receive
        {roadrunner_fake_send, _Pid, Data} -> iolist_to_binary(Data)
    after 1000 -> ct:fail(no_send)
    end.

expect_send_type(Type) ->
    case expect_send() of
        <<_:24, Type, _/binary>> = Bytes -> Bytes;
        Bytes -> ct:fail({wrong_frame_type, expected, Type, got, Bytes})
    end.

expect_rst() ->
    {ok, {rst_stream, StreamId, Code}, <<>>} =
        roadrunner_http2_frame:parse(expect_send_type(?RST_STREAM), 16384),
    {StreamId, Code}.

headers_stream(<<_:24, 1, _Flags, 0:1, StreamId:31, _/binary>>) ->
    StreamId.

%% Read sends until `Want` bytes of DATA on `StreamId` came: the HEADERS
%% before them are skipped. Returns the bytes and whether END_STREAM was
%% seen.
data_bytes(StreamId, Want) ->
    data_bytes(StreamId, Want, 0, false).

data_bytes(_StreamId, Want, Got, Fin) when Got >= Want ->
    {Got, Fin};
data_bytes(StreamId, Want, Got, _Fin) ->
    {Bytes, Fin} = frames(expect_send(), StreamId, 0, false),
    data_bytes(StreamId, Want, Got + Bytes, Fin).

frames(<<>>, _StreamId, Bytes, Fin) ->
    {Bytes, Fin};
frames(Bin, StreamId, Bytes, Fin) ->
    case roadrunner_http2_frame:parse(Bin, 16384) of
        {ok, {data, StreamId, Flags, Payload, _Len}, Rest} ->
            frames(Rest, StreamId, Bytes + iolist_size(Payload), (Flags band 16#01) =/= 0);
        {ok, {headers, StreamId, _, _, _}, Rest} ->
            frames(Rest, StreamId, Bytes, Fin);
        {ok, Other, _Rest} ->
            ct:fail({unexpected_frame, Other})
    end.

%% The stream worker the conn `ConnPid` started for stream 1.
stream_worker(ConnPid) ->
    [Worker] = [
        P
     || P <- processes(),
        proc_lib:get_label(P) =:= {roadrunner_http2_stream_worker, 1},
        monitors(P, ConnPid)
    ],
    Worker.

monitors(Pid, Target) ->
    case process_info(Pid, monitors) of
        {monitors, Monitors} -> lists:member({process, Target}, Monitors);
        undefined -> false
    end.

wait_inflight(Counter, N) ->
    wait_inflight(Counter, N, erlang:monotonic_time(millisecond) + 1000).

wait_inflight(Counter, N, Deadline) ->
    case counters:get(Counter, 1) of
        N ->
            ok;
        Other ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true ->
                    erlang:yield(),
                    wait_inflight(Counter, N, Deadline);
                false ->
                    ct:fail({inflight, Other, expected, N})
            end
    end.

wait_for_register(Name) ->
    wait_for_register(Name, erlang:monotonic_time(millisecond) + 1000).

wait_for_register(Name, Deadline) ->
    case whereis(Name) of
        undefined ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true ->
                    erlang:yield(),
                    wait_for_register(Name, Deadline);
                false ->
                    ct:fail({not_registered, Name})
            end;
        Pid ->
            Pid
    end.

%% Wait, with the conn traced for `receive`, for its stall timer to fire,
%% and stop tracing it.
stall_timer_fired(ConnPid) ->
    receive
        {trace, ConnPid, 'receive', {timeout, _, {roadrunner_conn_loop_http2, send_stall}}} -> ok
    after 2000 -> ct:fail(stall_timer_not_fired)
    end,
    _ = erlang:trace(ConnPid, false, ['receive']),
    ok.

%% Yield until the millisecond clock is past `Until`: the stall clocks
%% count in milliseconds, so this is what puts a wait past a point.
spin_past(Until) ->
    case erlang:monotonic_time(millisecond) > Until of
        true ->
            ok;
        false ->
            erlang:yield(),
            spin_past(Until)
    end.

cleanup(Pid, Ref) ->
    exit(Pid, kill),
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    end.
