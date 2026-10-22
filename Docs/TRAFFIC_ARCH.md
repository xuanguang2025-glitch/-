# 交通系统架构与依赖分析（Part 15 · Phase 324 前置）

> 这份文件回答 Part 15 执行顺序里的第 1、2 步："检查现有车辆/道路/导航/交通代码"与
> "编写架构与依赖分析"。结论以代码为准，写完后再动手，避免把已有能力再实现一遍。

## 一、现状盘点（2026-10-17 实测）

| 层 | 文件 | 真实能力 | 不是能力 |
|---|---|---|---|
| 道路几何 | `src/city/MajorRoads.gd` | 19 条主干道按折线生成路面/高架箱梁/桥/隧道；`_deck_len` 142.4 km | 只是**几何**，没有图结构 |
| 道路索引 | `src/city/CityData.gd` | `_rs_a/_rs_b/_rs_w/_rs_deck/_rs_elev/_rs_lane/_rs_name`，250 m 分桶；`major_road_info(p)` 返回 `along/elevated/deck/lanes/name/width` | 索引是**线段表**，没有节点、没有连通关系、没有车道 |
| 街区网格 | `src/city/Lattice.gd` | 静态格网：`cell_center / neighbors / edge_between / edge_width / edge_present` | 这是**车实际在跑的网络** |
| NPC 车辆 | `src/vehicle/TrafficSystem.gd` | 60 台预算的 MultiMesh 车流；`_next()` 按格网邻接随机前进；受 `sim.slow_at()` 拥堵降速；昼夜/雨天影响 | **不沿道路折线行驶**，不认车道，不认信号灯，不认单行 |
| 玩家车辆 | `src/vehicle/Car.gd` | 玩家可 F 上下车 | 单一操控参数，没有车型数据 |
| 行人 | `src/npc/CrowdSystem.gd` | 478 行人四相位步态，按格网节点游走 | 不走人行道/斑马线，不认过街信号 |
| 拥堵 | `src/sim/TripDemand.gd` | 加权占用格 → `slow_at()` 反哺车速与步速 | 是占用模型，不是车流仿真 |

**关键结论（必须先承认，否则后面全是假的）：**
主干道几何与车辆行驶是两套互不相干的东西。玩家看到的高架在 `MajorRoads` 里，
车跑的网络在 `Lattice` 里；两者只在出生点和视觉上重合。所以 Phase 325 不是"补字段"，
而是**新建一个可查询的道路图**，并在后续阶段把 `TrafficSystem` 接过去——这两步必须分开，
否则一次改动同时动几何、AI、门禁，出问题无法归因。

## 二、依赖方向（现状与目标）

```
CityData ──(线段表)──► MajorRoads（只读）      渲染
        └─(格网)────► Lattice ──► TrafficSystem ──► MultiMesh
                                └─► CrowdSystem
CitySim ──(slow_at)──► TrafficSystem / CrowdSystem    拥堵降速（已通）
```

目标是在 `CityData` 与 `TrafficSystem` 之间插入一层，且**不打破已有单向依赖**：

```
CityData ──► RoadGraph（节点/边/车道/管制）──► TrafficSystem（后续阶段接）
                                         └─► Navigation / 信号灯 / 公交（后续阶段）
```

`RoadGraph` 只依赖 `CityData` 的数据与 `GameGlobals` 常量，不反向依赖任何系统，
因此不会重演 Part 12 那类 `class_name` 编译期环。

## 三、Phase 325 设计（本轮实现）

- **节点**：折线端点 + 线段在容差内相交处。每个节点带 `y`（来自 `deck` 或地面 0），
  连接判定要求 **二维距离 ≤ 容差 且 高差 ≤ 3.5 m**——这是要求 6 的实现方式：
  高架与地面在平面上重叠是常态，只按 xz 连接会把匝道接错。
- **边**：一条道路的一段，字段按规范：`RoadID / RoadType / StartNode / EndNode /
  LaneCount / LaneWidth / SpeedLimit / Direction / PedestrianAccess / VehicleAccess /
  SurfaceType / TrafficCapacity`，外加 `elevated / deck_y / closed`。
- **车道**：每条边按 `LaneCount` 生成车道记录 `LaneID / ParentRoadID / LaneIndex /
  LaneDirection / LaneType / LaneCenterline / SpeedLimit`，横向偏移由 `LaneWidth` 推出。
  车道**类型**由该边在节点处的转向角决定：直行 / 左转 / 右转；公交与自行车道留给
  Phase 326 的数据位，本轮只标记车道存在的可能性，不虚构站台。
- **管制**：`close_edge(id, reason)` / `reopen_edge(id)`；查询路径时跳过封闭边，
  并要求存在替代路径，否则返回空并**说明原因**。
- **寻路**：A*（欧氏距离启发），只走允许方向；被封闭边阻断时重算。
  不接受"两点直线"作为路线。

## 四、本轮不做（避免伪装完成）

- `TrafficSystem` 改用 `RoadGraph` 行驶（Phase 329）：本轮只出图与测试，
  车仍走格网，`KNOWN_ISSUES` 继续挂着。
- 车道转向连接表（`EntryConnections / ExitConnections`）：需要先有节点级的
  车道匹配算法，留到下一轮与 329 一起做。
- 信号灯（330）、事故（331）、停车（332）、公交地铁（333/334）、
  出租车（335）、行人导航（336）、出行规划器（337）、多人同步（341）、
  性能统计（342）：均未开始。
- 上海分区交通风格（339）与编辑器联动（340）：依赖 325 的图先稳定。

## 五、验收（Phase 343 中本轮覆盖的两项）

- `RoadGraphConnectivityTest`：图连通、节点不重不漏、高架与地面不误连。
- `LaneConnectionTest`：车道数、方向、横向偏移与转向类型自洽。

测试入口：`--traffic-test`，与 `--sim-test` 同级，接入 `Pipeline/run.sh` 第 6 步门禁。
