#!/usr/bin/env bash
# DEPRECATED ALIAS — the single installer is now install.sh (it already installs the
# LATEST Claude Code at run time). This shim exists only so old one-liners and the
# Yumi AI Gateway OTA (which relaunches "install-latest.sh") keep working. It simply
# forwards to install.sh, passing any version argument through.
set -euo pipefail
REPO="Yumi-Lab/claude-code-smartpi"
RAW="https://raw.githubusercontent.com/${REPO}/main"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || true)"

if [ -n "$HERE" ] && [ -f "$HERE/install.sh" ]; then
  exec bash "$HERE/install.sh" "$@"          # local clone
fi
exec bash -c "$(curl -fsSL "$RAW/install.sh")" -- "$@"   # curl | bash
