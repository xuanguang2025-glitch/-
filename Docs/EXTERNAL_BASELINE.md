# 外部对照：开源城市 / 开放世界项目实测记录

> 记录日期：2026-10-03。目的只有一个：用可复现的证据回答**"这个项目还有没有必要从零往下做，
> 还是直接改用社区已有的开源产品"**。结论写在最后一节，前面全部是查到的事实。

## 1. 检索方法与边界

- GitHub：`GET /search/repositories?sort=stars&order=desc`，未授权但公开可用；关键词覆盖
  英文（`open world city game`、`procedural city generator`、`urban simulator 3d`、
  `openstreetmap 3d city`、`grand theft auto open source`、`driving simulator pedestrians traffic`、
  `city builder game godot`、`topic:open-world+topic:godot`）与中文（`上海 三维 城市`、
  `开放世界 游戏`）。
- **Gitee 未能自动覆盖**：`gitee.com/explore`、`gitee.com/explore/search` 对抓取返回 `405 Not Allowed`，
  `api/v5/search/repositories` 未登录时返回**空数组**，无法区分"确实没有"与"接口不返回"。
  本节结论因此只对 GitHub 负责；Gitee 侧需要人工检索或提供私人令牌。

| 项目 | 星数 | 许可证 | 最近提交 | 它实际是什么 |
|---|---|---|---|---|
| carla-simulator/carla | 14,449 | MIT | 2026-10-01 | 自动驾驶研究模拟器（UE 派生，真实尺度城市 + 车流 + 行人 + 天气） |
| citybound/citybound | 8,168 | AGPL-3.0 | 2023-01（停更） | Rust 多人**城市模拟**（分区/交通流），等距视角，非第三人称 |
| lgsvl/simulator | 2,458 | MIT | 2023-04（公司已关） | 曾有 **Digital Twin Shanghai**（真实扫描街道） |
| rwengine/openrw | 2,234 | MIT(代码) | 2025-06 | GTA III/VC/SA 引擎重制，**必须自备原版游戏资源** |
| vvoovv/blender-osm (blosm) | 2,128 | GPL-3.0 | 2026-09-08 | OpenStreetMap → Blender 真实城市导入 |
| kunifujiwara/VoxCity | 551 | — | 2026-09-15 | 地理数据 → 3D 城市模型 → 城市模拟框架 |
| SlashScreen/skelerealms | 483 | MIT | 2025-03 | Godot 4 开放世界 RPG 框架 |
| openfw-game/OpenLiberty | 462 | MIT | 2026-09-13 | Godot 开放世界游戏，可加载 GTA3 时代 mod 地图 |
| karimnaaji/vectiler | 502 | BSD | 2024-05 | 矢量瓦片 / 地形 / 3D 城市模型导出 |
| Vogadero/ThreeD | 0 | **无 LICENSE** | 2026-09-08 | three.js 上海全境沙盘：24 万栋建筑、379 座手工地标、453 座地铁站 |

搜 `open world city game` 命中的 228 个仓库里，**没有一个**是"真实尺度城市 + 第三人称 +
可建造 + 有经济"的开源游戏；命中物多为无关仓库与 2D 原型。

## 2. 本机实跑 CARLA 0.10.0（不是看介绍，是跑起来看）

选 0.10.0 而不是星数最高的分支线，因为它是 UE 4.26 → **UE 5.5** 迁移版：Town10 全量
**Nanite + Lumen**、PhysX → Chaos、重制建筑与路面（坑洼、减速带）。要判断"画质天花板"，
这一版才是答案。

| 事实 | 实测值 |
|---|---|
| 官方 Windows 包 | 10,203,028,286 B（10.2 GB），解压约 25 GB，16,520 个条目 |
| 分发方式 | **只有预编译包可跑**；GitHub 上的源码不能直接产出可执行体 |
| CDN 单连接速度 | 45–90 KB/s（被限速） |
| 12 连接并发 | 1.08 MB/s；24 连接不再提升（链路饱和）→ 实测 4–6 MB/s，约 40 分钟 |
| 免编程演示客户端 | **没有**。`Tools/` 下只有 `RecastBuilder.exe`（导航网格构建） |
| 车流 / 行人 | 需要 Python 客户端驱动（本机未装 Python，故实跑画面为**空城静态街景**） |
| 首启内存 | 6.1 GB（UE5 加载） |
| 渲染结果 | 真实尺度街道：多型号停放车辆、砖墙/玻璃幕墙/脚手架/防护网/灯杆旗帜、行道树、云、Lumen 间接光 |

复现：`D:\carla\Carla-0.10.0-Win64-Shipping\CarlaUnreal.exe -windowed -ResX=1280 -ResY=720 -quality-level=Epic`
（截图产物 `D:\carla\carla_town10.png`，不入库）。

## 3. 结论：继续做，但换掉一块自研

- **画质差距的来源是资产预算，不是工程能力。** CARLA 那 25 GB 是人工建模/扫描资产；本仓库的
  硬约束是零二进制资产、全程序化（见 README「素材与版权」）。这个差距不能靠"再努力一点"追平，
  它是两条路线，不是同一条路的两段。
- **它没有本项目立意所需的东西**：没有可扮演的第三人称游戏循环、没有建造与 UGC、没有城市经济
  （人口/就业/商铺/通勤）、没有创作合法性校验、没有中文城市、没有服务器权威的经济账本。
  "社区已经做好了"这个前提不成立——做好的是**仿真器**，不是**游戏**。
- **该借鉴的是方法，不是产物**：CARLA 0.9.15 起内置 **Digital Twins——从 OpenStreetMap 生成可驾驶
  地图**（MIT）。本项目最没优势、最该外包给社区的一块恰恰是城市几何本身：用真实路网与建筑轮廓
  （Overpass / blosm / VoxCity / vectiler）替换纯程序化路网，保留自己的游戏系统。
- **许可含义必须写清**：OSM 数据是 **ODbL**。把真实上海几何灌进来是合法可行的，但由此导出的
  城市数据集需要署名并以 ODbL 同等共享——**代码可以继续宽松，数据不行**。这是"借鉴"的真实代价。
- 不采纳：UE 引擎本身、任何外部美术资产（直接违反零二进制资产约束）。

## 4. 顺带发现的一个仓库级事实

README 已写明：**本仓库当前没有 LICENSE 文件**，法律上默认保留所有权利。这意味着别人（包括未来的
协作者）拿不走、也不该拿走任何代码。若打算以开源方式发布，需要单独决定许可证类型——这是产品决策，
不由本文件替作者决定。
