# 排查手册

按"症状 → 检查顺序"组织。每一步都给出可以立刻执行的命令。

## 症状 1：训练挂了，但没收到告警

按顺序查，绝大多数问题在第 2、3 步：

**① 远端 watchdog 还在跑吗**

```bash
pgrep -af train_watch.sh
tail -20 <state_dir>/status.jsonl      # 有没有持续采样
cat <state_dir>/alert.json 2>/dev/null  # 有它就是判定成功、推送可能失败
```

**② topic 两边一致吗**

配置里的 `topic=` 和本机 `watch_wake.sh --topic` 必须逐字符相同。常见错误：远端用了 `run/watch.conf` 的新 topic，本机还挂着旧的。

**③ 推送真的发出去了吗**

```bash
curl -s "https://ntfy.sh/<topic>/json?poll=1&since=1h" | tail -3
```

- 有消息 → 问题在本机叫醒器（第 ④ 步）。
- 没消息 → 远端网络或 ntfy 不可达：远端 `curl -s -o /dev/null -w "%{http_code}" https://ntfy.sh` 应为 200。

**④ 叫醒器还活着吗**

它**收到一条故障就退出**。如果上一次故障后没有重启，它已经不在了 —— 这是最常见的"漏警"原因。

```bash
job_list | grep watch_wake      # 确认作业还在
```

**⑤ 时间戳位点**

叫醒器把 `last_ts` 存在 `<告警目录>/.since_<topic>`。如果这个文件的时间戳比故障消息还新（比如手工改过主题或时钟跳变），历史消息会被跳过。删掉这个文件即可重置（注意会重放缓存里的旧消息）。

## 症状 2：误报

**`LOG_STALL` 但进程明明在跑**
日志缓冲。先加 `python -u` 或 `PYTHONUNBUFFERED=1`；改不了就把 `stall_sec` 放到最大打印间隔的 2 倍以上。大 checkpoint 保存、验证集评估期间也会长时间不打印。

**`NAN` 误伤**
正则太宽。默认 `(loss|metric|acc|ppl)[=: ]+.*(nan|inf)` 只匹配"字段名 + nan/inf"。如果项目日志里有别的 `inf`（比如 `inf once` 指标），改窄：
`pattern_nan=train_loss[=: ]+.*nan`

**`PROCESS_GONE` 但训练还在跑**
wrapper 死了、子进程被接管；或 pidfile 被别的 run 覆盖。检查 `<pidfile>` 和 `<pidfile>.child` 指向的进程，必要时开 `pgid_check=on`。

**`OOM` 但没崩**
某些框架会把被捕获的 OOM 打到日志里然后降级重试。这种情况下报警是对的，但处置不是"重跑"而是"看它重试了几次、batch 有没有被自动缩小"。

## 症状 3：多 rank / torchrun

- 每个 rank 一个日志时用 `log_glob=run/rank*.log`；脚本取**最近被写过的那个**文件做 tail，用**最新的 mtime** 判停更。
- 一个 rank 死了、其余还活着：`pgid_check=on` 能发现进程组整体，但如果 torchrun 自己也退出了，直接就是 `PROCESS_GONE`。
- 多 rank 刷盘更不规律，`stall_sec` 建议 ≥1800，`interval` 60。
- 想看"哪个 rank 死的"：alert 里只带一个文件的 tail。需要全量时用 `ssh_exec` 逐个 rank grep，或把 `log_glob` 里的文件名带上 rank 号。

## 症状 4：没有 GPU 也别怕

`gpu=auto` 只决定"要不要采样"，不影响其他判据。CPU / MPS / TPU 上设 `gpu=off`：

- `NO_PROGRESS` 不可用（它依赖 GPU 利用率）。
- 其余判据（进程、退出码、日志、正则）全部照常工作。

## 症状 5：推送太吵

- `heartbeat_sec=0` 关掉心跳。
- `fault_cooldown` 在 `--keep-running` 模式下给同一故障去重。
- 只关心"彻底死了"的话，把 `pattern_*` 置空（`pattern_nan=`），只留进程判活。

## 症状 6：换机器后不工作

按 SKILL.md 步骤 0 重跑一遍前置检查。三个最常变的环境事实：

1. 本机能不能 ssh（决定主路 vs 变体 A）
2. 两边能不能出公网（不能就换自托管地址或内网 webhook）
3. 远端有没有 `nvidia-smi`、`curl`、`date -d`（macOS 的 `date` 语法不同，`stat -c` 也不存在——本脚本假定 GNU coreutils）

## 清理

```bash
pkill -f train_watch.sh                     # 远端看门狗
rm -rf <state_dir> <run 目录>                # 远端证据与运行目录
job_kill <wake_job_id>                      # 本机叫醒器
rm -f <告警目录>/.since_<topic>              # 位点
```
