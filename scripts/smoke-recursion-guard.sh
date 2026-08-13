#!/usr/bin/env bash
# smoke-recursion-guard.sh — token-free checks for recursion and lock guards.
set -uo pipefail
unset AUTOPILOT_RUN_ID

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RUNNER="$SCRIPT_DIR/run-track-a.sh"
AUTOPILOT="$SCRIPT_DIR/run-autopilot.sh"
DISPATCH="$SCRIPT_DIR/dispatch.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILED=1; }
run_capture() {
  local out="$1" err="$2"
  shift 2
  set +e
  "$@" >"$out" 2>"$err"
  RC=$?
  set -e
}

PROJECT="$WORK/project"
CHANGE="$PROJECT/autopilot/changes/smoke"
mkdir -p "$CHANGE" "$WORK/bin"
printf '# Smoke\n\n> Verify: `true`\n\n## Task 1: Guard fixture\n\n**Status**: PENDING\n\n**Verify**: `true`\n' > "$CHANGE/tasks.md"
printf 'fixture\n' > "$PROJECT/fixture.txt"
git -C "$PROJECT" init -q
git -C "$PROJECT" config user.email smoke@example.com
git -C "$PROJECT" config user.name Smoke
git -C "$PROJECT" add .
git -C "$PROJECT" commit -qm init

cat > "$WORK/bin/qodercli" <<'STUB'
#!/usr/bin/env bash
attach=""; wdir=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --attachment) attach="$2"; shift 2 ;;
    -w) wdir="$2"; shift 2 ;;
    -m|-p|--permission-mode) shift 2 ;;
    *) shift ;;
  esac
done
if printf '%s' "$attach" | grep -q review; then
  printf '%0300d\nREVIEW_PASS\n' 0
else
  [ -z "$wdir" ] || printf 'changed\n' >> "$wdir/fixture.txt"
  printf '%0300d\n**Status:** DONE\n' 0
fi
STUB
chmod +x "$WORK/bin/qodercli"

run_capture "$WORK/out" "$WORK/err" env -u AUTOPILOT_ALLOW_NESTED AUTOPILOT_ROLE=worker bash "$RUNNER" --dry-run --change-dir "$CHANGE" --cwd "$PROJECT"
[ "$RC" -eq 2 ] && grep -q refused "$WORK/err" && pass 'run-track-a refuses nested worker' || fail 'run-track-a nested guard'
run_capture "$WORK/out" "$WORK/err" env AUTOPILOT_ROLE=worker AUTOPILOT_ALLOW_NESTED=1 bash "$RUNNER" --dry-run --change-dir "$CHANGE" --cwd "$PROJECT"
[ "$RC" -ne 2 ] && pass 'run-track-a nested override works' || fail 'run-track-a nested override'
run_capture "$WORK/out" "$WORK/err" env -u AUTOPILOT_ALLOW_NESTED AUTOPILOT_ROLE=worker bash "$AUTOPILOT" --dry-run --change-dir "$CHANGE" --cwd "$PROJECT"
[ "$RC" -eq 2 ] && grep -q refused "$WORK/err" && pass 'run-autopilot refuses nested worker' || fail 'run-autopilot nested guard'

printf 'prompt\n' > "$WORK/prompt.md"
run_capture "$WORK/out" "$WORK/err" env AUTOPILOT_ROLE=worker AUTOPILOT_PLATFORM=qoder PATH="$WORK/bin:$PATH" bash "$DISPATCH" --model Ultimate --cwd "$PROJECT" --prompt-file "$WORK/prompt.md" --instruction x --timeout 0
[ "$RC" -eq 2 ] && grep -q 'nested worker spawn refused' "$WORK/err" && pass 'dispatch refuses nested real worker' || fail 'dispatch real-model nested guard'
run_capture "$WORK/out" "$WORK/err" env AUTOPILOT_ROLE=worker AUTOPILOT_PLATFORM=qoder AUTOPILOT_USAGE_JSON=0 PATH="$WORK/bin:$PATH" bash "$DISPATCH" --model TestModel --cwd "$PROJECT" --prompt-file "$WORK/prompt.md" --instruction x --timeout 0
[ "$RC" -eq 0 ] && pass 'dispatch permits nested TestModel' || fail 'dispatch TestModel exception'

mkdir "$CHANGE/.lock"
printf '%s\n' "$$" > "$CHANGE/.lock/pid"
printf '%s\n' "$(date +%s)" > "$CHANGE/.lock/epoch"
run_capture "$WORK/out" "$WORK/err" env AUTOPILOT_ALLOW_NESTED=1 bash "$RUNNER" --dry-run --change-dir "$CHANGE" --cwd "$PROJECT"
[ "$RC" -eq 2 ] && grep -q "PID $$" "$WORK/err" && pass 'active lock refuses second runner' || fail 'active lock guard'
printf '%s\n' "$(( $(date +%s) - 46800 ))" > "$CHANGE/.lock/epoch"
run_capture "$WORK/out" "$WORK/err" env AUTOPILOT_ALLOW_NESTED=1 bash "$RUNNER" --dry-run --change-dir "$CHANGE" --cwd "$PROJECT"
[ "$RC" -ne 2 ] && [ ! -d "$CHANGE/.lock" ] && pass '13-hour lock is taken over and cleaned' || fail 'stale lock takeover'

run_capture "$WORK/out" "$WORK/err" env AUTOPILOT_ALLOW_NESTED=1 AUTOPILOT_PLATFORM=qoder AUTOPILOT_USAGE_JSON=0 AUTOPILOT_RETRY_BACKOFF_S=0 TMPDIR="$WORK" PATH="$WORK/bin:$PATH" bash "$RUNNER" --change-dir "$CHANGE" --cwd "$PROJECT" --impl-model TestModel --review-model TestModel --max-rounds 1
PROMPT_DIR="$(ls -dt "$WORK"/autopilot-track-a/smoke-* 2>/dev/null | sed -n '1p')"
printf '# Smoke\n\n## Task 1: Fix fixture\n\n**Status**: PENDING\n\n**Verify**: `false`\n' > "$CHANGE/tasks.md"
git -C "$PROJECT" add "$CHANGE/tasks.md"
git -C "$PROJECT" commit -qm 'reset fix fixture'
run_capture "$WORK/out" "$WORK/err" env AUTOPILOT_ALLOW_NESTED=1 AUTOPILOT_PLATFORM=qoder AUTOPILOT_USAGE_JSON=0 AUTOPILOT_RETRY_BACKOFF_S=0 TMPDIR="$WORK" PATH="$WORK/bin:$PATH" bash "$RUNNER" --change-dir "$CHANGE" --cwd "$PROJECT" --impl-model TestModel --review-model TestModel --max-rounds 1
FIX_PROMPT_DIR="$(ls -dt "$WORK"/autopilot-track-a/smoke-* 2>/dev/null | sed -n '1p')"
for kind in impl fix review; do
  case "$kind" in
    impl) file="$PROMPT_DIR/task-1-impl-prompt.md" ;;
    fix) file="$FIX_PROMPT_DIR/task-1-fix-1-prompt.md" ;;
    review) file="$PROMPT_DIR/task-1-review-1-prompt.md" ;;
  esac
  grep -q '禁止调用任何 autopilot-\* / using-neil-autopilot / neil-coding-autopilot skill' "$file" 2>/dev/null \
    && grep -q '禁止执行 run-track-a.sh / run-autopilot.sh / dispatch.sh' "$file" 2>/dev/null \
    && grep -q '只做本 Task 描述的事' "$file" 2>/dev/null \
    && pass "$kind prompt has recursion bans" || fail "$kind prompt recursion bans"
done

TELEMETRY_DIR="$WORK/telemetry"
mkdir -p "$TELEMETRY_DIR"
run_capture "$WORK/out" "$WORK/err" env NEIL_AUTOPILOT_LOG_DIR="$TELEMETRY_DIR" AUTOPILOT_RUN_ID=real-xyz bash "$SCRIPT_DIR/smoke-dispatch.sh"
if grep -R 'real-xyz' "$TELEMETRY_DIR" >/dev/null 2>&1; then fail 'smoke telemetry inherited real run id'; else pass 'smoke telemetry is isolated'; fi

[ "$FAILED" -eq 0 ] || exit 1
printf 'PASS: smoke-recursion-guard\n'
