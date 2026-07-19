# Explore Notes — self-evolution-hardening

> 执行档位：B（交互）｜任务类型：feature（增强 plugin 自进化能力）
> 触发输入：`research-self-evolution-capability.md`（调研：feature 完成后 AGENTS.md 是否主动更新）

## 项目现状摘要

- 形态：Qoder skills 插件（neil-coding-autopilot），"AI 全托管开发编排器"。核心 = 一组 `autopilot-*` skills（md 定义流程）+ `scripts/` bash 原语（dispatch / parse-status / task-state / run-track-a）+ `hooks/`（guard-*）。
- **安装模型（关键）**：`~/.qoder/skills/autopilot-*` 与 `neil-coding-autopilot` 全是 **symlink → 本工作区**（install.sh `ln -sf`）。编辑工作区文件 = 即时更新 Qoder 加载的 skill，**无需 copy/sync**。
- 与需求相关的现有代码：
  - `skills/autopilot-evolve/SKILL.md`：evolve 8 步闭环；Step 6「AGENTS.md 更新」当前**只有 `wc -l` + 超 150 行精简**，无"识别新规则 → 回写"路径。
  - `scripts/run-track-a.sh`：Track A 确定性编排器，**只跑 loop**（implement→verify→review→fix→commit），`exit 0` 后**不接 finish/evolve**。
  - `scripts/dispatch.sh`：统一 spawn qodercli worker（`-m/-w/--permission-mode bypass_permissions/--attachment/-p`，置 `AUTOPILOT_ROLE=worker`）。
  - `scripts/parse-status.sh`：鲁棒解析 worker 的 `*STATUS…DONE/BLOCKED`（对 `FINISH_STATUS=DONE` 亦匹配）。
- 技术约束：bash 3.2 兼容、macOS 无 flock/timeout 需降级、fail-closed、token-free smoke 自检、控制器永不内联写码（开发托管 `run-track-a.sh`）。

## 澄清记录（AskUserQuestion）

| # | 问题 | 用户选择 |
|---|------|---------|
| Q1 | 实现范围 | **Both fixes（全量方案 2）**：evolve AGENTS.md 回写 + Track A relay |
| Q2 | AGENTS.md 回写力度 | **Auto-write, gated**：SearchReplace 回写，受回写门禁（无源不写 / [inferred] / ≤150 行） |
| Q3 | Track A relay 形态 | **新 `run-autopilot.sh` 包装器**（loop→finish→evolve），`run-track-a.sh` 保持 loop-only |

## 关键更正（grounding 发现，纠正调研）

调研方案 2 第 3 步"同步两份 evolve 副本、保持 IDENTICAL"**基于误判**：`~/.qoder/skills/autopilot-evolve` 是**指向本工作区的 symlink**（同 inode `113965426`），并非两份物理副本。调研跑 `diff` 得 IDENTICAL 后**误推**为"两份需同步"。
→ **同步任务取消（moot）**；编辑工作区即生效，本次 run 的 evolve 阶段可直接 dogfood 新 Step 6。此更正将在 evolve 阶段写回知识库（pitfall）。

## 设计方向确认（用户已确认 "go"）

**功能目标**：让 evolve 真正主动回写 AGENTS.md（门禁化），并新增 `run-autopilot.sh` 让 Track A 无人值守端到端跑完 loop→finish→evolve。

**核心设计决策**：
1. evolve Step 6：识别本轮"有据可查"的稳定规则 / 架构变更 / 导航漂移 → SearchReplace 回写 AGENTS.md，受现有回写门禁约束，幂等，守 ≤150 行。
2. 新增 `scripts/run-autopilot.sh`：薄确定性包装器，串 `run-track-a.sh(loop)→finish→evolve`，各阶段经 dispatch.sh spawn fresh worker，fail-closed（loop BLOCKED 即停）。
3. 配套 `scripts/smoke-run-autopilot.sh` token-free 回归 + 文档更新（AGENTS.md / using-neil-autopilot / conventions）。

**不做（scope out）**：
- 不改 `run-track-a.sh` 的 loop 逻辑（只新增包装器）。
- 不重构 symlink 安装模型。
- 不改 finish 的合并 / 归档逻辑（relay 只负责调它）。
- ~~同步两份 evolve 副本~~（symlink，无需同步）。
