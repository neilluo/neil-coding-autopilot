---
updated: 2026-07-11
category: guides
evidence: primary
sources: [raw/20260711-dispatch-timeout-portability.md]
---

# 指南：verify-by-running + shell 可移植性

**适用**：涉及 shell 脚本、CLI 调度、跨平台（macOS/BSD vs Linux/GNU），或任何「招牌能力/关键机制」的正确性主张。

## verify-by-running（跑一次胜过读十遍）

- 任何关键机制必须有一个**能真正跑起来的冒烟测试**，否则视为未验证（fail-closed，别只靠读代码/读文档下结论）。
- 冒烟测试应**零外部代价**：stub 掉会烧 token / 联网 / 改环境的部分，只断言「流程能跑通 + 参数/契约正确」。本项目样板：`scripts/smoke-dispatch.sh`（stub qodercli/claude/codex，只 echo 参数并断言 flag）。
- 静态审阅与复盘报告都可能漏掉 runtime-only 的 bug（本项目已撞到多例，均在**真跑 Track A** 时才现形：① `timeout` on macOS → dispatch.sh exit 127；② `grep -P` on macOS BSD grep → parse-status.sh exit 2，且旧正则对 `**Status:** DONE` 会误取到 `**`；③ `flock` on stock macOS 缺失 → task-state.sh command not found；④ macOS 自带 bash 3.2，`declare -A`/`mapfile` 不可用。读代码/读文档都看不出，一跑就现形）。

## shell 可移植性（macOS/BSD vs GNU）

- 别假设 GNU 工具存在：`timeout`（mac 为 `gtimeout`，需 coreutils）、`flock`（stock macOS 无 → 降级 mkdir 原子锁）、`sed -i`（BSD 需 `-i ''` 或附着后缀）、`date`、`readlink -f`、`grep -P` 等行为不同或缺失。别假设 bash≥4（macOS 自带 3.2：无 `declare -A`/`mapfile`，用普通数组 + awk）。
- 对外部命令依赖用 `command -v X || command -v Y || 降级` 探测；缺失时优雅降级 + WARN，而不是硬崩。

## 相关

- 源自 `raw/20260711-dispatch-timeout-portability.md`
- 约束见 `SCHEMA.md` C6 / C7
