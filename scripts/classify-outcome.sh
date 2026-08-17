#!/usr/bin/env bash
# WHAT: Classify a worker exit code and log as OK, TRANSPORT, TIMEOUT, TRUNCATED, EMPTY, or APP.
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

# 1b) TRUNCATED —— dispatch.sh 用 125 标记「模型发出了工具调用但 CLI 没执行就退出，文件零改动」。
# 它**必须**与 TRANSPORT 分开：dispatch.sh 自己写着实测结论「原样重试 3 次全部复现，`-r` 续跑
# 同样救不回（会话已被悬空的 tool_use 污染）」，而 TRANSPORT 会被上层退避重试到耗尽 ——
# 等于把一次注定失败的调用按全价买三遍，还白等 5+10+20=35s。分出独立类别后由上层直接
# fail-closed，把浪费从 3 次调用压到 1 次。
#
# 只认「125 + dispatch 打出的锚定行」这一对组合，不单看退出码：`timeout(1)` 也用 125 表示
# 自身启动失败，单看码会把那种情况误标成截断。锚定判据是本仓一贯做法（见 parse-markers.sh）。
# 锚定行拿得到是有保证的：run-track-a.sh 的 dispatch_worker 用 `2>&1 | tee` 收日志，
# dispatch.sh 那句 ERROR 走 stderr 也会落进同一个文件。
case "$exit_code" in
  125)
    if [ -f "$log_file" ] && grep -q 'TRUNCATED_TOOL_USE' "$log_file" 2>/dev/null; then
      printf '%s\n' TRUNCATED
      exit 0
    fi
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

# 2.5) no anchored marker at all = worker gave no conclusion (spec Task 14)
#      exit 0 + no marker => EMPTY (retry), regardless of byte count.
#      Toggle off with AUTOPILOT_NO_MARKER_IS_EMPTY=0 to restore byte-only behavior.
no_marker_is_empty="${AUTOPILOT_NO_MARKER_IS_EMPTY:-1}"
if [ "$no_marker_is_empty" = "1" ] && [ "$exit_code" = "0" ]; then
  printf '%s\n' EMPTY
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
