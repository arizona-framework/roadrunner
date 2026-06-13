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

The body cap is enforced across all three protocols. For HTTP/1.1 it
covers both `Content-Length` and `Transfer-Encoding: chunked` requests:
the cap is checked as the body is read (a chunked body on its declared
size line), so an oversized body is rejected without buffering the whole
thing. HTTP/2 and HTTP/3 accumulate DATA frames against the same cap; an
over-cap body answers `413 Payload Too Large` and resets the stream
(`RST_STREAM(NO_ERROR)` on h2, `STOP_SENDING` on h3) so the client stops
sending.

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

Notes:

- `max_message_size` must be `>= max_frame_size`; a listener configured
  otherwise refuses to start
- each fragment is charged at least a small fixed overhead toward
  `max_message_size`, so a flood of empty or tiny continuation frames is
  bounded by the cap, not just the total payload bytes
- permessage-deflate is inflated in bounded chunks against
  `max_message_size`, so a small high-ratio frame cannot expand into
  gigabytes before the cap fires

When a cap closes a connection, roadrunner emits
`[roadrunner, ws, frame_rejected]` (metadata `reason`, measurement
`size`) so oversize and flood attempts are visible to subscribers.

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

A frame whose declared length exceeds the negotiated max frame size is
rejected on its 9-byte header, before the body is buffered. Streams over
the concurrency limit are refused. The cumulative header block has no
`SETTINGS` counterpart yet, so it is enforced silently: a peer that
overruns it gets `GOAWAY(ENHANCE_YOUR_CALM)`. The concurrency and
header-block caps are tuned under `{http2, #{...}}` in the `protocols`
list, with the keys `max_concurrent_streams` and `max_header_block`.

## HTTP/3 framing limits

| Limit | Default | Configurable |
|---|---|---|
| Field section block (encoded HEADERS) | 16 KB | yes |
| `initial_max_streams_bidi` | 100 | yes |

The encoded request field section is capped before it reaches the
handler; an overrun answers `431 Request Header Fields Too Large`. The
concurrent client-initiated bidirectional (request) stream count is
advertised to the peer in the QUIC transport parameters, the h3
counterpart to HTTP/2's `max_concurrent_streams`. Both are tuned under
`{http3, #{...}}` in the `protocols` list, with the keys
`max_header_block` and `max_streams_bidi`. QPACK runs static-table only,
so there is no dynamic-table memory to bound yet.

## Connection and slow-client guards

| Limit | Default | Configurable | Purpose |
|---|---|---|---|
| `socket_backlog` | 1024 | yes | TCP listen backlog (kernel SYN/accept queue depth) |
| `max_clients` | 150 | yes | concurrent connection cap per listener |
| `max_concurrent_requests` | `infinity` | yes | concurrent in-flight request cap per listener (HTTP/2 and HTTP/3) |
| `request_timeout` | 30 s | yes | header-read timeout on a fresh connection |
| `keep_alive_timeout` | 60 s | yes | idle timeout between requests |
| `max_keep_alive_requests` | 1000 | yes | requests served per connection before close |
| `min_bytes_per_second` | 100 | yes (0 disables) | slow-loris guard on the request-read phase |
| `rate_limit` | off | opt-in | per-peer request-rate cap (`429` + `Retry-After`) |

`max_clients` bounds connections and the HTTP/2 / HTTP/3
`max_concurrent_streams` bounds streams per connection, but their product
(the worst-case number of concurrent handler processes) is otherwise
unbounded. A high `max_clients`, set for burst tolerance, can let
concurrent handler memory grow without limit under heavy multiplexing.
`max_concurrent_requests` caps that product directly: a listener-wide
ceiling on live handler processes for the multiplexed protocols. Over the
ceiling, a new HTTP/2 or HTTP/3 stream is refused with `REFUSED_STREAM` /
`H3_REQUEST_REJECTED` (both retry-safe per RFC 9113 §8.7) before any
handler runs, and the refusal emits `[roadrunner, request, throttled]` and
increments the `throttled` count from `roadrunner_listener:info/1`. HTTP/1
is unaffected: it serves one request per connection, so `max_clients`
already bounds it.

Where `max_clients` and `max_concurrent_requests` bound the listener's
total load, `rate_limit` (off by default, the only opt-in guard here) caps
a single **source**, so one peer cannot monopolize the server. It is a
token bucket keyed on the client IP: `#{rate := N, period => Secs, burst
=> B}` allows `N` requests per `period` seconds (default 1) with a burst
of `B` (default `N`). A peer over its rate gets `429 Too Many Requests` +
`Retry-After` before any handler runs (a real 429 on HTTP/2 and HTTP/3,
not the retry-safe `REFUSED_STREAM` / `H3_REQUEST_REJECTED`, so clients
back off instead of retrying at once), emitting `[roadrunner, request,
throttled]` with `reason => rate_limit` and incrementing the
`rate_limited` count from `roadrunner_listener:info/1`. Idle per-peer
buckets are swept on a timer (`idle_ttl` / `sweep_interval`). It keys on
the real client IP, so set `proxy_protocol` behind an L4 balancer for
accurate per-client limiting.

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
