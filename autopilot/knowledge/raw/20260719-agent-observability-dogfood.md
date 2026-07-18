---
created: 2026-07-19
source: evolve/dogfood-agent-observability
evidence: primary
---

# Dogfooding agent-observability：worker stall、提交污染、自改冻结

## Problem

用 autopilot 的 Track A loop 开发 autopilot 自身的可观测性特性（改 `dispatch.sh`/`run-track-a.sh`、新增 `telemetry.sh` 等），暴露 3 个真实运行期问题：

1. **qodercli worker 瞬时 stall 且不自愈**：Task 4（daily-analysis.sh，最大单件）的 implement worker **连续 2 次卡死**——`ps` 显示 qodercli ~0% CPU、~20 分钟无任何文件产出、impl 日志只有启动 WARN。当时 `timeout`/`gtimeout` 均不存在（macOS 未装 coreutils），`dispatch.sh` 优雅降级为"无时限运行"，因此**卡死的 worker 永远不会被超时 kill**，loop 无限等待。

2. **`.qoder/` 自动生成文件污染自主提交（C12 实例）**：`run-track-a.sh` 每 Task `git add -A` 提交。仓库根的 `.qoder/repowiki/**`（IDE 自动生成的知识库，~130 文件）**未被 .gitignore 屏蔽**，被卷入每个 task commit——FF 合并时 `git merge` 显示 **137 files / 28297 insertions**，真正的代码变更（7 个脚本）淹没在噪声里。

3. **自改脚本损坏运行中编排器的风险**：本次要改的 `run-track-a.sh`/`dispatch.sh` 正是 loop 的编排器本体。若直接用仓库脚本跑，worker 改写 `run-track-a.sh` 时会破坏正在执行的 bash 进程（bash 按字节偏移重读被改文件 → 执行错乱）。

## Solution

1. **stall 恢复 = kill 进程树 + `--resume`**：`kill -9 <orchestrator> <dispatch> <tee> <qodercli>` 清掉卡死 worker，再 `bash run-track-a.sh --resume`——已 DONE 的 Task 跳过、IN_PROGRESS/BLOCKED 的 Task 由 **fresh worker** 重跑。fresh worker 清掉了瞬时 backend stall（第 3 次成功）。诊断信号：qodercli `%CPU≈0` + impl 日志停在启动行 + 目标文件长时间不出现（对比正常 worker `%CPU≈1`）。

2. **`.qoder/` 必须进 .gitignore**：本轮已把 `.qoder/` 加入根 `.gitignore`，防止后续 dogfooding 再污染。历史污染提交保留（清理需 rebase，代价大）。

3. **冻结编排器模式**：改编排器自身时，先 `cp scripts/{run-track-a,dispatch,parse-status,task-state}.sh /tmp/ao-frozen/`，用 `bash /tmp/ao-frozen/run-track-a.sh --cwd <repo>` 跑——冻结副本免疫 worker 对仓库脚本的改动，worker 照常改仓库文件（交付物），每 Task 的 verify 跑仓库里的新版验证。

## Lesson

- **无 timeout 兜底的环境，长跑 loop 有卡死不自愈风险**：建议 `brew install coreutils`（提供 `gtimeout`），让 `dispatch.sh` 能真正 cap worker；否则需人工监控 + kill/`--resume`。
- **分发型仓库根应显式 gitignore 一切自动生成物**（`.qoder/` 等），否则 `git add -A` 自主提交必被污染（C12 的又一实证）。
- **凡 dogfood 修改 `run-track-a.sh`/`dispatch.sh`/`telemetry.sh` 等编排原语本体，一律冻结编排器再跑**（拷贝到仓库外目录执行）。
- **stall 诊断优先看 `%CPU` 与目标文件是否出现**，不要只看 orchestrator 日志（qodercli 输出到收尾才刷）。
