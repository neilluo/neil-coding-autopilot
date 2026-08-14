# Cost and latency benchmark

Offline deterministic measurements; no model requests are issued.

| Group | Scope | Old / count | New / duration | Reduction / avoidable |
|---|---|---:|---:|---:|
| Review context | 4a93e43 autopilot(track-a): Task 1 — parse-markers.sh —— 锚定式状态/裁决解析（单文件，正则已给死） | 42205 B | 6947 B | 83.5% |
| Review context | cfc6095 autopilot(track-a): Task 2 — telemetry 扩展（token 字段 + 默认值调整） | 57684 B | 8687 B | 84.9% |
| Review context | 2933198 autopilot(track-a): Task 3 — dispatch.sh —— 真实 usage 抓取 + 超时哑弹修复 | 57178 B | 21766 B | 61.9% |
| Review context | f9e3b81 autopilot(track-a): Task 4 — run-track-a.sh —— 瞬时故障重试且不扣轮次 | 87764 B | 28210 B | 67.9% |
| Review context | b51e665 autopilot(track-a): Task 5 — review 上下文改为有界 diff | 77916 B | 14684 B | 81.2% |
| Review context | a8d5bfb autopilot(track-a): Task 6 — daily-analysis 增加 token/成本聚合 | 69365 B | 5515 B | 92.0% |
| Review context | 8305180 autopilot(track-a): Task 1 — smoke-parse-markers.sh —— D19 六条判别样例 | 23164 B | 24101 B | -4.0% |
| Review context | 9709fd1 autopilot(track-a): Task 2 — classify-outcome.sh 改用锚定解析 + D18 长度门 | 12546 B | 4657 B | 62.9% |
| Review context | 4ef0fa4 autopilot(track-a): Task 7 — 每日任务 TCC 修复 + 日志目录迁移工具 | 59619 B | 4867 B | 91.8% |
| Review context | 891e78c autopilot(track-a): Task 8 — SKILL.md 渐进式瘦身 + 不变量门禁 | 86381 B | 27057 B | 68.7% |
| Review context | 90ed816 autopilot(track-a): Task 9 — 文档与知识沉淀 | 85566 B | 19323 B | 77.4% |
| Review context | b8d3474 autopilot(track-a): Task 10 — 自迭代安全 — 递归护栏 + 并发锁 + smoke 遥测隔离 | 192419 B | 22491 B | 88.3% |
| Review context | 756f4b4 autopilot(track-a): Task 11 done (bench 76.7% review / 45% SKILL); Task 12/13 via side-change | 71218 B | 18706 B | 73.7% |
| Review context | dec4754 autopilot(track-a): Task 14 — no-marker=EMPTY tightening; two OK fixtures gain Status line (semantics noted in spec §12) | 77920 B | 5179 B | 93.4% |
| Review context | **Total** | **1000945 B** | **212190 B** | **78.8%** |
| SKILL.md injection | using-neil-autopilot | 16756 B | 9212 B | 45.0% |
| SKILL.md injection | current skills/* total | N/A | 77572 B | N/A |
| Replay waste | review/fix transient failures | 0 events | 0 s | 0 s avoidable |
| Replay waste | blocked/resumed implement replay | N/A | 0 s | 0 s avoidable |

**Conclusion:** Review context changed from 1000945 B to 212190 B (78.8% reduction); entry-skill injection changed from 16756 B to 9212 B (45.0% reduction); historical avoidable transient/replay wall time is 0 s / 0 s.
