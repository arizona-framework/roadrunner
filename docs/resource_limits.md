# Resource limits

Roadrunner bounds how much memory and CPU a single connection or peer
can pull in before any handler runs. The goal is that no client, by
sending oversized, malformed, or slow input, can grow a connection's
memory without bound or pin a worker. Every limit on this page is on by
default.

This page is an operator reference. For the reporting policy, see
`SECURITY.md`. For the exact option types, see
`t:roadrunner_listener:opts/0`.

## HTTP request limits

| Limit | Default | Configurable | Over-limit behavior |
|---|---|---|---|
| Request line | 8 KB | no (fixed) | 400, connection closed |
| Header line | 8 KB | no (fixed) | 400, connection closed |
| Header block (cumulative) | 10 KB | no (fixed) | 400, connection closed |
| Header count | 100 | no (fixed) | 400, connection closed |
| Body (`max_content_length`) | 10 MB | yes | 413 Payload Too Large |

The body cap is enforced the same way for both `Content-Length` and
`Transfer-Encoding: chunked` requests: the cap is checked as the body is
read, so an oversized chunked body is rejected without buffering the
whole thing.

## WebSocket limits

A WebSocket message is the WS analog of a request body, so its caps
default to the same value as `max_content_length`. Both are enforced
before the payload reaches the handler, and crossing either closes the
connection with RFC 6455 code 1009 (message too big).

| Limit | Default | Configurable | What it bounds |
|---|---|---|---|
| `ws_max_frame_size` | 10 MB | yes | one frame's declared payload, checked on the frame header before the body is buffered |
| `ws_max_message_size` | 10 MB | yes | a reassembled message: the running total across fragments, and the decompressed size when permessage-deflate is negotiated |

Notes:

- `ws_max_message_size` must be `>= ws_max_frame_size`; a listener
  configured otherwise refuses to start
- each fragment is charged at least a small fixed overhead toward
  `ws_max_message_size`, so a flood of empty or tiny continuation frames
  is bounded by the cap, not just the total payload bytes
- permessage-deflate is inflated in bounded chunks against
  `ws_max_message_size`, so a small high-ratio frame cannot expand into
  gigabytes before the cap fires

When a cap closes a connection, roadrunner emits
`[roadrunner, ws, frame_rejected]` (metadata `reason`, measurement
`size`) so oversize and flood attempts are visible to subscribers.

## HTTP/2 framing limits

These are advertised to the peer in the initial `SETTINGS` frame and
enforced by the framing layer.

| Limit | Default | Configurable |
|---|---|---|
| `SETTINGS_MAX_FRAME_SIZE` | 16 KB | no (fixed) |
| `SETTINGS_MAX_CONCURRENT_STREAMS` | 100 | no (fixed) |
| HPACK decoder table | 4 KB | no (fixed) |
| Connection receive window (`conn_window`) | 65535 | yes |
| Stream receive window (`stream_window`) | 65535 | yes |

A frame whose declared length exceeds the negotiated max frame size is
rejected on its 9-byte header, before the body is buffered. Streams over
the concurrency limit are refused.

## Connection and slow-client guards

| Limit | Default | Configurable | Purpose |
|---|---|---|---|
| `max_clients` | 150 | yes | concurrent connection cap per listener |
| `request_timeout` | 30 s | yes | header-read timeout on a fresh connection |
| `keep_alive_timeout` | 60 s | yes | idle timeout between requests |
| `max_keep_alive_requests` | 1000 | yes | requests served per connection before close |
| `min_bytes_per_second` | 100 | yes (0 disables) | slow-loris guard on the request-read phase |

## Configuring

Pass any configurable limit in the listener options map:

```erlang
roadrunner:start_listener(my_api, #{
    port => 8080,
    routes => my_handler,
    max_content_length => 5_242_880,
    ws_max_frame_size => 1_048_576,
    ws_max_message_size => 8_388_608
}).
```

See `t:roadrunner_listener:opts/0` for the full list and the canonical
defaults.
