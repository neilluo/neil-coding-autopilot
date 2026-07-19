# telemetry-pluggable-sink — 完成摘要

- 完成时间: 2026-07-19
- 分支: `feature/telemetry-pluggable-sink` → FF 合并至 `master`（本地，`df63edf`；push 待用户确认）
- Task 数: 1（DONE + REVIEW_PASS，一次过、无 fix 轮、无 stall）
- 档位: B（交互）

## 交付物
- `scripts/telemetry.sh`（改）— `telemetry_emit` 走 `_telemetry_sink_dispatch`；新增 `_telemetry_sink_file` / `_telemetry_is_function`；env `NEIL_AUTOPILOT_LOG_SINK`（默认 `file`）；按函数名自动发现后端 seam。
- `scripts/smoke-telemetry.sh`（改）— +scenario 5（自定义后端 seam）/ 6（未知 sink 兜底 + stdout 洁净）。
- `README.md` / `AGENTS.md`（改）— `NEIL_AUTOPILOT_LOG_SINK` 文档。
- `autopilot/knowledge/wiki/entities/telemetry-system.md`（改）— sink seam + out-of-scope 边界。

## 目的
为 autopilot 编排器将来上云（形态未定）买"形态无关"保险：换 OSS/SLS 等后端 = 加一个 `_telemetry_sink_<name>` 函数、采集侧零改动。默认行为零变化。

## 验证
- `smoke-telemetry` / `smoke-dispatch` / `smoke-run-track-a` 全 PASS（控制器独立复跑）。
- 提交 0 个 `.qoder`/`.run-active` 污染（上轮 `.gitignore` 防线生效）。

## 延迟事项（见 guide: cloud-deployment-readiness）
调度器上云适配、分析读侧、`run-track-a.sh` 完整输出路径、云端凭证、git 身份 + 合并治理、时区。
