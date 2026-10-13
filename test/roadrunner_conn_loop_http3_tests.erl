-module(roadrunner_conn_loop_http3_tests).
-moduledoc """
Unit tests for the pure request-stream frame folding + frame-sequence
state machine in `roadrunner_conn_loop_http3` (the live connection
paths are covered end-to-end by `roadrunner_http3_SUITE`).

The connection-error codes asserted here are RFC 9114 §8.1 values:
`16#0105` = H3_FRAME_UNEXPECTED, `16#0106` = H3_FRAME_ERROR.
""".
-include_lib("eunit/include/eunit.hrl").

%% A single-handler listener: no route can raise a stream's body cap.
-define(HANDLER, #{dispatch => {handler, some_mod, fun some_mod:handle/1, undefined}}).

new(MaxLen) ->
    roadrunner_conn_loop_http3:new_request_stream(MaxLen).

decode(Buf, MaxLen) ->
    roadrunner_conn_loop_http3:decode_request_frames(Buf, new(MaxLen), ?HANDLER).

decode(Buf, MaxLen, MaxHdrBlock) ->
    roadrunner_conn_loop_http3:decode_request_frames(Buf, new(MaxLen), ?HANDLER, MaxHdrBlock).

%% A HEADERS frame wrapping an arbitrary field block (the block is only
%% QPACK-decoded later, in the conn loop's dispatch, not here). The native
%% encoders return iodata; these build on-wire frames (binary) fed to the
%% decoder, so flatten them.
hf(Block) -> iolist_to_binary(roadrunner_quic_h3_frame:encode_headers(Block)).
df(Bin) -> iolist_to_binary(roadrunner_quic_h3_frame:encode_data(Bin)).

new_request_stream_test() ->
    ?assertEqual(
        #{
            buf => <<>>,
            header_block => undefined,
            headers => undefined,
            body => [],
            body_len => 0,
            unreleased => 0,
            body_cap => 8,
            frame_state => expecting_headers
        },
        new(8)
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
    ?assertMatch(
        {conn_error, 16#0105, _},
        decode(iolist_to_binary(roadrunner_quic_h3_frame:encode_settings(#{})), 1000)
    ).

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
    Oversized = iolist_to_binary([
        roadrunner_quic_varint:encode(0), roadrunner_quic_varint:encode(16#FFFFFFFF)
    ]),
    ?assertMatch({conn_error, 16#0106, _}, decode(Oversized, 1000)).

oversized_header_block_test() ->
    %% A complete HEADERS frame whose field section exceeds MAX_HEADER_BLOCK
    %% (16384) is rejected; the conn loop answers 431.
    ?assertEqual(headers_too_large, decode(hf(binary:copy(<<"x">>, 16385)), 1000000)).

dribbled_header_block_test() ->
    %% A still-incomplete HEADERS frame already past the cap is rejected
    %% without buffering the rest (the dribble guard in the `{more}` branch).
    Frame = hf(binary:copy(<<"x">>, 20000)),
    Partial = binary:part(Frame, 0, 17000),
    ?assertEqual(headers_too_large, decode(Partial, 1000000)).

configured_max_header_block_complete_test() ->
    %% A complete 300-byte HEADERS block (well under the default 16384) is
    %% rejected when the configured `max_header_block` is 200, accepted at
    %% the default. Proves the configured cap, not the macro, is enforced.
    Block = binary:copy(<<"x">>, 300),
    ?assertEqual(headers_too_large, decode(hf(Block), 1000000, 200)),
    ?assertMatch({ok, _}, decode(hf(Block), 1000000, 16384)).

configured_max_header_block_dribbled_test() ->
    %% The `{more}` dribble guard also honors the configured cap: a partial
    %% HEADERS frame already past a 200-byte cap is rejected.
    Frame = hf(binary:copy(<<"x">>, 1000)),
    Partial = binary:part(Frame, 0, 400),
    ?assertEqual(headers_too_large, decode(Partial, 1000000, 200)).

%% --- a route's own body cap ---

%% A body past the listener's cap (8 here) asks its route, which may set a
%% larger one; `/up` sets 64, `/plain` none.
route_cap_test_() ->
    {setup,
        fun() ->
            persistent_term:put(
                {roadrunner_routes, h3_route_cap},
                roadrunner_router:compile(
                    [
                        #{path => ~"/up", handler => up, max_content_length => 64},
                        {~"/plain", plain}
                    ],
                    []
                )
            )
        end,
        fun(_) -> persistent_term:erase({roadrunner_routes, h3_route_cap}) end, [
            fun raises_to_route_cap/0,
            fun route_cap_still_too_small/0,
            fun route_without_cap/0,
            fun undecodable_block_on_raise/0,
            fun raises_with_decoded_headers/0
        ]}.

-define(ROUTER, #{dispatch => {router, h3_route_cap}}).

req_block(Path) ->
    iolist_to_binary(
        roadrunner_qpack:encode([
            {~":method", ~"POST"},
            {~":scheme", ~"https"},
            {~":authority", ~"x"},
            {~":path", Path}
        ])
    ).

raises_to_route_cap() ->
    %% HEADERS and the over-cap DATA in one chunk: the field section is
    %% decoded for the route and kept for dispatch.
    Buf = <<(hf(req_block(~"/up")))/binary, (df(binary:copy(~"x", 20)))/binary>>,
    {ok, Stream} = roadrunner_conn_loop_http3:decode_request_frames(Buf, new(8), ?ROUTER),
    ?assertMatch(#{body_len := 20, body_cap := 64, headers := [_ | _]}, Stream).

route_cap_still_too_small() ->
    Buf = <<(hf(req_block(~"/up")))/binary, (df(binary:copy(~"x", 65)))/binary>>,
    ?assertEqual(
        too_large, roadrunner_conn_loop_http3:decode_request_frames(Buf, new(8), ?ROUTER)
    ).

route_without_cap() ->
    Buf = <<(hf(req_block(~"/plain")))/binary, (df(binary:copy(~"x", 9)))/binary>>,
    ?assertEqual(
        too_large, roadrunner_conn_loop_http3:decode_request_frames(Buf, new(8), ?ROUTER)
    ).

undecodable_block_on_raise() ->
    %% The field section has to decode to be routed; one that does not is
    %% the connection error it would be at dispatch (H3_QPACK_DECOMPRESSION_FAILED).
    Buf = <<(hf(~"blk"))/binary, (df(binary:copy(~"x", 9)))/binary>>,
    ?assertMatch(
        {conn_error, 16#0200, _},
        roadrunner_conn_loop_http3:decode_request_frames(Buf, new(8), ?ROUTER)
    ).

raises_with_decoded_headers() ->
    %% Headers decoded earlier (on their own chunk) are used as they are: the
    %% raw block is not decoded again. Past the raised cap, the route is asked
    %% again and the body refused.
    Decoded = (new(8))#{
        header_block := ~"not qpack",
        headers := [{~":method", ~"POST"}, {~":path", ~"/up"}],
        frame_state := expecting_data
    },
    {ok, Raised} = roadrunner_conn_loop_http3:decode_request_frames(
        df(binary:copy(~"x", 60)), Decoded, ?ROUTER
    ),
    ?assertMatch(#{body_len := 60, body_cap := 64}, Raised),
    ?assertEqual(
        too_large,
        roadrunner_conn_loop_http3:decode_request_frames(df(~"12345"), Raised, ?ROUTER)
    ).
