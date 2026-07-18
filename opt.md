# Autopilot 约束机制优化：从"md 软约束"到"运行时硬门禁"（2026-07-12）

> 复盘触发：`071203_opt.md` 自查发现，控制器全程内联写码，直接违反"控制器永不内联写码"铁律。
> 根本疑问（用户提出）：plugin 里全是用 md 约束 LLM，会产生很多问题，有没有更可靠的方案？
> 本文结论均基于**本地源码 + Qoder 官方文档（cli/hooks、cli/permissions）+ neil-qoder-kb 知识库**逐条核验，非推测。

## 结论先行

- **报告里那条 ❌ 不是"LLM 不听话"，是架构没设物理边界。** 铁律写在 md 里重复了 N 遍，但运行时没有任何一行代码能阻止 `Write`/`SearchReplace` 被调用。
- **用户的直觉正确：靠 md 约束关键不变量结构性不可靠**（Context Rot + LLM 漂移，见第二节）。
- **最优解不是"往 md 里写更多规则"，而是把不能容忍被违反的不变量下沉到 LLM 够不到的代码。** Qoder 原生就支持（PreToolUse 钩子的 `deny` 连 `bypass_permissions` 都拦得住）。
- **给个人长期工具的拍板建议：只做"最小硬门禁"**（一个 PreToolUse 钩子），不做大重构。理由见第五节。

---

## 一、根因：报告暴露的真问题

当前 plugin 约束几乎全是"软约束"（只写在 md，靠 LLM 自觉）。唯一真正"硬"的地方在 `scripts/run-track-a.sh` 内部（fail-closed 退出码、REVIEW_STATUS 三态、task-state 原子写）——**但"进不进这台确定性机器"本身是控制器的一个软决定**。控制器只要选择不调它、自己上手写，没有任何东西拦得住。

- `hooks/hooks-qoder.json` 只配了 `UserPromptSubmit`（注入 context），**连一个 `PreToolUse` 拦截都没有**。
- `autopilot-checkpoint` 不是真门禁：它只"读 progress.md / 自查 TodoWrite"，是 LLM 自己检查自己；档位 B 甚至退化成纯自觉。
- `run-track-a.sh` 缺失时系统是 fail-loud（明确报错），但**这只保证"脚本调度不静默失败"，不能阻止控制器绕过它内联写码**。

## 二、为什么"堆 md 约束 LLM"结构性不可靠

| 论据 | 出处 | 结论 |
|------|------|------|
| Context Rot | Chroma 研究 (trychroma.com/research/context-rot) | 输入越长，模型遵守度越不稳定——即使简单任务。md 越长，靠前的铁律越容易被稀释遗忘 |
| Workflow vs Agent | Anthropic《Building Effective Agents》 | 关键不变量应放进**预定义代码路径**（workflow），代码路径提供可预测性，prompt 不能 |
| 权限 vs 提示词 | Qoder 官方 permissions 文档 | 原文：Permission rules are enforced by Qoder, **not by the model**. Instructions in your prompt or AGENTS.md shape what it *tries* to do, but don't change what's *allowed* |
| 结构 vs 指令 | claude-code consensus-loop 案例 | behavioral constraints enforced by **structure** are more reliable than constraints enforced by **instruction**；你 build 一个 gate 让它"structurally impossible to proceed" |

**记忆点：把 LLM 当成不可信、会漂移的"填空器"，而不是会守规矩的"执行者"。凡是不能容忍被违反的规则，都必须由它够不到的代码来强制。**

## 三、当前 plugin 约束全景（软/硬审计）

| 铁律 | 现状 | 类型 |
|------|------|------|
| 控制器 loop 阶段永不写源码 | 仅 md（conventions/AGENTS/using 反复声明） | ❌ 软 |
| 必须过 CR 才能 commit/finish | run-track-a.sh 内硬；控制器不调则可绕 | ⚠️ 半硬 |
| 不许跳阶段 | checkpoint 读状态文件，自查 | ❌ 软 |
| verify 必须跑通 | run-track-a.sh 控制器自执，难伪造 | ✅ 硬（脚本内） |
| tasks.md 由脚本维护 | task-state.sh 原子写 | ✅ 硬 |
| 分支纪律 | git 层检查，但仅脚本内执行 | ⚠️ 半硬 |
| 知识沉淀 evolve | 仅 md | ❌ 软 |

## 四、Qoder 原生硬约束能力（已核验）

1. **PreToolUse 钩子**（官方 cli/hooks + KB [[cli-hook-system]]）：30 事件、`command` 型确定性 shell（不经过 LLM）、退出码 2 或 `permissionDecision:"deny"` 可阻断、`matcher:"Write|Edit"`、`if:"Bash(git *)"` 参数级 glob、`${QODER_PLUGIN_ROOT}` 占位符。
   - **关键（官方原文）**：Hook permission decisions have higher priority than permission modes — **even in `bypass_permissions` mode, a PreToolUse hook returning `deny` will still block execution**（unbypassable）。即便 dispatch.sh 用 `--permission-mode bypass_permissions` 跑，钩子照样拦得住。
2. **权限/工具裁剪**（cli/permissions + KB [[cli-permission-model]]）：`permissions.deny`（优先级最高，裸工具名会把工具从上下文移除）、`qodercli --tools 'Read,Grep'`（未列出即拒）、8 层配置合并、protected paths 默认覆盖 `.git`/多数 `.qoder` 配置。
3. **Subagent 工具白名单**（KB [[cli-subagent]]）：frontmatter `tools:{disallowed:[Write,Bash]}` + 独立 `permission_mode` + 独立 model，插件可自带 `agents/`。内置 `Explore`/`Plan` 即只读。
4. **原生 Workflow Engine**（KB [[cli-workflow-engine]]）：JS 脚本编排多 Agent，**脚本本身不能碰 shell/文件系统/网络，所有副作用只能通过子 Agent 发生**——是 bash `run-track-a.sh` 的 Qoder 原生版，"编排器碰不到代码"由引擎强制。

## 五、建议：只做"最小硬门禁"，不做重构

用户两个决定性约束：**① 长期用 → 要低维护、耐久；② 不一定要做好 → 别过度工程。** 据此拍板：

> 加一个 plugin 自带的 `PreToolUse` 钩子，把"控制器在会话里内联写源码"变成物理上做不到；worker 进程照常写码。其余铁律暂时继续留在 md。

**为什么不选另两个方向：**
- **结构性重构（迁到 Workflow Engine）**：虽 KB 证明可行且优雅，但要把整套 bash 编排推倒重来，迁移风险高、需长期跟引擎版本演进——违背"不过度做"。留作演进路径，不是现在。
- **分层硬化（CR 门禁 + 跳步门禁 + 受保护路径全上）**：每加一道门禁都是一份要长期维护的脚本 + 状态约定，收益递减。对个人长期工具，一道"地板"足够。

**为什么"最小硬门禁"最划算：** 只改 **3 处 + 1 个 ~30 行脚本**，一次性投入、几乎零维护，直击唯一硬违规。md 从"唯一防线"退化成"解释说明"——正好回应"md 约束不住 LLM"的根本担忧。

---

## 六、最小方案实施 Plan

### 目标与非目标

- **目标**：把"控制器内联写源码"变成运行时物理拦截（依据第四节 §1 的 unbypassable 特性）。
- **非目标（本次不做）**：不迁 Workflow Engine；不加跳步/CR-commit 门禁；不改 reviewer 为只读 subagent。留作可选增量。

### 改动 1：新增确定性钩子脚本 `hooks/guard-controller-write.sh`

bash、读 stdin JSON、default-deny，逻辑：

1. 取 `tool_input.file_path`（Write/Edit 均有）。
2. **worker 放行**：环境变量 `AUTOPILOT_ROLE=worker` 存在 → `exit 0`。
3. **控制器白名单放行**（命中任一 → `exit 0`）：
   - 路径含 `/autopilot/`（spec/tasks/progress/explore-notes/knowledge）
   - 以 `.md` 结尾（含 `/tmp/autopilot-*.md` prompt 文件）
   - 路径含 `/.qoder/` 或 basename 为 `AGENTS.md`（init 产物）
   - 路径以 `/tmp/` 或 `$TMPDIR` 开头
4. **其余（=源码）→ 阻断**：输出 `hookSpecificOutput.permissionDecision=deny` + reason，`exit 2`。reason：`控制器禁止内联写源码——开发一律经 run-track-a.sh 托管 qodercli。若确需控制器直写，请显式设 AUTOPILOT_ROLE=worker 或临时移除本 hook。`
5. 解析优先 `jq`，缺失降级 `sed`/`grep`（保持 macOS 可用）。用 `${QODER_PLUGIN_ROOT}` 占位符使其随安装即生效。

### 改动 2：挂载钩子到 `hooks/hooks-qoder.json`

在现有 `UserPromptSubmit` 外新增 `PreToolUse` 分组：`matcher:"Write|Edit"`，`type:"command"`，`command:"${QODER_PLUGIN_ROOT}/hooks/guard-controller-write.sh"`。保留原 session-start 注入不动。

### 改动 3：`scripts/dispatch.sh` 注入 worker 角色标记

在三个平台分支（qoder/claude/codex）的 `run_with_timeout` 调用前 `export AUTOPILOT_ROLE=worker`，使 spawn 出的 worker 及其钩子子进程识别为 worker；控制器交互会话不设此变量，天然被识别为控制器。

### 改动 4：文档对齐（md 降级为解释）

- `skills/_shared/conventions.md`「执行档位」铁律段：补一句"本铁律现由 `hooks/guard-controller-write.sh`（PreToolUse）运行时强制，非仅约定"。
- `AGENTS.md`：记一行硬门禁存在 + `AUTOPILOT_ROLE` 语义。
- 不改各阶段 SKILL.md 现有流程描述。

### 测试计划（免 token，先验证再依赖）

新增 `scripts/smoke-guard.sh`（仿 `smoke-dispatch.sh` 风格），对 `guard-controller-write.sh` 喂构造 stdin 断言退出码：

1. 控制器写源码（`/proj/src/App.java`，无 `AUTOPILOT_ROLE`）→ exit 2 + deny。
2. 控制器写 `autopilot/changes/x/spec.md` → exit 0。
3. 控制器写任意 `.md` / `/tmp/autopilot-*.md` → exit 0。
4. worker 写源码（`AUTOPILOT_ROLE=worker`）→ exit 0。
5. `jq` 缺失的降级解析覆盖一条。

**关键人工验证（脚本测不了）**：真实 qodercli 里确认"钩子子进程能继承 worker qodercli 的 `AUTOPILOT_ROLE`"。若继承不成立，改用备用判别（dispatch.sh 落 worker marker 文件，钩子按 marker 判断）。**此点未验证通过前不合并。**

将 `smoke-guard.sh` 接入 `install.sh` 安装后自检（非阻塞，与 smoke-dispatch 并列）。

### 假设与风险

- **假设**：钩子子进程继承父 qodercli 环境变量（用上面的人工验证兜底）。
- **已知残余（本次不处理，仅文档标注）**：① `Bash` heredoc/重定向写文件（`cat > x.py`）可绕过 Write/Edit 钩子——需要时再加 `Bash` matcher 门禁；② 跳步、CR-before-commit 等继续留 md 软约束。
- **回滚**：删除 hooks-qoder.json 的 PreToolUse 分组即完全回退；改动可逆、隔离，不影响 worker 与既有 run-track-a.sh。

## 七、后续可选演进（非本次）

- 想彻底去掉 bash 编排的 context-rot 风险：评估迁移到 Qoder 原生 **Workflow Engine**（JS 编排、脚本不能碰文件系统、副作用只走 subagent）—— KB [[cli-workflow-engine]]。
- 想让 CR 不可伪造：把 reviewer 做成 `tools.disallowed:[Write,Edit,Bash]` 的只读 subagent —— KB [[cli-subagent]]。

## 附：调研关键出处

- Qoder 官方：docs.qoder.com/en/cli/hooks、docs.qoder.com/en/cli/permissions
- neil-qoder-kb：[[cli-hook-system]]、[[cli-permission-model]]、[[cli-subagent]]、[[cli-workflow-engine]]
- Anthropic《Building Effective Agents》；Chroma《Context Rot》；claude-code consensus-loop（issue #34535）、RFC #45427；LangGraph Workflows；NVIDIA NeMo Guardrails；OpenAI Agents SDK
