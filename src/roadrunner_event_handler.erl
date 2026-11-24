-module(roadrunner_event_handler).
-moduledoc """
Behaviour for an event handler: the module roadrunner hands its
request, connection, and WebSocket events to.

Roadrunner has no telemetry dependency. Every event, gRPC calls'
(`roadrunner_grpc`) among them, goes to one
`handle_event/2` callback on the configured handler, which decides
what to do with it: forward it to the `telemetry` library, record
Prometheus metrics, open OpenTelemetry spans, or drop it. The default
handler, `roadrunner_event_noop`, drops everything.

Pick a handler with the `event_handler` application env, read once
when the `roadrunner` application starts:

```erlang
%% sys.config
[{roadrunner, [{event_handler, my_handler}]}].
```

The application refuses to start if the module does not export
`handle_event/2`.

## Raw arguments

Each event passes the values roadrunner already holds, rather than
prebuilt measurement and metadata maps: a lone value as is
(`request_start` gets the request), several as a tuple. A handler builds
only what it uses, and the default handler builds nothing, so an
unobserved event costs one `persistent_term` read and one call.

Time is not measured for the handler: read `erlang:monotonic_time/0`
in a start event and keep it in the span to compute a duration later.

## Spans

Four events open a span: `request_start`, `listener_accept`,
`ws_upgrade`, and `grpc_call_start`. Whatever `handle_event/2` returns
for them is opaque to roadrunner and is handed back as the first
element of the events that follow:

- `request_start` -> `request_stop` or `request_exception`, in the
  same process
- `listener_accept` -> `listener_conn_close`, in the same process
- `ws_upgrade` -> `ws_frame_in`, `ws_frame_out`, and
  `ws_frame_rejected`, in the WebSocket session process
- `grpc_call_start` -> `grpc_call_stop` or `grpc_call_exception`, in
  the process running the call, inside the request's own span

The return value of every other event is ignored.

Keep a span small: copy out the fields you need rather than holding
the whole request. The request span lives as long as the request, and
for a WebSocket upgrade the connection process hibernates holding it
for the whole session, so a span that keeps the request keeps its
headers and body alive too.

## How a handler runs

`handle_event/2` runs synchronously in the process that emits the
event: a connection, a stream worker, a WebSocket session, or an
acceptor. A slow handler slows the traffic it observes; hand heavy
work to another process.

A handler that raises does not take the connection down. Roadrunner
logs the crash once and replaces the handler with
`roadrunner_event_noop` for the rest of the node's life, so a broken
handler cannot fail again on every request. Fix it and restart the
`roadrunner` application to put it back.

There is one handler per node, set when the application starts.
Changing `event_handler` afterwards has no effect, and a listener run
without starting the `roadrunner` application uses the default. To
tell listeners apart, match on the listener name the events carry.

## Events

- `request_start`, `Req`: a request's headers are parsed and its
  `request_id` assigned, before the middleware and handler pipeline
  runs. Returns the request span.
- `request_stop`, `{Span, Status, Kind}`: the handler's response was
  written to the wire, or queued for the connection to write. For
  `stream`, `loop`, and `websocket` responses, after the initial
  dispatch returns. `Status` is `101` for a WebSocket upgrade. `Kind`
  is `buffered | stream | loop | sendfile | websocket`; a `{send, ...}`
  response reports the kind it sent. It also fires for a `{send, ...}`
  fun that stopped on purpose (`{shutdown, _}`), with what it sent.
- `request_exception`, `{Span, Class, Reason, Stacktrace}`: the
  pipeline raised. `Class` is `error | exit | throw`, and `Stacktrace`
  is where it raised, as caught by `catch Class:Reason:Stacktrace`.
  The connection then answers `500`, unless a `{send, ...}` fun had
  already sent its final response; then the connection only closes (or,
  on HTTP/2 and HTTP/3, the stream ends or is reset).
- `request_rejected`, `{ListenerName, Peer, Reason}`: a request was
  dropped by the parser or a limit before any handler ran (malformed
  request line, header injection, header count or size limits,
  oversized `Content-Length`, and similar). `Reason` is the parser's
  error.
- `request_throttled`, `{ListenerName, Reason}`: a request was
  refused at a listener limit before any handler ran. `Reason` is
  `max_concurrent_requests` (a request over the in-flight ceiling: an
  HTTP/2 or HTTP/3 stream reset as retry-safe, or answered `503` on any
  protocol when `overload_mode` is `shed`), `route_max_concurrent_requests`
  (a request over its route's own `max_concurrent_requests`, answered
  `503` on any protocol) or `rate_limit` (a peer over its `rate_limit`,
  answered `429`).
- `response_send_failed`, `{Phase, Reason}`: a response write failed
  after the status line was already going out, so the connection is
  about to close. `Phase` is `buffered_response`, `interim_response`
  (a `roadrunner_send:inform/3`), `stream_response_head`, `loop_response_head`,
  `sendfile_response_head`, `sendfile_body`, or
  `websocket_upgrade_response`. The connection's `logger` process
  metadata (`request_id`, `peer`, `method`, `path`) is set in the
  calling process.
- `listener_accept`, `{ListenerName, Peer}`: a connection's peer is
  known and it is about to be served. Returns the connection span.
- `listener_conn_close`, `{Span, RequestsServed, Reason}`: the
  connection process is about to exit. `RequestsServed` counts the
  requests parsed on it (`0` on HTTP/2 and HTTP/3). `Reason` says why
  it ended, see `t:close_reason/0`.
- `listener_conn_rejected`, `{ListenerName, Reason}`: a freshly
  accepted connection was dropped at the `max_clients` cap. `Reason`
  is `max_clients`. There is no peer: the reject path is the floodable
  one, so it skips the `peername` lookup.
- `listener_accept_error`, `{ListenerName, Reason}`: an acceptor's
  `accept/1` failed with anything other than the listen socket closing
  (`econnaborted`, or `emfile`/`enfile`/`system_limit` descriptor
  exhaustion, usually `max_clients` above `ulimit -n`), a TLS
  handshake failed (`{handshake, HsReason}`), or a `proxy_protocol`
  listener could not read the PROXY header (`{proxy_protocol, PReason}`).
- `slots_reconciled`, `{ListenerName, Released, CounterWas,
  LiveConnsBounded}`: the slot reaper released `Released` orphan slots
  that a killed connection left behind. `CounterWas` is the slot count
  before, `LiveConnsBounded` the live connections found, counted up to
  `CounterWas`.
- `drain_acknowledged`, `{Req, Deadline}`: a long-running handler
  (`loop` or WebSocket) called `roadrunner:acknowledge_drain/1,2` to
  say it is winding down for a drain. `Deadline` is the drain deadline
  in milliseconds, or `undefined` from `acknowledge_drain/1`.
- `ws_upgrade`, `{ListenerName, Peer, RequestId, Module}`: a WebSocket
  session validated its handler `Module` and the `101` is about to be
  written. Returns the WebSocket span.
- `ws_frame_in`, `{Span, Opcode, PayloadSize}`: a frame was parsed
  from the client, including the control frames the session handles
  itself. `Opcode` is `text | binary | continuation | close | ping |
  pong`.
- `ws_frame_out`, `{Span, Opcode, PayloadSize}`: a frame was queued
  for the client: handler replies, automatic pongs, and the closing
  frame. A batched reply gives one event per frame.
- `ws_frame_rejected`, `{Span, Reason, Size}`: the session is closing
  with `1009` because an inbound frame or message passed a size cap.
  `Reason` is `max_frame_size | max_message_size`, `Size` the
  offending byte count.
- `grpc_call_start`, `{Req, Service, Method, Kind}`: a gRPC call to
  `Service` (its full name, `package.Service`) and `Method` starts,
  ahead of its checks and its method. `Kind` is `unary`,
  `server_stream`, `client_stream` or `bidi_stream`, or `undefined` for
  a method the service does not have (answered `UNIMPLEMENTED`). Returns
  the call span. A request refused before a call starts (`405`, `415`,
  `505`, the router's `404`) has only the request's events.
- `grpc_call_stop`, `{Span, Status, Message, Reason, Messages,
  Encodings}`: the call ended. `Status` is a `t:roadrunner_grpc:status/0`
  and `Message` its `grpc-message` (`<<>>` for none). `Reason` says
  how the call ended, see `t:grpc_stop_reason/0`. `Messages` is `{Received,
  ReceivedBytes, Sent, SentBytes}`: the request messages read and the
  response messages sent, and their bytes as they crossed the wire
  (compressed when compressed, without gRPC's 5-byte prefix).
  `Encodings` is `{RecvEncoding, SendEncoding}`: the client's
  `grpc-encoding` (`identity` without one, its value as a binary for
  one roadrunner does not read), and the one the response messages went
  out with (`identity` when no response started).
- `grpc_call_exception`, `{Span, Class, Reason, Stacktrace, Messages,
  Encodings}`: the method raised (or returned something it may not),
  and the call is about to end with `INTERNAL`; also for any other
  raise that ends the call, such as trailers too large for the client,
  which reset the stream. Fires in place of `grpc_call_stop`.
  `Messages` and `Encodings` are as for `grpc_call_stop`.

Every call that starts ends with exactly one `grpc_call_stop` or
`grpc_call_exception`, however it ends, unless its process is ended by
an exit signal it does not trap (`exit(Pid, kill)`, a `max_heap_size`
kill, a linked process crashing) or its method never returns.

## Stability

An event's name and the shape of its arguments are its contract: a
handler matches the whole tuple, so a new argument would silently stop
an existing clause from matching. New data therefore ships as a new
event, never as an extra element on an existing one.

These events are **stable**: their name and arguments will not change
without a major version bump.

- `request_start` and `request_stop`
- `ws_upgrade` and `ws_frame_out`

Every other event is **unstable**: it may change in any minor release,
called out in the release notes. A handler that depends on one should
pin a roadrunner version.

Roadrunner may add events in any release, so end `handle_event/2` with
a catch-all clause.

## Example

A handler that logs slow requests and ignores the rest:

```erlang
-module(slow_requests).
-behaviour(roadrunner_event_handler).
-export([handle_event/2]).

handle_event(request_start, Req) ->
    {erlang:monotonic_time(), roadrunner_req:path(Req)};
handle_event(request_stop, {{Start, Path}, Status, _Kind}) ->
    Ms = erlang:convert_time_unit(erlang:monotonic_time() - Start, native, millisecond),
    case Ms > 500 of
        true -> logger:warning("slow ~s -> ~p (~p ms)", [Path, Status, Ms]);
        false -> ok
    end;
handle_event(_Event, _Args) ->
    ok.
```
""".

-export_type([event/0, span/0, peer/0, response_kind/0, close_reason/0]).
-export_type([grpc_stop_reason/0, grpc_messages/0, grpc_encodings/0]).

-doc "The name of an event handed to `handle_event/2`.".
-type event() ::
    request_start
    | request_stop
    | request_exception
    | request_rejected
    | request_throttled
    | response_send_failed
    | listener_accept
    | listener_conn_close
    | listener_conn_rejected
    | listener_accept_error
    | slots_reconciled
    | drain_acknowledged
    | ws_upgrade
    | ws_frame_in
    | ws_frame_out
    | ws_frame_rejected
    | grpc_call_start
    | grpc_call_stop
    | grpc_call_exception.

-doc """
What a handler returns from `request_start`, `listener_accept`,
`ws_upgrade`, or `grpc_call_start`; handed back unchanged on the
events that follow.
""".
-type span() :: term().

-doc "A connection's peer address, `undefined` when it could not be read.".
-type peer() :: {inet:ip_address(), inet:port_number()} | undefined.

-doc "The shape of the response a request was answered with.".
-type response_kind() :: buffered | stream | loop | sendfile | websocket.

-doc """
Why a connection ended, as carried by `listener_conn_close`.

- `normal`: roadrunner closed it after a response: `Connection: close`,
  `max_keep_alive_requests` reached, a `stream`, `loop`, `sendfile`
  body or WebSocket session that owns the connection finished, or a
  `404`, `405` or `500` that closes it
- `peer_closed`: the client closed it (on HTTP/2, also a client
  `GOAWAY`)
- `request_timeout`: no complete request within `request_timeout`
  (on HTTP/2, the client preface and `SETTINGS` did not arrive in time)
- `keep_alive_timeout`: idle between requests past `keep_alive_timeout`
  (on HTTP/2 and HTTP/3, the connection's idle timeout)
- `liveness_timeout`: an HTTP/2 connection with a handler still at work
  went quiet, and the client did not answer the PING sent to check it is
  still there
- `too_many_pings`: an HTTP/2 client pinged more often than the
  listener's `ping_policy` allows, and the connection closed with
  `GOAWAY(ENHANCE_YOUR_CALM)`
- `connection_age`: an HTTP/2 connection reached the listener's
  `connection_age` and closed gracefully once its requests were done
- `connection_age_grace`: as `connection_age`, but the grace ran out
  first, and the requests still open were reset
- `slow_client`: the client sent slower than `min_bytes_per_second`
- `drained`: closed by `roadrunner_listener:drain/2`
- `rejected`: an HTTP/1.1 request was refused before its handler ran
  (malformed, over a size limit, or over its `rate_limit`) and the
  connection closed with the error response
- `{protocol_error, Code}`: an HTTP/2 or HTTP/3 connection error,
  closed with `Code` (the `GOAWAY` error atom on HTTP/2, the HTTP/3
  error code integer)
- `{transport, Reason}`: the socket failed, with the transport's own
  reason (a TLS alert, a reset, a QUIC close)
""".
-type close_reason() ::
    normal
    | peer_closed
    | request_timeout
    | keep_alive_timeout
    | liveness_timeout
    | too_many_pings
    | connection_age
    | connection_age_grace
    | slow_client
    | drained
    | rejected
    | {protocol_error, atom() | non_neg_integer()}
    | {transport, term()}.

-doc """
How a gRPC call ended, as carried by `grpc_call_stop`, with the
`Status` each comes with:

- `normal`: the call ended `OK`
- `error`: it ended with another status, the method's
  (`{error, Status, Message, Stream}`) or one roadrunner answered for it
  (an unknown method, a request message too large or malformed, a read
  still waiting at the deadline, and so on), a call its method ended
  `unavailable` on a drain among them
- `cancelled`: the client cancelled the call (reset its stream) or its
  connection went away before it could read the call's status: a write
  or read failed with it, or it was seen before a Trailers-Only status,
  which goes out without waiting (including when `roadrunner_grpc:info/2`
  or `cancelled/2` told the method); `Status` is `cancelled`
- `deadline`: as `cancelled`, but from 50 ms before the call's
  `grpc-timeout` ran out on: roadrunner cancelled it a second after the
  deadline, or the client did at its own deadline; `Status` is
  `deadline_exceeded`. Roadrunner counts the deadline from when the
  request's headers arrived, so a client reset at its own deadline,
  which comes a little earlier, is `deadline`. The time compared is
  when the call learned the stream was gone: when
  `roadrunner_grpc:info/2` or `cancelled/2` told the method, or else
  when a write or read failed or the status was about to go out, which
  can be well after the reset came in (a method that keeps working
  without reading or writing)
- `stopped`: no gRPC status went out: the method stopped the call on
  purpose (`exit({shutdown, _})`), or its response headers were too
  large for the client and the request was answered `500`; `Status` is
  what a gRPC client reads then: `unknown` before a response started
  (an HTTP `500`), `internal` after (a stream ended without trailers)
""".
-type grpc_stop_reason() :: normal | error | cancelled | deadline | stopped.

-doc """
A gRPC call's messages: `{Received, ReceivedBytes, Sent, SentBytes}`,
the request messages read and the response messages sent, and their
bytes as they crossed the wire.
""".
-type grpc_messages() ::
    {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}.

-doc """
A gRPC call's encodings: `{RecvEncoding, SendEncoding}`, the client's
`grpc-encoding` (its value, for one roadrunner does not read) and the
response messages'.
""".
-type grpc_encodings() ::
    {roadrunner_grpc:encoding() | binary(), roadrunner_grpc:encoding()}.

-doc """
Handle one event. The return value is the span for `request_start`,
`listener_accept`, `ws_upgrade`, and `grpc_call_start`, and is ignored for every other
event. See the module documentation for each event's arguments.
""".
-callback handle_event
    (request_start, roadrunner_req:request()) -> span();
    (request_stop, {span(), roadrunner_http:status(), response_kind()}) -> term();
    (
        request_exception,
        {span(), error | exit | throw, term(), erlang:stacktrace()}
    ) -> term();
    (request_rejected, {atom(), peer(), term()}) -> term();
    (
        request_throttled,
        {atom(), max_concurrent_requests | route_max_concurrent_requests | rate_limit}
    ) -> term();
    (response_send_failed, {atom(), term()}) -> term();
    (listener_accept, {atom(), peer()}) -> span();
    (listener_conn_close, {span(), non_neg_integer(), close_reason()}) -> term();
    (listener_conn_rejected, {atom(), max_clients}) -> term();
    (listener_accept_error, {atom(), term()}) -> term();
    (
        slots_reconciled,
        {atom(), pos_integer(), non_neg_integer(), non_neg_integer()}
    ) -> term();
    (drain_acknowledged, {roadrunner_req:request(), integer() | undefined}) -> term();
    (ws_upgrade, {atom(), peer(), binary() | undefined, module()}) -> span();
    (ws_frame_in, {span(), roadrunner_ws:opcode(), non_neg_integer()}) -> term();
    (ws_frame_out, {span(), roadrunner_ws:opcode(), non_neg_integer()}) -> term();
    (
        ws_frame_rejected,
        {span(), max_frame_size | max_message_size, non_neg_integer()}
    ) -> term();
    (
        grpc_call_start,
        {roadrunner_req:request(), binary(), binary(), roadrunner_grpc_service:kind() | undefined}
    ) -> span();
    (
        grpc_call_stop,
        {
            span(),
            roadrunner_grpc:status(),
            binary(),
            grpc_stop_reason(),
            grpc_messages(),
            grpc_encodings()
        }
    ) -> term();
    (
        grpc_call_exception,
        {
            span(),
            error | exit | throw,
            term(),
            erlang:stacktrace(),
            grpc_messages(),
            grpc_encodings()
        }
    ) -> term().
