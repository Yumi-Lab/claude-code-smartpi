# Claude Code for Yumi Smart Pi One (32-bit ARM)

The **official Anthropic Claude Code CLI** running on **Allwinner H3 / armv7l**
(Smart Pi One, Yumi SmartPad) — a platform the official installer rejects and
that every doc declares "64-bit only".

It runs **natively, no emulation**, always on the **latest** Claude Code. Since
2.1.113 the official CLI ships as a Bun-compiled binary, but its JavaScript is
embedded inside: the installer downloads the official binary, **extracts that JS
on your device**, and runs it under **Node 22** (installed automatically) with a
small Bun→Node shim. No token, no account needed to install.

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

**One command** — installs the newest Claude Code (downloads the official binary,
extracts + builds on-device, sets up Node 22). Re-run it any time to update.

```bash
curl -fsSL https://raw.githubusercontent.com/Yumi-Lab/claude-code-smartpi/main/install.sh | bash
```

Pin a specific version instead of the newest:

```bash
curl -fsSL https://raw.githubusercontent.com/Yumi-Lab/claude-code-smartpi/main/install.sh | bash -s -- 2.1.212
```

> There is a single installer. `install-latest.sh` still exists but is only a
> deprecated alias that forwards to `install.sh` (kept so the OTA and old
> one-liners keep working).

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
| `claude` | **Full interactive interface** — the real official TUI, running natively |
| `claude -p "question"` | One-shot answer (full agent mode: reads/writes files, runs commands) |
| `claude setup-token` | Sign in with a Claude Pro/Max account (one-time OAuth code, browser on any machine) |
| `claude-token-save <token>` | Persist the 1-year token (`~/.claude/.oauth_token` + `settings.json`) |
| `claude-check-update` | Print `{"installed":…,"latest":…,"update_available":…}` as one JSON line |
| `CLAUDE_CPUS=0,1 claude …` | Throttle to a CPU subset for this launch — no reinstall (default = all 4 cores) |

Every `claude` launch goes through a small wrapper (`taskset … nice -n 5`) that
runs it on **all 4 cores at low priority** by default. Free cores — or stay cool
on a fan-less board — **without reinstalling**: `CLAUDE_CPUS=0,1 claude …` binds it
to 2 cores (same knob as `GROK_CPUS` on the sister
[grok-cli-smartpi](https://github.com/Yumi-Lab/grok-cli-smartpi)).

### Running many agents (batch mode)

One Claude Code runtime needs **~137 MB of RAM** on the pad, so a 1 GB board tops
out at ~3 comfortable / ~5 hard concurrent agents before swapping. Launching 10 at
once makes earlyoom cull ~4 of them. To run **any number** of headless jobs safely,
enable the on-device **job daemon**: it keeps only `CLAUDE_MAX_CONCURRENT` runtimes
live at a time and queues the rest at ~0 RAM.

```bash
export CLAUDE_DAEMON=1              # route headless jobs through the daemon
export CLAUDE_MAX_CONCURRENT=3      # how many run at once (default 3)
claude -p "task 1" &  claude -p "task 2" &  …  claude -p "task 20" &
```

Measured on the pad: **20 jobs requested → 3 run in parallel until the queue drains
→ 20/20 succeed**, RAM never below ~190 MB free, earlyoom never triggers. The daemon
lazy-starts on the first job and self-exits after `CLAUDE_IDLE_MS` idle (no boot
service). Interactive `claude` (full TUI) always stays a direct one-per-terminal
process. Leave `CLAUDE_DAEMON` unset for the plain, unchanged behaviour.

## Updating (OTA)

- **Check:** `claude-check-update` prints one JSON line —
  `{"cli":"claude","installed":"2.1.212","latest":"2.1.215","update_available":true}`.
  This is the probe the [Yumi AI Gateway](https://github.com/Yumi-Lab/yumi-ai-gateway)
  console polls for its update badge.
- **Update:** re-run `install.sh` — that IS the updater: it exits fast when already
  newest (`CLAUDE_FORCE=1` to rebuild), otherwise fetches and builds the newest
  published version. Auto-update stays disabled (a naive update would fetch a 64-bit
  binary); the OTA path is always this script.
- **Privileges:** root/sudo for the *first* install only. Updates run as any user
  that owns `/opt/claude-code` — the gateway service user updates without sudo (the
  `/usr/local/bin/claude` wrapper is version-independent and is not rewritten on
  routine updates).

## How it works

1. Up to **2.1.112**, the `@anthropic-ai/claude-code` npm package was **pure
   JavaScript**. From **2.1.113** it is only a thin wrapper that downloads a
   **Bun-compiled binary** for x64/arm64 → dead on 32-bit if you try to run it.
2. But `bun build --compile` **embeds the readable JS** inside that binary. The
   installer downloads the official binary, carves the JS out on-device
   ([`shim/extract-bun-js.py`](shim/extract-bun-js.py)), and rebuilds a runnable
   bundle:
   - **esbuild `--format=cjs --target=node20`** lowers the one modern syntax the
     bundle uses (`using` declarations) — preserving the resource cleanup a naive
     text replace would leak — and emits CJS so the launcher can cache it and
     `import.meta` is lowered too;
   - a **~15-function Bun→Node shim** ([`shim/bun-shim.mjs`](shim/bun-shim.mjs))
     provides the Bun APIs the app calls (`Bun.spawn`, `Bun.file`, `stringWidth`,
     `YAML`, `semver`, …); the app already degrades gracefully on the Bun-only bits;
   - a **V8 bytecode cache** ([`shim/claude.mjs`](shim/claude.mjs) via `vm.Script`)
     is primed at install, so the 26 MB bundle is compiled once, not on every launch:
     `claude --version` **8.4 s → 2.9 s** on the H3. Why not a Go rewrite? See
     [`bench/`](bench/) — `goja` can't even parse the bundle.
3. **Node 22.** Claude Code 2.1.212+ hard-requires Node `>=22.17.0` at agent runtime
   (Debian armhf only ships Node 20, and there is no official Node 24 armv7l build),
   so the installer fetches the official **Node v22.22.0 armv7l** from nodejs.org into
   `/usr/local` when the current node is too old. `CLAUDE_NODE_VERSION` overrides.
4. Two env vars make it work on armhf: `USE_BUILTIN_RIPGREP=0` (system `ripgrep`) and
   `DISABLE_AUTOUPDATER=1`. No account or token is involved during install — the
   binary is a **public** download, and nothing but our shim/launcher/extractor comes
   from this repo; the Anthropic bundle is built locally and never redistributed.

Full details (npm archaeology, extraction/shim method, dead ends, auth pitfalls,
thermal measurements): [docs/METHODOLOGY.md](docs/METHODOLOGY.md). Agent-density
load tests: [`bench/agents-loadtest.sh`](bench/agents-loadtest.sh).

## Target hardware & measured performance

Tested on a Yumi SmartPad (Allwinner H3, 4× Cortex-A7 @ 1.2 GHz, 1 GB RAM,
Debian 13 trixie armhf, Node 22). Measured: `claude --version` **2.9 s** (V8 bytecode
cache; ~8.4 s uncached) · one-shot answer ~24 s · one runtime ~137 MB RSS · multi-turn
agentic sessions stable. First install downloads ~240 MB (official binary) + ~25 MB
(Node 22), runs esbuild once (~30 s) and primes the bytecode cache (~7 s).

On 1 GB of RAM, memory exhaustion freezes the machine before the kernel OOM killer
reacts — the installer enables **earlyoom**. For many agents use the daemon (above)
rather than launching them all at once.

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
- Claude Code itself is **not redistributed here**. The installer downloads the
  official binary from Anthropic and extracts its JS **locally, on your own device**.
  The resulting bundle stays on that device and remains subject to Anthropic's terms.
