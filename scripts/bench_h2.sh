#!/usr/bin/env bash
#
# h2load-driven HTTP/2 throughput bench against a roadrunner listener.
# Phase H12.
#
# Sister to `scripts/bench.escript` (which is h1-only). Brings up a TLS
# listener with h2 enabled, drives load via h2load, and prints the
# canonical h2load summary.
#
# Honest framing per `feedback_perf_change_honesty`:
#   - h2 vs h1 throughput depends heavily on workload shape. Small
#     responses with high concurrency typically *favor* h2 (single
#     connection multiplexing). Single-request latency may favor h1
#     (no frame demux overhead).
#   - Run BOTH directions on the same hardware before claiming a win.
#   - Numbers vary 10-15% run-to-run on a loaded dev box. Repeat 5x and
#     take the median if you're publishing a comparison.
#
# Requirements:
#   - h2load (from nghttp2-tools / brew install nghttp2)
#   - mise / rebar3
#   - openssl
#
# Usage:
#   ./scripts/bench_h2.sh                   # default: 10s, 100 concurrent
#   H2_REQS=100000 H2_CONCURRENCY=200 ./scripts/bench_h2.sh
#   H2_DURATION=30 ./scripts/bench_h2.sh    # duration mode

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

REQS="${H2_REQS:-100000}"
CONCURRENCY="${H2_CONCURRENCY:-100}"
STREAMS="${H2_STREAMS:-10}"     # max concurrent streams per connection
DURATION="${H2_DURATION:-}"     # if set, overrides -n / -c with -D

if ! command -v h2load >/dev/null; then
    echo "h2load not found — install nghttp2-tools" >&2
    exit 2
fi

CERT_DIR="$(mktemp -d)"
trap 'rm -rf "$CERT_DIR"; pkill -P $$ || true' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$CERT_DIR/key.pem" \
    -out    "$CERT_DIR/cert.pem" \
    -subj   "/CN=localhost" \
    >/dev/null 2>&1

PORT_FILE="$CERT_DIR/port"
ERL_FLAGS="-config $HOME/.config/rebar3/ssl" \
mise exec -- rebar3 as test shell --eval "
    application:ensure_all_started(roadrunner),
    {ok, _} = roadrunner:start_listener(bench_h2_listener, #{
        transport => ssl,
        port => 0,
        tls_opts => [
            {certfile, \"$CERT_DIR/cert.pem\"},
            {keyfile, \"$CERT_DIR/key.pem\"},
            {alpn_preferred_protocols, [<<\"h2\">>]}
        ],
        http2_enabled => true,
        dispatch => {handler, roadrunner_hello_handler},
        middlewares => []
    }),
    Port = roadrunner_listener:port(bench_h2_listener),
    file:write_file(\"$PORT_FILE\", integer_to_binary(Port)).
" --no-shell >/dev/null 2>&1 &
SHELL_PID=$!

for _ in $(seq 1 30); do
    [ -s "$PORT_FILE" ] && break
    sleep 0.5
done

if [ ! -s "$PORT_FILE" ]; then
    echo "roadrunner listener didn't come up" >&2
    kill $SHELL_PID 2>/dev/null || true
    exit 2
fi

PORT=$(cat "$PORT_FILE")
URL="https://127.0.0.1:$PORT/"

if [ -n "$DURATION" ]; then
    h2load -D "$DURATION" -c "$CONCURRENCY" -m "$STREAMS" "$URL"
else
    h2load -n "$REQS" -c "$CONCURRENCY" -m "$STREAMS" "$URL"
fi
RC=$?

kill $SHELL_PID 2>/dev/null || true
exit $RC
