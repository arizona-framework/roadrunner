-module(roadrunner_quic_test_h3).
-moduledoc false.

%% In-test native HTTP/3 client over roadrunner_quic_test_conn: opens the
%% client control stream and sends SETTINGS (RFC 9114 §6.2.1), then issues
%% requests on client-initiated bidirectional streams (QPACK-encoded HEADERS
%% plus optional DATA) and collects the response. The h3 framing is the
%% production roadrunner_quic_h3_frame + roadrunner_qpack (static table only,
%% both directions). The connection delivers received stream data to this
%% module's caller (the connection owner), so connect/2 and the request calls
%% run in the same process.

-export([connect/2, close/1, get/2, post/3]).

-define(COLLECT_TIMEOUT, 5000).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Connect to the native HTTP/3 server and set up the client control stream
with a SETTINGS frame. Returns the underlying connection handle.
""".
-spec connect(inet:ip_address() | inet:hostname(), inet:port_number()) ->
    {ok, pid()} | {error, term()}.
connect(Host, Port) ->
    case roadrunner_quic_test_conn:connect(Host, Port) of
        {ok, Conn} ->
            Control = roadrunner_quic_test_conn:open_uni(Conn),
            ok = roadrunner_quic_test_conn:send(Conn, Control, control_with_settings(), false),
            {ok, Conn};
        {error, _} = Error ->
            Error
    end.

-doc "Close the connection.".
-spec close(pid()) -> ok.
close(Conn) ->
    roadrunner_quic_test_conn:close(Conn).

-doc "Issue a GET and collect the response as `{Status, Headers, Body}`.".
-spec get(pid(), binary()) -> {non_neg_integer(), [{binary(), binary()}], binary()} | timeout.
get(Conn, Path) ->
    StreamId = roadrunner_quic_test_conn:open_bidi(Conn),
    send_headers(Conn, StreamId, headers(~"GET", Path), true),
    collect(Conn, StreamId, <<>>).

-doc "Issue a POST with `Body` and collect the response as `{Status, Headers, Body}`.".
-spec post(pid(), binary(), binary()) ->
    {non_neg_integer(), [{binary(), binary()}], binary()} | timeout.
post(Conn, Path, Body) ->
    StreamId = roadrunner_quic_test_conn:open_bidi(Conn),
    send_headers(Conn, StreamId, headers(~"POST", Path), false),
    DataFrame = roadrunner_quic_h3_frame:encode_data(Body),
    ok = roadrunner_quic_test_conn:send(Conn, StreamId, iolist_to_binary(DataFrame), true),
    collect(Conn, StreamId, <<>>).

%% =============================================================================
%% Internal
%% =============================================================================

-spec send_headers(pid(), non_neg_integer(), [{binary(), binary()}], boolean()) -> ok.
send_headers(Conn, StreamId, Headers, Fin) ->
    Frame = roadrunner_quic_h3_frame:encode_headers(roadrunner_qpack:encode(Headers)),
    ok = roadrunner_quic_test_conn:send(Conn, StreamId, iolist_to_binary(Frame), Fin).

%% Accumulate the request stream's bytes until its FIN, then decode the h3
%% response. Stream data for other streams (the server's control / QPACK
%% streams) is left in the mailbox.
-spec collect(pid(), non_neg_integer(), binary()) ->
    {non_neg_integer(), [{binary(), binary()}], binary()} | timeout.
collect(Conn, StreamId, Acc) ->
    receive
        {quic_test_stream, Conn, StreamId, Data, true} ->
            decode_response(<<Acc/binary, Data/binary>>);
        {quic_test_stream, Conn, StreamId, Data, false} ->
            collect(Conn, StreamId, <<Acc/binary, Data/binary>>)
    after ?COLLECT_TIMEOUT ->
        timeout
    end.

-spec decode_response(binary()) -> {non_neg_integer(), [{binary(), binary()}], binary()}.
decode_response(Bytes) ->
    Frames = decode_frames(Bytes),
    {ok, Headers} = roadrunner_qpack:decode(first_headers_block(Frames)),
    {status(Headers), Headers, response_body(Frames)}.

-spec decode_frames(binary()) -> [tuple()].
decode_frames(<<>>) ->
    [];
decode_frames(Bytes) ->
    {ok, Frame, Rest} = roadrunner_quic_h3_frame:decode(Bytes),
    [Frame | decode_frames(Rest)].

-spec first_headers_block([tuple()]) -> binary().
first_headers_block([{headers, Block} | _]) -> Block;
first_headers_block([_ | Rest]) -> first_headers_block(Rest).

-spec response_body([tuple()]) -> binary().
response_body(Frames) ->
    iolist_to_binary([Data || {data, Data} <- Frames]).

-spec status([{binary(), binary()}]) -> non_neg_integer().
status(Headers) ->
    {~":status", Value} = lists:keyfind(~":status", 1, Headers),
    binary_to_integer(Value).

%% The control stream-type prefix followed by a SETTINGS frame (RFC 9114
%% §6.2.1 / §7.2.4); static-table-only QPACK advertises a zero table capacity.
-spec control_with_settings() -> binary().
control_with_settings() ->
    iolist_to_binary([
        roadrunner_quic_h3_frame:encode_stream_type(control),
        roadrunner_quic_h3_frame:encode_settings(#{qpack_max_table_capacity => 0})
    ]).

-spec headers(binary(), binary()) -> [{binary(), binary()}].
headers(Method, Path) ->
    [
        {~":method", Method},
        {~":scheme", ~"https"},
        {~":authority", ~"localhost"},
        {~":path", Path}
    ].
