---
created: 2026-07-18
source: evolve/task-blocked
evidence: primary
---

# 踩坑：调研假设"两份物理副本需同步"，实为 symlink（应先验证 FS 事实再定范围）

## Problem
调研方案 2 提出"同步两份 evolve 副本（顶层 `~/.qoder/skills/autopilot-evolve/` 与插件内 `skills/autopilot-evolve/`），保持 IDENTICAL"，并据此规划了一个"同步任务"。依据是 `diff` 两路径得 IDENTICAL → 推断为两份需手工同步的物理副本。

## Solution
grounding 阶段用 `ls -la` / `readlink` / `stat -f %i` / `test -ef` 验证发现：`~/.qoder/skills/autopilot-evolve` 是**指向本工作区的 symlink**（同 inode），插件全部 `autopilot-*` skill 均由 `install.sh` 以 `ln -sf` 安装。`diff IDENTICAL` 只是因为它们本就是同一个文件。→ "同步任务"取消（moot）；编辑工作区即时生效。

## Lesson
- **`diff` 结果 IDENTICAL 不能推断"两份独立副本"**——可能是 symlink/hardlink 指向同一 inode。定"同步/复制"类工作范围前，必须先用 `test -ef`（same-file）或 `stat` inode / `readlink` 验证是否真是两份物理文件。
- **grounding 先于 scoping**：调研/报告的"改动清单"可能基于对文件系统布局的误判；动手前用只读命令核实安装模型（symlink vs copy），能直接砍掉伪任务。
- 本项目安装模型：`install.sh` 用 `ln -sf` 把每个 skill 目录 symlink 进 `~/.qoder/skills/`；改工作区 = 改线上加载的 skill，无需 copy/sync。
