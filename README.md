English | [中文](README.zh-CN.md)

# training-watch

A model- and framework-agnostic watchdog for **remote training runs**. It samples the training process, the log and the GPU on the remote host, pushes an alert with the log tail when something dies, stalls, OOMs or goes NaN — and, the part that actually matters, **wakes your AI agent session** so it can diagnose and respond, instead of firing a notification nobody reads.

```
remote watchdog ──[FAULT + log tail]──▶ ntfy ──▶ local waker ──▶ job exits ──▶ agent wakes up
```

## The problem

Long training runs live on a remote box. You cannot watch them, and a plain monitoring script only tells you *that* something broke — it cannot get a human or an agent to pick it up. Meanwhile an agent's turn ends and it has no reason to wake up on its own.

Two design decisions carry the whole thing:

1. **The watchdog lives on the remote host.** It runs independently of your laptop, so closing the lid does not stop supervision.
2. **An exit code is the wake signal.** The local waker `exit 0` on a received fault; its background job completing triggers a runtime notification, which starts a real agent turn. Not a message sitting in a queue.

## The three probes

There are exactly three contracts with your training code. Any framework that writes these three files can be supervised:

| Probe | Question it answers | Written by |
|---|---|---|
| `pidfile` + `<pidfile>.child` | Is it still alive? | `run_train.sh` |
| `exit_code_file` | How did it die? (137 = OOM killer, 139 = segfault, 1 = exception) | `run_train.sh` |
| `log` / `log_glob` | Is it moving, and what did it say? | your training script |

Why the exit code is not optional: **a process killed by the kernel OOM killer may leave no trace in the log at all.** Only the exit status distinguishes "the system killed it" from "it crashed on its own".

## Quick start

```bash
# 0. Get the scripts
git clone https://github.com/Veryyoung957/training-watch.git
cd training-watch

# 1. Generate a topic (the topic name is the password)
TOPIC="train-$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')"

# 2. Copy to the remote host
scp -r skills/training-watch user@host:~/

# 3. Remote: launch training through run_train.sh
#    (it records pid, child pid and the exit code)
cd ~/training-watch
nohup bash scripts/run_train.sh \
  --pidfile ~/run/train.pid \
  --log     ~/run/train.log \
  --exit-code-file ~/run/train.exit \
  -- .venv/bin/python train.py > /dev/null 2>&1 &

# 4. Remote: start the watchdog
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

# 5. Local: start the waker in the background
#    (it must be a background job — otherwise nothing receives the exit code)
scripts/watch_wake.sh --topic "$TOPIC" --interval 10 --timeout 86400
```

Install [ntfy](https://ntfy.sh) on your phone and subscribe to the same topic to get the alert on mobile too.

## Smoke test first

Do not make a real training run your first test. Fire an 18-second fake run that crashes on purpose:

```bash
bash scripts/run_train.sh --pidfile /tmp/t/run/train.pid --log /tmp/t/run/train.log \
  --exit-code-file /tmp/t/run/train.exit -- \
  bash -c 'for i in 1 2 3; do echo "ep $i loss=0.5"; sleep 2; done; exit 3' &

# run the watchdog once with interval=2, expect:
#   [watch] FAULT PROCESS_GONE — pid=6 exit=3 -> EXIT_3
```

Success looks like: the agent session starts a turn **with no user input at all**.

## Configuration

| Key | Default | Meaning |
|---|---|---|
| `name` | `train` | Run name used in alert titles |
| `pidfile` | required | pid of the wrapper |
| `child_pidfile` | — | pid of the real training process (catches "wrapper alive, training dead") |
| `exit_code_file` | — | Without it you only get `PROCESS_GONE`, with no attribution |
| `log` / `log_glob` | one required | Single file / glob for multi-rank runs |
| `interval` | 30 | Sampling period; sets detection latency |
| `stall_sec` | 900 | Log silence that counts as `LOG_STALL` — **must exceed log flush interval** |
| `heartbeat_sec` | 300 | Heartbeat interval; `0` disables |
| `gpu` | `auto` | `auto`/`on`/`off`; set `off` on CPU, MPS or TPU |
| `pgid_check` | `auto` | Process-group liveness as a fallback |
| `no_progress` | 0 | >0: alert after N consecutive samples with GPU at 0% and a static log |
| `fault_cooldown` | 1800 | De-duplication window for the same fault under `--keep-running` |
| `topic` | empty | Empty = print only, no push (local debugging) |
| `ntfy_url` | `https://ntfy.sh` | Point at a self-hosted instance if needed |
| `pattern_oom` / `pattern_nan` / `pattern_traceback` / `extra_pattern` | see template | Detection regexes — **tune them against your real log** |

## Fault codes

| Code | Meaning | What to do |
|---|---|---|
| `PROCESS_GONE` + `OOMKILLED` | Killed by the kernel OOM killer; the log may show nothing | Reduce batch size / sequence length; do not blindly retry |
| `PROCESS_GONE` + `EXIT_1` | Python exception | Read the traceback |
| `PROCESS_GONE` + `SEGFAULT` | Segfault | Check driver / shared-library versions |
| `LOG_STALL` | Process alive, log frozen | Usually a deadlocked dataloader; `py-spy dump` |
| `OOM` / `NAN` / `TRACEBACK` | Log matched a pattern | Handle by keyword |
| `NO_PROGRESS` | GPU stuck at 0% with a static log | Deadlock or an empty data pipeline |

## Adapting to other frameworks

| Setup | Configuration change |
|---|---|
| PyTorch, single GPU | defaults |
| torchrun / accelerate / deepspeed | `log_glob=run/rank*.log`, `pgid_check=on`, `interval=60`, `stall_sec=1800` |
| TensorFlow / Keras | `pattern_oom=OOM when allocating\|Resource exhausted` |
| JAX / Flax | `pattern_oom=RESOURCE_EXHAUSTED` |
| CPU / MPS / TPU | `gpu=off`; `NO_PROGRESS` is unavailable |
| Metrics only in tensorboard / wandb | The `NAN` check cannot see them — print a line every N steps |

## Install as an AI skill (DeepSeek Harness)

This repository is itself a skill: `SKILL.md` is the entry point, `references/` loads on demand, `scripts/` is deployable code.

```text
skills/training-watch/      <- the skill itself
├── SKILL.md
├── references/
└── scripts/
```

```bash
# recommended: let gh install it
gh skill install Veryyoung957/training-watch training-watch

# or manually: clone and copy the skill folder
git clone --depth 1 https://github.com/Veryyoung957/training-watch.git /tmp/tw
cp -r /tmp/tw/skills/training-watch ~/.dsh/skills/
```

Then say "watch this training run for me" / "ping me if it dies" and the skill takes over.

## Design notes

- **Why the remote pushes and the local side polls**: on many machines the local `ssh` client is unusable (broken system config, no keys, firewall), while the local API is authenticated. See [`references/design.md`](skills/training-watch/references/design.md).
- **Why there is no automatic resume**: "auto-restart" and "silently burn GPU hours" differ by one bug. The watchdog reports; recovery waits for a human or agent to confirm.
- **Why the waker exits after one fault**: the exit code is the signal. Staying resident both spams and lets faults be swallowed automatically.

## Troubleshooting

Alerts not arriving, false positives, multi-rank runs, a new machine that does not work — see [`references/troubleshooting.md`](skills/training-watch/references/troubleshooting.md).

## Requirements and limits

- Remote: `bash`, `curl`, GNU coreutils (`date -d`, `stat -c`; on macOS install gdate/gstat or use Linux)
- Local: `bash`, `curl`, `jq`
- Both sides need to reach `ntfy.sh` (or your self-hosted instance)
- **If the harness process dies, nobody wakes up** — the polling script goes with it; only the phone alert remains
- `ntfy.sh` is a public, unencrypted relay and the topic name is the password; use a self-hosted instance for sensitive logs

## License

[MIT](LICENSE)
