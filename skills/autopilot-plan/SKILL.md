---
name: autopilot-plan
description: "Task拆解与Plan编写。读取Spec，拆解为原子级Task列表，写入tasks.md落盘追踪。"
---

# Autopilot Plan — Task 拆解

将 Spec 转化为可逐个执行的原子 Task 列表，每个 Task 是一个 worker 能独立完成的最小单元。

**宣告**: "正在使用 autopilot-plan 进行任务拆解。"

## 前置检查（自动执行）

执行本 skill 前，必须确认：
1. `.autopilot/progress.md` 存在
2. 本阶段的前置阶段已标记 `[x]`：analyze 必须已完成

如果前置未满足，立即停止并提示需要先执行哪个阶段。

## 输入

- `SPEC.md` 文件路径（必须已存在）
- 项目技术栈信息（从 AGENTS.md 或 pom.xml/package.json）

## Process

### Step 1: 读取 Spec

```bash
cat SPEC.md   # 完整读取，不截断
```

### Step 2: 确定构建验证命令

自动检测：
- 有 `pom.xml` → `mvn compile -q`
- 有 `package.json` → `npm run build` 或 `npx tsc --noEmit`
- 有 `build.gradle` → `gradle build -q`
- 有 `go.mod` → `go build ./...`

### Step 3: 拆解 Tasks

**拆解原则**:
- 每个 Task 产出可编译的代码增量
- Task 之间有明确依赖顺序
- 每个 Task 描述**自包含**（worker 无需读其他 Task 即可执行）
- 粒度参考：一个模块/一组紧密相关的类/一个 API endpoint
- 每个 Task 2-5 分钟（AI执行时间）

**Task 描述必须包含**:
1. 要创建/修改的文件路径
2. 具体的实现要求（接口签名、方法逻辑）
3. 依赖的前置 Task（如有）
4. 验证方式（编译通过 / 测试通过 / curl 验证）

### Step 4: 写入 tasks.md

**文件位置**: 项目根目录 `tasks.md`

**格式**:

```markdown
# Implementation Tasks

> Auto-generated from SPEC.md by autopilot-plan
> Verify command: `mvn compile -q`
> Total tasks: N

## Task 1: [名称]

**Branch**: `task/01-xxx`
**Depends**: none | Task N, Task M
**Gate**: auto | human
**Files**:
- Create: `path/to/File.java`
- Create: `path/to/AnotherFile.java`

**Description**:
[完整的、自包含的任务描述，包含所有实现细节]

**Verify**: `mvn compile -q` exit 0
**Runtime Verify**: `curl -sf http://localhost:8080/health`（可选，需要运行时验证时填写）

**Status**: PENDING

---

## Task 2: [名称]
...
```

### Step 5: 创建工作分支

```bash
git checkout -b autopilot/feature-name
```

### Step 6: 输出

- 状态: `PLAN_STATUS=DONE`
- 产物: `tasks.md` 已写入项目根目录
- 汇总: "共拆解 N 个 Task，预计 AI 执行时间 X 小时"

## 约束

- 第一个 Task 必须是项目骨架/依赖配置（确保后续 Task 有编译环境）
- 每个 Task 的 Description 不超过 500 字
- Task 总数建议 8-20 个（太少=粒度太粗，太多=碎片化）
- 不把测试单独拆为 Task（测试和实现在同一个 Task 里）
- 无前置依赖的 Task 标记 `Depends: none`，允许并行执行
- 涉及以下场景的 Task 自动标记 `Gate: human`：
  - 数据库 Schema 变更
  - 认证/权限逻辑
  - CI/CD 配置修改
  - 外部 API/第三方服务集成
  - 删除操作

## 强制后继（MANDATORY NEXT STEP）

本阶段完成后：
1. 调用 autopilot-checkpoint 标记 plan 完成
2. 必须立即调用 `Skill("autopilot-loop")`

不调用后继 = 流程中断，工作视为未完成。
