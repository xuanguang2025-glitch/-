# ARCHITECTURE

> 本文件区分三件事：**已经跑起来的东西**、**只有接口没有实现的东西**、**明确不做的东西**。
> 混淆这三者是 AI 协作开发最常见的失败模式。

## 1. 当前实际运行的架构

```
                    ┌──────────────────────────┐
                    │  GameRoot (composition)  │   src/GameRoot.gd
                    └────────────┬─────────────┘
        ┌──────────┬─────────────┼──────────────┬─────────────┐
        ▼          ▼             ▼              ▼             ▼
  TimeWeather  WorldStreamer  WaterBodies   MajorRoads   Landmarks
      │             │            │             │            │
      │             ▼            │             │            │
      │        ChunkBuilder ──► CellProgram ── Lattice ──► CityData
      │             │              │            │         (纯查询 + 量化缓存)
      │             ▼              ▼            ▼
      │         MeshFusion ─► ArrayMesh ─► Assets(材质/着色器)
      │
      ├── CrowdSystem ─► PopulationSystem ─► OccupationTable / NPCProfile
      ├── TrafficSystem
      ├── WeatherSystem (GPUParticles3D)
      ├── FarSilhouette (HLOD 替身)
      ├── CreationSystem ─► Validation ─► BuildTemplates ─► CellProgram
      ├── CitySim  ◄── 整点推进（随钟点，从不每帧）        src/sim/CitySim.gd
      │      │  区级状态：人口/劳动力/商铺/三桶现金/压力/客流/出行需求
      │      ├──► CrowdSystem.crowd_factor_at  → 街道行人预算
      │      └──► TrafficSystem.car_factor_at  → 街道车辆预算
      ├── SimTests (验收契约，不属于场景脚本)              src/sim/SimTests.gd
      └── DebugHUD

  GameGlobals (autoload)：事件总线 / 输入映射 / 世界常量 / 哈希噪声
  QualityPresets (autoload)：4 档画质，通过 call_group 广播 apply_quality
  CityData (autoload)：上海空间模型，所有生成的唯一真相来源

  消费者按 group("sim") 自行解析 CitySim，而不是由 GameRoot 赋值：
  未接入的系统会恒返回 1.0，看起来与接入后完全一样 —— 所以接线本身必须是可断言的。
```

### 关键不变量

| 不变量 | 由谁保证 | 被谁验证 |
|---|---|---|
| 任何几何/查询都读同一组 `CityData`/`Lattice` 纯函数 | 架构约定 | 跨 chunk 接缝缺陷曾在此被消灭 |
| 街区自己把颜色与占地画进本 chunk 的网格 | `ChunkCtx.paint_plate/mark_occupied` | `--validate-test` 的 occupied 断言 |
| 玩家作品与程序化城市共用生成器 | `BuildTemplates.build` → `CellProgram.*` | 截图 + `--create-test` |
| 任何新内容必须过 `Validation.check` | 唯一入口 | `--validate-test` 七类理由 |
| chunk 顶点是世界绝对坐标，节点保持原点 | `WorldStreamer._build` | BUG-003（曾整城位移） |
| 数值门槛解析失败即判失败 | `Pipeline/lib.sh` | 反例验证（删日志→7/8；`require` 经 `die` 置 RUNFAIL） |
| 经济只有配对转移，不凭空产生货币 | `CitySim._market` 每一行都是两桶配对 | `--sim-test` 守恒断言 + `--sim-soak=8760` |
| 守恒**不等于**经济在工作 | 支出按余额、房东也消费、利润回流家庭 | `--sim-soak` 的反塌缩三条（BUG-011） |
| 就业是商铺数的折叠，不是独立数字 | `CitySim.reconcile_jobs` | `--sim-test` 折叠断言 |
| 街道密度是经济的下游 | `crowd_factor_at` / `car_factor_at` | `--sim-test` 接入断言（未接入会恒 1.0 而无法被发现） |
| 模拟随钟点整点推进，绝不每帧 | `GameRoot._process` 的 `_sim_hour` 边沿 | `Pipeline/run.sh` 第 6 步 `[sim] day` 计数 |

## 2. 后端（`backend/`）

零依赖 Node 服务，实现 Part 7 中**可以在单机上被证伪**的那部分不变量：

```
Client ──HTTP──► backend/server.mjs
                    ├─ 账号：scrypt 口令哈希、session/refresh 双令牌、refresh 单次轮换、TTL
                    ├─ 存档：三代轮转 + sha256 校验 + 损坏自动回退 + 版本迁移下限
                    ├─ 账本：append-only JSONL，余额是逐笔折叠结果（不是可改字段）+ 幂等键
                    └─ UGC：扩展名黑名单 / 路径穿越 / 体积 / 性能预算 / 依赖存在性
                 └─ store.mjs  ← 换 Postgres/S3 的唯一接缝
```

**服务器权威的落点**（有断言守着）：
- 存档请求里出现 `balance`/`money`/`level` → 400
- 交易金额由服务器折叠，客户端无法提交余额
- 上传 ≠ 发布：任一检查不过就是 `rejected`，不进 browse 列表

## 3. Part 7 要求但**尚未实现**的东西

明确列出，避免被误认为已完成。

| Phase | 要求 | 现状 | 为什么现在不做 |
|---|---|---|---|
| 49-50 | 专用服务器 / 分区 / 动态实例 | ❌ 无 | 客户端目前根本没有网络同步层；单机原型无玩家可分片 |
| 51,54 | 创作者平台 / 创意工坊 UI | 🟡 仅后端注册表与 browse | 没有前端与账号体系接入 |
| 55 | 推荐系统 | 🟡 trending/new/top 三种排序 + 时间衰减 | 无真实行为数据，个性化无从训练 |
| 57 | 创作者收益 | ❌ 无 | 需要支付通道与经营主体，属法务+商务问题，不是代码问题 |
| 59-62 | AI 网关 / 模型路由 / 成本控制 | ❌ 无 | 无模型密钥与预算；先写契约（见下）不写假实现 |
| 63 | AI 创造最终流程 | 🟡 已有 Validation 与 Preview(ghost) | 缺 Intent Parser / Planner / Cost Estimator / Confirm 环 |
| 64-65 | 生成内容版本控制 / 城市快照 | ❌ 无 | 存档三代是最小雏形，城市级快照未做 |
| 66-69 | 监控 / 告警 / 日志聚合 / 分析 | 🟡 后端结构化日志已落盘 | 无服务器可监控 |
| 70-71 | 直播活动 / 城市永久演化 | ❌ 无 | 依赖多人后端 |
| 73-74 | 游戏模式系统 | ❌ 无 | 依赖创造工具补全 |
| 75,77 | Steam 发行 / 崩溃报告 | ❌ 无 | 需要 Steamworks 账号与打包环境 |
| 78 | 反作弊 | 🟡 经济侧服务器权威已实现 | 移动/伤害权威需多人同步层 |

## 3b. Part 8（城市动态模拟）要求但**尚未实现**的东西

同样明确列出。已实现部分见 `Docs/PROJECT_STATUS.md` 的 P81-123 行组。

| Phase | 要求 | 现状 | 缺口在哪 |
|---|---|---|---|
| 83-88 | NPC 个体经济身份（FSOWNPCData 四档） | 🟡 有 tier0/1/2 分层与作息，但个体不持有工资/记忆 | 行人读区级 `crowd_factor`，不是"我这份工资涨了" |
| 96-97 | 显式道路图与路网容量 | ❌ 无 | 车辆走 Lattice 隐式格网，边无容量、路口无通行权 |
| 98 | 公共交通 / 地铁 | ❌ 无 | 公交车只是车辆的一种外观，无线路与站点语义 |
| 99 | 城市事件（事故/施工/集会） | 🟡 仅 `OPEN/CLOSE/PLAYER_*` 经济事件 | 无空间事件，不影响路况与出行需求 |
| 101 | 社会关系 | ❌ 无 | — |
| 102 | NPC 长期记忆 | ❌ 无 | NPCProfile 有心情值，但不跨会话、不影响经济 |
| 103 | 动态任务生成 | ❌ 无 | 任务工具仍是占位（创造模式按键 6） |
| 110-111 | 城市数据库与跨会话持久化 | 🟡 `snapshot()/restore()` 只在内存 | 未接入 `backend/` 的存档三代，重启即回播种态 |
| 113 | AI 城市导演 | ❌ 无 | 当前戏剧性变化全部来自市场自身折叠，非导演调度 |

**为什么不先做成"看起来完成"**：导演、关系、记忆三项若没有可断言的下游效应，写出来只是带字段名
的空壳，规格明令禁止。因此先把守恒、反塌缩、价格响应、消费端接入钉成门禁，再逐项往上加。

## 4. 目标架构（保留规格原意，标注为设计而非事实）

```
Client ──► GameServer(权威) ──► WorldService ──► CityData(共享种子)
   │            │
   │            ├─► District/Zone/Instance 分配（按负载与好友）
   │            └─► Replication（玩家/车辆/建筑/任务/经济）
   ├──► Backend：Account / Save / Economy / UGC / Analytics
   └──► AIGateway（鉴权·限流·路由·缓存·计费·安全）──► Models
                     │
              Database + ObjectStorage + Monitoring/Alerting
```

接入顺序（依赖关系决定，不是按 Phase 编号）：
**多人同步层 → 服务器权威状态 → 实例分配 → 监控告警 → AI 网关 → 收益/发行**。

## 5. 数据与规模事实

- 世界 12 km × 12 km，1 单位 = 1 米，原点 = 人民广场
- 289 chunk × 250 m，稳态约 72 万三角面
- 单 chunk 构建 17.7 ms（门槛 25 ms；**7 ms 帧预算未达 = BUG-002**）
- 全城流式 14.7–17.7 s
- 1000 件玩家作品：放置 2.29 ms/件，静态内存 378.8 MB（**BUG-008：作品不随流式卸载**）
- 后端为文件系统存储，单进程；换 Postgres 的接缝只在 `store.mjs`
