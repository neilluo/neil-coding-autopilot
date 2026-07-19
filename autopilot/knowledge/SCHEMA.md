# Knowledge SCHEMA — Neil Coding Autopilot

> 三层知识库的维护规则 + 项目元数据。Agent 每次 analyze/plan 前读取本文件与 `wiki/index.md`。
> Karpathy LLM Wiki 架构：`raw/`（不可变源）→ `wiki/`（LLM 编译产物）→ 本 SCHEMA（维护规则）。

## 项目元数据

- 项目：Neil Coding Autopilot（Qoder 插件 / AI 全托管开发编排器）
- 形态：Markdown skill 定义集（无运行时代码；"代码"即 prompt / skill 文档）
- 执行模型：控制器永不内联写码，开发一律经 run-track-a.sh 托管 qodercli；双档（A 无人值守 / B 交互）只差外层阶段是否交互，共享同一套阶段与不变量
- 验证方式：无编译；用 grep 断言（覆盖率 / 闭环 / 残留）替代 CI

## Constraints（强制约束）

- **C1 不按档位 fork 逻辑**：执行层 skill 只保留一套步骤，档位差异集中在 `skills/_shared/conventions.md` 档位适配表（单一事实源）。
- **C2 CR fail-closed**：`REVIEW_STATUS ∈ {PASS, FAIL, INCOMPLETE}`；FAIL / INCOMPLETE 都不得进入 finish；绝不 force-commit 未过审代码。
- **C3 grow-on-demand**：不预建空目录 / 空状态机文件；有内容才建。
- **C4 不写死主干分支名**：用 base 分支自适应探测（master / main）。
- **C5 横切抽象必须全量 rollout**：见 `wiki/guides/cross-cutting-abstraction-rollout.md`。
- **C6 shell 可移植性**：脚本不假设 GNU 工具存在（timeout/gtimeout、flock、sed -i、date、readlink -f 等）+ 不假设 bash≥4（macOS 自带 3.2，无 declare -A/mapfile）；对外部命令 `command -v` 探测 + 优雅降级。见 `wiki/guides/verify-by-running.md`。
- **C7 verify-by-running**：关键机制必须有 token-free 冒烟测试（如 `scripts/smoke-dispatch.sh`）；未跑通 = 未验证。
- **C8 自带脚本可移植定位**：分发型 plugin 的自带脚本用解析出的绝对路径（env → 注入 base → 已知安装位置 → fail-closed），禁止相对 CWD 路径、禁止写死家目录/用户名。见 `wiki/guides/self-contained-script-resolution.md`。
- **C9 分支纪律**：每次变动先开功能分支（`<type>/<name>`），实现前自检当前分支，禁止在 `main`/`master` 直接改。见 `using-neil-autopilot` HARD-GATE #2 与 `_shared/conventions.md`「分支纪律」。
- **C10 自主批处理用确定性脚本编排**：Track A 用确定性 bash 编排器（`scripts/run-track-a.sh`）逐 Task 起 fresh worker，不用 LLM 当编排器（context-rot 搬家/非确定）；fail-closed。见 `wiki/guides/track-a-launcher-pattern.md`。
- **C11 控制器永不内联写码**：两档的开发（implement/CR/fix）一律经 `run-track-a.sh` 托管 fresh qodercli worker；控制器只收摘要 + 状态行，不读源文件/不看 diff。交互档同样托管（"交互=内联"是伪命题）。见 `wiki/guides/delegate-all-development.md`。
- **C12 自主提交需 .gitignore 兜底**：`run-track-a.sh` 的 `git add -A` 是自主提交（无控制器挑文件），依赖仓库有 `.gitignore` 屏蔽 scratch（`.DS_Store`/`*_opt.md`/日志）；否则 dogfooding 会撞出污染提交。见 `wiki/guides/verify-by-running.md`。
- **C13 归档毕业不变量**：完成变更经 `scripts/archive-change.sh` 从 `changes/` `git mv` 进 `archive/YYYY/MM/MM-DD/YYYY-MM-DD-<name>/`（四层：年/月/月-日 + 原扁平名叶子），一个变更在 archive **XOR** changes（绝不两处并存/皆无）；finish 硬门禁化，搬迁失败即 BLOCKED。
- **C14 archive→knowledge 反哺闭环**：归档的内容必须被 evolve 蒸馏进知识库（本地 raw→wiki；跨项目通用者经 `kb-path.sh` 升迁全局 KB）；explore/analyze 开工经 `kb-search.sh` 检索本地+全局命中。Agent 读蒸馏层 + 检索器输出，不直接把原始 archive 塞进上下文。
- **C15 归档布局迁移幂等**：`scripts/migrate-archive-layout.sh` 是一次性、幂等、fail-closed 的历史扁平 `archive/YYYY-MM-DD-<name>/` → 四层 `archive/YYYY/MM/MM-DD/YYYY-MM-DD-<name>/` 迁移脚本；只搬未迁移的扁平目录，已是四层结构的目标存在即跳过，重复运行不产生副作用/不报错。

## Design Principles

- 不变量优先于机制：HARD-GATE 约束"必须发生什么"，档位只决定"怎么做"。
- 单一事实源：状态源（progress.md / TodoWrite）与规则源（conventions 适配表）各自唯一。
- producer→consumer 闭环：任何新增状态 / 契约必须有明确消费者。

## Per-Stage Rules

- **spec**：技术约束来自被开发项目自身（AGENTS / SCHEMA / wiki），不硬编码语言 / 框架。
- **review**：语言无关通用维度 + 项目特定维度；未审文件报 INCOMPLETE。
- **evolve**：先写 raw 再编译 wiki；无源不写；inferred ≤ 30%。

## 维护规则

- 本文件 ≤ 200 行；细节移入 wiki 页。
- `raw/` append-only，不可修改。
- 每 5 次 evolve 后建议 lint（矛盾 / 过时 / 孤立页 / 断链）。
