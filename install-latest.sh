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
#     3. lowers the `using` syntax for broad compatibility (esbuild --target=node20),
#     4. runs it under Node 22 (installed from nodejs.org — 2.1.212+ hard-requires
#        >=22.17.0) with a small Bun→Node shim (shim/bun-shim.mjs — ~15 APIs; the
#        app already degrades gracefully on the Bun-only bits, "running under Node?").
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

# 1. Toolchain. Claude Code 2.1.212+ HARD-REQUIRES Node at runtime satisfying
#    ">=22.17.0 <23.0.0 || >=24.2.0" (guard in cli.js AND bundle.mjs; `--version`
#    still runs on Node 20, real agents do not). Debian only ships Node 20, and there
#    is NO official Node 24 armv7l build — so the one viable target is Node 22 armv7l
#    from nodejs.org. Its bundled npm builds esbuild + the runtime deps; ripgrep (the
#    app shells out to rg) still comes from apt. Node is installed into /usr/local so
#    `node`/`npm` resolve ahead of any Debian /usr/bin copy (no need to purge apt's).
NODE_VERSION="${CLAUDE_NODE_VERSION:-v22.22.0}"    # pinned armv7l build satisfying the guard
command -v rg >/dev/null || { log "Installing ripgrep…"; $SUDO apt-get update -qq; $SUDO apt-get install -y -qq ripgrep >/dev/null; }

node_ok() {   # does the resolved `node` satisfy Claude Code's engine guard?
  node -e 'const[a,b]=process.versions.node.split(".").map(Number);process.exit(((a===22&&b>=17)||(a>=24&&(a>24||b>=2)))?0:1)' 2>/dev/null
}
if node_ok; then
  log "Node $(node --version) already satisfies the >= 22.17 requirement."
else
  cur="$(node --version 2>/dev/null || echo none)"
  log "Installing Node $NODE_VERSION (armv7l, nodejs.org) — Claude Code needs >= 22.17 (have: $cur)…"
  ndir="$(mktemp -d -p /var/tmp claude-node.XXXXXX)"
  tb="node-$NODE_VERSION-linux-armv7l.tar.xz"
  curl -fSL --progress-bar -o "$ndir/$tb" "https://nodejs.org/dist/$NODE_VERSION/$tb" \
    || fail "Node $NODE_VERSION armv7l download failed (https://nodejs.org/dist/$NODE_VERSION/$tb)"
  $SUDO tar -xJf "$ndir/$tb" -C /usr/local --strip-components=1 \
    "node-$NODE_VERSION-linux-armv7l/bin" "node-$NODE_VERSION-linux-armv7l/include" \
    "node-$NODE_VERSION-linux-armv7l/lib" "node-$NODE_VERSION-linux-armv7l/share" \
    || fail "Node extract to /usr/local failed"
  rm -rf "$ndir"; hash -r 2>/dev/null || true
  node_ok || fail "Node $NODE_VERSION installed but the guard is still unmet (found: $(node --version 2>/dev/null); check PATH order of /usr/local/bin)."
  log "Node now: $(node --version) / npm $(npm --version 2>/dev/null)."
fi

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
# CJS (not ESM): the launcher runs the bundle through vm.Script to reuse a persisted V8
# bytecode cache, and --format=cjs also lowers the `import.meta` the bundle uses (the reason
# the old ESM wrapper existed). Same node20 target; still lowers `using`.
"$work/build/node_modules/.bin/esbuild" "$work/bundle.raw.mjs" \
  --outfile="$work/bundle.cjs" --format=cjs --target=node20 --platform=node --log-level=warning \
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
$S install -m644 "$work/bundle.cjs" "$LIB/bundle.cjs"   # vm.Script-cacheable, import.meta lowered
for f in shim/claude.mjs shim/bun-shim.mjs shim/claude-daemon.mjs shim/claude-client.mjs; do
  t="$(fetch_tmp "$f")" || fail "cannot fetch $f"
  $S install -m644 "$t" "$LIB/$(basename "$f")"; rm -f "$t"
done
for m in ws undici js-yaml argparse; do
  [ -d "$work/build/node_modules/$m" ] && $S cp -R "$work/build/node_modules/$m" "$LIB/node_modules/"
done
printf '%s\n' "$VER" > "$work/VERSION"
$S install -m644 "$work/VERSION" "$LIB/VERSION"

# 6b. Prime the V8 bytecode cache so EVERY launch is warm from the first (native behaviour).
#     The launcher compiles the 26 MB bundle once (~7 s on the H3) and writes
#     $LIB/bundle.v8cache; subsequent launches skip compilation (--version 8.4 s → 2.9 s on the
#     Smart Pi One). Built by the installer, which owns $LIB after the chown above → shared,
#     mode 644, all users read it. A missing/rejected cache (Node upgrade, or a per-user
#     read-only $LIB) is rebuilt automatically by the launcher, keyed on VERSION + running V8.
log "Priming V8 bytecode cache (one-time compile)…"
if node "$LIB/claude.mjs" --version >/dev/null 2>&1 && [ -f "$LIB/bundle.v8cache" ]; then
  log "cache primed ($(du -h "$LIB/bundle.v8cache" 2>/dev/null | cut -f1 | tr -d ' '))"
else
  warn "cache not primed now — the first launch builds it (still works, just slower once)."
fi

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
#
# CLAUDE_DAEMON=1 routes HEADLESS runs (-p/--print or piped stdin) through a
# bounded-concurrency job daemon: a 1 GB board can queue many agent jobs while
# only CLAUDE_MAX_CONCURRENT (default 3) hold a live runtime at once — the rest
# wait at ~0 RAM. Measured on the Smart Pi One: one runtime ~137 MB; 3 real
# agents concurrent leave ~190 MB free, 5 start swapping. The daemon lazy-starts
# on first job and self-exits after CLAUDE_IDLE_MS idle (no boot service).
# Interactive claude (full TUI) always stays a direct process — one TTY, one
# runtime. Unset/0 = direct, unchanged.
if [ "\${CLAUDE_DAEMON:-0}" = "1" ]; then
  headless=0; [ -t 0 ] || headless=1
  for a in "\$@"; do case "\$a" in -p|--print) headless=1;; esac; done
  [ "\$headless" = "1" ] && exec node "$LIB/claude-client.mjs" "\$@"
fi
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

✔ Claude Code $VER installed (extracted JS, runs on Node $(node --version 2>/dev/null || echo 22.x), no token).

Sign in with a Claude Pro/Max account (no API key, no local browser):
    claude setup-token
    claude-token-save sk-ant-oat01-…        # persist the printed 1-year token

Usage:
    claude                    full interactive interface
    claude -p "question"      one-shot answer
    CLAUDE_CPUS=0,1 claude …  throttle to 2 cores (no reinstall)
    CLAUDE_DAEMON=1 claude -p …   batch: queue many headless jobs, run only
                                  CLAUDE_MAX_CONCURRENT (default 3) at a time

Update later:  re-run install-latest.sh (fetches and builds the newest version).
Check first:   claude-check-update   →  {"installed":…,"latest":…,"update_available":…}
Roll back to the rock-solid pinned build:  install.sh  (2.1.112, pure JS).
MSG
