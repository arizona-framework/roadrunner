-module(roadrunner_conn_loop_http2).
-moduledoc """
HTTP/2 (RFC 9113) connection process.

Phase H8b — true multiplexing with per-stream workers. The conn
process owns:

- the active-mode socket (sole reader / writer of bytes),
- the HPACK encoder / decoder (single context per direction
  shared across all streams),
- the connection-level flow-control windows and per-stream
  windows / pending-send queues,
- a `streams` map keyed by stream id, and `worker_refs` mapping
  monitor refs back to stream ids for `'DOWN'` correlation.

Once a request stream finishes receiving (HEADERS + body +
END_STREAM), the conn spawns a `roadrunner_http2_stream_worker`
process. The worker resolves the route, runs middleware + handler,
and translates the response into messages back to the conn:

```
{h2_send_headers, Worker, Ref, StreamId, Status, Headers, EndStream}
{h2_send_data,    Worker, Ref, StreamId, Bin,    EndStream}
{h2_send_trailers, Worker, Ref, StreamId, Trailers}
{h2_worker_done,  StreamId}
```

The conn replies `{h2_send_ack, Ref}` once the corresponding
frame(s) are on the wire — so workers are synchronously
back-pressured against flow control without buffering.

Workers are spawn_monitored (NOT linked) so a handler crash
resets only the affected stream — `'DOWN'` triggers
`RST_STREAM(INTERNAL_ERROR)` and the other in-flight streams
keep running. `MAX_CONCURRENT_STREAMS=100` is advertised; HEADERS
beyond that limit get `RST_STREAM(REFUSED_STREAM)`.

Response shapes supported:

| shape | h2 |
|---|---|
| `{Status, Headers, Body}` (buffered) | yes |
| `{stream, _, _, Fun}` | yes |
| `{loop, _}` | 501 |
| `{sendfile, _}` | 501 |
| `{websocket, _, _}` | 501 (Phase H13) |
""".

-export([enter/5]).

%% RFC 9113 §3.4 client connection preface — fixed 24 bytes.
-define(PREFACE, ~"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n").
-define(PREFACE_LEN, 24).

%% Read-deadline caps for the handshake and idle states. Tests
%% override via `persistent_term:put/2` on `{?MODULE, handshake_timeout}`
%% / `{?MODULE, idle_timeout}` so the timeout branches are exercisable
%% without forcing 10–30 s waits per case.
-define(HANDSHAKE_TIMEOUT_DEFAULT, 10_000).
-define(IDLE_TIMEOUT_DEFAULT, 30_000).

%% RFC 9113 §6.5.2 default `MAX_FRAME_SIZE`.
-define(MAX_FRAME_SIZE, 16_384).

%% RFC 9113 §6.9.2 initial window size for both the connection and
%% each stream.
-define(INITIAL_WINDOW, 65535).

%% Send a WINDOW_UPDATE refill once the local recv window falls
%% below this threshold.
-define(WINDOW_REFILL_THRESHOLD, 32_768).

%% Hard upper bound on a flow-control window per RFC 9113 §6.9.1
%% (signed 31-bit). Increments that would push past this are a
%% FLOW_CONTROL_ERROR.
-define(MAX_WINDOW, 16#7FFFFFFF).

%% Phase H8b: lift from 1 (serial) to 100 concurrent streams.
%% Clients exceeding this on this connection get
%% RST_STREAM(REFUSED_STREAM) on the over-limit HEADERS.
-define(MAX_CONCURRENT_STREAMS, 100).

-define(GOAWAY(LastStreamId, ErrorCode),
    roadrunner_http2_frame:encode({goaway, (LastStreamId), (ErrorCode), <<>>})
).

-type stream_id() :: pos_integer().

-type stream_state() ::
    open | half_closed_remote | half_closed_local | closed.

%% Pending-send entry. Only DATA frames are ever queued —
%% HEADERS / trailer HEADERS write straight to the wire (HPACK
%% encoding is window-independent). Workers are synchronous so at
%% most one entry can be pending per stream at a time; we still
%% type it as a list to leave room for future enrichment without
%% reshaping callers.
-type pending_send() ::
    {data, reference(), pid(), binary(), boolean()}.

-type stream_entry() :: #{
    state := stream_state(),
    header_fragment := binary(),
    end_headers := boolean(),
    end_stream_seen := boolean(),
    headers := undefined | [roadrunner_http2_hpack:header()],
    body := iolist(),
    send_window := integer(),
    recv_window := non_neg_integer(),
    worker_pid := undefined | pid(),
    worker_ref := undefined | reference(),
    pending_sends := [pending_send()]
}.

-record(loop, {
    socket :: roadrunner_transport:socket(),
    proto_opts :: roadrunner_conn:proto_opts(),
    listener_name :: atom(),
    peer :: {inet:ip_address(), inet:port_number()} | undefined,
    start_mono :: integer(),
    scheme :: http | https,
    %% Active-mode message tags for this transport.
    msg_data :: atom(),
    msg_closed :: atom(),
    msg_error :: atom(),
    %% Inbound bytes still to parse.
    buffer = <<>> :: binary(),
    %% HPACK contexts.
    hpack_dec :: roadrunner_http2_hpack:context(),
    hpack_enc :: roadrunner_http2_hpack:context(),
    %% Highest stream id we've processed — for the LAST_STREAM_ID
    %% in GOAWAY.
    last_stream_id = 0 :: non_neg_integer(),
    %% Connection-level flow-control windows (RFC 9113 §5.2).
    conn_send_window = 65535 :: integer(),
    conn_recv_window = 65535 :: non_neg_integer(),
    %% Stream table, keyed by stream id.
    streams = #{} :: #{stream_id() => stream_entry()},
    %% Worker monitor ref → stream id, for DOWN correlation.
    worker_refs = #{} :: #{reference() => stream_id()}
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
    {Data, Closed, Error} = roadrunner_transport:messages(Socket),
    State = #loop{
        socket = Socket,
        proto_opts = ProtoOpts,
        listener_name = ListenerName,
        peer = Peer,
        start_mono = StartMono,
        scheme = Scheme,
        msg_data = Data,
        msg_closed = Closed,
        msg_error = Error,
        hpack_dec = roadrunner_http2_hpack:new_decoder(4096),
        hpack_enc = roadrunner_http2_hpack:new_encoder(4096)
    },
    handshake(State).

%% =============================================================================
%% Handshake — RFC 9113 §3.4
%% =============================================================================

-spec handshake(#loop{}) -> no_return().
handshake(State) ->
    _ = send(State, server_settings_frame()),
    handshake_phase_preface(State).

-spec server_settings_frame() -> iodata().
server_settings_frame() ->
    %% Advertise MAX_CONCURRENT_STREAMS=100 and MAX_FRAME_SIZE.
    %% IDs from RFC 9113 §6.5.2: 3 = MAX_CONCURRENT_STREAMS,
    %% 5 = MAX_FRAME_SIZE.
    roadrunner_http2_frame:encode(
        {settings, 0, [{3, ?MAX_CONCURRENT_STREAMS}, {5, ?MAX_FRAME_SIZE}]}
    ).

-spec handshake_timeout() -> non_neg_integer().
handshake_timeout() ->
    persistent_term:get({?MODULE, handshake_timeout}, ?HANDSHAKE_TIMEOUT_DEFAULT).

-spec idle_timeout() -> non_neg_integer().
idle_timeout() ->
    persistent_term:get({?MODULE, idle_timeout}, ?IDLE_TIMEOUT_DEFAULT).

-spec handshake_phase_preface(#loop{}) -> no_return().
handshake_phase_preface(#loop{buffer = Buf} = State) when byte_size(Buf) >= ?PREFACE_LEN ->
    <<Head:?PREFACE_LEN/binary, Rest/binary>> = Buf,
    case Head of
        ?PREFACE ->
            handshake_phase_settings(State#loop{buffer = Rest});
        _ ->
            exit_clean(State)
    end;
handshake_phase_preface(State) ->
    handshake_recv(State, fun handshake_phase_preface/1).

-spec handshake_phase_settings(#loop{}) -> no_return().
handshake_phase_settings(#loop{buffer = Buf} = State) ->
    case roadrunner_http2_frame:parse(Buf, ?MAX_FRAME_SIZE) of
        {ok, {settings, Flags, _Params}, Rest} when (Flags band 1) =:= 0 ->
            State1 = State#loop{buffer = Rest},
            _ = send(State1, roadrunner_http2_frame:encode({settings, 1, []})),
            frame_loop(State1);
        {ok, _, _} ->
            _ = send_goaway(State, protocol_error),
            exit_clean(State);
        {more, _Need} ->
            handshake_recv(State, fun handshake_phase_settings/1);
        {error, _} ->
            _ = send_goaway(State, protocol_error),
            exit_clean(State)
    end.

-spec handshake_recv(#loop{}, fun((#loop{}) -> no_return())) -> no_return().
handshake_recv(
    #loop{
        socket = Sock,
        msg_data = MData,
        msg_closed = MClosed,
        msg_error = MError,
        buffer = Buf
    } = State,
    Cont
) ->
    _ = roadrunner_transport:setopts(Sock, [{active, once}]),
    receive
        {MData, _, Bytes} ->
            Cont(State#loop{buffer = <<Buf/binary, Bytes/binary>>});
        {MClosed, _} ->
            exit_clean(State);
        {MError, _, _} ->
            exit_clean(State)
    after handshake_timeout() ->
        exit_clean(State)
    end.

%% =============================================================================
%% Frame loop — active-mode socket receive + worker message dispatch
%% =============================================================================

-spec frame_loop(#loop{}) -> no_return().
frame_loop(#loop{buffer = Buf} = State) ->
    case roadrunner_http2_frame:parse(Buf, ?MAX_FRAME_SIZE) of
        {ok, Frame, Rest} ->
            handle_frame(Frame, State#loop{buffer = Rest});
        {more, _Need} ->
            arm_and_recv(State);
        {error, _} ->
            _ = send_goaway(State, protocol_error),
            exit_clean(State)
    end.

-spec arm_and_recv(#loop{}) -> no_return().
arm_and_recv(#loop{socket = Sock} = State) ->
    _ = roadrunner_transport:setopts(Sock, [{active, once}]),
    recv_more(State).

%% Unified mailbox dispatch: socket events, worker send requests,
%% worker DOWN signals, and the idle-timeout `after` clause.
-spec recv_more(#loop{}) -> no_return().
recv_more(
    #loop{
        msg_data = MData,
        msg_closed = MClosed,
        msg_error = MError,
        buffer = Buf
    } = State
) ->
    receive
        {MData, _, Bytes} ->
            frame_loop(State#loop{buffer = <<Buf/binary, Bytes/binary>>});
        {MClosed, _} ->
            exit_clean(State);
        {MError, _, _} ->
            _ = send_goaway(State, protocol_error),
            exit_clean(State);
        {h2_send_headers, From, Ref, StreamId, Status, Headers, EndStream} ->
            recv_more(handle_send_headers(State, From, Ref, StreamId, Status, Headers, EndStream));
        {h2_send_data, From, Ref, StreamId, Bin, EndStream} ->
            recv_more(handle_send_data(State, From, Ref, StreamId, Bin, EndStream));
        {h2_send_trailers, From, Ref, StreamId, Trailers} ->
            recv_more(handle_send_trailers(State, From, Ref, StreamId, Trailers));
        {h2_worker_done, StreamId} ->
            recv_more(handle_worker_done(State, StreamId));
        {'DOWN', MonRef, process, _Pid, Reason} ->
            recv_more(handle_worker_down(State, MonRef, Reason))
    after idle_timeout() ->
        _ = send_goaway(State, protocol_error),
        exit_clean(State)
    end.

%% =============================================================================
%% Per-frame dispatch — peer → server frames
%% =============================================================================

-spec handle_frame(roadrunner_http2_frame:frame(), #loop{}) -> no_return().
handle_frame({settings, 1, _}, State) ->
    frame_loop(State);
handle_frame({settings, 0, _Params}, State) ->
    _ = send(State, roadrunner_http2_frame:encode({settings, 1, []})),
    frame_loop(State);
handle_frame({ping, 1, _Data}, State) ->
    frame_loop(State);
handle_frame({ping, 0, Opaque}, State) ->
    _ = send(State, roadrunner_http2_frame:encode({ping, 1, Opaque})),
    frame_loop(State);
handle_frame({window_update, 0, Inc}, State) ->
    case State#loop.conn_send_window + Inc of
        New when New > ?MAX_WINDOW ->
            _ = send_goaway(State, flow_control_error),
            exit_clean(State);
        New ->
            State1 = State#loop{conn_send_window = New},
            frame_loop(flush_all_pending_data(State1))
    end;
handle_frame({window_update, StreamId, Inc}, #loop{streams = Streams} = State) ->
    case maps:find(StreamId, Streams) of
        {ok, Stream} ->
            case maps:get(send_window, Stream) + Inc of
                New when New > ?MAX_WINDOW ->
                    _ = send_goaway(State, flow_control_error),
                    exit_clean(State);
                New ->
                    Stream1 = Stream#{send_window := New},
                    State1 = update_stream(State, StreamId, Stream1),
                    frame_loop(flush_pending_data(State1, StreamId))
            end;
        error ->
            %% Closed stream — silently ignore per RFC 9113 §6.9.
            frame_loop(State)
    end;
handle_frame({priority, _, _}, State) ->
    frame_loop(State);
handle_frame({rst_stream, StreamId, _}, #loop{streams = Streams} = State) ->
    case maps:is_key(StreamId, Streams) of
        true ->
            frame_loop(reset_stream(State, StreamId));
        false ->
            frame_loop(State)
    end;
handle_frame({goaway, _, _, _}, State) ->
    %% Client is shutting down.
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

on_headers(StreamId, _Flags, _Priority, _Fragment, #loop{streams = Streams} = State) when
    map_size(Streams) >= ?MAX_CONCURRENT_STREAMS
->
    %% Over the advertised concurrency limit — refuse the stream.
    _ = send_rst_stream(State, StreamId, refused_stream),
    frame_loop(State);
on_headers(StreamId, _Flags, _Priority, _Fragment, #loop{streams = Streams} = State) when
    is_map_key(StreamId, Streams)
->
    %% HEADERS for an already-open stream is a protocol error
    %% (RFC 9113 §5.1.1; trailers come via END_STREAM on the same
    %% stream, not a fresh HEADERS).
    _ = send_goaway(State, protocol_error),
    exit_clean(State);
on_headers(StreamId, Flags, _Priority, Fragment, State) when StreamId rem 2 =:= 1 ->
    EndHeaders = (Flags band 16#04) =/= 0,
    EndStream = (Flags band 16#01) =/= 0,
    Stream = new_stream(Fragment, EndHeaders, EndStream),
    State1 = State#loop{
        streams = maps:put(StreamId, Stream, State#loop.streams),
        last_stream_id = max(StreamId, State#loop.last_stream_id)
    },
    case EndHeaders of
        true -> finalize_headers(StreamId, State1);
        false -> frame_loop(State1)
    end;
on_headers(_StreamId, _Flags, _Priority, _Fragment, State) ->
    %% Even stream id from client — protocol error.
    _ = send_goaway(State, protocol_error),
    exit_clean(State).

new_stream(Fragment, EndHeaders, EndStream) ->
    #{
        state => open,
        header_fragment => Fragment,
        end_headers => EndHeaders,
        end_stream_seen => EndStream,
        headers => undefined,
        body => [],
        send_window => ?INITIAL_WINDOW,
        recv_window => ?INITIAL_WINDOW,
        worker_pid => undefined,
        worker_ref => undefined,
        pending_sends => []
    }.

on_continuation(StreamId, Flags, Fragment, #loop{streams = Streams} = State) ->
    case maps:find(StreamId, Streams) of
        {ok, #{end_headers := false} = Stream} ->
            Combined = <<(maps:get(header_fragment, Stream))/binary, Fragment/binary>>,
            EndHeaders = (Flags band 16#04) =/= 0,
            Stream1 = Stream#{header_fragment := Combined, end_headers := EndHeaders},
            State1 = update_stream(State, StreamId, Stream1),
            case EndHeaders of
                true -> finalize_headers(StreamId, State1);
                false -> frame_loop(State1)
            end;
        _ ->
            _ = send_goaway(State, protocol_error),
            exit_clean(State)
    end.

%% Decode the accumulated HPACK fragment, store decoded headers on
%% the stream entry. If END_STREAM was set on the HEADERS frame,
%% dispatch the worker now (no body); otherwise wait for DATA.
finalize_headers(StreamId, #loop{streams = Streams, hpack_dec = Dec} = State) ->
    Stream = maps:get(StreamId, Streams),
    Fragment = maps:get(header_fragment, Stream),
    case roadrunner_http2_hpack:decode(Fragment, Dec) of
        {ok, Headers, Dec1} ->
            Stream1 = Stream#{headers := Headers, header_fragment := <<>>},
            State1 = State#loop{
                hpack_dec = Dec1,
                streams = maps:put(StreamId, Stream1, Streams)
            },
            case maps:get(end_stream_seen, Stream1) of
                true -> dispatch_stream(StreamId, State1);
                false -> frame_loop(State1)
            end;
        {error, _} ->
            _ = send_goaway(State, protocol_error),
            exit_clean(State)
    end.

%% --- DATA ---

on_data(StreamId, Flags, Payload, #loop{streams = Streams} = State) ->
    case maps:find(StreamId, Streams) of
        {ok, Stream} ->
            EndStream = (Flags band 16#01) =/= 0,
            PayloadLen = byte_size(Payload),
            NewBody = [maps:get(body, Stream), Payload],
            NewConnRecv = State#loop.conn_recv_window - PayloadLen,
            NewStreamRecv = maps:get(recv_window, Stream) - PayloadLen,
            Stream1 = Stream#{
                body := NewBody,
                end_stream_seen := EndStream,
                recv_window := NewStreamRecv
            },
            State1 = State#loop{
                streams = maps:put(StreamId, Stream1, Streams),
                conn_recv_window = NewConnRecv
            },
            State2 = maybe_refill_recv_windows(State1, StreamId),
            case EndStream of
                true -> dispatch_stream(StreamId, State2);
                false -> frame_loop(State2)
            end;
        error ->
            _ = send_goaway(State, protocol_error),
            exit_clean(State)
    end.

%% Refill the conn-level + stream-level recv windows whenever they
%% drop below `?WINDOW_REFILL_THRESHOLD`.
-spec maybe_refill_recv_windows(#loop{}, stream_id()) -> #loop{}.
maybe_refill_recv_windows(State, StreamId) ->
    State1 = maybe_refill_conn(State),
    maybe_refill_stream(State1, StreamId).

maybe_refill_conn(#loop{conn_recv_window = W} = State) when W < ?WINDOW_REFILL_THRESHOLD ->
    Inc = ?INITIAL_WINDOW - W,
    _ = send(State, roadrunner_http2_frame:encode({window_update, 0, Inc})),
    State#loop{conn_recv_window = W + Inc};
maybe_refill_conn(State) ->
    State.

maybe_refill_stream(#loop{streams = Streams} = State, StreamId) ->
    Stream = maps:get(StreamId, Streams),
    case maps:get(recv_window, Stream) of
        W when W < ?WINDOW_REFILL_THRESHOLD ->
            Inc = ?INITIAL_WINDOW - W,
            _ = send(
                State,
                roadrunner_http2_frame:encode({window_update, StreamId, Inc})
            ),
            update_stream(State, StreamId, Stream#{recv_window := W + Inc});
        _ ->
            State
    end.

%% =============================================================================
%% Stream dispatch — spawn a worker
%% =============================================================================

dispatch_stream(
    StreamId,
    #loop{
        streams = Streams,
        proto_opts = ProtoOpts,
        peer = Peer,
        scheme = Scheme,
        listener_name = ListenerName
    } = State
) ->
    Stream = maps:get(StreamId, Streams),
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
            {WorkerPid, MonRef} = roadrunner_http2_stream_worker:start(
                self(), StreamId, Req, ProtoOpts
            ),
            Stream1 = Stream#{
                worker_pid := WorkerPid,
                worker_ref := MonRef,
                state := half_closed_remote,
                body := []
            },
            State1 = State#loop{
                streams = maps:put(StreamId, Stream1, Streams),
                worker_refs = maps:put(MonRef, StreamId, State#loop.worker_refs)
            },
            frame_loop(State1);
        {error, _Reason} ->
            _ = send_rst_stream(State, StreamId, protocol_error),
            frame_loop(remove_stream(State, StreamId))
    end.

%% =============================================================================
%% Worker → conn message handlers
%% =============================================================================

handle_send_headers(State, From, Ref, StreamId, Status, Headers, EndStream) ->
    case stream_open(State, StreamId) of
        {ok, _Stream} ->
            State1 = encode_and_send_headers(State, StreamId, Status, Headers, EndStream),
            _ = (From ! {h2_send_ack, Ref}),
            State1;
        not_open ->
            _ = (From ! {h2_stream_reset, StreamId}),
            State
    end.

handle_send_data(State, From, Ref, StreamId, Bin, EndStream) ->
    case stream_open(State, StreamId) of
        {ok, Stream} ->
            try_send_data(State, Stream, StreamId, From, Ref, Bin, EndStream);
        not_open ->
            _ = (From ! {h2_stream_reset, StreamId}),
            State
    end.

handle_send_trailers(State, From, Ref, StreamId, Trailers) ->
    case stream_open(State, StreamId) of
        {ok, _Stream} ->
            State1 = encode_and_send_trailers(State, StreamId, Trailers),
            _ = (From ! {h2_send_ack, Ref}),
            State1;
        not_open ->
            _ = (From ! {h2_stream_reset, StreamId}),
            State
    end.

handle_worker_done(State, StreamId) ->
    %% The worker exits after this message; the DOWN cleanup will
    %% remove the stream. Nothing to do here.
    _ = StreamId,
    State.

handle_worker_down(#loop{worker_refs = Refs} = State, MonRef, Reason) ->
    case maps:find(MonRef, Refs) of
        {ok, StreamId} ->
            State1 = State#loop{worker_refs = maps:remove(MonRef, Refs)},
            case Reason of
                normal -> remove_stream(State1, StreamId);
                _ -> abort_stream(State1, StreamId, internal_error)
            end;
        error ->
            State
    end.

%% Look up a stream that has not yet been reset / closed. Returns
%% `not_open` for streams the conn has already torn down (peer
%% RST_STREAM, write of END_STREAM completed, etc.) — workers
%% asking to write to those should be told to abort.
stream_open(#loop{streams = Streams}, StreamId) ->
    case maps:find(StreamId, Streams) of
        {ok, #{state := closed}} -> not_open;
        {ok, Stream} -> {ok, Stream};
        error -> not_open
    end.

%% Encode + write a HEADERS frame (always fits without flow control;
%% the wire just takes it).
encode_and_send_headers(
    #loop{hpack_enc = Enc} = State, StreamId, Status, Headers, EndStream
) ->
    StatusBin = integer_to_binary(Status),
    LowerHeaders = [{lowercase(N), V} || {N, V} <- Headers],
    AllHeaders = [{~":status", StatusBin} | LowerHeaders],
    {HpackBlock, Enc1} = roadrunner_http2_hpack:encode(AllHeaders, Enc),
    HpackBin = iolist_to_binary(HpackBlock),
    Flags =
        case EndStream of
            true -> 16#04 bor 16#01;
            false -> 16#04
        end,
    Frame = roadrunner_http2_frame:encode({headers, StreamId, Flags, undefined, HpackBin}),
    _ = send(State, Frame),
    State1 = State#loop{hpack_enc = Enc1},
    case EndStream of
        true -> close_stream_send_side(State1, StreamId);
        false -> State1
    end.

encode_and_send_trailers(#loop{hpack_enc = Enc} = State, StreamId, Trailers) ->
    LowerTrailers = [{lowercase(N), V} || {N, V} <- Trailers],
    {HpackBlock, Enc1} = roadrunner_http2_hpack:encode(LowerTrailers, Enc),
    HpackBin = iolist_to_binary(HpackBlock),
    Frame = roadrunner_http2_frame:encode(
        {headers, StreamId, 16#04 bor 16#01, undefined, HpackBin}
    ),
    _ = send(State, Frame),
    State1 = State#loop{hpack_enc = Enc1},
    close_stream_send_side(State1, StreamId).

%% Mark the send side closed. Future worker writes on this stream
%% get `{h2_stream_reset, _}` so they unwind cleanly.
close_stream_send_side(#loop{streams = Streams} = State, StreamId) ->
    Stream = maps:get(StreamId, Streams),
    update_stream(State, StreamId, Stream#{state := closed}).

%% =============================================================================
%% DATA send + flow control
%% =============================================================================

%% Try to send `Bin` as DATA frame(s). If both windows allow, send
%% everything and ack. If a partial chunk fits, send what we can
%% and queue the rest. If nothing fits, queue the whole thing.
%%
%% Empty `Bin` always means `EndStream = true` because
%% `roadrunner_http2_stream_response` short-circuits empty `nofin`
%% sends — the empty-body case here doesn't consume any window
%% bytes, so it bypasses the window check entirely.
try_send_data(State, _Stream, StreamId, From, Ref, <<>>, true) ->
    Frame = roadrunner_http2_frame:encode({data, StreamId, 16#01, <<>>}),
    _ = send(State, Frame),
    _ = (From ! {h2_send_ack, Ref}),
    close_stream_send_side(State, StreamId);
try_send_data(State, Stream, StreamId, From, Ref, Bin, EndStream) ->
    case window_budget(State, Stream) of
        0 ->
            %% Window closed — queue the whole send.
            Stream1 = enqueue_pending(Stream, {data, Ref, From, Bin, EndStream}),
            update_stream(State, StreamId, Stream1);
        _ ->
            send_data_chunks(State, Stream, StreamId, From, Ref, Bin, EndStream)
    end.

send_data_chunks(State, Stream, StreamId, From, Ref, Bin, EndStream) ->
    Available = window_budget(State, Stream),
    Take = min(min(byte_size(Bin), Available), ?MAX_FRAME_SIZE),
    case Take of
        0 ->
            %% Window closed mid-body — queue the remainder.
            Stream1 = enqueue_pending(Stream, {data, Ref, From, Bin, EndStream}),
            update_stream(State, StreamId, Stream1);
        N when N =:= byte_size(Bin) ->
            %% Last chunk — END_STREAM if the caller asked.
            Flags =
                case EndStream of
                    true -> 16#01;
                    false -> 0
                end,
            Frame = roadrunner_http2_frame:encode({data, StreamId, Flags, Bin}),
            _ = send(State, Frame),
            State1 = consume_send_window(State, StreamId, Stream, N),
            _ = (From ! {h2_send_ack, Ref}),
            case EndStream of
                true -> close_stream_send_side(State1, StreamId);
                false -> State1
            end;
        N ->
            <<Chunk:N/binary, Rest/binary>> = Bin,
            Frame = roadrunner_http2_frame:encode({data, StreamId, 0, Chunk}),
            _ = send(State, Frame),
            State1 = consume_send_window(State, StreamId, Stream, N),
            Stream1 = maps:get(StreamId, State1#loop.streams),
            send_data_chunks(State1, Stream1, StreamId, From, Ref, Rest, EndStream)
    end.

window_budget(#loop{conn_send_window = ConnW}, #{send_window := StreamW}) ->
    max(0, min(ConnW, StreamW)).

consume_send_window(
    #loop{conn_send_window = ConnW, streams = Streams} = State, StreamId, Stream, N
) ->
    Stream1 = Stream#{send_window := maps:get(send_window, Stream) - N},
    State#loop{
        conn_send_window = ConnW - N,
        streams = maps:put(StreamId, Stream1, Streams)
    }.

enqueue_pending(Stream, Entry) ->
    Stream#{pending_sends := maps:get(pending_sends, Stream) ++ [Entry]}.

%% After a stream's send window grew, drain its pending DATA queue
%% as far as windows allow.
flush_pending_data(#loop{streams = Streams} = State, StreamId) ->
    case maps:get(StreamId, Streams) of
        #{pending_sends := []} -> State;
        Stream -> drain_pending(State, StreamId, Stream)
    end.

%% After the conn-level send window grew, drain every stream's
%% pending queue.
flush_all_pending_data(#loop{streams = Streams} = State) ->
    maps:fold(
        fun(StreamId, _Stream, AccState) ->
            flush_pending_data(AccState, StreamId)
        end,
        State,
        Streams
    ).

%% Drain queued sends on a single stream until either the queue is
%% empty or the window forces us to stop again.
drain_pending(State, _StreamId, #{pending_sends := []}) ->
    State;
drain_pending(State, StreamId, #{pending_sends := [Entry | Rest]} = Stream) ->
    {data, Ref, From, Bin, EndStream} = Entry,
    Stream1 = Stream#{pending_sends := Rest},
    State1 = update_stream(State, StreamId, Stream1),
    State2 = try_send_data(State1, Stream1, StreamId, From, Ref, Bin, EndStream),
    Stream2 = maps:get(StreamId, State2#loop.streams),
    case maps:get(pending_sends, Stream2) of
        [Entry | _] ->
            %% Same entry re-queued: window still closed.
            State2;
        _ ->
            drain_pending(State2, StreamId, Stream2)
    end.

%% =============================================================================
%% Stream lifecycle helpers
%% =============================================================================

update_stream(#loop{streams = Streams} = State, StreamId, Stream) ->
    State#loop{streams = maps:put(StreamId, Stream, Streams)}.

%% Peer sent RST_STREAM for a stream we have alive. Tell the worker
%% (if any) to bail, then drop our stream entry. Pending sends get
%% reset notifications so workers waiting on `h2_send_ack` unwind.
reset_stream(#loop{streams = Streams, worker_refs = Refs} = State, StreamId) ->
    Stream = maps:get(StreamId, Streams),
    notify_pending_reset(StreamId, maps:get(pending_sends, Stream)),
    Refs1 =
        case maps:get(worker_ref, Stream) of
            undefined ->
                %% RST landed before END_STREAM dispatched a worker.
                Refs;
            MonRef ->
                Pid = maps:get(worker_pid, Stream),
                _ = (Pid ! {h2_stream_reset, StreamId}),
                true = demonitor(MonRef, [flush]),
                maps:remove(MonRef, Refs)
        end,
    State#loop{
        streams = maps:remove(StreamId, Streams),
        worker_refs = Refs1
    }.

%% Called by `handle_worker_down/3` when a worker dies abnormally.
%% Send RST_STREAM(error_code) to the peer and drop our state.
abort_stream(#loop{streams = Streams} = State, StreamId, ErrorCode) ->
    Stream = maps:get(StreamId, Streams),
    notify_pending_reset(StreamId, maps:get(pending_sends, Stream)),
    _ = send_rst_stream(State, StreamId, ErrorCode),
    State#loop{streams = maps:remove(StreamId, Streams)}.

%% Worker exited normally (handler done, all frames already on the
%% wire). Just drop state.
remove_stream(#loop{streams = Streams} = State, StreamId) ->
    State#loop{streams = maps:remove(StreamId, Streams)}.

notify_pending_reset(_StreamId, []) ->
    ok;
notify_pending_reset(StreamId, [{data, _Ref, From, _Bin, _Es} | Rest]) ->
    _ = (From ! {h2_stream_reset, StreamId}),
    notify_pending_reset(StreamId, Rest).

%% =============================================================================
%% Generic helpers
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
