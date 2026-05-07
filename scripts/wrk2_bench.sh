#!/usr/bin/env bash
#
# Open-loop tail-latency benchmark using wrk2
# (https://github.com/giltene/wrk2). Drives roadrunner / cowboy / elli
# at a fixed target rate and captures HdrHistogram percentiles
# (p50/p75/p90/p99/p99.9/p99.99/max) corrected for Coordinated
# Omission. Complements `scripts/bench.escript`'s closed-loop matrix.
#
# Step-3 minimal cut: `hello` scenario only, all three servers, one
# hardcoded rate per server (80 % of each server's measured peak from
# `docs/bench_results.md`). Output to stdout. Later steps add more
# scenarios + file output.
#
# Requirements:
#   - docker (we run wrk2 from `cylab/wrk2:latest` to avoid the
#     build-from-source dance on the host — same pattern as
#     `scripts/h2spec.sh`'s use of `summerwind/h2spec`)
#   - rebar3 + the test profile compiled (`rebar3 as test compile`)
#   - The standalone-mode bench.escript (`./scripts/bench.escript --standalone`)
#
# Docker uses `--network=host` so wrk2 inside the container can hit
# the BEAM listener on the host. Linux-only — on macOS/Windows the
# host network is namespaced.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

# Defaults — step-3 cut.
SCENARIO="hello"
SERVERS=(roadrunner cowboy elli)
DURATION_S=30
THREADS=8
CONNS=50

# Per-server target rate for `hello`. From `docs/bench_results.md`
# closed-loop peak × 0.8 (sustainable below saturation):
#   roadrunner 298k × 0.8 ≈ 240k
#   cowboy     179k × 0.8 ≈ 140k
#   elli       278k × 0.8 ≈ 220k
declare -A RATES=(
    ["roadrunner.hello"]=240000
    ["cowboy.hello"]=140000
    ["elli.hello"]=220000
)

WRK2_IMAGE="${WRK2_IMAGE:-cylab/wrk2:latest}"

if ! command -v docker >/dev/null 2>&1; then
    echo "error: docker not on PATH (need it to run $WRK2_IMAGE)" >&2
    exit 1
fi

if [ ! -d "_build/test/lib/roadrunner/ebin" ]; then
    echo "error: missing _build/test/lib/roadrunner/ebin — run" \
        "'rebar3 as test compile' first" >&2
    exit 2
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"; pkill -P $$ || true' EXIT

# Run one (server, scenario) → emit a one-line summary on stdout.
run_one() {
    local server="$1"
    local scenario="$2"
    local rate="${RATES["$server.$scenario"]}"
    local port_file="$WORK_DIR/$server.$scenario.port"
    local std_log="$WORK_DIR/$server.$scenario.standalone.log"
    local wrk_log="$WORK_DIR/$server.$scenario.wrk2.log"

    "$PROJECT_DIR/scripts/bench.escript" --standalone \
        --scenario "$scenario" --servers "$server" \
        --port-file "$port_file" >"$std_log" 2>&1 &
    local std_pid=$!

    # Wait up to 60 s for the port file to populate (cold BEAM start).
    local i
    for i in $(seq 1 120); do
        [ -s "$port_file" ] && break
        sleep 0.5
    done
    if [ ! -s "$port_file" ]; then
        echo "error: $server $scenario standalone listener didn't" \
            "come up — log:" >&2
        cat "$std_log" >&2
        kill "$std_pid" 2>/dev/null || true
        return 1
    fi

    local port path method
    port="$(grep ^PORT= "$port_file" | cut -d= -f2)"
    path="$(grep ^PATH= "$port_file" | cut -d= -f2)"
    method="$(grep ^METHOD= "$port_file" | cut -d= -f2)"

    if [ "$method" != "GET" ]; then
        echo "error: $scenario method=$method needs a Lua script" \
            "(step-4 work)" >&2
        kill "$std_pid" 2>/dev/null || true
        return 1
    fi

    docker run --rm --network=host "$WRK2_IMAGE" \
        -t"$THREADS" -c"$CONNS" -d"${DURATION_S}s" -R"$rate" -L \
        "http://127.0.0.1:$port$path" >"$wrk_log" 2>&1

    kill "$std_pid" 2>/dev/null || true
    wait "$std_pid" 2>/dev/null || true

    parse_and_emit "$server" "$scenario" "$rate" "$wrk_log"
}

# Pull the corrected (Coordinated-Omission-aware) percentiles out of
# wrk2's output. wrk2 prints two HdrHistogram blocks: "Recorded
# Latency" (CO-corrected) and "Service Time" (uncorrected). We want
# the first one.
parse_and_emit() {
    local server="$1" scenario="$2" rate="$3" log="$4"
    local block
    block=$(awk '
        /Latency Distribution \(HdrHistogram - Recorded Latency\)/ {flag=1; next}
        /Detailed Percentile spectrum/ {flag=0}
        flag && /^[[:space:]]*[0-9.]+%/ {print}
    ' "$log")

    # Percentile lines look like: `  50.000%  123.45us`
    local p50 p75 p90 p99 p999 p9999 max
    p50=$(echo "$block" | awk '$1=="50.000%"{print $2}')
    p75=$(echo "$block" | awk '$1=="75.000%"{print $2}')
    p90=$(echo "$block" | awk '$1=="90.000%"{print $2}')
    p99=$(echo "$block" | awk '$1=="99.000%"{print $2}')
    p999=$(echo "$block" | awk '$1=="99.900%"{print $2}')
    p9999=$(echo "$block" | awk '$1=="99.990%"{print $2}')
    max=$(echo "$block" | awk '$1=="100.000%"{print $2}')

    printf "%-12s %-10s %8d %8s %8s %8s %8s %8s %8s %8s\n" \
        "$server" "$scenario" "$rate" \
        "${p50:--}" "${p75:--}" "${p90:--}" "${p99:--}" \
        "${p999:--}" "${p9999:--}" "${max:--}"
}

# Header.
printf "wrk2 open-loop bench — t=%d c=%d d=%ds\n\n" \
    "$THREADS" "$CONNS" "$DURATION_S"
printf "%-12s %-10s %8s %8s %8s %8s %8s %8s %8s %8s\n" \
    "server" "scenario" "rate" \
    "p50" "p75" "p90" "p99" "p99.9" "p99.99" "max"
printf "%-12s %-10s %8s %8s %8s %8s %8s %8s %8s %8s\n" \
    "------" "--------" "----" \
    "---" "---" "---" "---" "-----" "------" "---"

for server in "${SERVERS[@]}"; do
    run_one "$server" "$SCENARIO"
done
