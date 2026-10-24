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
#   chrome   headless Chromium (chromedp/headless-shell), the browser
#            most deployments serve
#
# Each client runs these cases against a transient listener that serves
# files the script writes (`roadrunner_static`) and echoes request bodies
# (`roadrunner_h3_test_handler`):
#
#   small      GET 100 bytes
#   large      GET 5 MB (flow control, congestion control, batched sends)
#   multiplex  50 GETs of different sizes on one connection
#   upload     POST 1 MB and get it echoed back
#
# Chrome loads a page from the listener whose script runs the case with
# `fetch` (the multiplex fetches all start at once) and logs each body's
# SHA-256 plus the protocol of every request (`nextHopProtocol`) to the
# console; the case passes only if the hashes match and every request, the
# page included, went over h3. The upload case first fetches the 1 MB
# file, then POSTs it.
#
# The ngtcp2 client also runs cases quiche-client has no options for:
# updating its keys on demand, steering the handshake with its TLS
# options, and moving to a new address mid-connection.
#
#   keyupdate    GET 5 MB while the client updates its 1-RTT keys early in
#                the transfer (RFC 9001 §6); it passes only if the server's
#                packets switch to the new key phase too
#   chacha20     GET 100 bytes offering only TLS_CHACHA20_POLY1305_SHA256
#   chacha20-ku  keyupdate offering only TLS_CHACHA20_POLY1305_SHA256, so
#                the updated keys are ChaCha20-Poly1305 keys too
#   aes256       GET 100 bytes offering only TLS_AES_256_GCM_SHA384, so the
#                key schedule runs over SHA-384
#   aes256-ku    keyupdate offering only TLS_AES_256_GCM_SHA384, so the
#                updated keys are AES-256-GCM keys from a SHA-384 "quic ku"
#   p256         GET 100 bytes offering only the secp256r1 (P-256) group
#   hrr          GET 100 bytes sending a key share only for X25519MLKEM768,
#                which the server does not support, so the server asks for
#                an x25519 share with a HelloRetryRequest
#   migrate      GET 5 MB while the client moves to a new local port and to
#                a spare connection id of the server's just after the
#                handshake (RFC 9000 §9); it passes only if the server's
#                packets reach the client at its new address
#   rebind       POST 1 MB and get it echoed back while the client's port
#                changes under it as in a NAT rebinding, keeping its
#                connection ids (RFC 9000 §9.3); it passes only if the
#                server's packets reach the client at its new address. An
#                upload, since a client that only receives sends nothing
#                from the new port for the server to see
#   token        GET 100 bytes twice, on two connections: the client keeps
#                the address validation token the server sends with
#                NEW_TOKEN on the first (RFC 9000 §8.1.3) and presents it
#                in the Initial of the second; it passes only if both
#                downloads match and the second Initial carried the token
#   reset        GET 100 bytes with the request held back 3 s after the
#                handshake, while the server is killed and restarted on
#                the same port with the same `secret`: the restarted server
#                has forgotten the connection, so the request draws a
#                stateless reset (RFC 9000 §10.3), and the case passes only
#                if the client recognises it as one
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
# chromedp/headless-shell 156.0.8078.48
CHROME_IMAGE="chromedp/headless-shell@sha256:3da74b0945e4f80f00f0310bcda9f76cee283539ebd200a053a7bebf3de89423"

CLIENT_TIMEOUT="${H3INTEROP_TIMEOUT:-120}"
LOSS="${H3INTEROP_LOSS:-}"

WORK_DIR="$(mktemp -d)"
NETEM=false
SHELL_PID=""
cleanup() {
    # A client killed by `timeout` can leave its container running.
    docker ps -q --filter "label=h3interop=$$" | xargs -r docker rm -f >/dev/null 2>&1 || true
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

# The files the clients download, random bytes so a misplaced or repeated
# chunk cannot match.
WWW="$WORK_DIR/www"
mkdir -p "$WWW"
MULTIPLEX_SIZES=$(seq 20001 20050)
head -c 100 /dev/urandom >"$WWW/100"
head -c 5000000 /dev/urandom >"$WWW/5000000"
for n in $MULTIPLEX_SIZES; do
    head -c "$n" /dev/urandom >"$WWW/$n"
done
UPLOAD="$WWW/upload.bin"
head -c 1000000 /dev/urandom >"$UPLOAD"

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$WORK_DIR/key.pem" \
    -out    "$WORK_DIR/cert.pem" \
    -subj   "/CN=localhost" \
    >/dev/null 2>&1

# Chrome trusts the self-signed cert by the hash of its public key.
CERT_SPKI=$(openssl x509 -in "$WORK_DIR/cert.pem" -pubkey -noout |
    openssl pkey -pubin -outform der |
    openssl dgst -sha256 -binary |
    base64)

# The page Chrome loads. `?case=NAME` picks what its script fetches. It
# logs its report to the console, one `h3interop ...` message per line:
# `sha NAME HEX` per body, `proto PATH PROTOCOL` per request (the page
# included), then `done`, or `error MESSAGE` if a request failed.
cat >"$WWW/chrome.html" <<EOF
<!doctype html>
<meta charset="utf-8">
<title>h3interop</title>
<script>
const multiplex = "$(echo $MULTIPLEX_SIZES)".split(" ");
const report = (line) => console.log("h3interop " + line);
const hex = (buf) =>
    Array.from(new Uint8Array(buf), (b) => b.toString(16).padStart(2, "0")).join("");
async function body(url, init) {
    const resp = await fetch(url, { cache: "no-store", ...init });
    if (!resp.ok) throw new Error(url + " answered " + resp.status);
    return resp.arrayBuffer();
}
async function sha(name, buf) {
    return "sha " + name + " " + hex(await crypto.subtle.digest("SHA-256", buf));
}
const get = async (name) => sha(name, await body("/files/" + name));
const cases = {
    small: () => Promise.all([get("100")]),
    large: () => Promise.all([get("5000000")]),
    multiplex: () => Promise.all(multiplex.map(get)),
    upload: async () => {
        const upload = await body("/files/upload.bin");
        return [await sha("echo", await body("/echo", { method: "POST", body: upload }))];
    },
};
async function run() {
    const lines = await cases[new URLSearchParams(location.search).get("case")]();
    for (const e of performance.getEntries()) {
        // Navigation and resource entries; paint entries have no protocol.
        if (e.nextHopProtocol !== undefined) {
            lines.push("proto " + new URL(e.name).pathname + " " + e.nextHopProtocol);
        }
    }
    return lines;
}
run().then(
    (lines) => { lines.forEach(report); report("done"); },
    (err) => report("error " + err),
);
</script>
EOF

# Start the listener the same way `h2spec.sh` does: `erl -noshell` with
# explicit `-pa`, stdin from /dev/null, output to a log surfaced on failure.
# `$1` is the UDP port to bind (0 for an ephemeral one). The `secret` the
# QUIC keys derive from is fixed for the run, so a restarted listener (the
# reset case) issues the same stateless reset tokens.
PORT_FILE="$WORK_DIR/port"
SHELL_LOG="$WORK_DIR/shell.log"
PA_DIRS=()
for d in _build/test/lib/*/ebin _build/test/lib/roadrunner/test; do
    PA_DIRS+=(-pa "$d")
done
SECRET=$(openssl rand -hex 32)

start_listener() {
    rm -f "$PORT_FILE"
    erl -noshell "${PA_DIRS[@]}" -eval "
        {ok, _} = application:ensure_all_started(roadrunner),
        {ok, _} = roadrunner:start_listener(h3interop_listener, #{
            port => $1,
            protocols => [{http3, #{secret => binary:decode_hex(~\"$SECRET\")}}],
            tls => [
                {certfile, \"$WORK_DIR/cert.pem\"},
                {keyfile, \"$WORK_DIR/key.pem\"}
            ],
            routes => [
                {~\"/files/*path\", roadrunner_static, #{dir => <<\"$WWW\">>}},
                {~\"/echo\", roadrunner_h3_test_handler, undefined}
            ]
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
}

start_listener 0
PORT=$(cat "$PORT_FILE")
BASE="https://127.0.0.1:$PORT"
echo "roadrunner h3 listener on $BASE (udp, pid $SHELL_PID)" >&2

if [ -n "$LOSS" ]; then
    sudo tc qdisc add dev lo root netem loss "${LOSS}%"
    NETEM=true
    echo "loopback packet loss: ${LOSS}%" >&2
fi

case_urls() {
    case "$1" in
        small | token | reset) echo "$BASE/files/100" ;;
        large | keyupdate | chacha20-ku | aes256-ku | migrate) echo "$BASE/files/5000000" ;;
        multiplex) for n in $MULTIPLEX_SIZES; do echo "$BASE/files/$n"; done ;;
        upload | rebind) echo "$BASE/echo" ;;
        chacha20 | aes256 | p256 | hrr) echo "$BASE/files/100" ;;
    esac
}

# Whether the ngtcp2 client logged in `$1` moved: it logs its new local
# address, and a server packet must have reached it there.
migrated() {
    local addr
    addr=$(sed -n 's/^Local address is now \(.*\)$/\1/p' "$1" | tail -1)
    [ -n "$addr" ] && grep -qF "Received packet: local=$addr " "$1"
}

# Whether the ngtcp2 client logged in `$1` got a NEW_TOKEN frame on its first
# connection and sent that token in an Initial of its second, as the qlogs in
# `$2/qlog` show (its packet log leaves the Initial's token out).
token_reused() {
    local token
    token=$(sed -n 's/.* NEW_TOKEN(0x7) token=0x\([0-9a-f]*\) .*/\1/p' "$1" | head -1)
    [ -n "$token" ] &&
        cat "$2"/qlog/*.sqlog | grep '"name":"transport:packet_sent"' |
        grep -q "\"packet_type\":\"initial\",[^}]*\"token\":{\"data\":\"$token\"}"
}

# Whether the ngtcp2 client logged in `$1` took a datagram from the server
# for a stateless reset (RFC 9000 §10.3.1): it logs the token it matched.
was_reset() {
    grep -q "pkt rx .* SR token=" "$1"
}

# Check Chrome's report (`$2/report`): the expected hash for every body,
# and h3 for every request: more requests than bodies (the page itself
# counts) and none on another protocol.
check_chrome() {
    local name=$1 report=$2/report bodies n file
    case "$name" in
        small) bodies=100 ;;
        large) bodies=5000000 ;;
        multiplex) bodies=$MULTIPLEX_SIZES ;;
        upload) bodies=echo ;;
    esac
    grep -qx done "$report" || return 1
    for n in $bodies; do
        file=$WWW/$n
        [ "$n" = echo ] && file=$UPLOAD
        grep -qx "sha $n $(sha256sum "$file" | cut -d' ' -f1)" "$report" || return 1
    done
    # shellcheck disable=SC2086
    [ "$(grep -c '^proto ' "$report")" -gt "$(echo $bodies | wc -w)" ] &&
        ! grep '^proto ' "$report" | grep -qv ' h3$'
}

# Check a case's downloads in `$2`; quiche and ngtcp2 name each response file
# after the last segment of its URL path. The key update cases also need a
# server packet in key phase 1 in the client's packet log (`$2.log`), and
# the migration cases a server packet at the client's new address there.
check_case() {
    local client=$1 name=$2 dir=$3
    [ "$client" = chrome ] && {
        check_chrome "$name" "$dir"
        return
    }
    case "$name" in
        small | chacha20 | aes256 | p256 | hrr) cmp -s "$WWW/100" "$dir/100" ;;
        large) cmp -s "$WWW/5000000" "$dir/5000000" ;;
        keyupdate | chacha20-ku | aes256-ku)
            cmp -s "$WWW/5000000" "$dir/5000000" &&
                grep -q "pkt rx .* type=1RTT k=1" "$dir.log"
            ;;
        multiplex)
            for n in $MULTIPLEX_SIZES; do
                cmp -s "$WWW/$n" "$dir/$n" || return 1
            done
            ;;
        upload) cmp -s "$UPLOAD" "$dir/echo" ;;
        migrate) cmp -s "$WWW/5000000" "$dir/5000000" && migrated "$dir.log" ;;
        rebind) cmp -s "$UPLOAD" "$dir/echo" && migrated "$dir.log" ;;
        token) cmp -s "$WWW/100" "$dir/100" && token_reused "$dir.log" "$dir" ;;
        reset) was_reset "$dir.log" ;;
    esac
}

# Run one client for one case, downloading into `$3` (mounted as /out).
run_quiche() {
    local name=$1 dir=$2
    local body=()
    [ "$name" = upload ] && body=(--method POST --body /in/www/upload.bin)
    # shellcheck disable=SC2046
    timeout "$CLIENT_TIMEOUT" docker run --rm --init --label "h3interop=$$" --network host \
        --user "$(id -u):$(id -g)" -v "$dir:/out" -v "$WORK_DIR:/in:ro" \
        "$QUICHE_IMAGE" quiche-client --no-verify "${body[@]}" \
        --dump-responses /out $(case_urls "$name")
}

run_ngtcp2() {
    local name=$1 dir=$2
    local opts="-q"
    case "$name" in
        upload) opts="-q -d /in/www/upload.bin" ;;
        # Update the keys 1 ms after the handshake, while the download is
        # under way, and log every packet so check_case can see the key
        # phase the server answers in.
        keyupdate) opts="--key-update=1ms" ;;
        chacha20) opts="-q --ciphers=TLS_CHACHA20_POLY1305_SHA256" ;;
        chacha20-ku) opts="--ciphers=TLS_CHACHA20_POLY1305_SHA256 --key-update=1ms" ;;
        aes256) opts="-q --ciphers=TLS_AES_256_GCM_SHA384" ;;
        aes256-ku) opts="--ciphers=TLS_AES_256_GCM_SHA384 --key-update=1ms" ;;
        p256) opts="-q --groups=P-256" ;;
        hrr) opts="-q --groups=X25519MLKEM768:X25519" ;;
        # Move 1 ms after the handshake, logging every packet so check_case
        # can see where the server's packets arrive.
        migrate) opts="--change-local-addr=1ms" ;;
        rebind) opts="-d /in/www/upload.bin --change-local-addr=1ms --nat-rebinding" ;;
        # Hold the request back while the listener restarts (restart_listener
        # runs alongside), logging every packet so check_case can see the
        # reset.
        reset) opts="--delay-stream=3s" ;;
        # Keep the token in a file both connections share, logging every
        # frame and a qlog per connection so check_case can follow the token.
        token) opts="--token-file=/out/token --qlog-dir=/out/qlog" ;;
    esac
    # The token case connects twice, the second time with the token the first
    # connection was given.
    local setup=":" second=":"
    if [ "$name" = token ]; then
        setup="mkdir -p /out/qlog"
        second="\$client"
    fi
    # The client fails its handshake when run as a non-root user, so it runs
    # as root and hands the downloads back afterwards.
    timeout "$CLIENT_TIMEOUT" docker run --rm --init --label "h3interop=$$" --network host \
        -v "$dir:/out" -v "$WORK_DIR:/in:ro" --entrypoint sh "$NGTCP2_IMAGE" -c "
            client=\"/usr/local/bin/wsslclient 127.0.0.1 $PORT $(case_urls "$name" | tr '\n' ' ') \
                $opts --download /out --exit-on-all-streams-close \
                --no-quic-dump --no-http-dump\"
            $setup && \$client && $second
            rc=\$?
            chown -R $(id -u):$(id -g) /out
            exit \$rc"
}

# Kill the listener's node outright, so no connection says goodbye, once a
# client has had time to connect, and start another on the same port with the
# same secret.
restart_listener() {
    sleep 1
    kill -9 "$SHELL_PID"
    wait "$SHELL_PID" 2>/dev/null || true
    start_listener "$PORT"
}

# Chrome logs the page's console to stderr. Read its log until the report
# ends (`done` or `error`), keeping the report lines in `$2/report`, then
# remove the container: the browser keeps running after the page is done.
# `--origin-to-force-quic-on` makes it use QUIC from the first request,
# without waiting for an Alt-Svc header. It runs as the calling user and
# writes nothing to the host.
run_chrome() {
    local name=$1 dir=$2 cid line msg
    cid=$(docker run -d --rm --init --label "h3interop=$$" --network host \
        --user "$(id -u):$(id -g)" -e HOME=/tmp \
        --entrypoint /headless-shell/headless-shell "$CHROME_IMAGE" \
        --no-sandbox --user-data-dir=/tmp/profile --enable-logging=stderr \
        --origin-to-force-quic-on="127.0.0.1:$PORT" \
        --ignore-certificate-errors-spki-list="$CERT_SPKI" \
        "$BASE/files/chrome.html?case=$name")
    while IFS= read -r line; do
        echo "$line"
        case "$line" in
            *CONSOLE*'"h3interop '*)
                msg=${line#*\"h3interop }
                msg=${msg%%\", source: *}
                echo "$msg" >>"$dir/report"
                case "$msg" in done | error*) break ;; esac
                ;;
        esac
    done < <(timeout "$CLIENT_TIMEOUT" docker logs -f "$cid" 2>&1)
    docker rm -f "$cid" >/dev/null
}

# The cases each client runs.
client_cases() {
    case "$1" in
        quiche) echo small large multiplex upload ;;
        ngtcp2) echo small large multiplex upload keyupdate chacha20 chacha20-ku aes256 aes256-ku p256 hrr migrate rebind token reset ;;
        chrome) echo small large multiplex upload ;;
    esac
}

FAILED=0
printf '%-8s %-12s %s\n' client case result
for client in quiche ngtcp2 chrome; do
    for name in $(client_cases "$client"); do
        dir="$WORK_DIR/$client/$name"
        mkdir -p "$dir"
        log="$dir.log"
        ran=false
        if [ "$name" = reset ]; then
            # The client ends in an error once reset, so only the check
            # counts.
            "run_$client" "$name" "$dir" >"$log" 2>&1 &
            run_pid=$!
            restart_listener
            wait "$run_pid" || true
            ran=true
        elif "run_$client" "$name" "$dir" >"$log" 2>&1; then
            ran=true
        fi
        if [ "$ran" = true ] && check_case "$client" "$name" "$dir"; then
            result=pass
        else
            result=FAIL
            FAILED=1
        fi
        printf '%-8s %-12s %s\n' "$client" "$name" "$result"
        if [ "$result" = FAIL ]; then
            echo "---- $client $name output (last 20 lines)" >&2
            tail -20 "$log" >&2
            echo "----" >&2
        fi
    done
done

exit $FAILED
