# Autopilot 共享约定

> 本文件定义所有 autopilot skill 共享的约定，避免各 skill 重复声明。
> 控制器（using-neil-autopilot）在会话开始时读取本文件。

## 路径约定

| 变量 | 含义 | 示例 |
|------|------|------|
| $CHANGE_DIR | 当前变更目录 | autopilot/changes/video-distributor |
| $KNOWLEDGE_DIR | 知识库目录 | autopilot/knowledge |
| $HOOKS_DIR | 质量门禁目录 | autopilot/hooks |
| $ARCHIVE_DIR | 归档目录 | autopilot/archive |

## 工作流路由

**控制器全权负责阶段路由**。各 skill 只需完成自身任务并报告状态，不负责调度下一阶段。

流程顺序（由控制器按 `using-neil-autopilot` 流程图执行）：
```
init → explore → analyze → plan → loop → finish → evolve
```

每个阶段完成后，控制器自动调用 `autopilot-checkpoint` 标记完成，再调度下一阶段。

## 前置验证

**控制器在调度每个阶段前，已通过 `autopilot-checkpoint` 完成前置验证。**

各 skill 无需重复验证 progress.md 状态。如果 skill 被绕过 checkpoint 直接调用（异常情况），skill 应检查 `$CHANGE_DIR/progress.md` 是否存在，不存在则报错退出。

## qodercli Worker 调度模板

独立进程通过以下模式调度（控制器负责填充 prompt 并执行）：

```bash
# 1. 控制器生成 prompt 文件（填充模板变量）
cat > /tmp/autopilot-{stage}-{task}.md << 'EOF'
[填充后的 prompt 内容]
EOF

# 2. 调度 worker（模型通过环境变量配置，见 AGENTS.md）
qodercli -p "$(cat /tmp/autopilot-{stage}-{task}.md)" \
  --permission-mode bypass_permissions \
  --max-turns 30 \
  --output-format text 2>&1 | tail -20

# 3. 控制器解析结果中的 Status 行
```

**模型配置**（通过环境变量，当前 qodercli 不支持 `--model` 参数）：

| 环境变量 | 角色 | 默认值 |
|---------|------|--------|
| AUTOPILOT_IMPLEMENTER_MODEL | 编码型 worker | Performance |
| AUTOPILOT_REVIEWER_MODEL | 审查型 worker | Ultimate |
| AUTOPILOT_FIXER_MODEL | 修复型 worker | Performance |
| AUTOPILOT_ANALYZE_MODEL | 需求分析 | Ultimate |
| AUTOPILOT_PLAN_MODEL | Task 拆解 | Ultimate |
| AUTOPILOT_INIT_MODEL | 初始化 | Performance |
| AUTOPILOT_EVOLVE_MODEL | 知识沉淀 | Ultimate |

## 状态报告约定

每个 skill/worker 完成后必须在输出中包含状态行：

```
{STAGE}_STATUS=DONE | BLOCKED|{原因} | SKIPPED
```

控制器根据状态决定后续行为：
- `DONE` → 调 checkpoint + 下一阶段
- `BLOCKED` → 停止流程，通知用户
- `SKIPPED` → 调 checkpoint（标记 skipped）+ 下一阶段
