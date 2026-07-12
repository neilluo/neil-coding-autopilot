---
created: 2026-07-12
source: evolve/harden-bash-write-gate
evidence: primary
---

# 封堵 shell 重定向写源码旁路（Bash 门）+ 一个"钩子必须可执行"的硬坑

## 背景
spec §7 列的第 1 号残留：`guard-controller-write.sh` 只拦文件写工具（Write/Edit/…），
控制器仍可用 `cat > x.py` / `echo >> x.go` / `tee x.java` 经 shell 绕过。为增强
"控制器运行期绝不写源码"这条铁律的可信度，新增 `hooks/guard-bash-write.sh`
（PreToolUse matcher=Bash），复用同款 4+1 层（trap/scope/stale/worker/whitelist），
第 4 层用保守正则抽取 `>`/`>>`/`tee`/`dd of=` 的目标，仅当目标是**已知源码扩展名**
且不在白名单（.md / autopilot/ / .qoder/ / /dev/*）时 deny，其余一律 fail-open。

## 发现的硬坑（关键教训）
真机 e2e 第一次跑：控制器用 shell 写 `src/App.java` **未被拦**（created=yes）。
逐层排查（systematic debugging）：
1. 用真机 dump 探针确认 shell 工具契约：`tool_name="Bash"`、`tool_input.command` 存在、
   `cwd` 为 `/private/var/...`（macOS 符号链接）——与我的假设一致。
2. 把**真实命令**喂给 guard：**正确 deny（exit 2）**——逻辑没问题。
3. 用 wrapper（我 chmod +x 过、内部 `bash "$GUARD"` 调用）注册 → **拦住了**。
4. 直接注册 `guard-bash-write.sh` → **拦不住**。差异只有一处：
   **guard-bash-write.sh 不可执行**（`-rw-r--r--`；Write 工具建的文件不带 +x）。
   → **qodercli 对不可执行的 hook 命令静默跳过（fail-open），不报错。**
`chmod +x` 后直接注册即拦住。

## 修复与验证
- `chmod +x hooks/guard-bash-write.sh`；`install.sh` 新增 `chmod +x` 两个 guard，
  并把 Bash 门作为第二条 PreToolUse 注册进 `~/.qoder/settings.json`（幂等），
  安装后自检加跑 `smoke-bash-guard.sh`。
- `scripts/smoke-bash-guard.sh`（token-free）14 例全过：拦 `cat>src.py`/`tee .go`/`>>.py`；
  放行 git/verify `>/tmp/*.log`/`>/dev/null`/`>output.txt`/autopilot/md/worker/无哨兵。
- 真机 `bash-gate-e2e.sh` 4 例全过：控制器 shell 写源码→**blocked**（guard_denied=yes）；
  worker→created；控制器 shell 写 .md→created；无哨兵→created。

## Lesson
- **钩子脚本必须 `chmod +x`，否则 Qoder 静默跳过（fail-open）**——用 Write 工具新建的
  hook 一定要补 +x，install.sh 也要兜底 chmod。这是"装了却没生效"的隐形失败。
- 合成 smoke 只验证"我以为的契约"；**真机 e2e + dump 探针**才暴露真实失败（本例的 +x）。
- Bash 门保守 fail-open：只拦已知源码扩展名的重定向，绝不误伤 git/verify/日志等编排 shell。
- 残留（文档标注、非本轮）：`python -c 'open(...,"w")'` 之类非重定向写法仍可绕过；
  跳阶段 / 分支纪律仍为软约束。
