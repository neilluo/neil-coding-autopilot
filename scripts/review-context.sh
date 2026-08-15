#!/usr/bin/env bash
# WHAT: Produce a budget-bounded diff summary of a git repo for review prompts.
#       Outputs: stat section (always full), diff/content section (budget-capped),
#       and a TRUNCATED section when capped.
# USAGE: review-context.sh --cwd <repo> [--budget <bytes>] [--out <file>]
#        review-context.sh -h|--help
# EXIT CODES: 0 success (including graceful non-git fallback), 1 invalid args or output write failure
set -uo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: review-context.sh --cwd <repo> [--budget <bytes>] [--out <file>]
       review-context.sh -h|--help

Options:
  --cwd <repo>     Path to the git repository (required)
  --budget <bytes> Max output size in bytes (default: AUTOPILOT_REVIEW_DIFF_BUDGET or 120000)
  --out <file>     Write output to file instead of stdout
  -h, --help       Show this help

Exit codes: 0=success, 1=invalid arguments or output write failure
EOF
}

CWD=""
BUDGET="${AUTOPILOT_REVIEW_DIFF_BUDGET:-120000}"
OUT=""
# 带值选项缺值必须当场报错退出。本脚本只有 `set -uo pipefail`（无 -e），而 bash 的
# `shift 2` 在 $# < 2 时仅返回非零、**不移除任何参数**，于是 while 以同一个 $1 无限
# 循环：实测 `review-context.sh --cwd /repo --budget` 会 CPU 空转、永不返回（rc=124 靠
# 外部 timeout 才能杀掉）。本脚本在无人值守链路里由 run-track-a / bench 程序化调用，
# 一旦上游拼错参数，得到的不是 fail-closed 而是整条流水线挂死。
# 同仓的 finish-change.sh / archive-change.sh 本就是这么守的，这里对齐。
need_value() { [ "$2" -ge 2 ] || { echo "ERROR: $1 requires a value" >&2; usage; exit 1; }; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --cwd) need_value "$1" $#; CWD="$2"; shift 2 ;;
    --budget) need_value "$1" $#; BUDGET="$2"; shift 2 ;;
    --out) need_value "$1" $#; OUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done
if [ -z "$CWD" ] || ! [ "$BUDGET" -eq "$BUDGET" ] 2>/dev/null || [ "$BUDGET" -lt 1 ]; then
  usage
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
RESULT="$TMP/result"

# git 包装器：`core.quotePath=false` 必须加在**所有列路径与吃路径**的调用上。
# git 默认 core.quotePath=true，含非 ASCII 字节的文件名会被输出成带双引号的八进制
# 转义串（实测：`文档.md` → `"\346\226\207\346\241\243.md"`）。这个**带引号的字面串**被当
# 成真路径回灌给 git，pathspec 匹配不到任何文件，而错误又被 `2>/dev/null` / `|| true`
# 全部吞掉 —— 于是该文件既不在 stat 段、也不在 diff 正文，**还不会触发 TRUNCATED 标记**
# （完整内容本就没超预算）。reviewer 拿到一份看上去完整、实际缺了文件的上下文，
# 完全可能对未被审查的改动给出 REVIEW_PASS：在中文项目里这是很现实的假成功路径。
# pathspec 同时加 `:(literal)`，避开文件名里的 `*` / `[` 被 git 当成通配符解释。
GITQ() { git -c core.quotePath=false -C "$CWD" "$@"; }

is_noise() {
  case "$1" in
    autopilot/changes/*/tasks.md|*.lock|package-lock.json|*.min.*|dist/*|*/dist/*|build/*|*/build/*|target/*|*/target/*|node_modules/*|*/node_modules/*) return 0 ;;
    *) return 1 ;;
  esac
}

bytes() { wc -c < "$1" | tr -d ' '; }

emit() {
  # Write $TMP/full to OUT or stdout, honouring BUDGET exactly.
  local src="$1"
  local size
  size="$(bytes "$src")"
  if [ "$size" -le "$BUDGET" ]; then
    if [ -n "$OUT" ]; then cp "$src" "$OUT"; else cat "$src"; fi
  else
    dd if="$src" of="$RESULT" bs=1 count="$BUDGET" 2>/dev/null
    if [ -n "$OUT" ]; then cp "$RESULT" "$OUT"; else cat "$RESULT"; fi
  fi
}

if ! command -v git >/dev/null 2>&1 || ! git -C "$CWD" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  {
    printf '## 变更概览（文件清单）\n'
    printf '非 Git 仓库或 git 不可用，仅提供文件清单。\n'
    (cd "$CWD" 2>/dev/null && find . -type f 2>/dev/null | sed 's#^./##' | LC_ALL=C sort) || true
    printf '## 变更内容（unified diff，预算内）\n'
    printf '无 Git diff 可用。\n'
  } > "$TMP/full"
  if [ "$(bytes "$TMP/full")" -le "$BUDGET" ]; then
    emit "$TMP/full" || exit 1
  else
    {
      printf '## 变更概览（文件清单）\n'
      printf '非 Git 仓库或 git 不可用。\n'
      printf '## TRUNCATED\n'
    } > "$TMP/non-git-truncated"
    emit "$TMP/non-git-truncated" || exit 1
  fi
  exit 0
fi

TRACKED="$TMP/tracked"
UNTRACKED="$TMP/untracked"
: > "$TRACKED"
: > "$UNTRACKED"
while IFS= read -r path; do
  [ -n "$path" ] && ! is_noise "$path" && printf '%s\n' "$path" >> "$TRACKED"
done < <(GITQ diff --name-only HEAD -- 2>/dev/null)
while IFS= read -r path; do
  [ -n "$path" ] && ! is_noise "$path" && printf '%s\n' "$path" >> "$UNTRACKED"
done < <(GITQ ls-files --others --exclude-standard 2>/dev/null)

STAT="$TMP/stat"
: > "$STAT"
if [ -s "$TRACKED" ]; then
  PATHSPEC_ARGS=()
  while IFS= read -r path; do
    PATHSPEC_ARGS+=(":(literal)$path")
  done < "$TRACKED"
  GITQ diff --stat HEAD -- "${PATHSPEC_ARGS[@]}" 2>/dev/null >> "$STAT" || true
fi
while IFS= read -r path; do
  [ -n "$path" ] && printf ' %s (untracked)\n' "$path"
done < "$UNTRACKED" >> "$STAT"

{
  printf '## 变更概览（git diff --stat，全量，不裁剪）\n'
  cat "$STAT"
  printf '## 变更内容（unified diff，预算内）\n'
} > "$TMP/prefix"

BODY="$TMP/body"
OMITTED="$TMP/omitted"
: > "$BODY"
: > "$OMITTED"
while IFS= read -r path; do
  [ -n "$path" ] || continue
  if GITQ diff --numstat HEAD -- ":(literal)$path" 2>/dev/null | grep -q '^-'; then
    printf '%s（二进制，仅列名）\n' "$path" >> "$BODY"
  else
    GITQ diff --no-ext-diff --binary HEAD -- ":(literal)$path" 2>/dev/null >> "$BODY" || true
  fi
done < "$TRACKED"
while IFS= read -r path; do
  [ -n "$path" ] || continue
  # Skip symlinks to prevent leaking arbitrary local file contents.
  if [ -L "$CWD/$path" ]; then
    printf '%s（符号链接，仅列名）\n' "$path" >> "$BODY"
  elif LC_ALL=C grep -Iq . "$CWD/$path" 2>/dev/null; then
    {
      printf '### untracked: %s\n```\n' "$path"
      cat "$CWD/$path"
      printf '\n```\n'
    } >> "$BODY"
  else
    printf '%s（二进制，仅列名）\n' "$path" >> "$BODY"
  fi
done < "$UNTRACKED"

cat "$TMP/prefix" "$BODY" > "$TMP/full"
if [ "$(bytes "$TMP/full")" -le "$BUDGET" ]; then
  emit "$TMP/full" || exit 1
  exit 0
fi

cat "$TRACKED" "$UNTRACKED" > "$OMITTED"
{
  cat "$TMP/prefix"
  printf '## TRUNCATED\n'
  tr '\n' ' ' < "$OMITTED"
  printf '\n请 reviewer 自行打开以上文件。\n'
} > "$TMP/truncated"
if [ "$(bytes "$TMP/truncated")" -le "$BUDGET" ]; then
  emit "$TMP/truncated" || exit 1
  exit 0
fi

{
  cat "$TMP/prefix"
  printf '## TRUNCATED\n请 reviewer 自行打开文件。\n'
} > "$TMP/minimal"
if [ "$(bytes "$TMP/minimal")" -le "$BUDGET" ]; then
  emit "$TMP/minimal" || exit 1
  exit 0
fi

# Compact mandatory fallback: preserve every stat entry and the intact marker.
{
  printf '## 变更概览\n'
  while IFS= read -r path; do
    [ -n "$path" ] && printf '%s |\n' "$path"
  done < "$TRACKED"
  while IFS= read -r path; do
    [ -n "$path" ] && printf '%s (untracked)\n' "$path"
  done < "$UNTRACKED"
  printf '## TRUNCATED\n'
} > "$TMP/emergency"
# If the complete stat and marker cannot both fit, return the largest bounded prefix.
# Tiny budgets are valid and must still succeed.
emit "$TMP/emergency" || exit 1
