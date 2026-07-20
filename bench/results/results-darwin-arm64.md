# Benchmark results — Darwin/arm64 · Node 22.23.1

- **Host:** Darwin/arm64 · Node 22.23.1 · Go 1.26.5
- **Bundle:** Claude Code 2.1.215 (`26.6 MB` node20 lowered)
- **Reps:** 5 (median reported; first run discarded)
- **Generated:** 2026-07-19 23:28 CEST

## Summary

| Variant | Measure | Median | Min | Peak RSS | Notes |
|---|---|--:|--:|--:|---|
| V1 Node baseline | node claude --version | 310 ms | 300 ms | 211 MB |  |
| V1 Node baseline | node claude --help | 421 ms | 415 ms | 255 MB |  |
| V2 goja | goja compile+run (parse-fail) | 420 ms | 412 ms | 250 MB |  |
| V3 V8 code cache | cached launcher COLD (no cache) | 316 ms | 310 ms | 266 MB |  |
| V3 V8 code cache | cached launcher WARM (bytecode cache) | 83 ms | 77 ms | 193 MB |  |
| V3 V8 code cache | node --version (compile-cache warm) | 83 ms | 83 ms | 175 MB |  |

## Variant 3 — V8 bytecode cache (compile phase, keeps JIT)

- Cold compile (from source): **256 ms** (median of 5)
- Warm compile (from cache):  **0.0 ms**  → compile time cut **100%**
- Cache size: 8.2 MB · rejected: False
- Node 22.23.1 / arm64

> Compile-phase only; end-to-end includes module init/exec. On Node 22 the end-to-end `NODE_COMPILE_CACHE` rows above show the real cold-vs-warm launch delta.

## Variant 2 — goja (pure-Go JS engine)

- **Parses/compiles the bundle:** **NO**
- Fails after ~366.715 ms of parsing with:
  `SyntaxError: /Users/nicolasmichaut/Documents/GitHub/claude-code-smartpi/bench/build/bundle.goja.cjs: Line 9788:21 Unexpected reserved word (and 2750 more errors)`
- Cause: the bundle uses dynamic `import()` / `await import(...)` (a feature goja does not implement). Removing it needs a semantics-changing source rewrite, not target lowering — i.e. a research project, not an engineering task.
- goja-host binary builds & cross-compiles to armv7/arm64 (Go, no CGO).

