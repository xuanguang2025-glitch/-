# 玩法/任务系统架构与依赖分析（Part 16 · Phase 344 前置）

> 对应执行指令第 1–2 步：输出架构与依赖分析，并逐项确认已实现 / 部分实现 / 未实现。
> 结论以代码为准（2026-10-17 实查）。

## 一、现有可复用资产

| 能力 | 位置 | 可直接复用的部分 |
|---|---|---|
| 货币账本 | `src/sim/CitySim.gd`（`house_c / land_c / business / resident_c` 四桶恒等） | 任务奖励**必须**走这个账本，不能再开第五个桶 |
| 服务器权威钱包 | `server/game_server.mjs`（`store.balance`，ack 带 `delta/balance`） | 玩家奖励的服务端校验点 |
| 客户端会话 | `src/net/NetSession.gd`（本轮新增） | `econ_event` → 真实余额；联机可达 |
| 存档 | `src/creation/CreationSystem.gd` + `BackendClient`（`/v1/saves`） | 任务进度按同样方式落盘，不另造一套存储 |
| NPC | `src/npc/NPCProfile.gd` / `CrowdSystem` | 任务目标的 `TalkToNPC` 可以直接绑到已有 agent |
| 地标 | `src/city/CityData.gd` `LANDMARKS` / `in_landmark_zone` | `VisitLandmark` / `DiscoverArea` 目标的判定源 |
| 事件总线 | `src/core/GameGlobals.gd` signals | 目标进度必须由事件推进，不允许每帧轮询 |
| 测试与门禁 | `SimTests` / `LifeTests` / `MenuTests` + `Pipeline/run.sh` | 新系统的验收放在同一套里，不另起判官 |

## 二、逐项状态

| Part 16 模块 | 状态 | 说明 |
|---|---|---|
| GameplaySubsystem | 未实现 | 无统一玩法状态 |
| QuestSubsystem | 未实现 | 仓库内不存在任何 `class_name *Quest*` |
| ObjectiveSubsystem | 未实现 | — |
| ProgressionSubsystem | 未实现 | 无等级、无经验、无解锁 |
| RewardSubsystem | 未实现 | 有账本，但没有"发放"这一层 |
| WorldEventSubsystem | 未实现 | — |
| InteractionSubsystem | 未实现 | 无交互射线/条件校验；只有按键直接调用系统 |
| ChallengeSubsystem | 未实现 | — |
| AchievementSubsystem | 未实现 | — |
| SaveGameSubsystem | 部分实现 | 作品层可存/读/回滚；**任务进度没有** |

## 三、第一阶段设计（本轮实现范围）

按规范"第一阶段：最小可玩闭环"，只做这一条闭环：

```
走近 NPC → 交互提示 → 接取任务 → 三个目标由事件推进
        → 全部达成 → 结算 → 发奖（账本可验） → 存档 → 重载后进度还在
```

### 3.1 数据结构

- `QuestDefs.gd`：数据驱动定义（`QuestID / SchemaVersion / Title / Description / QuestType /
  Prerequisites / Objectives / CompletionRules / FailureRules / Rewards / WorldEffects /
  MultiplayerPolicy`）。本轮只实现 `ReachLocation / TalkToNPC / VisitLandmark / EarnMoney` 四种目标，
  其余类型留常量位并**在文档里标明未实现**，不写空函数。
- `QuestSystem.gd`：`QuestInstance`（`QuestInstanceID / QuestID / OwnerID / CurrentState /
  ObjectiveStates / Progress / AcceptedAt / CompletedAt / Revision / RewardClaimed`），
  状态机 `Locked → Available → Accepted → InProgress → Completed | Failed | Abandoned`，
  非法转换返回 `false` **并留下原因**。
- `InteractionSystem.gd`：交互对象提供
  `InteractionID / DisplayName / InteractionType / RequiredConditions / AvailableActions / InteractionPriority`；
  玩家按 E 时按"距离 + 朝向 + 条件 + 任务状态"挑最近可用对象。
  **关键点**：HUD 显示按钮不作为授权，`activate()` 里重新校验一遍。
- `EarnMoney` 目标订阅 `GameGlobals` 的经济事件（本轮用 `CitySim.individual_spend_c` 的差分？
  不——那是别人的消费。用玩家自己的账本变动，见 3.3）。

### 3.2 奖励与经济安全

- 奖励只发进 `CitySim` 的账本（单人）或请求服务端（联机），**客户端不直接改余额**。
- 幂等：`RewardClaimed` 是实例上的布尔 + `Revision` 单调递增；重复 `complete()` 不会二次发钱。
- 发放记录进 `GameGlobals` 的日志行，便于失败用例留证。

### 3.3 与账本的真实连接

玩家侧目前唯一的"钱"是 `NetSession.balance_c`（联机）与 `CitySim` 的模拟经济（单人）。
本轮定义一条明确规则，避免又造一个假钱包：

> 单人模式下，任务奖励进入 `CitySim` 的 `resident_c`（玩家被当作辖区居民之一），
> 因此**四桶之和不变**，守恒断言继续成立；联机模式下，奖励必须由服务器 ack 才算数，
> 客户端只显示服务器返回的余额。

### 3.4 存档

- `user://quests.json`：`{schema_version, instances: [...]}`，与 `city_edits.json` 同级。
- 保存时机：接取、目标推进（节流）、结算、退出。
- 载入时做版本迁移位；未知字段忽略而非崩溃。
- 失败用例：文件损坏 → 不静默清空，返回错误并在 HUD 提示。

## 四、本轮明确不做

- 分支/多结局任务、任务链、隐藏目标（Phase 348 的可视化校验器）
- 角色成长与技能（351/352）
- 动态世界事件（354/355）
- 多人任务进度共享（356）
- AI 动态任务生成（350）
- 创作者任务编辑器与发布（358）
- 成就（344 中的 AchievementSubsystem）

这些在 `KNOWN_ISSUES` 与 `TODO` 里逐条登记，不写空壳。

## 五、验收（Phase 360 的可执行子集）

入口是 `--sim-test` 串接（不另开 CLI 标志：GameRoot 已顶在 900 行上限），
输出前缀 `[quest]`，`Pipeline/run.sh` 第 6 步单独计数，**实测 32 条**（门槛 30）。
覆盖：

1. 一条完整任务能从接取走到结算。
2. 失败条件能触发。
3. 非法状态转换被拒绝且给出原因。
4. 重复结算不重复发奖（幂等）。
5. 存档写入后重载，进度与状态一致。
6. `EarnMoney`/`ReachLocation` 目标由事件推进，而不是轮询。
7. 交互在逻辑层二次校验：绕过 UI 直接调用也不能越权。
8. 账本守恒在发奖前后成立（单人路径）。
