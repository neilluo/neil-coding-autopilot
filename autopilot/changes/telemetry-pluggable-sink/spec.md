# Spec — telemetry-pluggable-sink（存储写入 sink 可插拔化 · 云端保险）

> 变更目录：`autopilot/changes/telemetry-pluggable-sink/` ｜ 分支：`feature/telemetry-pluggable-sink` ｜ 类型：feature（dogfooding）
> 输入依据：`explore-notes.md`（已锁定决策）+ `scripts/telemetry.sh`（现状）+ `autopilot/knowledge/SCHEMA.md`（C1–C12）。

## 1. 概述与用户故事

把 `telemetry.sh` 的**存储写入**从"硬编码写本地文件"抽象成**可插拔 sink**：由 env `NEIL_AUTOPILOT_LOG_SINK` 选择后端，默认 `file`、**行为与现在完全一致**。目的是为"autopilot 编排器将来上云（形态未定）"买一份**形态无关的保险**——将来换 OSS/SLS 等云后端时，只需新增一个后端函数，**采集调用点零改动**。

**用户故事**：作为维护者，等我把 autopilot 放上云时，不想回头重写采集层；现在花很小代价留好接缝，届时"加一个 sink 函数 + 设一个 env"即可切换存储去向。

## 2. 范围

**In scope**：`telemetry.sh` 的 JSONL 写入 sink 化 + `smoke-telemetry.sh` 用例 + 文档（README/AGENTS/entity）。
**Out of scope（本 spec 显式不做）**：真实云后端（oss/sls）实现、调度器上云、`daily-analysis.sh` 读侧、`run-track-a.sh` 完整输出复制路径、凭证/ git 身份/时区治理。这些延迟到真正部署时的后续变更。

## 3. 设计

### 3.1 新增环境变量

| 变量 | 默认 | 说明 |
|------|------|------|
| `NEIL_AUTOPILOT_LOG_SINK` | `file` | 选择 `telemetry_emit` 的写入后端。当前仅实现 `file`；未识别值**兜底回退到 `file`**（fail-safe，不静默丢日志）。 |

（`NEIL_AUTOPILOT_LOG_DIR` / `NEIL_AUTOPILOT_TELEMETRY` / `NEIL_AUTOPILOT_KEEP_DAYS` 语义不变。）

### 3.2 唯一写入点路由（核心改动）

现状：`telemetry_emit` 内部直接 `printf '%s\n' "$json" >> "$root/runs/$(date +%F).jsonl"`（telemetry.sh:87）。所有事件构造器都汇入此函数——**它是唯一写入点**。

改为：`telemetry_emit` 调用 `_telemetry_sink_dispatch "$json"`，由分发器按 env 选后端：

```bash
# 重构后（保持外层 fail-safe 包裹与 return 0 不变）
telemetry_emit() {
  local json="${1:-}"
  { if telemetry_enabled && [ -n "$json" ]; then _telemetry_sink_dispatch "$json"; fi; } 2>/dev/null || true
  return 0
}

_telemetry_is_function() { [ "$(type -t "${1:-}" 2>/dev/null)" = "function" ]; }

_telemetry_sink_dispatch() {
  local json="${1:-}" sink="${NEIL_AUTOPILOT_LOG_SINK:-file}" fn=""
  fn="_telemetry_sink_${sink}"
  if _telemetry_is_function "$fn"; then "$fn" "$json"; else _telemetry_sink_file "$json"; fi
  return 0
}

# 现逻辑原样抽出为默认后端
_telemetry_sink_file() {
  local json="${1:-}" root=""
  root="$(telemetry_log_root)"
  if [ -n "$root" ]; then printf '%s\n' "$json" >> "$root/runs/$(date +%F).jsonl"; fi
  return 0
}
```

### 3.3 扩展 seam（如何加云后端 · 现在只写文档不实现）

在 `telemetry.sh` 里定义一个 `_telemetry_sink_<name>()` 函数（fail-safe、绝不写 stdout），再设 `NEIL_AUTOPILOT_LOG_SINK=<name>` 即可——分发器**按函数名自动发现**，核心分发逻辑无需改动。示例（文档中给出，不落地）：`_telemetry_sink_oss()` 用 ossutil/SDK 追加；`_telemetry_sink_sls()` 调日志服务。

### 3.4 保留与不变

- `telemetry_rotate` **不变**：它是 `file` 后端的本地留存策略；云后端的留存由其自身机制（如 bucket 生命周期 / 日志服务 TTL）负责——文档注明。
- `telemetry_log_root` 的 CWD 安全护栏（C12）、JSON 转义、`telemetry_enabled` 开关、所有事件构造器**全部不变**。
- **不新增 `stdout` sink**（见 explore-notes 不变量：会破坏 in-worker stdout 契约）。

## 4. 变更文件

| 文件 | 动作 |
|------|------|
| `scripts/telemetry.sh` | 改：加 `_telemetry_is_function` / `_telemetry_sink_dispatch` / `_telemetry_sink_file`；重构 `telemetry_emit` 走分发；文件头补 sink seam 注释。 |
| `scripts/smoke-telemetry.sh` | 改：新增 scenario 5（自定义后端 seam）+ scenario 6（未知 sink 兜底 + stdout 洁净）。 |
| `README.md` | 改：环境变量表加 `NEIL_AUTOPILOT_LOG_SINK` + 一句"云端保险/扩展点"。 |
| `AGENTS.md` | 改：平台配置/环境变量处补 `NEIL_AUTOPILOT_LOG_SINK`（保持 ≤150 行）。 |
| `autopilot/knowledge/wiki/entities/telemetry-system.md` | 改：记录 sink 可插拔 seam 与 out-of-scope 边界。 |

## 5. 验证（token-free，verify-by-running · C7）

1. **`bash scripts/smoke-telemetry.sh` → ALL PASS**，含新用例：
   - **scenario 5（seam 可插拔）**：source 后在测试里定义 `_telemetry_sink_capture(){ printf '%s\n' "$1" >> "$WORK/captured"; }`，设 `NEIL_AUTOPILOT_LOG_SINK=capture` 后 emit；断言 `$WORK/captured` 收到该行**且** `runs/*.jsonl` 未被创建（证明分发去了自定义后端而非 file）。
   - **scenario 6（未知 sink 兜底 + stdout 洁净）**：`NEIL_AUTOPILOT_LOG_SINK=bogus` 下 emit；断言回退到 file（`runs/*.jsonl` 有效 JSON 行）、stdout 为空、调用方（`set -e` 子 shell）未中止。
   - 既有 scenario 1–4 保持全过（默认=file 行为不回归）。
2. **回归**：`bash scripts/smoke-dispatch.sh` + `bash scripts/smoke-run-track-a.sh` ALL PASS（二者 source telemetry.sh，确保重构不破坏运行时）。
3. **语法**：`bash -n scripts/telemetry.sh && bash -n scripts/smoke-telemetry.sh`。
4. **文档断言**：`grep -q NEIL_AUTOPILOT_LOG_SINK README.md AGENTS.md`。

## 6. 约束对齐（C1–C12 相关项）

| 约束 | 对齐 |
|------|------|
| C6 shell 可移植 | `type -t` 判函数为 bash 3.2 内建、两平台安全；不引入新外部依赖；纯 bash。 |
| C7 verify-by-running | 全靠 smoke 实跑断言，不靠"读着对"。 |
| C8 不硬编码 home/user | 仅经 env + `telemetry_log_root`，无新增硬编码路径。 |
| C12 自主提交防污染 | CWD 护栏不变；不新增会落在 CWD 内的写路径。 |
| fail-safe / stdout 契约 | 外层 `{…} 2>/dev/null || true` + `return 0` 不变；新 sink 函数同契约；不加 stdout sink。 |

## 7. 决策记录

- **未知 sink → 回退 file**（非 no-op）：避免打错一个字就静默丢全部遥测；同时不阻断、不报错（fail-safe）。
- **按函数名自动发现**（而非维护一张注册表）：加后端=加一个函数，分发器永不改动——最小化未来改动面。
- **只做写侧**：读侧（daily-analysis）与真实云后端一起延迟，避免本次范围膨胀（YAGNI）。
