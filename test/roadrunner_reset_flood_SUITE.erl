-module(roadrunner_reset_flood_SUITE).
-moduledoc """
A client that resets its requests while their handlers still run (the
HTTP/2 rapid reset attack, CVE-2023-44487, and its HTTP/3 form) gets no
more handlers running at once on a connection than the connection's stream
limit. Before an HTTP/2 client acknowledges our SETTINGS that limit is not
in force yet (RFC 9113 §6.5.2), so the streams it opens with its preface
are served, up to a fixed bound, but run no more at once than the limit:
the rest wait their turn. The handler
(`roadrunner_h2_slot_handler`) announces itself and runs until released,
ignoring the reset, so each one stands for work a client abandons.
""".

-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([
    h2_reset_handlers_hold_the_stream_limit/1,
    h2_slot_frees_when_a_reset_handler_ends/1,
    h2_reset_flood_gets_goaway/1,
    h2_client_with_open_streams_is_only_refused/1,
    h2_reset_at_a_normal_rate_is_served/1,
    h2_reset_of_an_answered_stream_frees_it/1,
    h2_burst_before_settings_ack_is_served/1,
    h2_over_limit_after_settings_ack_is_refused/1,
    h2_burst_past_the_pre_settings_bound_is_refused/1,
    h2_reset_flood_before_settings_ack_gets_goaway/1,
    h2_queued_stream_reset_is_dropped/1,
    h2_queued_stream_gets_its_body/1,
    h2_queued_manual_stream_reads_its_body/1,
    h2_drain_serves_queued_streams/1,
    h3_reset_handlers_hold_the_stream_credit/1,
    h3_credit_frees_when_a_reset_handler_ends/1,
    h3_reset_at_a_normal_rate_is_served/1,
    h3_request_after_stop_sending_is_not_served/1,
    h3_request_in_the_stop_sending_packet_is_not_served/1
]).

-define(MAX_STREAMS, 4).
%% The streams a client may open before it acknowledges our SETTINGS when
%% the advertised limit is lower (`?PRE_SETTINGS_STREAMS` in
%% `roadrunner_conn_loop_http2`).
-define(PRE_SETTINGS_STREAMS, 100).
-define(COLLECTOR, roadrunner_h2_slot_collector).
%% RFC 9114 §8.1 H3_REQUEST_CANCELLED.
-define(H3_REQUEST_CANCELLED, 16#010C).
%% RFC 9000 §20.1 STREAM_LIMIT_ERROR.
-define(STREAM_LIMIT_ERROR, 16#04).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        h2_reset_handlers_hold_the_stream_limit,
        h2_slot_frees_when_a_reset_handler_ends,
        h2_reset_flood_gets_goaway,
        h2_client_with_open_streams_is_only_refused,
        h2_reset_at_a_normal_rate_is_served,
        h2_reset_of_an_answered_stream_frees_it,
        h2_burst_before_settings_ack_is_served,
        h2_over_limit_after_settings_ack_is_refused,
        h2_burst_past_the_pre_settings_bound_is_refused,
        h2_reset_flood_before_settings_ack_gets_goaway,
        h2_queued_stream_reset_is_dropped,
        h2_queued_stream_gets_its_body,
        h2_queued_manual_stream_reads_its_body,
        h2_drain_serves_queued_streams,
        h3_reset_handlers_hold_the_stream_credit,
        h3_credit_frees_when_a_reset_handler_ends,
        h3_reset_at_a_normal_rate_is_served,
        h3_request_after_stop_sending_is_not_served,
        h3_request_in_the_stop_sending_packet_is_not_served
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(crypto),
    {ok, _} = application:ensure_all_started(ssl),
    %% Stream workers other suites left running, which this one does not
    %% count (`stream_workers/0`).
    [{other_workers, stream_workers()} | Config].

end_per_suite(_Config) ->
    ok.

init_per_testcase(Case, Config) ->
    %% `stop_all/0` kills the previous case's handlers without waiting:
    %% start once their workers are gone, so none is counted here.
    _ = put(other_workers, ?config(other_workers, Config)),
    ok = await_down([monitor(process, P) || P <- stream_workers()]),
    true = register(?COLLECTOR, self()),
    {ok, _} = roadrunner_listener:start_link(?MODULE, listener_opts(Case, protocol(Case))),
    [{port, roadrunner_listener:port(?MODULE)} | Config].

end_per_testcase(_Case, _Config) ->
    ok = roadrunner_h2_slot_handler:stop_all(),
    ok = roadrunner_listener:stop(?MODULE),
    true = unregister(?COLLECTOR),
    ok.

protocol(Case) ->
    case atom_to_binary(Case) of
        <<"h2_", _/binary>> -> http2;
        <<"h3_", _/binary>> -> http3
    end.

listener_opts(h2_queued_manual_stream_reads_its_body, http2) ->
    Opts = listener_opts(any, http2),
    Opts#{
        body_buffering => manual,
        routes => [
            {~"/", roadrunner_h2_slot_handler},
            {~"/echo", roadrunner_manual_body_handler, read}
        ]
    };
listener_opts(_Case, http2) ->
    #{
        port => 0,
        %% The client syncs on PINGs (`ping_sync/1`) after frames that
        %% bring no HEADERS or DATA back, so many would be strikes.
        protocols => [{http2, #{max_concurrent_streams => ?MAX_STREAMS, ping_policy => false}}],
        routes => [
            {~"/", roadrunner_h2_slot_handler},
            {~"/answered", roadrunner_answer_then_hold_handler},
            {~"/echo", roadrunner_echo_body_handler}
        ]
    };
listener_opts(_Case, http3) ->
    #{
        port => 0,
        protocols => [{http3, #{max_streams_bidi => ?MAX_STREAMS}}],
        tls => roadrunner_test_certs:server_opts(),
        routes => roadrunner_h2_slot_handler
    }.

%% =============================================================================
%% HTTP/2
%% =============================================================================

h2_reset_handlers_hold_the_stream_limit(Config) ->
    %% Eight requests, each reset at once: only the first four start a
    %% handler, which keeps running after its reset; the rest are refused
    %% (retry-safe REFUSED_STREAM, RFC 9113 §8.7) until one of them ends.
    Ids = stream_ids(1, 2 * ?MAX_STREAMS),
    C0 = lists:foldl(fun(Id, C) -> send_rst(send_headers(C, Id), Id) end, open(Config), Ids),
    {Frames, _C1} = ping_sync(C0),
    Handlers = handlers_started(?MAX_STREAMS),
    ?assert(lists:all(fun erlang:is_process_alive/1, Handlers)),
    ?assertEqual(
        [{rst_stream, Id, refused_stream} || Id <- lists:nthtail(?MAX_STREAMS, Ids)],
        [F || {rst_stream, _, _} = F <- Frames]
    ),
    ?assertEqual([], [F || {goaway, _, _, _} = F <- Frames]),
    release(Handlers).

h2_slot_frees_when_a_reset_handler_ends(Config) ->
    %% A reset handler gives its stream back when it ends: the next request
    %% is served.
    C = fill_with_reset_handlers(open(Config)),
    [First | Rest] = handlers_started(?MAX_STREAMS),
    Over = 2 * ?MAX_STREAMS + 1,
    {Frames, C0} = ping_sync(send_headers(C, Over)),
    ?assertEqual([{rst_stream, Over, refused_stream}], [F || {rst_stream, _, _} = F <- Frames]),
    Ref = monitor(process, First),
    First ! release,
    receive
        {'DOWN', Ref, process, First, _} -> ok
    end,
    {Id, C1} = admitted(C0, Over + 2),
    [Next] = handlers_started(1),
    Next ! release,
    ?assertMatch({200, _, _}, response(C1, Id)),
    release(Rest).

h2_reset_flood_gets_goaway(Config) ->
    %% With the limit held by handlers whose streams were reset, a client
    %% that keeps opening streams past it is refused up to the limit's worth
    %% of times, then told to calm down (RFC 9113 §5.4.1, §7) and closed.
    C0 = fill_with_reset_handlers(open(Config)),
    Handlers = handlers_started(?MAX_STREAMS),
    Refused = stream_ids(2 * ?MAX_STREAMS + 1, ?MAX_STREAMS),
    Over = 4 * ?MAX_STREAMS + 1,
    C1 = lists:foldl(fun(Id, C) -> send_headers(C, Id) end, C0, Refused ++ [Over]),
    {Frames, _C2} = until(C1, fun
        ({goaway, _, _, _}) -> true;
        (_) -> false
    end),
    ?assertEqual(
        [{rst_stream, Id, refused_stream} || Id <- Refused],
        [F || {rst_stream, _, _} = F <- Frames]
    ),
    ?assertMatch({goaway, 2 * ?MAX_STREAMS - 1, enhance_your_calm, _}, lists:last(Frames)),
    release(Handlers).

h2_client_with_open_streams_is_only_refused(Config) ->
    %% One reset handler and three streams the client still waits on fill
    %% the limit. The client may well have opened more before it learnt the
    %% reset stream still counts, so it is only refused, however often, and
    %% its open streams are served.
    Open = stream_ids(1, ?MAX_STREAMS - 1),
    Reset = 2 * ?MAX_STREAMS - 1,
    C0 = lists:foldl(fun(Id, C) -> send_headers(C, Id) end, open(Config), Open),
    C1 = send_rst(send_headers(C0, Reset), Reset),
    Handlers = handlers_started(?MAX_STREAMS),
    Refused = stream_ids(2 * ?MAX_STREAMS + 1, 2 * ?MAX_STREAMS),
    C2 = lists:foldl(fun(Id, C) -> send_headers(C, Id) end, C1, Refused),
    {Frames, C3} = ping_sync(C2),
    ?assertEqual(
        [{rst_stream, Id, refused_stream} || Id <- Refused],
        [F || {rst_stream, _, _} = F <- Frames]
    ),
    ?assertEqual([], [F || {goaway, _, _, _} = F <- Frames]),
    release(Handlers),
    ?assertMatch({200, _, _}, response(C3, hd(Open))).

h2_reset_at_a_normal_rate_is_served(Config) ->
    %% A client that resets one request at a time, each handler ending
    %% before the next request, is served every time: no refusal, no GOAWAY,
    %% however many it resets over the connection's life.
    C = lists:foldl(
        fun(Id, C0) ->
            C1 = send_headers(C0, Id),
            [Handler] = handlers_started(1),
            C2 = send_rst(C1, Id),
            {_, C3} = ping_sync(C2),
            ok = stop(Handler),
            C3
        end,
        open(Config),
        stream_ids(1, 4 * ?MAX_STREAMS)
    ),
    Id = 8 * ?MAX_STREAMS + 1,
    C1 = send_headers(C, Id),
    [Handler] = handlers_started(1),
    Handler ! release,
    ?assertMatch({200, _, _}, response(C1, Id)).

h2_reset_of_an_answered_stream_frees_it(Config) ->
    %% A stream whose response is complete no longer counts toward the
    %% limit (RFC 9113 §5.1.2), even while its handler still runs; a reset
    %% from the client, sent before it saw the end, does not make it count
    %% again.
    {C0, Handlers} = lists:foldl(
        fun(Id, {C, Acc}) ->
            C1 = send_headers(C, Id, ~"/answered"),
            {200, ~"ok", C2} = response(C1, Id),
            [Handler] = handlers_started(1),
            {send_rst(C2, Id), [Handler | Acc]}
        end,
        {open(Config), []},
        stream_ids(1, ?MAX_STREAMS)
    ),
    Id = 2 * ?MAX_STREAMS + 1,
    C1 = send_headers(C0, Id),
    [Handler] = handlers_started(1),
    Handler ! release,
    {200, ~"ok", C2} = response(C1, Id),
    lists:foreach(fun(H) -> ok = stop(H) end, Handlers),
    {_, _} = ping_sync(C2).

h2_burst_before_settings_ack_is_served(Config) ->
    %% The preface, SETTINGS and eight times the limit's worth of requests
    %% in one write, before the client could have read our SETTINGS: the
    %% limit is not in force yet (RFC 9113 §6.5.2), so every request is
    %% served, but no more run at once than the limit: the rest wait and
    %% start, oldest first, as running ones end.
    Ids = stream_ids(1, 8 * ?MAX_STREAMS),
    {Frames, C1} = ping_sync(burst(Config, Ids, false)),
    ?assertEqual([], [F || {rst_stream, _, _} = F <- Frames]),
    _ = serve_in_turn(C1, Ids).

h2_over_limit_after_settings_ack_is_refused(Config) ->
    %% Once the client acknowledges our SETTINGS the limit is in force: the
    %% streams it opened before stay and are served in turn, and a new one
    %% is refused while they are open.
    Ids = stream_ids(1, 2 * ?MAX_STREAMS),
    C0 = settings_ack(burst(Config, Ids, false)),
    Over = 4 * ?MAX_STREAMS + 1,
    {Frames, C1} = ping_sync(send_headers(C0, Over)),
    ?assertEqual([{rst_stream, Over, refused_stream}], [F || {rst_stream, _, _} = F <- Frames]),
    _ = serve_in_turn(C1, Ids).

h2_burst_past_the_pre_settings_bound_is_refused(Config) ->
    %% Before the ACK the streams a client may open, running or waiting,
    %% are still bounded: past the bound, the next one is refused
    %% (retry-safe, RFC 9113 §8.7), and the ones within it are served.
    Ids = stream_ids(1, ?PRE_SETTINGS_STREAMS + 1),
    {Frames, C1} = ping_sync(burst(Config, Ids, false)),
    ?assertEqual(
        [{rst_stream, lists:last(Ids), refused_stream}],
        [F || {rst_stream, _, _} = F <- Frames]
    ),
    _ = serve_in_turn(C1, lists:droplast(Ids)).

h2_reset_flood_before_settings_ack_gets_goaway(Config) ->
    %% A rapid reset sent with the preface: the handlers of the reset
    %% streams hold the limit, so the streams after them are refused rather
    %% than left waiting on work the client abandoned, and a client that
    %% keeps opening them is told to calm down.
    Reset = stream_ids(1, ?MAX_STREAMS),
    Refused = stream_ids(2 * ?MAX_STREAMS + 1, ?MAX_STREAMS),
    Over = 4 * ?MAX_STREAMS + 1,
    C0 = burst(Config, Reset ++ Refused ++ [Over], true),
    Handlers = handlers_started(?MAX_STREAMS),
    {Frames, _C1} = until(C0, fun
        ({goaway, _, _, _}) -> true;
        (_) -> false
    end),
    ?assertEqual(
        [{rst_stream, Id, refused_stream} || Id <- Refused],
        [F || {rst_stream, _, _} = F <- Frames]
    ),
    ?assertMatch({goaway, 2 * ?MAX_STREAMS - 1, enhance_your_calm, _}, lists:last(Frames)),
    release(Handlers).

h2_queued_stream_reset_is_dropped(Config) ->
    %% A stream waiting its turn that the client resets is dropped: it
    %% never starts a handler, and the next one waiting takes its turn.
    Ids = stream_ids(1, 2 * ?MAX_STREAMS),
    {Running, [Dropped | Waiting]} = lists:split(?MAX_STREAMS, Ids),
    {Frames, C1} = ping_sync(send_rst(burst(Config, Ids, false), Dropped)),
    ?assertEqual([], [F || {rst_stream, _, _} = F <- Frames]),
    C2 = serve_in_turn(C1, Running, ?MAX_STREAMS),
    _ = serve_in_turn(C2, Waiting, ?MAX_STREAMS).

h2_queued_stream_gets_its_body(Config) ->
    %% A request with a body sent while the limit is full waits its turn
    %% with its whole body, and its handler gets it once it runs.
    Ids = stream_ids(1, ?MAX_STREAMS),
    Id = 2 * ?MAX_STREAMS + 1,
    C0 = send_post(burst(Config, Ids, false), Id, ~"queued body"),
    {[], C1} = rst_frames(ping_sync(C0)),
    Handlers = handlers_started(?MAX_STREAMS),
    workers_running(?MAX_STREAMS),
    release(Handlers),
    ?assertEqual({200, ~"queued body"}, echoed(C1, Id)).

h2_queued_manual_stream_reads_its_body(Config) ->
    %% In manual body mode a request waiting its turn has no handler to
    %% read its body yet: the DATA it gets stays with the stream, within
    %% its receive window, and is read once its handler runs.
    Ids = stream_ids(1, ?MAX_STREAMS),
    Id = 2 * ?MAX_STREAMS + 1,
    C0 = send_post(burst(Config, Ids, false), Id, ~"queued body"),
    {[], C1} = rst_frames(ping_sync(C0)),
    Handlers = handlers_started(?MAX_STREAMS),
    release(Handlers),
    ?assertEqual({200, ~"11"}, echoed(C1, Id)).

h2_drain_serves_queued_streams(Config) ->
    %% A drain started while streams wait their turn serves them too: they
    %% were opened before the final GOAWAY, so they run as the running ones
    %% end, and the connection closes after the last.
    Ids = stream_ids(1, 2 * ?MAX_STREAMS),
    {_, #{sock := Sock} = C0} = ping_sync(burst(Config, Ids, false)),
    ok = roadrunner_listener:notify_drain(?MODULE, erlang:monotonic_time(millisecond) + 30_000),
    {Announced, C1} = until(C0, fun
        ({ping, 0, _}) -> true;
        (_) -> false
    end),
    {ping, 0, Opaque} = lists:last(Announced),
    ok = gen_tcp:send(Sock, roadrunner_http2_frame:encode({ping, 1, Opaque})),
    {Final, C2} = until(C1, fun
        ({goaway, _, _, _}) -> true;
        (_) -> false
    end),
    ?assertEqual({goaway, lists:last(Ids), no_error, <<>>}, lists:last(Final)),
    #{buf := <<>>} = serve_in_turn(C2, Ids),
    ?assertEqual({error, closed}, gen_tcp:recv(Sock, 0, 5000)).

%% =============================================================================
%% HTTP/3
%% =============================================================================

h3_reset_handlers_hold_the_stream_credit(Config) ->
    %% Four requests cancelled while their handlers run keep the stream
    %% credit they took: the server grants no more (RFC 9000 §4.6), and a
    %% client opening a fifth anyway breaks the limit (STREAM_LIMIT_ERROR).
    Conn = h3_connect(Config),
    Handlers = h3_fill_with_cancelled(Conn),
    ?assertEqual([], max_streams_grants(Conn)),
    {ok, _} = roadrunner_quic_test_h3:open_request(Conn, h3_headers()),
    receive
        {quic_test_closed, Conn, Code} -> ?assertEqual(?STREAM_LIMIT_ERROR, Code)
    after 5000 -> ct:fail(no_stream_limit_error)
    end,
    release(Handlers).

h3_credit_frees_when_a_reset_handler_ends(Config) ->
    %% A cancelled handler that ends gives its stream credit back.
    Conn = h3_connect(Config),
    [First | Rest] = h3_fill_with_cancelled(Conn),
    First ! release,
    receive
        {quic_test_max_streams, Conn, bidi, Max} -> ?assertEqual(?MAX_STREAMS + 1, Max)
    after 5000 -> ct:fail(no_max_streams)
    end,
    {ok, StreamId} = roadrunner_quic_test_h3:open_request(Conn, h3_headers()),
    [Next] = handlers_started(1),
    Next ! release,
    ?assertMatch({200, _, ~"ok"}, roadrunner_quic_test_h3:collect(Conn, StreamId)),
    release(Rest),
    roadrunner_quic_test_h3:close(Conn).

h3_reset_at_a_normal_rate_is_served(Config) ->
    %% One cancelled request at a time, each handler ending before the
    %% next: credit keeps coming back, so every request is served.
    Conn = h3_connect(Config),
    lists:foreach(
        fun(_) ->
            {ok, StreamId} = roadrunner_quic_test_h3:open_request(Conn, h3_headers()),
            [Handler] = handlers_started(1),
            ok = roadrunner_quic_test_h3:cancel(Conn, StreamId),
            ?assertEqual(?H3_REQUEST_CANCELLED, server_reset(Conn, StreamId)),
            ok = stop(Handler)
        end,
        lists:seq(1, 4 * ?MAX_STREAMS)
    ),
    {ok, StreamId} = roadrunner_quic_test_h3:open_request(Conn, h3_headers()),
    [Handler] = handlers_started(1),
    Handler ! release,
    ?assertMatch({200, _, ~"ok"}, roadrunner_quic_test_h3:collect(Conn, StreamId)),
    roadrunner_quic_test_h3:close(Conn).

h3_request_after_stop_sending_is_not_served(Config) ->
    %% A client opens a stream with no bytes, stops our side of it, then
    %% sends a request on it: the server gave the stream up, so the request
    %% is not read and starts no handler (it would run on a stream whose
    %% credit already came back). The next request is served as usual.
    Conn = h3_connect(Config),
    Bogus = roadrunner_quic_test_conn:open_bidi(Conn),
    ok = roadrunner_quic_test_conn:send(Conn, Bogus, <<>>, false),
    ok = roadrunner_quic_test_conn:stop_sending(Conn, Bogus, ?H3_REQUEST_CANCELLED),
    ?assertEqual(?H3_REQUEST_CANCELLED, server_reset(Conn, Bogus)),
    Frame = roadrunner_quic_h3_frame:encode_headers(roadrunner_qpack:encode(h3_headers())),
    ok = roadrunner_quic_test_conn:send(Conn, Bogus, iolist_to_binary(Frame), true),
    {ok, StreamId} = roadrunner_quic_test_h3:open_request(Conn, h3_headers()),
    [Handler] = handlers_started(1),
    Handler ! release,
    ?assertMatch({200, _, ~"ok"}, roadrunner_quic_test_h3:collect(Conn, StreamId)),
    receive
        {handler_started, Pid} -> ct:fail({bogus_request_served, Pid})
    after 0 -> ok
    end,
    roadrunner_quic_test_h3:close(Conn).

h3_request_in_the_stop_sending_packet_is_not_served(Config) ->
    %% The same, all in one packet: the request reaches the server's
    %% connection loop before it gives the stream up, and is still not read.
    Conn = h3_connect(Config),
    Bogus = roadrunner_quic_test_conn:open_bidi(Conn),
    Frame = iolist_to_binary(
        roadrunner_quic_h3_frame:encode_headers(roadrunner_qpack:encode(h3_headers()))
    ),
    ok = roadrunner_quic_test_conn:send_frames(Conn, [
        {stream, Bogus, 0, <<>>, false},
        {stop_sending, Bogus, ?H3_REQUEST_CANCELLED},
        {stream, Bogus, 0, Frame, true}
    ]),
    ?assertEqual(?H3_REQUEST_CANCELLED, server_reset(Conn, Bogus)),
    {ok, StreamId} = roadrunner_quic_test_h3:open_request(Conn, h3_headers()),
    [Handler] = handlers_started(1),
    Handler ! release,
    ?assertMatch({200, _, ~"ok"}, roadrunner_quic_test_h3:collect(Conn, StreamId)),
    receive
        {handler_started, Pid} -> ct:fail({bogus_request_served, Pid})
    after 0 -> ok
    end,
    roadrunner_quic_test_h3:close(Conn).

%% =============================================================================
%% Helpers
%% =============================================================================

%% `Count` odd stream ids from `First`.
stream_ids(First, Count) ->
    [First + 2 * N || N <- lists:seq(0, Count - 1)].

%% Open the connection's whole stream limit and reset every stream while
%% its handler runs.
fill_with_reset_handlers(C0) ->
    Ids = stream_ids(1, ?MAX_STREAMS),
    C1 = lists:foldl(fun(Id, C) -> send_rst(send_headers(C, Id), Id) end, C0, Ids),
    {Frames, C2} = ping_sync(C1),
    [] = [F || {rst_stream, _, _} = F <- Frames],
    C2.

%% Open stream `Id` once the connection has taken the end of a reset
%% handler in: until then it is refused, and the next id is tried.
admitted(C0, Id) ->
    C1 = send_headers(C0, Id),
    {Frames, C2} = ping_sync(C1),
    case [F || {rst_stream, StreamId, _} = F <- Frames, StreamId =:= Id] of
        [] -> {Id, C2};
        [{rst_stream, Id, refused_stream}] -> admitted(C2, Id + 2)
    end.

%% Serve `Ids`, opened in that order and with the first `?MAX_STREAMS` of
%% them running, the rest waiting: each turn, exactly the next
%% `?MAX_STREAMS` have handlers running and no other starts until they
%% end, so the streams run oldest first and never more than the limit at
%% once.
serve_in_turn(C, Ids) ->
    serve_in_turn(C, Ids, ?MAX_STREAMS).

serve_in_turn(C, [], _Turn) ->
    C;
serve_in_turn(C0, Ids, Turn) ->
    {Running, Rest} = lists:split(min(Turn, length(Ids)), Ids),
    Handlers = handlers_started(length(Running)),
    workers_running(length(Running)),
    Refs = [monitor(process, H) || H <- Handlers],
    release(Handlers),
    {Ended, C1} = responses_and_conn(C0, length(Running)),
    ?assertEqual([{Id, 200} || Id <- Running], lists:sort(Ended)),
    %% A handler runs in its stream's worker, which may outlive its
    %% response for a moment: the next turn counts workers once it is gone.
    ok = await_down(Refs),
    serve_in_turn(C1, Rest, Turn).

await_down(Refs) ->
    lists:foreach(
        fun(Ref) ->
            receive
                {'DOWN', Ref, process, _, _} -> ok
            end
        end,
        Refs
    ).

%% The stream workers of this suite alive now.
stream_workers() ->
    Others =
        case get(other_workers) of
            undefined -> [];
            Pids -> Pids
        end,
    [
        P
     || P <- processes(),
        process_info(P, initial_call) =:=
            {initial_call, {roadrunner_http2_stream_worker, init, 6}},
        not lists:member(P, Others)
    ].

%% No more stream workers run than `Count`, the handlers announced: a
%% stream waiting its turn has none. Every earlier one is gone, as the
%% connection dispatches a waiting stream only on a running one's end.
workers_running(Count) ->
    ?assertEqual(Count, length(stream_workers())).

handlers_started(0) ->
    [];
handlers_started(N) ->
    receive
        {handler_started, Pid} -> [Pid | handlers_started(N - 1)]
    after 5000 -> ct:fail({handlers_not_started, N})
    end.

release(Handlers) ->
    lists:foreach(fun(Pid) -> Pid ! release end, Handlers).

%% Release a handler and wait for it to end.
stop(Handler) ->
    Ref = monitor(process, Handler),
    Handler ! release,
    receive
        {'DOWN', Ref, process, Handler, _} -> ok
    end.

%% --- HTTP/2 client ---

%% A connection whose client has acknowledged our SETTINGS, so the stream
%% limit is in force.
open(Config) ->
    #{sock := Sock} = C = connect(Config),
    ok = gen_tcp:send(Sock, preface()),
    settings_ack(C).

%% A connection opened by one write: the preface, then the requests on
%% `Ids`, each reset at once when `Reset`, all sent before the client could
%% have read our SETTINGS.
burst(Config, Ids, Reset) ->
    {Frames, #{sock := Sock} = C} = lists:mapfoldl(
        fun(Id, C0) ->
            {Headers, C1} = headers_frame(C0, Id, ~"/"),
            case Reset of
                true -> {[Headers, roadrunner_http2_frame:encode({rst_stream, Id, cancel})], C1};
                false -> {Headers, C1}
            end
        end,
        connect(Config),
        Ids
    ),
    ok = gen_tcp:send(Sock, [preface(), Frames]),
    C.

connect(Config) ->
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, ?config(port, Config), [binary, {active, false}], 5000
    ),
    #{
        sock => Sock,
        buf => <<>>,
        enc => roadrunner_http2_hpack:new_encoder(4096),
        dec => roadrunner_http2_hpack:new_decoder(4096)
    }.

preface() ->
    [~"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", roadrunner_http2_frame:encode({settings, 0, []})].

%% Read the server's SETTINGS and acknowledge them (RFC 9113 §6.5.3).
settings_ack(#{sock := Sock} = C0) ->
    {_, C1} = until(C0, fun
        ({settings, 0, _}) -> true;
        (_) -> false
    end),
    ok = gen_tcp:send(Sock, roadrunner_http2_frame:encode({settings, 1, []})),
    C1.

%% A GET with END_STREAM: its handler starts at once.
send_headers(C, StreamId) ->
    send_headers(C, StreamId, ~"/").

send_headers(#{sock := Sock} = C, StreamId, Path) ->
    {Frame, C1} = headers_frame(C, StreamId, Path),
    ok = gen_tcp:send(Sock, Frame),
    C1.

headers_frame(#{enc := Enc} = C, StreamId, Path) ->
    Fields = [
        {~":method", ~"GET"},
        {~":scheme", ~"http"},
        {~":authority", ~"x"},
        {~":path", Path}
    ],
    {Block, Enc1} = roadrunner_http2_hpack:encode(Fields, Enc),
    {roadrunner_http2_frame:encode({headers, StreamId, 16#05, undefined, Block}), C#{enc := Enc1}}.

%% A POST of `Body` to `/echo`: HEADERS, then the body in a DATA frame
%% with END_STREAM.
send_post(#{sock := Sock, enc := Enc} = C, StreamId, Body) ->
    Fields = [
        {~":method", ~"POST"},
        {~":scheme", ~"http"},
        {~":authority", ~"x"},
        {~":path", ~"/echo"}
    ],
    {Block, Enc1} = roadrunner_http2_hpack:encode(Fields, Enc),
    ok = gen_tcp:send(Sock, [
        roadrunner_http2_frame:encode({headers, StreamId, 16#04, undefined, Block}),
        roadrunner_http2_frame:encode({data, StreamId, 16#01, Body})
    ]),
    C#{enc := Enc1}.

%% The RST_STREAM frames among `Frames`.
rst_frames({Frames, C}) ->
    {[F || {rst_stream, _, _} = F <- Frames], C}.

%% Stream `StreamId`'s status and body.
echoed(C, StreamId) ->
    {Status, Body, _C1} = response(C, StreamId),
    {Status, Body}.

send_rst(#{sock := Sock} = C, StreamId) ->
    ok = gen_tcp:send(Sock, roadrunner_http2_frame:encode({rst_stream, StreamId, cancel})),
    C.

%% Send a PING and collect every frame up to its ACK: the server handles
%% frames in order, so what it does about the frames sent before the PING
%% comes back first.
ping_sync(#{sock := Sock} = C) ->
    ok = gen_tcp:send(Sock, roadrunner_http2_frame:encode({ping, 0, <<1:64>>})),
    until(C, fun
        ({ping, 1, _}) -> true;
        (_) -> false
    end).

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

%% The `{StreamId, Status}` of each of the next `Count` responses to end,
%% in the order they end, however their frames interleave, and the
%% connection after them.
responses_and_conn(C, Count) ->
    responses(C, Count, #{}).

responses(C, 0, _Statuses) ->
    {[], C};
responses(C, Count, Statuses) ->
    case next_frame(C) of
        {{headers, StreamId, Flags, Headers}, C1} ->
            {_, S} = lists:keyfind(~":status", 1, Headers),
            Status = binary_to_integer(S),
            ended(C1, Count, Statuses#{StreamId => Status}, StreamId, Flags);
        {{data, StreamId, Flags, _Data, _}, C1} ->
            ended(C1, Count, Statuses, StreamId, Flags);
        {_Other, C1} ->
            responses(C1, Count, Statuses)
    end.

ended(C, Count, Statuses, StreamId, Flags) when Flags band 16#01 =/= 0 ->
    #{StreamId := Status} = Statuses,
    {Ended, C1} = responses(C, Count - 1, Statuses),
    {[{StreamId, Status} | Ended], C1};
ended(C, Count, Statuses, _StreamId, _Flags) ->
    responses(C, Count, Statuses).

until(C, Pred) ->
    until(C, Pred, []).

until(C, Pred, Acc) ->
    {Frame, C1} = next_frame(C),
    case Pred(Frame) of
        true -> {lists:reverse([Frame | Acc]), C1};
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

%% --- HTTP/3 client ---

h3_connect(Config) ->
    {ok, Conn} = roadrunner_quic_test_h3:connect(
        {127, 0, 0, 1}, ?config(port, Config), #{max_streams_events => true}
    ),
    Conn.

%% Open the connection's whole stream credit and cancel every request
%% while its handler runs, once the server has reset its side of each.
h3_fill_with_cancelled(Conn) ->
    StreamIds = [
        begin
            {ok, StreamId} = roadrunner_quic_test_h3:open_request(Conn, h3_headers()),
            StreamId
        end
     || _ <- lists:seq(1, ?MAX_STREAMS)
    ],
    Handlers = handlers_started(?MAX_STREAMS),
    lists:foreach(
        fun(StreamId) ->
            ok = roadrunner_quic_test_h3:cancel(Conn, StreamId),
            ?assertEqual(?H3_REQUEST_CANCELLED, server_reset(Conn, StreamId))
        end,
        StreamIds
    ),
    Handlers.

h3_headers() ->
    [
        {~":method", ~"GET"},
        {~":scheme", ~"https"},
        {~":authority", ~"localhost"},
        {~":path", ~"/"}
    ].

server_reset(Conn, StreamId) ->
    receive
        {quic_test_stream_reset, Conn, StreamId, Code} -> Code
    after 5000 -> ct:fail(no_server_reset)
    end.

%% The MAX_STREAMS (bidi) grants received so far.
max_streams_grants(Conn) ->
    receive
        {quic_test_max_streams, Conn, bidi, Max} -> [Max | max_streams_grants(Conn)]
    after 0 -> []
    end.
