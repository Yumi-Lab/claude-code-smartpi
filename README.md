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

One agent holds a full runtime (~180 MB on 2.1.261), so a 1 GB board only runs a few at once
before it runs out of memory. To submit **any number** of headless jobs safely,
enable the built-in job daemon — it runs a bounded number at a time and queues the
rest:

```bash
export CLAUDE_DAEMON=1              # route headless jobs through the daemon
export CLAUDE_MAX_CONCURRENT=3      # how many run at once (default 3)
claude -p "task 1" &  claude -p "task 2" &  …  claude -p "task 20" &
```

Measured on the pad (2.1.2xx monolith era): **20 jobs → 3 run at a time until the queue
drains → 20/20 succeed**, with memory kept safe throughout. The daemon starts on the first job and
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

## How it works

Anthropic ships Claude Code as a Bun-compiled native binary (no armv7 build). `install.sh`
downloads the official binary for a supported platform and rebuilds it for Node on the board:

1. `shim/extract-bun-js.py` reads the module table Bun serialises at the end of the binary
   and writes every embedded file under its virtual name (`bunfs/root/…`). Since Claude Code
   2.1.242 the application is not one 28 MB bundle any more but ~1 640 ES-module chunks plus
   ~180 embedded assets (bundled skills and prompts as `.md.zst`, native addons); a plain
   "largest text block" carve sees about 46 of those chunks, the module table sees all of them.
2. `shim/bundle-bunfs.mjs` feeds that graph to esbuild, which produces one `bundle.cjs`
   (chunks bundled, `using` lowered for Node 20+, `import.meta.require`/`dirname`/`url` mapped
   onto their CommonJS names). Versions up to 2.1.241 (single CJS bundle) still take the old
   path through the same script. This is the one memory-hungry step on a 1 GB board (see the
   measurements below).
3. `shim/claude.mjs` runs `bundle.cjs` through `vm.Script` with a persisted V8 bytecode cache;
   `shim/bun-shim.mjs` provides the Bun API surface the app calls (`Bun.spawn`, `Bun.file`,
   `stringWidth`, `Bun.zstdDecompressSync` via `node:zlib`…) and maps the virtual filesystem
   (`/$bunfs/root/…`) onto `/opt/claude-code/assets/`. Native `.node` addons are not shipped:
   the few features that need them fail at the point of use, nothing else.

Both layouts are built by the same script and verified end to end on a pad (see the
measurements below). zstd needs Node >= 22.15 (`install.sh` installs Node 22 on armv7l).

## Target hardware & measured performance

Measured on **Claude Code 2.1.261** (chunked layout), 5 September 2026, on a Yumi SmartPad:
Allwinner H3, 4× Cortex-A7 @ 1.2 GHz, **991 MB RAM + 1 GB swap**, DietPi / Debian 13 trixie
armhf, kernel 6.18, Node 22.22.0 — a freshly flashed image, with the Yumi AI Gateway service
running alongside. Any armv7l SBC with ≥ 1 GB RAM and swap should behave the same.

**Install** (`curl … | bash` on the bare image, ~9 min end to end):

| Step | Time | Notes |
|---|---|---|
| apt: ripgrep + xz-utils | ~70 s | first install only |
| Node 22 (26 MB from nodejs.org) | ~35 s | first install only |
| Official binary (198 MB) | 2 min 52 s | ~1.2 MB/s here; cached + resumable in `/var/tmp` |
| JS extraction (module table) | **4 s** | 1 818 modules |
| npm install (esbuild + deps) | ~20 s | |
| esbuild bundle → `bundle.cjs` 41.6 MB | ~2 min 45 s | the heavy step, see memory below |
| Install tree + V8 cache priming | 13 s + 15 s | `bundle.v8cache` 5.6 MB |

Re-running as an update with the binary already cached: **4 min 18 s**. The memory peak is
esbuild, which keeps the whole chunk graph live: **~820 MB RSS** whatever the GC settings,
so the board bottoms out at 2 MB available and **swap is required** (the pad images ship
with 1 GB; earlyoom did not fire). `install.sh` runs esbuild under `GOMEMLIMIT=512MiB`
(override: `CLAUDE_ESBUILD_GOMEMLIMIT`), measured against the default on the same pad:

| esbuild setting | Bundle | Swap peak | Available at trough |
|---|---|---|---|
| default | 151 s | 563 MB | 2 MB |
| `GOMEMLIMIT=512MiB` | **140 s** | **191 MB** | 5 MB |
| `GOMEMLIMIT=400MiB GOGC=50` | 151 s | 159 MB | 2 MB |
| `GOMEMLIMIT=300MiB GOGC=25` | 165 s | 157 MB | 2 MB |

The bundle is byte-identical in every case; the gateway process sharing the board is swapped
out for the duration of the build either way and recovers on its own.

**Runtime** (payload `/opt/claude-code` = 84 MB):

| Command | Wall | Peak RSS |
|---|---|---|
| `claude --version`, cold cache | 8.3 s | 140 MB |
| `claude --version`, warm | **3.1 s** | 140 MB |
| `claude --help` | 7.7 s | 164 MB |
| `claude -p "reply with exactly: pong"` → `pong` | **23 s** | 182 MB |
| `claude-check-update` | 1.1 s | — |

For comparison, ≤ 2.1.241 (26 MB monolith) measured 2.9 s / ~24 s / ~137 MB on the same
class of board: the chunked layout costs ~45 MB more per runtime and nothing on latency.

**OTA path** verified on the same pad: the gateway's update badge
(`GET /admin/cli/updates`) reports `installed 2.1.261, update_available false` from
`claude-check-update`, and `CLAUDE_FORCE=1 install.sh` run as the unprivileged service
user that owns `/opt/claude-code` (no sudo available) rebuilt in **3 min 26 s** with the
downloads cached, leaving the root-owned wrapper in `/usr/local/bin` untouched
(see [Updating](#updating-ota)).

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
