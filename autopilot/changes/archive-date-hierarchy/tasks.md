# Tasks — archive-date-hierarchy

> Global Verify: `for f in scripts/*.sh; do bash -n "$f" || exit 1; done`
> Verify command: `for f in scripts/*.sh; do bash -n "$f" || exit 1; done`
> 设计与验收见同目录 `spec.md`（尤其 §4 接口、§8 可观测验收）。所有脚本改动须 bash 3.2 安全、
> `chmod +x`、`pwd -P` 自定位、无 GNU 工具硬依赖、保持既有幂等/XOR/fail-closed 语义。
> 每个关键机制脚本必须配套 token-free 冒烟测试。

---

## Task 1: 改造 archive-change.sh 为四层结构 + 更新 smoke-archive-change.sh

**Status**: PENDING

**目标**: 把 `scripts/archive-change.sh` 的归档落点从扁平 `archive/YYYY-MM-DD-<name>/`
改为四层 `archive/YYYY/MM/MM-DD/YYYY-MM-DD-<name>/`（叶子名不变），并同步更新其冒烟测试断言。

**要做**:
1. 编辑 `scripts/archive-change.sh`：
   - 在 `DATE_STR` 定稿后（现约 L105 之后）、构造 `TARGET`（现 L107）之前，用 bash 3.2 安全的参数展开从 `DATE_STR`（形如 `YYYY-MM-DD`）切出三段：
     ```sh
     _Y="${DATE_STR%%-*}"      # YYYY
     _R="${DATE_STR#*-}"       # MM-DD
     _M="${_R%%-*}"            # MM
     _D="${_R#*-}"             # DD
     _MMDD="${_M}-${_D}"       # MM-DD
     ```
   - 把 `TARGET="$ARCHIVE_DIR/${DATE_STR}-${CHANGE_NAME}"` 改为
     `TARGET="$ARCHIVE_DIR/${_Y}/${_M}/${_MMDD}/${DATE_STR}-${CHANGE_NAME}"`。
   - 把 `mkdir -p "$ARCHIVE_DIR"`（现 L133）改为 `mkdir -p "$(dirname "$TARGET")"`（确保四层父目录存在，git mv 目标父目录必须先存在）。
   - 更新文件头注释（L2-13）里对落点路径的描述为四层结构。
   - **不得破坏**任何既有不变量：幂等前置检查 `[ -d "$TARGET" ]`、change-dir 存在性 fail-closed、
     summary.md skeleton 生成、git mv 优先 + mv 兜底 + 嵌套守卫、XOR 后置校验、`git add "$TARGET"` 入库。
2. 编辑 `scripts/smoke-archive-change.sh`：把所有断言里的 `autopilot/archive/${DATE_STR}-foo`
   / `${DATE_STR}-${name}` 路径改为四层 `autopilot/archive/<Y>/<M>/<M-D>/${DATE_STR}-<name>`。
   需在测试内同样用参数展开从 `DATE_STR` 切出 `Y/M/MMDD` 再拼断言路径。保持既有场景语义
   （move 落点存在且 changes 消失、summary 存在、幂等再跑、缺 dir fail-closed、summary 入库、#3 嵌套守卫、#1 staged）。

**Verify**: `bash scripts/smoke-archive-change.sh`

---

## Task 2: 新增 migrate-archive-layout.sh（扁平→四层, 幂等, fail-closed）+ 冒烟

**Status**: PENDING

**目标**: 新增确定性迁移脚本，把 `autopilot/archive/` 顶层残留的**扁平** `YYYY-MM-DD-<name>/`
目录 git mv 到四层 `YYYY/MM/MM-DD/YYYY-MM-DD-<name>/`，供一次性迁移存量使用。

**要做**:
1. 新增 `scripts/migrate-archive-layout.sh`（可执行, `chmod +x`, `#!/usr/bin/env bash`, `set -euo pipefail`）：
   - 用法：`migrate-archive-layout.sh [--archive-dir DIR] [--dry-run]`。
   - `--archive-dir` 默认解析：脚本自身 `pwd -P` 定位到 `scripts/` 的上级即 plugin 根，再取 `autopilot/archive`；
     若解析不到则要求显式传入（fail-closed，报错 exit 1）。允许 `--archive-dir` 显式覆盖。
   - 遍历 `--archive-dir` **顶层**条目，只处理**同时满足**的目录：名字匹配 `^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-`
     （即扁平 `YYYY-MM-DD-*`）。纯数字年份目录（如 `2026`）等已嵌套结构**跳过**（保证幂等）。
   - 对每个命中目录：从名字前 10 字符切出 `YYYY-MM-DD` → 派生 `Y/M/MMDD`（同 Task 1 参数展开），
     目标 `<archive-dir>/Y/M/MMDD/<原名>`。若目标已存在则跳过（幂等）；否则 `mkdir -p "$(dirname 目标)"`
     后 `git mv`（在 repo 内）优先、`mv` 兜底（兜底前 `[ -e 目标 ]` 守卫拒嵌套，fail-closed）。
   - `--dry-run`：只打印将执行的迁移（`FROM -> TO`），不实际移动，exit 0。
   - 每完成一个打印 `migrated: <原名> -> Y/M/MMDD/<原名>`；全程 fail-closed（任何 mv 失败 exit 1）。
2. 新增 `scripts/smoke-migrate-archive-layout.sh`（可执行, token-free）：
   - 在 `mktemp -d` 造临时 git repo，植入 2 个扁平 `2026-07-18-foo` / `2026-07-19-bar` + 1 个已嵌套
     `2026/07/07-19/2026-07-19-baz`，跑脚本；断言：foo→`2026/07/07-18/2026-07-18-foo`、
     bar→`2026/07/07-19/2026-07-19-bar` 均到位且顶层扁平消失、baz 原样不动（幂等跳过）；
     再跑一次断言零变更（幂等）；`--dry-run` 断言不改动文件系统。判别性：任一断言不满足 `exit 1`。
   - 临时目录用后清理。

**Verify**: `bash scripts/smoke-migrate-archive-layout.sh`

---

## Task 3: 同步文档 + SCHEMA 到四层结构

**Status**: PENDING

**目标**: 把仓库内所有把 archive 描述为**当前**扁平 `YYYY-MM-DD-<feature>` 的文档/规则更新为四层，
避免文档与实现漂移。

**要做**:
1. `skills/using-neil-autopilot/SKILL.md`：目录结构块里 `archive/` 下的
   `YYYY-MM-DD-<feature>/` 示例改为四层 `YYYY/MM/MM-DD/YYYY-MM-DD-<feature>/`（含注释说明年/月/月-日三层 + 原名叶子）。
2. `skills/autopilot-evolve/SKILL.md`：第 5 类来源"完成变更"里"读 `autopilot/archive/` 下对应日期目录"
   的散文，更新为四层路径描述（`autopilot/archive/YYYY/MM/MM-DD/YYYY-MM-DD-<name>/`）。
3. `autopilot/knowledge/SCHEMA.md`：找到归档命名相关的约束（C7/C8 附近）更新为四层结构不变量；
   新增或更新一条不变量登记 `migrate-archive-layout.sh` 的存在与幂等契约（若 SCHEMA 用 C 编号则续号，如 C15）。
4. `skills/_shared/conventions.md`：`$ARCHIVE_DIR` 行补注"叶子按 `YYYY/MM/MM-DD/` 三层组织"（根目录 `autopilot/archive` 不变）。
5. 不改任何 `.sh`（本 Task 纯文档）。

**Verify**: `test $(grep -rlE "archive/[0-9]{4}-[0-9]{2}-[0-9]{2}-<?feature" skills autopilot/knowledge/SCHEMA.md 2>/dev/null | wc -l) -eq 0 && grep -q "MM-DD" skills/using-neil-autopilot/SKILL.md`
