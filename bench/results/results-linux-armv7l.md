# Benchmark results — Linux/armv7l · Node 20.19.2

- **Host:** Linux/armv7l · Node 20.19.2 · Go none
- **Bundle:** Claude Code 2.1.215 (`26.6 MB` node20 lowered)
- **Reps:** 5 (median reported; first run discarded)
- **Generated:** 2026-07-19 21:42 UTC

## Summary

| Variant | Measure | Median | Min | Peak RSS | Notes |
|---|---|--:|--:|--:|---|
| V1 Node baseline | node claude --version | 8359 ms | 8012 ms | 158 MB |  |
| V1 Node baseline | node claude --help | 12942 ms | 12886 ms | 158 MB |  |
| V2 goja | goja compile+run (parse-fail) | 11945 ms | 11632 ms | 214 MB |  |
| V3 V8 code cache | cached launcher COLD (no cache) | 8574 ms | 8458 ms | 158 MB |  |
| V3 V8 code cache | cached launcher WARM (bytecode cache) | 2936 ms | 2930 ms | 115 MB |  |

## Variant 3 — V8 bytecode cache (compile phase, keeps JIT)

- Cold compile (from source): **6797 ms** (median of 5)
- Warm compile (from cache):  **1.5 ms**  → compile time cut **100%**
- Cache size: 7.2 MB · rejected: False
- Node 20.19.2 / arm

> Compile-phase only; end-to-end includes module init/exec. On Node 22 the end-to-end `NODE_COMPILE_CACHE` rows above show the real cold-vs-warm launch delta.

## Variant 2 — goja (pure-Go JS engine)

- **Parses/compiles the bundle:** **NO**
- Fails after ~12603.88 ms of parsing with:
  `SyntaxError: /tmp/bench/build/bundle.goja.cjs: Line 9788:21 Unexpected reserved word (and 2750 more errors)`
- Cause: the bundle uses dynamic `import()` / `await import(...)` (a feature goja does not implement). Removing it needs a semantics-changing source rewrite, not target lowering — i.e. a research project, not an engineering task.
- goja-host binary builds & cross-compiles to armv7/arm64 (Go, no CGO).

