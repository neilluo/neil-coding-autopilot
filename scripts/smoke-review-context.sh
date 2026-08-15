#!/usr/bin/env bash
# WHAT: Smoke-test scripts/review-context.sh with a synthetic git repo.
#       Validates budget bounds, noise filtering, truncation invariants,
#       stat completeness, symlink safety, and non-git fallback.
# USAGE: smoke-review-context.sh [-h|--help]
# EXIT CODES: 0=all assertions pass, 1=one or more assertions failed
set -uo pipefail
unset AUTOPILOT_RUN_ID

case "${1:-}" in
  -h|--help)
    sed -n '2,5p' "$0" | sed 's/^# //'
    exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILED=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILED=$((FAILED + 1)); }
assert_absent() {
  local file="$1" pattern="$2" message="$3"
  if grep -Fq "$pattern" "$file"; then fail "$message"; else pass "$message"; fi
}
assert_size() {
  local file="$1" budget="$2" message="$3" size
  size="$(wc -c < "$file" | tr -d ' ')"
  if [ "$size" -le "$budget" ]; then pass "$message"; else fail "$message ($size > $budget)"; fi
}

# Count stat entries: tracked lines containing '|' plus untracked lines containing '(untracked)'.
stat_entry_count() {
  awk '/^## 变更概览/{inside=1; next} /^## 变更内容/{inside=0} inside && (/\|/ || /\(untracked\)/) {count++} END {print count+0}' "$1"
}

REPO="$TMP/repo"
mkdir -p "$REPO/node_modules" "$REPO/autopilot/changes/foo"
git -C "$REPO" init -q
git -C "$REPO" config user.email smoke@example.com
git -C "$REPO" config user.name Smoke
printf 'old\n' > "$REPO/app.txt"
printf 'ignored old\n' > "$REPO/node_modules/x.js"
printf 'task old\n' > "$REPO/autopilot/changes/foo/tasks.md"
printf '\001\002old\000' > "$REPO/image.bin"
git -C "$REPO" add .
git -C "$REPO" -c core.hooksPath=/dev/null commit -qm initial
printf 'old\nnew content marker\n' > "$REPO/app.txt"
printf 'ignored new\n' > "$REPO/node_modules/x.js"
printf 'task new\n' > "$REPO/autopilot/changes/foo/tasks.md"
printf '\001\002new\000' > "$REPO/image.bin"
printf 'untracked marker\n' > "$REPO/new.txt"

# Symlink pointing to a sensitive file — must NOT be expanded.
ln -s /etc/hosts "$REPO/sneaky-link.txt" 2>/dev/null || ln -s /dev/null "$REPO/sneaky-link.txt"

LARGE="$TMP/large.txt"
MEDIUM="$TMP/medium.txt"
SMALL="$TMP/small.txt"
if bash "$SCRIPT_DIR/review-context.sh" --cwd "$REPO" --budget 20000 --out "$LARGE"; then
  pass 'large-budget generation succeeds'
else
  fail 'large-budget generation succeeds'
fi
assert_size "$LARGE" 20000 'large output respects budget'
assert_absent "$LARGE" '## TRUNCATED' 'large output is not truncated'
grep -Fq 'new content marker' "$LARGE" && pass 'tracked diff is included' || fail 'tracked diff is included'
grep -Fq 'untracked marker' "$LARGE" && pass 'untracked content is included' || fail 'untracked content is included'
grep -Fq 'image.bin' "$LARGE" && pass 'binary file is listed' || fail 'binary file is listed'
assert_absent "$LARGE" 'node_modules/x.js' 'node_modules is filtered'
assert_absent "$LARGE" 'autopilot/changes/foo/tasks.md' 'tasks.md is filtered'

# Symlink: the link must be LISTED by name, but its target's content must NOT be expanded.
# 旧写法把两件事揉成一个条件且写反了：
#   if grep -q 'localhost' && ! grep -Fq 'sneaky-link'; then fail ... else pass ...
# 真正的泄露场景是「既列出了 sneaky-link、又展开了 /etc/hosts 内容」—— 此时
# `! grep -Fq 'sneaky-link'` 为假、整个条件为假 → 走 else → **pass**。也就是说，
# review-context.sh 一旦改成 `cat` 未跟踪文件（而不是跳过 symlink）、把 /etc/hosts
# 内容写进 reviewer prompt，这条断言照样 PASS。拆成两条独立断言：
#   ① 链名必须出现（否则“没泄露”可能只是文件根本没被枚举，等于没测）；
#   ② 目标内容（/etc/hosts 里的 localhost）绝不能出现。
grep -Fq 'sneaky-link' "$LARGE" && pass 'symlink itself is listed (so the no-leak check is meaningful)' || fail 'symlink not listed at all — the no-leak assertion would be vacuous'
grep -q 'localhost' "$LARGE" 2>/dev/null && fail 'symlink target content leaked into review context' || pass 'symlink content is not expanded (no /etc/hosts data)'

bash "$SCRIPT_DIR/review-context.sh" --cwd "$REPO" --budget 800 --out "$MEDIUM" || fail 'medium-budget generation succeeds'
bash "$SCRIPT_DIR/review-context.sh" --cwd "$REPO" --budget 200 --out "$SMALL" || fail 'small-budget generation succeeds'
assert_size "$MEDIUM" 800 'medium output respects budget'
assert_size "$SMALL" 200 'small output respects requested budget'
grep -Fq '## TRUNCATED' "$SMALL" && pass 'small output reports truncation' || fail 'small output reports truncation'

LARGE_STAT="$(stat_entry_count "$LARGE")"
SMALL_STAT="$(stat_entry_count "$SMALL")"
[ "$LARGE_STAT" -gt 0 ] && pass 'stat entries are detected' || fail 'stat entries are detected'
[ "$LARGE_STAT" = "$SMALL_STAT" ] && pass 'stat entries complete when truncated (small)' || fail "stat entries complete when truncated (small): large=$LARGE_STAT small=$SMALL_STAT"

assert_absent "$MEDIUM" 'node_modules/x.js' 'medium output filters node_modules'
assert_absent "$SMALL" 'autopilot/changes/foo/tasks.md' 'small output filters tasks.md'

PLAIN="$TMP/plain"
mkdir -p "$PLAIN/sub"
printf 'plain marker\n' > "$PLAIN/sub/file.txt"
FALLBACK="$TMP/fallback.txt"
if bash "$SCRIPT_DIR/review-context.sh" --cwd "$PLAIN" --budget 1000 --out "$FALLBACK"; then
  pass 'non-git directory degrades gracefully'
else
  fail 'non-git directory degrades gracefully'
fi
grep -Fq '非 Git 仓库' "$FALLBACK" && pass 'fallback explains non-git mode' || fail 'fallback explains non-git mode'
grep -Fq 'sub/file.txt' "$FALLBACK" && pass 'fallback includes file list' || fail 'fallback includes file list'
assert_size "$FALLBACK" 1000 'fallback output respects budget'

FALLBACK_SMALL="$TMP/fallback-small.txt"
if bash "$SCRIPT_DIR/review-context.sh" --cwd "$PLAIN" --budget 100 --out "$FALLBACK_SMALL"; then
  pass 'over-budget non-git fallback succeeds'
else
  fail 'over-budget non-git fallback succeeds'
fi
assert_size "$FALLBACK_SMALL" 100 'over-budget non-git fallback respects budget'
grep -Fq '## TRUNCATED' "$FALLBACK_SMALL" && pass 'over-budget non-git fallback reports truncation' || fail 'over-budget non-git fallback reports truncation'

TINY="$TMP/tiny.txt"
if bash "$SCRIPT_DIR/review-context.sh" --cwd "$REPO" --budget 1 --out "$TINY"; then
  pass 'tiny-budget generation succeeds'
else
  fail 'tiny-budget generation succeeds'
fi
assert_size "$TINY" 1 'tiny output respects requested budget'

if bash "$SCRIPT_DIR/review-context.sh" --cwd "$REPO" --budget 1000 --out "$TMP/missing/output.txt" 2>/dev/null; then
  fail '--out write failure returns nonzero'
else
  pass '--out write failure returns nonzero'
fi

if [ "$FAILED" -ne 0 ]; then
  printf '%s smoke assertion(s) failed\n' "$FAILED" >&2
  exit 1
fi
printf 'smoke-review-context: PASS\n'
