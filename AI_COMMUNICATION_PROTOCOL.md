# AI 通信协议

Part 6 Phase 32。目的只有一个：**让一次"完成"声明可被机器复核**，而不是靠自然语言互相信任。

## 诚实前提

本仓库**没有常驻 AI 进程**。没有 `AI_Agents/*/daemon.py`，也没有会自己写代码的服务。
真正的编排者是驱动本仓库的编码智能体，它按 [`AI_Agents/manifest.json`](AI_Agents/manifest.json)
里的角色契约工作。协议因此不是"进程间通信"，而是**交接与验收的数据契约**——
它是可执行的：`Pipeline/check_msg.sh` 会真的校验它。

## 消息格式

```json
{
  "agent": "engine",
  "task": "Phase 19.10 道路创造工具",
  "status": "done",
  "result": "success",
  "evidence": {
    "commands": ["Pipeline/run.sh"],
    "assertions": "24/24 PASS",
    "metrics": {"chunk_build_ms": 17.9},
    "files": ["src/creation/BuildTemplates.gd"]
  },
  "unknowns": ["桥 underside 标线穿透未修，见 BUG-004"]
}
```

## 字段约束

| 字段 | 必填 | 约束 |
|---|---|---|
| `agent` | ✅ | 必须是 manifest 中 `roles[].name` 或 `director` |
| `task` | ✅ | 非空字符串，含 Phase/Task 编号 |
| `status` | ✅ | `working` \| `blocked` \| `done` |
| `result` | ✅ | `success` \| `failure` \| `partial` \| `pending` |
| `evidence.commands` | `status=done` 时必填 | 至少一条**可复制执行**的命令 |
| `evidence.assertions` | `status=done` 时必填 | 形如 `24/24 PASS`，不接受"测试通过" |
| `evidence.files` | ✅ | 本次改动的文件列表 |
| `unknowns` | 建议 | 已知但未解决的事项，须指向 BUG ID |

## 硬规则

1. **`status=done` 必须带可复现命令与断言计数。** 没有 `evidence.assertions` 的 done 视为无效。
2. **`result=partial` 是合法终态。** 禁止把部分完成写成 success。
3. **被门禁拦住的改动必须回退或登记 BUG**，不允许"先合进去再说"。
4. **任何生成式内容（AI 或玩家）必须经 `Validation.check`**，不允许绕过校验直改世界。
5. 数字阈值只在 `Pipeline/gates.sh` 定义，消息里引用而不复制。

## 校验

```bash
Pipeline/check_msg.sh path/to/message.json
```

退出码 0 = 合规；非 0 = 打印每条不合规原因。
