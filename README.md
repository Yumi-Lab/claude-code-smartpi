# Claude Code for Yumi Smart Pi One (32-bit ARM)

The **official Anthropic Claude Code CLI** running on **Allwinner H3 / armv7l**
(Smart Pi One, Yumi SmartPad) — hardware the official installer rejects as
"64-bit only".

It runs **natively, no emulation**, always on the **latest** version, and signs in
with a **Claude Pro/Max account** (no API key). Full interactive interface, full
agent mode.

```
╭─────────────────────────────────────────────────╮
│ ✻ Welcome to Claude Code!                       │
│                                                 │
│   /help for help, /status for your current      │
│   setup                                         │
│                                                 │
│   cwd: /home/pi        2.1.2xx · armv7l native  │
╰─────────────────────────────────────────────────╯
```

## Install

**One command** — installs the newest Claude Code, and is also the updater (re-run
any time to move to the latest):

```bash
curl -fsSL https://raw.githubusercontent.com/Yumi-Lab/claude-code-smartpi/main/install.sh | bash
```

Pin a specific version instead of the newest:

```bash
curl -fsSL https://raw.githubusercontent.com/Yumi-Lab/claude-code-smartpi/main/install.sh | bash -s -- 2.1.212
```

Then sign in (headless, no local browser needed):

```bash
claude setup-token
```

An OAuth URL is displayed: open it on any machine, approve, paste the one-time
code. The CLI prints a `sk-ant-oat…` token (valid 1 year) **once, without saving
it** — copy it immediately and persist it with:

```bash
claude-token-save sk-ant-oat01-…
```

## Usage

The everyday command is just **`claude`** — it always works, interactive or headless:

| Command | Purpose |
|---|---|
| `claude` | **Full interactive interface** — the real official TUI |
| `claude -p "question"` | One-shot answer (full agent mode: reads/writes files, runs commands) |
| `claude setup-token` | Sign in with a Claude Pro/Max account (one-time OAuth code, browser on any machine) |
| `claude-token-save <token>` | Persist the 1-year token |
| `claude-check-update` | Print `{"installed":…,"latest":…,"update_available":…}` as one JSON line |
| `claude-daemon-status` | Batch mode: how many agents are running / queued (`--json` for scripts) |
| `CLAUDE_CPUS=0,1 claude …` | Run on a CPU subset for this launch — no reinstall (default = all 4 cores) |

## Running many agents (batch mode)

One agent holds a full runtime (~137 MB), so a 1 GB board only runs a few at once
before it runs out of memory. To submit **any number** of headless jobs safely,
enable the built-in job daemon — it runs a bounded number at a time and queues the
rest:

```bash
export CLAUDE_DAEMON=1              # route headless jobs through the daemon
export CLAUDE_MAX_CONCURRENT=3      # how many run at once (default 3)
claude -p "task 1" &  claude -p "task 2" &  …  claude -p "task 20" &
```

Measured on the pad: **20 jobs → 3 run at a time until the queue drains → 20/20
succeed**, with memory kept safe throughout. The daemon starts on the first job and
stops on its own when idle. Watch it with `claude-daemon-status` (running / queued;
`--json` to poll). Leave `CLAUDE_DAEMON` unset for the plain behaviour; interactive
`claude` always runs directly.

## Updating (OTA)

- **Check:** `claude-check-update` prints one JSON line —
  `{"cli":"claude","installed":"2.1.212","latest":"2.1.215","update_available":true}`.
  This is the probe the [Yumi AI Gateway](https://github.com/Yumi-Lab/yumi-ai-gateway)
  console polls for its update badge.
- **Update:** re-run `install.sh` — that IS the updater (exits fast when already
  newest; `CLAUDE_FORCE=1` to rebuild). Do not run `claude update`; auto-update is
  disabled on this platform.
- **Privileges:** root/sudo for the *first* install only. Updates run as any user
  that owns `/opt/claude-code` — the gateway service user updates without sudo.

## Target hardware & measured performance

Tested on a Yumi SmartPad (Allwinner H3, 4× Cortex-A7 @ 1.2 GHz, 1 GB RAM,
Debian 13 trixie armhf). Any armv7l SBC with ≥ 1 GB RAM should work. Measured:
`claude --version` **~2.9 s** · one-shot answer **~24 s** · one runtime **~137 MB** ·
multi-turn agentic sessions stable. The first install takes a few minutes and a
larger download; every launch afterwards is fast.

On 1 GB of RAM the installer enables **earlyoom** (memory safety net). To run many
agents at once, use the batch mode above rather than launching them all directly.

## Sister projects (same board, other CLIs)

- [grok-cli-smartpi](https://github.com/Yumi-Lab/grok-cli-smartpi) — official xAI Grok CLI.
- [kimi-cli-smartpi](https://github.com/Yumi-Lab/kimi-cli-smartpi) — Moonshot Kimi CLI (Python).
- [kimi-code-smartpi](https://github.com/Yumi-Lab/kimi-code-smartpi) — Moonshot Kimi Code CLI (TypeScript successor), native via npm + Node 22.
- [vibe-cli-smartpi](https://github.com/Yumi-Lab/vibe-cli-smartpi) — official Mistral Vibe CLI.

All five are driven together by the [Yumi AI
Gateway](https://github.com/Yumi-Lab/yumi-ai-gateway).

## Licensing

Scripts, shim and launcher in this repo are MIT (Yumi Lab). Claude Code itself is
**not redistributed here** — it is obtained from Anthropic's official channels,
stays on your own device, and remains subject to Anthropic's terms.
