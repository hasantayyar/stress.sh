#!/usr/bin/env bash
# bash-loadtester.sh — tiny dependency-light HTTP load tester
#
# Dependencies: bash ≥4, curl, awk, sed, sort, xargs, date, mktemp, bc (optional for nicer floats)
# Works best on GNU userland. macOS users: install coreutils for GNU date if you hit issues.
#
# Features
# - Concurrency with xargs -P (no GNU parallel needed)
# - Duration- or request-count–based runs
# - Optional global RPS cap and simple ramp-up
# - Methods: GET/POST/PUT/PATCH/DELETE; payload from file or inline
# - Custom headers
# - Connection reuse (keep-alive) and compression by default
# - Plain-text report: throughput, success/failed, latency p50/p90/p95/p99, min/avg/max, status codes
# - Exit non-zero if error rate exceeds threshold
#
# Examples
#   ./bash-loadtester.sh -u https://example.com -d 30 -c 20
#   ./bash-loadtester.sh -u https://example.com/api -n 1000 -c 50 -m POST -b data.json -H "Content-Type: application/json"
#   ./bash-loadtester.sh -u https://example.com -d 60 -c 100 --rps 200 --ramp 10,100,5,5
#   ./bash-loadtester.sh -U urls.txt -d 30 -c 40 --rps 200
#
# Ramp syntax: start_conc,peak_conc,steps,step_seconds (e.g., 10,100,5,5 -> 10→100 over 5 steps, every 5s)

set -uo pipefail

# Defaults
URL=""
URLS_FILE=""
METHOD="GET"
DATA_FILE=""
DATA_INLINE=""
HEADERS=()
CONC=10
DURATION=0
REQUESTS=0
RPS=0
RAMP=""
TIMEOUT=30
KEEPALIVE=true
COMPRESS=true
INSECURE=false
OUTPUT_DIR=""
ERROR_THRESHOLD=100 # percentage basis points (i.e., 100 = 1%)
VERBOSE=false
