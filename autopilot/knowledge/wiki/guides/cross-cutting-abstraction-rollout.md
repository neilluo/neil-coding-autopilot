---
updated: 2026-07-11
category: guides
evidence: primary
sources: [raw/20260711-dual-track-rollout.md]
---

# 指南：横切抽象的全量 Rollout 与闭环验证

**适用**：当一次变更引入**横切抽象**（跨多个 skill 的新概念，如执行档位、新状态码、新契约）。

## 规则

1. **不 fork 逻辑，集中差异**。执行层各 skill 只保留一套步骤，抽象差异集中到单一事实源（本项目为 `skills/_shared/conventions.md` 档位适配表）。依据：OpenHands V0 按模式 fork 配置 → 2.8K 行 sprawl；Aider 同引擎、模式 = 运行时开关。

2. **全量 rollout 到消费方**。改完定义处，列出所有"消费该抽象"的 skill 并逐一改到。判据：`grep -c <抽象关键字>` 在每个消费方 > 0。

3. **producer→consumer 闭环**。任何新增状态 / 契约必须有明确消费者。反例：review 发 INCOMPLETE 但 loop / finish 不接 = 空头支票。

4. **fail-closed 默认**。新增"未完成 / 未知 / 超时"语义默认挡流程（BLOCKED），绝不 fail-open（force-complete / 静默 PASS）。

## 验证清单（本项目实际用的 grep 断言）

- **覆盖率**：执行层 skill 均含抽象关键字（如 `档位` / `适配表`）。
- **闭环**：producer 与 consumer 都含状态码（如 loop 与 finish 都含 `INCOMPLETE`）。
- **反模式已除**：无 `force complete` / 无硬编码 `main`。

## 相关

- 源自 `raw/20260711-dual-track-rollout.md`
- 约束见 `SCHEMA.md` C1 / C2 / C5
