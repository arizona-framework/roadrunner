# h2 loadgen 41 ms artifact — root cause

**Phase B1 of the unified bench / profile loadgen plan.**

## Symptom

Any keep-alive HTTP/2 client (curl `--http2`, our pure-Erlang
probe in `scripts/diag/h2_probe.escript`, the previous bench
prototype) sees ~40–50 ms latency per request against a
`roadrunner` h2 listener on loopback. Throughput tops out at
~25 req/s per connection. h1 against the same listener shows
~30 µs / req and 100k+ req/s.

## Root cause

TCP Nagle's algorithm on the server side.

Roadrunner's `src/roadrunner_listener.erl:base_listen_opts/0`
returns `[binary, {active, false}, {reuseaddr, true}, {packet, raw}]`
— **no `{nodelay, true}`**. Accepted TLS sockets inherit Nagle
ON.

HTTP/2 responses are split into multiple frames on the wire
(HEADERS frame, DATA frame, optional trailers). Roadrunner's h2
conn issues one `ssl:send/2` per frame (see
`src/roadrunner_conn_loop_http2.erl:send_response_headers/4` and
`stream_data_chunks/3`). With Nagle on:

1. Server sends HEADERS frame → kernel transmits it (no unacked data).
2. Server sends DATA frame → kernel sees small payload + prior unacked → **buffers** until ACK.
3. Client's TCP stack delays ACK by up to 40 ms (Linux delayed-ACK).
4. ACK arrives → DATA frame flushes.
5. Net: ~40 ms latency per response, every time.

HTTP/1.1 doesn't trigger this because roadrunner emits a single
`ssl:send/2` per response (status line + headers + body assembled
into one iolist) — no second small write to be Nagle-delayed.

## Why the previous diagnosis was wrong

I initially blamed the peer-BEAM setup. Reality: I'd already
patched the listener with `{nodelay, true}` during one of the
earlier diagnostic loops, then reverted it later as a "stowaway
change" without re-testing. The reverted listener kept Nagle on,
producing 41 ms on every test thereafter. The earlier
"50 µs same-BEAM probe" results were measured against a listener
that *did* have nodelay applied at the time.

curl confirms it independently: against a listener with nodelay
disabled, keep-alive requests take 47–53 ms each; with nodelay
enabled, 2 ms each.

## Fix

One line in `src/roadrunner_listener.erl:base_listen_opts/0`:

```erlang
base_listen_opts() ->
    [binary, {active, false}, {reuseaddr, true}, {packet, raw}, {nodelay, true}].
```

This is the standard production setting for HTTP servers — nginx,
h2o, cowboy, every other widely-deployed h2 server sets
`TCP_NODELAY` on accepted sockets. There is no tradeoff for this
class of server: small-write-batching from Nagle hurts request/
response latency without compensating throughput.

## Verification

After the fix:
- `mise exec -- ./scripts/diag/h2_probe.escript --mode local` reports p50 ≈ 1–3 ms (down from ~41 ms).
- `curl --http2 --insecure ...` keep-alive requests: ~2 ms each (down from ~50 ms).
- h1 path unchanged (already fast; nodelay neutral for it).
- Existing test suite still green.

## Done criterion (from plan)

✓ One-paragraph articulation of the cause (above).
✓ One-line code change that brings the bench client below the
  artifact threshold.
