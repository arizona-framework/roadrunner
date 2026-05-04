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
ERL_FLAGS="-config $HOME/.config/rebar3/ssl" \
mise exec -- rebar3 as test shell --eval "
    application:ensure_all_started(roadrunner),
    {ok, _} = roadrunner:start_listener(h2spec_listener, #{
        transport => ssl,
        port => $PORT,
        tls_opts => [
            {certfile, \"$CERT_DIR/cert.pem\"},
            {keyfile, \"$CERT_DIR/key.pem\"},
            {alpn_preferred_protocols, [<<\"h2\">>]}
        ],
        http2_enabled => true,
        dispatch => {handler, roadrunner_hello_handler},
        middlewares => []
    }),
    Port = roadrunner_listener:port(h2spec_listener),
    file:write_file(\"$PORT_FILE\", integer_to_binary(Port)).
" --no-shell >/dev/null 2>&1 &
SHELL_PID=$!

# Wait for the port file to appear.
for _ in $(seq 1 30); do
    [ -s "$PORT_FILE" ] && break
    sleep 0.5
done

if [ ! -s "$PORT_FILE" ]; then
    echo "roadrunner listener didn't come up — check the shell stdout" >&2
    kill $SHELL_PID 2>/dev/null || true
    exit 2
fi

ACTUAL_PORT=$(cat "$PORT_FILE")
echo "roadrunner h2 listener on https://127.0.0.1:$ACTUAL_PORT (pid $SHELL_PID)" >&2

# Forward to h2spec. `-t` enables TLS, `-k` skips cert verification.
docker run --rm --network=host \
    summerwind/h2spec:latest \
    -h 127.0.0.1 -p "$ACTUAL_PORT" -t -k "$@"
RC=$?

kill $SHELL_PID 2>/dev/null || true
exit $RC
