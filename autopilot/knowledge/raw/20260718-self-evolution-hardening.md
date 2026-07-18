---
created: 2026-07-18
source: evolve/self-evolution-hardening
evidence: primary
---

# 自进化闭环补齐：evolve 门禁化回写 AGENTS.md + run-autopilot.sh 端到端

## Problem
调研 `research-self-evolution-capability.md` 指出插件两处自进化缺口：
1. evolve Step 6 对 AGENTS.md 只有行数守卫（`wc -l`），无"识别新规则 → 回写"路径 → AGENTS.md 与知识库漂移。
2. Track A 有自动化断点：`run-track-a.sh` 只跑 loop，`exit 0` 后无脚本接力 finish/evolve → 无人值守时 evolve / AGENTS 进化实际不发生。

## Solution
- **evolve Step 6 升级为门禁化自动回写**（6a 识别候选[无源不写] → 6b SearchReplace 幂等回写 Critical Rules / Doc Navigation → 6c 行数守卫始终执行），复用 Step 3 现有回写门禁（无源不写 / `[inferred]` / `[disputed]` / 不覆盖用户规则）。
- **新增 `scripts/run-autopilot.sh`**：确定性薄包装器，串 `run-track-a.sh(loop) → finish → evolve`，各阶段经 dispatch.sh spawn fresh worker，fail-closed（loop BLOCKED 即停、不接力）；透传 loop 参数；`--skip-finish/--skip-evolve/--dry-run`；退出码 0/1/2/130。`run-track-a.sh` 保持 loop-only 单一职责不动。
- 配套 `scripts/smoke-run-autopilot.sh`（token-free 两场景：happy 全链 `exit 0` + finish/evolve 被调用；fail-closed `exit 2` + 不接力）。

## Lesson
- **职责分层**：loop-only 编排器（run-track-a.sh）+ 端到端编排器（run-autopilot.sh）分开，别把 finish/evolve 塞进 loop 脚本——单一职责 + 可独立测试。
- **幂等回写**：Step 6b 写 AGENTS.md 前先 grep 是否已存在（本轮 Task 3 已把 run-autopilot.sh 写进 AGENTS.md，evolve 再跑即命中幂等跳过、未重复）——证明门禁化回写的幂等设计有效。
- **dogfood**：本轮用 run-track-a.sh 托管开发 run-autopilot.sh 自身；新 Step 6 在本轮 evolve 首次被真实使用。
