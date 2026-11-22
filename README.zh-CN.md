English | [中文](README.zh-CN.md)

# training-watch

一个与模型、框架无关的**远程训练看门狗**：远端跑脚本盯训练，出事就推送告警（带日志尾部），并把你正在用的 AI agent 从会话里叫醒去处理。

```
远端 watchdog ──[FAULT + 日志尾部]──▶ ntfy ──▶ 本机叫醒器 ──▶ 作业退出 ──▶ agent 被唤醒
```

## 它解决什么问题

长训练跑在远端，人不可能一直守着。普通监控脚本只能"发现异常"，做不到"让人或 agent 接手"；而 agent 的回合结束后不会自己醒过来。

本项目的两个关键点：

1. **远端自治**：watchdog 独立于训练运行，不依赖你的电脑在线。
2. **退出码即信号**：本机叫醒器读到故障就 `exit 0`，后台作业结束触发运行时通知，agent 因此被真正唤醒 —— 不是发一条没人看的消息。

## 三个探针

与训练代码只有三个约定，任何框架把这三样落到文件就能被监督：

| 探针 | 回答的问题 | 谁写 |
|---|---|---|
| `pidfile` + `<pidfile>.child` | 还活着吗 | `run_train.sh` |
| `exit_code_file` | 怎么死的（137=OOM killer、139=段错误、1=异常） | `run_train.sh` |
| `log` / `log_glob` | 在动吗、报了什么错 | 你的训练脚本 |

为什么必须记录退出码：**被内核 OOM killer 杀掉的进程，日志里可能一个字都没有**。只有 137 能区分"被系统杀"和"自己崩了"。

## 快速开始

```bash
# 0. 取脚本
git clone https://github.com/Veryyoung957/training-watch.git
cd training-watch

# 1. 生成 topic（topic 即密码）
TOPIC="train-$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')"

# 2. 传到远端
scp -r scripts watch.conf.example user@host:~/training-watch/

# 3. 远端：用 run_train.sh 启动训练（它会写 pid / child pid / 退出码）
cd ~/training-watch
nohup bash scripts/run_train.sh \
  --pidfile ~/run/train.pid \
  --log     ~/run/train.log \
  --exit-code-file ~/run/train.exit \
  -- .venv/bin/python train.py > /dev/null 2>&1 &

# 4. 远端：起看门狗
cat > ~/run/watch.conf <<EOF
name=my-exp
pidfile=~/run/train.pid
child_pidfile=~/run/train.pid.child
exit_code_file=~/run/train.exit
log=~/run/train.log
interval=30
stall_sec=900
gpu=auto
topic=$TOPIC
EOF
nohup bash scripts/train_watch.sh --config ~/run/watch.conf > ~/run/watch.log 2>&1 &

# 5. 本机：起叫醒器（必须后台运行，退出码才有接收方）
scripts/watch_wake.sh --topic "$TOPIC" --interval 10 --timeout 86400
```

手机装 [ntfy](https://ntfy.sh) 订阅同一个 topic，告警会同时到你手机。

## 验收（务必先演练）

不要拿真训练当第一个测试。跑一个 18 秒就崩的假训练：

```bash
bash scripts/run_train.sh --pidfile /tmp/t/run/train.pid --log /tmp/t/run/train.log \
  --exit-code-file /tmp/t/run/train.exit -- \
  bash -c 'for i in 1 2 3; do echo "ep $i loss=0.5"; sleep 2; done; exit 3' &

# 用 interval=2 的临时配置跑一遍，期望看到：
#   [watch] FAULT PROCESS_GONE — pid=6 exit=3 -> EXIT_3
```

成功标志：agent 会话**在没有任何用户输入的情况下**自行开了一轮。

## 配置

| key | 默认 | 说明 |
|---|---|---|
| `name` | `train` | 告警标题里的运行名 |
| `pidfile` | 必填 | wrapper 的 pid |
| `child_pidfile` | — | 真实训练进程 pid（防"wrapper 活着训练已死"） |
| `exit_code_file` | — | 退出码文件，没有就只能报 `PROCESS_GONE`，无法归因 |
| `log` / `log_glob` | 二选一必填 | 单文件 / 多 rank 通配 |
| `interval` | 30 | 采样间隔，决定发现延迟 |
| `stall_sec` | 900 | 日志停更多久判 `LOG_STALL`，**必须大于刷盘间隔** |
| `heartbeat_sec` | 300 | 心跳间隔，`0` 关闭 |
| `gpu` | `auto` | `auto`/`on`/`off`；CPU、MPS、TPU 设 `off` |
| `pgid_check` | `auto` | 进程组兜底判活 |
| `no_progress` | 0 | >0：连续 N 次 GPU 0% 且日志不动即告警 |
| `fault_cooldown` | 1800 | `--keep-running` 时同一故障去重窗口 |
| `topic` | 空 | 留空 = 只打印不推送（本地调试） |
| `ntfy_url` | `https://ntfy.sh` | 可指向自托管实例 |
| `pattern_oom` / `pattern_nan` / `pattern_traceback` / `extra_pattern` | 见模板 | 判据正则，**按项目实际日志改** |

## 判据

| code | 含义 | 处置 |
|---|---|---|
| `PROCESS_GONE` + `OOMKILLED` | 被内核 OOM killer 杀，日志里可能没有痕迹 | 降 batch/长度，别盲目重试 |
| `PROCESS_GONE` + `EXIT_1` | Python 异常退出 | 看 traceback |
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

## 装成 AI 技能（DeepSeek Harness）

这个仓库本身就是一个技能：`SKILL.md` 是入口，`references/` 按需加载，`scripts/` 是可直接部署的代码。

```bash
git clone https://github.com/Veryyoung957/training-watch.git \
  ~/.dsh/skills/training-watch
```

之后在会话里说「帮我把这个训练盯起来 / 训练挂了叫我」即可触发。

## 设计取舍

- **为什么远端推、本机收**：很多机器上本机 `ssh` 不可用（系统配置损坏 / 无密钥 / 防火墙），而 `/api` 有鉴权。详见 [`references/design.md`](references/design.md)。
- **为什么不做自动 resume**：「自动重拉」和「静默烧卡」只差一个 bug。watchdog 只上报，恢复留给确认后的人或 agent。
- **为什么叫醒器收到一条就退出**：退出码才是唤醒信号；常驻会刷屏，也会让故障被自动吞掉。

## 排查

告警没来、误报、多 rank、换机器后不工作 —— 见 [`references/troubleshooting.md`](references/troubleshooting.md)。

## 依赖与限制

- 远端：`bash`、`curl`、GNU coreutils（`date -d`、`stat -c`；macOS 需装 gdate/gstat 或改用 Linux）
- 本机：`bash`、`curl`、`jq`
- 两端需要能访问 `ntfy.sh`（或自托管实例）
- **harness 进程挂了就没人醒**：轮询脚本也随之消失，兜底只有手机通知
- ntfy.sh 是公网明文服务，topic 名即密码；敏感日志请换自托管

## License

[MIT](LICENSE)
