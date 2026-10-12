# glm-reset-card

Agent Skill：一句话用掉 GLM 用量重置卡（智谱开放平台 / Z.ai）。

对 Claude Code / ZCode / Cursor 等支持 [Agent Skills](https://agentskills.io) 的编码助手说「**用一张 5 小时重置卡**」「**查下重置卡余额**」，它会自动查卡、选出最早过期的一张、向你确认后消耗——逻辑与桌面工具 [GLMeter](https://github.com/crazykun/GLMeter) 的「点击使用重置卡」完全一致。

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

## 配置鉴权（二选一）

1. 环境变量：`GLM_API_KEY`（可选 `GLM_BASE_URL`，国际站设为 `https://api.z.ai`）
2. 什么都不做——自动复用 [GLMeter](https://github.com/crazykun/GLMeter) 的配置 `~/.config/glmeter/config.toml`

API Key 只在本机读取使用，不会出现在任何输出里。

## 安全设计

- **用卡前必须确认**：`use` 会真实消耗一张卡且不可撤销，skill 强制要求先向你展示将消耗的卡（recordId + 过期时间）并获得明确同意
- **优先消耗最早过期的卡**：与官网规则一致，避免卡白白过期
- **幂等防重**：每次消耗带唯一 `requestId`；失败不自动重试，先查卡状态再决定，杜绝重复消耗

## License

[MIT](LICENSE)
