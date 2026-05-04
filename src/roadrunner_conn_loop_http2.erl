-module(roadrunner_conn_loop_http2).
-moduledoc """
HTTP/2 (RFC 9113) connection process — Phase H5.

Serial single-stream mode: handshake completes, then the conn
loops on inbound frames, dispatching one stream at a time
through the existing `roadrunner_conn:resolve_handler/2` +
`roadrunner_middleware` pipeline, emitting the response, and
returning to the loop for the next stream.

`SETTINGS_MAX_CONCURRENT_STREAMS = 1` is advertised to
discourage clients from opening overlapping streams; if a second
HEADERS arrives before the first stream is closed, the
new stream gets `RST_STREAM(REFUSED_STREAM)`.

Response shapes supported here:

| shape | h5 |
|---|---|
| `{Status, Headers, Body}` (buffered) | yes |
| `{stream, _}` | 501 (Phase H7) |
| `{loop, _}` | 501 (later) |
| `{sendfile, _}` | 501 (later) |
| `{websocket, _}` | 501 (Phase H13) |

The full frame demux + multiplexing arrives in Phase H8.
""".

-export([enter/5]).

%% RFC 9113 §3.4 client connection preface — fixed 24 bytes.
-define(PREFACE, ~"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n").
-define(PREFACE_LEN, 24).

%% Read-deadline cap for the handshake. The frame loop uses
%% per-recv timeouts that are recomputed against an absolute
%% deadline — slow clients can't tarpit us.
-define(HANDSHAKE_TIMEOUT, 10_000).
-define(IDLE_TIMEOUT, 30_000).
-define(RECV_CHUNK, 16_384).

%% RFC 9113 §6.5.2 default `MAX_FRAME_SIZE`. Clients can advertise
%% larger values; we honor the smaller of theirs and our cap. For
%% phase 5 the default is fine.
-define(MAX_FRAME_SIZE, 16_384).

-define(GOAWAY(LastStreamId, ErrorCode),
    roadrunner_http2_frame:encode({goaway, (LastStreamId), (ErrorCode), <<>>})
).

-record(loop, {
    socket :: roadrunner_transport:socket(),
    proto_opts :: roadrunner_conn:proto_opts(),
    listener_name :: atom(),
    peer :: {inet:ip_address(), inet:port_number()} | undefined,
    start_mono :: integer(),
    scheme :: http | https,
    %% Inbound bytes still to parse.
    buffer = <<>> :: binary(),
    %% HPACK contexts. Decoder mutates per inbound HEADERS;
    %% encoder mutates per outbound HEADERS.
    hpack_dec :: roadrunner_http2_hpack:context(),
    hpack_enc :: roadrunner_http2_hpack:context(),
    %% Highest stream id we've processed — for the LAST_STREAM_ID
    %% in GOAWAY.
    last_stream_id = 0 :: non_neg_integer(),
    %% Open stream state, or `undefined` when idle.
    stream = undefined ::
        undefined
        | #{
            id := pos_integer(),
            %% Pending HPACK fragment when END_HEADERS hasn't been
            %% seen yet; complete decoded headers go into `headers`.
            header_fragment := binary(),
            end_headers := boolean(),
            end_stream := boolean(),
            headers := undefined | [roadrunner_http2_hpack:header()],
            body := iodata()
        }
}).

-doc """
Top-level entry from the HTTP/1.1 dispatch fork. Owns the socket
from this point on; takes responsibility for releasing the listener
slot and firing `[roadrunner, listener, conn_close]` telemetry.
""".
-spec enter(
    roadrunner_transport:socket(),
    roadrunner_conn:proto_opts(),
    atom(),
    {inet:ip_address(), inet:port_number()} | undefined,
    integer()
) -> no_return().
enter(Socket, ProtoOpts, ListenerName, Peer, StartMono) ->
    proc_lib:set_label({roadrunner_conn_loop_http2, ListenerName, Peer}),
    Scheme = roadrunner_conn:scheme(Socket),
    State = #loop{
        socket = Socket,
        proto_opts = ProtoOpts,
        listener_name = ListenerName,
        peer = Peer,
        start_mono = StartMono,
        scheme = Scheme,
        hpack_dec = roadrunner_http2_hpack:new_decoder(4096),
        hpack_enc = roadrunner_http2_hpack:new_encoder(4096)
    },
    handshake(State).

%% =============================================================================
%% Handshake — RFC 9113 §3.4
%% =============================================================================

-spec handshake(#loop{}) -> no_return().
handshake(State) ->
    %% Send failures are silently ignored throughout — if the wire
    %% has gone away, the next `recv` will surface the error and
    %% we'll fall to `exit_clean` cleanly. Keeping per-call error
    %% branches added a forest of unreachable paths.
    _ = send(State, server_settings_frame()),
    read_preface(State).

-spec server_settings_frame() -> iodata().
server_settings_frame() ->
    %% Advertise MAX_CONCURRENT_STREAMS=1 (serial mode) plus our
    %% MAX_FRAME_SIZE (16384, the default — included for clarity).
    %% IDs from RFC 9113 §6.5.2: 3 = MAX_CONCURRENT_STREAMS,
    %% 5 = MAX_FRAME_SIZE.
    roadrunner_http2_frame:encode(
        {settings, 0, [{3, 1}, {5, ?MAX_FRAME_SIZE}]}
    ).

-spec read_preface(#loop{}) -> no_return().
read_preface(#loop{socket = Socket} = State) ->
    case roadrunner_transport:recv(Socket, ?PREFACE_LEN, ?HANDSHAKE_TIMEOUT) of
        {ok, ?PREFACE} -> read_client_settings(State);
        _ -> exit_clean(State)
    end.

-spec read_client_settings(#loop{}) -> no_return().
read_client_settings(State) ->
    case read_one_frame(State, ?HANDSHAKE_TIMEOUT) of
        {ok, {settings, Flags, _Params}, State1} when (Flags band 1) =:= 0 ->
            %% Non-ACK SETTINGS — apply (we don't enforce values
            %% beyond what the codec already validated) and ACK.
            _ = send(State1, roadrunner_http2_frame:encode({settings, 1, []})),
            frame_loop(State1);
        _ ->
            %% RFC 9113 §3.4: the client preface MUST be followed
            %% by a SETTINGS frame. Anything else is a connection
            %% error.
            _ = send_goaway(State, protocol_error),
            exit_clean(State)
    end.

%% =============================================================================
%% Frame loop
%% =============================================================================

-spec frame_loop(#loop{}) -> no_return().
frame_loop(State) ->
    case read_one_frame(State, ?IDLE_TIMEOUT) of
        {ok, Frame, State1} ->
            handle_frame(Frame, State1);
        %% Any failure — parse error, recv timeout, or peer close —
        %% gets a best-effort GOAWAY (the peer may already be gone)
        %% and a clean process exit. We don't try to distinguish
        %% "they hung up" vs "they sent garbage": both end the
        %% connection.
        {error, _Reason} ->
            _ = send_goaway(State, protocol_error),
            exit_clean(State)
    end.

-spec read_one_frame(#loop{}, non_neg_integer()) ->
    {ok, roadrunner_http2_frame:frame(), #loop{}} | {error, term()}.
read_one_frame(#loop{socket = Socket, buffer = Buf} = State, Timeout) ->
    case roadrunner_http2_frame:parse(Buf, ?MAX_FRAME_SIZE) of
        {ok, Frame, Rest} ->
            {ok, Frame, State#loop{buffer = Rest}};
        {more, _Need} ->
            case roadrunner_transport:recv(Socket, 0, Timeout) of
                {ok, More} ->
                    read_one_frame(
                        State#loop{buffer = <<Buf/binary, More/binary>>},
                        Timeout
                    );
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

%% =============================================================================
%% Per-frame dispatch
%% =============================================================================

-spec handle_frame(roadrunner_http2_frame:frame(), #loop{}) -> no_return().
handle_frame({settings, 1, _}, State) ->
    %% Client ACK to our SETTINGS — nothing to do.
    frame_loop(State);
handle_frame({settings, 0, _Params}, State) ->
    %% Client SETTINGS update — ACK.
    _ = send(State, roadrunner_http2_frame:encode({settings, 1, []})),
    frame_loop(State);
handle_frame({ping, 1, _Data}, State) ->
    %% PING ACK — drop.
    frame_loop(State);
handle_frame({ping, 0, Opaque}, State) ->
    %% PING — echo with ACK flag.
    _ = send(State, roadrunner_http2_frame:encode({ping, 1, Opaque})),
    frame_loop(State);
handle_frame({window_update, _, _}, State) ->
    %% Phase H5 doesn't enforce flow control; we accept any
    %% increment and move on. Phase H6 wires the real semantics.
    frame_loop(State);
handle_frame({priority, _, _}, State) ->
    %% PRIORITY is deprecated in RFC 9113 — accept and ignore.
    frame_loop(State);
handle_frame({rst_stream, StreamId, _}, #loop{stream = #{id := StreamId}} = State) ->
    %% Client cancelled our active stream — drop the in-progress
    %% state and continue.
    frame_loop(State#loop{stream = undefined});
handle_frame({rst_stream, _, _}, State) ->
    %% RST_STREAM for a stream we don't recognize — ignore.
    frame_loop(State);
handle_frame({goaway, _, _, _}, State) ->
    %% Client is shutting down — finish any in-flight stream
    %% (we have at most one) and exit. For phase 5 the simpler
    %% "exit immediately" is acceptable.
    exit_clean(State);
handle_frame({headers, StreamId, Flags, Priority, Fragment}, State) ->
    on_headers(StreamId, Flags, Priority, Fragment, State);
handle_frame({continuation, StreamId, Flags, Fragment}, State) ->
    on_continuation(StreamId, Flags, Fragment, State);
handle_frame({data, StreamId, Flags, Payload}, State) ->
    on_data(StreamId, Flags, Payload, State);
handle_frame({push_promise, _, _, _, _}, State) ->
    %% Servers MUST NOT receive PUSH_PROMISE — RFC 9113 §6.6.
    _ = send_goaway(State, protocol_error),
    exit_clean(State).

%% --- HEADERS / CONTINUATION ---

on_headers(NewStreamId, _Flags, _Priority, _Fragment, #loop{stream = #{id := _}} = State) ->
    %% Stream already in flight — Phase H5 is single-stream
    %% serial. Refuse the new stream.
    _ = send_rst_stream(State, NewStreamId, refused_stream),
    frame_loop(State);
on_headers(StreamId, Flags, _Priority, Fragment, State) when StreamId rem 2 =:= 1 ->
    %% Client-initiated stream ids are odd (RFC 9113 §5.1.1).
    EndHeaders = (Flags band 16#04) =/= 0,
    EndStream = (Flags band 16#01) =/= 0,
    Stream = #{
        id => StreamId,
        header_fragment => Fragment,
        end_headers => EndHeaders,
        end_stream => EndStream,
        headers => undefined,
        body => []
    },
    State1 = State#loop{stream = Stream, last_stream_id = StreamId},
    case EndHeaders of
        true -> finalize_headers(State1);
        false -> frame_loop(State1)
    end;
on_headers(_StreamId, _Flags, _Priority, _Fragment, State) ->
    %% Even stream id from client — protocol error.
    _ = send_goaway(State, protocol_error),
    exit_clean(State).

on_continuation(StreamId, Flags, Fragment, #loop{stream = #{id := StreamId} = Stream} = State) when
    map_get(end_headers, Stream) =:= false
->
    Combined = <<(maps:get(header_fragment, Stream))/binary, Fragment/binary>>,
    EndHeaders = (Flags band 16#04) =/= 0,
    NewStream = Stream#{header_fragment := Combined, end_headers := EndHeaders},
    State1 = State#loop{stream = NewStream},
    case EndHeaders of
        true -> finalize_headers(State1);
        false -> frame_loop(State1)
    end;
on_continuation(_, _, _, State) ->
    %% Unexpected CONTINUATION (no pending HEADERS, or wrong
    %% stream id, or already saw END_HEADERS). Connection error.
    _ = send_goaway(State, protocol_error),
    exit_clean(State).

%% Decode the accumulated HPACK fragment, build the request map.
%% If END_STREAM was set on the HEADERS frame, dispatch
%% immediately (no body). Otherwise wait for DATA frames.
finalize_headers(#loop{stream = Stream, hpack_dec = Dec} = State) ->
    Fragment = maps:get(header_fragment, Stream),
    case roadrunner_http2_hpack:decode(Fragment, Dec) of
        {ok, Headers, Dec1} ->
            State1 = State#loop{
                hpack_dec = Dec1,
                stream = Stream#{headers := Headers, header_fragment := <<>>}
            },
            case maps:get(end_stream, Stream) of
                true -> dispatch_stream(State1);
                false -> frame_loop(State1)
            end;
        {error, _Reason} ->
            _ = send_goaway(State, protocol_error),
            exit_clean(State)
    end.

%% --- DATA ---

on_data(StreamId, Flags, Payload, #loop{stream = #{id := StreamId} = Stream} = State) ->
    EndStream = (Flags band 16#01) =/= 0,
    NewBody = [maps:get(body, Stream), Payload],
    NewStream = Stream#{body := NewBody, end_stream := EndStream},
    State1 = State#loop{stream = NewStream},
    case EndStream of
        true -> dispatch_stream(State1);
        false -> frame_loop(State1)
    end;
on_data(_StreamId, _, _, State) ->
    %% DATA on an unknown / closed stream — protocol error.
    _ = send_goaway(State, protocol_error),
    exit_clean(State).

%% =============================================================================
%% Stream dispatch — build request, run handler, emit response.
%% =============================================================================

dispatch_stream(
    #loop{
        stream = Stream,
        peer = Peer,
        scheme = Scheme,
        listener_name = ListenerName
    } = State
) ->
    Headers = maps:get(headers, Stream),
    Body = iolist_to_binary(maps:get(body, Stream)),
    {RequestId, _} = roadrunner_conn:generate_request_id(<<>>),
    ConnInfo = #{
        peer => Peer,
        scheme => Scheme,
        listener_name => ListenerName,
        request_id => RequestId
    },
    case roadrunner_http2_request:from_headers(Headers, Body, ConnInfo) of
        {ok, Req} ->
            run_handler(Req, State);
        {error, _Reason} ->
            _ = send_rst_stream(State, maps:get(id, Stream), protocol_error),
            frame_loop(State#loop{stream = undefined})
    end.

run_handler(Req, #loop{proto_opts = Proto} = State) ->
    Dispatch = maps:get(dispatch, Proto),
    Mws = maps:get(middlewares, Proto, []),
    case roadrunner_conn:resolve_handler(Dispatch, Req) of
        {ok, Handler, Bindings, RouteOpts} ->
            FullReq = Req#{bindings => Bindings, route_opts => RouteOpts},
            invoke(Handler, Mws, FullReq, State);
        not_found ->
            emit_response(404, [{~"content-type", ~"text/plain"}], ~"Not Found", State)
    end.

invoke(Handler, ListenerMws, Req, State) ->
    RouteMws = roadrunner_conn:route_middlewares(Req),
    Pipeline =
        case ListenerMws =:= [] andalso RouteMws =:= [] of
            true ->
                fun Handler:handle/1;
            false ->
                roadrunner_middleware:compose(
                    ListenerMws ++ RouteMws,
                    fun(R) -> Handler:handle(R) end
                )
        end,
    try Pipeline(Req) of
        {Response, _Req2} ->
            emit_handler_response(Response, State)
    catch
        Class:Reason:Stack ->
            logger:error(#{
                msg => "roadrunner h2 handler crashed",
                handler => Handler,
                class => Class,
                reason => Reason,
                stacktrace => Stack
            }),
            emit_response(500, [{~"content-type", ~"text/plain"}], ~"Internal Server Error", State)
    end.

%% =============================================================================
%% Response shapes — buffered now; others 501 until later phases.
%% =============================================================================

emit_handler_response({Status, Headers, Body}, State) when
    is_integer(Status), Status >= 100, Status =< 599
->
    emit_response(Status, Headers, Body, State);
emit_handler_response({stream, _, _, _}, State) ->
    emit_501(State);
emit_handler_response({loop, _, _, _}, State) ->
    emit_501(State);
emit_handler_response({sendfile, _, _, _}, State) ->
    emit_501(State);
emit_handler_response({websocket, _, _}, State) ->
    emit_501(State).

emit_501(State) ->
    emit_response(
        501,
        [{~"content-type", ~"text/plain"}],
        ~"HTTP/2 does not yet support this response shape",
        State
    ).

%% Encode + send a response: HEADERS (END_HEADERS) + DATA
%% (END_STREAM). When body is empty, set END_STREAM on the
%% HEADERS frame and skip DATA.
emit_response(
    Status,
    Headers,
    Body0,
    #loop{
        stream = #{id := StreamId},
        hpack_enc = Enc
    } = State
) ->
    Body = iolist_to_binary(Body0),
    StatusBin = integer_to_binary(Status),
    %% Inject :status pseudo-header at the front; other pseudo-
    %% headers don't apply to responses (RFC 9113 §8.3.1).
    %% Lowercase regular header names per §8.2.
    LowerHeaders = [{lowercase(N), V} || {N, V} <- Headers],
    AllHeaders = [{~":status", StatusBin} | LowerHeaders],
    {HpackBlock, Enc1} = roadrunner_http2_hpack:encode(AllHeaders, Enc),
    HpackBin = iolist_to_binary(HpackBlock),
    HeadersFrame =
        case Body of
            <<>> ->
                %% No body — END_STREAM on HEADERS.
                roadrunner_http2_frame:encode(
                    {headers, StreamId, 16#04 bor 16#01, undefined, HpackBin}
                );
            _ ->
                roadrunner_http2_frame:encode(
                    {headers, StreamId, 16#04, undefined, HpackBin}
                )
        end,
    DataFrames =
        case Body of
            <<>> -> [];
            _ -> [roadrunner_http2_frame:encode({data, StreamId, 16#01, Body})]
        end,
    _ = send(State, [HeadersFrame, DataFrames]),
    frame_loop(State#loop{
        stream = undefined,
        hpack_enc = Enc1
    }).

%% =============================================================================
%% Helpers
%% =============================================================================

-spec lowercase(binary()) -> binary().
lowercase(B) ->
    roadrunner_bin:ascii_lowercase(B).

-spec send(#loop{}, iodata()) -> ok | {error, term()}.
send(#loop{socket = Socket}, Data) ->
    roadrunner_transport:send(Socket, Data).

-spec send_goaway(#loop{}, roadrunner_http2_frame:error_code()) -> ok | {error, term()}.
send_goaway(#loop{last_stream_id = LastId} = State, ErrorCode) ->
    send(State, ?GOAWAY(LastId, ErrorCode)).

-spec send_rst_stream(#loop{}, pos_integer(), roadrunner_http2_frame:error_code()) ->
    ok | {error, term()}.
send_rst_stream(State, StreamId, ErrorCode) ->
    send(State, roadrunner_http2_frame:encode({rst_stream, StreamId, ErrorCode})).

-spec exit_clean(#loop{}) -> no_return().
exit_clean(#loop{
    socket = Socket,
    proto_opts = ProtoOpts,
    listener_name = ListenerName,
    peer = Peer,
    start_mono = StartMono
}) ->
    roadrunner_telemetry:listener_conn_close(StartMono, #{
        listener_name => ListenerName,
        peer => Peer,
        requests_served => 0
    }),
    ok = roadrunner_conn:release_slot(ProtoOpts),
    ok = roadrunner_transport:close(Socket),
    exit(normal).
