---
name: training-watch
license: MIT
description: "Supervise any model's remote SSH training with a config-driven watchdog: detects process death (with exit-code attribution), log stall, OOM, NaN or tracebacks, pushes alerts with log tails through ntfy, and wakes the session so the agent can diagnose and respond. Use when the user asks to 监督/盯/监控 a training run, to be alerted when a remote job dies, to sync training logs back, or before starting a long training that must not silently fail. Works for PyTorch / TensorFlow / JAX / torchrun / DeepSpeed / single-GPU / CPU."
---

# 通用训练看门狗（模型 / 框架无关）

远端跑 watchdog → 判故障 → 推送（含日志尾部）→ 本机轮询命中即退出 → 作业结束 → 运行时唤醒本会话。

与训练代码只有三个约定，任何框架把这三样落到文件就能被监督：

| 探针 | 回答的问题 | 谁写 |
|---|---|---|
| `pidfile` + `<pidfile>.child` | 还活着吗 | `run_train.sh` |
| `exit_code_file` | 怎么死的（137=OOM killer、139=段错误、1=异常） | `run_train.sh` |
| `log` / `log_glob` | 在动吗、报了什么错 | 你的训练脚本 |

**用**：远端长训练，要求「出问题叫我 / 别静默死 / 日志带回来」。
**不用**：训练在本机跑 → 直接后台作业 + `job_output`。

## 脚本在哪

都在本技能目录的 `scripts/` 下（与 SKILL.md 同级，先 `ls` 确认绝对路径）：

| 文件 | 跑在哪 | 作用 |
|---|---|---|
| `train_watch.sh` | 远端 | 采样判故障、推送、落盘 alert |
| `run_train.sh` | 远端 | 包一层启动训练，写 pid / child pid / 退出码 |
| `watch_wake.sh` | 本机 | 轮询 topic，命中故障即退出（唤醒信号） |
| `watch.conf.example` | 远端 | 配置模板 |

用 `ssh_upload` 传远端，`chmod +x`。**不要用 heredoc 拼长脚本**，引号会坏。

### 换一个宿主时（Claude Code / Cursor / 其它）

本文用的是 DeepSeek Harness 的工具名，等价操作：

| 本文写法 | 通用含义 |
|---|---|
| `ssh_upload` / `ssh_exec` | 把文件传到远端 / 在远端执行命令 |
| `run_in_background` | 作为后台作业运行，并保留退出码 |
| `job_kill` | 终止该后台作业 |
| `~/.dsh/skills/` | 宿主自己的技能目录 |


## 深入阅读（按需，不必开头就全读）

这些文件不会被自动加载，需要时用 `read` 打开：

| 文件 | 什么时候读 |
|---|---|
| `references/design.md` | 想知道为什么是「远端推、本机收」、三个探针的取舍、实测数据、为什么不自动 resume |
| `references/troubleshooting.md` | 告警没来 / 误报 / 多 rank 判定 / 换机器后不工作 / 推送太吵 |

## 步骤 0：前置检查

```bash
command -v curl jq                                              # 本机
curl -s -m 8 -o /dev/null -w "%{http_code}\n" https://ntfy.sh   # 本机 + 远端各一次，期望 200
command -v curl tar nvidia-smi                                  # 远端；无 GPU 则配置 gpu=off
ssh -o BatchMode=yes <host> true && echo "ssh OK -> 变体 A"
```

本机 ssh 不可用（系统 ssh_config 损坏 / 无密钥 / 防火墙拦端口）是本方案的常见前提：**远端推、本机收**。

## 步骤 1：生成 topic

```bash
TOPIC="train-$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
```

topic 即密码。日志经第三方，敏感场景在配置里改 `ntfy_url=` 指向自托管。

## 步骤 2：写配置

```ini
name=exp-a
pidfile=run/train.pid
child_pidfile=run/train.pid.child
exit_code_file=run/train.exit
log=run/train.log            # 多 rank 改成 log_glob=run/rank*.log
interval=30
stall_sec=900                # 必须大于日志刷盘间隔，否则假 STALL
heartbeat_sec=300
gpu=auto                     # CPU / MPS / TPU 设 off
pgid_check=auto
no_progress=0                # >0：连续 N 次 GPU 0% 且日志不动即告警
topic=<你的 topic>
# pattern_oom / pattern_nan / pattern_traceback / extra_pattern 按实际日志改
```

先验：`train_watch.sh --config run/watch.conf --once --dry-run`（不推送，只采样一次并打印）。

## 步骤 3：启动

```bash
# 远端 tmux：训练（必须经 run_train.sh，否则没有退出码归因）
nohup bash run_train.sh --pidfile run/train.pid --log run/train.log \
  --exit-code-file run/train.exit -- .venv/bin/python train.py > /dev/null 2>&1 &

# 远端：看门狗（独立于训练）
nohup bash train_watch.sh --config run/watch.conf > run/watch.log 2>&1 &

# 本机：叫醒器（必须 run_in_background，退出码才有接收方）
watch_wake.sh --topic "$TOPIC" --interval 10 --timeout 86400
```

## 步骤 4：验收（先演练再上真训练）

```bash
bash run_train.sh --pidfile /tmp/t/train.pid --log /tmp/t/train.log \
  --exit-code-file /tmp/t/train.exit -- \
  bash -c 'for i in 1 2 3; do echo "ep $i loss=0.5"; sleep 2; done; exit 3' &
# interval=2 跑一遍 watch，期望：FAULT PROCESS_GONE — exit=3 -> EXIT_3
```

成功标志：本会话**在没有用户输入的情况下**自行开一轮并打印 ALERT 块。
未触发先查三件事：topic 两边一致 / 远端 `watch.log` / `curl -s "https://ntfy.sh/$TOPIC/json?poll=1"`。

## 步骤 5：收到告警后

读 `code` + `detail` + `tail`（已含最后 40 行）→ 按表处置 → 需要现场再 `ssh_exec` 抓 `nvidia-smi` / `py-spy dump` → **处置完必须重启叫醒器**（收到一条就退出）→ 给用户结论（为什么挂、是否重拉、下一步）。

## 判据

| code | 含义 | 处置 |
|---|---|---|
| `PROCESS_GONE` + `OOMKILLED` | 被内核 OOM killer 杀，**日志里可能没有 OOM 字样** | 降 batch/长度，别盲目重试 |
| `PROCESS_GONE` + `EXIT_1` | Python 异常 | 看 traceback |
| `PROCESS_GONE` + `SEGFAULT` | 段错误 | 查驱动 / so 版本 |
| `LOG_STALL` | 进程在但日志不动 | 多半 dataloader 卡死，`py-spy dump` |
| `OOM` / `NAN` / `TRACEBACK` | 日志命中关键字 | 按关键字处置 |
| `NO_PROGRESS` | GPU 一直 0% 且日志不动 | 死锁 / 数据管道空转 |

## 适配其他框架

| 场景 | 配置改动 |
|---|---|
| PyTorch 单卡 | 默认 |
| torchrun / accelerate / deepspeed | `log_glob=run/rank*.log`、`pgid_check=on`、`interval=60`、`stall_sec=1800` |
| TensorFlow / Keras | `pattern_oom=OOM when allocating\|Resource exhausted` |
| JAX / Flax | `pattern_oom=RESOURCE_EXHAUSTED` |
| CPU / MPS / TPU | `gpu=off`；`NO_PROGRESS` 不可用 |
| 指标只写 tensorboard / wandb | `NAN` 判据失效 → 让训练每 N step 打印一行 |
| loss 字段不叫 loss | `pattern_nan=(train_loss\|lm_loss\|ppl)[=: ]+.*(nan\|inf)` |

先看真实日志再定正则：`tail -300 run/train.log | grep -iE "nan|inf|oom|error" | head`

## 边界（必须告诉用户）

- **harness 死了就没人醒**：会话进程不在，轮询脚本也不在，兜底靠手机 ntfy。
- **ntfy.sh 公网明文**：topic 即密码。
- **不自动 resume**：只上报不重拉（「自动重拉」与「静默烧卡」只差一个 bug）。
- 不经 `run_train.sh` 起训练，就只剩 `PROCESS_GONE`，无法区分 OOM / 异常 / 段错误。

## 变体 A（本机 ssh 可用）

`while` 循环 `ssh 'kill -0 $(cat run/train.pid)'`，失败即 `exit 0` 唤醒；日志用 `rsync -az` 拉。缺点：手机收不到、无落盘证据。

## 清理

`pkill -f train_watch.sh`、`rm -rf <远端目录>`、`job_kill <wake_job_id>`。
