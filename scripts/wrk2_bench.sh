#!/usr/bin/env bash
#
# Open-loop tail-latency benchmark using wrk2
# (https://github.com/giltene/wrk2). Drives roadrunner / cowboy /
# elli at fixed target rates and captures HdrHistogram percentiles
# (p50/p75/p90/p99/p99.9/p99.99/max) corrected for Coordinated
# Omission. Complements `scripts/bench.escript`'s closed-loop matrix.
#
# Per-(scenario, server), the script sweeps FOUR rates set at 50%,
# 75%, 90%, and 95% of each server's measured peak from
# `docs/bench_results.md` (the PEAK_ESTIMATE table below). 90 % is
# where the elbow usually sits; 95 % typically saturates. The
# achieved rate is reported next to the target — when achieved/
# target < 0.99 the row is tagged `(saturated)`. Median across N
# runs (default 3) per data point.
#
# For each measurement, wrk2 runs with both `--latency` (Coordinated-
# Omission CORRECTED histogram) and `--u_latency` (UNCORRECTED, i.e.
# what a closed-loop tool would have reported). Both are parsed and
# emitted side-by-side so the reader can see the size of the
# coordinated-omission gap directly instead of taking our word for
# it.
#
# Connection-shape scenarios (pipelined_h1, slow_client,
# connection_storm, mixed_workload, accept_storm_burst,
# server_sent_events) are intentionally absent — wrk2's `-c50`
# keep-alive shape can't reproduce their wire patterns. h2-only
# scenarios are absent too (wrk2 is HTTP/1.1).
#
# Requirements:
#   - docker (for cylab/wrk2 image — same pattern as h2spec.sh)
#   - rebar3 + the test profile compiled (`rebar3 as test compile`)
#   - The standalone-mode bench.escript (`./scripts/bench.escript --standalone`)
#
# Docker uses `--network=host` so wrk2 inside the container can hit
# the BEAM listener on the host. Linux-only.
#
# Usage:
#   ./scripts/wrk2_bench.sh                     # full matrix
#   ./scripts/wrk2_bench.sh --quick             # --runs 1, dev iteration
#   ./scripts/wrk2_bench.sh --scenario hello    # one scenario only
#   ./scripts/wrk2_bench.sh --server roadrunner # one server only
#   ./scripts/wrk2_bench.sh --runs 5 --duration 90
#   ./scripts/wrk2_bench.sh --out /tmp/wrk2.md

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

# Defaults.
SCENARIO=""
SERVER_FILTER=""
RUNS=3
DURATION_S=60
THREADS=8
CONNS=50
OUT="docs/wrk2_results.md"
WRK2_IMAGE="${WRK2_IMAGE:-cylab/wrk2:latest}"

# Parse args.
while [ $# -gt 0 ]; do
    case "$1" in
        --scenario)   SCENARIO="$2"; shift 2 ;;
        --server)     SERVER_FILTER="$2"; shift 2 ;;
        --servers)    SERVER_FILTER="$2"; shift 2 ;;
        --runs)       RUNS="$2"; shift 2 ;;
        --duration)   DURATION_S="$2"; shift 2 ;;
        --out)        OUT="$2"; shift 2 ;;
        --quick)      RUNS=1; shift ;;
        -h|--help)
            sed -n '2,/^set/p' "$0" | sed 's/^# \{0,1\}//; /^set/d'
            exit 0 ;;
        *)
            echo "unknown arg: $1" >&2
            exit 2 ;;
    esac
done

# Scenarios in the matrix. Order matches docs/bench_results.md so the
# wrk2 report skims left-to-right alongside the closed-loop one.
SCENARIOS_ALL=(
    hello json echo headers_heavy large_response
    url_with_qs path_with_unicode cors_preflight redirect_response
    head_method post_4kb_form chunked_request_body
    compressed_request_body multi_request_body large_post_streaming
    cookies_heavy etag_304 large_keepalive_session
    gzip_response backpressure_sustained
)

# Scenarios elli doesn't support (mirrors `preflight_scenario/1` in
# bench.escript at lines 84-138). For these, the elli row is skipped
# and the table shows only roadrunner + cowboy.
ELLI_UNSUPPORTED=(
    url_with_qs path_with_unicode cors_preflight redirect_response
    head_method post_4kb_form chunked_request_body
    large_post_streaming cookies_heavy etag_304
    gzip_response backpressure_sustained
)

# Lua scripts for non-GET scenarios. Run via Docker volume mount.
declare -A LUA_FILE=(
    [echo]=echo.lua
    [multi_request_body]=multi_request_body.lua
    [large_post_streaming]=large_post_streaming.lua
    [post_4kb_form]=post_4kb_form.lua
    [compressed_request_body]=compressed_request_body.lua
    [cors_preflight]=cors_preflight.lua
    [chunked_request_body]=chunked_request_body.lua
    [head_method]=head_method.lua
)

# Custom request headers for GET-with-headers scenarios. Multiple
# headers separated by `|`. Empty for plain GET / GET-with-qs.
declare -A EXTRA_HEADERS=(
    [json]="Accept: application/json"
    [gzip_response]="Accept-Encoding: gzip"
    [etag_304]='If-None-Match: "v1"'
    [headers_heavy]="x-bench-1: 1|x-bench-2: 22|x-bench-3: 333|x-bench-4: 4444|x-bench-5: 55555|x-bench-6: 666666|x-bench-7: 7777777|x-bench-8: 88888888|x-bench-9: 999999999|x-bench-10: aaaaaaaaaa|x-bench-11: bbbbbbbbbbb|x-bench-12: cccccccccccc|x-bench-13: ddddddddddddd|x-bench-14: eeeeeeeeeeeeee|x-bench-15: fffffffffffffff|x-bench-16: gggggggggggggggg"
)

# Per-(server, scenario) PEAK ESTIMATE in req/s. Pulled from
# `docs/bench_results.md` (h1 section). The script sweeps at 50%,
# 75%, 95% of these. Estimates can drift with code changes; the
# achieved-rate column makes the gap visible.
declare -A PEAK=(
    [roadrunner.hello]=254000           [cowboy.hello]=181000           [elli.hello]=272000
    [roadrunner.json]=255000            [cowboy.json]=178000            [elli.json]=270000
    [roadrunner.echo]=225000            [cowboy.echo]=146000            [elli.echo]=269000
    [roadrunner.headers_heavy]=210000   [cowboy.headers_heavy]=125000   [elli.headers_heavy]=240000
    [roadrunner.large_response]=103000  [cowboy.large_response]=90000   [elli.large_response]=114000
    [roadrunner.url_with_qs]=247000     [cowboy.url_with_qs]=167000
    [roadrunner.path_with_unicode]=235000 [cowboy.path_with_unicode]=167000
    [roadrunner.cors_preflight]=242000  [cowboy.cors_preflight]=162000
    [roadrunner.redirect_response]=258000 [cowboy.redirect_response]=176000
    [roadrunner.head_method]=251000     [cowboy.head_method]=176000
    [roadrunner.post_4kb_form]=122000   [cowboy.post_4kb_form]=92000
    [roadrunner.chunked_request_body]=210000 [cowboy.chunked_request_body]=129000
    [roadrunner.compressed_request_body]=233000 [cowboy.compressed_request_body]=149000 [elli.compressed_request_body]=278000
    [roadrunner.multi_request_body]=225000 [cowboy.multi_request_body]=111000 [elli.multi_request_body]=245000
    [roadrunner.large_post_streaming]=15000 [cowboy.large_post_streaming]=6600
    [roadrunner.cookies_heavy]=234000   [cowboy.cookies_heavy]=160000
    [roadrunner.etag_304]=234000        [cowboy.etag_304]=169000
    [roadrunner.large_keepalive_session]=227000 [cowboy.large_keepalive_session]=175000 [elli.large_keepalive_session]=279000
    [roadrunner.gzip_response]=105000   [cowboy.gzip_response]=96000
    [roadrunner.backpressure_sustained]=249000 [cowboy.backpressure_sustained]=182000
)

# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------

contains() {
    # contains <needle> <haystack...>
    local needle="$1"; shift
    local item
    for item in "$@"; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

# Sanity checks.
command -v docker >/dev/null 2>&1 || {
    echo "error: docker not on PATH (need it to run $WRK2_IMAGE)" >&2
    exit 1
}

[ -d "_build/test/lib/roadrunner/ebin" ] || {
    echo "error: missing _build/test/lib/roadrunner/ebin —" \
         "run 'rebar3 as test compile' first" >&2
    exit 2
}

# Optional filters.
if [ -n "$SCENARIO" ]; then
    contains "$SCENARIO" "${SCENARIOS_ALL[@]}" || {
        echo "error: unknown scenario '$SCENARIO'" >&2
        exit 2
    }
    SCENARIOS=("$SCENARIO")
else
    SCENARIOS=("${SCENARIOS_ALL[@]}")
fi

if [ -n "$SERVER_FILTER" ]; then
    IFS=',' read -ra SERVERS_REQUESTED <<< "$SERVER_FILTER"
else
    SERVERS_REQUESTED=(roadrunner cowboy elli)
fi

# Working dirs.
WORK_DIR="$(mktemp -d)"
PER_RUN_LOG_DIR="/tmp/wrk2"
mkdir -p "$PER_RUN_LOG_DIR"
trap 'rm -rf "$WORK_DIR"; pkill -P $$ || true' EXIT

# All collected rows. Tab-separated:
#   scenario \t server \t target \t achieved \t saturated \t p50 \t p75 \t p90 \t p99 \t p99_9 \t p99_99 \t max
ROWS_FILE="$WORK_DIR/rows.tsv"
: > "$ROWS_FILE"

# ---------------------------------------------------------------------------
# Per-(server, scenario, rate, run): start standalone listener, run
# wrk2, parse output, kill.
# ---------------------------------------------------------------------------

start_standalone() {
    # args: server scenario port_file_path
    local server="$1" scenario="$2" port_file="$3"
    "$PROJECT_DIR/scripts/bench.escript" --standalone \
        --scenario "$scenario" --servers "$server" \
        --port-file "$port_file" >"$WORK_DIR/$server.$scenario.standalone.log" 2>&1 &
    STANDALONE_PID=$!
    local i
    for i in $(seq 1 120); do
        [ -s "$port_file" ] && return 0
        sleep 0.5
    done
    echo "error: $server $scenario standalone listener didn't" \
         "come up (60s timeout) — log:" >&2
    cat "$WORK_DIR/$server.$scenario.standalone.log" >&2
    kill "$STANDALONE_PID" 2>/dev/null || true
    return 1
}

stop_standalone() {
    [ -n "${STANDALONE_PID:-}" ] || return 0
    kill "$STANDALONE_PID" 2>/dev/null || true
    wait "$STANDALONE_PID" 2>/dev/null || true
    STANDALONE_PID=""
}

build_wrk2_args() {
    # args: scenario port path
    # echoes the wrk2 invocation flags AFTER `-Rrate -dDURATIONs`:
    #   [-s /lua/<file>] [-H "h1"]... -L <url>
    local scenario="$1" port="$2" path="$3"
    local args=()
    if [ -n "${LUA_FILE[$scenario]:-}" ]; then
        args+=("-s" "/lua/${LUA_FILE[$scenario]}")
    fi
    if [ -n "${EXTRA_HEADERS[$scenario]:-}" ]; then
        local IFS='|'
        for h in ${EXTRA_HEADERS[$scenario]}; do
            args+=("-H" "$h")
        done
    fi
    args+=("-L" "http://127.0.0.1:$port$path")
    printf '%s\n' "${args[@]}"
}

parse_wrk2_log() {
    # args: log_file
    # echoes (tab-separated, single line, 15 fields):
    #   achieved
    #   c_p50 c_p75 c_p90 c_p99 c_p999 c_p9999 c_max     (CO-corrected, "Recorded Latency")
    #   u_p50 u_p75 u_p90 u_p99 u_p999 u_p9999 u_max     (uncorrected, "Service Time")
    # Achieved is the floating-point Requests/sec from wrk2's footer.
    # Percentile values are wrk2's formatted strings (e.g. "1.23ms",
    # "456us"). When `--u_latency` is enabled wrk2 prints two
    # HdrHistogram blocks back-to-back; we parse both.
    local log="$1"
    local achieved
    achieved=$(awk '/^Requests\/sec:/{print $2}' "$log")

    extract_block() {
        # args: log_file block_marker
        # echoes the percentile lines (e.g. " 50.000%  123.45us") of
        # the named HdrHistogram block.
        local lf="$1" marker="$2"
        awk -v marker="$marker" '
            $0 ~ marker {flag=1; next}
            /Detailed Percentile spectrum/ {flag=0}
            flag && /^[[:space:]]*[0-9.]+%/ {print}
        ' "$lf"
    }

    pick() {
        # args: block percentile_label (e.g. "50.000%")
        echo "$1" | awk -v p="$2" '$1==p{print $2}'
    }

    local c_block u_block
    c_block=$(extract_block "$log" "Recorded Latency")
    u_block=$(extract_block "$log" "Uncorrected Latency")

    # Fall back to "-" if a block was missing (e.g. older wrk2
    # without --u_latency support).
    local c_p50 c_p75 c_p90 c_p99 c_p999 c_p9999 c_max
    c_p50=$(pick "$c_block" "50.000%")
    c_p75=$(pick "$c_block" "75.000%")
    c_p90=$(pick "$c_block" "90.000%")
    c_p99=$(pick "$c_block" "99.000%")
    c_p999=$(pick "$c_block" "99.900%")
    c_p9999=$(pick "$c_block" "99.990%")
    c_max=$(pick "$c_block" "100.000%")

    local u_p50 u_p75 u_p90 u_p99 u_p999 u_p9999 u_max
    u_p50=$(pick "$u_block" "50.000%")
    u_p75=$(pick "$u_block" "75.000%")
    u_p90=$(pick "$u_block" "90.000%")
    u_p99=$(pick "$u_block" "99.000%")
    u_p999=$(pick "$u_block" "99.900%")
    u_p9999=$(pick "$u_block" "99.990%")
    u_max=$(pick "$u_block" "100.000%")

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${achieved:--}" \
        "${c_p50:--}" "${c_p75:--}" "${c_p90:--}" "${c_p99:--}" "${c_p999:--}" "${c_p9999:--}" "${c_max:--}" \
        "${u_p50:--}" "${u_p75:--}" "${u_p90:--}" "${u_p99:--}" "${u_p999:--}" "${u_p9999:--}" "${u_max:--}"
}

# Convert a wrk2 latency string ("123us", "1.23ms", "0.45s") into
# microseconds (numeric, for sorting). "-" → 0.
to_us() {
    local s="$1"
    [ "$s" = "-" ] && { echo 0; return; }
    if [[ "$s" == *us ]]; then
        echo "${s%us}" | awk '{printf "%.3f\n", $1}'
    elif [[ "$s" == *ms ]]; then
        echo "${s%ms}" | awk '{printf "%.3f\n", $1*1000}'
    elif [[ "$s" == *s ]]; then
        echo "${s%s}" | awk '{printf "%.3f\n", $1*1000000}'
    else
        echo 0
    fi
}

# Median of N values (one per line). For N=1 returns the value;
# N=3 returns the middle. Tie-break: sort lexicographically after
# numeric sort so identical rounded values keep stable order.
median_of() {
    local n
    n=$(wc -l)
    awk -v n="$n" '
        { v[NR] = $0 }
        END {
            asort(v)
            mid = int((n + 1) / 2)
            print v[mid]
        }
    '
}

# Take N tab-separated rows on stdin (15 fields: achieved + 7
# corrected percentiles + 7 uncorrected), one per run, and emit the
# per-column median row. N is counted from the actual rows present
# (not `$RUNS`) so a partial run (one of three failed) still produces
# a valid median over the rows that did succeed.
median_row() {
    local rows
    rows=$(cat)
    local n
    n=$(printf '%s\n' "$rows" | grep -c '^.' || true)
    [ "$n" -eq 0 ] && return
    local cols=15
    local i out=""
    for i in $(seq 1 $cols); do
        local val
        val=$(echo "$rows" | awk -F'\t' -v c="$i" '{print $c}' \
              | while read -r raw; do
                    if [ "$i" -eq 1 ]; then
                        # achieved: numeric req/s; sort numerically
                        echo "$raw"
                    else
                        # latency string; emit "us value\tstring" so
                        # sort puts them in numeric order
                        printf '%s\t%s\n' "$(to_us "$raw")" "$raw"
                    fi
                done | {
                    if [ "$i" -eq 1 ]; then
                        sort -n | awk -v n="$n" 'NR==int((n+1)/2)'
                    else
                        sort -n | awk -v n="$n" -F'\t' \
                            'NR==int((n+1)/2){print $2}'
                    fi
                })
        if [ -z "$out" ]; then out="$val"; else out="$out	$val"; fi
    done
    echo "$out"
}

# ---------------------------------------------------------------------------
# Main loop.
# ---------------------------------------------------------------------------

# Prefix log lines with a timestamp so a multi-hour run is easy to
# eyeball.
ts() { date +'%H:%M:%S'; }

echo "[$(ts)] wrk2 open-loop bench: scenarios=${#SCENARIOS[@]}" \
     "servers=${SERVERS_REQUESTED[*]} runs=$RUNS dur=${DURATION_S}s" \
     "threads=$THREADS conns=$CONNS"

for scenario in "${SCENARIOS[@]}"; do
    # Determine which servers are eligible for this scenario.
    SERVERS_HERE=()
    for s in "${SERVERS_REQUESTED[@]}"; do
        if [ "$s" = "elli" ] && contains "$scenario" "${ELLI_UNSUPPORTED[@]}"; then
            continue
        fi
        SERVERS_HERE+=("$s")
    done

    for server in "${SERVERS_HERE[@]}"; do
        peak="${PEAK[$server.$scenario]:-}"
        if [ -z "$peak" ]; then
            echo "[$(ts)] $scenario $server: no peak estimate, skipping"
            continue
        fi

        for pct in 50 75 90 95; do
            target=$((peak * pct / 100))
            label="$scenario / $server @ ${pct}% (${target} req/s)"
            echo "[$(ts)] $label"

            # Drop stale logs from prior runs (e.g. a previous
            # `--runs 5` invocation leaves run-4 / run-5 files that
            # don't belong to this run's `--runs N`). Easier than
            # reasoning about which iteration produced which file.
            run_log_dir="$PER_RUN_LOG_DIR/$scenario/$server/$pct"
            mkdir -p "$run_log_dir"
            rm -f "$run_log_dir"/run-*.log

            # N runs, collect rows.
            run_rows=""
            for run in $(seq 1 "$RUNS"); do
                port_file="$WORK_DIR/$server.$scenario.$pct.$run.port"
                rm -f "$port_file"
                if ! start_standalone "$server" "$scenario" "$port_file"; then
                    echo "[$(ts)]   run $run: standalone failed, skipping rate"
                    stop_standalone
                    break
                fi
                port=$(grep ^PORT= "$port_file" | cut -d= -f2)
                path=$(grep ^PATH= "$port_file" | cut -d= -f2)
                wrk_args=()
                while IFS= read -r a; do wrk_args+=("$a"); done \
                    < <(build_wrk2_args "$scenario" "$port" "$path")

                run_log="$run_log_dir/run-$run.log"

                # `--latency` prints the CO-corrected (Recorded
                # Latency) HdrHistogram; `--u_latency` adds the
                # uncorrected (Service Time) one. Both are parsed
                # so the report can show them side-by-side.
                docker run --rm --network=host \
                    -v "$PROJECT_DIR/scripts/wrk2_lua:/lua:ro" \
                    "$WRK2_IMAGE" \
                    -t"$THREADS" -c"$CONNS" -d"${DURATION_S}s" \
                    -R"$target" --latency --u_latency \
                    "${wrk_args[@]}" \
                    >"$run_log" 2>&1

                stop_standalone

                row=$(parse_wrk2_log "$run_log")
                run_rows="${run_rows}${row}"$'\n'
                # Print a one-line summary: achieved + corrected p99
                # + uncorrected p99 so the live log is scannable.
                short=$(echo "$row" | awk -F'\t' \
                    '{printf "ach=%s c_p99=%s u_p99=%s c_p99.9=%s", $1, $5, $12, $6}')
                echo "[$(ts)]   run $run: $short"
            done

            if [ -z "$run_rows" ]; then
                continue
            fi

            # Median across runs (per metric).
            median=$(printf '%s' "$run_rows" | grep -v '^$' | median_row)
            achieved=$(echo "$median" | awk -F'\t' '{print $1}')
            # Saturated when achieved/target < 0.99.
            saturated="no"
            if [ -n "$achieved" ] && [ "$achieved" != "-" ]; then
                ratio=$(awk -v a="$achieved" -v t="$target" \
                    'BEGIN{printf "%.3f", a/t}')
                # bc-free comparison via awk
                if awk -v r="$ratio" 'BEGIN{exit !(r<0.99)}'; then
                    saturated="yes"
                fi
            fi
            printf '%s\t%s\t%s\t%s\n' \
                "$scenario" "$server" "$target" "$saturated" >> "$ROWS_FILE"
            printf '%s\n' "$median" \
                | awk -v file="$ROWS_FILE" \
                    '{print >> file}'
        done
    done
done

# ---------------------------------------------------------------------------
# Render markdown to $OUT.
# ---------------------------------------------------------------------------

# The TSV has alternating lines: meta line (4 cols: scenario server
# target saturated) then median line (8 cols). Pair them up.
emit_md() {
    local hostline cpu uname_s
    cpu=$(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo \
          2>/dev/null || echo "unknown")
    uname_s=$(uname -srm 2>/dev/null || echo "unknown")
    hostline="CPU: $cpu — Kernel: $uname_s"

    cat <<EOF
# wrk2 open-loop bench results

Generated by \`scripts/wrk2_bench.sh\` on $(date -u +'%Y-%m-%d %H:%M:%SZ').
$hostline

## Methodology

[wrk2](https://github.com/giltene/wrk2) is an open-loop HTTP load
driver: it issues requests at a fixed target rate regardless of
whether previous responses have arrived, and corrects the latency
histogram for [Coordinated
Omission](https://www.scylladb.com/2021/04/22/on-coordinated-omission/).
Closed-loop tools (wrk, ab, vegeta, our own \`bench.escript\`) hide
the tail because the client backs off when the server stalls.

For each scenario, each server is driven at four rates: 50 %, 75 %,
90 %, and 95 % of its measured peak from
[\`bench_results.md\`](bench_results.md). The 90 % point typically
sits around the elbow; 95 % usually saturates. The \`achieved\`
column is the actual rate wrk2 sustained; when achieved / target
< 0.99 the row is tagged \`(saturated)\`.

Each measurement runs wrk2 with both \`--latency\` (CO-corrected,
"Recorded Latency") and \`--u_latency\` (uncorrected, "Service
Time"). Two tables per scenario:

- **CO-corrected** — what every issued request *would have* seen.
  This is the honest tail.
- **Uncorrected** — what a closed-loop tool would have reported.
  Shown so the size of the coordinated-omission gap is visible
  directly. If the corrected and uncorrected p99 are close, the
  server is keeping up; if they diverge, that's a saturation
  signal even if achieved is at target.

Each row is the median of **${RUNS} runs at ${DURATION_S}s each**,
\`-t${THREADS} -c${CONNS}\`. Per-run logs live under
\`/tmp/wrk2/<scenario>/<server>/<rate-pct>/run-N.log\`.

Connection-shape scenarios (\`pipelined_h1\`, \`slow_client\`,
\`connection_storm\`, \`mixed_workload\`, \`accept_storm_burst\`,
\`server_sent_events\`) are intentionally absent — wrk2's
\`-c${CONNS}\` keep-alive shape can't reproduce their wire patterns.
HTTP/2-only scenarios are absent too; wrk2 is HTTP/1.1.

EOF

    # Per-scenario: emit two tables (corrected / uncorrected). Both
    # tables share the same server / target / achieved columns so the
    # rows line up across the pair.
    local seen=""
    while IFS= read -r meta_line; do
        IFS=$'\t' read -r m_scenario m_server m_target m_saturated <<< "$meta_line"
        IFS= read -r data_line || true
        IFS=$'\t' read -r \
            d_achieved \
            c_p50 c_p75 c_p90 c_p99 c_p999 c_p9999 c_max \
            u_p50 u_p75 u_p90 u_p99 u_p999 u_p9999 u_max \
            <<< "$data_line"

        # Format target/achieved as "Nk".
        local tgt ach
        tgt=$(awk -v v="$m_target" 'BEGIN{printf "%.1fk", v/1000}')
        ach=$(awk -v v="$d_achieved" 'BEGIN{printf "%.1fk", v/1000}')
        if [ "$m_saturated" = "yes" ]; then
            ach="$ach (sat)"
        fi

        # Stash this row's data for both tables. We emit when a new
        # scenario starts (printing all accumulated rows for the
        # previous scenario) or at the end.
        if [[ "$seen" != *"|$m_scenario|"* ]]; then
            if [ -n "$seen" ]; then emit_pending_tables; fi
            seen="$seen|$m_scenario|"
            current_scenario="$m_scenario"
            corrected_rows=""
            uncorrected_rows=""
        fi
        corrected_rows+="$(printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |' \
            "$m_server" "$tgt" "$ach" \
            "$c_p50" "$c_p75" "$c_p90" "$c_p99" "$c_p999" "$c_p9999" "$c_max")"$'\n'
        uncorrected_rows+="$(printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |' \
            "$m_server" "$tgt" "$ach" \
            "$u_p50" "$u_p75" "$u_p90" "$u_p99" "$u_p999" "$u_p9999" "$u_max")"$'\n'
    done < "$ROWS_FILE"
    [ -n "$seen" ] && emit_pending_tables
}

emit_pending_tables() {
    cat <<EOF

## \`$current_scenario\`

**CO-corrected (Recorded Latency)** — honest tail.

| server | target | achieved | p50 | p75 | p90 | p99 | p99.9 | p99.99 | max |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
$corrected_rows
**Uncorrected (Service Time)** — what closed-loop tools report. Compare to the corrected table for the size of the CO gap.

| server | target | achieved | p50 | p75 | p90 | p99 | p99.9 | p99.99 | max |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
$uncorrected_rows
EOF
}

emit_md > "$OUT"
echo "[$(ts)] wrote $OUT"
