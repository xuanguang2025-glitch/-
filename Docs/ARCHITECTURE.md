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
      └── DebugHUD

  GameGlobals (autoload)：事件总线 / 输入映射 / 世界常量 / 哈希噪声
  QualityPresets (autoload)：4 档画质，通过 call_group 广播 apply_quality
  CityData (autoload)：上海空间模型，所有生成的唯一真相来源
```

### 关键不变量

| 不变量 | 由谁保证 | 被谁验证 |
|---|---|---|
| 任何几何/查询都读同一组 `CityData`/`Lattice` 纯函数 | 架构约定 | 跨 chunk 接缝缺陷曾在此被消灭 |
| 街区自己把颜色与占地画进本 chunk 的网格 | `ChunkCtx.paint_plate/mark_occupied` | `--validate-test` 的 occupied 断言 |
| 玩家作品与程序化城市共用生成器 | `BuildTemplates.build` → `CellProgram.*` | 截图 + `--create-test` |
| 任何新内容必须过 `Validation.check` | 唯一入口 | `--validate-test` 七类理由 |
| chunk 顶点是世界绝对坐标，节点保持原点 | `WorldStreamer._build` | BUG-003（曾整城位移） |
| 数值门槛解析失败即判失败 | `Pipeline/lib.sh` | 反例验证（删日志→7/8） |

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
