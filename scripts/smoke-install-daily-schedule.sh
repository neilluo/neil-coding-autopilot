#!/usr/bin/env bash
set -euo pipefail
unset AUTOPILOT_RUN_ID

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAKE_HOME="$TMP/home"
BIN="$TMP/bin"
mkdir -p "$FAKE_HOME/Desktop/logs" "$FAKE_HOME/Library/Logs/neil-autopilot" "$BIN"
printf '#!/usr/bin/env bash\nprintf "stub:%s\\n" "$*" >> "$LAUNCHCTL_LOG"\n' > "$BIN/launchctl"
printf '#!/bin/bash\nprintf "Darwin\\n"\n' > "$BIN/uname"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/qodercli"
chmod +x "$BIN/launchctl" "$BIN/uname" "$BIN/qodercli"
export HOME="$FAKE_HOME" PATH="$BIN:/usr/bin:/bin" LAUNCHCTL_LOG="$TMP/launchctl.log"

run_install() {
  local output="$1"; shift
  bash "$SCRIPT_DIR/install-daily-schedule.sh" "$@" >"$output" 2>&1
}

protected_output="$TMP/protected-no-stage.out"
if run_install "$protected_output" --log-dir "$FAKE_HOME/Desktop/logs" --no-stage; then
  echo "expected protected --no-stage to fail" >&2
  exit 1
fi
[ ! -e "$FAKE_HOME/Library/LaunchAgents/com.neil.autopilot.daily.plist" ]
grep -q 'migrate-log-root.sh' "$protected_output"

protected_stage_output="$TMP/protected-stage.out"
run_install "$protected_stage_output" --log-dir "$FAKE_HOME/Desktop/logs" --stage-scripts
plist="$FAKE_HOME/Library/LaunchAgents/com.neil.autopilot.daily.plist"
staged="$FAKE_HOME/Library/Application Support/neil-autopilot/scripts/daily-analysis.sh"
[ -x "$staged" ]
! grep -q '/Desktop/' "$plist"
grep -q "$FAKE_HOME/Library/Logs/neil-autopilot" "$plist"
grep -Fq 'scripts/migrate-log-root.sh" --from "' "$protected_stage_output"
grep -Fq -- '--to "' "$protected_stage_output"

for mode in --stage-scripts --no-stage; do
  rm -f "$plist"
  run_install "$TMP/safe-${mode#--}.out" --log-dir "$FAKE_HOME/Library/Logs/neil-autopilot" "$mode"
  [ -f "$plist" ]
  ! grep -q '/Desktop/' "$plist"
done

protected_plugin="$FAKE_HOME/Desktop/plugin"
mkdir -p "$protected_plugin"
cp -R "$SCRIPT_DIR" "$protected_plugin/scripts"
rm -f "$plist"
if bash "$protected_plugin/scripts/install-daily-schedule.sh" \
  --log-dir "$FAKE_HOME/Library/Logs/neil-autopilot" --no-stage >"$TMP/protected-script-no-stage.out" 2>&1; then
  echo "expected protected script path with --no-stage to fail" >&2
  exit 1
fi
[ ! -e "$plist" ]
grep -q 'migrate-log-root.sh' "$TMP/protected-script-no-stage.out"

bash "$protected_plugin/scripts/install-daily-schedule.sh" \
  --log-dir "$FAKE_HOME/Library/Logs/neil-autopilot" --stage-scripts >"$TMP/protected-script-stage.out" 2>&1
[ -f "$plist" ]
grep -Fq "$FAKE_HOME/Library/Application Support/neil-autopilot/scripts/daily-analysis.sh" "$plist"
! grep -q '/Desktop/' "$plist"
[ -x "$FAKE_HOME/Library/Application Support/neil-autopilot/scripts/telemetry.sh" ]
[ -x "$FAKE_HOME/Library/Application Support/neil-autopilot/scripts/dispatch.sh" ]

rm -f "$plist"
unset NEIL_AUTOPILOT_LOG_DIR NEIL_AUTOPILOT_KEEP_DAYS
run_install "$TMP/defaults.out"
default_log_dir="$(cd "$FAKE_HOME/Library/Logs/neil-autopilot" && pwd -P)"
grep -q "<string>$default_log_dir</string>" "$plist"
grep -q '<key>NEIL_AUTOPILOT_KEEP_DAYS</key><string>30</string>' "$plist"

special_log="$FAKE_HOME/Library/Logs/a&b<c>d\"e'f"
mkdir -p "$special_log"
run_install "$TMP/xml-special.out" --log-dir "$special_log" --no-stage
plutil -lint "$plist" >/dev/null
grep -Fq '&amp;' "$plist"
grep -Fq '&lt;' "$plist"
grep -Fq '&gt;' "$plist"
grep -Fq '&quot;' "$plist"
grep -Fq '&apos;' "$plist"

printf '#!/bin/bash\nprintf "Linux\\n"\n' > "$BIN/uname"
chmod +x "$BIN/uname"
marker="$TMP/cron-injected"
cron_log="$FAKE_HOME/Library/Logs/cron & \"quote'\'' \$(touch $marker)%"
run_install "$TMP/linux-special.out" --log-dir "$cron_log" --no-stage
[ ! -e "$marker" ]
grep -Fq "NEIL_AUTOPILOT_LOG_DIR='" "$TMP/linux-special.out"
grep -Fq "'\''" "$TMP/linux-special.out"
grep -Fq '\%' "$TMP/linux-special.out"

[ -s "$LAUNCHCTL_LOG" ]
if grep -v '^stub:' "$LAUNCHCTL_LOG" | grep -q .; then
  echo "non-stub launchctl invocation recorded" >&2
  exit 1
fi

# ── --check-staged：staged 副本过期必须能被发现 ───────────────────────────
# 过期副本是真实踩过的坑：代码侧修好了，定时任务却一直跑旧副本。用 fixture 目录
# 验证判定逻辑（不依赖本机真实安装状态，保持 hermetic）。
CHK_DIR="$TMP/staged-fixture"

# 场景 1：副本不存在 → exit 0（未安装不算错）
set +e
AUTOPILOT_STAGED_SCRIPTS="$CHK_DIR" bash "$SCRIPT_DIR/install-daily-schedule.sh" --check-staged > "$TMP/chk-missing.log" 2>&1
rc_missing=$?
set -e
[ "$rc_missing" -eq 0 ] || { echo "missing staged copy should exit 0 (got $rc_missing)" >&2; exit 1; }
grep -q 'no staged copy' "$TMP/chk-missing.log" || { echo "missing staged copy not reported" >&2; exit 1; }

# 场景 2：副本与仓库一致 → exit 0
mkdir -p "$CHK_DIR"
cp "$SCRIPT_DIR"/*.sh "$CHK_DIR/"
set +e
AUTOPILOT_STAGED_SCRIPTS="$CHK_DIR" bash "$SCRIPT_DIR/install-daily-schedule.sh" --check-staged > "$TMP/chk-fresh.log" 2>&1
rc_fresh=$?
set -e
[ "$rc_fresh" -eq 0 ] || { echo "fresh staged copy should exit 0 (got $rc_fresh)" >&2; cat "$TMP/chk-fresh.log" >&2; exit 1; }
grep -q 'up to date' "$TMP/chk-fresh.log" || { echo "fresh staged copy not reported as up to date" >&2; exit 1; }

# 场景 3：副本落后 → exit 3 + 点名具体文件 + 给出刷新命令
printf '\n# staged copy is now stale\n' >> "$CHK_DIR/daily-analysis.sh"
set +e
AUTOPILOT_STAGED_SCRIPTS="$CHK_DIR" bash "$SCRIPT_DIR/install-daily-schedule.sh" --check-staged > "$TMP/chk-stale.log" 2>&1
rc_stale=$?
set -e
[ "$rc_stale" -eq 3 ] || { echo "stale staged copy should exit 3 (got $rc_stale)" >&2; cat "$TMP/chk-stale.log" >&2; exit 1; }
grep -q 'STALE: daily-analysis.sh' "$TMP/chk-stale.log" || { echo "stale file not named" >&2; exit 1; }
grep -q -- '--stage-scripts' "$TMP/chk-stale.log" || { echo "refresh command not suggested" >&2; exit 1; }
# 检测本身绝不能写任何东西（只读）：不得重建 plist 或碰 launchctl。
if grep -v '^stub:' "$LAUNCHCTL_LOG" | grep -q .; then
  echo "--check-staged must not touch launchctl" >&2
  exit 1
fi

echo "smoke-install-daily-schedule: PASS"
