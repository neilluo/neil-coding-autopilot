# Spec — Dual-Track Rollout（完善 workflow-hardening 的"另一半"）

> 变更类型：feature / refactor-completion
> 执行档位：B（交互）
> 分支：延续 `fix/workflow-hardening`（本变更是同一次硬化的下半场）
> 状态源：本文件（设计留痕）+ TodoWrite（Task 状态）

## 1. 背景与问题

`fix/workflow-hardening`（commit 2004e42）引入了两个新抽象，但只落在"框架层"，未下沉到执行层：

- **P1 双档（档位 A 批处理 / B 交互）**：只有 `using-neil-autopilot`(20)、`conventions.md`(11)、`checkpoint`(10) 有 `档位` 感知；执行主体 **loop / plan / finish / evolve / analyze = 0**。→ 档位 B 下控制器调用 `autopilot-loop` 会被无条件指示 "Spawn qodercli implementer/reviewer/fixer"，与入口"档位 B 不 spawn worker"直接矛盾。
- **P0 CR 安全（`REVIEW_STATUS=INCOMPLETE`）**：`review/SKILL.md` 发出 INCOMPLETE 并声称"loop 收到 INCOMPLETE 不得进 finish"，但 `autopilot-loop` 全文不出现 `REVIEW_STATUS`/`INCOMPLETE`，`finish` 也不校验 → 空头支票。

读源码时又发现两个同源缺口：
- **loop 的 fail-open bug**：`autopilot-loop` digraph "CR fix attempts < 3? → no, **force complete**"（L87）——CR 未过仍强制 commit，与 fail-closed 方向自相矛盾。
- **finish 漏改 main**：`autopilot-finish` 仍硬编码 `main`（`--base main` / `git checkout main`，L57-66），正是 review 已修、finish 被遗漏的 P0 分支可移植性 bug。

## 2. 设计方向（GitHub 调研结论，已与用户确认）

**核心决策：不按档位 fork 逻辑，改为"一套步骤 + 一层薄适配"。**

| # | 决策 | 依据（调研来源） |
|---|------|-----------------|
| D1 | 执行层 skill **只保留一套步骤**；档位差异集中在 `conventions.md` 的**单张"档位适配表"**（step→A机制/B机制），各 skill 顶部加一句"按适配表执行"，不复制两套 | OpenHands V0 按 CLI/headless/WebUI fork 配置导致 2.8K 行 sprawl、V1 才"单一事实源"重写（arXiv:2511.03690）；Aider 同引擎、档位=运行时开关(`-m/--yes`) |
| D2 | 状态源差异的正当性：**A=worker 每次 fresh context 需外部记忆(tasks.md/progress.md)；B=单一连续 context，TodoWrite 足矣** | Ralph Loop 的四条跨-reset 记忆通道（git/progress log/task 文件/AGENTS.md）|
| D3 | `INCOMPLETE` 必须 **fail-closed**：未审=挡住，不静默放行；`force-complete` fail-open 一并改为 BLOCKED/上报 | "Fail-closed = 拒绝不完整请求而非带部分信息继续"；"未消费的质量门 = theatre" |
| D4 | INCOMPLETE 的真正消费者在 **finish 的合并前硬门**（"lead 只看到 green code"）+ **loop 的 CR 三态分支** | Addy Osmani 质量门 hook / reviewer 自动触发 |
| D5 | loop 的 track-B 用 **Ralph 五步**（Pick→Implement→Validate→Commit→Reset）+ 安全阀(MAX_ITER、重试前反思、卡3轮 reassign)，仅把"spawn worker"替换为"控制器会话内做" | Ralph Loop |

## 3. 变更范围（7 个 Task，文件导向，每文件只编辑一次）

| Task | 文件 | 核心改动 | 优先级 | Depends | Gate |
|------|------|---------|--------|---------|------|
| T1 | `skills/_shared/conventions.md` | ①档位适配表 ②REVIEW_STATUS 三态共享约定 ③base-branch 自适应 snippet | 基础 | none | auto |
| T2 | `skills/autopilot-loop/SKILL.md` | ①CR 三态 fail-closed ②修 force-open→BLOCKED ③track-B 内联段+Ralph 安全阀 ④digraph 同步 | P0 | T1 | human |
| T3 | `skills/autopilot-finish/SKILL.md` | ①CR 完整性硬门(消费 INCOMPLETE) ②去硬编码 main ③track-B 状态源 | P0 | T1 | human |
| T4 | `skills/autopilot-plan/SKILL.md` | track-B 感知：tasks.md(A) vs TodoWrite(B)，引用适配表 | P1 | T1 | auto |
| T5 | `skills/autopilot-evolve/SKILL.md` | track-B 说明(两档都做)+grow-on-demand：inbox.md/log.md 按需创建(init 已不预建) | P1 | T1 | auto |
| T6 | `skills/autopilot-analyze/SKILL.md` | track-B 状态源轻量说明 | P1 | T1 | auto |
| T7 | `AGENTS.md` / `README.md` + sweep | 拓扑说明"执行层已 track-aware"；残留 sweep(main/spawn-only/INCOMPLETE 闭环) | P2 | T2-T6 | auto |

> Task 数 7（低于 8-20 指南）：本变更是文档/skill 定义类，文件数有限，按"每文件编辑一次"聚合最省 churn，故不强行拆碎。

## 4. 关键改动细节（decision-complete）

### T1 conventions.md（基础，先做）
- 新增 `## 档位适配表`：一张表，行=流程动作（实现代码 / 记录 Task 状态 / 阶段完成标记 / CR 调度 / 恢复），列=档位 A 机制 / 档位 B 机制。作为所有执行层 skill 的唯一引用点。
- 新增 `## REVIEW_STATUS 约定（三态）`：`PASS | FAIL | INCOMPLETE`，明确 **fail-closed 规则**：FAIL 与 INCOMPLETE 都不得进入 finish；INCOMPLETE 需重试一次仍未消解才上报。
- 新增 `## base 分支自适应`：给出 `BASE=$(git symbolic-ref refs/remotes/origin/HEAD ... || master/main 探测)` 的共享 snippet，供 review/finish 复用。

### T2 autopilot-loop（P0 核心）
- CR 判定从 2 态改 3 态：`PASS`→commit+下一个；`FAIL`→fixer（≤3 轮）；`INCOMPLETE`→**fail-closed**：不 commit、不推进、`LOOP_STATUS=BLOCKED|Task N: CR incomplete`，交控制器（重试/缩 diff/人工/显式豁免）。
- 删除 L87 "no, force complete"，改为 `CR fix attempts 用尽 → LOOP_STATUS=BLOCKED`（fail-closed，不再强制 commit 未过审代码）。
- 新增 `## 档位 B（交互）执行`：同 5 步（Pick→Implement→Validate→Commit→Reset），"Spawn qodercli X"→"控制器会话内直接做 X"，`tasks.md`→TodoWrite；Reset 在 B 下为"标记 Todo 完成+进入下一 Task"（无 context 重置）。安全阀：MAX_ITERATIONS + 重试前反思提示 + 卡 3 轮升级。
- digraph 增加 `REVIEW_STATUS=INCOMPLETE → BLOCKED` 边；顶部加"按 conventions 档位适配表执行"。

### T3 autopilot-finish（P0 核心）
- 新增 `### Step 0: CR 完整性门（fail-closed）`：扫描 tasks.md/TodoWrite，若任一 Task `REVIEW_STATUS ∈ {FAIL, INCOMPLETE}` 或存在未审文件 → `FINISH_STATUS=BLOCKED`，拒绝合并。这是 INCOMPLETE 的落地消费者。
- Step 3/4/选项B：`main` 全部替换为 T1 的 `$BASE` 自适应；PR `--base "$BASE"`，合并 `git checkout "$BASE"` / `git push origin "$BASE"`。
- Step 6 归档：档位 B 下 explore-notes/tasks.md 可能不存在，`cp ... 2>/dev/null || true` 容错（部分已有）；状态源按适配表。

### T4/T5/T6（P1 rollout）
- plan：Step 4 顶部注明 A 写 tasks.md、B 可用 TodoWrite 代替（拆解逻辑不变），引用适配表。
- evolve：开头加"两档都必须 evolve（不变量）"；Step 2/4 写 inbox.md/log.md 处加"若不存在则创建"（与 init 的 grow-on-demand 对齐）。
- analyze：加一句状态源随档位（A=progress.md、B=TodoWrite），逻辑不动。

### T7（P2 收尾）
- AGENTS.md/README：在拓扑说明处补一句"执行层 skill 已 track-aware，档位差异集中于 conventions 适配表"。
- 残留 sweep：`grep` 确认无 `git checkout main`/`--base main` 残留、loop/finish 均含 `INCOMPLETE`、执行层均引用适配表。

## 5. 验证方式（本仓库无编译，用 grep 断言）

```bash
# V1 双档覆盖：执行层均含"档位"或引用适配表
for f in loop plan finish evolve analyze; do grep -q "档位\|适配表" skills/autopilot-$f/SKILL.md || echo "MISS: $f"; done
# V2 INCOMPLETE 闭环：loop 与 finish 都消费 INCOMPLETE
grep -q "INCOMPLETE" skills/autopilot-loop/SKILL.md && grep -q "INCOMPLETE" skills/autopilot-finish/SKILL.md || echo "MISS: INCOMPLETE 闭环"
# V3 fail-open 已除
grep -q "force complete" skills/autopilot-loop/SKILL.md && echo "STILL fail-open"
# V4 去硬编码 main
grep -nE "checkout main|--base main|origin main" skills/autopilot-finish/SKILL.md && echo "STILL hardcoded main"
```
全部无输出（V3/V4 无匹配）= 通过。

## 6. 风险与回滚
- 风险：双档条件描述增多可能让 reading agent 判错档位 → 缓解：适配表集中单点 + 各 skill 只留一句引用，不复制逻辑（D1）。
- 回滚：纯 Markdown 变更，`git revert` 单/多 commit 即可；不影响运行时代码。

## 7. 完成定义（DoD）
- 第 5 节 V1-V4 全绿；loop/finish 的 INCOMPLETE 契约端到端闭环；`fix/workflow-hardening` 的 P1/P2 遗留清零；docs 与实现一致。
