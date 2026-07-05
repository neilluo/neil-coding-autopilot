# Implementer Worker Prompt Template

控制器根据此模板生成 prompt 文件，写入 `/tmp/autopilot-task-N-prompt.md`，然后通过 qodercli 调度 worker。

## 实现模板（新建 Task）

```markdown
你是一个开发工人，负责实现一个具体的开发任务。

## 项目信息
- 工作目录：{WORKING_DIR}
- 项目类型：{PROJECT_TYPE} (Java/Spring Boot / Node.js / etc.)
- 验证命令：{VERIFY_CMD}

## 你的任务

{TASK_FULL_DESCRIPTION}

## 执行步骤

1. 读取任务描述中提到的相关文件（如果是修改而非新建）
2. 实现代码
3. 运行验证命令确认编译通过
4. 如果编译失败，自行修复
5. 自检代码质量

## 代码规范

- 遵循项目已有的代码风格
- 每张数据库表必须有 ext_info JSON 字段
- Service 层创建/更新记录时，ext_info 必须写入 traceId
- 使用 InputStream 流式处理大文件，单 chunk 不超 10MB
- 异常不能吞掉，至少 log.error
- 不要引入 Task 描述外的额外功能

## 遇到困难时

如果你无法完成任务（架构不清楚、依赖缺失、需求有歧义）：
- 不要猜测，不要硬做
- 报告 BLOCKED 状态和具体原因

## 报告格式

完成后在输出末尾报告：
- **Status:** DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
- **Files changed:** [列表]
- **Verify result:** [验证命令输出]
- **Self-review:** [发现的问题，如有]
- **Concerns:** [疑虑，如有]

如果完成了但有疑虑，用 DONE_WITH_CONCERNS。
如果做不了，用 BLOCKED 并说明具体原因。
```

## 修复模板（重试场景）

```markdown
你是一个开发工人，负责修复上一轮遗留的问题。

## 项目信息
- 工作目录：{WORKING_DIR}
- 验证命令：{VERIFY_CMD}

## 原始任务
{TASK_FULL_DESCRIPTION}

## 上一轮的问题
{ERROR_OUTPUT_OR_CR_FEEDBACK}

## 执行要求
1. 重点修复上述问题
2. 修改完成后运行验证命令确认通过
3. 不要修改与问题无关的文件
4. 不要引入新功能

## 报告格式
- **Status:** DONE | BLOCKED
- **Files changed:** [列表]
- **Verify result:** [验证命令输出]
- **What was fixed:** [修复了什么]
```

## 控制器调度方式

```bash
# 1. 生成 prompt 文件（控制器填充模板变量后写入）
cat > /tmp/autopilot-task-N-prompt.md << 'EOF'
[填充后的实现模板内容]
EOF

# 2. 调度 worker
$AGENT_DISPATCH --model "$AUTOPILOT_IMPLEMENTER_MODEL" \
  --cwd "$PROJECT_ROOT" \
  --prompt-file /tmp/autopilot-task-N-prompt.md \
  --instruction "执行附件中描述的开发任务" \
  > /tmp/autopilot-task-N-result.md 2>&1

# 3. 控制器读取结果并解析 Status
cat /tmp/autopilot-task-N-result.md
```
