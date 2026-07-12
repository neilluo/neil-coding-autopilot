---
created: 2026-07-12
source: evolve/readme-overhaul (dogfooding via Track A)
evidence: primary
---

# dogfooding 真实需求走 Track A：验证流程 + 撞出 git add -A 污染

## Problem

把一个真实需求（完整重写 README.md，图文并茂）**真正走一遍 Track A**（控制器不内联写，经 `run-track-a.sh` 托管 qodercli worker），目的既是产出 README，也是端到端验证 plugin 流程能否被真实需求完整遵循。

结果：流程**主体跑通**——implementer(Performance) 写出 README（14 H2 / 3 mermaid）、verify（grep 结构断言）过、reviewer(Ultimate) `REVIEW_PASS`、commit、`RUN_RC=0`。但暴露一个静态审阅看不出的集成 bug：

- `run-track-a.sh` 的 commit 步用 `git add -A`（L257），而本仓库**无 `.gitignore`** → 提交把工作区里预先躺着的 scratch 文件（`.DS_Store` + 4 个 `_opt.md` 复盘笔记）一并扫入。Track A 是自主提交（无控制器挑文件），所以这类污染只有真跑才现形。

## Solution

- 加 `.gitignore`（`.DS_Store` / `*_opt.md` / 编辑器 cruft / `.track-a-logs/`）。`git add -A` 本就尊重 `.gitignore`——这是标准、零风险的正解，且是自主提交路径的正确防线。
- 清理已污染的提交（`git rm --cached` 5 个 scratch + `--amend`）→ 提交只剩 README/.gitignore/spec/tasks。
- **不硬化 run-track-a.sh 的 `git add -A`**：曾考虑"提交前排除 run 前就存在的 untracked"，但变更目录 spec.md/tasks.md 本身就是 run 前由控制器创建的 untracked，一刀切会误删它们；精确区分需特判 change dir + 绝对/相对路径，fiddly 且有丢文件风险。`.gitignore` 是更简单正确的答案。

## Lesson

- **dogfooding > 静态审阅**：让真实需求真正走一遍流程，会撞出静态读代码/读文档发现不了的集成缺陷（本例：`git add -A` × 无 .gitignore）。与 verify-by-running 同源。
- **自主 commit 循环必须有 .gitignore 兜底**：任何 `git add -A` 的自动提交器，都依赖仓库有像样的 `.gitignore`；这应作为 Track A 的前置约束写进文档/init 自检。
- **控制器托管、不内联**：README 这类"看似该内联"的文档需求也成功托管给 worker 产出，控制器全程只写 prompt + 读状态行，印证铁律可落地。
