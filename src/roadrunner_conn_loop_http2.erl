-module(roadrunner_conn_loop_http2).
-moduledoc """
HTTP/2 (RFC 9113) connection process.

Driven by either TLS ALPN-negotiated `h2` or a plaintext listener
configured with `protocols => [http2]` (RFC 7540 §3.4 prior-knowledge).
The dispatch decision lives in `roadrunner_conn_loop:awaiting_shoot/3`;
this module is transport-agnostic and reads frames via
`roadrunner_transport:recv/3` either way.

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
| `{loop, _}` | yes (worker enters handle_info loop) |
| `{sendfile, _}` | yes (chunked DATA via the stream-response engine) |
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

%% Default refill threshold + recv-window peaks when proto_opts
%% don't override. RFC 9113 doesn't mandate any of these — they're
%% policy. The defaults match the RFC 9113 §6.9.2 baseline (65535
%% for both windows; the threshold is half of that, the original
%% heuristic). `roadrunner_listener:opts()` carries the override
%% knobs (`h2_initial_conn_window`, `h2_initial_stream_window`,
%% `h2_window_refill_threshold`) — bumping the windows is the
%% standard tuning for non-LAN RTTs (window/RTT bounds per-stream
%% throughput).
-define(DEFAULT_CONN_RECV_WINDOW, 65535).
-define(DEFAULT_STREAM_RECV_WINDOW, 65535).
-define(DEFAULT_WINDOW_REFILL_THRESHOLD, 32_768).

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
    %% Cumulative byte count of received DATA payload, used to
    %% validate against the request's `content-length` header at
    %% END_STREAM (RFC 9113 §8.1.2.6).
    body_len := non_neg_integer(),
    send_window := integer(),
    recv_window := non_neg_integer(),
    worker_pid := undefined | pid(),
    worker_ref := undefined | reference(),
    pending_sends := queue:queue(pending_send())
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
    %% Pre-generated CSPRNG bytes for `request_id`, sliced 8 bytes
    %% at a time. Refilled by `roadrunner_conn:generate_request_id/1`
    %% in 256-byte batches so h2 conns amortize the crypto cost
    %% across ~32 requests instead of paying it per dispatch.
    req_id_buffer = <<>> :: binary(),
    %% Connection-level flow-control windows (RFC 9113 §5.2). Send
    %% window is set by peer SETTINGS / WINDOW_UPDATE. Recv window
    %% starts at 65535 (RFC default) and is bumped to
    %% `recv_window_peak` via an early `WINDOW_UPDATE(0, _)` in
    %% `handshake/1` when the peak is greater. Refilled to the peak
    %% whenever it drops below `recv_window_threshold`.
    conn_send_window = 65535 :: integer(),
    conn_recv_window = 65535 :: non_neg_integer(),
    %% Configured peaks + refill threshold. Read from proto_opts at
    %% `enter/5`. See the `?DEFAULT_*` macros above for the policy
    %% baseline + the listener moduledoc for the override knobs.
    recv_window_peak = ?DEFAULT_CONN_RECV_WINDOW :: pos_integer(),
    stream_recv_window_peak = ?DEFAULT_STREAM_RECV_WINDOW :: pos_integer(),
    recv_window_threshold = ?DEFAULT_WINDOW_REFILL_THRESHOLD :: pos_integer(),
    %% Stream table, keyed by stream id.
    streams = #{} :: #{stream_id() => stream_entry()},
    %% Worker monitor ref → stream id, for DOWN correlation.
    worker_refs = #{} :: #{reference() => stream_id()},
    %% Set to a stream id while a HEADERS / PUSH_PROMISE block is
    %% still being assembled (no END_HEADERS yet). The next inbound
    %% frame MUST be a CONTINUATION on the same stream — anything
    %% else is a connection error per RFC 9113 §6.10.
    awaiting_continuation = undefined :: undefined | stream_id(),
    %% Peer-advertised SETTINGS_INITIAL_WINDOW_SIZE for stream send
    %% windows. Default per §6.9.2 is 65535. New streams use this
    %% value; existing stream send-windows shift by the delta when
    %% the peer changes the setting (§6.9.2).
    peer_initial_window = 65535 :: integer(),
    %% Set to `true` once a `{roadrunner_drain, _}` message has
    %% been observed (Phase H9). In drain mode we've already sent
    %% GOAWAY(NO_ERROR), refuse fresh streams with
    %% RST_STREAM(REFUSED_STREAM), and exit as soon as the streams
    %% map empties.
    draining = false :: boolean()
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
    ConnPeak = maps:get(h2_initial_conn_window, ProtoOpts, ?DEFAULT_CONN_RECV_WINDOW),
    StreamPeak = maps:get(h2_initial_stream_window, ProtoOpts, ?DEFAULT_STREAM_RECV_WINDOW),
    Threshold = maps:get(
        h2_window_refill_threshold, ProtoOpts, ?DEFAULT_WINDOW_REFILL_THRESHOLD
    ),
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
        hpack_enc = roadrunner_http2_hpack:new_encoder(4096),
        recv_window_peak = ConnPeak,
        stream_recv_window_peak = StreamPeak,
        recv_window_threshold = Threshold
    },
    handshake(State).

%% =============================================================================
%% Handshake — RFC 9113 §3.4
%% =============================================================================

-spec handshake(#loop{}) -> no_return().
handshake(
    #loop{recv_window_peak = ConnPeak, stream_recv_window_peak = StreamPeak} = State
) ->
    _ = send(State, server_settings_frame(StreamPeak)),
    %% RFC 9113 §6.9.2: SETTINGS_INITIAL_WINDOW_SIZE only affects
    %% stream-level recv windows. The conn-level recv window stays
    %% at the 65535 default until an explicit `WINDOW_UPDATE(0, _)`,
    %% so emit one now if the configured peak is bigger.
    State1 =
        case ConnPeak > ?INITIAL_WINDOW of
            true ->
                Inc = ConnPeak - ?INITIAL_WINDOW,
                _ = send(State, roadrunner_http2_frame:encode({window_update, 0, Inc})),
                State#loop{conn_recv_window = ConnPeak};
            false ->
                State
        end,
    handshake_phase_preface(State1).

-spec server_settings_frame(pos_integer()) -> iodata().
server_settings_frame(StreamPeak) ->
    %% Advertise MAX_CONCURRENT_STREAMS=100 and MAX_FRAME_SIZE.
    %% IDs from RFC 9113 §6.5.2: 3 = MAX_CONCURRENT_STREAMS,
    %% 5 = MAX_FRAME_SIZE.  When the stream-level recv peak is bigger
    %% than the RFC 65535 default, also advertise
    %% SETTINGS_INITIAL_WINDOW_SIZE (id 4) so streams the peer opens
    %% start with the larger receive allowance.
    Base = [{3, ?MAX_CONCURRENT_STREAMS}, {5, ?MAX_FRAME_SIZE}],
    Settings =
        case StreamPeak > ?INITIAL_WINDOW of
            true -> [{4, StreamPeak} | Base];
            false -> Base
        end,
    roadrunner_http2_frame:encode({settings, 0, Settings}).

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
frame_loop(#loop{draining = true, streams = Streams} = State) when map_size(Streams) =:= 0 ->
    %% Drain done — the last in-flight stream finished or peer
    %% RST'd it, nothing more to do.
    exit_clean(State);
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
        {h2_send_response, From, Ref, StreamId, Status, Headers, Body} ->
            recv_more(handle_send_response(State, From, Ref, StreamId, Status, Headers, Body));
        {h2_worker_done, StreamId} ->
            recv_more(handle_worker_done(State, StreamId));
        {'DOWN', MonRef, process, _Pid, Reason} ->
            recv_more(maybe_exit_when_drained(handle_worker_down(State, MonRef, Reason)));
        {roadrunner_drain, _Deadline} ->
            recv_more(maybe_exit_when_drained(start_drain(State)))
    after idle_timeout() ->
        _ = send_goaway(State, protocol_error),
        exit_clean(State)
    end.

%% Begin a graceful drain: emit GOAWAY(NO_ERROR) once, refuse new
%% streams henceforth. In-flight workers continue to completion.
%% Idempotent — subsequent drain messages are no-ops.
-spec start_drain(#loop{}) -> #loop{}.
start_drain(#loop{draining = true} = State) ->
    State;
start_drain(#loop{} = State) ->
    _ = send_goaway(State, no_error),
    State#loop{draining = true}.

%% Once we're draining and the streams map empties, exit cleanly.
%% Called after every event that could remove a stream. Note that
%% `exit_clean/1` is `no_return`, so on the drained branch this
%% function never returns and the caller's tail-call to
%% `recv_more/1` is dead — typed as `#loop{}` rather than
%% `no_return()` so the type-checker sees the live path.
-spec maybe_exit_when_drained(#loop{}) -> #loop{}.
maybe_exit_when_drained(#loop{draining = true, streams = Streams} = State) when
    map_size(Streams) =:= 0
->
    exit_clean(State);
maybe_exit_when_drained(State) ->
    State.

%% =============================================================================
%% Per-frame dispatch — peer → server frames
%% =============================================================================

-spec handle_frame(roadrunner_http2_frame:frame(), #loop{}) -> no_return().
%% RFC 9113 §6.10: while a HEADERS / PUSH_PROMISE block is in
%% mid-flight (no END_HEADERS yet), the next frame MUST be a
%% CONTINUATION on the same stream. Anything else is PROTOCOL_ERROR.
handle_frame(Frame, #loop{awaiting_continuation = Awaiting} = State) when
    Awaiting =/= undefined
->
    case Frame of
        {continuation, Awaiting, Flags, Fragment} ->
            on_continuation(Awaiting, Flags, Fragment, State);
        _ ->
            _ = send_goaway(State, protocol_error),
            exit_clean(State)
    end;
handle_frame({settings, 1, _}, State) ->
    frame_loop(State);
handle_frame({settings, 0, Params}, State) ->
    case validate_settings(Params) of
        ok ->
            case apply_initial_window_size(Params, State) of
                {ok, State1} ->
                    _ = send(State1, roadrunner_http2_frame:encode({settings, 1, []})),
                    frame_loop(State1);
                {error, flow_control_error} ->
                    _ = send_goaway(State, flow_control_error),
                    exit_clean(State)
            end;
        {error, {protocol_error, _}} ->
            _ = send_goaway(State, protocol_error),
            exit_clean(State);
        {error, {flow_control_error, _}} ->
            _ = send_goaway(State, flow_control_error),
            exit_clean(State)
    end;
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
    case Streams of
        #{StreamId := #{send_window := SW} = Stream} ->
            case SW + Inc of
                New when New > ?MAX_WINDOW ->
                    %% RFC 9113 §6.9.1: stream-level overflow is a
                    %% stream error, not a connection error.
                    _ = send_rst_stream(State, StreamId, flow_control_error),
                    frame_loop(remove_stream(State, StreamId));
                New ->
                    Stream1 = Stream#{send_window := New},
                    State1 = State#loop{streams = Streams#{StreamId := Stream1}},
                    frame_loop(flush_pending_data(State1, StreamId))
            end;
        #{} ->
            %% RFC 9113 §5.1: WINDOW_UPDATE on an idle stream is
            %% PROTOCOL_ERROR. A closed-stream WU (id <=
            %% last_stream_id) is silently ignored per §6.9.
            case StreamId > State#loop.last_stream_id of
                true ->
                    _ = send_goaway(State, protocol_error),
                    exit_clean(State);
                false ->
                    frame_loop(State)
            end
    end;
handle_frame({priority, StreamId, #{stream_dependency := StreamId}}, State) ->
    %% RFC 9113 §5.3.1: a stream cannot depend on itself —
    %% stream-error PROTOCOL_ERROR.
    _ = send_rst_stream(State, StreamId, protocol_error),
    frame_loop(State);
handle_frame({priority, _, _}, State) ->
    frame_loop(State);
handle_frame({rst_stream, StreamId, _}, #loop{streams = Streams} = State) ->
    case Streams of
        #{StreamId := _} ->
            frame_loop(reset_stream(State, StreamId));
        #{} ->
            %% RFC 9113 §5.1: RST_STREAM on an idle stream is
            %% PROTOCOL_ERROR (we never opened it). On a closed
            %% stream (id <= last_stream_id) the receipt is a no-op
            %% per §5.4 — it's the peer telling us about the
            %% already-closed lifecycle.
            case StreamId > State#loop.last_stream_id of
                true ->
                    _ = send_goaway(State, protocol_error),
                    exit_clean(State);
                false ->
                    frame_loop(State)
            end
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
    exit_clean(State);
handle_frame({unknown, _Type, _StreamId}, State) ->
    %% RFC 9113 §4.1: unknown frame types MUST be ignored. The
    %% awaiting_continuation guard above already rejected the
    %% mid-header-block case (§6.10), so reaching here is benign.
    frame_loop(State).

%% --- HEADERS / CONTINUATION ---

on_headers(StreamId, _Flags, #{stream_dependency := StreamId}, _Fragment, State) ->
    %% RFC 9113 §5.3.1: a stream cannot depend on itself —
    %% stream-error PROTOCOL_ERROR. We never enter the stream into
    %% the streams map since we're rejecting it.
    _ = send_rst_stream(State, StreamId, protocol_error),
    frame_loop(State);
on_headers(StreamId, _Flags, _Priority, _Fragment, State) when StreamId rem 2 =:= 0 ->
    %% RFC 9113 §5.1.1: client-initiated stream IDs are odd.
    _ = send_goaway(State, protocol_error),
    exit_clean(State);
on_headers(StreamId, Flags, _Priority, Fragment, #loop{streams = Streams} = State) when
    is_map_key(StreamId, Streams)
->
    %% HEADERS for an already-open stream — only valid as a
    %% trailer block per RFC 9113 §8.1: peer's first HEADERS
    %% must have been finalized (end_headers + decoded), the
    %% stream's body must be open (no END_STREAM yet), and the
    %% trailer HEADERS frame MUST set END_STREAM.
    #{StreamId := Stream} = Streams,
    case is_trailer_block(Stream, Flags) of
        true ->
            EndHeaders = (Flags band 16#04) =/= 0,
            Stream1 = Stream#{
                header_fragment := Fragment,
                end_headers := EndHeaders,
                end_stream_seen := true
            },
            State1 = update_stream(State, StreamId, Stream1),
            State2 =
                case EndHeaders of
                    true -> State1;
                    false -> State1#loop{awaiting_continuation = StreamId}
                end,
            case EndHeaders of
                true -> finalize_trailers(StreamId, State2);
                false -> frame_loop(State2)
            end;
        false ->
            _ = send_goaway(State, protocol_error),
            exit_clean(State)
    end;
on_headers(StreamId, _Flags, _Priority, _Fragment, State) when
    StreamId =< State#loop.last_stream_id
->
    %% RFC 9113 §5.1.1: stream IDs MUST monotonically increase.
    %% Receiving a HEADERS for a stream id we've already advanced
    %% past (without it being currently open) means the peer is
    %% trying to (re)open a closed stream — STREAM_CLOSED is the
    %% nominal stream error, but with an unknown stream we have
    %% no per-stream context to RST against, so treat as a
    %% connection error.
    _ = send_goaway(State, protocol_error),
    exit_clean(State);
on_headers(StreamId, _Flags, _Priority, _Fragment, #loop{draining = true} = State) ->
    %% In drain mode — refuse all new streams. The peer already
    %% saw GOAWAY(NO_ERROR); it knows new requests on this conn
    %% won't be served.
    _ = send_rst_stream(State, StreamId, refused_stream),
    frame_loop(State);
on_headers(StreamId, _Flags, _Priority, _Fragment, #loop{streams = Streams} = State) when
    map_size(Streams) >= ?MAX_CONCURRENT_STREAMS
->
    %% Over the advertised concurrency limit — refuse the stream.
    _ = send_rst_stream(State, StreamId, refused_stream),
    frame_loop(State);
on_headers(StreamId, Flags, _Priority, Fragment, State) ->
    EndHeaders = (Flags band 16#04) =/= 0,
    EndStream = (Flags band 16#01) =/= 0,
    Stream = new_stream(
        Fragment,
        EndHeaders,
        EndStream,
        State#loop.peer_initial_window,
        State#loop.stream_recv_window_peak
    ),
    State1 = State#loop{
        streams = (State#loop.streams)#{StreamId => Stream},
        last_stream_id = StreamId,
        awaiting_continuation =
            if
                EndHeaders -> undefined;
                true -> StreamId
            end
    },
    if
        EndHeaders -> finalize_headers(StreamId, State1);
        true -> frame_loop(State1)
    end.

new_stream(Fragment, EndHeaders, EndStream, SendWindow, RecvWindow) ->
    #{
        state => open,
        header_fragment => Fragment,
        end_headers => EndHeaders,
        end_stream_seen => EndStream,
        headers => undefined,
        body => [],
        body_len => 0,
        send_window => SendWindow,
        recv_window => RecvWindow,
        worker_pid => undefined,
        worker_ref => undefined,
        pending_sends => queue:new()
    }.

on_continuation(StreamId, Flags, Fragment, #loop{streams = Streams} = State) ->
    case Streams of
        #{
            StreamId :=
                #{
                    end_headers := false,
                    header_fragment := Existing,
                    headers := PriorHeaders
                } = Stream
        } ->
            Combined = <<Existing/binary, Fragment/binary>>,
            EndHeaders = (Flags band 16#04) =/= 0,
            Stream1 = Stream#{header_fragment := Combined, end_headers := EndHeaders},
            State1 = State#loop{streams = Streams#{StreamId := Stream1}},
            State2 =
                case EndHeaders of
                    true -> State1#loop{awaiting_continuation = undefined};
                    false -> State1
                end,
            case {EndHeaders, PriorHeaders =:= undefined} of
                {true, true} -> finalize_headers(StreamId, State2);
                {true, false} -> finalize_trailers(StreamId, State2);
                {false, _} -> frame_loop(State2)
            end;
        _ ->
            _ = send_goaway(State, protocol_error),
            exit_clean(State)
    end.

%% Decode an inbound trailer HPACK block. We currently drop the
%% decoded fields (handlers don't see request trailers yet) but
%% MUST advance the HPACK decoder context so subsequent header
%% blocks decode correctly. After consuming, dispatch the
%% pending request (END_STREAM was already set by `on_headers/5`).
finalize_trailers(StreamId, #loop{streams = Streams, hpack_dec = Dec} = State) ->
    #{StreamId := #{header_fragment := Fragment} = Stream} = Streams,
    case roadrunner_http2_hpack:decode(Fragment, Dec) of
        {ok, _Trailers, Dec1} ->
            Stream1 = Stream#{header_fragment := <<>>},
            State1 = State#loop{
                hpack_dec = Dec1,
                streams = Streams#{StreamId := Stream1}
            },
            dispatch_stream(StreamId, State1);
        {error, _} ->
            _ = send_goaway(State, protocol_error),
            exit_clean(State)
    end.

%% Decode the accumulated HPACK fragment, store decoded headers on
%% the stream entry. If END_STREAM was set on the HEADERS frame,
%% dispatch the worker now (no body); otherwise wait for DATA.
finalize_headers(StreamId, #loop{streams = Streams, hpack_dec = Dec} = State) ->
    #{
        StreamId := #{
            header_fragment := Fragment,
            end_stream_seen := EndStreamSeen
        } = Stream
    } = Streams,
    case roadrunner_http2_hpack:decode(Fragment, Dec) of
        {ok, Headers, Dec1} ->
            Stream1 = Stream#{headers := Headers, header_fragment := <<>>},
            State1 = State#loop{
                hpack_dec = Dec1,
                streams = Streams#{StreamId := Stream1}
            },
            case EndStreamSeen of
                true -> dispatch_stream(StreamId, State1);
                false -> frame_loop(State1)
            end;
        {error, _} ->
            _ = send_goaway(State, protocol_error),
            exit_clean(State)
    end.

%% --- DATA ---

on_data(StreamId, _Flags, _Payload, State) when StreamId > State#loop.last_stream_id ->
    %% RFC 9113 §5.1: DATA on an idle stream is PROTOCOL_ERROR.
    _ = send_goaway(State, protocol_error),
    exit_clean(State);
on_data(StreamId, _Flags, _Payload, #loop{streams = Streams} = State) when
    not is_map_key(StreamId, Streams)
->
    %% RFC 9113 §6.1: DATA on a closed stream is STREAM_CLOSED.
    %% In our setup the conn-level recv window has already been
    %% partially consumed by the peer's send so we still emit a
    %% RST_STREAM rather than ignoring.
    _ = send_rst_stream(State, StreamId, stream_closed),
    frame_loop(State);
on_data(StreamId, Flags, Payload, #loop{streams = Streams} = State) ->
    #{
        StreamId :=
            #{body := Body, body_len := Len, recv_window := RW} = Stream
    } = Streams,
    EndStream = (Flags band 16#01) =/= 0,
    PayloadLen = byte_size(Payload),
    Stream1 = Stream#{
        body := [Body, Payload],
        body_len := Len + PayloadLen,
        end_stream_seen := EndStream,
        recv_window := RW - PayloadLen
    },
    State1 = State#loop{
        streams = Streams#{StreamId := Stream1},
        conn_recv_window = State#loop.conn_recv_window - PayloadLen
    },
    State2 = maybe_refill_recv_windows(State1, StreamId),
    case EndStream of
        true -> dispatch_stream(StreamId, State2);
        false -> frame_loop(State2)
    end.

%% Refill the conn-level + stream-level recv windows whenever they
%% drop below `?WINDOW_REFILL_THRESHOLD`.
-spec maybe_refill_recv_windows(#loop{}, stream_id()) -> #loop{}.
maybe_refill_recv_windows(State, StreamId) ->
    State1 = maybe_refill_conn(State),
    maybe_refill_stream(State1, StreamId).

maybe_refill_conn(
    #loop{
        conn_recv_window = W,
        recv_window_peak = Peak,
        recv_window_threshold = Threshold
    } = State
) when W < Threshold ->
    Inc = Peak - W,
    _ = send(State, roadrunner_http2_frame:encode({window_update, 0, Inc})),
    State#loop{conn_recv_window = W + Inc};
maybe_refill_conn(State) ->
    State.

maybe_refill_stream(
    #loop{
        streams = Streams,
        stream_recv_window_peak = Peak,
        recv_window_threshold = Threshold
    } = State,
    StreamId
) ->
    #{StreamId := #{recv_window := W} = Stream} = Streams,
    if
        W < Threshold ->
            Inc = Peak - W,
            _ = send(
                State,
                roadrunner_http2_frame:encode({window_update, StreamId, Inc})
            ),
            State#loop{streams = Streams#{StreamId := Stream#{recv_window := W + Inc}}};
        true ->
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
    #{
        StreamId := #{
            headers := Headers,
            body_len := BodyLen,
            body := BodyIolist
        } = Stream
    } = Streams,
    case content_length_matches(Headers, BodyLen) of
        true ->
            %% Pass the iolist body straight through to the worker's
            %% Req map. The body field is typed `iodata()`; handlers
            %% that need a flat binary call `iolist_to_binary/1`.
            {RequestId, NewBuf} = roadrunner_conn:generate_request_id(
                State#loop.req_id_buffer
            ),
            ConnInfo = #{
                peer => Peer,
                scheme => Scheme,
                listener_name => ListenerName,
                request_id => RequestId
            },
            case roadrunner_http2_request:from_headers(Headers, BodyIolist, ConnInfo) of
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
                        streams = Streams#{StreamId := Stream1},
                        worker_refs = (State#loop.worker_refs)#{MonRef => StreamId},
                        req_id_buffer = NewBuf
                    },
                    frame_loop(State1);
                {error, _Reason} ->
                    _ = send_rst_stream(State, StreamId, protocol_error),
                    frame_loop(remove_stream(State#loop{req_id_buffer = NewBuf}, StreamId))
            end;
        false ->
            %% RFC 9113 §8.1.2.6: content-length / DATA-payload
            %% mismatch is a stream-error PROTOCOL_ERROR.
            _ = send_rst_stream(State, StreamId, protocol_error),
            frame_loop(remove_stream(State, StreamId))
    end.

%% Verify that any client-supplied `content-length` header matches
%% the cumulative bytes received in DATA frames. Absent header is
%% always acceptable; multi-valued or non-integer values are
%% rejected as mismatches.
%% Single-pass walk: find the first (and check there isn't a
%% second) `content-length` header value, then compare against
%% `BodyLen`. Avoids the per-request list-comprehension allocation
%% the prior shape paid even when no `content-length` was present.
-spec content_length_matches([{binary(), binary()}], non_neg_integer()) -> boolean().
content_length_matches(Headers, BodyLen) ->
    case find_content_length(Headers, undefined) of
        none ->
            true;
        multiple ->
            false;
        V ->
            try binary_to_integer(V) of
                BodyLen -> true;
                _ -> false
            catch
                error:badarg -> false
            end
    end.

find_content_length([], undefined) -> none;
find_content_length([], V) -> V;
find_content_length([{~"content-length", _} | _], V) when V =/= undefined -> multiple;
find_content_length([{~"content-length", V} | Rest], undefined) -> find_content_length(Rest, V);
find_content_length([_ | Rest], V) -> find_content_length(Rest, V).

%% =============================================================================
%% Worker → conn message handlers
%% =============================================================================

%% Single-shot buffered-response path. Encodes HEADERS + (optional)
%% DATA(END_STREAM) and writes them in ONE `ssl:send/2`, halving
%% the per-response gen_call cost through `tls_sender`. Falls back
%% to the two-frame two-message path when the body doesn't fit a
%% single DATA frame AND the current window — the worker still
%% sees one ack at the end of the data send.
handle_send_response(State, From, Ref, StreamId, Status, Headers, <<>>) ->
    %% Empty body — same wire shape as `handle_send_headers` with
    %% `EndStream = true` (single HEADERS frame, END_STREAM bit set).
    case stream_open(State, StreamId) of
        not_open ->
            _ = (From ! {h2_stream_reset, StreamId}),
            State;
        _Stream ->
            State1 = encode_and_send_headers(State, StreamId, Status, Headers, true),
            _ = (From ! {h2_send_ack, Ref}),
            State1
    end;
handle_send_response(State, From, Ref, StreamId, Status, Headers, Body) ->
    case stream_open(State, StreamId) of
        not_open ->
            _ = (From ! {h2_stream_reset, StreamId}),
            State;
        Stream ->
            BodyLen = byte_size(Body),
            %% Short-circuit: skip the `window_budget/2` lookup when the
            %% body already won't fit in one frame.
            case BodyLen =< ?MAX_FRAME_SIZE andalso window_budget(State, Stream) >= BodyLen of
                true ->
                    State1 = encode_and_send_response_atomic(
                        State, StreamId, Status, Headers, Body
                    ),
                    _ = (From ! {h2_send_ack, Ref}),
                    State1;
                false ->
                    %% Body too big for one frame OR window too narrow —
                    %% emit HEADERS now, hand the body to `try_send_data`
                    %% which fragments / queues + acks the worker on
                    %% completion.
                    State1 = encode_and_send_headers(
                        State, StreamId, Status, Headers, false
                    ),
                    #{StreamId := Stream1} = State1#loop.streams,
                    try_send_data(State1, Stream1, StreamId, From, Ref, Body, true)
            end
    end.

handle_send_headers(State, From, Ref, StreamId, Status, Headers, EndStream) ->
    case stream_open(State, StreamId) of
        not_open ->
            _ = (From ! {h2_stream_reset, StreamId}),
            State;
        _Stream ->
            State1 = encode_and_send_headers(State, StreamId, Status, Headers, EndStream),
            _ = (From ! {h2_send_ack, Ref}),
            State1
    end.

handle_send_data(State, From, Ref, StreamId, Bin, EndStream) ->
    case stream_open(State, StreamId) of
        not_open ->
            _ = (From ! {h2_stream_reset, StreamId}),
            State;
        Stream ->
            try_send_data(State, Stream, StreamId, From, Ref, Bin, EndStream)
    end.

handle_send_trailers(State, From, Ref, StreamId, Trailers) ->
    case stream_open(State, StreamId) of
        not_open ->
            _ = (From ! {h2_stream_reset, StreamId}),
            State;
        _Stream ->
            State1 = encode_and_send_trailers(State, StreamId, Trailers),
            _ = (From ! {h2_send_ack, Ref}),
            State1
    end.

handle_worker_done(State, StreamId) ->
    %% The worker exits after this message; the DOWN cleanup will
    %% remove the stream. Nothing to do here.
    _ = StreamId,
    State.

handle_worker_down(#loop{worker_refs = Refs} = State, MonRef, Reason) ->
    case Refs of
        #{MonRef := StreamId} ->
            State1 = State#loop{worker_refs = maps:remove(MonRef, Refs)},
            case Reason of
                normal -> remove_stream(State1, StreamId);
                _ -> abort_stream(State1, StreamId, internal_error)
            end;
        #{} ->
            State
    end.

%% Look up a stream that has not yet been reset / closed. Returns
%% `not_open` for streams the conn has already torn down (peer
%% RST_STREAM, write of END_STREAM completed, etc.) — workers
%% asking to write to those should be told to abort.
%% Returns the stream entry map directly on hit, or the atom
%% `not_open` if the stream is gone or its send side is already
%% closed. The two return shapes are disjoint (map vs. atom) so
%% callers can pattern-match without an `{ok, _}` wrapper.
stream_open(#loop{streams = Streams}, StreamId) ->
    case Streams of
        #{StreamId := #{state := closed}} -> not_open;
        #{StreamId := Stream} -> Stream;
        #{} -> not_open
    end.

%% Encode + write a HEADERS frame (always fits without flow control;
%% the wire just takes it).
encode_and_send_headers(
    #loop{hpack_enc = Enc} = State, StreamId, Status, Headers, EndStream
) ->
    StatusBin = integer_to_binary(Status),
    %% Handler-supplied header names MUST already be lowercase per RFC 9113
    %% §8.1.2 (see `roadrunner_handler:response/0`). Bytes outside the
    %% RFC 9110 §5.5 field-value charset (CR/LF/NUL) crash here so the
    %% h2 path matches h1's `encode_headers/1` discipline.
    ok = validate_headers(Headers),
    AllHeaders = [{~":status", StatusBin} | Headers],
    {HpackBlock, Enc1} = roadrunner_http2_hpack:encode(AllHeaders, Enc),
    %% `frame:encode` accepts iodata for the header block — skip
    %% the upfront flatten; ssl:send walks the iolist anyway.
    Flags =
        if
            EndStream -> 16#04 bor 16#01;
            true -> 16#04
        end,
    Frame = roadrunner_http2_frame:encode({headers, StreamId, Flags, undefined, HpackBlock}),
    _ = send(State, Frame),
    State1 = State#loop{hpack_enc = Enc1},
    if
        EndStream -> close_stream_send_side(State1, StreamId);
        true -> State1
    end.

%% HEADERS + DATA (END_STREAM) packed into ONE `ssl:send/2`.
%% Caller has already verified `byte_size(Body)` fits in a single
%% DATA frame AND in the current send window. Consumes the window
%% by `byte_size(Body)` and marks the stream's send side closed.
encode_and_send_response_atomic(
    #loop{hpack_enc = Enc, streams = Streams} = State,
    StreamId,
    Status,
    Headers,
    Body
) ->
    #{StreamId := Stream} = Streams,
    StatusBin = integer_to_binary(Status),
    %% Names already lowercase per `roadrunner_handler:response/0` contract;
    %% reject CR/LF/NUL anywhere in the pair so they cannot reach the peer
    %% or split at an h2->h1 reverse proxy.
    ok = validate_headers(Headers),
    AllHeaders = [{~":status", StatusBin} | Headers],
    {HpackBlock, Enc1} = roadrunner_http2_hpack:encode(AllHeaders, Enc),
    HFrame = roadrunner_http2_frame:encode(
        {headers, StreamId, 16#04, undefined, HpackBlock}
    ),
    DFrame = roadrunner_http2_frame:encode({data, StreamId, 16#01, Body}),
    _ = send(State, [HFrame, DFrame]),
    State1 = State#loop{hpack_enc = Enc1},
    State2 = consume_send_window(State1, StreamId, Stream, byte_size(Body)),
    close_stream_send_side(State2, StreamId).

encode_and_send_trailers(#loop{hpack_enc = Enc} = State, StreamId, Trailers) ->
    %% Trailer names already lowercase per `roadrunner_handler:response/0`;
    %% h1 trailers run the same check in `roadrunner_stream_response`.
    ok = validate_headers(Trailers),
    {HpackBlock, Enc1} = roadrunner_http2_hpack:encode(Trailers, Enc),
    Frame = roadrunner_http2_frame:encode(
        {headers, StreamId, 16#04 bor 16#01, undefined, HpackBlock}
    ),
    _ = send(State, Frame),
    State1 = State#loop{hpack_enc = Enc1},
    close_stream_send_side(State1, StreamId).

%% RFC 9110 §5.5 / RFC 9113 §8.2.1: field values are VCHAR / SP /
%% HTAB only; no CTLs. HPACK is length-framed so CR/LF cannot smuggle
%% a new h2 frame, but malformed bytes still reach the peer (and any
%% downstream h2->h1 reverse proxy where they would split). Crash
%% hard so a handler echoing user input into a header turns into a
%% 500, matching `roadrunner_http1:encode_headers/1`.
-spec validate_headers([{binary(), binary()}]) -> ok.
validate_headers([]) ->
    ok;
validate_headers([{Name, Value} | Rest]) ->
    ok = roadrunner_http1:check_header_safe(Name, name),
    ok = roadrunner_http1:check_header_safe(Value, value),
    validate_headers(Rest).

%% Mark the send side closed. Future worker writes on this stream
%% get `{h2_stream_reset, _}` so they unwind cleanly.
close_stream_send_side(#loop{streams = Streams} = State, StreamId) ->
    #{StreamId := Stream} = Streams,
    State#loop{streams = Streams#{StreamId := Stream#{state := closed}}}.

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
                if
                    EndStream -> 16#01;
                    true -> 0
                end,
            Frame = roadrunner_http2_frame:encode({data, StreamId, Flags, Bin}),
            _ = send(State, Frame),
            State1 = consume_send_window(State, StreamId, Stream, N),
            _ = (From ! {h2_send_ack, Ref}),
            if
                EndStream -> close_stream_send_side(State1, StreamId);
                true -> State1
            end;
        N ->
            <<Chunk:N/binary, Rest/binary>> = Bin,
            Frame = roadrunner_http2_frame:encode({data, StreamId, 0, Chunk}),
            _ = send(State, Frame),
            State1 = consume_send_window(State, StreamId, Stream, N),
            #{StreamId := Stream1} = State1#loop.streams,
            send_data_chunks(State1, Stream1, StreamId, From, Ref, Rest, EndStream)
    end.

window_budget(#loop{conn_send_window = ConnW}, #{send_window := StreamW}) ->
    max(0, min(ConnW, StreamW)).

consume_send_window(
    #loop{conn_send_window = ConnW, streams = Streams} = State, StreamId, Stream, N
) ->
    #{send_window := SW} = Stream,
    Stream1 = Stream#{send_window := SW - N},
    State#loop{
        conn_send_window = ConnW - N,
        streams = Streams#{StreamId := Stream1}
    }.

enqueue_pending(#{pending_sends := Pending} = Stream, Entry) ->
    Stream#{pending_sends := queue:in(Entry, Pending)}.

%% After a stream's send window grew, drain its pending DATA queue
%% as far as windows allow.
flush_pending_data(#loop{streams = Streams} = State, StreamId) ->
    #{StreamId := #{pending_sends := Pending} = Stream} = Streams,
    case queue:is_empty(Pending) of
        true -> State;
        false -> drain_pending(State, StreamId, Stream)
    end.

%% After the conn-level send window grew, drain every stream's
%% pending queue. We iterate keys (not values) — `flush_pending_data`
%% re-fetches the stream from the post-iteration state which may
%% already be mutated by a prior drain.
flush_all_pending_data(#loop{streams = Streams} = State) ->
    lists:foldl(
        fun(StreamId, AccState) -> flush_pending_data(AccState, StreamId) end,
        State,
        maps:keys(Streams)
    ).

%% Drain queued sends on a single stream until either the queue is
%% empty or the window forces us to stop again.
drain_pending(State, StreamId, #{pending_sends := Pending} = Stream) ->
    case queue:out(Pending) of
        {empty, _} ->
            State;
        {{value, Entry}, Rest} ->
            {data, Ref, From, Bin, EndStream} = Entry,
            Stream1 = Stream#{pending_sends := Rest},
            State1 = update_stream(State, StreamId, Stream1),
            State2 = try_send_data(State1, Stream1, StreamId, From, Ref, Bin, EndStream),
            #{StreamId := #{pending_sends := Pending2} = Stream2} = State2#loop.streams,
            case queue:peek(Pending2) of
                {value, Entry} ->
                    %% Same entry re-queued: window still closed.
                    State2;
                _ ->
                    drain_pending(State2, StreamId, Stream2)
            end
    end.

%% =============================================================================
%% Stream lifecycle helpers
%% =============================================================================

update_stream(#loop{streams = Streams} = State, StreamId, Stream) ->
    State#loop{streams = Streams#{StreamId := Stream}}.

%% Peer sent RST_STREAM for a stream we have alive. Tell the worker
%% (if any) to bail, then drop our stream entry. Pending sends get
%% reset notifications so workers waiting on `h2_send_ack` unwind.
reset_stream(#loop{streams = Streams, worker_refs = Refs} = State, StreamId) ->
    #{
        StreamId := #{
            pending_sends := Pending,
            worker_pid := WorkerPid,
            worker_ref := WorkerRef
        }
    } = Streams,
    notify_pending_reset(StreamId, Pending),
    Refs1 =
        case WorkerRef of
            undefined ->
                %% RST landed before END_STREAM dispatched a worker.
                Refs;
            MonRef ->
                _ = (WorkerPid ! {h2_stream_reset, StreamId}),
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
    #{StreamId := #{pending_sends := Pending}} = Streams,
    notify_pending_reset(StreamId, Pending),
    _ = send_rst_stream(State, StreamId, ErrorCode),
    State#loop{streams = maps:remove(StreamId, Streams)}.

%% Worker exited normally (handler done, all frames already on the
%% wire). Just drop state.
remove_stream(#loop{streams = Streams} = State, StreamId) ->
    State#loop{streams = maps:remove(StreamId, Streams)}.

notify_pending_reset(StreamId, Pending) ->
    case queue:out(Pending) of
        {empty, _} ->
            ok;
        {{value, {data, _Ref, From, _Bin, _Es}}, Rest} ->
            _ = (From ! {h2_stream_reset, StreamId}),
            notify_pending_reset(StreamId, Rest)
    end.

%% =============================================================================
%% Generic helpers
%% =============================================================================

%% A second HEADERS frame on an already-open stream is only valid
%% as a trailer block (RFC 9113 §8.1): the body must still be
%% open (no END_STREAM seen yet) and the trailer HEADERS frame
%% MUST set END_STREAM. We don't need to check `headers =/=
%% undefined` because the only path into here is a duplicate
%% HEADERS for a stream where the first HEADERS had END_HEADERS=true
%% (otherwise the awaiting_continuation guard fires upstream),
%% which guarantees `finalize_headers/2` has already run.
-spec is_trailer_block(map(), non_neg_integer()) -> boolean().
is_trailer_block(#{end_stream_seen := true}, _Flags) ->
    false;
is_trailer_block(_Stream, Flags) ->
    (Flags band 16#01) =/= 0.

%% RFC 9113 §6.9.2: when peer changes INITIAL_WINDOW_SIZE we shift
%% every open stream's send window by the delta. Overflow on any
%% stream is FLOW_CONTROL_ERROR (connection error). New streams
%% use the latest value via `peer_initial_window`.
-spec apply_initial_window_size(
    [{non_neg_integer(), non_neg_integer()}], #loop{}
) -> {ok, #loop{}} | {error, flow_control_error}.
apply_initial_window_size(Params, #loop{peer_initial_window = Old} = State) ->
    %% RFC 9113 §6.5.3: when SETTINGS contains the same id more
    %% than once, the LAST value wins. Walk in order and keep the
    %% last `{4, V}` we see — single pass, no list-comp + reverse.
    case last_setting(Params, 4, undefined) of
        undefined ->
            {ok, State};
        New ->
            Delta = New - Old,
            case shift_stream_send_windows(State#loop.streams, Delta) of
                {ok, Streams1} ->
                    {ok, State#loop{
                        peer_initial_window = New,
                        streams = Streams1
                    }};
                {error, _} = E ->
                    E
            end
    end.

last_setting([], _Id, V) -> V;
last_setting([{Id, V} | Rest], Id, _) -> last_setting(Rest, Id, V);
last_setting([_ | Rest], Id, V) -> last_setting(Rest, Id, V).

%% Map-comprehension shift across the streams map (OTP 28+). A
%% single overflow short-circuits via `throw/1` — cleaner than
%% threading a Result tuple through the comprehension.
shift_stream_send_windows(Streams, Delta) ->
    try
        Streams1 =
            #{
                Id => Stream#{send_window := check_window(SW + Delta)}
             || Id := #{send_window := SW} = Stream <- Streams
            },
        {ok, Streams1}
    catch
        throw:flow_control_error ->
            {error, flow_control_error}
    end.

check_window(W) when W > ?MAX_WINDOW -> throw(flow_control_error);
check_window(W) -> W.

%% Validate the per-id constraints on incoming SETTINGS values per
%% RFC 9113 §6.5.2: ENABLE_PUSH ∈ {0,1}, INITIAL_WINDOW_SIZE
%% ≤ 2^31-1, MAX_FRAME_SIZE ∈ [2^14, 2^24-1]. Other ids carry no
%% range constraints (or are forward-compat unknowns we ignore).
-spec validate_settings([{non_neg_integer(), non_neg_integer()}]) ->
    ok | {error, {protocol_error | flow_control_error, atom()}}.
validate_settings([]) ->
    ok;
validate_settings([{2, V} | _]) when V =/= 0, V =/= 1 ->
    {error, {protocol_error, enable_push_value}};
validate_settings([{4, V} | _]) when V > 16#7FFFFFFF ->
    {error, {flow_control_error, initial_window_size}};
validate_settings([{5, V} | _]) when V < 16384; V > 16#FFFFFF ->
    {error, {protocol_error, max_frame_size}};
validate_settings([_ | Rest]) ->
    validate_settings(Rest).

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
