# Implementation Tasks — self-evolution-hardening

> Verify command: `bash -n scripts/run-track-a.sh`
> Total tasks: 3

## Task 1: 升级 evolve Step 6 为门禁化 AGENTS.md 自动回写

**Files**: `skills/autopilot-evolve/SKILL.md`（增量编辑 Step 6 与 Step 8，其余步骤/frontmatter/约束段一字不动）
**Depends**: none

**Description**:
先读 `skills/autopilot-evolve/SKILL.md` 全文，理解 8 步闭环与 Step 3 的「回写门禁」（无源不写 / `[inferred]` / `[disputed]`）。当前 Step 6「AGENTS.md 更新（如有架构变更）」只有 `wc -l` + 超 150 行精简，无回写路径。把 Step 6 重写为三小步（保持 Markdown 层级与全文中文风格）：
- **Step 6a 识别候选（无源不写）**：仅从本轮"有据可查"来源提取 AGENTS.md 更新候选——① 本轮写入 `raw/` 且已编译进 `wiki/guides` 的规律性稳定规则（≥2 次复现或被 CR 标 Major）；② 本轮新增/删除/改名的模块或知识页（Doc Navigation 修链）；③ 与 AGENTS.md 现有条目直接矛盾的新事实（标 `[disputed]`）。无候选 → 跳 6c。
- **Step 6b 门禁化写回（SearchReplace，幂等）**：每条候选须溯源到具体 `raw/` 文件或本轮真实代码变更（无源不写）；写前先 grep 该规则是否已在 AGENTS.md（幂等，不重复追加）；"新增稳定规则"追加到 Critical Rules / 对应小节末尾，一条一行并附 `(source: raw/{file})`；"Doc Navigation 修链"用 SearchReplace 精准替换失效链接 / 补新页，不重写整段；纯推理标 `[inferred]`、矛盾标 `[disputed]` 并保留原条目；不覆盖用户手写规则。
- **Step 6c 行数守卫（始终执行）**：保留原 `wc -l AGENTS.md` + 超 150 行精简（细节移入 `wiki/entities/`）；若 6b 追加导致超行，优先移旧细节入 wiki 而非放弃新规则。

再更新 Step 8 输出汇总，追加一行 `AGENTS.md: 追加 N 条规则 / 修 M 处链接 / 精简 K 行 / 无变更`。约束：中文；只改 Step 6 与 Step 8；不动其它步骤、约束段、frontmatter；改完自查 SKILL.md 仍结构完整并自己跑一遍验证命令确认通过。

**Verify**: `grep -q 'SearchReplace' skills/autopilot-evolve/SKILL.md && grep -q '无源不写' skills/autopilot-evolve/SKILL.md && grep -q '幂等' skills/autopilot-evolve/SKILL.md && grep -q 'wc -l AGENTS.md' skills/autopilot-evolve/SKILL.md`
**Status**: DONE

---

## Task 2: 新增 scripts/run-autopilot.sh（loop→finish→evolve 编排器，fail-closed）

**Files**: Create `scripts/run-autopilot.sh`
**Depends**: none

**Description**:
先读 `scripts/run-track-a.sh`、`scripts/dispatch.sh`、`scripts/parse-status.sh`，复用其风格（`SCRIPT_DIR` self-locate via `pwd -P`；bash 3.2 / macOS 安全；`set -euo pipefail`；日志入 `$TMPDIR`；`--help` via sed 头注释；`dispatch_worker` 用 tee 捕获 rc 不中断）。新建 `scripts/run-autopilot.sh`——Track A 端到端编排器，串 `run-track-a.sh(loop) → finish → evolve`。
- **参数**：`--change-dir DIR`（必需）、`--cwd DIR`（默认 `$PWD`）；透传 `--tasks/--resume/--max-rounds/--impl-model/--review-model` 给 run-track-a.sh；`--finish-model M`（默认 `$AUTOPILOT_FINISH_MODEL` 或 `Performance`）、`--evolve-model M`（默认 `$AUTOPILOT_EVOLVE_MODEL` 或 `Ultimate`）；`--skip-finish`、`--skip-evolve`、`--dry-run`、`-h/--help`。
- **兄弟脚本**：`SCRIPT_DIR` 下解析 `run-track-a.sh`/`dispatch.sh`/`parse-status.sh`，缺失即 `exit 1`。
- **流程**：① 调 `bash run-track-a.sh` 透传 loop 参数（含 `--dry-run`），捕获退出码 rc；`rc≠0` → 原样 `exit rc`（fail-closed，不进 finish/evolve）。② `--dry-run`：打印 `would: loop → finish → evolve` 后 `exit 0`（loop 段已透传 dry-run，不 spawn finish/evolve）。③ 非 skip-finish：经 dispatch.sh spawn finish worker——prompt 文件含标识串 `autopilot-finish` + 指示 worker 读 `$SCRIPT_DIR/../skills/autopilot-finish/SKILL.md` 针对 `--change-dir`/`--cwd` 执行、末尾输出 `FINISH_STATUS=DONE|BLOCKED`；用 `parse-status.sh` 解析 worker 输出日志，非 DONE → `exit 2`。④ 非 skip-evolve：同法 spawn evolve worker（标识 `autopilot-evolve`，模型 evolve-model，读 `autopilot-evolve/SKILL.md`），非 DONE → `exit 2`。⑤ 成功尾部 `rm -f autopilot/.run-active`（幂等）→ `exit 0`。
- **退出码**：0 全链成功 / 1 用法错 / 2 finish 或 evolve BLOCKED（或 loop 传播的 2）/ 130 中断。约束：不修改 run-track-a.sh；`bash -n` 通过；不引入 GNU-only 工具。

**Verify**: `bash -n scripts/run-autopilot.sh && bash scripts/run-autopilot.sh --help >/dev/null 2>&1`
**Status**: PENDING

---

## Task 3: 新增 smoke-run-autopilot.sh（token-free 回归）+ 文档更新

**Files**: Create `scripts/smoke-run-autopilot.sh`；Edit `AGENTS.md`、`skills/using-neil-autopilot/SKILL.md`、`skills/_shared/conventions.md`
**Depends**: Task 2

**Description**:
先读 `scripts/smoke-run-track-a.sh`，复用其 stub 模式（`mktemp` WORK；PATH 注入 stub `qodercli`；`AUTOPILOT_PLATFORM=qoder`；临时 git 项目 + canonical tasks.md）。新建 `scripts/smoke-run-autopilot.sh`（token-free）：stub `qodercli` 按 attachment 内容分流——含 `代码审查专家`→`REVIEW_PASS`；含 `autopilot-finish`→写标记文件 `$WORK/finish.hit` 并 echo `FINISH_STATUS=DONE`；含 `autopilot-evolve`→写 `$WORK/evolve.hit` 并 echo `EVOLVE_STATUS=DONE`；否则 implementer/fixer→追加文件 + echo `**Status:** DONE`。场景：
- **场景1 HAPPY**：verify=`true`、1 task；跑 `bash run-autopilot.sh --change-dir <chg> --cwd <proj>`；断言 `exit 0`、`finish.hit` 与 `evolve.hit` 均存在。
- **场景2 FAIL-CLOSED**：verify=`false`、1 task、`--max-rounds 1`；断言 `exit 2`、且 `finish.hit`/`evolve.hit` 均**不存在**（loop BLOCKED 后未接力）。
- 全 PASS → echo `SMOKE(run-autopilot): ALL PASS`; `exit 0`；否则 `exit 1`。

文档更新（增量，勿重写整节）：① `AGENTS.md`：在 scripts / 执行模型处补一句 `run-autopilot.sh` = Track A 无人值守端到端入口（loop→finish→evolve），并注明 evolve 现会门禁化回写 AGENTS.md。② `skills/using-neil-autopilot/SKILL.md`：在「执行档位」/「run-track-a.sh」附近补 `run-autopilot.sh` 为档位 A 端到端编排器（run-track-a.sh 仍是 loop-only 托管入口）。③ `skills/_shared/conventions.md`：在「Track A 一键启动器」段补 `run-autopilot.sh` 条目（loop→finish→evolve，fail-closed）。约束：中文；smoke 必须 token-free（不调真实模型）；文档只增量补充、不删除既有内容。

**Verify**: `bash scripts/smoke-run-autopilot.sh && grep -q 'run-autopilot.sh' AGENTS.md`
**Status**: PENDING

---
