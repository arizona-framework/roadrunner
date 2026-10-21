-module(roadrunner_conn_loop_http2).
-moduledoc false.

%% HTTP/2 (RFC 9113) connection process.
%%
%% Driven by either TLS ALPN-negotiated `h2` or a plaintext listener
%% configured with `protocols => [http2]` (RFC 7540 §3.4 prior-knowledge).
%% The dispatch decision lives in `roadrunner_conn_loop:awaiting_shoot/3`;
%% this module is transport-agnostic and reads frames via
%% `roadrunner_transport:recv/3` either way.
%%
%% Phase H8b — true multiplexing with per-stream workers. The conn
%% process owns:
%%
%% - the active-mode socket (sole reader / writer of bytes),
%% - the HPACK encoder / decoder (single context per direction
%%   shared across all streams),
%% - the connection-level flow-control windows and per-stream
%%   windows / pending-send queues,
%% - a `streams` map keyed by stream id, and `worker_refs` mapping
%%   monitor refs back to stream ids for `'DOWN'` correlation.
%%
%% Once a request stream finishes receiving (HEADERS + body +
%% END_STREAM), the conn spawns a `roadrunner_http2_stream_worker`
%% process. The worker resolves the route, runs middleware + handler,
%% and translates the response into messages back to the conn:
%%
%% ```
%% {h2_send_headers, Worker, Ref, StreamId, Status, Headers, EndStream}
%% {h2_send_data,    Worker, Ref, StreamId, Data, Size, EndStream}
%% {h2_send_trailers, Worker, Ref, StreamId, Trailers}
%% {h2_send_response, StreamId, Status, Headers, Body, BodyLen}
%% ```
%%
%% The worker sizes `Data` / `Body` itself (`Size` / `BodyLen` are their
%% `iolist_size/1`), so a handler's non-iodata body crashes that worker
%% alone rather than this process, which every stream shares.
%%
%% The conn replies `{h2_send_ack, Ref}` once the corresponding
%% frame(s) are on the wire — so workers are synchronously
%% back-pressured against flow control without buffering. The
%% buffered `h2_send_response` is the exception: it is the worker's
%% final message, so it carries no ack and the conn owns whatever of
%% the body flow control still holds after the worker exits.
%%
%% Workers are spawn_monitored (NOT linked) so a handler crash
%% resets only the affected stream — `'DOWN'` triggers
%% `RST_STREAM(INTERNAL_ERROR)` and the other in-flight streams
%% keep running. `MAX_CONCURRENT_STREAMS` is advertised (default 100,
%% overridable via the `max_concurrent_streams` http2 listener opt);
%% HEADERS beyond that limit get `RST_STREAM(REFUSED_STREAM)`.
%%
%% Response shapes supported:
%%
%% | shape | h2 |
%% |---|---|
%% | `{Status, Headers, Body}` (buffered) | yes |
%% | `{stream, _, _, Fun}` | yes |
%% | `{loop, _}` | yes (worker enters handle_info loop) |
%% | `{sendfile, _}` | yes (chunked DATA via the stream-response engine) |
%% | `{websocket, ...}` (with or without headers) | 501 (Phase H13) |

-export([enter/6]).

%% Hibernate continuation — invoked via `erlang:hibernate/3` when an
%% idle conn parks past `hibernate_after`. Must stay exported so the
%% runtime can re-enter the loop on wake.
-export([recv_more_hib/1]).

%% RFC 9113 §3.4 client connection preface — fixed 24 bytes.
-define(PREFACE, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n").
-define(PREFACE_LEN, 24).

%% Read-deadline caps for the handshake and idle states. Tests
%% override via `persistent_term:put/2` on `{?MODULE, handshake_timeout}`
%% / `{?MODULE, idle_timeout}` so the timeout branches are exercisable
%% without forcing 10–30 s waits per case.
-define(HANDSHAKE_TIMEOUT_DEFAULT, 10_000).
-define(IDLE_TIMEOUT_DEFAULT, 30_000).

%% RFC 9113 §6.5.2 default `MAX_FRAME_SIZE`.
-define(MAX_FRAME_SIZE, 16_384).

%% Default cumulative cap on an assembled HEADERS+CONTINUATION block. Each
%% frame is already bounded to MAX_FRAME_SIZE, but the number of CONTINUATION
%% frames is not, so without this a peer can flood CONTINUATION frames and
%% grow the block without bound (the HTTP/2 CONTINUATION Flood). Overridable
%% per listener via the `max_header_block` http2 opt. h1 and h3 have their own
%% header-block caps (each separately configurable; h1 defaults to 10240, h3
%% to 16384).
-define(MAX_HEADER_BLOCK, 16_384).

%% Default SETTINGS_MAX_HEADER_LIST_SIZE: 2x the encoded-block cap. The
%% decoded list is always larger than the compressed block (the +32/field
%% overhead alone pushes it up), so giving it headroom over `max_header_block`
%% means the decoded gate only fires on genuinely huge header sets. When the
%% encoded cap is overridden, the default tracks it (`2 * max_header_block`).
-define(DEFAULT_MAX_HEADER_LIST_SIZE, (2 * ?MAX_HEADER_BLOCK)).

%% RFC 7541 §4.2 default HPACK dynamic-table size: what we tell the peer
%% its encoder may use (our decoder), and the ceiling we hold our own
%% encoder to even when the peer advertises a larger table.
-define(HPACK_TABLE_SIZE, 4096).

%% RFC 9113 §6.9.2 initial window size for both the connection and
%% each stream.
-define(INITIAL_WINDOW, 65535).

%% Default refill threshold + recv-window peaks. RFC 9113 doesn't
%% mandate any of these — they're policy. The defaults match the
%% RFC 9113 §6.9.2 baseline (65535 for both windows; the threshold
%% is half of that, the original heuristic).
%% `roadrunner_listener:opts()` carries the override knobs as nested
%% `http2` sub-opts (`conn_window`, `stream_window`,
%% `window_refill_threshold`) — bumping the windows is the standard
%% tuning for non-LAN RTTs (window/RTT bounds per-stream
%% throughput). Defaults here mirror those baselines for static
%% record initialization; runtime values come from the proto_opts
%% map populated by `roadrunner_listener:normalize_protocols/1`.
-define(DEFAULT_CONN_RECV_WINDOW, 65535).
-define(DEFAULT_STREAM_RECV_WINDOW, 65535).
-define(DEFAULT_WINDOW_REFILL_THRESHOLD, 32_768).

%% Hard upper bound on a flow-control window per RFC 9113 §6.9.1
%% (signed 31-bit). Increments that would push past this are a
%% FLOW_CONTROL_ERROR.
-define(MAX_WINDOW, 16#7FFFFFFF).

%% Default cap on concurrent client-initiated streams (Phase H8b lifted
%% it from 1 serial to 100). Overridable per listener via the
%% `max_concurrent_streams` http2 opt; clients exceeding the live cap get
%% RST_STREAM(REFUSED_STREAM) on the over-limit HEADERS.
-define(MAX_CONCURRENT_STREAMS, 100).

%% Request-body cap fallback when proto_opts omits `max_content_length`
%% (only test harnesses do; the listener always sets it). Matches the
%% listener default.
-define(DEFAULT_MAX_CONTENT_LENGTH, 10_485_760).

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
%% reshaping callers. A buffered response's body has no worker
%% waiting on it, so its entry carries `undefined` for both the ack
%% ref and the worker.
-type pending_send() ::
    {data, reference() | undefined, pid() | undefined, iodata(), boolean()}.

-type stream_entry() :: #{
    state := stream_state(),
    %% Whether this stream still counts toward the advertised
    %% `max_concurrent_streams` (RFC 9113 §5.1.2: open and half-closed
    %% streams count; a fully closed one does not). Cleared exactly once —
    %% either when both sides have ended or on teardown — while the map
    %% entry itself lives until the worker's DOWN for state cleanup (or,
    %% for a buffered body still queued behind flow control, until that
    %% body drains, see `finish_stream/2`).
    counted := boolean(),
    %% Field block fragments (the HEADERS frame plus any CONTINUATIONs):
    %% a bare binary for a single frame, an iolist once CONTINUATIONs
    %% append, flattened once at finalize (like `body` accumulates DATA).
    header_fragment := iodata(),
    %% Running byte count of `header_fragment`, so the CONTINUATION-flood
    %% cap can compare against a counter instead of re-measuring the
    %% accumulated block on every frame.
    header_len := non_neg_integer(),
    end_headers := boolean(),
    end_stream_seen := boolean(),
    headers := undefined | roadrunner_http:headers(),
    body := iolist(),
    %% Cumulative byte count of received DATA payload, used to
    %% validate against the request's `content-length` header at
    %% END_STREAM (RFC 9113 §8.1.2.6).
    body_len := non_neg_integer(),
    %% The body cap: the listener's `max_content_length` until a body
    %% outgrows it and its route raises it (`stream_body_cap/4`).
    body_cap := non_neg_integer(),
    send_window := integer(),
    recv_window := non_neg_integer(),
    worker_pid := undefined | pid(),
    worker_ref := undefined | reference(),
    pending_sends := queue:queue(pending_send()),
    %% Set on a stream we are resetting with this code until its field
    %% block, possibly still arriving in CONTINUATION frames, is complete
    %% and decoded for its HPACK side effects (`reset_refused/4`).
    refused => roadrunner_http2_frame:error_code(),
    %% Manual body mode (`body_buffering => manual`): the worker runs from
    %% the end of the headers and pulls the body (`handle_body_demand/3`),
    %% `body` holding the DATA it has not taken yet. These keys mark such a
    %% stream. `reader` is the worker waiting for DATA, if it is;
    %% `continue_owed` a 100 Continue the client is holding its body back
    %% for, sent on the worker's first demand; `body_error` why the body
    %% cannot be read (over its cap), told to the worker instead; `declared`
    %% the request's `content-length`, checked as DATA arrives.
    reader => pid() | undefined,
    continue_owed => boolean(),
    body_error => undefined | content_length_too_large,
    declared => none | {ok, non_neg_integer()}
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
    %% Highest stream id the peer has opened, refused streams included
    %% (RFC 9113 §5.1.1: using an id closes every lower idle one). The
    %% idle-stream checks read this one; `last_stream_id` only counts the
    %% streams we accepted, since a later GOAWAY must never raise it (§6.8).
    peer_stream_id = 0 :: non_neg_integer(),
    %% Pre-generated `request_id`s (hex), sliced 16 characters at a
    %% time. Refilled by `roadrunner_conn:generate_request_id/1`
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
    %% `enter/6`. See the `?DEFAULT_*` macros above for the policy
    %% baseline + the listener moduledoc for the override knobs.
    recv_window_peak = ?DEFAULT_CONN_RECV_WINDOW :: pos_integer(),
    stream_recv_window_peak = ?DEFAULT_STREAM_RECV_WINDOW :: pos_integer(),
    recv_window_threshold = ?DEFAULT_WINDOW_REFILL_THRESHOLD :: pos_integer(),
    %% Max concurrent client-initiated streams: advertised in our SETTINGS
    %% and enforced in `on_headers/5`. Read from proto_opts at `enter/6`.
    max_concurrent_streams = ?MAX_CONCURRENT_STREAMS :: pos_integer(),
    %% Streams currently counting toward `max_concurrent_streams` — the
    %% entries whose `counted` flag is still set. Tracked separately from
    %% `map_size(streams)` because an entry outlives its RFC stream: it is
    %% kept until the worker's DOWN for cleanup, and admission must not
    %% charge a stream whose response already ended on the wire (a compliant
    %% client that refills the moment it sees our END_STREAM would otherwise
    %% race that DOWN and eat a spurious REFUSED_STREAM).
    live_streams = 0 :: non_neg_integer(),
    %% Cumulative HEADERS+CONTINUATION block cap (CONTINUATION-flood guard).
    %% Read from proto_opts at `enter/6`.
    max_header_block = ?MAX_HEADER_BLOCK :: pos_integer(),
    %% Request-body cap (`max_content_length` listener opt); an over-cap
    %% body answers 413 + RST_STREAM(NO_ERROR). Read from proto_opts at
    %% `enter/6`.
    max_content_length = ?DEFAULT_MAX_CONTENT_LENGTH :: non_neg_integer(),
    %% `auto` buffers a request's body and starts its worker at END_STREAM;
    %% `manual` starts the worker at the end of the headers and hands it the
    %% body as it reads (`dispatch_reading/3`), within `request_timeout`
    %% from then. Read from proto_opts at `enter/6`.
    body_buffering = auto :: auto | manual,
    request_timeout = 0 :: non_neg_integer(),
    %% Decoded header-list cap (RFC 9113 §6.5.2 SETTINGS_MAX_HEADER_LIST_SIZE):
    %% advertised in our SETTINGS and enforced after HPACK decode in
    %% `finalize_headers/2`. Read from proto_opts at `enter/6`.
    max_header_list_size = ?DEFAULT_MAX_HEADER_LIST_SIZE :: pos_integer(),
    %% `proto_opts.hibernate_after`, or 0 when unset (the common case).
    %% When > 0 and no streams are in flight, the idle-wait path parks
    %% for this window and hibernates. Read from proto_opts at `enter/6`.
    hibernate_after = 0 :: non_neg_integer(),
    %% Read-deadline caps, cached once at `enter/6` so the per-iteration
    %% handshake/idle waits read a record field instead of re-reading
    %% persistent_term every loop. The persistent_term override (a test
    %% hook) is captured at `enter/6`, so it must be set before connect.
    handshake_timeout = ?HANDSHAKE_TIMEOUT_DEFAULT :: non_neg_integer(),
    idle_timeout = ?IDLE_TIMEOUT_DEFAULT :: non_neg_integer(),
    %% Precomputed `Alt-Svc` value (h3 co-serving), or `undefined`.
    %% Prepended to every response by `roadrunner_http:auto_headers/2`.
    %% Read from proto_opts at `enter/6`.
    alt_svc = undefined :: binary() | undefined,
    %% In-flight-request slot accounting (cross-listener cap). `infinity`
    %% (default) disables it; `inflight_counter` is the shared gauge.
    %% Read from proto_opts at `enter/6` so the per-stream acquire/release
    %% passes them to `roadrunner_conn` directly. See `dispatch_stream/2`.
    max_concurrent_requests = infinity :: infinity | pos_integer(),
    inflight_counter :: counters:counters_ref() | undefined,
    %% What happens to a stream that arrives over the ceiling: refuse it
    %% (the default) or park it until a slot frees. Read from proto_opts
    %% at `enter/6` so the per-stream path never re-reads the map.
    overload = refuse :: roadrunner_conn:overload(),
    %% Streams parked waiting for an in-flight slot, holding the request
    %% already assembled for them. The loop must NOT block waiting: it
    %% releases slots by processing its own workers' `DOWN` messages, so
    %% a blocked loop would wait on something only it can deliver.
    awaiting_slot = #{} :: #{stream_id() => roadrunner_req:request()},
    %% Per-peer rate-limit guard resolved from proto_opts + peer at `enter/6`
    %% (`undefined` when off). Checked in `dispatch_stream/2`.
    rate_limit = undefined :: roadrunner_conn:rate_limit_state(),
    %% The `real_ip` trust config when the peer is a trusted proxy, decided
    %% once per connection (`roadrunner_real_ip:peer_trust/2`); `undefined`
    %% otherwise, the common case, so the request path resolves nothing.
    real_ip = undefined :: undefined | roadrunner_real_ip:config(),
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

`Buffered` seeds the connection's initial read buffer — the bytes a
coalesced TCP segment carried after a stripped PROXY-protocol header
(which may be the start of the client preface). Empty for the normal path.
""".
-spec enter(
    roadrunner_transport:socket(),
    roadrunner_conn:proto_opts(),
    atom(),
    {inet:ip_address(), inet:port_number()} | undefined,
    integer(),
    binary()
) -> no_return().
enter(Socket, ProtoOpts, ListenerName, Peer, StartMono, Buffered) ->
    proc_lib:set_label({roadrunner_conn_loop_http2, ListenerName, Peer}),
    Scheme = roadrunner_conn:scheme(Socket),
    {Data, Closed, Error} = roadrunner_transport:messages(Socket),
    %% h2 window knobs are flattened onto proto_opts top-level with
    %% an `http2_` prefix by `roadrunner_listener:normalize_protocols/1`
    %% — one `maps:get/2` per knob, no nested map dives. Fallback
    %% defaults match the listener's so tests that build proto_opts
    %% directly stay short.
    ConnPeak = maps:get(http2_conn_window, ProtoOpts, ?DEFAULT_CONN_RECV_WINDOW),
    StreamPeak = maps:get(http2_stream_window, ProtoOpts, ?DEFAULT_STREAM_RECV_WINDOW),
    Threshold = maps:get(
        http2_window_refill_threshold, ProtoOpts, ?DEFAULT_WINDOW_REFILL_THRESHOLD
    ),
    MaxStreams = maps:get(http2_max_concurrent_streams, ProtoOpts, ?MAX_CONCURRENT_STREAMS),
    MaxHeaderBlock = maps:get(http2_max_header_block, ProtoOpts, ?MAX_HEADER_BLOCK),
    %% Decoded-list cap defaults to 2x the (possibly overridden) encoded cap,
    %% so raising `max_header_block` for big headers lifts both gates together.
    MaxHeaderListSize = maps:get(http2_max_header_list_size, ProtoOpts, 2 * MaxHeaderBlock),
    MaxContentLength = maps:get(max_content_length, ProtoOpts, ?DEFAULT_MAX_CONTENT_LENGTH),
    HibernateAfter = maps:get(hibernate_after, ProtoOpts, 0),
    AltSvc = maps:get(alt_svc, ProtoOpts, undefined),
    MaxConcReq = maps:get(max_concurrent_requests, ProtoOpts, infinity),
    InflightCounter = maps:get(inflight_counter, ProtoOpts, undefined),
    HandshakeTimeout = handshake_timeout(),
    IdleTimeout = idle_timeout(),
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
        hpack_dec = roadrunner_http2_hpack:new_decoder(?HPACK_TABLE_SIZE),
        hpack_enc = roadrunner_http2_hpack:new_encoder(?HPACK_TABLE_SIZE),
        buffer = Buffered,
        recv_window_peak = ConnPeak,
        stream_recv_window_peak = StreamPeak,
        recv_window_threshold = Threshold,
        max_concurrent_streams = MaxStreams,
        max_header_block = MaxHeaderBlock,
        max_header_list_size = MaxHeaderListSize,
        max_content_length = MaxContentLength,
        body_buffering = maps:get(body_buffering, ProtoOpts, auto),
        request_timeout = maps:get(request_timeout, ProtoOpts, 0),
        hibernate_after = HibernateAfter,
        alt_svc = AltSvc,
        max_concurrent_requests = MaxConcReq,
        inflight_counter = InflightCounter,
        overload = maps:get(overload, ProtoOpts, refuse),
        rate_limit = roadrunner_conn:resolve_rate_limit(ProtoOpts, Peer),
        real_ip = roadrunner_real_ip:peer_trust(maps:get(real_ip, ProtoOpts, undefined), Peer),
        handshake_timeout = HandshakeTimeout,
        idle_timeout = IdleTimeout
    },
    handshake(State).

%% =============================================================================
%% Handshake — RFC 9113 §3.4
%% =============================================================================

-spec handshake(#loop{}) -> no_return().
handshake(
    #loop{
        recv_window_peak = ConnPeak,
        stream_recv_window_peak = StreamPeak,
        max_concurrent_streams = MaxStreams,
        max_header_list_size = MaxHeaderListSize
    } = State
) ->
    _ = send(State, server_settings_frame(StreamPeak, MaxStreams, MaxHeaderListSize)),
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

-spec server_settings_frame(pos_integer(), pos_integer(), pos_integer()) -> iodata().
server_settings_frame(StreamPeak, MaxStreams, MaxHeaderListSize) ->
    %% Advertise MAX_CONCURRENT_STREAMS, MAX_FRAME_SIZE and
    %% MAX_HEADER_LIST_SIZE. IDs from RFC 9113 §6.5.2: 3 =
    %% MAX_CONCURRENT_STREAMS, 5 = MAX_FRAME_SIZE, 6 =
    %% MAX_HEADER_LIST_SIZE. When the stream-level recv peak is bigger
    %% than the RFC 65535 default, also advertise
    %% SETTINGS_INITIAL_WINDOW_SIZE (id 4) so streams the peer opens
    %% start with the larger receive allowance.
    Base = [{3, MaxStreams}, {5, ?MAX_FRAME_SIZE}, {6, MaxHeaderListSize}],
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
handshake_phase_preface(#loop{buffer = <<?PREFACE, Rest/binary>>} = State) ->
    handshake_phase_settings(State#loop{buffer = Rest});
handshake_phase_preface(#loop{buffer = <<_:?PREFACE_LEN/binary, _/binary>>} = State) ->
    exit_clean(State);
handshake_phase_preface(State) ->
    handshake_recv(State, fun handshake_phase_preface/1).

-spec handshake_phase_settings(#loop{}) -> no_return().
handshake_phase_settings(#loop{buffer = Buf} = State) ->
    case roadrunner_http2_frame:parse(Buf, ?MAX_FRAME_SIZE) of
        {ok, {settings, Flags, Params}, Rest} when (Flags band 1) =:= 0 ->
            %% RFC 9113 §3.4: the connection-preface SETTINGS is a normal
            %% SETTINGS frame, so apply its parameters through the shared
            %% handler (validate, apply INITIAL_WINDOW_SIZE, ACK, enter the
            %% loop). Previously the parameters were dropped, pinning every
            %% stream's send window to the 65535 default no matter what the
            %% client advertised — forcing extra WINDOW_UPDATE round-trips
            %% (or stalling clients that never send one) on large responses.
            handle_frame({settings, 0, Params}, State#loop{buffer = Rest});
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
            Cont(State#loop{buffer = roadrunner_bin:append(Buf, Bytes)});
        {MClosed, _} ->
            exit_clean(State);
        {MError, _, _} ->
            exit_clean(State)
    after State#loop.handshake_timeout ->
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
            frame_loop(State#loop{buffer = roadrunner_bin:append(Buf, Bytes)});
        {MClosed, _} ->
            exit_clean(State);
        {MError, _, _} ->
            _ = send_goaway(State, protocol_error),
            exit_clean(State);
        {h2_send_headers, From, Ref, StreamId, Status, Headers, EndStream} ->
            recv_more(handle_send_headers(State, From, Ref, StreamId, Status, Headers, EndStream));
        {h2_send_data, From, Ref, StreamId, Data, Size, EndStream} ->
            recv_more(handle_send_data(State, From, Ref, StreamId, Data, Size, EndStream));
        {h2_send_trailers, From, Ref, StreamId, Trailers} ->
            recv_more(handle_send_trailers(State, From, Ref, StreamId, Trailers));
        {h2_send_response, StreamId, Status, Headers, Body, BodyLen} ->
            recv_more(handle_send_response(State, StreamId, Status, Headers, Body, BodyLen));
        {roadrunner_body_demand, Worker, StreamId} ->
            recv_more(handle_body_demand(State, Worker, StreamId));
        {roadrunner_continue, Worker, StreamId} ->
            recv_more(handle_continue(State, Worker, StreamId));
        {'DOWN', MonRef, process, _Pid, Reason} ->
            recv_more(maybe_exit_when_drained(handle_worker_down(State, MonRef, Reason)));
        {roadrunner_slot, StreamId, Outcome} ->
            %% A refused park drops its stream, which may be the last one
            %% a draining conn was waiting on.
            recv_more(maybe_exit_when_drained(handle_slot(State, StreamId, Outcome)));
        {roadrunner_drain, _Deadline} ->
            recv_more(maybe_exit_when_drained(start_drain(State)))
    after recv_timeout(State) ->
        recv_idle_expired(State)
    end.

%% Idle-wait timeout selection. When no streams are in flight AND the
%% listener opted into `hibernate_after`, park for that (typically
%% shorter) window so `recv_idle_expired/1` can hibernate. Otherwise
%% the GOAWAY idle timeout applies — including whenever streams are
%% active, where worker messages are imminent and hibernating would be
%% pointless.
-spec recv_timeout(#loop{}) -> non_neg_integer().
recv_timeout(#loop{streams = Streams, hibernate_after = Ms}) when
    map_size(Streams) =:= 0, Ms > 0
->
    Ms;
recv_timeout(#loop{idle_timeout = T}) ->
    T.

%% Fired when `recv_more/1` sees no traffic for `recv_timeout/1`. With
%% an empty streams map and `hibernate_after` set, collapse the heap
%% via hibernation; the socket is already `{active, once}`-armed (we
%% reached recv_more through `arm_and_recv/1`), so the next inbound
%% frame — or any worker / `'DOWN'` / drain message — wakes us and
%% `recv_more_hib/1` resumes the loop. Otherwise emit the idle GOAWAY.
-spec recv_idle_expired(#loop{}) -> no_return().
recv_idle_expired(#loop{streams = Streams, hibernate_after = Ms} = State) when
    map_size(Streams) =:= 0, Ms > 0
->
    erlang:hibernate(?MODULE, recv_more_hib, [State]);
recv_idle_expired(State) ->
    idle_goaway(State).

-spec idle_goaway(#loop{}) -> no_return().
idle_goaway(State) ->
    _ = send_goaway(State, protocol_error),
    exit_clean(State).

%% Hibernate re-entry (see `recv_idle_expired/1`). Resumes the unified
%% mailbox loop after an idle conn wakes from `erlang:hibernate/3`.
-doc false.
-spec recv_more_hib(#loop{}) -> no_return().
recv_more_hib(State) ->
    recv_more(State).

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
                    %% Raising INITIAL_WINDOW_SIZE grows open streams' send
                    %% windows (RFC 9113 §6.9.2): ACK, then drain any sends
                    %% blocked at the old window, like the WINDOW_UPDATE path.
                    State2 = apply_header_table_size(Params, State1),
                    _ = send(State2, roadrunner_http2_frame:encode({settings, 1, []})),
                    frame_loop(flush_all_pending_data(State2));
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
                    %% stream error, not a connection error. The stream's
                    %% worker may still be running, so tear the stream
                    %% down the way a peer reset does: the worker is told
                    %% and demonitored (its exit must not find the stream
                    %% gone and take the conn down) and its slot released.
                    _ = send_rst_stream(State, StreamId, flow_control_error),
                    frame_loop(reset_stream(State, StreamId));
                New ->
                    Stream1 = Stream#{send_window := New},
                    State1 = State#loop{streams = Streams#{StreamId := Stream1}},
                    frame_loop(flush_pending_data(State1, StreamId))
            end;
        #{} ->
            %% RFC 9113 §5.1: WINDOW_UPDATE on an idle stream is
            %% PROTOCOL_ERROR. A closed-stream WU (id <=
            %% peer_stream_id) is silently ignored per §6.9.
            case StreamId > State#loop.peer_stream_id of
                true ->
                    _ = send_goaway(State, protocol_error),
                    exit_clean(State);
                false ->
                    frame_loop(State)
            end
    end;
handle_frame(
    {priority, StreamId, #{stream_dependency := StreamId}}, #loop{streams = Streams} = State
) ->
    %% RFC 9113 §5.3.1: a stream cannot depend on itself —
    %% stream-error PROTOCOL_ERROR. A stream we hold is torn down the way
    %% a peer reset does (its worker told and demonitored, its slot
    %% released), so no frame of ours follows the RST_STREAM.
    _ = send_rst_stream(State, StreamId, protocol_error),
    case Streams of
        #{StreamId := _} -> frame_loop(reset_stream(State, StreamId));
        #{} -> frame_loop(State)
    end;
handle_frame({priority, _, _}, State) ->
    frame_loop(State);
handle_frame({rst_stream, StreamId, _}, #loop{streams = Streams} = State) ->
    case Streams of
        #{StreamId := _} ->
            frame_loop(reset_stream(State, StreamId));
        #{} ->
            %% RFC 9113 §5.1: RST_STREAM on an idle stream is
            %% PROTOCOL_ERROR (we never opened it). On a closed
            %% stream (id <= peer_stream_id) the receipt is a no-op
            %% per §5.4 — it's the peer telling us about the
            %% already-closed lifecycle.
            case StreamId > State#loop.peer_stream_id of
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
handle_frame({data, StreamId, Flags, Payload, FlowLen}, State) ->
    on_data(StreamId, Flags, Payload, FlowLen, State);
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

on_headers(StreamId, _Flags, _Priority, _Fragment, State) when StreamId rem 2 =:= 0 ->
    %% RFC 9113 §5.1.1: client-initiated stream IDs are odd.
    _ = send_goaway(State, protocol_error),
    exit_clean(State);
on_headers(StreamId, Flags, Priority, Fragment, #loop{streams = Streams} = State) when
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
                header_len := byte_size(Fragment),
                end_headers := EndHeaders,
                end_stream_seen := true
            },
            case Priority of
                #{stream_dependency := StreamId} ->
                    %% RFC 9113 §5.3.1: a stream cannot depend on itself —
                    %% stream-error PROTOCOL_ERROR, its trailer block still
                    %% decoded (`refuse_block/5`).
                    State1 = update_stream(State, StreamId, Stream1#{refused => protocol_error}),
                    refuse_block(StreamId, EndHeaders, Fragment, protocol_error, State1);
                _ ->
                    State1 = update_stream(State, StreamId, Stream1),
                    State2 =
                        case EndHeaders of
                            true -> State1;
                            false -> State1#loop{awaiting_continuation = StreamId}
                        end,
                    case EndHeaders of
                        true -> finalize_trailers(StreamId, State2);
                        false -> frame_loop(State2)
                    end
            end;
        false ->
            _ = send_goaway(State, protocol_error),
            exit_clean(State)
    end;
on_headers(StreamId, _Flags, _Priority, _Fragment, State) when
    StreamId =< State#loop.peer_stream_id
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
on_headers(StreamId, Flags, #{stream_dependency := StreamId}, Fragment, State) ->
    %% RFC 9113 §5.3.1: a stream cannot depend on itself —
    %% stream-error PROTOCOL_ERROR.
    refuse_new_stream(StreamId, Flags, Fragment, protocol_error, State);
on_headers(StreamId, Flags, _Priority, Fragment, #loop{draining = true} = State) ->
    %% In drain mode — refuse all new streams. The peer already
    %% saw GOAWAY(NO_ERROR); it knows new requests on this conn
    %% won't be served.
    refuse_new_stream(StreamId, Flags, Fragment, refused_stream, State);
on_headers(
    StreamId,
    Flags,
    _Priority,
    Fragment,
    #loop{live_streams = Live, max_concurrent_streams = MaxStreams} = State
) when
    Live >= MaxStreams
->
    %% Over the advertised concurrency limit — refuse the stream.
    refuse_new_stream(StreamId, Flags, Fragment, refused_stream, State);
on_headers(StreamId, Flags, _Priority, Fragment, State) ->
    EndHeaders = (Flags band 16#04) =/= 0,
    EndStream = (Flags band 16#01) =/= 0,
    Stream = new_stream(
        Fragment,
        EndHeaders,
        EndStream,
        State#loop.peer_initial_window,
        State#loop.stream_recv_window_peak,
        State#loop.max_content_length
    ),
    State1 = State#loop{
        streams = (State#loop.streams)#{StreamId => Stream},
        live_streams = State#loop.live_streams + 1,
        last_stream_id = StreamId,
        peer_stream_id = StreamId,
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

%% RFC 9113 §4.3, §6.8: a field block updates the connection's HPACK
%% state even when we refuse its stream, so the block is decoded (once its
%% CONTINUATION frames are in) before the stream is reset; skipping it
%% would desync our decoder from the peer's encoder for every later block.
%% The refused stream still uses its id (§5.1.1), so DATA the peer already
%% sent on it lands on a closed stream, not an idle one, and it never
%% counts toward `max_concurrent_streams`.
-spec refuse_new_stream(
    stream_id(), non_neg_integer(), binary(), roadrunner_http2_frame:error_code(), #loop{}
) -> no_return().
refuse_new_stream(StreamId, Flags, Fragment, Code, State) ->
    EndHeaders = (Flags band 16#04) =/= 0,
    Stream = new_stream(
        Fragment,
        EndHeaders,
        (Flags band 16#01) =/= 0,
        State#loop.peer_initial_window,
        State#loop.stream_recv_window_peak,
        State#loop.max_content_length
    ),
    State1 = State#loop{
        streams = (State#loop.streams)#{StreamId => Stream#{counted := false, refused => Code}},
        peer_stream_id = StreamId
    },
    refuse_block(StreamId, EndHeaders, Fragment, Code, State1).

%% A refused stream's field block: decode it now when complete, or wait
%% for its CONTINUATION frames (`on_continuation/4` finishes it).
-spec refuse_block(
    stream_id(), boolean(), binary(), roadrunner_http2_frame:error_code(), #loop{}
) -> no_return().
refuse_block(StreamId, true, Fragment, Code, State) ->
    reset_refused(StreamId, Fragment, Code, State);
refuse_block(StreamId, false, _Fragment, _Code, State) ->
    frame_loop(State#loop{awaiting_continuation = StreamId}).

%% Decode a refused stream's complete field block for its HPACK side
%% effects only, then reset the stream with `Code`.
-spec reset_refused(stream_id(), iodata(), roadrunner_http2_frame:error_code(), #loop{}) ->
    no_return().
reset_refused(StreamId, Fragment, Code, #loop{hpack_dec = Dec} = State) ->
    case roadrunner_http2_hpack:decode(iolist_to_binary(Fragment), Dec) of
        {ok, _Headers, Dec1} ->
            State1 = State#loop{hpack_dec = Dec1},
            _ = send_rst_stream(State1, StreamId, Code),
            frame_loop(reset_stream(State1, StreamId));
        {error, Reason} ->
            _ = send_goaway(State, decode_error_code(Reason)),
            exit_clean(State)
    end.

%% The GOAWAY code for a field block that did not decode. RFC 9113 §4.3:
%% a decoding error is a connection error of type COMPRESSION_ERROR. An
%% invalid field name or value decodes but makes the message malformed
%% (§8.2.1), a PROTOCOL_ERROR; the decoder stops there, without the rest
%% of the block, so the connection cannot go on either (§5.4.1 lets a
%% stream error be treated as a connection error).
-spec decode_error_code(roadrunner_http2_hpack:decode_error()) ->
    roadrunner_http2_frame:error_code().
decode_error_code(bad_header_name) -> protocol_error;
decode_error_code(bad_header_value) -> protocol_error;
decode_error_code(_) -> compression_error.

new_stream(Fragment, EndHeaders, EndStream, SendWindow, RecvWindow, BodyCap) ->
    #{
        state => open,
        counted => true,
        header_fragment => Fragment,
        header_len => byte_size(Fragment),
        end_headers => EndHeaders,
        end_stream_seen => EndStream,
        headers => undefined,
        body => [],
        body_len => 0,
        body_cap => BodyCap,
        send_window => SendWindow,
        recv_window => RecvWindow,
        worker_pid => undefined,
        worker_ref => undefined,
        pending_sends => queue:new()
    }.

on_continuation(
    StreamId, Flags, Fragment, #loop{streams = Streams, max_header_block = MaxHeaderBlock} = State
) ->
    case Streams of
        #{
            StreamId :=
                #{
                    end_headers := false,
                    header_fragment := Frags,
                    header_len := Len,
                    headers := PriorHeaders
                } = Stream
        } ->
            FragLen = byte_size(Fragment),
            NewLen = Len + FragLen,
            EndHeaders = (Flags band 16#04) =/= 0,
            %% CONTINUATION-flood guard, both variants. The assembled
            %% block crossed the cap (memory exhaustion), or a non-final
            %% empty CONTINUATION made no forward progress (an endless
            %% stream of those pins the conn in header assembly without
            %% ever growing the byte total). Each frame is bounded by
            %% MAX_FRAME_SIZE but neither the cumulative size nor the
            %% frame count is otherwise limited. The per-connection HPACK
            %% context can't be resynced if we skip the block, so this is
            %% a connection error rather than a per-stream reject.
            %% ENHANCE_YOUR_CALM is the RFC 9113 §6.5.2 resource-limit code.
            case NewLen > MaxHeaderBlock orelse (FragLen =:= 0 andalso not EndHeaders) of
                true ->
                    _ = send_goaway(State, enhance_your_calm),
                    exit_clean(State);
                false ->
                    Stream1 = Stream#{
                        header_fragment := [Frags, Fragment],
                        header_len := NewLen,
                        end_headers := EndHeaders
                    },
                    Streams1 = Streams#{StreamId := Stream1},
                    case EndHeaders of
                        false ->
                            frame_loop(State#loop{streams = Streams1});
                        true ->
                            %% Reset awaiting_continuation in the same record
                            %% update on the END_HEADERS path; two sequential
                            %% `#loop{}` updates would copy the record twice.
                            State1 = State#loop{
                                streams = Streams1, awaiting_continuation = undefined
                            },
                            case {Stream1, PriorHeaders} of
                                {#{refused := Code}, _} ->
                                    reset_refused(StreamId, [Frags, Fragment], Code, State1);
                                {_, undefined} ->
                                    finalize_headers(StreamId, State1);
                                {_, _} ->
                                    finalize_trailers(StreamId, State1)
                            end
                    end
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
    case roadrunner_http2_hpack:decode(iolist_to_binary(Fragment), Dec) of
        {ok, _Trailers, Dec1} ->
            Stream1 = Stream#{header_fragment := <<>>},
            State1 = State#loop{
                hpack_dec = Dec1,
                streams = Streams#{StreamId := Stream1}
            },
            case State1#loop.body_buffering of
                auto -> dispatch_stream(StreamId, State1);
                manual -> body_in(StreamId, Stream1, State1)
            end;
        {error, Reason} ->
            _ = send_goaway(State, decode_error_code(Reason)),
            exit_clean(State)
    end.

%% Decode the accumulated HPACK fragment, store decoded headers on
%% the stream entry. If END_STREAM was set on the HEADERS frame,
%% dispatch the worker now (no body); otherwise wait for DATA.
finalize_headers(
    StreamId, #loop{streams = Streams, hpack_dec = Dec, max_header_list_size = MaxHLS} = State
) ->
    #{
        StreamId := #{
            header_fragment := Fragment,
            end_stream_seen := EndStreamSeen
        } = Stream
    } = Streams,
    case roadrunner_http2_hpack:decode(iolist_to_binary(Fragment), Dec) of
        {ok, Headers, Dec1} ->
            Stream1 = Stream#{headers := Headers, header_fragment := <<>>},
            %% Commit the mutated HPACK context even if we reject below: the
            %% decode advanced the dynamic table, so dropping it would desync
            %% our decoder from the peer's encoder for every later block.
            State1 = State#loop{
                hpack_dec = Dec1,
                streams = Streams#{StreamId := Stream1}
            },
            case roadrunner_http:header_list_size(Headers) > MaxHLS of
                true ->
                    %% RFC 9113 §6.5.2: the decoded list exceeds the
                    %% MAX_HEADER_LIST_SIZE we advertised. Answer 431, then
                    %% RST_STREAM(NO_ERROR) (decode succeeded, so the
                    %% connection is intact), and drop the stream — no worker
                    %% is dispatched until END_STREAM.
                    Resp = ~"Request Header Fields Too Large",
                    State2 = encode_and_send_response_atomic(
                        State1,
                        StreamId,
                        431,
                        [{~"content-type", ~"text/plain"}],
                        Resp,
                        byte_size(Resp)
                    ),
                    _ = send_rst_stream(State2, StreamId, no_error),
                    frame_loop(remove_stream(State2, StreamId));
                false ->
                    case EndStreamSeen of
                        true -> dispatch_stream(StreamId, State1);
                        false -> await_body(StreamId, Headers, State1)
                    end
            end;
        {error, Reason} ->
            _ = send_goaway(State, decode_error_code(Reason)),
            exit_clean(State)
    end.

%% A request whose body is still to come waits for its DATA, or, in manual
%% body mode, has its worker start now and read it (`dispatch_reading/3`).
%% RFC 9110 §10.1.1: one that expects `100-continue` (HTTP/2 being
%% "HTTP/1.1 or later") gets an answer instead of leaving the client to time
%% out its wait: a 413 when its declared `content-length` is already over
%% its route's body cap, the status its body would earn anyway, else the
%% interim 100 that asks for the body, sent at once, or in manual mode on the
%% worker's first read, so a handler that answers from the headers alone
%% never has the client upload the body.
-spec await_body(stream_id(), roadrunner_http:headers(), #loop{}) -> no_return().
await_body(StreamId, Headers, #loop{proto_opts = ProtoOpts, max_content_length = MaxCL} = State) ->
    case roadrunner_conn:expect_answer(ProtoOpts, Headers, MaxCL) of
        too_large ->
            reject_too_large(State, StreamId);
        malformed ->
            _ = send_rst_stream(State, StreamId, protocol_error),
            frame_loop(remove_stream(State, StreamId));
        continue ->
            body_wanted(StreamId, State);
        none ->
            body_follows(StreamId, State)
    end.

%% A body expected with `100-continue`, to be asked for.
-spec body_wanted(stream_id(), #loop{}) -> no_return().
body_wanted(StreamId, #loop{body_buffering = auto} = State) ->
    frame_loop(send_continue(State, StreamId));
body_wanted(StreamId, State) ->
    dispatch_reading(StreamId, true, State).

%% A body on its way, the client expecting nothing.
-spec body_follows(stream_id(), #loop{}) -> no_return().
body_follows(_StreamId, #loop{body_buffering = auto} = State) ->
    frame_loop(State);
body_follows(StreamId, State) ->
    dispatch_reading(StreamId, false, State).

%% The interim `100 (Continue)`: a HEADERS frame with `:status` alone and
%% no END_STREAM, the final response following on the same stream.
-spec send_continue(#loop{}, stream_id()) -> #loop{}.
send_continue(#loop{hpack_enc = Enc} = State, StreamId) ->
    {Block, Enc1} = roadrunner_http2_hpack:encode([{~":status", ~"100"}], Enc),
    _ = send(State, roadrunner_http2_frame:encode({headers, StreamId, 16#04, undefined, Block})),
    State#loop{hpack_enc = Enc1}.

%% RFC 9113 §8.1: the request body is over its cap. Answer 413
%% before the full request, then RST_STREAM(NO_ERROR) to ask the client to
%% stop sending the rest, and drop the stream (no worker was dispatched,
%% dispatch is at END_STREAM).
-spec reject_too_large(#loop{}, stream_id()) -> no_return().
reject_too_large(State, StreamId) ->
    Resp = ~"Payload Too Large",
    State1 = encode_and_send_response_atomic(
        State, StreamId, 413, [{~"content-type", ~"text/plain"}], Resp, byte_size(Resp)
    ),
    _ = send_rst_stream(State1, StreamId, no_error),
    frame_loop(remove_stream(State1, StreamId)).

%% --- DATA ---

on_data(StreamId, _Flags, _Payload, _FlowLen, State) when StreamId > State#loop.peer_stream_id ->
    %% RFC 9113 §5.1: DATA on an idle stream is PROTOCOL_ERROR.
    _ = send_goaway(State, protocol_error),
    exit_clean(State);
on_data(StreamId, _Flags, _Payload, FlowLen, #loop{streams = Streams} = State) when
    not is_map_key(StreamId, Streams)
->
    %% RFC 9113 §6.1: DATA on a closed stream is STREAM_CLOSED. The bytes
    %% still consumed the peer's connection-level send window (§6.9.1);
    %% return the full on-wire `FlowLen` (padding included) since we're
    %% discarding them, so the conn window doesn't drift down across resets.
    _ = send_rst_stream(State, StreamId, stream_closed),
    frame_loop(replenish_conn_window(State, FlowLen));
on_data(StreamId, Flags, Payload, FlowLen, #loop{streams = Streams} = State) ->
    case Streams of
        #{
            StreamId :=
                #{
                    end_stream_seen := false,
                    body := Body,
                    body_len := Len,
                    body_cap := Cap,
                    recv_window := RW
                } = Stream
        } ->
            %% Flow control charges the full on-wire `FlowLen` (RFC 9113
            %% §6.9.1: pad-length byte + padding count). Past the window
            %% gates, the body cap and buffering use the stripped `Payload`
            %% the handler will see, so its length is only needed there. A
            %% frame we reject instead of buffering still counted against the
            %% peer's connection window (§6.9), so its `FlowLen` goes straight
            %% back, as for DATA on a closed stream; left uncounted on our side
            %% it would never trigger a refill, and each rejection would shrink
            %% the window the peer can send in for the life of the connection.
            ConnWindow = State#loop.conn_recv_window,
            if
                FlowLen > ConnWindow ->
                    %% RFC 9113 §6.9.1: more DATA than the connection-level
                    %% receive window permits is a connection-level
                    %% FLOW_CONTROL_ERROR.
                    _ = send_goaway(State, flow_control_error),
                    exit_clean(State);
                FlowLen > RW ->
                    %% More DATA than the stream-level window permits is a
                    %% stream-level FLOW_CONTROL_ERROR.
                    _ = send_rst_stream(State, StreamId, flow_control_error),
                    frame_loop(replenish_conn_window(reset_stream(State, StreamId), FlowLen));
                true ->
                    NewLen = Len + byte_size(Payload),
                    EndStream = (Flags band 16#01) =/= 0,
                    case stream_body_cap(NewLen, Cap, Stream, State) of
                        BodyCap when NewLen > BodyCap ->
                            body_over_cap(StreamId, Stream, NewLen, EndStream, FlowLen, State);
                        BodyCap ->
                            Stream1 = Stream#{
                                body := [Body, Payload],
                                body_len := NewLen,
                                body_cap := BodyCap,
                                end_stream_seen := EndStream,
                                recv_window := RW - FlowLen
                            },
                            State1 = State#loop{
                                streams = Streams#{StreamId := Stream1},
                                conn_recv_window = ConnWindow - FlowLen
                            },
                            case State1#loop.body_buffering of
                                auto ->
                                    State2 = maybe_refill_recv_windows(State1, StreamId),
                                    case EndStream of
                                        true -> dispatch_stream(StreamId, State2);
                                        false -> frame_loop(State2)
                                    end;
                                manual ->
                                    %% Every stream with a body is already
                                    %% dispatched to a reading worker.
                                    body_in(StreamId, Stream1, refill_conn_window(State1))
                            end
                    end
            end;
        #{StreamId := _} ->
            %% RFC 9113 §5.1: the peer already sent END_STREAM (the
            %% stream is half-closed remote, with a worker dispatched),
            %% so any further DATA is a STREAM_CLOSED stream error.
            %% Reset the peer and unwind the in-flight worker rather
            %% than appending to a request body that was already
            %% delivered (which would also re-dispatch on a second
            %% END_STREAM).
            _ = send_rst_stream(State, StreamId, stream_closed),
            frame_loop(replenish_conn_window(reset_stream(State, StreamId), FlowLen))
    end.

%% A DATA frame taking the body to `NewLen` bytes, past its cap. Before
%% dispatch (auto mode) the 413 is the request's answer. In manual mode the
%% worker is already running, so the frame is dropped, as is the rest of the
%% body, and the worker's read fails with `content_length_too_large` (its
%% next one, or the one it is waiting on), as on HTTP/1.1: the handler
%% answers. The frame's window goes back to the connection; the stream's
%% stays spent, so the client soon stops sending.
-spec body_over_cap(
    stream_id(), map(), non_neg_integer(), boolean(), non_neg_integer(), #loop{}
) -> no_return().
body_over_cap(
    StreamId, #{reader := Reader, recv_window := RW} = Stream, NewLen, EndStream, FlowLen, State
) ->
    ok = roadrunner_conn:send_body_error(Reader, StreamId, content_length_too_large),
    Stream1 = Stream#{
        body := [],
        body_len := NewLen,
        end_stream_seen := EndStream,
        recv_window := RW - FlowLen,
        reader := undefined,
        body_error := content_length_too_large
    },
    State1 = replenish_conn_window(update_stream(State, StreamId, Stream1), FlowLen),
    frame_loop(ended_after_answer(State1, StreamId));
body_over_cap(StreamId, _Stream, _NewLen, _EndStream, FlowLen, State) ->
    reject_too_large(replenish_conn_window(State, FlowLen), StreamId).

%% DATA, or the trailers ending it, for a manual-mode stream, `Stream`
%% already holding it in `body`. A body that outruns its declared
%% `content-length`, or ends short of it, is malformed (RFC 9113 §8.1.1),
%% so the stream is reset. Otherwise the worker waiting for DATA gets it
%% now, or it waits for the worker's next demand; a stream whose response
%% already went out drops it instead, as nobody will read it (the worker's
%% exit resets the client's side, `finish_stream/2`).
-spec body_in(stream_id(), map(), #loop{}) -> no_return().
body_in(
    StreamId, #{body_len := Len, end_stream_seen := Ended, declared := Declared} = Stream, State
) ->
    case roadrunner_http:body_length_fits(Declared, Len, Ended) of
        false ->
            _ = send_rst_stream(State, StreamId, protocol_error),
            frame_loop(reset_stream(State, StreamId));
        true ->
            State1 =
                case Stream of
                    #{state := closed} -> update_stream(State, StreamId, Stream#{body := []});
                    #{reader := Reader} when is_pid(Reader) -> deliver(State, StreamId, Stream);
                    _ -> State
                end,
            frame_loop(ended_after_answer(State1, StreamId))
    end.

%% Hand a manual-mode stream's received DATA to its waiting worker, `Fin`
%% marking the body's end, and give the stream its receive window back now
%% that the DATA has left the connection: what a stream holds for its
%% worker stays within one window, however slowly the worker reads.
-spec deliver(#loop{}, stream_id(), map()) -> #loop{}.
deliver(State, StreamId, #{reader := Reader, body := Body, end_stream_seen := Ended} = Stream) ->
    ok = roadrunner_conn:send_body(Reader, StreamId, Body, Ended),
    State1 = update_stream(State, StreamId, Stream#{body := [], reader := undefined}),
    case Ended of
        true ->
            State1;
        false ->
            case build_stream_refill(State1, StreamId) of
                {[], State2} ->
                    State2;
                {Frame, State2} ->
                    _ = send(State2, Frame),
                    State2
            end
    end.

%% A manual-mode stream whose response went out before its client finished
%% the body is closed both ways once it does, so it stops counting toward
%% `max_concurrent_streams` (`close_stream_send_side/2` does this when our
%% side ends last).
-spec ended_after_answer(#loop{}, stream_id()) -> #loop{}.
ended_after_answer(#loop{streams = Streams} = State, StreamId) ->
    case Streams of
        #{StreamId := #{end_stream_seen := true, state := closed}} ->
            uncount_stream(State, StreamId);
        _ ->
            State
    end.

%% The worker of a manual-mode stream asks for the body's next DATA
%% (`roadrunner_conn:stream_body_reader/5`). The first ask sends a 100
%% Continue the client is holding its body back for. It gets what has
%% arrived, the body's end once it came, or, with nothing yet, the next
%% DATA as it arrives (`body_in/3`). A body over its cap fails the read, and
%% a stream that is gone, or whose response already went out, ends it.
-spec handle_body_demand(#loop{}, pid(), stream_id()) -> #loop{}.
handle_body_demand(#loop{streams = Streams} = State, Worker, StreamId) ->
    case Streams of
        #{StreamId := #{reader := _, state := Side, body_error := undefined} = Stream} when
            Side =/= closed
        ->
            {Stream1, State1} =
                case Stream of
                    #{continue_owed := true} ->
                        {Stream#{continue_owed := false}, send_continue(State, StreamId)};
                    _ ->
                        {Stream, State}
                end,
            #{body := Body, end_stream_seen := Ended} = Stream1,
            case Ended orelse iolist_size(Body) > 0 of
                true -> deliver(State1, StreamId, Stream1#{reader := Worker});
                false -> update_stream(State1, StreamId, Stream1#{reader := Worker})
            end;
        #{StreamId := #{reader := _, body_error := Reason}} when Reason =/= undefined ->
            ok = roadrunner_conn:send_body_error(Worker, StreamId, Reason),
            State;
        _ ->
            ok = roadrunner_conn:send_body_error(Worker, StreamId, closed),
            State
    end.

%% A worker about to stream its response while the 100 Continue is still
%% owed (`roadrunner_conn:continue_before_stream/1`): it goes out now, ahead
%% of the response HEADERS the worker sends next, and no later read sends
%% another. The worker waits for the answer either way.
-spec handle_continue(#loop{}, pid(), stream_id()) -> #loop{}.
handle_continue(#loop{streams = Streams} = State, Worker, StreamId) ->
    State1 =
        case Streams of
            #{
                StreamId := #{continue_owed := true, state := Side, body_error := undefined} =
                    Stream
            } when
                Side =/= closed
            ->
                update_stream(
                    send_continue(State, StreamId), StreamId, Stream#{continue_owed := false}
                );
            _ ->
                State
        end,
    _ = Worker ! {roadrunner_continued, StreamId},
    State1.

-spec refill_conn_window(#loop{}) -> #loop{}.
refill_conn_window(State) ->
    case build_conn_refill(State) of
        {[], State1} ->
            State1;
        {Frame, State1} ->
            _ = send(State1, Frame),
            State1
    end.

%% The cap a DATA frame that takes the body to `NewLen` bytes is held to:
%% the stream's own `Cap` while the body fits in it, else its route's,
%% looked up only once a body outgrows the cap it has (the listener's, at
%% first) and kept on the stream from then on.
-spec stream_body_cap(non_neg_integer(), non_neg_integer(), map(), #loop{}) ->
    non_neg_integer().
stream_body_cap(NewLen, Cap, _Stream, _State) when NewLen =< Cap ->
    Cap;
stream_body_cap(
    _NewLen,
    _Cap,
    #{headers := Headers},
    #loop{proto_opts = #{dispatch := Dispatch}, max_content_length = MaxCL}
) ->
    roadrunner_conn:route_body_cap(Dispatch, Headers, MaxCL).

%% Return `N` bytes of connection-level receive window to the peer after
%% discarding a DATA payload on a closed / reset stream (RFC 9113
%% §6.9.1: flow-controlled bytes count against the conn window
%% regardless of stream state). A zero-length payload consumed no
%% window, and a WINDOW_UPDATE with a 0 increment is itself a protocol
%% error, so skip it.
-spec replenish_conn_window(#loop{}, non_neg_integer()) -> #loop{}.
replenish_conn_window(State, 0) ->
    State;
replenish_conn_window(State, N) ->
    _ = send(State, roadrunner_http2_frame:encode({window_update, 0, N})),
    State.

%% Refill the conn-level + stream-level recv windows whenever they
%% drop below the configured threshold. Both refills can fire on
%% the same `on_data` event (one DATA payload drains both windows
%% past the threshold simultaneously); when that happens, the two
%% WINDOW_UPDATE frames go out in a single `send/2` so they share
%% one trip through the ssl gen_statem (or `gen_tcp:send` for h2c)
%% instead of paying two.
-spec maybe_refill_recv_windows(#loop{}, stream_id()) -> #loop{}.
maybe_refill_recv_windows(State, StreamId) ->
    {ConnFrame, State1} = build_conn_refill(State),
    {StreamFrame, State2} = build_stream_refill(State1, StreamId),
    case {ConnFrame, StreamFrame} of
        {[], []} ->
            State2;
        {_, _} ->
            _ = send(State2, [ConnFrame, StreamFrame]),
            State2
    end.

build_conn_refill(
    #loop{
        conn_recv_window = W,
        recv_window_peak = Peak,
        recv_window_threshold = Threshold
    } = State
) when W < Threshold ->
    Inc = Peak - W,
    {roadrunner_http2_frame:encode({window_update, 0, Inc}), State#loop{conn_recv_window = W + Inc}};
build_conn_refill(State) ->
    {[], State}.

build_stream_refill(
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
            {roadrunner_http2_frame:encode({window_update, StreamId, Inc}), State#loop{
                streams = Streams#{StreamId := Stream#{recv_window := W + Inc}}
            }};
        true ->
            {[], State}
    end.

%% =============================================================================
%% Stream dispatch — spawn a worker
%% =============================================================================

%% Dispatch a request whose body is complete (auto mode, or no body at
%% all): its worker gets the buffered body, once it agrees with any
%% declared `content-length`.
dispatch_stream(StreamId, #loop{streams = Streams} = State) ->
    #{
        StreamId := #{
            headers := Headers,
            body_len := BodyLen,
            body := BodyIolist
        } = Stream
    } = Streams,
    case
        roadrunner_http:body_length_fits(
            roadrunner_http:request_content_length(Headers), BodyLen, true
        )
    of
        true ->
            %% Pass the iolist body straight through to the worker's
            %% Req map. The body field is typed `iodata()`; handlers
            %% that need a flat binary call `iolist_to_binary/1`.
            Dispatched = Stream#{state := half_closed_remote, body := []},
            dispatch_request(StreamId, Dispatched, Headers, {body, BodyIolist}, State);
        false ->
            %% RFC 9113 §8.1.2.6: content-length / DATA-payload
            %% mismatch is a stream-error PROTOCOL_ERROR.
            _ = send_rst_stream(State, StreamId, protocol_error),
            frame_loop(remove_stream(State, StreamId))
    end.

%% Dispatch a manual-mode request whose body is still to come: its worker
%% starts now and reads the body through a reader
%% (`roadrunner_conn:stream_body_reader/5`), DATA reaching it as it asks
%% (`handle_body_demand/3`) within `request_timeout`. `ContinueOwed` is a
%% 100 Continue its first ask sends. A malformed `content-length` resets
%% the stream, as at END_STREAM in auto mode.
-spec dispatch_reading(stream_id(), boolean(), #loop{}) -> no_return().
dispatch_reading(StreamId, ContinueOwed, #loop{streams = Streams} = State) ->
    #{StreamId := #{headers := Headers} = Stream} = Streams,
    case roadrunner_http:request_content_length(Headers) of
        error ->
            _ = send_rst_stream(State, StreamId, protocol_error),
            frame_loop(remove_stream(State, StreamId));
        Declared ->
            Reading = Stream#{
                reader => undefined,
                continue_owed => ContinueOwed,
                body_error => undefined,
                declared => Declared
            },
            dispatch_request(StreamId, Reading, Headers, reader, State)
    end.

%% Build the request of `Stream` (already in the state it is dispatched
%% in) and admit it: refused over its rate, then given a worker, parked for
%% an in-flight slot, or refused over the ceiling. Its body is `{body, _}`
%% (buffered) or `reader` (manual mode).
-spec dispatch_request(
    stream_id(), map(), roadrunner_http:headers(), {body, iodata()} | reader, #loop{}
) ->
    no_return().
dispatch_request(
    StreamId,
    Stream,
    Headers,
    Body,
    #loop{
        streams = Streams,
        proto_opts = ProtoOpts,
        peer = Peer,
        scheme = Scheme,
        listener_name = ListenerName,
        max_concurrent_requests = MaxConcReq,
        inflight_counter = InflightCounter,
        overload = Overload
    } = State
) ->
    {RequestId, NewBuf} = roadrunner_conn:generate_request_id(State#loop.req_id_buffer),
    RequestContext = #{
        peer => Peer,
        scheme => Scheme,
        listener_name => ListenerName,
        request_id => RequestId
    },
    case roadrunner_http2_request:from_headers(Headers, buffered_body(Body), RequestContext) of
        {ok, Req0} ->
            Req = request_body(
                StreamId,
                Stream,
                Body,
                roadrunner_conn:with_client_ip(Req0, State#loop.real_ip, Peer),
                State
            ),
            StateBuf = State#loop{req_id_buffer = NewBuf},
            case rate_limit_refused(StateBuf, StreamId, Req) of
                {refused, State1} ->
                    %% Per-peer rate exceeded: 429 + RST(no_error) sent,
                    %% no worker spawned. 429 (not REFUSED_STREAM) so the
                    %% client backs off per Retry-After instead of
                    %% retrying the stream immediately.
                    frame_loop(remove_stream(State1, StreamId));
                ok ->
                    case
                        roadrunner_conn:acquire_request_slot(
                            MaxConcReq, InflightCounter, Overload, StreamId
                        )
                    of
                        true ->
                            {WorkerPid, MonRef} = roadrunner_http2_stream_worker:start(
                                self(), StreamId, Req, ProtoOpts
                            ),
                            Stream1 = Stream#{
                                worker_pid := WorkerPid,
                                worker_ref := MonRef
                            },
                            frame_loop(StateBuf#loop{
                                streams = Streams#{StreamId := Stream1},
                                worker_refs = (StateBuf#loop.worker_refs)#{MonRef => StreamId}
                            });
                        queued ->
                            %% Over the ceiling, but this listener
                            %% parks rather than sheds. Keep the
                            %% assembled request and go back to the
                            %% frame loop; the grant arrives as a
                            %% message.
                            Awaiting = StateBuf#loop.awaiting_slot,
                            frame_loop(StateBuf#loop{
                                streams = Streams#{StreamId := Stream},
                                awaiting_slot = Awaiting#{StreamId => Req}
                            });
                        false ->
                            %% Listener-wide in-flight ceiling reached —
                            %% refuse with retry-safe REFUSED_STREAM, no
                            %% worker spawned.
                            ok = throttle_stream(StateBuf, ListenerName),
                            _ = send_rst_stream(StateBuf, StreamId, refused_stream),
                            frame_loop(remove_stream(StateBuf, StreamId))
                    end
            end;
        {error, Reason} when Reason =:= not_implemented; Reason =:= unsupported_expectation ->
            %% A well-formed request roadrunner can't serve, answered as on
            %% HTTP/1.1, then the stream closed: 501 for a CONNECT (no
            %% tunnels), 417 for an expectation other than `100-continue`.
            Status = roadrunner_conn:parse_error_status(Reason),
            State1 = encode_and_send_response_atomic(State, StreamId, Status, [], ~"", 0),
            _ = send_rst_stream(State1, StreamId, no_error),
            frame_loop(remove_stream(State1#loop{req_id_buffer = NewBuf}, StreamId));
        {error, _Reason} ->
            _ = send_rst_stream(State, StreamId, protocol_error),
            frame_loop(remove_stream(State#loop{req_id_buffer = NewBuf}, StreamId))
    end.

-spec buffered_body({body, iodata()} | reader) -> iodata().
buffered_body({body, Body}) -> Body;
buffered_body(reader) -> <<>>.

%% A manual-mode request reads its body through a reader instead of the
%% buffered `body`.
-spec request_body(
    stream_id(), map(), {body, iodata()} | reader, roadrunner_req:request(), #loop{}
) ->
    roadrunner_req:request().
request_body(_StreamId, _Stream, {body, _Body}, Req, _State) ->
    Req;
request_body(
    StreamId,
    #{continue_owed := ContinueOwed},
    reader,
    Req,
    #loop{request_timeout = Timeout, max_content_length = MaxCL}
) ->
    roadrunner_conn:with_body_reader(Req, StreamId, Timeout, MaxCL, ContinueOwed).

%% =============================================================================
%% Worker → conn message handlers
%% =============================================================================

%% Single-shot buffered-response path. Encodes HEADERS + (optional)
%% DATA(END_STREAM) and writes them in ONE `ssl:send/2`, halving
%% the per-response gen_call cost through `tls_sender`. Falls back
%% to the two-frame two-message path when the body doesn't fit a
%% single DATA frame AND the current window.
%%
%% This is the worker's final message for its stream and it does not
%% wait for an ack, so nothing is sent back: a body that flow control
%% holds is queued with no one to wake (`finish_stream/2` keeps the
%% stream until it drains), and a response for a stream already reset
%% or closed is dropped, its worker being gone or about to be.
handle_send_response(State, StreamId, Status, Headers, Body, BodyLen) ->
    case stream_open(State, StreamId) of
        not_open ->
            State;
        Stream ->
            case BodyLen of
                0 ->
                    %% Empty body — single HEADERS frame with END_STREAM,
                    %% same wire shape as `handle_send_headers/_, true)`.
                    encode_and_send_headers(State, StreamId, Status, Headers, true);
                _ ->
                    %% Short-circuit: skip the `window_budget/2` lookup
                    %% when the body already won't fit in one frame.
                    case
                        BodyLen =< ?MAX_FRAME_SIZE andalso
                            window_budget(State, Stream) >= BodyLen
                    of
                        true ->
                            encode_and_send_response_atomic(
                                State, StreamId, Status, Headers, Body, BodyLen
                            );
                        false ->
                            %% Body too big for one frame OR window too
                            %% narrow — emit HEADERS now, hand the body to
                            %% `try_send_data` which fragments / queues it.
                            State1 = encode_and_send_headers(
                                State, StreamId, Status, Headers, false
                            ),
                            #{StreamId := Stream1} = State1#loop.streams,
                            try_send_data(
                                State1, Stream1, StreamId, undefined, undefined, Body, BodyLen, true
                            )
                    end
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

handle_send_data(State, From, Ref, StreamId, Data, Size, EndStream) ->
    case stream_open(State, StreamId) of
        not_open ->
            _ = (From ! {h2_stream_reset, StreamId}),
            State;
        Stream ->
            try_send_data(State, Stream, StreamId, From, Ref, Data, Size, EndStream)
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

handle_worker_down(#loop{worker_refs = Refs} = State, MonRef, Reason) ->
    case Refs of
        #{MonRef := StreamId} ->
            %% Release the in-flight slot exactly once, tied to removing the
            %% worker ref so a worker is accounted for by its `DOWN` here or
            %% by the conn's clean exit, never both.
            ok = roadrunner_conn:release_request_slot(
                State#loop.max_concurrent_requests,
                State#loop.inflight_counter,
                State#loop.overload
            ),
            State1 = State#loop{worker_refs = maps:remove(MonRef, Refs)},
            case Reason of
                normal -> finish_stream(State1, StreamId);
                _ -> abort_stream(State1, StreamId, internal_error)
            end;
        #{} ->
            State
    end.

%% A worker exited normally. Its response is complete once our END_STREAM
%% is on the wire (the send side is `closed`, see
%% `close_stream_send_side/2`), or when flow control still holds part of a
%% buffered body, which the worker hands over without waiting
%% (`handle_send_response/6`): then the stream stays, its worker fields
%% cleared, until a window update drains the queue and `retire_drained/2`
%% drops it. Anything else is a response the worker left unfinished
%% without crashing (a stream fun or loop handler calling `exit(normal)`,
%% a loop worker stopped by `sys:terminate/2`), so the stream is reset
%% with INTERNAL_ERROR, as for a crash, instead of left open with the
%% client waiting for an end that never comes. The stream is always still
%% there: every path that drops a stream under a live worker demonitors
%% that worker first (`reset_stream/2`). In manual body mode the response
%% can end before the client's body does (a handler answering without
%% reading it all); RFC 9113 §8.1 lets the server then ask the client to
%% stop sending with RST_STREAM(NO_ERROR).
-spec finish_stream(#loop{}, stream_id()) -> #loop{}.
finish_stream(#loop{streams = Streams} = State, StreamId) ->
    #{StreamId := #{pending_sends := Pending} = Stream} = Streams,
    case {queue:is_empty(Pending), Stream} of
        {true, #{state := closed, end_stream_seen := true}} ->
            remove_stream(State, StreamId);
        {true, #{state := closed}} ->
            _ = send_rst_stream(State, StreamId, no_error),
            remove_stream(State, StreamId);
        {true, _} ->
            abort_stream(State, StreamId, internal_error);
        {false, _} ->
            update_stream(State, StreamId, Stream#{
                worker_pid := undefined, worker_ref := undefined
            })
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
    %% §8.1.2 (see `roadrunner_handler:response/0`), and the worker already
    %% answered 500 for any CR/LF/NUL (`roadrunner_stream_worker`), so a
    %% handler bug cannot crash this process, which every stream shares.
    %% Strip the connection-specific fields RFC 9113 §8.2.2 forbids h2 from
    %% generating.
    WireHeaders = roadrunner_http:strip_connection_specific_fields(Headers),
    AllHeaders =
        [{~":status", StatusBin} | roadrunner_http:auto_headers(WireHeaders, State#loop.alt_svc)],
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

%% HEADERS + DATA (END_STREAM) packed into ONE `ssl:send/2`. Body
%% is iodata; the frame encoder accepts it and the transport
%% `writev()`s the assembled iolist so no flatten happens here.
%% Caller has already verified `BodyLen` fits in a single DATA
%% frame AND in the current send window. Consumes the window by
%% `BodyLen` and marks the stream's send side closed.
encode_and_send_response_atomic(
    #loop{hpack_enc = Enc, streams = Streams} = State,
    StreamId,
    Status,
    Headers,
    Body,
    BodyLen
) ->
    #{StreamId := Stream} = Streams,
    StatusBin = integer_to_binary(Status),
    %% Names already lowercase per `roadrunner_handler:response/0` contract,
    %% CR/LF/NUL already answered with 500 by the worker; strip the
    %% connection-specific fields RFC 9113 §8.2.2 forbids h2 from generating.
    WireHeaders = roadrunner_http:strip_connection_specific_fields(Headers),
    AllHeaders =
        [{~":status", StatusBin} | roadrunner_http:auto_headers(WireHeaders, State#loop.alt_svc)],
    {HpackBlock, Enc1} = roadrunner_http2_hpack:encode(AllHeaders, Enc),
    HFrame = roadrunner_http2_frame:encode(
        {headers, StreamId, 16#04, undefined, HpackBlock}
    ),
    DFrame = roadrunner_http2_frame:encode({data, StreamId, 16#01, Body}),
    _ = send(State, [HFrame, DFrame]),
    State1 = State#loop{hpack_enc = Enc1},
    State2 = consume_send_window(State1, StreamId, Stream, BodyLen),
    close_stream_send_side(State2, StreamId).

encode_and_send_trailers(#loop{hpack_enc = Enc} = State, StreamId, Trailers) ->
    %% Trailer names already lowercase per `roadrunner_handler:response/0`;
    %% the worker already checked them for CR/LF/NUL and stripped the
    %% connection-specific fields (`roadrunner_http2_stream_response`).
    {HpackBlock, Enc1} = roadrunner_http2_hpack:encode(Trailers, Enc),
    Frame = roadrunner_http2_frame:encode(
        {headers, StreamId, 16#04 bor 16#01, undefined, HpackBlock}
    ),
    _ = send(State, Frame),
    State1 = State#loop{hpack_enc = Enc1},
    close_stream_send_side(State1, StreamId).

%% Mark the send side closed. Future worker writes on this stream
%% get `{h2_stream_reset, _}` so they unwind cleanly. Every path that
%% puts the response's final END_STREAM on the wire funnels through
%% here, so this is also where the stream stops counting toward the
%% advertised concurrency limit: with the peer's END_STREAM already
%% seen, the stream is closed on both sides (RFC 9113 §5.1.2), and a
%% compliant client may open a replacement the instant it reads our
%% END_STREAM — before the worker's DOWN retires the map entry. If the
%% peer is still sending (no END_STREAM yet), the stream is
%% half-closed(local), keeps counting, and is uncounted on teardown.
close_stream_send_side(#loop{streams = Streams} = State, StreamId) ->
    #{StreamId := Stream} = Streams,
    case Stream of
        #{end_stream_seen := true, counted := true} ->
            State#loop{
                streams = Streams#{StreamId := Stream#{state := closed, counted := false}},
                live_streams = State#loop.live_streams - 1
            };
        _ ->
            State#loop{streams = Streams#{StreamId := Stream#{state := closed}}}
    end.

%% =============================================================================
%% DATA send + flow control
%% =============================================================================

%% Try to send `Data` as DATA frame(s). If both windows allow, send
%% everything and ack. If a partial chunk fits, send what we can
%% and queue the rest. If nothing fits, queue the whole thing.
%%
%% `Size` is `iolist_size(Data)`: taken by the worker for a fresh send,
%% recomputed for a queued remainder (`drain_pending/3`).
%%
%% `Data` is iodata. The single-frame branch in `send_data_chunks`
%% passes it straight to the frame encoder (which accepts iodata)
%% and the transport `writev()`s it, so the common streaming case
%% never materialises to a flat binary.
%%
%% Empty `Data` always means `EndStream = true` because workers
%% short-circuit empty `nofin` sends — the empty-body case here
%% doesn't consume any window bytes, so it bypasses the window
%% check entirely.
try_send_data(State, Stream, StreamId, From, Ref, Data, Size, EndStream) ->
    case Size of
        0 when EndStream ->
            %% Final empty DATA frame closes the stream.
            Frame = roadrunner_http2_frame:encode({data, StreamId, 16#01, <<>>}),
            _ = send(State, Frame),
            ok = ack(From, Ref),
            close_stream_send_side(State, StreamId);
        Total ->
            %% `send_data_chunks/8` owns the window check: it queues the
            %% whole send when the window is closed (its `0 ->` clause).
            send_data_chunks(State, Stream, StreamId, From, Ref, Data, Total, EndStream)
    end.

send_data_chunks(State, Stream, StreamId, From, Ref, Data, Total, EndStream) ->
    Available = window_budget(State, Stream),
    case min(Total, Available) of
        0 ->
            %% Window closed mid-body — queue the remainder.
            Stream1 = enqueue_pending(Stream, {data, Ref, From, Data, EndStream}),
            update_stream(State, StreamId, Stream1);
        Total when Total =< ?MAX_FRAME_SIZE ->
            %% Whole body fits the window in a single DATA frame: ship
            %% iodata straight through. The frame encoder accepts iodata
            %% and the transport's writev() avoids the flatten.
            Flags =
                if
                    EndStream -> 16#01;
                    true -> 0
                end,
            Frame = roadrunner_http2_frame:encode({data, StreamId, Flags, Data}),
            _ = send(State, Frame),
            State1 = consume_send_window(State, StreamId, Stream, Total),
            ok = ack(From, Ref),
            if
                EndStream -> close_stream_send_side(State1, StreamId);
                true -> State1
            end;
        Sendable ->
            %% Multiple DATA frames: the body is larger than
            %% ?MAX_FRAME_SIZE and/or the window only covers `Sendable`
            %% of `Total`. Encode every frame that fits and emit them in
            %% ONE transport send (one writev) rather than one ssl:send
            %% per frame — the wire bytes are byte-for-byte identical,
            %% only the syscall + tls_sender round-trip count drops.
            %% Materialise once so the slices are sub-binaries.
            Bin = iolist_to_binary(Data),
            <<ToSend:Sendable/binary, Rest/binary>> = Bin,
            Full = Sendable =:= Total,
            Frames = data_frames(StreamId, ToSend, EndStream andalso Full),
            _ = send(State, Frames),
            State1 = consume_send_window(State, StreamId, Stream, Sendable),
            case Full of
                true ->
                    ok = ack(From, Ref),
                    if
                        EndStream -> close_stream_send_side(State1, StreamId);
                        true -> State1
                    end;
                false ->
                    %% Window exhausted mid-body: queue the unsent
                    %% remainder and defer the ack until a WINDOW_UPDATE
                    %% drains it (unchanged back-pressure contract).
                    #{StreamId := Stream1} = State1#loop.streams,
                    Stream2 = enqueue_pending(Stream1, {data, Ref, From, Rest, EndStream}),
                    update_stream(State1, StreamId, Stream2)
            end
    end.

%% Encode `Bin` into consecutive DATA frames, each at most
%% ?MAX_FRAME_SIZE. END_STREAM is set on the last frame only when
%% `Fin` is true; intermediate frames carry no flags. Cons on the way
%% out (no reverse). The caller emits the whole list in one send.
-spec data_frames(pos_integer(), binary(), boolean()) -> iodata().
data_frames(StreamId, Bin, Fin) when byte_size(Bin) =< ?MAX_FRAME_SIZE ->
    Flags =
        if
            Fin -> 16#01;
            true -> 0
        end,
    [roadrunner_http2_frame:encode({data, StreamId, Flags, Bin})];
data_frames(StreamId, Bin, Fin) ->
    <<Chunk:?MAX_FRAME_SIZE/binary, Rest/binary>> = Bin,
    [
        roadrunner_http2_frame:encode({data, StreamId, 0, Chunk})
        | data_frames(StreamId, Rest, Fin)
    ].

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

%% Wake the worker blocked on a send once its data is on the wire. A
%% buffered response's body has no worker waiting (`handle_send_response/6`).
-spec ack(pid() | undefined, reference() | undefined) -> ok.
ack(undefined, _Ref) ->
    ok;
ack(From, Ref) ->
    _ = (From ! {h2_send_ack, Ref}),
    ok.

%% After a stream's send window grew, drain its pending DATA queue
%% as far as windows allow.
flush_pending_data(#loop{streams = Streams} = State, StreamId) ->
    #{StreamId := #{pending_sends := Pending} = Stream} = Streams,
    case queue:is_empty(Pending) of
        true -> State;
        false -> retire_drained(drain_pending(State, StreamId, Stream), StreamId)
    end.

%% Drop a stream whose worker already exited (`finish_stream/2`) once its
%% queued body is fully sent: nothing else will retire it, since the
%% worker's `DOWN` has come and gone. A stream that still has a worker,
%% or still has bytes queued, stays. When the listener is draining, the
%% last stream to go lets the conn exit.
-spec retire_drained(#loop{}, stream_id()) -> #loop{}.
retire_drained(#loop{streams = Streams} = State, StreamId) ->
    case Streams of
        #{StreamId := #{worker_ref := undefined, pending_sends := Pending}} ->
            case queue:is_empty(Pending) of
                true -> maybe_exit_when_drained(remove_stream(State, StreamId));
                false -> State
            end;
        #{} ->
            State
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
            State2 = try_send_data(
                State1, Stream1, StreamId, From, Ref, Bin, iolist_size(Bin), EndStream
            ),
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

%% Release the stream's concurrency-limit slot if it still holds one.
%% Idempotent via the `counted` flag; called by every teardown path so
%% a stream that never reached `close_stream_send_side/2` with both
%% sides ended (peer RST, worker crash, early response) cannot leak a
%% slot when its map entry is dropped.
uncount_stream(#loop{streams = Streams, live_streams = Live} = State, StreamId) ->
    case Streams of
        #{StreamId := #{counted := true} = Stream} ->
            State#loop{
                streams = Streams#{StreamId := Stream#{counted := false}},
                live_streams = Live - 1
            };
        #{} ->
            State
    end.

%% Reset a stream we have alive: the peer sent RST_STREAM, or we sent
%% one for a stream-level flow-control error. Tell the worker (if any)
%% to bail, then drop our stream entry. Pending sends get reset
%% notifications so workers waiting on `h2_send_ack` unwind, as does a
%% worker waiting on a manual-mode body read.
reset_stream(State0, StreamId) ->
    #loop{streams = Streams, worker_refs = Refs} = State = uncount_stream(State0, StreamId),
    #{
        StreamId := #{
            pending_sends := Pending,
            worker_pid := WorkerPid,
            worker_ref := WorkerRef
        } = Stream
    } = Streams,
    notify_pending_reset(StreamId, Pending),
    ok =
        case Stream of
            #{reader := Reader} -> roadrunner_conn:send_body_error(Reader, StreamId, closed);
            _ -> ok
        end,
    Refs1 =
        case WorkerRef of
            undefined ->
                %% RST landed before END_STREAM dispatched a worker.
                Refs;
            MonRef ->
                _ = (WorkerPid ! {h2_stream_reset, StreamId}),
                true = demonitor(MonRef, [flush]),
                %% The worker held an in-flight slot. We demonitor it (so no
                %% `DOWN` fires) and drop its ref here, so this is the only
                %% place that can release the slot — `handle_worker_down`
                %% never runs and `exit_clean` no longer sees the ref.
                ok = roadrunner_conn:release_request_slot(
                    State#loop.max_concurrent_requests,
                    State#loop.inflight_counter,
                    State#loop.overload
                ),
                maps:remove(MonRef, Refs)
        end,
    withdraw_parked(
        State#loop{
            streams = maps:remove(StreamId, Streams),
            worker_refs = Refs1
        },
        StreamId
    ).

%% Called by `handle_worker_down/3` when a worker dies abnormally.
%% Send RST_STREAM(error_code) to the peer and drop our state.
abort_stream(State0, StreamId, ErrorCode) ->
    #loop{streams = Streams} = State = uncount_stream(State0, StreamId),
    #{StreamId := #{pending_sends := Pending}} = Streams,
    notify_pending_reset(StreamId, Pending),
    _ = send_rst_stream(State, StreamId, ErrorCode),
    withdraw_parked(State#loop{streams = maps:remove(StreamId, Streams)}, StreamId).

%% Drop a stream that needs no RST_STREAM: its response is complete
%% (`finish_stream/2`, `retire_drained/2`), or the caller already sent
%% one. Just drop state.
remove_stream(State0, StreamId) ->
    #loop{streams = Streams} = State = withdraw_parked(uncount_stream(State0, StreamId), StreamId),
    State#loop{streams = maps:remove(StreamId, Streams)}.

%% Withdraw a request parked for a slot. Every path that drops a stream
%% goes through here, so `awaiting_slot` never outlives its stream entry
%% and a grant can always find the stream it was granted for. A grant
%% already in flight still arrives; `handle_slot/3` gives that slot back.
-spec withdraw_parked(#loop{}, stream_id()) -> #loop{}.
withdraw_parked(#loop{awaiting_slot = Awaiting, overload = Overload} = State, StreamId) ->
    case Awaiting of
        #{StreamId := _} ->
            ok = roadrunner_conn:cancel_slot_wait(Overload, StreamId),
            State#loop{awaiting_slot = maps:remove(StreamId, Awaiting)};
        _ ->
            State
    end.

%% A parked stream's admission resolved. `granted` means the queue has
%% already taken the slot on our behalf, so a stream that has gone away
%% in the meantime must hand it back rather than drop it.
-spec handle_slot(#loop{}, stream_id(), granted | timeout | full) -> #loop{}.
handle_slot(#loop{awaiting_slot = Awaiting} = State, StreamId, granted) ->
    case Awaiting of
        #{StreamId := Req} ->
            spawn_parked(
                State#loop{awaiting_slot = maps:remove(StreamId, Awaiting)}, StreamId, Req
            );
        _ ->
            give_back_slot(State)
    end;
handle_slot(#loop{awaiting_slot = Awaiting, listener_name = ListenerName} = State, StreamId, _) ->
    case Awaiting of
        #{StreamId := _} ->
            State1 = State#loop{awaiting_slot = maps:remove(StreamId, Awaiting)},
            ok = throttle_stream(State1, ListenerName),
            _ = send_rst_stream(State1, StreamId, refused_stream),
            remove_stream(State1, StreamId);
        _ ->
            State
    end.

%% `withdraw_parked/2` keeps `awaiting_slot` and `streams` in step, so a
%% grant that still has its parked request always has its stream too.
-spec spawn_parked(#loop{}, stream_id(), roadrunner_req:request()) -> #loop{}.
spawn_parked(#loop{streams = Streams, proto_opts = ProtoOpts} = State, StreamId, Req) ->
    #{StreamId := Stream} = Streams,
    {WorkerPid, MonRef} = roadrunner_http2_stream_worker:start(self(), StreamId, Req, ProtoOpts),
    State#loop{
        streams = Streams#{StreamId := Stream#{worker_pid := WorkerPid, worker_ref := MonRef}},
        worker_refs = (State#loop.worker_refs)#{MonRef => StreamId}
    }.

-spec give_back_slot(#loop{}) -> #loop{}.
give_back_slot(State) ->
    ok = roadrunner_conn:release_request_slot(
        State#loop.max_concurrent_requests,
        State#loop.inflight_counter,
        State#loop.overload
    ),
    State.

notify_pending_reset(StreamId, Pending) ->
    case queue:out(Pending) of
        {empty, _} ->
            ok;
        {{value, {data, _Ref, undefined, _Bin, _Es}}, Rest} ->
            %% A buffered response's body: its worker is already gone.
            notify_pending_reset(StreamId, Rest);
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

%% RFC 9113 §6.5.2 / RFC 7541 §6.3: the peer's SETTINGS_HEADER_TABLE_SIZE
%% (id 1) caps OUR encoder's dynamic table. Apply the last value (§6.5.3),
%% clamped at our own ?HPACK_TABLE_SIZE ceiling so a generous peer can't
%% grow our table, and a smaller one shrinks it (evicting entries the
%% peer's decoder dropped, avoiding a desync). set_max_table_size flags
%% the encoder to emit the matching dynamic-table-size update on its next
%% encode.
-spec apply_header_table_size(
    [{non_neg_integer(), non_neg_integer()}], #loop{}
) -> #loop{}.
apply_header_table_size(Params, #loop{hpack_enc = Enc} = State) ->
    case last_setting(Params, 1, undefined) of
        undefined ->
            State;
        Limit ->
            Size = min(?HPACK_TABLE_SIZE, Limit),
            case roadrunner_http2_hpack:max_table_size(Enc) of
                Size ->
                    %% Already at this cap (e.g. the peer advertised our
                    %% default or larger): don't flag a redundant Size Update.
                    State;
                _ ->
                    State#loop{hpack_enc = roadrunner_http2_hpack:set_max_table_size(Size, Enc)}
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

%% Bump the cumulative throttled counter and emit the throttled telemetry
%% when a stream is refused at the `max_concurrent_requests` ceiling.
-spec throttle_stream(#loop{}, atom()) -> ok.
throttle_stream(#loop{proto_opts = #{throttled_counter := Counter}}, ListenerName) ->
    roadrunner_conn:throttled_telemetry(ListenerName, Counter, max_concurrent_requests).

%% Per-peer rate-limit gate before spawning a stream worker. `ok` to proceed;
%% `{refused, State1}` after sending `429` + `Retry-After` and an
%% `RST_STREAM(NO_ERROR)` on the request stream (the rate was exceeded). 429
%% (not `REFUSED_STREAM`) so the client honors `Retry-After` instead of
%% retrying the stream immediately. The guard being off (`undefined`) or a
%% missing peer IP proceeds.
-spec rate_limit_refused(#loop{}, stream_id(), roadrunner_req:request()) ->
    ok | {refused, #loop{}}.
rate_limit_refused(
    #loop{rate_limit = RateLimit, listener_name = ListenerName} = State, StreamId, Req
) ->
    case roadrunner_conn:rate_limit(RateLimit, Req, ListenerName) of
        allow ->
            ok;
        {deny, RetryAfter} ->
            State1 = encode_and_send_response_atomic(
                State, StreamId, 429, [{~"retry-after", integer_to_binary(RetryAfter)}], ~"", 0
            ),
            _ = send_rst_stream(State1, StreamId, no_error),
            {refused, State1}
    end.

-spec exit_clean(#loop{}) -> no_return().
exit_clean(#loop{
    socket = Socket,
    proto_opts = ProtoOpts,
    listener_name = ListenerName,
    peer = Peer,
    start_mono = StartMono,
    worker_refs = Refs,
    max_concurrent_requests = MaxConcReq,
    inflight_counter = InflightCounter,
    overload = Overload
}) ->
    roadrunner_telemetry:listener_conn_close(StartMono, #{
        listener_name => ListenerName,
        peer => Peer,
        requests_served => 0
    }),
    %% Account for any stream workers still live at teardown (each holds one
    %% in-flight slot). Workers whose `DOWN` already fired were removed from
    %% `worker_refs`, so this releases each remaining worker exactly once.
    ok = roadrunner_conn:release_request_slots(
        MaxConcReq, InflightCounter, map_size(Refs), Overload
    ),
    ok = roadrunner_conn:unregister_for_drain(ProtoOpts),
    ok = roadrunner_conn:release_slot(ProtoOpts),
    ok = roadrunner_transport:close(Socket),
    exit(normal).
