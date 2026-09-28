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
| BUG-011 | 城市模拟在**金钱完全守恒**的前提下依然塌缩：需求按全体人口计、收入只按就业者计，房租汇入只进不出的房东桶 → 模拟一年后每类商铺跌到接近 1 家 | green | `--sim-soak=8760`：`长周期后商铺总数没有塌缩` / `没有任何类别塌到只剩一家` / `运行一个月后就业上升而非塌缩` |
| BUG-012 | 价格 2% 步长在小额处被 `int()` 截断为 0（32×1.02=32.6→32），四类价格自播种值起永久冻结，状态里看起来"有价格"实则装饰 | green | `--sim-test`：`产能骤减后价格上调` / `产能过剩后价格下调` |
| BUG-013 | 上座率把"小时人流"除以"日容量"（量纲错误），所有类别恒为空闲，价格永远只向下 | green | `--sim-test` 同上两条（利用率驱动的定价必须两个方向都能被驱动） |
| BUG-014 | `Pipeline/lib.sh` 的 `require()` 只打印 GATE-FAIL、不改退出码，解析不到数值时流水线仍报 `PIPELINE: PASS` | green | 负测：`require "x" ""` 后 `RUNFAIL=1`；`Pipeline/gates.sh` 注释记录了这条 |
| BUG-015 | TrafficSystem 用 `1-0.35×wet` 在雨天**减少**车辆，而 CitySim 的出行需求在雨天**增加**——同一场雨存在两套相互矛盾的世界模型 | green | `--sim-test`：`雨天车辆系数高于晴天`；车辆数只由模拟需求给出，湿度只影响车速 |
| BUG-016 | `bootstrap()` 在 `--time=` 生效前播种 footfall / ride_demand，用钟点 17.4 而非请求时刻，首个整点前街景密度偏 | **red** | 一次整点推进即自动纠正；复现：`--time=3.0` 后看首行 `[sim]` 的 `crowd_f` |
| BUG-017 | `place()` 直接写 `objects` 并 `_realize`，绕过 `_put`，玩家放的商铺**永远不向经济登记**——编辑器一切正常，账本毫无变化 | green | `--create-test`：`放置商场后城市就业增加`（69407→69411）与 `撤销后回到放置前的就业` |
| BUG-018 | 分区规则生效后，`--demo-build` 的硬编码坐标落在黄浦核心区，塔楼被合法拒绝，演示截图只剩构件而看起来像"建筑生成坏了" | green | `ValidationTests.find_spots` 自检定位；截图复核命令：`--demo-build=2 --view=-0.06,0,2` |
| BUG-019 | `_check(what, got, want)` 被当作 `_check_that(cond, detail)` 使用，把 `"true"` 与 `"69407 -> 69411"` 相比，**通过的断言报 FAIL**（两个会话内复发两次） | green | `Pipeline/review.sh` R7（已用植入违规样本做正反例回归：有违规→FAIL，删除→PASS） |
| BUG-020 | 商铺登记若采用"每次存放后全表重算"，1000 件压力测试退化为 O(n²) | green | 改为按对象登记/撤销（`_register`/`_unregister`）；`--bench-stress=1000` 的 `per_object` 与拆分前同量级 |
| BUG-021 | 回滚接口先查版本链、后查"是否已是当前版本"，而当前版本不在链上——"回滚到已生效版本"返回误导性的 404 而不是 409 | green | `backend/test.mjs`：`回滚到当前版本被拒（不是空操作）` |
| BUG-022 | 三角面预算总量若每次放置都全表求和，压力路径同样退化；且增量账本一旦漂移就无人发现 | green | `--create-test`：`增量预算与全表重算一致`（放置若干件后与逐件 recount 对比） |

## red 项的处理约定

- `red` 项若已有门槛数值（BUG-002），门槛文件里保留**实测值**而不是理想值，并在
  `Pipeline/gates.sh` 注释中写明真实目标，避免"改门槛制造通过"。
- 无自动断言的 `red`（BUG-004 / 006 / 009）必须有固定机位截图命令，供人工比对。
- 修复一个 `red` 时，必须同时：改状态为 `green`、指出守住它的断言名、重跑 `Pipeline/run.sh`。
