# agent-observability — 完成摘要

- 完成时间: 2026-07-19
- 分支: `feature/agent-observability` → FF 合并至 `master`（本地，未 push）
- Task 数: 6（全部 DONE + REVIEW_PASS）
- 合并 commit: `741dd41`（Task 6 顶）

## 交付物
- `scripts/telemetry.sh` — fail-safe 遥测库（可 source，写侧零依赖）
- `scripts/dispatch.sh`（改）— 修 set-e 幸存者偏差 + emit dispatch 事件
- `scripts/run-track-a.sh`（改）— 修 fail-closed 出口丢事件 + round/task/run 事件 + EXIT trap
- `scripts/daily-analysis.sh` + `scripts/smoke-daily-analysis.sh` — 每日 jq 聚合 + agent 报告 + 分类回填
- `scripts/install-daily-schedule.sh` — launchd/cron 安装器（PATH 动态构造、env 固化进 plist）
- `scripts/smoke-telemetry.sh` — token-free 冒烟
- `README.md` + `AGENTS.md`（改）— 可观测性与数据驱动自进化文档

## 关键决策（来自 explore/analyze）
- 角色 prompt 是行为方向盘非准确率增强器 → 先建可观测性，数据驱动迭代角色（研究结论）
- 两层保留：`runs/` 3 天滚动 / `metrics/`+`reports/` 长期
- 自进化 = 每日报告出建议 + 人工批；建议只针对**插件自身角色 prompt**（不碰业务项目 AGENTS.md）
- 路径经 `NEIL_AUTOPILOT_LOG_DIR` env（C8，不硬编码用户名）

## 过程教训（详见 knowledge/raw + wiki）
1. **qodercli worker 瞬时 stall**：Task 4 worker 两次卡死（0% CPU、无产出、~20min），无 gtimeout 不自愈；`kill -9` 进程树 + `run-track-a.sh --resume`（fresh worker）第 3 次成功。
2. **`.qoder/` 提交污染（C12 实例）**：`git add -A` 把 ~130 个 `.qoder/repowiki/**` 自动生成文件卷入 6 个 task 提交（137 files/28k 行）——`.qoder/` 未 gitignore。
3. **自改脚本冻结模式**：本次改的是 run-track-a.sh/dispatch.sh 自身，用冻结副本（拷 `/tmp/ao-frozen` 跑）避免 worker 改动损坏运行中的编排器。

## Review 记录
- Spec 经 3 轮 + 终验共 9 个 subagent 审查收敛（4 CRITICAL + 多 MAJOR 全修）
- Loop 每 task 经 Ultimate reviewer CR，全 REVIEW_PASS
