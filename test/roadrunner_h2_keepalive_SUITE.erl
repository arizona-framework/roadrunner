-module(roadrunner_h2_keepalive_SUITE).
-moduledoc """
The HTTP/2 connection keepalive policy, driven by a hand-written client
over plain TCP: what an idle connection does when the client pings it.
""".

-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([
    pings_do_not_keep_an_idle_conn_open/1,
    other_frames_do_not_keep_an_idle_conn_open/1,
    a_request_restarts_the_idle_timeout/1,
    a_reset_of_the_last_stream_leaves_the_conn_idle/1,
    a_crash_of_the_last_handler_leaves_the_conn_idle/1,
    a_conn_left_idle_by_a_reset_hibernates/1
]).

%% The idle timeout the cases run with (`keep_alive_timeout`, shortened
%% through the conn's test hook).
-define(IDLE_TIMEOUT, 300).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        pings_do_not_keep_an_idle_conn_open,
        other_frames_do_not_keep_an_idle_conn_open,
        a_request_restarts_the_idle_timeout,
        a_reset_of_the_last_stream_leaves_the_conn_idle,
        a_crash_of_the_last_handler_leaves_the_conn_idle,
        a_conn_left_idle_by_a_reset_hibernates
    ].

init_per_suite(Config) ->
    {ok, _} = roadrunner_test_event_handler:start(),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(Case, Config) ->
    ok = persistent_term:put({roadrunner_conn_loop_http2, idle_timeout}, ?IDLE_TIMEOUT),
    {ok, _} = roadrunner_listener:start_link(
        ?MODULE,
        listener_opts(Case, #{
            port => 0,
            protocols => [{http2, #{}}],
            routes => [
                {~"/", roadrunner_h2_test_handler},
                {~"/stream/bad-trailers", roadrunner_h2_test_handler}
            ]
        })
    ),
    [{port, roadrunner_listener:port(?MODULE)} | Config].

end_per_testcase(_Case, _Config) ->
    ok = roadrunner_listener:stop(?MODULE),
    _ = persistent_term:erase({roadrunner_conn_loop_http2, idle_timeout}),
    ok.

listener_opts(a_conn_left_idle_by_a_reset_hibernates, Opts) ->
    Opts#{hibernate_after => 50};
listener_opts(_Case, Opts) ->
    Opts.

%% =============================================================================
%% Cases
%% =============================================================================

pings_do_not_keep_an_idle_conn_open(Config) ->
    %% A client that pings a conn with no request on it does not keep it
    %% open: the idle timeout counts from the start, and the conn closes
    %% with GOAWAY(NO_ERROR) as an idle one does.
    Ref = attach_conn_close(),
    Start = erlang:monotonic_time(millisecond),
    C = open(Config),
    {Close, C1} = ping_until_goaway(C),
    ok = idle_close(Close, 0),
    ?assert(erlang:monotonic_time(millisecond) - Start >= ?IDLE_TIMEOUT),
    ?assertEqual(keep_alive_timeout, conn_closed(Ref)),
    closed(C1).

other_frames_do_not_keep_an_idle_conn_open(Config) ->
    %% Nor do the other frames that carry no request: SETTINGS (each one
    %% answered), WINDOW_UPDATE, PRIORITY and a frame of an unknown type.
    Ref = attach_conn_close(),
    Start = erlang:monotonic_time(millisecond),
    C = open(Config),
    {Close, C1} = chatter_until_goaway(C),
    ok = idle_close(Close, 0),
    ?assert(erlang:monotonic_time(millisecond) - Start >= ?IDLE_TIMEOUT),
    ?assertEqual(keep_alive_timeout, conn_closed(Ref)),
    closed(C1).

a_request_restarts_the_idle_timeout(Config) ->
    %% A request is what keeps a conn in use: the idle timeout starts over
    %% once its stream is done, whatever the client sends meanwhile. The
    %% request goes a while in, so the close it brings (an idle timeout
    %% after its stream ended, so after it was sent) comes after the one
    %% the conn started with would have. The idle timeout is longer here,
    %% so the request makes it in time under load.
    ok = persistent_term:put({roadrunner_conn_loop_http2, idle_timeout}, 1000),
    C0 = open(Config),
    {_, C1} = until(send_ping(C0, 1), fun is_ping_ack/1),
    receive
    after 200 -> ok
    end,
    Sent = erlang:monotonic_time(millisecond),
    {200, _, C2} = response(send_headers(C1, 1), 1),
    {Close, C3} = ping_until_goaway(C2),
    ok = idle_close(Close, 1),
    ?assert(erlang:monotonic_time(millisecond) - Sent >= 1000),
    closed(C3).

a_reset_of_the_last_stream_leaves_the_conn_idle(Config) ->
    %% A request reset before its body came (no handler started for it) is
    %% gone like one that ended: the idle timeout counts from the reset,
    %% and frames that carry no request do not hold the conn open.
    Ref = attach_conn_close(),
    C = send_post_headers(open(Config), 1),
    Reset = erlang:monotonic_time(millisecond),
    C0 = send_rst(C, 1),
    {Close, C1} = chatter_until_goaway(C0),
    ok = idle_close(Close, 1),
    ?assert(erlang:monotonic_time(millisecond) - Reset >= ?IDLE_TIMEOUT),
    ?assertEqual(keep_alive_timeout, conn_closed(Ref)),
    closed(C1).

a_crash_of_the_last_handler_leaves_the_conn_idle(Config) ->
    %% Nor does a stream the server resets for its handler's crash.
    Ref = attach_conn_close(),
    Sent = erlang:monotonic_time(millisecond),
    C0 = send_headers(open(Config), 1, ~"/stream/bad-trailers"),
    {Frames, C1} = until(C0, fun
        ({rst_stream, 1, _}) -> true;
        (_) -> false
    end),
    ?assertMatch({rst_stream, 1, internal_error}, lists:last(Frames)),
    {Close, C2} = chatter_until_goaway(C1),
    ok = idle_close(Close, 1),
    ?assert(erlang:monotonic_time(millisecond) - Sent >= ?IDLE_TIMEOUT),
    ?assertEqual(keep_alive_timeout, conn_closed(Ref)),
    closed(C2).

a_conn_left_idle_by_a_reset_hibernates(Config) ->
    %% With `hibernate_after` shorter than the idle timeout, a conn whose
    %% last stream was reset parks as any idle one does. The idle timeout
    %% is long here, so the conn stays parked to be seen under load.
    ok = persistent_term:put({roadrunner_conn_loop_http2, idle_timeout}, 60_000),
    #{sock := Sock} = send_rst(send_post_headers(open(Config), 1), 1),
    ok = await_hibernating_conn(erlang:monotonic_time(millisecond) + 5000),
    ok = gen_tcp:close(Sock).

%% =============================================================================
%% Helpers
%% =============================================================================

%% Poll until this listener's conn hibernates, or fail at `Deadline`.
await_hibernating_conn(Deadline) ->
    Hibernating = [
        Pid
     || Pid <- processes(),
        {roadrunner_conn_loop_http2, ?MODULE, x} =:= label_of(Pid),
        {current_function, {erlang, hibernate, 3}} =:= process_info(Pid, current_function)
    ],
    case Hibernating of
        [_ | _] ->
            ok;
        [] ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true ->
                    receive
                    after 10 -> ok
                    end,
                    await_hibernating_conn(Deadline);
                false ->
                    ct:fail(conn_did_not_hibernate)
            end
    end.

label_of(Pid) ->
    case proc_lib:get_label(Pid) of
        {roadrunner_conn_loop_http2, _, _} = Label -> setelement(3, Label, x);
        _ -> undefined
    end.

%% A POST without END_STREAM: its body is still to come, so (with the
%% body read before the handler runs) no handler starts.
send_post_headers(#{sock := Sock, enc := Enc} = C, StreamId) ->
    Fields = [
        {~":method", ~"POST"},
        {~":scheme", ~"http"},
        {~":authority", ~"x"},
        {~":path", ~"/"}
    ],
    {Block, Enc1} = roadrunner_http2_hpack:encode(Fields, Enc),
    ok = gen_tcp:send(
        Sock, roadrunner_http2_frame:encode({headers, StreamId, 16#04, undefined, Block})
    ),
    C#{enc := Enc1}.

send_rst(#{sock := Sock} = C, StreamId) ->
    ok = gen_tcp:send(Sock, roadrunner_http2_frame:encode({rst_stream, StreamId, cancel})),
    C.

attach_conn_close() ->
    Self = self(),
    Ref = make_ref(),
    ok = telemetry:attach(
        Ref,
        [roadrunner, listener, conn_close],
        fun(_Event, _Measurements, #{listener_name := ?MODULE, reason := Reason}, _Config) ->
            Self ! {conn_closed, Ref, Reason}
        end,
        undefined
    ),
    Ref.

conn_closed(Ref) ->
    receive
        {conn_closed, Ref, Reason} ->
            ok = telemetry:detach(Ref),
            Reason
    after 5000 -> ct:fail(conn_not_closed)
    end.

%% Send frames that carry no request, each round once the server
%% answered the last round's SETTINGS, until it sends a GOAWAY.
chatter_until_goaway(#{sock := Sock} = C0) ->
    %% The server may have closed already: its GOAWAY is still there to read.
    _ = gen_tcp:send(Sock, [
        roadrunner_http2_frame:encode({window_update, 0, 1}),
        %% PRIORITY on idle stream 1 (RFC 9113 §6.3 allows it).
        <<5:24, 2, 0, 0:1, 1:31, 0:1, 0:31, 15>>,
        %% An unknown type, ignored (RFC 9113 §4.1).
        <<0:24, 16#20, 0, 0:32>>,
        roadrunner_http2_frame:encode({settings, 0, []})
    ]),
    case
        next_frame_until(C0, fun
            ({settings, 1, _}) -> true;
            ({goaway, _, _, _}) -> true;
            (_) -> false
        end)
    of
        {{settings, 1, _}, C1} -> chatter_until_goaway(C1);
        {Close, C1} -> {Close, C1}
    end.

next_frame_until(C0, Pred) ->
    {Frame, C1} = idle_frame(C0),
    case Frame =:= closed orelse Pred(Frame) of
        true -> {Frame, C1};
        false -> next_frame_until(C1, Pred)
    end.

%% Ping, each PING after the last one's ACK, until the server sends a
%% GOAWAY; return it.
ping_until_goaway(C0) ->
    case next_frame_until(send_ping(C0, 1), fun(F) -> is_ping_ack(F) orelse is_goaway(F) end) of
        {{ping, 1, _}, C1} -> ping_until_goaway(C1);
        {Close, C1} -> {Close, C1}
    end.

%% How an idle conn ended, as the client saw it: its GOAWAY(NO_ERROR)
%% naming `LastStreamId`, or the close alone when a frame the client sent
%% after the server closed made the client's kernel drop what was unread
%% (the close reason the test checks says why it closed).
idle_close({goaway, LastStreamId, no_error, _}, LastStreamId) -> ok;
idle_close(closed, _LastStreamId) -> ok.

%% The next frame, or `closed` once the server closed the connection.
idle_frame(#{sock := Sock, buf := Buf} = C) ->
    case roadrunner_http2_frame:parse(Buf, 16384) of
        {more, _} ->
            case gen_tcp:recv(Sock, 0, 5000) of
                {ok, Data} -> idle_frame(C#{buf := <<Buf/binary, Data/binary>>});
                {error, _} -> {closed, C#{buf := <<>>}}
            end;
        _Frame ->
            next_frame(C)
    end.

is_ping_ack({ping, 1, _}) -> true;
is_ping_ack(_Frame) -> false.

is_goaway({goaway, _, _, _}) -> true;
is_goaway(_Frame) -> false.

%% The server closed the connection. A frame the client sent after the
%% close may have the kernel report it as a reset rather than a close.
closed(#{sock := Sock}) ->
    {error, _} = gen_tcp:recv(Sock, 0, 5000),
    ok.

%% --- HTTP/2 client ---

open(Config) ->
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, ?config(port, Config), [binary, {active, false}], 5000
    ),
    ok = gen_tcp:send(Sock, [
        ~"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", roadrunner_http2_frame:encode({settings, 0, []})
    ]),
    #{
        sock => Sock,
        buf => <<>>,
        enc => roadrunner_http2_hpack:new_encoder(4096),
        dec => roadrunner_http2_hpack:new_decoder(4096)
    }.

send_ping(#{sock := Sock} = C, N) ->
    ok = gen_tcp:send(Sock, roadrunner_http2_frame:encode({ping, 0, <<N:64>>})),
    C.

%% A GET with END_STREAM.
send_headers(C, StreamId) ->
    send_headers(C, StreamId, ~"/").

send_headers(#{sock := Sock, enc := Enc} = C, StreamId, Path) ->
    Fields = [
        {~":method", ~"GET"},
        {~":scheme", ~"http"},
        {~":authority", ~"x"},
        {~":path", Path}
    ],
    {Block, Enc1} = roadrunner_http2_hpack:encode(Fields, Enc),
    ok = gen_tcp:send(
        Sock, roadrunner_http2_frame:encode({headers, StreamId, 16#05, undefined, Block})
    ),
    C#{enc := Enc1}.

%% Stream `StreamId`'s status and body, and the connection after them.
response(C, StreamId) ->
    response(C, StreamId, undefined, <<>>).

response(C, StreamId, Status, Body) ->
    case next_frame(C) of
        {{headers, StreamId, Flags, Headers}, C1} ->
            {_, S} = lists:keyfind(~":status", 1, Headers),
            Status1 = binary_to_integer(S),
            case Flags band 16#01 of
                0 -> response(C1, StreamId, Status1, Body);
                _ -> {Status1, Body, C1}
            end;
        {{data, StreamId, Flags, Data, _}, C1} ->
            Body1 = <<Body/binary, Data/binary>>,
            case Flags band 16#01 of
                0 -> response(C1, StreamId, Status, Body1);
                _ -> {Status, Body1, C1}
            end;
        {_Other, C1} ->
            response(C1, StreamId, Status, Body)
    end.

%% Every frame up to and including the first `Pred` picks; the server's
%% SETTINGS and the ACK of ours are left out.
until(C, Pred) ->
    until(C, Pred, []).

until(C, Pred, Acc) ->
    {Frame, C1} = next_frame(C),
    case Pred(Frame) of
        true -> {lists:reverse([Frame | Acc]), C1};
        false when element(1, Frame) =:= settings -> until(C1, Pred, Acc);
        false -> until(C1, Pred, [Frame | Acc])
    end.

next_frame(#{sock := Sock, buf := Buf, dec := Dec} = C) ->
    case roadrunner_http2_frame:parse(Buf, 16384) of
        {ok, {headers, StreamId, Flags, _Priority, Block}, Rest} ->
            {ok, Headers, Dec1} = roadrunner_http2_hpack:decode(Block, Dec),
            {{headers, StreamId, Flags, Headers}, C#{buf := Rest, dec := Dec1}};
        {ok, Frame, Rest} ->
            {Frame, C#{buf := Rest}};
        _More ->
            {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
            next_frame(C#{buf := <<Buf/binary, Data/binary>>})
    end.
