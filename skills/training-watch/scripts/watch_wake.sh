#!/usr/bin/env bash
# watch_wake.sh -- 本机叫醒器：轮询推送 topic，读到故障就退出（作业结束 = 唤醒 agent）。
#
# 与具体训练无关：只要有人往 topic 发 priority>=5 或标题含 [FAULT] 的消息就触发。
#
# 退出码（关键语义）：
#   0 = 收到故障，证据已落盘 -> 后台作业结束 -> 运行时唤醒 agent
#   2 = 超时，什么都没发生   -> 不该叫醒人
#   1 = 参数错误
#
# 用法：
#   watch_wake.sh --topic <t> [--interval 10] [--timeout 3600] [--dir <告警目录>]
#   watch_wake.sh --topic <t> --once          # 调试：只看一次
#
# 必须用 run_in_background 起，否则退出码没有接收方。
set -uo pipefail

TOPIC=""
INTERVAL=10
TIMEOUT=3600
OUT_DIR="${TRAIN_WATCH_ALERTS:-$PWD/.train-watch/alerts}"
ONCE=0
NTFY_URL="https://ntfy.sh"

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --topic)    TOPIC="${2:?}"; shift 2 ;;
    --interval) INTERVAL="${2:?}"; shift 2 ;;
    --timeout)  TIMEOUT="${2:?}"; shift 2 ;;
    --dir)      OUT_DIR="${2:?}"; shift 2 ;;
    --ntfy-url) NTFY_URL="${2:?}"; shift 2 ;;
    --once)     ONCE=1; shift ;;
    -h|--help)  usage ;;
    *) echo "未知参数: $1" >&2; usage ;;
  esac
done

[[ -n "$TOPIC" ]] || { echo "缺少 --topic" >&2; usage; }
command -v jq >/dev/null || { echo "需要 jq" >&2; exit 1; }
command -v curl >/dev/null || { echo "需要 curl" >&2; exit 1; }

mkdir -p "$OUT_DIR"
STATE="$OUT_DIR/.since_$TOPIC"

# 首次从"现在"开始，避免重放历史消息
[[ -f "$STATE" ]] || date +%s > "$STATE"
last_ts="$(cat "$STATE" 2>/dev/null || date +%s)"
deadline=$(( $(date +%s) + TIMEOUT ))

echo "[wake] 监听 topic=$TOPIC 间隔=${INTERVAL}s 超时=${TIMEOUT}s 输出=$OUT_DIR"

while :; do
  resp="$(curl -s -m 20 "${NTFY_URL}/${TOPIC}/json?poll=1&since=${last_ts}" 2>/dev/null)"
  rc=$?

  if [[ $rc -ne 0 ]]; then
    echo "[wake] 网络错误 (curl rc=$rc)，继续重试" >&2
  elif [[ -n "$resp" ]]; then
    hits="$(printf '%s\n' "$resp" \
      | jq -rc 'select(.event=="message") | {time, priority:(.priority//3), title:(.title//""), message:(.message//"")}' 2>/dev/null)"
    if [[ -n "$hits" ]]; then
      while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        t="$(jq -r '.time' <<<"$line")"
        prio="$(jq -r '.priority' <<<"$line")"
        title="$(jq -r '.title' <<<"$line")"
        msg="$(jq -r '.message' <<<"$line")"

        [[ "$t" -gt "$last_ts" ]] 2>/dev/null && { last_ts="$t"; echo "$last_ts" > "$STATE"; }

        if [[ "$prio" -ge 5 || "$title" == *"[FAULT]"* ]]; then
          ts="$(date -d "@$t" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "@$t")"
          file="$OUT_DIR/$(date -d "@$t" '+%Y%m%d_%H%M%S' 2>/dev/null || echo "alert_$t").txt"
          { echo "time:   $ts"; echo "title:  $title"; echo "prio:   $prio"; echo "---"; echo "$msg"; } > "$file"

          echo
          echo "########## ALERT ##########"
          echo "time:  $ts"
          echo "title: $title"
          echo "prio:  $prio"
          echo "saved: $file"
          echo "---------------------------"
          echo "$msg"
          echo "########## /ALERT ########"
          echo "[wake] 收到故障，退出 -> 作业结束 -> 唤醒 agent"
          exit 0
        fi
      done <<<"$hits"
    fi
  fi

  [[ $ONCE -eq 1 ]] && { echo "[wake] 单次模式，未发现故障"; exit 2; }
  [[ $(date +%s) -ge $deadline ]] && { echo "[wake] 超时 ${TIMEOUT}s，未收到故障"; exit 2; }
  sleep "$INTERVAL"
done
