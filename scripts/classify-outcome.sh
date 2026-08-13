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

TRANSPORT_PATTERN='unable to connect|response body idle timeout|typo in the url or port|econnreset|econnrefused|etimedout|socket hang up|fetch failed|network error|tls handshake|too many requests|rate limit|502 bad gateway|503 service unavailable|504 gateway timeout'
exit_code="${1:-}"
log_file="${2:-}"
threshold="${AUTOPILOT_EMPTY_LOG_BYTES:-300}"
log_bytes=0

case "$exit_code" in
  124|137)
    printf '%s\n' TIMEOUT
    exit 0
    ;;
esac

if [ -f "$log_file" ]; then
  if grep -qiE "$TRANSPORT_PATTERN" "$log_file"; then
    printf '%s\n' TRANSPORT
    exit 0
  fi
  log_bytes="$(wc -c < "$log_file" | tr -d '[:space:]')"
fi

if [ "$exit_code" != "0" ] && [ "$log_bytes" -lt "$threshold" ]; then
  printf '%s\n' TRANSPORT
elif [ "$exit_code" = "0" ] && [ "$log_bytes" -lt "$threshold" ]; then
  printf '%s\n' EMPTY
elif [ "$exit_code" != "0" ]; then
  printf '%s\n' APP
else
  printf '%s\n' OK
fi

exit 0
