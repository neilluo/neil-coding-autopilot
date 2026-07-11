# Autopilot 共享约定

> 本文件定义所有 autopilot skill 共享的约定，避免各 skill 重复声明。
> 控制器（using-neil-autopilot）在会话开始时读取本文件。

## 执行档位（见 using-neil-autopilot「执行档位」）

- **档位 A · 批处理**：控制器 spawn 独立 qodercli 进程逐阶段执行，`progress.md` 落盘为状态源，`autopilot-checkpoint` 把关。
- **档位 B · 交互**：控制器在会话内直接执行，**TodoWrite 为单一状态源**，checkpoint 以自查不变量替代，可不写 tasks.md、不 spawn worker。

以下约定除特别标注"（档位 A）"外，两档通用。

## 档位适配表

各执行层 skill **只描述一套步骤**；下表是唯一的档位差异映射（动作 → 档位 A 机制 / 档位 B 机制）。skill 内不再复制两套逻辑，遇到档位相关动作时**按本表执行**。

| 流程动作 | 档位 A（批处理） | 档位 B（交互） |
|---------|-----------------|---------------|
| 执行一个 Task | spawn 独立 qodercli worker（context 隔离） | 控制器在当前会话内直接实现 |
| Task 列表来源 | `$CHANGE_DIR/tasks.md`（落盘） | TodoWrite（可不写 tasks.md） |
| Task 状态记录 | 更新 tasks.md 的 `Status:` | 更新 TodoWrite 状态 |
| 阶段完成标记 | `autopilot-checkpoint` 写 `progress.md` | 自查前置不变量 + TodoWrite 标 COMPLETE |
| CR 调度 | spawn reviewer worker | 控制器直接审（OCR 或内联审查） |
| 修复 | spawn fixer worker | 控制器直接改 |
| 恢复 / 断点续跑 | 读 `progress.md` | 读 TodoWrite 状态 |

> 状态源之所以分档：档位 A 的 worker 每次 fresh context、需外部记忆（tasks.md/progress.md）跨进程存活；档位 B 单一连续 context，TodoWrite 即足。**两档的阶段顺序与不变量完全一致**（explore/CR/verify/evolve），差异只在上表机制列。

## 路径约定

| 变量 | 含义 | 示例 |
|------|------|------|
| $CHANGE_DIR | 当前变更目录 | autopilot/changes/video-distributor |
| $KNOWLEDGE_DIR | 知识库目录 | autopilot/knowledge |
| $HOOKS_DIR | 质量门禁目录 | autopilot/hooks |
| $ARCHIVE_DIR | 归档目录 | autopilot/archive |

## 工作流路由

**控制器全权负责阶段路由**。各 skill 只需完成自身任务并报告状态，不负责调度下一阶段。

流程顺序（由控制器按 `using-neil-autopilot` 流程图执行）：
```
init → explore → analyze → plan → loop → finish → evolve
```

- **档位 A**：每阶段完成后，控制器调用 `autopilot-checkpoint` 标记 `progress.md`，再调度下一阶段。
- **档位 B**：控制器用 TodoWrite 推进阶段状态，checkpoint 退化为"自查前置不变量"，不强制调 checkpoint-skill。

## 前置验证

- **档位 A**：控制器在调度每个阶段前，已通过 `autopilot-checkpoint` 完成前置验证；各 skill 无需重复验证 progress.md。若 skill 被绕过 checkpoint 直接调用（异常情况），应检查 `$CHANGE_DIR/progress.md` 是否存在，不存在则报错退出。
- **档位 B**：控制器进入每阶段前自查前置不变量（上一阶段产物是否就绪），无需 progress.md。

## qodercli Worker 调度模板（档位 A）

> 仅档位 A 使用。档位 B 由控制器在会话内直接实现，不 spawn worker。

独立进程通过以下模式调度（控制器负责填充 prompt 并执行）：

```bash
# 1. 控制器生成 prompt 文件（填充模板变量）
cat > /tmp/autopilot-{stage}-{task}.md << 'EOF'
[填充后的 prompt 内容]
EOF

# 2. 调度 worker（推荐经 dispatch.sh；模型默认见下表）
scripts/dispatch.sh --model "$AUTOPILOT_IMPLEMENTER_MODEL" --cwd "$PROJECT_ROOT" \
  --prompt-file /tmp/autopilot-{stage}-{task}.md \
  --instruction "执行该任务并在末尾输出 {STAGE}_STATUS 行" 2>&1 | tail -20
# 等价裸命令（dispatch.sh 的 qoder 分支内部就是这条，flag 均经 qodercli --help 核实）：
#   qodercli -m "$MODEL" -w "$CWD" --permission-mode bypass_permissions \
#     --attachment "$PROMPT_FILE" -p "$INSTRUCTION" -o text

# 3. 控制器解析结果中的 Status 行
```

> 注（以 `qodercli --help` 为准）：qodercli **支持** `-m/--model`、`-w/--cwd`、`--attachment`、`-o/--output-format`、`--context-window`、`-c/-r/--fork-session`（会话续跑）、`--worktree` 等；**不支持** `--max-turns`。**统一经 `scripts/dispatch.sh` 调度**（已封装 qoder/claude/codex 差异 + 可移植 timeout 兜底），不要手拼裸命令。

**模型配置**（各角色默认值；经 `dispatch.sh --model` 传入，内部映射到 qodercli `-m`）：

| 环境变量 | 角色 | 默认值 |
|---------|------|--------|
| AUTOPILOT_IMPLEMENTER_MODEL | 编码型 worker | Performance |
| AUTOPILOT_REVIEWER_MODEL | 审查型 worker | Ultimate |
| AUTOPILOT_FIXER_MODEL | 修复型 worker | Performance |
| AUTOPILOT_ANALYZE_MODEL | 需求分析 | Ultimate |
| AUTOPILOT_PLAN_MODEL | Task 拆解 | Ultimate |
| AUTOPILOT_INIT_MODEL | 初始化 | Performance |
| AUTOPILOT_EVOLVE_MODEL | 知识沉淀 | Ultimate |

## 状态报告约定

每个 skill/worker 完成后必须在输出中包含状态行：

```
{STAGE}_STATUS=DONE | BLOCKED|{原因} | SKIPPED
```

控制器根据状态决定后续行为：
- `DONE` → （档位 A）调 checkpoint + 下一阶段；（档位 B）TodoWrite 标记完成 + 下一阶段
- `BLOCKED` → 停止流程，通知用户
- `SKIPPED` → 标记 skipped + 下一阶段

## REVIEW_STATUS 约定（三态，fail-closed）

`autopilot-review` 的产出统一为三态，`autopilot-loop` 与 `autopilot-finish` 都必须消费：

| 状态 | 含义 | 下游行为 |
|------|------|---------|
| `PASS` | 全部目标文件已审，无 Critical/Major | 允许 commit / 进入 finish |
| `FAIL` | 有 Critical/Major 问题 | loop 调 fixer（≤3 轮）；仍未过 → BLOCKED |
| `INCOMPLETE` | 有文件未被审查（超时/跳过），重试一次仍未消解 | **fail-closed**：不得 commit、不得进入 finish；上报控制器（人工审 / 缩小 diff / 显式豁免） |

> 核心原则：**未经审查的变更不能静默通过**（fail-closed）。绝不「未审=通过」，也不在 CR 未过时 force-commit。

## base 分支自适应

凡涉及「相对主干」或「合并回主干」的操作，不写死 `main`/`master`，用以下探测（供 `autopilot-review`、`autopilot-finish` 复用）：

```bash
BASE=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')
[ -z "$BASE" ] && BASE=$(git rev-parse --verify --quiet main >/dev/null && echo main || echo master)
```
