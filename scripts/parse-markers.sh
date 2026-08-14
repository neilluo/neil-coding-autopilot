#!/usr/bin/env bash
# 锚定式解析 worker 输出的 Status / CR 裁决（spec §11 D19 的唯一实现）
# 用法: parse-markers.sh status|review <log-file>
# 输出: status → DONE|DONE_WITH_CONCERNS|BLOCKED|NEEDS_CONTEXT|UNKNOWN
#       review → REVIEW_PASS|REVIEW_FAIL|UNKNOWN
# 规则: 只看末 15 行；Status 须行首锚定；裁决须独占一行。文件缺失/无匹配 → UNKNOWN。
set -uo pipefail
MODE="${1:-}"; FILE="${2:-}"
WINDOW="${AUTOPILOT_MARKER_WINDOW:-15}"
if [ "$MODE" = "-h" ] || [ "$MODE" = "--help" ]; then echo "usage: parse-markers.sh status|review <log>"; exit 0; fi
if [ -z "$MODE" ] || [ -z "$FILE" ]; then echo "usage: parse-markers.sh status|review <log>" >&2; exit 2; fi
if [ ! -f "$FILE" ]; then echo "UNKNOWN"; exit 0; fi
case "$MODE" in
  status)
    M="$(tail -"$WINDOW" "$FILE" 2>/dev/null \
      | grep -oE '^[[:space:]]*\**[Ss]tatus\**[:：]\**[[:space:]]*\**(DONE_WITH_CONCERNS|DONE|BLOCKED|NEEDS_CONTEXT)' \
      | tail -1 | grep -oE '(DONE_WITH_CONCERNS|DONE|BLOCKED|NEEDS_CONTEXT)' | tail -1 || true)"
    ;;
  review)
    M="$(tail -"$WINDOW" "$FILE" 2>/dev/null \
      | grep -oE '^[[:space:]]*\**REVIEW_(PASS|FAIL)\**[[:space:]]*$' \
      | tail -1 | grep -oE 'REVIEW_(PASS|FAIL)' | tail -1 || true)"
    ;;
  *) echo "usage: parse-markers.sh status|review <log>" >&2; exit 2 ;;
esac
[ -n "$M" ] && echo "$M" || echo "UNKNOWN"
exit 0
