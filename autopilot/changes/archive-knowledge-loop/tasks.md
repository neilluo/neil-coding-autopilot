# Tasks — archive-knowledge-loop

> Global Verify: `for f in scripts/*.sh; do bash -n "$f" || exit 1; done`
> Verify command: `for f in scripts/*.sh; do bash -n "$f" || exit 1; done`
> 设计与验收见同目录 `spec.md`（尤其 §4 接口、§8 可观测验收）。所有新脚本须 bash 3.2 安全、`chmod +x`、
> `pwd -P` 自定位、无 GNU 工具硬依赖。每个关键机制脚本必须配套一个 token-free 冒烟测试（C7）。

---

## Task 1: 新增全局 KB 路径解析器 kb-path.sh + 冒烟测试（③升 基础）

**Status**: PENDING

**目标**: 建立"全局跨项目知识库"路径解析的**单一事实源**，供后续 evolve(写) / kb-search(读) 共用。

**要做**:
1. 新增 `scripts/kb-path.sh`（可执行）：
   - 用法 `kb-path.sh [--ensure]`。
   - 解析优先级（遵循 SCHEMA C8）：环境变量 `$NEIL_AUTOPILOT_KB_DIR` 非空则用之；否则默认 `$HOME/.neil-autopilot/knowledge`。
   - stdout **只打印**解析后的绝对路径（不打印多余日志到 stdout；诊断走 stderr）。
   - `--ensure`：若目录不存在则 `mkdir -p "$DIR/raw" "$DIR/wiki"`；成功 exit 0。
   - fail-closed：既无 env 又无 `$HOME` → 打印错误到 stderr、exit 1。禁止写死用户名/家目录字面量。
   - bash 3.2 安全，`set -euo pipefail`，`#!/usr/bin/env bash`。
2. 新增 `scripts/smoke-kb-path.sh`（可执行，token-free，不联网不调 agent）断言：
   - 设 `NEIL_AUTOPILOT_KB_DIR=$TMPDIR/kbp-x` → 输出恰为该路径（判别：仍输出默认=FAIL）。
   - 不设 env → 输出包含 `.neil-autopilot/knowledge`。
   - `--ensure` 后 `raw/` 与 `wiki/` 子目录存在。
   - 全部通过打印 `SMOKE(kb-path): ALL PASS` 并 exit 0；任一失败 exit 1。
   - 用完清理临时目录，不污染真实 `$HOME`。

**Verify**: `bash scripts/smoke-kb-path.sh`

---

## Task 2: 新增确定性归档脚本 archive-change.sh + 冒烟，并接入 finish（①挪）

**Status**: PENDING

**目标**: 修复"归档只 cp 不 mv、原件永不清理"的根因缺陷，落成确定性、幂等、fail-closed 的搬迁脚本，并让 finish 硬门禁化调用它。

**要做**:
1. 新增 `scripts/archive-change.sh`（可执行）：
   - 用法 `archive-change.sh --change-dir DIR [--archive-dir DIR] [--date YYYY-MM-DD]`。
   - `--archive-dir` 默认 `<change-dir 的父级的父级>/archive`（即 `autopilot/archive`，从 change-dir 推导）；`--date` 默认 `date +%Y-%m-%d`。
   - 幂等：若目标 `archive/<DATE>-<name>` 已存在 → 打印其路径、exit 0（不重复搬、不报错）。
   - 搬迁：优先 `git mv`（在 git 仓库内）；非 git 仓库或 git mv 失败降级 `mv`。
   - 若 change-dir 内缺 `summary.md`，搬迁前生成骨架（含 完成日期 / 变更名 / 占位）。
   - fail-closed：`--change-dir` 不存在 → stderr + exit 1；搬迁后源目录仍存在 → stderr + exit 1。
   - **不变量**（注释显式写明）：完成后该变更在 archive **XOR** changes，绝不两处并存。
   - bash 3.2 安全、`pwd -P`、`set -euo pipefail`。
2. 新增 `scripts/smoke-archive-change.sh`（token-free）：在 `$TMPDIR` 造一个临时 git 仓库 + `autopilot/changes/foo`，断言：
   - 搬迁后 `autopilot/archive/<DATE>-foo` 存在 且 `autopilot/changes/foo` 消失（O1 主不变量）。
   - 再跑一次（幂等）→ exit 0、状态不变。
   - `--change-dir` 指向不存在目录 → exit 1（判别：静默成功=FAIL）。
   - 通过打印 `SMOKE(archive-change): ALL PASS`；清理临时目录。
3. 编辑 `skills/autopilot-finish/SKILL.md` Step 6：把原 `cp ...` 归档手法替换为调用 `scripts/archive-change.sh --change-dir "$CHANGE_DIR"`；调用失败或搬迁后 `$CHANGE_DIR` 仍存在 → 置 `FINISH_STATUS=BLOCKED`。保留"生成 summary.md"语义（可由脚本承担）。在该步显式写明 XOR 不变量。注意：脚本自身用相对 `scripts/` 不可靠，SKILL 里用解析出的绝对路径（参考 `_shared/conventions.md` 的 dispatch.sh 路径解析范式）。

**Verify**: `bash scripts/smoke-archive-change.sh`

---

## Task 3: 新增 KB 检索器 kb-search.sh + 冒烟（④翻 基础）

**Status**: PENDING

**目标**: 提供确定性、fail-safe 的"历史经验检索"底座，检索 本地 + 全局 KB，供 explore/analyze 开工调用。依赖 Task 1 的 `scripts/kb-path.sh`。

**要做**:
1. 新增 `scripts/kb-search.sh`（可执行）：
   - 用法 `kb-search.sh --query "kw1 kw2 ..." [--cwd DIR] [--limit N]`（`--cwd` 默认 `$PWD`，N 默认 20）。
   - 本地 KB：`<cwd>/autopilot/knowledge/{raw,wiki}`；全局 KB：调用同目录 `kb-path.sh` 取路径（存在才搜）。
   - 对 query 里每个关键词做大小写不敏感 grep（`grep -rilE`），输出每条命中：`[LOCAL]` 或 `[GLOBAL]` + 相对路径 + 首个匹配行摘要。去重、限量 N。
   - **fail-safe**：无 KB 目录 / 无命中 → 打印 `(no prior-art hits)` 且 **exit 0**（绝不因空而失败）。只读，绝不修改 KB。
   - bash 3.2 安全、`pwd -P`、`set -euo pipefail`（注意 grep 无命中返回 1，不要让它触发 pipefail 退出——需 `|| true` 兜底）。
2. 新增 `scripts/smoke-kb-search.sh`（token-free）：在 `$TMPDIR` 造 假的全局 KB（`NEIL_AUTOPILOT_KB_DIR` 指过去）放一条含 `widget` 的 wiki 文件 + 造本地 `autopilot/knowledge/wiki` 放一条含 `alpha` 的文件，断言：
   - query `widget` → 输出含 `[GLOBAL]` 且含该文件（判别：漏 GLOBAL=FAIL）。
   - query `alpha` → 输出含 `[LOCAL]`。
   - query 无关词 `zzznope` → 输出 `(no prior-art hits)` 且 exit 0（判别：exit≠0=FAIL）。
   - 通过打印 `SMOKE(kb-search): ALL PASS`；清理临时目录。

**Verify**: `bash scripts/smoke-kb-search.sh`

---

## Task 4: explore/analyze 接入历史经验检索（④翻 接线）

**Status**: PENDING

**目标**: 让每次开发开工前检索 本地+全局 历史经验并纳入设计，使归档真正"喂回"未来开发。依赖 Task 3 的 `scripts/kb-search.sh`。

**要做**:
1. 编辑 `skills/autopilot-explore/SKILL.md` Step 1（读代码理解现状）：新增「历史经验检索」子步——用需求关键词调用 `scripts/kb-search.sh --query "<关键词>" --cwd "$PROJECT_ROOT"`（用解析出的绝对路径），把命中结果写入 `$CHANGE_DIR/explore-notes.md` 的新段「## 历史经验命中」；**无命中也必须写该段并注明"无命中"**。在 explore-notes.md 模板里补上该段。
2. 编辑 `skills/autopilot-analyze/SKILL.md` Step 1b（读知识库）：新增一句——除本地 wiki 外，同时读取 explore 记录的「历史经验命中」+（可选）再跑一次 `kb-search.sh` 覆盖全局 KB，将命中的既往决策/坑点作为 Spec 约束纳入（沿用现有优先级：explore 产出 > KB 约束 > 项目配置）。
3. 两处都必须出现字面 `kb-search.sh`（供 Verify 断言接线）。保持各自 SKILL 风格与行数节制。

**Verify**: `grep -q kb-search.sh skills/autopilot-explore/SKILL.md && grep -q kb-search.sh skills/autopilot-analyze/SKILL.md`

---

## Task 5: evolve 增"完成变更"蒸馏源 + 通用经验升迁全局（②嚼 + ③升 消费）

**Status**: PENDING

**目标**: 让归档的**内容**被蒸馏进知识库（本地 + 通用者升全局），这是让归档有真实作用的核心。依赖 Task 1 的 `scripts/kb-path.sh`。

**要做**:
1. 编辑 `skills/autopilot-evolve/SKILL.md` Step 1（收集本轮经验）：新增第 5 类来源「**完成变更**」——读取本轮 `$CHANGE_DIR`（或已归档路径）的 `spec.md/tasks.md/explore-notes.md`，提炼：本次做了什么、关键决策与被否决的替代方案（决策溯源）、可复用的模式/坑点。按现有 raw→wiki 流程写入（frontmatter `source: evolve/completed-change`）。
2. 在 evolve 中新增一步「全局升迁」：对其中**跨项目通用**（非本项目特定）的经验，经 `scripts/kb-path.sh --ensure` 取全局 KB 路径，写一份到全局 `raw/`（同样带 frontmatter 溯源）。沿用现有回写门禁：**无源不写**、`inferred≤30%`、矛盾标 `[disputed]`。项目特定经验只留本地、不升全局。
3. SKILL 中必须出现字面 `kb-path.sh`（供 Verify 断言接线）。遵守 evolve 现有约束（不删已有 wiki、raw append-only）。

**Verify**: `grep -q kb-path.sh skills/autopilot-evolve/SKILL.md`

---

## Task 6: SCHEMA 约束登记 + 全量回归冒烟（收口）

**Status**: PENDING

**目标**: 把本特性建立的两条不变量登记进知识库 SCHEMA，并确保没有破坏任何既有机制。

**要做**:
1. 编辑 `autopilot/knowledge/SCHEMA.md`，在 `Constraints` 段追加两条（保持文件 ≤200 行；超了把旧细节移入 wiki）：
   - **C13 归档毕业不变量**：完成变更经 `scripts/archive-change.sh` 从 `changes/` `git mv` 进 `archive/`，一个变更在 archive **XOR** changes（绝不两处并存/皆无）；finish 硬门禁化，搬迁失败即 BLOCKED。
   - **C14 archive→knowledge 反哺闭环**：归档的内容必须被 evolve 蒸馏进知识库（本地 raw→wiki；跨项目通用者经 `kb-path.sh` 升迁全局 KB）；explore/analyze 开工经 `kb-search.sh` 检索本地+全局命中。Agent 读蒸馏层 + 检索器输出，不直接把原始 archive 塞进上下文。
2. 不改动任何脚本逻辑；仅文档登记。

**Verify**: `grep -q C13 autopilot/knowledge/SCHEMA.md && grep -q C14 autopilot/knowledge/SCHEMA.md && for s in smoke-dispatch smoke-run-track-a smoke-run-autopilot smoke-kb-path smoke-archive-change smoke-kb-search; do bash scripts/$s.sh >/dev/null 2>&1 || exit 1; done`

---
