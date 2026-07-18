#!/usr/bin/env bash
# LATEST Claude Code on Yumi Smart Pi One / SmartPad — 32-bit ARM (armv7l)
#
# One-line install (also the updater — re-run any time to move to the newest):
#   curl -fsSL https://raw.githubusercontent.com/Yumi-Lab/claude-code-smartpi/main/install-latest.sh | bash
#   curl -fsSL .../install-latest.sh | bash -s -- 2.1.212     # pin a specific version
#
# How it runs a >=2.1.113 version WITHOUT emulation and WITHOUT a token:
#   Since 2.1.113 the official CLI is a Bun-compiled binary (x64/arm64 only).
#   But the readable JS is embedded in that binary. This installer:
#     1. downloads the OFFICIAL binary from Anthropic (public URL, no account),
#     2. carves out its JavaScript on-device (shim/extract-bun-js.py),
#     3. lowers the `using` syntax to Node 20 (esbuild --target=node20),
#     4. runs it under Debian's own Node 20 with a small Bun→Node shim
#        (shim/bun-shim.mjs — ~15 APIs; the app already degrades gracefully
#        on the Bun-only bits, "running under Node?").
#   Nothing but our shim/launcher/extractor is fetched from this repo; the
#   Anthropic bundle is built locally and never redistributed.
#
# Sign in afterwards with a Claude Pro/Max account (no API key): claude setup-token
#
# Prefer the lightweight, rock-solid pinned build? Use install.sh (2.1.112, pure JS).
set -euo pipefail

REPO="Yumi-Lab/claude-code-smartpi"
RAW="https://raw.githubusercontent.com/${REPO}/main"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || true)"
REL="https://downloads.claude.ai/claude-code-releases"
# The extracted JS is identical for every platform — we only need the bytes.
DL_PLATFORM="${CLAUDE_DL_PLATFORM:-linux-arm64-musl}"
PREFIX="${CLAUDE_PREFIX:-/opt/claude-code}"       # install root (root-owned)
BINDIR="${CLAUDE_BINDIR:-/usr/local/bin}"
VER="${1:-${CLAUDE_VERSION:-latest}}"

log()  { printf '\033[1;36m[claude-smartpi]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[claude-smartpi]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -m)" = "armv7l" ] || fail "This script targets armv7l (detected: $(uname -m)). On 64-bit, use the official installer."
command -v curl >/dev/null || fail "curl is required"
command -v python3 >/dev/null || fail "python3 is required"

# Fetch one of our repo files: local clone if present, else raw GitHub.
fetch() { # $1 repo-relative path, $2 destination
  if [ -n "$HERE" ] && [ -f "$HERE/$1" ]; then
    sudo install -m644 "$HERE/$1" "$2"
  else
    local tmpf; tmpf="$(mktemp)"
    curl -fsSL "$RAW/$1" -o "$tmpf" || fail "cannot fetch $1"
    sudo install -m644 "$tmpf" "$2"; rm -f "$tmpf"
  fi
}

# 1. Toolchain: Debian ships Node 20 (which RUNS the esbuild-lowered bundle),
#    npm (to build esbuild + runtime deps), ripgrep (the app shells out to rg).
log "Installing nodejs / npm / ripgrep…"
sudo apt-get update -qq
sudo apt-get install -y -qq nodejs npm ripgrep >/dev/null
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
[ "$NODE_MAJOR" -ge 20 ] || fail "needs Node >= 20 (found: $(node --version 2>/dev/null || echo none)); Debian 13 trixie armhf ships 20.x."

# 2. Resolve the target version.
if [ "$VER" = "latest" ]; then
  VER="$(curl -fsSL "$REL/latest" | tr -d '[:space:]')"
  [ -n "$VER" ] || fail "could not resolve the latest version"
fi
log "Target version: $VER"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

# 3. Download the OFFICIAL binary (public, no token; ~240 MB — grab a coffee).
log "Downloading the official Claude Code binary ($DL_PLATFORM, ~240 MB)…"
curl -fSL --progress-bar -o "$work/claude.bin" "$REL/$VER/$DL_PLATFORM/claude" \
  || fail "download failed ($REL/$VER/$DL_PLATFORM/claude)"

# 4. Carve out the JavaScript on-device.
log "Extracting the JavaScript bundle…"
fetch shim/extract-bun-js.py "$work/extract.py"
python3 "$work/extract.py" "$work/claude.bin" -o "$work/extracted" --label "$VER" >/dev/null \
  || fail "JS extraction failed"
cli="$work/extracted/claude-${VER}.cli.js"
[ -f "$cli" ] || fail "extraction produced no cli.js"

# 5. Lower `using` (Node 20 can't parse it) and gather the runtime deps Bun
#    provides but Node doesn't. esbuild ships a linux-arm (armv7) binary.
log "Building the Node bundle (esbuild) + runtime deps…"
mkdir -p "$work/build"
( cd "$work/build"
  printf '{"name":"b","private":true}\n' > package.json
  npm install --no-audit --no-fund --silent esbuild ws undici js-yaml >/dev/null 2>&1
) || fail "npm install (esbuild + deps) failed"
printf 'export default ' > "$work/bundle.raw.mjs"
cat "$cli" >> "$work/bundle.raw.mjs"
"$work/build/node_modules/.bin/esbuild" "$work/bundle.raw.mjs" \
  --outfile="$work/bundle.mjs" --format=esm --target=node20 --platform=node --log-level=warning \
  || fail "esbuild failed"

# 6. Assemble the install tree under $PREFIX/lib/claude-code.
LIB="$PREFIX/lib/claude-code"
log "Installing to $LIB…"
sudo rm -rf "$LIB"
sudo mkdir -p "$LIB/node_modules"
sudo install -m644 "$cli" "$LIB/cli.js"           # require base / __filename
sudo install -m644 "$work/bundle.mjs" "$LIB/bundle.mjs"
fetch shim/claude.mjs "$LIB/claude.mjs"
fetch shim/bun-shim.mjs "$LIB/bun-shim.mjs"
for m in ws undici js-yaml argparse; do
  [ -d "$work/build/node_modules/$m" ] && sudo cp -R "$work/build/node_modules/$m" "$LIB/node_modules/"
done

# 7. Launcher wrapper — same CLAUDE_CPUS knob as the pinned build (all 4 cores
#    by default; CLAUDE_CPUS=0,1 to free cores, no reinstall). Uses system Node.
#    rm -f FIRST: if the pinned install left a symlink here, `tee` would follow it.
sudo rm -f "$BINDIR/claude"
sudo tee "$BINDIR/claude" >/dev/null <<EOF
#!/bin/sh
# Claude Code $VER (extracted JS + Bun→Node shim) on armv7l — managed by
# claude-code-smartpi/install-latest.sh. Re-run that script to update.
exec taskset -c "\${CLAUDE_CPUS:-0,1,2,3}" nice -n 5 node "$LIB/claude.mjs" "\$@"
EOF
sudo chmod +x "$BINDIR/claude"
echo "$VER" | sudo tee "$LIB/VERSION" >/dev/null

# 8. Environment pinning: system ripgrep + no auto-update (the shim owns updates).
mkdir -p ~/.claude
if [ -e ~/.claude/settings.json ] && [ ! -w ~/.claude/settings.json ]; then
  sudo chown "$(id -un):$(id -gn)" ~/.claude/settings.json
fi
python3 - <<'EOF'
import json, os
p = os.path.expanduser('~/.claude/settings.json')
s = json.load(open(p)) if os.path.exists(p) else {}
env = s.setdefault('env', {})
env.setdefault('USE_BUILTIN_RIPGREP', '0')   # no arm-linux ripgrep vendored → system rg
env['DISABLE_AUTOUPDATER'] = '1'             # updates go through install-latest.sh
s['autoUpdates'] = False
json.dump(s, open(p, 'w'), indent=2)
print('~/.claude/settings.json pinned:', ', '.join(sorted(env)))
EOF

# 9. Token helper + anti-freeze safety net (1 GB RAM).
fetch bin/claude-token-save "$BINDIR/claude-token-save"; sudo chmod +x "$BINDIR/claude-token-save"
sudo apt-get install -y -qq earlyoom >/dev/null 2>&1 \
  && sudo systemctl enable --now earlyoom >/dev/null 2>&1 && log "earlyoom active" || true

hash -r 2>/dev/null || true
log "Check: $(timeout 40 claude --version 2>/dev/null || echo 'claude --version did not answer in 40 s — try again on an idle board')"

cat <<MSG

✔ Claude Code $VER installed (extracted JS, runs on Debian's Node 20, no token).

Sign in with a Claude Pro/Max account (no API key, no local browser):
    claude setup-token
    claude-token-save sk-ant-oat01-…        # persist the printed 1-year token

Usage:
    claude                    full interactive interface
    claude -p "question"      one-shot answer
    CLAUDE_CPUS=0,1 claude …  throttle to 2 cores (no reinstall)

Update later:  re-run install-latest.sh (fetches and builds the newest version).
Roll back to the rock-solid pinned build:  install.sh  (2.1.112, pure JS).
MSG
