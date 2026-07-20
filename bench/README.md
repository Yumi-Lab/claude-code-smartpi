# bench/ — is any "JS→Go / native" route faster than the current Node path on the H3?

This harness answers, with numbers, the question behind the original "compile the Claude
Code JS orchestrator to Go" request: **what actually makes Claude Code faster on the Smart
Pi One (Allwinner H3, armv7l), versus what we already ship?**

It runs the *real* extracted bundle (`claude-2.1.215.cli.js`, ~20 MB → ~26 MB after esbuild
lowering) three ways and measures cold-start latency and peak memory.

## TL;DR — verdict

| Route | Result | Faster than today? |
|---|---|---|
| **JS → Go transpiler** | Impossible — no tool exists; the bundle uses React/Ink, native addons, full Node API | — |
| **goja (JS *inside* Go)** | **Dead end — goja cannot even parse the bundle** (dynamic `import()`), and has no JIT | No (never runs) |
| **Node baseline (today)** | V8 + JIT — already the fastest JS runtime available on armv7l | baseline |
| **V8 bytecode cache** ⭐ | Keeps V8/JIT; persists compiled bytecode → **~4× faster cold start**, works on Node 20 | **Yes** |

**Recommendation:** drop the Go idea for performance. Ship a **V8 bytecode-cache launcher**
(`v8-fast/claude-cc.cjs` is a working Node-20 PoC that really launches Claude). It is the only
change here that makes the pad *faster*, and it needs no new runtime. The larger follow-up win
is a **warm resident daemon** (parse the 26 MB once, answer many prompts) — quantified below.

## Results (dev Mac — directional; the pad table is authoritative)

`Darwin/arm64 · Node 22.23.1 · Go 1.26.5 · bundle 2.1.215 · reps 6` — full table in
[results/results-darwin-arm64.md](results/results-darwin-arm64.md).

| Variant | Measure | Median | Peak RSS |
|---|---|--:|--:|
| V1 Node baseline (today) | `claude --version` | **288 ms** | 213 MB |
| V1 Node baseline (today) | `claude --help` | 448 ms | 256 MB |
| V2 goja (pure-Go engine) | compile+run | **fails to parse @ ~400 ms** | 248 MB |
| V3 V8 cache — cached launcher COLD | `claude --version` | 340 ms | 269 MB |
| V3 V8 cache — cached launcher **WARM** | `claude --version` | **73 ms** | 193 MB |
| V3 V8 cache — `NODE_COMPILE_CACHE` warm (Node 22) | `claude --version` | 74 ms | 174 MB |

Compile micro-benchmark: cold compile of the 26 MB bundle **270 ms → 0 ms** warm (bytecode
cache 8.2 MB, accepted). On the Mac's fast core this is sub-second either way; **on the H3,
where a cold `--version` takes 6–10 s dominated by parsing+compiling the 26 MB, removing the
compile phase is a multi-second win** — that is what the pad run will confirm.

## Why goja (JS-in-Go) is a dead end — the evidence

`goja.Compile()` aborts on the real bundle with **2751 syntax errors**, the first at:

```
bundle.goja.cjs:9788:21  →  let r = await import("fs"), …   ← Unexpected reserved word
```

The bundle lazy-loads Node modules through **dynamic `import()` / `await import(...)`**
(dozens of sites), a feature goja does not implement. It cannot be removed by esbuild target
lowering (external `import()` is preserved) nor by full bundling (optional packages like
`node-fetch` aren't resolvable, and `import()`→`require()` is **not** semantically equivalent —
one yields a namespace with `.default`, the other `module.exports`). Making the bundle
goja-parseable is a semantics-changing source rewrite — a research project, not a lowering.

And even if it parsed, goja has **no JIT** (interprets, ~10–100× slower than V8) and would need
~85% of the Node stdlib hand-written in Go. The cross-compiled Go binaries build fine —
`dist/goja-host-linux-armv7` is a **static 32-bit ARM ELF (13.2 MB)** — proving the *toolchain*
was never the blocker; the *runtime* is.

## The three variants

- **V1 `node-baseline/`** — the shipping path verbatim: `shim/claude.mjs` + `shim/bun-shim.mjs`
  over the esbuild-lowered `bundle.node20.mjs`, under system Node (V8 + JIT). The control line.
- **V2 `goja-host/`** — a Go program (`github.com/dop251/goja`) that tries to compile+run the
  es2020-lowered bundle headless, recording compile time, memory and the first Node-API wall.
  Cross-compiles to armv7/arm64/amd64 (no CGO) into `dist/`.
- **V3 `v8-fast/`** — keeps V8, attacks the cold start:
  - `codecache.cjs` — isolates the compile phase via `vm.Script` `produceCachedData`/`cachedData`.
  - `claude-cc.cjs` — a **Node-20-compatible cached launcher** that persists the bytecode to disk
    and really boots Claude. This is the shippable PoC.
  - `NODE_COMPILE_CACHE` end-to-end cross-check (Node ≥ 22 only).

## How to run

```bash
cd bench
./prepare.sh          # esbuild-lower cli.js → build/ bundles; stage node-baseline deps
./run.sh 10           # run all variants ×10 → results/results-<os>-<arch>.md
```

`prepare.sh` needs the extracted `input/cli.js` (already copied from
`~/Documents/GitHub/claude-js-extracted/claude-2.1.215.cli.js`), `node`, `npm`, `esbuild`
(auto-installed), and `go` for the goja host (optional — a prebuilt ARM binary in
`goja-host/dist/` is used as fallback).

### On the pad (H3, armv7l — the authoritative run)

The pad has no Go toolchain, so ship the prebuilt binary:

```bash
# from the Mac
scp -r bench pi@PAD:/tmp/bench                       # includes goja-host/dist/goja-host-linux-armv7
ssh pi@PAD 'cd /tmp/bench && ./prepare.sh && ./run.sh 10'
# → /tmp/bench/results/results-linux-armv7l.md
```

On Node 20 the `NODE_COMPILE_CACHE` cross-check is skipped, but the **portable cached launcher
(COLD vs WARM)** still runs and gives the real end-to-end H3 number — the one that decides the
follow-up. Expected: baseline `--version` in seconds; WARM cached launcher a large fraction
faster (compile phase eliminated).

## What to build next (the follow-up this benchmark chooses)

1. **Bytecode-cache launcher in the installer.** Fold `claude-cc.cjs`'s `vm.Script`
   produce/persist/reuse into the shipping launcher (`shim/claude.mjs`), keyed on bundle
   VERSION so the cache rebuilds on update. Portable to the pad's Node 20; no new runtime.
2. **Warm resident daemon** (bigger win). A small resident process parses the 26 MB once and
   services `claude -p` requests over a socket — turning the per-launch parse into a one-time
   cost. The WARM numbers above (~73 ms vs 288 ms cold on Mac; seconds on the H3) are the
   parse-once ceiling this would approach for every prompt.
3. Not Go. Every Go route is either impossible (transpile) or a regression (goja: no JIT, and
   it can't even parse the bundle).

## Files

```
prepare.sh              lower cli.js → build/{bundle.node20.mjs,.cjs, bundle.goja.cjs}; stage V1
run.sh                  orchestrate all variants → results/*.md
lib/measure.py          median wall-time + peak-RSS (portable macOS/Linux, no date +%N)
lib/report.py           render raw JSONL → markdown table
node-baseline/          V1: shim launcher + bundle.mjs + runtime deps (staged by prepare.sh)
goja-host/main.go       V2: goja probe; dist/ holds cross-compiled armv7/arm64/amd64 binaries
v8-fast/codecache.cjs   V3: compile-phase cache micro-bench
v8-fast/claude-cc.cjs   V3: Node-20 cached launcher PoC (really boots Claude)
results/                emitted tables + raw JSONL (committed)
input/, build/          heavy/derived artifacts (git-ignored)
```
