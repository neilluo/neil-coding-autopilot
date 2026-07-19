# Spec — Autopilot「可观测验收门」(Observable Acceptance Gate)

> 改动对象 = **autopilot 插件本身**（`neil-coding-autopilot`），非业务项目。
> v4（吸收 3 轮评审：v1 67/48/60 → v2 62/38/62 → v3 72/60/83 的全部 CRITICAL/MAJOR）。
> 核心：验收=**不变量+蜕变关系(metamorphic)**；验证=**扰动测试即 Task 的 `**Verify**`，蹭 run-track-a.sh 现成 `eval "$verify"`（[L273-275]）**，不动脚本即在无人值守生效。

## 1. 背景与根因（测试 oracle 问题）

卡片显示「1 个模型」、实际配 2 个：显示写成**实现口径**（"数 `tpm_by_model` 的 key"）。这是 **test oracle problem**（Liu 2014 / Segura）——作者把实现当期望值写进验收 → 测试照断言 → 把 bug 又确认一遍，全绿。**治本**：验收改写**不变量 + 蜕变关系**（扰动非权威源，断言可观测输出不变），作者无法把 bug 编码进不变量，因为测试**独立扰动两源**、buggy 实现必违反。

## 2. 目标 & 非目标

**目标**：G1 验收=规则/不变量+MR（非点 oracle）；G2 单一事实源；G3 不降自动化/不进决策环（阻塞仅结构性、真歧义异步旁路）；G4 完全通用；G5 **载重路径不动脚本**（MR 测试即 `**Verify**`，蹭现成 `eval`）。
**非目标**：不改 loop 控制流/dispatch/状态机（仅对 `build_review_prompt` 做**一处最小通用增补**，见 §3.9）；不实现观测/独立 QA（=**Phase 2**，补 §7 残留）。

## 3. 核心设计

### 3.1 单一事实源 `_shared/observable-acceptance.md`
承载 12 问（§6，采集前端）+ 验收产物格式，对每个用户可观测值/态产出：
- **权威源(SSOT) 声明**；多源时唯一权威源=?
- **不变量(rule)**：普适规则（"输出体现配置基数，与实测子集无关"）。
- **蜕变关系(MR)**：`固定权威源、扰动全部非权威源 → 输出不变（或仍=f(权威源)）`。点例由规则派生。
- 单源值：一句「单源：<源>，已排除候选源：<列举+为何不可能供值>」。

### 3.2 验收即不变量（core）
- 多源可观测值**必须**有 MR，扰动样例须有判别力（base 与扰动例期望不同，或明确"声明不变"且扰动确打在 buggy 分歧轴上）。
- **范例（写入 `_shared`）——区分"派生逻辑"与"纯渲染"**：卡片"模型数"的**计数/派生在后端**（`state` 携带的值，Python 可离线跑）；MR = 固定配置 2、扰动实测 stub（2→1→0）、断言派生计数**恒=2** → buggy（数实测）给 2/1/0 违反 → 被抓。**仅像素/DOM 渲染层**（无测试宿主）才归 §7 Phase 2。**多数"显示"bug 其实在可离线的派生层**——这是 gate 的主战场。
- 诚实：MR 正确性仍取决于 SSOT 选对（§7(a)）与扰动轴完备（§7(c)）。

### 3.3 验证蹭现有 verify 门（不动脚本）
- plan 在**设计阶段**为 user-facing Task 编写 MR 扰动测试，落为**该 Task 的 `**Verify**`**（脚本 `task_verify` 仅匹配 `**Verify**:`，[L164-168]；故字段名统一用 `**Verify**`，**不用**不被匹配的 `Runtime Verify`）。`run-track-a.sh` 现成 `eval "$verify"` 执行之 → 无人值守直接拦、**无需改脚本**。
- **oracle 独立性来自「不变量在实现前已冻结」**：不变量、扰动轴、期望关系由 **spec/tasks（设计阶段）固定**；可执行测试文件因 controller write-gate（[conventions L8-10]）只能由 **implementer worker 在该 Task 内、implement 步 verify 前落地**。独立性靠"MR 先于实现冻结"，非靠"谁敲测试文件"。
- MR 测试须**确定性/内存态/离线**（扰动 stub 两源，禁 live 数据/网络）→ 杜绝 flaky→fixer 空转。`**Verify**` 是**单条命令**指向测试目标（脚本 awk 只取首对反引号，[L166]）。
- **禁**仅编译级 Verify（user-facing Task）。
- **纯渲染层无离线宿主**（§7(b)）：Task 打 `UNVERIFIED-OBSERVABLE(<MR>)` 标记 + 登记 `clarifications.md` + 变更摘要醒目列出转 Phase 2。**诚实说明**：脚本不识别该标记、loop 不读 clarifications（[L150-168]），故 **headless 下该 Task 仍会 commit DONE**——这是**书面响亮登记、非运行期拦截**（靠 `git diff`/摘要/Phase 2/人读产物兜底），但不 stall、不烧钱、不冒充"已验证"。要 headless 运行期拦截须改脚本（本次非目标，见 §7(b)）。

### 3.4 落点 SKILL（只加义务/指针，格式全文仅在 `_shared`）
- **explore**：Step4 加指针 `**可观测验收**（不变量+MR，详见 _shared/…）`；bugfix 轻量模式落点前移 **Step 2**，强制"SSOT + ≥1 条 MR"；explore 不设 fail-closed（交互兜底，显式声明）。
- **analyze**：Step3「Spec 必须包含」新增第 8 项 `可观测验收=SSOT+不变量+多源值 MR`；Step4 **第 3 轮**加 WARN 维度「MR 完备性：多源值有 MR？扰动轴覆盖全部非权威源？SSOT 摆明？实现口径泄漏？」全 WARN 自修不 BLOCK。
- **plan**：user-facing Task 的 `**Verify**` 须为 §3.3 扰动测试（plan 作者、确定性、单命令）；改 SKILL 模板"默认 `**Verify**: <compile>`"为"user-facing 须扰动测试、禁仅编译"。**spec-ready**（跳过 explore+analyze）：plan 据来料 spec+KB 自填不变量+MR；**低置信/无法确信自填 → 打 `UNVERIFIED-OBSERVABLE` + 登记，不产 mandatory 错测试→不 stall**（degrade 不停线）；仅结构不可生成才 `PLAN_STATUS=BLOCKED|{原因}`。
- **using-neil-autopilot**：HARD-GATE #7（§3.8）。

### 3.5 两层判定
| 层 | 判据 | 后果 |
|----|------|------|
| **结构门（阻塞·确定性）** | user-facing 改动**既无验收段、又无 §3.7 可证伪免除** | `{ANALYZE\|PLAN}_STATUS=BLOCKED\|{原因}`（立即 exit，禁挂起） |
| **覆盖/口径（非阻塞·自愈）** | MR 缺失/无判别力/实现口径泄漏/三态缺 | analyze=WARN 自修；运行期由 §3.3 扰动测试**在既有 verify 门直接拦**（buggy 必挂→fixer） |

结构门只在"纯结构性缺失"BLOCK（确定、罕见、无人值守安全）；spec-ready 跳过 analyze 时由 plan 门兜（同上）。

### 3.6 clarifications 非阻塞 + 无人值守（沿用 v2 已验机制）
`[NEEDS CLARIFICATION]`/`UNVERIFIED-OBSERVABLE` 写入 `$CHANGE_DIR/clarifications.md`，与状态码解耦；`run-track-a.sh`/loop **永不读取**（[L150-168] 已核）→ 物理不阻塞。真歧义→状态保持 `DONE`+`ASSUMPTION:` best-effort 继续。档位 A：一律不阻塞，`BLOCKED` 只许立即 exit、禁挂起。档位 B：单次 run 汇总异步呈现。

### 3.7 触发条件 + 可证伪免除 + tripwire
- **user-facing**：新增/改变任何终端可观测输出（UI 渲染 / CLI·stdout / API 响应体 / 告警·通知内容 / 报表）；内部日志不属。
- 免除须**可证伪**：纯内部重构须声明「无用户可观测变化」+ 列所核 surface + 断言未变。
- **tripwire**：CR/verify 发现 diff 触及上述 surface 层 → 免除作废、回炉补验收。**caveat**：§3.9 已让 loop reviewer 读 spec + 本 Task 块，故「免除正当性」核验在 headless 亦生效（判 UNVERIFIED 滥用即 MAJOR）；但“diff 是否触及 surface”的自动判定仍偏 analyze/档位 B。

### 3.8 HARD-GATE 增补 #7
现 6 条后新增：
> **#7 可观测验收**：user-facing 改动必带「可观测验收」（多源值含**不变量+蜕变关系**，其扰动测试即该 Task 的 `**Verify**`）；不可离线验证者须 `UNVERIFIED-OBSERVABLE` 醒目登记转 Phase 2、**禁静默放行**；`BLOCKED` 只许立即 exit、禁挂起。（诚实说明：#7 不减少既有停线，只保证本门**不新增挂起**——载重路径蹭本就不能挂起的 verify 门。）

### 3.9 reviewer 交叉核验（默认开，本版新增）
**已默认启用（本版新增）**：对 `build_review_prompt` 做一处最小通用增补——加一条「可观测验收」审查维度：headless reviewer 读 `$CHANGE_DIR/spec.md` 的可观测验收段 + `_shared/observable-acceptance.md`，交叉核验：① 可观测值有 SSOT + 判别性 MR；② Task 的 Verify 为确定性扰动测试、期望可追溯到 MR；③ `UNVERIFIED-OBSERVABLE` 免除须正当；缺失/对不上/滥用 → MAJOR → `REVIEW_FAIL` → 既有 fixer 循环。这给 headless 拦截上了牙，且仅动 prompt 文本、不碰 loop 控制流/状态机。

## 4. 自动化率保全
验收 AI 自答；阻塞仅纯结构性缺失；bug 拦截靠确定性扰动测试蹭既有 verify 门（机器跑、自动修）；真歧义/不可验证→旁路登记 best-effort 继续、档位 A 永不挂起；evolve 沉淀 doctrine 使自动化率随 KB 上升。**不可离线验证的值 = 书面登记转 Phase 2，不停线、不冒充已验证。** 残留假停线向量：**确定性但写错的 MR**（SSOT 选错/扰错轴，§7a/c）会把正确实现翻 FAIL→fixer≤MAX_ROUNDS→exit2 停（**有界、非无限烧 token**）；靠"MR 由设计期不变量约束"+ Q5 逐轴扰动压低概率，§3.9 reviewer 交叉核验（默认开）进一步兜。

## 5. 通用性保证
插件只承载义务 + 不变量/MR 格式 + 单一事实源；哪个值/surface/场景由每次 spec 绑定。「不变量+蜕变关系」是领域无关通用测试范式（MT/PBT）；surface 开放式不枚举；措辞中性（"可观测输出"非"界面"）。MR 测试即普通单命令 `**Verify**`，与既有机制同构，不新增字段；脚本仅 `build_review_prompt`（+可观测验收维度、喂本 Task 块）与 `CHANGE_DIR` 绝对化共三处最小增补，不碰 loop 控制流/状态机（见 §3.9/§9）。

## 6.「可观测验收」12 问（采集前端；产物=SSOT+不变量+MR）
1. 可见值清单：哪些新增/变了？逐个列。
2. 来源+**权威源(SSOT)**：实时/配置/派生？多源以谁为准？
3. **不变量（禁实现口径）**：普适规则，非"代码怎么数"。
4. 配置对得上：填 N，输出体现 N，不被实测覆盖。
5. **蜕变关系**：固定权威源、**扰动须覆盖全部非权威源**（≥2 源时逐轴扰动，防"扰错轴假过"）；`配置∖实测`与`实测∖配置`双向各给样例。
6. 基数与集合：0/1/N/超大量？顺序？重名？**聚合/合计项是否计入判别量？**——**worked MR**（对齐同域第二 bug）：超阈计数 **k 恒排除 `*` 合计项**；扰动"结果集是否含 `*`"→ **k 不变**（buggy 把 `*` 混入分子 → k 跳变、致「1/3 超阈」误导 → 抓）。判别量是分子 k、非分母 n。
7. 状态细分：进行中/无数据/失败·超时/部分 各输出什么+恢复？
8. 时序并发：刷新时机、时间窗、陈旧、保存与测量竞态、多人同改？
9. **不变量测试**：MR 写成可自动跑的确定性扰动断言（即 Task 的 `**Verify**`）。
10. 连带影响（读+写+迁移）：别处读/写同一数据？迁移？改他人口径？回归范围？
11. 非功能+权限：性能、i18n、可访问性；各角色/租户值都对吗？
12. 上线可观测+未决登记：自动化测试守护？埋点能否发现复发？`[NEEDS CLARIFICATION]`。

> 来源：Metamorphic Testing（Liu2014/Segura，解 oracle problem）、Property-Based Testing、Rules-Oriented AC（Marcano）、spec-kit/Example Mapping、Test Heuristics（CORRECT/ZOMBIES）、Working Backwards/DoD。

## 7. 诚实边界 & Phase 2（不 overclaim）
v4 **能**：抓实现口径式验收、抓 config-vs-data（确定性扰动测试）、抓 oracle 反填（扰动必现分歧）；**多数"显示"bug 的派生逻辑在后端、可离线被 MR 抓**；无人值守生效（载重蹭现有 verify 门；reviewer 维度仅动 prompt 文本）。
v4 **不保证**（设计门固有上限，三处**已尽列**）：
- (a) **novel 且 SSOT 选错**：自洽错 MR 过全部结构门（§3.9 reviewer 交叉核验现默认开，但自洽的错 SSOT 仍可能放行）。
- (b) **纯渲染层无离线宿主**（像素/DOM）：确定性扰动测试跑不起来（无测试宿主）。现由 §3.9 的 reviewer 维度兜：headless reviewer 核验到「标 UNVERIFIED-OBSERVABLE 却并非真无宿主」即 MAJOR→FAIL，故缺口从 v4 的「静默 commit DONE」升级为「reviewer 拦截 / 要求正当化」。真无宿主的纯渲染值仍无法**运行期执行**扰动测试 → 交 Phase 2 观测层；但不再静默放行。
- (c) **多源扰动轴不完备**：只扰无关源 → buggy 与正确都不变而假过（§6-Q5 要求逐轴扰动以压低此风险，但无机检）。
- (d) **设计期缺陷类 reviewer FAIL 的有界浪费**：reviewer 因缺 MR/Verify 不可追溯/UNVERIFIED 滥用判 MAJOR 时，反馈喂给代码 fixer（改不动 spec/tasks）→ 撞 MAX_ROUNDS→exit2（有界停线、非无限烧；极少数下 fixer 可能改坏正确码述迹，靠 MR 设计期冻结压低）。
→ 三处均由 **Phase 2「观测/独立 QA 层」**兜（渲染真实产物 + 独立于实现验不变量）；v4 可观测验收即其输入契约。**故 v4 定级为"让决策显式可执行 + 最大化拦截 + 缺口响亮可见"，非"必然堵死"。**

## 8. 本改动自身的验收（对抗回放 + 扰动实证）
- **对抗回放**：历史 bug 的 explore-notes 在作者盲+全新 context 过带 gate 的 analyze → 通过判据=产出含判别力 MR（固定配置 2、扰动实测→派生计数恒 2），非仅含字段。
- **扰动实证**：对 buggy 版**后端派生逻辑**（非像素渲染）跑 §3.2 的确定性 MR 测试 → 必 FAIL；修正版 → PASS（与 §7(b) 无矛盾：计数在后端可宿主，纯渲染才归 (b)）。
- **不误伤**：纯后端重构声明「无可观测变化」+ surface 核对 + tripwire 未命中 → 不触发。
- **脚本改动最小可核**：`scripts/run-track-a.sh` 仅 `build_review_prompt`（+可观测验收维度、喂本 Task 块）与 `CHANGE_DIR` 绝对化三处文本/取数增补，不碰 loop 控制流/状态机；`bash -n` + `smoke-dispatch.sh` + `smoke-run-track-a.sh` 通过；prompt diff 可核。

## 9. 应用方式（review ≥95% 后）
落点（插件仓，feature 分支，禁 master 直改）：新增 `skills/_shared/observable-acceptance.md`；改 `skills/autopilot-{explore,analyze,plan}/SKILL.md`（plan 模板：user-facing 的 `**Verify**` 须为扰动测试、禁仅编译；**删除模板里不被脚本执行的 `**Runtime Verify**` 死字段行**）；改 `skills/using-neil-autopilot/SKILL.md`；改 `scripts/run-track-a.sh`（`build_review_prompt` +可观测验收维度并喂本 Task 块 + `CHANGE_DIR` 绝对化；仅文本/取数，不碰控制流）。写入经权限升级 Bash，每步 `git diff` 可核可回滚；冒烟 `smoke-dispatch.sh`+`smoke-run-track-a.sh`。
