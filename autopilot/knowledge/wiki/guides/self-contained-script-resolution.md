---
updated: 2026-07-11
category: guides
evidence: primary
sources: [raw/20260711-dispatch-path-resolution.md]
---

# 指南：分发型 plugin 自带脚本的可移植定位

**适用**：plugin/skill 需要执行自带的辅助脚本（如 dispatch.sh、smoke），且会被安装到"与被开发项目不同"的位置（如 `~/.qoder/skills/...`）。

## 规则

1. **禁止相对路径**。`scripts/x.sh` 相对的是消费项目的 CWD，不是 plugin 目录——在业务项目里必然找不到。
2. **解析绝对路径，多级兜底 + fail-closed**：① 环境变量覆盖 → ② 由 harness 注入的 skill base 目录推导 plugin 根 → ③ 已知安装位置探测 → ④ 都无则明确报错，**不静默降级成"假装能跑"**。
3. **绝不写死家目录/用户名**（`/Users/<name>/...`）。跨用户、跨 OS 立刻废；这是企业推广第一道坎。
4. **脚本自身 `pwd -P` 自定位**：`SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"`（别用 macOS 缺失的 `readlink -f`），以便找同目录兄弟脚本。
5. **把"能力"前移到安装/初始化期自检**：install 末尾 + init 阶段探测 CLI/依赖/脚本可达性，探不到就明确告知降级路径，而不是运行到一半崩。
6. **跨项目正确性靠"从外部目录真跑一次"验证**（token-free 解析 + 一次真实调用），不是读代码。见 [[verify-by-running]]。

## 单一事实源

本项目：`skills/_shared/conventions.md`「dispatch.sh 路径解析」。所有引用都指向它，不各自散落 `scripts/dispatch.sh`。
