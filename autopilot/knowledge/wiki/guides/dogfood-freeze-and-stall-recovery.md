# Dogfood 编排原语：冻结运行 + stall 恢复

> 来源：`raw/20260719-agent-observability-dogfood.md`（primary）。适用于用 autopilot 开发 autopilot 自身、或长跑无人值守 loop。

## 冻结编排器（改 run-track-a.sh/dispatch.sh 自身时必用）

当变更目标是 loop 的编排原语本体（`run-track-a.sh` / `dispatch.sh` / `telemetry.sh` / `parse-status.sh` / `task-state.sh`），**不能直接用仓库脚本跑 loop**——worker 改写 `run-track-a.sh` 会破坏正在执行的 bash 进程（bash 按字节偏移重读被改文件 → 执行错乱）。

**冻结模式**：
```bash
FROZEN=/tmp/ao-frozen; rm -rf "$FROZEN"; mkdir -p "$FROZEN"
cp scripts/{run-track-a,dispatch,parse-status,task-state}.sh "$FROZEN/"
bash "$FROZEN/run-track-a.sh" --change-dir "$PWD/autopilot/changes/<feat>" --cwd "$PWD"
```
冻结副本免疫 worker 对仓库脚本的改动；worker 照常改仓库文件（交付物）；每 Task 的 verify 跑仓库里的新版脚本验证。

## qodercli worker stall 诊断与恢复

**症状**：worker 长时间（≫ 同类 Task 正常耗时）无产出。**诊断优先级**：
1. `ps -Ao pid,etime,%cpu,command | grep qodercli` —— **`%CPU≈0` 且持续 = 卡死**（正常工作 worker `%CPU≈0.3–4`）。
2. 目标文件是否出现（`ls`）—— 长期不出现 = 未在写。
3. **别只看 orchestrator 日志**：qodercli 输出到收尾才 flush，日志停在启动行不代表卡死，要结合 1+2。

**恢复 = kill 进程树 + `--resume`**：
```bash
kill -9 <orchestrator> <dispatch> <tee> <qodercli>   # SIGTERM 常被 run-track-a 的 trap 拦，用 -9
bash "$FROZEN/run-track-a.sh" --change-dir … --cwd … --resume
```
`--resume` 跳过已 DONE 的 Task，由 **fresh worker** 重跑 IN_PROGRESS/BLOCKED 的 Task；fresh worker 通常能清掉瞬时 backend stall（本轮 Task 4 第 3 次成功）。

## 无 timeout 兜底的风险

macOS 默认无 `timeout`/`gtimeout`，`dispatch.sh` 降级为"无时限运行" → **卡死 worker 不会被自动 kill**，长跑 loop 需人工监控。缓解：`brew install coreutils`（装 `gtimeout`），或接受人工 kill/`--resume`。见 [[verify-by-running]] 的 shell 可移植性。

## 自主提交污染防线（C12 实证）

`run-track-a.sh` 每 Task `git add -A`。若仓库根有**自动生成物未 gitignore**（如 `.qoder/repowiki/**`，IDE 生成的知识库 ~130 文件），会被卷入每个 task commit（本轮合并显示 137 files/28k 行，真代码淹没）。**分发型仓库必须 gitignore 一切自动生成物 + 运行态哨兵**（`.qoder/`、`autopilot/.run-active`、`*_opt.md`、日志）。
