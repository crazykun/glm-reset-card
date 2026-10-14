#!/usr/bin/env bash
# GLM 额度工具：查套餐剩余额度 / 查重置卡余额 / 选卡 / 消耗一张 / 配置鉴权（逻辑对齐 GLMeter 桌面端）
# 依赖: curl + jq；鉴权来源: 环境变量 > setup 写入的本技能配置 > GLMeter 配置
set -euo pipefail

SCRIPT_NAME=$(basename "$0")
CONFIG_LINUX="${XDG_CONFIG_HOME:-$HOME/.config}/glmeter/config.toml"
CONFIG_MAC="$HOME/Library/Application Support/glmeter/config.toml"
CONFIG_OWN_LINUX="${XDG_CONFIG_HOME:-$HOME/.config}/glm-reset-card/config.toml"
CONFIG_OWN_MAC="$HOME/Library/Application Support/glm-reset-card/config.toml"
if [[ "$(uname -s)" == "Darwin" ]]; then
  CONFIG_OWN=$CONFIG_OWN_MAC
else
  CONFIG_OWN=$CONFIG_OWN_LINUX
fi

for dep in curl jq; do
  command -v "$dep" >/dev/null 2>&1 || { echo "错误: 缺少依赖 $dep，请先安装" >&2; exit 1; }
done

usage() {
  cat <<EOF
用法:
  $SCRIPT_NAME quota                    查询套餐剩余额度（只读：5小时/周窗口、MCP 月度调用）
  $SCRIPT_NAME list                     查询重置卡余额（只读）
  $SCRIPT_NAME pick [five_hour|week]    选出最早过期的可用卡，默认 five_hour（只读）
  $SCRIPT_NAME use <recordId> [five_hour|week]  消耗一张重置卡（不可撤销！）
  $SCRIPT_NAME setup [--base-url URL] [--api-key KEY] [--show]
                                        配置鉴权：无参数进入交互引导（询问地址与 Key，验证后保存）

鉴权来源（优先级从高到低）:
  1. 环境变量 GLM_API_KEY / GLM_BASE_URL
  2. 本技能配置 ~/.config/glm-reset-card/config.toml（setup 写入，权限 600）
  3. GLMeter 配置 ~/.config/glmeter/config.toml
EOF
  exit 2
}

# 从 toml 单行取值: api_key = 'xxx' 或 api_key = "xxx"
toml_get() {
  [[ -f "$1" ]] || return 0
  sed -nE "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*[\"']([^\"']+)[\"'].*/\1/p" "$1" | head -1
}

load_config() {
  API_KEY="${GLM_API_KEY:-}"
  BASE_URL="${GLM_BASE_URL:-}"
  if [[ -z "$API_KEY" || -z "$BASE_URL" ]]; then
    [[ -z "$API_KEY" ]] && API_KEY=$(toml_get "$CONFIG_OWN" api_key)
    [[ -z "$BASE_URL" ]] && BASE_URL=$(toml_get "$CONFIG_OWN" base_url)
  fi
  if [[ -z "$API_KEY" || -z "$BASE_URL" ]]; then
    for f in "$CONFIG_LINUX" "$CONFIG_MAC"; do
      if [[ -f "$f" ]]; then
        [[ -z "$API_KEY" ]] && API_KEY=$(toml_get "$f" api_key)
        [[ -z "$BASE_URL" ]] && BASE_URL=$(toml_get "$f" base_url)
        break
      fi
    done
  fi
  if [[ -z "$API_KEY" ]]; then
    # 未配置：交互终端直接进入引导；非交互（Agent 调用）给出可执行的指引
    if [[ -t 0 ]]; then
      echo "未找到 API Key，进入配置引导（保存到 $CONFIG_OWN）..." >&2
      cmd_setup
      API_KEY=$(toml_get "$CONFIG_OWN" api_key)
      BASE_URL=$(toml_get "$CONFIG_OWN" base_url)
      [[ -n "$API_KEY" ]] || exit 1
    else
      echo "错误: 未找到 API Key。任选其一：" >&2
      echo "  1. 运行 $SCRIPT_NAME setup --api-key <KEY> [--base-url <URL>] 写入配置（验证通过才保存）" >&2
      echo "  2. 设置环境变量 GLM_API_KEY（可选 GLM_BASE_URL）" >&2
      echo "  3. 安装 GLMeter 后复用其配置 ~/.config/glmeter/config.toml" >&2
      exit 1
    fi
  fi
  BASE_URL="${BASE_URL:-https://open.bigmodel.cn}"
  BASE_URL="${BASE_URL%/}"
}

trim() { # 去除首尾空白（含粘贴带入的 \r）
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s\n' "$s"
}

mask_key() { # 脱敏显示：只露头尾各几位
  local k=$1 n=${#1}
  if ((n <= 10)); then
    echo "****（长度 $n）"
  else
    echo "${k:0:6}…${k: -4}（长度 $n）"
  fi
}

# 当前生效的鉴权来源（不含完整 Key，可安全展示）
auth_status() {
  local key url src f
  key="${GLM_API_KEY:-}"
  if [[ -n "$key" ]]; then
    src="环境变量 GLM_API_KEY"
    url="${GLM_BASE_URL:-}"
  else
    key=$(toml_get "$CONFIG_OWN" api_key)
    [[ -n "$key" ]] && { src="本技能配置 $CONFIG_OWN"; url=$(toml_get "$CONFIG_OWN" base_url); }
  fi
  if [[ -z "$key" ]]; then
    for f in "$CONFIG_LINUX" "$CONFIG_MAC"; do
      key=$(toml_get "$f" api_key)
      [[ -n "$key" ]] && { src="GLMeter 配置 $f"; url=$(toml_get "$f" base_url); break; }
    done
  fi
  if [[ -z "$key" ]]; then
    echo "状态: 未配置（运行 $SCRIPT_NAME setup 引导配置）"
    echo "默认地址: https://open.bigmodel.cn"
  else
    echo "状态: 已配置（来源: $src）"
    echo "API 地址: ${url:-https://open.bigmodel.cn}"
    echo "API Key: $(mask_key "$key")"
  fi
}

validate_auth() { # validate_auth <api_key> <base_url>：调用只读额度接口验证，失败时输出服务端原因
  local resp
  resp=$(curl --silent --show-error --max-time 30 \
    -H "Authorization: Bearer $1" "$2/api/monitor/usage/quota/limit" 2>&1) || return 1
  if jq -e '.code == 200 and .success == true' >/dev/null 2>&1 <<<"$resp"; then
    return 0
  fi
  echo "  服务端返回: $(jq -r '.msg // "响应异常"' <<<"$resp" 2>/dev/null || echo '响应不是 JSON')" >&2
  return 1
}

save_config() { # save_config <api_key> <base_url>：TOML 单引号字符串，与 GLMeter 同格式
  mkdir -p "$(dirname "$CONFIG_OWN")"
  printf "api_key = '%s'\nbase_url = '%s'\n" "$1" "$2" > "$CONFIG_OWN"
  chmod 600 "$CONFIG_OWN"
}

# 配置鉴权：无参数进入交互引导（Key 隐藏输入、验证通过才保存）；Agent 非交互环境用 --api-key/--base-url 直传
cmd_setup() {
  local base_url="" api_key="" show=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --show)     show=1; shift ;;
      --base-url) [[ $# -ge 2 ]] || usage; base_url=$2; shift 2 ;;
      --api-key)  [[ $# -ge 2 ]] || usage; api_key=$2; shift 2 ;;
      *)          usage ;;
    esac
  done

  if ((show)); then
    auth_status
    return
  fi

  local interactive=0 retry
  [[ -z "$api_key" ]] && interactive=1
  if ((interactive)) && [[ ! -t 0 ]]; then
    echo "错误: 非交互环境无法询问，请用参数配置: $SCRIPT_NAME setup --api-key <KEY> [--base-url <URL>]" >&2
    exit 2
  fi
  if ((interactive)); then
    echo "配置 GLM 鉴权（保存到 $CONFIG_OWN，仅本机生效，权限 600，验证通过才写入）"
  fi

  while :; do
    if ((interactive)); then
      base_url="" api_key=""
      read -rp "API 地址（回车默认 https://open.bigmodel.cn，国际站填 https://api.z.ai）: " base_url
      read -rsp "API Key（输入不回显）: " api_key
      echo
      base_url=$(trim "$base_url")
      api_key=$(trim "$api_key")
    fi
    base_url="${base_url:-https://open.bigmodel.cn}"
    base_url="${base_url%/}"

    if [[ -z "$api_key" ]] || [[ "$api_key" = *"'"* || "$api_key" = *'"'* ]]; then
      echo "错误: API Key 为空或包含引号字符" >&2
      ((interactive)) || exit 1
      continue
    fi
    if [[ "$base_url" = *"'"* || "$base_url" = *'"'* ]]; then
      echo "错误: 地址不能包含引号字符" >&2
      ((interactive)) || exit 1
      continue
    fi
    if [[ ! "$base_url" =~ ^https?:// ]]; then
      echo "错误: 地址需以 http:// 或 https:// 开头（当前: $base_url）" >&2
      ((interactive)) || exit 1
      continue
    fi

    echo "→ 正在验证（调用只读额度接口）..."
    if validate_auth "$api_key" "$base_url"; then
      save_config "$api_key" "$base_url"
      echo "✓ 验证通过，已保存到 $CONFIG_OWN"
      auth_status
      return
    fi
    echo "验证失败（地址或 Key 不正确）" >&2
    ((interactive)) || exit 1
    read -rp "重新输入？(Y/n) " retry
    [[ "$retry" =~ ^[Nn] ]] && exit 1
  done
}

kind_key() { [[ "$1" == week ]] && echo weekResets || echo fiveHourResets; }
kind_cn()   { [[ "$1" == week ]] && echo "周额度" || echo "5小时额度"; }
kind_type() { [[ "$1" == week ]] && echo WEEK || echo FIVE_HOUR; }

new_request_id() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr 'A-Z' 'a-z'
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    python3 -c 'import uuid; print(uuid.uuid4())'
  fi
}

api_call() { # api_call <method> <url> [json_body]
  local method=$1 url=$2 body=${3:-}
  local args=(--silent --show-error --max-time 30
    -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json"
    -X "$method" "$url")
  [[ -n "$body" ]] && args+=(-d "$body")
  curl "${args[@]}"
}

# 控制台风格响应：HTTP 恒 200，业务结果在 code/success；失败时打 msg 到 stderr 并退出
biz_data() {
  local body=$1 msg
  if ! jq -e '.code == 200 and .success == true' >/dev/null 2>&1 <<<"$body"; then
    msg=$(jq -r '.msg // ("code " + ((.code // -1) | tostring))' <<<"$body" 2>/dev/null) || msg="响应不是合法 JSON"
    echo "错误: ${msg:-未知业务错误}" >&2
    exit 1
  fi
  jq '.data' <<<"$body"
}

fetch_cards() {
  biz_data "$(api_call GET "$BASE_URL/api/biz/customer-package-reset/list?targetType=PERSONAL")"
}

fetch_quota() {
  biz_data "$(api_call GET "$BASE_URL/api/monitor/usage/quota/limit")"
}

cmd_list() {
  fetch_cards | jq '{
    five_hour: {
      total: (.fiveHourResets | length),
      available: [.fiveHourResets[] | select(.available)],
      last_use: .lastFiveHourResetTime
    },
    week: {
      total: (.weekResets | length),
      available: [.weekResets[] | select(.available)],
      last_use: .lastWeekResetTime
    }
  }'
}

# 套餐用量（GLMeter 同款接口）：TOKENS_LIMIT 按 nextResetTime 排序，第 0/1 个即 5小时/每周窗口；
# TIME_LIMIT 为 MCP 月度调用额度，注意官网字段 usage=总额度、currentValue=已用
cmd_quota() {
  fetch_quota | jq '
    def ts: if . == null then null else (. / 1000 | localtime | strftime("%Y-%m-%d %H:%M")) end;
    def window: if . == null then null else {
      used_pct: (.percentage // 0),
      remaining_pct: (100 - (.percentage // 0)),
      activated: (.nextResetTime != null),
      next_reset: (.nextResetTime | ts)
    } end;
    . as $d
    | [$d.limits[]? | select(.type == "TOKENS_LIMIT")]
      | sort_by(if .nextResetTime == null then 9e15 else .nextResetTime end)
      | . as $w
      | {
          level: ($d.level // null),
          five_hour: ($w[0] | window),
          week: ($w[1] | window),
          mcp_monthly: ([$d.limits[]? | select(.type == "TIME_LIMIT")][0]
            | if . == null then null else {
                used: (.currentValue // 0),
                total: (.usage // 0),
                remaining: ((.usage // 0) - (.currentValue // 0)),
                used_pct: (.percentage // 0),
                next_reset: (.nextResetTime | ts),
                by_model: ([.usageDetails[]? | select(.usage > 0) | {(.modelCode // "?"): .usage}] | add // {})
              } end)
        }'
}

# 与 GLMeter 一致：只在 available 的卡里选 expireTime 最早的一张（格式统一，字典序即时间序）
cmd_pick() {
  local kind=${1:-five_hour} picked
  picked=$(fetch_cards | jq -r --arg k "$(kind_key "$kind")" \
    '.[$k] | map(select(.available)) | min_by(.expireTime) | if . then tojson else "" end')
  if [[ -z "$picked" ]]; then
    echo "没有可用的$(kind_cn "$kind")重置卡" >&2
    exit 1
  fi
  echo "$picked"
}

cmd_use() {
  local record_id=$1 kind=${2:-five_hour}
  [[ "$record_id" =~ ^[0-9]+$ ]] || { echo "错误: recordId 必须是数字" >&2; exit 2; }
  local rid reset_type
  rid=$(new_request_id)
  reset_type=$(kind_type "$kind")
  local body
  body=$(api_call POST "$BASE_URL/api/biz/customer-package-reset/use" \
    "{\"targetType\":\"PERSONAL\",\"resetType\":\"$reset_type\",\"recordId\":$record_id,\"requestId\":\"$rid\"}")
  biz_data "$body" >/dev/null
  echo "✓ $(kind_cn "$kind")重置卡使用成功（recordId=$record_id, requestId=$rid）"
}

main() {
  local cmd=${1:-}
  shift || true
  case "$cmd" in
    setup) cmd_setup "$@" ;;
    quota) load_config; cmd_quota ;;
    list)  load_config; cmd_list ;;
    pick) load_config; cmd_pick "${1:-five_hour}" ;;
    use)  [[ $# -ge 1 ]] || usage; load_config; cmd_use "$1" "${2:-five_hour}" ;;
    *)    usage ;;
  esac
}

main "$@"
