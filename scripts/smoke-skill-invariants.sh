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

# ── bash 3.2 陷阱：`"$VAR（"` 会把多字节字符的字节吃进变量名 ─────────────────
# 已用最小例实测（macOS bash 3.2.57）：
#   V=hello; echo "值=$V）之内"  →  "V）: unbound variable"，set -u 下脚本直接 exit 1
#   V=hello; echo "值=${V}）之内"  →  正常
# 为何必须钉死：本仓的报错文案大量是中文，而它们几乎只出现在**fail-closed 分支**里
# —— 那些分支平时不执行，所以 smoke 全绿也发现不了；一旦真的走到，本应“打印
# FINISH_STATUS=BLOCKED 并 exit 2”变成“无任何输出地 exit 1”（已实测到一例），
# 上游拿不到结论标记、排障也无线索 —— 恰好把最需要可靠的那条路径搞成不可靠。
# 只扫**活代码**：跳过注释行与转义的 `\$`（字面量，不展开）。
SCRIPTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# 扫描器写成函数，因为它要被调两次：一次扫夹具（自检）、一次扫真实代码。
# `close ARGV if eof;` 是必需的：perl 的 `$.` 跳文件不自动复位，不关就会把行号
# 一路累加 —— 从第二个文件起，FAIL 诊断里的 file:line 全是错的（指向不存在的行）。
mb_scan() {
  perl -ne '
    if (!/^\s*#/) {
      my $l = $_; $l =~ s/\\\$//g;
      print "$ARGV:$.: $_" if $l =~ /\$[A-Za-z_][A-Za-z0-9_]*[\x80-\xff]/;
    }
    close ARGV if eof;
  ' "$@" 2>/dev/null
}
# 自检（canary）：本断言完全依赖 perl，而 `perl … 2>/dev/null || true` 在 perl 缺失 /
# 自身报错时会返回空串 → 断言恒 PASS（fail-open，三个审查模型一致指出）。
# 先拿一份**已知违规**的夹具验证扫描器真的能报，它报不出就直接 FAIL。
MB_FIXTURE="$(mktemp -d "$TMP_ROOT/mb.XXXXXX")" || { printf 'FAIL cannot create multibyte canary fixture\n'; exit 1; }
printf 'V=x\necho "\xe5\x80\xbc=$V\xef\xbc\x89"\n' > "$MB_FIXTURE/bad.sh"
printf '# \xe6\xb3\xa8\xe9\x87\x8a\xe9\x87\x8c\xe7\x9a\x84 $V\xef\xbc\x89 \xe4\xb8\x8d\xe7\xae\x97\nV=x\necho "${V}\xef\xbc\x89"\n' > "$MB_FIXTURE/good.sh"
if [ -z "$(mb_scan "$MB_FIXTURE/bad.sh")" ]; then
  printf 'FAIL multibyte scanner is broken or perl is unavailable (would pass vacuously)\n'
  exit 1
fi
if [ -n "$(mb_scan "$MB_FIXTURE/good.sh")" ]; then
  printf 'FAIL multibyte scanner false-positives on braced/comment forms\n'
  exit 1
fi
MB_HITS="$(mb_scan "$SCRIPTS_ROOT"/scripts/*.sh "$SCRIPTS_ROOT"/hooks/*.sh "$SCRIPTS_ROOT"/install.sh)"
if [ -n "$MB_HITS" ]; then
  printf '%s\n' "$MB_HITS" | sed 's/^/  /'
  printf 'FAIL bash-3.2 trap: unbraced $VAR immediately followed by a multibyte char (use ${VAR})\n'
  exit 1
fi
printf 'PASS no unbraced $VAR before a multibyte char (bash 3.2 identifier trap)\n'

printf 'PASS smoke-skill-invariants\n'
