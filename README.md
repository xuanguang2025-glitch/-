# SHANGHAI: OPEN WORLD

一个以上海城市空间逻辑为原型的**可运行开放世界原型**：程序化生成的 12 km × 12 km 城市、
黄浦江、23 处地标、昼夜与天气、职业驱动的人群与车流，以及玩家可以改变城市的创造模式。

**状态：0.x 可运行原型（Vertical Slice）。** 不是完整游戏，也不是概念演示——
下面每一条"已实现"都有可复现的运行命令与实测数据支撑。

> ⚠️ **引擎说明：这是 Godot 4.4.1 工程，不是 UE5。**
> 原始设计文档以 UE5 + C++ 书写，但目标环境无 UE5 安装、磁盘也不足以容纳引擎与城市工程。
> 设计文档自身要求"优先保证项目真正可运行、不得伪装已完成"，
> 因此这里用 Godot 实现了同一套系统，并逐项记录了 UE5 技术的替代方案：
> 见 [Docs/KNOWN_ISSUES.md 第 1 条](Docs/KNOWN_ISSUES.md)。

---

## 城市

夜景天际线，相机高度 120 m，位于静安区上空：

![上海夜空景天际线](Docs/images/shot_03_t19.4.png)

街景，延安高架路下方，12:24：

![高架下的街道](Docs/images/shot_03_t12.4.png)

## 创造模式

按 `B` 进入：世界暂停、光标释放、点击放置。玩家作品与程序化城市**共用同一套生成器**，
所以窗格、檐口、夜景发光与周边建筑同源，不需要第二套渲染路径或任何美术资产：

![创造模式与玩家作品](Docs/images/shot_03_t19.6.png)

---

## 已实现 / 未实现

按实际运行结果分类，不标注"应该可以工作"的部分。

| 系统 | 状态 | 依据 |
|---|---|---|
| 城市地图：环线 + 放射干道 + 对偶格网街区 + 12 种街区原型 | ✅ 已实现 | `--census` 普查：cells=8182 plates=7316 edges=10529 |
| 黄浦江 / 苏州河 / 河岸地形 / 流式加载 / LOD | ✅ 已实现 | 289/289 chunk 全部生成，`freed=0`（无卸载-重建抖动） |
| 23 处地标（陆家嘴四件套、外滩万国建筑群、4 座桥等） | ✅ 已实现 | 含夜景发光签名 |
| 第三人称角色 + 光线投射车辆物理 | ✅ 已实现 | 稳态 45–55 FPS |
| 人群与车流（14 种职业、作息、通勤、心情） | ✅ 已实现 | 行人 478 / 车辆 65，HUD 显示姓名·年龄·职业·状态 |
| 昼夜循环 | ✅ 已实现 | 12:24 / 19:18 / 22:00 三组截图 |
| 天气（晴/多云/阴/雨/暴雨/雾/台风） | 🟡 部分实现 | GPU 粒子降水 + 着色器湿滑/雾密度；**无**车窗雨滴、路面积水 |
| 创造系统：放置/移动/旋转/缩放/复制/删除/撤销/重做/存盘/读盘 | ✅ 已实现 | `--create-test` 22 项断言全通过 |
| 创造工具：建筑（12 种模板） | ✅ 已实现 | 见上方截图 |
| 创造工具：道路 / 地形 / 装饰 / 车辆 / NPC / 任务 | ❌ 未实现 | 按键 2–7 只提示"待实现"，不产生世界修改 |
| 3D 拖拽 Gizmo | ❌ 未实现 | 改用键盘变换（方向键 / R / [ ] / Ctrl+D） |
| 放置合法性校验 | ❌ 未实现 | 目前可以把楼放进江里、别的楼里或马路上 |
| 红绿灯、行人让行 | ❌ 未实现 | — |
| 建筑室内、地铁、经济、任务、创意工坊、多人、AI 生成 | ❌ 未实现 | 均依赖尚未存在的最小可运行闭环 |

## 实测数据

```
1280×720 / 1600×900，Quality=高，RTX 5060 Laptop

chunks=289/289        三角面=717k        稳态 FPS=45–55     加载期 FPS=15–29
单 chunk 构建 = 17.9 ms（blocks 8.6 / ground 8.0 / streets 0.9 / furniture 0.4）
流式：built=289  freed=0  requeue=6  jumps=1

人口普查：homes=5822  retail=756  parks=463  total_pop=3,679,892
街区构成：XIAOQU 1842 / DENSE_WALKUP 1359 / VILLAS 1094 / FACTORY 965 /
          SPLIT_TOWER 709 / PARKING 474 / PARK_CELL 333 / MALL 393 /
          SHOPFRONT_ROW 347 / LILONG 266 / SITE 226 / OFFICE_PLINTH 174
```

规模：**29 个 GDScript / 7545 行 + 4 个着色器，零二进制资产。**
城市、建筑、地标、材质、人群全部由代码与着色器生成，仓库内没有任何模型、贴图或音频文件。

## 运行

需要 [Godot 4.4.1 stable](https://godotengine.org/download/archive/)（Forward+ / Vulkan）。

```bash
godot --path .              # 直接运行
godot --editor --path .     # 在编辑器中打开
```

无窗口验证（CI 友好，全部为只读检查）：

```bash
godot --headless --path . --quit-after 60  -- --census        # 世界普查
godot --headless --path . --quit-after 120 -- --create-test   # 创造系统 22 项断言
```

命令行截图与分相性能计时（用于视觉回归）：

```bash
godot --path . --resolution 1280x720 -- \
  "--shots=2" "--shot-every=11" "--shot-dir=<绝对路径>" \
  "--time=10.0" "--spawn=1150,300"
# 其他：--weather=<0..6>  --quality=<0..3>  --view=<pitch,yaw,lift>  --demo-build=<n>
```

## 控制

`WASD` 移动 · `Shift` 疾跑 · `空格` 跳跃 · `C` 一/三人称 · `F` 上下车 ·
`V` 切换天气 · `T` 推进时间 · `P` 画质档位 · `F1` 帮助

创造模式（`B`）：`左键` 放置/选中 · `Ctrl+左键` 删除 · `方向键` 移动 · `R` 旋转 ·
`[ ]` 缩放 · `Ctrl+D` 复制 · `Del` 删除 · `Ctrl+Z/Y` 撤销/重做 · `Tab` 换模板 ·
`E` 存盘 · `Q` 退出

## 架构

```
src/
  core/       GameGlobals（事件总线 / 输入映射 / 世界常量 / 哈希噪声）
              Assets（材质工厂 / 图元工厂）  QualityPresets（4 档画质）
  city/       CityData     上海空间模型：水系 / 路网 / 区划 / 地标 / 公园 + 量化查询缓存
              Lattice      对偶格网：街区多边形、街道边、邻接
              CellProgram  12 种街区原型的建筑生成
              ChunkBuilder 单个 250 m chunk → 合并网格 + 碰撞
              WorldStreamer 流式加载 / 时间预算 / LOD / 碰撞分层
              MajorRoads   环线与高架：桥、隧道、匝道、路灯
              Landmarks    地标工厂（东方明珠 / 上海中心 / 环球金融中心 / 金茂 / 外滩…）
              MeshFusion   顶点合并器（一个 chunk 一次 draw call 画出全部窗格）
  npc/        OccupationTable / NPCProfile / PopulationSystem / CrowdSystem
  vehicle/    Car / TrafficSystem
  weather/    TimeWeatherRig / WeatherSystem
  creation/   BuildTemplates（模板目录）/ CreationSystem（编辑状态机 + 撤销 + 持久化）
```

设计原则：所有生成读取同一组**纯查询函数**（`CityData` / `Lattice`），
而不是各自维护列表。因此"某个点属于哪个街区""这里离水多近"在网格、交通、人群、
小地图之间不可能漂移，chunk 之间也不会出现接缝。

## 已知问题

完整清单见 **[Docs/KNOWN_ISSUES.md](Docs/KNOWN_ISSUES.md)**，其中包含：

- 性能缺口：17.9 ms/chunk 仍是 7 ms 帧预算的 2.5 倍，以及为消除它试过并被**回退**的方案
- 量化副作用：距离场走 25 m 缓存格，岸边判定可偏移至多 25 m（哪些调用点因此走精确路径）
- 桥 underside 可见车道标线（已定位，未修）

[Docs/PROJECT_STATUS.md](Docs/PROJECT_STATUS.md) 记录阶段进度、实测数字，
以及**由运行结果（而非静态阅读）发现的缺陷及其根因**——其中包括一个曾让整座城市
按离原点距离成比例渲染位移的缺陷。

## 素材与版权

- 不含任何第三方受版权保护的游戏资产、角色模型、车辆模型、音乐或贴图。
- 全部几何体、材质、着色器、人群行为由本仓库代码程序化生成。
- 地标为**受其结构特征与视觉关系启发的原创体量**，非授权复制的真实建筑模型。
- 城市关系（路网走向、区划比例、江与两岸、密度梯度、天际线）按真实上海校准，
  但这是程序化近似，不是测绘数据。
- **本仓库当前未附带 LICENSE 文件**，因此在法律上默认保留所有权利。
  若需授权他人使用，请由作者明确选择并添加许可证。
