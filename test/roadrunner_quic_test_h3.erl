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
%%
%% Both a synchronous surface (get/post/request, which return the whole
%% response) and the dep-shaped split surface (open_request -> stream id,
%% send_data, collect) are offered, so a test can interleave work between the
%% request and the response.

-export([connect/2, close/1]).
-export([get/2, post/3, request/3]).
-export([open_request/2, open_request/3, send_data/4, collect/2, cancel/2, get_peer_settings/1]).

-define(COLLECT_TIMEOUT, 5000).
%% RFC 9114 §8.1 H3_REQUEST_CANCELLED.
-define(H3_REQUEST_CANCELLED, 16#010C).

%% =============================================================================
%% Connection
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

%% =============================================================================
%% Requests
%% =============================================================================

-doc "Issue a GET and collect the response as `{Status, Headers, Body}`.".
-spec get(pid(), binary()) -> response() | timeout | {error, term()}.
get(Conn, Path) ->
    request(Conn, headers(~"GET", Path), <<>>).

-doc "Issue a POST with `Body` and collect the response as `{Status, Headers, Body}`.".
-spec post(pid(), binary(), binary()) -> response() | timeout | {error, term()}.
post(Conn, Path, Body) ->
    request(Conn, headers(~"POST", Path), Body).

-doc """
Issue a request with the given full header list (pseudo-headers included)
and body, collecting the response. An empty body finishes the stream on the
HEADERS frame; a non-empty body finishes on the trailing DATA.
""".
-spec request(pid(), headers(), binary()) -> response() | timeout | {error, term()}.
request(Conn, Headers, <<>>) ->
    {ok, StreamId} = open_request(Conn, Headers),
    collect(Conn, StreamId);
request(Conn, Headers, Body) ->
    {ok, StreamId} = open_request(Conn, Headers, false),
    ok = send_data(Conn, StreamId, Body, true),
    collect(Conn, StreamId).

-doc "Open a request stream and send its HEADERS, finishing the stream.".
-spec open_request(pid(), headers()) -> {ok, non_neg_integer()}.
open_request(Conn, Headers) ->
    open_request(Conn, Headers, true).

-doc "Open a request stream and send its HEADERS, finishing the stream when `EndStream`.".
-spec open_request(pid(), headers(), boolean()) -> {ok, non_neg_integer()}.
open_request(Conn, Headers, EndStream) ->
    StreamId = roadrunner_quic_test_conn:open_bidi(Conn),
    Frame = roadrunner_quic_h3_frame:encode_headers(roadrunner_qpack:encode(Headers)),
    ok = roadrunner_quic_test_conn:send(Conn, StreamId, iolist_to_binary(Frame), EndStream),
    {ok, StreamId}.

-doc "Send a DATA frame on a request stream, with the FIN bit when `Fin`.".
-spec send_data(pid(), non_neg_integer(), binary(), boolean()) -> ok.
send_data(Conn, StreamId, Data, Fin) ->
    Frame = roadrunner_quic_h3_frame:encode_data(Data),
    roadrunner_quic_test_conn:send(Conn, StreamId, iolist_to_binary(Frame), Fin).

-doc "Cancel a request: RESET_STREAM + STOP_SENDING with H3_REQUEST_CANCELLED.".
-spec cancel(pid(), non_neg_integer()) -> ok.
cancel(Conn, StreamId) ->
    ok = roadrunner_quic_test_conn:reset_stream(Conn, StreamId, ?H3_REQUEST_CANCELLED),
    ok = roadrunner_quic_test_conn:stop_sending(Conn, StreamId, ?H3_REQUEST_CANCELLED).

-doc """
Collect the response on `StreamId`: accumulate its bytes until FIN, then
decode the h3 response. Returns `{error, {stream_reset, Code}}` if the server
resets the stream. Stream data for other streams stays in the mailbox.
""".
-spec collect(pid(), non_neg_integer()) -> response() | timeout | {error, term()}.
collect(Conn, StreamId) ->
    collect(Conn, StreamId, <<>>).

%% =============================================================================
%% Peer settings
%% =============================================================================

-doc """
Read the server's SETTINGS off its control stream (the server unidirectional
stream whose type prefix is `control`), returning the decoded settings map.
""".
-spec get_peer_settings(pid()) -> map().
get_peer_settings(Conn) ->
    receive
        {quic_test_stream, Conn, StreamId, Data, _Fin} when StreamId rem 4 =:= 3 ->
            case control_settings(Data) of
                {ok, Settings} -> Settings;
                more -> get_peer_settings(Conn)
            end
    after ?COLLECT_TIMEOUT ->
        #{}
    end.

%% =============================================================================
%% Internal
%% =============================================================================

-type headers() :: [{binary(), binary()}].
-type response() :: {non_neg_integer(), headers(), binary()}.

-spec collect(pid(), non_neg_integer(), binary()) -> response() | timeout | {error, term()}.
collect(Conn, StreamId, Acc) ->
    receive
        {quic_test_stream, Conn, StreamId, Data, true} ->
            decode_response(<<Acc/binary, Data/binary>>);
        {quic_test_stream, Conn, StreamId, Data, false} ->
            collect(Conn, StreamId, <<Acc/binary, Data/binary>>);
        {quic_test_stream_reset, Conn, StreamId, ErrorCode} ->
            {error, {stream_reset, ErrorCode}}
    after ?COLLECT_TIMEOUT ->
        timeout
    end.

-spec decode_response(binary()) -> response().
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

-spec status(headers()) -> non_neg_integer().
status(Headers) ->
    {~":status", Value} = lists:keyfind(~":status", 1, Headers),
    binary_to_integer(Value).

%% The SETTINGS map from a control stream's bytes (its `control` type prefix
%% then a SETTINGS frame), or `more` when the bytes are not the control stream.
-spec control_settings(binary()) -> {ok, map()} | more.
control_settings(Data) ->
    case roadrunner_quic_h3_frame:decode_stream_type(Data) of
        {ok, control, Rest} ->
            case roadrunner_quic_h3_frame:decode(Rest) of
                {ok, {settings, Settings}, _} -> {ok, Settings};
                _ -> more
            end;
        _ ->
            more
    end.

%% The control stream-type prefix followed by a SETTINGS frame (RFC 9114
%% §6.2.1 / §7.2.4); static-table-only QPACK advertises a zero table capacity.
-spec control_with_settings() -> binary().
control_with_settings() ->
    iolist_to_binary([
        roadrunner_quic_h3_frame:encode_stream_type(control),
        roadrunner_quic_h3_frame:encode_settings(#{qpack_max_table_capacity => 0})
    ]).

-spec headers(binary(), binary()) -> headers().
headers(Method, Path) ->
    [
        {~":method", Method},
        {~":scheme", ~"https"},
        {~":authority", ~"localhost"},
        {~":path", Path}
    ].
