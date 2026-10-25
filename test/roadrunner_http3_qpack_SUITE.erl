-module(roadrunner_http3_qpack_SUITE).
-moduledoc """
End-to-end tests of the QPACK dynamic table over HTTP/3 (RFC 9204): a
raw native QUIC client (`roadrunner_quic_test_conn`) writes encoder-stream
instructions and field sections that reference them by hand, and reads
the server's decoder stream for the instructions it answers with.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    advertises_table_capacity/1,
    request_uses_dynamic_table/1,
    request_with_body_uses_dynamic_table/1,
    reset_stream_is_cancelled/1,
    refused_request_is_cancelled/1,
    section_needing_more_inserts_fails/1,
    section_needing_more_inserts_fails_before_body/1,
    blocked_request_waits_for_inserts/1,
    blocked_request_body_waits/1,
    blocked_trailers_wait/1,
    blocked_section_fails_once_unblocked/1,
    too_many_blocked_streams/1,
    blocked_stream_reset_is_cancelled/1,
    blocked_body_over_cap/1,
    request_ended_before_blocked_trailers/1,
    section_before_blocked_trailers_fails/1,
    manual_blocked_trailers/1,
    manual_worker_done_while_blocked/1,
    drain_waits_for_blocked_stream/1,
    drain_deadline_ends_blocked_stream/1,
    static_section_with_dynamic_line_fails/1,
    capacity_over_the_limit_fails/1,
    dynamic_table_off/1,
    peer_allows_one_uni_stream/1
]).

%% RFC 9204 §6 error codes, RFC 9114 §8.1 H3_GENERAL_PROTOCOL_ERROR.
-define(QPACK_DECOMPRESSION_FAILED, 16#0200).
-define(QPACK_ENCODER_STREAM_ERROR, 16#0201).
-define(H3_GENERAL_PROTOCOL_ERROR, 16#0101).
-define(H3_REQUEST_CANCELLED, 16#010C).
-define(H3_NO_ERROR, 16#0100).
-define(H3_MESSAGE_ERROR, 16#010E).

%% The server's unidirectional streams are its control stream (id 3),
%% opened at the handshake, then its QPACK decoder stream (id 7), opened
%% with the first instruction it sends.
-define(DECODER_STREAM, 7).

%% The server's control stream, which carries its GOAWAY.
-define(CONTROL_STREAM, 3).

%% Set Dynamic Table Capacity 4096 (`001` + 5-bit prefix 31 + 4065).
-define(CAPACITY_4096, <<16#3F, 16#E1, 16#1F>>).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        advertises_table_capacity,
        request_uses_dynamic_table,
        request_with_body_uses_dynamic_table,
        reset_stream_is_cancelled,
        refused_request_is_cancelled,
        section_needing_more_inserts_fails,
        section_needing_more_inserts_fails_before_body,
        blocked_request_waits_for_inserts,
        blocked_request_body_waits,
        blocked_trailers_wait,
        blocked_section_fails_once_unblocked,
        too_many_blocked_streams,
        blocked_stream_reset_is_cancelled,
        blocked_body_over_cap,
        request_ended_before_blocked_trailers,
        section_before_blocked_trailers_fails,
        manual_blocked_trailers,
        manual_worker_done_while_blocked,
        drain_waits_for_blocked_stream,
        drain_deadline_ends_blocked_stream,
        static_section_with_dynamic_line_fails,
        capacity_over_the_limit_fails,
        dynamic_table_off,
        peer_allows_one_uni_stream
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(crypto),
    {ok, _} = application:ensure_all_started(ssl),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(Case, Config) ->
    Name = list_to_atom("rr_h3_qpack_" ++ atom_to_list(Case)),
    {ok, _} = roadrunner_listener:start_link(
        Name,
        maps:merge(
            #{
                port => 0,
                protocols => [{http3, http3_opts(Case)}],
                tls => roadrunner_test_certs:server_opts(),
                routes => roadrunner_h3_test_handler,
                max_content_length => 64
            },
            listener_opts(Case)
        )
    ),
    [{listener, Name}, {port, roadrunner_listener:port(Name)} | Config].

http3_opts(dynamic_table_off) -> #{qpack_max_table_capacity => 0};
http3_opts(section_needing_more_inserts_fails) -> #{qpack_blocked_streams => 0};
http3_opts(section_needing_more_inserts_fails_before_body) -> #{qpack_blocked_streams => 0};
http3_opts(too_many_blocked_streams) -> #{qpack_blocked_streams => 1};
http3_opts(blocked_stream_reset_is_cancelled) -> #{qpack_blocked_streams => 1};
http3_opts(_Case) -> #{}.

%% A blocked request holds no in-flight slot: with one allowed, another
%% request is served while it waits.
listener_opts(blocked_request_waits_for_inserts) -> #{max_concurrent_requests => 1};
listener_opts(manual_blocked_trailers) -> manual_opts();
listener_opts(manual_worker_done_while_blocked) -> manual_opts();
listener_opts(_Case) -> #{}.

%% Manual body reading, `/read` reading the body and answering its size,
%% `/reject` answering without reading it.
manual_opts() ->
    #{
        body_buffering => manual,
        routes => [
            {~"/", roadrunner_h3_test_handler, undefined},
            {~"/read", roadrunner_manual_body_handler, read},
            {~"/reject", roadrunner_manual_body_handler, reject}
        ]
    }.

end_per_testcase(_Case, Config) ->
    %% A failing testcase exits and takes its linked listener with it, so
    %% tolerate an already-gone listener on cleanup.
    try
        roadrunner_listener:stop(?config(listener, Config))
    catch
        _:_ -> ok
    end.

%% --- testcases ---

advertises_table_capacity(Config) ->
    %% RFC 9204 §5: a 4096-byte dynamic table by default, and 16 blocked
    %% streams.
    Conn = connect(Config),
    ?assertMatch(
        #{qpack_max_table_capacity := 4096, qpack_blocked_streams := 16},
        roadrunner_quic_test_h3:get_peer_settings(Conn)
    ),
    close(Conn).

request_uses_dynamic_table(Config) ->
    %% The encoder stream sets a capacity and inserts two entries; the
    %% server tells the encoder of both (Insert Count Increment 2, on a
    %% decoder stream it opens for it), decodes a request referencing them,
    %% and acknowledges the section (RFC 9204 §4.4.1). A Duplicate later
    %% gets an increment of its own, and a chunk that inserts nothing none.
    Conn = connect(Config),
    Encoder = insert_two(Conn),
    ok = await_decoder(Conn, <<16#03, 16#02>>),
    {200, ~"dynamic-value"} = request(Conn, dynamic_section(), true),
    ok = await_decoder(Conn, section_ack(0)),
    ok = roadrunner_quic_test_conn:send(Conn, Encoder, ?CAPACITY_4096, false),
    ok = roadrunner_quic_test_conn:send(Conn, Encoder, <<16#00>>, false),
    ok = await_decoder(Conn, <<16#01>>),
    %% The duplicate is absolute 2, a copy of x-custom: Required Insert
    %% Count 3, Base 3, the duplicate at relative 0 and `:authority` at 2.
    {200, ~"dynamic-value"} = request(
        Conn, section(3, [16#D1, 16#D7, 16#82, path_line(~"/header/x-custom"), 16#80]), true
    ),
    ok = await_decoder(Conn, section_ack(4)),
    close(Conn).

request_with_body_uses_dynamic_table(Config) ->
    %% A request whose body is still to come has its section decoded (and
    %% acknowledged) as its HEADERS frame arrives; its trailers, also
    %% referencing the table, are decoded and acknowledged too.
    Conn = connect(Config),
    _ = insert_two(Conn),
    ok = await_decoder(Conn, <<16#03, 16#02>>),
    StreamId = roadrunner_quic_test_conn:open_bidi(Conn),
    Path = ~"/echo",
    Block = section(2, [16#D4, 16#D7, 16#81, path_line(Path)]),
    ok = roadrunner_quic_test_conn:send(Conn, StreamId, headers_frame(Block), false),
    ok = await_decoder(Conn, section_ack(StreamId)),
    ok = roadrunner_quic_test_conn:send(
        Conn,
        StreamId,
        [roadrunner_quic_h3_frame:encode_data(~"body"), headers_frame(section(2, [16#80]))],
        true
    ),
    ?assertEqual({200, ~"body"}, response(Conn, StreamId)),
    ok = await_decoder(Conn, section_ack(StreamId)),
    close(Conn).

reset_stream_is_cancelled(Config) ->
    %% A request stream reset before its section is all in gets a Stream
    %% Cancellation (RFC 9204 §4.4.2), and the connection serves on.
    Conn = connect(Config),
    _ = insert_two(Conn),
    ok = await_decoder(Conn, <<16#03, 16#02>>),
    StreamId = roadrunner_quic_test_conn:open_bidi(Conn),
    Frame = iolist_to_binary(headers_frame(dynamic_section())),
    ok = roadrunner_quic_test_conn:send(Conn, StreamId, binary:part(Frame, 0, 4), false),
    ok = roadrunner_quic_test_conn:reset_stream(Conn, StreamId, ?H3_REQUEST_CANCELLED),
    ok = await_decoder(Conn, stream_cancellation(StreamId)),
    {200, ~"dynamic-value"} = request(Conn, dynamic_section(), true),
    close(Conn).

refused_request_is_cancelled(Config) ->
    %% A request refused before its section is decoded (413: the body is
    %% past the 64-byte cap of a single-handler listener) gets a Stream
    %% Cancellation instead of an acknowledgment.
    Conn = connect(Config),
    _ = insert_two(Conn),
    ok = await_decoder(Conn, <<16#03, 16#02>>),
    StreamId = roadrunner_quic_test_conn:open_bidi(Conn),
    ok = roadrunner_quic_test_conn:send(
        Conn,
        StreamId,
        [
            headers_frame(section(2, [16#D4, 16#D7, 16#81, path_line(~"/echo")])),
            roadrunner_quic_h3_frame:encode_data(binary:copy(~"x", 100))
        ],
        true
    ),
    ?assertMatch({413, _}, response(Conn, StreamId)),
    ok = await_decoder(Conn, stream_cancellation(StreamId)),
    close(Conn).

section_needing_more_inserts_fails(Config) ->
    %% A section whose Required Insert Count is past the inserts received
    %% would block, which `qpack_blocked_streams => 0` allows on no stream
    %% (RFC 9204 §2.1.2).
    Conn = connect(Config),
    ?assertMatch(
        #{qpack_blocked_streams := 0}, roadrunner_quic_test_h3:get_peer_settings(Conn)
    ),
    StreamId = roadrunner_quic_test_conn:open_bidi(Conn),
    ok = roadrunner_quic_test_conn:send(Conn, StreamId, headers_frame(dynamic_section()), true),
    ?assertEqual(?QPACK_DECOMPRESSION_FAILED, await_close_code(Conn)).

section_needing_more_inserts_fails_before_body(Config) ->
    %% The same for a section decoded ahead of a body still to come.
    Conn = connect(Config),
    StreamId = roadrunner_quic_test_conn:open_bidi(Conn),
    ok = roadrunner_quic_test_conn:send(Conn, StreamId, headers_frame(dynamic_section()), false),
    ?assertEqual(?QPACK_DECOMPRESSION_FAILED, await_close_code(Conn)).

static_section_with_dynamic_line_fails(Config) ->
    %% A section with Required Insert Count 0 that references the dynamic
    %% table anyway (RFC 9204 §2.2.3).
    Conn = connect(Config),
    StreamId = roadrunner_quic_test_conn:open_bidi(Conn),
    ok = roadrunner_quic_test_conn:send(Conn, StreamId, headers_frame(<<0, 0, 16#80>>), true),
    ?assertEqual(?QPACK_DECOMPRESSION_FAILED, await_close_code(Conn)).

capacity_over_the_limit_fails(Config) ->
    %% RFC 9204 §4.3.1: a capacity above the advertised 4096.
    Conn = connect(Config),
    _ = open_encoder(Conn, <<16#3F, 16#E2, 16#1F>>),
    ?assertEqual(?QPACK_ENCODER_STREAM_ERROR, await_close_code(Conn)).

dynamic_table_off(Config) ->
    %% `qpack_max_table_capacity => 0` advertises no table: a capacity of
    %% 0 is all the encoder may set, and the first insert fails.
    Conn = connect(Config),
    ?assertMatch(
        #{qpack_max_table_capacity := 0}, roadrunner_quic_test_h3:get_peer_settings(Conn)
    ),
    Encoder = open_encoder(Conn, <<16#20>>),
    {200, ~"ok"} = request(Conn, roadrunner_qpack:encode(headers(~"/")), true),
    ok = roadrunner_quic_test_conn:send(Conn, Encoder, <<16#C0, 16#01, $x>>, false),
    ?assertEqual(?QPACK_ENCODER_STREAM_ERROR, await_close_code(Conn)).

peer_allows_one_uni_stream(Config) ->
    %% RFC 9114 §6.2: a client must allow the server three unidirectional
    %% streams. One allowing a single stream has it taken by the control
    %% stream, so the decoder stream the first insert needs cannot open.
    {ok, Conn} = roadrunner_quic_test_conn:connect(
        {127, 0, 0, 1}, ?config(port, Config), #{max_streams_uni => 1}
    ),
    _ = insert_two(Conn),
    ?assertEqual(?H3_GENERAL_PROTOCOL_ERROR, await_close_code(Conn)).

blocked_request_waits_for_inserts(Config) ->
    %% RFC 9204 §2.2.1: a request referencing entries not received yet
    %% waits for them instead of failing. It holds no in-flight slot while
    %% it waits (one allowed here), so another request is served, and its
    %% section is acknowledged only once the inserts come and it is decoded.
    Conn = connect(Config),
    StreamId = roadrunner_quic_test_conn:open_bidi(Conn),
    ok = roadrunner_quic_test_conn:send(Conn, StreamId, headers_frame(dynamic_section()), true),
    {200, ~"ok"} = request(Conn, roadrunner_qpack:encode(headers(~"/")), true),
    ok = no_response(Conn, StreamId),
    _ = insert_two(Conn),
    ok = await_decoder(Conn, <<16#03, 16#02>>),
    ok = await_decoder(Conn, section_ack(StreamId)),
    ?assertEqual({200, ~"dynamic-value"}, response(Conn, StreamId)),
    close(Conn).

blocked_request_body_waits(Config) ->
    %% The body that follows a blocked HEADERS frame is held, in order, and
    %% read once the section is.
    Conn = connect(Config),
    StreamId = roadrunner_quic_test_conn:open_bidi(Conn),
    ok = roadrunner_quic_test_conn:send(Conn, StreamId, headers_frame(echo_section(2)), false),
    ok = roadrunner_quic_test_conn:send(Conn, StreamId, data_frame(~"bo"), false),
    ok = roadrunner_quic_test_conn:send(Conn, StreamId, data_frame(~"dy"), true),
    {200, ~"ok"} = request(Conn, roadrunner_qpack:encode(headers(~"/")), true),
    ok = no_response(Conn, StreamId),
    _ = insert_two(Conn),
    ok = await_decoder(Conn, <<16#03, 16#02>>),
    ok = await_decoder(Conn, section_ack(StreamId)),
    ?assertEqual({200, ~"body"}, response(Conn, StreamId)),
    close(Conn).

blocked_trailers_wait(Config) ->
    %% Trailers that need an insert still to come block the request, whose
    %% headers are decoded (and acknowledged) already; the third insert
    %% unblocks it and the trailers are acknowledged in turn.
    Conn = connect(Config),
    Encoder = insert_two(Conn),
    ok = await_decoder(Conn, <<16#03, 16#02>>),
    StreamId = roadrunner_quic_test_conn:open_bidi(Conn),
    ok = roadrunner_quic_test_conn:send(
        Conn,
        StreamId,
        [headers_frame(echo_section(2)), data_frame(~"body"), headers_frame(section(3, [16#80]))],
        true
    ),
    ok = await_decoder(Conn, section_ack(StreamId)),
    {200, ~"ok"} = request(Conn, roadrunner_qpack:encode(headers(~"/")), true),
    ok = no_response(Conn, StreamId),
    ok = roadrunner_quic_test_conn:send(Conn, Encoder, third_insert(), false),
    ok = await_decoder(Conn, <<16#01>>),
    ok = await_decoder(Conn, section_ack(StreamId)),
    ?assertEqual({200, ~"body"}, response(Conn, StreamId)),
    close(Conn).

blocked_section_fails_once_unblocked(Config) ->
    %% A blocked section that still does not decode once its inserts are in
    %% (a reference past them, RFC 9204 §2.2.3) fails the connection then.
    Conn = connect(Config),
    StreamId = roadrunner_quic_test_conn:open_bidi(Conn),
    ok = roadrunner_quic_test_conn:send(
        Conn, StreamId, headers_frame(section(2, [16#D1, 16#D7, 16#85])), true
    ),
    _ = insert_two(Conn),
    ?assertEqual(?QPACK_DECOMPRESSION_FAILED, await_close_code(Conn)).

too_many_blocked_streams(Config) ->
    %% RFC 9204 §2.1.2: one blocked stream allowed and advertised; a second
    %% is QPACK_DECOMPRESSION_FAILED.
    Conn = connect(Config),
    ?assertMatch(
        #{qpack_blocked_streams := 1}, roadrunner_quic_test_h3:get_peer_settings(Conn)
    ),
    First = roadrunner_quic_test_conn:open_bidi(Conn),
    ok = roadrunner_quic_test_conn:send(Conn, First, headers_frame(dynamic_section()), true),
    Second = roadrunner_quic_test_conn:open_bidi(Conn),
    ok = roadrunner_quic_test_conn:send(Conn, Second, headers_frame(dynamic_section()), true),
    ?assertEqual(?QPACK_DECOMPRESSION_FAILED, await_close_code(Conn)).

blocked_stream_reset_is_cancelled(Config) ->
    %% A blocked stream the client resets, or tells to stop sending, gets a
    %% Stream Cancellation (RFC 9204 §4.4.2) and stops counting as blocked:
    %% with one allowed, the next one may block in its place, and the
    %% insert it waits for unblocks it alone.
    Conn = connect(Config),
    Encoder = insert_one(Conn),
    ok = await_decoder(Conn, <<16#03, 16#01>>),
    Reset = roadrunner_quic_test_conn:open_bidi(Conn),
    ok = roadrunner_quic_test_conn:send(Conn, Reset, headers_frame(dynamic_section()), false),
    ok = roadrunner_quic_test_conn:reset_stream(Conn, Reset, ?H3_REQUEST_CANCELLED),
    ok = await_decoder(Conn, stream_cancellation(Reset)),
    Stopped = roadrunner_quic_test_conn:open_bidi(Conn),
    ok = roadrunner_quic_test_conn:send(Conn, Stopped, headers_frame(dynamic_section()), true),
    ok = roadrunner_quic_test_conn:stop_sending(Conn, Stopped, ?H3_REQUEST_CANCELLED),
    ok = await_decoder(Conn, stream_cancellation(Stopped)),
    StreamId = roadrunner_quic_test_conn:open_bidi(Conn),
    ok = roadrunner_quic_test_conn:send(Conn, StreamId, headers_frame(dynamic_section()), true),
    ok = roadrunner_quic_test_conn:send(Conn, Encoder, second_insert(), false),
    ok = await_decoder(Conn, <<16#01>>),
    ok = await_decoder(Conn, section_ack(StreamId)),
    ?assertEqual({200, ~"dynamic-value"}, response(Conn, StreamId)),
    ok = no_response(Conn, Reset),
    close(Conn).

blocked_body_over_cap(Config) ->
    %% A blocked stream holds at most its body cap (64 bytes here) plus two
    %% field sections' worth; past that it is answered 413, with a Stream
    %% Cancellation, as its section was never decoded.
    Conn = connect(Config),
    _ = insert_one(Conn),
    ok = await_decoder(Conn, <<16#03, 16#01>>),
    StreamId = roadrunner_quic_test_conn:open_bidi(Conn),
    ok = roadrunner_quic_test_conn:send(Conn, StreamId, headers_frame(echo_section(2)), false),
    ok = roadrunner_quic_test_conn:send(
        Conn, StreamId, data_frame(binary:copy(~"x", 2 * 16384 + 64)), true
    ),
    ?assertMatch({413, _}, response(Conn, StreamId)),
    ok = await_decoder(Conn, stream_cancellation(StreamId)),
    {200, ~"ok"} = request(Conn, roadrunner_qpack:encode(headers(~"/")), true),
    close(Conn).

request_ended_before_blocked_trailers(Config) ->
    %% The frames before blocked trailers can end the request first: a
    %% malformed `content-length` resets it, and one past the 64-byte cap is
    %% refused (413) on its `expect: 100-continue`. Neither blocks, and
    %% nothing is left behind: a drain right after ends at once.
    Name = ?config(listener, Config),
    Conn = connect(Config),
    Trailers = headers_frame(section(1, [16#80])),
    Malformed = roadrunner_quic_test_conn:open_bidi(Conn),
    ok = roadrunner_quic_test_conn:send(
        Conn, Malformed, [expect_headers(~"abc"), data_frame(~"x"), Trailers], true
    ),
    ?assertEqual(?H3_MESSAGE_ERROR, await_reset(Conn, Malformed)),
    Refused = roadrunner_quic_test_conn:open_bidi(Conn),
    ok = roadrunner_quic_test_conn:send(
        Conn, Refused, [expect_headers(~"100"), data_frame(~"x"), Trailers], true
    ),
    ?assertMatch({413, _}, response(Conn, Refused)),
    Unfinished = roadrunner_quic_test_conn:open_bidi(Conn),
    ok = roadrunner_quic_test_conn:send(
        Conn, Unfinished, [expect_headers(~"100"), data_frame(~"x"), Trailers], false
    ),
    ?assertMatch({413, _}, response(Conn, Unfinished)),
    ok = roadrunner_quic_test_conn:send(Conn, Unfinished, data_frame(~"x"), true),
    ?assertEqual({ok, drained}, roadrunner_listener:drain(Name, 2000)),
    close(Conn).

section_before_blocked_trailers_fails(Config) ->
    %% Request headers that do not decode (a static-only section with a
    %% dynamic line, RFC 9204 §2.2.3) fail the connection even when the
    %% trailers after them would block.
    Conn = connect(Config),
    StreamId = roadrunner_quic_test_conn:open_bidi(Conn),
    ok = roadrunner_quic_test_conn:send(
        Conn,
        StreamId,
        [headers_frame(<<0, 0, 16#80>>), data_frame(~"x"), headers_frame(section(1, [16#80]))],
        true
    ),
    ?assertEqual(?QPACK_DECOMPRESSION_FAILED, await_close_code(Conn)).

manual_blocked_trailers(Config) ->
    %% With manual body reading the request is dispatched on its headers;
    %% its worker reads the body, and the body's end, held behind blocked
    %% trailers, reaches it once the trailers are decoded.
    Conn = connect(Config),
    Encoder = insert_two(Conn),
    ok = await_decoder(Conn, <<16#03, 16#02>>),
    StreamId = roadrunner_quic_test_conn:open_bidi(Conn),
    ok = roadrunner_quic_test_conn:send(
        Conn, StreamId, [headers_frame(post_section(~"/read")), data_frame(~"body")], false
    ),
    ok = await_decoder(Conn, section_ack(StreamId)),
    ok = roadrunner_quic_test_conn:send(Conn, StreamId, headers_frame(section(3, [16#80])), false),
    ok = roadrunner_quic_test_conn:send(Conn, StreamId, <<>>, true),
    {200, ~"ok"} = request(Conn, roadrunner_qpack:encode(headers(~"/")), true),
    ok = no_response(Conn, StreamId),
    ok = roadrunner_quic_test_conn:send(Conn, Encoder, third_insert(), false),
    ok = await_decoder(Conn, <<16#01>>),
    ok = await_decoder(Conn, section_ack(StreamId)),
    ?assertEqual({200, ~"4"}, response(Conn, StreamId)),
    close(Conn).

manual_worker_done_while_blocked(Config) ->
    %% A manual-mode worker that answers without reading the body while the
    %% trailers wait on an insert: the stream is dropped with a Stream
    %% Cancellation, whether the client had finished sending or not.
    Conn = connect(Config),
    _ = insert_two(Conn),
    ok = await_decoder(Conn, <<16#03, 16#02>>),
    Request = [
        headers_frame(post_section(~"/reject")),
        data_frame(~"body"),
        headers_frame(section(3, [16#80]))
    ],
    Finished = roadrunner_quic_test_conn:open_bidi(Conn),
    ok = roadrunner_quic_test_conn:send(Conn, Finished, Request, true),
    ok = await_decoder(Conn, section_ack(Finished)),
    ?assertEqual({401, ~"no"}, response(Conn, Finished)),
    ok = await_decoder(Conn, stream_cancellation(Finished)),
    Sending = roadrunner_quic_test_conn:open_bidi(Conn),
    ok = roadrunner_quic_test_conn:send(Conn, Sending, Request, false),
    ok = await_decoder(Conn, section_ack(Sending)),
    ?assertEqual({401, ~"no"}, response(Conn, Sending)),
    ok = await_decoder(Conn, stream_cancellation(Sending)),
    close(Conn).

drain_waits_for_blocked_stream(Config) ->
    %% A request blocked when a drain starts is below the GOAWAY id, so it
    %% is still served: the connection stays open until the inserts it
    %% waits for come and its response is out, then closes, and the drain
    %% ends.
    Name = ?config(listener, Config),
    Conn = connect(Config),
    StreamId = roadrunner_quic_test_conn:open_bidi(Conn),
    ok = roadrunner_quic_test_conn:send(Conn, StreamId, headers_frame(dynamic_section()), true),
    {200, ~"ok"} = request(Conn, roadrunner_qpack:encode(headers(~"/")), true),
    Self = self(),
    _ = spawn(fun() -> Self ! {drained, roadrunner_listener:drain(Name, 10000)} end),
    ok = await_goaway(Conn, <<>>),
    ok = no_response(Conn, StreamId),
    _ = insert_two(Conn),
    ?assertEqual({200, ~"dynamic-value"}, response(Conn, StreamId)),
    ?assertEqual(?H3_NO_ERROR, await_close_code(Conn)),
    receive
        {drained, Result} -> ?assertEqual({ok, drained}, Result)
    after 5000 -> ct:fail(drain_never_returned)
    end.

drain_deadline_ends_blocked_stream(Config) ->
    %% If the inserts never come, the drain deadline ends the connection,
    %% as it does for a request still running.
    Name = ?config(listener, Config),
    Conn = connect(Config),
    StreamId = roadrunner_quic_test_conn:open_bidi(Conn),
    ok = roadrunner_quic_test_conn:send(Conn, StreamId, headers_frame(dynamic_section()), true),
    {200, ~"ok"} = request(Conn, roadrunner_qpack:encode(headers(~"/")), true),
    ?assertMatch({timeout, _}, roadrunner_listener:drain(Name, 200)),
    close(Conn).

%% --- helpers ---

%% Capacity 4096 and `:authority: localhost` (absolute 0), RFC 9204 §4.3.
insert_one(Conn) ->
    open_encoder(Conn, [?CAPACITY_4096, <<16#C0, 9, "localhost">>]).

%% `x-custom: dynamic-value` with a literal name, absolute 1 after
%% `insert_one/1`.
second_insert() ->
    <<16#48, "x-custom", 13, "dynamic-value">>.

%% `:authority: localhost` again, absolute 2 after `insert_two/1`.
third_insert() ->
    <<16#C0, 9, "localhost">>.

%% A POST of `/echo` with Required Insert Count `Ric`, its `:authority`
%% from absolute 0 (relative `Ric - 1`).
echo_section(Ric) ->
    section(Ric, [16#D4, 16#D7, 16#80 bor (Ric - 1), path_line(~"/echo")]).

%% A POST of `Path` with Required Insert Count 2, its `:authority` from
%% absolute 0.
post_section(Path) ->
    section(2, [16#D4, 16#D7, 16#81, path_line(Path)]).

%% A static-only POST of `/echo` expecting `100-continue`, with the
%% `content-length` given.
expect_headers(ContentLength) ->
    headers_frame(
        roadrunner_qpack:encode([
            {~":method", ~"POST"},
            {~":scheme", ~"https"},
            {~":authority", ~"localhost"},
            {~":path", ~"/echo"},
            {~"expect", ~"100-continue"},
            {~"content-length", ContentLength}
        ])
    ).

data_frame(Payload) ->
    roadrunner_quic_h3_frame:encode_data(Payload).

%% Nothing has come on `StreamId`. Called once a later request on the same
%% connection is answered, so the server has read this stream's bytes.
no_response(Conn, StreamId) ->
    receive
        {quic_test_stream, Conn, StreamId, _, _} = Message -> ct:fail({unexpected, Message})
    after 0 ->
        ok
    end.

%% Read the server's control stream until its GOAWAY (naming stream 8, the
%% first after the two requests of the drain tests) has come.
await_goaway(Conn, Acc) ->
    Goaway = iolist_to_binary(roadrunner_quic_h3_frame:encode_goaway(8)),
    case binary:match(Acc, Goaway) of
        nomatch ->
            receive
                {quic_test_stream, Conn, ?CONTROL_STREAM, Bin, false} ->
                    await_goaway(Conn, <<Acc/binary, Bin/binary>>)
            after 5000 ->
                ct:fail(no_goaway)
            end;
        _ ->
            ok
    end.

await_reset(Conn, StreamId) ->
    receive
        {quic_test_stream_reset, Conn, StreamId, ErrorCode} -> ErrorCode
    after 5000 ->
        ct:fail({no_reset, StreamId})
    end.

connect(Config) ->
    {ok, Conn} = roadrunner_quic_test_conn:connect({127, 0, 0, 1}, ?config(port, Config)),
    Conn.

close(Conn) ->
    _ = roadrunner_quic_test_conn:close(Conn),
    ok.

%% Open the encoder stream (type 0x02) and write `Instructions` on it.
open_encoder(Conn, Instructions) ->
    StreamId = roadrunner_quic_test_conn:open_uni(Conn),
    ok = roadrunner_quic_test_conn:send(Conn, StreamId, [<<16#02>>, Instructions], false),
    StreamId.

%% Capacity 4096, then `:authority: localhost` with a static name
%% reference (absolute 0) and `x-custom: dynamic-value` with a literal
%% name (absolute 1), RFC 9204 §4.3.
insert_two(Conn) ->
    open_encoder(Conn, [
        ?CAPACITY_4096,
        <<16#C0, 9, "localhost">>,
        <<16#48, "x-custom", 13, "dynamic-value">>
    ]).

%% A GET of `/header/x-custom` whose `:authority` and `x-custom` come from
%% the dynamic table: Required Insert Count 2, Base 2, `:authority` at
%% relative 1 and `x-custom` at relative 0.
dynamic_section() ->
    section(2, [16#D1, 16#D7, 16#81, path_line(~"/header/x-custom"), 16#80]).

%% A field section with Required Insert Count `Ric` (encoded `Ric + 1`
%% for a 4096-byte table) and Base `Ric` (Sign 0, Delta Base 0).
section(Ric, Lines) ->
    iolist_to_binary([Ric + 1, 0 | Lines]).

%% `:path` as a Literal with static Name Reference (index 1).
path_line(Path) ->
    <<16#51, (byte_size(Path)), Path/binary>>.

headers(Path) ->
    [{~":method", ~"GET"}, {~":scheme", ~"https"}, {~":authority", ~"localhost"}, {~":path", Path}].

headers_frame(Block) ->
    roadrunner_quic_h3_frame:encode_headers(Block).

%% RFC 9204 §4.4.1 and §4.4.2, for stream ids within their prefix.
section_ack(StreamId) -> <<(16#80 bor StreamId)>>.
stream_cancellation(StreamId) -> <<(16#40 bor StreamId)>>.

%% Send a request's field section on a new stream and read the response.
request(Conn, Block, Fin) ->
    StreamId = roadrunner_quic_test_conn:open_bidi(Conn),
    ok = roadrunner_quic_test_conn:send(Conn, StreamId, headers_frame(Block), Fin),
    response(Conn, StreamId).

%% The response on `StreamId` as `{Status, Body}`.
response(Conn, StreamId) ->
    Frames = frames(collect(Conn, StreamId, <<>>)),
    [{headers, Block} | _] = Frames,
    {ok, Headers} = roadrunner_qpack:decode(Block),
    {~":status", Status} = lists:keyfind(~":status", 1, Headers),
    {binary_to_integer(Status), iolist_to_binary([Data || {data, Data} <- Frames])}.

collect(Conn, StreamId, Acc) ->
    receive
        {quic_test_stream, Conn, StreamId, Bin, true} ->
            <<Acc/binary, Bin/binary>>;
        {quic_test_stream, Conn, StreamId, Bin, false} ->
            collect(Conn, StreamId, <<Acc/binary, Bin/binary>>)
    after 5000 ->
        ct:fail({no_response, StreamId})
    end.

frames(<<>>) ->
    [];
frames(Bytes) ->
    {ok, Frame, Rest} = roadrunner_quic_h3_frame:decode(Bytes),
    [Frame | frames(Rest)].

%% Read exactly `Expected` off the server's decoder stream.
await_decoder(Conn, Expected) ->
    await_decoder(Conn, Expected, <<>>).

await_decoder(_Conn, Expected, Acc) when byte_size(Acc) >= byte_size(Expected) ->
    ?assertEqual(Expected, Acc),
    ok;
await_decoder(Conn, Expected, Acc) ->
    receive
        {quic_test_stream, Conn, ?DECODER_STREAM, Bin, false} ->
            await_decoder(Conn, Expected, <<Acc/binary, Bin/binary>>)
    after 5000 ->
        ct:fail({no_decoder_instruction, Expected, Acc})
    end.

await_close_code(Conn) ->
    receive
        {quic_test_closed, Conn, ErrorCode} -> ErrorCode
    after 5000 ->
        ct:fail(connection_not_closed)
    end.
