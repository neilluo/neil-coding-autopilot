# Explore Notes — archive-knowledge-loop

> 本 explore 通过控制器与用户的多轮会话完成（已澄清模式）。以下沉淀该会话的现状调研、
> 根因结论、方案选择与设计方向确认（满足 HARD-GATE：用户已复述式确认方向）。

## 项目现状摘要

- 技术栈: 纯 Markdown skill 定义集 + Bash 编排脚本（无运行时代码、无编译；验证靠 grep 断言 + token-free 冒烟测试）。
- 形态: Qoder 插件 / AI 全托管开发编排器，双档（A 无人值守 / B 交互）共享同一套阶段。
- 与需求相关的现有代码:
  - `skills/autopilot-finish/SKILL.md` Step 6 — 唯一的归档步骤（现状 `cp` 复制）。
  - `skills/autopilot-evolve/SKILL.md` — 知识三层沉淀（raw→wiki），当前蒸馏源仅 CR/编译失败/task-blocked。
  - `skills/autopilot-explore/SKILL.md` / `autopilot-analyze/SKILL.md` — 开工前读 SCHEMA + wiki/index，但**不检索历史变更**。
  - `scripts/dispatch.sh` — 自定位路径解析范式（`pwd -P`，C8）。
  - `autopilot/knowledge/`（raw→wiki→SCHEMA）— 已在跑的蒸馏反哺链，被 analyze/explore 读。
- 技术约束（来自 SCHEMA.md）: C6 shell 可移植（bash 3.2 / 无 GNU 工具假设）、C7 verify-by-running、C8 自带脚本可移植定位、C10 确定性脚本编排、C11 控制器永不内联写码。

## 根因调研结论（本轮对话已确认）

1. **归档是 `cp` 而非 `mv`，且"清理原件"是空头承诺**：finish Step 6 用 `cp`，注释说"evolve 完成后清理"，但全仓 grep 无任何 `mv/rm changes/`。铁证：`self-evolution-hardening`/`agent-observability`/`telemetry-pluggable-sink` 三个文件夹同时存在于 changes/ 与 archive/。
2. **finish 是唯一归档器且极少跑完**：11 个 changes/ 中仅 3 个进了 archive（正好是跑完正式流程的那 3 个）；其余是 spec-only 草稿 / 手工实验 / 半途。
3. **archive 是"死存档"**：analyze/explore/plan **完全不读 archive**；evolve 也不读。归档在代码层面零功能作用。

## 业界调研（子代理已核实 Google/GitHub/AI-agent）

- 共识: 归档的价值不在存储，在**被后续工作读回去**。Google "Where's the design doc?"；SRE "未复盘的 postmortem 等于没发生过"。
- 关键设计判断: **Agent 不应直接读原始归档，而应读一层从归档蒸馏出的、可检索的知识层**（Claude Code memory / Reflexion / Kiro steering 一致）。
- 真实作用清单: ①上手考古 ②决策溯源避免重议 ③喂未来复盘/发现重复模式 ④"以前解过吗"可搜索知识库 ⑤changelog 原料 ⑥few-shot ⑦跨项目 institutional memory。

## 方案选择

| 方案 | 描述 | 评估 |
|------|------|------|
| A | 完成即蒸馏进 knowledge/（复用现有反哺链） | 采纳 ✓（复利引擎） |
| B | 让 explore 直接 grep 原始 archive 塞进上下文 | 否决（调研明确反对；但用户澄清"无 Context 问题"→改为经确定性检索器 + 蒸馏层，安全落地） |
| C | archive 仅做整理门面 | 否决（零功能作用 = 现状病症） |

**用户关键澄清**（解锁完整方案）:
- "这个 plugin 是未来所有系统的基石" → 归档缺陷会复制到每个项目；跨项目知识联邦是独有红利 → 采纳 ③升。
- "不在乎成本/时间" + "可连续开发" + "不会出现 Context 问题" → 检索历史喂给一次性 worker 是安全的 → 采纳 ④翻（经确定性检索器）。

## 设计方向确认（用户已确认："把这个 spec 落地吧"）

**功能目标**: 让 `changes→archive→knowledge` 主管线真正闭环并可跨项目复利，使归档从"死存档"变成"喂未来开发的活知识"。

**实现方案**: 四件事（①挪 ②嚼 ③升 ④翻），关键机制一律落成**确定性脚本 + token-free 冒烟测试**（遵循 C7/C10），而非不可验证的 prose：
1. **①挪**: 新增 `scripts/archive-change.sh`（`git mv` + 幂等 + summary + fail-closed），finish Step 6 改为调用它并硬门禁化。
2. **②嚼**: evolve 增加"完成变更"蒸馏源（决策溯源 + 可复用模式 → raw→wiki）。
3. **③升**: 新增 `scripts/kb-path.sh` 解析全局 KB 路径（`NEIL_AUTOPILOT_KB_DIR` env → 默认 `$HOME/.neil-autopilot/knowledge`），evolve 把通用经验升迁到全局。
4. **④翻**: 新增 `scripts/kb-search.sh`（grep 检索 本地+全局 KB），explore/analyze 开工前检索历史经验并记入 explore-notes.md。

**技术边界**:
- 涉及模块: skills/{finish,evolve,explore,analyze} + scripts/ + conventions.md + AGENTS.md + SCHEMA.md。
- 数据库变更: 否。API 变更: 否（新增 3 个内部脚本 CLI）。第三方集成: 否。

**核心设计决策**:
1. 关键机制脚本化 + 冒烟测试（可验证 > 可读 prose）。
2. Agent 读"蒸馏知识层 + 确定性检索器输出"，不直接把原始 archive 塞进上下文。
3. 全局 KB 路径解析单一事实源（kb-path.sh），evolve 写 / kb-search 读都经它（C8 纪律）。
4. 归档不变量: 一个完成变更在 archive/ XOR changes/（绝不两处并存 / 绝不两处皆无）。

**不做的事情（scope out）**:
- 不做 embedding / 向量检索（当前规模 grep 足够；留架构余地）。
- 不回溯迁移现有 changes/ 里的历史草稿（本次只修正向管线；历史清理另议）。
- 不自动改 AGENTS.md 以外的用户手写规则。
