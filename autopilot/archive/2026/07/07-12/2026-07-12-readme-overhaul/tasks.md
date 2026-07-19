# Implementation Tasks — readme-overhaul

> Verify command: `test -s README.md && grep -q mermaid README.md && [ $(grep -c '^## ' README.md) -ge 10 ]`
> Total tasks: 1

## Task 1: 完整重写 README.md（非常详细 + 图文并茂）

**Files**: `README.md`（覆盖重写仓库根目录的 README.md）
**Description**: 你要把本仓库根目录的 `README.md` 完整重写为一份**非常详细、图文并茂**的中文文档，准确介绍 neil-coding-autopilot 这个 Qoder 插件。

第一步（保证准确性，必须先读）：完整阅读以下源文件，README 内容必须与它们的当前实现一致，不得臆造：
- `AGENTS.md`（架构总览、平台配置、Skills 清单、调用拓扑、产物管理）
- `skills/_shared/conventions.md`（执行档位、dispatch 路径解析、档位适配表、Track A 启动器）
- `skills/using-neil-autopilot/SKILL.md`（HARD-GATE、执行档位表、任务类型分流、完整流程、Skill 调用规则）
- `scripts/run-track-a.sh` 顶部注释（用法、选项、退出码、可移植性）
- `scripts/dispatch.sh`（worker 调度接口）

第二步：产出新的 README.md，必须包含以下 `##` 级章节（至少 10 个 H2），且**图文并茂**（至少 3 个 mermaid 图 + 多个表格）：
1. 标题 + 一句话价值主张
2. `## 核心理念`：铁律=控制器永不内联写码，所有开发一律经 `scripts/run-track-a.sh` 托管给 fresh qodercli worker；控制器只写 prompt、收日志摘要 + 状态行，不读源文件/不看 diff；context 隔离（Anthropic subagent offload 思想）
3. `## 架构总览`：一个 mermaid `flowchart TD` 画顶层阶段流水线 init(条件)→explore→analyze→plan→loop→finish→evolve，每阶段间有 checkpoint 门禁
4. `## loop 内循环`：一个 mermaid `flowchart` 画单个 Task 的内循环 implement→verify→review→(fix 循环)→commit，并画出 fail-closed 分支（verify 失败/REVIEW_FAIL/commit 失败→BLOCKED 停止）
5. `## 执行档位`：档位 A（无人值守）vs 档位 B（交互）对比表 + 判定规则，强调"只差外层阶段是否有人交互，开发都托管给 qodercli"
6. `## Skills 清单`：表格列出 11 个 skill（using-neil-autopilot / autopilot-init / explore / analyze / plan / loop / review / finish / evolve / checkpoint）及各自职责
7. `## 底层脚本原语`：表格列出 scripts/ 下的 dispatch.sh、parse-status.sh、task-state.sh、run-track-a.sh、smoke-dispatch.sh、smoke-run-track-a.sh 及职责
8. `## 知识库三层架构`：一个 mermaid 图画 Karpathy LLM Wiki 三层 raw（不可变源）→ wiki（LLM 编译产物 index/guides）→ SCHEMA（维护规则+约束）
9. `## 快速开始`：安装（neil-skill-installer 或 install.sh）→ 冒烟自检（bash scripts/smoke-dispatch.sh、bash scripts/smoke-run-track-a.sh，不烧 token）→ dry-run（run-track-a.sh --dry-run）→ 真跑
10. `## 使用示例`：4 种触发（自然语言需求 / 按 spec 开发 / GitHub Issue / bugfix）代码块
11. `## 配置`：环境变量表（AUTOPILOT_PLATFORM、各阶段 MODEL、AUTOPILOT_MAX_PARALLEL 等，取自 AGENTS.md）
12. `## 产物目录结构`：autopilot/ 目录树（changes/archive/knowledge/hooks）代码块
13. `## HARD-GATE 不变量`：列出 6 条不变量（explore/分支纪律/CR/verify/evolve/状态可追溯）
14. `## 跨平台与可移植性`：说明 macOS 上 timeout→gtimeout 降级、flock→mkdir 锁降级、bash 3.2 兼容、pwd -P 自定位；需要 bash（Windows 用 WSL/Git Bash）
15. `## License`：MIT

写作要求：中文；专业清晰；mermaid 图语法正确（GitHub 可渲染）；表格对齐；不要保留旧 README 里的 ASCII 流程图（用 mermaid 取代）；只覆盖 README.md 这一个文件，不改动任何其它文件。

**Verify**: `test -s README.md && grep -q mermaid README.md && [ $(grep -c '^## ' README.md) -ge 10 ]`
**Status**: DONE

---
