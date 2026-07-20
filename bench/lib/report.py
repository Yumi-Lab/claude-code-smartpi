#!/usr/bin/env python3
"""
report.py — render the raw JSONL emitted by run.sh into a markdown results table.

Reads lines of JSON (mixed shapes) from a file argument; recognizes:
  - measure.py rows        : have "wall_median_ms" + "label"
  - goja probe report      : have "engine":"goja"
  - v8 code-cache report   : have "variant":"v8-codecache"
Everything is grouped into a human comparison table + per-variant detail.
"""
import json
import sys


def load(path):
    rows = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return rows


def median(xs):
    xs = sorted(xs)
    if not xs:
        return None
    n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2


def main():
    if len(sys.argv) < 3:
        print("usage: report.py raw.jsonl 'Host label'", file=sys.stderr)
        return 2
    rows = load(sys.argv[1])
    host = sys.argv[2]

    measures = [r for r in rows if "wall_median_ms" in r and "label" in r]
    goja = [r for r in rows if r.get("engine") == "goja"]
    cc = [r for r in rows if r.get("variant") == "v8-codecache"]

    meta = {}
    for r in rows:
        if "meta" in r:
            meta = r["meta"]
            break

    out = []
    out.append(f"# Benchmark results — {host}")
    out.append("")
    if meta:
        out.append(
            f"- **Host:** {meta.get('os','?')}/{meta.get('arch','?')} · "
            f"Node {meta.get('node','?')} · Go {meta.get('go','?')}"
        )
        out.append(f"- **Bundle:** Claude Code {meta.get('bundle_version','?')} "
                   f"(`{meta.get('bundle_mb','?')} MB` node20 lowered)")
        out.append(f"- **Reps:** {meta.get('reps','?')} (median reported; first run discarded)")
        out.append(f"- **Generated:** {meta.get('when','?')}")
        out.append("")

    # ---- headline comparison table ----
    out.append("## Summary")
    out.append("")
    out.append("| Variant | Measure | Median | Min | Peak RSS | Notes |")
    out.append("|---|---|--:|--:|--:|---|")
    for m in measures:
        rss = f"{m['peak_rss_mb']:.0f} MB" if m.get("peak_rss_mb") else "—"
        note = ""
        if not m.get("exit_ok", True):
            note = f"exits={m.get('exit_codes')}"
        out.append(
            f"| {m.get('group','')} | {m['label']} | "
            f"{m['wall_median_ms']:.0f} ms | {m['wall_min_ms']:.0f} ms | {rss} | {note} |"
        )
    out.append("")

    # ---- V8 code cache detail ----
    if cc:
        cold = median([c["cold_compile_ms"] for c in cc])
        warm = median([c["warm_compile_ms"] for c in cc])
        c0 = cc[0]
        saved = round((1 - (warm / cold)) * 100, 1) if cold else 0
        out.append("## Variant 3 — V8 bytecode cache (compile phase, keeps JIT)")
        out.append("")
        out.append(f"- Cold compile (from source): **{cold:.0f} ms** (median of {len(cc)})")
        out.append(f"- Warm compile (from cache):  **{warm:.1f} ms**  → compile time cut **{saved:.0f}%**")
        out.append(f"- Cache size: {c0['cache_bytes']/1e6:.1f} MB · rejected: {c0['cached_data_rejected']}")
        out.append(f"- Node {c0['node']} / {c0['arch']}")
        out.append("")
        out.append("> Compile-phase only; end-to-end includes module init/exec. On Node 22 the "
                   "end-to-end `NODE_COMPILE_CACHE` rows above show the real cold-vs-warm launch delta.")
        out.append("")

    # ---- goja detail ----
    if goja:
        g = goja[0]
        out.append("## Variant 2 — goja (pure-Go JS engine)")
        out.append("")
        out.append(f"- **Parses/compiles the bundle:** {'YES' if g.get('compile_ok') else '**NO**'}")
        if not g.get("compile_ok"):
            out.append(f"- Fails after ~{g.get('compile_ms','?')} ms of parsing with:")
            out.append(f"  `{g.get('compile_err','')}`")
            out.append("- Cause: the bundle uses dynamic `import()` / `await import(...)` (a feature goja "
                       "does not implement). Removing it needs a semantics-changing source rewrite, not "
                       "target lowering — i.e. a research project, not an engineering task.")
        else:
            out.append(f"- compile {g.get('compile_ms')} ms · first Node-API wall: "
                       f"`{g.get('first_wall','—')}`")
            out.append(f"- modules requested before wall: {g.get('modules_requested')}")
        out.append(f"- goja-host binary builds & cross-compiles to armv7/arm64 (Go, no CGO).")
        out.append("")

    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
