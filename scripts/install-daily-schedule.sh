#!/usr/bin/env bash
# install-daily-schedule.sh — install the daily-analysis.sh schedule (spec.md §5.6).
#
# WHAT: on macOS, generates+loads a launchd LaunchAgent plist that runs
#   scripts/daily-analysis.sh once a day. On Linux, prints a crontab line to
#   paste manually (no root/system-wide cron mutation).
#
# WHY THIS IS THE "ONE TRUE LINK" IN THE ENV-VAR CHAIN (spec.md §3.1):
#   interactive runs read the user's shell profile for NEIL_AUTOPILOT_LOG_DIR,
#   but launchd/cron do NOT source the profile. This script is the only place
#   that freezes the resolved absolute $LOG_ROOT into the scheduler's own env
#   (plist EnvironmentVariables / crontab prefix) — otherwise collection and
#   analysis silently point at two different directories.
#
# USAGE:
#   scripts/install-daily-schedule.sh [--hour H] [--log-dir DIR]
#
# OPTIONS:
#   --hour H       Local hour (0-23) to run daily-analysis.sh. Default: 13.
#   --log-dir DIR  Log root to freeze into the schedule. Default:
#                  $NEIL_AUTOPILOT_LOG_DIR, else $HOME/neil-autopilot-logs-analysis.
#                  Always resolved to an absolute path before use.
#   -h | --help    Show usage.
#
# ENV:
#   NEIL_AUTOPILOT_LOG_DIR    --log-dir fallback (see above).
#   NEIL_AUTOPILOT_KEEP_DAYS  runs/ retention days frozen into the schedule (default 3).
#
# EXIT CODES:
#   0    schedule installed (or crontab line printed on Linux)
#   1    usage error / missing qodercli / unsupported platform / launchd failure
#
# PORTABILITY: bash 3.2 (macOS stock); no hardcoded username/home dir (C8) —
#   everything routes through $HOME / $NEIL_AUTOPILOT_LOG_DIR / $SCRIPT_DIR.

set -euo pipefail

# ── self-locate (macOS-safe; not readlink -f) ────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DAILY_ANALYSIS="$SCRIPT_DIR/daily-analysis.sh"
LABEL="com.neil.autopilot.daily"

[ -f "$DAILY_ANALYSIS" ] || { echo "ERROR: missing sibling script: $DAILY_ANALYSIS" >&2; exit 1; }

usage() { sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ── args ──────────────────────────────────────────────────────────────────────
HOUR=13
LOG_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --hour) HOUR="$2"; shift 2;;
    --log-dir) LOG_DIR="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1 (use --help)" >&2; exit 1;;
  esac
done

case "$HOUR" in
  ''|*[!0-9]*) echo "ERROR: --hour must be an integer 0-23" >&2; exit 1;;
esac
if [ "$HOUR" -gt 23 ]; then
  echo "ERROR: --hour must be 0-23" >&2
  exit 1
fi

[ -n "$LOG_DIR" ] || LOG_DIR="${NEIL_AUTOPILOT_LOG_DIR:-${HOME:-}/neil-autopilot-logs-analysis}"
KEEP_DAYS="${NEIL_AUTOPILOT_KEEP_DAYS:-3}"
case "$KEEP_DAYS" in ''|*[!0-9]*) KEEP_DAYS=3;; esac

# ── resolve --log-dir to an absolute path (grow-on-demand mkdir) ────────────
resolve_abs_path() {
  local d="$1"
  mkdir -p "$d" 2>/dev/null || true
  (cd "$d" 2>/dev/null && pwd -P) || printf '%s\n' "$d"
}
ABS_LOG_DIR="$(resolve_abs_path "$LOG_DIR")"

# ── PATH construction: probe each optional binary, dirname it, never inject
#    "." for a missing one — a bare "." in a launchd PATH is a foothold for
#    whatever happens to be CWD at trigger time, so we build this by hand
#    instead of just copying $PATH. qodercli is the one hard requirement:
#    without it the nightly job would silently no-op forever. ─────────────
QODERCLI_PATH="$(command -v qodercli || true)"
if [ -z "$QODERCLI_PATH" ]; then
  echo "ERROR: qodercli 未在当前 PATH 中找到，无法安装每日调度（launchd 环境不 source shell profile，缺失会导致每日分析静默失效）。请先确保 qodercli 可执行后重试。" >&2
  exit 1
fi

PATH_DIRS=()
PATH_DIRS+=("$(dirname "$QODERCLI_PATH")")
JQ_PATH="$(command -v jq || true)"
[ -n "$JQ_PATH" ] && PATH_DIRS+=("$(dirname "$JQ_PATH")")
GTIMEOUT_PATH="$(command -v gtimeout || true)"
[ -n "$GTIMEOUT_PATH" ] && PATH_DIRS+=("$(dirname "$GTIMEOUT_PATH")")
PATH_DIRS+=("/opt/homebrew/bin" "/usr/local/bin" "/usr/bin" "/bin")

PATH_VALUE=""
SEEN=":"
for d in "${PATH_DIRS[@]}"; do
  [ -n "$d" ] || continue
  [ "$d" = "." ] && continue
  case "$SEEN" in
    *":$d:"*) continue;;
  esac
  SEEN="$SEEN$d:"
  if [ -z "$PATH_VALUE" ]; then
    PATH_VALUE="$d"
  else
    PATH_VALUE="$PATH_VALUE:$d"
  fi
done

# ── macOS: generate + (re)load the LaunchAgent plist ─────────────────────────
macos_install() {
  local plist_dir="$HOME/Library/LaunchAgents"
  local plist_path="$plist_dir/$LABEL.plist"
  mkdir -p "$plist_dir"

  # idempotent reinstall: unload/remove any previous version first.
  if [ -f "$plist_path" ]; then
    launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1 \
      || launchctl unload "$plist_path" >/dev/null 2>&1 \
      || true
    rm -f "$plist_path"
  fi

  cat > "$plist_path" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$DAILY_ANALYSIS</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>$HOUR</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>EnvironmentVariables</key>
    <dict>
        <key>NEIL_AUTOPILOT_LOG_DIR</key>
        <string>$ABS_LOG_DIR</string>
        <key>NEIL_AUTOPILOT_KEEP_DAYS</key>
        <string>$KEEP_DAYS</string>
        <key>PATH</key>
        <string>$PATH_VALUE</string>
    </dict>
    <key>StandardOutPath</key>
    <string>$ABS_LOG_DIR/daily-analysis.launchd.log</string>
    <key>StandardErrorPath</key>
    <string>$ABS_LOG_DIR/daily-analysis.launchd.log</string>
    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
PLIST_EOF

  if launchctl bootstrap "gui/$UID" "$plist_path" >/dev/null 2>&1; then
    echo "已安装并加载 launchd 定时任务（bootstrap）: $plist_path"
  elif launchctl load "$plist_path" >/dev/null 2>&1; then
    echo "已安装并加载 launchd 定时任务（load，bootstrap 不可用）: $plist_path"
  else
    echo "ERROR: launchctl bootstrap/load 均失败: $plist_path" >&2
    exit 1
  fi

  echo ""
  echo "每日 $HOUR:00 本地时间将运行: $DAILY_ANALYSIS"
  echo "日志根目录: $ABS_LOG_DIR"
  echo ""
  echo "请将以下一行加入你的 shell profile（~/.zshrc / ~/.bash_profile），保证交互式运行与 launchd 定时任务解析到同一日志目录："
  echo "export NEIL_AUTOPILOT_LOG_DIR=\"$ABS_LOG_DIR\""
}

# ── Linux: no root/system cron mutation — print a line to paste manually ────
linux_install() {
  echo "Linux 环境：请手动执行 crontab -e，加入以下一行（每日 $HOUR:00 本地时间运行）："
  echo ""
  echo "0 $HOUR * * * NEIL_AUTOPILOT_LOG_DIR=\"$ABS_LOG_DIR\" NEIL_AUTOPILOT_KEEP_DAYS=\"$KEEP_DAYS\" PATH=\"$PATH_VALUE\" \"$DAILY_ANALYSIS\" >> \"$ABS_LOG_DIR/daily-analysis.cron.log\" 2>&1"
  echo ""
  echo "请将以下一行加入你的 shell profile（~/.bashrc 等），保证交互式运行与 cron 定时任务解析到同一日志目录："
  echo "export NEIL_AUTOPILOT_LOG_DIR=\"$ABS_LOG_DIR\""
}

PLATFORM="$(uname -s)"
case "$PLATFORM" in
  Darwin) macos_install;;
  Linux) linux_install;;
  *) echo "ERROR: unsupported platform: $PLATFORM (only Darwin/Linux supported)" >&2; exit 1;;
esac
