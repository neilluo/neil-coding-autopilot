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
# 遥测必须强制开启：本文件末尾的 canary 以“沙箱里确实落了事件”为判据，
# 而开发机常年 export NEIL_AUTOPILOT_TELEMETRY=0（全局关遥测）—— 那时事件一条都不会写，
# canary 必然 FAIL，健康套件被环境变量搞红（已被交叉审查指出）。smoke 不得依赖环境配置。
export NEIL_AUTOPILOT_TELEMETRY=1
# 遥测隔离无条件覆盖：本脚本会实跑 run-track-a / dispatch，不隔离就会把测试事件
# 写进生产日志根（开发机 shell 里 NEIL_AUTOPILOT_LOG_DIR 几乎总是已 export）。
# 下方个别用例仍可在命令行内联该变量来断言遥测内容。
export NEIL_AUTOPILOT_LOG_DIR="$WORK/telemetry"
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
# dry-run 成功的正确语义是 rc=0。旧写法只排除 rc=2：若 AUTOPILOT_ALLOW_NESTED=1 路径
# 回归成直接崩溃（rc=1，如 override 分支被误删、或嵌套环境下参数解析报错），
# "override works" 照样 PASS —— 而无人值守链路里嵌套派生会全数中断。
[ "$RC" -eq 0 ] && pass 'run-track-a nested override works' || fail "run-track-a nested override (rc=$RC, expected 0)"
run_capture "$WORK/out" "$WORK/err" env -u AUTOPILOT_ALLOW_NESTED AUTOPILOT_ROLE=worker bash "$AUTOPILOT" --dry-run --change-dir "$CHANGE" --cwd "$PROJECT"
[ "$RC" -eq 2 ] && grep -q refused "$WORK/err" && pass 'run-autopilot refuses nested worker' || fail 'run-autopilot nested guard'

printf 'prompt\n' > "$WORK/prompt.md"
run_capture "$WORK/out" "$WORK/err" env AUTOPILOT_ROLE=worker AUTOPILOT_PLATFORM=qoder PATH="$WORK/bin:$PATH" bash "$DISPATCH" --model Ultimate --cwd "$PROJECT" --prompt-file "$WORK/prompt.md" --instruction x --timeout 0
[ "$RC" -eq 2 ] && grep -q 'nested worker spawn refused' "$WORK/err" && pass 'dispatch refuses nested real worker' || fail 'dispatch real-model nested guard'
run_capture "$WORK/out" "$WORK/err" env AUTOPILOT_ROLE=worker AUTOPILOT_PLATFORM=qoder AUTOPILOT_USAGE_JSON=0 PATH="$WORK/bin:$PATH" bash "$DISPATCH" --model TestModel --cwd "$PROJECT" --prompt-file "$WORK/prompt.md" --instruction x --timeout 0
[ "$RC" -eq 0 ] && pass 'dispatch permits nested TestModel' || fail 'dispatch TestModel exception'

# 锁已从 $CHANGE/.lock 移到 TMPDIR（否则 git add -A 会把它提进业务仓库），
# 这里用 AUTOPILOT_LOCK_DIR 显式指定一个可断言的路径，不再依赖它落在哪里。
LOCKD="$WORK/track-a.lock"
mkdir "$LOCKD"
printf '%s\n' "$$" > "$LOCKD/pid"
printf '%s\n' "$(date +%s)" > "$LOCKD/epoch"
run_capture "$WORK/out" "$WORK/err" env AUTOPILOT_ALLOW_NESTED=1 AUTOPILOT_LOCK_DIR="$LOCKD" bash "$RUNNER" --dry-run --change-dir "$CHANGE" --cwd "$PROJECT"
[ "$RC" -eq 2 ] && grep -q "PID $$" "$WORK/err" && pass 'active lock refuses second runner' || fail 'active lock guard'
printf '%s\n' "$(( $(date +%s) - 46800 ))" > "$LOCKD/epoch"
run_capture "$WORK/out" "$WORK/err" env AUTOPILOT_ALLOW_NESTED=1 AUTOPILOT_LOCK_DIR="$LOCKD" bash "$RUNNER" --dry-run --change-dir "$CHANGE" --cwd "$PROJECT"
# 同 65 行：dry-run 接管成功的正确语义是 rc=0。`-ne 2` 会让“接管逻辑回归成崩溃（rc=1）
# 但 EXIT trap 仍删掉了锁目录”这条路径同时满足两个条件而 PASS —— 而它的现实症状是
# 无人值守链路被一个 13 小时前的死锁永久挡住。
[ "$RC" -eq 0 ] && [ ! -d "$LOCKD" ] && pass '13-hour lock is taken over and cleaned' || fail "stale lock takeover (rc=$RC, lockdir_present=$([ -d "$LOCKD" ] && echo yes || echo no))"
# 不得回归到业务仓库内加锁。
run_capture "$WORK/out" "$WORK/err" env AUTOPILOT_ALLOW_NESTED=1 bash "$RUNNER" --dry-run --change-dir "$CHANGE" --cwd "$PROJECT"
[ ! -e "$CHANGE/.lock" ] && pass 'lock never lands inside the consumer repo' || fail 'lock created inside the consumer repo'

run_capture "$WORK/out" "$WORK/err" env AUTOPILOT_ALLOW_NESTED=1 AUTOPILOT_PLATFORM=qoder AUTOPILOT_USAGE_JSON=0 AUTOPILOT_RETRY_BACKOFF_S=0 TMPDIR="$WORK" PATH="$WORK/bin:$PATH" bash "$RUNNER" --change-dir "$CHANGE" --cwd "$PROJECT" --impl-model TestModel --review-model TestModel --max-rounds 1
PROMPT_DIR="$(ls -dt "$WORK"/autopilot-track-a/smoke-* 2>/dev/null | sed -n '1p')"
printf '# Smoke\n\n## Task 1: Fix fixture\n\n**Status**: PENDING\n\n**Verify**: `false`\n' > "$CHANGE/tasks.md"
git -C "$PROJECT" add "$CHANGE/tasks.md"
git -C "$PROJECT" commit -qm 'reset fix fixture'
# 本用例要钉的是「fix 提示词带递归禁令」，为此得先让流水线真的生成一份 fix 提示词。
# 必须用 --max-rounds 2（不能是 1）：run-track-a 现在在最后一轮**不再派 fixer**
# （它的产出永远不会再过 verify/CR/commit，只会白烧一次 worker 并给工作树叠上
# 一层未经门禁的修改），所以 max-rounds=1 + verify 失败下根本不会产生 fix 提示词。
# max-rounds=2 时：round 1 verify 失败 → 派 fixer（生成 task-1-fix-1-prompt.md）→
# round 2 verify 再失败 → 本轮已是最后一轮，不再派 fixer → BLOCKED。
run_capture "$WORK/out" "$WORK/err" env AUTOPILOT_ALLOW_NESTED=1 AUTOPILOT_PLATFORM=qoder AUTOPILOT_USAGE_JSON=0 AUTOPILOT_RETRY_BACKOFF_S=0 TMPDIR="$WORK" PATH="$WORK/bin:$PATH" bash "$RUNNER" --change-dir "$CHANGE" --cwd "$PROJECT" --impl-model TestModel --review-model TestModel --max-rounds 2
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

# 本用例必须用一个**专属且此前从未被写过**的日志根。曾用 "$WORK/telemetry"，而第 15 行
# 已全局 export NEIL_AUTOPILOT_LOG_DIR="$WORK/telemetry"：第 70/72 行的 dispatch 实跑与
# 第 93/104 行的 run-track-a 实跑早就往那里发过遥测、建好了 runs/ —— 于是下面那条 canary
# 恒真（它证明的是“前面的用例写过事件”，而不是“本次 smoke-dispatch 把事件写进了沙箱”），
# 整条断言退化成装饰。换成 telemetry-iso/ 后，runs/ 只可能由本行这次调用创建。
TELEMETRY_DIR="$WORK/telemetry-iso"
[ ! -e "$TELEMETRY_DIR" ] || { printf 'FAIL: %s\n' "telemetry-iso dir already exists — canary would be vacuous" >&2; FAILED=1; }
# 必须同时传 AUTOPILOT_SMOKE_SANDBOX=1：smoke-dispatch.sh 现在的隔离逻辑是“未标沙箱就
# 自己 export 一个临时日志根”，不传标记时它会**覆盖掉**这里传入的 NEIL_AUTOPILOT_LOG_DIR，
# 事件全落进它自己的 mktemp 目录并在退出时删除 → $TELEMETRY_DIR 里永远不会出现 real-xyz，
# 无论它是否真的隔离了 run id，下面那条断言都恒 PASS（单跑本文件时）。
run_capture "$WORK/out" "$WORK/err" env NEIL_AUTOPILOT_LOG_DIR="$TELEMETRY_DIR" AUTOPILOT_SMOKE_SANDBOX=1 AUTOPILOT_RUN_ID=real-xyz bash "$SCRIPT_DIR/smoke-dispatch.sh"
# 嵌套跑的 RC 必须表态：它在写出事件**之后**自己的断言挂了（exit 1）时，下面两条
# 断言依旧双双 PASS，没人看退出码；而“沙箱模式”（AUTOPILOT_SMOKE_SANDBOX=1）这条路径
# 只在本用例被行使（smoke-all 跑 smoke-dispatch 时不带该标记），这里不报就无处可报。
[ "$RC" -eq 0 ] && pass 'nested smoke-dispatch itself passes in sandbox mode' || { fail "nested smoke-dispatch rc=$RC in sandbox mode"; tail -5 "$WORK/out" | sed 's/^/    | /'; }
# canary：先确认沙箱里真的落了事件，否则“没有 real-xyz”可能只是“压根没写事件”（
# 甚至写到了生产日志根）—— 那正是本套件要防的泄露形态。
[ -d "$TELEMETRY_DIR/runs" ] && [ -n "$(find "$TELEMETRY_DIR/runs" -name '*.jsonl' -size +0 2>/dev/null | head -1)" ] \
  && pass 'smoke telemetry landed in the sandbox (isolation check is meaningful)' \
  || fail 'no events in sandbox — the run-id isolation assertion would be vacuous'
if grep -R 'real-xyz' "$TELEMETRY_DIR" >/dev/null 2>&1; then fail 'smoke telemetry inherited real run id'; else pass 'smoke telemetry is isolated'; fi

[ "$FAILED" -eq 0 ] || exit 1
printf 'PASS: smoke-recursion-guard\n'
