#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Evolve writeback for observable-acceptance-gate: index + log edits in the
plugin's knowledge wiki. Fail-loud: each anchor must match exactly once."""
import sys

BASE = "/Users/neil/Desktop/neilcodebase/neil-coding-autopilot/autopilot/knowledge/wiki"

EDITS = [
    # index.md: add the first Concepts entry
    (f"{BASE}/index.md",
     "## Concepts（架构决策）\n\n## Entities（模块 / 组件）",
     "## Concepts（架构决策）\n- [[observable-acceptance-gate]] — 可观测验收门：验收=不变量+蜕变关系（治 test oracle problem）；扰动测试蹭 verify 门；headless reviewer 上牙；纯渲染/错 SSOT 转 Phase 2\n\n## Entities（模块 / 组件）"),
    # log.md: append an evolve row after the last (telemetry-pluggable-sink) row
    (f"{BASE}/log.md",
     "+1 guide(cloud-deployment-readiness) |",
     "+1 guide(cloud-deployment-readiness) |\n| 2026-07-19 | Feat+Evolve | 可观测验收门落地(feature/observable-acceptance-gate FF 合并 181005d)：新增 skills/_shared/observable-acceptance.md(SSOT) + explore/analyze/plan/HARD-GATE#7 引用 + build_review_prompt 上「可观测验收」维度(headless reviewer 读 spec 交叉核验 Verify↔MR)+CHANGE_DIR 绝对化；验收=不变量/蜕变关系治 test oracle problem，扰动测试蹭现有 eval verify 门；spec 经 7 轮×3 视角≈20 审收敛(R1=96%)，植入违规实测 reviewer 真输出 REVIEW_FAIL；smoke-dispatch/run-track-a 全绿；+1 raw / +1 concept(observable-acceptance-gate) |"),
]

def main():
    for path, old, new in EDITS:
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
        n = text.count(old)
        if n != 1:
            print(f"ABORT: anchor matched {n} times (want 1) in {path}")
            sys.exit(1)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text.replace(old, new, 1))
        print(f"patched: {path}")
    print("ALL PATCHED")

if __name__ == "__main__":
    main()
