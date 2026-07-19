# Implementation Tasks — telemetry-pluggable-sink

> Auto-generated from spec.md by autopilot-plan
> Verify (per-task **Verify** line): smoke-telemetry + smoke-dispatch + smoke-run-track-a（token-free 门禁，控制器自跑）
> Total tasks: 1 ｜ 权威依据：本目录 `spec.md`（worker 必读 §3/§5）

## Task 1: telemetry.sh sink 可插拔化 + smoke 用例 + 文档

**Branch**: `feature/telemetry-pluggable-sink`
**Depends**: none
**Gate**: auto
**Verify**: `bash scripts/smoke-telemetry.sh && bash scripts/smoke-dispatch.sh && bash scripts/smoke-run-track-a.sh`
**Files**:
- Modify: `scripts/telemetry.sh`
- Modify: `scripts/smoke-telemetry.sh`
- Modify: `README.md`
- Modify: `AGENTS.md`
- Modify: `autopilot/knowledge/wiki/entities/telemetry-system.md`

**Description**:
读 `autopilot/changes/telemetry-pluggable-sink/spec.md` §3（设计，权威）+ §5（验证）+ `explore-notes.md`（不变量）。

1. **`scripts/telemetry.sh`**：
   - 新增 `_telemetry_is_function()`：`[ "$(type -t "${1:-}" 2>/dev/null)" = "function" ]`。
   - 新增 `_telemetry_sink_dispatch()`：按 `${NEIL_AUTOPILOT_LOG_SINK:-file}` 组 `fn="_telemetry_sink_${sink}"`；`_telemetry_is_function "$fn"` 为真则 `"$fn" "$json"`，否则回退 `_telemetry_sink_file "$json"`。**绝不 eval**。
   - 新增 `_telemetry_sink_file()`：把现 `telemetry_emit` 内的 `root=$(telemetry_log_root)` + `printf '%s\n' "$json" >> "$root/runs/$(date +%F).jsonl"` 原样搬入。
   - 重构 `telemetry_emit()`：外层 `{ … } 2>/dev/null || true` + `return 0` 保持不变，内部改为 `_telemetry_sink_dispatch "$json"`。
   - 文件头补 sink seam 注释（如何加 `_telemetry_sink_<name>`；不新增 stdout sink 的原因）。
   - **不改** `telemetry_rotate` / `telemetry_log_root` / `telemetry_json_escape` / `telemetry_enabled` / 所有 `telemetry_emit_*` 事件构造器。

2. **`scripts/smoke-telemetry.sh`**：新增两个 scenario（沿用现有 fail/pass 风格与 `$WORK` 临时目录）：
   - **scenario 5（seam 可插拔）**：子 shell 内 source 后定义 `_telemetry_sink_capture(){ printf '%s\n' "${1:-}" >> "$root/captured"; }`，`export NEIL_AUTOPILOT_LOG_SINK=capture`，调 `telemetry_emit_run ...`；断言 `$root/captured` 有该行 **且** `$root/runs/$(date +%F).jsonl` **未**被创建。
   - **scenario 6（未知 sink 兜底 + stdout 洁净）**：`export NEIL_AUTOPILOT_LOG_SINK=bogus`，emit；断言回退到 file（`runs/*.jsonl` 存在且 `jq -e .` 通过）、捕获的 stdout 为空。
   - 保证既有 scenario 1–4 不动、仍全过。

3. **文档**：
   - `README.md` 环境变量表加 `NEIL_AUTOPILOT_LOG_SINK`（默认 `file`；一句"云端保险/未来加 OSS/SLS 后端的扩展点"）。
   - `AGENTS.md` 环境变量处补 `NEIL_AUTOPILOT_LOG_SINK`（**保持 ≤150 行**）。
   - `autopilot/knowledge/wiki/entities/telemetry-system.md` 记录 sink 可插拔 seam + out-of-scope 边界（写侧 only）。

**完成前必须自行跑通（token-free）**：
- `bash scripts/smoke-telemetry.sh` → SMOKE: ALL PASS（含新 scenario 5/6）
- `bash scripts/smoke-dispatch.sh` → ALL PASS（回归，source telemetry.sh）
- `bash scripts/smoke-run-track-a.sh` → ALL PASS（回归）
- `bash -n scripts/telemetry.sh && bash -n scripts/smoke-telemetry.sh`
- `grep -q NEIL_AUTOPILOT_LOG_SINK README.md AGENTS.md`

**Status**: DONE
