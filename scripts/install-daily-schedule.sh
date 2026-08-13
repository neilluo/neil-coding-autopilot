#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DAILY_ANALYSIS="$SCRIPT_DIR/daily-analysis.sh"
LABEL="com.neil.autopilot.daily"
[ -f "$DAILY_ANALYSIS" ] || { echo "ERROR: missing sibling script: $DAILY_ANALYSIS" >&2; exit 1; }
usage() { echo "Usage: install-daily-schedule.sh [--hour H] [--log-dir DIR] [--stage-scripts|--no-stage]"; }

HOUR=13; LOG_DIR=""; STAGE_MODE="auto"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --hour) [ "$#" -ge 2 ] || { usage >&2; exit 1; }; HOUR="$2"; shift 2 ;;
    --log-dir) [ "$#" -ge 2 ] || { usage >&2; exit 1; }; LOG_DIR="$2"; shift 2 ;;
    --stage-scripts) STAGE_MODE="yes"; shift ;;
    --no-stage) STAGE_MODE="no"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1 (use --help)" >&2; exit 1 ;;
  esac
done
case "$HOUR" in ''|*[!0-9]*) echo "ERROR: --hour must be an integer 0-23" >&2; exit 1 ;; esac
[ "$HOUR" -le 23 ] || { echo "ERROR: --hour must be 0-23" >&2; exit 1; }
[ -n "$LOG_DIR" ] || LOG_DIR="${NEIL_AUTOPILOT_LOG_DIR:-${HOME:-}/Library/Logs/neil-autopilot}"
KEEP_DAYS="${NEIL_AUTOPILOT_KEEP_DAYS:-30}"
case "$KEEP_DAYS" in ''|*[!0-9]*) KEEP_DAYS=30 ;; esac

resolve_abs_path() { local d="$1"; mkdir -p "$d" 2>/dev/null || true; (cd "$d" 2>/dev/null && pwd -P) || printf '%s\n' "$d"; }
xml_escape() {
  local value="$1"
  value="${value//&/&amp;}"; value="${value//</&lt;}"; value="${value//>/&gt;}"
  value="${value//\"/&quot;}"; value="${value//\'/&apos;}"
  printf '%s' "$value"
}
shell_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
ABS_LOG_DIR="$(resolve_abs_path "$LOG_DIR")"
QODERCLI_PATH="$(command -v qodercli || true)"
[ -n "$QODERCLI_PATH" ] || { echo "ERROR: qodercli 未在当前 PATH 中找到，无法安装每日调度。" >&2; exit 1; }
PATH_DIRS=("$(dirname "$QODERCLI_PATH")")
JQ_PATH="$(command -v jq || true)"; [ -n "$JQ_PATH" ] && PATH_DIRS+=("$(dirname "$JQ_PATH")")
GTIMEOUT_PATH="$(command -v gtimeout || true)"; [ -n "$GTIMEOUT_PATH" ] && PATH_DIRS+=("$(dirname "$GTIMEOUT_PATH")")
PATH_DIRS+=("/opt/homebrew/bin" "/usr/local/bin" "/usr/bin" "/bin")
PATH_VALUE=""; SEEN=":"
for d in "${PATH_DIRS[@]}"; do
  [ -n "$d" ] || continue; [ "$d" = "." ] && continue
  case "$SEEN" in *":$d:"*) continue ;; esac
  SEEN="$SEEN$d:"; [ -z "$PATH_VALUE" ] && PATH_VALUE="$d" || PATH_VALUE="$PATH_VALUE:$d"
done

ABS_HOME="$(cd "$HOME" && pwd -P)"
is_protected() {
  local path="$1" prefix
  for prefix in "$ABS_HOME/Desktop" "$ABS_HOME/Documents" "$ABS_HOME/Downloads"; do
    case "$path" in "$prefix"|"$prefix"/*) return 0 ;; esac
  done
  return 1
}
print_tcc_fix() {
  local safe_log="$HOME/Library/Logs/neil-autopilot"
  echo "ERROR: macOS protected path cannot be used safely without staging: $1" >&2
  echo "Run: \"$SCRIPT_DIR/migrate-log-root.sh\" --from \"$ABS_LOG_DIR\" --to \"$safe_log\"" >&2
  echo "Add to ~/.zshrc: export NEIL_AUTOPILOT_LOG_DIR=\"$safe_log\"" >&2
  echo "Alternatively grant Full Disk Access（完整磁盘访问权限）to /bin/bash." >&2
}

macos_install() {
  local scheduled_script="$DAILY_ANALYSIS" effective_log="$ABS_LOG_DIR"
  local plist_dir="$HOME/Library/LaunchAgents"
  local plist_path="$plist_dir/$LABEL.plist"
  local stage_root="$HOME/Library/Application Support/neil-autopilot"
  local staged_scripts="$stage_root/scripts"
  [ "$STAGE_MODE" = "auto" ] && STAGE_MODE="yes"
  if [ "$STAGE_MODE" = "yes" ]; then
    rm -rf "$staged_scripts.new"; mkdir -p "$stage_root"; cp -R "$SCRIPT_DIR" "$staged_scripts.new"
    rm -rf "$staged_scripts"; mv "$staged_scripts.new" "$staged_scripts"
    scheduled_script="$staged_scripts/daily-analysis.sh"
    echo "plugin 更新后需重跑本脚本以刷新 staged 副本。"
    if is_protected "$effective_log"; then
      local protected_log="$effective_log"
      effective_log="$HOME/Library/Logs/neil-autopilot"; mkdir -p "$effective_log"
      echo "受保护日志路径已改为安全路径: $effective_log"
      printf '迁移已有日志（只复制不删除）: "%s" --from "%s" --to "%s"\n' \
        "$staged_scripts/migrate-log-root.sh" "$protected_log" "$effective_log"
    fi
  fi
  if is_protected "$scheduled_script" || is_protected "$effective_log"; then print_tcc_fix "$scheduled_script / $effective_log"; exit 1; fi
  mkdir -p "$plist_dir"
  if [ -f "$plist_path" ]; then
    launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1 || launchctl unload "$plist_path" >/dev/null 2>&1 || true
    rm -f "$plist_path"
  fi
  local xml_label xml_script xml_log xml_keep_days xml_path xml_output
  xml_label="$(xml_escape "$LABEL")"; xml_script="$(xml_escape "$scheduled_script")"
  xml_log="$(xml_escape "$effective_log")"; xml_keep_days="$(xml_escape "$KEEP_DAYS")"
  xml_path="$(xml_escape "$PATH_VALUE")"; xml_output="$(xml_escape "$effective_log/daily-analysis.launchd.log")"
  cat > "$plist_path" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$xml_label</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>$xml_script</string></array>
<key>StartCalendarInterval</key><dict><key>Hour</key><integer>$HOUR</integer><key>Minute</key><integer>0</integer></dict>
<key>EnvironmentVariables</key><dict><key>NEIL_AUTOPILOT_LOG_DIR</key><string>$xml_log</string><key>NEIL_AUTOPILOT_KEEP_DAYS</key><string>$xml_keep_days</string><key>PATH</key><string>$xml_path</string></dict>
<key>StandardOutPath</key><string>$xml_output</string>
<key>StandardErrorPath</key><string>$xml_output</string><key>RunAtLoad</key><false/>
</dict></plist>
PLIST_EOF
  if launchctl bootstrap "gui/$UID" "$plist_path" >/dev/null 2>&1; then echo "已安装并加载 launchd 定时任务（bootstrap）: $plist_path"
  elif launchctl load "$plist_path" >/dev/null 2>&1; then echo "已安装并加载 launchd 定时任务（load）: $plist_path"
  else echo "ERROR: launchctl bootstrap/load 均失败: $plist_path" >&2; exit 1; fi
  echo "每日 $HOUR:00 本地时间将运行: $scheduled_script"; echo "日志根目录: $effective_log"
  echo "export NEIL_AUTOPILOT_LOG_DIR=\"$effective_log\""
}
linux_install() {
  local cron_line
  echo "Linux 环境：请手动执行 crontab -e，加入以下一行："
  cron_line="0 $HOUR * * * NEIL_AUTOPILOT_LOG_DIR=$(shell_quote "$ABS_LOG_DIR") NEIL_AUTOPILOT_KEEP_DAYS=$(shell_quote "$KEEP_DAYS") PATH=$(shell_quote "$PATH_VALUE") $(shell_quote "$DAILY_ANALYSIS") >> $(shell_quote "$ABS_LOG_DIR/daily-analysis.cron.log") 2>&1"
  cron_line="${cron_line//%/\\%}"
  printf '%s\n' "$cron_line"
  printf 'export NEIL_AUTOPILOT_LOG_DIR=%s\n' "$(shell_quote "$ABS_LOG_DIR")"
}
PLATFORM="$(uname -s)"
case "$PLATFORM" in Darwin) macos_install ;; Linux) linux_install ;; *) echo "ERROR: unsupported platform: $PLATFORM" >&2; exit 1 ;; esac
