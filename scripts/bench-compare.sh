#!/usr/bin/env bash
# WHAT: Compare offline review, skill injection, and replay waste measurements.
# USAGE: bench-compare.sh [-h|--help]
# EXIT CODES: 0=success, 1=measurement failure
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
REPORT="$ROOT/autopilot/changes/autopilot-cost-latency/bench-report.md"
SUMMARY="$ROOT/autopilot/changes/autopilot-cost-latency/summary.md"
BASE_BRANCH="${AUTOPILOT_BENCH_BASE:-master}"

case "${1:-}" in
  -h|--help) echo "Usage: bench-compare.sh [-h|--help]"; exit 0 ;;
  "") ;;
  *) echo "Usage: bench-compare.sh [-h|--help]" >&2; exit 1 ;;
esac
command -v git >/dev/null 2>&1 || { echo "git is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
git -C "$ROOT" rev-parse --verify "$BASE_BRANCH" >/dev/null 2>&1 || { echo "missing base branch: $BASE_BRANCH" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ROWS="$WORK/review-rows"
: > "$ROWS"
total_old=0
total_new=0

pct() {
  awk -v old="$1" -v new="$2" 'BEGIN { if (old == 0) print "NO-DATA"; else printf "%.1f%%", (old-new)*100/old }'
}

measure_commit() {
  commit="$1"
  label="$(git -C "$ROOT" show -s --format='%h %s' "$commit" | sed 's/|/\\|/g')"
  repo="$WORK/repo"
  rm -rf "$repo"
  git clone -q --no-hardlinks "$ROOT" "$repo"
  git -C "$repo" checkout -q "${commit}^"
  git -C "$repo" diff --binary "${commit}^" "$commit" | git -C "$repo" apply
  old=0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if [ -f "$repo/$path" ] && [ ! -L "$repo/$path" ]; then
      size="$(wc -c < "$repo/$path" | tr -d ' ')"
      old=$((old + size))
    fi
  done < <(git -C "$ROOT" diff-tree --no-commit-id --name-only -r "$commit")
  out="$WORK/review.out"
  "$SCRIPT_DIR/review-context.sh" --cwd "$repo" --budget 120000 --out "$out"
  new="$(wc -c < "$out" | tr -d ' ')"
  total_old=$((total_old + old))
  total_new=$((total_new + new))
  printf '| Review context | %s | %s B | %s B | %s |\n' "$label" "$old" "$new" "$(pct "$old" "$new")" >> "$ROWS"
}

while IFS= read -r commit; do
  [ -n "$commit" ] && measure_commit "$commit"
done < <(git -C "$ROOT" log --reverse --format=%H "$BASE_BRANCH..HEAD" --grep='^autopilot(track-a): Task ')

if ! git -C "$ROOT" diff --quiet HEAD -- || [ -n "$(git -C "$ROOT" ls-files --others --exclude-standard)" ]; then
  WORKTREE_FILES="$WORK/worktree-files"
  { git -C "$ROOT" diff --name-only HEAD; git -C "$ROOT" ls-files --others --exclude-standard; } |
    LC_ALL=C sort -u |
    grep -Ev '^autopilot/changes/[^/]+/(tasks\.md|bench-report\.md|summary\.md)$' > "$WORKTREE_FILES" || true
  old=0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    [ -f "$ROOT/$path" ] || continue
    size="$(wc -c < "$ROOT/$path" | tr -d ' ')"
    old=$((old + size))
  done < "$WORKTREE_FILES"
  repo="$WORK/worktree-repo"
  rm -rf "$repo"
  git clone -q --no-hardlinks "$ROOT" "$repo"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    mkdir -p "$repo/$(dirname "$path")"
    if [ -f "$ROOT/$path" ]; then cp "$ROOT/$path" "$repo/$path"; else rm -f "$repo/$path"; fi
  done < "$WORKTREE_FILES"
  "$SCRIPT_DIR/review-context.sh" --cwd "$repo" --budget 120000 --out "$WORK/worktree-review.out"
  new="$(wc -c < "$WORK/worktree-review.out" | tr -d ' ')"
  total_old=$((total_old + old)); total_new=$((total_new + new))
  printf '| Review context | Task 11 worktree | %s B | %s B | %s |\n' "$old" "$new" "$(pct "$old" "$new")" >> "$ROWS"
fi
printf '| Review context | **Total** | **%s B** | **%s B** | **%s** |\n' "$total_old" "$total_new" "$(pct "$total_old" "$total_new")" >> "$ROWS"

skill_old="$(git -C "$ROOT" show "$BASE_BRANCH:skills/using-neil-autopilot/SKILL.md" | wc -c | tr -d ' ')"
skill_new="$(wc -c < "$ROOT/skills/using-neil-autopilot/SKILL.md" | tr -d ' ')"
skill_total=0
for skill in "$ROOT"/skills/*/SKILL.md; do
  [ -f "$skill" ] || continue
  size="$(wc -c < "$skill" | tr -d ' ')"; skill_total=$((skill_total + size))
done

log_root="${NEIL_AUTOPILOT_LOG_DIR:-${HOME:-}/Library/Logs/neil-autopilot}"
failure_count="NO-DATA"; failure_seconds="NO-DATA"; replay_seconds="NO-DATA"
if compgen -G "$log_root/runs/*.jsonl" >/dev/null; then
  failure_count="$(jq -s '[.[] | select(type=="object") | select(.event=="dispatch" and (.stage=="review" or .stage=="fix") and (.failure_class=="TRANSPORT" or .failure_class=="EMPTY" or .failure_class=="TIMEOUT"))] | length' "$log_root"/runs/*.jsonl)"
  failure_seconds="$(jq -s '[.[] | select(type=="object") | select(.event=="dispatch" and (.stage=="review" or .stage=="fix") and (.failure_class=="TRANSPORT" or .failure_class=="EMPTY" or .failure_class=="TIMEOUT"))] | map(.duration_s // 0) | add // 0' "$log_root"/runs/*.jsonl)"
  # `E as $x | body` 里 body 的输入是 **E 的输入**，不是最外层 slurp 数组。旧写法在
  # `[ ... ] | unique as $retried |` 之后，`.` 已经变成「change 名字符串数组」，于是 else
  # 分支里的 `.[] | select(.event==...)` 是在字符串上取 .event。它恰好被前面的
  # `select(type=="object")` 全部过滤掉，所以**不报错**，而是静默得到空数组 → `add // 0`
  # → 永远输出 0（实测：造一条 blocked run + 一条 42s 的 implement dispatch，旧程序得 0、
  # 修后得 42）—— 这个指标从来没真正工作过，而且因为不报错而没人发现。
  # 修法：先把全量事件绑到 $all，else 分支基于 $all 遍历。
  replay_seconds="$(jq -s '
    . as $all |
    [ $all[] | select(type=="object") | select(.event=="run" and .change and .run_id) ] as $runs |
    ([ $runs[] | select(.outcome=="blocked") | .change ] | unique) as $retried |
    if ($retried|length)==0 then "NO-DATA" else
      [ $all[] | select(type=="object") | select(.event=="dispatch" and .stage=="implement" and ([.run_id] | inside([$runs[] | select(.change as $c | $retried | index($c)) | .run_id]))) | .duration_s // 0 ] | add // 0
    end' "$log_root"/runs/*.jsonl)"
fi

{
  echo "# Cost and latency benchmark"
  echo
  echo "Offline deterministic measurements; no model requests are issued."
  echo
  echo '| Group | Scope | Old / count | New / duration | Reduction / avoidable |'
  echo '|---|---|---:|---:|---:|'
  cat "$ROWS"
  printf '| SKILL.md injection | using-neil-autopilot | %s B | %s B | %s |\n' "$skill_old" "$skill_new" "$(pct "$skill_old" "$skill_new")"
  printf '| SKILL.md injection | current skills/* total | N/A | %s B | N/A |\n' "$skill_total"
  printf '| Replay waste | review/fix transient failures | %s events | %s s | %s s avoidable |\n' "$failure_count" "$failure_seconds" "$failure_seconds"
  printf '| Replay waste | blocked/resumed implement replay | N/A | %s s | %s s avoidable |\n' "$replay_seconds" "$replay_seconds"
  echo
  printf '**Conclusion:** Review context changed from %s B to %s B (%s reduction); entry-skill injection changed from %s B to %s B (%s reduction); historical avoidable transient/replay wall time is %s s / %s s.\n' "$total_old" "$total_new" "$(pct "$total_old" "$total_new")" "$skill_old" "$skill_new" "$(pct "$skill_old" "$skill_new")" "$failure_seconds" "$replay_seconds"
} | tee "$REPORT"

summary_line="- Benchmark: review ${total_old} B → ${total_new} B ($(pct "$total_old" "$total_new")); entry SKILL.md ${skill_old} B → ${skill_new} B ($(pct "$skill_old" "$skill_new")); avoidable transient/replay wall time ${failure_seconds} s / ${replay_seconds} s. Offline evidence supports lower review context and injection cost without model calls."
if [ ! -f "$SUMMARY" ] || ! grep -Fq -- '- Benchmark:' "$SUMMARY"; then
  { [ -f "$SUMMARY" ] || printf '# Summary\n\n'; printf '%s\n' "$summary_line"; } >> "$SUMMARY"
else
  python3 - "$SUMMARY" "$summary_line" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
lines = p.read_text().splitlines()
lines = [sys.argv[2] if line.startswith('- Benchmark:') else line for line in lines]
p.write_text('\n'.join(lines) + '\n')
PY
fi
