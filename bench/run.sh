#!/usr/bin/env bash
# run.sh — run every benchmark variant on this host and emit a markdown results table.
# Directional on the dev Mac; authoritative on the pad (armv7l). Re-runnable.
#
#   ./run.sh [REPS]           (default REPS=10)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
REPS="${1:-10}"
BUILD="$HERE/build"
RAW="$(mktemp)"; trap 'rm -f "$RAW"' EXIT
M() { python3 "$HERE/lib/measure.py" "$@"; }

# --- 0. prerequisites -------------------------------------------------------
[ -f "$BUILD/bundle.node20.mjs" ] || { echo "[run] bundles missing → running prepare.sh"; ./prepare.sh || exit 1; }
OS="$(uname -s)"; ARCH="$(uname -m)"
NODE_V="$(node -p process.versions.node 2>/dev/null || echo none)"
NODE_MAJOR="${NODE_V%%.*}"; [ "$NODE_MAJOR" = "none" ] && NODE_MAJOR=0
GO_V="$(go version 2>/dev/null | awk '{print $3}' | sed 's/go//' || echo none)"
BUNDLE_MB="$(python3 -c "import os;print(round(os.path.getsize('$BUILD/bundle.node20.mjs')/1e6,1))")"
BVER="$(basename "$(ls "$HERE"/input/cli.js)" | sed 's/.*/2.1.215/')"
WHEN="$(date '+%Y-%m-%d %H:%M %Z')"
printf '{"meta":{"os":"%s","arch":"%s","node":"%s","go":"%s","bundle_mb":"%s","bundle_version":"%s","reps":"%s","when":"%s"}}\n' \
  "$OS" "$ARCH" "$NODE_V" "$GO_V" "$BUNDLE_MB" "$BVER" "$REPS" "$WHEN" >> "$RAW"

echo "== bench on $OS/$ARCH · Node $NODE_V · Go $GO_V · reps=$REPS =="

# --- 1. Variant 1: Node baseline (shipping path) ----------------------------
echo "[V1] Node baseline (V8 + JIT, current path)"
M --label "node claude --version" --group "V1 Node baseline" --reps "$REPS" --warmup 1 \
  --cwd "$HERE/node-baseline" --expect-exit 0 -- node claude.mjs --version >> "$RAW"
M --label "node claude --help" --group "V1 Node baseline" --reps "$REPS" --warmup 1 \
  --cwd "$HERE/node-baseline" --expect-exit 0 -- node claude.mjs --help >> "$RAW"

# --- 2. Variant 2: goja host (pure-Go engine) -------------------------------
echo "[V2] goja host (pure-Go, no JIT)"
GOJA="$HERE/goja-host/goja-host"
# Prefer a fresh local build; else fall back to a prebuilt cross-compiled binary for this
# arch (the pad has no Go toolchain — copy dist/goja-host-linux-armv7 there).
if [ ! -x "$GOJA" ]; then
  if command -v go >/dev/null 2>&1; then ( cd "$HERE/goja-host" && go build -o goja-host . ) || echo "[V2] go build failed"; fi
fi
if [ ! -x "$GOJA" ]; then
  case "$ARCH" in
    armv7l|armhf) GOJA="$HERE/goja-host/dist/goja-host-linux-armv7" ;;
    aarch64|arm64) GOJA="$HERE/goja-host/dist/goja-host-linux-arm64" ;;
    x86_64|amd64) GOJA="$HERE/goja-host/dist/goja-host-linux-amd64" ;;
  esac
fi
if [ -x "$GOJA" ]; then
  # tool-internal probe (compile ok? first wall?) — captured directly
  "$GOJA" --bundle "$BUILD/bundle.goja.cjs" --args "--version" >> "$RAW" 2>/dev/null
  # wall + RSS of a launch (parses until it fails / walls) — labelled honestly
  M --label "goja compile+run (parse-fail)" --group "V2 goja" --reps "$REPS" --warmup 1 \
    -- "$GOJA" --bundle "$BUILD/bundle.goja.cjs" --args "--version" >> "$RAW"
else
  echo '{"engine":"goja","compile_ok":false,"compile_err":"go build unavailable on this host"}' >> "$RAW"
fi

# --- 3. Variant 3: V8 stays, cold start attacked ----------------------------
echo "[V3] V8 code cache (keeps JIT, kills compile)"
# 3A compile micro-bench (portable Node 20 + 22): run a few times for a stable median
for i in 1 2 3 4 5; do
  node "$HERE/v8-fast/codecache.cjs" "$BUILD/bundle.node20.cjs" >> "$RAW" 2>/dev/null || true
done
# 3B portable end-to-end cached launcher (Node 20 & 22): vm.Script persisted bytecode.
# Really launches Claude (--version). cold = cache disabled; warm = cache present.
export BENCH_BUNDLE="$BUILD/bundle.node20.cjs" BENCH_BASE="$HERE/node-baseline"
export BENCH_CACHE="$HERE/v8-fast/.compile-cache/bundle.v8cache"
CCJS="$HERE/v8-fast/claude-cc.cjs"
rm -rf "$HERE/v8-fast/.compile-cache"
BENCH_CACHE_DISABLE=1 M --label "cached launcher COLD (no cache)" --group "V3 V8 code cache" \
  --reps "$REPS" --warmup 1 --expect-exit 0 -- node "$CCJS" --version >> "$RAW"
node "$CCJS" --version >/dev/null 2>&1 || true   # build the cache once
M --label "cached launcher WARM (bytecode cache)" --group "V3 V8 code cache" \
  --reps "$REPS" --warmup 1 --expect-exit 0 -- node "$CCJS" --version >> "$RAW"
unset BENCH_CACHE_DISABLE

# 3C end-to-end NODE_COMPILE_CACHE (Node >= 22 only): cross-check on the shipping ESM launcher
if [ "$NODE_MAJOR" -ge 22 ]; then
  CC="$(mktemp -d)"
  NODE_COMPILE_CACHE="$CC" node "$HERE/node-baseline/claude.mjs" --version >/dev/null 2>&1 || true  # populate
  NODE_COMPILE_CACHE="$CC" M --label "node --version (compile-cache warm)" --group "V3 V8 code cache" \
    --reps "$REPS" --warmup 1 --cwd "$HERE/node-baseline" --expect-exit 0 -- node claude.mjs --version >> "$RAW"
  rm -rf "$CC"
else
  echo "[V3] NODE_COMPILE_CACHE end-to-end skipped (needs Node >= 22; this host: $NODE_V)"
fi

# --- 4. render --------------------------------------------------------------
OUT="$HERE/results/results-$(echo "$OS" | tr 'A-Z' 'a-z')-$ARCH.md"
mkdir -p "$HERE/results"
python3 "$HERE/lib/report.py" "$RAW" "$OS/$ARCH · Node $NODE_V" > "$OUT"
cp "$RAW" "$HERE/results/raw-$(echo "$OS" | tr 'A-Z' 'a-z')-$ARCH.jsonl"
echo "== wrote $OUT =="
echo
cat "$OUT"
