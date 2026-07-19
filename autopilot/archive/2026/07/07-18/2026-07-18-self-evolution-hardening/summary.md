# self-evolution-hardening — 完成摘要

- 完成时间: 2026-07-18
- 执行档位: B（交互）；开发经 run-track-a.sh 托管（3 Task fresh qodercli worker，context 隔离）
- 分支: feature/self-evolution-hardening → master（本地 FF 合并，未 push）
- Task 数: 3（全 DONE，全 REVIEW_PASS，无 CRITICAL/MAJOR）

## 交付
1. evolve Step 6 升级为门禁化 AGENTS.md 自动回写（6a 识别候选[无源不写] → 6b SearchReplace 幂等回写 → 6c 行数守卫）。
2. 新增 scripts/run-autopilot.sh（Track A 端到端编排器 loop→finish→evolve，fail-closed）+ scripts/smoke-run-autopilot.sh（token-free 2 场景）。
3. 文档：AGENTS.md / using-neil-autopilot / conventions 增补 run-autopilot.sh 端到端入口。

## 关键决策
- AGENTS.md 回写：自动、受回写门禁（无源不写 / [inferred] / 不覆盖用户规则 / ≤150 行）。
- Track A relay：新 run-autopilot.sh 薄包装器（run-track-a.sh 保持 loop-only 单一职责）。

## grounding 更正
- 调研"同步两份 evolve 副本"为误判：~/.qoder/skills/autopilot-evolve 是指向工作区的 symlink（同 inode），无需同步。已砍掉该伪任务（沉淀为 raw + verify-by-running guide）。

## 验证
- bash -n 全绿；smoke-run-autopilot ALL PASS（happy exit0 + relay / fail-closed exit2 不接力）；smoke-run-track-a 无回归；AGENTS.md 115 行(≤150)。

## dogfood
- 本轮用 run-track-a.sh 托管开发 run-autopilot.sh 自身；本轮 evolve 首次真实使用新 Step 6 回写 AGENTS.md（2 处，幂等 + 溯源）。
