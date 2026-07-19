#!/usr/bin/env bash
# LATEST Claude Code on Yumi Smart Pi One / SmartPad — 32-bit ARM (armv7l)
#
# One-line install (also the UPDATER — re-run any time to move to the newest):
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
# OTA contract (shared by every Yumi-Lab/*-smartpi repo):
#   * re-running this script IS the update; it exits fast when already newest
#     (CLAUDE_FORCE=1 to rebuild anyway);
#   * `claude-check-update` (installed alongside) prints one JSON line
#     {installed, latest, update_available} — what the Yumi AI Gateway polls;
#   * privileges: root (or sudo) for the FIRST install; a plain user that OWNS
#     $PREFIX for updates — the gateway service user updates WITHOUT sudo (the
#     wrapper in /usr/local/bin is version-independent and never rewritten).
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
PREFIX="${CLAUDE_PREFIX:-/opt/claude-code}"       # install root (payload)
BINDIR="${CLAUDE_BINDIR:-/usr/local/bin}"
VER="${1:-${CLAUDE_VERSION:-latest}}"

log()  { printf '\033[1;36m[claude-smartpi]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[claude-smartpi]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[claude-smartpi]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -m)" = "armv7l" ] || fail "This script targets armv7l (detected: $(uname -m)). On 64-bit, use the official installer."
command -v curl >/dev/null || fail "curl is required"
command -v python3 >/dev/null || fail "python3 is required"

# --- Privilege model. Root → no sudo. Non-root owning $PREFIX (the gateway
#     service user doing an OTA update) → plain writes, NO sudo at all. Anything
#     else → sudo (first install by a normal user; may prompt for a password).
if [ "$(id -u)" -eq 0 ]; then SUDO=""
elif [ -d "$PREFIX" ] && [ -w "$PREFIX" ]; then SUDO=""
else SUDO="sudo"
fi
# Remember who owns an existing payload: a root re-run over a service-owned tree
# must give it back at the end, or the next unprivileged OTA update would break.
PREFIX_OWNER="$(stat -c %U "$PREFIX" 2>/dev/null || echo)"

# Install a file (mode $3, default 644) without sudo when the target dir allows it.
put() { # $1 src, $2 dest, $3 mode
  local dir; dir="$(dirname "$2")"
  if [ -w "$dir" ] || { [ -e "$2" ] && [ -w "$2" ]; }; then
    install -m "${3:-644}" "$1" "$2"
  else
    $SUDO install -m "${3:-644}" "$1" "$2"
  fi
}

# Fetch one of our repo files to a temp path: local clone if present, else raw GitHub.
fetch_tmp() { # $1 repo-relative path → prints temp file path
  local tmpf; tmpf="$(mktemp)"
  if [ -n "$HERE" ] && [ -f "$HERE/$1" ]; then
    cat "$HERE/$1" > "$tmpf"
  else
    curl -fsSL "$RAW/$1" -o "$tmpf" || { rm -f "$tmpf"; return 1; }
  fi
  printf '%s' "$tmpf"
}

# Write $2 (a temp file) to $1 only when the content differs — routine updates
# never touch $BINDIR (root-owned), so the unprivileged OTA path stays clean.
# Returns non-zero (does NOT abort) when the write is impossible: the caller
# decides whether a stale-but-functional file is acceptable.
put_if_changed() { # $1 dest, $2 src, $3 mode
  if [ -e "$1" ] && cmp -s "$1" "$2"; then rm -f "$2"; return 0; fi
  local rc=0
  put "$2" "$1" "${3:-755}" || rc=$?
  rm -f "$2"; return $rc
}

# 1. Toolchain: Debian ships Node 20 (which RUNS the esbuild-lowered bundle),
#    npm (to build esbuild + runtime deps), ripgrep (the app shells out to rg).
#    Already present (any re-run / OTA update) → no apt, no sudo needed.
if command -v node >/dev/null && command -v npm >/dev/null && command -v rg >/dev/null; then
  log "Toolchain already present (node $(node --version 2>/dev/null))."
else
  log "Installing nodejs / npm / ripgrep…"
  $SUDO apt-get update -qq
  $SUDO apt-get install -y -qq nodejs npm ripgrep >/dev/null
fi
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
[ "$NODE_MAJOR" -ge 20 ] || fail "needs Node >= 20 (found: $(node --version 2>/dev/null || echo none)); Debian 13 trixie armhf ships 20.x."

# 2. Resolve the target version, and stop right here when already on it.
if [ "$VER" = "latest" ]; then
  VER="$(curl -fsSL "$REL/latest" | tr -d '[:space:]')"
  [ -n "$VER" ] || fail "could not resolve the latest version"
fi
LIB="$PREFIX/lib/claude-code"
CURRENT="$(head -1 "$LIB/VERSION" 2>/dev/null | tr -d '[:space:]' || true)"
if [ "$CURRENT" = "$VER" ] && [ -z "${CLAUDE_FORCE:-}" ]; then
  log "Claude Code $VER is already installed — nothing to do (CLAUDE_FORCE=1 to rebuild)."
  exit 0
fi
log "Target version: $VER (installed: ${CURRENT:-none})"

# /var/tmp, NOT /tmp: /tmp is often a tmpfs (RAM) on Armbian, and the official
# binary alone weighs ~240 MB — on a 1 GB board that's an OOM freeze waiting.
work="$(mktemp -d -p /var/tmp claude-smartpi.XXXXXX)"; trap 'rm -rf "$work"' EXIT

# 3. Download the OFFICIAL binary (public, no token; ~240 MB — grab a coffee).
log "Downloading the official Claude Code binary ($DL_PLATFORM, ~240 MB)…"
curl -fSL --progress-bar -o "$work/claude.bin" "$REL/$VER/$DL_PLATFORM/claude" \
  || fail "download failed ($REL/$VER/$DL_PLATFORM/claude)"

# 4. Carve out the JavaScript on-device.
log "Extracting the JavaScript bundle…"
ex="$(fetch_tmp shim/extract-bun-js.py)" || fail "cannot fetch shim/extract-bun-js.py"
python3 "$ex" "$work/claude.bin" -o "$work/extracted" --label "$VER" >/dev/null \
  || fail "JS extraction failed"
rm -f "$ex"
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
log "Installing to $LIB…"
$SUDO mkdir -p "$PREFIX"
if [ -w "$PREFIX" ]; then RMLIB=""; else RMLIB="$SUDO"; fi
$RMLIB rm -rf "$LIB"
$RMLIB mkdir -p "$LIB/node_modules"
# The mkdir above may have been root's — make sure we can fill the tree.
[ -w "$LIB" ] || $SUDO chown -R "$(id -un):$(id -gn)" "$PREFIX" 2>/dev/null || true
S=""; [ -w "$LIB" ] || S="$SUDO"
$S install -m644 "$cli" "$LIB/cli.js"           # require base / __filename
$S install -m644 "$work/bundle.mjs" "$LIB/bundle.mjs"
for f in shim/claude.mjs shim/bun-shim.mjs; do
  t="$(fetch_tmp "$f")" || fail "cannot fetch $f"
  $S install -m644 "$t" "$LIB/$(basename "$f")"; rm -f "$t"
done
for m in ws undici js-yaml argparse; do
  [ -d "$work/build/node_modules/$m" ] && $S cp -R "$work/build/node_modules/$m" "$LIB/node_modules/"
done
printf '%s\n' "$VER" > "$work/VERSION"
$S install -m644 "$work/VERSION" "$LIB/VERSION"

# 7. Launcher wrapper — same CLAUDE_CPUS knob as the pinned build (all 4 cores
#    by default; CLAUDE_CPUS=0,1 to free cores, no reinstall). Uses system Node.
#    VERSION-INDEPENDENT on purpose: routine updates only swap the payload in
#    $LIB, so an unprivileged (gateway) update never has to touch $BINDIR.
#    put_if_changed also neutralizes a stale pinned-install symlink (rm first).
wrap="$(mktemp)"
cat > "$wrap" <<EOF
#!/bin/sh
# Claude Code (extracted JS + Bun→Node shim) on armv7l — managed by
# claude-code-smartpi/install-latest.sh. Version: see $LIB/VERSION.
# Re-run install-latest.sh (or the gateway console update button) to update.
exec taskset -c "\${CLAUDE_CPUS:-0,1,2,3}" nice -n 5 node "$LIB/claude.mjs" "\$@"
EOF
if [ -L "$BINDIR/claude" ]; then $SUDO rm -f "$BINDIR/claude" || true; fi
if ! put_if_changed "$BINDIR/claude" "$wrap" 755; then
  if [ -x "$BINDIR/claude" ]; then
    warn "cannot rewrite $BINDIR/claude (no privileges) — existing wrapper kept, payload updated."
  else
    fail "cannot install the $BINDIR/claude wrapper (run once as root/sudo first)."
  fi
fi

# 8. Environment pinning: system ripgrep + no auto-update (the shim owns updates).
mkdir -p ~/.claude
if [ -e ~/.claude/settings.json ] && [ ! -w ~/.claude/settings.json ]; then
  $SUDO chown "$(id -un):$(id -gn)" ~/.claude/settings.json
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

# 9. Helpers: token save + update probe (the OTA contract's JSON one-liner).
for h in bin/claude-token-save bin/claude-check-update; do
  t="$(fetch_tmp "$h")" || { warn "cannot fetch $h (non-fatal)"; continue; }
  put_if_changed "$BINDIR/$(basename "$h")" "$t" 755 \
    || warn "cannot write $BINDIR/$(basename "$h") (no privileges) — existing copy kept."
done

# 10. Anti-freeze safety net (1 GB RAM). Optional: root/passwordless-sudo only —
#     an unprivileged OTA update silently skips it (it was set up at install time).
if [ -z "$SUDO" ] && [ "$(id -u)" -eq 0 ]; then
  apt-get install -y -qq earlyoom >/dev/null 2>&1 \
    && systemctl enable --now earlyoom >/dev/null 2>&1 && log "earlyoom active" || true
elif sudo -n true 2>/dev/null; then
  sudo apt-get install -y -qq earlyoom >/dev/null 2>&1 \
    && sudo systemctl enable --now earlyoom >/dev/null 2>&1 && log "earlyoom active" || true
fi

# A root re-run over a service-owned payload gives ownership back (the gateway
# service user must keep updating without sudo).
if [ "$(id -u)" -eq 0 ] && [ -n "$PREFIX_OWNER" ] && [ "$PREFIX_OWNER" != "root" ] \
   && id "$PREFIX_OWNER" >/dev/null 2>&1; then
  chown -R "$PREFIX_OWNER" "$PREFIX" && log "ownership of $PREFIX returned to $PREFIX_OWNER"
fi

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
Check first:   claude-check-update   →  {"installed":…,"latest":…,"update_available":…}
Roll back to the rock-solid pinned build:  install.sh  (2.1.112, pure JS).
MSG
