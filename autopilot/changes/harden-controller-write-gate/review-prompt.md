# Code Review 任务：控制器写码硬门禁（harden-controller-write-gate）

你是资深审查型 worker（只读审查，**不要修改任何文件**）。当前 CWD 是插件仓库根。
本次变更把「autopilot 控制器在运行期不得内联写源码」从 md 软约束升级为 Qoder **PreToolUse 运行时硬门禁**（deny，连 bypass_permissions 也拦得住），worker 照常写码。

## 请逐一阅读并审查这些文件

1. `hooks/guard-controller-write.sh` —— 核心判定逻辑（最重要）
2. `scripts/smoke-guard.sh` —— token-free 单测
3. `scripts/dispatch.sh` —— 新增 `export AUTOPILOT_ROLE=worker`
4. `install.sh` —— 把 guard 合并进 `~/.qoder/settings.json` 的逻辑（激活入口）
5. `hooks/hooks-qoder.json` —— 声明式 hook 记录
6. `skills/using-neil-autopilot/SKILL.md` —— sentinel 创建（搜 `.run-active`）
7. `skills/autopilot-finish/SKILL.md` + `skills/autopilot-evolve/SKILL.md` —— sentinel 移除
8. `skills/_shared/conventions.md` —— 铁律文档行
9. `autopilot/changes/harden-controller-write-gate/spec.md` —— 设计记录（对照实现是否一致）

## 审查重点（每条给结论 + 证据 file:line）

1. **判定正确性**：4 层门（scope→worker→whitelist→deny）逻辑是否正确？
   - worker（`AUTOPILOT_ROLE=worker`）放行、白名单（`.md`/`autopilot/`/`.qoder`/`AGENTS.md`）放行、控制器写源码 deny、非运行期（无 sentinel）全放行——有无逻辑漏判/误判？
2. **安全洞**：除已知延后项（Bash 重定向 `cat > x.py`、跳阶段/CR 门）外，是否还有可绕过的写源码路径？matcher 是否覆盖 IDE 真实工具名（`create_file/search_replace` 等）？
3. **fail 方向**：hook 内部出错是否 fail-open（放行、绝不卡死宿主）？worker 万一没 role 是否 fail-closed（deny，不误放控制器）？方向是否正确？
4. **install.sh 合并安全性**：jq 合并是否**非破坏**（保留既有 PostToolUse 等）、**幂等**（不重复添加）、有**备份**、无 jq 时有降级提示？有无可能损坏用户 `~/.qoder/settings.json`？
5. **sentinel 生命周期**：创建（run 开始）/移除（finish+evolve）是否闭环？陈旧残留（崩溃）会不会长期误锁日常编码？TTL(mtime>12h 忽略) 是否兜底？
6. **macOS 可移植性**：sed（无 -P/\d/\s）、stat（`-f` vs `-c`）、无 flock、`${TMPDIR}` 处理是否 BSD 安全？
7. **spec 与实现一致性**：spec.md §0 声称的 3 处修正（激活改 install.sh / worker 只认 role / 去 tmp 白名单）是否与代码一致？

## 输出格式

先按严重度列出发现（若无则写“无”）：
```
[Critical] <问题> — <file:line> — <建议>
[Major]    ...
[Minor]    ...
```
最后**单独一行**输出（本插件 REVIEW_STATUS 三态约定）：
- 无 Critical/Major → `REVIEW_STATUS=PASS`
- 有 Critical/Major → `REVIEW_STATUS=FAIL`
- 有文件没审到 → `REVIEW_STATUS=INCOMPLETE`
