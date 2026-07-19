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
| 2026-07-18 | Feat+Evolve | 补齐自进化闭环：evolve Step 6 门禁化回写 AGENTS.md + 新增 run-autopilot.sh(loop→finish→evolve,fail-closed)+smoke；dogfood 走 Track A(3 Task 全 REVIEW_PASS)；grounding 纠正调研“两份副本”误判(实为 symlink)；+2 raw / entities/run-autopilot / 2 guide 更新 / AGENTS.md 回写 2 处 |
| 2026-07-19 | Feat+Evolve | agent-observability 走 Track A 落地(6 Task 全 REVIEW_PASS, FF 合并 741dd41)：telemetry.sh + dispatch/run-track-a 埋点 + daily-analysis + install-daily-schedule + README/AGENTS；spec 经 9 subagent/3 轮 Review 收敛(4 CRITICAL 全修)；撞出 qodercli worker 瞬时 stall(kill+--resume 恢复) + .qoder 提交污染(C12 再现,补 .gitignore)；+1 raw / +1 guide(dogfood-freeze-and-stall-recovery) / +1 entity(telemetry-system) |
| 2026-07-19 | Feat+Evolve | telemetry sink 可插拔化(NEIL_AUTOPILOT_LOG_SINK,默认 file 零回归)走 Track B(1 Task,REVIEW_PASS,FF df63edf)：单点 telemetry_emit→按函数名自动发现 sink 分发器,加后端零改采集,为 autopilot 上云(形态未定)买接缝保险；本轮零 stall/零 .qoder 污染(验证上轮 .gitignore 防线)；撞出 tasks.md verify 须用 **Verify**:`cmd` 反引号(非表头 > Verify command:)；+1 raw / +1 guide(cloud-deployment-readiness) |
| 2026-07-19 | Feat+Evolve | 可观测验收门落地(feature/observable-acceptance-gate FF 合并 181005d)：新增 skills/_shared/observable-acceptance.md(SSOT) + explore/analyze/plan/HARD-GATE#7 引用 + build_review_prompt 上「可观测验收」维度(headless reviewer 读 spec 交叉核验 Verify↔MR)+CHANGE_DIR 绝对化；验收=不变量/蜕变关系治 test oracle problem，扰动测试蹭现有 eval verify 门；spec 经 7 轮×3 视角≈20 审收敛(R1=96%)，植入违规实测 reviewer 真输出 REVIEW_FAIL；smoke-dispatch/run-track-a 全绿；+1 raw / +1 concept(observable-acceptance-gate) |
| 2026-07-19 | Evolve | archive-knowledge-loop 完成变更蒸馏(archive/2026-07-19-*)：闭环 changes→archive→knowledge(①挪 archive-change.sh + ②嚼 evolve 第5源 + ③升 kb-path.sh 全局KB + ④翻 kb-search.sh)，归档变"喂未来开发的活知识"、跨项目复利；本轮 CR 撞出 3 规律教训并沉淀——pipefail+head SIGPIPE(141) 须 `\|\| true`(kb-search.sh:139)、脚本生成文件须显式 git add(commit 41af2ea track summary.md)、归档 XOR 不变量(C13 已登记)；+2 raw / 新建 guide(archive-knowledge-loop) + 更新 guide(verify-by-running) + index 导航 / 全局升迁 1 条(通用 bash/git 坑) |
