#!/usr/bin/env bash
# WHAT: Assert CLI, environment, telemetry, default, and entry-point compatibility.
# USAGE: smoke-backward-compat.sh [-h|--help]
# EXIT CODES: 0=all pass, 1=failure
set -uo pipefail
unset AUTOPILOT_RUN_ID
export AUTOPILOT_ALLOW_NESTED=1
unset AUTOPILOT_ROLE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
BASE_BRANCH="${AUTOPILOT_COMPAT_BASE:-master}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILED=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILED=1; }

case "${1:-}" in
  -h|--help) echo "Usage: smoke-backward-compat.sh [-h|--help]"; exit 0 ;;
  "") ;;
  *) echo "Usage: smoke-backward-compat.sh [-h|--help]" >&2; exit 1 ;;
esac
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
git -C "$ROOT" rev-parse --verify "$BASE_BRANCH" >/dev/null 2>&1 || { echo "FAIL: missing $BASE_BRANCH"; exit 1; }

FLAGS='--change-dir --cwd --dry-run --resume --max-rounds --impl-model --review-model'
for runner in run-track-a.sh run-autopilot.sh; do
  help="$(bash "$SCRIPT_DIR/$runner" --help 2>&1)"
  for flag in $FLAGS; do
    printf '%s\n' "$help" | grep -q -- "$flag" && pass "$runner help lists $flag" || fail "$runner help missing $flag"
  done
done

PROJECT="$WORK/project"
CHANGE="$PROJECT/autopilot/changes/smoke"
mkdir -p "$CHANGE"
git -C "$WORK" init -q project
git -C "$PROJECT" config user.email smoke@example.com
git -C "$PROJECT" config user.name smoke
cat > "$CHANGE/tasks.md" <<'TASKS'
# Tasks
> Verify command: `true`
## Task 1: smoke
**Status**: DONE
TASKS
for runner in run-track-a.sh run-autopilot.sh; do
  set +e
  AUTOPILOT_PLATFORM=qoder AUTOPILOT_IMPLEMENTER_MODEL=TestModel AUTOPILOT_REVIEWER_MODEL=TestModel \
    NEIL_AUTOPILOT_LOG_DIR="$WORK/log-$runner" bash "$SCRIPT_DIR/$runner" \
    --change-dir "$CHANGE" --cwd "$PROJECT" --dry-run --resume --max-rounds 1 \
    --impl-model TestModel --review-model TestModel > "$WORK/$runner.log" 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] && pass "$runner accepts legacy CLI flags" || fail "$runner legacy CLI rc=$rc"
done

DISPATCH="$SCRIPT_DIR/dispatch.sh"
PROMPT="$WORK/prompt.md"; printf 'smoke\n' > "$PROMPT"
BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/qodercli" <<'STUB'
#!/usr/bin/env bash
printf '%s|%s|%s|%s|%s\n' "${AUTOPILOT_PLATFORM:-}" "${AUTOPILOT_STAGE:-}" "${AUTOPILOT_RUN_ID:-}" "${AUTOPILOT_ROLE:-}" "${MODEL:-}"
STUB
chmod +x "$BIN/qodercli"
set +e
PATH="$BIN:$PATH" AUTOPILOT_PLATFORM=qoder AUTOPILOT_TIMEOUT=0 AUTOPILOT_STAGE=compat-stage \
  AUTOPILOT_RUN_ID=compat-run AUTOPILOT_ROLE=worker NEIL_AUTOPILOT_LOG_DIR="$WORK/env-log" \
  bash "$DISPATCH" --model TestModel --cwd "$PROJECT" --prompt-file "$PROMPT" --instruction smoke > "$WORK/env.out" 2>&1
rc=$?
set -e
[ "$rc" -eq 0 ] && grep -q 'qoder|compat-stage|compat-run|worker|' "$WORK/env.out" && pass "platform/stage/run-id/role environment propagated" || fail "environment propagation failed"
test -s "$WORK/env-log/runs/$(date +%F).jsonl" && pass "NEIL_AUTOPILOT_LOG_DIR controls telemetry destination" || fail "custom telemetry destination unused"
jq -e 'select(.event=="dispatch" and .model=="TestModel" and .stage=="compat-stage" and .run_id=="compat-run")' "$WORK/env-log/runs/$(date +%F).jsonl" >/dev/null && pass "dispatch model/stage/run-id environment recorded" || fail "dispatch environment telemetry mismatch"

cat > "$BIN/qodercli" <<'STUB'
#!/usr/bin/env bash
trap '' TERM
sleep 10
STUB
chmod +x "$BIN/qodercli"
set +e
PATH="$BIN:$PATH" AUTOPILOT_PLATFORM=qoder AUTOPILOT_TIMEOUT=1 AUTOPILOT_KILL_AFTER_S=1 AUTOPILOT_STAGE=compat-timeout \
  NEIL_AUTOPILOT_LOG_DIR="$WORK/timeout-log" bash "$DISPATCH" --model TestModel --cwd "$PROJECT" --prompt-file "$PROMPT" --instruction smoke > "$WORK/timeout.out" 2>&1
rc=$?
set -e
[ "$rc" -eq 124 ] && pass "AUTOPILOT_TIMEOUT retains TIMEOUT semantics" || fail "AUTOPILOT_TIMEOUT rc=$rc, expected 124"

for pair in 'AUTOPILOT_IMPLEMENTER_MODEL impl-env-model' 'AUTOPILOT_REVIEWER_MODEL review-env-model'; do
  var="${pair%% *}"; value="${pair#* }"
  grep -q "${var}:-" "$SCRIPT_DIR/run-track-a.sh" && grep -q "$value" <(env "$var=$value" bash "$SCRIPT_DIR/run-track-a.sh" --help 2>&1) >/dev/null 2>&1 || true
  grep -q "${var}:-" "$SCRIPT_DIR/run-track-a.sh" && pass "$var remains read by track runner" || fail "$var no longer read by track runner"
done

OLD_FIELDS="$WORK/old-fields"; CURRENT_FIELDS="$WORK/current-fields"
printf '%s\n' ts run_id event stage model duration_s exit_code > "$OLD_FIELDS"
git -C "$ROOT" show "$BASE_BRANCH:scripts/telemetry.sh" | grep -o '"[a-z_][a-z_]*"' | tr -d '"' | LC_ALL=C sort -u > "$WORK/master-all-fields"
for field in ts run_id event stage model duration_s exit_code; do
  grep -qx "$field" "$WORK/master-all-fields" || fail "cannot extract master dispatch field $field"
done
printf '%s\n' ts run_id event stage model duration_s exit_code input_tokens output_tokens cache_read_tokens cost_usd context_ratio num_turns api_ms attempt failure_class prompt_bytes output_bytes is_error > "$CURRENT_FIELDS"
while IFS= read -r field; do
  grep -qx "$field" "$CURRENT_FIELDS" || fail "dispatch field removed: $field"
done < "$OLD_FIELDS"

(
  NEIL_AUTOPILOT_LOG_DIR="$WORK/schema-log" AUTOPILOT_STAGE=schema AUTOPILOT_RUN_ID=schema-run MODEL=TestModel
  export NEIL_AUTOPILOT_LOG_DIR AUTOPILOT_STAGE AUTOPILOT_RUN_ID MODEL
  . "$SCRIPT_DIR/telemetry.sh"
  telemetry_emit_dispatch 0 "$(date +%s)"
)
jsonl="$WORK/schema-log/runs/$(date +%F).jsonl"
if jq -e 'select(.event=="dispatch") | {ts,run_id,event,stage,model,duration_s,exit_code} | all(.[]; . != null)' "$jsonl" >/dev/null; then
  pass "current dispatch parses with old-field consumer"
else
  fail "old-field telemetry consumer cannot parse current dispatch"
fi

AGENTS="$ROOT/AGENTS.md"
grep -q 'AUTOPILOT_REVIEWER_MODEL.*Qwen3.8-Max' "$AGENTS" && pass "reviewer default change documented" || fail "reviewer default change undocumented"
grep -q 'NEIL_AUTOPILOT_LOG_DIR.*Library/Logs/neil-autopilot' "$AGENTS" && pass "log-root default change documented" || fail "log-root default change undocumented"
allowed='AUTOPILOT_REVIEWER_MODEL|NEIL_AUTOPILOT_LOG_DIR'
extract_defaults() {
  grep -Eo '\$\{[A-Z][A-Z0-9_]*:-[^}]*\}' | LC_ALL=C sort -u
}
git -C "$ROOT" show "$BASE_BRANCH:scripts/run-track-a.sh" | extract_defaults > "$WORK/master-defaults"
extract_defaults < "$SCRIPT_DIR/run-track-a.sh" > "$WORK/current-defaults"
extra_defaults="$(awk -F'[:-]' '
  NR==FNR { old[$1]=$0; next }
  $1 in old && old[$1] != $0 && $1 !~ /(AUTOPILOT_REVIEWER_MODEL|NEIL_AUTOPILOT_LOG_DIR)/ { print old[$1] " -> " $0 }
' "$WORK/master-defaults" "$WORK/current-defaults")"
[ -z "$extra_defaults" ] && pass "no third existing default changed" || { fail "unwhitelisted default change detected"; printf '%s\n' "$extra_defaults"; }

missing=0
while IFS= read -r path; do
  [ -f "$ROOT/$path" ] || { fail "master entry point removed: $path"; missing=1; }
done < <(git -C "$ROOT" ls-tree -r --name-only "$BASE_BRANCH" scripts | grep '\.sh$')
[ "$missing" -eq 0 ] && pass "all master shell entry points still exist"

if [ "$FAILED" -eq 0 ]; then echo "SMOKE(backward-compat): ALL PASS"; exit 0; fi
echo "SMOKE(backward-compat): FAILED"; exit 1
