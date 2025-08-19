#!/usr/bin/env bash
# bash-loadtester.sh — tiny dependency-light HTTP load tester
#
# Dependencies: bash (3.2+ OK; 5.x recommended), curl, awk, sort, xargs, date, mktemp
# Optional: bc
# macOS: stock tools work; for newer bash: `brew install bash`
#
# Features
# - Concurrency with xargs -P (no GNU parallel)
# - Duration or request-count runs
# - Optional global RPS cap and simple ramp-up
# - Methods: GET/POST/PUT/PATCH/DELETE; payload from file or inline
# - Custom headers
# - Keep-alive and compression by default
# - Plain-text report: throughput; ok/fail; latency p50/p90/p95/p99; min/avg/max; status codes
# - Non-zero exit if error rate exceeds threshold

set -uo pipefail

# ===== Defaults =====
URL=""
URLS_FILE=""
METHOD="GET"
DATA_FILE=""
DATA_INLINE=""
HEADERS=()                # array, guarded everywhere for bash 3.2 + set -u
CONC=10
DURATION=0
REQUESTS=0
RPS=0
RAMP=""                   # start,peak,steps,step_seconds
TIMEOUT=30
KEEPALIVE=true
COMPRESS=true
INSECURE=false
OUTPUT_DIR=""
ERROR_THRESHOLD=100       # basis points (100 = 1.00%)
VERBOSE=false

# ===== Interrupt handling (Ctrl+C prints partial report) =====
interrupted=0
goto_report=0
on_int() {
  interrupted=1
  echo ""
  echo "Stopping test and generating report..." >&2
  # kill all background jobs and child processes
  jobs -p | xargs -r kill 2>/dev/null || true
  pkill -P $$ 2>/dev/null || true
  goto_report=1
}
trap on_int INT TERM

usage() {
  cat <<USAGE
Usage: $0 [-u URL | -U urls.txt] [-d seconds | -n requests] [-c concurrency] [--rps rps] [--ramp s,p,steps,sec]
           [-m METHOD] [-b file|--data STRING] [-H "Header: Value"] [--timeout sec] [--no-keepalive] [--no-compress]
           [--insecure] [--out dir] [--errbp basis_points] [--verbose]
USAGE
}

# ===== Parse args =====
while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0;;
    -u) URL="$2"; shift 2;;
    -U) URLS_FILE="$2"; shift 2;;
    -d) DURATION="$2"; shift 2;;
    -n) REQUESTS="$2"; shift 2;;
    -c) CONC="$2"; shift 2;;
    -m) METHOD="$2"; shift 2;;
    -b) DATA_FILE="$2"; shift 2;;
    -H) HEADERS+=("$2"); shift 2;;
    --rps) RPS="$2"; shift 2;;
    --ramp) RAMP="$2"; shift 2;;
    --timeout) TIMEOUT="$2"; shift 2;;
    --no-keepalive) KEEPALIVE=false; shift;;
    --no-compress) COMPRESS=false; shift;;
    --insecure) INSECURE=true; shift;;
    --out) OUTPUT_DIR="$2"; shift 2;;
    --errbp) ERROR_THRESHOLD="$2"; shift 2;;
    --data) DATA_INLINE="$2"; shift 2;;
    --verbose) VERBOSE=true; shift;;
    --*) echo "Unknown option: $1" >&2; usage; exit 2;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

if [[ -z "$URL" && -z "$URLS_FILE" ]]; then echo "Error: must specify -u or -U" >&2; usage; exit 2; fi
if [[ -n "$URL" && -n "$URLS_FILE" ]]; then echo "Error: -u and -U are mutually exclusive" >&2; usage; exit 2; fi
if (( DURATION == 0 && REQUESTS == 0 )); then echo "Error: specify -d or -n" >&2; usage; exit 2; fi
if (( DURATION > 0 && REQUESTS > 0 )); then echo "Error: -d and -n are mutually exclusive" >&2; usage; exit 2; fi

# ===== Output files =====
if [[ -z "$OUTPUT_DIR" ]]; then OUTPUT_DIR=$(mktemp -d -t blt.XXXXXX); fi
RESULTS="$OUTPUT_DIR/results.tsv"
TIMES_FILE="$OUTPUT_DIR/times.txt"
CODES_FILE="$OUTPUT_DIR/codes.txt"
BYTES_FILE="$OUTPUT_DIR/bytes.txt"
ERRORS_FILE="$OUTPUT_DIR/errors.txt"
META_FILE="$OUTPUT_DIR/meta.txt"
: > "$RESULTS"; : > "$TIMES_FILE"; : > "$CODES_FILE"; : > "$BYTES_FILE"; : > "$ERRORS_FILE"

# curl args are now built dynamically in do_req() function

# ===== URL provider =====
get_url() {
  if [[ -n "$URL" ]]; then echo "$URL"; return; fi
  # pick random line from file (uniform)
  awk 'BEGIN{srand()} {a[NR]=$0} END{if(NR>0){print a[int(rand()*NR)+1]}}' "$URLS_FILE"
}

# ===== Single request =====
do_req() {
  local idx="$1"; local target
  target=$(get_url)
  local line
  
  # Build curl command with proper options
  local curl_cmd=("curl" "-s" "-o" "/dev/null" "--max-time" "$TIMEOUT" "-w" "%{time_total} %{time_connect} %{time_starttransfer} %{http_code} %{size_download}\n")
  
  # Add conditional options
  if [[ "$KEEPALIVE" == "false" ]]; then curl_cmd+=("--no-keepalive"); fi
  if [[ "$COMPRESS" == "true" ]]; then curl_cmd+=("--compressed"); fi
  if [[ "$INSECURE" == "true" ]]; then curl_cmd+=("-k"); fi
  
  # Add headers if any
  local h
  for h in ${HEADERS+"${HEADERS[@]}"}; do
    curl_cmd+=("-H" "$h")
  done
  
  # Add method and data
  if [[ "$METHOD" != "GET" ]]; then curl_cmd+=("-X" "$METHOD"); fi
  if [[ -n "$DATA_FILE" ]]; then curl_cmd+=("--data-binary" "@${DATA_FILE}"); fi
  if [[ -n "$DATA_INLINE" ]]; then curl_cmd+=("--data-binary" "$DATA_INLINE"); fi
  
  # Add target URL
  curl_cmd+=("$target")
  
  # Execute curl and capture output
  if ! line=$("${curl_cmd[@]}" 2>/dev/null); then
    echo "curl_error" >> "$ERRORS_FILE"
    $VERBOSE && echo "[ERR] curl failed idx=$idx url=$target" >&2
    return 1
  fi
  
  # Validate that we got expected format (single line with 5 space-separated values)
  local field_count line_count
  line_count=$(echo "$line" | wc -l)
  field_count=$(echo "$line" | awk '{print NF}')
  
  if [[ "$line_count" -ne 1 ]] || [[ "$field_count" -ne 5 ]]; then
    echo "parse_error" >> "$ERRORS_FILE"
    $VERBOSE && echo "[ERR] unexpected curl output format idx=$idx lines=$line_count fields=$field_count" >&2
    return 1
  fi
  
  # Parse line: time_total time_connect time_starttransfer http_code size
  printf "%s\t%s\n" "$line" "$target" >> "$RESULTS"
  # Robust field writes
  echo "$line" | awk '{print ($1=="" ? 0 : $1)}' >> "$TIMES_FILE"
  echo "$line" | awk '{print ($4=="" ? "000" : $4)}' >> "$CODES_FILE"
  echo "$line" | awk '{print ($5=="" ? 0 : $5)}' >> "$BYTES_FILE"
}

# ===== Dispatcher timing =====
START_EPOCH=$(date +%s)
END_EPOCH=$START_EPOCH
if (( DURATION > 0 )); then END_EPOCH=$((START_EPOCH + DURATION)); fi

current_conc="$CONC"
# Ramp parsing (note: xargs -P is static for the run; ramp affects token pacing, not worker count)
if [[ -n "$RAMP" ]]; then
  IFS=',' read -r ramp_start ramp_peak ramp_steps ramp_stepsec <<< "$RAMP"
  current_conc=${ramp_start:-$CONC}
fi

# ===== Token producer =====
producer() {
  local target_req="$1"   # 0 if duration mode
  local rps="$2"
  local now sent=0 idx=1
  local last_step_epoch=$START_EPOCH
  local have_ramp=0
  [[ -n "$RAMP" ]] && have_ramp=1

  while :; do
    now=$(date +%s)
    if (( DURATION > 0 )); then
      (( now >= END_EPOCH )) && break
    else
      (( sent >= target_req )) && break
    fi

    # Handle ramp steps (token pacing only)
    if (( have_ramp == 1 )); then
      if (( now - last_step_epoch >= ramp_stepsec )); then
        step_size=$(( (ramp_peak - ramp_start) / (ramp_steps>0 ? ramp_steps : 1) ))
        current_conc=$(( current_conc + step_size ))
        if (( current_conc > ramp_peak )); then current_conc=$ramp_peak; fi
        last_step_epoch=$now
      fi
    fi

    echo "$idx"
    ((sent++)); ((idx++))

    if (( rps > 0 )); then
      # Sleep ~1/RPS seconds
      sleep $(awk -v r="$rps" 'BEGIN{printf("%.6f", 1.0/r)}')
    fi
  done
}

# ===== Metadata =====
{
  echo "url=$URL"
  echo "urls_file=$URLS_FILE"
  echo "method=$METHOD"
  printf 'headers='
  # safe expansion if unset/empty
  printf '%s;' ${HEADERS+"${HEADERS[@]}"}; echo
  echo "concurrency=$CONC"
  echo "duration=$DURATION"
  echo "requests=$REQUESTS"
  echo "rps=$RPS"
  echo "ramp=$RAMP"
  echo "timeout=$TIMEOUT"
  echo "start_epoch=$START_EPOCH"
} > "$META_FILE"

# ===== Run =====
export -f do_req get_url producer
export URL URLS_FILE RESULTS TIMES_FILE CODES_FILE BYTES_FILE ERRORS_FILE VERBOSE
export METHOD DATA_FILE DATA_INLINE TIMEOUT KEEPALIVE COMPRESS INSECURE HEADERS
export RPS START_EPOCH DURATION current_conc

# Show test start info
if (( DURATION > 0 )); then
  echo "Running load test for ${DURATION}s with ${current_conc} workers against ${URL:-$URLS_FILE}..."
else
  echo "Running ${REQUESTS} requests with ${current_conc} workers against ${URL:-$URLS_FILE}..."
fi

# Execute the test with proper duration control
if (( DURATION > 0 )); then
  # Start a background timeout process that will stop the test after duration
  (
    sleep "$DURATION"
    echo "Duration limit reached, stopping test..." >&2
    # Kill the entire process group to stop all children immediately
    kill -TERM -$$ 2>/dev/null || kill -TERM $$ 2>/dev/null || true
    sleep 1
    kill -KILL -$$ 2>/dev/null || kill -KILL $$ 2>/dev/null || true
  ) &
  timeout_pid=$!
  
  # Run the test
  {
    producer 0 "$RPS" | xargs -I{} -P "$current_conc" bash -c 'do_req "$@"' _ {}
  } 2>/dev/null
  
  # Clean up timeout process if test completed normally
  kill $timeout_pid 2>/dev/null || true
  wait $timeout_pid 2>/dev/null || true
else
  # For request count mode, no timeout needed
  {
    seq 1 "$REQUESTS" | xargs -I{} -P "$current_conc" bash -c 'do_req "$@"' _ {}
  } 2>/dev/null
fi

echo "Test completed, generating report..."

# if interrupted, still fall through to report
# ===== Reporting helpers =====
percentile() {
  local p="$1" file="$2" n idx
  # keep only non-empty numeric lines, then sort
  awk 'NF' "$file" | sort -n > "$file.sorted"
  n=$(wc -l < "$file.sorted" | tr -d ' ')
  (( n == 0 )) && { echo 0; return; }
  # nearest-rank ceil(p/100 * n) — BSD awk safe
  idx=$(awk -v n="$n" -v p="$p" 'BEGIN{
    val = p/100.0*n
    i = int(val)
    if (val > i) i = i + 1
    if (i < 1) i = 1
    if (i > n) i = n
    print i
  }')
  awk -v i="$idx" 'NR==i{print $1; exit}' "$file.sorted"
}

sum()  { awk '{s+=$1} END{print s+0}' "$1"; }
minv() { sort -n "$1" | head -n1; }
maxv() { sort -n "$1" | tail -n1; }
mean() {
  local total cnt
  total=$(sum "$1"); cnt=$(wc -l < "$1" | tr -d ' ')
  awk -v t="$total" -v c="$cnt" 'BEGIN{if(c==0){print 0}else{printf("%.6f", t/c)}}'
}

generate_report() {
  local END_TIME ELAPSED
  END_TIME=$(date +%s)
  ELAPSED=$((END_TIME - START_EPOCH))
  (( ELAPSED == 0 )) && ELAPSED=1

  local ok_count all_count fail_count rps_achieved
  ok_count=$(grep -E '^[0-9]{3}$' "$CODES_FILE" | awk '$1<500 && $1>=200' | wc -l | tr -d ' ')
  all_count=$(wc -l < "$CODES_FILE" | tr -d ' ')
  fail_count=$(( all_count - ok_count ))
  rps_achieved=$(awk -v c="$all_count" -v e="$ELAPSED" 'BEGIN{printf("%.2f", c/(e>0?e:1))}')

  local p50 p90 p95 p99 min_t max_t mean_t
  p50=$(percentile 50 "$TIMES_FILE")
  p90=$(percentile 90 "$TIMES_FILE")
  p95=$(percentile 95 "$TIMES_FILE")
  p99=$(percentile 99 "$TIMES_FILE")
  min_t=$(minv "$TIMES_FILE")
  max_t=$(maxv "$TIMES_FILE")
  mean_t=$(mean "$TIMES_FILE")

  local bytes_total bytes_mean
  bytes_total=$(sum "$BYTES_FILE")
  bytes_mean=$(awk -v t="$bytes_total" -v n="$all_count" 'BEGIN{printf("%.0f", (n>0)?t/n:0)}')

  local status_hist err_hist
  status_hist=$(awk 'NF{c[$1]++} END{for(k in c){printf("  %s: %d\n", k, c[k])}}' "$CODES_FILE" | sort)
  err_hist=$(awk 'NF{c[$1]++} END{for(k in c){printf("  %s: %d\n", k, c[k])}}' "$ERRORS_FILE" | sort)

  cat <<REPORT
=== bash-loadtester report ===
Start:   $(date -d @${START_EPOCH} 2>/dev/null || date -r ${START_EPOCH})
End:     $(date -d @${END_TIME} 2>/dev/null || date -r ${END_TIME})
Elapsed: ${ELAPSED}s
Target:  ${URL:-$URLS_FILE}
Method:  $METHOD
Workers: $current_conc
RPS cap: ${RPS}

Requests: total=${all_count} ok=${ok_count} fail=${fail_count}
Throughput: ${rps_achieved} req/s (avg)

Latency (s):
  min=${min_t}
  p50=${p50}
  p90=${p90}
  p95=${p95}
  p99=${p99}
  max=${max_t}
  avg=${mean_t}

Bytes:
  total=${bytes_total}
  mean_per_req=${bytes_mean}

Status codes:
${status_hist:-"  (none)"}

Errors:
${err_hist:-"  (none)"}

Artifacts: $OUTPUT_DIR
REPORT

  # Exit code based on error threshold
  local err_bp=0
  if (( all_count > 0 )); then
    err_bp=$(awk -v f="$fail_count" -v a="$all_count" 'BEGIN{printf("%d", (f*10000)/a)}')
  fi
  if (( err_bp > ERROR_THRESHOLD )); then
    echo "Error rate ${err_bp}bp exceeds threshold ${ERROR_THRESHOLD}bp" >&2
    return 3
  fi
  return 0
}

if (( interrupted )); then
  echo "Interrupted early, generating partial report..." >&2
fi

generate_report
exit_code=$?
if (( goto_report )); then
  # honor SIGINT semantics if we were interrupted
  exit 130
fi
exit "$exit_code"
