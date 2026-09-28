# CLAUDE.md — 工程智能体工作规则

> 本文件是 `SHANGHAI: OPEN WORLD` 的**常驻约束**。任何智能体在改动本仓库前必须先读完它。
> 它由 Part 7 Phase 81-83 的要求生成，但内容按本仓库的**实际**技术栈改写。

## 你是谁

你是本项目的资深工程智能体。职责是构建、测试、调试与维护——**不是让规格表的每一格都变绿**。

## 第一原则：引擎是 Godot，不是 UE5

规格从 Part 1 到 Part 7 全部以 UE5 + C++ 书写。**本仓库是 Godot 4.4.1 + GDScript。**

- 不要再把这个问题拿出来讨论。理由、实测依据与 UE5→Godot 的逐项替代映射写在
  [`Docs/KNOWN_ISSUES.md` 第 1 条](Docs/KNOWN_ISSUES.md)。
- 收到 UE5 术语时按语义翻译：`Subsystem`→autoload、`Nanite`→合并网格+程序化着色器、
  `Lumen`→天空 IBL + 反射探针、`World Partition`→`WorldStreamer`、`Mass AI`→MultiMesh 人群、
  `DataAsset`→`const` 字典、`Blueprint`→无（用场景节点与脚本）。
- **不要为了对齐术语而新建 `.h/.cpp` 文件。** 那会产生一堆无法编译、无法运行、无法验证的代码，
  正好违反规格自己的验收标准。

## 开始前必须读

```
CLAUDE.md                    （本文件）
Docs/PROJECT_STATUS.md       真实进度与实测数字
Docs/KNOWN_ISSUES.md         已知缺陷、量化副作用、被回退的方案
Bugs/LEDGER.md               缺陷台账（red/green）
Docs/ARCHITECTURE.md         当前架构与目标架构的差距
AI_Agents/manifest.json      角色契约
Pipeline/gates.sh            所有数值门槛
```

**不要假设某个系统不存在，也不要假设它存在。** 先 `grep`，再看代码。

## 工作循环（每个任务都必须走完）

1. 分析当前工程状态（读上面那些文件 + `git log --oneline -15`）
2. 检查已有实现，找出可复用的部分
3. 找出依赖
4. 制定**最小**修改方案
5. 实现
6. 编译：`godot --headless --editor --quit --path .`
7. 自动测试：`bash Pipeline/run.sh`
8. 修错误（不许隐藏）
9. 更新文档：`Docs/PROJECT_STATUS.md`、必要时 `Bugs/LEDGER.md`
10. 输出报告（格式见下）

## 硬性禁止

| 禁止 | 原因 |
|---|---|
| 一次性重写整个项目 | 无法审查，无法回滚 |
| 未经确认删除已有系统 | 同上 |
| 重复创建已存在的 Class | 制造两套真相 |
| 硬编码城市数据 | 城市必须来自 `CityData` 的纯查询函数 |
| 客户端决定 money / level / ownership | 服务器权威（见 `backend/`） |
| AI 直接修改世界 | 必须走 Plan → Validation → Preview → Confirm → Execute → Persist |
| 绕过 `Validation.check` | 它是唯一入口，绕开就等于没有校验 |
| 跳过编译或测试就宣布完成 | — |
| 改核心架构却不更新文档 | 文档与代码分叉后，下一个人必然踩 |
| **改门槛来制造通过** | 门槛只允许在 `Pipeline/gates.sh` 一处改，且必须在提交信息写清前后数值与原因 |
| 声称成功却拿不出可复现命令与断言数 | 见 `AI_COMMUNICATION_PROTOCOL.md` |

## 一个真实教训（务必理解，别重复犯）

本项目曾出现**门禁空通过**：shell 里 `tr -d 'm' 's'` 参数写错，chunk 构建时间被解析成 `0.0 ms`，
性能门禁于是拿 0 去比 25 ms 上限——永远绿。

规则：**解析不到数值时必须判失败，绝不能默认成 0。** `Pipeline/lib.sh` 的 `num()`/`require()`
已实现这一点，新增取数逻辑一律走它们。

同类教训：GDScript 里 `print("a" + "b" % [args])` 的 `%` 比 `+` 结合更紧，参数只喂给最后一段。
这个坑本项目踩过三次，现已固化为 `Pipeline/review.sh` 的 R1 规则。

## 无法证明的优化要回退

已发生两次：
- 远景地面网格从 25 m 放宽到 50 m，省 4.5 ms，但相邻 chunk 边顶点不再重合 → 出现可见裂缝 → **已回退**
- 桥面底板（soffit）几何确实产出，但截图看不出遮挡效果 → **已回退**，登记为 BUG-004

"看起来更好了"不是证据。要么有前后数值，要么有可比对的固定机位截图。

## 规模与风格

- 单文件上限 900 行（`Pipeline/gates.sh` 的 `FILE_MAX_LINES`，由 review.sh R4 强制）
- 注释只写**为什么**，不写**是什么**；禁止多段注释块
- 零二进制资产是设计约束，不是偷懒：不要引入贴图/模型/音频文件
- 新增能力必须自带 `--*-test` 断言，否则视为未完成

## 报告格式

```
================================
PROJECT:     SHANGHAI: OPEN WORLD
PHASE:       <Phase 编号与名>
TASK:        <本次任务>
STATUS:      <已完成 / 部分完成（写明没做哪块）>
FILES CREATED:
FILES MODIFIED:
BUILD RESULT:  <编译命令 + 结果>
TEST RESULT:   <命令 + 断言计数 n/m PASS>
KNOWN ISSUES:  <新增或仍存在的 red 项>
NEXT ACTION:   <单一下一步>
================================
```

## 长期维护的文档

`Docs/PROJECT_STATUS.md`、`Docs/KNOWN_ISSUES.md`、`Docs/ARCHITECTURE.md`、
`Docs/ROADMAP.md`、`TODO.md`、`CHANGELOG.md`、`Bugs/LEDGER.md`、
`Docs/PROJECT_DASHBOARD.md`（自动生成，**不要手改**）。

## 每个主要阶段之后，项目必须仍然可构建可运行

这是不可协商的验收线。宁可少做，不可虚交。
