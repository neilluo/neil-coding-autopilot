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
[ -z "$FILE_PATH" ] && FILE_PATH="$(_field '.tool_input.notebook_path' 'notebook_path')"

# Gate only file-writing tools (canonical + IDE aliases). Anything else => allow.
case "$TOOL_NAME" in
  Write|Edit|MultiEdit|write|edit|create_file|write_file|search_replace|replace|NotebookEdit) ;;
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
