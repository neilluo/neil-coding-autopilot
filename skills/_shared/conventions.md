# Autopilot 共享约定

> 本文件定义所有 autopilot skill 共享的约定，避免各 skill 重复声明。
> 控制器（using-neil-autopilot）在会话开始时读取本文件。

## 执行档位（见 using-neil-autopilot「执行档位」）

- **档位 A · 批处理**：控制器 spawn 独立 qodercli 进程逐阶段执行，`progress.md` 落盘为状态源，`autopilot-checkpoint` 把关。
- **档位 B · 交互**：控制器在会话内直接执行，**TodoWrite 为单一状态源**，checkpoint 以自查不变量替代，可不写 tasks.md、不 spawn worker。

以下约定除特别标注"（档位 A）"外，两档通用。

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

- **档位 A**：每阶段完成后，控制器调用 `autopilot-checkpoint` 标记 `progress.md`，再调度下一阶段。
- **档位 B**：控制器用 TodoWrite 推进阶段状态，checkpoint 退化为"自查前置不变量"，不强制调 checkpoint-skill。

## 前置验证

- **档位 A**：控制器在调度每个阶段前，已通过 `autopilot-checkpoint` 完成前置验证；各 skill 无需重复验证 progress.md。若 skill 被绕过 checkpoint 直接调用（异常情况），应检查 `$CHANGE_DIR/progress.md` 是否存在，不存在则报错退出。
- **档位 B**：控制器进入每阶段前自查前置不变量（上一阶段产物是否就绪），无需 progress.md。

## qodercli Worker 调度模板（档位 A）

> 仅档位 A 使用。档位 B 由控制器在会话内直接实现，不 spawn worker。

独立进程通过以下模式调度（控制器负责填充 prompt 并执行）：

```bash
# 1. 控制器生成 prompt 文件（填充模板变量）
cat > /tmp/autopilot-{stage}-{task}.md << 'EOF'
[填充后的 prompt 内容]
EOF

# 2. 调度 worker（模型通过环境变量配置，见 AGENTS.md）
qodercli -p "$(cat /tmp/autopilot-{stage}-{task}.md)" \
  --permission-mode bypass_permissions \
  --output-format text 2>&1 | tail -20

# 3. 控制器解析结果中的 Status 行
```

> 注：当前 qodercli 不支持 `--max-turns` / `--model` 等参数；worker 靠任务自然收敛，模型经环境变量选择。如需时长兜底，由控制器侧用 `timeout` 等外部命令包裹，**不要给 qodercli 传它不认识的 flag**（会直接报错）。

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
- `DONE` → （档位 A）调 checkpoint + 下一阶段；（档位 B）TodoWrite 标记完成 + 下一阶段
- `BLOCKED` → 停止流程，通知用户
- `SKIPPED` → 标记 skipped + 下一阶段
