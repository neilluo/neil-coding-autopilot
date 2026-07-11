# Spec — dispatch.sh 路径解析可移植化（Track A 跨项目可用）

> 变更类型：bugfix / refactor-completion
> 执行档位：B（交互）
> 分支：master（当前）— 小改动，改完 diff 交用户过目，**不自动 commit**
> 状态源：本文件（设计留痕）+ TodoWrite（Task 状态）

## 1. 背景与根因

Track A（批处理）靠控制器执行 `scripts/dispatch.sh` spawn worker。但该脚本**只存在于 plugin 安装目录**（`~/.qoder/skills/neil-coding-autopilot/scripts/`），而所有 skill 文档让控制器执行的是**相对路径** `scripts/dispatch.sh`。在业务项目（如 monitor）里跑时 CWD=业务项目根 → `scripts/dispatch.sh` 解析成 `monitor/scripts/dispatch.sh` → 不存在 → Track A 起不来。这正是 `071102_opt.md` 里"monitor 没有 dispatch.sh、切不了 Track A"的真实机制。

**结论**：不是"每个项目各自搭建"的问题，是 **plugin 层的路径引用缺陷**——该用 plugin 自带那份的绝对路径。

## 2. 方案（不 copy 脚本进业务项目）

定义 `$DISPATCH` 解析顺序，集中在 `conventions.md` 作单一事实源：

1. `$AGENT_DISPATCH`（显式覆盖，CI/非标准安装）
2. 注入的 skill base 目录推导 plugin 根 → `<root>/scripts/dispatch.sh`（主路径，与安装位置无关）
3. 已知安装位置 `$HOME/.qoder/skills/neil-coding-autopilot/scripts/dispatch.sh`（兜底）
4. 都无 → fail-closed 明确报错，不静默假装跑 A

## 3. 改动清单

| # | 文件 | 改动 |
|---|------|------|
| T2 | skills/_shared/conventions.md | 新增「dispatch.sh 路径解析」小节（单一事实源）；调度模板 + 注解改用 `$DISPATCH` |
| T3 | scripts/dispatch.sh | 顶部加自定位 `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"` |
| T4 | skills/autopilot-init/SKILL.md | 新增 Step 1b：Track A 能力自检（which qodercli + timeout 探测 + 解析 dispatch + smoke），只校验+记录，不 copy |
| T5 | install.sh | 结尾跑 smoke-dispatch.sh 自检（失败 WARN，不阻断安装） |
| T6 | AGENTS.md / autopilot-loop / using-neil | 措辞同步：`AGENT_DISPATCH` 语义→"解析到绝对路径"；semi-executable 处指向 `$DISPATCH` |

## 4. 跨 OS 表态（写进 conventions）

Track A 依赖 bash：mac/Linux 开箱可用；Windows 需 WSL/Git Bash。探不到 bash/qodercli → 明确只能档位 B。

## 5. 验证（fail-closed；任一不过即停）

- **V1** token-free：`bash scripts/smoke-dispatch.sh` → ALL PASS（dispatch.sh 带新 SCRIPT_DIR 仍工作）
- **V2** token-free：从"外部项目 CWD"跑解析逻辑 → 解析到 plugin 绝对 dispatch.sh 且 `test -f` 通过（证明跨项目修复）
- **V3** token-free：`bash -n` 语法检查 dispatch.sh / install.sh / smoke-dispatch.sh
- **V4** 真实（少量 token）：从外部 CWD 用解析出的绝对路径 dispatch 一个 echo-only worker → 真起 qodercli，证明 monitor 场景现可跑
- 清理所有中间产物

## 6. 边界 / 非目标

- **不**往业务项目 copy 脚本。
- **不**改 Track A/B 的判定逻辑与阶段不变量。
- 纯 Markdown/shell 文档改动，无运行时程序。
