#!/usr/bin/env bash
# run_train.sh -- 启动训练并登记运行状态，供 train_watch.sh 判活与归因。
#
# 它解决三件事：
#   1) 写 pidfile（wrapper 自己的 pid，用于存活检测）
#   2) 写子进程 pid 到 <pidfile>.child（防止 wrapper 活着但训练已死）
#   3) 记录真实退出码（137=被 OOM killer 杀、139=段错误、1=异常……差别很大）
#
# 用法：
#   run_train.sh --pidfile runs/x/train.pid --log runs/x/train.log \
#                --exit-code-file runs/x/exit_code -- <命令> [参数...]
#
# 例：
#   run_train.sh --pidfile run/train.pid --log run/train.log \
#                --exit-code-file run/exit_code -- .venv/bin/python train.py --epochs 10
set -uo pipefail

PIDFILE=""
LOG=""
EXITCODE=""
CMD=()

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 3; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pidfile)        PIDFILE="${2:?}"; shift 2 ;;
    --log)            LOG="${2:?}"; shift 2 ;;
    --exit-code-file) EXITCODE="${2:?}"; shift 2 ;;
    --)               shift; CMD=("$@"); break ;;
    -h|--help)        usage ;;
    *)                echo "未知参数: $1" >&2; usage ;;
  esac
done

[[ -n "$PIDFILE" && -n "$LOG" && -n "$EXITCODE" ]] || usage
[[ ${#CMD[@]} -gt 0 ]] || { echo "缺少 -- 之后的命令" >&2; usage; }

mkdir -p "$(dirname "$PIDFILE")" "$(dirname "$LOG")" "$(dirname "$EXITCODE")"
echo $$ > "$PIDFILE"
printf '%s\n' "${CMD[*]}" > "${PIDFILE%.pid}.cmd"

: > "$LOG"
"${CMD[@]}" >> "$LOG" 2>&1 &
child=$!
echo "$child" > "${PIDFILE}.child"

cleanup() {
  echo "[run] 收到信号，转发给训练进程 $child" >&2
  kill -TERM "$child" 2>/dev/null || true
}
trap cleanup INT TERM

rc=0
while :; do
  wait "$child"; rc=$?
  kill -0 "$child" 2>/dev/null || break
done

echo "$rc" > "$EXITCODE"
echo "[run] 训练退出 rc=$rc" | tee -a "$LOG" >&2
exit "$rc"
