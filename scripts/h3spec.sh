#!/usr/bin/env bash
#
# Run h3spec (https://github.com/kazu-yamamoto/h3spec) against a roadrunner
# listener.
#
# Brings up a transient h3 listener on a random UDP port, points the pinned
# h3spec release binary at it, and prints the report. h3spec tests how a
# server handles QUIC and HTTP/3 error cases: it sends a malformed or
# forbidden frame and checks the connection closes with the right code.
#
# Requirements:
#   - Linux x86_64 or macOS arm64 (h3spec ships release binaries for both)
#   - mise (or rebar3 + erl on PATH)
#   - openssl (for the throwaway test cert), curl, sha256sum or shasum
#
# Usage:
#   ./scripts/h3spec.sh                         # every case not known to fail
#   ./scripts/h3spec.sh -m "HTTP/3 servers"     # extra h3spec args pass through
#   H3SPEC_KNOWN_FAILURES=run ./scripts/h3spec.sh   # also run the known failures
#
# Exit codes:
#   0  — h3spec passed
#   1  — h3spec found failures
#   2  — setup failed (missing build, listener didn't start, bad download)

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

H3SPEC_VERSION="v0.1.14"

# Cases the server fails today. Each one is a conformance gap, skipped so
# the run gates every other case; a PR that fixes one deletes its line.
# Matched as substrings of h3spec's case descriptions.
KNOWN_FAILURES=(
    "MUST send FRAME_ENCODING_ERROR if an ACK range reaches below zero"
    "SHOULD send PROTOCOL_VIOLATION on an ACK for a packet never sent"
    "MUST send FRAME_ENCODING_ERROR if a frame of unknown type is received"
    "MUST send PROTOCOL_VIOLATION on no frames"
    "MUST send CRYPTO_BUFFER_EXCEEDED if CRYPTO data is buffered beyond the limit"
    "MUST send PROTOCOL_VIOLATION if PATH_CHALLENGE in Handshake is received"
    "MUST send PROTOCOL_VIOLATION if RETIRE_CONNECTION_ID for a sequence number never issued"
    "MUST send PROTOCOL_VIOLATION if STREAM_DATA_BLOCKED in Handshake is received"
    "MUST send PROTOCOL_VIOLATION if DATA_BLOCKED in Handshake is received"
    "MUST send STREAM_STATE_ERROR if STOP_SENDING is received for a non-existing stream"
    "MUST send PROTOCOL_VIOLATION if NEW_TOKEN is received"
    "MUST send STREAM_STATE_ERROR if MAX_STREAM_DATA is received for a stream that has not yet been created"
    "MUST send STREAM_STATE_ERROR if MAX_STREAM_DATA is received for a receive-only stream"
    "MUST send FRAME_ENCODING_ERROR if invalid MAX_STREAMS is received"
    "MUST send STREAM_LIMIT_ERROR or FRAME_ENCODING_ERROR if invalid STREAMS_BLOCKED is received"
    "MUST send FRAME_ENCODING_ERROR if NEW_CONNECTION_ID with invalid Retire_Prior_To is received"
    "MUST send FRAME_ENCODING_ERROR if NEW_CONNECTION_ID with 0-byte CID is received"
    "MUST send PROTOCOL_VIOLATION if HANDSHAKE_DONE is received"
    "MUST send unexpected_message TLS alert if KeyUpdate in Handshake is received"
    "MUST send unexpected_message TLS alert if EndOfEarlyData is received"
    "MUST send H3_FRAME_ERROR if a SETTINGS frame stops mid-parameter"
    "MUST send H3_FRAME_UNEXPECTED if CANCEL_PUSH is received in a request stream"
    "MUST NOT buffer a frame longer than SETTINGS_MAX_FIELD_SECTION_SIZE"
)

case "$(uname -s)-$(uname -m)" in
    Linux-x86_64)
        ASSET="h3spec-linux-x86_64"
        SHA256="7f2e3232715a3f6ff5212d408b2a3e74d6aa3ca06f96efca9a4e5dc55f3c6860"
        ;;
    Darwin-arm64)
        ASSET="h3spec-mac-arm64"
        SHA256="1d76372c74b5fbc28256229e01135f7c878045b8b0a1dc578eaa866e10df140a"
        ;;
    *)
        echo "no h3spec release binary for $(uname -s)-$(uname -m)" >&2
        exit 2
        ;;
esac

sha256() {
    if command -v sha256sum >/dev/null; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# Download the pinned release once into _build (cleaned with the build)
# and check it against the release's published digest.
H3SPEC="_build/h3spec/$H3SPEC_VERSION/$ASSET"
if [ ! -x "$H3SPEC" ]; then
    mkdir -p "$(dirname "$H3SPEC")"
    curl -fsSL -o "$H3SPEC.part" \
        "https://github.com/kazu-yamamoto/h3spec/releases/download/$H3SPEC_VERSION/$ASSET"
    if [ "$(sha256 "$H3SPEC.part")" != "$SHA256" ]; then
        echo "h3spec download doesn't match the pinned SHA-256" >&2
        rm -f "$H3SPEC.part"
        exit 2
    fi
    chmod +x "$H3SPEC.part"
    mv "$H3SPEC.part" "$H3SPEC"
fi

PORT="${H3SPEC_PORT:-0}"   # 0 = let the kernel pick
CERT_DIR="$(mktemp -d)"
trap 'rm -rf "$CERT_DIR"; pkill -P $$ || true' EXIT

# Generate a throwaway self-signed cert for the test listener.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$CERT_DIR/key.pem" \
    -out    "$CERT_DIR/cert.pem" \
    -subj   "/CN=localhost" \
    >/dev/null 2>&1

PORT_FILE="$CERT_DIR/port"

# Expect `_build/test/lib/*` populated (CI restores it from the
# `cache-erlang` job; locally, run `rebar3 as test compile` once).
if [ ! -d "_build/test/lib/roadrunner/ebin" ]; then
    echo "missing _build/test/lib/roadrunner/ebin — run 'rebar3 as test compile' first" >&2
    exit 2
fi

# Start the listener the same way `h2spec.sh` does: `erl -noshell` with
# explicit `-pa`, stdin from /dev/null, output to a log surfaced on failure.
SHELL_LOG="$CERT_DIR/shell.log"
PA_DIRS=()
for d in _build/test/lib/*/ebin _build/test/lib/roadrunner/test; do
    PA_DIRS+=(-pa "$d")
done

erl -noshell "${PA_DIRS[@]}" -eval "
    {ok, _} = application:ensure_all_started(roadrunner),
    {ok, _} = roadrunner:start_listener(h3spec_listener, #{
        port => $PORT,
        protocols => [http3],
        tls => [
            {certfile, \"$CERT_DIR/cert.pem\"},
            {keyfile, \"$CERT_DIR/key.pem\"}
        ],
        routes => roadrunner_hello_handler
    }),
    Port = roadrunner_listener:port(h3spec_listener),
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
echo "roadrunner h3 listener on https://127.0.0.1:$ACTUAL_PORT (udp, pid $SHELL_PID)" >&2

SKIPS=()
if [ "${H3SPEC_KNOWN_FAILURES:-skip}" != "run" ]; then
    for c in "${KNOWN_FAILURES[@]}"; do
        SKIPS+=(-s "$c")
    done
    echo "skipping ${#KNOWN_FAILURES[@]} known failures" >&2
fi

# `-n` skips cert verification (the cert is self-signed). `|| RC=$?` keeps
# a failing run from tripping `set -e` so the listener is stopped first.
RC=0
"$H3SPEC" 127.0.0.1 "$ACTUAL_PORT" -n "${SKIPS[@]}" "$@" || RC=$?

kill $SHELL_PID 2>/dev/null || true
exit $RC
