#!/usr/bin/env bash
# train_watch.sh -- 通用训练看门狗（模型 / 框架无关，靠配置适配）。
#
# 采样 进程 / 日志 / GPU -> 判故障 -> 推送（自带日志尾部附件）-> 落盘 -> 退出。
# 与具体训练代码解耦：只认 pidfile、日志文件、退出码文件三样东西。
#
# 用法：
#   train_watch.sh --config watch.conf [--once] [--keep-running] [--dry-run]
#   train_watch.sh --config watch.conf --topic dimp-xxx    # 覆盖配置里的 topic
#
# 退出码：0=无故障(--once)或故障已上报；3=参数/配置错误
#
# 配置项见同目录 watch.conf.example。核心思想：脚本提供机制，项目只提供配置文件。
set -uo pipefail
shopt -s nullglob

CONFIG=""
ONCE=0
KEEP=0
DRY=0

# ---------- 默认值（config 可覆盖） ----------
NAME="train"
PIDFILE=""
CHILD_PIDFILE=""
EXIT_CODE_FILE=""
LOG=""
LOG_GLOB=""
INTERVAL=30
STALL_SEC=900
HEARTBEAT_SEC=300
TOPIC=""
NTFY_URL="https://ntfy.sh"
GPU="auto"             # auto | on | off
PGID_CHECK="auto"      # auto | on | off
NO_PROGRESS=0          # >0：连续 N 次采样无进展即告警
NO_PROGRESS_SEC=""     # 可选：无进展持续秒数（优先于 NO_PROGRESS）
FAULT_COOLDOWN=1800
STATE_DIR="${TRAIN_WATCH_STATE:-$HOME/.train-watch}"
PAT_OOM='CUDA out of memory|OutOfMemoryError|OOM when allocating|RESOURCE_EXHAUSTED|out of memory'
PAT_NAN='(loss|metric|acc|ppl)[=: ]+.*(nan|inf)'
PAT_TB='Traceback \(most recent call last\)|RuntimeError|Segmentation fault|core dumped'
EXTRA_PAT=""

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 3; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)       CONFIG="${2:?}"; shift 2 ;;
    --topic)        TOPIC="${2:?}"; shift 2 ;;
    --once)         ONCE=1; shift ;;
    --keep-running) KEEP=1; shift ;;
    --dry-run)      DRY=1; shift ;;
    -h|--help)      usage ;;
    *) echo "未知参数: $1" >&2; usage ;;
  esac
done
[[ -n "$CONFIG" ]] || { echo "缺少 --config" >&2; usage; }
[[ -f "$CONFIG" ]] || { echo "配置不存在: $CONFIG" >&2; exit 3; }

# ---------- 配置解析（只支持 key=value，不做 shell 求值） ----------
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
load_config() {
  local line k v
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"                       # 行内注释（值里别用 #）
    [[ -z "$(trim "$line")" ]] && continue
    [[ "$line" == *=* ]] || continue
    k="$(trim "${line%%=*}")"
    v="$(trim "${line#*=}")"
    case "$k" in
      name)            NAME="$v" ;;
      pidfile)         PIDFILE="$v" ;;
      child_pidfile)   CHILD_PIDFILE="$v" ;;
      exit_code_file)  EXIT_CODE_FILE="$v" ;;
      log)             LOG="$v" ;;
      log_glob)        LOG_GLOB="$v" ;;
      interval)        INTERVAL="$v" ;;
      stall_sec)       STALL_SEC="$v" ;;
      heartbeat_sec)   HEARTBEAT_SEC="$v" ;;
      topic)           TOPIC="$v" ;;
      ntfy_url)        NTFY_URL="$v" ;;
      gpu)             GPU="$v" ;;
      pgid_check)      PGID_CHECK="$v" ;;
      no_progress)     NO_PROGRESS="$v" ;;
      no_progress_sec) NO_PROGRESS_SEC="$v" ;;
      fault_cooldown)  FAULT_COOLDOWN="$v" ;;
      state_dir)       STATE_DIR="$v" ;;
      pattern_oom)     PAT_OOM="$v" ;;
      pattern_nan)     PAT_NAN="$v" ;;
      pattern_traceback) PAT_TB="$v" ;;
      extra_pattern)   EXTRA_PAT="${EXTRA_PAT:+$EXTRA_PAT|}$v" ;;
      *) echo "[watch] 忽略未知配置项: $k" >&2 ;;
    esac
  done < "$CONFIG"
}
load_config

# 相对路径按配置文件所在目录解析
CFG_DIR="$(cd "$(dirname "$CONFIG")" && pwd)"
abs() { [[ -z "$1" ]] && return; [[ "$1" == /* ]] && printf '%s' "$1" || printf '%s/%s' "$CFG_DIR" "$1"; }
PIDFILE="$(abs "$PIDFILE")"
CHILD_PIDFILE="$(abs "$CHILD_PIDFILE")"
EXIT_CODE_FILE="$(abs "$EXIT_CODE_FILE")"
LOG="$(abs "$LOG")"

mkdir -p "$STATE_DIR"
ALERT_FILE="$STATE_DIR/alert.json"

[[ -n "$PIDFILE" ]] || { echo "配置缺少 pidfile" >&2; exit 3; }
[[ -n "$LOG" || -n "$LOG_GLOB" ]] || { echo "配置缺少 log 或 log_glob" >&2; exit 3; }

ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }
NODE="$(hostname -s 2>/dev/null || echo remote)"

# ---------- 采样 ----------
pid_alive() { [[ -n "${1:-}" ]] && kill -0 "$1" 2>/dev/null; }
read_pid()   { [[ -f "${1:-}" ]] && tr -dc '0-9' < "$1" | head -c 12; }

pgid_alive() {  # 进程组存活：覆盖 launcher 已死、worker 成孤儿的场景
  [[ "$PGID_CHECK" == off ]] && return 1
  local pid pg
  pid="$(read_pid "$PIDFILE")"
  pid_alive "$pid" || return 1
  pg="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')"
  [[ -n "$pg" ]] && kill -0 -- "-$pg" 2>/dev/null
}

logfiles() {  # 输出被监听的日志文件列表
  if [[ -n "$LOG_GLOB" ]]; then
    printf '%s\n' $LOG_GLOB
  elif [[ -n "$LOG" ]]; then
    printf '%s\n' "$LOG"
  fi
}

log_newest_age() {  # 最近被写过的那个日志距现在多少秒；无文件返回 -1
  local f newest=-1 age
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    age=$(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0) ))
    if [[ $newest -lt 0 || $age -lt $newest ]]; then newest=$age; fi
  done < <(logfiles)
  echo "$newest"
}

log_tail() {  # log_tail <n>：取最近被写的那个文件的尾巴
  local n="${1:-40}" f best="" best_m=0 m
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    m=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    if [[ -z "$best" || $m -gt $best_m ]]; then best="$f"; best_m=$m; fi
  done < <(logfiles)
  [[ -n "$best" ]] || { echo "(no log)"; return; }
  tail -n "$n" "$best" 2>/dev/null
}

gpu_ok() {
  [[ "$GPU" == off ]] && return 1
  [[ "$GPU" == on ]]  && return 0
  command -v nvidia-smi >/dev/null 2>&1
}
GPU_SUMMARY="n/a"; GPU_UTIL_MAX=-1
sample_gpu() {
  GPU_SUMMARY="n/a"; GPU_UTIL_MAX=-1
  gpu_ok || return 0
  local out
  out="$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total \
         --format=csv,noheader,nounits 2>/dev/null)" || return 0
  [[ -n "$out" ]] || { GPU_SUMMARY="n/a"; return 0; }
  GPU_SUMMARY="$(awk -F', *' '{u+=$1; m+=$2; t+=$3; n++; if($1>mx) mx=$1}
                  END{printf "util~%d%% mem=%d/%dMiB gpus=%d", u/n, m, t, n}' <<<"$out")"
  GPU_UTIL_MAX="$(awk -F', *' 'BEGIN{mx=-1} {if($1>mx) mx=$1} END{print mx}' <<<"$out")"
}

read_exit_code() { [[ -f "${1:-}" ]] && tr -dc '0-9' < "$1" | head -c 3; }
classify_exit() {
  case "${1:-}" in
    0)   echo "EXIT_0" ;;
    1)   echo "ERROR" ;;
    130) echo "SIGINT" ;;
    137) echo "OOMKILLED" ;;
    139) echo "SEGFAULT" ;;
    143) echo "SIGTERM" ;;
    "")  echo "UNKNOWN" ;;
    *)   echo "EXIT_$1" ;;
  esac
}

# ---------- 推送 ----------
push() {  # push <prio> <tags> <title> <body-file>
  local prio="$1" tags="$2" title="$3" body="$4"
  if [[ -z "$TOPIC" || $DRY -eq 1 ]]; then
    echo "[push:dry] prio=$prio title=$title"
    sed 's/^/    /' "$body"
    return 0
  fi
  curl -s -m 20 -o /dev/null \
    -H "Title: $title" -H "Priority: $prio" -H "Tags: $tags" \
    --data-binary "@${body}" "${NTFY_URL}/${TOPIC}" >/dev/null 2>&1
}
push_attachment() {
  local file="$1" name="$2"
  [[ -z "$TOPIC" || $DRY -eq 1 ]] && return 0
  curl -s -m 30 -o /dev/null \
    -H "Filename: $name" -H "Title: log tail" -H "Priority: 3" \
    -T "$file" "${NTFY_URL}/${TOPIC}" >/dev/null 2>&1
}

# ---------- 判故障 ----------
emit_fault() {
  local code="$1" detail="$2" age bodyf
  age="$(log_newest_age)"
  bodyf="$STATE_DIR/.body.$$"
  {
    echo "run:    $NAME"
    echo "node:   $NODE"
    echo "code:   $code"
    echo "time:   $(ts)"
    echo "detail: $detail"
    echo "log:    $age s ago  ($(logfiles | tr '\n' ' '))"
    echo "gpu:    $GPU_SUMMARY"
    echo "------ tail 40 ------"
    log_tail 40
  } > "$bodyf"

  push 5 "rotating_light,warning" "[FAULT] $NAME: $code @ $NODE" "$bodyf"
  push_attachment "$bodyf" "fault_$(date +%Y%m%d_%H%M%S).txt"

  {
    echo "{"
    echo "  \"run\": \"$NAME\","
    echo "  \"code\": \"$code\","
    echo "  \"node\": \"$NODE\","
    echo "  \"time\": \"$(ts)\","
    echo "  \"log_age_s\": $age,"
    echo "  \"detail\": \"$(printf '%s' "$detail" | tr '"' "'" | tr '\n' ' ')\""
    echo "}"
  } > "$ALERT_FILE"

  rm -f "$bodyf"
  echo "$(ts) FAULT $code $detail" >> "$STATE_DIR/status.jsonl"
  echo "[watch] FAULT $code — $detail"
}

# ---------- 主循环 ----------
last_hb=0
last_fault_ts=0
last_fault_code=""
no_progress_samples=0
no_progress_since=0

while :; do
  now="$(date +%s)"
  age="$(log_newest_age)"
  sample_gpu

  pid="$(read_pid "$PIDFILE")"
  child="$(read_pid "$CHILD_PIDFILE")"
  alive=0
  if pid_alive "$pid" || pid_alive "$child" || pgid_alive; then alive=1; fi

  line="alive=$alive age=${age}s gpu=${GPU_SUMMARY}"
  echo "$(ts) $line" >> "$STATE_DIR/status.jsonl"
  [[ $ONCE -eq 1 ]] && echo "[watch] $line"

  fault=""; detail=""

  if [[ $alive -eq 0 ]]; then
    ec="$(read_exit_code "$EXIT_CODE_FILE")"
    fault="PROCESS_GONE"; detail="pid=${pid:-none} exit=${ec:-n/a} -> $(classify_exit "$ec")"
  elif [[ "$age" -lt 0 ]]; then
    fault="NO_LOG"; detail="日志文件不存在"
  elif [[ "$age" -gt "$STALL_SEC" ]]; then
    fault="LOG_STALL"; detail="age=${age}s > ${STALL_SEC}s"
  elif hit="$(log_tail 300 | grep -iE "$PAT_OOM" | tail -1)" && [[ -n "$hit" ]]; then
    fault="OOM"; detail="$hit"
  elif hit="$(log_tail 300 | grep -iE "$PAT_NAN" | tail -1)" && [[ -n "$hit" ]]; then
    fault="NAN"; detail="$hit"
  elif hit="$(log_tail 300 | grep -iE "$PAT_TB" | tail -1)" && [[ -n "$hit" ]]; then
    fault="TRACEBACK"; detail="$hit"
  elif [[ -n "$EXTRA_PAT" ]] && hit="$(log_tail 300 | grep -iE "$EXTRA_PAT" | tail -1)" && [[ -n "$hit" ]]; then
    fault="PATTERN"; detail="$hit"
  fi

  # 无进展：GPU 一直 0% 且日志不动
  if [[ -z "$fault" && $NO_PROGRESS -gt 0 && "$GPU_UTIL_MAX" -ge 0 ]]; then
    if [[ "$GPU_UTIL_MAX" -eq 0 && "$age" -gt $((INTERVAL * 2)) ]]; then
      no_progress_samples=$((no_progress_samples + 1))
      [[ $no_progress_since -eq 0 ]] && no_progress_since=$now
    else
      no_progress_samples=0; no_progress_since=0
    fi
    if [[ $no_progress_samples -ge $NO_PROGRESS ]]; then
      fault="NO_PROGRESS"
      detail="连续 $no_progress_samples 次采样 GPU 0% 且日志不动"
    fi
  fi

  if [[ -n "$fault" ]]; then
    # 常驻模式下同一故障按 cooldown 去重，避免刷屏
    if [[ $KEEP -eq 1 && "$fault" == "$last_fault_code" && $((now - last_fault_ts)) -lt $FAULT_COOLDOWN ]]; then
      :
    else
      emit_fault "$fault" "$detail"
      last_fault_ts=$now; last_fault_code="$fault"
    fi
    [[ $KEEP -eq 1 ]] || exit 0
    sleep "$INTERVAL"; continue
  fi

  if [[ $HEARTBEAT_SEC -gt 0 ]] && (( now - last_hb >= HEARTBEAT_SEC )); then
    bodyf="$STATE_DIR/.hb.$$"
    { echo "$NAME alive"; echo "$GPU_SUMMARY"; echo "$(log_tail 3)"; } > "$bodyf"
    push 2 "heartbeat" "[HB] $NAME alive @ $NODE" "$bodyf"
    rm -f "$bodyf"
    last_hb=$now
  fi

  [[ $ONCE -eq 1 ]] && exit 0
  sleep "$INTERVAL"
done
