---
name: using-neil-autopilot
description: "AI全托管开发编排器入口。当用户提到autopilot、全自动开发、从需求到部署、开发spec.md、跑autopilot时触发。"
---

# Neil Coding Autopilot

AI 全托管开发编排器。从需求到部署的全自动开发流水线。

<HARD-GATE>
当用户要求开发一个功能或执行 spec 时，必须满足以下**不变量**（无论用哪种执行档位）：
1. 需求澄清（explore）：动手前确认边界与设计方向，不臆测。
2. 分支纪律：**每次变动先开功能分支**（`<type>/<feature-name>`，type ∈ feature/fix/refactor）；实现前自检当前分支，若在 `main`/`master` 上必须先切分支——**禁止在主干直接改**。
3. Code Review：改动完成后必须经过 CR（autopilot-review），未审不得进入 finish。
4. 验证：合并 / 部署前跑通验证命令（编译 / 测试 / 自检）。
5. 知识沉淀（evolve）：把 CR 发现的规律与踩坑写回知识库。
6. 状态可追溯：进度写入 `progress.md`（档位 A），或以 TodoWrite 为单一状态源（档位 B）——不靠记忆。
7. 可观测验收：user-facing 改动（改变 UI/CLI/API/告警/报表等终端可观测输出）必带「可观测验收」——每个可观测值/态给出 SSOT + 不变量 + 蜕变关系（多源值含判别样例），其确定性扰动测试即该 Task 的 `**Verify**`；不可离线验证者须 `UNVERIFIED-OBSERVABLE` 醒目登记转 Phase 2、禁静默放行；结构缺失（无验收段且无可证伪免除）→ `BLOCKED|{原因}` 立即 exit、禁挂起。详见 `_shared/observable-acceptance.md`（headless 运行期拦截限可离线派生层；纯渲染/错 SSOT 交 Phase 2）。

**HARD-GATE 约束的是"必须发生什么"（不变量），不是"用哪种机制"（见「执行档位」）。**
</HARD-GATE>

## 触发条件

以下任一条件满足即触发 autopilot 流程：
- 用户说"跑 autopilot""全自动""从需求到部署""AI 全托管"
- 用户说"开发 spec.md""按照 spec 开发""实现 spec"
- GitHub Issue 标记 `autonomous` label
- 用户提了一个功能需求且期望 AI 端到端完成

## 执行档位（Execution Tracks）

> **铁律：控制器永不内联写码。** 所有开发（implement→verify→review→fix→commit 内循环）**一律经 `scripts/run-track-a.sh` 托管给 fresh qodercli worker**——控制器只写 prompt、收日志摘要 + 状态行，不读源文件、不看 diff。开发细节全部活在 worker 的独立 context 里，控制器 context 不随开发膨胀。

两档**只差"外层阶段是否有人在交互"**，开发都托管、都走同一个 `run-track-a.sh`：

| 档位 | 何时用 | 外层阶段(explore/analyze/plan/finish/evolve) | loop(开发) | 状态源 |
|------|--------|----------------------------------------------|-----------|--------|
| **A · 无人值守 (Autonomous)** | CI / 后台批量 / spec-ready / 需求已明确 | headless（spec-ready 跳过 explore/analyze） | 从终端起 `run-track-a.sh` 端到端跑完 | `progress.md` + `tasks.md`(脚本维护) |
| **B · 交互 (Interactive)** | 会话内协作 / 需求要边聊边澄清 | 控制器在会话内跟用户跑（可随时插话） | 控制器**调 `run-track-a.sh`** 跑 loop（同样托管 qodercli） | TodoWrite(阶段级) + `tasks.md`(Task 级,脚本维护) + `spec.md` |

**判定规则**：
- 需求要跟用户边聊边澄清 / 期望边做边看 → **档位 B**（交互编排 + 托管 loop）。
- 需求已明确 / spec-ready / 无人值守 / CI → **档位 A**（终端起 run-track-a.sh 端到端）。
- 拿不准 → 默认 **B**。
- **无论哪档，loop 的开发都由 `run-track-a.sh` 托管给 qodercli——控制器绝不在会话内内联写码。**

**两档都必须满足 HARD-GATE 的全部不变量。** 档位只决定外层阶段是否交互，不决定是否 explore / CR / verify / evolve，也不决定开发是否托管（**永远托管**）。

### run-track-a.sh —— 开发托管的唯一入口（两档通用）

`scripts/run-track-a.sh` 是**确定性 bash 编排器**：读 `tasks.md`，逐 Task 经 dispatch.sh spawn fresh qodercli worker，跑 implement→verify→review→fix→commit（fail-closed；退出码 0=全 DONE / 2=BLOCKED）。编排器是脚本（零 context、可续跑、可 dry-run），worker 是每步一次性 fresh qodercli。

```bash
# 从业务项目根启动；控制器(档位 B 交互) 或终端(档位 A 无人值守) 都用这一条
RUNNER="$(dirname "$DISPATCH")/run-track-a.sh"   # 与 dispatch.sh 同目录（$DISPATCH 解析见 conventions）
bash "$RUNNER" --change-dir autopilot/changes/<feature> --cwd "$PROJECT_ROOT"
# --dry-run 先看计划(不烧 token)；--resume 断点续跑；--max-rounds N 控 CR 轮数
```

- **控制器（档位 B）**：会话内 `bash run-track-a.sh ...`，只看 driver 日志摘要、不碰开发细节；跑完在会话内继续 finish/evolve。
- 别用"起一个 qodercli 当编排器、让它自己读 SKILL 循环"——那把 context-rot 搬到编排器、非确定、难调试（调研见 `autopilot/knowledge/wiki/guides/track-a-launcher-pattern.md`）。
- **前置**：`run-track-a.sh` 依赖同目录 dispatch.sh / parse-status.sh / task-state.sh；超时依赖 `timeout`/`gtimeout`（macOS 需 `brew install coreutils`，缺失自动降级）。跑前先 `bash scripts/smoke-dispatch.sh` + `bash scripts/smoke-run-track-a.sh` 冒烟自检（不烧 token）。
- **`run-track-a.sh` 仍是纯 loop-only 托管入口**（只跑开发内循环）；`scripts/run-autopilot.sh` 是档位 A 的端到端编排器，链式跑完 loop（`run-track-a.sh`）→ finish → evolve 三阶段（fail-closed，任一阶段 BLOCKED 即停不接力）。跑前可先 `bash scripts/smoke-run-autopilot.sh` 冒烟自检（不烧 token）。

## 任务类型分流

| 类型 | 判断条件 | 流程 |
|------|---------|------|
| new-project | 新项目/无 AGENTS.md | init → explore → analyze → plan → loop → finish → evolve |
| feature | 新功能/用户说"新增" | init(条件) → explore → analyze → plan → loop → finish → evolve |
| bugfix | 用户说"修复/fix/bug" + 已有代码 | init(条件) → explore(轻量) → analyze(轻量) → plan → loop → finish → evolve |
| spec-ready | 用户提供了 spec 或说"按照 spec" | init(条件) → plan → loop → finish → evolve（跳过 explore + analyze） |

bugfix 类型走轻量 analyze（仅生成最小化 spec：bug 范围 + 修复方向 + 验证方法）。
spec-ready 类型将 explore 和 analyze 都标记为 `[x] ... (skipped)`。
init 阶段在项目已有完整 harness 时标记为 `[x] init (skipped)`。





## Skill 调用规则

### 通用
1. 先声明当前**执行档位**（A 无人值守 / B 交互）。
2. 不得跳过 **explore**（需求澄清强制）。
3. 不得跳过 **CR**（未审变更不得进入 finish）。
4. 不得跳过 **evolve**（知识沉淀强制）。
5. **loop 的开发一律经 `run-track-a.sh` 托管 qodercli**——控制器不内联写码。
6. 任何 skill / worker 报告 **BLOCKED** → 停止流程并通知用户。

### 档位 A
- explore/analyze/plan 若已 headless 就绪（或 spec-ready），从终端起 `run-track-a.sh` 端到端跑 loop。
- 每阶段完成后调用 `Skill("autopilot-checkpoint")` 校验前置并标记 `progress.md`。
- 阶段间完成状态以 `progress.md` 为唯一事实源。

### 档位 B
- 控制器在会话内跑 explore/analyze/plan（跟用户交互）+ finish/evolve，**TodoWrite 为阶段级状态源**。
- **loop：控制器 `bash run-track-a.sh ...` 托管开发**（只看日志摘要，不内联写码）；Task 级状态由脚本写进 tasks.md。
- 以"自查前置不变量"替代 checkpoint-skill 调用。
- 仍需在变更目录落盘 `spec.md`（设计留痕）+ `tasks.md`（run-track-a.sh 输入，可小到 1 Task）；`progress.md` 可选。

**路由只由控制器负责**；skill 只报告状态。
见 `_shared/conventions.md`。

## 状态约定（SSOT，fail-closed）

每个 skill/worker 必须输出 `{STAGE}_STATUS=DONE | BLOCKED|{原因} | SKIPPED`：DONE 推进；BLOCKED 立即停止并通知用户；SKIPPED 留痕后推进。REVIEW 三态以 `_shared/conventions.md` 为 SSOT：`PASS`（`REVIEW_PASS`，可 commit/finish）、`FAIL`（`REVIEW_FAIL`，fix 后重审）、`INCOMPLETE`（`REVIEW_INCOMPLETE`，禁 commit/finish）。未经审查绝不静默通过。

## 按需加载

| Reference | 何时读 |
|---|---|
| [workflow-graph.md](references/workflow-graph.md) | 完整 DOT/checkpoint 路由 |
| [directory-layout.md](references/directory-layout.md) | 产物/archive 四层目录 |
| [bootstrap.md](references/bootstrap.md) | 分支、目录、哨兵、progress、兼容迁移 |
| [usage-examples.md](references/usage-examples.md) | 调用示例 |
| [recovery.md](references/recovery.md) | 中断恢复/断点续跑 |

## 路径约定

详见 `_shared/conventions.md`。

| 变量 | 含义 |
|------|------|
| $CHANGE_DIR | 变更目录 |
| $KNOWLEDGE_DIR | 知识库目录 |
| $HOOKS_DIR | 质量门禁目录 |
| $ARCHIVE_DIR | 归档 |
