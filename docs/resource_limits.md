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

Notes:

- `max_message_size` must be `>= max_frame_size`; a listener configured
  otherwise refuses to start
- each fragment is charged at least a small fixed overhead toward
  `max_message_size`, so a flood of empty or tiny continuation frames is
  bounded by the cap, not just the total payload bytes
- permessage-deflate is inflated in bounded chunks against
  `max_message_size`, so a small high-ratio frame cannot expand into
  gigabytes before the cap fires

When a cap closes a connection, roadrunner emits the
`ws_frame_rejected` event (with the cap's `reason` and the offending
`size`) so oversize and flood attempts are visible to your event
handler.

## HTTP/2 framing limits

The framing layer enforces these. The ones with a `SETTINGS` counterpart
are advertised to the peer in the initial `SETTINGS` frame.

| Limit | Default | Configurable |
|---|---|---|
| `SETTINGS_MAX_FRAME_SIZE` | 16 KB | no (fixed) |
| `SETTINGS_MAX_CONCURRENT_STREAMS` | 100 | yes |
| HPACK decoder table | 4 KB | no (fixed) |
| Header block (HEADERS + CONTINUATION) | 16 KB | yes |
| Connection receive window (`conn_window`) | 65535 | yes |
| Stream receive window (`stream_window`) | 65535 | yes |
| Unread socket reads per connection (`active`) | 16 | yes |

A frame whose declared length exceeds the negotiated max frame size is
rejected on its 9-byte header, before the body is buffered. Streams over
the concurrency limit are refused. The cumulative header block has no
`SETTINGS` counterpart yet, so it is enforced silently: a peer that
overruns it gets `GOAWAY(ENHANCE_YOUR_CALM)`. The concurrency and
header-block caps are tuned under `{http2, #{...}}` in the `protocols`
list, with the keys `max_concurrent_streams` and `max_header_block`.

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
| `initial_max_streams_bidi` | 100 | yes |
| QPACK dynamic table (`SETTINGS_QPACK_MAX_TABLE_CAPACITY`) | 4 KB | yes |
| QPACK blocked streams (`SETTINGS_QPACK_BLOCKED_STREAMS`) | 16 | yes |

The encoded request field section is capped before it reaches the
handler; an overrun answers `431 Request Header Fields Too Large`. The
concurrent client-initiated bidirectional (request) stream count is
advertised to the peer in the QUIC transport parameters, the h3
counterpart to HTTP/2's `max_concurrent_streams`. Both are tuned under
`{http3, #{...}}` in the `protocols` list, with the keys
`max_header_block` and `max_streams_bidi`.

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
| `recv_buffer` | 64 KB | yes | per-connection inbound TCP buffer (body-path throughput vs memory at scale) |
| `max_clients` | 16384 | yes | concurrent connection cap per listener |
| `max_concurrent_requests` | `infinity` | yes | concurrent in-flight request cap per listener (HTTP/2 and HTTP/3, every protocol in `shed` mode) |
| `overload_mode` | `refuse` | yes | what a request over `max_concurrent_requests` gets: refused, queued, or shed with `503` |
| `request_timeout` | 30 s | yes | header-read timeout on a fresh connection |
| `keep_alive_timeout` | 60 s | yes | idle timeout between requests |
| `max_keep_alive_requests` | 1000 | yes | requests served per connection before close |
| `min_bytes_per_second` | 100 | yes (0 disables) | slow-loris guard on the request-read phase |
| `rate_limit` | off | opt-in | per-peer request-rate cap (`429` + `Retry-After`) |

`max_clients`'s effective cap is `min(max_clients, the OS file-descriptor
limit)`. With the 16384 default above a stock `ulimit -n` of 1024, the
acceptors hit `emfile` at the descriptor ceiling — each emits
`listener_accept_error` and keeps accepting after a short
back-off rather than going silent — so raise `ulimit -n` (and the systemd
`LimitNOFILE`) for high concurrency. Saturation recv-buffer memory scales
as `max_clients × recv_buffer`, so lower either for a tighter bound.

`max_clients` bounds connections and the HTTP/2 / HTTP/3
`max_concurrent_streams` bounds streams per connection, but their product
(the worst-case number of concurrent handler processes) is otherwise
unbounded. At the defaults that product (`16384 × 100` ≈ 1.6M) exceeds the
BEAM process limit (`+P`, default 262144), so under heavy multiplexing it
can exhaust the VM-global process table — failing spawns everywhere, not
just this listener — on top of unbounded handler memory.
`max_concurrent_requests` caps that product directly: a listener-wide
ceiling on live handler processes for the multiplexed protocols. Over the
ceiling, a new HTTP/2 or HTTP/3 stream is refused with `REFUSED_STREAM` /
`H3_REQUEST_REJECTED` (both retry-safe per RFC 9113 §8.7) before any
handler runs, and the refusal emits `request_throttled` and
increments the `throttled` count from `roadrunner_listener:info/1`. HTTP/1
is unaffected: it serves one request per connection, so `max_clients`
already bounds it.

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
body is read. A shed request emits `request_throttled` and increments
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
