#!/usr/bin/env bash
# smoke-run-autopilot.sh — token-free regression test for run-autopilot.sh.
#
# Verifies the Track A end-to-end orchestrator (loop → finish → evolve)
# WITHOUT calling a real model: shims `qodercli` with a stub that routes on
# attachment content (reviewer / finish / evolve / implementer-fixer) and
# drops hit-files for finish/evolve so the test can assert whether they ran.
#   1. HAPPY       : verify passes + REVIEW_PASS → loop DONE, finish + evolve
#                     both invoked (hit files exist), exit 0.
#   2. FAIL-CLOSED : verify always fails, --max-rounds 1 → loop BLOCKED exit 2,
#                     finish/evolve NEVER invoked (no hit files — no relay
#                     after a fail-closed stop).
#
# Usage: bash scripts/smoke-run-autopilot.sh    # 0 = all pass, 1 = failure.
set -uo pipefail
unset AUTOPILOT_RUN_ID
export AUTOPILOT_ALLOW_NESTED=1
unset AUTOPILOT_ROLE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RUNNER="$SCRIPT_DIR/run-autopilot.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# 遥测隔离无条件覆盖（同 smoke-run-track-a.sh）：开发机 shell 里该变量几乎总是已
# export（安装指引要求写进 .zshrc），用 `:=` 兑底等于没隔离，测试事件会流进生产
# 日志根，daily-analysis 聚合出来的就是假数据。
export NEIL_AUTOPILOT_LOG_DIR="$WORK/telemetry"
FAILED=0

# ── stub qodercli: reviewer→REVIEW_PASS; finish/evolve→hit-file + status;
#    otherwise (implementer/fixer)→change file + DONE ────────────────────────
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
if grep -q "代码审查专家" "$attach" 2>/dev/null; then
  printf 'review output %0400d\n' 0
  echo "REVIEW_PASS"
elif grep -q "autopilot-finish" "$attach" 2>/dev/null; then
  touch "$WORK/finish.hit"
  # FINISH_SILENT_UNTIL：前 N 次完全不开口（复现真实事故：finish 静默一次就把整条
  # 无人值守流水线杀在 loop 全部成功之后），且不碰工作树，因此重试是安全的。
  printf 'x\n' >> "$WORK/finish.calls"
  if [ "$(wc -l < "$WORK/finish.calls" | tr -d '[:space:]')" -le "${FINISH_SILENT_UNTIL:-0}" ]; then exit 0; fi
  printf 'finish output %0400d\n' 0
  echo "FINISH_STATUS=DONE"
elif grep -q "autopilot-evolve" "$attach" 2>/dev/null; then
  touch "$WORK/evolve.hit"
  # EVOLVE_SILENT_WITH_ARTIFACT：写出合规 raw 笔记但不报数（真实碰到过的形态）。
  if [ -n "${EVOLVE_SILENT_WITH_ARTIFACT:-}" ]; then
    mkdir -p "$wdir/autopilot/knowledge/raw"
    printf '---\ncreated: 2026-08-15\n---\n\n# stub evolve note\n' > "$wdir/autopilot/knowledge/raw/20260815-stub.md"
    exit 0
  fi
  printf 'evolve output %0400d\n' 0
  echo "EVOLVE_STATUS=DONE"
else
  echo "stub work $(date +%s)-$RANDOM" >> "$wdir/stub-proof.txt"
  printf 'worker output %0400d\n' 0
  echo "**Status:** DONE"
fi
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

echo "===== Scenario 1: HAPPY (verify=true, 1 task) ====="
P1="$(make_project true 1)"
rm -f "$WORK/finish.hit" "$WORK/evolve.hit"
set +e
WORK="$WORK" TMPDIR="$WORK" PATH="$STUB_BIN:$PATH" AUTOPILOT_PLATFORM=qoder \
  bash "$RUNNER" --change-dir "$P1/autopilot/changes/smoke" --cwd "$P1" \
  > "$WORK/s1.log" 2>&1
rc1=$?
set -e
[ "$rc1" -eq 0 ] && pass "exit 0" || { fail "exit=$rc1 (expected 0)"; tail -15 "$WORK/s1.log" | sed 's/^/    | /'; }
# finish 现在默认确定性执行（C10），所以不再有 finish worker 被调用——该断言改为
# 验证真正的效果：归档已发生（XOR 不变量）。拿 worker 是否被调用当判据是在测实现、不是测行为。
grep -q 'finish → deterministic' "$WORK/s1.log" && pass "finish ran deterministically (no agent in the merge path)" || fail "finish did not take the deterministic path"
[ ! -d "$P1/autopilot/changes/smoke" ] && pass "change dir left changes/ (archived)" || fail "change dir still in changes/"
find "$P1/autopilot/archive" -maxdepth 4 -type d -name '*-smoke' 2>/dev/null | grep -q . && pass "change landed in archive/" || fail "change not archived"
[ -f "$WORK/evolve.hit" ] && pass "evolve.hit exists (evolve invoked)" || fail "evolve.hit missing"

echo ""
echo "===== Scenario 2: FAIL-CLOSED (verify=false, 1 task, --max-rounds 1) ====="
P2="$(make_project false 1)"
rm -f "$WORK/finish.hit" "$WORK/evolve.hit"
set +e
WORK="$WORK" TMPDIR="$WORK" PATH="$STUB_BIN:$PATH" AUTOPILOT_PLATFORM=qoder \
  bash "$RUNNER" --change-dir "$P2/autopilot/changes/smoke" --cwd "$P2" --max-rounds 1 \
  > "$WORK/s2.log" 2>&1
rc2=$?
set -e
[ "$rc2" -eq 2 ] && pass "exit 2 (loop BLOCKED)" || { fail "exit=$rc2 (expected 2)"; tail -15 "$WORK/s2.log" | sed 's/^/    | /'; }
# 不能用 `[ ! -f "$WORK/finish.hit" ]` 当判据：finish 现在默认走确定性路径（C10），
# 根本不会调 qodercli stub，而 finish.hit 只由 stub 创建 —— 那条断言已经**恒真**：
# 即使 fail-closed 回归成“loop BLOCKED 后照样接力 finish”，它也照样 PASS，
# 于是本套件最核心的保护在 finish 侧失去检测能力。Scenario 1 已经为同一原因换过判据，
# 这里改成对**行为**的断言：阶段根本没进入，且归档没发生。
grep -q 'stage 2/3: finish' "$WORK/s2.log" && fail "finish stage ran after a BLOCKED loop" || pass "finish stage never entered (no relay after BLOCKED)"
[ -d "$P2/autopilot/changes/smoke" ] && pass "change NOT archived after a BLOCKED loop" || fail "change was archived despite a BLOCKED loop"
[ ! -f "$WORK/evolve.hit" ] && pass "evolve.hit NOT created (no relay after BLOCKED)" || fail "evolve.hit unexpectedly exists"

echo ""
echo "===== Scenario 3: SILENT finish —— 静默必须被重试救回来（worker 模式）====="
# 真实事故：finish worker 静默（rc=0、零输出），而本脚本当时每阶段只 dispatch 一次，
# 于是 loop 全部成功后整条流水线死在 finish，日志只说 “BLOCKED (status=UNKNOWN)”。
# 也顺带验证了 FINISH_STATUS= / EVOLVE_STATUS= 这两种真实标记能被解析（旧解析器只认
# `**Status:**`，导致 finish 无论成败都判 BLOCKED）。
P3="$(make_project true 1)"
rm -f "$WORK/finish.hit" "$WORK/evolve.hit" "$WORK/finish.calls"
set +e
start3=$(date +%s)
TMPDIR="$WORK" PATH="$STUB_BIN:$PATH" AUTOPILOT_PLATFORM=qoder WORK="$WORK" \
  AUTOPILOT_FINISH_MODE=worker \
  FINISH_SILENT_UNTIL=2 AUTOPILOT_SILENT_RETRIES=5 AUTOPILOT_RETRY_BACKOFF_S=30 \
  bash "$RUNNER" --change-dir "$P3/autopilot/changes/smoke" --cwd "$P3" --max-rounds 2 \
  > "$WORK/s3.log" 2>&1
rc3=$?
elapsed3=$(( $(date +%s) - start3 ))
set -e
grep -q 'finish: silent worker output (attempt 1/5)' "$WORK/s3.log" && pass "silent finish is retried, not fatal" || { fail "silent finish was not retried"; grep -n 'finish' "$WORK/s3.log" | sed 's/^/    | /'; }
grep -q "lowering reasoning effort" "$WORK/s3.log" && pass "reasoning effort is lowered on retry" || fail "effort was never lowered"
[ "$rc3" -eq 0 ] && pass "pipeline completes through finish+evolve (exit 0)" || { fail "exit=$rc3 (expected 0)"; tail -12 "$WORK/s3.log" | sed 's/^/    | /'; }
grep -q 'finish OK' "$WORK/s3.log" && pass "FINISH_STATUS=DONE is parsed" || fail "FINISH_STATUS=DONE not parsed"
grep -q 'evolve OK' "$WORK/s3.log" && pass "EVOLVE_STATUS=DONE is parsed" || fail "EVOLVE_STATUS=DONE not parsed"
grep -q 'ALL STAGES DONE' "$WORK/s3.log" && pass "all three stages completed" || fail "pipeline did not reach ALL STAGES DONE"
# 静默重试不得退避：退避基数设 30s，若误用则 2 次重试至少多睡 30+60s。
[ "$elapsed3" -lt 60 ] && pass "silent retries waste no wall clock (${elapsed3}s)" || fail "silent retries slept too long (${elapsed3}s)"

echo ""
echo "===== Scenario 4: evolve 静默但已写知识 —— 必须凭产物验收并提交 ====="
# 真实碰到过：evolve worker 已写出 633B 的合规 raw 笔记（含 front-matter），却未输出
# EVOLVE_STATUS=DONE，于是整条流水线在最后一步被判失败——而知识已经沉淀完了。
# 产物也必须被提交：否则永久留脏，下一轮 finish 的工作树清洁门禁会被它卡住。
P4="$(make_project true 1)"
rm -f "$WORK/finish.hit" "$WORK/evolve.hit" "$WORK/finish.calls"
set +e
TMPDIR="$WORK" PATH="$STUB_BIN:$PATH" AUTOPILOT_PLATFORM=qoder WORK="$WORK" \
  EVOLVE_SILENT_WITH_ARTIFACT=1 AUTOPILOT_SILENT_RETRIES=2 \
  bash "$RUNNER" --change-dir "$P4/autopilot/changes/smoke" --cwd "$P4" --max-rounds 2 \
  > "$WORK/s4.log" 2>&1
rc4=$?
set -e
grep -q 'accepting on artifact evidence' "$WORK/s4.log" && pass "silent evolve accepted on artifact evidence" || { fail "artifact-based acceptance did not trigger"; tail -8 "$WORK/s4.log" | sed 's/^/    | /'; }
[ "$rc4" -eq 0 ] && pass "pipeline completes (exit 0)" || { fail "exit=$rc4 (expected 0)"; tail -10 "$WORK/s4.log" | sed 's/^/    | /'; }
[ -f "$P4/autopilot/knowledge/raw/20260815-stub.md" ] && pass "knowledge note present" || fail "knowledge note missing"
grep -q 'committed the knowledge artifacts' "$WORK/s4.log" && pass "knowledge artifacts committed" || fail "knowledge artifacts were not committed"
left=$( cd "$P4" && git status --porcelain -- autopilot/knowledge | wc -l | tr -d ' ' )
[ "$left" = "0" ] && pass "no knowledge files left uncommitted" || fail "$left knowledge file(s) left dirty"

# 对照：静默且没写任何东西 → 绝不能被当成成功
P5="$(make_project true 1)"
rm -f "$WORK/finish.calls"
cat > "$STUB_BIN/qodercli-evolve-mute" <<'MUTE'
#!/usr/bin/env bash
attach=""; wdir=""
while [ $# -gt 0 ]; do
  case "$1" in
    --attachment) attach="$2"; shift 2;; -w) wdir="$2"; shift 2;;
    -m|-p|--permission-mode) shift 2;; *) shift;;
  esac
done
if grep -q "autopilot-evolve" "$attach" 2>/dev/null; then exit 0; fi
if grep -q "代码审查专家" "$attach" 2>/dev/null; then printf 'r %0400d\n' 0; echo REVIEW_PASS; exit 0; fi
if grep -q "autopilot-finish" "$attach" 2>/dev/null; then printf 'f %0400d\n' 0; echo "FINISH_STATUS=DONE"; exit 0; fi
echo "w $(date +%s)-$RANDOM" >> "$wdir/stub-proof.txt"; printf 'i %0400d\n' 0; echo "**Status:** DONE"
MUTE
chmod +x "$STUB_BIN/qodercli-evolve-mute"
MUTE_BIN="$WORK/bin-evolve-mute"; mkdir -p "$MUTE_BIN"; cp "$STUB_BIN/qodercli-evolve-mute" "$MUTE_BIN/qodercli"
set +e
TMPDIR="$WORK" PATH="$MUTE_BIN:$PATH" AUTOPILOT_PLATFORM=qoder WORK="$WORK" \
  AUTOPILOT_SILENT_RETRIES=2 AUTOPILOT_SILENT_FALLBACK_MODEL= \
  bash "$RUNNER" --change-dir "$P5/autopilot/changes/smoke" --cwd "$P5" --max-rounds 2 \
  > "$WORK/s5.log" 2>&1
rc5=$?
set -e
[ "$rc5" -eq 2 ] && pass "silent evolve with NO artifact still fails closed" || { fail "exit=$rc5 (expected 2)"; tail -8 "$WORK/s5.log" | sed 's/^/    | /'; }
grep -q 'stayed silent through every attempt' "$WORK/s5.log" && pass "reason distinguishes silence from refusal" || fail "stop reason unclear"

echo ""
echo "===== Scenario 6: 归档后重跑 —— 必须自动恢复到 evolve ====="
# 真实漏洞：finish 成功后 change 目录已搬进 archive，若 evolve 挂了，再跑本入口会在
# loop 就失败（读不到 tasks.md）——于是“只差沉淀一步”变成无法从入口恢复。
P6="$(make_project true 1)"
rm -f "$WORK/finish.hit" "$WORK/evolve.hit" "$WORK/finish.calls"
set +e
TMPDIR="$WORK" PATH="$STUB_BIN:$PATH" AUTOPILOT_PLATFORM=qoder WORK="$WORK" \
  bash "$RUNNER" --change-dir "$P6/autopilot/changes/smoke" --cwd "$P6" --skip-evolve \
  > "$WORK/s6a.log" 2>&1
rc6a=$?
set -e
[ "$rc6a" -eq 0 ] && pass "first pass (loop+finish) succeeds" || { fail "first pass exit=$rc6a"; tail -8 "$WORK/s6a.log" | sed 's/^/    | /'; }
[ ! -d "$P6/autopilot/changes/smoke" ] && pass "change archived by finish" || fail "change still in changes/"
# 重跑：同一条命令（不加任何 skip）必须识别出已归档并直接跑 evolve
rm -f "$WORK/evolve.hit"
set +e
TMPDIR="$WORK" PATH="$STUB_BIN:$PATH" AUTOPILOT_PLATFORM=qoder WORK="$WORK" \
  bash "$RUNNER" --change-dir "$P6/autopilot/changes/smoke" --cwd "$P6" \
  > "$WORK/s6b.log" 2>&1
rc6b=$?
set -e
grep -q 'change already archived' "$WORK/s6b.log" && pass "rerun detects the archived change" || { fail "rerun did not detect the archive"; tail -8 "$WORK/s6b.log" | sed 's/^/    | /'; }
grep -q 'stage 1/3: loop (skipped)' "$WORK/s6b.log" && pass "loop is skipped on rerun" || fail "loop was not skipped"
[ "$rc6b" -eq 0 ] && pass "rerun completes through evolve (exit 0)" || { fail "rerun exit=$rc6b"; tail -8 "$WORK/s6b.log" | sed 's/^/    | /'; }
[ -f "$WORK/evolve.hit" ] && pass "evolve actually ran on rerun" || fail "evolve did not run on rerun"

# 误拼的 --change-dir 绝不能被当成“已完成”静默放行
set +e
TMPDIR="$WORK" PATH="$STUB_BIN:$PATH" AUTOPILOT_PLATFORM=qoder WORK="$WORK" \
  bash "$RUNNER" --change-dir "$P6/autopilot/changes/typo-name" --cwd "$P6" \
  > "$WORK/s6c.log" 2>&1
rc6c=$?
set -e
[ "$rc6c" -ne 0 ] && pass "a mistyped change name still fails (not silently 'done')" || { fail "mistyped change name was treated as complete"; tail -6 "$WORK/s6c.log" | sed 's/^/    | /'; }

echo ""
echo "===== Scenario 7: 已归档但搬迁未提交 —— 绝不能洗成 ALL STAGES DONE ====="
# finish-change.sh 的 merge 与归档 mv 发生在提交**之前**：它在 `git add -A` / `git commit`
# 那一步 fail-closed（磁盘满 / hook 拒绝 / index.lock 被长期占用）时，归档搬迁已落在
# 主干工作树上但未提交。而本入口的“已归档 → 跳过 loop+finish”捷径会直接接力跑 evolve，
# 然后打印 ALL STAGES DONE ✅ exit 0 —— 把一个未提交的主干状态洗成全绿。
# 这里用 `git reset --soft HEAD~1` 精确复现那个状态（搬迁已发生、commit 没成）。
P7="$(make_project true 1)"
rm -f "$WORK/finish.hit" "$WORK/evolve.hit" "$WORK/finish.calls"
set +e
TMPDIR="$WORK" PATH="$STUB_BIN:$PATH" AUTOPILOT_PLATFORM=qoder WORK="$WORK" \
  bash "$RUNNER" --change-dir "$P7/autopilot/changes/smoke" --cwd "$P7" --skip-evolve \
  > "$WORK/s7a.log" 2>&1
rc7a=$?
set -e
[ "$rc7a" -eq 0 ] && pass "first pass (loop+finish) succeeds" || { fail "first pass exit=$rc7a"; tail -8 "$WORK/s7a.log" | sed 's/^/    | /'; }
( cd "$P7" && git reset --soft HEAD~1 ) >/dev/null 2>&1 || true   # set -e 下夹具失败不得崩掉整套（下一行的 vacuity 守卫负责把它报成 FAIL）
[ -n "$(cd "$P7" && git status --porcelain -- autopilot/archive autopilot/changes)" ] \
  && pass "fixture reproduces the state: archived, move uncommitted" \
  || fail "fixture did not produce an uncommitted archive move (scenario would be vacuous)"
rm -f "$WORK/evolve.hit"
set +e
TMPDIR="$WORK" PATH="$STUB_BIN:$PATH" AUTOPILOT_PLATFORM=qoder WORK="$WORK" \
  bash "$RUNNER" --change-dir "$P7/autopilot/changes/smoke" --cwd "$P7" \
  > "$WORK/s7b.log" 2>&1
rc7b=$?
set -e
[ "$rc7b" -eq 2 ] && pass "exit 2 (fail-closed)" || { fail "exit=$rc7b (expected 2)"; tail -10 "$WORK/s7b.log" | sed 's/^/    | /'; }
grep -q 'ALL STAGES DONE' "$WORK/s7b.log" && fail "an uncommitted archive move was washed into ALL STAGES DONE" || pass "never printed ALL STAGES DONE"
[ ! -f "$WORK/evolve.hit" ] && pass "evolve did NOT run on a dirty archive" || fail "evolve ran on top of an uncommitted archive move"
grep -q '归档搬迁尚未提交' "$WORK/s7b.log" && pass "reason names the uncommitted archive move" || fail "stop reason unclear"
grep -q 'git commit -m' "$WORK/s7b.log" && pass "prints a runnable recovery command" || fail "no recovery command printed"
# 恢复后必须能接力（门禁不得把人永久锁在外面）
( cd "$P7" && git add -A -- autopilot && git commit -qm 'chore(autopilot): archive smoke' ) >/dev/null 2>&1 || true
set +e
TMPDIR="$WORK" PATH="$STUB_BIN:$PATH" AUTOPILOT_PLATFORM=qoder WORK="$WORK" \
  bash "$RUNNER" --change-dir "$P7/autopilot/changes/smoke" --cwd "$P7" \
  > "$WORK/s7c.log" 2>&1
rc7c=$?
set -e
[ "$rc7c" -eq 0 ] && pass "after committing the move, the rerun resumes at evolve" || { fail "recovery rerun exit=$rc7c"; tail -10 "$WORK/s7c.log" | sed 's/^/    | /'; }
[ -f "$WORK/evolve.hit" ] && pass "evolve ran once the state was clean" || fail "evolve still did not run after recovery"

echo ""
echo "===== Scenario 8: 显式 --skip-loop --skip-finish 不得绕过归档提交断言 ====="
# 上一个场景只盖住了“自动探测到已归档”那条入口。而 OPTIONS 里自己推荐的
# “evolve 挂了单独重跑”写法是 `--skip-loop --skip-finish`：它跳过整个自动探测分支，
# 已实测能把同一个“已归档但搬迁未提交”的主干状态洗成 exit 0 + 终局成功标记。
P8="$(make_project true 1)"
rm -f "$WORK/finish.hit" "$WORK/evolve.hit" "$WORK/finish.calls"
set +e
TMPDIR="$WORK" PATH="$STUB_BIN:$PATH" AUTOPILOT_PLATFORM=qoder WORK="$WORK" \
  bash "$RUNNER" --change-dir "$P8/autopilot/changes/smoke" --cwd "$P8" --skip-evolve \
  > "$WORK/s8a.log" 2>&1
rc8a=$?
set -e
[ "$rc8a" -eq 0 ] && pass "first pass (loop+finish) succeeds" || { fail "first pass exit=$rc8a"; tail -8 "$WORK/s8a.log" | sed 's/^/    | /'; }
( cd "$P8" && git reset --soft HEAD~1 ) >/dev/null 2>&1 || true
rm -f "$WORK/evolve.hit"
set +e
TMPDIR="$WORK" PATH="$STUB_BIN:$PATH" AUTOPILOT_PLATFORM=qoder WORK="$WORK" \
  bash "$RUNNER" --change-dir "$P8/autopilot/changes/smoke" --cwd "$P8" --skip-loop --skip-finish \
  > "$WORK/s8b.log" 2>&1
rc8b=$?
set -e
[ "$rc8b" -eq 2 ] && pass "exit 2 (explicit flags cannot bypass the gate)" || { fail "exit=$rc8b (expected 2)"; tail -10 "$WORK/s8b.log" | sed 's/^/    | /'; }
grep -q 'ALL STAGES DONE' "$WORK/s8b.log" && fail "explicit-flag path washed it into ALL STAGES DONE" || pass "never printed ALL STAGES DONE"
[ ! -f "$WORK/evolve.hit" ] && pass "evolve did NOT run" || fail "evolve ran on top of an uncommitted archive move"
# --skip-evolve 也不得绕过（它同样会走到末尾打终局成功标记）
set +e
TMPDIR="$WORK" PATH="$STUB_BIN:$PATH" AUTOPILOT_PLATFORM=qoder WORK="$WORK" \
  bash "$RUNNER" --change-dir "$P8/autopilot/changes/smoke" --cwd "$P8" --skip-loop --skip-finish --skip-evolve \
  > "$WORK/s8c.log" 2>&1
rc8c=$?
set -e
[ "$rc8c" -eq 2 ] && pass "--skip-evolve does not bypass it either" || { fail "exit=$rc8c (expected 2)"; tail -8 "$WORK/s8c.log" | sed 's/^/    | /'; }

# 反面断言（防止门禁过宽）：归档已干净提交、但同仓有**另一个进行中的 change**（未提交），
# 重跑 evolve 必须正常通过。曾用 `autopilot/changes` 整目录做 pathspec，已实测会在这里
# 误拦成 exit 2，并把报错归因到一个不存在的 finish 故障上。
( cd "$P8" && git add -A -- autopilot && git commit -qm 'chore(autopilot): archive smoke' ) >/dev/null 2>&1 || true
mkdir -p "$P8/autopilot/changes/other-wip"
printf '# an unrelated in-flight change\n' > "$P8/autopilot/changes/other-wip/spec.md"
rm -f "$WORK/evolve.hit"
set +e
TMPDIR="$WORK" PATH="$STUB_BIN:$PATH" AUTOPILOT_PLATFORM=qoder WORK="$WORK" \
  bash "$RUNNER" --change-dir "$P8/autopilot/changes/smoke" --cwd "$P8" \
  > "$WORK/s8d.log" 2>&1
rc8d=$?
set -e
[ "$rc8d" -eq 0 ] && pass "an unrelated in-flight change does NOT trip the gate" || { fail "exit=$rc8d (expected 0) — gate is over-broad"; tail -10 "$WORK/s8d.log" | sed 's/^/    | /'; }
[ -f "$WORK/evolve.hit" ] && pass "evolve still runs with a parallel WIP change present" || fail "evolve was blocked by an unrelated change"

echo ""
if [ "$FAILED" -eq 0 ]; then echo "SMOKE(run-autopilot): ALL PASS"; exit 0; fi
echo "SMOKE(run-autopilot): FAILURES"; exit 1
