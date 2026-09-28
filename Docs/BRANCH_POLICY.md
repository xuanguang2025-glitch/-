# 分支与提交策略

Part 6 Phase 34。目的：**防止多轮 AI 修改互相覆盖**，以及防止"看起来完成了"的东西进入主干。

## 分支

```
main                 只接受通过全部门禁的合并，禁止直接 push
develop              集成枝，每次合入必须 run.sh 全绿
feature/city         world_builder 角色
feature/ai           ai_systems 角色
feature/npc          ai_systems 角色
feature/vehicle      engine 角色
feature/creation     engine 角色
feature/render       technical_artist 角色
feature/perf         optimization 角色
bugfix/BUG-0xx       对应 Bugs/LEDGER.md 的条目
```

## 流程

```
领任务 → feature 分支开发 → 补 --*-test 断言 → 本地 Pipeline/run.sh
      → 推 develop → 审查（review.sh + 人工/智能体复核）→ 合 main → 打 tag
```

## 硬约束

1. **禁止直接 push `main`。** 由 `.githooks/pre-push` 拦（本地）+ CI 的分支保护（远端）。
2. **禁止用改门槛制造通过。** 门槛只允许在 `Pipeline/gates.sh` 一处修改，且必须在提交信息里
   写明前后数值与原因。
3. **无法证明改善的优化必须回退。** 本项目已有两次先例：50 m 远景地面网格（省 4.5 ms 但产生
   跨 chunk 裂缝）与桥面底板（几何确实产出，但截图看不出遮挡效果），两者均已回退并记入
   KNOWN_ISSUES。
4. **每个合并请求必须附一条符合 `AI_COMMUNICATION_PROTOCOL.md` 的交接消息**，
   并用 `Pipeline/check_msg.sh` 校验通过。
5. 提交信息写"为什么"，不写"做了什么"——文件名已经说明做了什么。

## 启用本地钩子

```bash
git config core.hooksPath .githooks
```

（只改本仓库的钩子路径，不动全局配置。）
