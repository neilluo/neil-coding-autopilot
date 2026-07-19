---
created: 2026-07-19
source: evolve/telemetry-pluggable-sink
evidence: primary
---

# telemetry sink 可插拔化 + 云端就绪讨论

## Problem
`agent-observability` 上线后，用户提出 autopilot 编排器**将来要上云**（形态未定：VM？CI？k8s？），担心"写本地文件夹 + launchd + `~/.zshrc`"不适合云端。诉求：先讨论清楚，再花小代价买保险，别过度设计。

## What / Decision
诊断：现设计是"跨 Unix 主机可移植"、**非"云原生"**；但已分层解耦（采集 ↔ 存储位置 ↔ 调度），上云本质是换两块后端。用户在三档里选"顺手做可插拔 sink"（中间档）。

落地（Track B，1 Task，REVIEW_PASS，FF `df63edf`）：
- `telemetry.sh` 的**唯一写入点** `telemetry_emit` → `_telemetry_sink_dispatch`：按 `NEIL_AUTOPILOT_LOG_SINK`（默认 `file`）组 `_telemetry_sink_<name>`，`type -t` 判函数存在则调、否则回退 `file`。**加云后端 = 加一个函数，采集侧零改动、分发器永不动。**
- 未知 sink 回退 `file`（非 no-op）：不静默丢日志、不阻断（fail-safe）。**不新增 `stdout` sink**（会破坏 in-worker stdout 契约）。
- smoke +2（自定义后端 seam / 未知 sink 兜底 + stdout 洁净）；README/AGENTS/entity 文档。

## Lessons
1. **单点收口是可插拔化的前提**：telemetry 当初把所有事件汇到一个 `telemetry_emit`，这次抽 sink 只改 1 处 + 抽 3 个小函数即成。设计"唯一写入点"是未来换后端的红利。
2. **tasks.md verify 格式坑**：`run-track-a.sh` 只认**每 task 的** `**Verify**: \`cmd\``（反引号包裹，`task_verify()` 按反引号取第 2 段），**不认**表头 `> Verify command:`。写错则 `verify=<none>`、门禁空跑（仍靠 worker+reviewer 兜底，但控制器不独立验证）。**dry-run 的 `verify:` 行是检验点**。
3. **零 stall / 零污染**：本轮 1 Task 一次过、无 worker stall、提交 0 个 `.qoder`——验证上轮 evolve 的 `.gitignore .qoder`（C12）+ stall-recovery 认知有效。小任务比大任务（daily-analysis）明显更少触发 qodercli 瞬时 hang。

## Deferred（详见 guide: cloud-deployment-readiness）
调度器上云适配、分析读侧、`run-track-a.sh` 完整输出复制路径、云端凭证、git 身份 + 合并治理、时区——真部署时再做。
