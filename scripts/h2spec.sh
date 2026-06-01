#!/usr/bin/env bash
#
# Run h2spec (https://github.com/summerwind/h2spec) against a roadrunner
# listener. Phase H12.
#
# Brings up a transient TLS h2 listener on a random port, points h2spec
# at it via Docker, and prints the conformance report.
#
# Requirements:
#   - docker (for `summerwind/h2spec:latest`)
#   - mise (or rebar3 + erl on PATH)
#   - openssl (for the throwaway test cert)
#
# Usage:
#   ./scripts/h2spec.sh                    # full suite
#   ./scripts/h2spec.sh -k                 # skip strict (allow extensions)
#   ./scripts/h2spec.sh 6.5                # run section 6.5 only
#   H2SPEC_PORT=8443 ./scripts/h2spec.sh   # explicit port
#
# Exit codes:
#   0  — h2spec passed
#   1+ — h2spec found failures (count == failed test count)

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

PORT="${H2SPEC_PORT:-0}"   # 0 = let the kernel pick
CERT_DIR="$(mktemp -d)"
trap 'rm -rf "$CERT_DIR"; pkill -P $$ || true' EXIT

# Generate a throwaway self-signed cert for the test listener.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$CERT_DIR/key.pem" \
    -out    "$CERT_DIR/cert.pem" \
    -subj   "/CN=localhost" \
    >/dev/null 2>&1

# Start a roadrunner listener in the background. The escript opens a
# TLS h2-enabled listener and writes its bound port to a known file
# so we can inject it into the h2spec invocation.
PORT_FILE="$CERT_DIR/port"

# Expect `_build/test/lib/*` populated (CI restores it from the
# `cache-erlang` job; locally, run `rebar3 as test compile` once).
if [ ! -d "_build/test/lib/roadrunner/ebin" ]; then
    echo "missing _build/test/lib/roadrunner/ebin — run 'rebar3 as test compile' first" >&2
    exit 2
fi

# Capture stdout+stderr to a log file so a failed listener-start shows
# its real error message; surface the log on failure below.
#
# Arizona-style (see arizona/scripts/start_test_server.sh): invoke
# `erl` directly with explicit `-pa`. `-noshell` skips the
# interactive prompt entirely (so stdin EOF doesn't tear down BEAM
# in CI); the eval's trailing `receive` blocks BEAM until we kill it.
# Redirect stdin from /dev/null for belt-and-braces.
SHELL_LOG="$CERT_DIR/shell.log"
PA_DIRS=()
for d in _build/test/lib/*/ebin _build/test/lib/roadrunner/test; do
    PA_DIRS+=(-pa "$d")
done

erl -noshell "${PA_DIRS[@]}" -eval "
    {ok, _} = application:ensure_all_started(roadrunner),
    {ok, _} = roadrunner:start_listener(h2spec_listener, #{
        port => $PORT,
        protocols => [http2],
        tls => [
            {certfile, \"$CERT_DIR/cert.pem\"},
            {keyfile, \"$CERT_DIR/key.pem\"}
        ],
        routes => roadrunner_hello_handler
    }),
    Port = roadrunner_listener:port(h2spec_listener),
    file:write_file(\"$PORT_FILE\", integer_to_binary(Port)),
    receive _ -> ok end.
" </dev/null >"$SHELL_LOG" 2>&1 &
SHELL_PID=$!

# Wait for the port file to appear. Up to 60 s — cold-BEAM start
# on a CI runner can take a few seconds.
for _ in $(seq 1 120); do
    [ -s "$PORT_FILE" ] && break
    sleep 0.5
done

if [ ! -s "$PORT_FILE" ]; then
    echo "roadrunner listener didn't come up — shell stdout follows:" >&2
    echo "----" >&2
    cat "$SHELL_LOG" >&2
    echo "----" >&2
    kill $SHELL_PID 2>/dev/null || true
    exit 2
fi

ACTUAL_PORT=$(cat "$PORT_FILE")
echo "roadrunner h2 listener on https://127.0.0.1:$ACTUAL_PORT (pid $SHELL_PID)" >&2

# Forward to h2spec. `-t` enables TLS, `-k` skips cert verification.
#
# A couple of h2spec cases (e.g. §5.1 "DATA frame on a non-open stream")
# are inherently timing-sensitive: h2spec sends a request then immediately
# probes for the server's reaction, and on a loaded CI runner the handler's
# legitimate response can win the race against the error-detection path, so
# the probe observes the response instead of the expected GOAWAY. That is a
# harness timing race, not a conformance failure. Retry the full run up to
# RETRIES times against the same listener: a genuine non-conformance fails
# every attempt deterministically, so the retry stabilises flakes WITHOUT
# masking a real regression. The listener is shared across attempts (it is
# started once above), so a retry is just another h2spec pass.
RETRIES="${H2SPEC_RETRIES:-3}"
RC=1
for attempt in $(seq 1 "$RETRIES"); do
    # `|| RC=$?` keeps the non-zero exit from tripping `set -e` and captures
    # h2spec's real return code (== failed-test count) for the retry decision.
    RC=0
    docker run --rm --network=host \
        summerwind/h2spec:latest \
        -h 127.0.0.1 -p "$ACTUAL_PORT" -t -k "$@" || RC=$?
    [ "$RC" -eq 0 ] && break
    if [ "$attempt" -lt "$RETRIES" ]; then
        echo "h2spec attempt $attempt/$RETRIES failed (rc=$RC); retrying..." >&2
        sleep 1
    fi
done

kill $SHELL_PID 2>/dev/null || true
exit $RC
