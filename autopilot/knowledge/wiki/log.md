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
