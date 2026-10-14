---
name: glm-reset-card
version: 0.2.0
description: 查询 GLM Coding 套餐剩余额度与使用用量重置卡（智谱开放平台 / Z.ai）：查 5 小时窗口/每周额度用量与下次重置时间、MCP 月度调用额度、重置卡余额，以及使用一张 5 小时或周额度重置卡立即重置对应用量额度。当用户说「glm还有多少额度」「套餐还剩多少额度」「额度用了多少」「什么时候重置/恢复」「用/使用重置卡」「帮我重置 5 小时额度」「重置周额度」「重置卡还剩几张」等时使用。查询类命令只读；消耗卡片不可撤销，调用 use 前必须获得用户明确确认。
---

# GLM 套餐额度与用量重置卡

查询侧复刻 GLMeter 桌面端的额度监控接口，用卡侧复刻其「点击使用重置卡」逻辑。全部操作通过 `scripts/glm_reset_card.sh` 完成（依赖 curl + jq），查询均为只读。

## 使用流程

脚本位于本技能目录下：`scripts/glm_reset_card.sh`（各 Agent 均按技能目录解析相对路径，下文以 `glm_reset_card.sh` 代称）。

1. **查套餐额度**（只读，回答「还有多少额度 / 用了多少 / 什么时候重置」）：
   ```bash
   glm_reset_card.sh quota   # 套餐档位 + 5小时/每周窗口用量与下次重置时间 + MCP 月度调用额度
   ```
   输出字段解读：
   - `five_hour` / `week`：token 额度窗口，接口只给百分比——`used_pct` 已用、`remaining_pct` 剩余、`next_reset` 下次自然重置时间（本地时区）。`week` 为 `null` 表示当前套餐没有周窗口（如 lite）。
   - `activated: false`：该窗口还没发起过 API 请求，额度统计尚未生成，`next_reset` 为空；发起任意一次对话后即可见（GLMeter 的「激活」即此原理）。
   - `mcp_monthly`：MCP 工具月度调用次数（如 search-prime / web-reader），`used/total/remaining` 为次数，`by_model` 为分工具明细。
2. **查卡选卡**（只读）：
   ```bash
   glm_reset_card.sh list                   # 两类卡的余额、可用卡列表、上次用卡时间
   glm_reset_card.sh pick [five_hour|week]  # 自动选出最早过期的可用卡，输出 {"recordId":..,"expireTime":".."}
   ```
3. **向用户展示并确认**（必须，见安全红线）：告知将消耗哪张卡（recordId、过期时间、重置哪种额度）。
4. **消耗**（不可撤销）：
   ```bash
   glm_reset_card.sh use <recordId> [five_hour|week]
   ```
   成功输出 `✓ …重置卡使用成功（recordId=…, requestId=…）`。

不传类型时默认 `five_hour`（5 小时重置卡）。`week` 卡会同时重置周额度和 5 小时窗口。

用户只问额度时，先 `quota`；若某窗口已接近用尽且 `list` 显示有可用卡，可顺带告知剩余卡数并询问是否用卡（但绝不能未经确认直接 `use`）。

## 安全红线

- **`use` 消耗一张卡且不可撤销**。执行前必须在当前对话中获得用户对「这一张卡（含 recordId 和过期时间）」的明确确认；用户没有点头就只停留在 quota/pick/list。这与 GLMeter 的确认弹窗逻辑一致：宁可不执行，也不静默消耗。
- **不要自动重试失败的 use**。脚本每次调用生成新的 requestId（幂等键），换新 ID 重试可能重复消耗。use 超时或结果不明时，先 `list` 确认该卡是否已被消耗，再决定下一步。
- 脚本不会回显 API Key；对话中也不要输出配置文件原始内容。

## 鉴权与配置

优先级：环境变量 `GLM_API_KEY` / `GLM_BASE_URL` > GLMeter 桌面端配置 `~/.config/glmeter/config.toml`（macOS 为 `~/Library/Application Support/glmeter/config.toml`）。`base_url` 默认 `https://open.bigmodel.cn`，国际站为 `https://api.z.ai`。

## 错误处理

- 这些接口 HTTP 恒为 200，业务结果看 `code`/`success`；失败时脚本输出 `错误: <msg>` 并以非零码退出（如 401 Key 无效、`不支持的重置对象类型`）。
- `pick` 报「没有可用的…重置卡」时向用户说明余额为零，可引导去官网个人用量页获取。
- `quota` 中 token 窗口只有百分比没有绝对 token 数，这是官网接口本身的行为，直接按百分比汇报即可。
