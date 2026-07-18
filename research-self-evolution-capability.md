# 调研：Autopilot 插件的"自进化"能力（重点：feature 完成后 AGENTS.md 是否主动更新）

> 调研日期：2026-07-18
> 调研范围：`neil-coding-autopilot` 插件源码（`~/.qoder/skills/neil-coding-autopilot/` 及同级 `autopilot-*` skills）
> 方法：只读通读 SKILL.md / scripts / conventions，严格基于源码，不臆测
> 触发背景：用户问"这个 plugin 能否帮项目自进化，比如 feature 开发完后主动更新 AGENTS.md"

---

## 一句话结论

**能自进化，但"进化的主体是知识库，不是 AGENTS.md"。**

feature 开发完成后，插件会**强制执行 `evolve` 阶段**，把 CR 发现的规律、踩坑、新模块**真实写回知识库**（`autopilot/knowledge/` 的 raw → wiki → index，受回写门禁约束）。
但具体到 **AGENTS.md 本身的"主动更新"，力度很弱且是条件触发的**——它不会像知识库那样丰富地自动生长内容。招牌上的"AGENTS.md 自进化"**名大于实**。

---

## 1. 进化对象拆解

| 进化对象 | 是否自动 | 力度 | 依据 |
|----------|---------|------|------|
| **知识库** (`raw/` → `wiki/` → `index.md`) | ✅ 强制、真写文件 | 强，8 步闭环 + 回写门禁 | evolve 是 HARD-GATE #5，"不得跳过" |
| **SCHEMA.md** | ✅ 有新约束时更新 | 中 | evolve Step 5 |
| **AGENTS.md** | ⚠️ **条件触发**（"如有架构变更"） | **弱** | evolve Step 6 **只有** `wc -l` + 超 150 行才精简 |

**关键点**：`autopilot-evolve/SKILL.md` 的 Step 6 对 AGENTS.md 的**唯一明确动作是"行数守卫"**（超 150 行就把细节挪进 `wiki/entities/`）。**没有**"识别本轮新增稳定规则 → 追加到 Critical Rules / 更新 Doc Navigation"的写入流程。AGENTS.md 的**全量生成/迁移是 `init` 的职责**，不是 evolve。

---

## 2. evolve 做什么（8 步闭环）

evolve 的两份 SKILL.md 内容**完全一致**（顶层 `~/.qoder/skills/autopilot-evolve/SKILL.md` 与插件内 `skills/autopilot-evolve/SKILL.md`，`diff` 结果 IDENTICAL）。核心目标是"知识库"而非 AGENTS.md：

- **Step 1 收集本轮经验**：来源 = ① CR 反馈 ② 编译失败 ③ Task BLOCKED ④ 新增模块
- **Step 2 写 `raw/`（不可变源）**：`{YYYYMMDD}-{slug}.md`，append-only 语义，一旦写入不可修改
- **Step 3 Ingest（raw → wiki 编译）**：2-Step CoT，归类到 `entities/concepts/guides/comparisons`，维护 `[[wikilink]]`，更新 `wiki/index.md`
- **Step 4 更新 `log.md` / `inbox.md`**（不存在则创建）
- **Step 5 SCHEMA.md 更新**（如有新约束）
- **Step 6 AGENTS.md 更新**（如有架构变更）——**仅** `wc -l AGENTS.md` + 超 150 行则精简
- **Step 7 Lint 建议**（每 5 次 evolve）；**Step 7.9** 移除 `autopilot/.run-active` 哨兵
- **Step 8 输出** `EVOLVE_STATUS=DONE`

**写回门禁（约束 evolve 写入，防幻觉传播）**：
- 必须有明确来源（raw 文件 / 官方文档 URL）——**无源不写**
- 纯推理内容标注 `[inferred]`，与现有 wiki 矛盾标 `[disputed]`，不直接覆盖
- inferred 内容占比不超过 30%；不删除已有 wiki 页面（只更新或归档）

**防超行 / compaction**：有。约束段写明 "AGENTS.md 不超过 150 行"、"SCHEMA.md 不超过 200 行"、"单次 ingest 不超过 15 页更新"。

---

## 3. 触发时机 & 强制性

**触发时机**（evolve SKILL「触发条件」）：
- autopilot-loop 完成后（无论全部完成还是部分完成）
- autopilot-finish 完成后

编排器流程图（`skills/using-neil-autopilot/SKILL.md`）中 evolve 是 finish 之后的最后阶段：
`finish → checkpoint(finish) → evolve → Done`

**是否强制**：**强制不可跳过**。
- HARD-GATE #5："知识沉淀（evolve）：把 CR 发现的规律与踩坑写回知识库。"
- Skill 调用规则通用第 4 条："不得跳过 evolve（知识沉淀强制）。"
- evolve SKILL："档位无关：两档（A 无人值守 / B 交互）都必须执行 evolve（知识沉淀是不变量）。"

---

## 4. 档位 A / 档位 B 的自动化程度（关键：loop 自动化 ≠ evolve 自动化）

**`run-track-a.sh` 的职责边界**（读全文确认）：它**只跑 loop 内循环**（implement → verify → review → fix → commit），**不含 finish/evolve**。
- 头注释：`for each PENDING task, runs the inner loop implement → verify → review → (fix)* → commit`
- main 循环只 `for n in TASK_NUMS: run_task "$n"`，结束即 `ALL TASKS DONE ✅ (Track A complete); exit 0`
- 全文无任何 finish / evolve / AGENTS / knowledge 字样

**因此存在一个真实的自动化断点**：

| 档位 | loop 自动化 | evolve 触发方式 |
|------|-----------|----------------|
| **A · 无人值守** | ✅ 终端 `run-track-a.sh` 端到端 | ❌ **不在脚本内**；需外层控制器/人在脚本 `exit 0` 后**单独再起一步** `Skill(autopilot-evolve)` |
| **B · 交互** | ✅ 控制器调 `run-track-a.sh` | ✅ 控制器**跑完在会话内继续 finish/evolve**（明确写在 SKILL） |

> ⚠️ 若"无人值守"仅指跑 `run-track-a.sh`，则 evolve / AGENTS 进化实际上**不会发生**，除非有更外层控制器接力。源码里**没有**任何脚本在 `run-track-a.sh exit 0` 后自动接力调 finish/evolve。
>
> ✅ **档位 B（交互）才能可靠保证 evolve 真的发生。**

---

## 5. AGENTS.md 进化的真实力度（自动改 or 仅建议）

**是"真实写文件"，不是"仅建议"——但 AGENTS.md 这块力度弱且条件化：**

- evolve 由 LLM agent（`AUTOPILOT_EVOLVE_MODEL=Ultimate`）执行，会**实际读写文件**（raw/wiki/index/log/SCHEMA 都是真写）。SCHEMA.md 头部自证 `Maintained by autopilot-evolve`。
- **但 AGENTS.md 具体到 evolve Step 6 只有 `wc -l` + 超 150 行才精简**，没有"识别新规则 → SearchReplace 追加到 Critical Rules"的写入路径。真正**生成/迁移** AGENTS.md 的是 **init**（Step 2 "Generate AGENTS.md"，60-150 行 Index 风格；约束"不覆盖用户已有的 AGENTS.md"）。
- 另有一个**纯提示型**触点（不是自动改）：init 生成的 `pre-completion.md` 清单里一条 `[ ] AGENTS.md updated if architecture changed`——这是给 worker 的自检提醒，靠人/agent 自觉。

---

## 6. 用真实项目印证（video-distributor / xyf）

这个"AGENTS.md 进化弱"的结论，在 `/Users/neil/Desktop/neilcodebase/xyf` 项目上**活生生印证**了：

- 该项目的知识库早已从"旧扁平结构"进化成"三层 wiki"（`SCHEMA.md` + `wiki/`）——**知识库进化发生了**；
- 但项目根 `AGENTS.md` 的 Doc Navigation 却**没跟着更新**，仍指向已删除的 `rules/`、`learnings.md`、`context.yaml`、`knowledge-base.md`——直到人工手动修复。

这正是"**知识库会自进化、AGENTS.md 却漂移滞后**"的典型症状：印证了 Step 6 力度弱导致 AGENTS.md 与知识库实际状态不同步。

---

## 7. 局限性 / 注意事项

1. **AGENTS.md 的"自进化"名不副实**：description 标榜"AGENTS.md 自进化"，但 evolve Step 6 的实际指令只有行数守卫；真正丰富的进化对象是知识库（raw → wiki）。AGENTS.md 更新是**条件触发（架构变更）+ 弱指令**，是否落笔高度依赖执行 agent 的自由裁量。
2. **档位 A 存在自动化断点**：`run-track-a.sh` 端到端只覆盖 loop，`exit 0` 后没有脚本自动接力 finish/evolve。
3. **evolve 无独立触发脚本**：`scripts/` 下无 evolve 相关脚本（仅 dispatch/parse-status/task-state/run-track-a/smoke-*），evolve 完全靠控制器按流程图调用 Skill，属"编排约定"而非"脚本强制"。
4. **finish 不碰 AGENTS.md**：`autopilot-finish/SKILL.md` 全文只做合并/归档/移哨兵，无 AGENTS.md 更新。

---

## 8. 改进建议

若希望 **AGENTS.md 也能在 feature 完成后被可靠地主动更新**，有两条路：

### 方案 1 · 用法层面（零改动）
开发走**档位 B（交互）**，并确保 evolve 真的被调用——这样至少 evolve 会检查 AGENTS.md（行数守卫）+ 知识库进化到位。

### 方案 2 · 增强 plugin（改 evolve skill）
1. 把 `autopilot-evolve/SKILL.md` 的 **Step 6** 从"只看行数"升级为：**识别本轮新增的稳定规则 / 架构变更 → 用精准编辑（SearchReplace）回写 AGENTS.md 的 Critical Rules / Doc Navigation（受回写门禁约束，无源不写）**。
2. 在 `run-track-a.sh` 之后补一个 **evolve 接力**（或独立 `run-evolve.sh`），堵上档位 A 的自动化断点。
3. 同步更新两份 evolve 副本（顶层 `~/.qoder/skills/autopilot-evolve/` 与插件内 `skills/autopilot-evolve/`），保持 IDENTICAL。

---

## 关键证据清单（文件路径 : 引用）

- `skills/autopilot-evolve/SKILL.md`（≡ 顶层 `~/.qoder/skills/autopilot-evolve/SKILL.md`，diff IDENTICAL）
  : "AGENTS.md自进化与知识沉淀…写回项目知识体系" / Step 6 "AGENTS.md 更新（如有架构变更）… `wc -l AGENTS.md` # 超过 150 行则精简" / "回写门禁…无源不写" / "两档…都必须执行 evolve"
- `skills/using-neil-autopilot/SKILL.md`
  : HARD-GATE #5 "知识沉淀（evolve）" / Skill 调用规则 #4 "不得跳过 evolve（强制）" / 流程图 finish → evolve → Done / "控制器（档位 B）…跑完在会话内继续 finish/evolve"
- `scripts/run-track-a.sh`
  : 头注释 "runs the inner loop implement → verify → review → (fix)* → commit" / 结尾 `for n … run_task` + `"ALL TASKS DONE ✅ (Track A complete)"; exit 0`（**无 finish/evolve**）
- `skills/_shared/conventions.md`
  : "run-track-a.sh …逐 Task 跑 implement→verify→review→fix→commit" / "AUTOPILOT_EVOLVE_MODEL … Ultimate"
- `autopilot-init/SKILL.md`（同级 skill）
  : Step 2 "Generate AGENTS.md" / "Maintained by autopilot-evolve" / pre-completion 清单 "AGENTS.md updated if architecture changed" / "AGENTS.md 绝不超过 150 行 / 不覆盖用户已有的 AGENTS.md"
- `autopilot-finish/SKILL.md`（同级 skill）
  : 全文无 AGENTS.md / evolve 更新（只合并/归档/移哨兵）

> 说明：未发现独立的 `autopilot-evolve` 触发脚本；`scripts/` 下仅 dispatch / parse-status / task-state / run-track-a / smoke-* 等，均不含 evolve。
