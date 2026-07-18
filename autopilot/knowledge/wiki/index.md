# Knowledge Wiki Index

> Agent 每次会话读取本文件定位知识。

## Guides（编码规则 / 指南）
- [[cross-cutting-abstraction-rollout]] — 横切抽象的全量 rollout 与闭环验证
- [[verify-by-running]] — verify-by-running + shell 可移植性
- [[self-contained-script-resolution]] — 分发型 plugin 自带脚本的可移植定位
- [[track-a-launcher-pattern]] — 自主批处理用确定性脚本编排器（非 LLM 编排）
- [[delegate-all-development]] — 控制器永不内联写码，开发一律托管子 agent
- [[dogfood-freeze-and-stall-recovery]] — dogfood 冻结编排器 + qodercli worker stall 诊断/恢复 + 提交污染防线

## Concepts（架构决策）

## Entities（模块 / 组件）
- [[run-autopilot]] — Track A 端到端编排器（loop→finish→evolve），fail-closed
- [[telemetry-system]] — 自观测遥测 + 每日分析 + 数据驱动自进化建议（telemetry.sh / daily-analysis.sh / install-daily-schedule.sh）

## Comparisons（对比分析）
