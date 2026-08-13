#!/usr/bin/env bash
# WHAT: Classify a worker exit code and log as OK, TRANSPORT, TIMEOUT, EMPTY, or APP.
# USAGE: classify-outcome.sh <exit_code> <log_file>
# EXIT CODES: Always 0 for classification requests; help also exits 0.
set -euo pipefail

usage() {
  echo "Usage: classify-outcome.sh <exit_code> <log_file>"
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
TRANSPORT_PATTERN='unable to connect|response body idle timeout|typo in the url or port|econnreset|econnrefused|etimedout|socket hang up|fetch failed|network error|tls handshake|too many requests|rate limit|502 bad gateway|503 service unavailable|504 gateway timeout'
exit_code="${1:-}"
log_file="${2:-}"
transport_threshold="${AUTOPILOT_TRANSPORT_LOG_BYTES:-4096}"
threshold="${AUTOPILOT_EMPTY_LOG_BYTES:-300}"
log_bytes=0

# 1) TIMEOUT
case "$exit_code" in
  124|137)
    printf '%s\n' TIMEOUT
    exit 0
    ;;
esac

# measure log size
if [ -f "$log_file" ]; then
  log_bytes="$(wc -c < "$log_file" | tr -d '[:space:]')"
fi

# 2) anchored marker parse via parse-markers.sh
status_marker="$("$SCRIPT_DIR/parse-markers.sh" status "$log_file" 2>/dev/null || echo UNKNOWN)"
review_marker="$("$SCRIPT_DIR/parse-markers.sh" review "$log_file" 2>/dev/null || echo UNKNOWN)"

if [ "$status_marker" != "UNKNOWN" ] || [ "$review_marker" != "UNKNOWN" ]; then
  if [ "$exit_code" = "0" ]; then
    printf '%s\n' OK
  else
    printf '%s\n' APP
  fi
  exit 0
fi

# 3) transport regex: only when log_bytes < transport_threshold, only on tail -20
if [ "$log_bytes" -lt "$transport_threshold" ] && [ -f "$log_file" ]; then
  if tail -20 "$log_file" | grep -qiE "$TRANSPORT_PATTERN"; then
    printf '%s\n' TRANSPORT
    exit 0
  fi
fi

# 4) nonzero exit + short log
if [ "$exit_code" != "0" ] && [ "$log_bytes" -lt "$threshold" ]; then
  printf '%s\n' TRANSPORT
  exit 0
fi

# 5) zero exit + short log
if [ "$exit_code" = "0" ] && [ "$log_bytes" -lt "$threshold" ]; then
  printf '%s\n' EMPTY
  exit 0
fi

# 6) nonzero exit
if [ "$exit_code" != "0" ]; then
  printf '%s\n' APP
  exit 0
fi

# 7) default
printf '%s\n' OK
exit 0
