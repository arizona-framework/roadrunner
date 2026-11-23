# Resource limits

Roadrunner bounds how much memory and CPU a single connection or peer
can pull in before any handler runs. The goal is that no client, by
sending oversized, malformed, or slow input, can grow a connection's
memory without bound or pin a worker. Every limit on this page is on by
default, except the opt-in per-peer rate guard (`rate_limit`, below).

This page is an operator reference. For the reporting policy, see
`SECURITY.md`. For the exact option types, see
`t:roadrunner_listener:opts/0`.

## HTTP request limits

| Limit | Default | Configurable | Over-limit behavior |
|---|---|---|---|
| Request line | 8 KB | yes | 414 URI Too Long, connection closed |
| Header line | 8 KB | yes | 431 Request Header Fields Too Large, connection closed |
| Header block (cumulative) | 10 KB | yes | 431 Request Header Fields Too Large, connection closed |
| Header count | 100 | yes | 431 Request Header Fields Too Large, connection closed |
| Body (`max_content_length`) | 10 MB | yes | 413 Payload Too Large |

The request line, header line, header block, and header count caps are
tuned under `{http1, #{...}}` in the `protocols` list, with the keys
`max_request_line`, `max_header_line`, `max_header_block`, and
`max_header_count`. A chunked body's trailer block obeys the same header
caps and is rejected the same way.

The `http1` `active` key sets how many socket reads a connection takes
before it asks the socket for more: `once` asks before every request.
Unset, it is `16` on TLS, where each ask is a call into the TLS
connection process, and `once` on plain TCP. A connection can hold up to
that many unread reads in its mailbox.

The body cap is enforced across all three protocols. For HTTP/1.1 it
covers both `Content-Length` and `Transfer-Encoding: chunked` requests:
the cap is checked as the body is read (a chunked body on its declared
size line), so an oversized body is rejected without buffering the whole
thing. The 413 goes out first and the connection then closes, reading and
dropping what the client still sends for up to the `http1` `linger_timeout`
(1 s by default) or until it closes, so the client reads the 413 rather than
losing it to a reset. HTTP/2 and HTTP/3 accumulate DATA frames against the same cap; an
over-cap body answers `413 Payload Too Large` and resets the stream
(`RST_STREAM(NO_ERROR)` on h2, `STOP_SENDING` on h3) so the client stops
sending.

A route can set its own cap with the `max_content_length` key of its map
form, larger or smaller than the listener's; it applies to the requests
that route answers, and requests no route answers keep the listener's.
`infinity` sets no cap on a route whose handler reads its body as it
arrives (`body_buffering => manual`), where the handler decides how much
it holds; with `auto`, where the listener reads the body whole first, the
route keeps the listener's cap. A manual read holds only what it asks
for: a chunk over 64 KB comes in parts as it arrives, whatever size it
declares, and a body the handler leaves unread is read and dropped 64 KB
at a time after the response, within the request's deadline, so an
uncapped body takes time but not memory.
HTTP/1.1 routes each request before reading its body, so the route's cap
governs the read, the `100 Continue` answer and the early 413. HTTP/2 and
HTTP/3 hold a body to the listener's cap and ask its route when the body
grows past it, so a larger route cap lets it continue. A smaller route
cap is checked once the request is routed, after its body is in; a
request that sends `Expect: 100-continue` gets the 413 from its headers
alone.

## WebSocket limits

A WebSocket message is the WS analog of a request body, so its caps
default to the same value as `max_content_length`. Both are enforced
before the payload reaches the handler, and crossing either closes the
connection with RFC 6455 code 1009 (message too big).

These are configured under the `ws` listener option as a nested map,
e.g. `ws => #{max_frame_size => N, max_message_size => N}`.

| Limit | Default | What it bounds |
|---|---|---|
| `ws.max_frame_size` | 10 MB | one frame's declared payload, checked on the frame header before the body is buffered |
| `ws.max_message_size` | 10 MB | a reassembled message: the running total across fragments, and the decompressed size when permessage-deflate is negotiated |
| `ws.active` | `once` on plain TCP, 16 on TLS | unread socket reads a session can hold in its mailbox |
| `ws.recv_buffer` | adaptive, `idle_recv_buffer` up to `recv_buffer`, on plain TCP | bytes one socket read can carry, and what each connection holds for it |
| `ws.compress` | `false` | whether a client's permessage-deflate offer is accepted; a compressed connection holds zlib state for its lifetime, about 290 KB with `true` and about 50 KB with `#{server_window_bits => 12, client_window_bits => 12, mem_level => 4}` |

Notes:

- unset, `ws.recv_buffer` adapts on plain TCP: a session reads with the
  listener's `idle_recv_buffer` (4 KB by default), grows the buffer
  for a frame whose header announces more (up to the listener's
  `recv_buffer`), keeps it while large and small messages mix, and goes
  back after 16 small messages in a row, so a large frame still arrives in
  one read. On TLS, whose records run up to 16 KB, or with a size set, the
  buffer is fixed
- `max_message_size` must be `>= max_frame_size`; a listener configured
  otherwise refuses to start
- a fragmented message is held in about as many bytes as it has
  received, so the most one connection holds for an unfinished message
  is close to `max_message_size`. Plan memory for connections ×
  `max_message_size` (10 MB × 1,000 connections is 10 GB), or lower the
  cap when messages are small: 1 MB or less suits most chat and
  live-update traffic
- a continuation frame that would take its message over
  `max_message_size` closes the connection on its header, before its
  payload is read
- each fragment is charged at least a small fixed overhead toward
  `max_message_size`, so a flood of empty or tiny continuation frames
  still reaches the cap
- permessage-deflate is inflated in bounded chunks against
  `max_message_size`, so a small high-ratio frame cannot expand into
  gigabytes before the cap fires

When a cap closes a connection, roadrunner emits the
`ws_frame_rejected` event (with the cap's `reason` and the offending
`size`) so oversize and flood attempts are visible to your event
handler.

## Form body limits

A form body parsed into terms costs more memory than it takes on the
wire: each urlencoded pair, multipart part, and part header becomes its
own term. The form parsers cap them. `roadrunner_req:read_form/1` uses
the defaults; `roadrunner_qs:parse/2`, `roadrunner_multipart:parse/3`,
and the streaming `roadrunner_multipart:read_part/2` take them as
options:

| Limit | Default | Over-limit behavior |
|---|---|---|
| `max_pairs` (`roadrunner_qs:parse/2`) | 1000 | `{error, too_many_pairs}` |
| `max_parts` (`roadrunner_multipart`) | 1000 | `{error, too_many_parts}` |
| `max_header_count` (`roadrunner_multipart`) | 100 per part | `{error, too_many_headers}` |
| `length` (`roadrunner_multipart:read_part/2`) | 64000 bytes per part's header block | `{error, headers_too_large}` |

`roadrunner_qs:parse/1`, which `roadrunner_req:parse_qs/1` uses, takes
every pair: a query string is already bounded by the request-line limit.
A handler that gets one of these errors answers as it sees fit, usually
with a 400 or 413.

## gRPC limits

`roadrunner_grpc` adds a per-message cap on top of the body cap. Both are
set in the map given to `roadrunner_grpc:routes/1`, for every service in
it. See the [gRPC guide](grpc.md).

| Limit | Default | What it bounds |
|---|---|---|
| `max_message_size` | 4 MB | one request message, both as it arrives and after it is decompressed; over it the call ends with `RESOURCE_EXHAUSTED` |
| `max_content_length` | `infinity` | all of a call's request messages together, set on each gRPC route; over it the call ends with `RESOURCE_EXHAUSTED`. With `body_buffering => auto` a route at `infinity` keeps the listener's cap, and a body over it is answered 413 |

A compressed message is inflated in bounded chunks against
`max_message_size`, so a small message cannot expand into unbounded
memory. gRPC has no limit on a whole call, so a client stream or bidi
stream may go on for as long as it lives: with `manual` buffering a call
holds one message at a time, which `max_message_size` bounds, and flow
control keeps the client to the pace the method reads at. Set
`max_content_length` on the routes to cap what a call may send in all.

## HTTP/2 framing limits

The framing layer enforces these. The ones with a `SETTINGS` counterpart
are advertised to the peer in the initial `SETTINGS` frame.

| Limit | Default | Configurable |
|---|---|---|
| `SETTINGS_MAX_FRAME_SIZE` | 16 KB | no (fixed) |
| `SETTINGS_MAX_CONCURRENT_STREAMS` | 100 | yes |
| HPACK decoder table | 4 KB | no (fixed) |
| Header block (HEADERS + CONTINUATION) | 16 KB | yes |
| Decoded header list (`SETTINGS_MAX_HEADER_LIST_SIZE`) | 32 KB | yes |
| Connection receive window (`conn_window`) | 2^31-1 (the largest allowed) | yes |
| Stream receive window (`stream_window`) | 16 MB | yes |
| Unread socket reads per connection (`active`) | 16 | yes |
| Client PINGs (`ping_policy`) | 1 s apart, 2 closer ones forgiven | yes (`false` disables) |
| Frames that serve no request (`control_frame_policy`) | 1000, then 1000 per 10 s, less 4 per HEADERS or DATA frame sent | yes (`false` disables) |
| Response waiting for the client's window (`send_stall_timeout`) | 60 s with nothing sent | yes (`infinity` disables) |
| Connection lifetime (`connection_age`) | none | opt-in |
| Linger after the closing GOAWAY (`linger_timeout`) | 1 s | yes (`0` disables) |

A frame whose declared length exceeds the negotiated max frame size is
rejected on its 9-byte header, before the body is buffered, with
`GOAWAY(FRAME_SIZE_ERROR)`. A connection closed with a GOAWAY then reads
and drops what the client still sends for up to `linger_timeout` or until
it closes, so the client reads the GOAWAY rather than losing it to a
reset. Streams over
the concurrency limit are refused with `REFUSED_STREAM`, which a client
may retry (RFC 9113 §8.7).

A stream the client resets is closed for the client, but its handler may
still be running: it learns of the reset at its next read or write, and
it is not stopped, so it can clean up. Until it ends it still counts
toward the concurrency limit, so a client that opens and resets streams
in a loop (the HTTP/2 rapid reset attack, CVE-2023-44487) runs no more
unfinished handlers at once on a connection than the limit allows. The
limit counts streams whose response is not complete: a handler that keeps
working after its response is complete no longer counts (RFC 9113
§5.1.2), and a reset does not make it count again; `max_concurrent_requests`
bounds those. When the handlers of reset streams fill the whole limit on
their own and the client keeps opening streams, it is refused as many
times as the limit, then the connection is closed with
`GOAWAY(ENHANCE_YOUR_CALM)`. The count starts over each time one of
those handlers ends, and a client that still has streams of its own open
is only refused, so a client that resets its requests now and then is
not closed for it.

A client may ping no more than `ping_policy` allows, the keepalive
enforcement gRPC servers apply: a PING less than `min_time` after the
client's last one is a strike (with no request open and
`permit_without_stream => false`, one less than two hours after it), and
the strike past `max_strikes` closes the connection with
`GOAWAY(ENHANCE_YOUR_CALM)` and the debug data `too_many_pings`. A PING
right after a response's HEADERS or DATA is never a strike, so a client
that pings as it reads is not closed for it. The default (1 s, 2
strikes) stops a PING flood (each PING costs the server an answer) and
no usual client meets it; gRPC's own servers enforce 5 minutes and no
PINGs without a call, which a listener for gRPC alone can match (see
[gRPC keepalive](grpc.md#keepalive)). The connection closes with the
reason `too_many_pings` in `listener_conn_close`.

Some frames make the server work without serving anything (RFC 9113
§10.5): SETTINGS (each one answered with an ACK), WINDOW_UPDATE,
PRIORITY, frames of an unknown type, DATA frames that carry nothing and
do not end their stream, RST_STREAM or DATA frames on a stream already
closed, a request reset while no handler runs for it, a request the
server refuses, and header blocks on a stream the server reset. DATA the
client sent on a stream before it saw the server reset it is not
counted, up to the receive window the stream had left, as that much may
have been on its way (each frame is charged at least 16 KB of it, so a
window sent a byte at a time is not free), nor is a WINDOW_UPDATE that
lets out DATA the server was holding back. `control_frame_policy`
bounds these frames, against the SETTINGS, empty frames
(CVE-2019-9518), WINDOW_UPDATE and PRIORITY (CVE-2019-9513) floods. Each
HEADERS or DATA frame the server sends takes 4 off the count. The first
`max` frames are free; past them a client may send `max` more per
`window` milliseconds, and one more within the window closes the
connection with `GOAWAY(ENHANCE_YOUR_CALM)` and the reason
`{protocol_error, enhance_your_calm}` in `listener_conn_close`. A
browser sends a handful of these as it connects (its SETTINGS, a
WINDOW_UPDATE, the ACK of the server's SETTINGS, maybe a few PRIORITY
frames), and a client reading a response sends a WINDOW_UPDATE or two
per DATA frame it reads, which the 4 that frame takes off covers, so the
default (1000, then 1000 per 10 s) is far above what clients send. A
flood with no response in between is closed at its 2001st frame, and a
client that buys the response a byte at a time to earn credit gains no
more than 4 frames per DATA frame. PINGs are left to `ping_policy`. An
empty CONTINUATION frame that does not end its header block closes the
connection at once (see the CONTINUATION flood below).

A response goes out as fast as the client's flow-control windows allow
(RFC 9113 §5.2), and what they hold back waits in the server: a buffered
body in full, a streamed one a chunk at a time, its handler waiting for
each chunk to go out before it sends the next. The body waits as one
binary, its byte size and no more, so a stream holds at most its
response body back and a connection at most `max_concurrent_streams`
of them. A client that never opens its windows (a
`SETTINGS_INITIAL_WINDOW_SIZE` of 0 and no WINDOW_UPDATE) would keep
them waiting for as long as it holds the connection, so a stream whose
response has waited `send_stall_timeout` milliseconds (60 s unless set)
is reset with `CANCEL`, and its body dropped. A stream waiting for its
own window counts from when nothing more was sent on it; one waiting
for the connection window counts from when no DATA at all went out on
the connection, so the streams queued behind one the client is reading
are not reset. Its handler, if it is still sending, stops as on a client
reset, and keeps its in-flight slot until it ends. Each DATA frame sent
starts the wait over, so a slow client that keeps reading is not reset,
nor is a stream with nothing to send, such as an event stream between
events. A minute with nothing read is far longer than a client that is
reading takes; a gRPC client that holds a server stream's window shut on
purpose while it is busy for longer needs a higher timeout, or
`infinity`.

A connection lives as long as it is used unless `connection_age` sets
how long it may: at that age (drawn within 10% of `max` for each
connection, so connections opened together do not close together) it
closes gracefully, as on a drain, and the requests open then may finish
within `grace` (`infinity` unless set), after which they are reset with
`CANCEL`. Behind a load balancer this moves long-lived clients onto
servers added since they connected. `listener_conn_close` carries the
reason `connection_age`, or `connection_age_grace` when the grace ran
out.

A request whose header block (HEADERS plus its CONTINUATION frames) is
over `max_header_block`, or whose decoded headers are over the
advertised `SETTINGS_MAX_HEADER_LIST_SIZE` (name + value + 32 per field,
RFC 9113 §6.5.2), is answered `431 Request Header Fields Too Large` and
its stream reset with `NO_ERROR`; the connection and its other streams
go on. The block is still decoded first, as every block updates the
connection's HPACK state (RFC 9113 §4.3). The list size defaults to twice
`max_header_block`, and the larger of the two is the most of one block
the server reads: a block that grows past it is the CONTINUATION flood,
and the connection is closed with `GOAWAY(ENHANCE_YOUR_CALM)`. A client
that keeps to the advertised list size and encodes its headers as usual
stays under it; Huffman coding can make some strings longer than they
are, so a block of those can pass it, which the advisory list size
(RFC 9113 §6.5.2) allows. The
concurrency and header caps are tuned under `{http2, #{...}}` in the
`protocols` list, with the keys `max_concurrent_streams`,
`max_header_block`, `max_header_list_size`, `ping_policy`,
`control_frame_policy`, `send_stall_timeout`, `connection_age` and
`linger_timeout`.

`active` sets how many socket reads a connection takes before it asks
the socket for more (`once` asks after every read). On TLS each ask is a
call into the TLS connection process, so a larger value saves CPU. A
connection can hold up to that many unread reads (each up to
`recv_buffer` bytes on plain TCP), so a smaller value bounds that memory
more tightly.

Response headers are held to the client's own limit: a client that sends
`SETTINGS_MAX_HEADER_LIST_SIZE` gets no header section over it (RFC 9113
§6.5.2), counted as name + value + 32 per field, `:status` and the auto
headers (`date`, `alt-svc`) included. A handler response whose headers
are over it is answered `500 Internal Server Error` instead, before
anything is sent, and the error is logged; the request's telemetry and
events report the `500`. Trailers over it come after the status is sent,
so they reset the stream with `INTERNAL_ERROR`, as does a limit too small
for even the 500 or for one of the server's other answers (`404`, `405`,
`413`). Each request is held to the limit known when its handler starts:
a lower limit in a later SETTINGS frame holds for the requests after it
(the setting is advisory, RFC 9113 §10.5.1). With no limit sent there is
none. The connection's own short answers (`413`, `431`, `429`, `503`,
the interim `100`) are not checked: their few fields are far below any
real limit. HTTP/3 does the same with `SETTINGS_MAX_FIELD_SECTION_SIZE`
(below).

## HTTP/3 framing limits

| Limit | Default | Configurable |
|---|---|---|
| Field section block (encoded HEADERS) | 16 KB | yes |
| Decoded field section (`SETTINGS_MAX_FIELD_SECTION_SIZE`) | 32 KB | yes |
| `initial_max_streams_bidi` | 100 | yes |
| QPACK dynamic table (`SETTINGS_QPACK_MAX_TABLE_CAPACITY`) | 4 KB | yes |
| QPACK blocked streams (`SETTINGS_QPACK_BLOCKED_STREAMS`) | 16 | yes |

The encoded request field section is capped before it reaches the
handler; an overrun answers `431 Request Header Fields Too Large`, as
does a decoded one over the advertised `SETTINGS_MAX_FIELD_SECTION_SIZE`
(twice `max_header_block` unless set with `max_field_section_size`).
Either refuses that request alone: a field section is decoded on its own
stream, so the connection's other requests go on. The
concurrent client-initiated bidirectional (request) stream count is
advertised to the peer in the QUIC transport parameters, the h3
counterpart to HTTP/2's `max_concurrent_streams`. Both are tuned under
`{http3, #{...}}` in the `protocols` list, with the keys
`max_header_block` and `max_streams_bidi`.

The stream count holds at once, not over the connection's life: each
request stream that closes gives its credit back with a `MAX_STREAMS`
frame (RFC 9000 §4.6), so a connection serves any number of requests,
never more than `max_streams_bidi` at a time. A request the client
cancels (`RESET_STREAM` or `STOP_SENDING`) is not closed until its
handler ends, as on HTTP/2, so cancelling requests in a loop (the HTTP/3
form of the rapid reset attack) runs no more handlers at once than the
limit. A client that opens a stream past its credit breaks the QUIC
limit and the connection is closed with `STREAM_LIMIT_ERROR`.

Response headers are held to the client's own limit: a client that sends
`SETTINGS_MAX_FIELD_SECTION_SIZE` (Chrome, quiche and ngtcp2 all do) gets
no header section over it (RFC 9114 §4.2.2), counted the same way (name
+ value + 32 per field, `:status` and `date` included). A handler
response whose headers are over it is answered `500 Internal Server
Error` instead, before anything is sent, and the error is logged.
Trailers over it come after the status is sent, so they reset the stream
with `H3_INTERNAL_ERROR`, as does a limit too small for even the 500. A
request served before the client's SETTINGS arrive has no limit (RFC
9114 §7.2.4.2).

The QPACK dynamic table a client may fill to compress its request
headers is capped per connection at `qpack_max_table_capacity` bytes
(name + value + 32 per entry, RFC 9204 §3.2.1), set under
`{http3, #{...}}` too; `0` turns it off. A partial encoder instruction is
buffered only up to the size a valid one can reach.

A request whose headers (or trailers) use table entries still on their
way is held until they arrive (a blocked stream, RFC 9204 §2.1.2). At
most `qpack_blocked_streams` requests of a connection wait this way at
once; a client that goes past that is closed with
`QPACK_DECOMPRESSION_FAILED`. A waiting request holds no in-flight slot
until it can be read. With `body_buffering => manual` what it holds
stays within its stream's flow-control window. Otherwise it holds at
most `max_content_length` plus twice `max_header_block` bytes, frame
headers counted, and past that it is answered `413`, since its route
(which may allow a larger body) is not known before its headers are
read. `0` allows no waiting request, and most clients then never use the
table.

## Connection and slow-client guards

| Limit | Default | Configurable | Purpose |
|---|---|---|---|
| `socket_backlog` | 1024 | yes | TCP listen backlog (kernel SYN/accept queue depth) |
| `accept_priority` | `high` | yes | how quickly new connections leave the kernel queue under load (TCP only); see [Accepting connections](#accepting-connections) |
| `recv_buffer` | 64 KB | yes | the most one read takes: every read on TLS, a plain-TCP connection once a large request body comes in, a large WebSocket frame |
| `idle_recv_buffer` | 4 KB | yes | the read buffer a plain-TCP connection starts with, and what it holds while it waits for the next request or message |
| `max_clients` | 16384 | yes | concurrent connection cap per listener |
| `max_concurrent_requests` | `infinity` | yes | concurrent in-flight request cap per listener (HTTP/2 and HTTP/3, every protocol in `shed` mode) |
| `overload_mode` | `refuse` | yes | what a request over `max_concurrent_requests` gets: refused, queued, or shed with `503` |
| `max_lingering` | `auto`: `max(256, max_clients div 32)` | yes | connections lingering at once after a response that closes before the request was read to its end; over it the close follows at once (`lingers_skipped` in `roadrunner_listener:info/1`) |
| `request_timeout` | 30 s | yes | header-read timeout on a fresh connection; in `manual` body mode, also how long the body may take to read (on HTTP/2 and HTTP/3 from dispatch, on HTTP/1.1 within the request's read deadline, which is `keep_alive_timeout` for a connection's later requests), which `roadrunner_req:set_body_timeout/2` changes per request; at most `16#FFFFFFFF` ms, as `keep_alive_timeout` and `tls_handshake_timeout` |
| `keep_alive_timeout` | 60 s | yes | idle timeout between requests (on HTTP/2 and HTTP/3, of the whole connection, at least 1 s; on HTTP/2 counted from the end of the last request, whatever else the client sends; an HTTP/2 connection with a handler still at work gets a PING instead, while on HTTP/3 the client waiting on a response keeps the connection open, as RFC 9114 §5.1 expects of it) |
| `max_keep_alive_requests` | `infinity` | yes | requests an HTTP/1.1 connection serves before it closes |
| `min_bytes_per_second` | 100 | yes (0 disables) | slow-loris guard on HTTP/1.1 request heads and bodies; silence counts; a body is measured over the time spent waiting for its bytes |
| `rate_limit` | off | opt-in | per-peer request-rate cap (`429` + `Retry-After`) |

`max_clients`'s effective cap is `min(max_clients, the OS file-descriptor
limit)`. With the 16384 default above a stock `ulimit -n` of 1024, the
acceptors hit `emfile` at the descriptor ceiling — each emits
`listener_accept_error` and keeps accepting after a short
back-off rather than going silent — so raise `ulimit -n` (and the systemd
`LimitNOFILE`) for high concurrency.

`max_keep_alive_requests` is off by default. Closing a connection after a
fixed number of requests frees the memory it gathered in servers that keep
it until the connection ends; a roadrunner connection is a process whose
garbage collector does that while it lives. A fixed count also makes every
client open a new connection (and redo its TLS handshake) each time it
reaches the count, and connections a load generator or a proxy opens
together reach it together, so they all reconnect at once. Set it when you
want clients to move between servers, for example behind a load balancer
that only places new connections.

A plain-TCP connection waiting to read holds a read buffer of
`idle_recv_buffer` (4 KB), so idle memory scales as `max_clients` times
that buffer. One that receives a request head larger than that reads
heads with 16 KB from then on, so a client with many cookies does not
split each head across reads. One that receives a large request body
(HTTP/1.1), or any request body (HTTP/2), switches to `recv_buffer` for
the rest of its life, so uploads read as fast as before, and only the
connections that never receive one stay small. An idle TLS connection holds no read
buffer: its cost is the TLS connection process.

`max_clients` bounds connections and the HTTP/2 / HTTP/3
`max_concurrent_streams` bounds streams per connection, but their product
(the worst-case number of concurrent handler processes) is otherwise
unbounded. At the defaults that product (`16384 × 100` ≈ 1.6M) exceeds the
BEAM process limit (`+P`, default 262144), so under heavy multiplexing it
can exhaust the VM-global process table — failing spawns everywhere, not
just this listener — on top of unbounded handler memory.
`max_concurrent_requests` caps that product directly: a listener-wide
ceiling on live handler processes for the multiplexed protocols. Like
the per-connection stream limits, it counts a handler still running
after its client reset the stream. It also counts one still running
after its connection closed (the client went away, or a drain ended
it): the slot is released when the handler ends, not with the
connection, so a client that fills the ceiling, drops the connection
and reconnects cannot run more handlers than it allows. A connection
that dies without closing (killed, or crashed) has the slots it held
reclaimed on the next `slot_reconciliation` tick (at once when it had a
request queued): the handlers it leaves running stop counting then.
With `graceful_drain => false` there is no registry to reclaim from, so
those slots stay counted until the listener restarts. Over the
ceiling, a new HTTP/2 or HTTP/3 stream is refused with `REFUSED_STREAM` /
`H3_REQUEST_REJECTED` (both retry-safe per RFC 9113 §8.7) before any
handler runs, and the refusal emits `request_throttled` and
increments the `throttled` count from `roadrunner_listener:info/1`. HTTP/1
is unaffected: it serves one request per connection, so `max_clients`
already bounds it.

An HTTP/2 client may open streams before it has read the connection's
SETTINGS, so it cannot know `max_concurrent_streams` yet (RFC 9113
§6.5.2 makes the limit unlimited until then). Such a burst is served, up
to 100 streams when the limit is lower, and the limit applies to new
streams once the client acknowledges the SETTINGS. Streams of the burst
over the limit wait their turn instead of all running: each is decoded
but not dispatched until a running one ends, oldest first, so at most
`max_concurrent_streams` handlers run at once while any wait (a handler
still finishing after its response is sent may briefly go past it, as it
may at any time). Before the acknowledgement a connection holds at most
100 streams, running or waiting, or `max_concurrent_streams` when that is
higher; streams past that are refused.

`overload_mode` picks what a request over the ceiling gets. `refuse`, the
default, is the refusal above. `{queue, #{max_queued => N, timeout =>
Ms}}` parks it until a slot frees, refusing it only when the wait runs
out or the queue is full. `{shed, #{retry_after => Secs}}` answers it
`503 Service Unavailable` with `Retry-After` (default 1 second, RFC 9110
§15.6.4) and no body, before any handler runs: clients wait and come
back instead of retrying at once, which suits clients that talk to the
server directly, while the retry-safe refusal suits a proxy that can try
another backend. In shed mode HTTP/1 requests count against the ceiling
too, so it is one in-flight budget across every protocol; an HTTP/1
request over it gets the 503 with `connection: close` before any of its
body is read. A WebSocket upgrade holds its slot only until the `101`
is out: the session after it is a connection, which `max_clients`
bounds. A shed request emits `request_throttled` and increments
`throttled`, like a refused one. Connections over `max_clients` are
still closed without a response: answering them would cost a process,
and on TLS a handshake, for clients the server is turning away. Setting
`max_concurrent_requests` below what `max_clients` allows makes the
ceiling the soft limit that sheds and `max_clients` the hard one.

When choosing between the two knobs, prefer sizing the advertised
limits: pick `max_clients` and `max_concurrent_streams` (or
`max_streams_bidi` for HTTP/3) so their product fits the process budget.
The stream limit reaches clients in `SETTINGS` (or the QUIC transport
parameters), so they window themselves and no request is refused. A
refusal cap sheds load instead: retry-safe per the RFC, but a client
that does not retry `REFUSED_STREAM` sees every refusal as a failed
request.
Reserve `max_concurrent_requests` as the hard backstop against peers
that ignore the advertised limits, not as the primary bound.

Where `max_clients` and `max_concurrent_requests` bound the listener's
total load, `rate_limit` (off by default, the only opt-in guard here) caps
a single **source**, so one peer cannot monopolize the server. It is a
token bucket keyed on the client IP: `#{rate := N, period => Secs, burst
=> B}` allows `N` requests per `period` seconds (default 1) with a burst
of `B` (default `N`). A peer over its rate gets `429 Too Many Requests` +
`Retry-After` before any handler runs, on HTTP/1.1 from the request's
headers alone, before any of its body is read (a real 429 on HTTP/2 and HTTP/3,
not the retry-safe `REFUSED_STREAM` / `H3_REQUEST_REJECTED`, so clients
back off instead of retrying at once), emitting the `request_throttled` event with
reason `rate_limit` and incrementing the
`rate_limited` count from `roadrunner_listener:info/1`. An IPv6 client is
keyed by its /64, the network a host is given: the host can use any
address in it, so a bucket per address would let it lift its own limit
(an IPv4 client carried in IPv6, IPv4-mapped or under the NAT64 prefix
`64:ff9b::/96`, keeps its IPv4 key). A bucket is dropped once it is full
again (checked every `sweep_interval`), which a peer cannot tell from no
bucket, so waiting never resets a limit. It keys on the client IP, so
behind a balancer set `proxy_protocol` (an L4 balancer)
or `real_ip` (HTTP proxies passing `X-Forwarded-For` or `Forwarded`);
otherwise every client behind the proxy shares one bucket.

A route can have its own rate with the `rate_limit` key of its map form,
in the same shape (`rate`, `period`, `burst`). It is a second bucket per
client, kept on top of the listener's: a request to the route spends from
both, and either one can refuse it with the same 429, telemetry event and
`rate_limited` count. It needs no listener `rate_limit` to work. The check
is the first of the route's own middlewares, after the listener's, so a
route without a limit pays nothing for it, and the 429 is a response from
the route like any other: the listener's middlewares see it, it is
reported as a request, and the connection stays open. Its buckets are
dropped like the listener's, once full again. `reload_routes/2` keeps the
buckets of a route whose path, methods and limit stay the same, and
starts new ones when they change.

## Accepting connections

A new connection reaches roadrunner in two steps. First the kernel
completes the TCP handshake and puts the connection in the listen
socket's queue, which holds up to `socket_backlog` connections (Linux
caps it at `net.core.somaxconn`). From that moment the client sees
itself as connected, and it has often sent its first request already.
Then one of roadrunner's acceptors takes the connection from the queue
and starts a process to serve it. Until that second step the server
cannot see the client, time it out or answer it. When the queue is full,
the kernel drops new connection attempts and clients retry.

`accept_priority` decides how quickly the second step happens when the
server is busy. It applies to the TCP side of a listener (HTTP/1.1 and
HTTP/2, with or without TLS). HTTP/3 runs over UDP and takes its
connections another way, so the option does not affect it. The gain is
largest on plain TCP listeners. On a TLS listener, taking a connection
from the queue also waits on the `ssl` application's own processes,
which run at normal priority, so the acceptor's priority shortens only
part of that wait.

The default is `high`. The Erlang VM always runs a waiting high-priority
process before a waiting normal-priority one, so the acceptors get CPU
time ahead of the connections being served. Accepting a connection is
only a little work, so this takes very little from them. The connection
processes the acceptors start run at normal priority, like the rest of
the system. High priority only covers taking the connection from the
queue. The TLS handshake and the requests themselves run in the
connection process at normal priority, and they share the server with
everyone else.

At `normal`, the acceptors take turns with every busy connection
process. Under load that means a new client can sit in the kernel queue
long after it connected, and it sees a slow first response. At `high`
new clients are taken in promptly, and every client gets its share of
the server instead of some waiting outside it.

High priority has a guard. While the listener is at `max_clients`, it
accepts each new connection and closes it right away without a
response. During that time the acceptors drop to normal priority on
their own, so a flood of connections at the cap cannot take CPU from the
clients already being served. Each acceptor drops on the connection it
turns away and returns to high on the next one it admits. The guard is
always on and has no setting.

The trade-off: taking every client in at once has a cost. More
connections are in service at the same time, so more of them hold memory
at the same time. Plan for `max_clients` connections being served at
once; see the memory notes under
[Connection and slow-client guards](#connection-and-slow-client-guards).
On a saturated server the median latency rises, because the load is
shared across every client instead of some clients waiting in the
kernel queue. Workloads made mostly of very short-lived connections can
also see lower throughput at saturation. Connection churn below
`max_clients` is admitted promptly too: a flood of clients that connect
and close under the cap shares CPU with the existing connections, so
their deepest latency tail can rise, because the guard only engages at
the cap. Below saturation both settings behave the same.

Choose `accept_priority => normal` when three things are true: most
connections are short-lived (clients make a few requests and reconnect),
the server often runs saturated, and peak throughput matters more to you
than the time to a first response. Keep the default for long-lived
connections (keep-alive clients, pipelining, WebSockets, server-sent
events), which covers most Arizona and Phoenix LiveView apps, and
wherever a fast first response matters.

The setting is per listener, because a connection is accepted before
any request on it is read, so it cannot depend on the route. An app
with mixed traffic, such as a short-lived API whose clients reconnect
often next to long-lived browser and WebSocket traffic, can serve them
on separate listeners (ports), each with its own `accept_priority`.

```erlang
%% Default: accept promptly, drop to normal priority at max_clients.
roadrunner:start_listener(api, #{port => 8080, routes => my_handler}).

%% Acceptors stay at normal priority.
roadrunner:start_listener(api, #{
    port => 8080,
    routes => my_handler,
    accept_priority => normal
}).
```

On HTTP/1.1, two settings decide how many clients get in: `max_clients`
caps the connections being served, and `socket_backlog` caps the
connections waiting in the kernel queue. `max_concurrent_requests` does
not limit HTTP/1.1 connections. In its default `refuse` mode and in
`queue` mode it only counts HTTP/2 and HTTP/3 requests. In `shed` mode
it counts HTTP/1.1 requests too, but it answers the ones over the
ceiling with a `503`. It does not keep their connections out. See
[Connection and slow-client guards](#connection-and-slow-client-guards)
for these options.

## Configuring

Pass any configurable limit in the listener options map:

```erlang
roadrunner:start_listener(my_api, #{
    port => 8080,
    routes => my_handler,
    socket_backlog => 4096,
    max_content_length => 5_242_880,
    protocols => [
        {http1, #{max_header_count => 200}},
        {http2, #{max_concurrent_streams => 250, max_header_block => 32_768}},
        {http3, #{max_header_block => 32_768, max_streams_bidi => 250}}
    ],
    ws => #{max_frame_size => 1_048_576, max_message_size => 8_388_608}
}).
```

See `t:roadrunner_listener:opts/0` for the full list and the canonical
defaults.

## Connection-process memory: the GC policy

Every handler-running process is spawned with `[{fullsweep_after, 0}]`,
which makes each garbage collection a full sweep and keeps the
per-connection heap flat. It is the `handler_spawn` listener option, so a
deployment can swap in the emulator's generational default instead.
Which way that trade goes depends on whether your connections are busy
or idle, so both halves are worth knowing before you set it.

While connections are busy, the generational policy is faster on a
handler that allocates heavily. On a route that builds about 27 KB of
transient iolist per request (3 interleaved runs per side):

| policy | req/s | rss |
| --- | --- | --- |
| `fullsweep_after, 0` | 98.5k | 146 MB |
| generational | 114.8k | 185 MB |

On a route serving a precomputed body, the two policies measured the
same throughput within noise, and the default still held less resident
memory (143 MB against 162 MB). In an earlier run, on a JSON route that
builds a large transient iolist per request, values of 5, 10 and 20
measured within noise of the generational policy on both axes, because
the refc-binary garbage driving the heap piles up between full sweeps
whatever the interval between them is. Sweep every time or effectively
never.

Once connections go idle still holding the heap their last request grew,
the generational policy is much more expensive. With 2000 keep-alive
connections open, each having served a burst, and only 50 of them still
working:

| policy | process memory | live blocks | rss |
| --- | --- | --- | --- |
| `fullsweep_after, 0` | 32 MB | 211-247 MB | 406 MB |
| generational | 464 MB | not measured | 1136 MB |
| generational + `hibernate_after` | 36 MB | 134-143 MB | 645 MB |

The generational row comes from an earlier batch of runs, in which the
default measured the same 32 MB of process memory and 449-469 MB of rss.
That idle case is what the default is for: 14.5x the process memory.

Adding `hibernate_after` to the default policy is not a further win.
In a separate batch of three interleaved rounds, a 1000 ms
`hibernate_after` cut the emulator's total memory from 252-253 MB to
193-194 MB and the binary allocator's blocks from 166-184 MB to
73-99 MB, but the resident set came out 12-22 MB higher and the 50 busy
connections served 2-7.5% fewer requests.

The last row is the configuration worth reaching for if you want the
throughput anyway. It was measured with these settings:

```erlang
roadrunner:start_listener(my_api, #{
    port => 8080,
    routes => my_handler,
    handler_spawn => #{opts => [{fullsweep_after, 65535}]},
    hibernate_after => 1000
}).
```

Hibernation sweeps and shrinks an idle connection's heap, so its process
memory lands close to the default's, and its live blocks (the memory the
emulator is actually using) come out below the default's.

Two things to weigh before setting it. First, the resident set stays
well above the default even though less memory is in use, because the
heap allocator holds on to carriers its blocks no longer fill: in these
runs `eheap_alloc` held 125-145 MB of carriers for 16-20 MB of blocks.
Switching off the segment cache with `+MMmcs 0` in `vm.args` recovers
roughly half of the gap (645 MB to 535 MB, two rounds each), with
throughput within 3%. Carrier abandonment (`+M<S>acul`) did not help
in either direction. It is already enabled: on OTP 29 the per-scheduler
allocator instances default to 45 for `eheap_alloc` and 60 for
`binary_alloc`. Turning it off (`+MHacul 0 +MBacul 0`) raised the
resident set in all three rounds of an earlier batch (medians 829-938 MB
against 610-712 MB). Raising `eheap_alloc` to 60 on top of `+MMmcs 0`
did not lower it: over two rounds its median went up in one and down in
the other, and its peak rose in both.

Second, waking a hibernated connection is charged to the request that
wakes it. With connections idling 1500 ms between requests, just past a
1000 ms `hibernate_after`, mean request latency went from 2.1-2.4 ms to
about 3.0 ms. In that run every active connection started its idle gap
at the same moment, so they woke at about the same time; staggered
wakes were not measured.

### The heap floor: a larger heap for requests that need one

Under the default policy, every full sweep leaves the heap just big
enough for what is live, so a handler that builds a large response grows
it again from that small size and collects several times on the way.
Even on a small JSON route, garbage collection was about 18% of the
server's CPU.

An HTTP/1.1 connection therefore keeps a heap floor: after each request
it raises its `min_heap_size` to the heap that request needed, up to
`handler_spawn`'s `heap_floor` `max` (46422 words, about 360 KB, by default),
and the next request starts at that size. Every 16 requests the floor
drops back and is learned again, and before the connection hibernates or
runs a WebSocket session it drops to the spawn `min_heap_size`. Dropping
it costs a connection whose requests still need the heap nothing, since
the heap only shrinks at a collection
that finds it mostly empty, while a connection that served one large
response and now serves small ones gives the memory back: without that,
it would keep the large heap as long as it stayed busy. In a
two-sided A/B against the arena-style JSON, pipelined and mixed
GET/POST loads (1024 connections, a fresh server per run):

| load | without the floor | with it |
| --- | --- | --- |
| compressed JSON | 16.8k req/s | 20.8k req/s (+23%) |
| pipelined GETs | 1.09M req/s | 1.33M req/s (+22%) |
| mixed GET/POST | 366k req/s | 385k req/s (+5%) |

Busy connections held about 10% more memory on the JSON load and the
same on the others. A connection that waits collects nothing and so
keeps the heap its last request left: 1000 connections idle after a
large JSON response held the same memory with and without the floor
(after small requests they keep the least floor described below). With
a `max_heap_size` set, in `handler_spawn`'s `opts` or as the emulator's
default when the connection started, the floor is off, the least one
included, as for stream workers below. Set `heap_floor => false` to
turn it off.

The floor a request teaches is the smallest heap that fits it, so a
request still fills that heap and collects about once each time. On a
large heap that collection costs mostly the copying of what is live, and
a larger floor saves little; on a small one it costs mostly its fixed
price. So once a connection has served a request its floor stays at
least 2586 words (about 20 KB, or `max` when lower), and the relearning
every 16 requests drops it back to that rather than to the spawn size.
In a two-sided A/B at 256 connections (4 runs per side, fresh server
per run), keep-alive GETs answered by a tiny handler went from 0.5 to
1.0 collections per request (which of the two depends on how the heap
happened to grow) to 0.29, and used about 5-8% less CPU per request on
average; 16-deep
pipelined GETs used about 16% less, and larger JSON responses were
unchanged. Tail latency stayed the same. The price is memory on
connections whose requests need less than that: 1000 such connections
idle after a burst held 21.6 KB of process memory each instead of
8.8 KB (about 130 MB more per 10,000 idle connections), while
connections serving larger responses already keep more than the least
floor and hold the same. `hibernate_after` gives that memory back from
connections that stay idle.

HTTP/2 and HTTP/3 run each request in a stream worker of its own, which
lives for that request alone, so there the connection keeps the floor and
starts each worker at it. A worker's heap at the end of its request says
little of what the request needed, since a full sweep can shrink it back
toward what is live, so a worker instead tells whether it collected at all: one
that did raises the floor by half, and the workers after it raise it again
until they run without collecting. Every 16th stream starts at half the
floor and, if it runs without collecting, lowers the floor to that, so a
connection whose requests got smaller stops sizing workers for the larger
ones. A streamed or file response teaches the floor only what happened
before its body started, since a long stream collects however large the
floor, and every worker drops its `min_heap_size` back to the base once
it has started, so a stream that lives on holds only what it keeps live.
With a `max_heap_size` set, in `handler_spawn`'s `opts` or as the
emulator's default (read as a connection starts, and again at each
spawn while it has none), the floor is off: a
raised `min_heap_size` makes every collection hold larger heaps, so it
could take a worker over the limit when the worker's own data would
not.

Compared with learning from the heap left at the end of a request, over
h2c with 16 connections and a fresh server per run, a JSON response used
about 15% less CPU per request (most of its collections gone), a gRPC
unary call about 5% less, and a bare hello response about 1% more. Tail
latency stayed the same or got better. Peak memory under load rose about
7-13%, as each worker starts with the floor's heap; idle connections hold
no workers, so they cost the same. A load that mixes in large responses
sees about the same CPU, as those responses dominate its cost.

A WebSocket session keeps a floor too, learned from its `handle_info/2`
calls, where a server push is usually built: a message from another
process turned into a rendered, encoded frame. The next push starts at
the heap the last one needed. It relearns every 16 messages while
raised and drops back before the session hibernates. A session pushing
a 50-item JSON message from `handle_info/2` collected once per push
instead of five times, and a push took 48 µs instead of 78 to 82 µs,
round trip included. Inbound frames run no floor code, so an echo or
chat session answering small messages costs exactly what it did. An
idle session holds the heap its last event left with or without the
floor. A session that runs in an HTTP/1.1 connection inherits the heap
the requests before it left, so with its floor on it collects once as
it starts when that heap is over its base, and learns its floor from
its own data rather than from those requests.

Only a `handle_info/2` that needed at least the `min` of `ws.heap_floor`
(2586 words, about 20 KB, by default) raises the floor, so small
messages such as timers or presence pings leave it; `#{min => 0}` lets
every message raise it. Its `max` sets the cap for sessions alone (by
default `handler_spawn.heap_floor`'s), `ws => #{heap_floor => false}`
turns it off for sessions, and an upgrade can set the same for its own
session.

To start every connection at a size from its first request, raise
`min_heap_size` itself. On the bench's `httparena_json` route, which
builds a 50-item JSON list per request (8 interleaved runs per side,
before the floor existed):

| `handler_spawn` opts | collections per request | req/s | CPU per request |
| --- | --- | --- | --- |
| default | 3.9 | 32.6k | 179 µs |
| `[{min_heap_size, 16384}]` | 1.5 | 40.9k | 142 µs |

```erlang
roadrunner:start_listener(my_api, #{
    port => 8080,
    routes => my_handler,
    handler_spawn => #{opts => [{min_heap_size, 16384}]}
}).
```

The price is idle memory. The minimum applies to every handler-running
process from its start, the connection process included, so with 2000
idle connections each keep-alive or WebSocket connection held 140 KB of
process memory instead of 9 KB. The gain also depends on what the route
allocates: on a route that compresses a body it has already built,
throughput moved within noise (+2.4%). Size it to what one request
allocates: the value is in words, so 16384 is 128 KB on a 64-bit system.

Reproduce the idle-connection numbers in this section with
`scripts/idle_pool.escript`, which opens a pool of mostly-idle
connections and samples the server's memory. A closed-loop benchmark
cannot show them, since there every connection stays busy.

## CPU in containers: scheduler busy-wait

The listener options above bound memory. The one emulator flag worth
setting for CPU is the scheduler busy-wait threshold. By default a
scheduler that runs out of work spins for a while before sleeping, on
the bet that more work is about to arrive. That bet pays off on a
dedicated machine; in a container with a CPU quota it burns quota doing
nothing, and the spin is charged to your workload.

Add to `vm.args` when running in a container, or anywhere CPU is metered
or shared:

```
+sbwt none
+sbwtdcpu none
+sbwtdio none
```

Measured on a mostly-idle server (1024 connections, a paced 10k req/s,
so schedulers repeatedly run dry — the shape most production services
actually have): **CPU 265% → 110%** for the same request rate, with p99
and p99.9 both *improving* and peak throughput unchanged. Run-to-run
variance also drops sharply, because the spin is what was varying.

How the trade lands depends on how long the idle gaps are, so measure
your own workload. Where gaps are long — a paced service at a low rate,
the case above — a scheduler would sleep through them anyway and these
flags mostly just stop it burning quota. Where gaps are short, a fast
request-response or WebSocket echo with microseconds between messages,
the spin is precisely what keeps a scheduler from sleeping between them,
and switching it off costs real latency: on a 64-connection WebSocket
ping-pong, RTT p50 went from 169-181 us to 247-257 us with the busy-wait
disabled, a 42-46% regression, and throughput fell about 30%. At true
saturation, where a scheduler always has another process ready to run,
the spin never triggers and the flags do nothing either way.

## Many cores: I/O poll threads

The emulator watches sockets from I/O poll threads, and by default it
starts one. On plain TCP, roadrunner reads HTTP/1.1 and WebSocket
connections with `{active, once}`: after each request or message the
connection re-arms its socket, and when the peer's next bytes arrive,
the poll thread sees the socket turn readable and hands the read to a
scheduler, waking it if it sleeps. A server at full load mostly skips
that step, because by the time a connection re-arms, the next bytes are
often already waiting. A server with spare capacity does not: every
request and every message then passes through that one thread. With
many schedulers the thread becomes the limit, and throughput stops
growing while the schedulers still have time to spare.

On a machine with many cores, give the emulator one poll thread, each
with its own pollset, per eight schedulers. In `vm.args`:

```
+IOPt 13
+IOPp 100
```

`+IOPt 13` sets the poll threads to 13% of the schedulers, rounded
down: 8 threads for 64 schedulers, 2 for 16, and the default single
thread below 16. `+IOPp 100` gives each thread a pollset of its own.
The OTP documentation for `+IOt` gives the test for whether a node
needs more: microstate accounting shows the poll thread busy. Run
`msacc:start(1000), msacc:print().` under load and read the `poll` row.

Measured on a 24-thread machine, one message or request in flight per
connection. With the load generator on the same cores, the single poll
thread was the limit: it was busy for 86% of each run while getting
about a third of a core, and the schedulers spent 20-29% of their time
spinning for work. With `+IOPt 13 +IOPp 100` (three poll threads at 24
schedulers), a 512-connection WebSocket echo went from 3.9M to 5.2M
messages in 6 seconds (+33%), and HTTP/1.1 keep-alive from 3.6M to 4.7M
requests (+30%). Four poll threads gave +50% for the echo at both 512
and 4000 connections, with the schedulers' spin down to about 5%. Where
the poll thread was not the limit (the server on cores of its own, or 16
messages in flight per connection), throughput stayed within run-to-run
noise, a few percent either way.

The gain grows with the core count. On a 64-core server, with 64
schedulers and the load generator on cores of its own, the same
one-message-in-flight echo was capped at about 330K messages per second
with the single poll thread, while the schedulers sat partly idle. With
`+IOPt 13 +IOPp 100` (eight poll threads) it reached about 2M per second
at 512, 4096 and 16384 connections, with the schedulers busy.

## Cold start: the first requests after a deploy

Outside a release the emulator runs in interactive mode, where a module
is loaded the first time something calls into it. Only a handful of
roadrunner's modules are resident when a listener starts; the whole
request path is still on disk. ERTS spells out the consequence in
"Non-blocking code loading": "The ability to prepare several modules in
parallel is not currently used as almost all code loading is serialized
by the code_server process." So traffic arriving at a just-started node
queues there, and the cost lands on the first requests the deploy
serves, not on the steady state.

It is worth real time. On a 512-connection TLS workload the p99 of a
connection's first 7 requests was 83.6 ms against a cold node and
8.7 ms once warm, with steady-state latency identical. A 1024-connection
burst measured from connect to first response byte took 45 ms cold and
8 ms warm.

Deploy as an OTP release and the problem does not arise: the generated
boot script `primLoad`s every module of every application at start, in
interactive and embedded mode alike. If you run roadrunner outside a
release (a plain shell, an escript, a container that boots `erl`
directly), expect the first requests after each restart to be slower,
and send some traffic before putting the node into rotation.

## TLS alert logging on internet-facing ports

`ssl` logs every alert it raises or receives as a notice-level report,
"TLS server: In state hello ... generated SERVER ALERT: Fatal - Unexpected
Message" being the common shape. A TLS port reachable from the internet
raises one for every scanner and misdirected client that connects and
sends something other than a ClientHello, so the log fills with them.

Roadrunner reports each failed handshake itself as
`listener_accept_error` with a `{handshake, Reason}` reason
that carries the alert text, so a deployment that consumes that event
already has the information and can silence the duplicate through the
listener's `tls` opts:

```erlang
roadrunner:start_listener(edge, #{
    port => 443,
    tls => [{certfile, Cert}, {keyfile, Key}, {log_level, warning}],
    routes => Routes
}).
```

Roadrunner leaves the level at `ssl`'s default on purpose. The same
setting also hides alerts raised after the handshake (a bad record from a
buggy client, a renegotiation attempt). Those close the connection, and
`listener_conn_close` reports them as `{transport, {tls_alert, _}}`, but
the default event handler drops events, so a deployment without one
would otherwise see nothing about TLS trouble at all. Quiet it when you
consume the events; keep it while the log is what you read.
