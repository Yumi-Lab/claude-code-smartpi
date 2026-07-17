#!/usr/bin/env bash
# Official Claude Code CLI on Yumi Smart Pi One / SmartPad — 32-bit ARM (armv7l)
#
# One-line install:
#   curl -fsSL https://raw.githubusercontent.com/Yumi-Lab/claude-code-smartpi/main/install.sh | bash
#
# This script installs:
#   @anthropic-ai/claude-code@2.1.112     last npm version distributed as pure JavaScript
#   ~/.claude/settings.json               env pinning (system ripgrep, auto-update off)
#   /usr/local/bin/claude-token-save      persist the 1-year OAuth token (Pro/Max login)
#   earlyoom                              anti-freeze memory safety net (1 GB RAM)
#
# Why 2.1.112 and nothing newer: from 2.1.113 the npm package is only a thin
# wrapper that downloads a Bun binary built for x64/arm64 → impossible on 32-bit.
# See docs/METHODOLOGY.md for the reasoning behind every choice.
set -euo pipefail

RAW="https://raw.githubusercontent.com/Yumi-Lab/claude-code-smartpi/main"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || true)"
CLAUDE_VER="2.1.112"   # LAST pure-JS npm version — do not bump on 32-bit

log()  { printf '\033[1;36m[claude-smartpi]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[claude-smartpi]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -m)" = "armv7l" ] || fail "This script targets armv7l (detected: $(uname -m)). On 64-bit, use the official installer instead."
command -v curl >/dev/null || fail "curl is required"
command -v python3 >/dev/null || fail "python3 is required"

# Fetch a file: local copy from a clone if available, otherwise raw GitHub.
fetch() { # $1 repo-relative path, $2 destination
  if [ -n "$HERE" ] && [ -f "$HERE/$1" ]; then
    sudo install -m755 "$HERE/$1" "$2"
  else
    tmpf=$(mktemp)
    curl -fsSL "$RAW/$1" -o "$tmpf"
    sudo install -m755 "$tmpf" "$2"
    rm -f "$tmpf"
  fi
}

# 1. Node.js ≥ 18 + system ripgrep, straight from Debian (trixie armhf ships
#    nodejs 20.19 and ripgrep 14.1 — no third-party repo needed).
log "Installing nodejs / npm / ripgrep…"
sudo apt-get update -qq
sudo apt-get install -y -qq nodejs npm ripgrep >/dev/null

NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
[ "$NODE_MAJOR" -ge 18 ] || fail "Claude Code needs Node ≥ 18 (found: $(node --version 2>/dev/null || echo none)). Debian 13 trixie armhf ships 20.x."

# 2. Claude Code, hard-pinned to the last pure-JS version.
#    --save-exact: NEVER let it float to ≥ 2.1.113 (Bun binary, 64-bit only).
log "Installing @anthropic-ai/claude-code@${CLAUDE_VER} (pure JS, a few minutes on the H3)…"
sudo npm install -g --save-exact "@anthropic-ai/claude-code@${CLAUDE_VER}" --no-audit --no-fund

# 3. Environment pinning in ~/.claude/settings.json:
#    USE_BUILTIN_RIPGREP=0   the package vendors no arm-linux ripgrep → system rg
#    DISABLE_AUTOUPDATER=1   one auto-update = 64-bit binary = broken install
mkdir -p ~/.claude
# A previous run through sudo may have left settings.json root-owned — take it back.
if [ -e ~/.claude/settings.json ] && [ ! -w ~/.claude/settings.json ]; then
  sudo chown "$(id -un):$(id -gn)" ~/.claude/settings.json
fi
python3 - <<'EOF'
import json, os
p = os.path.expanduser('~/.claude/settings.json')
s = json.load(open(p)) if os.path.exists(p) else {}
env = s.setdefault('env', {})
env.setdefault('USE_BUILTIN_RIPGREP', '0')
env.setdefault('DISABLE_AUTOUPDATER', '1')
s['autoUpdates'] = False
json.dump(s, open(p, 'w'), indent=2)
print('~/.claude/settings.json pinned:', ', '.join(sorted(env)))
EOF

# 4. Token helper: `claude setup-token` prints the 1-year OAuth token ONCE and
#    does not persist it — this helper saves it properly.
fetch bin/claude-token-save /usr/local/bin/claude-token-save

# 5. Anti-freeze safety net: kills the largest process before memory exhaustion
#    (1 GB of RAM + SD-card swap = full machine freeze otherwise).
if command -v apt-get >/dev/null; then
  sudo apt-get install -y -qq earlyoom >/dev/null 2>&1 \
    && sudo systemctl enable --now earlyoom >/dev/null 2>&1 \
    && log "earlyoom active" || true
fi

hash -r 2>/dev/null || true
log "Check: $(claude --version)"   # ~6 s on the H3, be patient

cat <<'MSG'

✔ Install complete.

Sign in with a Claude Pro/Max account (no API key, no local browser):
    claude setup-token
  → open the displayed URL in a browser (any machine), approve, paste the
    one-time code. The token (sk-ant-oat…, valid 1 year) is printed ONCE and
    saved nowhere: copy it immediately, then persist it with
    claude-token-save sk-ant-oat01-…

Usage:
    claude                    full interactive interface (native, pure JS)
    claude -p "question"      one-shot answer (~23 s on the H3)
    claude --version          sanity check (~6 s)

DO NOT:
    update Claude Code beyond 2.1.112 on 32-bit — every newer version is a
    64-bit Bun binary. Auto-update is disabled by this installer; to repair
    an install, re-run install.sh.
MSG
