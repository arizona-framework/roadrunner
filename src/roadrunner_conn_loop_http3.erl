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
    decode_request_frames/3, decode_request_frames/4, new_request_stream/1, uni_event/4, uni_reset/1
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
    %% Pre-generated `request_id`s (hex), sliced 16 characters at a
    %% time and refilled by `roadrunner_conn:generate_request_id/1`.
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
    %% `auto` buffers a request's body and dispatches at the stream's FIN;
    %% `manual` dispatches at the end of the headers and hands the worker
    %% the body as it reads (`dispatch_reading/4`). Read from proto_opts.
    body_buffering = auto :: auto | manual,
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
    %% What happens to a request that arrives over the ceiling: refuse it
    %% (the default) or park it until a slot frees. Read from proto_opts
    %% alongside the two fields above.
    overload = refuse :: roadrunner_conn:overload(),
    %% Requests parked waiting for an in-flight slot, already assembled.
    %% The loop must NOT block waiting: it releases slots by processing
    %% its own workers' `DOWN` messages, so a blocked loop would wait on
    %% something only it can deliver.
    awaiting_slot = #{} :: #{non_neg_integer() => roadrunner_req:request()},
    %% Per-peer rate-limit guard resolved from proto_opts + peer at conn start
    %% (`undefined` when off). Checked in `dispatch_decoded/4`.
    rate_limit = undefined :: roadrunner_conn:rate_limit_state(),
    %% The `real_ip` trust config when the peer is a trusted proxy, decided
    %% once per connection (`roadrunner_real_ip:peer_trust/2`); `undefined`
    %% otherwise, the common case, so the request path resolves nothing.
    real_ip = undefined :: undefined | roadrunner_real_ip:config()
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
    ok = roadrunner_conn:register_for_drain(ProtoOpts),
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
        body_buffering = maps:get(body_buffering, ProtoOpts, auto),
        max_header_block = MaxHeaderBlock,
        %% Decoded-section cap defaults to 2x the (possibly overridden) encoded
        %% cap, so raising `max_header_block` lifts both gates together.
        max_field_section_size = maps:get(
            http3_max_field_section_size, ProtoOpts, 2 * MaxHeaderBlock
        ),
        max_concurrent_requests = maps:get(max_concurrent_requests, ProtoOpts, infinity),
        inflight_counter = maps:get(inflight_counter, ProtoOpts, undefined),
        overload = maps:get(overload, ProtoOpts, refuse),
        rate_limit = roadrunner_conn:resolve_rate_limit(ProtoOpts, Peer),
        real_ip = roadrunner_real_ip:peer_trust(maps:get(real_ip, ProtoOpts, undefined), Peer)
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
        {roadrunner_body_demand, Worker, StreamId} ->
            loop(handle_body_demand(State, Worker, StreamId));
        {roadrunner_continue, Worker, StreamId} ->
            loop(handle_continue(State, Worker, StreamId));
        {roadrunner_slot, StreamId, Outcome} ->
            loop(handle_slot(State, StreamId, Outcome));
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
is_drained(#h3{streams = Streams, worker_refs = WorkerRefs, awaiting_slot = Awaiting}) ->
    %% A request parked for an in-flight slot is in neither `streams` (it
    %% is fully received) nor `worker_refs` (no worker yet), but it has
    %% been accepted and still owes the client a response. Leaving it out
    %% here would close the connection under it, silently dropping a
    %% request the peer sent before the GOAWAY. Its wait is bounded by
    %% the queue deadline, and the listener force-closes at the drain
    %% deadline regardless.
    map_size(Streams) =:= 0 andalso map_size(WorkerRefs) =:= 0 andalso
        map_size(Awaiting) =:= 0.

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
    #h3{streams = Streams, proto_opts = ProtoOpts, max_header_block = MaxHdrBlock} =
        State = note_request_id(State0, StreamId),
    Stream0 =
        case Streams of
            #{StreamId := Stream} -> Stream;
            _ -> new_request_stream(State#h3.max_content_length)
        end,
    case Stream0 of
        #{frame_state := discarding} ->
            %% The stream was already answered (413). Residual in-flight
            %% body must be ignored — it is continued body on an answered
            %% request, NOT a new header-less request, so it must not trip
            %% the DATA-before-HEADERS check or re-trigger a 413. The
            %% marker is freed when the client finishes (FIN) or resets
            %% the stream, so it never outlives the stream.
            case Fin of
                true -> State#h3{streams = maps:remove(StreamId, Streams)};
                false -> State
            end;
        #{reader := _, body_error := Error} when Error =/= undefined ->
            %% A manual-mode body that cannot be read (over its cap): what
            %% still comes is dropped, its credit kept, so the client soon
            %% stops; the worker answers, and its exit ends the stream.
            State#h3{streams = Streams#{StreamId := Stream0#{fin := Fin}}};
        #{buf := Buf0} ->
            case
                decode_request_frames(
                    <<Buf0/binary, Data/binary>>, Stream0, ProtoOpts, MaxHdrBlock
                )
            of
                {ok, Stream1} ->
                    %% The stream with this chunk counted, which `await_body/4`
                    %% stores again once it decodes the headers.
                    Stream2 = unreleased(Stream1, Data, State),
                    State1 = State#h3{streams = Streams#{StreamId => Stream2}},
                    case {Stream2, Fin} of
                        {#{reader := _}, _} -> body_in(State1, StreamId, Fin);
                        {_, true} -> dispatch_request(State1, StreamId);
                        {_, false} -> await_body(State1, StreamId, Stream0, Stream2)
                    end;
                too_large when is_map_key(reader, Stream0) ->
                    body_over_cap(State, StreamId, Stream0, Fin);
                too_large ->
                    refuse_request(State, StreamId, Stream0, Fin, 413, ~"Payload Too Large");
                headers_too_large ->
                    refuse_request(
                        State, StreamId, Stream0, Fin, 431, ~"Request Header Fields Too Large"
                    );
                {conn_error, _, _} = ConnError ->
                    ConnError
            end
    end.

%% A request whose body is still to come. When its HEADERS frame has just
%% arrived, the field section is decoded now rather than at dispatch, so a
%% request expecting `100-continue` gets the immediate answer RFC 9110
%% §10.1.1 requires (HTTP/3 being "HTTP/1.1 or later") instead of leaving
%% the client to time out its wait. It is decoded once either way: the
%% stream keeps the headers for dispatch. A body that already outgrew the
%% listener's cap in the same chunk had them decoded for its route
%% (`raise_body_cap/4`).
-spec await_body(#h3{}, non_neg_integer(), map(), map()) -> handle_result().
await_body(
    State,
    StreamId,
    #{header_block := undefined} = Stream0,
    #{header_block := Block, headers := undefined} = Stream1
) when
    is_binary(Block)
->
    case roadrunner_qpack:decode(Block) of
        {error, _} ->
            qpack_decompression_failed();
        {ok, Headers} ->
            Streams = State#h3.streams,
            State1 = State#h3{streams = Streams#{StreamId := Stream1#{headers := Headers}}},
            answer_expectation(State1, StreamId, Stream0, Headers)
    end;
await_body(State, StreamId, #{header_block := undefined} = Stream0, #{headers := Headers}) when
    is_list(Headers)
->
    answer_expectation(State, StreamId, Stream0, Headers);
await_body(State, _StreamId, _Stream0, _Stream1) ->
    State.

%% RFC 9110 §10.1.1: a 413 when the declared `content-length` is already
%% over its route's body cap, the status the body would earn anyway, else
%% the interim 100 (a HEADERS frame with `:status` alone, no FIN) that asks
%% for the body. A request expecting nothing waits for its body as before.
%% In manual mode the request is dispatched now instead, its worker reading
%% the body, and the 100 goes out on its first read.
-spec answer_expectation(#h3{}, non_neg_integer(), map(), roadrunner_http:headers()) ->
    handle_result().
answer_expectation(
    #h3{proto_opts = ProtoOpts, max_content_length = MaxLen, body_buffering = Mode} = State,
    StreamId,
    Stream0,
    Headers
) ->
    case {roadrunner_conn:expect_answer(ProtoOpts, Headers, MaxLen), Mode} of
        {too_large, _} ->
            refuse_request(State, StreamId, Stream0, false, 413, ~"Payload Too Large");
        {continue, auto} ->
            send_continue(State, StreamId);
        {none, auto} ->
            State;
        {Answer, manual} ->
            dispatch_reading(State, StreamId, Headers, Answer =:= continue)
    end.

%% The interim `100 (Continue)`: a HEADERS frame with `:status` alone and
%% no FIN, the final response following on the same stream.
-spec send_continue(#h3{}, non_neg_integer()) -> #h3{}.
send_continue(State, StreamId) ->
    Continue = roadrunner_quic_h3_frame:encode_headers(
        roadrunner_qpack:encode([{~":status", ~"100"}])
    ),
    _ = roadrunner_quic:send_data(State#h3.conn, StreamId, Continue, false),
    State.

%% Answer a request refused before dispatch: 413 for a body over its cap,
%% 431 for an oversized field section. A client still sending (no FIN yet)
%% is asked to stop, and the stream is marked `discarding` so residual body
%% is dropped rather than mistaken for a new request; its FIN or reset frees
%% the marker. When the FIN came with this chunk, nothing more arrives on
%% the stream, so it is dropped now: a marker would never be freed, and
%% would hold a graceful drain open until its deadline.
-spec refuse_request(
    #h3{}, non_neg_integer(), map(), boolean(), roadrunner_http:status(), binary()
) -> #h3{}.
refuse_request(#h3{conn = Conn, streams = Streams} = State, StreamId, Stream0, Fin, Status, Body) ->
    ok = roadrunner_http3_stream_worker:send_buffered(
        Conn, StreamId, Status, [{~"content-type", ~"text/plain"}], Body
    ),
    case Fin of
        true ->
            drop_stream(State, StreamId);
        false ->
            _ = roadrunner_quic:stop_sending(Conn, StreamId, ?H3_NO_ERROR),
            State#h3{
                streams = Streams#{
                    StreamId => Stream0#{
                        frame_state := discarding,
                        buf := <<>>,
                        body := [],
                        body_len := 0
                    }
                }
            }
    end.

%% Dispatch a manual-mode request whose body is still to come: its worker
%% starts now and reads the body as it asks (`handle_body_demand/3`), the
%% stream's QUIC credit given back with each delivery (`deliver/3`), so a
%% stream holds at most one window of body its worker has not read. A 100
%% Continue the client holds its body back for (`ContinueOwed`) goes out on
%% the first ask. A malformed `content-length` is a malformed request.
-spec dispatch_reading(#h3{}, non_neg_integer(), roadrunner_http:headers(), boolean()) ->
    handle_result().
dispatch_reading(#h3{streams = Streams} = State, StreamId, Headers, ContinueOwed) ->
    #{StreamId := Stream} = Streams,
    Declared = roadrunner_http:request_content_length(Headers),
    Reading = Stream#{
        reader => undefined,
        continue_owed => ContinueOwed,
        body_error => undefined,
        declared => Declared,
        fin => false
    },
    State1 = State#h3{streams = Streams#{StreamId := Reading}},
    case Declared of
        error -> reset_and_drop(State1, StreamId, ?H3_MESSAGE_ERROR);
        _ -> dispatch_headers(State1, StreamId, Reading, Headers)
    end.

%% Count a chunk's raw bytes toward what a manual-mode stream hands back to
%% QUIC flow control once its worker reads them (`deliver/3`).
-spec unreleased(map(), binary(), #h3{}) -> map().
unreleased(#{unreleased := Unreleased} = Stream, Data, #h3{body_buffering = manual}) ->
    Stream#{unreleased := Unreleased + byte_size(Data)};
unreleased(Stream, _Data, _State) ->
    Stream.

%% DATA, or the FIN ending it, for a dispatched manual-mode stream, `body`
%% already holding it. A body that outruns its declared `content-length`, or
%% ends short of it, is malformed (RFC 9114 §4.1.2): the read fails and the
%% stream is reset. Otherwise the worker waiting for DATA gets it now, or it
%% waits for the worker's next ask.
-spec body_in(#h3{}, non_neg_integer(), boolean()) -> #h3{}.
body_in(#h3{streams = Streams} = State, StreamId, Fin) ->
    #{StreamId := #{body_len := Len, declared := Declared, reader := Reader} = Stream} = Streams,
    Stream1 = Stream#{fin := Fin},
    case roadrunner_http:body_length_fits(Declared, Len, Fin) of
        false ->
            ok = roadrunner_conn:send_body_error(Reader, StreamId, closed),
            Ended = Stream1#{reader := undefined},
            reset_and_drop(
                State#h3{streams = Streams#{StreamId := Ended}}, StreamId, ?H3_MESSAGE_ERROR
            );
        true when is_pid(Reader) ->
            deliver(State, StreamId, Stream1);
        true ->
            State#h3{streams = Streams#{StreamId := Stream1}}
    end.

%% Hand a manual-mode stream's received DATA to its waiting worker, `Fin`
%% marking the body's end, and give the stream's QUIC credit back for every
%% raw byte received so far, now that all of it has left the connection.
-spec deliver(#h3{}, non_neg_integer(), map()) -> #h3{}.
deliver(
    #h3{conn = Conn, streams = Streams} = State,
    StreamId,
    #{reader := Reader, body := Body, fin := Fin, unreleased := Unreleased} = Stream
) ->
    %% The credit goes back first, so it is already queued at the QUIC
    %% connection by the time the worker, and whatever it tells the client,
    %% sees the DATA.
    ok =
        case Fin orelse Unreleased =:= 0 of
            true -> ok;
            false -> roadrunner_quic:consumed(Conn, StreamId, Unreleased)
        end,
    ok = roadrunner_conn:send_body(Reader, StreamId, Body, Fin),
    Delivered = Stream#{body := [], reader := undefined, unreleased := 0},
    State#h3{streams = Streams#{StreamId := Delivered}}.

%% A manual-mode body past its cap: the worker's read fails with
%% `content_length_too_large`, as on HTTP/1.1 and HTTP/2, for the handler to
%% answer. Its bytes, and the rest of the body, are dropped and their credit
%% kept, so the client soon stops sending.
-spec body_over_cap(#h3{}, non_neg_integer(), map(), boolean()) -> #h3{}.
body_over_cap(#h3{streams = Streams} = State, StreamId, #{reader := Reader} = Stream0, Fin) ->
    ok = roadrunner_conn:send_body_error(Reader, StreamId, content_length_too_large),
    Refused = Stream0#{
        buf := <<>>,
        body := [],
        reader := undefined,
        body_error := content_length_too_large,
        fin := Fin
    },
    State#h3{streams = Streams#{StreamId := Refused}}.

%% The worker of a manual-mode stream asks for its body's next DATA
%% (`roadrunner_conn:stream_body_reader/5`). The first ask sends a 100
%% Continue the client is holding its body back for. It gets what has
%% arrived, the body's end once it came, or, with nothing yet, the next
%% DATA as it arrives (`body_in/3`). A body that cannot be read fails the
%% read, and a stream that is gone or being discarded ends it.
-spec handle_body_demand(#h3{}, pid(), non_neg_integer()) -> #h3{}.
handle_body_demand(#h3{streams = Streams} = State, Worker, StreamId) ->
    case Streams of
        #{StreamId := #{frame_state := discarding}} ->
            ok = roadrunner_conn:send_body_error(Worker, StreamId, closed),
            State;
        #{StreamId := #{reader := _, body_error := undefined} = Stream} ->
            State1 =
                case Stream of
                    #{continue_owed := true} -> send_continue(State, StreamId);
                    _ -> State
                end,
            Asked = Stream#{reader := Worker, continue_owed := false},
            #{body := Body, fin := Fin} = Asked,
            case Fin orelse iolist_size(Body) > 0 of
                true -> deliver(State1, StreamId, Asked);
                false -> State1#h3{streams = Streams#{StreamId := Asked}}
            end;
        #{StreamId := #{reader := _, body_error := Reason}} ->
            ok = roadrunner_conn:send_body_error(Worker, StreamId, Reason),
            State;
        _ ->
            ok = roadrunner_conn:send_body_error(Worker, StreamId, closed),
            State
    end.

%% A worker about to stream its response while the 100 Continue is still
%% owed (`roadrunner_conn:continue_before_stream/1`): it goes out now, before
%% this answer lets the worker send its response, and no later read sends
%% another. The worker waits for the answer either way.
-spec handle_continue(#h3{}, pid(), non_neg_integer()) -> #h3{}.
handle_continue(#h3{streams = Streams} = State, Worker, StreamId) ->
    State1 =
        case Streams of
            #{
                StreamId := #{continue_owed := true, frame_state := Frames, body_error := undefined} =
                    Stream
            } when Frames =/= discarding ->
                Sent = send_continue(State, StreamId),
                Sent#h3{streams = Streams#{StreamId := Stream#{continue_owed := false}}};
            _ ->
                State
        end,
    _ = Worker ! {roadrunner_continued, StreamId},
    State1.

%% A peer reset of a dispatched manual-mode stream ends its body: a waiting
%% read fails, as does any later one, and a `discarding` marker has nothing
%% left to wait for.
-spec reading_reset(#h3{}, non_neg_integer()) -> #h3{}.
reading_reset(#h3{streams = Streams} = State, StreamId) ->
    case Streams of
        #{StreamId := #{frame_state := discarding}} ->
            State#h3{streams = maps:remove(StreamId, Streams)};
        #{StreamId := #{reader := Reader} = Stream} ->
            ok = roadrunner_conn:send_body_error(Reader, StreamId, closed),
            Ended = Stream#{reader := undefined, body_error := closed, fin := true},
            State#h3{streams = Streams#{StreamId := Ended}};
        _ ->
            State
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
                    reading_reset(State, StreamId);
                _ ->
                    %% Still mid-receive, parked for a slot, or already
                    %% gone. Drop the frame-accumulation entry and
                    %% withdraw any parked request; a grant already in
                    %% flight still arrives and `handle_slot/3` gives
                    %% that slot back.
                    ok = roadrunner_conn:cancel_slot_wait(State#h3.overload, StreamId),
                    State#h3{
                        streams = maps:remove(StreamId, Streams),
                        awaiting_slot = maps:remove(StreamId, State#h3.awaiting_slot)
                    }
            end
    end.

%% RFC 9114 §7.2.8: HTTP/2-reserved frame types → H3_FRAME_UNEXPECTED;
%% other malformed/oversized frames (§7.1) → H3_FRAME_ERROR.
-spec frame_error_code(term()) -> non_neg_integer().
frame_error_code({h2_reserved_frame, _}) -> ?H3_FRAME_UNEXPECTED;
frame_error_code(_) -> ?H3_FRAME_ERROR.

-spec new_request_stream(non_neg_integer()) -> map().
new_request_stream(BodyCap) ->
    #{
        buf => <<>>,
        header_block => undefined,
        %% The decoded field section, once decoded: as the HEADERS frame
        %% arrives for a request with a body to come (`await_body/4`), else
        %% at dispatch.
        headers => undefined,
        body => [],
        body_len => 0,
        %% Raw stream bytes received and not yet handed back to QUIC flow
        %% control. Only manual mode counts them: its request streams' credit
        %% is granted as the worker reads (`deliver/3`).
        unreleased => 0,
        %% The listener's `max_content_length` until a body outgrows it and
        %% its route raises it (`raise_body_cap/4`).
        body_cap => BodyCap,
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
-spec decode_request_frames(binary(), map(), roadrunner_conn:proto_opts()) -> decode_result().
decode_request_frames(Buf, Stream, ProtoOpts) ->
    decode_request_frames(Buf, Stream, ProtoOpts, ?MAX_HEADER_BLOCK).

-spec decode_request_frames(binary(), map(), roadrunner_conn:proto_opts(), pos_integer()) ->
    decode_result().
decode_request_frames(Buf, Stream, ProtoOpts, MaxHdrBlock) ->
    case roadrunner_quic_h3_frame:decode(Buf) of
        {ok, Frame, Rest} ->
            case apply_frame(Frame, Stream, ProtoOpts, MaxHdrBlock) of
                {ok, Stream1} -> decode_request_frames(Rest, Stream1, ProtoOpts, MaxHdrBlock);
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
-spec apply_frame(
    roadrunner_quic_h3_frame:frame(), map(), roadrunner_conn:proto_opts(), pos_integer()
) ->
    {ok, map()} | too_large | headers_too_large | {conn_error, non_neg_integer(), binary()}.
apply_frame({headers, Block}, #{frame_state := expecting_headers}, _ProtoOpts, MaxHdrBlock) when
    byte_size(Block) > MaxHdrBlock
->
    headers_too_large;
apply_frame({headers, Block}, #{frame_state := expecting_headers} = Stream, _ProtoOpts, _MaxHdr) ->
    {ok, Stream#{header_block := Block, frame_state := expecting_data}};
apply_frame({headers, _Trailers}, #{frame_state := expecting_data} = Stream, _ProtoOpts, _MaxHdr) ->
    {ok, Stream#{frame_state := expecting_done}};
apply_frame({data, Payload}, #{frame_state := expecting_data} = Stream, ProtoOpts, _MaxHdrBlock) ->
    #{body := Body, body_len := Len, body_cap := Cap} = Stream,
    NewLen = Len + byte_size(Payload),
    case NewLen > Cap of
        true -> raise_body_cap(Stream, Payload, NewLen, ProtoOpts);
        false -> {ok, Stream#{body := [Body, Payload], body_len := NewLen}}
    end;
apply_frame({unknown, _Type, _Payload}, Stream, _ProtoOpts, _MaxHdrBlock) ->
    {ok, Stream};
apply_frame(_Frame, _Stream, _ProtoOpts, _MaxHdrBlock) ->
    %% DATA before HEADERS, a frame after trailers, or a control-stream
    %% frame (SETTINGS / GOAWAY / MAX_PUSH_ID / CANCEL_PUSH / PUSH_PROMISE)
    %% on a request stream — RFC 9114 §4.1 / §7.2: H3_FRAME_UNEXPECTED.
    {conn_error, ?H3_FRAME_UNEXPECTED, ~"unexpected frame on request stream"}.

%% A DATA payload that takes the body to `NewLen` bytes, past the stream's
%% cap (the listener's `max_content_length`, at first): the request's route
%% may set a larger one. Looked up only here, once per raise, and kept on
%% the stream after. The field section is decoded first when its HEADERS
%% frame came in this same chunk, and kept for dispatch. A listener with a
%% single handler has no route to look up.
-spec raise_body_cap(map(), binary(), non_neg_integer(), roadrunner_conn:proto_opts()) ->
    {ok, map()} | too_large | {conn_error, non_neg_integer(), binary()}.
raise_body_cap(_Stream, _Payload, _NewLen, #{dispatch := {handler, _Mod, _Pipeline, _State}}) ->
    too_large;
raise_body_cap(#{headers := undefined, header_block := Block} = Stream, Payload, NewLen, ProtoOpts) ->
    case roadrunner_qpack:decode(Block) of
        {ok, Headers} -> raise_body_cap(Stream#{headers := Headers}, Payload, NewLen, ProtoOpts);
        {error, _} -> qpack_decompression_failed()
    end;
raise_body_cap(
    #{headers := Headers, body := Body, body_cap := Cap} = Stream,
    Payload,
    NewLen,
    #{dispatch := Dispatch}
) ->
    case roadrunner_conn:route_body_cap(Dispatch, Headers, Cap) of
        RouteCap when NewLen =< RouteCap ->
            {ok, Stream#{body := [Body, Payload], body_len := NewLen, body_cap := RouteCap}};
        _ ->
            too_large
    end.

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
        #{headers := undefined, header_block := Block} = Stream ->
            %% QPACK decode happens here (not in the worker) because a
            %% decompression failure is a CONNECTION error per RFC 9204
            %% §2.2 — the dynamic-table state is unrecoverable — whereas
            %% a malformed message is a per-stream error.
            case roadrunner_qpack:decode(Block) of
                {error, _} -> qpack_decompression_failed();
                {ok, Headers} -> dispatch_headers(State, StreamId, Stream, Headers)
            end;
        #{headers := Headers} = Stream ->
            dispatch_headers(State, StreamId, Stream, Headers)
    end.

-spec qpack_decompression_failed() -> {conn_error, non_neg_integer(), binary()}.
qpack_decompression_failed() ->
    {conn_error, ?H3_QPACK_DECOMPRESSION_FAILED, ~"QPACK decompression failed"}.

-spec dispatch_headers(#h3{}, non_neg_integer(), map(), roadrunner_http:headers()) ->
    handle_result().
dispatch_headers(State, StreamId, Stream, Headers) ->
    case roadrunner_http:header_list_size(Headers) > State#h3.max_field_section_size of
        true ->
            %% RFC 9114 §4.2.2: the decoded field section exceeds the
            %% MAX_FIELD_SECTION_SIZE we advertised. QPACK is static-only
            %% here, so there's no decoder state to desync — answer 431 and
            %% drop the stream.
            respond_field_section_too_large(State, StreamId);
        false ->
            dispatch_decoded(State, StreamId, Headers, request_body(Stream))
    end.

%% The body a request is dispatched with: the one buffered, or, for a
%% manual-mode stream still receiving it, `reading` (a body reader).
-spec request_body(map()) -> iodata() | reading.
request_body(#{reader := _}) -> reading;
request_body(#{body := Body}) -> Body.

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

-spec dispatch_decoded(#h3{}, non_neg_integer(), roadrunner_http:headers(), iodata() | reading) ->
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
    case build_request(Headers, Body, RequestContext) of
        {error, _} ->
            %% Malformed request (bad/missing pseudo-headers, a
            %% connection-specific header) — RFC 9114 §4.1.2 / §4.2:
            %% stream error H3_MESSAGE_ERROR.
            reset_and_drop(State1, StreamId, ?H3_MESSAGE_ERROR);
        {ok, Req0} ->
            Req = with_body(
                roadrunner_conn:with_client_ip(Req0, State#h3.real_ip, State#h3.peer),
                Body,
                StreamId,
                State
            ),
            case rate_limit_refused(State1, StreamId, Req) of
                {refused, State2} ->
                    %% Per-peer rate exceeded: 429 + Retry-After sent, stream
                    %% dropped. 429 (not H3_REQUEST_REJECTED) so the client backs
                    %% off per Retry-After instead of retrying immediately.
                    State2;
                ok ->
                    dispatch_with_slot(State1, StreamId, Req)
            end
    end.

-spec build_request(roadrunner_http:headers(), iodata() | reading, map()) ->
    {ok, roadrunner_req:request()} | {error, roadrunner_http3_request:build_error()}.
build_request(Headers, reading, RequestContext) ->
    roadrunner_http3_request:from_headers_reading(Headers, RequestContext);
build_request(Headers, Body, RequestContext) ->
    roadrunner_http3_request:from_headers(Headers, Body, RequestContext).

%% A manual-mode request reads its body through a reader instead of the
%% buffered `body`, within the listener's `request_timeout`.
-spec with_body(roadrunner_req:request(), iodata() | reading, non_neg_integer(), #h3{}) ->
    roadrunner_req:request().
with_body(Req, reading, StreamId, #h3{
    proto_opts = #{request_timeout := Timeout}, max_content_length = MaxLen, streams = Streams
}) ->
    #{StreamId := #{continue_owed := ContinueOwed}} = Streams,
    roadrunner_conn:with_body_reader(Req, StreamId, Timeout, MaxLen, ContinueOwed);
with_body(Req, _Body, _StreamId, _State) ->
    Req.

%% Acquire the listener-wide in-flight slot and spawn the stream worker, or
%% refuse with retry-safe H3_REQUEST_REJECTED at the ceiling.
-spec dispatch_with_slot(#h3{}, non_neg_integer(), roadrunner_req:request()) ->
    handle_result().
dispatch_with_slot(#h3{streams = Streams} = State1, StreamId, Req) ->
    case
        roadrunner_conn:acquire_request_slot(
            State1#h3.max_concurrent_requests,
            State1#h3.inflight_counter,
            State1#h3.overload,
            StreamId
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
                streams = dispatched(Streams, StreamId),
                worker_refs = (State1#h3.worker_refs)#{MonRef => StreamId},
                worker_pids = (State1#h3.worker_pids)#{StreamId => WorkerPid}
            };
        queued ->
            %% Over the ceiling, but this listener parks rather than
            %% sheds. Keep the assembled request and return to the loop;
            %% the grant arrives as a message.
            State1#h3{
                streams = dispatched(Streams, StreamId),
                awaiting_slot = (State1#h3.awaiting_slot)#{StreamId => Req}
            };
        false ->
            %% Listener-wide in-flight ceiling reached — refuse the
            %% stream (retry-safe H3_REQUEST_REJECTED) without spawning
            %% a worker.
            ok = throttle_stream(State1),
            reset_and_drop(State1, StreamId, ?H3_REQUEST_REJECTED)
    end.

%% A dispatched request leaves the streams map, which only holds requests
%% still being received; a manual-mode one is still receiving its body for
%% the worker, so it stays.
-spec dispatched(#{non_neg_integer() => map()}, non_neg_integer()) ->
    #{non_neg_integer() => map()}.
dispatched(Streams, StreamId) ->
    case Streams of
        #{StreamId := #{reader := _}} -> Streams;
        _ -> maps:remove(StreamId, Streams)
    end.

%% A parked request's admission resolved. `granted` means the queue has
%% already taken the slot on our behalf, so a request that has gone away
%% in the meantime must hand it back rather than drop it.
-spec handle_slot(#h3{}, non_neg_integer(), granted | timeout | full) -> #h3{}.
handle_slot(#h3{awaiting_slot = Awaiting} = State, StreamId, granted) ->
    case Awaiting of
        #{StreamId := Req} ->
            State1 = State#h3{awaiting_slot = maps:remove(StreamId, Awaiting)},
            {WorkerPid, MonRef} = roadrunner_http3_stream_worker:start(
                State1#h3.conn, StreamId, Req, State1#h3.proto_opts
            ),
            State1#h3{
                worker_refs = (State1#h3.worker_refs)#{MonRef => StreamId},
                worker_pids = (State1#h3.worker_pids)#{StreamId => WorkerPid}
            };
        _ ->
            give_back_slot(State)
    end;
handle_slot(#h3{awaiting_slot = Awaiting} = State, StreamId, _Refused) ->
    case Awaiting of
        #{StreamId := _} ->
            State1 = State#h3{awaiting_slot = maps:remove(StreamId, Awaiting)},
            ok = throttle_stream(State1),
            reset_and_drop(State1, StreamId, ?H3_REQUEST_REJECTED);
        _ ->
            State
    end.

-spec give_back_slot(#h3{}) -> #h3{}.
give_back_slot(State) ->
    ok = roadrunner_conn:release_request_slot(
        State#h3.max_concurrent_requests, State#h3.inflight_counter, State#h3.overload
    ),
    State.

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
        State#h3.max_concurrent_requests, State#h3.inflight_counter, State#h3.overload
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
    roadrunner_conn:throttled_telemetry(ListenerName, Counter, max_concurrent_requests).

%% Per-peer rate-limit gate before spawning a stream worker. `ok` to proceed;
%% `{refused, State1}` after sending `429` + `Retry-After` as a buffered
%% response and dropping the stream (the rate was exceeded). 429 (not
%% H3_REQUEST_REJECTED) so the client honors `Retry-After` instead of retrying
%% the request immediately. The guard being off (`undefined`) or a missing peer
%% IP proceeds.
-spec rate_limit_refused(#h3{}, non_neg_integer(), roadrunner_req:request()) ->
    ok | {refused, #h3{}}.
rate_limit_refused(
    #h3{rate_limit = RateLimit, conn = Conn, listener_name = ListenerName} = State, StreamId, Req
) ->
    case roadrunner_conn:rate_limit(RateLimit, Req, ListenerName) of
        allow ->
            ok;
        {deny, RetryAfter} ->
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

%% Forget a request stream, unless its client is still sending on it. A
%% manual-mode stream whose client has not finished (no FIN yet) is
%% stopped instead: the client is asked to stop sending (STOP_SENDING
%% H3_NO_ERROR), and a `discarding` marker drops what is already in flight
%% rather than reading it as a new request. A marker stays until the
%% client's FIN or reset frees it (`handle_request_stream/4`,
%% `handle_stream_reset/2`), even once the stream's worker is gone.
-spec drop_stream(#h3{}, non_neg_integer()) -> #h3{}.
drop_stream(#h3{conn = Conn, streams = Streams} = State, StreamId) ->
    case Streams of
        #{StreamId := #{frame_state := discarding}} ->
            State;
        #{StreamId := #{fin := false} = Stream} ->
            _ = roadrunner_quic:stop_sending(Conn, StreamId, ?H3_NO_ERROR),
            Discarding = Stream#{
                frame_state := discarding, buf := <<>>, body := [], reader := undefined
            },
            State#h3{streams = Streams#{StreamId := Discarding}};
        _ ->
            State#h3{streams = maps:remove(StreamId, Streams)}
    end.

-spec terminate(#h3{}) -> ok.
terminate(#h3{
    proto_opts = ProtoOpts,
    listener_name = ListenerName,
    peer = Peer,
    start_mono = StartMono,
    worker_refs = Refs,
    max_concurrent_requests = MaxConcReq,
    inflight_counter = InflightCounter,
    overload = Overload
}) ->
    ok = roadrunner_telemetry:listener_conn_close(StartMono, #{
        listener_name => ListenerName,
        peer => Peer,
        requests_served => 0
    }),
    %% Account for any stream workers still live at teardown (each holds one
    %% in-flight slot); workers whose `DOWN` already fired were removed from
    %% `worker_refs`, so this releases each remaining worker exactly once.
    ok = roadrunner_conn:release_request_slots(
        MaxConcReq, InflightCounter, map_size(Refs), Overload
    ),
    ok = roadrunner_conn:unregister_for_drain(ProtoOpts),
    ok = roadrunner_conn:release_slot(ProtoOpts).
