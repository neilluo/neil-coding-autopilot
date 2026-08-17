#!/usr/bin/env bash
# WHAT: token-free 冒烟 —— dispatch.sh 在 worker 静默时能否正确取证并定性。
# WHY:  2026-08-16 的真实事故是「worker 干完活没报数 → 被判 transport → 丢弃重试
#       → Task BLOCKED」。三种静默的后果正好相反，取证结论必须准确，否则
#       上层的「能不能重试」决策就是抛硬币。本脚本用桩伪造 transcript 覆盖三种形态。
#
# 手法：stub qodercli 会收到 dispatch.sh 传下来的 `--session-id <uuid>`，
#       于是它能把伪造的 transcript 写到我们指定的 QODER_SESSION_ROOT 下 ——
#       这同时验证了 `--session-id` 确实被传了下去（否则 stub 拿不到 uuid，断言必失败）。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="${TMPDIR:-/tmp}/smoke-session-forensics-$$"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
cleanup() { rm -rf "$ROOT"; }
trap cleanup EXIT

mkdir -p "$ROOT/bin" "$ROOT/proj" "$ROOT/logs" "$ROOT/sessions"
( cd "$ROOT/proj" && git init -q && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
echo "task" > "$ROOT/prompt.md"

# ── stub qodercli：按 SHAPE 伪造一份 transcript，然后静默退出 0 ───────────────
cat > "$ROOT/bin/qodercli" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "--version" ] && { echo "1.0.16-stub"; exit 0; }
sid=""; wdir=""; prev=""
for a in "$@"; do
  case "$prev" in --session-id) sid="$a" ;; -w) wdir="$a" ;; esac
  prev="$a"
done
# 拿不到 session-id 就直接失败：说明 dispatch.sh 没把 --session-id 传下来。
[ -n "$sid" ] || { echo "STUB-ERROR: no --session-id received" >&2; exit 3; }
slug="$(cd "$wdir" 2>/dev/null && pwd -P | tr '/' '-')"
dir="$QODER_SESSION_ROOT/$slug"
mkdir -p "$dir"
t="$dir/$sid.jsonl"
case "$SHAPE" in
  thinking_only)
    printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"go"}]}}' >  "$t"
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"}]}}' >> "$t"
    ;;
  truncated_tool_use)
    printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"go"}]}}' >  "$t"
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Read"}]}}' >> "$t"
    ;;
  work_done)
    printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"go"}]}}' >  "$t"
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Write"}]}}' >> "$t"
    ;;
  readonly_bash)
    # 只跑了只读 Bash（ls）+ Read，一个字没写。真实案例：每日分析 agent d09d5965。
    printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"go"}]}}' >  "$t"
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"ls -la /tmp/x"}}]}}' >> "$t"
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Read"}]}}' >> "$t"
    ;;
  writing_bash)
    # Bash 带重定向 = 真的动过盘，必须仍判为不可重试。
    printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"go"}]}}' >  "$t"
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash","input":{"command":"echo hi > /tmp/out.md"}}]}}' >> "$t"
    ;;
esac
printf '\n'     # 静默：1 字节 stdout，0 字节 stderr
exit 0
STUB
chmod +x "$ROOT/bin/qodercli"

run_shape() {   # run_shape <shape> <expected-verdict> [<expected-classify-outcome>]
  local shape="$1" want="$2" want_class="${3:-}" out="" tm="" rc=0 got_class=""
  rm -rf "$ROOT/logs"; mkdir -p "$ROOT/logs"
  out="$(PATH="$ROOT/bin:$PATH" SHAPE="$shape" \
    QODER_SESSION_ROOT="$ROOT/sessions" \
    NEIL_AUTOPILOT_LOG_DIR="$ROOT/logs" \
    AUTOPILOT_PLATFORM=qoder AUTOPILOT_STAGE=implement AUTOPILOT_RUN_ID=smoke \
    "$SCRIPT_DIR/dispatch.sh" --model Performance --cwd "$ROOT/proj" \
      --prompt-file "$ROOT/prompt.md" --instruction "x" 2>&1)"
  rc=$?

  case "$out" in
    *"verdict=$want"*) pass "$shape → stderr reports verdict=$want" ;;
    *) fail "$shape → expected verdict=$want in output; got: $(printf '%s' "$out" | tr '\n' '|' | cut -c1-200)" ;;
  esac

  tm="$(jq -r 'select(.event=="dispatch")|.forensic_verdict // "<missing>"' "$ROOT/logs/runs/"*.jsonl 2>/dev/null | tail -1)"
  if [ "$tm" = "$want" ]; then
    pass "$shape → telemetry forensic_verdict=$want"
  else
    fail "$shape → telemetry forensic_verdict expected $want, got ${tm:-<none>}"
  fi

  # 取证定了性还不够 —— 真正花钱的是上层会不会拿它去重试。这里把 merged stdout+stderr
  # 写成日志再过 classify-outcome，复现 run-track-a.sh 的 `2>&1 | tee` + classify 链路，
  # 直接断言分类结果：TRUNCATED 会被上层 fail-closed，EMPTY 才会被重试到 5 次。
  if [ -n "$want_class" ]; then
    printf '%s\n' "$out" > "$ROOT/logs/worker.log"
    got_class="$("$SCRIPT_DIR/classify-outcome.sh" "$rc" "$ROOT/logs/worker.log" 2>/dev/null)"
    if [ "$got_class" = "$want_class" ]; then
      pass "$shape → classify(rc=$rc)=$want_class"
    else
      fail "$shape → classify(rc=$rc) expected $want_class, got ${got_class:-<none>}"
    fi
  fi
}

echo "===== dispatch.sh silent-worker forensics ====="
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed (forensics is jq-gated by design)"; exit 0
fi
# 第三个参数盯的是「花不花第二次钱」：
#   truncated 必须落到 TRUNCATED（上层直接 fail-closed）—— 它原本被归为 EMPTY，
#   会被立即重试到 AUTOPILOT_SILENT_RETRIES（默认 5），而 dispatch.sh 自己写着
#   「原样重试 3/3 复现」：一次注定失败的调用按全价买五遍。
#   thinking_only 则必须仍是 EMPTY（重试是安全且有效的），防止上面那个例外误伤它。
run_shape thinking_only      THINKING_ONLY      EMPTY
run_shape truncated_tool_use TRUNCATED_TOOL_USE TRUNCATED
run_shape work_done          WORK_DONE_UNREPORTED
# Bash 不能一律当成「动过盘」。真实踩坑：每日分析 agent 只跑了只读 ls + Read，
# 却被判成 WORK_DONE_UNREPORTED、结论“不要重试”—— 而重试恰恰是正确动作。
run_shape readonly_bash      TRUNCATED_TOOL_USE
# 但带重定向的 Bash 仍必须判为已改盘（否则反过来会在半成品上重跑）。
run_shape writing_bash       WORK_DONE_UNREPORTED

# 带空格的 cwd（如 `~/Library/Application Support/…`）必须能解析到 transcript。
# 真实踩坑：CLI 把空格也换成 `-`，而旧 slug 只换 `/`，于是取证**静默失效**
# 并回退到笼统文案 —— 比没有取证更坐误。
SPACE_CWD="$ROOT/with space/proj"
mkdir -p "$SPACE_CWD"
# 必须用 printf 去掉 pwd 的尾部换行再过 tr。写成 `pwd -P | tr …` 会把换行也当成
# 待替换字符（若 SET1 含 [:space:]）或保留换行，产生带尾差的目录名，
# 让本用例假失败 —— 已真的犯过一次，勿改回去。
SPACE_SLUG="$(printf '%s' "$(cd "$SPACE_CWD" && pwd -P)" | tr '/ ' '--')"
mkdir -p "$ROOT/sessions/$SPACE_SLUG"
SPACE_SID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"go"}]}}' \
  > "$ROOT/sessions/$SPACE_SLUG/$SPACE_SID.jsonl"
printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"x"}]}}' \
  >> "$ROOT/sessions/$SPACE_SLUG/$SPACE_SID.jsonl"
space_out="$(QODER_SESSION_ROOT="$ROOT/sessions" "$SCRIPT_DIR/session-forensics.sh" \
  --cwd "$SPACE_CWD" --session-id "$SPACE_SID" --format json 2>/dev/null || true)"
case "$space_out" in
  *THINKING_ONLY*) pass "cwd containing spaces resolves to the transcript" ;;
  *) fail "space-containing cwd did not resolve (got: ${space_out:-<empty>})" ;;
esac

# session_id 必须始终落进遥测（取证的钥匙，不能只在失败分支才有）。
sid="$(jq -r 'select(.event=="dispatch")|.session_id // "<missing>"' "$ROOT/logs/runs/"*.jsonl 2>/dev/null | tail -1)"
case "$sid" in
  ????????-????-????-????-????????????) pass "telemetry carries the pinned session_id ($sid)" ;;
  *) fail "telemetry session_id missing or malformed: $sid" ;;
esac

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
