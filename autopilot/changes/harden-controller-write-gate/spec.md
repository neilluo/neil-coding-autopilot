# MVP Spec — 控制器写码硬门禁（harden-controller-write-gate）

> 目标：把「autopilot 控制器在运行期不得内联写源码」这条铁律，从 md **软约束**升级为 Qoder PreToolUse **运行时硬门禁**（deny，unbypassable）。worker 照常写码。
> 范围：最小 MVP。2 个新文件 + 4 处小改，完全可回滚。
> 状态：技术可行性已**真机实跑确认**（见下「可行性证据」），可进入实施。

## 0. 实施修正（相对初稿，均已真机验证）

实施中发现 3 处初稿假设需修正，最终实现以本节为准：

1. **激活方式变了**：本插件以 **skills 软链**安装、**不是** Qoder plugin，`hooks-qoder.json` 不会被自动加载（实测 `~/.qoder/settings.json` 从未引用它）。改由 **`install.sh` 幂等合并一条 PreToolUse guard（绝对路径）进 `~/.qoder/settings.json`** 激活（沙箱验证：非破坏既有 hooks、幂等、带备份）。`hooks-qoder.json` 保留为声明式记录（未来若做成正式 plugin 可直接用）。
2. **worker 判据收紧**：去掉「`permission_mode==bypassPermissions` 也放行」这条辅判据——它会让任何 bypass 会话（含 bypass 的控制器）被当 worker。worker **只认 `AUTOPILOT_ROLE=worker`**（实测可继承）；worker 万一没这标记则 deny＝安全方向，绝不误放控制器。
3. **去掉 tmp 白名单**：控制器唯一合法的 tmp 写是 prompt 文件（`.md`，已被 `*.md` 覆盖）；`review-files.txt`/`task-diff.patch` 经 Bash 重定向写、本 MVP 不拦。保留 tmp 白名单反而给「源码写进 tmp」开洞，故移除。
4. **matcher 含 IDE 别名**：除 `Write|Edit|MultiEdit` 外补 `create_file|write_file|search_replace|replace`（本机活样例 `guard-tool.sh` 证实 IDE 用这些名），否则控制器用 `create_file` 即绕过。

---

---

## 1. 背景与可行性证据（真机 qodercli 1.0.16，2026-07-12 实跑）

痛点（源自 `opt.md` / `0711_opt.md` / `071102_opt.md`）：几乎所有铁律都写在 md 里靠 LLM 自觉；运行时无任何东西能阻止控制器内联 `Write`/`Edit` 写源码。`run-track-a.sh` 内部虽硬，但「进不进这台机器」是软决定。

用一个隔离探针（`--settings` 注入 echo-hook + `-w /tmp` 隔离 workdir，未碰全局配置）实跑确认：

| 结论 | 证据 |
|------|------|
| PreToolUse 在 `--permission-mode bypass_permissions` 下**照常触发**（unbypassable 成立） | worker 全程 bypass，hook 仍 fire |
| **`AUTOPILOT_ROLE=worker` 被 hook 子进程继承** | dump 的 `--ENV--` 段含 `AUTOPILOT_ROLE=worker` |
| worker 的 `permission_mode == "bypassPermissions"`；普通 IDE/控制器会话该字段 **MISSING** | 探针 dump + audit.jsonl 关联统计 |
| stdin 真实字段名 | `tool_name`（顶层）、`tool_input.file_path`、`cwd`、`permission_mode`、`hook_event_name` |
| deny 契约 | `exit 2`（stderr 回传 Agent）或 `hookSpecificOutput.{hookEventName(必填),permissionDecision:"deny",permissionDecisionReason}` |
| 插件脚本路径占位符 | Qoder 原生 `${QODER_PLUGIN_ROOT}`（运行时注入的 env）；**非** `__PLUGIN_HOME__`（本插件自定义、install.sh 未替换 → 现有 hook 亦有此隐患） |
| 复用资产 | 本机 `~/.qoder/hooks/common.sh` 已有 `jq_field`（jq + sed 兜底）、fail-open trap、JSON 转义等成熟 idiom，可照搬 |

---

## 2. 目标 / 非目标

**目标**
- 控制器在 autopilot 运行期写**源码** → 运行时 `deny`（物理拦截，`bypass_permissions` 也拦得住）。
- worker 写码正常放行。
- **绝不影响非 autopilot 的正常编码**（这是硬约束：不能因为装了插件就让日常 Qoder 改代码被拦）。

**非目标（本 MVP 明确不做，留后续增量）**
- Bash 重定向写码旁路（`cat > x.py` / `tee`）门禁。
- git commit/push 的 CR/分支门禁。
- 只读 reviewer subagent、event-log、budget/stuck、TDD 硬门。

---

## 3. 设计：判定逻辑（4 层门，fail-open on error）

新增 `hooks/guard-controller-write.sh`，挂在 PreToolUse `matcher:"Write|Edit|MultiEdit|write|edit|create_file|write_file|search_replace|replace"`。判定顺序：

```
0. trap 'exit 0' ERR    # 脚本内部任何错误 → 放行（fail-open：绝不因 hook bug 卡死宿主）
1. 范围门：cwd 下不存在 autopilot/.run-active(sentinel) → exit 0
   # 不在 autopilot 运行期 = 正常编码，绝不干预
1b. 陈旧门：sentinel 的 mtime 超 AUTOPILOT_RUN_TTL_HOURS(默认12h) → exit 0（崩溃残留，视为不在运行期）
2. worker 放行：AUTOPILOT_ROLE=="worker"（唯一判据，实测可继承）→ exit 0
   # 不再看 permission_mode：bypass 会话（含 bypass 控制器）不因此获写权
3. 白名单放行：写目标匹配任一 → exit 0
     */autopilot/* | autopilot/*        (spec/tasks/progress/knowledge)
     *.md | *.MD | *.markdown           (文档 / prompt 模板，含 /tmp 里的 prompt)
     */.qoder/* | */AGENTS.md           (harness 产物)
   # 注意：不放行 /tmp、$TMPDIR（否则源码可写进 tmp 绕过）
4. 否则（= 控制器在运行期写源码）→ deny：
     输出 hookSpecificOutput{hookEventName,permissionDecision:"deny",reason} + stderr reason + exit 2
     reason: "控制器禁止内联写源码(<path>)；开发一律经 run-track-a.sh 托管 worker。"
```

- 字段取值：`tool_name`/`tool_input.file_path`(缺则回退 `.tool_input.path`)/`cwd` 来自 stdin JSON；`AUTOPILOT_ROLE` 来自 env。内联 `_field`（jq 优先，缺失 sed 兜底，macOS 安全），不依赖外部 `common.sh`。
- **为何要范围门（层 1）**：guard 由 `install.sh` 注册进 `~/.qoder/settings.json`、对**所有** Qoder 会话全局触发；sentinel 把 deny 限定在 autopilot 运行期内，保证日常编码不受影响。
- **失败方向**：层 0/1/1b 任何不确定 → 放行（宁可漏拦，不可误锁正常编码）。deny 只发生在「运行期 + 非 worker + 非白名单」三条件同时成立时。

---

## 4. 变更清单

**新增**
1. `hooks/guard-controller-write.sh`（~35 行）：上述判定逻辑；`source "${QODER_PLUGIN_ROOT}/hooks/common.sh"`（或内联同款 `jq_field`）。
2. `scripts/smoke-guard.sh`（token-free）：构造 stdin JSON 喂 guard，断言退出码；接入 `install.sh` 安装后自检（与 `smoke-dispatch.sh` / `smoke-run-track-a.sh` 并列）。

**改**
3. `scripts/dispatch.sh`：在 `case "$PLATFORM"` 调度前加 `export AUTOPILOT_ROLE=worker`（worker 标记，已验可被 hook 子进程继承）。
4. `install.sh`：**激活入口**——安装后幂等合并一条 PreToolUse guard（`matcher` 含 IDE 别名 + guard **绝对路径**）进 `~/.qoder/settings.json`（jq 合并、非破坏既有 hooks、带时间戳备份、`AUTOPILOT_SKIP_GUARD_INSTALL=1` 可跳过、无 jq 时打印手动指引）；并接入 `smoke-guard` 安装后自检（与 `smoke-dispatch` 并列）。
5. `hooks/hooks-qoder.json`：更新为正确声明式记录（补 `PreToolUse` guard 分组 + 修 `__PLUGIN_HOME__`→`${QODER_PLUGIN_ROOT}`）。**注意**：因本插件以 skills 安装，此文件当前不被自动加载，真正激活靠 install.sh（见 §0.1）。
6. sentinel 生命周期：
   - `skills/using-neil-autopilot/SKILL.md`「初始化流程」：run 开始 `> autopilot/.run-active`（记 epoch+PID+时间戳）。
   - `skills/autopilot-finish/SKILL.md`(Step 6.5) + `skills/autopilot-evolve/SKILL.md`(Step 7.9)：流程结束 `rm -f autopilot/.run-active`（幂等双保险）。
7. 文档一行：`skills/_shared/conventions.md`「控制器不内联写码」处注明「现由 guard（PreToolUse deny）运行时强制，install.sh 激活」。

---

## 5. 测试 / 验收

**A. `smoke-guard.sh`（synthetic stdin，token-free，CI/安装自检）**
| 场景 | 构造 | 期望 |
|------|------|------|
| 运行期控制器写源码 | sentinel 在 + 无 role + `file_path=src/App.java` | `exit 2`（deny）|
| worker 写源码 | `AUTOPILOT_ROLE=worker` + `file_path=src/App.java` | `exit 0` |
| worker（bypass 但无 role）| `permission_mode=bypassPermissions` 无 `AUTOPILOT_ROLE` | `exit 2`（收紧后 bypass 单独不放行）|
| 写 autopilot 产物 | `file_path=autopilot/changes/x/spec.md` | `exit 0` |
| 写 .md | `file_path=README.md` | `exit 0` |
| **非运行期正常编码** | sentinel 不在 + 写源码 | `exit 0`（不误锁）|
| jq 缺失降级 | 同「运行期控制器写源码」但无 jq | `exit 2`（sed 兜底判定正确）|

**B. 真机 end-to-end 验收（实施后跑一次）**
1. 装插件 → 起 autopilot run（sentinel 建立）→ 控制器尝试写源码 **被 deny**。
2. 同 run 内 worker 写码 **放行**、`run-track-a.sh` 正常。
3. finish 后 sentinel 移除 → 新开非 autopilot 会话写源码 **不受影响**。
> 机制已由本 spec §1 探针证实；B 仅回归确认接线无误。

---

## 6. 回滚

删除 `~/.qoder/settings.json` 中由 install.sh 添加的 PreToolUse guard 条目（`command` 指向 `hooks/guard-controller-write.sh` 那条；install.sh 已存 `settings.json.bak-*` 备份可直接还原）即完全停用硬门禁；其余改动（dispatch 的 export、sentinel、hooks-qoder.json 声明、文档）无副作用。改动隔离、可逆。

---

## 7. 假设与已知残余

**假设**
- 控制器不显式跑 `bypass_permissions`。若跑，`permission_mode` 辅判据会误判为 worker；但 `AUTOPILOT_ROLE` 主判据不设=按控制器处理（安全方向），且有范围门兜底。

**已知残余（不在本 MVP，文档标注）**
- Bash 重定向写码 `cat > x.py` / `tee` 可绕过 Write/Edit 门 → 后续加 `matcher:"Bash"` 门。
- 跳阶段 / CR-before-commit / 分支纪律仍为 md 软约束。
- sentinel 陈旧：异常崩溃可能残留 `autopilot/.run-active` → 后续正常编码被误拦。缓解：finish/evolve 负责删除；sentinel 记时间戳，guard 忽略超 N 小时的陈旧 sentinel；并提供人工 `rm` 逃生口。失败方向偏「删 sentinel（漏拦）」而非「误锁」。

---

## 8. 实施顺序（供 plan 阶段拆 Task）

1. 切功能分支 `feature/harden-controller-write-gate`（当前在 master，HARD-GATE #2）。
2. 写 `guard-controller-write.sh` + `smoke-guard.sh` → 本地跑 smoke 全绿。
3. 改 `hooks-qoder.json`（加 PreToolUse + 修 `${QODER_PLUGIN_ROOT}`）+ `dispatch.sh`（export role）。
4. 接 sentinel 生命周期（using-neil-autopilot + finish + evolve）。
5. `install.sh` 接入 smoke-guard 自检。
6. 真机 end-to-end 验收（§5.B）。
7. 文档一行（conventions.md）。
