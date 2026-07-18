---
updated: 2026-07-18
category: entities
evidence: primary
sources: [raw/20260718-self-evolution-hardening.md]
---

# 实体：scripts/run-autopilot.sh（Track A 端到端编排器）

**是什么**：档位 A 无人值守的端到端入口。确定性 bash 薄包装器，串联三阶段：`run-track-a.sh(loop) → finish → evolve`。

## 职责边界
- **run-autopilot.sh**：端到端编排（loop→finish→evolve），fail-closed 串联。
- **run-track-a.sh**：**只跑 loop**（implement→verify→review→fix→commit），保持单一职责，run-autopilot.sh 不改它。
- 二者都是"确定性脚本编排器"（见 [[track-a-launcher-pattern]]），worker 才是 fresh qodercli。

## 契约
- finish / evolve 各经 dispatch.sh spawn fresh worker（prompt 指向对应 SKILL.md）；用 parse-status.sh 解析 `FINISH_STATUS` / `EVOLVE_STATUS`。
- **fail-closed**：loop `exit≠0` 原样传播、不接力；finish/evolve 非 DONE → `exit 2`。
- 透传 loop 参数（`--tasks/--resume/--max-rounds/--impl-model/--review-model`）；另有 `--skip-finish/--skip-evolve/--finish-model/--evolve-model/--dry-run`。
- 退出码 0/1/2/130；日志入 `$TMPDIR`（不污染业务项目 git）。

## 验证
- `scripts/smoke-run-autopilot.sh`（token-free）：① happy 全链 `exit 0` + finish/evolve 被调用；② fail-closed loop BLOCKED → `exit 2` 且不接力。

## 相关
- 源自 `raw/20260718-self-evolution-hardening.md`；模式见 [[track-a-launcher-pattern]]；铁律见 [[delegate-all-development]]。
