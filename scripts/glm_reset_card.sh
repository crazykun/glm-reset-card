#!/usr/bin/env bash
# GLM 额度工具：查套餐剩余额度 / 查重置卡余额 / 选卡 / 消耗一张（逻辑对齐 GLMeter 桌面端）
# 依赖: curl + jq；鉴权复用 GLMeter 配置或环境变量 GLM_API_KEY / GLM_BASE_URL
set -euo pipefail

SCRIPT_NAME=$(basename "$0")
CONFIG_LINUX="${XDG_CONFIG_HOME:-$HOME/.config}/glmeter/config.toml"
CONFIG_MAC="$HOME/Library/Application Support/glmeter/config.toml"

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

鉴权来源（优先级从高到低）:
  1. 环境变量 GLM_API_KEY / GLM_BASE_URL
  2. GLMeter 配置 ~/.config/glmeter/config.toml
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
    for f in "$CONFIG_LINUX" "$CONFIG_MAC"; do
      if [[ -f "$f" ]]; then
        [[ -z "$API_KEY" ]] && API_KEY=$(toml_get "$f" api_key)
        [[ -z "$BASE_URL" ]] && BASE_URL=$(toml_get "$f" base_url)
        break
      fi
    done
  fi
  BASE_URL="${BASE_URL:-https://open.bigmodel.cn}"
  BASE_URL="${BASE_URL%/}"
  if [[ -z "$API_KEY" ]]; then
    echo "错误: 未找到 API Key（设 GLM_API_KEY，或配置 $CONFIG_LINUX）" >&2
    exit 1
  fi
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
    quota) load_config; cmd_quota ;;
    list)  load_config; cmd_list ;;
    pick) load_config; cmd_pick "${1:-five_hour}" ;;
    use)  [[ $# -ge 1 ]] || usage; load_config; cmd_use "$1" "${2:-five_hour}" ;;
    *)    usage ;;
  esac
}

main "$@"
