# Autopilot 共享约定

> 本文件定义所有 autopilot skill 共享的约定，避免各 skill 重复声明。
> 控制器（using-neil-autopilot）在会话开始时读取本文件。

## 执行档位（见 using-neil-autopilot「执行档位」）

**铁律：控制器永不内联写码；loop 的开发一律经 `run-track-a.sh` 托管给 fresh qodercli worker（两档通用）。**

> **此铁律现由运行时硬门禁强制，非仅约定**：`hooks/guard-controller-write.sh`（PreToolUse `deny`，`bypass_permissions` 也拦得住）在 autopilot 运行期（`autopilot/.run-active` 哨兵存在时）拦截控制器对源码的 `Write/Edit`；worker（`dispatch.sh` 置 `AUTOPILOT_ROLE=worker`）与 `.md`/`autopilot/` 产物放行。**注意两个 fail-open 边界**：① 哨兵超过 `AUTOPILOT_RUN_TTL_HOURS`（默认 12h）视为崩溃残留而放行，避免把正常编码锁死；② 无法分类时（如拿不到 file_path）也放行。由 `install.sh` 合并进 `~/.qoder/settings.json` 激活（本插件以 skills 安装、非 Qoder plugin，故 `hooks-qoder.json` 不会被自动加载）。见 `autopilot/changes/harden-controller-write-gate/spec.md`。

- **档位 A · 无人值守**：explore/analyze/plan headless（或 spec-ready），从终端起 `run-track-a.sh` 端到端跑 loop，`progress.md` 落盘为状态源，`autopilot-checkpoint` 把关。
- **档位 B · 交互**：控制器在会话内跑 explore/analyze/plan/finish/evolve（跟用户交互），**loop 同样调 `run-track-a.sh` 托管开发**；阶段级状态用 TodoWrite，Task 级状态由脚本写进 tasks.md。

两档只差"外层阶段是否有人交互"，开发都托管。以下约定除特别标注"（档位 A）"外，两档通用。

## 档位适配表

各执行层 skill **只描述一套步骤**；下表是唯一的档位差异映射。**loop 的开发（执行 Task / CR / 修复）两档都经 `run-track-a.sh` 托管 qodercli，控制器不内联**——差异只在外层阶段与状态源。

| 流程动作 | 档位 A（无人值守） | 档位 B（交互） |
|---------|-----------------|---------------|
| 执行一个 Task（开发） | `run-track-a.sh` 逐 Task spawn fresh qodercli worker | 同 A：控制器调 `run-track-a.sh` 托管（不内联写码） |
| CR / 修复 | `run-track-a.sh` 内 spawn reviewer / fixer worker | 同 A（由 `run-track-a.sh` 托管） |
| Task 列表来源 | `$CHANGE_DIR/tasks.md`（脚本输入，必产） | `$CHANGE_DIR/tasks.md`（同；小 spec 可 1 Task） |
| Task 状态记录 | `run-track-a.sh` 写 tasks.md 的 `Status:` | 同（脚本维护 tasks.md） |
| 外层阶段(explore/analyze/plan/finish/evolve) | headless / spec-ready | 控制器在会话内跟用户交互 |
| 阶段完成标记 | `autopilot-checkpoint` 写 `progress.md` | 自查前置不变量 + TodoWrite 标 COMPLETE |
| 恢复 / 断点续跑 | 读 `progress.md` + `run-track-a.sh --resume` | 读 TodoWrite + `run-track-a.sh --resume` |

> **开发一律托管**：控制器（无论档位）不读源文件、不写代码、不看 diff——开发细节全在 worker 的独立 context，控制器 context 不随开发膨胀。两档的阶段顺序与不变量完全一致（explore/CR/verify/evolve），差异只在"外层阶段是否交互"。

## 路径约定

| 变量 | 含义 | 示例 |
|------|------|------|
| $CHANGE_DIR | 当前变更目录 | autopilot/changes/video-distributor |
| $KNOWLEDGE_DIR | 知识库目录 | autopilot/knowledge |
| $HOOKS_DIR | 质量门禁目录 | autopilot/hooks |
| $ARCHIVE_DIR | 归档目录 | autopilot/archive（叶子按 `YYYY/MM/MM-DD/` 三层组织，根目录不变） |

## 分支纪律（两档通用）

**每次变动先开功能分支，禁止在 `main`/`master` 直接实现**（HARD-GATE #2）。

> **作用域**：分支切在**被开发项目的仓库**里（autopilot 运行时 CWD = 业务项目根），与 plugin 仓库无关——**任何引用方每次跑 autopilot 都在自己项目里得到功能分支**。

控制器在 init / 实现前执行：

```bash
# 当前在主干则切功能分支（主干名自适应见 autopilot-finish，不写死 main/master）
CUR="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
case "$CUR" in
  main|master) git checkout -b "<type>/<feature-name>" ;;  # type ∈ feature|fix|refactor
  *) : ;;                                                   # 已在功能分支
esac
```

- 命名：`feature/<name>`（新功能）、`fix/<name>`（bugfix）、`refactor/<name>`（重构）；`<name>` 与 `$CHANGE_DIR` 同名。
- 合并策略见 `autopilot-finish`（PR 或 FF 合并回主干）。
- 例外：仅当用户显式要求“在当前分支直接改”时跳过（需显式声明）。

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

## dispatch.sh 路径解析（单一事实源）

`scripts/dispatch.sh` 只随 plugin 安装（如 `~/.qoder/skills/neil-coding-autopilot/scripts/`），**不在被开发的业务项目里**。控制器在业务项目 CWD 下**禁止用相对路径** `scripts/dispatch.sh`（会解析到业务项目、不存在）。任何档位 A 调度前，先按下列顺序解析出绝对路径 `$DISPATCH`，第一个 `test -f` 通过者即用：

1. **`$AGENT_DISPATCH`**（显式覆盖，CI / 非标准安装）：已设且文件存在 → 用它。
2. **由注入的 skill base 目录推导**（主路径，与安装位置无关）：harness 每次调用 skill 会注入 `Base directory for this skill: <ABS>/skills/<name>`；去掉尾部 `/skills/<name>` 得 plugin 根，拼 `<root>/scripts/dispatch.sh`。
3. **已知安装位置探测**（兜底）：`$HOME/.qoder/skills/neil-coding-autopilot/scripts/dispatch.sh`。
4. **都不存在 → fail-closed**：明确报 "Track A 不可用（定位不到 dispatch.sh）：改用档位 B 或设 $AGENT_DISPATCH"，**绝不静默降级成"假装在跑 A"**。

控制器执行的解析函数（把 `SKILL_BASE_DIR` 用 harness 注入的绝对 base 目录替换）：

```bash
export SKILL_BASE_DIR="<注入的 Base directory for this skill 绝对路径>"
resolve_dispatch() {
  [ -n "${AGENT_DISPATCH:-}" ] && [ -f "${AGENT_DISPATCH}" ] && { printf '%s\n' "${AGENT_DISPATCH}"; return 0; }
  local base="${SKILL_BASE_DIR:-}" root="${SKILL_BASE_DIR:-}"; root="${root%/skills/*}"
  [ -n "${base}" ] && [ -f "${root}/scripts/dispatch.sh" ] && { printf '%s\n' "${root}/scripts/dispatch.sh"; return 0; }
  local cand="${HOME}/.qoder/skills/neil-coding-autopilot/scripts/dispatch.sh"
  [ -f "${cand}" ] && { printf '%s\n' "${cand}"; return 0; }
  echo "ERROR: Track A dispatch.sh not found — use Track B or set \$AGENT_DISPATCH" >&2; return 1
}
DISPATCH="$(resolve_dispatch)" || exit 1
```

> 跨 OS：Track A 依赖 bash——mac/Linux 开箱可用；**Windows 需 WSL 或 Git Bash**。探不到 bash/qodercli 的环境只能跑档位 B（autopilot-init 会自检并告知）。
> 全文出现的 `scripts/dispatch.sh` 均代指解析后的 `$DISPATCH` 绝对路径。

## Track A 一键启动器（run-track-a.sh）

`scripts/run-track-a.sh` 是基于以上原语（dispatch.sh + parse-status.sh + task-state.sh）的**确定性 bash 编排器**：读 `tasks.md`，逐 Task 跑 implement→verify→review→fix→commit（fail-closed，退出码 0=全 DONE / 1=用法错 / 2=BLOCKED / 130=中断）。**它是两档 loop 开发的托管入口**——档位 A 从终端起、档位 B 由控制器在会话内 `bash run-track-a.sh ...` 起；编排器是脚本（零 context、可续跑、可 dry-run），worker 是每步 fresh qodercli。不要"起一个 qodercli 当编排器让它自己循环"（把 context-rot 搬到编排器、非确定、难调试；调研依据见 `autopilot/knowledge/wiki/guides/track-a-launcher-pattern.md`）。用法/前置见 `using-neil-autopilot`「执行档位」。

`scripts/run-autopilot.sh` 在 `run-track-a.sh` 之上再加一层：链式跑完 loop（`run-track-a.sh`）→ finish → evolve 三阶段（同样 fail-closed，任一阶段 BLOCKED 即停、不接力下一阶段），是档位 A 的端到端入口；`run-track-a.sh` 本身仍只负责 loop，不受影响。

## qodercli Worker 调度模板

> `run-track-a.sh` 内部逐 Task 按此模板 spawn worker（两档通用）；此处记录调度契约供理解与排障。**控制器不手拼裸命令、不内联写码，一律经 `run-track-a.sh` 托管。**

独立进程通过以下模式调度（控制器负责填充 prompt 并执行）：

```bash
# 1. 控制器生成 prompt 文件（填充模板变量）
cat > /tmp/autopilot-{stage}-{task}.md << 'EOF'
[填充后的 prompt 内容]
EOF

# 2. 调度 worker（先解析 $DISPATCH，见上「dispatch.sh 路径解析」；模型默认见下表）
"$DISPATCH" --model "$AUTOPILOT_IMPLEMENTER_MODEL" --cwd "$PROJECT_ROOT" \
  --prompt-file /tmp/autopilot-{stage}-{task}.md \
  --instruction "执行该任务并在末尾输出 {STAGE}_STATUS 行" 2>&1 | tail -20
# 等价裸命令（dispatch.sh 的 qoder 分支内部就是这条，flag 均经 qodercli --help 核实）：
#   qodercli -m "$MODEL" -w "$CWD" --permission-mode bypass_permissions \
#     --attachment "$PROMPT_FILE" -p "$INSTRUCTION" -o text

# 3. 控制器解析结果中的 Status 行
```

> 注（以 `qodercli --help` 为准）：qodercli **支持** `-m/--model`、`-w/--cwd`、`--attachment`、`-o/--output-format`、`--context-window`、`-c/-r/--fork-session`（会话续跑）、`--worktree` 等；**不支持** `--max-turns`。**统一经解析出的 `$DISPATCH` 调度**（见「dispatch.sh 路径解析」；已封装 qoder/claude/codex 差异 + 可移植 timeout 兜底），不要手拼裸命令、也不要用相对 `scripts/dispatch.sh`（业务项目里不存在）。

**模型配置**（各角色默认值；经 `dispatch.sh --model` 传入，内部映射到 qodercli `-m`）：

| 环境变量 | 角色 | 默认值 |
|---------|------|--------|
| AUTOPILOT_IMPLEMENTER_MODEL | 编码型 worker | Performance |
| AUTOPILOT_REVIEWER_MODEL | 审查型 worker | Ultimate |
| AUTOPILOT_FIXER_MODEL | 修复型 worker | 跟随 IMPLEMENTER（未设时） |
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
