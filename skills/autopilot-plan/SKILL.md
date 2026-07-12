---
name: autopilot-plan
description: "Task拆解与Plan编写。读取Spec，拆解为原子级Task列表，写入tasks.md落盘追踪。"
---

# Autopilot Plan — Task 拆解

将 Spec 转化为可逐个执行的原子 Task 列表，每个 Task 是一个 worker 能独立完成的最小单元。

**宣告**: "正在使用 autopilot-plan 进行任务拆解。"

## 输入

- `$CHANGE_DIR/spec.md`（必须已存在，bugfix 模式为轻量版 spec）
- 项目技术栈信息（从 AGENTS.md 或 pom.xml/package.json）
- `$KNOWLEDGE_DIR/SCHEMA.md` 中的 Per-Stage Rules / tasks 规则
- `$KNOWLEDGE_DIR/wiki/guides/` 中与 Task 拆解相关的规则页

## Process

### Step 1: 读取 Spec

```bash
cat $CHANGE_DIR/spec.md   # 完整读取，不截断
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

### Step 4: 写入 tasks.md（两档都产 —— run-track-a.sh 的输入）

> `tasks.md` 是 `run-track-a.sh` 的必需输入，**两档都要产**（开发一律托管，见 conventions 档位适配表）。TodoWrite 仅供档位 B 追踪**阶段级**进度，不替代 Task 列表。

**粒度按 spec 大小（关键）**：
- **小 spec（单文件 / 一处改动）→ 1 个 Task**：Task 1 直接指向 spec（`实现 spec.md 的全部内容`），近零拆解仪式，run-track-a.sh 循环一次即可。
- **大 spec（多模块 / 多文件）→ 拆 N 个 Task**：按下方拆解原则分解，换取粒度化 CR（小 diff）、逐 Task commit、`--resume` 续跑、worker context 卫生。

**文件位置**: `$CHANGE_DIR/tasks.md`

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

### Step 5: 确认工作分支

分支已在 init / 实现前的分支纪律门切好（`<type>/<feature-name>`，见 `_shared/conventions.md`「分支纪律」）；plan 阶段只需确认当前不在 main/master，无需再切。

### Step 6: 输出

- 状态: `PLAN_STATUS=DONE`
- 产物: `$CHANGE_DIR/tasks.md` 已写入
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
