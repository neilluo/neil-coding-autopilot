# 操作日志

| 日期 | 操作 | 详情 |
|------|------|------|
| 2026-07-11 | Evolve | 新增 1 条 raw，新建 1 页 guide + index，bootstrap SCHEMA（dual-track-rollout 教训沉淀） |
| 2026-07-11 | Evolve | 新增 1 条 raw（dispatch timeout），新建 verify-by-running guide；dispatch/conventions/using-neil 修复并冒烟验证 |
| 2026-07-11 | Evolve | 档位 B context 预算兜底（P1-4：fork-session/-r 续跑 + 局部 offload）+ verify 层项目形状注记（P2-7）落地 loop |
| 2026-07-11 | E2E+Fix | 真跑 Track A（Rung1 echo + Rung2 worker 写文件/发 Status 均 PASS）；撞出并修复 parse-status.sh `grep -P` 不可移植(BSD exit2) + `**Status:**` 误取，verify 全绿 |
| 2026-07-11 | Evolve | dispatch.sh 相对路径→绝对路径解析（跨项目 Track A 修复）；conventions 单一事实源 + init Step1b 自检 + install smoke；新建 self-contained-script-resolution guide + C8；V2/V4 从外部 cwd 真跑 PASS |
| 2026-07-11 | Evolve | 分支纪律从原则升级为强制：HARD-GATE #2 + init 分支准备片段 + conventions「分支纪律」SSOT + C9；raw 记录本轮 master 直改教训 |
| 2026-07-11 | Evolve | 分支纪律补强：loop 加前置分支纪律门(fail-closed 自检) + conventions 标注作用域=被开发项目仓库；明确对引用方生效，非仅约束 plugin 自身开发 |
| 2026-07-12 | Feat+E2E | 新增 run-track-a.sh（确定性 bash Track A 编排器，Ralph 范式）+ smoke-run-track-a.sh(3场景) + 修 task-state.sh flock(macOS 降级)；文档入口改指启动器；真实 E2E 从 monitor 跑通 qodercli inner loop(commit 1d41fb0)；subagent CR 修 commit-fail fail-open |
| 2026-07-12 | Evolve | 确立铁律"控制器永不内联写码，开发一律托管 qodercli"（纠正 071201/071202 的"假 A"前提）：档位 B 的 loop 改经 run-track-a.sh 托管；6 文档 + C11；零脚本改动，回归 smoke 全绿 |
| 2026-07-12 | Feat+E2E | dogfooding README 重写走 Track A：worker 托管产出 README(14 H2/3 mermaid/REVIEW_PASS)；撞出并修复 git add -A × 无 .gitignore 的 scratch 污染（加 .gitignore + 清理提交 e653d57）；+C12 |
| 2026-07-12 | Fix+E2E | 第二轮 dogfooding：Track A 增量修 README 悬空引用 + 补 REVIEW 三态表(INCOMPLETE 此前缺失)；RUN_RC=0/REVIEW_PASS，commit 受 .gitignore 保护无 scratch；raw 记自动门禁放过文档悬空引用的盲区 |
