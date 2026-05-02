-module(roadrunner_http1_props).
-moduledoc """
Property-based tests for `roadrunner_http1`'s incremental parsers.

The headline property is **incremental-feed equivalence**: parsing a
full request buffer in one shot and parsing it byte-by-byte must
yield the same result. This catches state-leak bugs in the
incremental path that example-based tests rarely surface.

Additional properties cover **robustness**: every parser must
return one of its documented shapes (`{ok, _}`, `{more, _}`, or
`{error, _}`) for any binary input — never crash.
""".

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct_property_test.hrl").

%% =============================================================================
%% Robustness: parsers never crash, only return their declared shapes.
%% =============================================================================

prop_parse_request_line_never_crashes() ->
    ?FORALL(B, binary(), is_documented_shape(roadrunner_http1:parse_request_line(B))).

prop_parse_header_never_crashes() ->
    ?FORALL(B, binary(), is_documented_shape(roadrunner_http1:parse_header(B))).

prop_parse_headers_never_crashes() ->
    ?FORALL(B, binary(), is_documented_shape(roadrunner_http1:parse_headers(B))).

prop_parse_request_never_crashes() ->
    ?FORALL(B, binary(), is_documented_shape(roadrunner_http1:parse_request(B))).

prop_parse_chunk_never_crashes() ->
    ?FORALL(B, binary(), is_documented_shape(roadrunner_http1:parse_chunk(B))).

is_documented_shape({ok, _}) -> true;
is_documented_shape({ok, _, _}) -> true;
is_documented_shape({ok, _, _, _}) -> true;
is_documented_shape({ok, _, _, _, _}) -> true;
is_documented_shape({more, _}) -> true;
is_documented_shape({error, _}) -> true;
is_documented_shape(end_of_headers) -> true;
is_documented_shape(_) -> false.

%% =============================================================================
%% Incremental-feed equivalence — the full point of the parsers being
%% incremental: a complete buffer or one-byte-at-a-time must reach the
%% same conclusion.
%% =============================================================================

prop_parse_request_line_incremental() ->
    ?FORALL(
        Bytes,
        request_line_bytes(),
        roadrunner_http1:parse_request_line(Bytes) =:= feed(parse_request_line, Bytes)
    ).

prop_parse_request_incremental() ->
    ?FORALL(
        Bytes,
        full_request_bytes(),
        roadrunner_http1:parse_request(Bytes) =:= feed(parse_request, Bytes)
    ).

%% A single chunk plus the size-0 terminator, fed all at once vs.
%% byte-by-byte, must reach the same `{ok, last, _, _}` result.
prop_parse_chunk_incremental() ->
    ?FORALL(
        Bytes,
        chunked_body_bytes(),
        roadrunner_http1:parse_chunk(Bytes) =:= feed(parse_chunk, Bytes)
    ).

%% Drive the parser one byte at a time, accumulating into Buf, until
%% it returns a non-`{more, _}` result.
feed(Fn, Bytes) ->
    feed(Fn, Bytes, <<>>).

feed(Fn, <<>>, Buf) ->
    roadrunner_http1:Fn(Buf);
feed(Fn, <<C, Rest/binary>>, Buf) ->
    NewBuf = <<Buf/binary, C>>,
    case roadrunner_http1:Fn(NewBuf) of
        {more, _} -> feed(Fn, Rest, NewBuf);
        Result -> Result
    end.

%% =============================================================================
%% Generators
%% =============================================================================

request_line_bytes() ->
    ?LET(
        {Method, Target},
        {method(), target()},
        iolist_to_binary([Method, " ", Target, " HTTP/1.1\r\n"])
    ).

full_request_bytes() ->
    ?LET(
        {Method, Target, Headers},
        {method(), target(), header_block()},
        iolist_to_binary([
            Method,
            " ",
            Target,
            " HTTP/1.1\r\n",
            [[N, ": ", V, "\r\n"] || {N, V} <- Headers],
            "\r\n"
        ])
    ).

method() ->
    oneof([
        <<"GET">>,
        <<"POST">>,
        <<"PUT">>,
        <<"HEAD">>,
        <<"DELETE">>,
        <<"PATCH">>,
        <<"OPTIONS">>
    ]).

target() ->
    ?LET(
        Segments,
        list(non_empty(list(oneof([$a, $b, $c, $d, $-, $_, $.])))),
        iolist_to_binary([[$/ | Seg] || Seg <- Segments] ++ [$/])
    ).

header_block() ->
    list({header_name(), header_value()}).

header_name() ->
    ?LET(
        L,
        non_empty(list(oneof([$a, $b, $c, $d, $e, $f, $-]))),
        iolist_to_binary(L)
    ).

header_value() ->
    ?LET(
        L,
        list(oneof([$a, $b, $c, $d, $e, $\s])),
        iolist_to_binary(L)
    ).

%% A single complete chunk — no terminator. The incremental feed
%% stops at the first `{ok, _, _}` return so we generate exactly the
%% bytes for one chunk and compare against the full-buffer parse.
chunked_body_bytes() ->
    ?LET(
        Payload,
        binary(),
        iolist_to_binary([
            integer_to_binary(byte_size(Payload), 16),
            ~"\r\n",
            Payload,
            ~"\r\n"
        ])
    ).
