#!/usr/bin/env bash
# smoke-run-track-a.sh — token-free regression test for run-track-a.sh.
#
# Verifies the Track A driver loop end-to-end WITHOUT calling a real model: it
# shims `qodercli` with a stub that echoes controllable status lines and makes a
# trivial file change. Scenarios:
#   1. HAPPY             : verify passes + REVIEW_PASS → all tasks DONE, commits made, exit 0.
#   2. FAIL-CLOSED       : verify always fails → driver stops exit 2, task BLOCKED,
#                          NO commit, NO false DONE.
#   3. COMMIT-FAILURE    : pre-commit hook rejects → exit 2, BLOCKED, no commit.
#   4. TRANSPORT-RETRY   : stub returns exit 1 + "Unable to connect." → 3 retries,
#                          exit 2 BLOCKED, no fixer, -a1/-a2/-a3 logs, round 1 only.
#   5. TIMEOUT-NO-RETRY  : stub sleeps past timeout → exit 2, no retry, wall ≤20s.
#   6. APP-FAIL-CLOSED   : review returns exit 1 + real CR body with REVIEW_FAIL → no
#                          retry, fixer invoked, round advances to 2.
#   7. MARKER-ANCHOR integration: unanchored body verdict fails closed; anchored pass succeeds.
# Also exercises task-state.sh's macOS flock-fallback (stock macOS has no flock).
#
# Usage: bash scripts/smoke-run-track-a.sh    # 0 = all pass, 1 = failure.
set -uo pipefail
# 清场：把开发机 shell 里所有 AUTOPILOT_* 旋钮清掉，再只设本测试需要的。
# 之前只 unset 了 RUN_ID / ROLE，其余约 20 个旋钮会直接泄漏进被测 runner，造成假失败
# 或语义扭曲（已实测：本机 shell 里就存在已导出的 AUTOPILOT_TIMEOUT）。具体危害例子：
#   • AUTOPILOT_TIMEOUT_IMPLEMENT 泄漏 → 场景 5 只设了 AUTOPILOT_TIMEOUT，而分阶段变量优先级更高，
#     stub 会睡满 30s、墙钟断言假失败；
#   • AUTOPILOT_EMPTY_LOG_BYTES 泄漏到 >400 → stub 的填充输出全被当成 EMPTY；
#   • AUTOPILOT_SILENT_EFFORT= 泄漏 → 降档断言假失败。
# 本文件开头那段关于 NEIL_AUTOPILOT_LOG_DIR 的注释已证明“开发机常驻 export”是真实事故模式。
# 保留 AUTOPILOT_SMOKE_SANDBOX（smoke-all 的沙箱标记，属测试 harness 而非生产旋钮）。
_smoke_sandbox_keep="${AUTOPILOT_SMOKE_SANDBOX:-}"
for _v in ${!AUTOPILOT_@}; do unset "$_v"; done
unset _v
[ -z "$_smoke_sandbox_keep" ] || export AUTOPILOT_SMOKE_SANDBOX="$_smoke_sandbox_keep"
unset STUB_MODE
export AUTOPILOT_ALLOW_NESTED=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RUNNER="$SCRIPT_DIR/run-track-a.sh"
PARSE_MARKERS="$SCRIPT_DIR/parse-markers.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# 遥测隔离必须无条件覆盖，不能用 `:=` 兑底：安装指引让使用者把
# NEIL_AUTOPILOT_LOG_DIR export 进 .zshrc，所以开发机的 shell 里它几乎总是已设值——
# 那时 `:=` 不生效，单跑本脚本就会把数百条 TestModel 假事件写进生产日志根
# （已实测到：以为修好了，单跑几次后生产 runs/ 里又多出 28 个 smoke-* 目录）。
# 单个用例如需断言遥测内容，自己在命令行上内联设该变量即可覆盖本行。
export NEIL_AUTOPILOT_LOG_DIR="$WORK/telemetry"
FAILED=0

# ── stub qodercli: reviewer→REVIEW_PASS; implementer/fixer→change file + DONE ──
STUB_BIN="$WORK/bin"; mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/qodercli" <<'STUB'
#!/usr/bin/env bash
wdir=""; attach=""
while [ $# -gt 0 ]; do
  case "$1" in
    -w) wdir="$2"; shift 2;;
    --attachment) attach="$2"; shift 2;;
    -m|-p|--permission-mode) shift 2;;
    *) shift;;
  esac
done
# STUB_MODE overrides default behaviour
case "${STUB_MODE:-}" in
  transport)
    echo "Unable to connect."
    exit 1
    ;;
  timeout)
    # trap "" TERM so kill -TERM doesn't kill us, forcing KILL_AFTER
    trap "" TERM
    sleep 30
    exit 0
    ;;
  silent_dirty)
    # 「干完活一言不发」：先改盘，再零输出 exit 0。实测中模型把整个回合收在
    # thinking/redacted_thinking 里（工具已跑完、文件已落盘）就是这个形状。
    # 只作用于 implementer/fixer；reviewer 正常干活，否则测不出“verify+CR 接管”这个行为。
    if grep -q "代码审查专家" "$attach" 2>/dev/null; then
      printf 'review output %0400d\n' 0
      echo "REVIEW_PASS"
      exit 0
    fi
    echo "silent work $(date +%s)-$RANDOM" >> "$wdir/silent-proof.txt"
    exit 0
    ;;
  review_body_unknown)
    if grep -q "代码审查专家" "$attach" 2>/dev/null; then
      printf 'Body mentions REVIEW_FAIL but has no standalone verdict. %0400d\n' 0
      exit 1
    else
      printf 'stub implementation output %0400d\n' 0
      echo "stub work $(date +%s)-$RANDOM" >> "$wdir/stub-proof.txt"
      echo "**Status:** DONE"
    fi
    ;;
  review_app_fail)
    if grep -q "代码审查专家" "$attach" 2>/dev/null; then
      # Return exit 1 with a fat CR body containing REVIEW_FAIL (APP outcome)
      cat <<'CRBODY'
## Code Review

Examining the changes across 5 files, I found several issues that need attention.

### scripts/x.sh:12
MAJOR: The function does not handle empty input. When called with no arguments, it
will dereference a null pointer and crash the entire pipeline. This is a regression
from the previous version which had a guard clause.

### scripts/y.sh:34
MAJOR: SQL injection vulnerability in the query construction — user-supplied data is
concatenated directly without escaping or parameterisation.

### scripts/z.sh:56
CRITICAL: Hard-coded API key "sk-prod-xxxxxxxxxxxxxxxxxxxx" committed to source. This
must be rotated immediately and moved to an environment variable or secrets manager.

### scripts/w.sh:78
MINOR: Variable name shadows a global; rename to avoid confusion.

Overall the implementation logic in scripts/x.sh is sound but the three major/critical
issues listed above must be resolved before this can be merged.

REVIEW_FAIL
CRBODY
      exit 1
    else
      printf 'stub implementation output %0400d\n' 0
      echo "stub work $(date +%s)-$RANDOM" >> "$wdir/stub-proof.txt"
      echo "**Status:** DONE"
    fi
    ;;
  *)
    if grep -q "代码审查专家" "$attach" 2>/dev/null; then
      printf 'review output %0400d\n' 0
      echo "REVIEW_PASS"
    else
      printf 'stub implementation output %0400d\n' 0
      echo "stub work $(date +%s)-$RANDOM" >> "$wdir/stub-proof.txt"
      echo "**Status:** DONE"
    fi
    ;;
esac
STUB
chmod +x "$STUB_BIN/qodercli"

# ── helper: fresh temp git project (under WORK) with a canonical tasks.md ──────
make_project() {  # $1=verify-cmd  $2=num-tasks  → echoes project dir
  local verify="$1" ntasks="$2" proj chg n
  proj="$(mktemp -d "$WORK/proj.XXXXXX")"
  ( cd "$proj" && git init -q && git config user.email t@t && git config user.name t )
  chg="$proj/autopilot/changes/smoke"; mkdir -p "$chg"
  {
    echo "# Implementation Tasks — smoke"
    echo "> Verify command: \`$verify\`"
    echo "> Total tasks: $ntasks"
    echo
    n=1
    while [ "$n" -le "$ntasks" ]; do
      echo "## Task $n: smoke task $n"
      echo "**Files**: stub-proof.txt"
      echo "**Description**: append a line to stub-proof.txt."
      echo "**Verify**: \`$verify\`"
      echo "**Status**: PENDING"
      echo; echo "---"; echo
      n=$((n + 1))
    done
  } > "$chg/tasks.md"
  echo "$proj"
}

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILED=1; }

echo "===== Scenario 1: HAPPY (verify=true, 2 tasks) ====="
P1="$(make_project true 2)"
set +e
TMPDIR="$WORK" PATH="$STUB_BIN:$PATH" AUTOPILOT_PLATFORM=qoder \
  bash "$RUNNER" --change-dir "$P1/autopilot/changes/smoke" --cwd "$P1" --max-rounds 2 \
  > "$WORK/s1.log" 2>&1
rc1=$?
set -e
[ "$rc1" -eq 0 ] && pass "exit 0" || { fail "exit=$rc1 (expected 0)"; tail -15 "$WORK/s1.log" | sed 's/^/    | /'; }
d1=$(grep -c '^\*\*Status\*\*: DONE$' "$P1/autopilot/changes/smoke/tasks.md" || true)
[ "$d1" -eq 2 ] && pass "2 tasks DONE" || fail "DONE count=$d1 (expected 2)"
c1=$( cd "$P1" && git log --oneline 2>/dev/null | grep -c 'autopilot(track-a)' || true )
[ "$c1" -eq 2 ] && pass "2 commits" || fail "commit count=$c1 (expected 2)"
# harness 自己的运行期产物绝不能被 git add -A 卷进业务提交（已实测到 .lock/pid
# 与 .lock/epoch 被提交）。这里直接断言提交内容，而不是断言锁的存放位置。
lockfiles1=$( cd "$P1" && git log --name-only --pretty=format: 2>/dev/null | grep -c '\.lock/' || true )
[ "$lockfiles1" -eq 0 ] && pass "no harness lock files in commits" || { fail "lock files committed ($lockfiles1)"; ( cd "$P1" && git log --name-only --pretty=format: | grep '\.lock/' | sed 's/^/    | /' ); }

echo ""
echo "===== Scenario 2: FAIL-CLOSED (verify=false, 1 task) ====="
P2="$(make_project false 1)"
set +e
TMPDIR="$WORK" PATH="$STUB_BIN:$PATH" AUTOPILOT_PLATFORM=qoder \
  bash "$RUNNER" --change-dir "$P2/autopilot/changes/smoke" --cwd "$P2" --max-rounds 1 \
  > "$WORK/s2.log" 2>&1
rc2=$?
set -e
[ "$rc2" -eq 2 ] && pass "exit 2 (BLOCKED)" || { fail "exit=$rc2 (expected 2)"; tail -15 "$WORK/s2.log" | sed 's/^/    | /'; }
b2=$(grep -c '^\*\*Status\*\*: BLOCKED$' "$P2/autopilot/changes/smoke/tasks.md" || true)
[ "$b2" -eq 1 ] && pass "task BLOCKED" || fail "BLOCKED count=$b2 (expected 1)"
c2=$( cd "$P2" && git log --oneline 2>/dev/null | grep -c 'autopilot(track-a)' || true )
[ "$c2" -eq 0 ] && pass "no false commit" || fail "commit count=$c2 (expected 0)"

echo ""
echo "===== Scenario 3: COMMIT-FAILURE (pre-commit hook rejects) ====="
P3="$(make_project true 1)"
cat > "$P3/.git/hooks/pre-commit" <<'HOOK'
#!/bin/sh
exit 1
HOOK
chmod +x "$P3/.git/hooks/pre-commit"
set +e
TMPDIR="$WORK" PATH="$STUB_BIN:$PATH" AUTOPILOT_PLATFORM=qoder \
  bash "$RUNNER" --change-dir "$P3/autopilot/changes/smoke" --cwd "$P3" --max-rounds 1 \
  > "$WORK/s3.log" 2>&1
rc3=$?
set -e
[ "$rc3" -eq 2 ] && pass "exit 2 (commit failure → BLOCKED)" || { fail "exit=$rc3 (expected 2)"; tail -15 "$WORK/s3.log" | sed 's/^/    | /'; }
b3=$(grep -c '^\*\*Status\*\*: BLOCKED$' "$P3/autopilot/changes/smoke/tasks.md" || true)
[ "$b3" -eq 1 ] && pass "task BLOCKED (not DONE)" || fail "BLOCKED count=$b3 (expected 1)"
d3=$(grep -c '^\*\*Status\*\*: DONE$' "$P3/autopilot/changes/smoke/tasks.md" || true)
[ "$d3" -eq 0 ] && pass "not falsely DONE" || fail "false DONE count=$d3 (expected 0)"
c3=$( cd "$P3" && git log --oneline 2>/dev/null | grep -c 'autopilot(track-a)' || true )
[ "$c3" -eq 0 ] && pass "no commit" || fail "commit count=$c3 (expected 0)"

echo ""
echo "===== Scenario 4: TRANSPORT-RETRY (stub always exits 1 + 'Unable to connect.') ====="
P4="$(make_project true 1)"
set +e
TMPDIR="$WORK" PATH="$STUB_BIN:$PATH" AUTOPILOT_PLATFORM=qoder \
  STUB_MODE=transport \
  AUTOPILOT_TRANSPORT_RETRIES=3 \
  AUTOPILOT_RETRY_BACKOFF_S=0 \
  bash "$RUNNER" --change-dir "$P4/autopilot/changes/smoke" --cwd "$P4" --max-rounds 2 \
  > "$WORK/s4.log" 2>&1
rc4=$?
set -e

# ① attempt 1/3 .. 3/3 in log
a1=$(grep -c 'transport failure (attempt 1/3)' "$WORK/s4.log" || true)
a3=$(grep -c 'transport failure (attempt 3/3)' "$WORK/s4.log" || true)
[ "$a1" -ge 1 ] && pass "transport failure attempt 1/3 logged" || { fail "attempt 1/3 not found in log"; grep 'transport failure' "$WORK/s4.log" | sed 's/^/    | /'; }
[ "$a3" -ge 1 ] && pass "transport failure attempt 3/3 logged" || { fail "attempt 3/3 not found in log"; grep 'transport failure' "$WORK/s4.log" | sed 's/^/    | /'; }
backoff4=$(grep -c 'transport failure (attempt 1/3) → retry in 0s' "$WORK/s4.log" || true)
[ "$backoff4" -eq 1 ] && pass "AUTOPILOT_RETRY_BACKOFF_S=0 honored" || fail "zero retry backoff was not honored"

# ② round 1 only once, round 2 never
r1=$(grep -c 'round 1' "$WORK/s4.log" || true)
r2=$(grep -c 'round 2' "$WORK/s4.log" || true)
[ "$r1" -eq 1 ] && pass "round 1 appears exactly once" || fail "round 1 count=$r1 (expected 1)"
[ "$r2" -eq 0 ] && pass "round 2 never appears" || fail "round 2 appeared (should not)"

# ③ exit=2, task BLOCKED
[ "$rc4" -eq 2 ] && pass "exit 2 (transport exhausted)" || { fail "exit=$rc4 (expected 2)"; tail -10 "$WORK/s4.log" | sed 's/^/    | /'; }
b4=$(grep -c '^\*\*Status\*\*: BLOCKED$' "$P4/autopilot/changes/smoke/tasks.md" || true)
[ "$b4" -ge 1 ] && pass "task BLOCKED" || fail "BLOCKED count=$b4 (expected ≥1)"

# ④ no fixer dispatched — 行为证据优先：此场景下 stub 全部返回 transport 故障、从不写
#    stub-proof.txt，所以“没有任何 worker 真正跑过”可以直接用文件不存在来钉。
#    日志 grep 只作为辅助：它既依赖 driver 的自由格式措辞（措辞一改就恒为 0、
#    “transport 误派 fixer”的回归静默通过），模式也过宽（`fix.*dispatch` 能命中 prefix/suffix）。
[ ! -f "$P4/stub-proof.txt" ] && pass "no worker actually ran (behavioural: stub-proof absent)" || fail "a worker ran despite transport exhaustion"
fix4=$(grep -c '→ dispatch.*fix\|fix.*→ dispatch\|dispatch(.*fix\|fix.*dispatch' "$WORK/s4.log" || true)
[ "$fix4" -eq 0 ] && pass "no fixer dispatched" || { fail "fixer was dispatched ($fix4 times)"; grep -i 'fix' "$WORK/s4.log" | sed 's/^/    | /'; }

# ⑤ -a1/-a2/-a3 log files generated (look inside the driver log dir captured in TMPDIR)
# The driver logs to $TMPDIR/autopilot-track-a/<change>-<ts>/; find the dir
logdir4="$(ls -1td "$WORK"/autopilot-track-a/smoke-* 2>/dev/null | head -1 || true)"
if [ -n "$logdir4" ]; then
  a1f=$(ls "$logdir4"/task-1-impl-a1.log 2>/dev/null | wc -l | tr -d ' ')
  a2f=$(ls "$logdir4"/task-1-impl-a2.log 2>/dev/null | wc -l | tr -d ' ')
  a3f=$(ls "$logdir4"/task-1-impl-a3.log 2>/dev/null | wc -l | tr -d ' ')
  [ "$a1f" -ge 1 ] && pass "-a1 log exists" || fail "-a1 log missing in $logdir4"
  [ "$a2f" -ge 1 ] && pass "-a2 log exists" || fail "-a2 log missing in $logdir4"
  [ "$a3f" -ge 1 ] && pass "-a3 log exists" || fail "-a3 log missing in $logdir4"
else
  fail "cannot find driver log dir under $WORK/autopilot-track-a/"
fi

echo ""
echo "===== Scenario 5: TIMEOUT-NO-RETRY ====="
P5="$(make_project true 1)"
t5_start="$(date +%s)"
set +e
TMPDIR="$WORK" PATH="$STUB_BIN:$PATH" AUTOPILOT_PLATFORM=qoder \
  STUB_MODE=timeout \
  AUTOPILOT_TIMEOUT=2 AUTOPILOT_KILL_AFTER_S=1 \
  AUTOPILOT_RETRY_BACKOFF_S=0 \
  bash "$RUNNER" --change-dir "$P5/autopilot/changes/smoke" --cwd "$P5" --max-rounds 1 \
  > "$WORK/s5.log" 2>&1
rc5=$?
set -e
t5_end="$(date +%s)"
t5_wall=$(( t5_end - t5_start ))

retry5=$(grep -c 'retry in' "$WORK/s5.log" || true)
[ "$retry5" -eq 0 ] && pass "no 'retry in' (timeout not retried)" || fail "'retry in' found ($retry5 times)"
[ "$rc5" -eq 2 ] && pass "exit 2" || { fail "exit=$rc5 (expected 2)"; tail -10 "$WORK/s5.log" | sed 's/^/    | /'; }
[ "$t5_wall" -le 20 ] && pass "wall clock ≤ 20s (actual ${t5_wall}s)" || fail "wall clock ${t5_wall}s > 20s"

echo ""
echo "===== Scenario 6: APP-FAIL-CLOSED (review returns exit 1 + fat REVIEW_FAIL body) ====="
P6="$(make_project true 1)"
set +e
TMPDIR="$WORK" PATH="$STUB_BIN:$PATH" AUTOPILOT_PLATFORM=qoder \
  STUB_MODE=review_app_fail \
  AUTOPILOT_RETRY_BACKOFF_S=0 \
  bash "$RUNNER" --change-dir "$P6/autopilot/changes/smoke" --cwd "$P6" --max-rounds 2 \
  > "$WORK/s6.log" 2>&1
rc6=$?
set -e

# ① no retry (APP outcome → no retry, goes straight to fixer)
retry6=$(grep -c 'retry in' "$WORK/s6.log" || true)
[ "$retry6" -eq 0 ] && pass "no 'retry in' (APP not retried)" || fail "'retry in' found ($retry6 times)"

# ② fixer is dispatched (the review failure triggered the fixer path)
fix6=$(grep -c 'fix.*dispatch\|dispatch.*fix' "$WORK/s6.log" || true)
[ "$fix6" -ge 1 ] && pass "fixer dispatched" || { fail "fixer not dispatched"; tail -20 "$WORK/s6.log" | sed 's/^/    | /'; }

# ③ round advances to 2
r2_6=$(grep -c 'round 2' "$WORK/s6.log" || true)
[ "$r2_6" -ge 1 ] && pass "round advances to 2" || { fail "round 2 never appears"; grep 'round' "$WORK/s6.log" | sed 's/^/    | /'; }

# ④ 最高危不变量：CR 判 FAIL 就**绝不能** commit、绝不能标 DONE。
# 之前本场景只断言了“没重试 / 派了 fixer / 进了 round 2”，`rc6` 捕获后再无引用，
# 于是“CR 判 FAIL 却照样提交并把 Task 标成 DONE”这条回归完全无网：只要驱动仍然
# 打印 fix dispatch 与 round 2，它照样全绿。而全套用例里 no-commit 只覆盖了 verify 失败
# （Scenario 2）与 commit hook 失败（Scenario 3），**CR 失败路径一条都没有**。
T6="$P6/autopilot/changes/smoke/tasks.md"
[ "$rc6" -eq 2 ] && pass "CR-fail exhausts rounds and exits 2 (fail-closed)" || { fail "exit=$rc6 (expected 2)"; tail -10 "$WORK/s6.log" | sed 's/^/    | /'; }
d6=$(grep -c '^\*\*Status\*\*: DONE$' "$T6" || true)
[ "$d6" -eq 0 ] && pass "CR-fail never marks the Task DONE" || fail "Task marked DONE despite REVIEW_FAIL ($d6)"
b6=$(grep -c '^\*\*Status\*\*: BLOCKED$' "$T6" || true)
[ "$b6" -eq 1 ] && pass "CR-fail marks the Task BLOCKED" || fail "expected 1 BLOCKED status line, got $b6"
c6=$( ( cd "$P6" && git log --oneline 2>/dev/null | grep -c 'autopilot(track-a)' ) || true )
[ "$c6" -eq 0 ] && pass "CR-fail commits nothing" || fail "unreviewed work committed ($c6 autopilot commits)"

echo ""
echo "===== Scenario 7: MARKER-ANCHOR integration ====="


# Driver integration: body mention without anchored verdict must be UNKNOWN and go to fixer.
P7="$(make_project true 1)"
set +e
TMPDIR="$WORK" PATH="$STUB_BIN:$PATH" AUTOPILOT_PLATFORM=qoder \
  STUB_MODE=review_body_unknown AUTOPILOT_RETRY_BACKOFF_S=0 \
  bash "$RUNNER" --change-dir "$P7/autopilot/changes/smoke" --cwd "$P7" --max-rounds 2 \
  > "$WORK/s7.log" 2>&1
rc7=$?
set -e
grep -q 'review = UNKNOWN.*fixer' "$WORK/s7.log" && pass "unanchored body verdict → UNKNOWN/fixer" || fail "unanchored body verdict did not fail closed"
retry7=$(grep -c 'retry in' "$WORK/s7.log" || true)
[ "$retry7" -eq 0 ] && pass "unanchored APP outcome is not transport-retried" || fail "unanchored APP outcome retried $retry7 times"

# Fixture A: body mentions REVIEW_FAIL but no anchored verdict at end → UNKNOWN
FIXTURE_A="$WORK/fixture-a.log"
cat > "$FIXTURE_A" <<'EOF'
This code review found many problems. In fact REVIEW_FAIL appears in this paragraph
as part of a sentence, and again here: REVIEW_FAIL is mentioned, and REVIEW_FAIL
is in the middle of text. There is no anchored verdict at the very end.
Some trailing lines with no verdict.
Another line.
Yet another line.
EOF
rv_a="$("$PARSE_MARKERS" review "$FIXTURE_A")"
[ "$rv_a" = "UNKNOWN" ] && pass "fixture-A (body REVIEW_FAIL, no anchor) → UNKNOWN" || fail "fixture-A expected UNKNOWN, got $rv_a"

# Fixture B: last anchored line is REVIEW_PASS → REVIEW_PASS
FIXTURE_B="$WORK/fixture-b.log"
cat > "$FIXTURE_B" <<'EOF'
Detailed review of the changes.
Everything looks good. The implementation is correct and follows the coding standards.
No CRITICAL or MAJOR issues found.

REVIEW_PASS
EOF
rv_b="$("$PARSE_MARKERS" review "$FIXTURE_B")"
[ "$rv_b" = "REVIEW_PASS" ] && pass "fixture-B (anchored REVIEW_PASS at end) → REVIEW_PASS" || fail "fixture-B expected REVIEW_PASS, got $rv_b"

# Fixture C: anchored Status at end → DONE
FIXTURE_C="$WORK/fixture-c.log"
cat > "$FIXTURE_C" <<'EOF'
Did some work. Status: mentioned in passing earlier in the body.
More text here.

**Status:** DONE
EOF
st_c="$("$PARSE_MARKERS" status "$FIXTURE_C")"
[ "$st_c" = "DONE" ] && pass "fixture-C (anchored **Status:** DONE) → DONE" || fail "fixture-C expected DONE, got $st_c"

# Fixture D: body mentions DONE but no anchored status → UNKNOWN
FIXTURE_D="$WORK/fixture-d.log"
cat > "$FIXTURE_D" <<'EOF'
I am going to mark this as DONE in the middle of a sentence.
The work is clearly DONE from my perspective but no final marker.
EOF
st_d="$("$PARSE_MARKERS" status "$FIXTURE_D")"
[ "$st_d" = "UNKNOWN" ] && pass "fixture-D (body DONE, no anchor) → UNKNOWN" || fail "fixture-D expected UNKNOWN, got $st_d"

echo ""
echo "===== Scenario 8: SILENT-BUT-PRODUCTIVE (zero output, exit 0, worktree modified) ====="
# 真实事故：worker 干完活却只在 thinking 里收尾，stdout 零字节。对 implement 而言这不该
# 停机：后面紧跟着 verify 门禁，而本仓原则就是“控制器自己跑 verify、绝不信自述”。
# 但不变量不得放松：仍须 verify 通过 + 独立 CR 才能 commit。
P8="$(make_project true 1)"
set +e
TMPDIR="$WORK" PATH="$STUB_BIN:$PATH" AUTOPILOT_PLATFORM=qoder \
  STUB_MODE=silent_dirty AUTOPILOT_TRANSPORT_RETRIES=3 AUTOPILOT_RETRY_BACKOFF_S=0 \
  bash "$RUNNER" --change-dir "$P8/autopilot/changes/smoke" --cwd "$P8" --max-rounds 2 \
  > "$WORK/s8.log" 2>&1
rc8=$?
set -e

grep -q 'without a verdict line' "$WORK/s8.log" && pass "unreported work is named as such" || { fail "unreported work not diagnosed"; tail -12 "$WORK/s8.log" | sed 's/^/    | /'; }
grep -q 'letting the verify gate decide' "$WORK/s8.log" && pass "hands the decision to the verify gate" || fail "did not defer to the verify gate"
retry8=$(grep -c 'retry in' "$WORK/s8.log" || true)
[ "$retry8" -eq 0 ] && pass "dirty worktree is never blind-retried" || fail "silent worker retried $retry8 times on a dirty tree"
# verify=true 且 reviewer stub 返回 REVIEW_PASS → 本轮应该真的完成（不再白白丢弃已完成的工作）
[ "$rc8" -eq 0 ] && pass "task completes on verify+CR evidence (exit 0)" || { fail "exit=$rc8 (expected 0)"; tail -12 "$WORK/s8.log" | sed 's/^/    | /'; }
d8=$(grep -c '^\*\*Status\*\*: DONE$' "$P8/autopilot/changes/smoke/tasks.md" || true)
[ "$d8" -eq 1 ] && pass "task marked DONE" || fail "DONE count=$d8 (expected 1)"
c8=$( cd "$P8" && git log --oneline 2>/dev/null | grep -c 'autopilot(track-a)' || true )
[ "$c8" -eq 1 ] && pass "committed after verify+CR passed" || fail "commit count=$c8 (expected 1)"

# 对照：同样静默改盘，但 verify 失败 → 绝不能被当成完成（不变量仍然 fail-closed）
P8b="$(make_project false 1)"
set +e
TMPDIR="$WORK" PATH="$STUB_BIN:$PATH" AUTOPILOT_PLATFORM=qoder \
  STUB_MODE=silent_dirty AUTOPILOT_TRANSPORT_RETRIES=2 AUTOPILOT_RETRY_BACKOFF_S=0 \
  bash "$RUNNER" --change-dir "$P8b/autopilot/changes/smoke" --cwd "$P8b" --max-rounds 1 \
  > "$WORK/s8b.log" 2>&1
rc8b=$?
set -e
[ "$rc8b" -ne 0 ] && pass "silent work with FAILING verify still fails closed" || { fail "exit=$rc8b (expected non-zero)"; tail -10 "$WORK/s8b.log" | sed 's/^/    | /'; }
c8b=$( cd "$P8b" && git log --oneline 2>/dev/null | grep -c 'autopilot(track-a)' || true )
[ "$c8b" -eq 0 ] && pass "nothing committed when verify fails" || fail "commit count=$c8b (expected 0)"

# 对照组：同样零输出但没动过盘 → 仍属可安全重试的静默，且必须立即重试（不退避）。
# 等待对 thinking-only 回合无效，退避只会白白拖长墙钟。
cat > "$STUB_BIN/qodercli-silent-clean" <<'CLEANSTUB'
#!/usr/bin/env bash
exit 0
CLEANSTUB
chmod +x "$STUB_BIN/qodercli-silent-clean"
CLEAN_BIN="$WORK/bin-clean"; mkdir -p "$CLEAN_BIN"
cp "$STUB_BIN/qodercli-silent-clean" "$CLEAN_BIN/qodercli"
P9="$(make_project true 1)"
set +e
start9=$(date +%s)
TMPDIR="$WORK" PATH="$CLEAN_BIN:$PATH" AUTOPILOT_PLATFORM=qoder \
  AUTOPILOT_SILENT_RETRIES=4 AUTOPILOT_RETRY_BACKOFF_S=30 \
  bash "$RUNNER" --change-dir "$P9/autopilot/changes/smoke" --cwd "$P9" --max-rounds 2 \
  > "$WORK/s9.log" 2>&1
rc9=$?
elapsed9=$(( $(date +%s) - start9 ))
set -e
retry9=$(grep -c 'retry immediately' "$WORK/s9.log" || true)
[ "$retry9" -eq 3 ] && pass "clean-tree silence retried immediately 3x (cap 4)" || { fail "immediate retries=$retry9 (expected 3)"; grep -n 'attempt' "$WORK/s9.log" | sed 's/^/    | /'; }
if grep -q 'retry in 30s' "$WORK/s9.log"; then fail "silence must not use exponential backoff"; else pass "silence does not sleep on backoff"; fi
# 退避基数设为 30s：若错误地退避，3 次重试至少要睡 30+60+120=210s。
[ "$elapsed9" -lt 60 ] && pass "silence retry wastes no wall clock (${elapsed9}s)" || fail "silence retry slept too long (${elapsed9}s)"
grep -q 'silent worker output (attempt 4/4)' "$WORK/s9.log" && pass "silence cap honoured (AUTOPILOT_SILENT_RETRIES)" || fail "silence cap not honoured"
[ "$rc9" -eq 2 ] && pass "exit 2 (clean-tree silence exhausted)" || fail "exit=$rc9 (expected 2)"
grep -q 'fail-closed, worker stayed silent' "$WORK/s9.log" && pass "silence exhaustion is not mislabelled transport" || { fail "silence exhaustion still says transport"; tail -4 "$WORK/s9.log" | sed 's/^/    | /'; }

echo ""
echo "===== Scenario 10: SILENT-MODEL FALLBACK (default model mute, fallback speaks) ====="
# 实测依据：同一 review prompt 下 Ultimate 8/15 静默，Performance 0/6、Qwen3.8-Max 0/6。
# 所以静默时死磕同一个模型是浪费；连续静默后换模型必须能把 Task 救回来。
MUTE_BIN="$WORK/bin-mute"; mkdir -p "$MUTE_BIN"
cat > "$MUTE_BIN/qodercli" <<'MUTESTUB'
#!/usr/bin/env bash
model=""; wdir=""; attach=""; effort="none"
while [ $# -gt 0 ]; do
  case "$1" in
    -m) model="$2"; shift 2;;
    -w) wdir="$2"; shift 2;;
    --attachment) attach="$2"; shift 2;;
    --reasoning-effort) effort="$2"; shift 2;;
    -p|--permission-mode) shift 2;;
    *) shift;;
  esac
done
# 记下每次尝试实际用的推理档位，用于断言“首次不降档、重试才降档”。
printf '%s\n' "$effort" >> "$EFFORT_LOG"
# MuteModel 完全不开口（模拟 thinking-only 回合）；其他模型正常干活。
if [ "$model" = MuteModel ]; then exit 0; fi
if grep -q "代码审查专家" "$attach" 2>/dev/null; then
  printf 'review body %0400d\n' 0
  echo "REVIEW_PASS"
else
  printf 'impl body %0400d\n' 0
  echo "work $(date +%s)-$RANDOM" >> "$wdir/fallback-proof.txt"
  echo "**Status:** DONE"
fi
MUTESTUB
chmod +x "$MUTE_BIN/qodercli"
EFFORT_LOG="$WORK/effort.log"; : > "$EFFORT_LOG"; export EFFORT_LOG
P10="$(make_project true 1)"
set +e
TMPDIR="$WORK" PATH="$MUTE_BIN:$PATH" AUTOPILOT_PLATFORM=qoder \
  AUTOPILOT_SILENT_RETRIES=5 AUTOPILOT_SILENT_SWITCH_AFTER=2 AUTOPILOT_SILENT_FALLBACK_MODEL=SpeakModel \
  bash "$RUNNER" --change-dir "$P10/autopilot/changes/smoke" --cwd "$P10" \
  --impl-model MuteModel --review-model MuteModel --max-rounds 2 \
  > "$WORK/s10.log" 2>&1
rc10=$?
set -e
grep -q 'switching to SpeakModel' "$WORK/s10.log" && pass "fallback model kicks in after repeated silence" || { fail "no model switch happened"; grep -n 'silent\|switch' "$WORK/s10.log" | sed 's/^/    | /'; }
[ "$rc10" -eq 0 ] && pass "fallback rescues the run (exit 0)" || { fail "exit=$rc10 (expected 0)"; tail -12 "$WORK/s10.log" | sed 's/^/    | /'; }
d10=$(grep -c '^\*\*Status\*\*: DONE$' "$P10/autopilot/changes/smoke/tasks.md" || true)
[ "$d10" -eq 1 ] && pass "task DONE via fallback model" || fail "DONE count=$d10 (expected 1)"
[ -s "$P10/fallback-proof.txt" ] && pass "fallback worker really did the work" || fail "no work produced by fallback"
# 默认模型先被试过，不能一上来就降级（否则白白丢掉默认模型的质量）。
grep -q 'silent worker output (attempt 1/5)' "$WORK/s10.log" && pass "default model is tried first" || fail "default model was skipped"
# 降档阶梯：第一次尝试不能降档（保质量），静默后必须降档并真的透传给 CLI。
grep -q "lowering reasoning effort to 'low'" "$WORK/s10.log" && pass "reasoning effort is lowered after silence" || fail "reasoning effort was never lowered"
first_eff=$(sed -n '1p' "$MUTE_BIN/../effort.log" 2>/dev/null || true)
[ "$first_eff" = "none" ] && pass "attempt 1 keeps full reasoning depth" || fail "attempt 1 effort=$first_eff (expected none)"
later_eff=$(sed -n '2p' "$MUTE_BIN/../effort.log" 2>/dev/null || true)
[ "$later_eff" = "low" ] && pass "attempt 2 runs with --reasoning-effort low" || fail "attempt 2 effort=$later_eff (expected low)"
# 关闭开关后必须回到纯重试、不换模型。
P11="$(make_project true 1)"
set +e
TMPDIR="$WORK" PATH="$MUTE_BIN:$PATH" AUTOPILOT_PLATFORM=qoder \
  AUTOPILOT_SILENT_RETRIES=2 AUTOPILOT_SILENT_FALLBACK_MODEL= \
  bash "$RUNNER" --change-dir "$P11/autopilot/changes/smoke" --cwd "$P11" \
  --impl-model MuteModel --review-model MuteModel --max-rounds 1 \
  > "$WORK/s11.log" 2>&1
rc11=$?
set -e
if grep -q 'switching to' "$WORK/s11.log"; then fail "fallback ignored the opt-out"; else pass "empty AUTOPILOT_SILENT_FALLBACK_MODEL disables the switch"; fi
[ "$rc11" -eq 2 ] && pass "opt-out still fails closed (exit 2)" || fail "exit=$rc11 (expected 2)"

echo ""
if [ "$FAILED" -eq 0 ]; then echo "SMOKE(run-track-a): ALL PASS"; exit 0; fi
echo "SMOKE(run-track-a): FAILURES"; exit 1
