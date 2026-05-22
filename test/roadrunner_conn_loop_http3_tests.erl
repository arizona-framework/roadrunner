-module(roadrunner_conn_loop_http3_tests).
-moduledoc """
Unit tests for the pure request-stream frame folding + frame-sequence
state machine in `roadrunner_conn_loop_http3` (the live connection
paths are covered end-to-end by `roadrunner_http3_SUITE`).

The connection-error codes asserted here are RFC 9114 §8.1 values:
`16#0105` = H3_FRAME_UNEXPECTED, `16#0106` = H3_FRAME_ERROR.
""".
-include_lib("eunit/include/eunit.hrl").

new() ->
    roadrunner_conn_loop_http3:new_request_stream().

decode(Buf, MaxLen) ->
    roadrunner_conn_loop_http3:decode_request_frames(Buf, new(), MaxLen).

%% A HEADERS frame wrapping an arbitrary field block (the block is only
%% QPACK-decoded later, in the conn loop's dispatch, not here).
hf(Block) -> quic_h3_frame:encode_headers(Block).
df(Bin) -> quic_h3_frame:encode_data(Bin).

new_request_stream_test() ->
    ?assertEqual(
        #{
            buf => <<>>,
            header_block => undefined,
            body => [],
            body_len => 0,
            frame_state => expecting_headers
        },
        new()
    ).

headers_first_test() ->
    {ok, Stream} = decode(hf(~"block"), 1000),
    ?assertEqual(~"block", maps:get(header_block, Stream)),
    ?assertEqual(expecting_data, maps:get(frame_state, Stream)).

headers_then_data_test() ->
    {ok, Stream} = decode(<<(hf(~"blk"))/binary, (df(~"hello"))/binary>>, 1000),
    ?assertEqual(~"blk", maps:get(header_block, Stream)),
    ?assertEqual(~"hello", iolist_to_binary(maps:get(body, Stream))),
    ?assertEqual(5, maps:get(body_len, Stream)).

data_before_headers_test() ->
    %% RFC 9114 §4.1: a DATA frame before any HEADERS → H3_FRAME_UNEXPECTED.
    ?assertMatch({conn_error, 16#0105, _}, decode(df(~"x"), 1000)).

body_too_large_test() ->
    Buf = <<(hf(~"blk"))/binary, (df(binary:copy(<<"x">>, 20)))/binary>>,
    ?assertEqual(too_large, decode(Buf, 8)).

trailers_accepted_test() ->
    %% HEADERS, DATA, then trailing HEADERS — trailers are accepted but
    %% not surfaced (header_block keeps the request headers).
    Buf = <<(hf(~"req"))/binary, (df(~"body"))/binary, (hf(~"trailer"))/binary>>,
    {ok, Stream} = decode(Buf, 1000),
    ?assertEqual(expecting_done, maps:get(frame_state, Stream)),
    ?assertEqual(~"req", maps:get(header_block, Stream)).

frame_after_trailers_test() ->
    %% A DATA frame after the trailing HEADERS → H3_FRAME_UNEXPECTED.
    Buf = <<(hf(~"req"))/binary, (hf(~"trailer"))/binary, (df(~"x"))/binary>>,
    ?assertMatch({conn_error, 16#0105, _}, decode(Buf, 1000)).

settings_on_request_stream_test() ->
    %% A control-stream-only frame on a request stream → H3_FRAME_UNEXPECTED.
    ?assertMatch({conn_error, 16#0105, _}, decode(quic_h3_frame:encode_settings(#{}), 1000)).

unknown_frame_ignored_test() ->
    %% Grease frame type 0x21 (empty payload) — ignored (RFC 9114 §9).
    {ok, Stream} = decode(<<16#21, 0>>, 1000),
    ?assertEqual(expecting_headers, maps:get(frame_state, Stream)).

partial_frame_buffered_test() ->
    {ok, Stream} = decode(<<1>>, 1000),
    ?assertEqual(<<1>>, maps:get(buf, Stream)).

h2_reserved_frame_test() ->
    %% Frame type 0x02 is HTTP/2-reserved → H3_FRAME_UNEXPECTED (§7.2.8).
    ?assertMatch({conn_error, 16#0105, _}, decode(<<2, 0>>, 1000)).

oversized_frame_test() ->
    %% A frame declaring a length above the cap → H3_FRAME_ERROR (§7.1).
    Oversized = iolist_to_binary([quic_varint:encode(0), quic_varint:encode(16#FFFFFFFF)]),
    ?assertMatch({conn_error, 16#0106, _}, decode(Oversized, 1000)).
