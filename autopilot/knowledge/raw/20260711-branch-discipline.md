---
created: 2026-07-11
source: evolve/self-observation
evidence: primary
---

# 未开分支、直接在 master 上改（违反分支纪律）

## Problem

本次 dispatch 路径解析修复（含知识库沉淀）是**直接在 master 工作树上做的**（虽未提交）。HARD-GATE #2「分支纪律：功能分支开发，不直接在主干写」当时只是一条原则性不变量，**没有可执行的强制步骤**——`using-neil-autopilot`「初始化流程」只建变更目录、不切分支，控制器因此默认在当前分支（master）动手。用户当场指出："理论上每次有变动都要新开分支。"

## Solution

把"每次变动先开功能分支"从原则升级为**可执行 + 可自检的约束**：

- HARD-GATE #2 明确"实现前自检当前分支，在 main/master 上必须先切 `<type>/<feature-name>`"。
- `using-neil-autopilot`「初始化流程」加分支准备 git 片段（建变更目录**前**先切分支）。
- `_shared/conventions.md` 新增「分支纪律」单一事实源片段（主干名自适应，不写死 main/master，呼应 C4）。
- SCHEMA C9 固化为可检查约束。
- `autopilot-loop` 加「前置分支纪律门」自检（fail-closed，兜底 init 被跳过如 spec-ready 快路径）；conventions 标注**作用域=被开发项目仓库**——明确约束对象是**引用方在自己项目里**，不止 plugin 自身开发。

## Lesson

不变量光写在 HARD-GATE 里不够——控制器会按"当前状态默认值"行事（当前分支=master 就在 master 改）。**强制行为必须配一个可执行步骤 + 自检点**，否则等于没约束。本轮当场践行：把未提交工作切到 `fix/workflow-branch-discipline` 再继续。
