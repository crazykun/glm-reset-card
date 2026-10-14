# glm-reset-card

Agent Skill：一句话查 GLM 套餐剩余额度、用掉 GLM 用量重置卡（智谱开放平台 / Z.ai）。

对 Claude Code / ZCode / Cursor 等支持 [Agent Skills](https://agentskills.io) 的编码助手说「**GLM 还有多少额度**」「**套餐还剩多少额度**」「**用一张 5 小时重置卡**」「**查下重置卡余额**」，它会自动查额度/查卡、选出最早过期的一张、向你确认后消耗——逻辑与桌面工具 [GLMeter](https://github.com/crazykun/GLMeter) 完全一致。

## 功能

- `quota`：套餐档位、5 小时窗口 / 每周额度用量百分比与下次重置时间、MCP 工具月度调用额度（分工具明细）
- `list` / `pick`：重置卡余额、自动选出最早过期的可用卡
- `use`：消耗一张重置卡立即重置对应额度（需确认）
- `setup`：鉴权引导配置——询问 API 地址与 Key（终端隐藏输入），调用只读接口验证通过后保存到 `~/.config/glm-reset-card/config.toml`（权限 600）；未配置时任何命令都会自动进入引导，`setup --show` 查看当前来源（Key 脱敏）

## 前置条件

- GLM API Key（智谱开放平台 [open.bigmodel.cn](https://open.bigmodel.cn) / 国际站 [api.z.ai](https://api.z.ai)， Coding 套餐含用量重置卡）
- `curl` + `jq`

## 安装

```bash
npx skills add crazykun/glm-reset-card
```

自动检测已安装的编码助手并放到对应目录。也可手动克隆：

```bash
git clone https://github.com/crazykun/glm-reset-card.git ~/.zcode/skills/glm-reset-card   # ZCode
git clone https://github.com/crazykun/glm-reset-card.git ~/.claude/skills/glm-reset-card  # Claude Code
```

## 配置鉴权（三选一）

1. 什么都不做——自动复用 [GLMeter](https://github.com/crazykun/GLMeter) 的配置 `~/.config/glmeter/config.toml`（已装 GLMeter 的用户无感）
2. 运行 `scripts/glm_reset_card.sh setup`：交互式询问地址和 Key（终端隐藏输入），调用只读接口验证通过后保存（Agent 助手在未配置时会主动向你要这两项信息并代为配置）；`setup --show` 查看当前来源
3. 环境变量：`GLM_API_KEY`（可选 `GLM_BASE_URL`，国际站设为 `https://api.z.ai`）

API Key 只保存在本机配置文件（权限 600）中用于调用，任何输出均为脱敏形式。

## 安全设计

- **用卡前必须确认**：`use` 会真实消耗一张卡且不可撤销，skill 强制要求先向你展示将消耗的卡（recordId + 过期时间）并获得明确同意
- **优先消耗最早过期的卡**：与官网规则一致，避免卡白白过期
- **幂等防重**：每次消耗带唯一 `requestId`；失败不自动重试，先查卡状态再决定，杜绝重复消耗

## License

[MIT](LICENSE)
