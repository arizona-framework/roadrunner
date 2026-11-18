-module(roadrunner_h2_control_frame_SUITE).
-moduledoc """
The HTTP/2 `control_frame_policy`, driven by a hand-written client over
plain TCP: a flood of frames that serve no request closes the connection
with `GOAWAY(ENHANCE_YOUR_CALM)` (RFC 9113 §10.5), and the frames real
clients send as they connect, upload and read never do.
""".

-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([handle/1]).
-export([
    settings_flood_closes/1,
    settings_ack_flood_closes/1,
    conn_window_update_flood_closes/1,
    stream_window_update_flood_closes/1,
    window_update_nothing_waits_on_flood_closes/1,
    priority_flood_closes/1,
    unknown_frame_flood_closes/1,
    empty_data_flood_closes/1,
    padded_empty_data_flood_closes/1,
    rst_stream_on_a_closed_stream_flood_closes/1,
    data_on_a_closed_stream_flood_closes/1,
    empty_data_on_a_client_reset_stream_flood_closes/1,
    empty_data_on_a_server_reset_stream_flood_closes/1,
    data_past_a_reset_stream_window_closes/1,
    resets_of_requests_with_no_handler_close/1,
    refused_requests_close/1,
    a_trickled_response_buys_few_frames/1,
    byte_sized_data_on_a_reset_stream_is_charged_a_frame/1,
    header_blocks_on_a_reset_stream_flood_closes/1,
    updates_that_let_no_data_out_close/1,
    a_smaller_initial_window_is_allowed/1,
    updates_that_open_a_window_data_waits_on_are_not_counted/1,
    default_policy_closes_a_flood/1,
    a_response_takes_frames_off_the_count/1,
    frames_spread_over_the_window_are_allowed/1,
    browser_startup_is_allowed/1,
    window_updates_as_the_client_reads_are_allowed/1,
    window_updates_as_the_client_reads_are_allowed_by_default/1,
    a_large_upload_is_allowed/1,
    a_large_upload_is_allowed_by_default/1,
    resets_of_running_handlers_are_not_counted/1,
    data_in_flight_on_a_reset_stream_is_not_counted/1,
    pings_are_left_to_the_ping_policy/1,
    no_policy_allows_any_number/1
]).

%% The `max` the flood cases run with: small, so each sends few frames.
-define(MAX, 5).
%% Their `window`: far longer than any case takes, so every frame comes
%% within it.
-define(WINDOW, 60_000).
%% The `window` of the case that spreads its frames over time.
-define(SHORT_WINDOW, 200).
%% A frame of a type RFC 9113 does not define (ignored, §4.1), as
%% PRIORITY_UPDATE (RFC 9218, type 0x10) is to a server that does not
%% take it.
-define(UNKNOWN, <<0:24, 16#10, 0, 0:32>>).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        settings_flood_closes,
        settings_ack_flood_closes,
        conn_window_update_flood_closes,
        stream_window_update_flood_closes,
        window_update_nothing_waits_on_flood_closes,
        priority_flood_closes,
        unknown_frame_flood_closes,
        empty_data_flood_closes,
        padded_empty_data_flood_closes,
        rst_stream_on_a_closed_stream_flood_closes,
        data_on_a_closed_stream_flood_closes,
        empty_data_on_a_client_reset_stream_flood_closes,
        empty_data_on_a_server_reset_stream_flood_closes,
        data_past_a_reset_stream_window_closes,
        resets_of_requests_with_no_handler_close,
        refused_requests_close,
        a_trickled_response_buys_few_frames,
        byte_sized_data_on_a_reset_stream_is_charged_a_frame,
        header_blocks_on_a_reset_stream_flood_closes,
        updates_that_let_no_data_out_close,
        a_smaller_initial_window_is_allowed,
        updates_that_open_a_window_data_waits_on_are_not_counted,
        default_policy_closes_a_flood,
        a_response_takes_frames_off_the_count,
        frames_spread_over_the_window_are_allowed,
        browser_startup_is_allowed,
        window_updates_as_the_client_reads_are_allowed,
        window_updates_as_the_client_reads_are_allowed_by_default,
        a_large_upload_is_allowed,
        a_large_upload_is_allowed_by_default,
        resets_of_running_handlers_are_not_counted,
        data_in_flight_on_a_reset_stream_is_not_counted,
        pings_are_left_to_the_ping_policy,
        no_policy_allows_any_number
    ].

init_per_suite(Config) ->
    {ok, _} = roadrunner_test_event_handler:start(),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(Case, Config) ->
    {ok, _} = roadrunner_listener:start_link(?MODULE, #{
        port => 0,
        protocols => [{http2, http2_opts(Case)}],
        routes => [
            {~"/", roadrunner_h2_test_handler},
            {~"/stream/large", roadrunner_h2_test_handler},
            {~"/hold", roadrunner_h2_slot_handler},
            {~"/upload", ?MODULE}
        ]
    }),
    [{port, roadrunner_listener:port(?MODULE)} | Config].

end_per_testcase(_Case, _Config) ->
    ok = roadrunner_listener:stop(?MODULE).

http2_opts(default_policy_closes_a_flood) ->
    #{};
http2_opts(browser_startup_is_allowed) ->
    #{};
http2_opts(window_updates_as_the_client_reads_are_allowed_by_default) ->
    #{};
http2_opts(a_large_upload_is_allowed_by_default) ->
    #{};
http2_opts(refused_requests_close) ->
    #{
        max_concurrent_streams => 1,
        ping_policy => false,
        control_frame_policy => #{max => ?MAX, window => ?WINDOW}
    };
http2_opts(frames_spread_over_the_window_are_allowed) ->
    #{ping_policy => false, control_frame_policy => #{max => 2, window => ?SHORT_WINDOW}};
http2_opts(window_updates_as_the_client_reads_are_allowed) ->
    %% As strict as a policy can be and still let a client open both
    %% windows for each DATA frame it reads.
    #{control_frame_policy => #{max => 2, window => ?WINDOW}};
http2_opts(a_large_upload_is_allowed) ->
    %% The strictest policy there is: one frame, then one per window.
    #{control_frame_policy => #{max => 1, window => ?WINDOW}};
http2_opts(no_policy_allows_any_number) ->
    #{ping_policy => false, control_frame_policy => false};
http2_opts(_Case) ->
    %% PINGs mark what the server has read, as often as a case needs.
    #{ping_policy => false, control_frame_policy => #{max => ?MAX, window => ?WINDOW}}.

%% The `/upload` route: the size of the body it read.
handle(Req) ->
    {ok, Body, Req1} = roadrunner_req:read_body(Req),
    {{200, [], integer_to_binary(iolist_size(Body))}, Req1}.

%% =============================================================================
%% Cases
%% =============================================================================

%% The client's SETTINGS sent with its preface is the first frame counted:
%% `2 * ?MAX` frames in all are allowed (`?MAX`, then `?MAX` within the
%% window), and the one after closes.

settings_flood_closes(Config) ->
    %% Each SETTINGS is answered with an ACK.
    Ref = attach_conn_close(),
    C = open(Config),
    flood(C, 1, roadrunner_http2_frame:encode({settings, 0, []})),
    ?assertEqual({protocol_error, enhance_your_calm}, conn_closed(Ref)).

settings_ack_flood_closes(Config) ->
    %% The ACK of the server's SETTINGS counts too, and every one after it.
    flood(open(Config), 1, roadrunner_http2_frame:encode({settings, 1, []})).

conn_window_update_flood_closes(Config) ->
    flood(open(Config), 1, roadrunner_http2_frame:encode({window_update, 0, 1})).

stream_window_update_flood_closes(Config) ->
    %% On a stream still open, its body to come.
    C = send_post_headers(open(Config), 1),
    flood(C, 1, roadrunner_http2_frame:encode({window_update, 1, 1})).

window_update_nothing_waits_on_flood_closes(Config) ->
    %% On a stream whose window the client opened at 0, with nothing
    %% waiting on it: the first one opens it, but lets no DATA out.
    C = send_post_headers(open(Config, [{4, 0}]), 1),
    flood(C, 1, roadrunner_http2_frame:encode({window_update, 1, 1})).

priority_flood_closes(Config) ->
    %% PRIORITY on idle streams (RFC 9113 §6.3 allows it), each ignored
    %% (CVE-2019-9513, the priority shuffling attack).
    flood(open(Config), 1, priority(3)).

unknown_frame_flood_closes(Config) ->
    flood(open(Config), 1, ?UNKNOWN).

empty_data_flood_closes(Config) ->
    %% DATA frames with nothing in them and no END_STREAM, on a stream
    %% still open (CVE-2019-9518, the empty frames flood).
    C = send_post_headers(open(Config), 1),
    flood(C, 1, roadrunner_http2_frame:encode({data, 1, 0, <<>>})).

padded_empty_data_flood_closes(Config) ->
    %% The same with padding, which takes window (returned) and no data.
    C = send_post_headers(open(Config), 1),
    flood(C, 1, roadrunner_http2_frame:encode({data, 1, 16#08, <<0>>})).

rst_stream_on_a_closed_stream_flood_closes(Config) ->
    %% RST_STREAM on a stream already closed is ignored (RFC 9113 §5.4).
    %% The response to stream 1 started the count over.
    {200, _, C} = response(send_get(open(Config), 1, ~"/"), 1),
    flood(C, 0, roadrunner_http2_frame:encode({rst_stream, 1, cancel})).

data_on_a_closed_stream_flood_closes(Config) ->
    %% DATA on a stream already closed is answered with
    %% RST_STREAM(STREAM_CLOSED) (RFC 9113 §6.1).
    {200, _, C} = response(send_get(open(Config), 1, ~"/"), 1),
    flood(C, 0, roadrunner_http2_frame:encode({data, 1, 0, ~"x"})).

empty_data_on_a_client_reset_stream_flood_closes(Config) ->
    %% DATA with nothing in it, END_STREAM or not, on a stream the client
    %% reset: each is answered with RST_STREAM(STREAM_CLOSED) (RFC 9113
    %% §6.1). The reset, of a request with no handler started, counts too.
    C = send_rst(send_post_headers(open(Config), 1), 1),
    [Last | Frames] = empty_data(1, 2 * ?MAX - 1),
    flood_frames(C, Frames, Last).

empty_data_on_a_server_reset_stream_flood_closes(Config) ->
    %% The same on a stream the server reset (here, refused for depending
    %% on itself, which counts too): each is ignored, as DATA the client
    %% sent before it saw the reset would be, but carries nothing.
    C = send_self_dependent(open(Config), 1),
    [Last | Frames] = empty_data(1, 2 * ?MAX - 1),
    flood_frames(C, Frames, Last).

data_past_a_reset_stream_window_closes(Config) ->
    %% DATA on a stream the server reset is ignored up to the window the
    %% stream had left, all the client may have had in flight; past it,
    %% each frame counts.
    C0 = send_self_dependent(open(Config), 1),
    C1 = lists:foldl(
        fun(Size, C) -> send_data(C, 1, binary:copy(~"x", Size), 0) end,
        C0,
        [16384, 16384, 16384, 16383]
    ),
    flood(C1, 2, roadrunner_http2_frame:encode({data, 1, 0, ~"x"})).

resets_of_requests_with_no_handler_close(Config) ->
    %% A request whose body is still to come starts no handler, so the
    %% rapid reset guard does not see it reset: opening one and resetting
    %% it serves nothing, and the reset counts.
    {Frames, C} = lists:mapfoldl(
        fun(StreamId, C0) -> post_and_reset(C0, StreamId) end,
        open(Config),
        lists:seq(1, 2 * (2 * ?MAX - 1), 2)
    ),
    {Last, C1} = post_and_reset(C, 4 * ?MAX - 1),
    flood_frames(C1, Frames, Last).

refused_requests_close(Config) ->
    %% With the client's own request filling `max_concurrent_streams`, each
    %% stream more is refused, and counts. Its SETTINGS ACK puts the limit
    %% in force, and counts too.
    #{sock := Sock} = C0 = send_post_headers(open(Config), 1),
    ok = gen_tcp:send(Sock, roadrunner_http2_frame:encode({settings, 1, []})),
    {Frames, C1} = lists:mapfoldl(
        fun(StreamId, C) -> get_frame(C, StreamId) end,
        C0,
        lists:seq(3, 2 * (2 * ?MAX - 2) + 1, 2)
    ),
    {Last, C2} = get_frame(C1, 4 * ?MAX - 1),
    flood_frames(C2, Frames, Last).

updates_that_open_a_window_data_waits_on_are_not_counted(Config) ->
    %% A WINDOW_UPDATE that opens a stream's window while the server holds
    %% DATA back for it is not counted, even at the limit: it lets that
    %% DATA out. One with nothing waiting on it still counts.
    C1 = first_byte(open(Config, [{4, 0}])),
    %% At the limit: what came before was taken off by the HEADERS and the
    %% DATA, so these are all the frames counted.
    #{sock := Sock} = C2 = allowed(C1, lists:duplicate(2 * ?MAX, ?UNKNOWN)),
    ok = gen_tcp:send(Sock, roadrunner_http2_frame:encode({window_update, 1, 10})),
    {_, C3} = until(C2, fun(F) -> is_goaway(F) orelse element(1, F) =:= data end),
    %% That DATA took 4 off the count: 4 more are allowed, then the
    %% connection window, which nothing waits on, closes it.
    C4 = allowed(C3, lists:duplicate(4, ?UNKNOWN)),
    flood_frames(C4, [], roadrunner_http2_frame:encode({window_update, 0, 1})).

byte_sized_data_on_a_reset_stream_is_charged_a_frame(Config) ->
    %% On a stream the server reset, each DATA frame is charged at least a
    %% full frame of the window the stream had left: 65535 bytes sent a
    %% byte at a time make four free frames, not 65535.
    C0 = send_self_dependent(open(Config), 1),
    Byte = roadrunner_http2_frame:encode({data, 1, 0, ~"x"}),
    C1 = allowed(C0, lists:duplicate(4, Byte)),
    flood(C1, 2, Byte).

header_blocks_on_a_reset_stream_flood_closes(Config) ->
    %% Trailers on a stream the server reset are decoded and ignored, and
    %% each counts, however many come on the one stream.
    #{enc := Enc0} = C0 = send_self_dependent(open(Config), 1),
    {Blocks, Enc} = lists:mapfoldl(
        fun(_, E0) ->
            {Block, E1} = roadrunner_http2_hpack:encode([{~"x-trailer", ~"t"}], E0),
            {roadrunner_http2_frame:encode({headers, 1, 16#05, undefined, Block}), E1}
        end,
        Enc0,
        lists:seq(1, 2 * ?MAX - 1)
    ),
    [Last | Frames] = Blocks,
    flood_frames(C0#{enc := Enc}, Frames, Last).

updates_that_let_no_data_out_close(Config) ->
    %% A stream WINDOW_UPDATE that opens a window DATA waits on is not
    %% counted, even with the connection window spent, so the SETTINGS
    %% that shrinks the stream window again is charged for the stream it
    %% closes: a client cannot buy one free update per SETTINGS.
    C0 = send_get(open(Config), 1, ~"/stream/large"),
    %% The server spends the connection window, 65535 bytes, the rest of
    %% the response waiting on it.
    C1 = read_data(C0, 1, 65535),
    Update = roadrunner_http2_frame:encode({window_update, 1, 1}),
    Settings = fun(K) -> roadrunner_http2_frame:encode({settings, 0, [{4, 65535 - K}]}) end,
    %% Each SETTINGS counts two (itself and the stream it closes); the
    %% updates count nothing.
    Frames = lists:append([[Update, Settings(K)] || K <- lists:seq(1, ?MAX)]) ++ [Update],
    flood_frames(C1, Frames, Settings(?MAX + 1)).

a_smaller_initial_window_is_allowed(Config) ->
    %% A client that lowers its initial window once, with a few requests
    %% open, is charged for the streams it closes, well within the limit.
    C0 = lists:foldl(
        fun(StreamId, C) -> send_post_headers(C, StreamId) end,
        open(Config),
        [1, 3, 5]
    ),
    _ = allowed(C0, [roadrunner_http2_frame:encode({settings, 0, [{4, 0}]})]).

a_trickled_response_buys_few_frames(Config) ->
    %% A client that opens no window and buys the response a byte at a time
    %% (WINDOW_UPDATE for one byte, not counted as it lets DATA out) gains
    %% 4 frames of its own per DATA frame the server sends: five each round
    %% add up and close.
    trickle(first_byte(open(Config, [{4, 0}])), 10).

default_policy_closes_a_flood(Config) ->
    %% By default 1000 frames are free, and 1000 more within 10 s.
    Ref = attach_conn_close(),
    C = open(Config),
    flood(C, 1, ?UNKNOWN, 2000),
    ?assertEqual({protocol_error, enhance_your_calm}, conn_closed(Ref)).

a_response_takes_frames_off_the_count(Config) ->
    %% Up to `max`, then a request: its response (HEADERS and DATA) takes
    %% 4 per frame off the count, so the whole budget is there again.
    C0 = open(Config),
    C1 = allowed(C0, lists:duplicate(?MAX - 1, ?UNKNOWN)),
    {200, ~"ok", C2} = response(send_get(C1, 1, ~"/"), 1),
    flood(C2, 0, ?UNKNOWN).

frames_spread_over_the_window_are_allowed(Config) ->
    %% A connection that lives long, the client sending SETTINGS and
    %% PRIORITY now and then: `max` frames per window are allowed however
    %% long it goes. Each round is read (its PING answered) before the
    %% window is waited out, so the server sees at least that much time
    %% between two rounds; the case is about time passing, which nothing
    %% the server sends marks.
    Round = [roadrunner_http2_frame:encode({settings, 0, []}), priority(3)],
    C = lists:foldl(
        fun(_, C0) ->
            C1 = allowed(C0, Round),
            ok = wait(?SHORT_WINDOW),
            C1
        end,
        open(Config),
        lists:seq(1, 5)
    ),
    {200, ~"ok", _} = response(send_get(C, 1, ~"/"), 1).

browser_startup_is_allowed(Config) ->
    %% What a browser sends as it connects, under the default policy: its
    %% SETTINGS, a WINDOW_UPDATE that opens the connection window, PRIORITY
    %% frames that build a tree of idle streams, the ACK of the server's
    %% SETTINGS, and a PRIORITY_UPDATE per request it reprioritizes.
    #{sock := Sock} = C0 = open(Config, [{4, 6291456}, {2, 0}]),
    ok = gen_tcp:send(Sock, [
        roadrunner_http2_frame:encode({window_update, 0, 15663105}),
        [priority(Id) || Id <- [3, 5, 7, 9, 11]],
        roadrunner_http2_frame:encode({settings, 1, []})
    ]),
    C = lists:foldl(
        fun(StreamId, C1) ->
            C2 = send_get(C1, StreamId, ~"/"),
            ok = gen_tcp:send(Sock, ?UNKNOWN),
            {200, ~"ok", C3} = response(C2, StreamId),
            C3
        end,
        C0,
        [13, 15, 17]
    ),
    _ = allowed(C, []).

window_updates_as_the_client_reads_are_allowed(Config) ->
    %% A client that reads a large response over a small window, as gRPC
    %% clients may: it opens the stream and connection windows after each
    %% DATA frame it reads, two WINDOW_UPDATEs for each, many more than the
    %% policy allows in all. Each DATA frame the server sends takes 4 off
    %% the count.
    C = open(Config, [{4, 4096}]),
    {200, Body, _} = read_with_updates(send_get(C, 1, ~"/stream/large"), 1, <<>>),
    ?assertEqual(100_000, byte_size(Body)).

window_updates_as_the_client_reads_are_allowed_by_default(Config) ->
    window_updates_as_the_client_reads_are_allowed(Config).

a_large_upload_is_allowed_by_default(Config) ->
    a_large_upload_is_allowed(Config).

a_large_upload_is_allowed(Config) ->
    %% A 1 MB upload in many DATA frames, the server opening the windows as
    %% it reads: DATA that carries data is never counted.
    C0 = send_post_headers(open(Config), 1, ~"/upload"),
    C1 = upload(C0, 1, 1_000_000, 65535),
    {200, ~"1000000", _} = response(C1, 1).

resets_of_running_handlers_are_not_counted(Config) ->
    %% A request reset while its handler runs is the rapid reset guard's to
    %% judge, not this one's.
    C = lists:foldl(
        fun(StreamId, C0) -> send_rst(send_get(C0, StreamId, ~"/hold"), StreamId) end,
        open(Config),
        lists:seq(1, 4 * ?MAX, 2)
    ),
    {200, ~"ok", _} = response(send_get(allowed(C, []), 4 * ?MAX + 1, ~"/"), 4 * ?MAX + 1).

data_in_flight_on_a_reset_stream_is_not_counted(Config) ->
    %% DATA a client sent before it saw the server reset its stream (here,
    %% an upload over the body cap answered `413`) is ignored, within the
    %% window the stream had left.
    ok = roadrunner_listener:stop(?MODULE),
    {ok, _} = roadrunner_listener:start_link(?MODULE, #{
        port => 0,
        max_content_length => 10,
        protocols => [{http2, http2_opts(data_in_flight_on_a_reset_stream_is_not_counted)}],
        routes => [{~"/upload", ?MODULE}]
    }),
    Config1 = [{port, roadrunner_listener:port(?MODULE)} | Config],
    C0 = send_post_headers(open(Config1), 1, ~"/upload"),
    #{sock := Sock} = C1 = send_data(C0, 1, binary:copy(~"x", 20), 0),
    {413, _, C2} = response(C1, 1),
    %% Most of the window it had left, in full frames, as a client sends
    %% a body.
    ok = gen_tcp:send(Sock, [
        roadrunner_http2_frame:encode({data, 1, 0, binary:copy(~"x", 16384)})
     || _ <- lists:seq(1, 3)
    ]),
    _ = allowed(C2, []).

pings_are_left_to_the_ping_policy(Config) ->
    %% PINGs are counted by `ping_policy` alone (here off).
    C = lists:foldl(fun(_, C0) -> allowed(C0, []) end, open(Config), lists:seq(1, 4 * ?MAX)),
    {200, ~"ok", _} = response(send_get(C, 1, ~"/"), 1).

no_policy_allows_any_number(Config) ->
    %% `control_frame_policy => false`: no frame is counted.
    C = allowed(open(Config), lists:duplicate(5000, ?UNKNOWN)),
    {200, ~"ok", _} = response(send_get(C, 1, ~"/"), 1).

%% =============================================================================
%% Helpers
%% =============================================================================

%% `C` has had `Sent` frames counted: send `Frame` up to the limit, which
%% is allowed, then once more, which closes the connection.
flood(C, Sent, Frame) ->
    flood(C, Sent, Frame, 2 * ?MAX).

flood(C, Sent, Frame, Limit) ->
    flood_frames(C, lists:duplicate(Limit - Sent, Frame), Frame).

%% `Frames` are allowed; `Last` after them closes the connection with
%% GOAWAY(ENHANCE_YOUR_CALM), naming the last stream the client opened.
flood_frames(C0, Frames, Last) ->
    #{sock := Sock} = C1 = allowed(C0, Frames),
    ok = gen_tcp:send(Sock, Last),
    {Seen, C2} = until(C1, fun is_goaway/1),
    ?assertEqual({goaway, last_stream(C2), enhance_your_calm, <<>>}, lists:last(Seen)),
    closed(C2).

%% Send `Frames`, then a PING: the server answers it, so it read them all
%% and stayed open.
allowed(#{sock := Sock} = C0, Frames) ->
    N = length(Frames),
    ok = gen_tcp:send(Sock, [Frames, roadrunner_http2_frame:encode({ping, 0, <<N:64>>})]),
    {Seen, C1} = until(C0, fun(F) -> is_ping_ack(F) orelse is_goaway(F) end),
    ?assertEqual({ping, 1, <<N:64>>}, lists:last(Seen)),
    C1.

%% `N` DATA frames with nothing in them on `StreamId`, END_STREAM or not.
empty_data(StreamId, N) ->
    [
        roadrunner_http2_frame:encode({data, StreamId, 16#01 * (I rem 2), <<>>})
     || I <- lists:seq(1, N)
    ].

%% The frames of a POST whose body is still to come, and its reset.
post_and_reset(#{enc := Enc} = C, StreamId) ->
    {Block, Enc1} = roadrunner_http2_hpack:encode(fields(~"POST", ~"/"), Enc),
    Frames = [
        roadrunner_http2_frame:encode({headers, StreamId, 16#04, undefined, Block}),
        roadrunner_http2_frame:encode({rst_stream, StreamId, cancel})
    ],
    {Frames, C#{enc := Enc1, last := StreamId}}.

%% The frame of a GET the server refuses: the last stream it took stays.
get_frame(#{enc := Enc} = C, StreamId) ->
    {Block, Enc1} = roadrunner_http2_hpack:encode(fields(~"GET", ~"/"), Enc),
    {roadrunner_http2_frame:encode({headers, StreamId, 16#05, undefined, Block}), C#{enc := Enc1}}.

%% A POST on `StreamId` that depends on itself (RFC 9113 §5.3.1): the
%% server refuses the stream and resets it, its body still to come.
send_self_dependent(#{sock := Sock, enc := Enc} = C, StreamId) ->
    {Block, Enc1} = roadrunner_http2_hpack:encode(fields(~"POST", ~"/"), Enc),
    Priority = #{exclusive => false, stream_dependency => StreamId, weight => 15},
    ok = gen_tcp:send(
        Sock, roadrunner_http2_frame:encode({headers, StreamId, 16#04, Priority, Block})
    ),
    {[{rst_stream, StreamId, protocol_error}], C1} = until(C#{enc := Enc1}, fun is_rst_stream/1),
    C1.

%% A GET of `/stream/large` whose first byte the client bought with a
%% WINDOW_UPDATE (its window opened at 0): the rest of the response is
%% held back, waiting on the stream window.
first_byte(C0) ->
    #{sock := Sock} = C1 = send_get(C0, 1, ~"/stream/large"),
    ok = gen_tcp:send(Sock, roadrunner_http2_frame:encode({window_update, 1, 1})),
    {[_ | _], C2} = until(C1, fun(F) -> element(1, F) =:= data end),
    C2.

%% Read `Bytes` of stream `StreamId`'s DATA.
read_data(C, _StreamId, 0) ->
    C;
read_data(C0, StreamId, Bytes) ->
    case next_frame(C0) of
        {{data, StreamId, _, Data, _}, C1} -> read_data(C1, StreamId, Bytes - byte_size(Data));
        {_Other, C1} -> read_data(C1, StreamId, Bytes)
    end.

%% Buy one byte of stream 1's response with WINDOW_UPDATE and send five
%% frames of an unknown type, each round once the byte came, until the
%% server closes the connection; fail after `Rounds`.
trickle(_C, 0) ->
    ct:fail(trickle_not_closed);
trickle(#{sock := Sock} = C0, Rounds) ->
    ok = gen_tcp:send(Sock, [
        roadrunner_http2_frame:encode({window_update, 1, 1}), lists:duplicate(5, ?UNKNOWN)
    ]),
    {Seen, C1} = until(C0, fun(F) -> is_goaway(F) orelse element(1, F) =:= data end),
    trickle_next(lists:last(Seen), C1, Rounds).

trickle_next({data, 1, 0, <<_>>, _}, C, Rounds) ->
    trickle(C, Rounds - 1);
trickle_next({goaway, 1, enhance_your_calm, <<>>}, C, _Rounds) ->
    closed(C).

fields(Method, Path) ->
    [{~":method", Method}, {~":scheme", ~"http"}, {~":authority", ~"x"}, {~":path", Path}].

is_rst_stream({rst_stream, _, _}) -> true;
is_rst_stream(_Frame) -> false.

priority(StreamId) ->
    roadrunner_http2_frame:encode(
        {priority, StreamId, #{exclusive => false, stream_dependency => 0, weight => 15}}
    ).

%% The last stream the client opened (the GOAWAY names it).
last_stream(#{last := Last}) -> Last.

%% Read stream `StreamId`'s response, opening the stream and connection
%% windows after each DATA frame by what it carried.
read_with_updates(#{sock := Sock} = C0, StreamId, Body) ->
    case next_frame(C0) of
        {{data, StreamId, Flags, Data, _}, C1} ->
            Body1 = <<Body/binary, Data/binary>>,
            case Flags band 16#01 of
                0 ->
                    ok = gen_tcp:send(Sock, [
                        roadrunner_http2_frame:encode({window_update, StreamId, byte_size(Data)}),
                        roadrunner_http2_frame:encode({window_update, 0, byte_size(Data)})
                    ]),
                    read_with_updates(C1, StreamId, Body1);
                _ ->
                    {200, Body1, C1}
            end;
        {{goaway, _, _, _} = GoAway, _C1} ->
            ct:fail({unexpected, GoAway});
        {_Other, C1} ->
            read_with_updates(C1, StreamId, Body)
    end.

%% Send `Left` bytes of body on `StreamId` in 16 KB DATA frames within the
%% stream's send window `Window`, reading the server's WINDOW_UPDATEs when
%% it runs out (the connection window is far larger).
upload(C, _StreamId, 0, _Window) ->
    C;
upload(C0, StreamId, Left, Window) when Window > 0 ->
    Size = lists:min([Left, Window, 16384]),
    Fin =
        case Size of
            Left -> 16#01;
            _ -> 0
        end,
    C1 = send_data(C0, StreamId, binary:copy(~"x", Size), Fin),
    upload(C1, StreamId, Left - Size, Window - Size);
upload(C0, StreamId, Left, Window) ->
    case next_frame(C0) of
        {{window_update, StreamId, Inc}, C1} -> upload(C1, StreamId, Left, Window + Inc);
        {{goaway, _, _, _} = GoAway, _C1} -> ct:fail({unexpected, GoAway});
        {_Other, C1} -> upload(C1, StreamId, Left, Window)
    end.

send_data(#{sock := Sock} = C, StreamId, Data, Flags) ->
    ok = gen_tcp:send(Sock, roadrunner_http2_frame:encode({data, StreamId, Flags, Data})),
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

wait(Ms) ->
    receive
    after Ms -> ok
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
    open(Config, []).

open(Config, Settings) ->
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, ?config(port, Config), [binary, {active, false}], 5000
    ),
    ok = gen_tcp:send(Sock, [
        ~"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", roadrunner_http2_frame:encode({settings, 0, Settings})
    ]),
    #{
        sock => Sock,
        buf => <<>>,
        last => 0,
        enc => roadrunner_http2_hpack:new_encoder(4096),
        dec => roadrunner_http2_hpack:new_decoder(4096)
    }.

send_rst(#{sock := Sock} = C, StreamId) ->
    ok = gen_tcp:send(Sock, roadrunner_http2_frame:encode({rst_stream, StreamId, cancel})),
    C.

%% A POST without END_STREAM: its body is still to come.
send_post_headers(C, StreamId) ->
    send_post_headers(C, StreamId, ~"/").

send_post_headers(C, StreamId, Path) ->
    send_request(C, StreamId, ~"POST", Path, 16#04).

%% A GET with END_STREAM.
send_get(C, StreamId, Path) ->
    send_request(C, StreamId, ~"GET", Path, 16#05).

send_request(#{sock := Sock, enc := Enc} = C, StreamId, Method, Path, Flags) ->
    Fields = [
        {~":method", Method},
        {~":scheme", ~"http"},
        {~":authority", ~"x"},
        {~":path", Path}
    ],
    {Block, Enc1} = roadrunner_http2_hpack:encode(Fields, Enc),
    ok = gen_tcp:send(
        Sock, roadrunner_http2_frame:encode({headers, StreamId, Flags, undefined, Block})
    ),
    C#{enc := Enc1, last := StreamId}.

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
        {{goaway, _, _, _} = GoAway, _C1} ->
            ct:fail({unexpected, GoAway});
        {_Other, C1} ->
            response(C1, StreamId, Status, Body)
    end.

%% Every frame up to and including the first `Pred` picks; SETTINGS and
%% WINDOW_UPDATE frames are left out.
until(C, Pred) ->
    until(C, Pred, []).

until(C, Pred, Acc) ->
    {Frame, C1} = next_frame(C),
    case Pred(Frame) of
        true ->
            {lists:reverse([Frame | Acc]), C1};
        false when element(1, Frame) =:= settings; element(1, Frame) =:= window_update ->
            until(C1, Pred, Acc);
        false ->
            until(C1, Pred, [Frame | Acc])
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
