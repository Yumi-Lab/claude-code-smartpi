# Full methodology — official Claude Code CLI on 32-bit ARM

How to run a CLI whose official distribution is 64-bit only (x86_64/aarch64
Bun binaries) on a SoC that can only execute 32-bit code (Allwinner H3,
Cortex-A7, armv7l). Reference document: every choice below was tested on a
Yumi SmartPad (quad-core H3 @ 1.2 GHz, 1 GB RAM, Debian 13 trixie armhf)
on 2026-07-17.

## 1. The problem

- The Cortex-A7 is **32-bit only** (ARMv7-A): no native aarch64 execution is
  possible, unlike 64-bit SoCs (H5, A53…) which can boot a 32-bit OS.
- The official installer only ships x86_64 and arm64 builds → rejected on
  armv7l. The modern CLI is a **Bun-compiled binary** (a JS runtime embedded
  in the executable), not something a 32-bit userland can run.
- Official docs and forums all state "64-bit required". That is true of the
  binary distribution — but not of the npm history.

## 2. The key discovery: 2.1.112 is the last pure-JS npm release

The `@anthropic-ai/claude-code` npm package changed nature mid-2026:

| Version | npm package content | armv7l |
|---|---|---|
| ≤ 2.1.112 | **Pure JavaScript** (`cli.js`, engines `node>=18`, no arch check) | ✔ runs natively |
| ≥ 2.1.113 | 132 KB wrapper that downloads a **Bun binary** (x64/arm64 only) | ✖ dead |

So the whole trick is: **pin 2.1.112 with `--save-exact` and make sure nothing
ever updates it**. Node 20.19 and ripgrep 14.1 come straight from Debian trixie
armhf — no third-party repository, no cross-compilation, no emulation.

Two environment variables are required (written to `~/.claude/settings.json` →
`env` by the installer):

- `USE_BUILTIN_RIPGREP=0` — the package vendors ripgrep binaries but has no
  `arm-linux` build in `vendor/`; this forces the system `rg`.
- `DISABLE_AUTOUPDATER=1` (+ `"autoUpdates": false`) — a single auto-update
  would fetch a 64-bit binary and kill the install.

Notes: `sharp` works (an `@img/sharp-linux-arm` build exists for armv7);
the seccomp sandbox is unavailable on this kernel (non-fatal log line at
startup, everything else works).

## 3. Dead ends (all tested)

| Attempt | Result |
|---|---|
| Official installer | Rejects armv7l (x64/arm64 only) |
| npm ≥ 2.1.113 | Wrapper downloads a Bun x64/arm64 binary → unusable |
| box64 | Requires an **arm64 host** — useless on a 32-bit-only CPU |
| QEMU user-mode emulation of the native binary | Boots, but unusable (below) |

The emulation attempt in detail (same QEMU 7.2 64-on-32 technique as
[grok-cli-smartpi](https://github.com/Yumi-Lab/grok-cli-smartpi)): the official
`linux-arm64-musl` binary (~243 MB, dynamic musl — its `ld-musl-aarch64.so.1`
loader must be extracted from the Debian `musl` arm64 package into a sysroot
passed to qemu via `-L`):

- **SIGTRAP at boot** by default: JavaScriptCore/bmalloc reserves several GB of
  virtual address space (the "Gigacage") — impossible inside the ~3 GB address
  space of a 32-bit host (`mmap` returns ENOMEM → trap). Fix:
  `GIGACAGE_ENABLED=no Malloc=1` (plus `BUN_JSC_useJIT=false` to be safe) —
  `claude --version` (2.1.212) then works under emulation.
- **But it is unusable in practice**: without JIT, a simple `claude -p` burns
  10 minutes of CPU with no answer. With JIT (`BUN_JSC_useConcurrentJIT=false`
  avoids the segfaults the grok TUI hits), still > 8 minutes with no answer and
  the SoC at 89 °C → test killed.
- Grok survives emulation because it is **plain Rust with no JIT**; a Bun/JSC
  runtime under 64-on-32 emulation is hopeless. Emulation of the native Claude
  binary is only good for checking versions (`--version`, `--help`).

Conclusion: **native pure-JS 2.1.112 is THE usable solution on 32-bit** — and
since it runs natively, it is actually the *most capable* CLI on the pad
(heavy multi-turn agentic tasks are fine, where emulated CLIs overheat).

## 4. Installed layout

```
/usr/local/lib/node_modules/@anthropic-ai/claude-code   pinned 2.1.112 (npm -g)
/usr/local/bin/claude                                   official entry point (cli.js)
/usr/local/bin/claude-token-save                        OAuth token persister (this repo)
~/.claude/settings.json                                 env pinning + autoUpdates: false
~/.claude/.oauth_token                                  1-year token (mode 600)
```

## 5. Authentication (Claude Pro/Max account, no API key)

`claude setup-token` is the official headless flow:

1. It prints an OAuth URL — open it in a browser on **any** machine.
2. Approve, copy the one-time code, paste it in the terminal.
3. The CLI prints a `sk-ant-oat…` token, **valid 1 year**.

Pitfalls (all hit in real use):

- The token is displayed **once and persisted nowhere** (it is NOT written to
  `~/.claude/.credentials.json`). Copy it immediately, then run
  `claude-token-save <token>` — it stores `~/.claude/.oauth_token` (600) and
  injects `env.CLAUDE_CODE_OAUTH_TOKEN` into `settings.json`.
- The OAuth code is **single-use**: a failed paste means restarting the flow.
- When driving `setup-token` remotely through tmux: use a wide pane
  (`tmux new-session -x 450`) so the token box is not wrapped/truncated, and
  end the command with `; sleep 99999` — otherwise the pane dies with the
  process and the token is lost.

## 6. Performance and memory (1 GB H3)

Measured on the SmartPad (Debian 13 trixie armhf, Node 20.19):

- `claude --version`: 6.6 s (Node cold start of a large bundle)
- `claude -p "simple question"`: ~23 s end-to-end
- Multi-turn agentic sessions: stable, no thermal runaway (native JS does not
  saturate the SoC the way emulation does — the same pad hit 102 °C and froze
  under a 4-core emulated agentic task).

On 1 GB of RAM with SD-card swap, memory exhaustion freezes the machine before
the kernel OOM killer reacts — the installer enables **earlyoom**. Operating
rules on the pad: one heavy CLI at a time, and bound batch workloads
(`systemd-run --scope -p MemoryMax=600M`, `timeout`).

## 7. Maintenance

- **Never update beyond 2.1.112 on 32-bit.** Auto-update is disabled at three
  levels (env var, `autoUpdates: false`, `--save-exact`); don't defeat them.
- To repair or reinstall: re-run `install.sh` (idempotent).
- If `claude` suddenly breaks, check `npm ls -g @anthropic-ai/claude-code` —
  anything other than 2.1.112 means something updated it.
- Token expired (1 year): redo `claude setup-token` + `claude-token-save`.
