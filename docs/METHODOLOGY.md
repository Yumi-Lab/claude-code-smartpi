# Full methodology — official Claude Code CLI on 32-bit ARM

How to run a CLI whose official distribution is 64-bit only (x86_64/aarch64
Bun binaries) on a SoC that can only execute 32-bit code (Allwinner H3,
Cortex-A7, armv7l). Reference document: every choice below was tested on a
Yumi SmartPad (quad-core H3 @ 1.2 GHz, 1 GB RAM, Debian 13 trixie armhf)
on 2026-07-17/18 (the extraction + Bun→Node shim path, section 4, on 07-18).

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

Conclusion on emulation: pinned pure-JS 2.1.112 was the first usable solution on
32-bit, and running the *native* binary under QEMU is a dead end. But 2.1.112 is
no longer the ceiling — section 4 shows how to run **any** recent version
natively by extracting its embedded JS.

## 4. Breakthrough: run any recent version by extracting its embedded JS

`bun build --compile` produces a single executable, but it **embeds the readable
JavaScript** inside it (even with `--bytecode`, JavaScriptCore needs the source
next to the bytecode). So the modern "64-bit-only" binary still contains a
runnable JS bundle — we just have to get it out and give it a Node-compatible
runtime. `install-latest.sh` does this entirely **on-device, with no token and no
account** (validated on the SmartPad, 2026-07-18):

1. **Download the official binary** from the public release URL
   (`downloads.claude.ai/claude-code-releases/<ver>/<platform>/claude`, ~240 MB).
   The platform is irrelevant — the embedded JS is byte-for-byte identical across
   platforms — we only need the bytes.
2. **Carve out the JS** ([`shim/extract-bun-js.py`](../shim/extract-bun-js.py)):
   the bundle sits in a trailer terminated by the `\n---- Bun! ----\n` magic; the
   script locates it and extracts `cli.js` (~20 MB). Pure stdlib, works on armv7l.
3. **Lower the one modern syntax** the bundle uses — `using` / `await using`
   (explicit resource management, Node 24+) — with **esbuild `--target=node20`**.
   This matters: a naïve `sed using→const` would drop the `Symbol.dispose` calls
   and leak file descriptors and lock files; esbuild emits the correct
   `try/finally`. esbuild ships a native `linux-arm` (armv7) build, so it runs on
   the pad (~30 s for the 20 MB bundle).
4. **Shim the Bun-only APIs** ([`shim/bun-shim.mjs`](../shim/bun-shim.mjs)). The
   app calls a small surface — `Bun.spawn`, `Bun.file`, `Bun.hash`,
   `Bun.stringWidth` / `stripANSI` / `wrapAnsi` (Ink layout), `Bun.YAML`,
   `Bun.semver`, `Bun.which`, `require("bun:ffi")` — and the truly Bun-only bits
   (`Bun.Terminal`, `Bun.serve`, `Bun.SQL`) are already **guarded** in the code
   (it literally checks "running under Node?" and degrades). ~15 functions in the
   shim cover everything the CLI path touches. A tiny launcher
   ([`shim/claude.mjs`](../shim/claude.mjs)) installs the shim, then runs the
   bundle as a CJS factory (it is exported as an ESM default so `import.meta.*`
   stays legal).
5. **Run it under Debian's own Node 20.** Because esbuild already lowered the
   syntax, the system `nodejs` (20.19, straight from apt) parses and runs the
   bundle — **no Node 22/24 needed**. `claude --version` answers in ~6–10 s, one
   shot in ~24 s: same ballpark as the pinned 2.1.112.

Runtime modules Bun provides but Node does not (`ws`, `undici`, `js-yaml`) are
installed with npm and shipped alongside the bundle. The Anthropic JS is built
**locally on the device** from the user's own download and never redistributed by
this repo — only our extractor, shim and launcher live here.

Two settings still apply exactly as for the pinned build: `USE_BUILTIN_RIPGREP=0`
(system `rg`) and `DISABLE_AUTOUPDATER=1` (the installer owns updates — re-run
`install-latest.sh` to move to a newer version).

## 5. Installed layout

Latest channel (`install-latest.sh`):

```
/opt/claude-code/lib/claude-code/                        extracted + shimmed bundle
    cli.js  bundle.cjs  claude.mjs  bun-shim.mjs  node_modules/{ws,undici,js-yaml,argparse}
    bundle.v8cache                                        V8 bytecode cache (primed at install)
    VERSION                                               installed version marker
/usr/local/bin/claude                                    #!/bin/sh wrapper
                                                         exec taskset -c ${CLAUDE_CPUS:-0,1,2,3} \
                                                           nice -n 5 node /opt/claude-code/lib/claude-code/claude.mjs "$@"
```

Pinned channel (`install.sh`):

```
/usr/local/lib/node_modules/@anthropic-ai/claude-code   pinned 2.1.112 (npm -g)
/usr/local/bin/claude-bin                               real npm entry point → cli.js
/usr/local/bin/claude                                   #!/bin/sh wrapper
                                                        exec taskset -c ${CLAUDE_CPUS:-0,1,2,3} \
                                                          nice -n 5 /usr/local/bin/claude-bin "$@"
/usr/local/bin/claude-token-save                        OAuth token persister (this repo)
~/.claude/settings.json                                 env pinning + autoUpdates: false
~/.claude/.oauth_token                                  1-year token (mode 600)
```

`npm install -g` creates `claude` as a symlink to `cli.js`; the installer keeps
that real target as `claude-bin` and replaces the public `claude` name with a
small CPU-affinity wrapper (`taskset`/`nice`, both from util-linux/coreutils —
no extra dependency). `npm ls -g @anthropic-ai/claude-code` still reports 2.1.112
(it reads `node_modules`, not the bin link). The catch: **any** npm operation on
the package (`install`, `update`, `rebuild`) recreates the plain symlink and
drops the wrapper — the installer is idempotent (it re-clears a stale wrapper
before `npm install` and re-wraps after, keying idempotence on the resolved
`cli.js`, never on `bin/claude`), so re-running `install.sh` restores it.

## 6. Authentication (Claude Pro/Max account, no API key)

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

## 7. Performance and memory (1 GB H3)

Measured on the SmartPad (Debian 13 trixie armhf, Node 20.19):

- `claude --version`: ~8.4 s uncached → **2.9 s with the V8 bytecode cache** (below)
- `claude -p "simple question"`: ~23 s end-to-end
- Multi-turn agentic sessions: stable, no thermal runaway (native JS does not
  saturate the SoC the way emulation does — the same pad hit 102 °C and froze
  under a 4-core emulated agentic task).

### V8 bytecode cache (warm start, since the latest channel)

Most of that cold start is V8 parsing+compiling the 26 MB bundle — ~6.8 s of the
~8.4 s `--version` on the H3 (measured, see [`bench/`](../bench/)). The launcher
([`shim/claude.mjs`](../shim/claude.mjs)) loads the bundle through `vm.Script` with a
persisted bytecode cache (`produceCachedData`/`cachedData`): the first launch compiles
once and writes `$LIB/bundle.v8cache`; every launch after skips compilation.
`install-latest.sh` **primes** that cache at install time, so the very first real
launch is already warm — no user action.

Measured on the Smart Pi One: `claude --version` **8.4 s → 2.9 s** (compile phase
6.8 s → ~0 ms), peak RSS 158 → 115 MB. The cache is keyed on VERSION (a whole new
`$LIB` on update) and on the running V8 (`cachedDataRejected` after a Node upgrade), so
it rebuilds itself automatically — no stale-cache risk. This is why the bundle is now
`bundle.cjs` (esbuild `--format=cjs`, which also lowers `import.meta`) instead of the
earlier ESM `bundle.mjs` + `await import()` path. Full comparison — including why a
Go/`goja` rewrite is a dead end (`goja` cannot even parse the bundle's dynamic
`import()`) — lives in [`bench/`](../bench/).

On 1 GB of RAM with SD-card swap, memory exhaustion freezes the machine before
the kernel OOM killer reacts — the installer enables **earlyoom**. Operating
rules on the pad: one heavy CLI at a time, and bound batch workloads
(`systemd-run --scope -p MemoryMax=600M`, `timeout`).

### Runtime CPU throttle (`CLAUDE_CPUS`)

Every launch goes through the `claude` wrapper (see the layout above):

```
exec taskset -c "${CLAUDE_CPUS:-0,1,2,3}" nice -n 5 /usr/local/bin/claude-bin "$@"
```

By default it runs on **all 4 cores at `nice 5`**. To pin a session to a subset
of cores **without reinstalling** — to leave headroom for another job (the pad
runs one heavy CLI at a time) or to stay cool on a fan-less board — set the
variable at launch:

```
CLAUDE_CPUS=0,1 claude -p "…"     # 2 cores; verify with:
grep Cpus_allowed_list /proc/<pid>/status   # → 0-1
```

The mask is inherited by every child process and worker thread of the CLI. This
is the same knob as `GROK_CPUS` on the sister
[grok-cli-smartpi](https://github.com/Yumi-Lab/grok-cli-smartpi) — where it is a
thermal necessity (a 4-core emulated agentic run froze the H3 at 102 °C). Native
pure-JS Claude is far gentler on the SoC (no thermal runaway observed), so here
the knob is mostly about **sharing cores**, not survival — but it is wired
identically for consistency across the CLI family.

## 8. Maintenance

- **Single installer:** there is now one system — `install.sh` installs the newest
  Claude Code at run time and is also the updater. Re-run it to update (pin a version
  with `bash -s -- <version>`). `install-latest.sh` is kept only as a deprecated alias
  forwarding to `install.sh` (so the OTA and old one-liners keep working).
- Never use `claude update` — it would replace the shimmed bundle with a 64-bit
  binary; auto-update is disabled (env var + `autoUpdates: false`).
- The `/usr/local/bin/claude` wrapper is version-independent — routine updates only
  swap the payload under `/opt/claude-code`, so unprivileged (gateway) updates never
  touch it. The pinned pure-JS 2.1.112 path described above is historical (kept in git
  history); the extract + Node 22 build is the one system going forward.
- Token expired (1 year): redo `claude setup-token` + `claude-token-save`.
