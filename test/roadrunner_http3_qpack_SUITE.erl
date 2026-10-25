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

%% The server's unidirectional streams are its control stream (id 3),
%% opened at the handshake, then its QPACK decoder stream (id 7), opened
%% with the first instruction it sends.
-define(DECODER_STREAM, 7).

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
    {ok, _} = roadrunner_listener:start_link(Name, #{
        port => 0,
        protocols => [{http3, http3_opts(Case)}],
        tls => roadrunner_test_certs:server_opts(),
        routes => roadrunner_h3_test_handler,
        max_content_length => 64
    }),
    [{listener, Name}, {port, roadrunner_listener:port(Name)} | Config].

http3_opts(dynamic_table_off) -> #{qpack_max_table_capacity => 0};
http3_opts(_Case) -> #{}.

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
    %% RFC 9204 §5: a 4096-byte dynamic table by default, and no blocked
    %% streams.
    Conn = connect(Config),
    ?assertMatch(
        #{qpack_max_table_capacity := 4096, qpack_blocked_streams := 0},
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
    %% would block, which no blocked streams allows (RFC 9204 §2.1.2).
    Conn = connect(Config),
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

%% --- helpers ---

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
