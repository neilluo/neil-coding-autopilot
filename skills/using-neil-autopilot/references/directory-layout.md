何时读我：需要创建、定位或解释 autopilot 产物目录及 archive 四层结构时。

## 目录结构

autopilot 的所有产物统一管理在项目根目录的 `autopilot/` 下（**完整形态**如下；实际**按需生长**，`autopilot-init` 不预建空目录 / 空状态机文件）：

```
autopilot/
├── changes/                      # 活跃的开发变更（每次 run 一个文件夹）
│   └── <feature-name>/           # 如 add-user-registration/
│       ├── spec.md               # 本次变更的技术方案
│       ├── tasks.md              # Task 拆解（两档都产，run-track-a.sh 输入；小 spec 可 1 Task）
│       ├── progress.md           # 工作流状态（档位 A）
│       └── explore-notes.md      # 澄清阶段的对话记录摘要
│
├── archive/                      # 已完成的历史变更（四层：YYYY/MM/MM-DD + 原扁平名叶子）
│   └── YYYY/                     # 年，如 2026/
│       └── MM/                   # 月，如 07/
│           └── MM-DD/            # 月-日，如 07-06/
│               └── YYYY-MM-DD-<feature>/  # 原扁平名叶子，如 2026-07-06-video-distributor/
│                   ├── spec.md
│                   ├── tasks.md
│                   └── summary.md         # 完成摘要
│
├── knowledge/                    # Karpathy LLM Wiki 三层知识库
│   ├── SCHEMA.md                 # 维护规则 + 项目元数据（≤200行）
│   ├── raw/                      # Layer 1: 不可变源（CR/踩坑/代码快照）
│   ├── wiki/                     # Layer 2: LLM 编译产物（index + entities/concepts/guides/comparisons）
│   └── references/               # 静态框架性内容
│
└── hooks/                        # 质量门禁（Feedback/Sensor Layer）
    ├── post-edit.sh              # 变更后自动检查
    ├── build-gate.sh             # 编译验证
    └── pre-completion.md         # 完成前自检清单
```
