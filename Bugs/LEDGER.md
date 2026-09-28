# Bug 台账

Part 6 Phase 38。规则：**缺陷必须变成可重跑的断言**，否则它只是散文。
状态只有三种：`red`（存在且未修，有复现命令）、`green`（已修，有守住它的断言）、`wontfix`。

| ID | 标题 | 状态 | 复现 / 守护命令 |
|---|---|---|---|
| BUG-001 | 分相计时器把样本计数按阶段累加，所有每-chunk 均值被低估 4 倍 | green | `Pipeline/run.sh` 第 5 步；`[prof]` 四阶段之和须与门槛同量级 |
| BUG-002 | 单 chunk 构建 17.9 ms，仍是 7 ms 帧预算的 2.5 倍 | **red** | `Pipeline/run.sh`；`grep '\[prof\]' Pipeline/logs/perf.log` |
| BUG-003 | chunk 节点被平移到 chunk 中心，而网格顶点是世界绝对坐标 → 整座城市按离原点距离成比例渲染位移，碰撞却正确 | green | `Pipeline/run.sh`；`--validate-test` 的 "found an occupied spot" 依赖渲染与碰撞一致 |
| BUG-004 | 高架 / 桥 underside 可见顶面车道标线 | **red** | 桥下仰拍固定机位截图（尚无自动断言） |
| BUG-005 | 开启降水粒子拖尾后 FPS 由 51 掉到 23 | **red** | `--weather=4` 对比 `--weather=0` 的 `fps=` |
| BUG-006 | 玩家可在水面上行走，无水体阻挡 | **red** | `--spawn=1530,0` 后按 W |
| BUG-007 | `in_water` 走 25 m 量化格，岸边判定可错 25 m，曾使出生点落进黄浦江 | green | `--validate-test`：`river refused` / `mud bank refused` |
| BUG-008 | 玩家作品不参与流式卸载，常驻场景树 | **red** | `--bench-stress=1000`，观察 `static_mem` 与 teardown |
| BUG-009 | 外白渡桥处桥梁几何与路网/水体冲突未消解 | **red** | `--spawn=1700,-1000` 目视 |
| BUG-010 | 创造模式放置道路时，走廊搜索与提交使用同一 near-list 才可通过（测试曾因此假失败） | green | `--validate-test`：`second click commits road` |

## red 项的处理约定

- `red` 项若已有门槛数值（BUG-002），门槛文件里保留**实测值**而不是理想值，并在
  `Pipeline/gates.sh` 注释中写明真实目标，避免"改门槛制造通过"。
- 无自动断言的 `red`（BUG-004 / 006 / 009）必须有固定机位截图命令，供人工比对。
- 修复一个 `red` 时，必须同时：改状态为 `green`、指出守住它的断言名、重跑 `Pipeline/run.sh`。
