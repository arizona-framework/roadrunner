-module(roadrunner_conn_loop_http3).
-moduledoc false.

%% HTTP/3 connection owner loop (RFC 9114) — the h3 analogue of
%% `roadrunner_conn_loop_http2`. One process per QUIC connection,
%% spawned by `roadrunner_listener`'s `connection_handler` and made the
%% connection owner by the QUIC listener.
%%
%% roadrunner owns this loop and applies its own rules (slot tracking,
%% drain group, telemetry, dispatch, response shapes, crash isolation);
%% the native `roadrunner_quic` stack provides the transport
%% (`roadrunner_quic_listener` drives the UDP socket, `roadrunner_quic` the
%% per-connection control + streams) and the codecs
%% (`roadrunner_quic_h3_frame` for framing, `roadrunner_qpack` for QPACK).
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
%% (`rem 4 =:= 2`) are demultiplexed by stream type (RFC 9114 §6.2):
%% the peer control stream is validated (exactly one, SETTINGS as its
%% first frame, no request frames), the QPACK encoder/decoder streams
%% are accepted and drained (zero table capacity means no instructions
%% are expected), a client-initiated push stream is refused, and
%% unknown stream types are ignored. A violation on any of these closes
%% the connection with the matching RFC 9114 §8.1 error code.
%%
%% On a graceful drain (a `{roadrunner_drain, _}` message from the
%% listener) it sends a GOAWAY on its control stream (RFC 9114 §5.2),
%% refuses request streams opened at or beyond the GOAWAY id with
%% H3_REQUEST_REJECTED, lets in-flight requests finish, and then closes
%% the connection; the listener force-exits it at the deadline if a
%% request is still running.
%%
%% All response shapes are supported (buffered, `stream`, `loop`,
%% `sendfile`). WebSocket over h3 (RFC 9220 Extended CONNECT) is not
%% implemented and answers 501 in the worker.

-export([start/2]).
-export([init/2]).
%% Exported for unit testing of the pure request-stream frame folding
%% and the pure peer-uni-stream state machine; not part of any public
%% surface.
-export([
    decode_request_frames/3, decode_request_frames/4, new_request_stream/0, uni_event/4, uni_reset/1
]).

%% RFC 9114 §8.1 / RFC 9204 §8.3 error codes.
-define(H3_NO_ERROR, 16#0100).
-define(H3_INTERNAL_ERROR, 16#0102).
-define(H3_STREAM_CREATION_ERROR, 16#0103).
-define(H3_CLOSED_CRITICAL_STREAM, 16#0104).
-define(H3_FRAME_UNEXPECTED, 16#0105).
-define(H3_FRAME_ERROR, 16#0106).
-define(H3_SETTINGS_ERROR, 16#0109).
-define(H3_MISSING_SETTINGS, 16#010A).
-define(H3_REQUEST_REJECTED, 16#010B).
-define(H3_MESSAGE_ERROR, 16#010E).
-define(H3_QPACK_DECOMPRESSION_FAILED, 16#0200).

%% Default cap on the encoded request field section (the HEADERS block).
%% The body is bounded by `max_content_length`; this bounds header memory
%% so a peer cannot make the conn buffer an unbounded header block.
%% Over-cap answers 431. Overridable per listener via the `max_header_block`
%% http3 opt. h1 and h2 have their own header-block caps (each separately
%% configurable; h1 defaults to 10240, h2 to 16384).
-define(MAX_HEADER_BLOCK, 16384).

%% Default SETTINGS_MAX_FIELD_SECTION_SIZE (RFC 9114 §7.2.4.1): 2x the
%% encoded-block cap, mirroring the h2 MAX_HEADER_LIST_SIZE default. The
%% decoded field section is always larger than the compressed block (the
%% +32/field overhead alone), so the headroom means the decoded gate only
%% fires on genuinely huge header sets; tracks `max_header_block` when set.
-define(DEFAULT_MAX_FIELD_SECTION_SIZE, (2 * ?MAX_HEADER_BLOCK)).

%% A critical stream role can be claimed at most once per connection.
-type critical_role() :: control | qpack_encoder | qpack_decoder.
-type critical_set() :: #{critical_role() => true}.

%% Per peer-uni-stream state: `pending` while the leading stream-type
%% varint is still arriving, `control` once it is known to be the peer
%% control stream (buffering frames + tracking whether SETTINGS was
%% seen), `drain` for streams whose bytes we read and discard (QPACK
%% encoder/decoder = `critical`, unknown types = `noncritical`).
-type uni_state() ::
    {pending, binary()}
    | {control, binary(), SettingsReceived :: boolean()}
    | {drain, critical | noncritical}.

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
    %% StreamId => worker pid, so a peer RESET_STREAM on a dispatched
    %% stream can be routed to its worker (`{roadrunner_stream_reset, _}`).
    worker_pids = #{} :: #{non_neg_integer() => pid()},
    %% StreamId => peer-uni-stream state (see `uni_event/4`).
    uni = #{} :: #{non_neg_integer() => uni_state()},
    %% Critical stream roles already claimed, so a duplicate control or
    %% QPACK stream is rejected (RFC 9114 §6.2.1, §7.2.1).
    critical = #{} :: critical_set(),
    %% Our control stream id, set on `connected` — GOAWAY is sent on it.
    control_stream_id = undefined :: non_neg_integer() | undefined,
    %% Highest client-initiated request stream id accepted, so a drain
    %% GOAWAY can name the first request we will not process.
    last_request_id = 0 :: non_neg_integer(),
    %% Set once a graceful drain starts (RFC 9114 §5.2): the GOAWAY id we
    %% sent. While set, the connection is draining and request streams at
    %% or beyond it are refused. `undefined` means not draining.
    goaway_id = undefined :: non_neg_integer() | undefined,
    max_content_length :: non_neg_integer(),
    %% Cap on the encoded request field section (HEADERS block). Read from
    %% proto_opts at conn start; defaults to `?MAX_HEADER_BLOCK`.
    max_header_block = ?MAX_HEADER_BLOCK :: pos_integer(),
    %% Cap on the DECODED field-section size (RFC 9114 §7.2.4.1
    %% SETTINGS_MAX_FIELD_SECTION_SIZE): advertised on the control stream
    %% (so conformant clients self-limit, §4.2.2) and enforced after QPACK
    %% decode in `dispatch_request/2`. Read from proto_opts; defaults to
    %% `2 * max_header_block`.
    max_field_section_size = ?DEFAULT_MAX_FIELD_SECTION_SIZE :: pos_integer(),
    %% In-flight-request slot accounting (cross-listener cap). `infinity`
    %% (default) disables it; `inflight_counter` is the shared gauge. Read
    %% from proto_opts at `init/2` so the per-stream acquire/release passes
    %% them to `roadrunner_conn` directly. See `dispatch_decoded/3`.
    max_concurrent_requests = infinity :: infinity | pos_integer(),
    inflight_counter :: counters:counters_ref() | undefined,
    %% Per-peer rate-limit guard resolved from proto_opts + peer at conn start
    %% (`undefined` when off). Checked in `dispatch_decoded/4`.
    rate_limit = undefined :: roadrunner_conn:rate_limit_state()
}).

-doc """
Spawn the connection-owner loop for a freshly accepted QUIC
connection. Called from the QUIC listener's `connection_handler` (in
the listener's process) before ownership is transferred, so the
`max_clients` slot is acquired here, synchronously: on refusal the
connection is closed and `{error, max_clients}` is returned, and the
QUIC listener never transfers ownership to (or `set_owner_sync`s) a
connection we will not serve. On success the loop is spawned unlinked,
so a connection crash never reaches the listener, and it releases the
slot in `terminate/1`.
""".
-spec start(pid(), roadrunner_conn:proto_opts()) -> {ok, pid()} | {error, max_clients}.
start(ConnPid, ProtoOpts) ->
    case roadrunner_conn:try_acquire_slot(ProtoOpts) of
        false ->
            %% Over `max_clients` — refuse before ownership transfer.
            %% `try_acquire_slot/1` already rolled the counter back.
            _ = roadrunner_quic:close(ConnPid, ?H3_NO_ERROR),
            {error, max_clients};
        true ->
            #{handler_spawn_opts := SpawnOpts} = ProtoOpts,
            {ok, proc_lib:spawn_opt(?MODULE, init, [ConnPid, ProtoOpts], SpawnOpts)}
    end.

-doc false.
-spec init(pid(), roadrunner_conn:proto_opts()) -> ok.
init(Conn, #{listener_name := ListenerName, max_content_length := MaxContentLength} = ProtoOpts) ->
    proc_lib:set_label({roadrunner_conn_loop_http3, ListenerName, Conn}),
    %% The `max_clients` slot was acquired by `start/2` (in the listener
    %% process); it is released in `terminate/1`.
    DrainGroup = maps:get(graceful_drain, ProtoOpts, true),
    ok = roadrunner_conn:join_drain_group(ListenerName, DrainGroup),
    %% Share fate with the QUIC connection process: if it dies abnormally
    %% (without a `closed` event) the loop dies too, rather than hanging.
    %% The slot then leaks until slot reconciliation reaps it, the same
    %% bound h1/h2 carry for a `kill`-ed conn. The graceful path releases
    %% it in `terminate/1` on the `closed` event.
    true = link(Conn),
    %% `remote_addr` is set at connection creation, so peername is
    %% available from the start (idle / handshaking states).
    {ok, Peer} = roadrunner_quic:peername(Conn),
    StartMono = roadrunner_telemetry:listener_accept(#{
        listener_name => ListenerName, peer => Peer
    }),
    MaxHeaderBlock = maps:get(http3_max_header_block, ProtoOpts, ?MAX_HEADER_BLOCK),
    loop(#h3{
        conn = Conn,
        proto_opts = ProtoOpts,
        listener_name = ListenerName,
        peer = Peer,
        start_mono = StartMono,
        max_content_length = MaxContentLength,
        max_header_block = MaxHeaderBlock,
        %% Decoded-section cap defaults to 2x the (possibly overridden) encoded
        %% cap, so raising `max_header_block` lifts both gates together.
        max_field_section_size = maps:get(
            http3_max_field_section_size, ProtoOpts, 2 * MaxHeaderBlock
        ),
        max_concurrent_requests = maps:get(max_concurrent_requests, ProtoOpts, infinity),
        inflight_counter = maps:get(inflight_counter, ProtoOpts, undefined),
        rate_limit = roadrunner_conn:resolve_rate_limit(ProtoOpts, Peer)
    }).

-spec loop(#h3{}) -> ok.
loop(State) ->
    case is_drained(State) of
        true ->
            %% Graceful drain complete (RFC 9114 §5.2): GOAWAY was sent
            %% and no request remains in flight — close cleanly.
            close_connection(State, ?H3_NO_ERROR, ~"graceful shutdown");
        false ->
            recv_loop(State)
    end.

-spec recv_loop(#h3{}) -> ok.
recv_loop(#h3{conn = Conn} = State) ->
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
            case handle_stream_reset(State, StreamId) of
                {conn_error, Code, Reason} -> close_connection(State, Code, Reason);
                State1 -> loop(State1)
            end;
        {quic, Conn, {closed, _Reason}} ->
            terminate(State);
        {'DOWN', MonRef, process, _Pid, Reason} ->
            loop(handle_worker_down(State, MonRef, Reason));
        {roadrunner_drain, _Deadline} ->
            %% Begin a graceful drain: send GOAWAY, refuse new requests,
            %% let in-flight ones finish (the `loop/1` head closes the
            %% connection once they do). The listener force-exits us at
            %% the deadline if a request is still running then.
            loop(start_drain(State))
        %% No catch-all: like the h2 connection loop, the owner uses a
        %% selective receive. The native transport only ever sends it the
        %% `{quic, Conn, Event}` notifications matched above, so an unmatched
        %% message stays queued rather than being silently dropped.
    end.

%% Open the server control stream and send SETTINGS on the `connected`
%% event (RFC 9114 §6.2.1: each side opens one control stream and sends
%% SETTINGS as its first frame). Ownership transfers in the handshaking
%% state, so `connected` is delivered to this loop exactly once. The
%% control stream stays open (no FIN) for the connection's lifetime.
%%
%% The SETTINGS send is fire-and-forget (`_ =`, as in `start_drain/1`): a
%% peer that closes right after the handshake (e.g. rejecting a field
%% section) leaves the connection draining, so the send returns
%% `{error, {invalid_state, draining}}`. That is an expected race, not a
%% fault — the queued `{closed, _}` event terminates the loop cleanly, so
%% there is nothing to recover and no reason to crash on it. The open
%% runs the instant the handshake completes, before any peer close can
%% arrive, so it stays strictly matched.
-spec send_control_stream(#h3{}) -> #h3{}.
send_control_stream(#h3{conn = Conn, max_field_section_size = MaxFieldSection} = State) ->
    {ok, CtrlStreamId} = roadrunner_quic:open_unidirectional_stream(Conn),
    Prefix = roadrunner_quic_h3_frame:encode_stream_type(control),
    Settings = roadrunner_quic_h3_frame:encode_settings(#{
        qpack_max_table_capacity => 0,
        qpack_blocked_streams => 0,
        max_field_section_size => MaxFieldSection,
        %% A reserved "GREASE" setting (RFC 9114 §7.2.4.1): an identifier of
        %% the form 0x1f*N+0x21 a conformant peer MUST ignore, sent so peers
        %% that mishandle unknown settings are shaken out early rather than
        %% letting the wire format ossify. The identifier and value are
        %% otherwise arbitrary.
        16#1f21 => 0
    }),
    _ = roadrunner_quic:send_data(Conn, CtrlStreamId, [Prefix, Settings], false),
    State#h3{control_stream_id = CtrlStreamId}.

%% Begin a graceful drain (RFC 9114 §5.2): send a GOAWAY on the control
%% stream naming the first request-stream id we will not process
%% (`last_request_id + 4`, the next client-initiated bidirectional id),
%% and mark the connection draining so later request streams are
%% refused. Re-sending the same id on a repeated drain is harmless and
%% RFC-compliant (the id never increases — refused streams are not
%% counted). The control stream always exists here: `connected` (which
%% opens it) is delivered before any request, and a drain only follows
%% an established connection.
-spec start_drain(#h3{}) -> #h3{}.
start_drain(#h3{conn = Conn, control_stream_id = CtrlId, last_request_id = LastId} = State) when
    is_integer(CtrlId)
->
    GoawayId = LastId + 4,
    _ = roadrunner_quic:send_data(
        Conn, CtrlId, roadrunner_quic_h3_frame:encode_goaway(GoawayId), false
    ),
    State#h3{goaway_id = GoawayId}.

%% A draining connection is done once no request is in flight — neither
%% mid-receive (`streams`) nor awaiting a worker response (`worker_refs`).
-spec is_drained(#h3{}) -> boolean().
is_drained(#h3{goaway_id = undefined}) ->
    false;
is_drained(#h3{streams = Streams, worker_refs = WorkerRefs}) ->
    map_size(Streams) =:= 0 andalso map_size(WorkerRefs) =:= 0.

%% Track the highest request stream id accepted, for the drain GOAWAY id.
-spec note_request_id(#h3{}, non_neg_integer()) -> #h3{}.
note_request_id(#h3{last_request_id = Last} = State, StreamId) when StreamId > Last ->
    State#h3{last_request_id = StreamId};
note_request_id(State, _StreamId) ->
    State.

-type handle_result() :: #h3{} | {conn_error, non_neg_integer(), binary()}.

-spec handle_stream_data(#h3{}, non_neg_integer(), binary(), boolean()) -> handle_result().
handle_stream_data(State, StreamId, Data, Fin) ->
    case StreamId rem 4 of
        %% Client-initiated bidirectional stream — an HTTP/3 request.
        0 -> handle_request_stream(State, StreamId, Data, Fin);
        %% Client-initiated unidirectional (control / QPACK / push /
        %% unknown) — demultiplexed by stream type (RFC 9114 §6.2).
        2 -> handle_uni_stream(State, StreamId, Data, Fin)
        %% Server-initiated ids (1, 3) only carry data this side writes,
        %% so inbound `stream_data` for one cannot occur.
    end.

-spec handle_request_stream(#h3{}, non_neg_integer(), binary(), boolean()) -> handle_result().
handle_request_stream(#h3{goaway_id = GoawayId} = State, StreamId, _Data, _Fin) when
    is_integer(GoawayId), StreamId >= GoawayId
->
    %% RFC 9114 §5.2: a request stream opened at or beyond the GOAWAY id
    %% will not be processed — reject it with H3_REQUEST_REJECTED.
    reset_and_drop(State, StreamId, ?H3_REQUEST_REJECTED);
handle_request_stream(State0, StreamId, Data, Fin) ->
    #h3{streams = Streams, max_content_length = MaxLen, max_header_block = MaxHdrBlock} =
        State = note_request_id(State0, StreamId),
    Stream0 = maps:get(StreamId, Streams, new_request_stream()),
    case Stream0 of
        #{frame_state := discarding} ->
            %% The stream was already answered (413). Residual in-flight
            %% body must be ignored — it is continued body on an answered
            %% request, NOT a new header-less request, so it must not trip
            %% the DATA-before-HEADERS check or re-trigger a 413. The
            %% marker is freed when the client finishes (FIN) or resets
            %% the stream, so it never outlives the stream.
            case Fin of
                true -> drop_stream(State, StreamId);
                false -> State
            end;
        #{buf := Buf0} ->
            case
                decode_request_frames(<<Buf0/binary, Data/binary>>, Stream0, MaxLen, MaxHdrBlock)
            of
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
                    %% Ask the client to stop and mark the stream
                    %% `discarding` so residual body is dropped rather
                    %% than mistaken for a new request.
                    _ = roadrunner_quic:stop_sending(State#h3.conn, StreamId, ?H3_NO_ERROR),
                    State#h3{
                        streams = Streams#{
                            StreamId => Stream0#{
                                frame_state := discarding,
                                buf := <<>>,
                                body := [],
                                body_len := 0
                            }
                        }
                    };
                headers_too_large ->
                    ok = roadrunner_http3_stream_worker:send_buffered(
                        State#h3.conn,
                        StreamId,
                        431,
                        [{~"content-type", ~"text/plain"}],
                        ~"Request Header Fields Too Large"
                    ),
                    _ = roadrunner_quic:stop_sending(State#h3.conn, StreamId, ?H3_NO_ERROR),
                    State#h3{
                        streams = Streams#{
                            StreamId => Stream0#{
                                frame_state := discarding,
                                buf := <<>>,
                                body := [],
                                body_len := 0
                            }
                        }
                    };
                {conn_error, _, _} = ConnError ->
                    ConnError
            end
    end.

%% Advance a peer-initiated unidirectional stream by one chunk. The
%% per-stream and connection-wide critical-role state lives in the `#h3`
%% record; the decision logic is the pure `uni_event/4` (unit-tested),
%% so this wrapper just slices the relevant state in and folds the
%% result back.
-spec handle_uni_stream(#h3{}, non_neg_integer(), binary(), boolean()) -> handle_result().
handle_uni_stream(#h3{uni = Uni, critical = Critical} = State, StreamId, Data, Fin) ->
    UniState = maps:get(StreamId, Uni, {pending, <<>>}),
    case uni_event(UniState, Critical, Data, Fin) of
        {conn_error, _, _} = ConnError ->
            ConnError;
        {drop, Critical1} ->
            State#h3{uni = maps:remove(StreamId, Uni), critical = Critical1};
        {UniState1, Critical1} ->
            State#h3{uni = Uni#{StreamId => UniState1}, critical = Critical1}
    end.

%% A RESET_STREAM aborts a stream. For a critical stream (peer control /
%% QPACK) that is a connection error of type H3_CLOSED_CRITICAL_STREAM
%% (RFC 9114 §6.2.1, §7.2.1); for any other stream (a request stream, a
%% not-yet-typed or unknown uni stream) it just drops the per-stream
%% state we hold.
-spec handle_stream_reset(#h3{}, non_neg_integer()) -> handle_result().
handle_stream_reset(#h3{uni = Uni, streams = Streams, worker_pids = WorkerPids} = State, StreamId) ->
    case Uni of
        #{StreamId := UniState} ->
            case uni_reset(UniState) of
                critical ->
                    {conn_error, ?H3_CLOSED_CRITICAL_STREAM, ~"peer reset a critical stream"};
                noncritical ->
                    State#h3{uni = maps:remove(StreamId, Uni)}
            end;
        _ ->
            case WorkerPids of
                #{StreamId := WorkerPid} ->
                    %% Peer cancelled a dispatched request stream. Tell the
                    %% worker so a `{loop, ...}` handler gets its disconnect;
                    %% the worker's normal exit then releases the slot and
                    %% drops the stream via `handle_worker_down/3` (no RST
                    %% back — the peer already reset it).
                    _ = (WorkerPid ! {roadrunner_stream_reset, StreamId}),
                    State;
                _ ->
                    %% Still mid-receive (or already gone) — drop the
                    %% in-progress frame-accumulation entry.
                    State#h3{streams = maps:remove(StreamId, Streams)}
            end
    end.

%% RFC 9114 §7.2.8: HTTP/2-reserved frame types → H3_FRAME_UNEXPECTED;
%% other malformed/oversized frames (§7.1) → H3_FRAME_ERROR.
-spec frame_error_code(term()) -> non_neg_integer().
frame_error_code({h2_reserved_frame, _}) -> ?H3_FRAME_UNEXPECTED;
frame_error_code(_) -> ?H3_FRAME_ERROR.

-spec new_request_stream() -> map().
new_request_stream() ->
    #{
        buf => <<>>,
        header_block => undefined,
        body => [],
        body_len => 0,
        %% RFC 9114 §4.1 request frame sequence: HEADERS, then DATA, then
        %% optional trailing HEADERS, then nothing.
        frame_state => expecting_headers
    }.

-type decode_result() ::
    {ok, map()} | too_large | headers_too_large | {conn_error, non_neg_integer(), binary()}.

%% Decode as many complete HTTP/3 frames as the buffer holds, applying
%% the request frame-sequence rules and folding payloads into the
%% accumulated request. The undecoded remainder is stashed in `buf` for
%% the next `stream_data` message.
-spec decode_request_frames(binary(), map(), non_neg_integer()) -> decode_result().
decode_request_frames(Buf, Stream, MaxLen) ->
    decode_request_frames(Buf, Stream, MaxLen, ?MAX_HEADER_BLOCK).

-spec decode_request_frames(binary(), map(), non_neg_integer(), pos_integer()) -> decode_result().
decode_request_frames(Buf, Stream, MaxLen, MaxHdrBlock) ->
    case roadrunner_quic_h3_frame:decode(Buf) of
        {ok, Frame, Rest} ->
            case apply_frame(Frame, Stream, MaxLen, MaxHdrBlock) of
                {ok, Stream1} -> decode_request_frames(Rest, Stream1, MaxLen, MaxHdrBlock);
                Other -> Other
            end;
        {more, _} ->
            %% A still-incomplete HEADERS frame already over the cap is an
            %% oversized field section: reject now instead of buffering more.
            %% Once in `expecting_data` the body cap governs the buffer.
            case Stream of
                #{frame_state := expecting_headers} when byte_size(Buf) > MaxHdrBlock ->
                    headers_too_large;
                _ ->
                    {ok, Stream#{buf := Buf}}
            end;
        {error, Reason} ->
            %% A frame-level decode failure is a connection error per
            %% RFC 9114 §7.1 (malformed/oversized frame) and §7.2.8
            %% (HTTP/2-reserved frame type).
            {conn_error, frame_error_code(Reason), ~"frame error"}
    end.

%% Apply one decoded frame against the request frame-sequence state
%% machine (RFC 9114 §4.1). An out-of-sequence or control-stream-only
%% frame on a request stream is a connection error of type
%% H3_FRAME_UNEXPECTED (§4.1, §7.2.4); unknown/reserved frames are
%% ignored (§9). Trailers (a HEADERS after the body) are accepted but
%% not surfaced by the buffered path.
-spec apply_frame(roadrunner_quic_h3_frame:frame(), map(), non_neg_integer(), pos_integer()) ->
    {ok, map()} | too_large | headers_too_large | {conn_error, non_neg_integer(), binary()}.
apply_frame({headers, Block}, #{frame_state := expecting_headers}, _MaxLen, MaxHdrBlock) when
    byte_size(Block) > MaxHdrBlock
->
    headers_too_large;
apply_frame({headers, Block}, #{frame_state := expecting_headers} = Stream, _MaxLen, _MaxHdrBlock) ->
    {ok, Stream#{header_block := Block, frame_state := expecting_data}};
apply_frame({headers, _Trailers}, #{frame_state := expecting_data} = Stream, _MaxLen, _MaxHdrBlock) ->
    {ok, Stream#{frame_state := expecting_done}};
apply_frame({data, Payload}, #{frame_state := expecting_data} = Stream, MaxLen, _MaxHdrBlock) ->
    #{body := Body, body_len := Len} = Stream,
    NewLen = Len + byte_size(Payload),
    case NewLen > MaxLen of
        true -> too_large;
        false -> {ok, Stream#{body := [Body, Payload], body_len := NewLen}}
    end;
apply_frame({unknown, _Type, _Payload}, Stream, _MaxLen, _MaxHdrBlock) ->
    {ok, Stream};
apply_frame(_Frame, _Stream, _MaxLen, _MaxHdrBlock) ->
    %% DATA before HEADERS, a frame after trailers, or a control-stream
    %% frame (SETTINGS / GOAWAY / MAX_PUSH_ID / CANCEL_PUSH / PUSH_PROMISE)
    %% on a request stream — RFC 9114 §4.1 / §7.2: H3_FRAME_UNEXPECTED.
    {conn_error, ?H3_FRAME_UNEXPECTED, ~"unexpected frame on request stream"}.

-type uni_result() ::
    {uni_state() | drop, critical_set()} | {conn_error, non_neg_integer(), binary()}.

%% Advance one peer-initiated unidirectional stream by a chunk of bytes
%% (RFC 9114 §6.2). `Critical` is the connection-wide set of claimed
%% critical roles, threaded through so a duplicate control / QPACK
%% stream is rejected. Returns the new per-stream state (or `drop` when
%% the stream is finished and needs no further tracking) plus the
%% updated claim set, or a connection error. Pure — the `#h3` plumbing
%% is in `handle_uni_stream/4`.
-spec uni_event(uni_state(), critical_set(), binary(), boolean()) -> uni_result().
uni_event({pending, Buf}, Critical, Data, Fin) ->
    uni_classify(<<Buf/binary, Data/binary>>, Critical, Fin);
uni_event({control, Buf, SettingsReceived}, Critical, Data, Fin) ->
    uni_control(<<Buf/binary, Data/binary>>, SettingsReceived, Critical, Fin);
uni_event({drain, Criticality}, Critical, _Data, Fin) ->
    uni_drain(Criticality, Critical, Fin).

%% Read the leading stream-type varint and dispatch on it.
-spec uni_classify(binary(), critical_set(), boolean()) -> uni_result().
uni_classify(Buf, Critical, Fin) ->
    case roadrunner_quic_h3_frame:decode_stream_type(Buf) of
        {more, _} ->
            uni_more(Buf, Critical, Fin);
        {ok, control, Rest} ->
            case claim(Critical, control) of
                {error, dup} ->
                    {conn_error, ?H3_STREAM_CREATION_ERROR, ~"duplicate control stream"};
                {ok, Critical1} ->
                    uni_control(Rest, false, Critical1, Fin)
            end;
        {ok, qpack_encoder, _Rest} ->
            uni_qpack(Critical, qpack_encoder, Fin);
        {ok, qpack_decoder, _Rest} ->
            uni_qpack(Critical, qpack_decoder, Fin);
        {ok, push, _Rest} ->
            %% RFC 9114 §6.2.2 / §7.2.5: only servers open push streams.
            {conn_error, ?H3_STREAM_CREATION_ERROR, ~"client-initiated push stream"};
        {ok, {unknown, _Type}, _Rest} ->
            uni_unknown(Critical, Fin)
    end.

%% The stream-type varint has not fully arrived yet. If the peer also
%% closed the stream there is no type to enforce, so just drop it.
-spec uni_more(binary(), critical_set(), boolean()) -> uni_result().
uni_more(_Buf, Critical, true) ->
    {drop, Critical};
uni_more(Buf, Critical, false) ->
    {{pending, Buf}, Critical}.

%% RFC 9114 §6.2.3: an unknown unidirectional stream type carries no
%% obligation; read and discard it (dropping a closed one).
-spec uni_unknown(critical_set(), boolean()) -> uni_result().
uni_unknown(Critical, true) ->
    {drop, Critical};
uni_unknown(Critical, false) ->
    {{drain, noncritical}, Critical}.

%% A QPACK encoder / decoder stream (RFC 9204 §4.2). One of each only; a
%% peer closing it is H3_CLOSED_CRITICAL_STREAM. We advertised table
%% capacity 0, so no instructions are expected — keep it open and drain.
-spec uni_qpack(critical_set(), qpack_encoder | qpack_decoder, boolean()) -> uni_result().
uni_qpack(Critical, Role, Fin) ->
    case claim(Critical, Role) of
        {error, dup} ->
            {conn_error, ?H3_STREAM_CREATION_ERROR, ~"duplicate QPACK stream"};
        {ok, Critical1} ->
            case Fin of
                true -> {conn_error, ?H3_CLOSED_CRITICAL_STREAM, ~"peer closed a QPACK stream"};
                false -> {{drain, critical}, Critical1}
            end
    end.

%% Validate buffered bytes of the peer control stream against the
%% control-frame sequence rules, then (if not closed) keep the leftover
%% partial frame and the running `SettingsReceived` flag.
-spec uni_control(binary(), boolean(), critical_set(), boolean()) -> uni_result().
uni_control(Buf, SettingsReceived, Critical, Fin) ->
    case validate_control_frames(Buf, SettingsReceived) of
        {conn_error, _, _} = ConnError ->
            ConnError;
        {ok, Leftover, SettingsReceived1} ->
            case Fin of
                true ->
                    %% RFC 9114 §6.2.1: the control stream is critical and
                    %% MUST NOT be closed.
                    {conn_error, ?H3_CLOSED_CRITICAL_STREAM, ~"peer closed the control stream"};
                false ->
                    {{control, Leftover, SettingsReceived1}, Critical}
            end
    end.

%% Bytes on a stream we only drain. A closed critical stream (QPACK) is
%% an error; a closed non-critical stream (unknown type) is dropped.
-spec uni_drain(critical | noncritical, critical_set(), boolean()) -> uni_result().
uni_drain(critical, _Critical, true) ->
    {conn_error, ?H3_CLOSED_CRITICAL_STREAM, ~"peer closed a critical stream"};
uni_drain(noncritical, Critical, true) ->
    {drop, Critical};
uni_drain(Criticality, Critical, false) ->
    {{drain, Criticality}, Critical}.

%% Claim a critical stream role, rejecting a second of the same kind.
-spec claim(critical_set(), critical_role()) -> {ok, critical_set()} | {error, dup}.
claim(Critical, Role) when is_map_key(Role, Critical) ->
    {error, dup};
claim(Critical, Role) ->
    {ok, Critical#{Role => true}}.

%% Decode and validate as many complete control-stream frames as the
%% buffer holds (RFC 9114 §7.2). SETTINGS MUST be the first frame and
%% MUST appear only once; request frames (DATA / HEADERS / PUSH_PROMISE)
%% are forbidden; other frames (GOAWAY / MAX_PUSH_ID / CANCEL_PUSH /
%% reserved) are allowed. The undecoded remainder is returned to be
%% buffered for the next chunk.
-spec validate_control_frames(binary(), boolean()) ->
    {ok, binary(), boolean()} | {conn_error, non_neg_integer(), binary()}.
validate_control_frames(Buf, SettingsReceived) ->
    case roadrunner_quic_h3_frame:decode(Buf) of
        {ok, Frame, Rest} ->
            case control_frame(Frame, SettingsReceived) of
                {ok, SettingsReceived1} -> validate_control_frames(Rest, SettingsReceived1);
                {conn_error, _, _} = ConnError -> ConnError
            end;
        {more, _} ->
            {ok, Buf, SettingsReceived};
        {error, {frame_error, settings, _}} ->
            %% RFC 9114 §7.2.4 / §7.2.4.1: a forbidden HTTP/2 setting,
            %% a duplicate identifier, or other malformed SETTINGS
            %% content → H3_SETTINGS_ERROR.
            {conn_error, ?H3_SETTINGS_ERROR, ~"invalid SETTINGS frame"};
        {error, Reason} ->
            {conn_error, frame_error_code(Reason), ~"control frame error"}
    end.

-spec control_frame(roadrunner_quic_h3_frame:frame(), boolean()) ->
    {ok, boolean()} | {conn_error, non_neg_integer(), binary()}.
control_frame({settings, _}, false) ->
    {ok, true};
control_frame(_Frame, false) ->
    %% RFC 9114 §6.2.1: SETTINGS MUST be the first frame on the control
    %% stream — anything before it is H3_MISSING_SETTINGS.
    {conn_error, ?H3_MISSING_SETTINGS, ~"SETTINGS expected as first control frame"};
control_frame({settings, _}, true) ->
    %% RFC 9114 §7.2.4: SETTINGS occurs at most once.
    {conn_error, ?H3_FRAME_UNEXPECTED, ~"duplicate SETTINGS on control stream"};
control_frame(Frame, true) ->
    case is_control_allowed(Frame) of
        true -> {ok, true};
        false -> {conn_error, ?H3_FRAME_UNEXPECTED, ~"request frame on control stream"}
    end.

%% RFC 9114 §7.2: DATA / HEADERS / PUSH_PROMISE belong on request (or
%% push) streams, never the control stream; everything else (GOAWAY,
%% MAX_PUSH_ID, CANCEL_PUSH, reserved/grease) is fine after SETTINGS.
-spec is_control_allowed(roadrunner_quic_h3_frame:frame()) -> boolean().
is_control_allowed({data, _}) -> false;
is_control_allowed({headers, _}) -> false;
is_control_allowed({push_promise, _, _}) -> false;
is_control_allowed(_Frame) -> true.

%% Whether a RESET_STREAM on a tracked uni stream is on a critical
%% stream (so it must close the connection).
-spec uni_reset(uni_state()) -> critical | noncritical.
uni_reset({control, _, _}) -> critical;
uni_reset({drain, critical}) -> critical;
uni_reset(_UniState) -> noncritical.

-spec dispatch_request(#h3{}, non_neg_integer()) -> handle_result().
dispatch_request(#h3{streams = Streams} = State, StreamId) ->
    case maps:get(StreamId, Streams) of
        #{header_block := undefined} ->
            %% Stream ended with no HEADERS frame — a malformed message
            %% (RFC 9114 §4.1): stream error H3_MESSAGE_ERROR.
            reset_and_drop(State, StreamId, ?H3_MESSAGE_ERROR);
        #{header_block := Block} = Stream ->
            %% QPACK decode happens here (not in the worker) because a
            %% decompression failure is a CONNECTION error per RFC 9204
            %% §2.2 — the dynamic-table state is unrecoverable — whereas
            %% a malformed message is a per-stream error.
            case roadrunner_qpack:decode(Block) of
                {error, _} ->
                    {conn_error, ?H3_QPACK_DECOMPRESSION_FAILED, ~"QPACK decompression failed"};
                {ok, Headers} ->
                    case
                        roadrunner_http:header_list_size(Headers) >
                            State#h3.max_field_section_size
                    of
                        true ->
                            %% RFC 9114 §4.2.2: the decoded field section
                            %% exceeds the MAX_FIELD_SECTION_SIZE we advertised.
                            %% QPACK is static-only here, so there's no decoder
                            %% state to desync — answer 431 and drop the stream.
                            respond_field_section_too_large(State, StreamId);
                        false ->
                            #{body := Body} = Stream,
                            dispatch_decoded(State, StreamId, Headers, Body)
                    end
            end
    end.

%% RFC 9114 §4.2.2: a request whose decoded field section exceeds the
%% advertised MAX_FIELD_SECTION_SIZE gets 431. The request stream has
%% already ended (we dispatch at stream close), so no `stop_sending` is
%% needed — just answer and drop the stream.
-spec respond_field_section_too_large(#h3{}, non_neg_integer()) -> #h3{}.
respond_field_section_too_large(#h3{conn = Conn} = State, StreamId) ->
    ok = roadrunner_http3_stream_worker:send_buffered(
        Conn,
        StreamId,
        431,
        [{~"content-type", ~"text/plain"}],
        ~"Request Header Fields Too Large"
    ),
    drop_stream(State, StreamId).

-spec dispatch_decoded(#h3{}, non_neg_integer(), roadrunner_http:headers(), iodata()) ->
    handle_result().
dispatch_decoded(State, StreamId, Headers, Body) ->
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
            case rate_limit_refused(State1, StreamId) of
                {refused, State2} ->
                    %% Per-peer rate exceeded: 429 + Retry-After sent, stream
                    %% dropped. 429 (not H3_REQUEST_REJECTED) so the client backs
                    %% off per Retry-After instead of retrying immediately.
                    State2;
                ok ->
                    dispatch_with_slot(State1, StreamId, Req)
            end
    end.

%% Acquire the listener-wide in-flight slot and spawn the stream worker, or
%% refuse with retry-safe H3_REQUEST_REJECTED at the ceiling.
-spec dispatch_with_slot(#h3{}, non_neg_integer(), roadrunner_req:request()) ->
    handle_result().
dispatch_with_slot(#h3{streams = Streams} = State1, StreamId, Req) ->
    case
        roadrunner_conn:try_acquire_request_slot(
            State1#h3.max_concurrent_requests, State1#h3.inflight_counter
        )
    of
        true ->
            {WorkerPid, MonRef} = roadrunner_http3_stream_worker:start(
                State1#h3.conn, StreamId, Req, State1#h3.proto_opts
            ),
            %% The worker owns the response now, tracked by its monitor
            %% ref; drop the (no-longer-needed) frame-accumulation entry
            %% so the streams map only ever holds in-progress requests.
            %% Record the pid too so a peer reset can reach the worker.
            State1#h3{
                streams = maps:remove(StreamId, Streams),
                worker_refs = (State1#h3.worker_refs)#{MonRef => StreamId},
                worker_pids = (State1#h3.worker_pids)#{StreamId => WorkerPid}
            };
        false ->
            %% Listener-wide in-flight ceiling reached — refuse the
            %% stream (retry-safe H3_REQUEST_REJECTED) without spawning
            %% a worker.
            ok = throttle_stream(State1),
            reset_and_drop(State1, StreamId, ?H3_REQUEST_REJECTED)
    end.

%% A worker exit: normal means it sent its response with the stream FIN
%% (drop the stream); abnormal (QPACK decompression, malformed
%% pseudo-headers, response encoding) resets the stream, leaving the
%% connection's other streams untouched.
-spec handle_worker_down(#h3{}, reference(), term()) -> #h3{}.
handle_worker_down(#h3{worker_refs = WorkerRefs, worker_pids = WorkerPids} = State, MonRef, Reason) ->
    %% Every monitor the loop holds is a stream worker (the QUIC conn is
    %% linked, not monitored), so the ref is always present.
    {StreamId, WorkerRefs1} = maps:take(MonRef, WorkerRefs),
    %% Release the in-flight slot exactly once, tied to removing the worker
    %% ref so it is accounted for by this `DOWN` or by the conn's clean
    %% exit, never both.
    ok = roadrunner_conn:release_request_slot(
        State#h3.max_concurrent_requests, State#h3.inflight_counter
    ),
    State1 = State#h3{
        worker_refs = WorkerRefs1, worker_pids = maps:remove(StreamId, WorkerPids)
    },
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
    _ = roadrunner_quic:reset_stream(Conn, StreamId, ErrorCode),
    drop_stream(State, StreamId).

%% Bump the cumulative throttled counter and emit the throttled telemetry
%% when a stream is refused at the `max_concurrent_requests` ceiling.
-spec throttle_stream(#h3{}) -> ok.
throttle_stream(#h3{proto_opts = #{throttled_counter := Counter}, listener_name = ListenerName}) ->
    ok = atomics:add(Counter, 1, 1),
    roadrunner_telemetry:request_throttled(#{
        listener_name => ListenerName,
        reason => max_concurrent_requests
    }).

%% Per-peer rate-limit gate before spawning a stream worker. `ok` to proceed;
%% `{refused, State1}` after sending `429` + `Retry-After` as a buffered
%% response and dropping the stream (the rate was exceeded). 429 (not
%% H3_REQUEST_REJECTED) so the client honors `Retry-After` instead of retrying
%% the request immediately. The guard being off (`undefined`) or a missing peer
%% IP proceeds.
-spec rate_limit_refused(#h3{}, non_neg_integer()) -> ok | {refused, #h3{}}.
rate_limit_refused(#h3{rate_limit = undefined}, _StreamId) ->
    ok;
rate_limit_refused(
    #h3{
        rate_limit = {Rate, Cap, Cost, Table, Counter, IP},
        conn = Conn,
        listener_name = ListenerName
    } = State,
    StreamId
) ->
    NowMs = erlang:monotonic_time(millisecond),
    case roadrunner_conn:rate_limit_check(Table, IP, Rate, Cap, Cost, NowMs) of
        allow ->
            ok;
        {deny, RetryAfter} ->
            ok = roadrunner_conn:rate_limited_telemetry(ListenerName, Counter),
            ok = roadrunner_http3_stream_worker:send_buffered(
                Conn, StreamId, 429, [{~"retry-after", integer_to_binary(RetryAfter)}], ~""
            ),
            {refused, drop_stream(State, StreamId)}
    end.

%% A connection error (RFC 9114 §8): close the QUIC connection with the
%% h3 error code + reason, then run the normal teardown. The peer sees
%% CONNECTION_CLOSE; the linked conn process stopping ends this loop too,
%% but we tear down explicitly so the slot is released and telemetry
%% fires regardless.
-spec close_connection(#h3{}, non_neg_integer(), binary()) -> ok.
close_connection(#h3{conn = Conn} = State, ErrorCode, Reason) ->
    _ = roadrunner_quic:close(Conn, ErrorCode, Reason),
    terminate(State).

-spec drop_stream(#h3{}, non_neg_integer()) -> #h3{}.
drop_stream(#h3{streams = Streams} = State, StreamId) ->
    State#h3{streams = maps:remove(StreamId, Streams)}.

-spec terminate(#h3{}) -> ok.
terminate(#h3{
    proto_opts = ProtoOpts,
    listener_name = ListenerName,
    peer = Peer,
    start_mono = StartMono,
    worker_refs = Refs,
    max_concurrent_requests = MaxConcReq,
    inflight_counter = InflightCounter
}) ->
    ok = roadrunner_telemetry:listener_conn_close(StartMono, #{
        listener_name => ListenerName,
        peer => Peer,
        requests_served => 0
    }),
    %% Account for any stream workers still live at teardown (each holds one
    %% in-flight slot); workers whose `DOWN` already fired were removed from
    %% `worker_refs`, so this releases each remaining worker exactly once.
    ok = roadrunner_conn:release_request_slots(MaxConcReq, InflightCounter, map_size(Refs)),
    ok = roadrunner_conn:release_slot(ProtoOpts).
