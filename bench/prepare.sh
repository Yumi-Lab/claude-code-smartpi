#!/usr/bin/env bash
# prepare.sh — build the lowered bundles the benchmark variants consume, from the
# raw extracted cli.js (bench/input/cli.js). Mirrors install-latest.sh steps 5-6.
#
# Emits into bench/build/:
#   bundle.node20.mjs  ESM  target=node20  → Variant 1 (Node baseline, shipping path)
#   bundle.node20.cjs  CJS  target=node20  → Variant 3 (vm.Script code-cache micro-bench)
#   bundle.goja.cjs    CJS  target=es2020  → Variant 2 (goja host; lowers `using`, keeps BigInt)
#
# NB: es2017 is too low — the bundle uses BigInt literals (1024n), which are ES2020.
# es2020 keeps BigInt while still lowering `using` (an ES2023 feature Node 20/goja lack).
#
# Idempotent; safe to re-run. Records esbuild success/fail per target.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IN="$HERE/input/cli.js"
BUILD="$HERE/build"
mkdir -p "$BUILD"

[ -f "$IN" ] || { echo "FATAL: $IN missing — copy the extracted cli.js there first." >&2; exit 1; }

# esbuild: prefer a local install, else npx (network on first use). Pin a version so
# the pad and the Mac lower identically.
ESBUILD_VER="0.24.2"
if [ -x "$BUILD/node_modules/.bin/esbuild" ]; then
  ESBUILD="$BUILD/node_modules/.bin/esbuild"
else
  echo "[prepare] installing esbuild@$ESBUILD_VER (one time)…"
  ( cd "$BUILD"
    printf '{"name":"bench-build","private":true}\n' > package.json
    npm install --no-audit --no-fund --silent "esbuild@$ESBUILD_VER" >/dev/null 2>&1
  )
  ESBUILD="$BUILD/node_modules/.bin/esbuild"
fi
"$ESBUILD" --version >/dev/null || { echo "FATAL: esbuild unusable" >&2; exit 1; }
echo "[prepare] esbuild $("$ESBUILD" --version)"

# The raw cli.js is a bare CJS factory:  (function(exports,require,module,__filename,__dirname){…})
# Wrap it as `export default <factory>` so esbuild has a valid module to lower, then emit
# both ESM (import default) and CJS (module.exports.default) shapes.
lower() { # $1 target, $2 format, $3 outfile, $4 human-label
  local target="$1" format="$2" out="$3" label="$4"
  printf '[prepare] %-22s ' "$label"
  if "$ESBUILD" "$RAW" --outfile="$out" --format="$format" \
        --target="$target" --platform=node --log-level=error 2>"$out.err"; then
    printf 'OK  (%s, %s MB)\n' "$target" "$(python3 -c "import os;print(round(os.path.getsize('$out')/1048576,1))")"
    rm -f "$out.err"
  else
    printf 'FAIL — see %s\n' "$out.err"
    return 1
  fi
}

# Idempotent: skip the (slow, ~1m40 on H3) esbuild lowering when all bundles are already
# built and newer than the input. `rm -rf build/` (or touch input/cli.js) to force a rebuild.
if [ "$BUILD/bundle.node20.mjs" -nt "$IN" ] && [ "$BUILD/bundle.node20.cjs" -nt "$IN" ] \
   && [ "$BUILD/bundle.goja.cjs" -nt "$IN" ]; then
  echo "[prepare] bundles already built (newer than input) — skipping esbuild lowering."
else
  RAW="$BUILD/bundle.raw.mjs"
  printf 'export default ' > "$RAW"
  cat "$IN" >> "$RAW"
  lower node20 esm "$BUILD/bundle.node20.mjs" "node20 / esm (V1)"
  lower node20 cjs "$BUILD/bundle.node20.cjs" "node20 / cjs (V3)"
  # es2020 for goja: keeps BigInt, lowers `using`. Allowed to fail (a recorded result).
  if ! lower es2020 cjs "$BUILD/bundle.goja.cjs" "es2020 / cjs (V2 goja)"; then
    echo "[prepare] NOTE: es2020 lowering failed — goja variant will report 'esbuild es2020: FAIL'."
  fi
  rm -f "$RAW"
fi

# ---------------------------------------------------------------- stage Variant 1
# Node baseline runs the shipping launcher path verbatim: claude.mjs + bun-shim.mjs
# over bundle.mjs, with cli.js as the require base and the runtime deps Bun provides
# but Node doesn't (ws, undici, js-yaml, argparse) alongside — exactly the install tree.
REPO="$(cd "$HERE/.." && pwd)"
NB="$HERE/node-baseline"
mkdir -p "$NB"                       # git-ignored (staged content) — recreate on fresh clone
# Locate the shipping shim. On the Mac it's ../shim; on a standalone deploy (e.g. the pad)
# it may be shipped in bench/shim, installed under /opt, or pointed to by $SHIM_DIR.
SHIMDIR=""
for d in "$HERE/shim" "$REPO/shim" "/opt/claude-code/lib/claude-code" "${SHIM_DIR:-}"; do
  [ -n "$d" ] && [ -f "$d/bun-shim.mjs" ] && [ -f "$d/claude.mjs" ] && { SHIMDIR="$d"; break; }
done
[ -n "$SHIMDIR" ] || { echo "FATAL: shim (claude.mjs + bun-shim.mjs) not found. Ship it to bench/shim/ or set SHIM_DIR." >&2; exit 1; }
echo "[prepare] staging Variant 1 (node-baseline) from shim: $SHIMDIR"
cp "$SHIMDIR/claude.mjs"   "$NB/claude.mjs"
cp "$SHIMDIR/bun-shim.mjs" "$NB/bun-shim.mjs"
cp "$BUILD/bundle.node20.mjs" "$NB/bundle.mjs"
cp "$HERE/input/cli.js"       "$NB/cli.js"      # require base + __filename only (not executed)
if [ ! -d "$NB/node_modules/ws" ]; then
  ( cd "$NB"
    printf '{"name":"node-baseline","private":true}\n' > package.json
    npm install --no-audit --no-fund --silent ws undici js-yaml argparse >/dev/null 2>&1
  ) || echo "[prepare] WARN: npm install of runtime deps failed (baseline --version may still work)."
fi

echo "[prepare] done → $BUILD (+ staged node-baseline)"
ls -la "$BUILD"/bundle.* 2>/dev/null || true
