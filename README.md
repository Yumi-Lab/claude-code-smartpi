# Claude Code for Yumi Smart Pi One (32-bit ARM)

The **official Anthropic Claude Code CLI** running on **Allwinner H3 / armv7l**
(Smart Pi One, Yumi SmartPad) — a platform the official installer rejects and
that every doc declares "64-bit only".

It runs **natively, no emulation**, in two flavours:

- **Latest** — *any* current version (2.1.2xx…). Since 2.1.113 the official CLI
  ships as a Bun-compiled binary, but its JavaScript is embedded inside. The
  installer downloads the official binary, **extracts that JS on your device**,
  lowers it to Node 20 syntax, and runs it under Debian's own Node with a small
  Bun→Node shim. No token, no account needed to install.
- **Pinned** — **2.1.112**, the last npm release distributed as pure JavaScript.
  The lightest, most battle-tested path; needs only Node ≥ 18.

Sign in with a **Claude Pro/Max account** (no API key required); full interactive
interface, full agent mode.

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

**Latest version** (downloads the official binary, extracts + builds on-device):

```bash
curl -fsSL https://raw.githubusercontent.com/Yumi-Lab/claude-code-smartpi/main/install-latest.sh | bash
```

**Pinned 2.1.112** (lightest, pure-JS npm — no big download):

```bash
curl -fsSL https://raw.githubusercontent.com/Yumi-Lab/claude-code-smartpi/main/install.sh | bash
```

Both leave the same `claude` command; the last one you run wins. Then sign in
(headless, no local browser needed):

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
| `claude` | **Full interactive interface** — the real official TUI, running natively |
| `claude -p "question"` | One-shot answer (full agent mode: reads/writes files, runs commands) |
| `claude setup-token` | Sign in with a Claude Pro/Max account (one-time OAuth code, browser on any machine) |
| `claude-token-save <token>` | Persist the 1-year token (`~/.claude/.oauth_token` + `settings.json`) |
| `CLAUDE_CPUS=0,1 claude …` | Throttle to a CPU subset for this launch — no reinstall (default = all 4 cores) |

Every `claude` launch goes through a small wrapper (`taskset … nice -n 5`) that
runs it on **all 4 cores at low priority** by default. To free cores for another
job — or stay cool on a fan-less board — throttle it **without reinstalling**:
`CLAUDE_CPUS=0,1 claude …` binds it to 2 cores (same knob as `GROK_CPUS` on the
sister [grok-cli-smartpi](https://github.com/Yumi-Lab/grok-cli-smartpi)).

## Updating

- **Latest channel:** re-run `install-latest.sh` — it fetches and builds the
  newest published version. Pin a specific one with
  `curl … | bash -s -- 2.1.212`.
- **Pinned channel:** intentionally frozen. Do **not** run `claude update`
  (it would fetch a 64-bit binary); auto-update is disabled. Re-run `install.sh`
  to repair.

## How it works

1. Up to **2.1.112**, the `@anthropic-ai/claude-code` npm package is **pure
   JavaScript** (`cli.js`, engines `node>=18`). From **2.1.113** it is only a
   thin wrapper that downloads a **Bun-compiled binary** for x64/arm64 → dead on
   32-bit if you try to run it.
2. But `bun build --compile` **embeds the readable JS** inside that binary. The
   *latest* installer downloads the official binary, carves the JS out on-device
   ([`shim/extract-bun-js.py`](shim/extract-bun-js.py)), and rebuilds a runnable
   bundle:
   - **esbuild `--target=node20`** lowers the one modern syntax the bundle uses
     (`using` declarations) so Debian's Node 20 can parse it — and preserves the
     resource cleanup, which a naive text replace would leak;
   - a **~15-function Bun→Node shim** ([`shim/bun-shim.mjs`](shim/bun-shim.mjs))
     provides the Bun APIs the app calls (`Bun.spawn`, `Bun.file`, `stringWidth`,
     `YAML`, `semver`, …); the app already degrades gracefully on the Bun-only
     bits ("running under Node?").
   - No account or token is involved: the binary is a **public** download, and
     nothing but our shim/launcher/extractor comes from this repo.
3. Two environment variables make either flavour work on armhf:
   `USE_BUILTIN_RIPGREP=0` (no arm-linux ripgrep is vendored — the Debian
   `ripgrep` package is used) and `DISABLE_AUTOUPDATER=1`.
4. Unlike its sister project [grok-cli-smartpi](https://github.com/Yumi-Lab/grok-cli-smartpi)
   (which needs QEMU 64-on-32 emulation), Claude Code runs **natively** — the CLI
   of choice on the pad for heavy multi-turn agentic tasks. Emulating the modern
   binary under QEMU was tested and is a dead end (>10 min per prompt): the
   extraction path above is what makes recent versions usable.

Full details (npm archaeology, the extraction/shim method, dead ends, auth
pitfalls, thermal measurements): [docs/METHODOLOGY.md](docs/METHODOLOGY.md)

## Target hardware & measured performance

Tested on a Yumi SmartPad (Allwinner H3, 4× Cortex-A7 @ 1.2 GHz, 1 GB RAM,
Debian 13 trixie armhf). Any armv7l SBC with ≥ 1 GB RAM should work. Measured:
`claude --version` 6–10 s · one-shot answer ~24 s · multi-turn agentic sessions
stable. The *latest* install downloads ~240 MB (the official binary) and runs
esbuild once (~30 s on the H3); the built version then behaves like the pinned one.

On 1 GB of RAM with SD-card swap, memory exhaustion freezes the machine before the
kernel OOM killer reacts — the installer enables **earlyoom**. Rule on the pad: one
heavy CLI at a time.

## Sister projects (same board, other CLIs)

- [grok-cli-smartpi](https://github.com/Yumi-Lab/grok-cli-smartpi) — official xAI
  Grok CLI, via QEMU 64-on-32 emulation of the static Rust binary.
- [kimi-cli-smartpi](https://github.com/Yumi-Lab/kimi-cli-smartpi) — Moonshot Kimi
  CLI, native Python via uv.
- [vibe-cli-smartpi](https://github.com/Yumi-Lab/vibe-cli-smartpi) — official Mistral
  Vibe CLI, native Python via uv.

All four are driven together by the [Yumi AI
Gateway](https://github.com/Yumi-Lab/yumi-ai-gateway).

## Licensing

- Scripts, shim and launcher in this repo: MIT (Yumi Lab).
- Claude Code itself is **not redistributed here**. The pinned install pulls it
  from the official npm registry; the latest install downloads the official
  binary from Anthropic and extracts its JS **locally, on your own device**. The
  resulting bundle stays on that device and remains subject to Anthropic's terms.
