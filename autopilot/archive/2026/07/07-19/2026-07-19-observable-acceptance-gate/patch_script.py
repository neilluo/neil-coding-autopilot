#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Give the headless Track A reviewer real teeth for Observable Acceptance.
3 minimal, general edits to run-track-a.sh (prompt text + arg normalization +
feeding the current Task block to the reviewer). No loop/dispatch/state-machine
control-flow change. Fail-loud: every anchor must match exactly once."""
import sys

F = "/Users/neil/Desktop/neilcodebase/neil-coding-autopilot/scripts/run-track-a.sh"

EDITS = []

# A) build_review_prompt takes the task number
EDITS.append((
"""build_review_prompt() {
  local files="$1" out="$2\"""",
"""build_review_prompt() {
  local files="$1" out="$2" n="${3:-}\""""))

# B1) inject the Observable-Acceptance review dimension
EDITS.append((
'    echo "- 项目特定：读 AGENTS.md / autopilot/knowledge/SCHEMA.md / wiki/guides/*（存在才读），把其中强制规则当 Major 检查项。"',
'''    echo "- 项目特定：读 AGENTS.md / autopilot/knowledge/SCHEMA.md / wiki/guides/*（存在才读），把其中强制规则当 Major 检查项。"
    echo "- 可观测验收（本 Task 若改动用户可观测输出——UI/CLI/API/告警/报表）：读 $CHANGE_DIR/spec.md 的「可观测验收」段 + $SCRIPT_DIR/../skills/_shared/observable-acceptance.md，核验 ① 每个改动的可观测值/态有 SSOT + 判别性蜕变关系（多源值扰动非权威源期望不同）；② 下方本 Task 块的 Verify 为确定性扰动测试（非仅编译级）且期望可追溯到 spec 的 MR；③ 标 UNVERIFIED-OBSERVABLE 者须确为无离线宿主的纯渲染层、否则免除无效。缺失/对不上/免除滥用 → MAJOR。纯内部改动（无可观测变化）跳过本维度。"'''))

# B2) feed the current Task block (contains **Verify** and any UNVERIFIED marker)
EDITS.append((
'    echo; echo "## 结论（回复末尾必须输出其一）"',
'''    echo; echo "## 本 Task 块（含 **Verify** 与可能的 UNVERIFIED-OBSERVABLE 标记，供 ②③ 交叉核验）"; echo
    [ -n "$n" ] && task_block "$n"
    echo; echo "## 结论（回复末尾必须输出其一）"'''))

# C) pass $n at the call site
EDITS.append((
'    build_review_prompt "$LOG_DIR/task-$n-files-$round.txt" "$LOG_DIR/task-$n-review-$round-prompt.md"',
'    build_review_prompt "$LOG_DIR/task-$n-files-$round.txt" "$LOG_DIR/task-$n-review-$round-prompt.md" "$n"'))

# D) absolutize CHANGE_DIR so the worker (cwd=$CWD) can always resolve spec.md
EDITS.append((
'[ -n "$CHANGE_DIR" ] || { echo "ERROR: --change-dir is required (use --help)" >&2; exit 1; }',
'''[ -n "$CHANGE_DIR" ] || { echo "ERROR: --change-dir is required (use --help)" >&2; exit 1; }
CHANGE_DIR="$(cd "$CHANGE_DIR" 2>/dev/null && pwd -P || printf %s "$CHANGE_DIR")"  # absolute so review worker (cwd=$CWD) can read spec.md'''))

s = open(F, encoding="utf-8").read()
for old, new in EDITS:
    c = s.count(old)
    if c != 1:
        print(f"FAIL: anchor count={c} (want 1) for: {old[:56]!r}"); sys.exit(1)
    s = s.replace(old, new, 1)
open(F, "w", encoding="utf-8").write(s)
print("OK: run-track-a.sh +5 anchors (dimension + task-block feed + $n + CHANGE_DIR abs)")
