#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Apply Observable Acceptance Gate edits to neil-coding-autopilot SKILLs.
Fail-loud: each anchor must match exactly once, else abort (no partial writes)."""
import sys
from collections import defaultdict

BASE = "/Users/neil/Desktop/neilcodebase/neil-coding-autopilot/skills"

EDITS = []

# ---- using-neil-autopilot: HARD-GATE add #7 ----
EDITS.append((f"{BASE}/using-neil-autopilot/SKILL.md",
"6. 状态可追溯：进度写入 `progress.md`（档位 A），或以 TodoWrite 为单一状态源（档位 B）——不靠记忆。",
"""6. 状态可追溯：进度写入 `progress.md`（档位 A），或以 TodoWrite 为单一状态源（档位 B）——不靠记忆。
7. 可观测验收：user-facing 改动（改变 UI/CLI/API/告警/报表等终端可观测输出）必带「可观测验收」——每个可观测值/态给出 SSOT + 不变量 + 蜕变关系（多源值含判别样例），其确定性扰动测试即该 Task 的 `**Verify**`；不可离线验证者须 `UNVERIFIED-OBSERVABLE` 醒目登记转 Phase 2、禁静默放行；结构缺失（无验收段且无可证伪免除）→ `BLOCKED|{原因}` 立即 exit、禁挂起。详见 `_shared/observable-acceptance.md`（headless 运行期拦截限可离线派生层；纯渲染/错 SSOT 交 Phase 2）。"""))

# ---- analyze: Step 3 spec-must-contain add item 8 ----
EDITS.append((f"{BASE}/autopilot-analyze/SKILL.md",
"7. 里程碑 / Phase 规划",
"""7. 里程碑 / Phase 规划
8. 可观测验收（Observable Acceptance）：对每个用户可观测输出值/态给出 SSOT + 不变量 + 蜕变关系（多源值必带判别样例、含空/部分/打架三态）；禁实现口径。先查 KB doctrine 推导，查不到覆盖真歧义才登记 `[NEEDS CLARIFICATION]`。详见 `_shared/observable-acceptance.md`。user-facing 改动缺此段且无可证伪免除 → `ANALYZE_STATUS=BLOCKED|{原因}`"""))

# ---- analyze: Step 4 self-review round-3 dimension ----
EDITS.append((f"{BASE}/autopilot-analyze/SKILL.md",
"| 第3轮 | 边界情况、扩展性、MVP聚焦度 |",
"| 第3轮 | 边界情况、扩展性、MVP聚焦度；可观测验收完备性（多源值有判别性 MR？扰动轴覆盖全部非权威源？SSOT 摆明？实现口径泄漏？——均 WARN 自修不 BLOCK） |"))

# ---- plan: Task-description-must-contain add item 5 ----
EDITS.append((f"{BASE}/autopilot-plan/SKILL.md",
"4. 验证方式（编译通过 / 测试通过 / curl 验证）",
"""4. 验证方式（编译通过 / 测试通过 / curl 验证）
5. 若改动用户可观测输出：SSOT + 不变量 + 蜕变关系的确定性扰动测试（`_shared/observable-acceptance.md`），作为该 Task 的 `**Verify**`"""))

# ---- plan: template Verify line (remove dead Runtime Verify, pin user-facing) ----
EDITS.append((f"{BASE}/autopilot-plan/SKILL.md",
"""**Verify**: `mvn compile -q` exit 0
**Runtime Verify**: `curl -sf http://localhost:8080/health`（可选，需要运行时验证时填写）""",
"**Verify**: `mvn compile -q` exit 0  # user-facing 改动：此处须为「可观测验收」的确定性扰动测试（见 `_shared/observable-acceptance.md`），禁仅编译级；不可离线验证者改标 `UNVERIFIED-OBSERVABLE(<MR>)` 登记转 Phase 2、禁静默放行"))

# ---- plan: constraint bullet for user-facing + spec-ready ----
EDITS.append((f"{BASE}/autopilot-plan/SKILL.md",
"- 涉及以下场景的 Task 自动标记 `Gate: human`：",
"""- user-facing 改动：改动用户可观测输出的 Task，其 `**Verify**` 须为可观测验收的确定性扰动测试（`_shared/observable-acceptance.md`）；spec-ready（跳过 analyze）由 plan 据来料 spec+KB 自填不变量+MR，低置信→标 `UNVERIFIED-OBSERVABLE`+登记、不产错测试（不 stall），结构不可生成才 `PLAN_STATUS=BLOCKED|{原因}`。
- 涉及以下场景的 Task 自动标记 `Gate: human`："""))

# ---- explore: bugfix lightweight mode add item 4 ----
EDITS.append((f"{BASE}/autopilot-explore/SKILL.md",
"""**bugfix 轻量模式**: 只确认以下问题后即可结束：
1. Bug 的复现路径/触发条件
2. 期望的正确行为
3. 修复范围（是否涉及数据库/API 变更）""",
"""**bugfix 轻量模式**: 只确认以下问题后即可结束：
1. Bug 的复现路径/触发条件
2. 期望的正确行为
3. 修复范围（是否涉及数据库/API 变更）
4. 若改动用户可观测输出：该值的 SSOT + ≥1 条判别性蜕变关系（见 `_shared/observable-acceptance.md`）"""))

# ---- explore: Step 4 design-summary pointer ----
EDITS.append((f"{BASE}/autopilot-explore/SKILL.md",
"如果用户提出修改意见，调整后重新呈现，直到确认。",
"""如果用户提出修改意见，调整后重新呈现，直到确认。

> 可观测验收（user-facing 改动必附）：对每个用户可观测输出值/态给出 SSOT + 不变量 + 蜕变关系（多源值含判别样例，含空/部分/打架三态）；详见 `_shared/observable-acceptance.md`。"""))

byfile = defaultdict(list)
for f, o, n in EDITS:
    byfile[f].append((o, n))

for f, ops in byfile.items():
    try:
        s = open(f, encoding="utf-8").read()
    except FileNotFoundError:
        print(f"FAIL: file not found: {f}"); sys.exit(1)
    for o, n in ops:
        c = s.count(o)
        if c != 1:
            print(f"FAIL [{f}]: anchor count={c} (want 1) for: {o[:48]!r}"); sys.exit(1)
        s = s.replace(o, n, 1)
    open(f, "w", encoding="utf-8").write(s)
    print(f"OK  {f}  (+{len(ops)} edits)")

print("ALL EDITS APPLIED")
