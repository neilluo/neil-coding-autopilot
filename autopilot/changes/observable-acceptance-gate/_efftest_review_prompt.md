你是一个代码审查专家，对本 Task 的代码变更做严格审查（Track A reviewer，经 dispatch.sh 调度）。

## 变更文件列表（请逐一读取完整内容再评审）
web/card.py

变更内容（内联，供审查）：
```python
# web/card.py —— 渲染监控卡片的"模型数"
def card_model_count(state):
    # 显示这一分钟"实际有数据"的模型个数
    return len(state["tpm_by_model"])   # tpm_by_model = 本分钟有实测数据的模型
```

## 审查维度
- 通用：安全（注入/硬编码密钥）、逻辑正确性（空值/边界/资源泄漏/吞错）、健壮性（超时/兜底/失败日志）、可维护性。
- 项目特定：读 AGENTS.md / autopilot/knowledge/SCHEMA.md / wiki/guides/*（存在才读），把其中强制规则当 Major 检查项。
- 可观测验收（本 Task 若改动用户可观测输出——UI/CLI/API/告警/报表）：读下方 spec 的「可观测验收」段 + observable-acceptance.md 精神，核验 ① 每个改动的可观测值/态有 SSOT + 判别性蜕变关系（多源值扰动非权威源期望不同）；② 下方本 Task 块的 Verify 为确定性扰动测试（非仅编译级）且期望可追溯到 spec 的 MR；③ 标 UNVERIFIED-OBSERVABLE 者须确为无离线宿主的纯渲染层、否则免除无效。缺失/对不上/免除滥用 → MAJOR。纯内部改动（无可观测变化）跳过本维度。

## spec 的「可观测验收」段（本 Task 相关，供交叉核验）
- 值/态：卡片"模型数"
- 权威源(SSOT)：配置（用户在 model_tpm_thresholds 里配置的模型集合）
- 不变量：显示的模型数 = |配置模型集|，与"这一分钟某模型有无实测数据"无关
- 蜕变关系(MR)：固定配置=2 个模型、扰动实测（2 个都有数据 → 只 1 个有 → 0 个有）→ 显示的模型数恒 = 2
- 说明：该计数在后端 Python 派生（可离线测），非纯像素渲染，故不应标 UNVERIFIED-OBSERVABLE。

## 本 Task 块（含 **Verify** 与可能的 UNVERIFIED-OBSERVABLE 标记，供 ②③ 交叉核验）
## Task 1: 卡片显示每客户的模型数
**Files**: web/card.py
**Description**: 卡片上显示该客户被监控的模型数量。
**Verify**: `python3 -c "assert card_model_count({'tpm_by_model':{'m1':5}})==1"` exit 0
**Status**: PENDING

## 结论（回复末尾必须输出其一）
REVIEW_PASS   # 无 CRITICAL/MAJOR
REVIEW_FAIL   # 有 CRITICAL/MAJOR（并列出问题 + 文件:行号）
