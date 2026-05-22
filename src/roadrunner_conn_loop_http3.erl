-module(roadrunner_conn_loop_http3).
-moduledoc false.

%% HTTP/3 connection owner loop (RFC 9114) — the h3 analogue of
%% `roadrunner_conn_loop_http2`. One process per QUIC connection,
%% spawned by `roadrunner_listener`'s `connection_handler` and made the
%% connection owner by the QUIC listener.
%%
%% roadrunner owns this loop and applies its own rules (slot tracking,
%% drain group, telemetry, dispatch, response shapes, crash isolation);
%% the `quic` dependency provides the transport (`quic` / `quic_listener`
%% drive the UDP socket + QUIC streams) and the codec helpers
%% (`quic_h3_frame` for framing, `quic_qpack` for QPACK). The turnkey
%% `quic_h3` server is deliberately not used.
%%
%% The loop receives QUIC stream events as messages from the connection
%% process:
%%
%%   {quic, Conn, {connected, Info}}            handshake complete
%%   {quic, Conn, {stream_opened, StreamId}}    peer opened a stream
%%   {quic, Conn, {stream_data, StreamId, Bin, Fin}}
%%   {quic, Conn, {stream_reset, StreamId, ErrorCode}}
%%   {quic, Conn, {closed, Reason}}             connection closed
%%
%% On `connected` it opens its own control stream and sends SETTINGS
%% (advertising `qpack_max_table_capacity = 0`, so QPACK runs
%% static-table only — no dynamic-table encoder/decoder state). Request
%% streams (client-initiated bidirectional, `StreamId rem 4 =:= 0`)
%% accumulate HEADERS + DATA frames; on the stream FIN a per-stream
%% `roadrunner_http3_stream_worker` is spawned to dispatch the request
%% and write the response. Peer-initiated unidirectional streams
%% (control / QPACK, `rem 4 =:= 2`) are ignored: with a zero QPACK
%% table there are no encoder/decoder instructions to apply, and the
%% peer's SETTINGS carry nothing this server depends on.
%%
%% Streaming response shapes (`stream` / `loop` / `sendfile`) and
%% WebSocket-over-h3 are phase-2 and answer 501 for now (in the worker).

-export([start/2]).
-export([init/2]).
%% Exported for unit testing of the pure request-stream frame folding;
%% not part of any public surface.
-export([decode_request_frames/3, set_header_block/2, new_request_stream/0]).

%% RFC 9114 §8.1 / RFC 9204 §8.3 error codes.
-define(H3_NO_ERROR, 16#0100).
-define(H3_INTERNAL_ERROR, 16#0102).
-define(H3_FRAME_UNEXPECTED, 16#0105).
-define(H3_FRAME_ERROR, 16#0106).
-define(H3_MESSAGE_ERROR, 16#010E).
-define(H3_QPACK_DECOMPRESSION_FAILED, 16#0200).

-record(h3, {
    conn :: pid(),
    proto_opts :: roadrunner_conn:proto_opts(),
    listener_name :: atom(),
    peer :: {inet:ip_address(), inet:port_number()} | undefined,
    start_mono :: integer(),
    %% Pre-generated CSPRNG bytes for `request_id`, sliced 8 at a time
    %% and refilled by `roadrunner_conn:generate_request_id/1`.
    req_id_buffer = <<>> :: binary(),
    %% StreamId => in-progress request stream (see `new_request_stream/0`).
    streams = #{} :: #{non_neg_integer() => map()},
    %% Worker monitor ref => StreamId, for correlating `'DOWN'`.
    worker_refs = #{} :: #{reference() => non_neg_integer()},
    max_content_length :: non_neg_integer()
}).

-doc """
Spawn the connection-owner loop for a freshly accepted QUIC
connection. Called from the QUIC listener's `connection_handler` (in
the listener's process), so it just spawns and returns the pid — the
QUIC listener then transfers connection ownership to it. Unlinked so a
connection crash never reaches the listener.
""".
-spec start(pid(), roadrunner_conn:proto_opts()) -> {ok, pid()}.
start(ConnPid, ProtoOpts) ->
    {ok, proc_lib:spawn(?MODULE, init, [ConnPid, ProtoOpts])}.

-doc false.
-spec init(pid(), roadrunner_conn:proto_opts()) -> ok.
init(Conn, ProtoOpts) ->
    ListenerName = maps:get(listener_name, ProtoOpts),
    proc_lib:set_label({roadrunner_conn_loop_http3, ListenerName, Conn}),
    case roadrunner_conn:try_acquire_slot(ProtoOpts) of
        false ->
            %% Over `max_clients` — refuse by closing the connection.
            %% `try_acquire_slot/1` already rolled the counter back.
            _ = quic:close(Conn),
            ok;
        true ->
            DrainGroup = maps:get(graceful_drain, ProtoOpts, true),
            ok = roadrunner_conn:join_drain_group(ListenerName, DrainGroup),
            %% Share fate with the QUIC connection process: if it dies
            %% abnormally (without a `closed` event) the loop dies too,
            %% rather than hanging. The slot then leaks until slot
            %% reconciliation reaps it, the same bound h1/h2 carry for a
            %% `kill`-ed conn. The graceful path releases it in
            %% `terminate/1` on the `closed` event.
            true = link(Conn),
            %% `remote_addr` is set at connection creation, so peername
            %% is available from the start (idle / handshaking states).
            {ok, Peer} = quic:peername(Conn),
            StartMono = roadrunner_telemetry:listener_accept(#{
                listener_name => ListenerName, peer => Peer
            }),
            loop(#h3{
                conn = Conn,
                proto_opts = ProtoOpts,
                listener_name = ListenerName,
                peer = Peer,
                start_mono = StartMono,
                max_content_length = maps:get(max_content_length, ProtoOpts)
            })
    end.

-spec loop(#h3{}) -> ok.
loop(#h3{conn = Conn} = State) ->
    receive
        {quic, Conn, {connected, _Info}} ->
            loop(send_control_stream(State));
        {quic, Conn, {stream_opened, _StreamId}} ->
            loop(State);
        {quic, Conn, {stream_data, StreamId, Data, Fin}} ->
            case handle_stream_data(State, StreamId, Data, Fin) of
                {conn_error, Code, Reason} -> close_connection(State, Code, Reason);
                State1 -> loop(State1)
            end;
        {quic, Conn, {stream_reset, StreamId, _ErrorCode}} ->
            loop(drop_stream(State, StreamId));
        {quic, Conn, {closed, _Reason}} ->
            terminate(State);
        {'DOWN', MonRef, process, _Pid, Reason} ->
            loop(handle_worker_down(State, MonRef, Reason));
        {roadrunner_drain, _Deadline} ->
            %% Phase 1: buffered requests are short-lived, so keep
            %% serving. The listener force-exits us at the deadline if
            %% the connection is still up.
            loop(State);
        _Other ->
            loop(State)
    end.

%% Open the server control stream and send SETTINGS on the `connected`
%% event (RFC 9114 §6.2.1: each side opens one control stream and sends
%% SETTINGS as its first frame). Ownership transfers in the handshaking
%% state, so `connected` is delivered to this loop exactly once. The
%% control stream stays open (no FIN) for the connection's lifetime.
-spec send_control_stream(#h3{}) -> #h3{}.
send_control_stream(#h3{conn = Conn} = State) ->
    {ok, CtrlStreamId} = quic:open_unidirectional_stream(Conn),
    Prefix = quic_h3_frame:encode_stream_type(control),
    Settings = quic_h3_frame:encode_settings(#{
        qpack_max_table_capacity => 0,
        qpack_blocked_streams => 0
    }),
    ok = quic:send_data(Conn, CtrlStreamId, [Prefix, Settings], false),
    State.

-type handle_result() :: #h3{} | {conn_error, non_neg_integer(), binary()}.

-spec handle_stream_data(#h3{}, non_neg_integer(), binary(), boolean()) -> handle_result().
handle_stream_data(State, StreamId, Data, Fin) ->
    case StreamId rem 4 of
        %% Client-initiated bidirectional stream — an HTTP/3 request.
        0 -> handle_request_stream(State, StreamId, Data, Fin);
        %% Client-initiated unidirectional (control / QPACK) — ignored
        %% (see moduledoc); server-initiated ids never carry peer data.
        _ -> State
    end.

-spec handle_request_stream(#h3{}, non_neg_integer(), binary(), boolean()) -> handle_result().
handle_request_stream(
    #h3{streams = Streams, max_content_length = MaxLen} = State, StreamId, Data, Fin
) ->
    %% Only in-progress (still-accumulating) streams live in the map;
    %% `dispatch_request` removes a stream once it's handed to a worker,
    %% and QUIC never delivers data after a stream's FIN, so a stream
    %% seen here is always mid-accumulation.
    #{buf := Buf0} = Stream0 = maps:get(StreamId, Streams, new_request_stream()),
    case decode_request_frames(<<Buf0/binary, Data/binary>>, Stream0, MaxLen) of
        {ok, Stream1} ->
            State1 = State#h3{streams = Streams#{StreamId => Stream1}},
            case Fin of
                true -> dispatch_request(State1, StreamId);
                false -> State1
            end;
        too_large ->
            ok = roadrunner_http3_stream_worker:send_buffered(
                State#h3.conn,
                StreamId,
                413,
                [{~"content-type", ~"text/plain"}],
                ~"Payload Too Large"
            ),
            %% Abort the client's upload and drop the stream. Keeping a
            %% "done" marker would leak: QUIC retires the completed
            %% stream (returning credit) but a map entry would persist
            %% for the connection's lifetime, so repeated oversized
            %% requests grow it without bound. `stop_sending` tells the
            %% client to stop, so trailing DATA doesn't re-trigger a 413.
            _ = quic:stop_sending(State#h3.conn, StreamId, ?H3_NO_ERROR),
            drop_stream(State, StreamId);
        {error, Reason} ->
            %% A frame-level decode failure is a connection error per
            %% RFC 9114 §7.1 (malformed/oversized frame) and §7.2.8
            %% (HTTP/2-reserved frame type).
            {conn_error, frame_error_code(Reason), ~"frame error"}
    end.

%% RFC 9114 §7.2.8: HTTP/2-reserved frame types → H3_FRAME_UNEXPECTED;
%% other malformed/oversized frames (§7.1) → H3_FRAME_ERROR.
-spec frame_error_code(term()) -> non_neg_integer().
frame_error_code({h2_reserved_frame, _}) -> ?H3_FRAME_UNEXPECTED;
frame_error_code(_) -> ?H3_FRAME_ERROR.

-spec new_request_stream() -> map().
new_request_stream() ->
    #{buf => <<>>, header_block => undefined, body => [], body_len => 0}.

%% Decode as many complete HTTP/3 frames as the buffer holds, folding
%% them into the stream's accumulated request. The undecoded remainder
%% is stashed back in `buf` for the next `stream_data` message.
-spec decode_request_frames(binary(), map(), non_neg_integer()) ->
    {ok, map()} | too_large | {error, term()}.
decode_request_frames(Buf, Stream, MaxLen) ->
    case quic_h3_frame:decode(Buf) of
        {ok, {headers, Block}, Rest} ->
            decode_request_frames(Rest, set_header_block(Stream, Block), MaxLen);
        {ok, {data, Payload}, Rest} ->
            #{body := Body, body_len := Len} = Stream,
            NewLen = Len + byte_size(Payload),
            case NewLen > MaxLen of
                true ->
                    too_large;
                false ->
                    decode_request_frames(
                        Rest, Stream#{body := [Body, Payload], body_len := NewLen}, MaxLen
                    )
            end;
        {ok, _Ignored, Rest} ->
            %% SETTINGS / GOAWAY / unknown / grease on a request stream —
            %% not meaningful to a buffered request; skip.
            decode_request_frames(Rest, Stream, MaxLen);
        {more, _} ->
            {ok, Stream#{buf := Buf}};
        {error, _} = Error ->
            Error
    end.

%% Keep the first HEADERS block as the request headers; a later HEADERS
%% frame is trailers, which the buffered path does not surface.
-spec set_header_block(map(), binary()) -> map().
set_header_block(#{header_block := undefined} = Stream, Block) ->
    Stream#{header_block := Block};
set_header_block(Stream, _Block) ->
    Stream.

-spec dispatch_request(#h3{}, non_neg_integer()) -> handle_result().
dispatch_request(#h3{streams = Streams} = State, StreamId) ->
    case maps:get(StreamId, Streams) of
        #{header_block := undefined} ->
            %% Stream ended with no HEADERS frame — a malformed message
            %% (RFC 9114 §4.1): stream error H3_MESSAGE_ERROR.
            reset_and_drop(State, StreamId, ?H3_MESSAGE_ERROR);
        #{header_block := Block, body := Body} ->
            %% QPACK decode happens here (not in the worker) because a
            %% decompression failure is a CONNECTION error per RFC 9204
            %% §2.2 — the dynamic-table state is unrecoverable — whereas
            %% a malformed message is a per-stream error.
            case quic_qpack:decode(Block) of
                {error, _} ->
                    {conn_error, ?H3_QPACK_DECOMPRESSION_FAILED, ~"QPACK decompression failed"};
                {ok, Headers} ->
                    dispatch_decoded(State, StreamId, Headers, Body)
            end
    end.

-spec dispatch_decoded(#h3{}, non_neg_integer(), roadrunner_http:headers(), iodata()) ->
    handle_result().
dispatch_decoded(#h3{streams = Streams} = State, StreamId, Headers, Body) ->
    {ReqId, NewBuf} = roadrunner_conn:generate_request_id(State#h3.req_id_buffer),
    RequestContext = #{
        peer => State#h3.peer,
        scheme => https,
        listener_name => State#h3.listener_name,
        request_id => ReqId
    },
    State1 = State#h3{req_id_buffer = NewBuf},
    case roadrunner_http3_request:from_headers(Headers, Body, RequestContext) of
        {error, _} ->
            %% Malformed request (bad/missing pseudo-headers, a
            %% connection-specific header) — RFC 9114 §4.1.2 / §4.2:
            %% stream error H3_MESSAGE_ERROR.
            reset_and_drop(State1, StreamId, ?H3_MESSAGE_ERROR);
        {ok, Req} ->
            {_WorkerPid, MonRef} = roadrunner_http3_stream_worker:start(
                State1#h3.conn, StreamId, Req, State1#h3.proto_opts
            ),
            %% The worker owns the response now, tracked by its monitor
            %% ref; drop the (no-longer-needed) frame-accumulation entry
            %% so the streams map only ever holds in-progress requests.
            State1#h3{
                streams = maps:remove(StreamId, Streams),
                worker_refs = (State1#h3.worker_refs)#{MonRef => StreamId}
            }
    end.

%% A worker exit: normal means it sent its response with the stream FIN
%% (drop the stream); abnormal (QPACK decompression, malformed
%% pseudo-headers, response encoding) resets the stream, leaving the
%% connection's other streams untouched.
-spec handle_worker_down(#h3{}, reference(), term()) -> #h3{}.
handle_worker_down(#h3{worker_refs = WorkerRefs} = State, MonRef, Reason) ->
    %% Every monitor the loop holds is a stream worker (the QUIC conn is
    %% linked, not monitored), so the ref is always present.
    {StreamId, WorkerRefs1} = maps:take(MonRef, WorkerRefs),
    State1 = State#h3{worker_refs = WorkerRefs1},
    case Reason of
        normal ->
            drop_stream(State1, StreamId);
        _ ->
            %% A worker that died after dispatch is a genuine internal
            %% failure (e.g. a response-encoding crash) — H3_INTERNAL_ERROR.
            reset_and_drop(State1, StreamId, ?H3_INTERNAL_ERROR)
    end.

-spec reset_and_drop(#h3{}, non_neg_integer(), non_neg_integer()) -> #h3{}.
reset_and_drop(#h3{conn = Conn} = State, StreamId, ErrorCode) ->
    _ = quic:reset_stream(Conn, StreamId, ErrorCode),
    drop_stream(State, StreamId).

%% A connection error (RFC 9114 §8): close the QUIC connection with the
%% h3 error code + reason, then run the normal teardown. The peer sees
%% CONNECTION_CLOSE; the linked conn process stopping ends this loop too,
%% but we tear down explicitly so the slot is released and telemetry
%% fires regardless.
-spec close_connection(#h3{}, non_neg_integer(), binary()) -> ok.
close_connection(#h3{conn = Conn} = State, ErrorCode, Reason) ->
    _ = quic:close(Conn, ErrorCode, Reason),
    terminate(State).

-spec drop_stream(#h3{}, non_neg_integer()) -> #h3{}.
drop_stream(#h3{streams = Streams} = State, StreamId) ->
    State#h3{streams = maps:remove(StreamId, Streams)}.

-spec terminate(#h3{}) -> ok.
terminate(#h3{
    proto_opts = ProtoOpts, listener_name = ListenerName, peer = Peer, start_mono = StartMono
}) ->
    ok = roadrunner_telemetry:listener_conn_close(StartMono, #{
        listener_name => ListenerName,
        peer => Peer,
        requests_served => 0
    }),
    ok = roadrunner_conn:release_slot(ProtoOpts).
