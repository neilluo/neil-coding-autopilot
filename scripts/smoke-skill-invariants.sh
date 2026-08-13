#!/usr/bin/env bash
# WHAT: Validate the bootstrap skill's size, required invariants, and reference links.
# USAGE: bash scripts/smoke-skill-invariants.sh
# EXIT CODES: 0 when the real skill and mutation checks pass; 1 otherwise.
set -u
unset AUTOPILOT_RUN_ID

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
REAL_SKILL="$ROOT_DIR/skills/using-neil-autopilot/SKILL.md"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skill-invariants.XXXXXX")" || exit 1
trap 'rm -rf "$TMP_ROOT"' EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  return 1
}

validate_skill() {
  skill="$1"
  skill_dir="$(cd "$(dirname "$skill")" && pwd -P)" || return 1

  [ -f "$skill" ] || { fail "missing SKILL.md: $skill"; return 1; }
  bytes="$(wc -c < "$skill" | tr -d ' ')"
  [ "$bytes" -le 9216 ] || { fail "SKILL.md is $bytes bytes (limit 9216)"; return 1; }

  for keyword in \
    'HARD-GATE' \
    '需求澄清' \
    '分支纪律' \
    'Code Review' \
    '验证' \
    '知识沉淀' \
    '状态可追溯' \
    '可观测验收' \
    '控制器永不内联写码' \
    'run-track-a.sh' \
    '拿不准' \
    '{STAGE}_STATUS' \
    'REVIEW_PASS' \
    'fail-closed' \
    'REVIEW_FAIL' \
    'REVIEW_INCOMPLETE'
  do
    LC_ALL=C grep -Fq "$keyword" "$skill" || { fail "missing required keyword: $keyword"; return 1; }
  done

  links="$(mktemp "$TMP_ROOT/links.XXXXXX")" || return 1
  LC_ALL=C grep -o 'references/[^)]*\.md' "$skill" > "$links" || true
  [ -s "$links" ] || { fail "no references/*.md links found"; return 1; }
  while IFS= read -r link; do
    [ -f "$skill_dir/$link" ] || { fail "missing linked reference: $link"; return 1; }
  done < "$links"

  for name in workflow-graph.md directory-layout.md bootstrap.md usage-examples.md recovery.md; do
    ref="$skill_dir/references/$name"
    [ -s "$ref" ] || { fail "reference is missing or empty: $name"; return 1; }
    first_line="$(LC_ALL=C sed -n '1p' "$ref")"
    case "$first_line" in
      *何时读我*) : ;;
      *) fail "reference first line lacks 何时读我: $name"; return 1 ;;
    esac
  done

  return 0
}

make_fixture() {
  destination="$1"
  mkdir -p "$destination/references" || return 1
  cp "$REAL_SKILL" "$destination/SKILL.md" || return 1
  cp "$ROOT_DIR/skills/using-neil-autopilot/references/"*.md "$destination/references/" || return 1
}

expect_mutation_failure() {
  name="$1"
  fixture="$TMP_ROOT/$name"
  make_fixture "$fixture" || return 1
  shift
  "$@" "$fixture" || return 1
  if validate_skill "$fixture/SKILL.md" >/dev/null 2>&1; then
    fail "mutation unexpectedly passed: $name"
    return 1
  fi
  printf 'PASS mutation rejected: %s\n' "$name"
}

mutate_gate() {
  fixture="$1"
  LC_ALL=C sed 's/HARD-GATE//g' "$fixture/SKILL.md" > "$fixture/SKILL.tmp" || return 1
  mv "$fixture/SKILL.tmp" "$fixture/SKILL.md"
}

mutate_reference() {
  fixture="$1"
  LC_ALL=C sed 's@references/workflow-graph\.md@references/workflow-graph-missing.md@' "$fixture/SKILL.md" > "$fixture/SKILL.tmp" || return 1
  mv "$fixture/SKILL.tmp" "$fixture/SKILL.md"
}

mutate_oversize() {
  fixture="$1"
  dd if=/dev/zero bs=1024 count=10 2>/dev/null | tr '\000' 'x' >> "$fixture/SKILL.md"
}

printf 'Validating %s\n' "$REAL_SKILL"
validate_skill "$REAL_SKILL" || exit 1
printf 'PASS real skill invariants\n'
expect_mutation_failure removed-hard-gate mutate_gate || exit 1
expect_mutation_failure missing-reference mutate_reference || exit 1
expect_mutation_failure oversized-skill mutate_oversize || exit 1
printf 'PASS smoke-skill-invariants\n'
