#!/usr/bin/env bash
# 从 worker 输出文件中鲁棒提取 Status
# 用法: parse-status.sh /tmp/autopilot-task-N-result.md
# 输出: DONE / DONE_WITH_CONCERNS / BLOCKED / NEEDS_CONTEXT / UNKNOWN

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PARSE_MARKERS="$SCRIPT_DIR/parse-markers.sh"

FILE="${1:-}"
if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
  echo "UNKNOWN"
  exit 1
fi

"$PARSE_MARKERS" status "$FILE"
