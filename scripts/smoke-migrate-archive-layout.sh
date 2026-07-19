#!/usr/bin/env bash
# smoke-migrate-archive-layout.sh — token-free regression test for
# scripts/migrate-archive-layout.sh.
#
# Verifies, WITHOUT calling any LLM/model, in a scratch git repo:
#   1. Migration: flat 2026-07-18-foo -> 2026/07/07-18/2026-07-18-foo,
#      flat 2026-07-19-bar -> 2026/07/07-19/2026-07-19-bar, both top-level
#      flat dirs gone; already-nested 2026/07/07-19/2026-07-19-baz is left
#      untouched (idempotent skip of nested structures).
#   2. Idempotent re-run: running again produces zero further changes.
#   3. --dry-run: prints planned moves but leaves the filesystem untouched.
#
# Usage: bash scripts/smoke-migrate-archive-layout.sh   # 0 = pass, 1 = fail.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
MIGRATE="$SCRIPT_DIR/migrate-archive-layout.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILED=0

fail() { echo "FAIL: $1"; FAILED=1; }
pass() { echo "PASS: $1"; }

if [ ! -f "$MIGRATE" ]; then
  echo "FAIL: $MIGRATE not found"
  exit 1
fi

REPO="$WORK/repo"
ARCHIVE="$REPO/autopilot/archive"
mkdir -p "$ARCHIVE/2026-07-18-foo"
mkdir -p "$ARCHIVE/2026-07-19-bar"
mkdir -p "$ARCHIVE/2026/07/07-19/2026-07-19-baz"
echo "foo-content" > "$ARCHIVE/2026-07-18-foo/spec.md"
echo "bar-content" > "$ARCHIVE/2026-07-19-bar/spec.md"
echo "baz-content" > "$ARCHIVE/2026/07/07-19/2026-07-19-baz/spec.md"

(
  cd "$REPO" && \
  git init -q && \
  git config user.email "smoke@test.local" && \
  git config user.name "smoke" && \
  git add -A && \
  git commit -q -m "init"
) >/dev/null

# ── scenario 1: migration moves flat dirs, leaves nested dirs alone ────────
run_migrate_scenario() {
  local out rc
  out="$(cd "$REPO" && bash "$MIGRATE" --archive-dir "$ARCHIVE" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "migrate: expected exit 0, got $rc (output: $out)"
    return
  fi

  if [ ! -d "$ARCHIVE/2026/07/07-18/2026-07-18-foo" ]; then
    fail "migrate: foo target missing: $ARCHIVE/2026/07/07-18/2026-07-18-foo"
  elif [ -d "$ARCHIVE/2026-07-18-foo" ]; then
    fail "migrate: flat foo source still exists (should have been moved)"
  else
    pass "migrate: foo -> 2026/07/07-18/2026-07-18-foo, flat source gone"
  fi

  if [ ! -d "$ARCHIVE/2026/07/07-19/2026-07-19-bar" ]; then
    fail "migrate: bar target missing: $ARCHIVE/2026/07/07-19/2026-07-19-bar"
  elif [ -d "$ARCHIVE/2026-07-19-bar" ]; then
    fail "migrate: flat bar source still exists (should have been moved)"
  else
    pass "migrate: bar -> 2026/07/07-19/2026-07-19-bar, flat source gone"
  fi

  if [ ! -f "$ARCHIVE/2026/07/07-19/2026-07-19-baz/spec.md" ]; then
    fail "migrate: pre-existing nested baz was disturbed"
  else
    pass "migrate: pre-existing nested baz left untouched"
  fi

  local top_level_flat
  top_level_flat="$(find "$ARCHIVE" -maxdepth 1 -type d -name '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-*')"
  if [ -n "$top_level_flat" ]; then
    fail "migrate: top-level flat dirs remain: $top_level_flat"
  else
    pass "migrate: no top-level flat dirs remain"
  fi
}
run_migrate_scenario

# ── scenario 2: idempotent re-run — zero further changes ───────────────────
run_idempotent_scenario() {
  local before after out rc
  before="$(cd "$REPO" && find autopilot/archive -type f | sort)"
  out="$(cd "$REPO" && bash "$MIGRATE" --archive-dir "$ARCHIVE" 2>&1)"
  rc=$?
  after="$(cd "$REPO" && find autopilot/archive -type f | sort)"
  if [ "$rc" -ne 0 ]; then
    fail "idempotent: expected exit 0 on re-run, got $rc (output: $out)"
  elif [ -n "$out" ]; then
    fail "idempotent: re-run printed unexpected migration output: $out"
  elif [ "$before" != "$after" ]; then
    fail "idempotent: file listing changed after re-run"
  else
    pass "idempotent: re-run exits 0, zero changes, no output"
  fi
}
run_idempotent_scenario

# ── scenario 3: --dry-run leaves filesystem untouched ───────────────────────
run_dry_run_scenario() {
  local name="qux"
  mkdir -p "$ARCHIVE/2026-07-20-${name}"
  echo "qux-content" > "$ARCHIVE/2026-07-20-${name}/spec.md"
  (cd "$REPO" && git add -A && git commit -q -m "add $name") >/dev/null

  local before after out rc
  before="$(cd "$REPO" && find autopilot/archive -type f | sort)"
  out="$(cd "$REPO" && bash "$MIGRATE" --archive-dir "$ARCHIVE" --dry-run 2>&1)"
  rc=$?
  after="$(cd "$REPO" && find autopilot/archive -type f | sort)"

  if [ "$rc" -ne 0 ]; then
    fail "dry-run: expected exit 0, got $rc (output: $out)"
  elif [ "$before" != "$after" ]; then
    fail "dry-run: filesystem was modified"
  elif [ -d "$ARCHIVE/2026/07/07-20/2026-07-20-${name}" ]; then
    fail "dry-run: target dir was created despite --dry-run"
  elif ! printf '%s' "$out" | grep -q "2026-07-20-${name} -> "; then
    fail "dry-run: did not print planned move for ${name} (output: $out)"
  else
    pass "dry-run: filesystem untouched, planned move printed"
  fi
}
run_dry_run_scenario

if [ "$FAILED" = 0 ]; then
  echo "SMOKE(migrate-archive-layout): ALL PASS"
  exit 0
else
  echo "SMOKE(migrate-archive-layout): FAILED"
  exit 1
fi
