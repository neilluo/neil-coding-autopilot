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

echo "smoke-install-daily-schedule: PASS"
