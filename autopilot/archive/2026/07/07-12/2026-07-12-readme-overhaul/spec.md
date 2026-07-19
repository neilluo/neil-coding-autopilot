# Spec — README.md 完整重写（图文并茂）+ 流程端到端验证

> 变更类型：feature（README overhaul）+ 流程 dogfooding 验证
> 执行档位：B（外层交互 + loop 经 run-track-a.sh 托管 qodercli）
> 分支：`feature/readme-overhaul`（从 master dd6f29d 切出）
> 状态源：本文件 + TodoWrite

## 1. 背景与双重目标

用户要求：把 README.md 完整更新为**非常详细 + 图文并茂**的文档。并**借此验证**：一个真实需求能否完整走通 plugin 设计（控制器不内联写码，loop 托管 qodercli）。若流程卡壳 → Google/GitHub 找根因 → 修 → 重跑，循环至完整走通。

**因此本次 loop 必须经 `run-track-a.sh` 把 README 写作托管给 fresh qodercli worker**（而非控制器内联写）——这既满足铁律，又是对 plugin 流程的真实压测。README 本身是 plugin 自己的文档，worker 以 cwd=本仓库启动、可读 AGENTS.md/skills/scripts 写出准确内容。

## 2. README 目标结构（decision-complete，worker 照此产出）

新 README 必须包含以下章节（`##` 级），且**图文并茂**（≥3 个 mermaid 图 + 多个表格）：

1. 标题 + 一句话价值主张
2. **核心理念**：控制器永不内联写码 / 双档 / context 隔离（Anthropic subagent offload）
3. **架构总览**：mermaid `flowchart` —— 顶层阶段流水线 init→explore→analyze→plan→loop→finish→evolve
4. **loop 内循环**：mermaid `flowchart` —— implement→verify→review→(fix)*→commit + fail-closed 分支（BLOCKED）
5. **执行档位 A vs B**：对比表 + 判定规则（只差外层是否交互，开发都托管）
6. **Skills 清单**：表格（11 个 skill 各自职责）
7. **底层脚本原语**：表格 —— dispatch.sh / parse-status.sh / task-state.sh / run-track-a.sh / smoke-*.sh
8. **知识库三层架构**：mermaid —— raw → wiki(ingest) → SCHEMA（Karpathy LLM Wiki）
9. **快速开始**：安装 → 冒烟自检(smoke) → dry-run → 真跑
10. **使用示例**：4 种触发（需求/spec-ready/Issue/bugfix）
11. **配置**：环境变量表
12. **产物目录结构**：autopilot/ 树
13. **HARD-GATE 不变量**：6 条
14. **跨平台/可移植性**：macOS timeout/flock/bash3.2 已处理
15. **License**

**准确性要求**：档位、铁律、脚本接口、环境变量必须与 AGENTS.md / skills/_shared/conventions.md / scripts/ 当前实现一致（worker 须先读这些源文件）。

## 3. 验证方法（tasks.md 头部 Verify，无 backtick）

结构化断言（非空 + 有 mermaid 图 + ≥10 个 H2 章节）：

```
test -s README.md && grep -q mermaid README.md && [ $(grep -c '^## ' README.md) -ge 10 ]
```

reviewer worker 另做质量维度审查（章节齐全 / 图文并茂 / 与源码一致 / 无明显错误）→ REVIEW_PASS/FAIL。

## 4. 边界 / 非目标

- 只改 `README.md`（+ 变更目录 spec/tasks 留痕 + 知识库 evolve）。不改 skills / scripts（除非验证中发现真 bug 才修，属 T5）。
- 不改 run-track-a.sh 等脚本行为（本轮验证它们，不重构）。

## 5. 流程验证观察点（dogfooding）

- run-track-a.sh 能否正确解析这份 tasks.md（--dry-run）。
- 单文件 README 的 1-Task 是否顺畅（小 spec→1 Task 旋钮）。
- verify（grep 结构断言）+ reviewer(REVIEW_PASS) fail-closed 是否正常把关。
- 卡壳则记录根因 + 修复，沉淀进 evolve。
