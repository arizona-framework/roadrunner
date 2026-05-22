-module(roadrunner_conn_loop_http3_tests).
-moduledoc """
Unit tests for the pure request-stream frame folding in
`roadrunner_conn_loop_http3` (the live connection paths are covered
end-to-end by `roadrunner_http3_SUITE`).
""".
-include_lib("eunit/include/eunit.hrl").

new() ->
    roadrunner_conn_loop_http3:new_request_stream().

decode(Buf, MaxLen) ->
    roadrunner_conn_loop_http3:decode_request_frames(Buf, new(), MaxLen).

new_request_stream_test() ->
    ?assertEqual(
        #{buf => <<>>, header_block => undefined, body => [], body_len => 0, worker => undefined},
        new()
    ).

headers_frame_test() ->
    {ok, Stream} = decode(quic_h3_frame:encode_headers(~"qpack-block"), 1000),
    ?assertEqual(~"qpack-block", maps:get(header_block, Stream)).

data_frame_test() ->
    {ok, Stream} = decode(quic_h3_frame:encode_data(~"hello"), 1000),
    ?assertEqual(~"hello", iolist_to_binary(maps:get(body, Stream))),
    ?assertEqual(5, maps:get(body_len, Stream)).

headers_then_data_test() ->
    Buf = <<
        (quic_h3_frame:encode_headers(~"hb"))/binary,
        (quic_h3_frame:encode_data(~"xy"))/binary
    >>,
    {ok, Stream} = decode(Buf, 1000),
    ?assertEqual(~"hb", maps:get(header_block, Stream)),
    ?assertEqual(~"xy", iolist_to_binary(maps:get(body, Stream))).

body_too_large_test() ->
    ?assertEqual(too_large, decode(quic_h3_frame:encode_data(binary:copy(<<"x">>, 20)), 8)).

ignored_frame_test() ->
    %% A SETTINGS frame on a request stream is neither HEADERS nor DATA,
    %% so it's skipped without affecting the accumulated request.
    {ok, Stream} = decode(quic_h3_frame:encode_settings(#{}), 1000),
    ?assertEqual(undefined, maps:get(header_block, Stream)).

partial_frame_buffered_test() ->
    %% Incomplete frame header → buffered for the next stream_data.
    {ok, Stream} = decode(<<1>>, 1000),
    ?assertEqual(<<1>>, maps:get(buf, Stream)).

malformed_frame_test() ->
    %% Frame type 0x02 is an HTTP/2-reserved type — a frame error.
    ?assertEqual(error, decode(<<2, 0>>, 1000)).

set_header_block_first_test() ->
    Stream = roadrunner_conn_loop_http3:set_header_block(new(), ~"first"),
    ?assertEqual(~"first", maps:get(header_block, Stream)).

set_header_block_trailers_ignored_test() ->
    Stream = (new())#{header_block := ~"first"},
    %% A second HEADERS block (trailers) leaves the request headers intact.
    ?assertEqual(Stream, roadrunner_conn_loop_http3:set_header_block(Stream, ~"second")).
