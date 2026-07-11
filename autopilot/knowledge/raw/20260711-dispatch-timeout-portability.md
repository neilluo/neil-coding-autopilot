---
created: 2026-07-11
source: evolve/cr-round-1
evidence: primary
---

# dispatch.sh 依赖 GNU timeout，在 macOS 上直接 exit 127

## Problem

`scripts/dispatch.sh` 的 `run_with_timeout` 硬调用 `timeout "$TIMEOUT" "$@"`。macOS 默认不带 GNU `timeout`（coreutils 里叫 `gtimeout`，需 `brew install coreutils`）。实测本机 `timeout`/`gtimeout` 皆无 → 任何平台的 worker 在起 CLI 之前就 `timeout: command not found` / **exit 127**。这才是「Track A 从未端到端跑通」的真实机制 —— 脚本级阻断，比 flag 冲突更致命，且静态审阅与复盘报告都没抓到。

配套发现：conventions.md 曾声称「qodercli 不支持 `--model`」（事实错误，`qodercli --help` 明确有 `-m/--model`）；该假声明由 workflow-hardening commit 引入 —— 它正确删了不存在的 `--max-turns`，却把存在的 `--model` 一起误判为不支持。

## Solution

- dispatch.sh 探测 `TIMEOUT_BIN=$(command -v timeout || command -v gtimeout || true)`；有则用，无则降级为「无超时 + WARN」（提示 `brew install coreutils`），不再硬崩。
- 新增 `scripts/smoke-dispatch.sh`：stub 掉 qodercli/claude/codex（只 echo 参数），断言 dispatch.sh 能跑通且传对 flag —— 不烧 token，可进 CI / install 自检。实测 `SMOKE: ALL PASS`。
- 修正 conventions.md：以 `qodercli --help` 为准列真实 flag，统一经 dispatch.sh 调度。

## Lesson

1. **shell 脚本别假设 GNU 工具存在**：`timeout`/`sed -i`/`date`/`readlink -f` 在 macOS/BSD 上行为不同或缺失；对外部命令依赖要 `command -v` 探测 + 优雅降级。
2. **verify-by-running > 静态审阅**：报告与静态分析都漏了 timeout bug，一次 token-free stub 冒烟就复现了。招牌能力必须有「能真跑起来」的冒烟证据，否则视为未验证（fail-closed）。
3. **删 flag 时别误伤**：批量清理「不支持的参数」时，逐个核对 `--help`，别把真实 flag 一起误标。
