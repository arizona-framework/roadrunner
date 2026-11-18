-module(roadrunner_conn_loop_http2).
-moduledoc false.

-include("roadrunner_proto_opts.hrl").

%% HTTP/2 (RFC 9113) connection process.
%%
%% Driven by either TLS ALPN-negotiated `h2` or a plaintext connection
%% with prior knowledge (RFC 9113 §3.3): every connection on a
%% `protocols => [http2]` listener, and on an `[http1, http2]` one each
%% connection that opens with the preface (`preface/1`).
%% The dispatch decision lives in `roadrunner_conn_loop:serve/5`;
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
%% - a `streams` map keyed by stream id, and `workers` mapping
%%   worker pids back to stream ids for `'DOWN'` correlation.
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
%% HEADERS beyond that limit get `RST_STREAM(REFUSED_STREAM)`. A worker
%% whose stream is reset is told, not stopped, and counts toward the limit
%% until it exits (`reset_workers`), so resetting streams cannot run more
%% handlers at once than the limit (CVE-2023-44487, rapid reset).
%%
%% Until the client acknowledges our SETTINGS the limit is not yet in
%% force (RFC 9113 §6.5.2: SETTINGS_MAX_CONCURRENT_STREAMS is initially
%% unlimited; §6.5.3: only the ACK says our values apply), so a client
%% that sends a burst of requests along with its preface, before it has
%% read our SETTINGS, is not refused for it. The streams it opens then are
%% held to `?PRE_SETTINGS_STREAMS`, or the advertised limit when that is
%% higher, the same way, rapid reset guard included; once the ACK
%% arrives, new streams are held to the advertised limit and the ones
%% already open run to their end.
%%
%% Client header limit (RFC 9113 §6.5.2): a client that sent
%% SETTINGS_MAX_HEADER_LIST_SIZE may treat a larger header section as
%% malformed. The conn records the value and hands it to each worker it
%% spawns, and the worker keeps its response within it (a 500 in place of
%% headers over it; for trailers over it a crash, which the `'DOWN'` turns
%% into a stream reset), so the status the worker reports is the one
%% sent. The conn itself does not check. The
%% setting is advisory (§10.5.1): a value lowered by a later SETTINGS
%% frame holds for the workers spawned after it, not those already
%% running.
%%
%% Response shapes supported:
%%
%% | shape | h2 |
%% |---|---|
%% | `{Status, Headers, Body}` (buffered) | yes |
%% | `{stream, _, _, Fun}` | yes |
%% | `{loop, _}` | yes (worker enters handle_info loop) |
%% | `{sendfile, _}` | yes (chunked DATA via the stream-response engine) |
%% | `{send, _, Fun}` | yes (each `roadrunner_send` call as its shape) |
%% | `{websocket, ...}`, `roadrunner_send:websocket/4` | 501 (RFC 8441, roadmap) |

-export([enter/6, preface/1]).

%% Hibernate continuation — invoked via `erlang:hibernate/3` when an
%% idle conn parks past `hibernate_after`. Must stay exported so the
%% runtime can re-enter the loop on wake.
-export([recv_more_hib/2]).

%% RFC 9113 §3.4 client connection preface — fixed 24 bytes.
-define(PREFACE, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n").
-define(PREFACE_LEN, 24).

%% Read-deadline caps for the handshake and idle states. Tests
%% override via `persistent_term:put/2` on `{?MODULE, handshake_timeout}`
%% / `{?MODULE, idle_timeout}` so the timeout branches are exercisable
%% without forcing 10–60 s waits per case. The idle one is the listener's
%% `keep_alive_timeout`.
-define(HANDSHAKE_TIMEOUT_DEFAULT, 10_000).
%% The shortest idle wait an HTTP/2 conn takes from `keep_alive_timeout`:
%% shorter would close it before a client's first request, or before a
%% client could answer the liveness PING. A value of 0 means "no keep-alive
%% wait" on HTTP/1.1, which has no HTTP/2 counterpart.
-define(MIN_IDLE_TIMEOUT, 1_000).

%% Opaque data of the PING a conn still serving sends when its idle timeout
%% passes with nothing heard (`recv_idle_expired/1`).
-define(LIVENESS_PING, ~"rr-alive").
%% Opaque data of the PING that follows a graceful close's first GOAWAY
%% (`announce_goaway/2`): its ACK says the client has seen that GOAWAY.
-define(GOAWAY_PING, ~"rr-drain").
%% The largest stream id (RFC 9113 §5.1.1), which the first GOAWAY of a
%% graceful close names so that no stream the client opened is refused.
-define(MAX_STREAM_ID, 16#7FFFFFFF).
%% The least time between two client PINGs with no stream open when the
%% `ping_policy` does not permit PINGs without one: gRPC's (grpc-go's
%% `defaultPingTimeout`, gRPC core's no-call ping interval), 2 hours.
-define(PING_IDLE_MIN_TIME, 7_200_000).
%% Debug data of the GOAWAY that closes a conn for its PINGs: what gRPC
%% servers send, and gRPC clients look for to ping less.
-define(TOO_MANY_PINGS, ~"too_many_pings").
%% How many of the streams it reset a conn remembers, to ignore what the
%% peer still sends on them (`remember_reset/2`).
-define(RESET_MEMORY, 128).

%% RFC 9113 §6.5.2 default `MAX_FRAME_SIZE`.
-define(MAX_FRAME_SIZE, 16_384).

%% Default cap on a request's assembled HEADERS+CONTINUATION block. A
%% request over it is answered 431 on its own stream, its block still
%% decoded (HPACK state is per connection, RFC 9113 §4.3). Overridable per
%% listener via the `max_header_block` http2 opt. h1 and h3 have their own
%% header-block caps (each separately configurable; h1 defaults to 10240, h3
%% to 16384).
-define(MAX_HEADER_BLOCK, 16_384).

%% Default SETTINGS_MAX_HEADER_LIST_SIZE: 2x the encoded-block cap. The
%% decoded list is always larger than the compressed block (the +32/field
%% overhead alone pushes it up), so giving it headroom over `max_header_block`
%% means the decoded gate only fires on genuinely huge header sets. When the
%% encoded cap is overridden, the default tracks it (`2 * max_header_block`).
%%
%% The larger of the two is the most the conn assembles of one block (the
%% `header_block_ceiling`). Each frame is bounded to MAX_FRAME_SIZE, but the
%% number of CONTINUATION frames is not, so without a ceiling a peer could
%% grow a block without bound (the HTTP/2 CONTINUATION Flood); past it the
%% connection ends with GOAWAY(ENHANCE_YOUR_CALM). A client that keeps to
%% the advertised list size and sends its headers plain or Huffman-coded
%% as encoders usually do stays under it: a field then encodes in about
%% its name and value plus a few length bytes, under the 32 bytes the list
%% size counts for it. Huffman coding can make a string longer than it is
%% (RFC 7541 §5.2: a backslash takes 19 bits), so a block of such strings can
%% pass the ceiling while its list size does not; the setting is advisory
%% (RFC 9113 §6.5.2).
-define(DEFAULT_MAX_HEADER_LIST_SIZE, (2 * ?MAX_HEADER_BLOCK)).

%% RFC 7541 §4.2 default HPACK dynamic-table size: what we tell the peer
%% its encoder may use (our decoder), and the ceiling we hold our own
%% encoder to even when the peer advertises a larger table.
-define(HPACK_TABLE_SIZE, 4096).

%% RFC 9113 §6.9.2 initial window size for both the connection and
%% each stream.
-define(INITIAL_WINDOW, 65535).

%% Default recv-window peaks. RFC 9113 doesn't mandate them; they're
%% policy. A stream's upload rate is bounded by its window over the round
%% trip, so the RFC 9113 §6.9.2 baseline of 65535 caps one upload at about
%% 0.6 MB/s over a 100 ms RTT. Every stream still opens at that baseline
%% (we advertise no SETTINGS_INITIAL_WINDOW_SIZE), so a stream we refuse
%% or reject before reading its body can draw at most 65535 bytes; its
%% window grows to the peak with its first refill, once its DATA is taken
%% (on arrival in auto mode, as the worker reads in manual mode). 16 MB
%% per stream keeps a single upload at about 160 MB/s over a 100 ms RTT.
%% The connection window bounds no memory (its credit is returned as DATA
%% arrives, refused or not), so it is the largest a window may be (RFC
%% 9113 §6.9.1). Credit for a buffered (auto-mode) body is returned as it
%% arrives, so the stream peak bounds the rate, not the memory a body
%% takes, which `max_content_length` bounds; in manual mode a stream holds
%% at most its peak until its worker reads. Each window is refilled once
%% it drops below half its peak, unless `window_refill_threshold` sets one
%% threshold for both. `roadrunner_listener:opts()` carries the override
%% knobs as nested `http2` sub-opts (`conn_window`, `stream_window`,
%% `window_refill_threshold`). Defaults here mirror the listener's for
%% static record initialization; runtime values come from the `http2_*`
%% fields of the connection options (`#proto_opts{}`).
-define(DEFAULT_CONN_RECV_WINDOW, 16#7FFFFFFF).
-define(DEFAULT_STREAM_RECV_WINDOW, 16_777_216).

%% Hard upper bound on a flow-control window per RFC 9113 §6.9.1
%% (signed 31-bit). Increments that would push past this are a
%% FLOW_CONTROL_ERROR.
-define(MAX_WINDOW, 16#7FFFFFFF).

%% Default cap on concurrent client-initiated streams (Phase H8b lifted
%% it from 1 serial to 100). Overridable per listener via the
%% `max_concurrent_streams` http2 opt; clients exceeding the live cap get
%% RST_STREAM(REFUSED_STREAM) on the over-limit HEADERS.
-define(MAX_CONCURRENT_STREAMS, 100).

%% The most streams a client may have open before it acknowledges our
%% SETTINGS, when we advertise fewer (`stream_limit`). RFC 9113 §6.5.2
%% recommends SETTINGS_MAX_CONCURRENT_STREAMS be no smaller than 100, so a
%% client that starts sending before it has our SETTINGS typically allows
%% itself 100 streams. A client that never acknowledges stays held to this
%% many, and one that opens more is refused with the retry-safe
%% REFUSED_STREAM (§8.7), so it bounds what a connection can hold.
-define(PRE_SETTINGS_STREAMS, 100).

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

%% An HTTP/2 stream's state, held in the conn's `streams` map by stream id.
-record(stream, {
    state = open :: stream_state(),
    %% Whether this stream still counts toward the advertised
    %% `max_concurrent_streams` (RFC 9113 §5.1.2: open and half-closed
    %% streams count; a fully closed one does not). Cleared exactly once —
    %% either when both sides have ended or on teardown — while the map
    %% entry itself lives until the worker's DOWN for state cleanup (or,
    %% for a buffered body still queued behind flow control, until that
    %% body drains, see `finish_stream/2`).
    counted = true :: boolean(),
    %% Field block fragments (the HEADERS frame plus any CONTINUATIONs):
    %% a bare binary for a single frame, an iolist once CONTINUATIONs
    %% append, flattened once at finalize (like `body` accumulates DATA).
    header_fragment :: iodata(),
    %% Running byte count of `header_fragment`, so the CONTINUATION-flood
    %% cap can compare against a counter instead of re-measuring the
    %% accumulated block on every frame.
    header_len :: non_neg_integer(),
    end_headers :: boolean(),
    end_stream_seen :: boolean(),
    headers :: undefined | roadrunner_http:headers(),
    body = [] :: iolist(),
    %% Cumulative byte count of received DATA payload, used to
    %% validate against the request's `content-length` header at
    %% END_STREAM (RFC 9113 §8.1.2.6).
    body_len = 0 :: non_neg_integer(),
    %% The body cap: the listener's `max_content_length` until a body
    %% outgrows it and its route raises it (`stream_body_cap/4`), to
    %% `infinity` for a route that sets no cap.
    body_cap :: roadrunner_router:body_limit(),
    send_window :: integer(),
    recv_window :: non_neg_integer(),
    worker_pid :: undefined | pid(),
    worker_ref :: undefined | reference(),
    pending_sends :: queue:queue(pending_send()),
    %% Set on a stream we are resetting with this code until its field
    %% block, possibly still arriving in CONTINUATION frames, is complete
    %% and decoded for its HPACK side effects (`reset_refused/4`); `ignore`
    %% for a late block on a stream we already reset, which gets no reply.
    refused :: undefined | roadrunner_http2_frame:error_code() | ignore,
    %% Manual body mode (`body_buffering => manual`): the worker runs from
    %% the end of the headers and pulls the body (`handle_body_demand/3`),
    %% `body` holding the DATA it has not taken yet. `manual` marks such a
    %% stream. `reader` is the worker waiting for DATA, if it is;
    %% `continue_owed` a 100 Continue the client is holding its body back
    %% for, sent on the worker's first demand; `body_error` why the body
    %% cannot be read (over its cap), told to the worker instead; `declared`
    %% the request's `content-length`, checked as DATA arrives.
    manual = false :: boolean(),
    reader :: undefined | pid(),
    continue_owed = false :: boolean(),
    body_error :: undefined | content_length_too_large,
    declared :: undefined | none | {ok, non_neg_integer()},
    %% When the header block of a request whose body is still to come was
    %% decoded, in `erlang:monotonic_time(millisecond)`: the request's
    %% `headers_at` (`headers_at/1`). Unset for a request dispatched with
    %% its headers.
    headers_at :: undefined | integer()
}).

-record(loop, {
    socket :: roadrunner_transport:socket(),
    proto_opts :: roadrunner_conn:proto_opts(),
    listener_name :: atom(),
    peer :: {inet:ip_address(), inet:port_number()} | undefined,
    %% The connection queries each request carries, built once.
    conn_info :: roadrunner_req:conn_info(),
    %% The event handler's span from `listener_accept`, fired by the
    %% HTTP/1.1 fork before `enter/6`.
    conn_span :: roadrunner_event_handler:span(),
    scheme :: http | https,
    %% Active-mode message tags for this transport.
    msg_data :: atom(),
    msg_closed :: atom(),
    msg_error :: atom(),
    msg_passive :: atom(),
    %% Socket read mode: `once` re-arms after every read; `N` arms
    %% `{active, N}` and re-arms on the transport's passive message.
    active :: once | 1..32767,
    %% True while an `{active, N}` arm still has reads left, so the
    %% frame loop skips the setopts call. Always false under `once`.
    armed = false :: boolean(),
    %% `{Idle, Max}` while a prior-knowledge h2c socket still reads with
    %% its small `idle_recv_buffer`: the first DATA frame with a payload
    %% grows it to `Max` (`recv_buffer`) for good, so a request body is
    %% not read in small pieces. `undefined` once grown, and on TLS.
    grow_buffer :: {pos_integer(), pos_integer()} | undefined,
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
    %% whenever it drops below `recv_window_threshold`; a stream's to
    %% its peak below `stream_recv_window_threshold`.
    conn_send_window = 65535 :: integer(),
    conn_recv_window = 65535 :: non_neg_integer(),
    %% Configured peaks + refill thresholds. Read from proto_opts at
    %% `enter/6`. See the `?DEFAULT_*` macros above for the policy
    %% baseline + the listener moduledoc for the override knobs.
    recv_window_peak = ?DEFAULT_CONN_RECV_WINDOW :: pos_integer(),
    stream_recv_window_peak = ?DEFAULT_STREAM_RECV_WINDOW :: pos_integer(),
    recv_window_threshold = ?DEFAULT_CONN_RECV_WINDOW div 2 :: pos_integer(),
    stream_recv_window_threshold = ?DEFAULT_STREAM_RECV_WINDOW div 2 :: pos_integer(),
    %% Max concurrent client-initiated streams: advertised in our SETTINGS
    %% and enforced in `on_headers/5` (as `stream_limit`) once the client
    %% acknowledges them. Read from proto_opts at `enter/6`.
    max_concurrent_streams = ?MAX_CONCURRENT_STREAMS :: pos_integer(),
    %% The stream limit in force: `max_concurrent_streams` once the client
    %% has acknowledged our SETTINGS, and until then at least
    %% `?PRE_SETTINGS_STREAMS` (RFC 9113 §6.5.2: the limit is initially
    %% unlimited), so streams a client opened before it could know our
    %% limit are not refused for it.
    stream_limit = ?MAX_CONCURRENT_STREAMS :: pos_integer(),
    %% Streams currently counting toward `max_concurrent_streams` — the
    %% entries whose `counted` flag is still set. Tracked separately from
    %% `map_size(streams)` because an entry outlives its RFC stream: it is
    %% kept until the worker's DOWN for cleanup, and admission must not
    %% charge a stream whose response already ended on the wire (a compliant
    %% client that refills the moment it sees our END_STREAM would otherwise
    %% race that DOWN and eat a spurious REFUSED_STREAM).
    live_streams = 0 :: non_neg_integer(),
    %% The monitors of workers still running for streams reset while they
    %% counted toward `max_concurrent_streams` (`drop_reset_stream/2`): the
    %% stream is closed (RFC 9113 §5.1), but its handler is not done, so
    %% admission counts it with `live_streams` until its `DOWN`. Without this
    %% a client could open and reset streams in a loop, each reset freeing a
    %% slot while the handler it started ran on (the HTTP/2 rapid reset
    %% attack, CVE-2023-44487), and run any number of handlers at once.
    reset_workers = #{} :: #{reference() => []},
    %% Streams refused while `reset_workers` alone held the whole limit, since
    %% the last one of those workers ended. Past `stream_limit` the
    %% client is resetting far beyond the limit and gets
    %% GOAWAY(ENHANCE_YOUR_CALM) (`refuse_over_limit/5`).
    reset_refusals = 0 :: non_neg_integer(),
    %% A request's HEADERS+CONTINUATION block cap: a larger block is
    %% decoded, then answered 431 in `finalize_headers/2`. Read from
    %% proto_opts at `enter/6`.
    max_header_block = ?MAX_HEADER_BLOCK :: pos_integer(),
    %% The most bytes of one block the conn assembles (CONTINUATION-flood
    %% guard), the larger of `max_header_block` and `max_header_list_size`;
    %% past it, GOAWAY(ENHANCE_YOUR_CALM) in `on_continuation/4`.
    header_block_ceiling = ?DEFAULT_MAX_HEADER_LIST_SIZE :: pos_integer(),
    %% Request-body cap (`max_content_length` listener opt); an over-cap
    %% body answers 413 + RST_STREAM(NO_ERROR). Read from proto_opts at
    %% `enter/6`.
    max_content_length :: non_neg_integer(),
    %% `auto` buffers a request's body and starts its worker at END_STREAM;
    %% `manual` starts the worker at the end of the headers and hands it the
    %% body as it reads (`dispatch_reading/3`), within `request_timeout`
    %% from then. Read from proto_opts at `enter/6`.
    body_buffering = auto :: roadrunner_listener:body_buffering(),
    request_timeout :: non_neg_integer(),
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
    idle_timeout :: non_neg_integer(),
    %% When (`erlang:monotonic_time(millisecond)`) the conn closes for
    %% being idle: set once it has no stream and no worker left (from the
    %% start, and as its last stream goes, `idle_deadline/3`), cleared by
    %% the next stream it opens, and moved by nothing else, so no frame a
    %% client sends without a request (PING, SETTINGS, WINDOW_UPDATE...)
    %% keeps an unused conn open. `undefined` while it serves.
    idle_deadline = undefined :: integer() | undefined,
    %% The client PING policy (`http2_ping_*` proto_opts, `ping_policy/1`):
    %% `off`, or the least time between two PINGs with a stream open and
    %% with none, and the PINGs closer than that a client may send before
    %% the next one closes the conn.
    ping_policy = off :: off | {pos_integer(), pos_integer(), non_neg_integer()},
    %% When the client last pinged, in milliseconds, and its strikes
    %% since; `undefined` while its next PING is free: none came yet, or
    %% HEADERS or DATA went out since (`ping_strike/1`).
    ping_clock = undefined :: undefined | {integer(), non_neg_integer()},
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
    %% Whether a stream ever parked here: a grant may then still be on its
    %% way when the conn exits, which `hand_off_slots/1` gives back.
    parked = false :: boolean(),
    %% Per-peer rate-limit guard resolved from proto_opts + peer at `enter/6`
    %% (`undefined` when off). Checked in `dispatch_stream/2`.
    rate_limit = undefined :: roadrunner_conn:rate_limit_state(),
    %% The `real_ip` trust config when the peer is a trusted proxy, decided
    %% once per connection (`roadrunner_real_ip:peer_trust/2`); `undefined`
    %% otherwise, the common case, so the request path resolves nothing.
    real_ip = undefined :: undefined | roadrunner_real_ip:config(),
    %% Stream table, keyed by stream id.
    streams = #{} :: #{stream_id() => #stream{}},
    %% Worker pid → stream id, for DOWN correlation: the workers that hold
    %% an in-flight slot, until their `DOWN` is handled.
    workers = #{} :: #{pid() => stream_id()},
    %% Whether a liveness PING (`recv_idle_expired/1`) waits for its ACK.
    liveness_ping = false :: boolean(),
    %% Streams this conn reset, oldest first, so frames the peer sent
    %% before it saw the reset are ignored (`remember_reset/2`).
    reset_ids = {queue:new(), #{}} :: {queue:queue(stream_id()), #{stream_id() => []}},
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
    %% The client's SETTINGS_MAX_HEADER_LIST_SIZE (RFC 9113 §6.5.2), the
    %% largest response header section it says it will take; `infinity`
    %% (no limit, the §6.5.2 default) until a SETTINGS frame carries it.
    %% Not to be confused with `max_header_list_size`, our own limit on
    %% request headers. Handed to each worker as it is spawned
    %% (`roadrunner_http2_stream_worker:start/6`), which applies it.
    peer_max_header_list_size = infinity :: non_neg_integer() | infinity,
    %% The heap floor this connection starts its workers at
    %% (`roadrunner_stream_worker:conn_heap_floor/1`).
    heap_floor = undefined :: roadrunner_stream_worker:conn_heap_floor(),
    %% The `Deadline` of the first `{roadrunner_drain, Deadline}`
    %% message, `undefined` until one arrives. In drain mode we've
    %% passed the message on to every stream worker and hand the same
    %% message to each worker started from then on.
    drain_deadline = undefined :: integer() | undefined,
    %% Where the connection is in a graceful close (RFC 9113 §6.8):
    %% `open` until one starts; `{announced, TRef, Reason}` once a
    %% GOAWAY naming the largest stream id and a PING are out, while new
    %% streams are still served, until the PING's ACK (or `TRef`, an
    %% idle timeout later) says the client has seen it; `{final, Reason}`
    %% once the GOAWAY naming the last stream served is out: new streams
    %% are refused with RST_STREAM(REFUSED_STREAM) and the conn exits
    %% with `Reason` as soon as the streams map empties.
    goaway = open :: open | {announced, reference(), close_reason()} | {final, close_reason()}
}).

-type close_reason() :: roadrunner_event_handler:close_reason().

-doc """
Top-level entry from the HTTP/1.1 dispatch fork. Owns the socket
from this point on; takes responsibility for releasing the listener
slot and firing the `listener_conn_close` event for `ConnSpan`.

`Buffered` seeds the connection's initial read buffer: the bytes a
coalesced TCP segment carried after a stripped PROXY-protocol header
(which may be the start of the client preface), or, on a plain-TCP port
shared with HTTP/1.1, the bytes that matched the preface. Empty for the
normal path.
""".
-spec enter(
    roadrunner_transport:socket(),
    roadrunner_conn:proto_opts(),
    atom(),
    {inet:ip_address(), inet:port_number()} | undefined,
    roadrunner_event_handler:span(),
    binary()
) -> no_return().
enter(Socket, ProtoOpts, ListenerName, Peer, ConnSpan, Buffered) ->
    proc_lib:set_label({roadrunner_conn_loop_http2, ListenerName, Peer}),
    Scheme = roadrunner_conn:scheme(Socket),
    {Data, Closed, Error} = roadrunner_transport:messages(Socket),
    %% h2 knobs are flattened onto `http2_*` fields by
    %% `roadrunner_listener:normalize_protocols/1`, no nested map dives.
    #proto_opts{
        http2_conn_window = ConnPeak,
        http2_stream_window = StreamPeak,
        http2_window_refill_threshold = RefillThreshold,
        http2_max_concurrent_streams = MaxStreams,
        http2_max_header_block = MaxHeaderBlock,
        http2_max_header_list_size = MaxHeaderListSize,
        http2_active = Active,
        max_content_length = MaxContentLength,
        hibernate_after = HibernateAfter,
        alt_svc = AltSvc,
        max_concurrent_requests = MaxConcReq,
        inflight_counter = InflightCounter,
        grow_recv_buffer = GrowBuffer,
        body_buffering = BodyBuffering,
        request_timeout = RequestTimeout,
        overload = Overload
    } = ProtoOpts,
    {ConnThreshold, StreamThreshold} = refill_thresholds(RefillThreshold, ConnPeak, StreamPeak),
    HandshakeTimeout = handshake_timeout(),
    IdleTimeout = idle_timeout(ProtoOpts),
    State = #loop{
        socket = Socket,
        proto_opts = ProtoOpts,
        heap_floor = roadrunner_stream_worker:conn_heap_floor(ProtoOpts),
        listener_name = ListenerName,
        peer = Peer,
        conn_info = roadrunner_conn:conn_info(Socket),
        conn_span = ConnSpan,
        scheme = Scheme,
        msg_data = Data,
        msg_closed = Closed,
        msg_error = Error,
        msg_passive = roadrunner_transport:passive_message(Socket),
        active = Active,
        grow_buffer = GrowBuffer,
        hpack_dec = roadrunner_http2_hpack:new_decoder(?HPACK_TABLE_SIZE),
        hpack_enc = roadrunner_http2_hpack:new_encoder(?HPACK_TABLE_SIZE),
        buffer = Buffered,
        recv_window_peak = ConnPeak,
        stream_recv_window_peak = StreamPeak,
        recv_window_threshold = ConnThreshold,
        stream_recv_window_threshold = StreamThreshold,
        max_concurrent_streams = MaxStreams,
        stream_limit = max(MaxStreams, ?PRE_SETTINGS_STREAMS),
        max_header_block = MaxHeaderBlock,
        header_block_ceiling = max(MaxHeaderBlock, MaxHeaderListSize),
        max_header_list_size = MaxHeaderListSize,
        max_content_length = MaxContentLength,
        body_buffering = BodyBuffering,
        request_timeout = RequestTimeout,
        hibernate_after = HibernateAfter,
        alt_svc = AltSvc,
        max_concurrent_requests = MaxConcReq,
        inflight_counter = InflightCounter,
        overload = Overload,
        rate_limit = roadrunner_conn:resolve_rate_limit(ProtoOpts, Peer),
        real_ip = roadrunner_conn:resolve_real_ip(ProtoOpts, Peer),
        handshake_timeout = HandshakeTimeout,
        idle_timeout = IdleTimeout,
        idle_deadline = erlang:monotonic_time(millisecond) + IdleTimeout,
        ping_policy = ping_policy(ProtoOpts)
    },
    ok = start_connection_age(ProtoOpts),
    handshake(State).

%% The listener's `connection_age`: one timer for the conn's whole life,
%% at its age, carrying the grace that follows (`handle_timer/3`).
-spec start_connection_age(roadrunner_conn:proto_opts()) -> ok.
start_connection_age(#proto_opts{http2_connection_age_max = undefined}) ->
    ok;
start_connection_age(#proto_opts{
    http2_connection_age_max = Max, http2_connection_age_grace = Grace
}) ->
    _ = erlang:start_timer(jittered(Max), self(), {?MODULE, {connection_age, Grace}}),
    ok.

%% `Max` give or take up to a tenth of it, as grpc-go jitters its
%% `MaxConnectionAge`: the conns a client opened together (or a restart
%% saw reconnect together) then close spread over time, not all at once.
-spec jittered(pos_integer()) -> pos_integer().
jittered(Max) ->
    Spread = Max div 10,
    Max - Spread + rand:uniform(2 * Spread + 1) - 1.

%% The listener's `ping_policy`, flattened onto `http2_ping_*` fields, all
%% `undefined` when it is off. Without stream, a PING must wait `MinTime`
%% when PINGs are permitted then, and at least 2 hours otherwise.
-spec ping_policy(roadrunner_conn:proto_opts()) ->
    off | {pos_integer(), pos_integer(), non_neg_integer()}.
ping_policy(#proto_opts{http2_ping_min_time = undefined}) ->
    off;
ping_policy(#proto_opts{
    http2_ping_min_time = MinTime,
    http2_ping_permit_without_stream = Permit,
    http2_ping_max_strikes = MaxStrikes
}) ->
    IdleMinTime =
        case Permit of
            true -> MinTime;
            false -> max(MinTime, ?PING_IDLE_MIN_TIME)
        end,
    {MinTime, IdleMinTime, MaxStrikes}.

%% The connection and stream refill thresholds: the configured
%% `window_refill_threshold` for both, else half of each window's peak
%% (at least 1, so a window of 1 byte still refills once spent).
-spec refill_thresholds(pos_integer() | undefined, pos_integer(), pos_integer()) ->
    {pos_integer(), pos_integer()}.
refill_thresholds(undefined, ConnPeak, StreamPeak) ->
    {max(1, ConnPeak div 2), max(1, StreamPeak div 2)};
refill_thresholds(Threshold, _ConnPeak, _StreamPeak) ->
    {Threshold, Threshold}.

%% =============================================================================
%% Handshake — RFC 9113 §3.4
%% =============================================================================

-spec handshake(#loop{}) -> no_return().
handshake(
    #loop{
        recv_window_peak = ConnPeak,
        max_concurrent_streams = MaxStreams,
        max_header_list_size = MaxHeaderListSize
    } = State
) ->
    _ = send(State, server_settings_frame(MaxStreams, MaxHeaderListSize)),
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

-spec server_settings_frame(pos_integer(), pos_integer()) -> iodata().
server_settings_frame(MaxStreams, MaxHeaderListSize) ->
    %% Advertise MAX_CONCURRENT_STREAMS, MAX_FRAME_SIZE and
    %% MAX_HEADER_LIST_SIZE. IDs from RFC 9113 §6.5.2: 3 =
    %% MAX_CONCURRENT_STREAMS, 5 = MAX_FRAME_SIZE, 6 =
    %% MAX_HEADER_LIST_SIZE. No SETTINGS_INITIAL_WINDOW_SIZE: every
    %% stream opens at the RFC 65535 and grows to its peak through
    %% refills once its DATA is taken (see `?DEFAULT_STREAM_RECV_WINDOW`).
    roadrunner_http2_frame:encode(
        {settings, 0, [{3, MaxStreams}, {5, ?MAX_FRAME_SIZE}, {6, MaxHeaderListSize}]}
    ).

-spec handshake_timeout() -> non_neg_integer().
handshake_timeout() ->
    persistent_term:get({?MODULE, handshake_timeout}, ?HANDSHAKE_TIMEOUT_DEFAULT).

%% The listener's `keep_alive_timeout`: how long a connection may stay
%% quiet before it is closed, or, with a handler still at work, checked
%% with a liveness PING (`recv_idle_expired/1`). Tests shorten it through
%% `persistent_term`.
-spec idle_timeout(roadrunner_conn:proto_opts()) -> non_neg_integer().
idle_timeout(#proto_opts{keep_alive_timeout = KeepAliveTimeout}) ->
    case persistent_term:get({?MODULE, idle_timeout}, undefined) of
        undefined ->
            max(KeepAliveTimeout, ?MIN_IDLE_TIMEOUT);
        Override ->
            Override
    end.

%% What the first bytes of a plain-TCP connection on a port shared with
%% HTTP/1.1 say: `http2` once they hold the whole client preface, `more`
%% while they are a proper prefix of it (none yet included), and `http1`
%% as soon as they leave it. See `roadrunner_conn_loop:sniff_preface/2`.
-spec preface(binary()) -> http2 | http1 | more.
preface(<<?PREFACE, _/binary>>) ->
    http2;
preface(Buf) when byte_size(Buf) < ?PREFACE_LEN ->
    Size = byte_size(Buf),
    case binary:longest_common_prefix([Buf, <<?PREFACE>>]) of
        Size -> more;
        _ -> http1
    end;
preface(_Buf) ->
    http1.

-spec handshake_phase_preface(#loop{}) -> no_return().
handshake_phase_preface(#loop{buffer = <<?PREFACE, Rest/binary>>} = State) ->
    handshake_phase_settings(State#loop{buffer = Rest});
handshake_phase_preface(#loop{buffer = <<_:?PREFACE_LEN/binary, _/binary>>} = State) ->
    exit_clean(State, {protocol_error, protocol_error});
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
            goaway_exit(State, protocol_error);
        {more, _Need} ->
            handshake_recv(State, fun handshake_phase_settings/1);
        {error, _} ->
            goaway_exit(State, protocol_error)
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
            exit_clean(State, peer_closed);
        {MError, _, Reason} ->
            exit_clean(State, {transport, Reason})
    after State#loop.handshake_timeout ->
        exit_clean(State, request_timeout)
    end.

%% =============================================================================
%% Frame loop — active-mode socket receive + worker message dispatch
%% =============================================================================

-spec frame_loop(#loop{}) -> no_return().
frame_loop(#loop{goaway = {final, Reason}, streams = Streams} = State) when
    map_size(Streams) =:= 0
->
    %% Drain done — the last in-flight stream finished or peer
    %% RST'd it, nothing more to do.
    exit_clean(State, Reason);
frame_loop(#loop{buffer = Buf} = State) ->
    case roadrunner_http2_frame:parse(Buf, ?MAX_FRAME_SIZE) of
        {ok, Frame, Rest} ->
            handle_frame(Frame, State#loop{buffer = Rest});
        {more, _Need} ->
            arm_and_recv(State);
        {error, _} ->
            goaway_exit(State, protocol_error)
    end.

%% Under `{active, N}` the socket stays armed across reads until the
%% transport's passive message, so an armed loop goes straight to the
%% mailbox. On TLS each setopts is a call into the ssl connection
%% process, which is what `N` saves.
-spec arm_and_recv(#loop{}) -> no_return().
arm_and_recv(#loop{armed = true} = State) ->
    recv_more(State);
arm_and_recv(#loop{socket = Sock, active = once} = State) ->
    _ = roadrunner_transport:setopts(Sock, [{active, once}]),
    recv_more(State);
arm_and_recv(#loop{socket = Sock, active = N} = State) ->
    _ = roadrunner_transport:setopts(Sock, [{active, N}]),
    recv_more(State#loop{armed = true}).

%% Unified mailbox dispatch: socket events, worker send requests,
%% worker DOWN signals, and the idle-timeout `after` clause.
-spec recv_more(#loop{}) -> no_return().
recv_more(
    #loop{
        msg_data = MData,
        msg_closed = MClosed,
        msg_error = MError,
        msg_passive = MPassive,
        buffer = Buf
    } = State
) ->
    receive
        {MData, _, Bytes} ->
            frame_loop(State#loop{buffer = roadrunner_bin:append(Buf, Bytes)});
        {MPassive, _} ->
            arm_and_recv(State#loop{armed = false});
        {MClosed, _} ->
            exit_clean(State, peer_closed);
        {MError, _, Reason} ->
            _ = send_goaway(State, protocol_error),
            exit_clean(State, {transport, Reason});
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
        {roadrunner_body_withdraw, Worker, StreamId} ->
            recv_more(withdraw_body_demand(State, Worker, StreamId));
        {roadrunner_continue, Worker, StreamId} ->
            recv_more(handle_continue(State, Worker, StreamId));
        {roadrunner_skip_continue, StreamId} ->
            recv_more(skip_continue(State, StreamId));
        {roadrunner_cancel_stream, StreamId} ->
            recv_more(maybe_exit_when_drained(cancel_stream(State, StreamId)));
        {'DOWN', MonRef, process, Pid, Reason} ->
            recv_more(maybe_exit_when_drained(handle_worker_down(State, MonRef, Pid, Reason)));
        {roadrunner_slot, StreamId, Outcome} ->
            %% A refused park drops its stream, which may be the last one
            %% a draining conn was waiting on.
            recv_more(maybe_exit_when_drained(handle_slot(State, StreamId, Outcome)));
        {roadrunner_drain, Deadline} ->
            recv_more(start_drain(State, Deadline));
        {timeout, TRef, {?MODULE, Timer}} ->
            recv_more(handle_timer(State, TRef, Timer))
    after recv_timeout(State) ->
        recv_idle_expired(State)
    end.

%% Idle-wait timeout selection. A conn still serving waits the idle
%% timeout from its last message: worker messages are imminent, and the
%% quiet wire only brings the liveness PING (`recv_idle_expired/1`). An
%% idle one waits what is left until its `idle_deadline`, or, when the
%% listener opted into a `hibernate_after` shorter than that, parks for
%% that window so `recv_idle_expired/1` can hibernate.
-spec recv_timeout(#loop{}) -> non_neg_integer().
recv_timeout(#loop{idle_deadline = undefined, idle_timeout = T}) ->
    T;
recv_timeout(#loop{idle_deadline = Deadline, hibernate_after = Ms}) ->
    case max(0, Deadline - erlang:monotonic_time(millisecond)) of
        Left when Ms > 0, Ms < Left -> Ms;
        Left -> Left
    end.

%% Fired when `recv_more/1` sees no traffic for `recv_timeout/1`. With
%% no stream and no worker and `hibernate_after` the shorter wait, collapse
%% the heap via hibernation; the socket is already armed
%% (we reached recv_more through `arm_and_recv/1`), so the next inbound
%% frame, or any worker / `'DOWN'` / drain message, wakes us and
%% `recv_more_hib/2` resumes the loop. A hibernated process only wakes
%% on a message, so a timer for the rest of the idle timeout goes with
%% it: without one, an idle conn would never send its idle GOAWAY.
%% A conn still serving is not idle, however quiet the wire: a handler
%% may take longer than the idle timeout to answer, or a `{loop, ...}`
%% stream wait that long for its next event. It sends a PING (RFC 9113
%% §6.7) and waits again: a live client ACKs it, and a client gone without
%% a word (a dropped network, a NAT that forgot the flow) lets another
%% idle timeout pass, which closes the conn. Otherwise emit the idle
%% GOAWAY now.
-spec recv_idle_expired(#loop{}) -> no_return().
recv_idle_expired(#loop{idle_deadline = Deadline} = State) when is_integer(Deadline) ->
    %% Idle: time left means the `hibernate_after` wait ran out first.
    case Deadline - erlang:monotonic_time(millisecond) of
        Left when Left > 0 ->
            TRef = erlang:start_timer(Left, self(), ?MODULE),
            erlang:hibernate(?MODULE, recv_more_hib, [State, TRef]);
        _Passed ->
            idle_goaway(State)
    end;
recv_idle_expired(#loop{liveness_ping = false} = State) ->
    case serving(State) of
        true ->
            _ = send(State, roadrunner_http2_frame:encode({ping, 0, ?LIVENESS_PING})),
            recv_more(State#loop{liveness_ping = true});
        false ->
            idle_goaway(State)
    end;
recv_idle_expired(State) ->
    %% The liveness PING went unanswered for a whole idle timeout: the
    %% client is gone if the conn still serves, else simply idle.
    case serving(State) of
        true -> idle_goaway(State, liveness_timeout);
        false -> idle_goaway(State)
    end.

%% Whether the conn is still serving: a worker runs and no stream holds
%% sends that wait for the client's flow-control window. A worker reading a
%% body waits on the client too, within its read's deadline, which the
%% handler may have moved to never (`roadrunner_req:set_body_timeout/2`):
%% the liveness PING is then all that ends a client gone quiet. A
%% client that stops granting window meets the idle timeout, and the conn
%% closes with every stream on it, a quiet one still at work included: a
%% client that holds a window shut that long has stopped reading.
-spec serving(#loop{}) -> boolean().
serving(#loop{workers = Workers}) when map_size(Workers) =:= 0 ->
    false;
serving(#loop{streams = Streams}) ->
    no_blocked_sends(maps:iterator(Streams)).

-spec no_blocked_sends(maps:iterator(stream_id(), #stream{})) -> boolean().
no_blocked_sends(Iter) ->
    case maps:next(Iter) of
        none ->
            true;
        {_StreamId, #stream{pending_sends = Pending}, Next} ->
            queue:is_empty(Pending) andalso no_blocked_sends(Next)
    end.

-spec idle_goaway(#loop{}) -> no_return().
idle_goaway(State) ->
    idle_goaway(State, keep_alive_timeout).

-spec idle_goaway(#loop{}, keep_alive_timeout | liveness_timeout) -> no_return().
idle_goaway(State, Reason) ->
    %% Closing an idle conn is no error (RFC 9113 §6.8, §7).
    _ = send_goaway(State, no_error),
    exit_clean(State, Reason).

%% The `idle_deadline` once `Streams` and `Workers` are what the conn holds:
%% the idle timeout from now when they leave it with no stream and no
%% worker, the deadline it already has otherwise. Set as the last stream
%% or worker goes, in the update that drops it: every path that drops a
%% stream (`remove_stream/3`, `drop_reset_stream/2`, `abort_stream/3`) or
%% a worker whose stream is gone (`handle_worker_down/4`) asks it.
-spec idle_deadline(#{stream_id() => #stream{}}, #{reference() => stream_id()}, #loop{}) ->
    integer() | undefined.
idle_deadline(Streams, Workers, #loop{idle_deadline = undefined, idle_timeout = T}) when
    map_size(Streams) =:= 0, map_size(Workers) =:= 0
->
    erlang:monotonic_time(millisecond) + T;
idle_deadline(_Streams, _Refs, #loop{idle_deadline = Deadline}) ->
    Deadline.

%% Judge a client PING against the `ping_policy`, as gRPC servers do
%% (grpc-go's `handlePing`, gRPC core's ping policy): one that comes less
%% than the policy's least time after the client's last PING (with a
%% stream open, or with none) is a strike, and the strike past
%% `max_strikes` closes the conn (`too_many_pings/2`). Strikes do not wear
%% off; HEADERS or DATA the conn sends clears them and makes the next PING
%% free (`ping_clock`), so a client pinging as it reads a response (to
%% measure its bandwidth) is never struck.
-spec ping_strike(#loop{}) -> {ok, #loop{}} | too_many_pings.
ping_strike(#loop{ping_policy = off} = State) ->
    {ok, State};
ping_strike(#loop{ping_clock = undefined} = State) ->
    {ok, State#loop{ping_clock = {erlang:monotonic_time(millisecond), 0}}};
ping_strike(
    #loop{
        ping_policy = {MinTime, IdleMinTime, MaxStrikes},
        ping_clock = {Last, Strikes},
        live_streams = Live
    } = State
) ->
    Now = erlang:monotonic_time(millisecond),
    Least =
        case Live of
            0 -> IdleMinTime;
            _ -> MinTime
        end,
    case Now - Last >= Least of
        true -> {ok, State#loop{ping_clock = {Now, Strikes}}};
        false when Strikes >= MaxStrikes -> too_many_pings;
        false -> {ok, State#loop{ping_clock = {Now, Strikes + 1}}}
    end.

%% A client past its PING strikes: answer the PING (RFC 9113 §6.7), then
%% close with GOAWAY(ENHANCE_YOUR_CALM) and `too_many_pings` (gRPC's
%% keepalive enforcement), which tells a gRPC client to ping less.
-spec too_many_pings(#loop{}, iodata()) -> no_return().
too_many_pings(#loop{last_stream_id = LastId} = State, Ack) ->
    _ = send(State, [
        Ack,
        roadrunner_http2_frame:encode({goaway, LastId, enhance_your_calm, ?TOO_MANY_PINGS})
    ]),
    exit_clean(State, too_many_pings).

%% Hibernate re-entry (see `recv_idle_expired/1`). Drops the idle
%% timer and resumes the unified mailbox loop after an idle conn wakes
%% from `erlang:hibernate/3`. If the timer already fired, the conn sat
%% out its whole idle timeout: consume the timer's message and send the
%% idle GOAWAY.
-doc false.
-spec recv_more_hib(#loop{}, reference()) -> no_return().
recv_more_hib(State, TRef) ->
    case erlang:cancel_timer(TRef) of
        false ->
            receive
                {timeout, TRef, ?MODULE} -> idle_goaway(State)
            end;
        _Left ->
            recv_more(State)
    end.

%% Begin a graceful drain: start the graceful close (`announce_goaway/2`)
%% unless one is under way, and refuse new streams once it is done.
%% In-flight workers continue to completion, and
%% each gets the same `{roadrunner_drain, Deadline}` the conn did: the
%% handler runs in the worker, not here, so this is how a `{loop, ...}`
%% response (an SSE stream, say) learns of the drain and can wind down,
%% as it does on HTTP/1.1, where it runs in the conn process. Every
%% worker gets it, not only loop ones, again as on HTTP/1.1: a worker
%% still in `handle/1` may be about to answer with a loop, and one that
%% is not just leaves it unread. Idempotent: subsequent drain messages
%% are no-ops, so a worker hears of the drain once.
-spec start_drain(#loop{}, integer()) -> #loop{}.
start_drain(#loop{drain_deadline = Deadline} = State, _Deadline) when is_integer(Deadline) ->
    State;
start_drain(#loop{streams = Streams} = State, Deadline) ->
    ok = maps:foreach(
        fun
            (_StreamId, #stream{worker_pid = Pid, worker_ref = MonRef}) when is_reference(MonRef) ->
                _ = (Pid ! {roadrunner_drain, Deadline}),
                ok;
            (_StreamId, _Stream) ->
                ok
        end,
        Streams
    ),
    announce_goaway(State#loop{drain_deadline = Deadline}, drained).

%% The first step of a graceful close (RFC 9113 §6.8): a GOAWAY(NO_ERROR)
%% naming the largest stream id, so a request the client sends before it
%% sees the GOAWAY is still served rather than refused, then a PING. Its
%% ACK comes after the client has read the GOAWAY, so every stream it
%% opened before then has reached us by then: `final_goaway/2` names
%% the last of them. A client that never answers gets the final GOAWAY
%% an idle timeout later. A close already under way is left as it is.
-spec announce_goaway(#loop{}, close_reason()) -> #loop{}.
announce_goaway(#loop{goaway = open, idle_timeout = Timeout} = State, Reason) ->
    _ = send(State, [
        ?GOAWAY(?MAX_STREAM_ID, no_error),
        roadrunner_http2_frame:encode({ping, 0, ?GOAWAY_PING})
    ]),
    TRef = erlang:start_timer(Timeout, self(), {?MODULE, goaway_ping}),
    State#loop{goaway = {announced, TRef, Reason}};
announce_goaway(State, _Reason) ->
    State.

%% The second step of a graceful close: the GOAWAY(NO_ERROR) naming the
%% last stream this conn opened. Every stream up to it is served to its
%% end, and every later one refused.
-spec final_goaway(#loop{}, close_reason()) -> #loop{}.
final_goaway(State, Reason) ->
    _ = send_goaway(State, no_error),
    maybe_exit_when_drained(State#loop{goaway = {final, Reason}}).

%% A timer this conn started went off. One no longer wanted (its step
%% already happened another way) is ignored. The conn reaching its
%% `connection_age` starts the graceful close (which a drain may have
%% started already) and the grace it has to finish in.
-spec handle_timer(
    #loop{},
    reference(),
    goaway_ping | {connection_age, non_neg_integer() | infinity} | connection_age_grace
) -> #loop{}.
handle_timer(#loop{goaway = {announced, TRef, Reason}} = State, TRef, goaway_ping) ->
    final_goaway(State, Reason);
handle_timer(State, _TRef, {connection_age, Grace}) ->
    ok = start_grace(Grace),
    announce_goaway(State, connection_age);
handle_timer(State, _TRef, connection_age_grace) ->
    grace_expired(State);
handle_timer(State, _TRef, goaway_ping) ->
    State.

-spec start_grace(non_neg_integer() | infinity) -> ok.
start_grace(infinity) ->
    ok;
start_grace(Grace) ->
    _ = erlang:start_timer(Grace, self(), {?MODULE, connection_age_grace}),
    ok.

%% The `connection_age` grace ran out with requests still open: reset each
%% stream not yet closed with CANCEL (RFC 9113 §8.4, the request is no
%% longer wanted) and close the conn. A client that has only seen the
%% first GOAWAY (a grace shorter than its answer to the PING) gets the
%% final one first, naming the last stream this conn took: any stream it
%% opened after that was not processed and is safe to retry (§6.8).
-spec grace_expired(#loop{}) -> no_return().
grace_expired(#loop{streams = Streams} = State) ->
    _ = send(State, [
        final_goaway_frame(State)
        | [
            roadrunner_http2_frame:encode({rst_stream, StreamId, cancel})
         || StreamId := #stream{state = StreamState} <- Streams, StreamState =/= closed
        ]
    ]),
    exit_clean(State, connection_age_grace).

-spec final_goaway_frame(#loop{}) -> iodata().
final_goaway_frame(#loop{goaway = {final, _}}) ->
    [];
final_goaway_frame(#loop{last_stream_id = LastId}) ->
    ?GOAWAY(LastId, no_error).

%% Spawn the worker for `StreamId`. A worker started once the drain has
%% begun (a stream below the GOAWAY whose body was still arriving, or a
%% request parked for an in-flight slot) gets the drain message right
%% away, as the workers already running did in `start_drain/2`.
-spec start_worker(#loop{}, stream_id(), roadrunner_req:request()) -> {pid(), reference()}.
start_worker(
    #loop{
        proto_opts = ProtoOpts,
        peer_max_header_list_size = PeerLimit,
        heap_floor = HeapFloor,
        drain_deadline = Deadline
    },
    StreamId,
    Req
) ->
    {WorkerPid, _MonRef} =
        Worker = roadrunner_http2_stream_worker:start(
            self(),
            StreamId,
            Req,
            ProtoOpts,
            PeerLimit,
            roadrunner_stream_worker:heap_floor(HeapFloor, StreamId, h2)
        ),
    _ =
        case Deadline of
            undefined -> ok;
            _ -> WorkerPid ! {roadrunner_drain, Deadline}
        end,
    Worker.

%% Once we're draining and the streams map empties, exit cleanly.
%% Called after every event that could remove a stream. Note that
%% `exit_clean/1` is `no_return`, so on the drained branch this
%% function never returns and the caller's tail-call to
%% `recv_more/1` is dead — typed as `#loop{}` rather than
%% `no_return()` so the type-checker sees the live path.
-spec maybe_exit_when_drained(#loop{}) -> #loop{}.
maybe_exit_when_drained(#loop{goaway = {final, Reason}, streams = Streams} = State) when
    map_size(Streams) =:= 0
->
    exit_clean(State, Reason);
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
            goaway_exit(State, protocol_error)
    end;
handle_frame({settings, 1, _}, #loop{max_concurrent_streams = MaxStreams} = State) ->
    %% The client applied our SETTINGS (RFC 9113 §6.5.3): we send one
    %% SETTINGS frame, so this puts our stream limit in force. Streams
    %% already open stay; new ones over the limit are refused.
    frame_loop(State#loop{stream_limit = MaxStreams});
handle_frame({settings, 0, Params}, State) ->
    case validate_settings(Params) of
        ok ->
            case apply_initial_window_size(Params, State) of
                {ok, State1} ->
                    %% Raising INITIAL_WINDOW_SIZE grows open streams' send
                    %% windows (RFC 9113 §6.9.2): ACK, then drain any sends
                    %% blocked at the old window, like the WINDOW_UPDATE path.
                    State2 = apply_peer_max_header_list_size(
                        Params, apply_header_table_size(Params, State1)
                    ),
                    _ = send(State2, roadrunner_http2_frame:encode({settings, 1, []})),
                    frame_loop(flush_all_pending_data(State2));
                {error, flow_control_error} ->
                    goaway_exit(State, flow_control_error)
            end;
        {error, {protocol_error, _}} ->
            goaway_exit(State, protocol_error);
        {error, {flow_control_error, _}} ->
            goaway_exit(State, flow_control_error)
    end;
handle_frame({ping, 1, ?LIVENESS_PING}, State) ->
    frame_loop(State#loop{liveness_ping = false});
handle_frame({ping, 1, ?GOAWAY_PING}, #loop{goaway = {announced, TRef, Reason}} = State) ->
    _ = erlang:cancel_timer(TRef, [{async, true}, {info, false}]),
    frame_loop(final_goaway(State, Reason));
handle_frame({ping, 1, _Data}, State) ->
    frame_loop(State);
handle_frame({ping, 0, Opaque}, State) ->
    Ack = roadrunner_http2_frame:encode({ping, 1, Opaque}),
    case ping_strike(State) of
        {ok, State1} ->
            _ = send(State1, Ack),
            frame_loop(State1);
        too_many_pings ->
            too_many_pings(State, Ack)
    end;
handle_frame({window_update, 0, Inc}, State) ->
    case State#loop.conn_send_window + Inc of
        New when New > ?MAX_WINDOW ->
            goaway_exit(State, flow_control_error);
        New ->
            State1 = State#loop{conn_send_window = New},
            frame_loop(flush_all_pending_data(State1))
    end;
handle_frame({window_update, StreamId, Inc}, #loop{streams = Streams} = State) ->
    case Streams of
        #{StreamId := #stream{send_window = SW} = Stream} ->
            case SW + Inc of
                New when New > ?MAX_WINDOW ->
                    %% RFC 9113 §6.9.1: stream-level overflow is a
                    %% stream error, not a connection error. The stream's
                    %% worker may still be running, so tear the stream
                    %% down the way a peer reset does: the worker is told,
                    %% and its slot is held until it ends.
                    _ = send_rst_stream(State, StreamId, flow_control_error),
                    frame_loop(reset_stream(State, StreamId));
                New ->
                    Stream1 = Stream#stream{send_window = New},
                    State1 = State#loop{streams = Streams#{StreamId := Stream1}},
                    frame_loop(flush_pending_data(State1, StreamId))
            end;
        #{} ->
            %% RFC 9113 §5.1: WINDOW_UPDATE on an idle stream is
            %% PROTOCOL_ERROR. A closed-stream WU (id <=
            %% peer_stream_id) is silently ignored per §6.9.
            case StreamId > State#loop.peer_stream_id of
                true ->
                    goaway_exit(State, protocol_error);
                false ->
                    frame_loop(State)
            end
    end;
handle_frame(
    {priority, StreamId, #{stream_dependency := StreamId}}, #loop{streams = Streams} = State
) ->
    %% RFC 9113 §5.3.1: a stream cannot depend on itself —
    %% stream-error PROTOCOL_ERROR. A stream we hold is torn down the way
    %% a peer reset does (its worker told; its slot held until the worker
    %% ends), so no frame of ours follows the RST_STREAM.
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
            frame_loop(drop_reset_stream(State, StreamId));
        #{} ->
            %% RFC 9113 §5.1: RST_STREAM on an idle stream is
            %% PROTOCOL_ERROR (we never opened it). On a closed
            %% stream (id <= peer_stream_id) the receipt is a no-op
            %% per §5.4 — it's the peer telling us about the
            %% already-closed lifecycle.
            case StreamId > State#loop.peer_stream_id of
                true ->
                    goaway_exit(State, protocol_error);
                false ->
                    frame_loop(State)
            end
    end;
handle_frame({goaway, _, _, _}, State) ->
    %% Client is shutting down.
    exit_clean(State, peer_closed);
handle_frame({headers, StreamId, Flags, Priority, Fragment}, State) ->
    on_headers(StreamId, Flags, Priority, Fragment, State);
handle_frame({continuation, StreamId, Flags, Fragment}, State) ->
    on_continuation(StreamId, Flags, Fragment, State);
handle_frame({data, StreamId, Flags, Payload, FlowLen}, State) ->
    on_data(StreamId, Flags, Payload, FlowLen, grow_buffer(Flags, Payload, State));
handle_frame({push_promise, _, _, _, _}, State) ->
    %% Servers MUST NOT receive PUSH_PROMISE — RFC 9113 §6.6.
    goaway_exit(State, protocol_error);
handle_frame({unknown, _Type, _StreamId}, State) ->
    %% RFC 9113 §4.1: unknown frame types MUST be ignored. The
    %% awaiting_continuation guard above already rejected the
    %% mid-header-block case (§6.10), so reaching here is benign.
    frame_loop(State).

%% A prior-knowledge h2c socket starts with the small `idle_recv_buffer`,
%% which bounds what an idle connection holds, and every `{active, N}` read
%% is sized by it. A request body that may be larger, a DATA frame with a
%% payload that does not end its stream or does not fit in that buffer,
%% grows it to `recv_buffer` for the rest of the connection, so large
%% bodies are not read in small pieces. A small body sent whole in one
%% frame, as an API client's JSON usually is, leaves it small, like the
%% HTTP/1.1 threshold in `roadrunner_conn_loop:grow_buffer/2`. It stays
%% grown: the driver hands a freed buffer back to the next read that fits
%% in it, so shrinking would not release it.
-spec grow_buffer(non_neg_integer(), binary(), #loop{}) -> #loop{}.
grow_buffer(_Flags, _Payload, #loop{grow_buffer = undefined} = State) ->
    State;
grow_buffer(_Flags, <<>>, State) ->
    State;
grow_buffer(Flags, Payload, #loop{grow_buffer = {Idle, _Max}} = State) when
    Flags band 16#01 =/= 0, byte_size(Payload) =< Idle
->
    State;
grow_buffer(_Flags, _Payload, #loop{grow_buffer = {_Idle, Max}, socket = Socket} = State) ->
    _ = roadrunner_transport:setopts(Socket, [{buffer, Max}]),
    State#loop{grow_buffer = undefined}.

%% --- HEADERS / CONTINUATION ---

on_headers(StreamId, _Flags, _Priority, _Fragment, State) when StreamId rem 2 =:= 0 ->
    %% RFC 9113 §5.1.1: client-initiated stream IDs are odd.
    goaway_exit(State, protocol_error);
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
            Stream1 = Stream#stream{
                header_fragment = Fragment,
                header_len = byte_size(Fragment),
                end_headers = EndHeaders,
                end_stream_seen = true
            },
            case Priority of
                #{stream_dependency := StreamId} ->
                    %% RFC 9113 §5.3.1: a stream cannot depend on itself —
                    %% stream-error PROTOCOL_ERROR, its trailer block still
                    %% decoded (`refuse_block/5`).
                    State1 = update_stream(State, StreamId, Stream1#stream{refused = protocol_error}),
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
            goaway_exit(State, protocol_error)
    end;
on_headers(StreamId, Flags, _Priority, Fragment, #loop{reset_ids = {_, Ids}} = State) when
    StreamId =< State#loop.peer_stream_id, is_map_key(StreamId, Ids)
->
    %% Trailers the peer sent before it saw our RST_STREAM (RFC 9113 §5.1:
    %% ignored on a stream we reset), decoded all the same so the HPACK
    %% state stays in step (§4.3). Only an id at or below the last opened
    %% one can be remembered, so a new stream's HEADERS skips the lookup.
    refuse_new_stream(StreamId, Flags, Fragment, ignore, State);
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
    goaway_exit(State, protocol_error);
on_headers(StreamId, Flags, #{stream_dependency := StreamId}, Fragment, State) ->
    %% RFC 9113 §5.3.1: a stream cannot depend on itself —
    %% stream-error PROTOCOL_ERROR.
    refuse_new_stream(StreamId, Flags, Fragment, protocol_error, State);
on_headers(StreamId, Flags, _Priority, Fragment, #loop{goaway = {final, _}} = State) ->
    %% Past the final GOAWAY(NO_ERROR) of a graceful close: refuse all
    %% new streams. The peer already saw it; it knows new requests on
    %% this conn won't be served, and may retry them elsewhere.
    refuse_new_stream(StreamId, Flags, Fragment, refused_stream, State);
on_headers(
    StreamId,
    Flags,
    _Priority,
    Fragment,
    #loop{live_streams = Live, reset_workers = Reset, stream_limit = Limit} = State
) when
    Live + map_size(Reset) >= Limit
->
    refuse_over_limit(StreamId, Flags, Fragment, map_size(Reset) >= Limit, State);
on_headers(StreamId, Flags, _Priority, Fragment, State) ->
    EndHeaders = (Flags band 16#04) =/= 0,
    EndStream = (Flags band 16#01) =/= 0,
    Stream = new_stream(
        Fragment,
        EndHeaders,
        EndStream,
        State#loop.peer_initial_window,
        ?INITIAL_WINDOW,
        State#loop.max_content_length
    ),
    State1 = State#loop{
        streams = (State#loop.streams)#{StreamId => Stream},
        live_streams = State#loop.live_streams + 1,
        idle_deadline = undefined,
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

%% A stream over the concurrency limit is refused with REFUSED_STREAM, which
%% the client may retry (RFC 9113 §8.7). When the handlers of reset streams
%% fill the whole limit on their own (the `true` clauses), the client has no stream
%% left that it waits on and nothing it opens can be admitted until one of
%% those handlers ends. `stream_limit` refusals in that state,
%% with none of the handlers ending in between, mean it keeps opening
%% streams far beyond the limit: the connection ends with
%% GOAWAY(ENHANCE_YOUR_CALM), the code for a peer exhausting resources
%% (§5.4.1, §7). A client that still has streams of its own open is only
%% refused, as it may have opened the new stream before it saw our limit
%% come into force, or while a stream it reset still had its handler
%% running.
-spec refuse_over_limit(stream_id(), non_neg_integer(), binary(), boolean(), #loop{}) ->
    no_return().
refuse_over_limit(_StreamId, _Flags, _Fragment, true, #loop{reset_refusals = Refusals} = State) when
    Refusals >= State#loop.stream_limit
->
    goaway_exit(State, enhance_your_calm);
refuse_over_limit(StreamId, Flags, Fragment, true, #loop{reset_refusals = Refusals} = State) ->
    refuse_new_stream(
        StreamId, Flags, Fragment, refused_stream, State#loop{reset_refusals = Refusals + 1}
    );
refuse_over_limit(StreamId, Flags, Fragment, false, State) ->
    refuse_new_stream(StreamId, Flags, Fragment, refused_stream, State).

%% RFC 9113 §4.3, §6.8: a field block updates the connection's HPACK
%% state even when we refuse its stream, so the block is decoded (once its
%% CONTINUATION frames are in) before the stream is reset; skipping it
%% would desync our decoder from the peer's encoder for every later block.
%% The refused stream still uses its id (§5.1.1), so DATA the peer already
%% sent on it lands on a closed stream, not an idle one, and it never
%% counts toward `max_concurrent_streams`.
-spec refuse_new_stream(
    stream_id(), non_neg_integer(), binary(), roadrunner_http2_frame:error_code() | ignore, #loop{}
) -> no_return().
refuse_new_stream(StreamId, Flags, Fragment, Code, State) ->
    EndHeaders = (Flags band 16#04) =/= 0,
    Stream = new_stream(
        Fragment,
        EndHeaders,
        (Flags band 16#01) =/= 0,
        State#loop.peer_initial_window,
        ?INITIAL_WINDOW,
        State#loop.max_content_length
    ),
    State1 = State#loop{
        streams = (State#loop.streams)#{
            StreamId => Stream#stream{state = closed, counted = false, refused = Code}
        },
        peer_stream_id = max(StreamId, State#loop.peer_stream_id)
    },
    refuse_block(StreamId, EndHeaders, Fragment, Code, State1).

%% A refused stream's field block: decode it now when complete, or wait
%% for its CONTINUATION frames (`on_continuation/4` finishes it).
-spec refuse_block(
    stream_id(), boolean(), binary(), roadrunner_http2_frame:error_code() | ignore, #loop{}
) -> no_return().
refuse_block(StreamId, true, Fragment, Code, State) ->
    reset_refused(StreamId, Fragment, Code, State);
refuse_block(StreamId, false, _Fragment, _Code, State) ->
    frame_loop(State#loop{awaiting_continuation = StreamId}).

%% Decode a refused stream's complete field block for its HPACK side
%% effects only, then reset the stream with `Code`, or drop it with
%% `ignore`.
-spec reset_refused(
    stream_id(), iodata(), roadrunner_http2_frame:error_code() | ignore, #loop{}
) -> no_return().
reset_refused(StreamId, Fragment, Code, #loop{hpack_dec = Dec} = State) ->
    case roadrunner_http2_hpack:decode(iolist_to_binary(Fragment), Dec) of
        {ok, _Headers, Dec1} ->
            State1 = State#loop{hpack_dec = Dec1},
            _ =
                case Code of
                    ignore -> ok;
                    _ -> send_rst_stream(State1, StreamId, Code)
                end,
            frame_loop(reset_stream(State1, StreamId));
        {error, Reason} ->
            goaway_exit(State, decode_error_code(Reason))
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
    #stream{
        header_fragment = Fragment,
        header_len = byte_size(Fragment),
        end_headers = EndHeaders,
        end_stream_seen = EndStream,
        body_cap = BodyCap,
        send_window = SendWindow,
        recv_window = RecvWindow,
        pending_sends = queue:new()
    }.

on_continuation(
    StreamId, Flags, Fragment, #loop{streams = Streams, header_block_ceiling = Ceiling} = State
) ->
    case Streams of
        #{
            StreamId :=
                #stream{
                    end_headers = false,
                    header_fragment = Frags,
                    header_len = Len,
                    headers = PriorHeaders,
                    refused = Refused
                } = Stream
        } ->
            FragLen = byte_size(Fragment),
            NewLen = Len + FragLen,
            EndHeaders = (Flags band 16#04) =/= 0,
            %% CONTINUATION-flood guard, both variants. The assembled
            %% block crossed the ceiling (memory exhaustion), or a non-final
            %% empty CONTINUATION made no forward progress (an endless
            %% stream of those pins the conn in header assembly without
            %% ever growing the byte total). Each frame is bounded by
            %% MAX_FRAME_SIZE but neither the cumulative size nor the
            %% frame count is otherwise limited. The per-connection HPACK
            %% context can't be resynced if we skip the block, so this is
            %% a connection error rather than a per-stream reject (a block
            %% only over `max_header_block` is, in `finalize_headers/2`).
            %% ENHANCE_YOUR_CALM is the RFC 9113 §6.5.2 resource-limit code.
            case NewLen > Ceiling orelse (FragLen =:= 0 andalso not EndHeaders) of
                true ->
                    goaway_exit(State, enhance_your_calm);
                false ->
                    Stream1 = Stream#stream{
                        header_fragment = [Frags, Fragment],
                        header_len = NewLen,
                        end_headers = EndHeaders
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
                            case {Refused, PriorHeaders} of
                                {undefined, undefined} ->
                                    finalize_headers(StreamId, State1);
                                {undefined, _} ->
                                    finalize_trailers(StreamId, State1);
                                {Code, _} ->
                                    reset_refused(StreamId, [Frags, Fragment], Code, State1)
                            end
                    end
            end;
        _ ->
            goaway_exit(State, protocol_error)
    end.

%% Decode an inbound trailer HPACK block. We currently drop the
%% decoded fields (handlers don't see request trailers yet) but
%% MUST advance the HPACK decoder context so subsequent header
%% blocks decode correctly. After consuming, dispatch the
%% pending request (END_STREAM was already set by `on_headers/5`).
finalize_trailers(StreamId, #loop{streams = Streams, hpack_dec = Dec} = State) ->
    #{StreamId := #stream{header_fragment = Fragment} = Stream} = Streams,
    case roadrunner_http2_hpack:decode(iolist_to_binary(Fragment), Dec) of
        {ok, _Trailers, Dec1} ->
            Stream1 = Stream#stream{header_fragment = <<>>},
            State1 = State#loop{
                hpack_dec = Dec1,
                streams = Streams#{StreamId := Stream1}
            },
            case State1#loop.body_buffering of
                auto -> dispatch_stream(StreamId, State1);
                manual -> body_in(StreamId, Stream1, State1)
            end;
        {error, Reason} ->
            goaway_exit(State, decode_error_code(Reason))
    end.

%% Decode the accumulated HPACK fragment, store decoded headers on
%% the stream entry. If END_STREAM was set on the HEADERS frame,
%% dispatch the worker now (no body); otherwise wait for DATA.
finalize_headers(
    StreamId,
    #loop{
        streams = Streams,
        hpack_dec = Dec,
        max_header_block = MaxHeaderBlock,
        max_header_list_size = MaxHLS
    } = State
) ->
    #{
        StreamId := #stream{
            header_fragment = Fragment,
            header_len = Len,
            end_stream_seen = EndStreamSeen
        } = Stream
    } = Streams,
    case roadrunner_http2_hpack:decode(iolist_to_binary(Fragment), Dec) of
        {ok, Headers, Dec1} ->
            %% A request with a body still to come notes when its headers
            %% were decoded (`headers_at`); one dispatched now takes the time
            %% as it is built (`dispatch_request/5`).
            Stream1 =
                case EndStreamSeen of
                    true ->
                        Stream#stream{headers = Headers, header_fragment = <<>>};
                    false ->
                        Stream#stream{
                            headers = Headers,
                            header_fragment = <<>>,
                            headers_at = erlang:monotonic_time(millisecond)
                        }
                end,
            %% Commit the mutated HPACK context even if we reject below: the
            %% decode advanced the dynamic table, so dropping it would desync
            %% our decoder from the peer's encoder for every later block.
            State1 = State#loop{
                hpack_dec = Dec1,
                streams = Streams#{StreamId := Stream1}
            },
            case Len > MaxHeaderBlock orelse roadrunner_http:header_list_size(Headers) > MaxHLS of
                true ->
                    %% The block is over `max_header_block`, or the decoded
                    %% list over the MAX_HEADER_LIST_SIZE we advertised (RFC
                    %% 9113 §6.5.2). Either refuses this request alone
                    %% (§10.5.1): answer 431, then RST_STREAM(NO_ERROR)
                    %% (decode succeeded, so the connection is intact), and
                    %% drop the stream; no worker is dispatched until
                    %% END_STREAM.
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
                    frame_loop(remove_reset_stream(State2, StreamId));
                false ->
                    case EndStreamSeen of
                        true -> dispatch_stream(StreamId, State1);
                        false -> await_body(StreamId, Headers, State1)
                    end
            end;
        {error, Reason} ->
            goaway_exit(State, decode_error_code(Reason))
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
            frame_loop(remove_reset_stream(State, StreamId));
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
    State#loop{hpack_enc = Enc1, ping_clock = undefined}.

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
    frame_loop(remove_reset_stream(State1, StreamId)).

%% --- DATA ---

on_data(StreamId, _Flags, _Payload, _FlowLen, State) when StreamId > State#loop.peer_stream_id ->
    %% RFC 9113 §5.1: DATA on an idle stream is PROTOCOL_ERROR.
    goaway_exit(State, protocol_error);
on_data(StreamId, _Flags, _Payload, FlowLen, #loop{streams = Streams} = State) when
    not is_map_key(StreamId, Streams)
->
    %% DATA on a stream we no longer hold. Its bytes still consumed the
    %% peer's connection-level send window (RFC 9113 §6.9.1); return the
    %% full on-wire `FlowLen` (padding included) since we're discarding
    %% them, so the conn window doesn't drift down across resets. On a
    %% stream we reset, the peer sent it before it saw our RST_STREAM:
    %% ignored (§5.1). On any other closed stream it is STREAM_CLOSED
    %% (§6.1). A stream we hold, the common case, never gets here.
    _ =
        case State#loop.reset_ids of
            {_, #{StreamId := _}} -> ok;
            _ -> send_rst_stream(State, StreamId, stream_closed)
        end,
    frame_loop(replenish_conn_window(State, FlowLen));
on_data(StreamId, Flags, Payload, FlowLen, #loop{streams = Streams} = State) ->
    case Streams of
        #{
            StreamId :=
                #stream{
                    end_stream_seen = false,
                    body = Body,
                    body_len = Len,
                    body_cap = Cap,
                    recv_window = RW
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
                    goaway_exit(State, flow_control_error);
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
                            Stream1 = Stream#stream{
                                body = [Body, Payload],
                                body_len = NewLen,
                                body_cap = BodyCap,
                                end_stream_seen = EndStream,
                                recv_window = RW - FlowLen
                            },
                            State1 = State#loop{
                                streams = Streams#{StreamId := Stream1},
                                conn_recv_window = ConnWindow - FlowLen
                            },
                            case State1#loop.body_buffering of
                                auto ->
                                    %% The DATA that ends the body leaves the
                                    %% stream no more to receive, so only the
                                    %% connection's window may need credit back.
                                    case EndStream of
                                        true ->
                                            dispatch_stream(StreamId, refill_conn_window(State1));
                                        false ->
                                            frame_loop(maybe_refill_recv_windows(State1, StreamId))
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
    stream_id(), #stream{}, non_neg_integer(), boolean(), non_neg_integer(), #loop{}
) -> no_return().
body_over_cap(
    StreamId,
    #stream{manual = true, reader = Reader, recv_window = RW} = Stream,
    NewLen,
    EndStream,
    FlowLen,
    State
) ->
    ok = roadrunner_conn:send_body_error(Reader, StreamId, content_length_too_large),
    Stream1 = Stream#stream{
        body = [],
        body_len = NewLen,
        end_stream_seen = EndStream,
        recv_window = RW - FlowLen,
        reader = undefined,
        body_error = content_length_too_large
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
-spec body_in(stream_id(), #stream{}, #loop{}) -> no_return().
body_in(
    StreamId, #stream{body_len = Len, end_stream_seen = Ended, declared = Declared} = Stream, State
) ->
    case roadrunner_http:body_length_fits(Declared, Len, Ended) of
        false ->
            _ = send_rst_stream(State, StreamId, protocol_error),
            frame_loop(reset_stream(State, StreamId));
        true ->
            State1 =
                case Stream of
                    #stream{state = closed} ->
                        update_stream(State, StreamId, Stream#stream{body = []});
                    #stream{reader = Reader} when is_pid(Reader) ->
                        deliver(State, StreamId, Stream);
                    _ ->
                        State
                end,
            frame_loop(ended_after_answer(State1, StreamId))
    end.

%% Hand a manual-mode stream's received DATA to its waiting worker, `Fin`
%% marking the body's end, and give the stream its receive window back now
%% that the DATA has left the connection: what a stream holds for its
%% worker stays within one window, however slowly the worker reads.
-spec deliver(#loop{}, stream_id(), #stream{}) -> #loop{}.
deliver(
    State, StreamId, #stream{reader = Reader, body = Body, end_stream_seen = Ended} = Stream
) ->
    ok = roadrunner_conn:send_body(Reader, StreamId, Body, Ended),
    State1 = update_stream(State, StreamId, Stream#stream{body = [], reader = undefined}),
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
        #{StreamId := #stream{end_stream_seen = true, state = closed}} ->
            uncount_stream(State, StreamId);
        _ ->
            State
    end.

%% A worker's body read timed out (`roadrunner_conn:stream_recv/2`) and
%% takes its demand back: DATA arriving later stays with the stream
%% instead of going to a worker no longer reading. The answer tells the
%% worker that whatever was handed to it before has arrived.
-spec withdraw_body_demand(#loop{}, pid(), stream_id()) -> #loop{}.
withdraw_body_demand(#loop{streams = Streams} = State, Worker, StreamId) ->
    _ = Worker ! {roadrunner_body_withdrawn, StreamId},
    case Streams of
        #{StreamId := #stream{reader = Worker} = Stream} ->
            State#loop{streams = Streams#{StreamId := Stream#stream{reader = undefined}}};
        #{} ->
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
        #{StreamId := #stream{manual = true, state = Side, body_error = undefined} = Stream} when
            Side =/= closed
        ->
            {Stream1, State1} =
                case Stream of
                    #stream{continue_owed = true} ->
                        {Stream#stream{continue_owed = false}, send_continue(State, StreamId)};
                    _ ->
                        {Stream, State}
                end,
            #stream{body = Body, end_stream_seen = Ended} = Stream1,
            case Ended orelse iolist_size(Body) > 0 of
                true -> deliver(State1, StreamId, Stream1#stream{reader = Worker});
                false -> update_stream(State1, StreamId, Stream1#stream{reader = Worker})
            end;
        #{StreamId := #stream{manual = true, body_error = Reason}} when Reason =/= undefined ->
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
                StreamId := #stream{continue_owed = true, state = Side, body_error = undefined} =
                    Stream
            } when
                Side =/= closed
            ->
                update_stream(
                    send_continue(State, StreamId), StreamId, Stream#stream{continue_owed = false}
                );
            _ ->
                State
        end,
    _ = Worker ! {roadrunner_continued, StreamId},
    State1.

%% A worker about to send a complete response while the 100 Continue is
%% still owed (`roadrunner_conn:skip_continue/1`): a read after it sends
%% none, even while flow control still holds part of the response.
-spec skip_continue(#loop{}, stream_id()) -> #loop{}.
skip_continue(#loop{streams = Streams} = State, StreamId) ->
    case Streams of
        #{StreamId := #stream{continue_owed = true} = Stream} ->
            update_stream(State, StreamId, Stream#stream{continue_owed = false});
        _ ->
            State
    end.

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
-spec stream_body_cap(non_neg_integer(), roadrunner_router:body_limit(), #stream{}, #loop{}) ->
    roadrunner_router:body_limit().
stream_body_cap(NewLen, Cap, _Stream, _State) when NewLen =< Cap ->
    Cap;
stream_body_cap(
    _NewLen,
    _Cap,
    #stream{headers = Headers},
    #loop{proto_opts = #proto_opts{dispatch = Dispatch}, max_content_length = MaxCL}
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
) when W < Threshold, W < Peak ->
    %% Below the threshold and short of the peak: a peak under the RFC's
    %% opening 65535 (or a threshold set above the peak) leaves the window
    %% to drain down to the peak first, never shrinking it by a negative
    %% increment.
    Inc = Peak - W,
    {roadrunner_http2_frame:encode({window_update, 0, Inc}), State#loop{conn_recv_window = W + Inc}};
build_conn_refill(State) ->
    {[], State}.

build_stream_refill(
    #loop{
        streams = Streams,
        stream_recv_window_peak = Peak,
        stream_recv_window_threshold = Threshold
    } = State,
    StreamId
) ->
    #{StreamId := #stream{recv_window = W} = Stream} = Streams,
    if
        %% As for the connection window (`build_conn_refill/1`): a stream
        %% opens at the RFC's 65535, which may be above a small peak.
        W < Threshold, W < Peak ->
            Inc = Peak - W,
            {roadrunner_http2_frame:encode({window_update, StreamId, Inc}), State#loop{
                streams = Streams#{StreamId := Stream#stream{recv_window = W + Inc}}
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
        StreamId := #stream{
            headers = Headers,
            body_len = BodyLen,
            body = BodyIolist
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
            Dispatched = Stream#stream{state = half_closed_remote, body = []},
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
    #{StreamId := #stream{headers = Headers} = Stream} = Streams,
    case roadrunner_http:request_content_length(Headers) of
        error ->
            _ = send_rst_stream(State, StreamId, protocol_error),
            frame_loop(remove_reset_stream(State, StreamId));
        Declared ->
            Reading = Stream#stream{
                manual = true,
                continue_owed = ContinueOwed,
                declared = Declared
            },
            dispatch_request(StreamId, Reading, Headers, reader, State)
    end.

%% Build the request of `Stream` (already in the state it is dispatched
%% in) and admit it: refused over its rate, then given a worker, parked for
%% an in-flight slot, or refused over the ceiling. Its body is `{body, _}`
%% (buffered) or `reader` (manual mode).
-spec dispatch_request(
    stream_id(), #stream{}, roadrunner_http:headers(), {body, iodata()} | reader, #loop{}
) ->
    no_return().
dispatch_request(
    StreamId,
    Stream,
    Headers,
    Body,
    #loop{
        streams = Streams,
        peer = Peer,
        conn_info = ConnInfo,
        scheme = Scheme,
        listener_name = ListenerName,
        max_concurrent_requests = MaxConcReq,
        inflight_counter = InflightCounter,
        overload = Overload
    } = State
) ->
    {RequestId, NewBuf} = roadrunner_conn:generate_request_id(State#loop.req_id_buffer),
    RequestContext = roadrunner_http:request_context(
        Peer, ConnInfo, Scheme, ListenerName, RequestId, headers_at(Stream)
    ),
    case roadrunner_http2_request:from_headers(Headers, buffered_body(Body), RequestContext) of
        {ok, Req0} ->
            Req = request_body(
                StreamId,
                Stream,
                Body,
                roadrunner_conn:with_client_ip(Req0, State#loop.real_ip, Peer),
                State
            ),
            %% The new request-id buffer is stored by each branch's own final
            %% update (no separate copy of the ~50-word state first): neither
            %% the rate check nor the worker start reads it.
            case rate_limit_refused(State, StreamId, Req) of
                {refused, State1} ->
                    %% Per-peer rate exceeded: 429 + RST(no_error) sent,
                    %% no worker spawned. 429 (not REFUSED_STREAM) so the
                    %% client backs off per Retry-After instead of
                    %% retrying the stream immediately.
                    frame_loop(
                        remove_reset_stream(State1#loop{req_id_buffer = NewBuf}, StreamId)
                    );
                ok ->
                    case
                        roadrunner_conn:acquire_request_slot(
                            MaxConcReq, InflightCounter, Overload, StreamId
                        )
                    of
                        true ->
                            {WorkerPid, MonRef} = start_worker(State, StreamId, Req),
                            Stream1 = Stream#stream{
                                worker_pid = WorkerPid,
                                worker_ref = MonRef
                            },
                            frame_loop(State#loop{
                                req_id_buffer = NewBuf,
                                streams = Streams#{StreamId := Stream1},
                                workers = (State#loop.workers)#{WorkerPid => StreamId}
                            });
                        queued ->
                            %% Over the ceiling, but this listener
                            %% parks rather than sheds. Keep the
                            %% assembled request and go back to the
                            %% frame loop; the grant arrives as a
                            %% message.
                            Awaiting = State#loop.awaiting_slot,
                            frame_loop(State#loop{
                                req_id_buffer = NewBuf,
                                streams = Streams#{StreamId := Stream},
                                awaiting_slot = Awaiting#{StreamId => Req},
                                parked = true
                            });
                        false ->
                            %% Listener-wide in-flight ceiling reached —
                            %% refuse with retry-safe REFUSED_STREAM, no
                            %% worker spawned.
                            StateBuf = State#loop{req_id_buffer = NewBuf},
                            ok = throttle_stream(StateBuf, ListenerName),
                            _ = send_rst_stream(StateBuf, StreamId, refused_stream),
                            frame_loop(remove_reset_stream(StateBuf, StreamId));
                        {shed, RetryAfter} ->
                            %% Over the ceiling on a shed listener: 503 +
                            %% Retry-After, no worker spawned, so the client
                            %% waits instead of retrying the stream at once.
                            StateBuf = State#loop{req_id_buffer = NewBuf},
                            ok = throttle_stream(StateBuf, ListenerName),
                            State1 = retry_later(StateBuf, StreamId, 503, RetryAfter),
                            frame_loop(remove_reset_stream(State1, StreamId))
                    end
            end;
        {error, Reason} when Reason =:= not_implemented; Reason =:= unsupported_expectation ->
            %% A well-formed request roadrunner can't serve, answered as on
            %% HTTP/1.1, then the stream closed: 501 for a CONNECT (no
            %% tunnels), 417 for an expectation other than `100-continue`.
            Status = roadrunner_conn:parse_error_status(Reason),
            State1 = encode_and_send_response_atomic(State, StreamId, Status, [], ~"", 0),
            _ = send_rst_stream(State1, StreamId, no_error),
            frame_loop(remove_reset_stream(State1#loop{req_id_buffer = NewBuf}, StreamId));
        {error, _Reason} ->
            _ = send_rst_stream(State, StreamId, protocol_error),
            frame_loop(remove_reset_stream(State#loop{req_id_buffer = NewBuf}, StreamId))
    end.

%% When the request's header block was decoded: noted on a stream whose
%% body came after its headers, else now, as they were just decoded.
-spec headers_at(#stream{}) -> integer().
headers_at(#stream{headers_at = undefined}) -> erlang:monotonic_time(millisecond);
headers_at(#stream{headers_at = At}) -> At.

-spec buffered_body({body, iodata()} | reader) -> iodata().
buffered_body({body, Body}) -> Body;
buffered_body(reader) -> <<>>.

%% A manual-mode request reads its body through a reader instead of the
%% buffered `body`.
-spec request_body(
    stream_id(), #stream{}, {body, iodata()} | reader, roadrunner_req:request(), #loop{}
) ->
    roadrunner_req:request().
request_body(_StreamId, _Stream, {body, _Body}, Req, _State) ->
    Req;
request_body(
    StreamId,
    #stream{continue_owed = ContinueOwed},
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

handle_worker_down(#loop{workers = Workers} = State, MonRef, Pid, Reason) ->
    case Workers of
        #{Pid := StreamId} ->
            %% Release the in-flight slot exactly once, tied to removing the
            %% worker ref so a worker is accounted for by its `DOWN` here or
            %% by the conn's clean exit, never both.
            ok = roadrunner_conn:release_request_slot(
                State#loop.max_concurrent_requests,
                State#loop.inflight_counter,
                State#loop.overload
            ),
            Workers1 = maps:remove(Pid, Workers),
            case State#loop.streams of
                #{StreamId := #stream{worker_ref = MonRef}} ->
                    worker_ended(State, StreamId, Workers1, Reason);
                #{} ->
                    %% Its stream was reset while it ran (`drop_reset_stream/2`),
                    %% gone or left as a placeholder for a header block
                    %% still arriving (`forget_stream/3`): nothing is left
                    %% to answer, and the stream it held toward
                    %% `max_concurrent_streams` is free.
                    reset_worker_ended(
                        State#loop{
                            workers = Workers1,
                            idle_deadline = idle_deadline(State#loop.streams, Workers1, State)
                        },
                        MonRef
                    )
            end;
        #{} ->
            State
    end.

%% A worker whose stream was reset ended. If the stream counted toward
%% `max_concurrent_streams` when it was reset, the worker held its place
%% until now (`reset_workers`): give it back.
-spec reset_worker_ended(#loop{}, reference()) -> #loop{}.
reset_worker_ended(#loop{reset_workers = Reset} = State, MonRef) ->
    case Reset of
        #{MonRef := _} ->
            State#loop{reset_workers = maps:remove(MonRef, Reset), reset_refusals = 0};
        #{} ->
            State
    end.

%% The stream of a worker that exited, by how it exited.
-spec worker_ended(#loop{}, stream_id(), #{reference() => stream_id()}, term()) -> #loop{}.
worker_ended(State, StreamId, Workers, normal) ->
    finish_stream(State, StreamId, Workers);
worker_ended(State, StreamId, Workers, stream_reset) ->
    %% The worker wrote to a stream whose response had already ended (a
    %% stream fun sending after its `fin`): `stream_open/2` told it the
    %% stream was reset, so it stopped. The response on the wire is
    %% complete, so the stream ends as for a normal exit, never with an
    %% RST_STREAM after its END_STREAM (RFC 9113 §5.1: no frames on a
    %% closed stream).
    finish_stream(State, StreamId, Workers);
worker_ended(#loop{streams = Streams} = State, StreamId, Workers, _Reason) ->
    case Streams of
        #{StreamId := #stream{state = closed}} ->
            %% It ended abnormally after its response was complete
            %% (killed, or taken down by a linked process): the stream
            %% ends as for a normal exit, with no RST_STREAM on a stream
            %% closed both ways (RFC 9113 §5.1).
            worker_ended(State, StreamId, Workers, normal);
        #{} ->
            abort_stream(State#loop{workers = Workers}, StreamId, internal_error)
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
%% client waiting for an end that never comes. A stream reset while its
%% worker ran is gone by then, and `handle_worker_down/4` only gives the
%% slot back. In manual body mode the response
%% can end before the client's body does (a handler answering without
%% reading it all); RFC 9113 §8.1 lets the server then ask the client to
%% stop sending with RST_STREAM(NO_ERROR).
%%
%% `Workers` is the worker map without this worker's monitor; the common
%% end (closed both ways, nothing queued) stores it in the same update
%% that drops the stream.
-spec finish_stream(#loop{}, stream_id(), #{reference() => stream_id()}) -> #loop{}.
finish_stream(#loop{streams = Streams} = State, StreamId, Workers) ->
    #{StreamId := #stream{pending_sends = Pending} = Stream} = Streams,
    case {queue:is_empty(Pending), Stream} of
        {true, #stream{state = closed, end_stream_seen = true}} ->
            remove_stream(State, StreamId, Workers);
        {true, #stream{state = closed}} ->
            _ = send_rst_stream(State, StreamId, no_error),
            remove_stream(remember_reset(State, StreamId), StreamId, Workers);
        {true, _} ->
            abort_stream(State#loop{workers = Workers}, StreamId, internal_error);
        {false, _} ->
            update_stream(State#loop{workers = Workers}, StreamId, Stream#stream{
                worker_pid = undefined, worker_ref = undefined
            })
    end.

%% Look up a stream that has not yet been reset / closed. Returns
%% `not_open` for streams the conn has already torn down (peer
%% RST_STREAM, write of END_STREAM completed, etc.) — workers
%% asking to write to those should be told to abort.
%% Returns the `#stream{}` record directly on hit, or the atom
%% `not_open` if the stream is gone or its send side is already
%% closed. The two return shapes are disjoint (record vs. atom) so
%% callers can pattern-match without an `{ok, _}` wrapper.
stream_open(#loop{streams = Streams}, StreamId) ->
    case Streams of
        #{StreamId := #stream{state = closed}} -> not_open;
        #{StreamId := Stream} -> Stream;
        #{} -> not_open
    end.

%% The response field section as sent, built by the function the worker
%% sizes it with against the client's SETTINGS_MAX_HEADER_LIST_SIZE, so the
%% two agree (`roadrunner_http2_stream_worker:field_section/3`).
-spec response_fields(#loop{}, roadrunner_http:status(), roadrunner_http:headers()) ->
    roadrunner_http:headers().
response_fields(#loop{alt_svc = AltSvc}, Status, Headers) ->
    roadrunner_http2_stream_worker:field_section(Status, Headers, AltSvc).

%% Encode + write a HEADERS frame (always fits without flow control;
%% the wire just takes it).
encode_and_send_headers(
    #loop{hpack_enc = Enc} = State, StreamId, Status, Headers, EndStream
) ->
    %% Handler-supplied header names MUST already be lowercase per RFC 9113
    %% §8.1.2 (see `roadrunner_handler:response/0`), and the worker already
    %% answered 500 for any CR/LF/NUL (`roadrunner_stream_worker`), so a
    %% handler bug cannot crash this process, which every stream shares.
    {HpackBlock, Enc1} = roadrunner_http2_hpack:encode(
        response_fields(State, Status, Headers), Enc
    ),
    %% `frame:encode` accepts iodata for the header block — skip
    %% the upfront flatten; ssl:send walks the iolist anyway.
    Flags =
        if
            EndStream -> 16#04 bor 16#01;
            true -> 16#04
        end,
    Frame = roadrunner_http2_frame:encode({headers, StreamId, Flags, undefined, HpackBlock}),
    _ = send(State, Frame),
    case EndStream of
        true ->
            #loop{streams = #{StreamId := Stream} = Streams, live_streams = Live0} = State,
            {Closed, Live} = close_send(Stream, Live0),
            State#loop{
                hpack_enc = Enc1,
                streams = Streams#{StreamId := Closed},
                live_streams = Live,
                ping_clock = undefined
            };
        false ->
            State#loop{hpack_enc = Enc1, ping_clock = undefined}
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
    %% Names already lowercase per `roadrunner_handler:response/0` contract,
    %% CR/LF/NUL already answered with 500 by the worker.
    {HpackBlock, Enc1} = roadrunner_http2_hpack:encode(
        response_fields(State, Status, Headers), Enc
    ),
    HFrame = roadrunner_http2_frame:encode(
        {headers, StreamId, 16#04, undefined, HpackBlock}
    ),
    DFrame = roadrunner_http2_frame:encode({data, StreamId, 16#01, Body}),
    _ = send(State, [HFrame, DFrame]),
    %% The encoder, both send windows and the closed send side land in one
    %% state update (and one stream update): this runs once per buffered
    %% response, and each `#loop{}` copy is ~50 words.
    #loop{conn_send_window = ConnW, live_streams = Live0} = State,
    #stream{send_window = SW} = Stream,
    {Closed, Live} = close_send(Stream, Live0, SW - BodyLen),
    State#loop{
        hpack_enc = Enc1,
        conn_send_window = ConnW - BodyLen,
        streams = Streams#{StreamId := Closed},
        live_streams = Live,
        ping_clock = undefined
    }.

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
close_stream_send_side(#loop{streams = Streams, live_streams = Live0} = State, StreamId) ->
    #{StreamId := Stream} = Streams,
    {Closed, Live} = close_send(Stream, Live0),
    %% The frame that ended the stream (trailers, or an empty DATA) went
    %% out: the client's next PING is free (`ping_strike/1`).
    State#loop{streams = Streams#{StreamId := Closed}, live_streams = Live, ping_clock = undefined}.

%% A stream entry with its send side closed, and the live-stream count
%% after it: a stream the peer already ended is closed both ways and
%% stops counting. `close_send/3` also sets the stream's send window, so
%% a response that spends it pays one stream update, not two.
-spec close_send(#stream{}, non_neg_integer()) -> {#stream{}, non_neg_integer()}.
close_send(#stream{end_stream_seen = true, counted = true} = Stream, Live) ->
    {Stream#stream{state = closed, counted = false}, Live - 1};
close_send(Stream, Live) ->
    {Stream#stream{state = closed}, Live}.

-spec close_send(#stream{}, non_neg_integer(), integer()) -> {#stream{}, non_neg_integer()}.
close_send(#stream{end_stream_seen = true, counted = true} = Stream, Live, SendWindow) ->
    {Stream#stream{state = closed, counted = false, send_window = SendWindow}, Live - 1};
close_send(Stream, Live, SendWindow) ->
    {Stream#stream{state = closed, send_window = SendWindow}, Live}.

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

window_budget(#loop{conn_send_window = ConnW}, #stream{send_window = StreamW}) ->
    max(0, min(ConnW, StreamW)).

%% DATA went out: spend the windows, and make the client's next PING free
%% (`ping_strike/1`), as HEADERS do.
consume_send_window(
    #loop{conn_send_window = ConnW, streams = Streams} = State, StreamId, Stream, N
) ->
    #stream{send_window = SW} = Stream,
    Stream1 = Stream#stream{send_window = SW - N},
    State#loop{
        conn_send_window = ConnW - N,
        streams = Streams#{StreamId := Stream1},
        ping_clock = undefined
    }.

enqueue_pending(#stream{pending_sends = Pending} = Stream, Entry) ->
    Stream#stream{pending_sends = queue:in(Entry, Pending)}.

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
    #{StreamId := #stream{pending_sends = Pending} = Stream} = Streams,
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
        #{StreamId := #stream{worker_ref = undefined, pending_sends = Pending}} ->
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
drain_pending(State, StreamId, #stream{pending_sends = Pending} = Stream) ->
    case queue:out(Pending) of
        {empty, _} ->
            State;
        {{value, Entry}, Rest} ->
            {data, Ref, From, Bin, EndStream} = Entry,
            Stream1 = Stream#stream{pending_sends = Rest},
            State1 = update_stream(State, StreamId, Stream1),
            State2 = try_send_data(
                State1, Stream1, StreamId, From, Ref, Bin, iolist_size(Bin), EndStream
            ),
            #{StreamId := #stream{pending_sends = Pending2} = Stream2} = State2#loop.streams,
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
        #{StreamId := #stream{counted = true} = Stream} ->
            State#loop{
                streams = Streams#{StreamId := Stream#stream{counted = false}},
                live_streams = Live - 1
            };
        #{} ->
            State
    end.

%% A stream the server gives up on, at a deadline its worker armed
%% (`roadrunner_send_writer:cancel_after/2`): reset it, which tells the
%% worker. The frame depends on how far the exchange got (RFC 9113 §5.1,
%% §8.1): CANCEL while our response is unfinished; NO_ERROR once it is
%% complete and only the client's body is left, so the client keeps the
%% response; nothing once both sides ended, as no frame may go on a closed
%% stream, so it is not remembered as reset either. Stream ids are never
%% reused, so a stream already gone makes this a no-op.
-spec cancel_stream(#loop{}, stream_id()) -> #loop{}.
cancel_stream(#loop{streams = Streams} = State, StreamId) ->
    case Streams of
        #{StreamId := #stream{refused = Refused}} when Refused =/= undefined ->
            %% Already reset by us, its header block still arriving.
            State;
        #{StreamId := #stream{state = closed, end_stream_seen = true}} ->
            drop_reset_stream(State, StreamId);
        #{StreamId := #stream{state = closed}} ->
            _ = send_rst_stream(State, StreamId, no_error),
            reset_stream(State, StreamId);
        #{StreamId := _} ->
            _ = send_rst_stream(State, StreamId, cancel),
            reset_stream(State, StreamId);
        #{} ->
            State
    end.

%% Reset a stream we have alive: the peer sent RST_STREAM, or we sent
%% one for a stream-level flow-control error. Tell the worker (if any)
%% to bail, then drop our stream entry. Pending sends get reset
%% notifications so workers waiting on `h2_send_ack` unwind, as does a
%% worker waiting on a manual-mode body read. A worker still computing
%% learns of it at its next write or read; until it exits
%% (`handle_worker_down/4`) it keeps its in-flight slot and counts as a
%% stream toward `max_concurrent_streams` (`reset_workers`), so work a
%% client abandons still counts against both limits while it runs.
reset_stream(State, StreamId) ->
    drop_reset_stream(remember_reset(State, StreamId), StreamId).

%% `reset_stream/2` for the peer's own RST_STREAM: nothing it sent before
%% is in flight, so the stream is not remembered.
-spec drop_reset_stream(#loop{}, stream_id()) -> #loop{}.
drop_reset_stream(#loop{streams = Streams0} = State0, StreamId) ->
    #{StreamId := #stream{counted = Counted}} = Streams0,
    #loop{streams = Streams} = State = uncount_stream(State0, StreamId),
    #{
        StreamId := #stream{
            pending_sends = Pending,
            worker_pid = WorkerPid,
            worker_ref = WorkerRef,
            reader = Reader
        }
    } = Streams,
    notify_pending_reset(StreamId, Pending),
    ok = roadrunner_conn:send_body_error(Reader, StreamId, closed),
    Reset =
        case WorkerRef of
            %% RST landed before END_STREAM dispatched a worker.
            undefined ->
                State#loop.reset_workers;
            MonRef ->
                WorkerPid ! {h2_stream_reset, StreamId},
                hold_reset_slot(State#loop.reset_workers, MonRef, Counted)
        end,
    Streams1 = forget_stream(State, StreamId, Streams),
    withdraw_parked(
        State#loop{
            streams = Streams1,
            reset_workers = Reset,
            idle_deadline = idle_deadline(Streams1, State#loop.workers, State)
        },
        StreamId
    ).

%% A worker whose stream is reset while it counts toward
%% `max_concurrent_streams` keeps counting until it ends. One whose stream
%% had already ended both ways (its response complete) was not counted, and
%% is not now.
-spec hold_reset_slot(#{reference() => []}, reference(), boolean()) -> #{reference() => []}.
hold_reset_slot(Reset, MonRef, true) -> Reset#{MonRef => []};
hold_reset_slot(Reset, _MonRef, false) -> Reset.

%% Called by `handle_worker_down/4` when a worker dies abnormally.
%% Send RST_STREAM(error_code) to the peer and drop our state.
abort_stream(State0, StreamId, ErrorCode) ->
    #loop{streams = Streams} = State = uncount_stream(State0, StreamId),
    #{StreamId := #stream{pending_sends = Pending}} = Streams,
    notify_pending_reset(StreamId, Pending),
    _ = send_rst_stream(State, StreamId, ErrorCode),
    Streams1 = forget_stream(State, StreamId, Streams),
    withdraw_parked(
        remember_reset(
            State#loop{
                streams = Streams1,
                idle_deadline = idle_deadline(Streams1, State#loop.workers, State)
            },
            StreamId
        ),
        StreamId
    ).

%% Remember a stream this conn reset, or saw reset, so frames on it that
%% were in flight are ignored (RFC 9113 §5.1) instead of answered as on a
%% stream that never existed. The last `?RESET_MEMORY` are kept, which
%% §5.1 allows ("MAY choose to limit the period"): a peer still sending
%% on an older one is answered as before.
-spec remember_reset(#loop{}, stream_id()) -> #loop{}.
remember_reset(#loop{reset_ids = {_, Ids}} = State, StreamId) when is_map_key(StreamId, Ids) ->
    State;
remember_reset(#loop{reset_ids = {Queue, Ids}} = State, StreamId) ->
    Queue1 = queue:in(StreamId, Queue),
    Ids1 = Ids#{StreamId => []},
    case map_size(Ids1) > ?RESET_MEMORY of
        true ->
            {{value, Oldest}, Queue2} = queue:out(Queue1),
            State#loop{reset_ids = {Queue2, maps:remove(Oldest, Ids1)}};
        false ->
            State#loop{reset_ids = {Queue1, Ids1}}
    end.

%% Drop a stream that needs no RST_STREAM: its response is complete
%% (`finish_stream/2`, `retire_drained/2`), or the caller already sent
%% one. Just drop state.
remove_stream(#loop{workers = Workers} = State, StreamId) ->
    remove_stream(State, StreamId, Workers).

%% Drop a stream we just reset, remembering it (`remember_reset/2`).
-spec remove_reset_stream(#loop{}, stream_id()) -> #loop{}.
remove_reset_stream(State, StreamId) ->
    remove_stream(remember_reset(State, StreamId), StreamId).

%% Drop a stream and store `Workers` as the worker map in the same update.
-spec remove_stream(#loop{}, stream_id(), #{reference() => stream_id()}) -> #loop{}.
remove_stream(State0, StreamId, Workers) ->
    #loop{streams = Streams} = State = withdraw_parked(uncount_stream(State0, StreamId), StreamId),
    Streams1 = forget_stream(State, StreamId, Streams),
    State#loop{
        streams = Streams1,
        workers = Workers,
        idle_deadline = idle_deadline(Streams1, Workers, State)
    }.

%% Drop a stream's entry, unless its header block (trailers) is still
%% arriving in CONTINUATION frames: then the entry stays, as a closed
%% `ignore` refusal with no worker (a write to it finds it not open,
%% `stream_open/2`), until the block is complete, so the block is
%% still decoded (RFC 9113 §4.3) and its CONTINUATION frames land on a
%% stream we hold instead of failing the connection. Its end drops it
%% (`reset_refused/4`).
-spec forget_stream(#loop{}, stream_id(), #{stream_id() => #stream{}}) ->
    #{stream_id() => #stream{}}.
forget_stream(#loop{awaiting_continuation = StreamId}, StreamId, Streams) ->
    #{StreamId := Stream} = Streams,
    Streams#{
        StreamId := Stream#stream{
            state = closed,
            refused = ignore,
            manual = false,
            reader = undefined,
            worker_pid = undefined,
            worker_ref = undefined,
            pending_sends = queue:new()
        }
    };
forget_stream(_State, StreamId, Streams) ->
    maps:remove(StreamId, Streams).

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
            remove_reset_stream(State1, StreamId);
        _ ->
            State
    end.

%% `withdraw_parked/2` keeps `awaiting_slot` and `streams` in step, so a
%% grant that still has its parked request always has its stream too.
-spec spawn_parked(#loop{}, stream_id(), roadrunner_req:request()) -> #loop{}.
spawn_parked(#loop{streams = Streams} = State, StreamId, Req) ->
    #{StreamId := Stream} = Streams,
    {WorkerPid, MonRef} = start_worker(State, StreamId, Req),
    State#loop{
        streams = Streams#{StreamId := Stream#stream{worker_pid = WorkerPid, worker_ref = MonRef}},
        workers = (State#loop.workers)#{WorkerPid => StreamId}
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
-spec is_trailer_block(#stream{}, non_neg_integer()) -> boolean().
is_trailer_block(#stream{end_stream_seen = true}, _Flags) ->
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

%% RFC 9113 §6.5.2: SETTINGS_MAX_HEADER_LIST_SIZE (id 6) is the most
%% header bytes the peer will take in one section. It is advisory
%% (§10.5.1), but a peer may treat a larger one as malformed, so we keep
%% the last value it sent (§6.5.3) for the workers spawned from now on.
-spec apply_peer_max_header_list_size(
    [{non_neg_integer(), non_neg_integer()}], #loop{}
) -> #loop{}.
apply_peer_max_header_list_size(Params, #loop{peer_max_header_list_size = Current} = State) ->
    State#loop{peer_max_header_list_size = last_setting(Params, 6, Current)}.

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
                Id => Stream#stream{send_window = check_window(SW + Delta)}
             || Id := #stream{send_window = SW} = Stream <- Streams
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
throttle_stream(#loop{proto_opts = #proto_opts{throttled_counter = Counter}}, ListenerName) ->
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
            {refused, retry_later(State, StreamId, 429, RetryAfter)}
    end.

%% A bodyless `429` (over the per-peer rate) or `503` (shed at the
%% in-flight ceiling) with `Retry-After`, then `RST_STREAM(NO_ERROR)`: the
%% response is complete, so any request body still on its way is not
%% wanted (RFC 9113 §8.1).
-spec retry_later(#loop{}, stream_id(), 429 | 503, pos_integer()) -> #loop{}.
retry_later(State, StreamId, Status, RetryAfter) ->
    State1 = encode_and_send_response_atomic(
        State, StreamId, Status, [{~"retry-after", integer_to_binary(RetryAfter)}], ~"", 0
    ),
    _ = send_rst_stream(State1, StreamId, no_error),
    State1.

%% A connection error (RFC 9113 §5.4.1): tell the peer with a GOAWAY
%% carrying `ErrorCode`, then tear down with it as the close reason.
-spec goaway_exit(#loop{}, roadrunner_http2_frame:error_code()) -> no_return().
goaway_exit(State, ErrorCode) ->
    _ = send_goaway(State, ErrorCode),
    exit_clean(State, {protocol_error, ErrorCode}).

-spec exit_clean(#loop{}, roadrunner_event_handler:close_reason()) -> no_return().
exit_clean(#loop{socket = Socket, proto_opts = ProtoOpts, conn_span = ConnSpan} = State, Reason) ->
    ok = hand_off_slots(State),
    ok = roadrunner_event:listener_conn_close(ConnSpan, 0, Reason),
    Close = roadrunner_conn:close_opts(ProtoOpts),
    ok = roadrunner_conn:unregister_for_drain(Close),
    ok = roadrunner_conn:release_slot(Close),
    ok = roadrunner_transport:close(Socket),
    exit(normal).

%% The in-flight slots the conn still holds as it exits, one per worker not
%% yet seen ending (`workers`). A worker still running keeps its slot after
%% the conn is gone: every one is handed to the listener's slot keeper,
%% which releases it when the worker ends, or at once for one already gone
%% (`roadrunner_conn:hand_off_request_slots/5`). Releasing them here instead
%% would let a client that drops its connection and opens another run
%% handlers past `max_concurrent_requests`. A conn that crashes or is killed
%% never gets here: its workers' slots stay counted, erring on the side of
%% the ceiling, until the listener restarts.
-spec hand_off_slots(#loop{}) -> ok.
hand_off_slots(#loop{proto_opts = #proto_opts{slot_keeper = undefined}}) ->
    ok;
hand_off_slots(#loop{workers = Workers, parked = false}) when map_size(Workers) =:= 0 ->
    ok;
hand_off_slots(#loop{
    proto_opts = #proto_opts{slot_keeper = Keeper},
    workers = Workers,
    max_concurrent_requests = Max,
    inflight_counter = Counter,
    overload = Overload
}) ->
    roadrunner_conn:hand_off_request_slots(Keeper, maps:keys(Workers), Max, Counter, Overload).
