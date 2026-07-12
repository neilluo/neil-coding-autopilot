# 任务：创建控制器写码硬门禁的 2 个新文件（逐字落盘 + 自验）

你是 neil-coding-autopilot 插件的实现型 worker。当前工作目录（CWD）就是插件仓库根目录。
本任务只做一件事：**逐字创建下面两个文件**（内容一字不差），给可执行位，然后运行 smoke 自验并回报。

⚠️ 纪律：
- 严格按给定内容创建，不要“优化”、不要改措辞、不要改注释、不要改判定顺序。
- 不要动仓库里任何其它文件。
- 完成后必须实际运行 `bash scripts/smoke-guard.sh` 并把**完整输出**贴回。

---

## 文件 1：`hooks/guard-controller-write.sh`

创建该文件，内容**完全等于**下面 BEGIN/END 之间的文本（不含 BEGIN/END 行）：

===BEGIN hooks/guard-controller-write.sh===
#!/usr/bin/env bash
# ============================================================
# neil-coding-autopilot — Controller Write Hard-Gate (PreToolUse)
# ============================================================
# Enforces the plugin's #1 invariant at RUNTIME (not just in markdown):
#   "The autopilot CONTROLLER must never inline-write source code; all
#    coding is delegated to fresh qodercli workers via run-track-a.sh."
#
# Wired as a Qoder PreToolUse hook on file-writing tools. Reads the
# tool-call JSON on stdin; decides allow (exit 0) vs deny (exit 2).
# A PreToolUse deny holds even under --permission-mode bypass_permissions.
#
# Decision order — FAIL-OPEN on any uncertainty (never lock up normal coding):
#   0. trap            any internal error              => allow (exit 0)
#   1. scope gate      no autopilot/.run-active         => allow (not in a run)
#   1b. stale sentinel sentinel older than TTL           => allow (crash residue)
#   2. worker allow    AUTOPILOT_ROLE=worker (sole signal)=> allow
#   3. whitelist       md / autopilot / harness (NOT tmp)=> allow
#   4. otherwise       controller writing source at run  => DENY (exit 2)
#
# Contract (qodercli 1.0.16, verified live): stdin carries top-level
# tool_name, cwd, permission_mode and tool_input.file_path (fallback
# tool_input.path). Deny via exit 2 (+stderr reason) and hookSpecificOutput
# JSON. See autopilot/knowledge raw hooks.md.
# ============================================================

# Fail-open: a bug in this hook must NEVER block the host agent.
set +e +u
trap 'exit 0' ERR

_STDIN="$(cat 2>/dev/null || true)"

# Field extractor: jq when present, sed fallback (macOS BSD-safe: no -P/\d/\s).
_field() {
  local q="$1" key="$2"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$_STDIN" | jq -r "$q // empty" 2>/dev/null
  else
    printf '%s' "$_STDIN" \
      | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
  fi
}

TOOL_NAME="$(_field '.tool_name' 'tool_name')"
CWD="$(_field '.cwd' 'cwd')"
FILE_PATH="$(_field '.tool_input.file_path' 'file_path')"
[ -z "$FILE_PATH" ] && FILE_PATH="$(_field '.tool_input.path' 'path')"

# Gate only file-writing tools (canonical + IDE aliases). Anything else => allow.
case "$TOOL_NAME" in
  Write|Edit|MultiEdit|write|edit|create_file|write_file|search_replace|replace) ;;
  *) exit 0 ;;
esac

# --- layer 1: scope gate — only active INSIDE an autopilot run ---
BASE="${CWD:-$PWD}"
SENTINEL="${BASE%/}/autopilot/.run-active"
[ -f "$SENTINEL" ] || exit 0

# --- layer 1b: ignore a STALE sentinel (crash residue) to avoid locking coding ---
TTL_H="${AUTOPILOT_RUN_TTL_HOURS:-12}"
if [[ "${OSTYPE:-}" == darwin* ]]; then
  _born=$(stat -f '%m' "$SENTINEL" 2>/dev/null || echo 0)
else
  _born=$(stat -c '%Y' "$SENTINEL" 2>/dev/null || echo 0)
fi
_now=$(date +%s 2>/dev/null || echo 0)
if [ "${_born:-0}" -gt 0 ] 2>/dev/null && [ "${_now:-0}" -gt 0 ] 2>/dev/null; then
  [ $(( _now - _born )) -gt $(( TTL_H * 3600 )) ] 2>/dev/null && exit 0
fi

# --- layer 2: worker allow — the SOLE legitimate-writer signal ---
# Workers are marked by dispatch.sh (export AUTOPILOT_ROLE=worker); proven to
# propagate to the hook subprocess. We deliberately do NOT allow on
# permission_mode=bypassPermissions — that would let ANY bypass session (incl. a
# bypassed controller) write source. Fail direction: a worker somehow missing
# the role is DENIED (safe) rather than a controller being false-allowed.
[ "${AUTOPILOT_ROLE:-}" = "worker" ] && exit 0

# --- layer 3: whitelist allow (path classes the controller legitimately writes) ---
[ -z "$FILE_PATH" ] && exit 0            # cannot classify => fail-open (allow)
# NOTE: /tmp and $TMPDIR are intentionally NOT whitelisted. The controller's
# only legit tmp writes are prompt files (*.md, already allowed below); the
# review .txt/.patch files are produced via Bash redirection, which this MVP
# gate does not intercept. Whitelisting tmp would let source be written there.
case "$FILE_PATH" in
  *.md|*.MD|*.markdown)              exit 0 ;;  # docs / prompt templates
  */autopilot/*|autopilot/*)        exit 0 ;;  # spec / tasks / progress / knowledge
  */.qoder/*|*/AGENTS.md|AGENTS.md) exit 0 ;;  # harness artifacts
esac

# --- layer 4: DENY — controller writing source during a run ---
REASON="控制器禁止内联写源码(${FILE_PATH})；autopilot 开发一律经 run-track-a.sh 托管 fresh qodercli worker（结构性硬约束，非仅约定）。"
# stdout structured decision (path escaped); harmless if runtime prefers exit-2/stderr.
_esc="${FILE_PATH//\\/\\\\}"; _esc="${_esc//\"/\\\"}"
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"控制器禁止内联写源码(%s)；开发一律经 run-track-a.sh 托管 worker。"}}\n' "$_esc"
# stderr reason (delivered to the agent when exit code is 2).
printf '%s\n' "$REASON" >&2
exit 2
===END hooks/guard-controller-write.sh===

---

## 文件 2：`scripts/smoke-guard.sh`

创建该文件，内容**完全等于**下面 BEGIN/END 之间的文本（不含 BEGIN/END 行）：

===BEGIN scripts/smoke-guard.sh===
#!/usr/bin/env bash
# Smoke test for hooks/guard-controller-write.sh (controller write hard-gate).
#
# Verifies — WITHOUT burning LLM tokens — the guard's allow/deny decisions by
# feeding it synthetic PreToolUse stdin JSON and asserting exit codes:
#   exit 2 = deny, exit 0 = allow.
# Intended for CI and post-install self-check.
#
# Usage:  bash scripts/smoke-guard.sh
# Exit:   0 = all cases pass, 1 = any failure.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/../hooks/guard-controller-write.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Fake project WITH an active-run sentinel (= inside an autopilot run).
RUN_DIR="$WORK/run"; mkdir -p "$RUN_DIR/autopilot"
printf '%s\npid=%s\n' "$(date +%s)" "$$" > "$RUN_DIR/autopilot/.run-active"
# Fake project WITHOUT a sentinel (= normal, non-autopilot coding).
BARE_DIR="$WORK/bare"; mkdir -p "$BARE_DIR"

fail=0

# Build a PreToolUse JSON.  $1=cwd $2=tool_name $3=file_path $4=permission_mode
mk() {
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"%s","permission_mode":"%s","tool_input":{"file_path":"%s"}}' \
    "$1" "$2" "$4" "$3"
}

# check <expect_exit> <label> <json> [role]
check() {
  local expect="$1" label="$2" json="$3" role="${4:-}" rc
  if [ -n "$role" ]; then
    printf '%s' "$json" | AUTOPILOT_ROLE="$role" bash "$GUARD" >/dev/null 2>&1
  else
    printf '%s' "$json" | env -u AUTOPILOT_ROLE bash "$GUARD" >/dev/null 2>&1
  fi
  rc=$?
  if [ "$rc" = "$expect" ]; then
    echo "PASS: $label (exit $rc)"
  else
    echo "FAIL: $label — expected exit $expect, got $rc"; fail=1
  fi
}

# 1. run-time controller writes SOURCE => deny
check 2 "controller writes src during run"       "$(mk "$RUN_DIR" Write "$RUN_DIR/src/App.java" "")"
# 2. worker writes source (AUTOPILOT_ROLE) => allow
check 0 "worker writes src (AUTOPILOT_ROLE)"      "$(mk "$RUN_DIR" Write "$RUN_DIR/src/App.java" "")" worker
# 3. bypass mode but NO worker role => STILL denied (bypass alone grants nothing)
check 2 "bypass-but-no-role writes src => deny"   "$(mk "$RUN_DIR" Write "$RUN_DIR/src/App.java" bypassPermissions)"
# 4. controller writes autopilot artifact => allow
check 0 "controller writes autopilot/spec.md"     "$(mk "$RUN_DIR" Write "$RUN_DIR/autopilot/changes/x/spec.md" "")"
# 5. controller writes .md => allow
check 0 "controller writes README.md"             "$(mk "$RUN_DIR" Write "$RUN_DIR/README.md" "")"
# 6. NOT in a run (no sentinel) => allow even for source
check 0 "normal coding (no sentinel)"             "$(mk "$BARE_DIR" Write "$BARE_DIR/src/App.java" "")"
# 7. IDE alias create_file is also gated => deny
check 2 "controller create_file src during run"   "$(mk "$RUN_DIR" create_file "$RUN_DIR/src/Main.py" "")"

# 8. jq-missing degradation: run under a PATH without jq; sed fallback must still deny.
if command -v jq >/dev/null 2>&1; then
  MINI="$WORK/minibin"; mkdir -p "$MINI"
  for tool in bash sh sed cat date stat env grep head printf dirname; do
    p="$(command -v "$tool" 2>/dev/null)"; [ -n "$p" ] && ln -sf "$p" "$MINI/$tool"
  done
  json8="$(mk "$RUN_DIR" Write "$RUN_DIR/src/App.java" "")"
  printf '%s' "$json8" | PATH="$MINI" env -u AUTOPILOT_ROLE bash "$GUARD" >/dev/null 2>&1
  rc=$?
  if [ "$rc" = 2 ]; then echo "PASS: jq-missing sed-fallback still denies (exit 2)"; else echo "FAIL: jq-missing — expected exit 2, got $rc"; fail=1; fi
else
  echo "INFO: jq not installed; sed fallback is the only code path (already exercised above)"
fi

if [ "$fail" = 0 ]; then echo "SMOKE-GUARD: ALL PASS"; else echo "SMOKE-GUARD: FAILED"; exit 1; fi
===END scripts/smoke-guard.sh===

---

## 完成后必须执行

```bash
chmod +x hooks/guard-controller-write.sh scripts/smoke-guard.sh
bash scripts/smoke-guard.sh
```

把 `smoke-guard.sh` 的**完整输出**贴回。最后单独一行输出：
- 全绿 → `IMPL_STATUS=DONE`
- 任一失败或无法创建 → `IMPL_STATUS=BLOCKED|<原因>`
