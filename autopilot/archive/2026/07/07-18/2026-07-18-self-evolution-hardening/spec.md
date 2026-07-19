# Spec — self-evolution-hardening（evolve 主动回写 AGENTS.md + Track A 端到端）

> 变更类型：feature（补齐插件自进化闭环）
> 执行档位：B（交互）；开发经 `run-track-a.sh` 托管
> 分支：`feature/self-evolution-hardening`（从 master 切出）
> 状态源：TodoWrite（阶段级）+ `tasks.md`（Task 级，脚本维护）
> 输入：`research-self-evolution-capability.md` + `explore-notes.md`

## 1. 背景与根因

调研结论：插件"能自进化，但进化主体是知识库、非 AGENTS.md"。两处缺口：
- **evolve Step 6 对 AGENTS.md 只有行数守卫**（`wc -l` + 超 150 行精简），无"识别新规则 → 回写"路径 → AGENTS.md 与知识库实际状态漂移。
- **Track A 有自动化断点**：`run-track-a.sh` 只跑 loop，`exit 0` 后无脚本接力 finish/evolve → 无人值守时 evolve / AGENTS 进化实际不发生。

**grounding 更正**：调研"同步两份 evolve 副本"基于误判——`~/.qoder/skills/autopilot-evolve` 是指向本工作区的 symlink（同 inode），非两份物理副本。→ 同步任务取消。

## 2. 方案（用户确认：Both / Auto-write gated / run-autopilot.sh 包装器）

| # | 改动 | 说明 |
|---|------|------|
| ① | `skills/autopilot-evolve/SKILL.md` Step 6 重写 | 增量改 Step 6：**6a 识别候选**（无源不写）→ **6b SearchReplace 门禁化回写** Critical Rules / Doc Navigation（幂等、`[inferred]`/`[disputed]` 标注、不覆盖用户规则）→ **6c 行数守卫**（始终执行）。Step 8 汇总加 AGENTS.md 变更行。其余步骤一字不动。 |
| ② | `scripts/run-autopilot.sh`（新） | 薄确定性包装器：`run-track-a.sh(loop) → finish → evolve`；finish/evolve 经 dispatch.sh spawn fresh worker（prompt 指向对应 SKILL.md 执行）；fail-closed；透传 loop 参数；`--skip-finish/--skip-evolve/--finish-model/--evolve-model`；`--dry-run` 只打印计划；退出码 0/1/2/130；日志入 `$TMPDIR`。 |
| ③ | `scripts/smoke-run-autopilot.sh`（新） | token-free：stub qodercli；①happy 全链 loop→finish→evolve `exit 0`；②fail-closed：loop BLOCKED → `exit 2` 且 finish/evolve **未被调用**。 |
| ④ | 文档：`AGENTS.md` / `using-neil-autopilot` / `conventions.md` | 新增 `run-autopilot.sh` 为 Track A 无人值守端到端入口；注明 evolve 现会门禁化回写 AGENTS.md。 |

## 3. evolve Step 6 回写契约（门禁化，复用 Step 3 现有回写门禁）

- **无源不写**：每条候选须溯源到本轮 `raw/` 文件或真实代码变更。
- **幂等**：写前 grep 是否已存在，重跑不重复追加。
- **不覆盖**：只追加规则 / 修链 / 并列标注；推理标 `[inferred]`、矛盾标 `[disputed]`，保留原条目。
- **守行数**：6c 始终跑 `wc -l AGENTS.md`；6b 追加导致超 150 行时，优先移旧细节入 `wiki/entities/` 而非放弃新规则。

## 4. run-autopilot.sh fail-closed 契约

- loop（`run-track-a.sh`）`exit≠0` → 原样传播退出码，**不进 finish/evolve**。
- finish worker 输出非 `FINISH_STATUS=DONE`（经 `parse-status.sh` 解析）→ `exit 2`，不进 evolve。
- evolve worker 输出非 `EVOLVE_STATUS=DONE` → `exit 2`。
- 全链成功 → 移除 `autopilot/.run-active` 哨兵（与 finish/evolve 双保险）→ `exit 0`。
- `--dry-run` 打印 "loop→finish→evolve" 计划、不 spawn（loop 部分透传 `run-track-a.sh --dry-run`）。
- 可移植性：bash 3.2 / macOS 安全，self-locate 兄弟脚本（`run-track-a.sh`/`dispatch.sh`/`parse-status.sh`），不依赖 GNU-only 工具。

## 5. 验证（token-free 为主）

- `bash -n` 全绿（run-autopilot.sh / smoke-run-autopilot.sh）。
- `bash scripts/smoke-run-track-a.sh` 仍全 PASS（未回归既有编排器）。
- `bash scripts/smoke-run-autopilot.sh` 两场景全 PASS（happy `exit 0` + fail-closed `exit 2` 不触 finish/evolve）。
- evolve Step 6：grep 结构校验（含 `6a`/`6b`/`6c`、`SearchReplace`、`无源不写`、`wc -l AGENTS.md`）。
- dogfood：本次 run 的 evolve 阶段用新 Step 6 回写 AGENTS.md（人工盯门禁）。

## 6. 边界与不做

- 不改 `run-track-a.sh` loop 逻辑；不改 finish 合并逻辑；不重构 symlink 安装模型；不同步"两份副本"（symlink 无需）。
- `run-autopilot.sh` 面向档位 A（无人值守）；本次 run 仍走档位 B（控制器会话内跑 finish/evolve）——不产生自举悖论。
