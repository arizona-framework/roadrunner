-module(roadrunner_h2_keepalive_SUITE).
-moduledoc """
The HTTP/2 connection keepalive policy, driven by a hand-written client
over plain TCP: how often a client may ping (`ping_policy`), what an
idle connection does when the client sends frames without a request, and
how a connection ends at its `connection_age`.
""".

-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([
    default_policy_closes_a_ping_flood/1,
    no_policy_answers_every_ping/1,
    pings_past_the_least_time_are_no_strikes/1,
    pings_without_a_stream_strike_unless_permitted/1,
    pings_with_a_stream_open_wait_the_least_time/1,
    data_sent_frees_the_next_ping/1,
    interim_response_frees_the_next_ping/1,
    pings_do_not_keep_an_idle_conn_open/1,
    other_frames_do_not_keep_an_idle_conn_open/1,
    a_request_restarts_the_idle_timeout/1,
    a_reset_of_the_last_stream_leaves_the_conn_idle/1,
    a_crash_of_the_last_handler_leaves_the_conn_idle/1,
    a_conn_left_idle_by_a_reset_hibernates/1,
    a_request_waiting_for_a_slot_keeps_the_conn_open/1,
    a_client_goaway_lets_open_requests_finish/1,
    a_client_goaway_with_an_error_closes_at_once/1,
    a_client_goaway_ends_a_graceful_close/1,
    age_closes_an_idle_conn/1,
    age_lets_open_requests_finish/1,
    age_grace_resets_open_requests/1,
    age_with_no_grace_names_the_last_stream/1,
    age_grace_after_the_final_goaway_only_resets/1,
    age_during_a_drain_keeps_its_grace/1
]).

-define(COLLECTOR, roadrunner_h2_slot_collector).

%% The idle timeout the idle cases run with (`keep_alive_timeout`,
%% shortened through the conn's test hook); the others keep the
%% listener's, far longer than any of them takes.
-define(IDLE_TIMEOUT, 300).
%% The `min_time` the spaced-PING cases run with: long enough that a PING
%% sent right after the last one's ACK comes well within it.
-define(MIN_TIME, 300).
%% The `connection_age` the age cases run with: each conn's is within a
%% tenth of it.
-define(AGE, 200).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        default_policy_closes_a_ping_flood,
        no_policy_answers_every_ping,
        pings_past_the_least_time_are_no_strikes,
        pings_without_a_stream_strike_unless_permitted,
        pings_with_a_stream_open_wait_the_least_time,
        data_sent_frees_the_next_ping,
        interim_response_frees_the_next_ping,
        pings_do_not_keep_an_idle_conn_open,
        other_frames_do_not_keep_an_idle_conn_open,
        a_request_restarts_the_idle_timeout,
        a_reset_of_the_last_stream_leaves_the_conn_idle,
        a_crash_of_the_last_handler_leaves_the_conn_idle,
        a_conn_left_idle_by_a_reset_hibernates,
        a_request_waiting_for_a_slot_keeps_the_conn_open,
        a_client_goaway_lets_open_requests_finish,
        a_client_goaway_with_an_error_closes_at_once,
        a_client_goaway_ends_a_graceful_close,
        age_closes_an_idle_conn,
        age_lets_open_requests_finish,
        age_grace_resets_open_requests,
        age_with_no_grace_names_the_last_stream,
        age_grace_after_the_final_goaway_only_resets,
        age_during_a_drain_keeps_its_grace
    ].

init_per_suite(Config) ->
    {ok, _} = roadrunner_test_event_handler:start(),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(Case, Config) ->
    _ =
        case idle_case(Case) of
            true -> persistent_term:put({roadrunner_conn_loop_http2, idle_timeout}, ?IDLE_TIMEOUT);
            false -> ok
        end,
    true = register(?COLLECTOR, self()),
    {ok, _} = roadrunner_listener:start_link(
        ?MODULE,
        listener_opts(Case, #{
            port => 0,
            protocols => [{http2, http2_opts(Case)}],
            routes => [
                {~"/", roadrunner_h2_test_handler},
                {~"/stream/bad-trailers", roadrunner_h2_test_handler},
                {~"/hold", roadrunner_h2_slot_handler}
            ]
        })
    ),
    [{port, roadrunner_listener:port(?MODULE)} | Config].

end_per_testcase(_Case, _Config) ->
    ok = roadrunner_listener:stop(?MODULE),
    true = unregister(?COLLECTOR),
    _ = persistent_term:erase({roadrunner_conn_loop_http2, idle_timeout}),
    ok.

listener_opts(a_conn_left_idle_by_a_reset_hibernates, Opts) ->
    Opts#{hibernate_after => 50};
listener_opts(a_request_waiting_for_a_slot_keeps_the_conn_open, Opts) ->
    Opts#{max_concurrent_requests => 1, overload_mode => {queue, #{}}};
listener_opts(_Case, Opts) ->
    Opts.

idle_case(Case) ->
    lists:member(Case, [
        pings_do_not_keep_an_idle_conn_open,
        other_frames_do_not_keep_an_idle_conn_open,
        a_request_restarts_the_idle_timeout,
        a_reset_of_the_last_stream_leaves_the_conn_idle,
        a_crash_of_the_last_handler_leaves_the_conn_idle,
        a_conn_left_idle_by_a_reset_hibernates,
        a_request_waiting_for_a_slot_keeps_the_conn_open
    ]).

http2_opts(default_policy_closes_a_ping_flood) ->
    #{};
http2_opts(pings_past_the_least_time_are_no_strikes) ->
    #{ping_policy => #{min_time => ?MIN_TIME, max_strikes => 0}};
http2_opts(pings_without_a_stream_strike_unless_permitted) ->
    #{ping_policy => #{min_time => ?MIN_TIME, permit_without_stream => false, max_strikes => 0}};
http2_opts(pings_with_a_stream_open_wait_the_least_time) ->
    #{ping_policy => #{min_time => ?MIN_TIME, permit_without_stream => false, max_strikes => 0}};
http2_opts(data_sent_frees_the_next_ping) ->
    #{ping_policy => #{min_time => 60_000, max_strikes => 0}};
http2_opts(interim_response_frees_the_next_ping) ->
    #{ping_policy => #{min_time => 60_000, max_strikes => 0}};
http2_opts(a_client_goaway_ends_a_graceful_close) ->
    #{connection_age => #{max => ?AGE, grace => 10_000}};
http2_opts(age_closes_an_idle_conn) ->
    #{connection_age => #{max => ?AGE}};
http2_opts(age_lets_open_requests_finish) ->
    #{connection_age => #{max => ?AGE}};
http2_opts(age_grace_resets_open_requests) ->
    #{connection_age => #{max => ?AGE, grace => 100}};
http2_opts(age_with_no_grace_names_the_last_stream) ->
    #{connection_age => #{max => ?AGE, grace => 0}};
http2_opts(age_grace_after_the_final_goaway_only_resets) ->
    #{connection_age => #{max => ?AGE, grace => 1000}};
http2_opts(age_during_a_drain_keeps_its_grace) ->
    #{connection_age => #{max => ?AGE, grace => 100}};
http2_opts(_Case) ->
    %% The idle cases ping, and send frames that serve nothing, as fast as
    %% the server answers.
    #{ping_policy => false, control_frame_policy => false}.

%% =============================================================================
%% Cases
%% =============================================================================

default_policy_closes_a_ping_flood(Config) ->
    %% By default a client may ping once a second, two PINGs closer than
    %% that forgiven: the fourth PING in a row is answered, then the
    %% connection is closed as gRPC servers close it (RFC 9113 §5.4.1).
    Ref = attach_conn_close(),
    C0 = open(Config),
    C1 = acked_pings(C0, 3),
    {Frames, C2} = until(send_ping(C1, 4), fun is_goaway/1),
    ?assertEqual(
        [{ping, 1, <<4:64>>}, {goaway, 0, enhance_your_calm, ~"too_many_pings"}],
        [F || F <- Frames, element(1, F) =/= window_update]
    ),
    ?assertEqual(too_many_pings, conn_closed(Ref)),
    closed(C2).

no_policy_answers_every_ping(Config) ->
    %% `ping_policy => false`: every PING is answered, however fast.
    C = acked_pings(open(Config), 20),
    {200, _, _} = response(send_headers(C, 1), 1).

pings_past_the_least_time_are_no_strikes(Config) ->
    %% PINGs `min_time` apart are fine; the first one closer than that is a
    %% strike, and with `max_strikes => 0` it closes the connection.
    C0 = open(Config),
    C1 = spaced_pings(C0, 3, ?MIN_TIME),
    too_many_pings(send_ping(C1, 4)).

pings_without_a_stream_strike_unless_permitted(Config) ->
    %% Without `permit_without_stream`, a client with no request open must
    %% not ping again for two hours: `min_time` apart is not enough.
    C0 = open(Config),
    C1 = spaced_pings(C0, 1, ?MIN_TIME),
    ok = wait(?MIN_TIME),
    too_many_pings(send_ping(C1, 2)).

pings_with_a_stream_open_wait_the_least_time(Config) ->
    %% With a request open (its handler holding its response back), PINGs
    %% `min_time` apart are fine even without `permit_without_stream`.
    C0 = send_headers(open(Config), 1, ~"/hold"),
    Handler = handler_started(),
    C1 = spaced_pings(C0, 3, ?MIN_TIME),
    Handler ! release,
    {200, ~"ok", _} = response(C1, 1).

data_sent_frees_the_next_ping(Config) ->
    %% A PING right after a response is no strike, however soon it comes:
    %% a client measuring its bandwidth pings as it reads.
    C0 = acked_pings(open(Config), 1),
    {200, _, C1} = response(send_headers(C0, 1), 1),
    C2 = acked_pings(C1, 1),
    %% With nothing sent since, the next one is a strike.
    too_many_pings(send_ping(C2, 3)).

interim_response_frees_the_next_ping(Config) ->
    %% So is a PING right after an interim `100 (Continue)`, HEADERS with
    %% no END_STREAM: every HEADERS and DATA the server sends frees it.
    C0 = acked_pings(open(Config), 1),
    C1 = send_expect_continue(C0, 1),
    {[{headers, 1, 16#04, [{~":status", ~"100"}]}], C2} = until(C1, fun is_headers/1),
    C3 = acked_pings(C2, 1),
    too_many_pings(send_ping(C3, 3)).

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

a_request_waiting_for_a_slot_keeps_the_conn_open(Config) ->
    %% A request parked for the listener's only in-flight slot has no
    %% handler yet, but it is still the server's to answer: its quiet conn
    %% is checked with a PING when the idle timeout passes, not closed with
    %% a GOAWAY that names the request (which would leave the client no
    %% answer and no safe retry). Once the slot frees, it is served.
    _ = send_headers(open(Config), 1, ~"/hold"),
    Holder = handler_started(),
    C0 = send_headers(open(Config), 1, ~"/hold"),
    {Frames, #{sock := Sock} = C1} = until(C0, fun(F) -> is_goaway(F) orelse is_ping(F) end),
    {ping, 0, Opaque} = lists:last(Frames),
    ok = gen_tcp:send(Sock, roadrunner_http2_frame:encode({ping, 1, Opaque})),
    Holder ! release,
    Parked = handler_started(),
    Parked ! release,
    {200, ~"ok", _} = response(C1, 1).

a_client_goaway_lets_open_requests_finish(Config) ->
    %% A client's GOAWAY(NO_ERROR) bars only the streams the server would
    %% open (RFC 9113 §6.8): the request it sent before is still answered.
    %% The server replies with a GOAWAY naming that request, refuses a
    %% stream opened after it (retry-safe), ignores a second GOAWAY, and
    %% closes once the request is done.
    Ref = attach_conn_close(),
    #{sock := Sock} = C0 = send_headers(open(Config), 1, ~"/hold"),
    Handler = handler_started(),
    ok = gen_tcp:send(Sock, roadrunner_http2_frame:encode({goaway, 0, no_error, <<>>})),
    {Frames, C1} = until(C0, fun is_goaway/1),
    ?assertEqual([{goaway, 1, no_error, <<>>}], [
        F
     || F <- Frames, element(1, F) =/= window_update
    ]),
    ok = gen_tcp:send(Sock, roadrunner_http2_frame:encode({goaway, 0, no_error, <<>>})),
    {Refused, C2} = until(send_headers(C1, 3), fun is_rst_stream/1),
    ?assertEqual({rst_stream, 3, refused_stream}, lists:last(Refused)),
    Handler ! release,
    {200, ~"ok", C3} = response(C2, 1),
    ?assertEqual(peer_closed, conn_closed(Ref)),
    closed(C3).

a_client_goaway_with_an_error_closes_at_once(Config) ->
    %% A GOAWAY with an error code closes the connection at once (RFC 9113
    %% §5.4.1), the request still open with it.
    Ref = attach_conn_close(),
    #{sock := Sock} = C = send_headers(open(Config), 1, ~"/hold"),
    Handler = handler_started(),
    ok = gen_tcp:send(Sock, roadrunner_http2_frame:encode({goaway, 0, protocol_error, <<>>})),
    ?assertEqual([], frames_until_closed(C)),
    ?assertEqual(peer_closed, conn_closed(Ref)),
    Handler ! release.

a_client_goaway_ends_a_graceful_close(Config) ->
    %% A client that answers the server's first GOAWAY with one of its own
    %% rather than the PING's ACK has sent every stream it will: the final
    %% GOAWAY, naming the last of them, follows at once, and the request
    %% open is still served to its end.
    Ref = attach_conn_close(),
    C0 = send_headers(open(Config), 1, ~"/hold"),
    Handler = handler_started(),
    {Frames, #{sock := Sock} = C1} = until(C0, fun is_ping/1),
    ?assertEqual([{goaway, 16#7FFFFFFF, no_error, <<>>}, {ping, 0, ~"rr-drain"}], [
        F
     || F <- Frames, element(1, F) =/= window_update
    ]),
    ok = gen_tcp:send(Sock, roadrunner_http2_frame:encode({goaway, 0, no_error, <<>>})),
    {Final, C2} = until(C1, fun is_goaway/1),
    ?assertEqual([{goaway, 1, no_error, <<>>}], Final),
    Handler ! release,
    {200, ~"ok", C3} = response(C2, 1),
    ?assertEqual(connection_age, conn_closed(Ref)),
    closed(C3).

age_closes_an_idle_conn(Config) ->
    %% At its age a conn closes as a drained one does (RFC 9113 §6.8): a
    %% GOAWAY that refuses nothing and a PING, then, on the PING's ACK, the
    %% GOAWAY naming the last stream, and with no request open, the close.
    Ref = attach_conn_close(),
    Opened = erlang:monotonic_time(millisecond),
    C0 = open(Config),
    C1 = graceful_close(C0, 0),
    ?assert(erlang:monotonic_time(millisecond) - Opened >= ?AGE - ?AGE div 10),
    ?assertEqual(connection_age, conn_closed(Ref)),
    closed(C1).

age_lets_open_requests_finish(Config) ->
    %% A request open at the conn's age is served to its end; one sent
    %% after the final GOAWAY is refused (retry-safe, RFC 9113 §8.7).
    Ref = attach_conn_close(),
    C0 = send_headers(open(Config), 1, ~"/hold"),
    Handler = handler_started(),
    C1 = graceful_close(C0, 1),
    {Frames, C2} = until(send_headers(C1, 3), fun is_rst_stream/1),
    ?assertEqual({rst_stream, 3, refused_stream}, lists:last(Frames)),
    Handler ! release,
    {200, ~"ok", C3} = response(C2, 1),
    ?assertEqual(connection_age, conn_closed(Ref)),
    closed(C3).

age_grace_resets_open_requests(Config) ->
    %% A request still open when the grace runs out is reset with CANCEL
    %% and the conn closes. However far the client got answering the PING,
    %% the GOAWAY naming the last stream comes before the reset.
    Ref = attach_conn_close(),
    C0 = send_headers(open(Config), 1, ~"/hold"),
    Handler = handler_started(),
    ?assertEqual(
        [
            {goaway, 16#7FFFFFFF, no_error, <<>>},
            {ping, 0, ~"rr-drain"},
            {goaway, 1, no_error, <<>>},
            {rst_stream, 1, cancel}
        ],
        frames_until_closed(C0)
    ),
    ?assertEqual(connection_age_grace, conn_closed(Ref)),
    Handler ! release.

age_with_no_grace_names_the_last_stream(Config) ->
    %% With `grace => 0` the requests open at the conn's age are reset at
    %% once, the client not having answered the PING (here, it never
    %% does): the final GOAWAY still goes out first, so the client knows
    %% no stream it opened after stream 1 was processed.
    Ref = attach_conn_close(),
    C0 = send_headers(open(Config), 1, ~"/hold"),
    Handler = handler_started(),
    ?assertEqual(
        [
            {goaway, 16#7FFFFFFF, no_error, <<>>},
            {ping, 0, ~"rr-drain"},
            {goaway, 1, no_error, <<>>},
            {rst_stream, 1, cancel}
        ],
        frames_until_closed(C0, false)
    ),
    ?assertEqual(connection_age_grace, conn_closed(Ref)),
    Handler ! release.

age_grace_after_the_final_goaway_only_resets(Config) ->
    %% A client that answered the PING has the final GOAWAY already: when
    %% the grace runs out, the requests still open are only reset.
    Ref = attach_conn_close(),
    C0 = send_headers(open(Config), 1, ~"/hold"),
    Handler = handler_started(),
    C1 = graceful_close(C0, 1),
    ?assertEqual([{rst_stream, 1, cancel}], frames_until_closed(C1)),
    ?assertEqual(connection_age_grace, conn_closed(Ref)),
    Handler ! release.

age_during_a_drain_keeps_its_grace(Config) ->
    %% A conn the listener drains before its age is closing already: its
    %% age starts no second close, but its grace still bounds the requests
    %% left open.
    Ref = attach_conn_close(),
    C0 = send_headers(open(Config), 1, ~"/hold"),
    Handler = handler_started(),
    ok = roadrunner_listener:notify_drain(?MODULE, erlang:monotonic_time(millisecond) + 30_000),
    ?assertEqual(
        [
            {goaway, 16#7FFFFFFF, no_error, <<>>},
            {ping, 0, ~"rr-drain"},
            {goaway, 1, no_error, <<>>},
            {rst_stream, 1, cancel}
        ],
        frames_until_closed(C0)
    ),
    ?assertEqual(connection_age_grace, conn_closed(Ref)),
    Handler ! release.

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

%% Walk a graceful close: the first GOAWAY (naming the largest stream id)
%% and its PING, which is answered, then the final GOAWAY, which names
%% `LastStreamId`.
graceful_close(C0, LastStreamId) ->
    {Frames, #{sock := Sock} = C1} = until(C0, fun
        ({ping, 0, _}) -> true;
        (_) -> false
    end),
    [{goaway, 16#7FFFFFFF, no_error, <<>>}, {ping, 0, Opaque}] =
        [F || F <- Frames, element(1, F) =/= window_update],
    ok = gen_tcp:send(Sock, roadrunner_http2_frame:encode({ping, 1, Opaque})),
    {Final, C2} = until(C1, fun is_goaway/1),
    ?assertEqual([{goaway, LastStreamId, no_error, <<>>}], Final),
    C2.

%% Every frame up to the close (leaving out SETTINGS and WINDOW_UPDATE),
%% each PING answered as it comes, if the connection is still open.
frames_until_closed(C) ->
    frames_until_closed(C, true).

%% The same, answering PINGs only when `Ack` is `true`.
frames_until_closed(#{sock := Sock, buf := Buf, dec := Dec} = C, Ack) ->
    case roadrunner_http2_frame:parse(Buf, 16384) of
        {ok, {headers, StreamId, Flags, _Priority, Block}, Rest} ->
            {ok, Headers, Dec1} = roadrunner_http2_hpack:decode(Block, Dec),
            [
                {headers, StreamId, Flags, Headers}
                | frames_until_closed(C#{buf := Rest, dec := Dec1}, Ack)
            ];
        {ok, {ping, 0, Opaque} = Ping, Rest} ->
            ok =
                case Ack of
                    true -> send_tolerant(Sock, roadrunner_http2_frame:encode({ping, 1, Opaque}));
                    false -> ok
                end,
            [Ping | frames_until_closed(C#{buf := Rest}, Ack)];
        {ok, Frame, Rest} when
            element(1, Frame) =:= settings; element(1, Frame) =:= window_update
        ->
            frames_until_closed(C#{buf := Rest}, Ack);
        {ok, Frame, Rest} ->
            [Frame | frames_until_closed(C#{buf := Rest}, Ack)];
        {more, _} ->
            case gen_tcp:recv(Sock, 0, 5000) of
                {ok, Data} -> frames_until_closed(C#{buf := <<Buf/binary, Data/binary>>}, Ack);
                {error, closed} -> []
            end
    end.

is_rst_stream({rst_stream, _, _}) -> true;
is_rst_stream(_Frame) -> false.

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
    _ = send_tolerant(Sock, [
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

%% `N` PINGs, each sent once the last one is answered, and none answered
%% with a GOAWAY.
acked_pings(C, 0) ->
    C;
acked_pings(C0, N) ->
    {Frames, C1} = until(send_ping(C0, N), fun(F) -> is_ping_ack(F) orelse is_goaway(F) end),
    ?assertEqual({ping, 1, <<N:64>>}, lists:last(Frames)),
    acked_pings(C1, N - 1).

%% The PING just sent was the strike too many: it is answered, then the
%% connection closes with GOAWAY(ENHANCE_YOUR_CALM, too_many_pings).
too_many_pings(C0) ->
    {Frames, C1} = until(C0, fun is_goaway/1),
    ?assertMatch([{ping, 1, _}, {goaway, _, enhance_your_calm, ~"too_many_pings"}], [
        F
     || F <- Frames, element(1, F) =/= window_update
    ]),
    closed(C1).

handler_started() ->
    receive
        {handler_started, Pid} -> Pid
    after 5000 -> ct:fail(handler_not_started)
    end.

is_headers({headers, _, _, _}) -> true;
is_headers(_Frame) -> false.

%% A POST expecting `100-continue`, its body still to come.
send_expect_continue(#{sock := Sock, enc := Enc} = C, StreamId) ->
    Fields = [
        {~":method", ~"POST"},
        {~":scheme", ~"http"},
        {~":authority", ~"x"},
        {~":path", ~"/"},
        {~"content-length", ~"3"},
        {~"expect", ~"100-continue"}
    ],
    {Block, Enc1} = roadrunner_http2_hpack:encode(Fields, Enc),
    ok = gen_tcp:send(
        Sock, roadrunner_http2_frame:encode({headers, StreamId, 16#04, undefined, Block})
    ),
    C#{enc := Enc1}.

%% `N` PINGs, each but the first sent `Ms` after the last one's ACK. The
%% server took the last one before it answered it, so it sees at least
%% `Ms` between them. The case is about time passing, and nothing the server sends
%% marks it, so it is waited out: the wait only has to be long enough,
%% never short, so load cannot break it.
spaced_pings(C0, N, Ms) ->
    C1 = acked_pings(C0, 1),
    case N of
        1 ->
            C1;
        _ ->
            ok = wait(Ms),
            spaced_pings(C1, N - 1, Ms)
    end.

wait(Ms) ->
    receive
    after Ms -> ok
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

is_ping({ping, 0, _}) -> true;
is_ping(_Frame) -> false.

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
    ok = send_tolerant(Sock, roadrunner_http2_frame:encode({ping, 0, <<N:64>>})),
    C.

%% Send, unless the server closed the connection already: what it sent
%% before it closed (its GOAWAY) is still there to read.
send_tolerant(Sock, Data) ->
    case gen_tcp:send(Sock, Data) of
        ok -> ok;
        {error, closed} -> ok
    end.

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
