#!/usr/bin/env bash
#
# Drive a roadrunner HTTP/3 listener with independent QUIC clients.
#
# The CT suites talk to the server through roadrunner's own QUIC test
# client, which shares the server's codecs and TLS code, so a bug both
# sides share passes them. This script runs real clients from other QUIC
# stacks instead and checks every byte they get back:
#
#   quiche   Cloudflare's quiche-client (Rust, BoringSSL)
#   ngtcp2   ngtcp2's client on nghttp3 and wolfSSL (C)
#
# Each client runs these cases against a transient listener serving
# `roadrunner_h3_interop_handler`:
#
#   small      GET 100 bytes
#   large      GET 5 MB (flow control, congestion control, batched sends)
#   multiplex  50 GETs of different sizes on one connection
#   upload     POST 1 MB and get it echoed back
#
# Requirements:
#   - docker (the client images are pulled on first run)
#   - mise (or rebar3 + erl on PATH)
#   - openssl (for the throwaway test cert)
#
# Usage:
#   ./scripts/h3interop.sh                   # every client, every case
#   H3INTEROP_LOSS=5 ./scripts/h3interop.sh  # with 5% loopback packet loss
#
# `H3INTEROP_LOSS` adds a netem qdisc to `lo` for the run (removed on
# exit), so it needs passwordless sudo and touches every process on the
# host's loopback: meant for CI.
#
# Exit codes:
#   0  — every client passed every case
#   1  — a case failed
#   2  — setup failed (missing build, listener didn't start)

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

QUICHE_IMAGE="cloudflare/quiche@sha256:25e0f78b133bc11a098ccd70f3ad44d8ac866e269db2f4683e596049b0d4419f"
NGTCP2_IMAGE="ghcr.io/ngtcp2/ngtcp2-interop@sha256:272308234be3086f08154b556137aa0220ca7aefc68af238cbaab3e9a842b510"

CLIENT_TIMEOUT="${H3INTEROP_TIMEOUT:-120}"
LOSS="${H3INTEROP_LOSS:-}"

WORK_DIR="$(mktemp -d)"
NETEM=false
SHELL_PID=""
cleanup() {
    if [ "$NETEM" = true ]; then
        sudo tc qdisc del dev lo root || true
    fi
    if [ -n "$SHELL_PID" ]; then
        kill "$SHELL_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

if [ ! -d "_build/test/lib/roadrunner/ebin" ]; then
    echo "missing _build/test/lib/roadrunner/ebin — run 'rebar3 as test compile' first" >&2
    exit 2
fi

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$WORK_DIR/key.pem" \
    -out    "$WORK_DIR/cert.pem" \
    -subj   "/CN=localhost" \
    >/dev/null 2>&1

# Start the listener the same way `h2spec.sh` does: `erl -noshell` with
# explicit `-pa`, stdin from /dev/null, output to a log surfaced on failure.
PORT_FILE="$WORK_DIR/port"
SHELL_LOG="$WORK_DIR/shell.log"
PA_DIRS=()
for d in _build/test/lib/*/ebin _build/test/lib/roadrunner/test; do
    PA_DIRS+=(-pa "$d")
done

erl -noshell "${PA_DIRS[@]}" -eval "
    {ok, _} = application:ensure_all_started(roadrunner),
    {ok, _} = roadrunner:start_listener(h3interop_listener, #{
        port => 0,
        protocols => [http3],
        tls => [
            {certfile, \"$WORK_DIR/cert.pem\"},
            {keyfile, \"$WORK_DIR/key.pem\"}
        ],
        routes => roadrunner_h3_interop_handler
    }),
    Port = roadrunner_listener:port(h3interop_listener),
    file:write_file(\"$PORT_FILE\", integer_to_binary(Port)),
    receive _ -> ok end.
" </dev/null >"$SHELL_LOG" 2>&1 &
SHELL_PID=$!

for _ in $(seq 1 120); do
    [ -s "$PORT_FILE" ] && break
    sleep 0.5
done

if [ ! -s "$PORT_FILE" ]; then
    echo "roadrunner listener didn't come up — shell stdout follows:" >&2
    echo "----" >&2
    cat "$SHELL_LOG" >&2
    echo "----" >&2
    exit 2
fi

PORT=$(cat "$PORT_FILE")
BASE="https://127.0.0.1:$PORT"
echo "roadrunner h3 listener on $BASE (udp, pid $SHELL_PID)" >&2

if [ -n "$LOSS" ]; then
    sudo tc qdisc add dev lo root netem loss "${LOSS}%"
    NETEM=true
    echo "loopback packet loss: ${LOSS}%" >&2
fi

UPLOAD="$WORK_DIR/upload.bin"
head -c 1000000 /dev/urandom >"$UPLOAD"
MULTIPLEX_SIZES=$(seq 20001 20050)

# The body `/bytes/N` serves: N bytes of the repeating pattern.
pattern() {
    head -c "$1" < <(yes 0123456789abcdef | tr -d '\n')
}

case_urls() {
    case "$1" in
        small) echo "$BASE/bytes/100" ;;
        large) echo "$BASE/bytes/5000000" ;;
        multiplex) for n in $MULTIPLEX_SIZES; do echo "$BASE/bytes/$n"; done ;;
        upload) echo "$BASE/echo" ;;
    esac
}

# Check a case's downloads in `$2`; both clients name each response file
# after the last segment of its URL path.
check_case() {
    local name=$1 dir=$2
    case "$name" in
        small) pattern 100 | cmp -s - "$dir/100" ;;
        large) pattern 5000000 | cmp -s - "$dir/5000000" ;;
        multiplex)
            for n in $MULTIPLEX_SIZES; do
                pattern "$n" | cmp -s - "$dir/$n" || return 1
            done
            ;;
        upload) cmp -s "$UPLOAD" "$dir/echo" ;;
    esac
}

# Run one client for one case, downloading into `$3` (mounted as /out).
run_quiche() {
    local name=$1 dir=$2
    local body=()
    [ "$name" = upload ] && body=(--method POST --body /in/upload.bin)
    # shellcheck disable=SC2046
    timeout "$CLIENT_TIMEOUT" docker run --rm --network host \
        --user "$(id -u):$(id -g)" -v "$dir:/out" -v "$WORK_DIR:/in:ro" \
        "$QUICHE_IMAGE" quiche-client --no-verify "${body[@]}" \
        --dump-responses /out $(case_urls "$name")
}

run_ngtcp2() {
    local name=$1 dir=$2
    local body=""
    [ "$name" = upload ] && body="-d /in/upload.bin"
    # The client fails its handshake when run as a non-root user, so it runs
    # as root and hands the downloads back afterwards.
    timeout "$CLIENT_TIMEOUT" docker run --rm --network host \
        -v "$dir:/out" -v "$WORK_DIR:/in:ro" --entrypoint sh "$NGTCP2_IMAGE" -c "
            /usr/local/bin/wsslclient 127.0.0.1 $PORT $(case_urls "$name" | tr '\n' ' ') \
                $body --download /out --exit-on-all-streams-close \
                -q --no-quic-dump --no-http-dump
            rc=\$?
            chown -R $(id -u):$(id -g) /out
            exit \$rc"
}

FAILED=0
printf '%-8s %-10s %s\n' client case result
for client in quiche ngtcp2; do
    for name in small large multiplex upload; do
        dir="$WORK_DIR/$client/$name"
        mkdir -p "$dir"
        log="$dir.log"
        if "run_$client" "$name" "$dir" >"$log" 2>&1 && check_case "$name" "$dir"; then
            result=pass
        else
            result=FAIL
            FAILED=1
        fi
        printf '%-8s %-10s %s\n' "$client" "$name" "$result"
        if [ "$result" = FAIL ]; then
            echo "---- $client $name output (last 20 lines)" >&2
            tail -20 "$log" >&2
            echo "----" >&2
        fi
    done
done

exit $FAILED
