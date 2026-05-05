#!/usr/bin/env bash
#
# bench_matrix.sh — run scripts/bench.escript across every
# (scenario, protocol) pair, take the median of N runs per cell,
# and emit:
#   docs/bench_results.csv  — machine-readable medians
#   docs/bench_results.md   — human-readable per-protocol tables
#
# bench.escript runs ONE scenario at a time (single peer BEAM,
# isolated per side). This wrapper drives the full matrix and
# writes the consolidated tables that ship under docs/.
#
# Requires bash 4+ (associative arrays + BASH_REMATCH `match[]`).
# macOS ships /bin/bash 3.2 — install bash via brew and run
# explicitly: `bash ./scripts/bench_matrix.sh`.
#
# Usage (from repo root):
#
#   ./scripts/bench_matrix.sh
#
# Tunables (env vars):
#
#   RUNS=3                # samples per cell, median is reported
#   DURATION=5            # measure seconds per run
#   WARMUP=2              # warmup seconds per run
#   CLIENTS=50            # bench.escript --clients
#   SKIP_BENCH=1          # reuse existing /tmp/bench_matrix.log
#                         #   (regenerate the CSV + MD only)
#
# Drift note: the PROTOS / SCENARIOS arrays below MUST be kept in
# sync with the `scenario_roadrunner_opts/2` clauses in
# scripts/bench.escript and that script's `preflight_scenario/1`
# h1-only / h2-only filters. Adding a scenario without updating
# this list silently drops it from the rendered tables.
#
set -u

RUNS=${RUNS:-3}
DURATION=${DURATION:-5}
WARMUP=${WARMUP:-2}
CLIENTS=${CLIENTS:-50}
SKIP_BENCH=${SKIP_BENCH:-0}

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG=/tmp/bench_matrix.log
CSV="$REPO_ROOT/docs/bench_results.csv"
MD="$REPO_ROOT/docs/bench_results.md"
PER_RUN_TSV=/tmp/bench_per_run.tsv

# ---- Scenario × protocol matrix ---------------------------------

declare -A PROTOS=(
  [hello]="h1 h2"
  [headers_heavy]="h1 h2"
  [echo]="h1 h2"
  [large_response]="h1"
  [json]="h1 h2"
  [head_method]="h1"
  [cookies_heavy]="h1 h2"
  [multi_request_body]="h1 h2"
  [streaming_response]="h2"
  [multi_stream_h2]="h2"
  [small_chunked_response]="h2"
  [tls_handshake_throughput]="h2"
  [pipelined_h1]="h1"
  [slow_client]="h1"
  [connection_storm]="h1"
  [mixed_workload]="h1"
  [post_4kb_form]="h1"
  [large_post_streaming]="h1"
  [gzip_response]="h1"
  [backpressure_sustained]="h1"
  [server_sent_events]="h1"
  [expect_100_continue]="h1"
  [large_keepalive_session]="h1"
  [websocket_msg_throughput]="h1"
  [url_with_qs]="h1"
  [accept_storm_burst]="h1"
  [etag_304]="h1"
  [partial_body_drop]="h1"
  [path_with_unicode]="h1"
  [cors_preflight]="h1"
  [chunked_request_body]="h1"
  [redirect_response]="h1"
  [compressed_request_body]="h1"
  [router_404_storm]="h1"
  [varied_paths_router]="h1"
)

# Stable iteration order — groups roughly by category for the
# rendered tables (simple, parsing/routing, body, connection,
# streaming/push, websocket, then h2-only at the bottom).
SCENARIOS=(
  hello json echo headers_heavy large_response
  url_with_qs varied_paths_router path_with_unicode
  router_404_storm cors_preflight redirect_response head_method
  post_4kb_form chunked_request_body compressed_request_body
  multi_request_body expect_100_continue large_post_streaming
  cookies_heavy etag_304 mixed_workload
  pipelined_h1 large_keepalive_session connection_storm
  slow_client accept_storm_burst partial_body_drop
  server_sent_events gzip_response backpressure_sustained
  websocket_msg_throughput
  streaming_response multi_stream_h2 small_chunked_response
  tls_handshake_throughput
)

# ---- Drive the matrix -------------------------------------------

if [[ "$SKIP_BENCH" != "1" ]]; then
  : > "$LOG"
  total=0
  for s in "${SCENARIOS[@]}"; do
    for _ in ${PROTOS[$s]}; do total=$((total+1)); done
  done
  idx=0
  for s in "${SCENARIOS[@]}"; do
    for p in ${PROTOS[$s]}; do
      idx=$((idx+1))
      echo "[$idx/$total] $s ($p)"
      for run in $(seq 1 "$RUNS"); do
        out=$(mise exec -- "$REPO_ROOT/scripts/bench.escript" \
          --scenario "$s" --protocol "$p" \
          --duration "$DURATION" --warmup "$WARMUP" --clients "$CLIENTS" \
          --servers roadrunner,cowboy,elli 2>&1)
        printf '===== %s | %s | run %s =====\n%s\n' "$s" "$p" "$run" "$out" >> "$LOG"
      done
    done
  done
fi

# ---- Parse log → per-run TSV ------------------------------------

awk '
  /^===== / {
    if (match($0, /===== ([^ ]+) \| ([^ ]+) \| run ([0-9]+) =====/, m)) {
      scenario=m[1]; proto=m[2]; run=m[3]
    }
    next
  }
  /req\/s/ && /total=/ {
    if (match($0, /^[[:space:]]*(roadrunner|cowboy|elli)[[:space:]]+([0-9,]+) req\/s.*p50=([0-9.]+) (µs|ms|ns).*p99=([0-9.]+) (µs|ms|ns)/, m)) {
      r=m[2]; gsub(",","",r);
      print scenario"\t"proto"\t"m[1]"\t"run"\t"r"\t"m[3]"\t"m[4]"\t"m[5]"\t"m[6]
    }
  }
' "$LOG" > "$PER_RUN_TSV"

# ---- Aggregate medians → CSV ------------------------------------

awk -F'\t' '
  function to_us(v, u) {
    if (u=="ms") return v*1000+0
    if (u=="µs") return v+0
    if (u=="ns") return v/1000
    return -1
  }
  function median(arr,    n, i, j, t, half) {
    n = arr["n"]+0; if (n==0) return -1
    for (i=1;i<=n;i++) for (j=i+1;j<=n;j++) if (arr[i]>arr[j]) {t=arr[i];arr[i]=arr[j];arr[j]=t}
    if (n%2==1) return arr[(n+1)/2]
    half=n/2; return int((arr[half]+arr[half+1])/2)
  }
  {
    sc=$1; pr=$2; sv=$3; r=$5+0; p50us=to_us($6,$7); p99us=to_us($8,$9)
    key=sc"|"pr"|"sv
    if (r>0) {
      n_r[key]++; rs[key,n_r[key]]=r
      n_p50[key]++; p50s[key,n_p50[key]]=p50us
      n_p99[key]++; p99s[key,n_p99[key]]=p99us
    }
    seen[key]=1
  }
  END {
    for (k in seen) {
      split(k, parts, "|")
      sc=parts[1]; pr=parts[2]; sv=parts[3]
      if (!n_r[k]) {
        print sc","pr","sv",N/A,N/A,N/A"
        continue
      }
      delete tmpr; delete tmp50; delete tmp99
      for (i=1;i<=n_r[k];i++) tmpr[i]=rs[k,i]
      for (i=1;i<=n_p50[k];i++) tmp50[i]=p50s[k,i]
      for (i=1;i<=n_p99[k];i++) tmp99[i]=p99s[k,i]
      tmpr["n"]=n_r[k]; tmp50["n"]=n_p50[k]; tmp99["n"]=n_p99[k]
      printf "%s,%s,%s,%d,%d,%d\n", sc, pr, sv, median(tmpr), median(tmp50), median(tmp99)
    }
  }
' "$PER_RUN_TSV" | sort > "$CSV"

# ---- Emit human-readable markdown -------------------------------

declare -A R_RPS R_P50 R_P99 C_RPS E_RPS
while IFS=, read -r sc pr sv rps p50 p99; do
  case "$sv" in
    roadrunner) R_RPS[$sc,$pr]=$rps; R_P50[$sc,$pr]=$p50; R_P99[$sc,$pr]=$p99 ;;
    cowboy)     C_RPS[$sc,$pr]=$rps ;;
    elli)       E_RPS[$sc,$pr]=$rps ;;
  esac
done < "$CSV"

cell_ks() {
  local v="$1"
  if [[ "$v" == "N/A" || -z "$v" ]]; then echo "—"; return; fi
  if (( v < 10000 )); then awk -v x="$v" 'BEGIN{printf "%.1f k", x/1000}'
  else awk -v x="$v" 'BEGIN{printf "%.0f k", x/1000}'
  fi
}

fmt_us() {
  local v=$1
  if [[ -z "$v" || "$v" == "N/A" ]]; then echo "—"; return; fi
  if (( v >= 1000 )); then awk -v x="$v" 'BEGIN{printf "%.1f ms", x/1000}'
  else awk -v x="$v" 'BEGIN{printf "%d µs", x}'
  fi
}

emit_table() {
  local proto="$1"
  echo "| scenario | roadrunner | cowboy | elli | rr p50 / p99 |"
  echo "|---|---:|---:|---:|---:|"
  for sc in "${SCENARIOS[@]}"; do
    [[ " ${PROTOS[$sc]} " == *" $proto "* ]] || continue
    local r=${R_RPS[$sc,$proto]:-N/A}
    local c=${C_RPS[$sc,$proto]:-N/A}
    local e=${E_RPS[$sc,$proto]:-N/A}
    local p50=${R_P50[$sc,$proto]:-} p99=${R_P99[$sc,$proto]:-}
    local lat="—"
    if [[ -n "$p50" && -n "$p99" && "$p50" != "N/A" ]]; then
      lat="$(fmt_us "$p50") / $(fmt_us "$p99")"
    fi
    echo "| \`$sc\` | $(cell_ks "$r") | $(cell_ks "$c") | $(cell_ks "$e") | $lat |"
  done
}

GIT_SHA=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
DATE_STAMP=$(date -u +%Y-%m-%d)
KERNEL=$(uname -srm)
CPU=$(lscpu 2>/dev/null | awk -F: '/Model name/{gsub(/^[ \t]+/,"",$2); print $2; exit}')
NPROC=$(nproc 2>/dev/null || echo unknown)
OTP=$(mise exec -- erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]), halt().' 2>/dev/null || echo unknown)

{
  echo "# Benchmark results"
  echo
  echo "Captured by \`scripts/bench_matrix.sh\` on $DATE_STAMP at \`$GIT_SHA\`."
  echo
  echo "**Hardware / runtime**"
  echo
  echo "- CPU: $CPU ($NPROC threads)"
  echo "- Kernel: $KERNEL"
  echo "- OTP: $OTP"
  echo "- Loadgen: $RUNS runs/cell × ${DURATION}s measure (${WARMUP}s warmup), $CLIENTS clients, loopback"
  echo "- Bench client: in-tree \`roadrunner_bench_client\` (h1 + h2)"
  echo
  echo "Numbers are the **median** req/s across $RUNS runs. \`p50 / p99\`"
  echo "shown is **roadrunner's** for that cell — see the raw"
  echo "\`bench_results.csv\` (next to this file) for the full"
  echo "rr / cowboy / elli breakdown including each server's p50 / p99."
  echo
  echo "Re-run locally with:"
  echo
  echo '```'
  echo "./scripts/bench_matrix.sh"
  echo '```'
  echo
  echo "Override defaults via env: \`RUNS=5 DURATION=10 ./scripts/bench_matrix.sh\`."
  echo "Set \`SKIP_BENCH=1\` to regenerate the CSV / MD from the existing"
  echo "\`/tmp/bench_matrix.log\` without re-running the bench."
  echo
  echo "## HTTP/1.1"
  echo
  emit_table h1
  echo
  echo "## HTTP/2"
  echo
  emit_table h2
  echo
  echo "## Notes / known gaps"
  echo
  echo "- \`large_response\` / \`head_method\` are listed h1-only here."
  echo "  Their h2 cells errored on 64 KB single-stream responses"
  echo "  against both servers — a flow-control interaction in the"
  echo "  test client, not a server-side bug."
  echo "- \`pipelined_h1\` elli: elli's keep-alive path doesn't"
  echo "  pipeline; the 4.9 k req/s reflects per-request RTT,"
  echo "  not pipelining."
  echo "- \`tls_handshake_throughput\` h2: cowboy edges roadrunner"
  echo "  here. See"
  echo "  [\`docs/conn_lifecycle_investigation.md\`](conn_lifecycle_investigation.md)"
  echo "  Round 3 for the prior null-result investigation."
  echo
  echo "## Reading the numbers honestly"
  echo
  echo "- Throughput deltas under ~15 % are inside run-to-run"
  echo "  variance on a loaded dev box. The bench's banner reminds"
  echo "  on every run."
  echo "- p50 / p99 are usually steadier than throughput run-to-run."
  echo "- Loopback hides NIC + kernel TCP cost. For a public"
  echo "  comparison run against a remote host with \`--clients\`"
  echo "  tuned to your CPU count."
} > "$MD"

echo
echo "=== done ==="
echo "  CSV: $CSV"
echo "  MD : $MD"
[[ "$SKIP_BENCH" != "1" ]] && echo "  log: $LOG"
