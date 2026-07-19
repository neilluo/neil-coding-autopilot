---
created: 2026-07-19
updated: 2026-07-19
type: concept
source: raw/20260719-observable-acceptance-gate
---

# 可观测验收门（Observable Acceptance Gate）

**一句话**：user-facing 改动的验收，写成**不变量 + 蜕变关系（metamorphic relation）**，不写"期望等于几"的点 oracle——因为作者会把实现口径当期望写进去（test oracle problem），测试便把 bug 又确认一遍。

## 为什么

被 autopilot 开发的项目逃逸过一个 bug：卡片显示"1 个模型"、用户实配 2 个——spec 把显示写成实现口径（"数 `tpm_by_model` 的 key"）而非用户承诺（"配 N 个→显示 N 个"），下游白盒门全信 spec、把 bug 确认一遍。详见 `raw/20260719-observable-acceptance-gate.md`。

## 机制

- **SSOT**：`skills/_shared/observable-acceptance.md`（12 问采集 + 格式 + 判据 + 诚实边界）。各阶段一律"详见本文"，不复制。
- **验收产物**：每个可观测值/态 = SSOT + 不变量 + 蜕变关系；多源值必给**判别样例**（扰动非权威源时期望不同）。
- **验证 = 扰动测试即 Task 的 `**Verify**`**：蹭 `run-track-a.sh` 现成 `eval "$verify"`，无人值守直接拦，不新增控制流。
- **headless reviewer 上牙**：`build_review_prompt` 加「可观测验收」维度（读 spec 验收段 + SSOT，交叉核验 Verify↔MR、UNVERIFIED 正当性）；`CHANGE_DIR` 绝对化保证 review worker 读得到 spec。
- **落点**：HARD-GATE #7（`using-neil`）+ explore/analyze/plan 引用 SSOT。

## 边界（诚实）

- headless 运行期拦截**只覆盖可离线派生层**（如后端计数）。
- **纯像素渲染 / 选错 SSOT** 类缺陷 headless 拦不住 → `UNVERIFIED-OBSERVABLE` 醒目登记转 **Phase 2**（观测 / 独立 QA 层），禁静默放行。

## 相关

- [[delegate-all-development]] — 控制器不内联写码，验收测试由 worker 在 Task 内落地（保 oracle 独立=不变量先于实现冻结）
- [[verify-by-running]] — 载重蹭现有 verify 门（`eval "$verify"`），与 token-free 冒烟同源
