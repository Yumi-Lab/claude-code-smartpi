# Claude Code for Yumi Smart Pi One (32-bit ARM)

The **official Anthropic Claude Code CLI** running on **Allwinner H3 / armv7l**
(Smart Pi One, Yumi SmartPad) — a platform the official installer rejects and
that every doc declares "64-bit only".

It runs **natively** (no emulation): version **2.1.112** is the last npm release
distributed as pure JavaScript, so it only needs Node ≥ 18. Sign in with a
**Claude Pro/Max account** (no API key required), full interactive interface,
full agent mode.

```
╭─────────────────────────────────────────────────╮
│ ✻ Welcome to Claude Code!                       │
│                                                 │
│   /help for help, /status for your current      │
│   setup                                         │
│                                                 │
│   cwd: /home/pi        2.1.112 · armv7l native  │
╰─────────────────────────────────────────────────╯
```

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Yumi-Lab/claude-code-smartpi/main/install.sh | bash
```

Then sign in with your Claude Pro/Max account (headless, no local browser needed):

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

| Command | Purpose |
|---|---|
| `claude` | **Full interactive interface** — the real official TUI, running natively (pure JS, no tricks) |
| `claude -p "question"` | One-shot answer (full agent mode: reads/writes files, runs commands) |
| `claude setup-token` | Sign in with a Claude Pro/Max account (one-time OAuth code, browser on any machine) |
| `claude-token-save <token>` | Persist the 1-year token (`~/.claude/.oauth_token` + `settings.json`) |

⚠️ **Never update Claude Code beyond 2.1.112 on 32-bit** — every newer version
is a 64-bit Bun binary. The installer disables auto-update; to repair or
reinstall, re-run `install.sh`.

## How it works

1. Up to **2.1.112**, the `@anthropic-ai/claude-code` npm package is **pure
   JavaScript** (`cli.js`, engines `node>=18`, no architecture check). From
   **2.1.113** it becomes a 132 KB wrapper that downloads a Bun binary built
   for x64/arm64 only → dead on 32-bit. We pin 2.1.112 with `--save-exact`.
2. Two environment variables make it work on armhf: `USE_BUILTIN_RIPGREP=0`
   (the package vendors no arm-linux ripgrep — the Debian `ripgrep` package is
   used instead) and `DISABLE_AUTOUPDATER=1` (one auto-update = 64-bit binary =
   broken install).
3. Unlike its sister project [grok-cli-smartpi](https://github.com/Yumi-Lab/grok-cli-smartpi)
   (which needs QEMU 64-on-32 emulation), Claude Code runs **natively** — which
   makes it the CLI of choice on the pad for heavy multi-turn agentic tasks.
   Emulating the modern native binary was tested and is a dead end (details in
   the methodology).

Full details (npm archaeology, dead ends, auth pitfalls, thermal measurements):
[docs/METHODOLOGY.md](docs/METHODOLOGY.md)

## Target hardware

Tested on a Yumi SmartPad (Allwinner H3, 4× Cortex-A7 @ 1.2 GHz, 1 GB RAM,
Debian 13 trixie armhf). Any armv7l SBC with ≥ 1 GB RAM should work. Measured
performance: `claude --version` 6.6 s · one-shot answer ~23 s · multi-turn
agentic sessions stable. `earlyoom` is installed as a memory safety net.

## Licensing

- Scripts in this repo: MIT (Yumi Lab)
- Claude Code itself is installed from the official npm registry at install
  time (it is not redistributed here) and remains subject to Anthropic's terms.
