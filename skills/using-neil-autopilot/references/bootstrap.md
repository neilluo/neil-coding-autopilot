何时读我：开始一次变更、创建分支/哨兵/progress.md，或处理旧目录兼容时。

## 初始化流程

执行任何阶段前，先切功能分支、再建立变更目录：

```bash
FEATURE_NAME="<feature-name>"   # 从需求提取的 kebab-case 标识
TYPE="fix"                      # 任务类型 → feature | fix | refactor（见「任务类型分流」）

# 分支纪律（HARD-GATE #2）：禁止在主干直接改；当前在 main/master 则先切功能分支
CUR="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
case "$CUR" in
  main|master) git checkout -b "${TYPE}/${FEATURE_NAME}" ;;
  *) echo "已在功能分支 $CUR，继续" ;;
esac

mkdir -p autopilot/changes/${FEATURE_NAME}

# 运行期哨兵：激活「控制器写码硬门禁」(hooks/guard-controller-write.sh 仅在此哨兵存在时 deny)。
# 记录 epoch + PID 便于排障；由 finish/evolve 结束时移除。异常残留超 12h 视为陈旧，guard 自动忽略，
# 避免误锁日常编码（人工可随时 rm -f autopilot/.run-active 逃生）。
mkdir -p autopilot
{ date +%s; echo "pid=$$"; echo "started=$(date '+%Y-%m-%d %H:%M:%S')"; } > autopilot/.run-active

# 哨兵是瞬时运行态、非交付物：确保被 .gitignore 排除，否则 run-track-a.sh 的
# `git add -A`（逐 Task 提交）会把它卷进被开发项目的提交历史。幂等追加。
grep -qxF 'autopilot/.run-active' .gitignore 2>/dev/null || printf '%s\n' 'autopilot/.run-active' >> .gitignore
```

- **档位 A**：写 `progress.md`（下方模板）作为落盘状态源。
- **档位 B**：以 TodoWrite 为状态源；`progress.md` 可选。

知识库（`autopilot/knowledge/**`）与 hooks 目录**不在此处预建空目录**——由 `autopilot-init` 按需生长（缺什么建什么），避免留下空壳。

progress.md 模板（档位 A / 需要落盘时）：

```bash
cat > autopilot/changes/${FEATURE_NAME}/progress.md << 'EOF'
# Autopilot Progress

> Auto-maintained by autopilot workflow. Do not edit manually.
> Feature: [feature name]
> Branch: [branch name]
> Started: YYYY-MM-DD HH:mm

- [ ] init
- [ ] explore
- [ ] analyze
- [ ] plan
- [ ] loop
- [ ] finish
- [ ] evolve
EOF
```

替换 `[feature name]`、`[branch name]`、`YYYY-MM-DD HH:mm` 为实际值。

**向下兼容**：如果项目根目录存在旧的 SPEC.md/tasks.md/.autopilot/，首次运行时提示用户归档到 `autopilot/archive/`。
