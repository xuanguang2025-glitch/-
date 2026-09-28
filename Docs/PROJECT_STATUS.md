# PROJECT STATUS

项目：SHANGHAI: OPEN WORLD
引擎：**Godot 4.4.1 stable**（不是 UE5 — 理由见 KNOWN_ISSUES 第 1 条）
工程：`C:/Users/徐浩然/Documents/Qoder/2026-09-27/385ef28b/shanghai-open-world`
规模：29 个 GDScript / 7545 行 + 4 个着色器，零二进制资产
更新：2026-09-28

## 阶段进度（全部以实际运行结果为准）

| 阶段 | 内容 | 状态 | 证据 |
|---|---|---|---|
| P0 | 工程初始化 / 状态文件 / 输入映射 | 已实现 | headless 启动零报错零警告 |
| P1 | 渲染基底：4 个程序化着色器 + 材质工厂 + 质量档位 | 已实现 | 截图可见窗格/沥青标线/水面 |
| P2 | 城市地图：环线+放射+对偶格网街区+12 种建筑+黄浦江+流式+LOD | 已实现 | 289 chunk / 71.7 万三角面全部生成，freed=0 |
| P3 | 第三人称角色 + VehicleBody3D 汽车 | 已实现 | 稳态 45-55 FPS，出生点自动落在地面道路上 |
| P4 | NPC 人群 + 车流（职业/作息驱动的行人档案） | 已实现 | 行人 478 / 车辆 65，HUD 显示姓名·年龄·职业·心情 |
| P4 | 红绿灯 / 行人让行规则 | 待实现 | — |
| P5 | 昼夜循环 | 已实现 | 12:24 / 19:18 / 20:30 三组截图 |
| P5 | 天气（雨/雾/台风） | 部分实现 | GPUParticles3D 降水+拖尾已接，未做车窗雨滴/路面积水 |
| P6 | 创造系统：放置/移动/旋转/缩放/复制/删除/撤销/重做/存盘/读盘 | 已实现 | `--create-test` 22 项断言全通过 |
| P6 | 创造工具：建筑（12 种模板） | 已实现 | 截图可见玩家作品与生成城市同轴同材质渲染 |
| P6 | 创造工具：道路 / 地形 / 装饰 / 车辆 / NPC / 任务 | 待实现 | 按键 2-7 有占位提示，未接入 |
| P6 | 大地图 / 主菜单 | 待实现 | 仅调试 HUD 已实现 |
| P7 | 性能 | 部分实现 | 单 chunk 构建 46.5→17.3 ms；仍超 7 ms 预算，见 KNOWN_ISSUES 第 3 条 |
| P9 | 地标 | 已实现 | 23 点位，陆家嘴四件套 + 外滩 + 4 桥，含夜景发光签名 |

## 实测数据（1280×720 / 1600×900，Quality=高，RTX 5060 Laptop）

```
chunks=289/289   三角面=717k   稳态 FPS=45-55   加载期 FPS=15-29
全图构建完成 ≈ 首帧起 6 s
单 chunk 构建 = 17.3 ms（blocks 8.3 / ground 7.7 / streets 0.9 / furniture 0.4）
ground 内部   = water 5.4 / colour 1.9（其中 fields 1.8）/ emit 0.3 / height 0.0
自然地面着色样本 = 13986 / 28900（其余由街区板块自绘）
流式：built=289  freed=0  requeue=6  jumps=1（无卸载-重建抖动）
人口普查：homes=5822  retail=756  parks=463  total_pop=3679892  scan=896ms
格网普查：cells=8182  plates=7316  edges=10529  edges_per_cell=1.29
街区构成：XIAOQU 1842 / DENSE_WALKUP 1359 / VILLAS 1094 / FACTORY 965 /
          SPLIT_TOWER 709 / PARKING 474 / PARK_CELL 333 / MALL 393 /
          SHOPFRONT_ROW 347 / LILONG 266 / SITE 226 / OFFICE_PLINTH 174
```

> **数据口径更正**：本轮之前所有"每 chunk 平均"数字都被一个计时器缺陷压低了 4 倍
> （分相计时把样本计数 `n` 在四个阶段各加一次）。因此历史文档里的
> "稳态 179 FPS / 生成预算 0.07 ms / 单 chunk ~70 ms"不可作为基线，
> 本表数字来自修正后的计数器。

## 本轮修掉的真实缺陷（全部由运行结果发现，非静态阅读）

| # | 症状 | 根因 |
|---|---|---|
| 0 | **整座城市渲染位移，且随离原点距离增大** | chunk 网格顶点是世界绝对坐标，但 chunk 节点又被平移到 `chunk_index × 250 m`；碰撞用 `to_local()` 因而位置正确 —— 玩家走在看不见的街道上，建筑偏移到一公里外。实测 `node.pos=(1250,0,250)` 与 `mesh.aabb x∈[1141,1275]` 才暴露。改为节点保持原点 |
| 1 | 性能数字普遍偏乐观 4 倍 | 分相计时器每阶段都 `n += 1`，均值被除以 4 |
| 2 | 地面着色占单 chunk 25 ms | 每个地面采样点做一次"属于哪个街区"的多边形搜索（35 次带数组分配的判内测试）→ 反转方向：街区生成时自行把颜色画进地面槽位网格 |
| 3 | 距离查询每次命中都新建字典 | `water_info` / `major_road_info` 每改进一次分配一条记录，空桶用 `.get(k, [])` 分配空数组 → 拆出纯标量路径 + 平行 typed 数组索引 |
| 4 | 远离江的采样仍扫 81 个桶 | 缺"附近有没有水"粗判 → 建 `_water_near` 膨胀集，空格 O(1) 返回 |
| 5 | 桶扫描顺序固定，首个命中不紧 | 最近邻改为按环序遍历 + 后缀距离下界提前终止 |
| 6 | 启动报 2 条粒子错误 | `trail_lifetime = 0.0`（<0.01 被引擎拒）与晴天下 `amount = 0`（<1 被拒） |
| 7 | **出生点落进黄浦江** | `in_water` 走 25 m 量化备忘格，岸边可错 25 m，`_find_spawn` 因此选中被量化判为陆地的江心点。已让 `in_water` 走精确路径；`_furniture` 用"量化粗判 + 精确复核" |
| 8 | `cell_kind` 每格重扫全部行政区 | 用了未缓存的 `district_at` → 改 `district_q` 并加格缓存 |
| 9 | 相邻 chunk 重复解析同一街区 | 街区的 kind/style/intensity/高度带/随机数无缓存 → 新增 `CellFacts` 一次解析 |
| 10 | 判内测试在退化边上有符号错误 | `_poly_has` 用 `absf(b.y - a.y)` 作除数，跨过下向边时参数变号 |

## 世界尺度基准

- 1 单位 = 1 米；可玩范围 12 km × 12 km（约上海内环）
- 原点 = 人民广场；+X = 东，+Z = 南
- 外滩在原点以东约 1.3 km，陆家嘴正对江面，静安寺以西 2.4 km —— 与真实城市关系一致
- 黄浦江 321 个加密中心线点、半宽 190–270 m；苏州河 55 个点
- 19 条主干道：内环 / 中环 / 外环 + 南京路 / 延安高架 / 淮海路 / 世纪大道 / 南北高架 / 外滩中山东一路 等

## 启动方式

```bash
GODOT="/d/徐浩然/2026-08-29-21-56-21/.tools/Godot441_console.exe"
"$GODOT" --editor --path .                                  # 编辑器
"$GODOT" --path .                                           # 直接运行
"$GODOT" --headless --path . --quit-after 60 -- --census    # 无窗口普查
"$GODOT" --headless --path . --quit-after 120 -- --create-test   # 创造系统 22 项断言
"$GODOT" --path . --resolution 1280x720 -- "--shots=1" "--shot-every=12" \
    "--shot-dir=<abs>" "--time=19.6" "--spawn=880,700" "--view=-0.22,0.7,26" \
    "--demo-build=6"                                        # 截图：玩家作品 + 编辑器 UI
# 其他开关：--weather=<0..6>  --quality=<0..3>
"$GODOT" --path . --resolution 1280x720 -- "--shots=2" "--shot-every=11" \
    "--shot-dir=<abs>" "--time=10.0" "--spawn=1150,300"     # 截图 + 分相计时
# 其他开关：--weather=<0..6>  --quality=<0..3>  --view=<pitch,yaw,lift>
```

控制：WASD 移动 / Shift 疾跑 / 空格 跳跃 / C 视角 / F 上下车 / B 建造 / V 天气 / T 时间 / P 画质 / F1 帮助
