---
created: 2026-07-19
source: evolve/completed-change
evidence: primary
---

# 本轮 CR 规律性教训：pipefail+head SIGPIPE / 生成文件入库 / 归档 XOR 不变量

> 源：本轮 review 日志 + 提交（`scripts/kb-search.sh` L137-139、commit `41af2ea` "track generated summary.md"、`skills/autopilot-finish/SKILL.md` Step 6、SCHEMA C13）。

## Problem

本轮开发/CR/dogfood 撞出三条规律性坑：

1. **`set -o pipefail` + `| head` 截断 → SIGPIPE(141)**：管道以 `head -n N` 收尾，当上游命中数 > N 时 `head` 提前关闭管道，上游写入被 `SIGPIPE` 打断，`pipefail` 把 141 当作整管道退出码传播。对 kb-search.sh 这种"fail-safe / 恒 exit 0"契约是致命破坏——检索命中数超 `--limit` 时脚本会假失败。
2. **脚本生成文件漏入库**：`archive-change.sh` 会在搬迁前生成 `summary.md` 骨架（若缺），但 finish 走 `git mv` 只移动**已被 git 跟踪**的文件；新生成的 summary.md 未 `git add` → 归档后该产物游离在工作区、漏进提交（本轮 commit `41af2ea` 才补上 track）。
3. **归档易两处并存 / 皆无**：`cp` 只复制不清理导致 archive 与 changes 同时存在（旧根因）；反过来若 `mv` 失败又可能两处皆无。缺一条显式不变量来兜底校验。

## Solution

1. **管道末段 `|| true` 兜底**：`awk '!seen[$0]++' "$F" | head -n "$LIMIT" || true`（kb-search.sh:139），并注释写明"guards against SIGPIPE(141) when head closes the pipe early"。这是 `pipefail` 脚本用 `head`/`grep -q` 截断上游时的通用修法。
2. **生成文件必须显式入库**：脚本生成新产物（summary.md）后，调用方（finish / dogfood）需 `git add -A`（或 add 具体文件）再提交，否则 `git mv`-only 流程漏提交新产物。SKILL 调 archive-change.sh 后应 `git add -A`。
3. **登记 C13 归档毕业不变量**：完成变更经 `archive-change.sh` 从 `changes/` `git mv` 进 `archive/`，一个变更 ∈ archive **XOR** changes（绝不两处并存/皆无）；archive-change.sh 后置断言"源目录必须消失"+ finish 双保险硬门禁化，搬迁失败即 BLOCKED。

## Lesson

- **`pipefail` 下任何以 `head`/`grep -q`/早退命令收尾的管道，都要 `|| true` 兜底**——否则命中数超行数时上游 SIGPIPE 会让整管道退 141，静默破坏 fail-safe 契约。跨项目通用坑。
- **凡"脚本生成新文件"，调用链必须显式 `git add`**——`git mv`/`git commit` 只认已跟踪文件，新产物默认游离，dogfood 时才现形。跨项目通用坑。
- **文件系统状态迁移类操作要有 XOR 不变量 + 后置断言**：搬迁后校验源必须消失、目标必须存在，任一违反即 fail-closed，别信"移动一定成功"。
