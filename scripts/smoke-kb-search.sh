#!/usr/bin/env bash
# smoke-kb-search.sh — token-free regression test for scripts/kb-search.sh.
#
# Verifies, WITHOUT calling any LLM/model, in a scratch tree with a fake
# global KB (NEIL_AUTOPILOT_KB_DIR) and a fake local KB (autopilot/knowledge):
#   1. query "widget" -> output contains "[GLOBAL]" AND the matching file
#      (discriminator: missing [GLOBAL] = FAIL).
#   2. query "alpha"  -> output contains "[LOCAL]".
#   3. query "zzznope" (no matches anywhere) -> output is "(no prior-art
#      hits)" and exit 0 (discriminator: exit != 0 = FAIL).
#
# Usage: bash scripts/smoke-kb-search.sh   # 0 = all pass, 1 = failure.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
KB_SEARCH="$SCRIPT_DIR/kb-search.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILED=0

fail() { echo "FAIL: $1"; FAILED=1; }
pass() { echo "PASS: $1"; }

if [ ! -f "$KB_SEARCH" ]; then
  echo "FAIL: $KB_SEARCH not found"
  exit 1
fi

# ── fixture: fake global KB ─────────────────────────────────────────────────
GLOBAL_DIR="$WORK/global-kb"
mkdir -p "$GLOBAL_DIR/wiki"
echo "The widget subsystem handles rendering." > "$GLOBAL_DIR/wiki/widget-notes.md"

# ── fixture: fake local KB (mirrors <cwd>/autopilot/knowledge) ─────────────
PROJECT_DIR="$WORK/project"
mkdir -p "$PROJECT_DIR/autopilot/knowledge/wiki"
echo "alpha channel is used for transparency." > "$PROJECT_DIR/autopilot/knowledge/wiki/alpha-notes.md"

# ── scenario 1: query "widget" -> [GLOBAL] + the matching file ─────────────
run_global_scenario() {
  local out rc
  out="$(NEIL_AUTOPILOT_KB_DIR="$GLOBAL_DIR" bash "$KB_SEARCH" --query "widget" --cwd "$PROJECT_DIR" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "global: expected exit 0, got $rc (output: $out)"
    return
  fi
  if ! printf '%s' "$out" | grep -q '\[GLOBAL\]'; then
    fail "global: output missing [GLOBAL] tag (output: $out)"
  elif ! printf '%s' "$out" | grep -q 'widget-notes.md'; then
    fail "global: output missing matching file widget-notes.md (output: $out)"
  else
    pass "global: output contains [GLOBAL] and widget-notes.md"
  fi
}
run_global_scenario

# ── scenario 2: query "alpha" -> [LOCAL] ────────────────────────────────────
run_local_scenario() {
  local out rc
  out="$(NEIL_AUTOPILOT_KB_DIR="$GLOBAL_DIR" bash "$KB_SEARCH" --query "alpha" --cwd "$PROJECT_DIR" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "local: expected exit 0, got $rc (output: $out)"
    return
  fi
  if ! printf '%s' "$out" | grep -q '\[LOCAL\]'; then
    fail "local: output missing [LOCAL] tag (output: $out)"
  else
    pass "local: output contains [LOCAL]"
  fi
}
run_local_scenario

# ── scenario 3: query "zzznope" -> "(no prior-art hits)" and exit 0 ────────
run_no_hits_scenario() {
  local out rc
  out="$(NEIL_AUTOPILOT_KB_DIR="$GLOBAL_DIR" bash "$KB_SEARCH" --query "zzznope" --cwd "$PROJECT_DIR" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "no-hits: expected exit 0 (silent success required, exit != 0 = FAIL), got $rc (output: $out)"
    return
  fi
  if [ "$out" != "(no prior-art hits)" ]; then
    fail "no-hits: expected exactly '(no prior-art hits)', got '$out'"
  else
    pass "no-hits: prints (no prior-art hits) and exits 0"
  fi
}
run_no_hits_scenario

# ── fixture: many-hit local KB (exercises --limit truncation path) ─────────
MANYHIT_PROJECT_DIR="$WORK/manyhit-project"
mkdir -p "$MANYHIT_PROJECT_DIR/autopilot/knowledge/wiki"
i=1
while [ "$i" -le 8 ]; do
  echo "manyhit reference number $i" > "$MANYHIT_PROJECT_DIR/autopilot/knowledge/wiki/manyhit-$i.md"
  i=$((i + 1))
done

# ── scenario 4: hits > --limit -> exactly LIMIT lines and exit 0 ───────────
# Regresses MAJOR-1: `head` closing the pipe early on truncation used to
# SIGPIPE the upstream `awk`, and `pipefail` turned that into exit 141.
run_limit_truncation_scenario() {
  local out rc line_count
  out="$(NEIL_AUTOPILOT_KB_DIR="$GLOBAL_DIR" bash "$KB_SEARCH" --query "manyhit" --cwd "$MANYHIT_PROJECT_DIR" --limit 5 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "limit-truncation: expected exit 0, got $rc (output: $out)"
    return
  fi
  line_count="$(printf '%s\n' "$out" | grep -c 'manyhit-')"
  if [ "$line_count" -ne 5 ]; then
    fail "limit-truncation: expected exactly 5 hit lines, got $line_count (output: $out)"
  else
    pass "limit-truncation: exactly 5 hit lines and exit 0"
  fi
}
run_limit_truncation_scenario

if [ "$FAILED" = 0 ]; then
  echo "SMOKE(kb-search): ALL PASS"
  exit 0
else
  echo "SMOKE(kb-search): FAILED"
  exit 1
fi
